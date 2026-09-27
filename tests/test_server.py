import hashlib
import hmac
import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

from sutra.runtime import IntegrationError
from sutra.server import GatewayProbe, SutraApplication, SutraHandler, parse_role_routes

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

    def get(self, path):
        return urlopen(f"{self.base}{path}", timeout=2)

    def test_model_role_routes_are_validated_and_reject_unknown_fields(self):
        self.assertEqual(parse_role_routes(
            '{"architect":{"provider":"kimi-coding","model":"kimi-k2.6"}}'),
            {"architect": ("kimi-coding", "kimi-k2.6")})
        for malformed in (
            "[]", '{"unknown":{"provider":"openai","model":"gpt-6-luna"}}',
            '{"cpo":{"provider":"openai","model":"gpt-6-luna","key":"secret"}}',
            '{"ceo":{"provider":"","model":"gpt-6-luna"}}',
        ):
            with self.subTest(malformed=malformed), self.assertRaises((ValueError, TypeError)):
                parse_role_routes(malformed)

    def test_hermes_health_probe_allows_private_railway_http(self):
        class Response:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, _limit):
                return b'{"status":"ok"}'

        with patch.dict("os.environ", {"HERMES_HEALTH_URL": "http://sutra.railway.internal:8642/health"}):
            with patch("sutra.server.open_outbound_request", return_value=Response()) as request:
                self.assertEqual(GatewayProbe.state(), "running")
        request.assert_called_once()

    def test_liveness_stays_ok_while_readiness_reports_missing_database(self):
        old_store = self.app.store
        self.addCleanup(setattr, self.app, "store", old_store)
        self.app.store = None
        with patch.dict("os.environ", {
            "SUTRA_ENABLE_TELEGRAM": "false",
            "SUTRA_ENABLE_AGENT_WORKER": "false",
            "SUTRA_ENABLE_GITHUB_DISPATCHER": "false",
        }, clear=False):
            with self.get("/health") as response:
                self.assertEqual(response.status, 200)
            with self.assertRaises(HTTPError) as caught:
                self.get("/ready")
        self.assertEqual(caught.exception.code, 503)
        body = json.loads(caught.exception.read())
        self.assertFalse(body["ready"])
        self.assertIn("database", body["blockers"])

    def test_readiness_passes_when_database_is_reachable_and_integrations_are_disabled(self):
        old_store = self.app.store
        self.addCleanup(setattr, self.app, "store", old_store)
        self.app.store = FakeStore()
        with patch.dict("os.environ", {
            "SUTRA_ENABLE_TELEGRAM": "false",
            "SUTRA_ENABLE_AGENT_WORKER": "false",
            "SUTRA_ENABLE_GITHUB_DISPATCHER": "false",
        }, clear=False):
            with self.get("/ready") as response:
                body = json.loads(response.read())
        self.assertEqual(response.status, 200)
        self.assertTrue(body["ready"])
        self.assertEqual(body["blockers"], [])
        self.assertEqual(body["checks"]["database"], "reachable")

    def test_readiness_blocks_an_enabled_telegram_integration_until_it_is_running(self):
        old_store, old_status = self.app.store, self.app.telegram_status
        self.addCleanup(setattr, self.app, "store", old_store)
        self.addCleanup(setattr, self.app, "telegram_status", old_status)
        self.app.store = FakeStore()
        self.app.telegram_status = "unconfigured"
        with patch.dict("os.environ", {
            "SUTRA_ENABLE_TELEGRAM": "true",
            "SUTRA_ENABLE_AGENT_WORKER": "false",
            "SUTRA_ENABLE_GITHUB_DISPATCHER": "false",
        }, clear=False):
            with self.assertRaises(HTTPError) as caught:
                self.get("/ready")
        self.assertEqual(caught.exception.code, 503)
        body = json.loads(caught.exception.read())
        self.assertEqual(body["blockers"], ["telegram"])

    def test_internal_spend_requires_server_token(self):
        before = len(self.app.store.calls)
        with self.assertRaises(HTTPError) as caught:
            self.post({"actor_id": "developer", "category": "ai_api", "description": "test", "amount": 2})
        self.assertEqual(caught.exception.code, 401)
        self.assertEqual(len(self.app.store.calls), before)

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

    def test_task_review_routes_bounded_evidence_to_database_gate(self):
        payload = {
            "task_id": "00000000-0000-4000-8000-000000000005",
            "actor_agent_id": AGENT_ID,
            "evidence": {"result": "pass", "summary": "Review evidence ready"},
        }
        request = Request(f"{self.base}/internal/task-review", data=json.dumps(payload).encode(),
                          headers={"Content-Type": "application/json", "Authorization": "Bearer unit-test-only-token"}, method="POST")
        with urlopen(request, timeout=2) as response:
            self.assertEqual(response.status, 200)
        name, rpc_payload = self.app.store.calls[-1]
        self.assertEqual(name, "sutra_submit_task_review")
        self.assertEqual(rpc_payload["p_task_id"], payload["task_id"])
        self.assertEqual(rpc_payload["p_evidence"]["result"], "pass")

        before = len(self.app.store.calls)
        malformed = Request(f"{self.base}/internal/task-review", data=json.dumps({**payload, "unexpected": True}).encode(),
                             headers={"Content-Type": "application/json", "Authorization": "Bearer unit-test-only-token"}, method="POST")
        with self.assertRaises(HTTPError) as caught:
            urlopen(malformed, timeout=2)
        self.assertEqual(caught.exception.code, 400)
        self.assertEqual(len(self.app.store.calls), before)

    def test_github_webhook_requires_signature_and_persists_normalized_event(self):
        secret = "unit-test-webhook-secret"
        old_secret, old_repo = self.app.github_webhook_secret, self.app.github_repository
        self.app.github_webhook_secret = secret
        self.app.github_repository = "acme/sutra"
        self.addCleanup(setattr, self.app, "github_webhook_secret", old_secret)
        self.addCleanup(setattr, self.app, "github_repository", old_repo)
        task_id = "01942c8a-68b1-7c29-bf9b-63f02e97359e"
        payload = {
            "action": "closed",
            "repository": {"full_name": "acme/sutra"},
            "pull_request": {
                "number": 88,
                "html_url": "https://github.com/acme/sutra/pull/88",
                "body": f"Sutra-Task-ID: {task_id}\nCloses #41",
                "merged": True,
                "head": {"sha": "a" * 40},
                "base": {"ref": "main"},
            },
        }
        body = json.dumps(payload).encode()
        signature = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
        before = len(self.app.store.calls)
        request = Request(f"{self.base}/webhooks/github", data=body, headers={
            "Content-Type": "application/json", "X-Hub-Signature-256": signature,
            "X-GitHub-Delivery": "01942c8a-68b1-7c29-bf9b-63f02e973590", "X-GitHub-Event": "pull_request",
        }, method="POST")
        with urlopen(request, timeout=2) as response:
            self.assertEqual(response.status, 202)
        name, rpc_payload = self.app.store.calls[-1]
        self.assertEqual(len(self.app.store.calls), before + 1)
        self.assertEqual(name, "sutra_record_github_webhook_event")
        self.assertEqual(rpc_payload["p_event"]["task_id"], task_id)
        self.assertEqual(rpc_payload["p_event"]["issue_number"], 41)

        bad_request = Request(f"{self.base}/webhooks/github", data=body, headers={
            "Content-Type": "application/json", "X-Hub-Signature-256": "sha256=" + "0" * 64,
            "X-GitHub-Delivery": "01942c8a-68b1-7c29-bf9b-63f02e973590", "X-GitHub-Event": "pull_request",
        }, method="POST")
        with self.assertRaises(HTTPError) as caught:
            urlopen(bad_request, timeout=2)
        self.assertEqual(caught.exception.code, 401)
        self.assertEqual(len(self.app.store.calls), before + 1)

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

    def test_telegram_health_checks_the_bot_token_before_starting_polling(self):
        class IdleThread:
            def __init__(self, **kwargs):
                self.kwargs = kwargs
                self.started = False

            def start(self):
                self.started = True

        threads = []

        def make_thread(**kwargs):
            thread = IdleThread(**kwargs)
            threads.append(thread)
            return thread

        env = {
            "SUTRA_ENABLE_TELEGRAM": "true",
            "SUTRA_ENABLE_AGENT_WORKER": "false",
            "SUTRA_ENABLE_GITHUB_DISPATCHER": "false",
            "TELEGRAM_BOT_TOKEN": "unit-test-token",
            "TELEGRAM_FOUNDER_USER_ID": "123456789",
        }
        with patch.dict("os.environ", env, clear=False), \
                patch("sutra.server.telegram_call", return_value={"id": 123, "is_bot": True}), \
                patch("sutra.server.threading.Thread", side_effect=make_thread):
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
            self.assertEqual(app.telegram_status, "starting")
            self.assertEqual(app.health()["telegram"], "starting")
            self.assertTrue(threads[0].started)
            app._set_telegram_status("running")
            self.assertEqual(app.health()["telegram"], "running")
            app.close()

    def test_telegram_health_retries_after_transient_startup_failure(self):
        env = {
            "SUTRA_ENABLE_TELEGRAM": "true",
            "SUTRA_ENABLE_AGENT_WORKER": "false",
            "SUTRA_ENABLE_GITHUB_DISPATCHER": "false",
            "TELEGRAM_BOT_TOKEN": "unit-test-token",
            "TELEGRAM_FOUNDER_USER_ID": "123456789",
        }
        with patch.dict("os.environ", env, clear=False), \
                patch("sutra.server.telegram_call", side_effect=IntegrationError("unauthorized")), \
                patch("sutra.server.threading.Thread") as thread_type:
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
            self.assertEqual(app.health()["telegram"], "starting")
            thread_type.assert_called_once()
            thread_type.return_value.start.assert_called_once()

        with patch.dict("os.environ", env, clear=False), \
                patch("sutra.server.telegram_call", return_value={"ok": True}), \
                patch("sutra.server.threading.Thread") as thread_type:
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
            self.assertEqual(app.telegram_status, "invalid_response")
            thread_type.assert_not_called()

    def test_telegram_enabled_without_required_secrets_reports_unconfigured(self):
        env = {
            "SUTRA_ENABLE_TELEGRAM": "true",
            "SUTRA_ENABLE_AGENT_WORKER": "false",
            "SUTRA_ENABLE_GITHUB_DISPATCHER": "false",
            "TELEGRAM_BOT_TOKEN": "",
            "TELEGRAM_FOUNDER_USER_ID": "123456789",
        }
        with patch.dict("os.environ", env, clear=False), patch("sutra.server.telegram_call") as telegram_call:
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
        self.assertEqual(app.health()["telegram"], "unconfigured")
        telegram_call.assert_not_called()

    def test_github_dispatcher_is_opt_in_and_fails_closed_without_repo_token(self):
        with patch.dict("os.environ", {
            "SUTRA_ENABLE_GITHUB_DISPATCHER": "true",
            "GITHUB_TOKEN": "",
            "GITHUB_REPOSITORY": "",
            "GITHUB_WEBHOOK_SECRET": "",
        }, clear=False):
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
        self.assertEqual(app.github_dispatcher_status, "blocked_runtime_configuration")
        self.assertIsNone(app.github_dispatcher_thread)

    def test_github_dispatcher_requires_task_signing_secret(self):
        env = {
            "SUTRA_ENABLE_GITHUB_DISPATCHER": "true",
            "GITHUB_TOKEN": "unit-test-token",
            "GITHUB_REPOSITORY": "acme/sutra",
            "GITHUB_WEBHOOK_SECRET": "too-short",
        }
        with patch.dict("os.environ", env, clear=False):
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
            "GITHUB_WEBHOOK_SECRET": "test-only-github-webhook-secret-long-enough",
        }
        with patch.dict("os.environ", env, clear=False), patch("sutra.server.GitHubTaskDispatcher", IdleDispatcher):
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
            self.assertEqual(app.github_dispatcher_status, "running")
            self.assertIsNotNone(app.github_dispatcher_thread)
            self.assertEqual(app.health()["github_dispatcher"], "running")
            app.close()

    def test_codex_runner_is_opt_in_and_blocks_without_secrets(self):
        with patch.dict("os.environ", {
            "SUTRA_ENABLE_CODEX_RUNNER": "true",
            "GITHUB_TOKEN": "",
            "OPENAI_API_KEY": "",
            "GITHUB_REPOSITORY": "acme/sutra",
            "GITHUB_WEBHOOK_SECRET": "test-only-github-webhook-secret-long-enough",
        }, clear=False):
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
        self.assertEqual(app.codex_runner_status, "blocked_runtime_configuration")
        self.assertIsNone(app.codex_runner_thread)
        self.assertIn("codex_runner", app.readiness()["checks"])

    def test_codex_runner_requires_active_database_model_price_profile(self):
        env = {
            "SUTRA_ENABLE_CODEX_RUNNER": "true",
            "GITHUB_TOKEN": "unit-test-token",
            "OPENAI_API_KEY": "unit-test-key",
            "GITHUB_REPOSITORY": "acme/sutra",
            "GITHUB_WEBHOOK_SECRET": "test-only-github-webhook-secret-long-enough",
        }
        with patch.dict("os.environ", env, clear=False):
            app = SutraApplication()
            app.store = FakeStore()
            app.start()
        self.assertEqual(app.codex_runner_status, "blocked_model_profile")
        self.assertIsNone(app.codex_runner_thread)


if __name__ == "__main__":
    unittest.main()
