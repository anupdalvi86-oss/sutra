"""Opt-in, budget-reserved customer email delivery through Resend.

The worker is intentionally disabled unless both an enable flag and live-send
mode are set. Ambiguous provider outcomes remain unknown and are never retried.
"""

from __future__ import annotations

import json
import logging
import re
import threading
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

from .runtime import IntegrationError, open_outbound_request

logger = logging.getLogger(__name__)

_IDEMPOTENCY_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")
_MESSAGE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
_EMAIL = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


@dataclass(frozen=True)
class EmailDeliveryResult:
    outcome: str  # sent, failed, or unknown
    provider_message_id: str | None = None
    error_code: str | None = None


class ResendEmailProvider:
    """Single-recipient plain-text email client; never logs payloads or headers."""

    endpoint = "https://api.resend.com/emails"

    def __init__(self, api_key: str, from_address: str,
                 opener: Callable[[urllib.request.Request, float], Any] = open_outbound_request,
                 timeout: float = 8.0):
        if not isinstance(api_key, str) or not api_key.strip():
            raise ValueError("Resend API key is required")
        if (not isinstance(from_address, str) or len(from_address.strip()) > 320
                or not _EMAIL.fullmatch(from_address.strip().split("<")[-1].rstrip(">").strip())):
            raise ValueError("A valid sender address is required")
        if not 1 <= timeout <= 30:
            raise ValueError("Email provider timeout is out of range")
        self._api_key = api_key.strip()
        self.from_address = from_address.strip()
        self._opener = opener
        self.timeout = timeout

    def send(self, action: dict[str, Any]) -> EmailDeliveryResult:
        recipient = action.get("recipient_email")
        subject = action.get("subject")
        body_text = action.get("body_text")
        idempotency_key = action.get("idempotency_key")
        if (not isinstance(recipient, str) or len(recipient) > 320 or not _EMAIL.fullmatch(recipient)
                or not isinstance(subject, str) or not 1 <= len(subject) <= 200
                or not isinstance(body_text, str) or not 1 <= len(body_text) <= 10000
                or not isinstance(idempotency_key, str) or not _IDEMPOTENCY_KEY.fullmatch(idempotency_key)):
            return EmailDeliveryResult("failed", error_code="invalid_action")

        payload = json.dumps({
            "from": self.from_address,
            "to": [recipient],
            "subject": subject,
            "text": body_text,
        }, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(
            self.endpoint,
            data=payload,
            method="POST",
            headers={
                "Authorization": f"Bearer {self._api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Idempotency-Key": idempotency_key,
            },
        )
        try:
            with self._opener(request, timeout=self.timeout) as response:
                raw = response.read(65_537)
                if len(raw) > 65_536:
                    return EmailDeliveryResult("unknown", error_code="provider_response_too_large")
                try:
                    result = json.loads(raw) if raw else None
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return EmailDeliveryResult("unknown", error_code="malformed_provider_response")
                message_id = result.get("id") if isinstance(result, dict) else None
                if not isinstance(message_id, str) or not _MESSAGE_ID.fullmatch(message_id):
                    return EmailDeliveryResult("unknown", error_code="malformed_provider_response")
                return EmailDeliveryResult("sent", provider_message_id=message_id)
        except urllib.error.HTTPError as exc:
            # A deterministic client rejection did not create a message. Conflict,
            # throttling, server, and timeout outcomes can follow an accepted send.
            if 400 <= exc.code < 500 and exc.code not in {408, 409, 425, 429}:
                return EmailDeliveryResult("failed", error_code="provider_rejected")
            return EmailDeliveryResult("unknown", error_code="provider_outcome_unknown")
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            # Do not retry a request whose transmission or response is ambiguous.
            return EmailDeliveryResult("unknown", error_code="provider_outcome_unknown")


class CustomerEmailDeliveryWorker:
    """Claim and deliver only database-authorized, pre-reserved email actions."""

    def __init__(self, store: Any, provider: ResendEmailProvider,
                 worker_id: str = "sutra-worker-email0001"):
        if not isinstance(worker_id, str) or not re.fullmatch(r"sutra-worker-[a-z0-9]{8,64}", worker_id):
            raise ValueError("Invalid customer email worker ID")
        self.store = store
        self.provider = provider
        self.worker_id = worker_id

    def run_once(self) -> bool:
        claim = self.store.claim_customer_email_action(self.worker_id)
        if claim is None:
            return False
        if (not isinstance(claim, dict) or not isinstance(claim.get("action_id"), str)
                or not isinstance(claim.get("claim_token"), str)
                or not isinstance(claim.get("action"), dict)):
            raise IntegrationError("Supabase returned an invalid customer email claim")
        action_id = claim["action_id"]
        claim_token = claim["claim_token"]
        ledger_id = claim.get("ledger_id")
        if not isinstance(ledger_id, str):
            raise IntegrationError("Supabase returned an invalid customer email claim")

        # Recheck consent, assignment, budget assessment, legal hold, and claim
        # immediately before the only external write.
        if not self.store.validate_customer_email_claim(self.worker_id, action_id, claim_token):
            self.store.finish_customer_email_action(
                self.worker_id, action_id, claim_token, "failed", None,
                "authorization_revoked", 0, True,
            )
            return True

        result = self.provider.send(claim["action"])
        actual_cost = 0 if result.outcome == "failed" else None
        cost_known = result.outcome == "failed"
        self.store.finish_customer_email_action(
            self.worker_id, action_id, claim_token, result.outcome,
            result.provider_message_id, result.error_code,
            actual_cost, cost_known,
        )
        logger.info("customer_email_delivery_finished action_id=%s outcome=%s error_code=%s",
                    action_id, result.outcome, result.error_code or "none")
        return True

    def run(self, stop: threading.Event, idle_seconds: float = 30.0) -> None:
        while not stop.is_set():
            try:
                worked = self.run_once()
            except (IntegrationError, OSError, ValueError) as exc:
                logger.warning("customer_email_delivery_cycle_failed error_type=%s", type(exc).__name__)
                worked = False
            if not worked:
                stop.wait(idle_seconds)
