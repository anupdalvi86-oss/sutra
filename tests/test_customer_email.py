import json
import urllib.error
import unittest
from unittest.mock import Mock, patch

from sutra.customer_email import (
    CustomerEmailDeliveryWorker,
    EmailDeliveryResult,
    ResendEmailProvider,
)
from sutra.runtime import IntegrationError


class FakeResponse:
    def __init__(self, body=b'{"id":"email_123"}'):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, limit):
        return self.body[:limit]


class ResendEmailProviderTests(unittest.TestCase):
    def provider(self, opener):
        return ResendEmailProvider("test-secret", "Sutra <founder@example.test>", opener=opener)

    def action(self, **changes):
        return {
            "recipient_email": "customer@example.test",
            "subject": "A short follow-up",
            "body_text": "Would a short overview help?",
            "idempotency_key": "email-action-0001",
            **changes,
        }

    def test_request_is_single_recipient_plain_text_and_idempotent(self):
        response = FakeResponse()
        opener = Mock(return_value=response)
        result = self.provider(opener).send(self.action())
        self.assertEqual(result, EmailDeliveryResult("sent", provider_message_id="email_123"))
        request = opener.call_args.args[0]
        timeout = opener.call_args.kwargs["timeout"]
        self.assertEqual(request.full_url, "https://api.resend.com/emails")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.get_header("Authorization"), "Bearer test-secret")
        self.assertEqual(request.get_header("Idempotency-key"), "email-action-0001")
        self.assertEqual(json.loads(request.data), {
            "from": "Sutra <founder@example.test>",
            "to": ["customer@example.test"],
            "subject": "A short follow-up",
            "text": "Would a short overview help?",
        })
        self.assertEqual(timeout, 8.0)

    def test_malformed_action_fails_without_network(self):
        opener = Mock()
        result = self.provider(opener).send(self.action(recipient_email="bad-address"))
        self.assertEqual(result, EmailDeliveryResult("failed", error_code="invalid_action"))
        opener.assert_not_called()

    def test_malformed_success_response_is_unknown(self):
        result = self.provider(lambda *_args, **_kwargs: FakeResponse(b'{"unexpected":true}')).send(self.action())
        self.assertEqual(result, EmailDeliveryResult("unknown", error_code="malformed_provider_response"))

    def test_deterministic_rejection_is_failed_but_ambiguous_http_is_unknown(self):
        def http_error(code):
            def open_request(*_args, **_kwargs):
                raise urllib.error.HTTPError(
                    "https://api.resend.com/emails", code, "provider error", {}, None)
            return open_request

        self.assertEqual(self.provider(http_error(400)).send(self.action()),
                         EmailDeliveryResult("failed", error_code="provider_rejected"))
        for code in (408, 409, 425, 429, 500):
            with self.subTest(code=code):
                self.assertEqual(self.provider(http_error(code)).send(self.action()),
                                 EmailDeliveryResult("unknown", error_code="provider_outcome_unknown"))


class CustomerEmailDeliveryWorkerTests(unittest.TestCase):
    def claim(self):
        return {
            "action_id": "00000000-0000-4000-8000-000000000001",
            "claim_token": "00000000-0000-4000-8000-000000000002",
            "ledger_id": "00000000-0000-4000-8000-000000000003",
            "action": {"recipient_email": "customer@example.test"},
        }

    def test_empty_queue_does_not_send(self):
        store = Mock()
        store.claim_customer_email_action.return_value = None
        provider = Mock()
        worker = CustomerEmailDeliveryWorker(store, provider)
        self.assertFalse(worker.run_once())
        provider.send.assert_not_called()

    def test_rechecks_authorization_before_provider_and_records_unknown_cost(self):
        store = Mock()
        store.claim_customer_email_action.return_value = self.claim()
        store.validate_customer_email_claim.return_value = True
        provider = Mock()
        provider.send.return_value = EmailDeliveryResult("unknown", error_code="provider_outcome_unknown")
        worker = CustomerEmailDeliveryWorker(store, provider)
        self.assertTrue(worker.run_once())
        store.validate_customer_email_claim.assert_called_once_with(
            "sutra-worker-email0001", self.claim()["action_id"], self.claim()["claim_token"])
        provider.send.assert_called_once_with(self.claim()["action"])
        store.finish_customer_email_action.assert_called_once_with(
            "sutra-worker-email0001", self.claim()["action_id"], self.claim()["claim_token"],
            "unknown", None, "provider_outcome_unknown", None, False)

    def test_revoked_authorization_prevents_provider_call_and_settles_zero(self):
        store = Mock()
        store.claim_customer_email_action.return_value = self.claim()
        store.validate_customer_email_claim.return_value = False
        provider = Mock()
        worker = CustomerEmailDeliveryWorker(store, provider)
        self.assertTrue(worker.run_once())
        provider.send.assert_not_called()
        store.finish_customer_email_action.assert_called_once_with(
            "sutra-worker-email0001", self.claim()["action_id"], self.claim()["claim_token"],
            "failed", None, "authorization_revoked", 0, True)

    def test_malformed_claim_fails_closed(self):
        store = Mock()
        store.claim_customer_email_action.return_value = {"action_id": "bad"}
        provider = Mock()
        worker = CustomerEmailDeliveryWorker(store, provider)
        with self.assertRaises(IntegrationError):
            worker.run_once()
        provider.send.assert_not_called()


class CustomerEmailRuntimeConfigurationTests(unittest.TestCase):
    def test_delivery_worker_is_disabled_by_default(self):
        from sutra.server import SutraApplication

        app = SutraApplication()
        app.store = Mock()
        with patch.dict("os.environ", {}, clear=True):
            app.start()
        self.assertEqual(app.customer_email_worker_status, "disabled")
        self.assertIsNone(app.customer_email_worker_thread)
        app.close()

    def test_explicit_enablement_without_all_credentials_fails_closed(self):
        from sutra.server import SutraApplication

        app = SutraApplication()
        app.store = Mock()
        with patch.dict("os.environ", {
            "SUTRA_ENABLE_CUSTOMER_EMAIL_WORKER": "true",
            "RESEND_API_KEY": "",
            "SUTRA_CUSTOMER_EMAIL_FROM": "",
            "SUTRA_CUSTOMER_EMAIL_SEND_MODE": "live",
        }, clear=True):
            app.start()
            self.assertEqual(app.customer_email_worker_status, "blocked_runtime_configuration")
            self.assertIsNone(app.customer_email_worker_thread)
            readiness = app.readiness()
        self.assertIn("customer_email_worker", readiness["blockers"])
        app.close()

    def test_worker_starts_only_with_all_explicit_live_settings(self):
        from sutra.server import SutraApplication

        app = SutraApplication()
        app.store = Mock()
        with patch.dict("os.environ", {
            "SUTRA_ENABLE_CUSTOMER_EMAIL_WORKER": "true",
            "RESEND_API_KEY": "unit-test-key",
            "SUTRA_CUSTOMER_EMAIL_FROM": "Sutra <founder@example.test>",
            "SUTRA_CUSTOMER_EMAIL_SEND_MODE": "live",
        }, clear=True), patch("sutra.server.CustomerEmailDeliveryWorker"), \
                patch("sutra.server.ResendEmailProvider"), \
                patch("sutra.server.threading.Thread") as thread_factory:
            app.start()
        self.assertEqual(app.customer_email_worker_status, "running")
        self.assertEqual(thread_factory.call_args.kwargs["name"], "sutra-customer-email-worker")
        app.close()
