import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from unittest.mock import patch

from sutra.drafts import (
    DraftRequestError, DraftService, UserScopedSupabase, _LoopbackOnlyRedirect,
    generate_synthetic_draft,
)
from sutra.server import SutraApplication, SutraHandler


OWNER_ID = "00000000-0000-4000-8000-000000000111"
DRAFT_ID = "00000000-0000-4000-8000-000000000222"


class FakeDraftStore:
    def __init__(self):
        self.calls = []

    def authenticate(self, token):
        self.calls.append(("authenticate", token))
        if token != "user-jwt":
            raise DraftRequestError("bad token")
        return OWNER_ID

    def create(self, token, owner_id, payload):
        self.calls.append(("create", token, owner_id, payload))
        return {"id": DRAFT_ID, **payload, "owner_id": owner_id, "tenant_id": owner_id}

    def get(self, token, draft_id):
        self.calls.append(("get", token, draft_id))
        if draft_id != DRAFT_ID:
            raise LookupError
        return {"id": DRAFT_ID, "test_draft": {"executable": False}}

    def review(self, token, owner_id, draft_id, payload):
        self.calls.append(("review", token, owner_id, draft_id, payload))
        return {"id": "review-id", **payload}

    def delete(self, token, draft_id):
        self.calls.append(("delete", token, draft_id))
        if draft_id != DRAFT_ID:
            from sutra.drafts import DraftNotFound
            raise DraftNotFound
        return {"id": draft_id, "deleted": True}


class SyntheticDraftTests(unittest.TestCase):
    def test_generator_returns_only_inert_manual_steps_and_rationale(self):
        result = generate_synthetic_draft({
            "scenario": "A member signs in. The dashboard shows their saved items.",
            "context": "Synthetic account only",
        })
        self.assertFalse(result["draft"]["executable"])
        self.assertEqual(result["draft"]["verification"], "unverified")
        self.assertEqual(len(result["draft"]["steps"]), 2)
        self.assertEqual(len(result["rationale"]), 2)
        self.assertTrue(any("Synthetic" in warning for warning in result["warnings"]))
        self.assertTrue(all(set(step) == {"id", "instruction", "expected_observation"}
                            for step in result["draft"]["steps"]))

    def test_generator_rejects_unknown_fields_unsupported_inputs_and_oversized_steps(self):
        for payload in (
            {"scenario": "A long enough scenario", "execute": True},
            {"scenario": "A long enough scenario", "framework": "selenium"},
            {"scenario": "A" * 600},
            {"scenario": "A long enough scenario", "context": "x" * 16_001},
            {"scenario": "A long enough scenario", "language": "ruby"},
            {"scenario": "A long enough scenario", "language": []},
        ):
            with self.subTest(payload=list(payload)), self.assertRaises(DraftRequestError):
                generate_synthetic_draft(payload)

    def test_review_requires_inert_manual_plan_shape(self):
        service = DraftService(FakeDraftStore())
        with self.assertRaises(DraftRequestError):
            service.review("user-jwt", DRAFT_ID, {"decision": "edit", "edited_draft": {"code": "run()"}})
        with self.assertRaises(DraftRequestError):
            service.review("user-jwt", DRAFT_ID, {"decision": []})

    def test_user_scoped_client_requires_https_and_a_key(self):
        for url, key in (("http://db.example", "anon"), ("http://127.0.0.1:54321", "anon"),
                         ("https://db.example", "")):
            with self.subTest(url=url), self.assertRaises(ValueError):
                UserScopedSupabase(url, key)
        self.assertTrue(UserScopedSupabase(
            "http://127.0.0.1:54321", "anon", allow_local_http=True,
        ).local_http)

    def test_local_supabase_redirect_cannot_leave_loopback(self):
        handler = _LoopbackOnlyRedirect()
        with self.assertRaises(URLError):
            handler.redirect_request(
                Request("http://127.0.0.1:54321/auth/v1/user"), None, 302, "Found", {},
                "https://example.com/steal-token",
            )

    def test_user_scoped_auth_uses_anon_key_and_callers_access_token(self):
        store = UserScopedSupabase("https://project.supabase.co", "publishable-key")
        requests = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, _limit):
                return json.dumps({"id": OWNER_ID}).encode()

        def open_request(request, timeout):
            requests.append((request, timeout))
            return Response()

        with patch("sutra.drafts.open_outbound_request", side_effect=open_request):
            self.assertEqual(store.authenticate("user-jwt"), OWNER_ID)
        request, timeout = requests[0]
        self.assertEqual(request.full_url, "https://project.supabase.co/auth/v1/user")
        self.assertEqual(request.get_header("Authorization"), "Bearer user-jwt")
        self.assertEqual(request.get_header("Apikey"), "publishable-key")
        self.assertEqual(timeout, 8.0)

    def test_create_and_review_use_authenticated_owner_and_append_review(self):
        store = FakeDraftStore()
        service = DraftService(store)
        created = service.create("user-jwt", {"scenario": "User saves an item."})
        self.assertEqual(created["id"], DRAFT_ID)
        create_call = next(call for call in store.calls if call[0] == "create")
        self.assertEqual(create_call[2], OWNER_ID)
        review = service.review("user-jwt", DRAFT_ID, {"decision": "accept", "comment": "Reviewed"})
        self.assertEqual(review["decision"], "accept")
        self.assertEqual(store.calls[-1][0], "review")

    def test_owner_can_delete_draft_and_invalid_ids_are_rejected(self):
        store = FakeDraftStore()
        service = DraftService(store)
        self.assertEqual(service.delete("user-jwt", DRAFT_ID), {"id": DRAFT_ID, "deleted": True})
        self.assertEqual(store.calls[-1], ("delete", "user-jwt", DRAFT_ID))
        with self.assertRaises(DraftRequestError):
            service.delete("user-jwt", "not-a-uuid")


class DraftEndpointTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = SutraApplication()
        cls.app.draft_api_enabled = True
        cls.app.draft_service = DraftService(FakeDraftStore())
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), SutraHandler)
        cls.server.app = cls.app
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def request(self, method, path, payload=None, token=None):
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        body = json.dumps(payload).encode() if payload is not None else None
        request = Request(f"{self.base}{path}", data=body, headers=headers, method=method)
        return urlopen(request, timeout=2)

    def test_create_requires_authentication_and_valid_payload(self):
        with self.assertRaises(HTTPError) as caught:
            self.request("POST", "/v1/drafts", {"scenario": "User saves an item."})
        self.assertEqual(caught.exception.code, 401)
        with self.assertRaises(HTTPError) as caught:
            self.request("POST", "/v1/drafts", {"scenario": "User saves an item.", "code": "bad"}, "user-jwt")
        self.assertEqual(caught.exception.code, 400)
        with self.request("POST", "/v1/drafts", {"scenario": "User saves an item."}, "user-jwt") as response:
            self.assertEqual(response.status, 201)

    def test_read_and_review_are_user_authenticated_and_review_is_append_only(self):
        with self.assertRaises(HTTPError) as caught:
            self.request("GET", f"/v1/drafts/{DRAFT_ID}")
        self.assertEqual(caught.exception.code, 401)
        with self.request("GET", f"/v1/drafts/{DRAFT_ID}", token="user-jwt") as response:
            self.assertEqual(json.loads(response.read())["id"], DRAFT_ID)
        with self.request("PATCH", f"/v1/drafts/{DRAFT_ID}/review", {"decision": "reject"}, "user-jwt") as response:
            self.assertEqual(response.status, 201)

    def test_delete_requires_authentication_and_returns_no_content(self):
        with self.assertRaises(HTTPError) as caught:
            self.request("DELETE", f"/v1/drafts/{DRAFT_ID}")
        self.assertEqual(caught.exception.code, 401)
        with self.request("DELETE", f"/v1/drafts/{DRAFT_ID}", token="user-jwt") as response:
            self.assertEqual(response.status, 204)

    def test_disabled_feature_is_not_exposed(self):
        self.app.draft_api_enabled = False
        try:
            with self.assertRaises(HTTPError) as caught:
                self.request("POST", "/v1/drafts", {"scenario": "User saves an item."}, "user-jwt")
            self.assertEqual(caught.exception.code, 404)
        finally:
            self.app.draft_api_enabled = True

    def test_feature_flag_is_fail_closed_outside_explicit_development(self):
        for environment in (None, "production", "test"):
            values = {"SUTRA_ENABLE_DRAFT_API": "true"}
            if environment is not None:
                values["SUTRA_ENV"] = environment
            with self.subTest(environment=environment), patch.dict("os.environ", values, clear=True):
                app = SutraApplication()
                self.assertFalse(app.draft_api_enabled)
        local_values = {
            "SUTRA_ENV": "development", "SUTRA_ENABLE_DRAFT_API": "true",
            "SUPABASE_URL": "http://127.0.0.1:54321", "SUPABASE_ANON_KEY": "local-anon",
        }
        with patch.dict("os.environ", local_values, clear=True):
            self.assertTrue(SutraApplication().draft_api_enabled)
        with patch.dict("os.environ", {
            **local_values, "SUPABASE_URL": "https://production.supabase.co",
        }, clear=True):
            self.assertFalse(SutraApplication().draft_api_enabled)


if __name__ == "__main__":
    unittest.main()
