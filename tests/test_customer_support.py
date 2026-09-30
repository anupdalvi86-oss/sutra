import base64
import hashlib
import hmac
import json
import os
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from sutra.customer_support import normalize_zendesk_ticket_event, verify_zendesk_signature
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
                                "p_provider_updated_at": "2026-09-30T09:00:00.000000Z"})


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
