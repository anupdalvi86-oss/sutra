"""Privacy-minimized, authenticated Zendesk ticket-state ingestion."""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import re
import time
from typing import Any


_TICKET_ID = re.compile(r"^[1-9][0-9]{0,18}$")
_TIMESTAMP = re.compile(r"^[0-9]{1,12}$")
_STATUSES = {"new", "open", "pending", "hold", "solved", "closed"}
_PRIORITIES = {"low", "normal", "high", "urgent"}


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
