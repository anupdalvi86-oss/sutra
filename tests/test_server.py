import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

from sutra.runtime import IntegrationError
from sutra.server import SutraApplication, SutraHandler

AGENT_ID = "00000000-0000-4000-8000-000000000002"


class FakeStore:
    def __init__(self):
        self.calls = []

    def rpc(self, name, payload):
        self.calls.append((name, payload))
        return {"status": "requested", "expense_id": "expense-1", "required_approvers": ["founder"]}

    def request(self, *_args, **_kwargs):
        return []

    def get_agent_model_spend_profile(self, *_args):
        return {"configured": False}


class InternalEndpointTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = SutraApplication()
        cls.app.store = FakeStore()
        cls.app.internal_token = "unit-test-only-token"
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), SutraHandler)
        cls.server.app = cls.app
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def post(self, payload, token=None, content_type="application/json"):
        headers = {"Content-Type": content_type}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        request = Request(f"{self.base}/internal/spend", data=payload if isinstance(payload, bytes) else json.dumps(payload).encode(), headers=headers, method="POST")
        return urlopen(request, timeout=2)

    def test_internal_spend_requires_server_token(self):
        with self.assertRaises(HTTPError) as caught:
            self.post({"actor_id": "developer", "category": "ai_api", "description": "test", "amount": 2})
        self.assertEqual(caught.exception.code, 401)
        self.assertEqual(self.app.store.calls, [])

    def test_internal_spend_uses_central_policy_rpc(self):
        with self.post({"actor_id": "developer", "agent_id": AGENT_ID, "category": "ai_api", "description": "test", "amount": 2}, "unit-test-only-token") as response:
            body = json.loads(response.read())
        self.assertEqual(body["status"], "requested")
        name, payload = self.app.store.calls[-1]
        self.assertEqual(name, "sutra_authorize_spend")
        self.assertEqual(payload["p_actor_type"], "agent")
        self.assertEqual(payload["p_amount"], 2)

    def test_malformed_and_oversized_fields_fail_closed(self):
        with self.assertRaises(HTTPError) as caught:
            self.post({"actor_id": "developer", "category": "ai_api", "description": "test", "amount": True}, "unit-test-only-token")
        self.assertEqual(caught.exception.code, 400)
        with self.assertRaises(HTTPError) as caught:
            self.post({"actor_id": "developer", "agent_id": AGENT_ID, "category": "ai_api", "description": "test", "amount": float("nan")}, "unit-test-only-token")
        self.assertEqual(caught.exception.code, 400)
        with self.assertRaises(HTTPError) as caught:
            self.post({"actor_id": "developer", "agent_id": AGENT_ID, "category": "ai_api", "description": "test", "amount": 10**1000}, "unit-test-only-token")
        self.assertEqual(caught.exception.code, 400)
        with self.assertRaises(HTTPError) as caught:
            self.post({"actor_id": "developer", "agent_id": "not-a-uuid", "category": "ai_api", "description": "test", "amount": 3}, "unit-test-only-token")
        self.assertEqual(caught.exception.code, 400)
        with self.assertRaises(HTTPError) as caught:
            self.post({"actor_id": "developer", "category": "ai_api", "description": "test", "amount": 3, "approved": True}, "unit-test-only-token")
        self.assertEqual(caught.exception.code, 400)

    def test_role_approval_is_shape_checked_before_database_rpc(self):
        payload = {
            "approval_id": "00000000-0000-4000-8000-000000000003",
            "actor_id": AGENT_ID,
            "actor_role": "cfo",
            "decision": "approve",
            "comment": "Budget checked",
        }
        request = Request(f"{self.base}/internal/role-approval", data=json.dumps(payload).encode(),
                          headers={"Content-Type": "application/json", "Authorization": "Bearer unit-test-only-token"}, method="POST")
        with urlopen(request, timeout=2) as response:
            self.assertEqual(response.status, 200)
        name, rpc_payload = self.app.store.calls[-1]
        self.assertEqual(name, "sutra_decide_role_approval")
        self.assertEqual(rpc_payload["p_actor_role"], "cfo")
        with self.assertRaises(HTTPError) as caught:
            self.post(b"{malformed", "unit-test-only-token")
        self.assertEqual(caught.exception.code, 400)

    def test_task_update_calls_authorized_task_rpc(self):
        payload = {
            "task_id": "00000000-0000-4000-8000-000000000004",
            "actor_agent_id": AGENT_ID,
            "status": "done",
            "evidence": {"tests": "passed"},
        }
        request = Request(f"{self.base}/internal/task-update", data=json.dumps(payload).encode(),
                          headers={"Content-Type": "application/json", "Authorization": "Bearer unit-test-only-token"}, method="POST")
        with urlopen(request, timeout=2) as response:
            self.assertEqual(response.status, 200)
        name, rpc_payload = self.app.store.calls[-1]
        self.assertEqual(name, "sutra_update_task")
        self.assertEqual(rpc_payload["p_actor_agent_id"], AGENT_ID)

    def test_agent_worker_cannot_start_without_database_route_or_credential(self):
        with patch.dict("os.environ", {"SUTRA_ENABLE_AGENT_WORKER": "true"}, clear=False):
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
        self.assertEqual(app.agent_worker_status, "blocked_runtime_configuration")
        self.assertIsNone(app.agent_worker_thread)

    def test_agent_worker_stays_disabled_until_database_has_an_active_price_profile(self):
        env = {
            "SUTRA_ENABLE_AGENT_WORKER": "true",
            "SUTRA_HERMES_PROVIDER": "openai",
            "SUTRA_HERMES_MODEL": "gpt-4o-mini",
            "HERMES_AGENT_API_URL": "https://hermes.example",
            "HERMES_AGENT_API_KEY": "unit-test-key",
        }
        with patch.dict("os.environ", env, clear=False):
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
        self.assertEqual(app.agent_worker_status, "blocked_model_profile")
        self.assertIsNone(app.agent_worker_thread)

    def test_github_dispatcher_is_opt_in_and_fails_closed_without_repo_token(self):
        with patch.dict("os.environ", {"SUTRA_ENABLE_GITHUB_DISPATCHER": "true", "GITHUB_TOKEN": "", "GITHUB_REPOSITORY": ""}, clear=False):
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
        self.assertEqual(app.github_dispatcher_status, "blocked_runtime_configuration")
        self.assertIsNone(app.github_dispatcher_thread)

    def test_github_dispatcher_starts_only_with_explicit_configuration(self):
        class IdleDispatcher:
            def __init__(self, store, issues):
                self.store = store
                self.issues = issues

            def run(self, stop):
                stop.wait(0.01)

        env = {
            "SUTRA_ENABLE_GITHUB_DISPATCHER": "true",
            "GITHUB_TOKEN": "unit-test-token",
            "GITHUB_REPOSITORY": "acme/sutra",
        }
        with patch.dict("os.environ", env, clear=False), patch("sutra.server.GitHubTaskDispatcher", IdleDispatcher):
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
            self.assertEqual(app.github_dispatcher_status, "running")
            self.assertIsNotNone(app.github_dispatcher_thread)
            self.assertEqual(app.health()["github_dispatcher"], "running")
            app.close()


if __name__ == "__main__":
    unittest.main()
