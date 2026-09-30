import json
import os
import unittest
import urllib.error
from unittest.mock import Mock
from unittest.mock import patch

from sutra.crm_hubspot import HubSpotContactClient, HubSpotContactSyncWorker, HubSpotSyncResult
from sutra.server import SutraApplication


class FakeResponse:
    def __init__(self, body):
        self.body = body
    def __enter__(self):
        return self
    def __exit__(self, *_args):
        return None
    def read(self, _size):
        return self.body


class HubSpotContactClientTests(unittest.TestCase):
    def setUp(self):
        self.request = None
        self.client = HubSpotContactClient("synthetic-private-token", self.open_request)

    def open_request(self, request, timeout):
        self.request = request
        self.timeout = timeout
        return FakeResponse(json.dumps({"status": "COMPLETE", "results": [{"id": "12345"}]}).encode())

    def test_upserts_only_allowlisted_contact_fields_by_email(self):
        result = self.client.upsert_contact({
            "email": "person@example.test", "name": "Riley Example", "company": "Example Co",
        })
        self.assertEqual(result.outcome, "synced")
        self.assertEqual(result.contact_id, "12345")
        self.assertEqual(self.request.full_url, HubSpotContactClient.endpoint)
        self.assertEqual(self.request.get_method(), "POST")
        self.assertEqual(self.request.get_header("Authorization"), "Bearer synthetic-private-token")
        self.assertEqual(json.loads(self.request.data), {"inputs": [{
            "id": "person@example.test", "idProperty": "email",
            "properties": {"email": "person@example.test", "firstname": "Riley",
                           "lastname": "Example", "company": "Example Co"},
        }]})

    def test_invalid_contact_and_extra_pii_fields_fail_before_provider_call(self):
        for contact in (
            {"email": "not-an-email", "name": "Name", "company": None},
            {"email": "Person@example.test", "name": "Name", "company": None},
            {"email": "person@example.test", "name": "Name", "company": None,
             "notes": "unapproved free text"},
        ):
            self.assertEqual(self.client.upsert_contact(contact).error_code, "invalid_contact")
        self.assertIsNone(self.request)

    def test_ambiguous_provider_responses_are_unknown(self):
        self.client._opener = lambda *_args, **_kwargs: FakeResponse(b'{"status":"PROCESSING"}')
        result = self.client.upsert_contact({"email": "a@example.test", "name": "A", "company": None})
        self.assertEqual(result.outcome, "unknown")

    def test_malformed_success_does_not_claim_sync_completion(self):
        self.client._opener = lambda *_args, **_kwargs: FakeResponse(b'{"status":"COMPLETE","results":[]}')
        result = self.client.upsert_contact({"email": "a@example.test", "name": "A", "company": None})
        self.assertEqual(result.outcome, "unknown")
        self.assertEqual(result.error_code, "malformed_provider_response")

    def test_deterministic_rejection_and_ambiguous_http_errors_are_distinguished(self):
        self.client._opener = lambda *_args, **_kwargs: (_ for _ in ()).throw(
            urllib.error.HTTPError("https://api.hubapi.com/", 400, "rejected", {}, None))
        result = self.client.upsert_contact({"email": "a@example.test", "name": "A", "company": None})
        self.assertEqual((result.outcome, result.error_code), ("failed", "provider_rejected"))
        self.client._opener = lambda *_args, **_kwargs: (_ for _ in ()).throw(
            urllib.error.HTTPError("https://api.hubapi.com/", 429, "throttled", {}, None))
        result = self.client.upsert_contact({"email": "a@example.test", "name": "A", "company": None})
        self.assertEqual((result.outcome, result.error_code), ("unknown", "provider_outcome_unknown"))


class HubSpotSyncWorkerTests(unittest.TestCase):
    def setUp(self):
        self.store = Mock()
        self.provider = Mock()
        self.worker = HubSpotContactSyncWorker(self.store, self.provider)
        self.claim = {"status": "claimed", "action_id": "action-1", "claim_token": "claim-1",
                      "ledger_id": "ledger-1", "action": {"email": "a@example.test", "name": "A",
                                                                "company": None}}
        self.store.claim_customer_crm_sync_action.return_value = self.claim

    def test_idle_worker_makes_no_provider_call(self):
        self.store.claim_customer_crm_sync_action.return_value = None
        self.assertFalse(self.worker.run_once())
        self.provider.upsert_contact.assert_not_called()

    def test_rechecks_authorization_before_provider_request(self):
        self.store.validate_customer_crm_sync_claim.return_value = False
        self.assertTrue(self.worker.run_once())
        self.provider.upsert_contact.assert_not_called()
        self.store.finish_customer_crm_sync_action.assert_called_once_with(
            self.worker.worker_id, "action-1", "claim-1", "failed", None,
            "authorization_revoked", 0, True,
        )

    def test_success_settles_actual_cost_and_persists_provider_id(self):
        self.store.validate_customer_crm_sync_claim.return_value = True
        self.provider.upsert_contact.return_value = HubSpotSyncResult("synced", contact_id="hubspot-123")
        self.assertTrue(self.worker.run_once())
        self.provider.upsert_contact.assert_called_once_with(self.claim["action"])
        self.store.finish_customer_crm_sync_action.assert_called_once_with(
            self.worker.worker_id, "action-1", "claim-1", "synced", "hubspot-123", None, 0, True,
        )

    def test_ambiguous_provider_outcome_keeps_unknown_reservation(self):
        self.store.validate_customer_crm_sync_claim.return_value = True
        self.provider.upsert_contact.return_value = HubSpotSyncResult(
            "unknown", error_code="provider_outcome_unknown")
        self.assertTrue(self.worker.run_once())
        self.store.finish_customer_crm_sync_action.assert_called_once_with(
            self.worker.worker_id, "action-1", "claim-1", "unknown", None,
            "provider_outcome_unknown", None, False,
        )


class HubSpotWorkerConfigurationTests(unittest.TestCase):
    def test_worker_and_external_writes_stay_disabled_without_explicit_flag(self):
        app = SutraApplication()
        app.store = Mock()
        with patch.dict(os.environ, {
            "SUTRA_ENABLE_HUBSPOT_SYNC_WORKER": "false",
            "SUTRA_ENABLE_TELEGRAM": "false",
            "SUTRA_ENABLE_AGENT_WORKER": "false",
            "SUTRA_ENABLE_GITHUB_DISPATCHER": "false",
            "SUTRA_ENABLE_CODEX_RUNNER": "false",
            "SUTRA_ENABLE_CODE_RELEASE_WORKER": "false",
            "SUTRA_ENABLE_CUSTOMER_EMAIL_WORKER": "false",
        }, clear=True):
            app.start()
            self.assertEqual(app.hubspot_sync_worker_status, "disabled")
            self.assertIsNone(app.hubspot_sync_worker_thread)
            app.close()


if __name__ == "__main__":
    unittest.main()
