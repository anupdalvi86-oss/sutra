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
                         success: bool) -> dict[str, Any]:
        return self.rpc("sutra_codex_finish_run", {
            "p_worker_id": worker_id, "p_run_id": run_id, "p_lease_token": lease_token,
            "p_success": success,
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

    def company_status(self) -> dict[str, int]:
        projects = self.request("projects?select=id&status=in.(proposed,approved,active,paused)")
        tasks = self.request("tasks?select=id&status=in.(backlog,ready,in_progress,blocked,review)")
        approvals = self.request("approvals?select=id&status=eq.pending")
        if not all(isinstance(rows, list) for rows in (projects, tasks, approvals)):
            raise IntegrationError("Supabase returned an invalid company status response")
        return {"projects": len(projects), "open_tasks": len(tasks), "pending_approvals": len(approvals)}

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
    lowered = text.lower()
    if re.fullmatch(r"\s*(?:(?:ceo[, :]\s*)?(?:show|list)\s+(?:my\s+)?approvals?|what\s+needs\s+my\s+approval)\s*[?.!]*\s*", lowered):
        return FounderCommand("approvals", text.strip())
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
            return FounderResponse(
                "Sutra company status\n"
                f"Projects: {status['projects']}\n"
                f"Open tasks: {status['open_tasks']}\n"
                f"Pending approvals: {status['pending_approvals']}"
            )
        if command.kind == "approvals":
            try:
                approvals = self.store.founder_pending_approvals(user_id)
            except IntegrationError:
                return FounderResponse("I couldn't load the founder approval queue. No approval was changed; check the database connection and try again.")
            if not approvals:
                return FounderResponse("No pending founder approval requests.")
            lines = [f"Founder approvals ({len(approvals)} shown):"]
            keyboard: list[list[dict[str, str]]] = []
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
        return FounderResponse(
            "I can report company status, list founder approvals, prepare a budgeted proposal, or decide an approval.\n"
            "Use: CEO, give me company status.\n"
            "Use: CEO, show my approvals.\n"
            "Use: retry PM review <run-id>.\n"
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
