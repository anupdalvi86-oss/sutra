"""Inert HubSpot contact upsert adapter; callers must provide a budgeted claim."""

from __future__ import annotations

import json
import logging
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

from .runtime import open_outbound_request

logger = logging.getLogger(__name__)

_EMAIL = re.compile(r"^[^\s@]{1,128}@[^\s@]{1,190}$")
_CONTACT_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


@dataclass(frozen=True)
class HubSpotSyncResult:
    outcome: str  # synced, failed or unknown
    contact_id: str | None = None
    error_code: str | None = None


class HubSpotContactClient:
    """Upsert one existing Sutra contact without logging PII or provider bodies.

    This class is not wired to an HTTP endpoint or background worker. Production
    callers must obtain the customer record from an active, budget-reserved,
    task-assigned CRM sync claim immediately before calling ``upsert_contact``.
    """

    endpoint = "https://api.hubapi.com/crm/objects/2026-09/contacts/batch/upsert"

    def __init__(self, access_token: str,
                 opener: Callable[[urllib.request.Request, float], Any] = open_outbound_request,
                 timeout: float = 8.0):
        if not isinstance(access_token, str) or not access_token.strip():
            raise ValueError("HubSpot private app token is required")
        if not 1 <= timeout <= 30:
            raise ValueError("HubSpot request timeout is out of range")
        self._access_token = access_token.strip()
        self._opener = opener
        self.timeout = timeout

    @staticmethod
    def _payload(contact: Any) -> dict[str, Any] | None:
        if not isinstance(contact, dict) or set(contact) != {"email", "name", "company"}:
            return None
        email, name, company = contact["email"], contact["name"], contact["company"]
        if (not isinstance(email, str) or len(email) > 320 or not _EMAIL.fullmatch(email)
                or email != email.strip().lower()
                or not isinstance(name, str) or not 1 <= len(name.strip()) <= 160
                or not isinstance(company, str | type(None))
                or (company is not None and len(company) > 160)):
            return None
        name_parts = name.strip().split(None, 1)
        properties = {"email": email, "firstname": name_parts[0]}
        if len(name_parts) == 2:
            properties["lastname"] = name_parts[1]
        if isinstance(company, str) and company.strip():
            properties["company"] = company.strip()
        return {"inputs": [{"id": email, "idProperty": "email", "properties": properties}]}

    def upsert_contact(self, contact: Any) -> HubSpotSyncResult:
        payload = self._payload(contact)
        if payload is None:
            return HubSpotSyncResult("failed", error_code="invalid_contact")
        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": f"Bearer {self._access_token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        try:
            with self._opener(request, timeout=self.timeout) as response:
                raw = response.read(65_537)
                if len(raw) > 65_536:
                    return HubSpotSyncResult("unknown", error_code="provider_response_too_large")
                try:
                    result = json.loads(raw) if raw else None
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return HubSpotSyncResult("unknown", error_code="malformed_provider_response")
                if not isinstance(result, dict) or result.get("status") != "COMPLETE":
                    return HubSpotSyncResult("unknown", error_code="provider_outcome_unknown")
                results = result.get("results")
                if not isinstance(results, list) or len(results) != 1 or not isinstance(results[0], dict):
                    return HubSpotSyncResult("unknown", error_code="malformed_provider_response")
                contact_id = results[0].get("id")
                if not isinstance(contact_id, str) or not _CONTACT_ID.fullmatch(contact_id):
                    return HubSpotSyncResult("unknown", error_code="malformed_provider_response")
                return HubSpotSyncResult("synced", contact_id=contact_id)
        except urllib.error.HTTPError as exc:
            if 400 <= exc.code < 500 and exc.code not in {408, 409, 425, 429}:
                return HubSpotSyncResult("failed", error_code="provider_rejected")
            return HubSpotSyncResult("unknown", error_code="provider_outcome_unknown")
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            return HubSpotSyncResult("unknown", error_code="provider_outcome_unknown")
