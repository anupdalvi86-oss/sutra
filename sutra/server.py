"""HTTP liveness endpoint and private integration service for Sutra."""

from __future__ import annotations

import hmac
import json
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

from .runtime import FounderCommandRouter, IntegrationError, SupabaseREST, telegram_poll_loop


class GatewayProbe:
    """Probe the separately deployed Hermes service without exposing API credentials."""

    @staticmethod
    def state() -> str:
        url = os.environ.get("HERMES_HEALTH_URL", "")
        if not url.startswith("https://"):
            return "not_configured"
        request = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=1.5) as response:
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

    def start(self) -> None:
        if self.store and self.founder_id:
            try:
                self.store.rpc("sutra_register_founder", {"p_telegram_user_id": self.founder_id})
                self.founder_verified = True
                self.router = FounderCommandRouter(self.store, self.founder_id)
            except IntegrationError:
                self.founder_verified = False
        if self.store and self.router and self.telegram_token and self.founder_verified and os.environ.get("SUTRA_ENABLE_TELEGRAM", "false").lower() == "true":
            self.telegram_thread = threading.Thread(
                target=telegram_poll_loop,
                args=(self.telegram_token, self.router, self.telegram_stop),
                daemon=True,
                name="telegram-founder-interface",
            )
            self.telegram_thread.start()

    def health(self) -> dict[str, Any]:
        database = "unconfigured"
        if self.store:
            try:
                self.store.request("company_settings?select=key&limit=1")
                database = "reachable"
            except IntegrationError:
                database = "unreachable"
        telegram = "enabled" if self.store and self.router and self.telegram_token and self.founder_verified and os.environ.get("SUTRA_ENABLE_TELEGRAM", "false").lower() == "true" else "unconfigured"
        gateway = GatewayProbe.state()
        return {
            "status": "ok" if self.store and database == "reachable" else "degraded",
            "service": "sutra",
            "database": database,
            "telegram": telegram,
            "hermes_gateway": gateway,
        }

    def close(self) -> None:
        self.telegram_stop.set()


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
        if path == "/health":
            status = self.app.health()
            self._json(200, status)
            return
        if path == "/":
            self._json(200, {"service": "sutra", "health": "/health"})
            return
        self._json(404, {"error": "not_found"})

    def _read_json(self) -> dict[str, Any]:
        length = self.headers.get("Content-Length", "")
        if not length.isdigit() or int(length) <= 0 or int(length) > 64_000:
            raise ValueError("Request body size is invalid")
        if self.headers.get_content_type() != "application/json":
            raise ValueError("Content-Type must be application/json")
        try:
            payload = json.loads(self.rfile.read(int(length)))
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ValueError("Request body must be valid JSON") from exc
        if not isinstance(payload, dict):
            raise ValueError("Request body must be a JSON object")
        return payload

    def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
        path = urlsplit(self.path).path
        if path not in {"/internal/spend", "/internal/role-approval", "/internal/task-update"}:
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
            if path == "/internal/task-update":
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

    def log_message(self, fmt: str, *args: Any) -> None:
        # Exclude request bodies, credentials, and founder commands from logs.
        sys.stderr.write(f"{self.log_date_time_string()} {self.address_string()} {fmt % args}\n")


def serve() -> None:
    app = SutraApplication()
    app.start()
    host = os.environ.get("SUTRA_BIND_HOST", "0.0.0.0")
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
