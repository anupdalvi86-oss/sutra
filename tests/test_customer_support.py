import base64
import hashlib
import hmac
import json
import os
import time
import unittest
from unittest.mock import Mock
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from sutra.customer_support import (ZendeskReplyClient, ZendeskReplyDeliveryWorker,
                                    ZendeskReplyResult, ZendeskTaskContextProvider, ZendeskTicketReader,
                                    normalize_zendesk_ticket_event, verify_zendesk_signature)
from sutra.runtime import IntegrationError
from sutra.server import SutraApplication


class ZendeskWebhookTests(unittest.TestCase):
    def setUp(self):
        self.secret = "synthetic-zendesk-secret"
        self.timestamp = str(int(time.time()))
        self.payload = {"id": 123, "status": "open", "priority": "normal",
                        "updated_at": "2026-09-30T09:00:00Z"}
        self.body = json.dumps(self.payload, separators=(",", ":")).encode()
        self.signature = base64.b64encode(hmac.new(
            self.secret.encode(), self.timestamp.encode() + self.body, hashlib.sha256
        ).digest()).decode()

    def test_verifies_exact_raw_body_and_timestamp_window(self):
        self.assertTrue(verify_zendesk_signature(self.secret, self.timestamp, self.body,
                                                 self.signature, now=int(self.timestamp)))
        self.assertFalse(verify_zendesk_signature(self.secret, self.timestamp, self.body + b" ",
                                                  self.signature, now=int(self.timestamp)))
        self.assertFalse(verify_zendesk_signature("wrong", self.timestamp, self.body,
                                                  self.signature, now=int(self.timestamp)))
        self.assertFalse(verify_zendesk_signature(self.secret, self.timestamp, self.body,
                                                  self.signature, now=int(self.timestamp) + 301))
        self.assertFalse(verify_zendesk_signature(self.secret, "1e3", self.body, self.signature,
                                                  now=int(self.timestamp)))

    def test_normalizer_keeps_only_bounded_ticket_metadata(self):
        result = normalize_zendesk_ticket_event({**self.payload, "requester": {"email": "secret@example.test"}})
        self.assertIsNone(result)
        result = normalize_zendesk_ticket_event(self.payload)
        self.assertEqual(result, {"ticket_id": "123", "status": "open", "priority": "normal",
                                  "updated_at": "2026-09-30T09:00:00.000000Z"})
        for update in (
            {**self.payload, "status": "unknown"},
            {**self.payload, "priority": "critical"},
            {**self.payload, "id": True},
            {**self.payload, "updated_at": "2026-09-30T09:00:00"},
        ):
            self.assertIsNone(normalize_zendesk_ticket_event(update))


class ZendeskTicketReadTests(unittest.TestCase):
    class Response:
        def __init__(self, value):
            self.value = json.dumps(value).encode()
        def __enter__(self):
            return self
        def __exit__(self, *_args):
            return False
        def read(self, size=-1):
            return self.value[:size]

    def test_reads_bounded_ticket_and_public_comments_without_metadata(self):
        values = [
            {"ticket": {"id": 123, "subject": "Cannot sign in", "description": "Login fails.",
                         "status": "open", "priority": "high", "requester": {"email": "private@example.test"}}},
            {"comments": [
                {"public": False, "plain_body": "Internal staff note."},
                {"public": True, "plain_body": "I cannot log in."},
            ]},
        ]
        requests = []
        def opener(request, timeout):
            requests.append(request)
            return self.Response(values.pop(0))
        reader = ZendeskTicketReader("sutra", "agent@example.test", "secret-token", opener=opener)
        result = reader.read_ticket("123")
        self.assertEqual(result, {"ticket_id": "123", "status": "open", "priority": "high",
                                  "subject": "Cannot sign in", "description": "Login fails.",
                                  "recent_public_comments": ["I cannot log in."]})
        self.assertEqual(len(requests), 2)
        self.assertNotIn("private@example.test", json.dumps(result))
        self.assertEqual(requests[0].get_header("Authorization"), "Basic " + base64.b64encode(
            b"agent@example.test/token:secret-token").decode())
        self.assertIn("sort_order=desc", requests[1].full_url)

    def test_rejects_unsafe_subdomains_and_closed_tickets(self):
        for subdomain in ("https://example.com", "example.com/evil", "user@example.com"):
            with self.assertRaises(ValueError):
                ZendeskTicketReader(subdomain, "agent@example.test", "token")
        reader = ZendeskTicketReader("sutra", "agent@example.test", "token",
            opener=lambda *_args, **_kwargs: self.Response({"ticket": {"id": 123, "status": "solved"}}))
        with self.assertRaisesRegex(IntegrationError, "closed"):
            reader.read_ticket("123")

    def test_support_context_is_database_authorized_before_provider_fetch(self):
        events = []
        class Store:
            def rpc(self, name, payload):
                events.append((name, payload))
                return {"ticket_id": "123"}
        class Reader:
            def read_ticket(self, ticket_id):
                events.append(("provider_read", ticket_id))
                return {"ticket_id": ticket_id, "status": "open"}
        provider = ZendeskTaskContextProvider(Store(), Reader())
        run = {"agent": {"id": "agent-id", "slug": "sales"},
               "task_artifact": {"task_id": "task-id", "title": "Reply to Zendesk ticket",
                 "description": "Zendesk ticket ID: 123", "acceptance_criteria": ["Classify the case"]}}
        self.assertEqual(provider(run), {"ticket_id": "123", "status": "open"})
        self.assertEqual(events[0], ("sutra_authorize_zendesk_task_context", {
            "p_agent_id": "agent-id", "p_task_id": "task-id", "p_ticket_id": "123"}))
        self.assertEqual(events[1], ("provider_read", "123"))
        run["task_artifact"]["description"] = "Zendesk ticket ID: 123; Zendesk ticket ID: 456"
        with self.assertRaisesRegex(IntegrationError, "exactly one"):
            provider(run)
        self.assertEqual(len(events), 2)


class ZendeskReplyClientTests(unittest.TestCase):
    class Response:
        def __init__(self, value):
            self.value = json.dumps(value).encode()
        def __enter__(self):
            return self
        def __exit__(self, *_args):
            return False
        def read(self, size=-1):
            return self.value[:size]

    def action(self, **overrides):
        return {"ticket_id": "123", "reply_text": "Please try account recovery again.",
                "idempotency_key": "zendesk-reply-action-0001", **overrides}

    @staticmethod
    def ticket(updated_at="2026-09-30T09:00:00Z", status="open"):
        return {"ticket": {"id": 123, "status": status, "updated_at": updated_at}}

    def reader(self, opener):
        return ZendeskTicketReader("sutra", "agent@example.test", "token", opener=opener)

    def test_sends_one_public_reply_with_fresh_safe_update_and_database_recheck(self):
        replies = [self.Response(self.ticket()), self.Response(self.ticket("2026-09-30T09:01:00Z"))]
        requests = []
        def opener(request, timeout):
            requests.append(request)
            return replies.pop(0)
        checks = []
        result = ZendeskReplyClient(self.reader(opener)).send(self.action(), lambda: checks.append(True) or True)
        self.assertEqual(result, ZendeskReplyResult("sent"))
        self.assertEqual(len(requests), 2)
        self.assertEqual(checks, [True])
        self.assertEqual(requests[1].get_method(), "PUT")
        self.assertEqual(requests[1].get_header("Authorization"), "Basic " + base64.b64encode(
            b"agent@example.test/token:token").decode())
        self.assertEqual(json.loads(requests[1].data), {"ticket": {
            "comment": {"body": "Please try account recovery again.", "public": True},
            "safe_update": True, "updated_stamp": "2026-09-30T09:00:00Z"}})

    def test_safe_update_conflict_refetches_and_reauthorizes_once(self):
        requests = []
        stamps = ["2026-09-30T09:00:00Z", "2026-09-30T09:02:00Z"]
        def opener(request, timeout):
            requests.append(request)
            if request.get_method() == "GET":
                return self.Response(self.ticket(stamps.pop(0)))
            if len([item for item in requests if item.get_method() == "PUT"]) == 1:
                raise HTTPError(request.full_url, 409, "conflict", {}, None)
            return self.Response(self.ticket("2026-09-30T09:03:00Z"))
        checks = []
        result = ZendeskReplyClient(self.reader(opener)).send(self.action(), lambda: checks.append(True) or True)
        self.assertEqual(result, ZendeskReplyResult("sent"))
        self.assertEqual([item.get_method() for item in requests], ["GET", "PUT", "GET", "PUT"])
        self.assertEqual(checks, [True, True])
        self.assertEqual(json.loads(requests[-1].data)["ticket"]["updated_stamp"], "2026-09-30T09:02:00Z")

    def test_safe_update_conflict_retry_is_bounded(self):
        requests = []
        def opener(request, timeout):
            requests.append(request)
            if request.get_method() == "GET":
                return self.Response(self.ticket(f"2026-09-30T09:0{len(requests)}:00Z"))
            raise HTTPError(request.full_url, 409, "safe conflict", {}, None)
        checks = []
        result = ZendeskReplyClient(self.reader(opener)).send(self.action(), lambda: checks.append(True) or True)
        self.assertEqual(result, ZendeskReplyResult("failed", "safe_update_conflict"))
        self.assertEqual([item.get_method() for item in requests], ["GET", "PUT", "GET", "PUT"])
        self.assertEqual(checks, [True, True])

    def test_revoked_authorization_or_closed_ticket_prevents_public_write(self):
        requests = []
        reader = self.reader(lambda req, timeout: requests.append(req) or self.Response(self.ticket()))
        result = ZendeskReplyClient(reader).send(self.action(), lambda: False)
        self.assertEqual(result, ZendeskReplyResult("failed", "authorization_revoked"))
        self.assertEqual([item.get_method() for item in requests], ["GET"])

        requests.clear()
        reader = self.reader(lambda req, timeout: requests.append(req) or self.Response(self.ticket(status="closed")))
        result = ZendeskReplyClient(reader).send(self.action(), lambda: True)
        self.assertEqual(result, ZendeskReplyResult("failed", "ticket_not_actionable"))
        self.assertEqual([item.get_method() for item in requests], ["GET"])

    def test_ambiguous_write_is_terminal_and_known_provider_rejection_is_failed(self):
        def timeout_after_write(request, timeout):
            if request.get_method() == "GET":
                return self.Response(self.ticket())
            raise TimeoutError("response lost")
        result = ZendeskReplyClient(self.reader(timeout_after_write)).send(self.action(), lambda: True)
        self.assertEqual(result, ZendeskReplyResult("unknown", "provider_outcome_unknown"))

        def reject(request, timeout):
            if request.get_method() == "GET":
                return self.Response(self.ticket())
            raise HTTPError(request.full_url, 403, "rejected", {}, None)
        result = ZendeskReplyClient(self.reader(reject)).send(self.action(), lambda: True)
        self.assertEqual(result, ZendeskReplyResult("failed", "provider_rejected"))

    def test_malformed_action_fails_without_network(self):
        opener = Mock()
        result = ZendeskReplyClient(self.reader(opener)).send(self.action(ticket_id="../../users"), lambda: True)
        self.assertEqual(result, ZendeskReplyResult("failed", "invalid_action"))
        opener.assert_not_called()


class ZendeskReplyDeliveryWorkerTests(unittest.TestCase):
    def claim(self):
        return {"action_id": "reply-action-0001", "claim_token": "claim-token-0001",
                "ledger_id": "ledger-entry-0001", "action": {"ticket_id": "123"}}

    def test_empty_queue_has_no_provider_activity(self):
        store = Mock()
        store.claim_zendesk_reply_action.return_value = None
        provider = Mock()
        worker = ZendeskReplyDeliveryWorker(store, provider)
        self.assertFalse(worker.run_once())
        provider.send.assert_not_called()

    def test_rechecks_authorization_and_keeps_unknown_reservation(self):
        store = Mock()
        store.claim_zendesk_reply_action.return_value = self.claim()
        store.validate_zendesk_reply_claim.return_value = True
        provider = Mock()
        def send(action, authorize):
            self.assertEqual(action, self.claim()["action"])
            self.assertTrue(authorize())
            return ZendeskReplyResult("unknown", "provider_outcome_unknown")
        provider.send.side_effect = send
        worker = ZendeskReplyDeliveryWorker(store, provider)
        self.assertTrue(worker.run_once())
        provider.send.assert_called_once()
        store.finish_zendesk_reply_action.assert_called_once_with(
            "sutra-worker-zendesk0001", "reply-action-0001", "claim-token-0001",
            "unknown", "provider_outcome_unknown", None, False)

    def test_revoked_claim_never_calls_provider_and_releases_known_zero(self):
        store = Mock()
        store.claim_zendesk_reply_action.return_value = self.claim()
        store.validate_zendesk_reply_claim.return_value = False
        provider = Mock()
        worker = ZendeskReplyDeliveryWorker(store, provider)
        self.assertTrue(worker.run_once())
        provider.send.assert_not_called()
        store.finish_zendesk_reply_action.assert_called_once_with(
            "sutra-worker-zendesk0001", "reply-action-0001", "claim-token-0001",
            "failed", "authorization_revoked", 0, True)

    def test_malformed_claim_fails_closed(self):
        store = Mock()
        store.claim_zendesk_reply_action.return_value = {"action_id": "reply-action-0001"}
        worker = ZendeskReplyDeliveryWorker(store, Mock())
        with self.assertRaisesRegex(IntegrationError, "invalid Zendesk reply claim"):
            worker.run_once()


class ZendeskWebhookServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from http.server import ThreadingHTTPServer
        from threading import Thread
        from sutra.server import SutraHandler
        from tests.test_server import FakeStore

        cls.app = SutraApplication()
        cls.app.store = FakeStore()
        cls.app.zendesk_webhook_secret = "synthetic-zendesk-secret"
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), SutraHandler)
        cls.server.app = cls.app
        cls.thread = Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def test_endpoint_is_disabled_by_default_and_persists_minimized_event_when_enabled(self):
        payload = {"id": 234, "status": "pending", "priority": "high",
                   "updated_at": "2026-09-30T09:00:00Z"}
        body = json.dumps(payload, separators=(",", ":")).encode()
        timestamp = str(int(time.time()))
        signature = base64.b64encode(hmac.new(
            self.app.zendesk_webhook_secret.encode(), timestamp.encode() + body, hashlib.sha256
        ).digest()).decode()
        request = Request(f"{self.base}/webhooks/zendesk", data=body, headers={
            "Content-Type": "application/json", "X-Zendesk-Webhook-Timestamp": timestamp,
            "X-Zendesk-Webhook-Signature": signature,
        }, method="POST")
        with patch_env("SUTRA_ENABLE_ZENDESK_WEBHOOK", "false"):
            with self.assertRaises(HTTPError) as caught:
                urlopen(request, timeout=2)
        self.assertEqual(caught.exception.code, 503)
        before = len(self.app.store.calls)
        with patch_env("SUTRA_ENABLE_ZENDESK_WEBHOOK", "true"):
            with urlopen(request, timeout=2) as response:
                self.assertEqual(response.status, 202)
        self.assertEqual(len(self.app.store.calls), before + 1)
        name, args = self.app.store.calls[-1]
        self.assertEqual(name, "sutra_ingest_zendesk_ticket_event")
        self.assertEqual(args, {"p_ticket_id": "234", "p_status": "pending", "p_priority": "high",
                                "p_provider_updated_at": "2026-09-30T09:00:00.000000Z",
                                "p_route_tasks": False})

        configured_context = self.app.zendesk_support_context_provider
        try:
            self.app.zendesk_support_context_provider = object()
            routed_payload = {"id": 235, "status": "open", "priority": "normal",
                              "updated_at": "2026-09-30T09:01:00Z"}
            routed_body = json.dumps(routed_payload, separators=(",", ":")).encode()
            routed_signature = base64.b64encode(hmac.new(
                self.app.zendesk_webhook_secret.encode(), timestamp.encode() + routed_body, hashlib.sha256
            ).digest()).decode()
            routed_request = Request(f"{self.base}/webhooks/zendesk", data=routed_body, headers={
                "Content-Type": "application/json", "X-Zendesk-Webhook-Timestamp": timestamp,
                "X-Zendesk-Webhook-Signature": routed_signature,
            }, method="POST")
            with patch_env("SUTRA_ENABLE_ZENDESK_WEBHOOK", "true"):
                with urlopen(routed_request, timeout=2) as response:
                    self.assertEqual(response.status, 202)
            self.assertTrue(self.app.store.calls[-1][1]["p_route_tasks"])
        finally:
            self.app.zendesk_support_context_provider = configured_context


class patch_env:
    def __init__(self, key, value):
        self.key, self.value = key, value
    def __enter__(self):
        self.old = os.environ.get(self.key)
        os.environ[self.key] = self.value
    def __exit__(self, *_args):
        if self.old is None:
            os.environ.pop(self.key, None)
        else:
            os.environ[self.key] = self.old


if __name__ == "__main__":
    unittest.main()
