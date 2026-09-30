"""HTTP liveness endpoint and private integration service for Sutra."""

from __future__ import annotations

import hmac
import json
import logging
import math
import os
import re
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
from .code_release import CodeReleaseWorker
from .customer_email import CustomerEmailDeliveryWorker, ResendEmailProvider
from .crm_hubspot import HubSpotContactClient, HubSpotContactSyncWorker
from .customer_support import normalize_zendesk_ticket_event, verify_zendesk_signature
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


def parse_agent_worker_concurrency(raw: str) -> int:
    """Limit parallel Hermes jobs to the two audited database worker slots."""
    value = raw.strip()
    if value not in {"1", "2"}:
        raise ValueError("agent worker concurrency must be 1 or 2")
    return int(value)


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
        self.agent_worker_threads: list[threading.Thread] = []
        self.agent_worker_status = "disabled"
        self.github_dispatcher_thread: threading.Thread | None = None
        self.github_dispatcher_status = "disabled"
        self.codex_runner_thread: threading.Thread | None = None
        self.codex_runner_status = "disabled"
        self.code_release_thread: threading.Thread | None = None
        self.code_release_status = "disabled"
        self.customer_email_worker_thread: threading.Thread | None = None
        self.customer_email_worker_status = "disabled"
        self.hubspot_sync_worker_thread: threading.Thread | None = None
        self.hubspot_sync_worker_status = "disabled"
        self.hubspot_private_app_token = os.environ.get("HUBSPOT_PRIVATE_APP_TOKEN", "").strip()
        self.github_webhook_secret = os.environ.get("GITHUB_WEBHOOK_SECRET", "")
        self.github_repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
        self.zendesk_webhook_secret = os.environ.get("ZENDESK_WEBHOOK_SECRET", "")
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
                worker_concurrency = parse_agent_worker_concurrency(
                    os.environ.get("SUTRA_AGENT_WORKER_CONCURRENCY", "1"))
            except (TypeError, ValueError, json.JSONDecodeError):
                role_routes = {}
                worker_concurrency = 0
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
                    for slot in range(worker_concurrency):
                        # Each worker owns its own Hermes client because usage
                        # diagnostics are request-local mutable state.
                        hermes = HermesAgentClient(hermes_url, hermes_key, provider, model)
                        worker = AgentWorker(self.store, hermes, provider, model, role_routes=role_routes)
                        thread = threading.Thread(
                            target=worker.run, args=(self.telegram_stop,), daemon=True,
                            name=f"sutra-agent-worker-{slot + 1}")
                        thread.start()
                        self.agent_worker_threads.append(thread)
                    self.agent_worker_thread = self.agent_worker_threads[0]
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
        if os.environ.get("SUTRA_ENABLE_CODE_RELEASE_WORKER", "false").lower() == "true":
            github_token = os.environ.get("GITHUB_TOKEN", "").strip()
            github_repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
            if (not self.store or not github_token
                    or github_repository != "anupdalvi86-oss/sutra"
                    or len(self.github_webhook_secret) < 32):
                self.code_release_status = "blocked_runtime_configuration"
            else:
                try:
                    issues = GitHubIssues(github_token, github_repository,
                                          self.github_webhook_secret)
                    worker = CodeReleaseWorker(self.store, issues)
                    self.code_release_thread = threading.Thread(
                        target=worker.run, args=(self.telegram_stop,), daemon=True,
                        name="sutra-code-release-worker")
                    self.code_release_thread.start()
                    self.code_release_status = "running"
                except ValueError:
                    self.code_release_status = "blocked_runtime_configuration"
        if os.environ.get("SUTRA_ENABLE_CUSTOMER_EMAIL_WORKER", "false").lower() == "true":
            api_key = os.environ.get("RESEND_API_KEY", "").strip()
            from_address = os.environ.get("SUTRA_CUSTOMER_EMAIL_FROM", "").strip()
            send_mode = os.environ.get("SUTRA_CUSTOMER_EMAIL_SEND_MODE", "disabled").strip().lower()
            if not self.store or not api_key or not from_address or send_mode != "live":
                self.customer_email_worker_status = "blocked_runtime_configuration"
            else:
                try:
                    provider = ResendEmailProvider(api_key, from_address)
                    worker_id = "sutra-worker-email" + uuid.uuid4().hex[:12]
                    worker = CustomerEmailDeliveryWorker(self.store, provider, worker_id)
                    self.customer_email_worker_thread = threading.Thread(
                        target=worker.run, args=(self.telegram_stop,), daemon=True,
                        name="sutra-customer-email-worker")
                    self.customer_email_worker_thread.start()
                    self.customer_email_worker_status = "running"
                except ValueError:
                    self.customer_email_worker_status = "blocked_runtime_configuration"
        if os.environ.get("SUTRA_ENABLE_HUBSPOT_SYNC_WORKER", "false").lower() == "true":
            if not self.store or not self.hubspot_private_app_token:
                self.hubspot_sync_worker_status = "blocked_runtime_configuration"
            else:
                try:
                    provider = HubSpotContactClient(self.hubspot_private_app_token)
                    worker_id = "sutra-worker-hubspot" + uuid.uuid4().hex[:12]
                    worker = HubSpotContactSyncWorker(self.store, provider, worker_id)
                    self.hubspot_sync_worker_thread = threading.Thread(
                        target=worker.run, args=(self.telegram_stop,), daemon=True,
                        name="sutra-hubspot-contact-sync-worker")
                    self.hubspot_sync_worker_thread.start()
                    self.hubspot_sync_worker_status = "running"
                except ValueError:
                    self.hubspot_sync_worker_status = "blocked_runtime_configuration"
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
        zendesk_enabled = os.environ.get("SUTRA_ENABLE_ZENDESK_WEBHOOK", "false").lower() == "true"
        zendesk_state = (
            "configured" if zendesk_enabled and self.zendesk_webhook_secret
            else "blocked_runtime_configuration" if zendesk_enabled
            else "disabled"
        )
        return {
            "status": "ok" if self.store and database == "reachable" else "degraded",
            "service": "sutra",
            "database": database,
            "telegram": self.telegram_status,
            "hermes_gateway": gateway,
            "agent_worker": self.agent_worker_status,
            "github_dispatcher": self.github_dispatcher_status,
            "codex_runner": self.codex_runner_status,
            "code_release_worker": self.code_release_status,
            "customer_email_worker": self.customer_email_worker_status,
            "hubspot_sync_worker": self.hubspot_sync_worker_status,
            "github_webhook": "configured" if self.github_webhook_secret and self.github_repository else "unconfigured",
            "zendesk_webhook": zendesk_state,
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
            "code_release_worker": health["code_release_worker"],
            "customer_email_worker": health["customer_email_worker"],
            "hubspot_sync_worker": health["hubspot_sync_worker"],
            "github_webhook": health["github_webhook"],
            "zendesk_webhook": health["zendesk_webhook"],
        }
        blockers = []
        if health["database"] != "reachable":
            blockers.append("database")
        telegram_enabled = os.environ.get("SUTRA_ENABLE_TELEGRAM", "false").lower() == "true"
        worker_enabled = os.environ.get("SUTRA_ENABLE_AGENT_WORKER", "false").lower() == "true"
        dispatcher_enabled = os.environ.get("SUTRA_ENABLE_GITHUB_DISPATCHER", "false").lower() == "true"
        codex_enabled = os.environ.get("SUTRA_ENABLE_CODEX_RUNNER", "false").lower() == "true"
        code_release_enabled = os.environ.get("SUTRA_ENABLE_CODE_RELEASE_WORKER", "false").lower() == "true"
        customer_email_enabled = os.environ.get("SUTRA_ENABLE_CUSTOMER_EMAIL_WORKER", "false").lower() == "true"
        hubspot_enabled = os.environ.get("SUTRA_ENABLE_HUBSPOT_SYNC_WORKER", "false").lower() == "true"
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
        if code_release_enabled and health["code_release_worker"] != "running":
            blockers.append("code_release_worker")
        if customer_email_enabled and health["customer_email_worker"] != "running":
            blockers.append("customer_email_worker")
        if hubspot_enabled and health["hubspot_sync_worker"] != "running":
            blockers.append("hubspot_sync_worker")
        zendesk_enabled = os.environ.get("SUTRA_ENABLE_ZENDESK_WEBHOOK", "false").lower() == "true"
        if zendesk_enabled and health["zendesk_webhook"] != "configured":
            blockers.append("zendesk_webhook")
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
        for thread in self.agent_worker_threads:
            thread.join(timeout=2)
        if self.agent_worker_thread and not self.agent_worker_threads:
            self.agent_worker_thread.join(timeout=2)
        if self.github_dispatcher_thread:
            self.github_dispatcher_thread.join(timeout=2)
        if self.codex_runner_thread:
            self.codex_runner_thread.join(timeout=2)
        if self.code_release_thread:
            self.code_release_thread.join(timeout=2)
        if self.customer_email_worker_thread:
            self.customer_email_worker_thread.join(timeout=2)
        if self.hubspot_sync_worker_thread:
            self.hubspot_sync_worker_thread.join(timeout=2)


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
        if path == "/webhooks/zendesk":
            self._zendesk_webhook()
            return
        if path == "/v1/drafts":
            self._draft_request("POST", path)
            return
        if path not in {"/internal/spend", "/internal/role-approval", "/internal/task-update", "/internal/task-review", "/internal/customer-email", "/internal/customer-crm-sync"}:
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
            if path == "/internal/customer-crm-sync":
                if self.app.hubspot_sync_worker_status != "running":
                    self._json(503, {"error": "crm_sync_worker_disabled"})
                    return
                allowed = {"actor_agent_id", "task_id", "project_id", "customer_id",
                           "estimated_cost_eur", "idempotency_key"}
                if set(payload) != allowed:
                    raise ValueError("Malformed customer CRM sync request")
                estimated_cost = payload["estimated_cost_eur"]
                if (not isinstance(estimated_cost, (int, float)) or isinstance(estimated_cost, bool)
                        or estimated_cost <= 0 or estimated_cost > 999999999999.99
                        or (isinstance(estimated_cost, float) and not math.isfinite(estimated_cost))):
                    raise ValueError("Estimated cost must be finite, positive EUR within the supported range")
                idempotency_key = payload["idempotency_key"]
                if not isinstance(idempotency_key, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}", idempotency_key):
                    raise ValueError("CRM sync requires an 8 to 128 character idempotency key")
                try:
                    agent_id = str(uuid.UUID(str(payload["actor_agent_id"])))
                    task_id = str(uuid.UUID(str(payload["task_id"])))
                    project_id = str(uuid.UUID(str(payload["project_id"])))
                    customer_id = str(uuid.UUID(str(payload["customer_id"])))
                except (TypeError, ValueError, AttributeError) as exc:
                    raise ValueError("Customer CRM sync IDs must be UUIDs") from exc
                result = self.app.store.rpc("sutra_queue_customer_crm_sync", {
                    "p_agent_id": agent_id, "p_task_id": task_id, "p_project_id": project_id,
                    "p_customer_id": customer_id, "p_estimated_cost_eur": estimated_cost,
                    "p_idempotency_key": idempotency_key,
                })
            elif path == "/internal/customer-email":
                allowed = {
                    "actor_agent_id", "actor_agent_slug", "task_id", "project_id", "customer_id",
                    "purpose", "subject", "body_text", "estimated_cost_eur", "idempotency_key",
                }
                if set(payload) != allowed:
                    raise ValueError("Malformed customer email action")
                agent_slug = payload["actor_agent_slug"]
                if agent_slug not in {"sales", "cmo"}:
                    raise ValueError("Customer email action requires a Sales or Marketing agent")
                purpose = payload["purpose"]
                if purpose not in {"sales", "marketing", "support"}:
                    raise ValueError("Invalid customer email purpose")
                subject, body_text = payload["subject"], payload["body_text"]
                if (not isinstance(subject, str) or not subject.strip() or len(subject) > 200
                        or not isinstance(body_text, str) or not body_text.strip() or len(body_text) > 10_000):
                    raise ValueError("Email subject or body exceeds the supported bounds")
                estimated_cost = payload["estimated_cost_eur"]
                if (not isinstance(estimated_cost, (int, float)) or isinstance(estimated_cost, bool)
                        or estimated_cost <= 0 or estimated_cost > 999999999999.99
                        or (isinstance(estimated_cost, float) and not math.isfinite(estimated_cost))):
                    raise ValueError("Estimated cost must be finite, positive EUR within the supported range")
                idempotency_key = payload["idempotency_key"]
                if not isinstance(idempotency_key, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}", idempotency_key):
                    raise ValueError("Customer email actions require an 8 to 128 character idempotency key")
                try:
                    agent_id = str(uuid.UUID(str(payload["actor_agent_id"])))
                    task_id = str(uuid.UUID(str(payload["task_id"])))
                    project_id = str(uuid.UUID(str(payload["project_id"])))
                    customer_id = str(uuid.UUID(str(payload["customer_id"])))
                except (TypeError, ValueError, AttributeError) as exc:
                    raise ValueError("Customer email action IDs must be UUIDs") from exc
                result = self.app.store.rpc("sutra_queue_customer_email", {
                    "p_agent_id": agent_id,
                    "p_agent_slug": agent_slug,
                    "p_task_id": task_id,
                    "p_project_id": project_id,
                    "p_customer_id": customer_id,
                    "p_purpose": purpose,
                    "p_subject": subject.strip(),
                    "p_body_text": body_text.strip(),
                    "p_estimated_cost_eur": estimated_cost,
                    "p_idempotency_key": idempotency_key,
                })
            elif path == "/internal/task-review":
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
                allowed = {"actor_id", "project_id", "department_id", "agent_id", "category", "vendor", "description", "amount", "currency", "idempotency_key"}
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
                if payload.get("project_id") is not None:
                    idempotency_key = payload.get("idempotency_key")
                    if not isinstance(idempotency_key, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}", idempotency_key):
                        raise ValueError("project costs require an 8 to 128 character idempotency_key")
                    result = self.app.store.rpc("sutra_authorize_initiative_cost", {
                        "p_actor_type": "agent", "p_actor_id": actor_id, "p_agent_id": agent_id,
                        "p_project_id": payload["project_id"], "p_category": payload["category"],
                        "p_vendor": vendor, "p_description": payload["description"],
                        "p_amount": amount, "p_currency": currency,
                        "p_idempotency_key": idempotency_key,
                    })
                else:
                    if payload.get("idempotency_key") is not None:
                        raise ValueError("idempotency_key is only accepted with a project cost")
                    result = self.app.store.rpc("sutra_authorize_spend", {
                        "p_actor_type": "agent",
                        "p_actor_id": actor_id,
                        "p_project_id": None,
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

    def _zendesk_webhook(self) -> None:
        enabled = os.environ.get("SUTRA_ENABLE_ZENDESK_WEBHOOK", "false").lower() == "true"
        if not enabled or self.app.store is None or not self.app.zendesk_webhook_secret:
            self._json(503, {"error": "zendesk_webhook_disabled"})
            return
        try:
            raw = self._read_raw_json()
            timestamp = self.headers.get("X-Zendesk-Webhook-Timestamp", "")
            signature = self.headers.get("X-Zendesk-Webhook-Signature", "")
            if not verify_zendesk_signature(self.app.zendesk_webhook_secret, timestamp, raw, signature):
                self._json(401, {"error": "invalid_signature"})
                return
            payload = json.loads(raw)
            normalized = normalize_zendesk_ticket_event(payload)
            if normalized is None:
                self._json(400, {"error": "invalid_ticket_event"})
                return
            result = self.app.store.rpc("sutra_ingest_zendesk_ticket_event", {
                "p_ticket_id": normalized["ticket_id"],
                "p_status": normalized["status"],
                "p_priority": normalized["priority"],
                "p_provider_updated_at": normalized["updated_at"],
            })
            self._json(202, result)
        except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
            self._json(400, {"error": "invalid_ticket_event"})
        except IntegrationError:
            self._json(503, {"error": "support_event_persistence_unavailable"})

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
