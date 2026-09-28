"""Founder command router and server-side Supabase access."""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any, Callable


class IntegrationError(RuntimeError):
    """An external integration returned an invalid or unsuccessful response."""


def validate_outbound_request(request: urllib.request.Request) -> None:
    """Allow HTTPS integrations and only the private Railway HTTP network."""
    try:
        parsed = urllib.parse.urlsplit(request.full_url)
        _ = parsed.port
    except ValueError as exc:
        raise urllib.error.URLError("Outbound request URL is invalid") from exc
    private_railway_http = (
        parsed.scheme == "http" and bool(parsed.hostname)
        and parsed.hostname.endswith(".railway.internal")
    )
    if (
        not parsed.hostname or parsed.username is not None or parsed.password is not None
        or (parsed.scheme != "https" and not private_railway_http)
    ):
        raise urllib.error.URLError("Outbound request URL scheme or authority is not allowed")


def open_outbound_request(request: urllib.request.Request, timeout: float) -> Any:
    validate_outbound_request(request)
    # The HTTPS/private-network allowlist above prevents file and custom URL handlers.
    return urllib.request.urlopen(request, timeout=timeout)  # nosec B310


class SupabaseREST:
    """Small server-only PostgREST client; never log headers or response secrets."""

    def __init__(self, url: str, key: str, timeout: float = 8.0):
        self.url = url.rstrip("/")
        self.key = key
        self.timeout = timeout

    def request(self, path: str, method: str = "GET", payload: dict[str, Any] | None = None) -> Any:
        if not self.url.startswith("https://") or not self.key:
            raise IntegrationError("Supabase is not configured")
        body = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(
            f"{self.url}/rest/v1/{path.lstrip('/')}",
            data=body,
            method=method,
            headers={
                "apikey": self.key,
                "Authorization": f"Bearer {self.key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Prefer": "return=representation",
            },
        )
        try:
            with open_outbound_request(req, timeout=self.timeout) as response:
                raw = response.read(1_000_001)
                if len(raw) > 1_000_000:
                    raise IntegrationError("Supabase response exceeded the size limit")
                return json.loads(raw) if raw else None
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise IntegrationError("Supabase request failed") from exc

    def rpc(self, name: str, payload: dict[str, Any]) -> dict[str, Any]:
        result = self.request(f"rpc/{name}", "POST", payload)
        if not isinstance(result, dict):
            raise IntegrationError("Supabase returned an invalid RPC response")
        return result

    def acquire_agent_worker_execution_lease(self, worker_id: str) -> bool:
        result = self.request("rpc/sutra_acquire_agent_worker_execution_lease", "POST",
                              {"p_worker_id": worker_id})
        if type(result) is not bool:
            raise IntegrationError("Supabase returned an invalid worker lease response")
        return result

    def release_agent_worker_execution_lease(self, worker_id: str) -> bool:
        result = self.request("rpc/sutra_release_agent_worker_execution_lease", "POST",
                              {"p_worker_id": worker_id})
        if type(result) is not bool:
            raise IntegrationError("Supabase returned an invalid worker lease response")
        return result

    def claim_agent_run(self, worker_id: str) -> dict[str, Any] | None:
        result = self.request("rpc/sutra_claim_agent_run", "POST", {"p_worker_id": worker_id})
        if result is None:
            result = self.request("rpc/sutra_claim_task_review_agent_run", "POST", {"p_worker_id": worker_id})
        if result is None:
            result = self.request("rpc/sutra_claim_task_agent_run", "POST", {"p_worker_id": worker_id})
        if result is None:
            return None
        if not isinstance(result, dict):
            raise IntegrationError("Supabase returned an invalid worker claim")
        return result

    def complete_agent_run(self, worker_id: str, run: dict[str, Any], outcome: str,
                           output: dict[str, Any], error_code: str | None = None) -> dict[str, Any]:
        run_id, lease_token = run.get("run_id"), run.get("lease_token")
        if not isinstance(run_id, str) or not isinstance(lease_token, str):
            raise IntegrationError("Claimed worker run is missing its lease")
        return self.rpc("sutra_complete_agent_run", {
            "p_worker_id": worker_id,
            "p_run_id": run_id,
            "p_lease_token": lease_token,
            "p_outcome": outcome,
            "p_output": output,
            "p_error_code": error_code,
        })

    def submit_task_review(self, run: dict[str, Any], evidence: dict[str, Any]) -> dict[str, Any]:
        task_review = run.get("task_review")
        agent = run.get("agent")
        if not isinstance(task_review, dict) or not isinstance(agent, dict):
            raise IntegrationError("Task review run is missing its assigned task context")
        return self.rpc("sutra_submit_task_review", {
            "p_task_id": task_review.get("task_id"),
            "p_actor_agent_id": agent.get("id"),
            "p_evidence": evidence,
        })

    def submit_task_agent_artifact(self, worker_id: str, run: dict[str, Any], artifact: dict[str, Any]) -> dict[str, Any]:
        return self.rpc("sutra_submit_task_agent_artifact", {
            "p_worker_id": worker_id, "p_run_id": run.get("run_id"),
            "p_lease_token": run.get("lease_token"), "p_output": artifact,
        })

    def get_agent_model_spend_profile(self, provider: str, model: str) -> dict[str, Any]:
        return self.rpc("sutra_get_agent_model_spend_profile", {
            "p_provider": provider, "p_model": model,
        })

    def reserve_agent_run_spend(self, worker_id: str, run: dict[str, Any], provider: str, model: str) -> dict[str, Any]:
        return self.rpc("sutra_reserve_agent_run_spend_from_profile", {
            "p_worker_id": worker_id, "p_run_id": run.get("run_id"),
            "p_lease_token": run.get("lease_token"), "p_provider": provider, "p_model": model,
        })

    def begin_agent_run_spend(self, worker_id: str, run: dict[str, Any], reservation_id: str) -> dict[str, Any]:
        return self.rpc("sutra_begin_agent_run_spend", {
            "p_worker_id": worker_id, "p_run_id": run.get("run_id"),
            "p_lease_token": run.get("lease_token"), "p_reservation_id": reservation_id,
        })

    def reconcile_agent_run_spend(self, worker_id: str, run: dict[str, Any], reservation_id: str,
                                  provider: str, model: str, usage: dict[str, Any] | None) -> dict[str, Any]:
        known = isinstance(usage, dict)
        input_tokens = usage.get("prompt_tokens") if known else None
        output_tokens = usage.get("completion_tokens") if known else None
        if (known and (isinstance(input_tokens, bool) or not isinstance(input_tokens, int)
                       or isinstance(output_tokens, bool) or not isinstance(output_tokens, int))):
            known = False
            input_tokens = output_tokens = None
        return self.rpc("sutra_reconcile_agent_run_spend_from_usage", {
            "p_worker_id": worker_id, "p_run_id": run.get("run_id"),
            "p_lease_token": run.get("lease_token"), "p_reservation_id": reservation_id,
            "p_provider": provider, "p_model": model, "p_input_tokens": input_tokens,
            "p_output_tokens": output_tokens, "p_usage": usage if isinstance(usage, dict) else {},
            "p_usage_known": known,
        })

    def codex_start_request(self, worker_id: str, run_id: str, lease_token: str,
                            model: str, output_tokens: int, request_bytes: int) -> dict[str, Any]:
        return self.rpc("sutra_codex_start_request", {
            "p_worker_id": worker_id, "p_run_id": run_id, "p_lease_token": lease_token,
            "p_model": model, "p_output_tokens": output_tokens, "p_request_bytes": request_bytes,
        })

    def authorize_codex_task(self, worker_id: str, task_id: str, issue_number: int,
                             issue_url: str, provider: str, model: str) -> dict[str, Any]:
        return self.rpc("sutra_authorize_codex_task", {
            "p_worker_id": worker_id, "p_task_id": task_id,
            "p_issue_number": issue_number, "p_issue_url": issue_url,
            "p_provider": provider, "p_model": model,
        })

    def claim_codex_execution(self, worker_id: str, run_id: str,
                              lease_token: str) -> dict[str, Any]:
        return self.rpc("sutra_claim_codex_execution", {
            "p_worker_id": worker_id, "p_run_id": run_id, "p_lease_token": lease_token,
        })

    def codex_record_usage(self, worker_id: str, run_id: str, lease_token: str,
                           input_tokens: int, output_tokens: int) -> dict[str, Any]:
        return self.rpc("sutra_codex_record_usage", {
            "p_worker_id": worker_id, "p_run_id": run_id, "p_lease_token": lease_token,
            "p_input_tokens": input_tokens, "p_output_tokens": output_tokens,
        })

    def codex_finish_run(self, worker_id: str, run_id: str, lease_token: str,
                         usage_trusted: bool, process_succeeded: bool,
                         process_exit_code: int | None,
                         failure_detail_code: str | None) -> dict[str, Any]:
        return self.rpc("sutra_codex_finish_run", {
            "p_worker_id": worker_id, "p_run_id": run_id, "p_lease_token": lease_token,
            "p_usage_trusted": usage_trusted,
            "p_process_succeeded": process_succeeded,
            "p_process_exit_code": process_exit_code,
            "p_failure_detail_code": failure_detail_code,
        })

    def claim_github_task(self, worker_id: str) -> dict[str, Any] | None:
        result = self.request("rpc/sutra_claim_github_task", "POST", {"p_worker_id": worker_id})
        if result is None:
            return None
        if not isinstance(result, dict):
            raise IntegrationError("Supabase returned an invalid GitHub task claim")
        return result

    def complete_github_task(self, worker_id: str, task_id: str, lease_token: str,
                             issue_number: int, issue_url: str) -> dict[str, Any]:
        return self.rpc("sutra_complete_github_task_dispatch", {
            "p_worker_id": worker_id, "p_task_id": task_id, "p_lease_token": lease_token,
            "p_issue_number": issue_number, "p_issue_url": issue_url,
        })

    def fail_github_task(self, worker_id: str, task_id: str, lease_token: str,
                         error_code: str) -> dict[str, Any]:
        return self.rpc("sutra_fail_github_task_dispatch", {
            "p_worker_id": worker_id, "p_task_id": task_id,
            "p_lease_token": lease_token, "p_error_code": error_code,
        })

    def company_status(self) -> dict[str, list[dict[str, Any]]]:
        """Read a bounded, factual operating snapshot from authoritative company state."""
        paths = {
            "projects": "projects?select=id,name,status,requested_budget,currency,department_id,owner_agent_id,updated_at&status=in.(proposed,approved,active,paused)&order=updated_at.desc&limit=50",
            "tasks": "tasks?select=id,title,status,project_id,owner_agent_id,updated_at&status=in.(backlog,ready,in_progress,blocked,review)&order=updated_at.desc&limit=100",
            "approvals": "approvals?select=id,project_id,summary,amount,currency,status,required_roles,decisions,created_at&status=eq.pending&order=created_at.desc&limit=50",
            "agent_runs": "agent_runs?select=task_id,status,output,finished_at&status=in.(failed,blocked)&order=finished_at.desc&limit=200",
            "agents": "agents?select=id,slug,display_name,department_id,active&active=eq.true&limit=100",
            "departments": "departments?select=id,slug,name&limit=100",
            "budgets": "budgets?select=scope,scope_key,period,currency,limit_amount,warning_percent,hard_stop&active=eq.true&limit=100",
            "expenses": "expenses?select=amount,currency,status,category,project_id,department_id,agent_id&status=in.(approved,paid,requested)&limit=500",
        }
        snapshot = {key: self.request(path) for key, path in paths.items()}
        dispatch_status = self.rpc("sutra_company_github_dispatch_status", {})
        dispatches = dispatch_status.get("dispatches")
        if not isinstance(dispatches, list):
            raise IntegrationError("Supabase returned an invalid GitHub dispatch status response")
        snapshot["github_dispatches"] = dispatches
        if not all(isinstance(rows, list) for rows in snapshot.values()):
            raise IntegrationError("Supabase returned an invalid company status response")
        return snapshot

    def founder_pending_approvals(self, founder_telegram_user_id: str) -> list[dict[str, Any]]:
        result = self.rpc("sutra_founder_pending_approvals", {
            "p_founder_telegram_user_id": founder_telegram_user_id,
        })
        approvals = result.get("approvals") if isinstance(result, dict) else None
        if not isinstance(approvals, list) or not all(isinstance(item, dict) for item in approvals):
            raise IntegrationError("Supabase returned an invalid founder approval queue")
        return approvals

    def record_denied_identity(self, actor_hash: str) -> None:
        self.request("rpc/sutra_log_auth_denial", "POST", {"p_actor_hash": actor_hash})


@dataclass(frozen=True)
class FounderCommand:
    kind: str
    text: str
    approval_id: str | None = None
    decision: str | None = None
    comment: str = ""
    budget: float | None = None
    task_id: str | None = None
    status_role: str = "company"
    retry_limit: int | None = None


@dataclass(frozen=True)
class FounderResponse:
    text: str
    reply_markup: dict[str, Any] | None = None


MONEY_PATTERNS = (
    re.compile(r"(?:€|EUR\s*)\s*([0-9]+(?:[.,][0-9]{1,2})?)", re.IGNORECASE),
    re.compile(r"([0-9]+(?:[.,][0-9]{1,2})?)\s*(?:€|EUR)", re.IGNORECASE),
)
APPROVAL_RE = re.compile(r"^\s*(approve|reject)\s+([0-9a-f-]{36})(?:\s+(.*))?\s*$", re.IGNORECASE)
PM_RETRY_RE = re.compile(r"^\s*(?:ceo[, :]\s*)?retry\s+pm\s+review\s+([0-9a-f-]{36})\s*[.!]?\s*$", re.IGNORECASE)
AGENT_REVIEW_RETRY_RE = re.compile(r"^\s*(?:ceo[, :]\s*)?retry\s+agent\s+review\s+([0-9a-f-]{36})\s*[.!]?\s*$", re.IGNORECASE)
PRODUCT_TASK_RETRY_RE = re.compile(r"^\s*(?:ceo[, :]\s*)?retry\s+pm\s+task\s+([0-9a-f-]{36})\s*[.!]?\s*$", re.IGNORECASE)
ARCHITECT_TASK_RETRY_RE = re.compile(r"^\s*(?:ceo[, :]\s*)?retry\s+architect\s+task\s+([0-9a-f-]{36})\s*[.!]?\s*$", re.IGNORECASE)
GITHUB_DISPATCH_RETRY_RE = re.compile(r"^\s*(?:ceo[, :]\s*)?retry\s+github\s+dispatch\s+([0-9a-f-]{36})\s*[.!]?\s*$", re.IGNORECASE)
CODEX_TASK_RETRY_RE = re.compile(r"^\s*(?:ceo[, :]\s*)?retry\s+codex\s+task\s+([0-9a-f-]{36})\s*[.!]?\s*$", re.IGNORECASE)
CODEX_RETRY_LIMIT_SET_RE = re.compile(
    r"^\s*(?:ceo[, :]\s*)?(?:set|change)\s+(?:the\s+)?codex\s+no-request\s+retry\s+limit\s+to\s+([0-9]{1,3})(?:\s+total\s+attempts?)?\s*[.!]?\s*$",
    re.IGNORECASE,
)
CODEX_RETRY_LIMIT_GET_RE = re.compile(
    r"^\s*(?:ceo[, :]\s*)?(?:show(?:\s+me)?|what\s+is)\s+(?:the\s+)?codex\s+no-request\s+retry\s+limit\s*[?.!]*\s*$",
    re.IGNORECASE,
)
STATUS_ROLE_RE = re.compile(r"^\s*(ceo|cto|cpo|cfo|coo|product manager|pm|architect|developer|qa|security|devops|cmo|marketing|sales|governance|audit)[, :]\s*(?:give me|show me|provide)?\s*(?:the\s+)?(?:company\s+)?(?:department\s+)?status(?:\s+report)?\s*[?.!]*\s*$", re.IGNORECASE)
STATUS_ROLES = {
    "ceo": ("CEO", None), "cto": ("CTO", "cto"), "cpo": ("CPO", "cpo"),
    "cfo": ("CFO", "cfo"), "coo": ("COO", "coo"), "product manager": ("Product Manager", "product_manager"),
    "pm": ("Product Manager", "product_manager"), "architect": ("Architect", "architect"),
    "developer": ("Developer", "developer"), "qa": ("QA", "qa"), "security": ("Security", "security"),
    "devops": ("DevOps", "devops"), "cmo": ("Marketing", "cmo"), "marketing": ("Marketing", "cmo"),
    "sales": ("Sales", "sales"), "governance": ("Governance / Audit", "governance"),
    "audit": ("Governance / Audit", "governance"),
}


def parse_founder_command(text: str) -> FounderCommand:
    if not isinstance(text, str) or not text.strip() or len(text) > 3000:
        raise ValueError("Command must contain 1 to 3000 characters")
    match = APPROVAL_RE.fullmatch(text)
    if match:
        return FounderCommand("approval", text.strip(), match.group(2), match.group(1).lower(), match.group(3) or "")
    match = PM_RETRY_RE.fullmatch(text)
    if match:
        try:
            run_id = str(uuid.UUID(match.group(1)))
        except ValueError as exc:
            raise ValueError("PM review retry needs a valid run ID") from exc
        return FounderCommand("retry_pm_review", text.strip(), approval_id=run_id)
    match = AGENT_REVIEW_RETRY_RE.fullmatch(text)
    if match:
        try:
            run_id = str(uuid.UUID(match.group(1)))
        except ValueError as exc:
            raise ValueError("Agent review retry needs a valid run ID") from exc
        return FounderCommand("retry_agent_review", text.strip(), approval_id=run_id)
    match = PRODUCT_TASK_RETRY_RE.fullmatch(text)
    if match:
        try:
            task_id = str(uuid.UUID(match.group(1)))
        except ValueError as exc:
            raise ValueError("PM task retry needs a valid task ID") from exc
        return FounderCommand("retry_product_task", text.strip(), task_id=task_id)
    match = ARCHITECT_TASK_RETRY_RE.fullmatch(text)
    if match:
        try:
            task_id = str(uuid.UUID(match.group(1)))
        except ValueError as exc:
            raise ValueError("Architect task retry needs a valid task ID") from exc
        return FounderCommand("retry_architect_task", text.strip(), task_id=task_id)
    match = GITHUB_DISPATCH_RETRY_RE.fullmatch(text)
    if match:
        try:
            task_id = str(uuid.UUID(match.group(1)))
        except ValueError as exc:
            raise ValueError("GitHub dispatch retry needs a valid task ID") from exc
        return FounderCommand("retry_github_dispatch", text.strip(), task_id=task_id)
    match = CODEX_TASK_RETRY_RE.fullmatch(text)
    if match:
        try:
            task_id = str(uuid.UUID(match.group(1)))
        except ValueError as exc:
            raise ValueError("Codex retry needs a valid task ID") from exc
        return FounderCommand("retry_codex_task", text.strip(), task_id=task_id)
    match = CODEX_RETRY_LIMIT_SET_RE.fullmatch(text)
    if match:
        total_attempts = int(match.group(1))
        if not 1 <= total_attempts <= 3:
            raise ValueError("Codex no-request retry limit must be 1 to 3 total attempts")
        return FounderCommand("set_codex_retry_limit", text.strip(), retry_limit=total_attempts)
    if CODEX_RETRY_LIMIT_GET_RE.fullmatch(text):
        return FounderCommand("get_codex_retry_limit", text.strip())
    lowered = text.lower()
    if re.fullmatch(r"\s*(?:(?:ceo[, :]\s*)?(?:show|list)\s+(?:my\s+)?approvals?|what\s+needs\s+my\s+approval)\s*[?.!]*\s*", lowered):
        return FounderCommand("approvals", text.strip())
    role_match = STATUS_ROLE_RE.fullmatch(text)
    if role_match:
        return FounderCommand("status", text.strip(), status_role=role_match.group(1).lower())
    if any(phrase in lowered for phrase in ("company status", "company update", "status report", "ceo, status")):
        return FounderCommand("status", text.strip())
    amount = None
    for pattern in MONEY_PATTERNS:
        found = pattern.search(text)
        if found:
            amount = float(found.group(1).replace(",", "."))
            if not math.isfinite(amount) or amount <= 0 or amount > 999999999999.99:
                raise ValueError("Budget must be positive and within the supported EUR range")
            break
    if amount is not None and any(phrase in lowered for phrase in ("investigate", "research", "proposal", "product", "prepare")):
        return FounderCommand("proposal", text.strip(), budget=amount)
    return FounderCommand("unsupported", text.strip())


def proposal_name(text: str) -> str:
    clean = re.split(r"\b(?:initial\s+)?budget\b", text, maxsplit=1, flags=re.IGNORECASE)[0]
    clean = clean.split(".", 1)[0]
    clean = re.sub(r"^(?:ceo[, :]\s*)?(?:please\s+)?(?:investigate|research|prepare\s+a\s+proposal\s+for|prepare)\s+", "", clean, flags=re.IGNORECASE)
    clean = re.sub(r"^(?:an?|the)\s+", "", clean, flags=re.IGNORECASE)
    clean = re.sub(r"\s+", " ", clean).strip(" .,:;\n")
    if not clean:
        clean = "Founder product proposal"
    return (clean[:145] + " opportunity")[:160]


class FounderCommandRouter:
    def __init__(self, store: SupabaseREST, founder_telegram_user_id: str):
        self.store = store
        self.founder_telegram_user_id = founder_telegram_user_id

    def handle(self, user_id: str, chat_id: str, text: str) -> FounderResponse:
        if not self.founder_telegram_user_id or user_id != self.founder_telegram_user_id or chat_id != user_id:
            digest = hashlib.sha256(str(user_id).encode()).hexdigest()[:24]
            try:
                self.store.record_denied_identity(digest)
            except IntegrationError:
                pass
            return FounderResponse("This founder interface is restricted to the configured founder in a private chat.")
        try:
            command = parse_founder_command(text)
        except ValueError as exc:
            return FounderResponse(str(exc))
        if command.kind == "status":
            try:
                status = self.store.company_status()
            except IntegrationError:
                return FounderResponse("I couldn't load company status. No company state was changed; check the database connection and try again.")
            return FounderResponse(render_status_brief(status, command.status_role))
        if command.kind == "approvals":
            try:
                approvals = self.store.founder_pending_approvals(user_id)
            except IntegrationError:
                return FounderResponse("I couldn't load the founder approval queue. No approval was changed; check the database connection and try again.")
            if not approvals:
                return FounderResponse("No pending founder approval requests.")
            lines = [f"Founder approvals ({len(approvals)} shown):"]
            keyboard: list[list[dict[str, str]]] = []
            scope_context_shown = False
            for item in approvals:
                approval_id = item.get("approval_id")
                summary = re.sub(r"\s+", " ", str(item.get("summary") or "Approval request"))[:180]
                amount = item.get("amount")
                currency = re.sub(r"[^A-Z]", "", str(item.get("currency") or "EUR").upper())[:3]
                valid_amount = isinstance(amount, int) or (isinstance(amount, float) and math.isfinite(amount))
                value = f"{currency} {amount:,.2f}"[:48] if valid_amount else "amount not specified"
                missing = item.get("pending_roles")
                reviewer_list = ", ".join(str(role)[:32] for role in missing[:3]) if isinstance(missing, list) and missing else "department review"
                readiness = "ready for your decision" if item.get("ready") is True else f"waiting for {reviewer_list}"
                lines.extend((f"• {summary} — {value}; {readiness}", f"  ID: {approval_id}"))
                scope = item.get("scope_review")
                if item.get("approval_type") == "developer_scope" and isinstance(scope, dict) and not scope_context_shown:
                    scope_context_shown = True
                    design = re.sub(r"\s+", " ", str(scope.get("design") or ""))
                    if len(design) > 1400:
                        design = design[:1399].rstrip() + "…"
                    risks = scope.get("security_risks")
                    if design:
                        lines.append(f"  Proposed implementation design: {design}")
                    if isinstance(risks, list) and risks:
                        lines.append("  Security risks to review: " + "; ".join(re.sub(r"\s+", " ", str(risk))[:180] for risk in risks[:3]))
                    lines.append("  This authorizes the Developer to begin this scoped implementation; it does not approve spend or release.")
                try:
                    approval_id = str(uuid.UUID(str(approval_id)))
                except (ValueError, TypeError, AttributeError):
                    approval_id = ""
                if item.get("ready") is True and approval_id:
                    keyboard.append([
                        {"text": "Approve", "callback_data": f"approve:{approval_id}"},
                        {"text": "Reject", "callback_data": f"reject:{approval_id}"},
                    ])
            lines.append("Approve or reject only when ready: approve <approval-id> [comment] / reject <approval-id> [comment].")
            markup = {"inline_keyboard": keyboard} if keyboard else None
            return FounderResponse("\n".join(lines), markup)
        if command.kind == "proposal":
            try:
                result = self.store.rpc("sutra_submit_proposal", {
                    "p_founder_telegram_user_id": user_id,
                    "p_name": proposal_name(command.text),
                    "p_description": command.text,
                    "p_requested_budget": command.budget,
                    "p_currency": "EUR",
                })
            except IntegrationError:
                return FounderResponse("I couldn't record that proposal. No project or spending authorization was created; check the database connection and try again.")
            return FounderResponse(
                "Proposal recorded for CEO → Product → CTO → CFO review, then founder approval.\n"
                f"Project: {result.get('project_id')}\n"
                f"Approval: {result.get('approval_id')}\n"
                f"Requested maximum: €{command.budget:,.2f}. No spending is authorized until approval."
            )
        if command.kind == "approval":
            try:
                result = self.store.rpc("sutra_founder_decide_approval", {
                    "p_founder_telegram_user_id": user_id,
                    "p_approval_id": command.approval_id,
                    "p_decision": command.decision,
                    "p_comment": command.comment,
                })
            except IntegrationError:
                return FounderResponse("Approval unchanged. Confirm the request is pending and all required department reviews, including CFO, are complete.")
            return FounderResponse(f"Approval {result.get('status')}: {result.get('approval_id')}")
        if command.kind == "retry_pm_review":
            try:
                result = self.store.rpc("sutra_founder_retry_pm_review", {
                    "p_founder_telegram_user_id": user_id,
                    "p_run_id": command.approval_id,
                })
            except IntegrationError:
                return FounderResponse("PM review was not retried. It must be a failed, bounded PM run with CFO review complete and the project approval still pending.")
            return FounderResponse(
                f"PM review queued: {result.get('run_id')}. A new attempt uses the normal spend reservation and monthly hard cap. "
                "Unknown earlier usage remains reserved; project spending is not authorized."
            )
        if command.kind == "retry_agent_review":
            try:
                result = self.store.rpc("sutra_founder_retry_agent_review", {
                    "p_founder_telegram_user_id": user_id,
                    "p_run_id": command.approval_id,
                })
            except IntegrationError:
                return FounderResponse("Agent review was not retried. It must be a failed, bounded CEO/CPO/CTO/CFO stage with all prior reviews complete and a pending project approval.")
            role = str(result.get("review_role") or "agent")[:32].upper()
            return FounderResponse(
                f"{role} review queued: {result.get('run_id')}. A new attempt uses the normal spend reservation and monthly hard cap. "
                "Unknown earlier usage remains reserved; project spending is not authorized."
            )
        if command.kind == "retry_product_task":
            try:
                result = self.store.rpc("sutra_founder_retry_product_task_artifact", {
                    "p_founder_telegram_user_id": user_id,
                    "p_task_id": command.task_id,
                })
            except IntegrationError:
                return FounderResponse("PM task was not retried. It must be a blocked task in an approved project with a failed, recognized artifact run and retry capacity remaining.")
            return FounderResponse(
                f"PM task queued: {result.get('task_id')}. A new run uses the normal spend reservation and monthly hard cap. "
                "Unknown earlier usage remains reserved; project approval and spending authority are unchanged."
            )
        if command.kind == "retry_architect_task":
            try:
                result = self.store.rpc("sutra_founder_retry_architecture_task_artifact", {
                    "p_founder_telegram_user_id": user_id,
                    "p_task_id": command.task_id,
                })
            except IntegrationError:
                return FounderResponse("Architect task was not retried. It must be a blocked architecture task in an approved project with a failed, recognized artifact run and retry capacity remaining.")
            return FounderResponse(
                f"Architect task queued: {result.get('task_id')}. A new run uses the normal spend reservation and monthly hard cap. "
                "Unknown earlier usage remains reserved; project approval and spending authority are unchanged."
            )
        if command.kind == "retry_github_dispatch":
            try:
                result = self.store.rpc("sutra_founder_retry_github_task_dispatch", {
                    "p_founder_telegram_user_id": user_id,
                    "p_task_id": command.task_id,
                })
            except IntegrationError:
                return FounderResponse(
                    "GitHub dispatch was not retried. Only a failed permission-denied dispatch for the same approved Developer task can be retried; confirm GitHub access is fixed first."
                )
            retry_number = result.get("founder_retry_number")
            return FounderResponse(
                f"GitHub issue dispatch queued (founder retry {retry_number}/3). The existing founder-approved task scope is unchanged; "
                "this grants no spending, merge, or release authority."
            )
        if command.kind == "retry_codex_task":
            try:
                result = self.store.rpc("sutra_founder_retry_codex_task_execution", {
                    "p_founder_telegram_user_id": user_id,
                    "p_task_id": command.task_id,
                })
            except IntegrationError:
                return FounderResponse(
                    "Codex was not retried. The founder retry requires the same approved Developer task and scope, no open PR, zero model requests/usage, an unknown prior reservation, and retry capacity."
                )
            if result.get("status") == "awaiting_approval":
                return FounderResponse(
                    f"Codex attempt {result.get('attempt_number', '?')} of {result.get('max_total_attempts', '?')} is waiting for model-spend approval: {result.get('approval_id')}. The old unknown reservation remains preserved."
                )
            return FounderResponse(
                f"Codex attempt {result.get('attempt_number', '?')} of {result.get('max_total_attempts', '?')} queued. The previous unknown reservation remains preserved; a fresh reservation was requested under the existing spend policy and monthly hard cap. No project spending, merge, or release authority was added."
            )
        if command.kind == "get_codex_retry_limit":
            try:
                result = self.store.rpc("sutra_founder_get_codex_retry_limit", {
                    "p_founder_telegram_user_id": user_id,
                })
            except IntegrationError:
                return FounderResponse("I couldn't read the Codex retry limit. No setting changed; check the database connection and try again.")
            return FounderResponse(
                f"Current Codex no-request retry limit: {result.get('max_total_attempts')} total attempts per execution (founder-adjustable from 1 to 3). Changing it never starts a retry."
            )
        if command.kind == "set_codex_retry_limit":
            try:
                result = self.store.rpc("sutra_founder_set_codex_retry_limit", {
                    "p_founder_telegram_user_id": user_id,
                    "p_total_attempts": command.retry_limit,
                })
            except IntegrationError:
                return FounderResponse("Codex retry limit unchanged. Only the configured founder can set it from 1 to 3 total attempts.")
            changed = bool(result.get("changed"))
            change_note = (
                "The change was audit logged and did not trigger a retry."
                if changed
                else "It was already set to that value, so no change or retry occurred."
            )
            return FounderResponse(
                f"Codex no-request retry limit {'changed' if changed else 'already set'}: {result.get('max_total_attempts')} total attempts per execution. {change_note} Existing spend policy, monthly hard cap, task scope, merge, and release authority are unchanged."
            )
        return FounderResponse(
            "I can report company status, list founder approvals, prepare a budgeted proposal, or decide an approval.\n"
            "Use: CEO, give me company status.\n"
            "Use: CEO, show my approvals.\n"
            "Use: retry PM review <run-id>.\n"
            "Use: retry PM task <task-id> for a bounded failed product-plan task.\n"
            "Use: retry Architect task <task-id> for a bounded failed architecture task.\n"
            "Use: retry GitHub dispatch <task-id> after fixing a GitHub permission failure.\n"
            "Use: retry Codex task <task-id> after a verified no-request runner failure.\n"
            "Use: CEO, show Codex no-request retry limit.\n"
            "Use: CEO, set Codex no-request retry limit to <1-3> total attempts. This only changes the audited founder setting; it does not retry a task.\n"
            "Use: retry agent review <run-id> for a bounded failed CEO/CPO/CTO/CFO stage.\n"
            "Use: Investigate <idea>. Maximum budget €<amount>. Prepare a proposal.\n"
            "Use: approve <approval-id> [comment] or reject <approval-id> [comment]."
        )

    def handle_callback(self, user_id: str, chat_id: str, data: str) -> str:
        """Process a short-lived Telegram button action through the founder-only DB RPC."""
        if not self.founder_telegram_user_id or user_id != self.founder_telegram_user_id or chat_id != user_id:
            digest = hashlib.sha256(str(user_id).encode()).hexdigest()[:24]
            try:
                self.store.record_denied_identity(digest)
            except IntegrationError:
                pass
            return "Founder approval controls are restricted to the configured founder in a private chat."
        match = re.fullmatch(r"(approve|reject):([0-9a-f-]{36})", data) if isinstance(data, str) else None
        if not match:
            return "Invalid approval action. No approval was changed."
        try:
            approval_id = str(uuid.UUID(match.group(2)))
        except ValueError:
            return "Invalid approval action. No approval was changed."
        decision = match.group(1)
        comment = "Approved from the founder's Telegram approval button." if decision == "approve" else "Rejected from the founder's Telegram approval button."
        try:
            result = self.store.rpc("sutra_founder_decide_approval", {
                "p_founder_telegram_user_id": user_id,
                "p_approval_id": approval_id,
                "p_decision": decision,
                "p_comment": comment,
            })
        except IntegrationError:
            return "Approval unchanged. Confirm it is pending and all required department reviews, including CFO, are complete."
        return f"Approval {result.get('status')}: {result.get('approval_id')}"


def render_status_brief(snapshot: dict[str, list[dict[str, Any]]], requested_role: str = "company") -> str:
    """Render a board-style status using only persisted Supabase facts."""
    label, agent_slug = STATUS_ROLES.get(requested_role, ("Company", None))
    projects = snapshot["projects"]
    tasks = snapshot["tasks"]
    approvals = snapshot["approvals"]
    runs_by_task: dict[str, dict[str, Any]] = {}
    for run in snapshot["agent_runs"]:
        task_id = run.get("task_id")
        if not task_id:
            continue
        run_key = str(task_id)
        output = run.get("output") if isinstance(run.get("output"), dict) else {}
        has_failure_detail = bool(output.get("error_code") or output.get("failure_detail_code"))
        current_output = runs_by_task.get(run_key, {}).get("output")
        current_has_failure_detail = isinstance(current_output, dict) and bool(
            current_output.get("error_code") or current_output.get("failure_detail_code")
        )
        if run_key not in runs_by_task or (has_failure_detail and not current_has_failure_detail):
            runs_by_task[run_key] = run
    agents = {str(row.get("id")): row for row in snapshot["agents"]}
    departments = {str(row.get("id")): row for row in snapshot["departments"]}
    target_agent = next((row for row in agents.values() if row.get("slug") == agent_slug), None)
    dept_id = target_agent.get("department_id") if target_agent else None
    is_company_wide = agent_slug is None or requested_role in {"ceo", "cfo", "coo"}
    if is_company_wide:
        scoped_projects, scoped_tasks, scoped_approvals = projects, tasks, approvals
    else:
        team_agent_ids = {agent_id for agent_id, row in agents.items()
                          if row.get("slug") == agent_slug or (dept_id and row.get("department_id") == dept_id)}
        scoped_projects = [row for row in projects if row.get("department_id") == dept_id or row.get("owner_agent_id") in team_agent_ids]
        scoped_tasks = [row for row in tasks if row.get("owner_agent_id") in team_agent_ids]
        scoped_project_ids = {row.get("id") for row in scoped_projects}
        scoped_approvals = [row for row in approvals if row.get("project_id") in scoped_project_ids]
    task_statuses = ("backlog", "ready", "in_progress", "blocked", "review")
    counts = {state: sum(1 for task in scoped_tasks if task.get("status") == state) for state in task_statuses}
    active_projects = [p for p in scoped_projects if p.get("status") in {"approved", "active", "paused"}]
    blocked_tasks = [t for t in scoped_tasks if t.get("status") == "blocked"]
    department_label = departments.get(str(dept_id), {}).get("name") if dept_id else None
    lines = [f"{label} operating brief — board update", ""]
    if department_label and not is_company_wide:
        lines.append(f"Scope: {department_label}")
    lines.extend([
        "Portfolio",
        f"• Active/approved/paused projects: {len(active_projects)}; proposals awaiting decisions: {sum(1 for p in scoped_projects if p.get('status') == 'proposed')}",
        f"• Open work: {sum(counts.values())} tasks — {counts['backlog']} backlog, {counts['ready']} ready, {counts['in_progress']} in progress, {counts['review']} in review, {counts['blocked']} blocked",
        f"• Pending approvals: {len(scoped_approvals)}",
        "",
        "Projects in motion",
    ])
    if not scoped_projects:
        lines.append("• None recorded in this scope.")
    for project in scoped_projects[:8]:
        name = re.sub(r"\s+", " ", str(project.get("name") or "Untitled project"))[:90]
        status_text = str(project.get("status") or "unknown")
        amount = project.get("requested_budget")
        currency = str(project.get("currency") or "EUR")[:3]
        budget = f"; requested ceiling {currency} {amount}" if isinstance(amount, (int, float)) else ""
        owner = agents.get(str(project.get("owner_agent_id")), {}).get("display_name", "Unassigned")
        lines.append(f"• {name} — {status_text}; owner {owner}{budget}")
    if len(scoped_projects) > 8:
        lines.append(f"• {len(scoped_projects) - 8} more projects omitted; see the Supabase project list.")
    lines.extend(["", "Open tasks"])
    status_order = {"blocked": 0, "in_progress": 1, "review": 2, "ready": 3, "backlog": 4}
    visible_tasks = sorted(
        (task for task in scoped_tasks if task.get("status") in status_order),
        key=lambda task: (status_order.get(task.get("status"), 5), str(task.get("updated_at") or "")),
    )
    if not visible_tasks:
        lines.append("• No open tasks recorded in this scope.")
    for task in visible_tasks[:12]:
        owner = agents.get(str(task.get("owner_agent_id")), {}).get("display_name", "Unassigned")
        title = re.sub(r"\s+", " ", str(task.get("title") or "Untitled task"))[:84]
        lines.append(f"• [{task.get('status', 'unknown')}] {title} — {owner}")
    if len(visible_tasks) > 12:
        lines.append(f"• {len(visible_tasks) - 12} more open tasks omitted; see the Supabase task list.")
    failed_codex_tasks = []
    for task in scoped_tasks:
        run = runs_by_task.get(str(task.get("id")), {})
        output = run.get("output") if isinstance(run.get("output"), dict) else {}
        if task.get("status") == "in_progress" and output.get("error_code") in {
            "codex_process_failed", "codex_usage_unknown", "codex_usage_settlement_failed",
        }:
            failed_codex_tasks.append(task)
    lines.extend(["", "Blockers and risks"])
    if not blocked_tasks and not failed_codex_tasks:
        lines.append("• No tasks currently marked blocked.")
    for task in blocked_tasks[:6]:
        title = re.sub(r"\s+", " ", str(task.get("title") or "Untitled task"))[:100]
        owner = agents.get(str(task.get("owner_agent_id")), {}).get("display_name", "Unassigned")
        run = runs_by_task.get(str(task.get("id")), {})
        output = run.get("output") if isinstance(run.get("output"), dict) else {}
        error_code = output.get("error_code")
        detail_code = output.get("failure_detail_code")
        cause_parts = [str(code)[:48] for code in (error_code, detail_code)
                       if isinstance(code, str) and re.fullmatch(r"[a-z0-9_:-]{1,48}", code)]
        if "unknown_or_overrun_spend" in cause_parts or "unknown_spend" in cause_parts:
            explanation = "model usage could not be verified within its reservation, so the run stopped under the spend controls"
        elif "invalid_evidence" in cause_parts:
            explanation = "the agent output failed evidence validation; research claims need source, URL and claim evidence"
        elif "invalid_artifact_schema" in cause_parts or "invalid_agent_output" in cause_parts:
            explanation = "the agent output did not match the required artifact schema"
        elif cause_parts:
            explanation = "latest failed run recorded " + " / ".join(cause_parts)
        elif run:
            explanation = "the task is blocked, but its run did not persist a specific failure reason"
        else:
            explanation = "no execution run is linked to this task, so there is no recorded completion or blocker evidence"
        cause = "; " + explanation
        lines.append(f"• {title} — owned by {owner}{cause}.")
    for task in failed_codex_tasks[:6]:
        title = re.sub(r"\s+", " ", str(task.get("title") or "Untitled task"))[:100]
        run = runs_by_task[str(task.get("id"))]
        output = run.get("output") if isinstance(run.get("output"), dict) else {}
        exit_code = output.get("process_exit_code")
        detail = f" (Codex exit code {exit_code})" if isinstance(exit_code, int) else ""
        detail_code = output.get("failure_detail_code")
        safe_detail = f"; diagnostic {detail_code}" if isinstance(detail_code, str) and re.fullmatch(r"[a-z0-9_]{1,48}", detail_code) else ""
        if output.get("error_code") == "codex_process_failed":
            explanation = "provider usage was reconciled"
        else:
            explanation = "usage or its settlement could not be confirmed; the spend reservation remains under database control"
        lines.append(f"• {title} — Codex execution failed{detail}{safe_detail}; {explanation}, no PR was produced, and no automatic retry is queued.")
    dispatch_rows = snapshot.get("github_dispatches", [])
    include_delivery = is_company_wide or agent_slug in {"cto", "developer", "devops"}
    visible_dispatches = dispatch_rows[:6] if include_delivery else []
    if visible_dispatches:
        lines.append("Engineering delivery")
        for dispatch in visible_dispatches:
            title = re.sub(r"\s+", " ", str(dispatch.get("task_title") or "Engineering task"))[:90]
            code = dispatch.get("last_error")
            if code == "github_permission_denied":
                explanation = "GitHub rejected the issue write using the configured repository token; verify its Issues write permission is active"
            elif code == "github_rate_limited":
                explanation = "GitHub rate limit reached; dispatch will retry within its attempt limit"
            elif code:
                explanation = f"latest dispatch error: {str(code)[:48]}"
            elif dispatch.get("status") == "creating":
                explanation = "GitHub issue handoff is in progress"
            else:
                explanation = "GitHub delivery needs attention"
            attempts = dispatch.get("attempts")
            attempt_text = f"; attempt {attempts}/3" if isinstance(attempts, int) else ""
            lines.append(f"• [{dispatch.get('status', 'unknown')}] {title}{attempt_text} — {explanation}.")
    lines.extend(["", "Approvals requiring attention"])
    if not scoped_approvals:
        lines.append("• None pending.")
    for approval in scoped_approvals[:6]:
        summary = re.sub(r"\s+", " ", str(approval.get("summary") or "Approval request"))[:100]
        required = approval.get("required_roles")
        decisions = approval.get("decisions")
        decisions = decisions if isinstance(decisions, dict) else {}
        awaiting = [str(role) for role in required if not isinstance(decisions.get(role), dict)
                    or decisions[role].get("decision") not in {"approve", "approved"}] if isinstance(required, list) else []
        amount = approval.get("amount")
        value = f" — {str(approval.get('currency') or 'EUR')[:3]} {amount}" if isinstance(amount, (int, float)) else ""
        waiting_text = f"; awaiting {', '.join(awaiting[:4])}" if awaiting else "; ready for founder decision"
        lines.append(f"• {summary}{value}{waiting_text} (ID {approval.get('id', 'unknown')})")
    lines.extend(["", "Financial controls"])
    active_budgets = snapshot["budgets"]
    if not active_budgets:
        lines.append("• No active budget controls returned by the database.")
    else:
        for budget in active_budgets[:8]:
            amount = budget.get("limit_amount")
            amount_text = "no fixed ceiling" if amount is None else f"{budget.get('currency', 'EUR')} {amount}"
            hard_stop = "hard stop" if budget.get("hard_stop") else "warning only"
            lines.append(f"• {budget.get('scope')} / {budget.get('scope_key')} / {budget.get('period')}: {amount_text}; warn at {budget.get('warning_percent')}%; {hard_stop}")
    expenses = snapshot["expenses"]
    totals: dict[str, float] = {}
    for expense in expenses:
        currency = str(expense.get("currency") or "EUR")
        if isinstance(expense.get("amount"), (int, float)):
            totals[currency] = totals.get(currency, 0) + float(expense["amount"])
    if totals:
        lines.append("• Recorded requested/approved/paid expenses (all time): " + ", ".join(f"{currency} {amount:.2f}" for currency, amount in sorted(totals.items())))
    lines.extend(["", "Next focus", "• Resolve the listed blocked tasks and outstanding approvals; confirm each project owner’s next milestone."])
    output = "\n".join(lines)
    if len(output) > 3800:
        output = output[:3760].rsplit("\n", 1)[0] + "\n… Brief truncated to fit Telegram; consult Supabase for the full work queue."
    return output

def telegram_call(token: str, method: str, payload: dict[str, Any], timeout: float = 35.0) -> Any:
    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with open_outbound_request(request, timeout=timeout) as response:
            envelope = json.loads(response.read(1_000_001))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise IntegrationError("Telegram API request failed") from exc
    if not isinstance(envelope, dict) or envelope.get("ok") is not True:
        raise IntegrationError("Telegram API rejected the request")
    return envelope.get("result")


def telegram_poll_loop(token: str, router: FounderCommandRouter, stop: threading.Event,
                       status_callback: Callable[[str], None] | None = None) -> None:
    """Long-poll commands; skip old queued messages at startup to avoid replay."""
    offset: int | None = None
    try:
        latest = telegram_call(token, "getUpdates", {"timeout": 0, "limit": 1, "offset": -1})
        if latest:
            offset = int(latest[-1]["update_id"]) + 1
    except (IntegrationError, KeyError, TypeError, ValueError):
        pass
    while not stop.is_set():
        try:
            updates = telegram_call(token, "getUpdates", {"timeout": 25, "limit": 25, **({"offset": offset} if offset is not None else {})}) or []
            if not isinstance(updates, list):
                raise IntegrationError("Telegram returned an invalid updates response")
            if status_callback:
                status_callback("running")
            for update in updates:
                if not isinstance(update, dict) or isinstance(update.get("update_id"), bool) or not isinstance(update.get("update_id"), int):
                    continue
                offset = update["update_id"] + 1
                callback = update.get("callback_query")
                if isinstance(callback, dict):
                    sender_obj = callback.get("from")
                    message = callback.get("message")
                    chat_obj = message.get("chat") if isinstance(message, dict) else None
                    sender_id = sender_obj.get("id") if isinstance(sender_obj, dict) else None
                    chat_id = chat_obj.get("id") if isinstance(chat_obj, dict) else None
                    callback_id = callback.get("id")
                    if (isinstance(sender_id, int) and not isinstance(sender_id, bool)
                            and isinstance(chat_id, int) and not isinstance(chat_id, bool)
                            and isinstance(callback_id, str) and len(callback_id) <= 256):
                        callback_text = router.handle_callback(str(sender_id), str(chat_id), callback.get("data", ""))
                        approved = callback_text.startswith("Approval approved:") or callback_text.startswith("Approval rejected:")
                        try:
                            telegram_call(token, "answerCallbackQuery", {
                                "callback_query_id": callback_id,
                                "text": callback_text[:180],
                                "show_alert": not approved,
                            }, timeout=10)
                            if approved and isinstance(message, dict) and isinstance(message.get("message_id"), int):
                                telegram_call(token, "editMessageReplyMarkup", {
                                    "chat_id": chat_id,
                                    "message_id": message["message_id"],
                                    "reply_markup": {"inline_keyboard": []},
                                }, timeout=10)
                        except IntegrationError:
                            continue
                    continue
                message = update.get("message") or update.get("edited_message") or {}
                if not isinstance(message, dict):
                    continue
                sender_id = (message.get("from") or {}).get("id") if isinstance(message.get("from") or {}, dict) else None
                chat_id = (message.get("chat") or {}).get("id") if isinstance(message.get("chat") or {}, dict) else None
                if (isinstance(sender_id, bool) or not isinstance(sender_id, int)
                        or isinstance(chat_id, bool) or not isinstance(chat_id, int)):
                    continue
                sender, chat = str(sender_id), str(chat_id)
                text = message.get("text")
                if not isinstance(text, str):
                    continue
                try:
                    reply = router.handle(sender, chat, text)
                    payload = {"chat_id": chat, "text": reply.text[:3900]}
                    if reply.reply_markup:
                        payload["reply_markup"] = reply.reply_markup
                    telegram_call(token, "sendMessage", payload, timeout=10)
                except IntegrationError:
                    # Keep the polling loop alive; do not log command content or secrets.
                    continue
        except IntegrationError:
            if status_callback:
                status_callback("unreachable")
            stop.wait(5)
