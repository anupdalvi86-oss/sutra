"""HTTP liveness endpoint and private integration service for Sutra."""

from __future__ import annotations

import hmac
import json
import logging
import math
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
import urllib.error
import urllib.request
import uuid
from urllib.parse import urlsplit

from .github_dispatch import GitHubIssues, GitHubTaskDispatcher
from .codex_runner import CodexTaskRunner
from .drafts import DraftNotFound, DraftRequestError, DraftService, UserScopedSupabase
from .github_webhook import normalize_github_event, verify_github_signature
from .runtime import (
    FounderCommandRouter,
    IntegrationError,
    SupabaseREST,
    open_outbound_request,
    telegram_call,
    telegram_poll_loop,
)
from .worker import AgentWorker, HermesAgentClient, ROLE_GUIDANCE


def parse_role_routes(raw: str) -> dict[str, tuple[str, str]]:
    """Parse explicit, bounded per-role model routes from trusted deployment config."""
    if not raw.strip():
        return {}
    routes = json.loads(raw)
    if not isinstance(routes, dict) or len(routes) > len(ROLE_GUIDANCE):
        raise ValueError("role routes must be a bounded JSON object")
    parsed: dict[str, tuple[str, str]] = {}
    for role, route in routes.items():
        if role not in ROLE_GUIDANCE or not isinstance(route, dict) or set(route) != {"provider", "model"}:
            raise ValueError("role route has an unsupported role or fields")
        provider, model = route["provider"], route["model"]
        if (not isinstance(provider, str) or not provider.strip() or len(provider) > 80
                or not isinstance(model, str) or not model.strip() or len(model) > 160):
            raise ValueError("role route provider and model must be bounded non-empty strings")
        parsed[role] = (provider.strip(), model.strip())
    return parsed


class GatewayProbe:
    """Probe the separately deployed Hermes service without exposing API credentials."""

    @staticmethod
    def state() -> str:
        url = os.environ.get("HERMES_HEALTH_URL", "")
        parsed = urlsplit(url)
        private_railway_http = parsed.scheme == "http" and bool(parsed.hostname) and parsed.hostname.endswith(".railway.internal")
        if parsed.scheme != "https" and not private_railway_http:
            return "not_configured"
        request = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            with open_outbound_request(request, timeout=1.5) as response:
                if response.status != 200:
                    return "unreachable"
                payload = json.loads(response.read(4096))
            if not isinstance(payload, dict) or payload.get("status") != "ok":
                return "unhealthy"
            return "unhealthy" if payload.get("gateway") == "stopped" else "running"
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            return "unreachable"


class SutraApplication:
    def __init__(self) -> None:
        self.supabase_url = os.environ.get("SUPABASE_URL", "")
        self.supabase_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
        self.store = SupabaseREST(self.supabase_url, self.supabase_key) if self.supabase_url and self.supabase_key else None
        self.founder_id = os.environ.get("TELEGRAM_FOUNDER_USER_ID", "").strip()
        self.telegram_token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
        self.internal_token = os.environ.get("SUTRA_INTERNAL_TOKEN", "")
        self.router: FounderCommandRouter | None = None
        self.founder_verified = False
        self.telegram_stop = threading.Event()
        self.telegram_thread: threading.Thread | None = None
        self.telegram_status = "disabled"
        self.agent_worker_thread: threading.Thread | None = None
        self.agent_worker_status = "disabled"
        self.github_dispatcher_thread: threading.Thread | None = None
        self.github_dispatcher_status = "disabled"
        self.codex_runner_thread: threading.Thread | None = None
        self.codex_runner_status = "disabled"
        self.github_webhook_secret = os.environ.get("GITHUB_WEBHOOK_SECRET", "")
        self.github_repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
        # Keep the synthetic prototype local-only, even if a hosted service is mislabeled.
        draft_supabase = urlsplit(self.supabase_url)
        local_draft_database = (
            draft_supabase.scheme == "http"
            and draft_supabase.hostname in {"127.0.0.1", "localhost", "::1"}
        )
        self.draft_api_enabled = (
            os.environ.get("SUTRA_ENV", "").lower() == "development"
            and os.environ.get("SUTRA_ENABLE_DRAFT_API", "false").lower() == "true"
            and local_draft_database
        )
        self.draft_service: DraftService | None = None
        if self.draft_api_enabled and self.supabase_url and os.environ.get("SUPABASE_ANON_KEY", ""):
            try:
                self.draft_service = DraftService(UserScopedSupabase(
                    self.supabase_url, os.environ["SUPABASE_ANON_KEY"],
                    allow_local_http=True,
                ))
            except ValueError:
                self.draft_service = None

    def start(self) -> None:
        if self.store and self.founder_id:
            try:
                self.store.rpc("sutra_register_founder", {"p_telegram_user_id": self.founder_id})
                self.founder_verified = True
                self.router = FounderCommandRouter(self.store, self.founder_id)
            except IntegrationError:
                self.founder_verified = False
        worker_enabled = os.environ.get("SUTRA_ENABLE_AGENT_WORKER", "false").lower() == "true"
        if worker_enabled:
            provider = os.environ.get("SUTRA_HERMES_PROVIDER", "").strip()
            model = os.environ.get("SUTRA_HERMES_MODEL", "").strip()
            hermes_url = os.environ.get("HERMES_AGENT_API_URL", "").strip()
            hermes_key = os.environ.get("HERMES_AGENT_API_KEY", "").strip()
            try:
                role_routes = parse_role_routes(os.environ.get("SUTRA_HERMES_ROLE_ROUTES", ""))
            except (TypeError, ValueError, json.JSONDecodeError):
                role_routes = {}
                self.agent_worker_status = "blocked_runtime_configuration"
            if not self.store or not provider or not model or not hermes_url or not hermes_key:
                self.agent_worker_status = "blocked_runtime_configuration"
            else:
                profile_routes = {(provider, model), *role_routes.values()}
                for route_provider, route_model in profile_routes:
                    try:
                        profile = self.store.get_agent_model_spend_profile(route_provider, route_model)
                    except IntegrationError:
                        profile = {"configured": False}
                    if (profile.get("configured") is not True
                            or profile.get("provider") != route_provider or profile.get("model") != route_model):
                        self.agent_worker_status = "blocked_model_profile"
                        break
                if self.agent_worker_status not in {"blocked_model_profile", "blocked_runtime_configuration"}:
                    hermes = HermesAgentClient(hermes_url, hermes_key, provider, model)
                    worker = AgentWorker(self.store, hermes, provider, model, role_routes=role_routes)
                    self.agent_worker_thread = threading.Thread(
                        target=worker.run, args=(self.telegram_stop,), daemon=True, name="sutra-agent-worker")
                    self.agent_worker_thread.start()
                    self.agent_worker_status = "running"
        if os.environ.get("SUTRA_ENABLE_GITHUB_DISPATCHER", "false").lower() == "true":
            github_token = os.environ.get("GITHUB_TOKEN", "").strip()
            github_repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
            if (not self.store or not github_token or not github_repository
                    or len(self.github_webhook_secret) < 32):
                self.github_dispatcher_status = "blocked_runtime_configuration"
            else:
                try:
                    issues = GitHubIssues(github_token, github_repository, self.github_webhook_secret)
                    dispatcher = GitHubTaskDispatcher(self.store, issues)
                    self.github_dispatcher_thread = threading.Thread(
                        target=dispatcher.run, args=(self.telegram_stop,), daemon=True,
                        name="sutra-github-task-dispatcher")
                    self.github_dispatcher_thread.start()
                    self.github_dispatcher_status = "running"
                except ValueError:
                    self.github_dispatcher_status = "blocked_runtime_configuration"
        if os.environ.get("SUTRA_ENABLE_CODEX_RUNNER", "false").lower() == "true":
            github_token = os.environ.get("GITHUB_TOKEN", "").strip()
            openai_api_key = os.environ.get("OPENAI_API_KEY", "").strip()
            github_repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
            provider = os.environ.get("SUTRA_CODEX_PROVIDER", "openai").strip()
            model = os.environ.get("SUTRA_CODEX_MODEL", "gpt-6-luna").strip()
            codex_binary = os.environ.get("SUTRA_CODEX_BINARY", "codex").strip()
            if (not self.store or not github_token or not openai_api_key or not github_repository
                    or len(self.github_webhook_secret) < 32):
                self.codex_runner_status = "blocked_runtime_configuration"
            else:
                try:
                    profile = self.store.get_agent_model_spend_profile(provider, model)
                    if (profile.get("configured") is not True or profile.get("provider") != provider
                            or profile.get("model") != model):
                        self.codex_runner_status = "blocked_model_profile"
                    else:
                        issues = GitHubIssues(github_token, github_repository,
                                              self.github_webhook_secret)
                        runner = CodexTaskRunner(self.store, issues, openai_api_key,
                                                 provider, model, codex_binary)
                        self.codex_runner_thread = threading.Thread(
                            target=runner.run, args=(self.telegram_stop,), daemon=True,
                            name="sutra-codex-task-runner")
                        self.codex_runner_thread.start()
                        self.codex_runner_status = "running"
                except (IntegrationError, ValueError, OSError):
                    self.codex_runner_status = "blocked_runtime_configuration"
        if os.environ.get("SUTRA_ENABLE_TELEGRAM", "false").lower() == "true":
            if not self.store or not self.router or not self.telegram_token:
                self.telegram_status = "unconfigured"
            elif not self.founder_verified:
                self.telegram_status = "founder_unverified"
            else:
                try:
                    bot = telegram_call(self.telegram_token, "getMe", {}, timeout=8)
                except IntegrationError:
                    # A transient startup/network error must not permanently disable polling.
                    # getUpdates performs the same token/auth check and retries with backoff.
                    self.telegram_status = "starting"
                    self.telegram_thread = threading.Thread(
                        target=telegram_poll_loop,
                        args=(self.telegram_token, self.router, self.telegram_stop, self._set_telegram_status),
                        daemon=True,
                        name="telegram-founder-interface",
                    )
                    self.telegram_thread.start()
                else:
                    if (not isinstance(bot, dict) or bot.get("is_bot") is not True
                            or isinstance(bot.get("id"), bool) or not isinstance(bot.get("id"), int)):
                        self.telegram_status = "invalid_response"
                    else:
                        self.telegram_status = "starting"
                        self.telegram_thread = threading.Thread(
                            target=telegram_poll_loop,
                            args=(self.telegram_token, self.router, self.telegram_stop, self._set_telegram_status),
                            daemon=True,
                            name="telegram-founder-interface",
                        )
                        self.telegram_thread.start()

    def _set_telegram_status(self, status: str) -> None:
        if status in {"running", "unreachable"}:
            self.telegram_status = status

    def health(self) -> dict[str, Any]:
        database = "unconfigured"
        if self.store:
            try:
                self.store.request("company_settings?select=key&limit=1")
                database = "reachable"
            except IntegrationError:
                database = "unreachable"
        gateway = GatewayProbe.state()
        return {
            "status": "ok" if self.store and database == "reachable" else "degraded",
            "service": "sutra",
            "database": database,
            "telegram": self.telegram_status,
            "hermes_gateway": gateway,
            "agent_worker": self.agent_worker_status,
            "github_dispatcher": self.github_dispatcher_status,
            "codex_runner": self.codex_runner_status,
            "github_webhook": "configured" if self.github_webhook_secret and self.github_repository else "unconfigured",
        }

    def readiness(self) -> dict[str, Any]:
        """Report whether database-backed features enabled for this deployment can run."""
        health = self.health()
        checks = {
            "database": health["database"],
            "telegram": health["telegram"],
            "hermes_gateway": health["hermes_gateway"],
            "agent_worker": health["agent_worker"],
            "github_dispatcher": health["github_dispatcher"],
            "codex_runner": health["codex_runner"],
            "github_webhook": health["github_webhook"],
        }
        blockers = []
        if health["database"] != "reachable":
            blockers.append("database")
        telegram_enabled = os.environ.get("SUTRA_ENABLE_TELEGRAM", "false").lower() == "true"
        worker_enabled = os.environ.get("SUTRA_ENABLE_AGENT_WORKER", "false").lower() == "true"
        dispatcher_enabled = os.environ.get("SUTRA_ENABLE_GITHUB_DISPATCHER", "false").lower() == "true"
        codex_enabled = os.environ.get("SUTRA_ENABLE_CODEX_RUNNER", "false").lower() == "true"
        if telegram_enabled and health["telegram"] != "running":
            blockers.append("telegram")
        if worker_enabled and health["agent_worker"] != "running":
            blockers.append("agent_worker")
        if worker_enabled and health["hermes_gateway"] != "running":
            blockers.append("hermes_gateway")
        if dispatcher_enabled:
            if health["github_dispatcher"] != "running":
                blockers.append("github_dispatcher")
            if health["github_webhook"] != "configured":
                blockers.append("github_webhook")
        if codex_enabled and health["codex_runner"] != "running":
            blockers.append("codex_runner")
        ready = not blockers
        return {
            "status": "ready" if ready else "not_ready",
            "service": "sutra",
            "ready": ready,
            "blockers": blockers,
            "checks": checks,
        }

    def close(self) -> None:
        self.telegram_stop.set()
        if self.agent_worker_thread:
            self.agent_worker_thread.join(timeout=2)
        if self.github_dispatcher_thread:
            self.github_dispatcher_thread.join(timeout=2)
        if self.codex_runner_thread:
            self.codex_runner_thread.join(timeout=2)


class SutraHandler(BaseHTTPRequestHandler):
    server_version = "Sutra/0.1"
    sys_version = ""

    @property
    def app(self) -> SutraApplication:
        return self.server.app  # type: ignore[attr-defined]

    def _json(self, status: int, body: dict[str, Any]) -> None:
        encoded = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        path = urlsplit(self.path).path
        if path.startswith("/v1/drafts/"):
            self._draft_request("GET", path)
            return
        if path == "/health":
            status = self.app.health()
            self._json(200, status)
            return
        if path == "/ready":
            status = self.app.readiness()
            self._json(200 if status["ready"] else 503, status)
            return
        if path == "/":
            self._json(200, {"service": "sutra", "health": "/health"})
            return
        self._json(404, {"error": "not_found"})

    def _read_json(self) -> dict[str, Any]:
        try:
            payload = json.loads(self._read_raw_json())
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ValueError("Request body must be valid JSON") from exc
        if not isinstance(payload, dict):
            raise ValueError("Request body must be a JSON object")
        return payload

    def _read_raw_json(self) -> bytes:
        length = self.headers.get("Content-Length", "")
        if not length.isdigit() or int(length) <= 0 or int(length) > 64_000:
            raise ValueError("Request body size is invalid")
        if self.headers.get_content_type() != "application/json":
            raise ValueError("Content-Type must be application/json")
        raw = self.rfile.read(int(length))
        if len(raw) != int(length):
            raise ValueError("Request body was truncated")
        return raw

    def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
        path = urlsplit(self.path).path
        if path == "/webhooks/github":
            self._github_webhook()
            return
        if path == "/v1/drafts":
            self._draft_request("POST", path)
            return
        if path not in {"/internal/spend", "/internal/role-approval", "/internal/task-update", "/internal/task-review"}:
            self._json(404, {"error": "not_found"})
            return
        token = self.app.internal_token
        authorization = self.headers.get("Authorization", "")
        if not token or not hmac.compare_digest(authorization, f"Bearer {token}"):
            self._json(401, {"error": "unauthorized"})
            return
        if self.app.store is None:
            self._json(503, {"error": "database_unconfigured"})
            return
        try:
            payload = self._read_json()
            if path == "/internal/task-review":
                allowed = {"task_id", "actor_agent_id", "evidence"}
                if set(payload) - allowed or not {"task_id", "actor_agent_id", "evidence"}.issubset(payload):
                    raise ValueError("Malformed task review")
                task_id = str(uuid.UUID(str(payload["task_id"])))
                actor_agent_id = str(uuid.UUID(str(payload["actor_agent_id"])))
                evidence = payload["evidence"]
                if not isinstance(evidence, dict) or len(json.dumps(evidence, allow_nan=False).encode()) > 16_000:
                    raise ValueError("Review evidence must be an object up to 16000 bytes")
                result = self.app.store.rpc("sutra_submit_task_review", {
                    "p_task_id": task_id,
                    "p_actor_agent_id": actor_agent_id,
                    "p_evidence": evidence,
                })
            elif path == "/internal/task-update":
                allowed = {"task_id", "actor_agent_id", "status", "evidence"}
                if set(payload) - allowed or not {"task_id", "actor_agent_id", "status"}.issubset(payload):
                    raise ValueError("Malformed task update")
                task_id = str(uuid.UUID(str(payload["task_id"])))
                actor_agent_id = str(uuid.UUID(str(payload["actor_agent_id"])))
                if payload["status"] not in {"in_progress", "review", "done", "blocked", "ready"}:
                    raise ValueError("Invalid task status")
                evidence = payload.get("evidence", {})
                if not isinstance(evidence, dict) or len(json.dumps(evidence).encode()) > 16_000:
                    raise ValueError("Evidence must be an object up to 16000 bytes")
                result = self.app.store.rpc("sutra_update_task", {
                    "p_task_id": task_id,
                    "p_actor_agent_id": actor_agent_id,
                    "p_status": payload["status"],
                    "p_evidence": evidence,
                })
            elif path == "/internal/role-approval":
                allowed = {"approval_id", "actor_id", "actor_role", "decision", "comment"}
                if set(payload) - allowed or not {"approval_id", "actor_id", "actor_role", "decision"}.issubset(payload):
                    raise ValueError("Malformed approval request")
                approval_id = str(uuid.UUID(str(payload["approval_id"])))
                actor_id = str(uuid.UUID(str(payload["actor_id"])))
                if payload["actor_role"] not in {"ceo", "cfo", "department_head"} or payload["decision"] not in {"approve", "reject"}:
                    raise ValueError("Invalid role or approval decision")
                comment = payload.get("comment", "")
                if not isinstance(comment, str) or len(comment) > 2000:
                    raise ValueError("Comment must be at most 2000 characters")
                result = self.app.store.rpc("sutra_decide_role_approval", {
                    "p_approval_id": approval_id,
                    "p_actor_id": actor_id,
                    "p_actor_role": payload["actor_role"],
                    "p_decision": payload["decision"],
                    "p_comment": comment,
                })
            else:
                allowed = {"actor_id", "project_id", "department_id", "agent_id", "category", "vendor", "description", "amount", "currency"}
                if set(payload) - allowed or not {"actor_id", "agent_id", "category", "description", "amount"}.issubset(payload):
                    raise ValueError("Malformed spend request")
                for key in ("actor_id", "category", "description"):
                    if not isinstance(payload[key], str) or not payload[key].strip() or len(payload[key]) > 1000:
                        raise ValueError(f"{key} must be a nonempty string of at most 1000 characters")
                actor_id = payload["actor_id"]
                if len(actor_id) > 64 or any(char not in "abcdefghijklmnopqrstuvwxyz0123456789_" for char in actor_id):
                    raise ValueError("actor_id must be a valid agent slug")
                agent_id = str(uuid.UUID(str(payload["agent_id"])))
                for key in ("project_id", "department_id"):
                    if key in payload and payload[key] is not None:
                        payload[key] = str(uuid.UUID(str(payload[key])))
                amount = payload["amount"]
                if not isinstance(amount, (int, float)) or isinstance(amount, bool):
                    raise ValueError("Amount must be finite and numeric")
                if amount <= 0 or amount > 999999999999.99 or (isinstance(amount, float) and not math.isfinite(amount)):
                    raise ValueError("Amount must be positive and within the supported EUR range")
                vendor = payload.get("vendor")
                if vendor is not None and (not isinstance(vendor, str) or len(vendor) > 200):
                    raise ValueError("vendor must be at most 200 characters")
                currency = payload.get("currency", "EUR")
                if currency != "EUR":
                    raise ValueError("Only EUR is supported")
                result = self.app.store.rpc("sutra_authorize_spend", {
                    "p_actor_type": "agent",
                    "p_actor_id": actor_id,
                    "p_project_id": payload.get("project_id"),
                    "p_department_id": payload.get("department_id"),
                    "p_agent_id": agent_id,
                    "p_category": payload["category"],
                    "p_vendor": vendor,
                    "p_description": payload["description"],
                    "p_amount": amount,
                    "p_currency": currency,
                })
        except ValueError as exc:
            self._json(400, {"error": "invalid_request", "message": str(exc)})
            return
        except IntegrationError:
            self._json(503, {"error": "policy_service_unavailable"})
            return
        self._json(200, result)

    def do_PATCH(self) -> None:  # noqa: N802 - stdlib handler API
        path = urlsplit(self.path).path
        if path.startswith("/v1/drafts/") and path.endswith("/review"):
            self._draft_request("PATCH", path)
            return
        self._json(404, {"error": "not_found"})

    def do_DELETE(self) -> None:  # noqa: N802 - stdlib handler API
        path = urlsplit(self.path).path
        if path.startswith("/v1/drafts/"):
            self._draft_request("DELETE", path)
            return
        self._json(404, {"error": "not_found"})

    def _draft_request(self, method: str, path: str) -> None:
        if not self.app.draft_api_enabled:
            self._json(404, {"error": "not_found"})
            return
        if self.app.draft_service is None:
            self._json(503, {"error": "draft_api_unconfigured"})
            return
        authorization = self.headers.get("Authorization", "")
        if not authorization.startswith("Bearer "):
            self._json(401, {"error": "unauthorized"})
            return
        access_token = authorization[7:]
        try:
            if method == "POST" and path == "/v1/drafts":
                result = self.app.draft_service.create(access_token, self._read_json())
                self._json(201, result)
                return
            parts = path.strip("/").split("/")
            if len(parts) == 3 and parts[:2] == ["v1", "drafts"] and method == "GET":
                result = self.app.draft_service.get(access_token, parts[2])
                self._json(200, result)
                return
            if len(parts) == 4 and parts[:2] == ["v1", "drafts"] and parts[3] == "review" and method == "PATCH":
                result = self.app.draft_service.review(access_token, parts[2], self._read_json())
                self._json(201, result)
                return
            if len(parts) == 3 and parts[:2] == ["v1", "drafts"] and method == "DELETE":
                self.app.draft_service.delete(access_token, parts[2])
                self.send_response(204)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self._json(404, {"error": "not_found"})
        except (DraftRequestError, ValueError):
            self._json(400, {"error": "invalid_request"})
        except DraftNotFound:
            self._json(404, {"error": "not_found"})
        except IntegrationError:
            self._json(503, {"error": "draft_service_unavailable"})

    def _github_webhook(self) -> None:
        if self.app.store is None or not self.app.github_webhook_secret or not self.app.github_repository:
            self._json(503, {"error": "github_webhook_unconfigured"})
            return
        try:
            raw = self._read_raw_json()
            signature = self.headers.get("X-Hub-Signature-256", "")
            if not verify_github_signature(self.app.github_webhook_secret, raw, signature):
                self._json(401, {"error": "invalid_signature"})
                return
            delivery_id = str(uuid.UUID(self.headers.get("X-GitHub-Delivery", "")))
            event_name = self.headers.get("X-GitHub-Event", "")
            if event_name not in {"pull_request", "workflow_run"}:
                self._json(202, {"accepted": True, "ignored": "event_type"})
                return
            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise ValueError("GitHub event body must be an object")
            normalized = normalize_github_event(event_name, self.app.github_repository, payload)
            if normalized is None:
                self._json(202, {"accepted": True, "ignored": "unmatched_or_unrelated_event"})
                return
            result = self.app.store.rpc("sutra_record_github_webhook_event", {
                "p_worker_id": "sutra-github-webhook-" + uuid.uuid4().hex,
                "p_delivery_id": delivery_id,
                "p_repository": self.app.github_repository,
                "p_event_name": event_name,
                "p_event": normalized,
            })
            self._json(202, result)
        except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
            self._json(400, {"error": "invalid_github_event"})
        except IntegrationError:
            self._json(503, {"error": "github_event_persistence_unavailable"})

    def log_message(self, fmt: str, *args: Any) -> None:
        # Exclude request bodies, credentials, and founder commands from logs.
        sys.stderr.write(f"{self.log_date_time_string()} {self.address_string()} {fmt % args}\n")


def serve() -> None:
    log_level = getattr(logging, os.environ.get("SUTRA_LOG_LEVEL", "INFO").upper(), logging.INFO)
    logging.basicConfig(level=log_level, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    app = SutraApplication()
    app.start()
    # Railway's private health check connects through the container interface.
    host = os.environ.get("SUTRA_BIND_HOST", "0.0.0.0")  # nosec B104
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer((host, port), SutraHandler)
    server.daemon_threads = True
    server.app = app  # type: ignore[attr-defined]
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        app.close()


if __name__ == "__main__":
    serve()
