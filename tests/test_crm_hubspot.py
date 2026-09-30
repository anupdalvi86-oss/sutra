import json
import unittest
import urllib.error

from sutra.crm_hubspot import HubSpotContactClient


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


if __name__ == "__main__":
    unittest.main()
