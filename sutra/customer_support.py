"""Privacy-minimized, authenticated Zendesk ticket-state ingestion."""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import json
import re
import time
from typing import Any
import urllib.error
import urllib.parse
import urllib.request

from .runtime import IntegrationError, open_outbound_request


_TICKET_ID = re.compile(r"^[1-9][0-9]{0,18}$")
_TIMESTAMP = re.compile(r"^[0-9]{1,12}$")
_STATUSES = {"new", "open", "pending", "hold", "solved", "closed"}
_PRIORITIES = {"low", "normal", "high", "urgent"}
_ZENDESK_SUBDOMAIN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


class ZendeskTicketReader:
    """Fetch a bounded, ephemeral customer conversation for one authorized task."""

    def __init__(self, subdomain: str, agent_email: str, api_token: str,
                 opener: Any = open_outbound_request, timeout: float = 8.0):
        if not isinstance(subdomain, str) or not _ZENDESK_SUBDOMAIN.fullmatch(subdomain):
            raise ValueError("Zendesk subdomain is invalid")
        if (not isinstance(agent_email, str) or not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", agent_email)
                or not isinstance(api_token, str) or not api_token.strip()):
            raise ValueError("Zendesk agent email and API token are required")
        if not 1 <= timeout <= 30:
            raise ValueError("Zendesk timeout is out of range")
        self.base_url = f"https://{subdomain}.zendesk.com/api/v2"
        token = base64.b64encode(f"{agent_email}/token:{api_token.strip()}".encode()).decode("ascii")
        self.authorization = f"Basic {token}"
        self.opener = opener
        self.timeout = timeout

    def _get_json(self, path: str) -> dict[str, Any]:
        request = urllib.request.Request(
            f"{self.base_url}/{path.lstrip('/')}", method="GET",
            headers={"Authorization": self.authorization, "Accept": "application/json"},
        )
        try:
            with self.opener(request, timeout=self.timeout) as response:
                raw = response.read(65_537)
                if len(raw) > 65_536:
                    raise IntegrationError("Zendesk response exceeded the size limit")
                result = json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            raise IntegrationError("Zendesk ticket read failed",
                                   code="zendesk_ticket_read_rejected" if exc.code in {401, 403, 404} else "zendesk_ticket_read_failed") from exc
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            raise IntegrationError("Zendesk ticket read failed", code="zendesk_ticket_read_failed") from exc
        if not isinstance(result, dict):
            raise IntegrationError("Zendesk returned an invalid ticket response")
        return result

    def read_ticket(self, ticket_id: str) -> dict[str, Any]:
        if not isinstance(ticket_id, str) or not _TICKET_ID.fullmatch(ticket_id):
            raise ValueError("Zendesk ticket ID is invalid")
        ticket_payload = self._get_json(f"tickets/{ticket_id}.json")
        ticket = ticket_payload.get("ticket")
        if (not isinstance(ticket, dict) or str(ticket.get("id")) != ticket_id
                or ticket.get("status") not in _STATUSES):
            raise IntegrationError("Zendesk returned a mismatched or malformed ticket")
        if ticket["status"] in {"solved", "closed"}:
            raise IntegrationError("Zendesk ticket is already closed", code="zendesk_ticket_closed")
        comments_path = (f"tickets/{ticket_id}/comments.json?"
                         + urllib.parse.urlencode({"per_page": "5", "sort_order": "desc"}))
        comments_payload = self._get_json(comments_path)
        comments = comments_payload.get("comments")
        if not isinstance(comments, list):
            raise IntegrationError("Zendesk returned malformed ticket comments")
        public_comments = []
        for comment in comments[:5]:
            if not isinstance(comment, dict) or comment.get("public") is not True:
                continue
            body = comment.get("plain_body")
            if not isinstance(body, str):
                body = comment.get("body")
            if isinstance(body, str) and body.strip():
                public_comments.append(body.strip()[:2000])
        context = {
            "ticket_id": ticket_id,
            "status": ticket["status"],
            "priority": ticket.get("priority") if ticket.get("priority") in _PRIORITIES else None,
            "subject": ticket.get("subject", "")[:300] if isinstance(ticket.get("subject"), str) else "",
            "description": ticket.get("description", "")[:3000] if isinstance(ticket.get("description"), str) else "",
            "recent_public_comments": public_comments,
        }
        if not context["subject"] and not context["description"] and not public_comments:
            raise IntegrationError("Zendesk ticket contains no usable customer context")
        if len(json.dumps(context, ensure_ascii=False).encode("utf-8")) > 12_000:
            raise IntegrationError("Zendesk ticket context exceeded the size limit")
        return context


class ZendeskTaskContextProvider:
    """Authorize a task in Supabase before reading any Zendesk ticket content."""

    def __init__(self, store: Any, reader: ZendeskTicketReader):
        self.store = store
        self.reader = reader

    def __call__(self, run: dict[str, Any]) -> dict[str, Any] | None:
        task = run.get("task_artifact") if isinstance(run, dict) else None
        agent = run.get("agent") if isinstance(run, dict) else None
        if not isinstance(task, dict) or not isinstance(agent, dict) or agent.get("slug") != "sales":
            return None
        task_text = " ".join(str(task.get(field, "")) for field in ("title", "description"))
        criteria = task.get("acceptance_criteria")
        if isinstance(criteria, list):
            task_text += " " + " ".join(item for item in criteria if isinstance(item, str))
        matches = re.findall(r"Zendesk ticket ID: ([1-9][0-9]{0,18})(?![0-9])", task_text)
        if not matches:
            return None
        if len(matches) != 1:
            raise IntegrationError("Support task must identify exactly one Zendesk ticket")
        task_id, agent_id = task.get("task_id"), agent.get("id")
        if not isinstance(task_id, str) or not isinstance(agent_id, str):
            raise IntegrationError("Support task is missing its database assignment")
        authorization = self.store.rpc("sutra_authorize_zendesk_task_context", {
            "p_agent_id": agent_id, "p_task_id": task_id, "p_ticket_id": matches[0],
        })
        if authorization.get("ticket_id") != matches[0]:
            raise IntegrationError("Supabase returned mismatched support authorization")
        return self.reader.read_ticket(matches[0])


def verify_zendesk_signature(
    secret: str, timestamp: str, body: bytes, signature: str,
    *, now: float | None = None, max_age_seconds: int = 300,
) -> bool:
    """Verify Zendesk's Base64 HMAC over timestamp + exact raw request bytes."""
    if (not isinstance(secret, str) or not secret or not isinstance(body, bytes)
            or not isinstance(timestamp, str) or not _TIMESTAMP.fullmatch(timestamp)
            or not isinstance(signature, str) or len(signature) > 128
            or not 1 <= max_age_seconds <= 900):
        return False
    try:
        sent_at = int(timestamp)
    except ValueError:
        return False
    current = time.time() if now is None else now
    if abs(current - sent_at) > max_age_seconds:
        return False
    digest = hmac.new(secret.encode("utf-8"), timestamp.encode("ascii") + body, hashlib.sha256).digest()
    expected = base64.b64encode(digest).decode("ascii")
    return hmac.compare_digest(expected, signature)


def normalize_zendesk_ticket_event(payload: Any) -> dict[str, Any] | None:
    """Accept only bounded ticket metadata; discard messages and arbitrary fields."""
    if not isinstance(payload, dict) or set(payload) != {"id", "status", "priority", "updated_at"}:
        return None
    ticket_id = payload.get("id")
    if isinstance(ticket_id, int) and not isinstance(ticket_id, bool):
        ticket_id = str(ticket_id)
    if not isinstance(ticket_id, str) or not _TICKET_ID.fullmatch(ticket_id):
        return None
    status = payload.get("status")
    priority = payload.get("priority")
    if status not in _STATUSES or (priority is not None and priority not in _PRIORITIES):
        return None
    updated = payload.get("updated_at")
    if not isinstance(updated, str) or len(updated) > 40:
        return None
    try:
        parsed = dt.datetime.fromisoformat(updated.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    normalized = parsed.astimezone(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
    return {"ticket_id": ticket_id, "status": status, "priority": priority, "updated_at": normalized}
