"""Offline, synthetic-only manual test-plan drafts behind Supabase RLS."""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any

from .runtime import IntegrationError, open_outbound_request


class DraftRequestError(ValueError):
    """A bounded, user-correctable draft request is invalid."""


class DraftNotFound(LookupError):
    """The draft does not exist or is not visible under the caller's RLS scope."""


class _LoopbackOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, new_url):
        parsed = urllib.parse.urlsplit(new_url)
        if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
            raise urllib.error.URLError("Local Supabase redirect left loopback")
        return super().redirect_request(request, fp, code, msg, headers, new_url)


def _compact_size(value: Any) -> int:
    try:
        return len(json.dumps(value, separators=(",", ":"), allow_nan=False).encode())
    except (TypeError, ValueError) as exc:
        raise DraftRequestError("Draft data must be JSON serializable") from exc


def validate_draft(value: Any) -> dict[str, Any]:
    """Validate inert manual-review steps; this format never contains executable code."""
    fields = {"kind", "executable", "verification", "framework", "language", "steps"}
    if not isinstance(value, dict) or set(value) != fields:
        raise DraftRequestError("Draft must contain only the supported manual-plan fields")
    language = value.get("language")
    if (value.get("kind") != "manual_test_plan" or value.get("executable") is not False
            or value.get("verification") != "unverified" or value.get("framework") != "playwright"
            or not isinstance(language, str) or language not in {"javascript", "typescript", "python"}):
        raise DraftRequestError("Draft must remain an unverified, non-executable manual plan")
    steps = value.get("steps")
    if not isinstance(steps, list) or not 1 <= len(steps) <= 20:
        raise DraftRequestError("Draft must have between 1 and 20 manual steps")
    for index, step in enumerate(steps, start=1):
        if not isinstance(step, dict) or set(step) != {"id", "instruction", "expected_observation"}:
            raise DraftRequestError("Each step must contain only its ID, instruction, and expected observation")
        if (step.get("id") != f"step-{index}"
                or not isinstance(step.get("instruction"), str)
                or not 1 <= len(step["instruction"]) <= 500
                or not isinstance(step.get("expected_observation"), str)
                or not 1 <= len(step["expected_observation"]) <= 500):
            raise DraftRequestError("Draft steps have invalid or oversized text")
    if _compact_size(value) > 24_000:
        raise DraftRequestError("Draft exceeds 24000 bytes")
    return value


def generate_synthetic_draft(payload: Any) -> dict[str, Any]:
    """Turn synthetic scenario statements into non-executable manual review steps."""
    if not isinstance(payload, dict) or set(payload) - {"scenario", "context", "language", "framework"}:
        raise DraftRequestError("Request accepts only scenario, context, language, and framework")
    scenario = payload.get("scenario")
    context = payload.get("context", "")
    language = payload.get("language", "typescript")
    framework = payload.get("framework", "playwright")
    if not isinstance(scenario, str) or not 8 <= len(scenario.strip()) <= 12_000:
        raise DraftRequestError("Scenario must be between 8 and 12000 characters")
    if not isinstance(context, str) or len(context.encode()) > 16_000:
        raise DraftRequestError("Context must be text up to 16000 bytes")
    if (not isinstance(language, str) or language not in {"javascript", "typescript", "python"}
            or framework != "playwright"):
        raise DraftRequestError("Only Playwright manual plans in JavaScript, TypeScript, or Python are supported")

    statements = [item.strip(" \t-*\u2022") for item in re.split(r"\n+|(?<=[.!?])\s+", scenario.strip())]
    statements = [item for item in statements if item]
    if not 1 <= len(statements) <= 20 or any(len(item) > 500 for item in statements):
        raise DraftRequestError("Scenario must produce between 1 and 20 statements of at most 500 characters")
    steps = [
        {
            "id": f"step-{index}",
            "instruction": f"Manually review this scenario statement: {statement}",
            "expected_observation": "A reviewer records whether the stated behavior is observed; no browser is launched.",
        }
        for index, statement in enumerate(statements, start=1)
    ]
    result = {
        "draft": {
            "kind": "manual_test_plan",
            "executable": False,
            "verification": "unverified",
            "framework": framework,
            "language": language,
            "steps": steps,
        },
        "rationale": [
            {"step_id": step["id"], "scenario_excerpt": statement[:160],
             "relation": "This manual review step reflects one supplied scenario statement."}
            for step, statement in zip(steps, statements)
        ],
        "warnings": [
            "Synthetic offline prototype; use synthetic, non-sensitive examples only.",
            "Not AI-generated, provider-verified, executable, or browser-tested; reviewer validation is required.",
        ],
    }
    validate_draft(result["draft"])
    if _compact_size(result["rationale"]) > 16_000 or _compact_size(result["warnings"]) > 8_000:
        raise DraftRequestError("Generated rationale or warnings exceed the supported size")
    return result


class UserScopedSupabase:
    """Use the caller's JWT for auth and every REST request so Supabase RLS applies."""

    def __init__(self, url: str, anon_key: str, timeout: float = 8.0,
                 allow_local_http: bool = False):
        parsed = urllib.parse.urlsplit(url)
        local_http = (parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"})
        if ((parsed.scheme != "https" and not (local_http and allow_local_http))
                or not parsed.hostname or parsed.username or parsed.password
                or parsed.query or parsed.fragment):
            raise ValueError("Draft API requires an HTTPS Supabase URL or explicit local loopback HTTP")
        if not anon_key or "\n" in anon_key or "\r" in anon_key:
            raise ValueError("Draft API requires the Supabase publishable/anon key")
        self.url = url.rstrip("/")
        self.anon_key = anon_key
        self.timeout = timeout
        self.local_http = local_http

    def _request(self, url: str, access_token: str, method: str = "GET",
                 payload: dict[str, Any] | None = None) -> Any:
        if (not access_token or len(access_token) > 8192 or "\r" in access_token
                or "\n" in access_token):
            raise DraftRequestError("A valid Supabase user access token is required")
        body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode() if payload is not None else None
        request = urllib.request.Request(url, data=body, method=method, headers={
            "apikey": self.anon_key,
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Prefer": "return=representation",
        })
        try:
            if self.local_http:
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _LoopbackOnlyRedirect())
                response_context = opener.open(request, timeout=self.timeout)
            else:
                response_context = open_outbound_request(request, timeout=self.timeout)
            with response_context as response:
                raw = response.read(64_001)
                if len(raw) > 64_000:
                    raise IntegrationError("Draft service response exceeded the size limit")
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                raise DraftRequestError("Supabase user authentication failed") from exc
            if exc.code == 404:
                raise DraftNotFound from exc
            raise IntegrationError("Supabase draft request failed") from exc
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise IntegrationError("Supabase draft request failed") from exc

    def authenticate(self, access_token: str) -> str:
        result = self._request(f"{self.url}/auth/v1/user", access_token)
        if not isinstance(result, dict) or not isinstance(result.get("id"), str):
            raise DraftRequestError("Supabase returned an invalid user identity")
        try:
            return str(uuid.UUID(result["id"]))
        except ValueError as exc:
            raise DraftRequestError("Supabase returned an invalid user identity") from exc

    def create(self, access_token: str, owner_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        row = {**payload, "owner_id": owner_id, "tenant_id": owner_id}
        result = self._request(f"{self.url}/rest/v1/test_drafts", access_token, "POST", row)
        if not isinstance(result, list) or len(result) != 1 or not isinstance(result[0], dict):
            raise IntegrationError("Supabase returned an invalid draft")
        return result[0]

    def get(self, access_token: str, draft_id: str) -> dict[str, Any]:
        query = urllib.parse.urlencode({
            "select": "id,scenario,context,framework,language,test_draft,rationale,warnings,generator_kind,generator_name,generator_version,created_at",
            "id": f"eq.{draft_id}", "limit": "1",
        })
        result = self._request(f"{self.url}/rest/v1/test_drafts?{query}", access_token)
        if not isinstance(result, list) or not result:
            raise DraftNotFound
        draft = result[0]
        review_query = urllib.parse.urlencode({
            "select": "id,decision,edited_draft,comment,created_at",
            "draft_id": f"eq.{draft_id}", "order": "created_at.desc", "limit": "50",
        })
        reviews = self._request(f"{self.url}/rest/v1/test_draft_reviews?{review_query}", access_token)
        if not isinstance(reviews, list):
            raise IntegrationError("Supabase returned invalid review history")
        return {**draft, "reviews": reviews}

    def review(self, access_token: str, owner_id: str, draft_id: str,
               payload: dict[str, Any]) -> dict[str, Any]:
        row = {**payload, "tenant_id": owner_id, "reviewer_id": owner_id, "draft_id": draft_id}
        result = self._request(f"{self.url}/rest/v1/test_draft_reviews", access_token, "POST", row)
        if not isinstance(result, list) or len(result) != 1 or not isinstance(result[0], dict):
            raise IntegrationError("Supabase returned an invalid review")
        return result[0]

    def delete(self, access_token: str, draft_id: str) -> dict[str, Any]:
        query = urllib.parse.urlencode({"id": f"eq.{draft_id}", "select": "id"})
        result = self._request(
            f"{self.url}/rest/v1/test_drafts?{query}", access_token, "DELETE",
        )
        if not isinstance(result, list) or len(result) != 1 or result[0].get("id") != draft_id:
            raise DraftNotFound
        return {"id": draft_id, "deleted": True}


class DraftService:
    def __init__(self, store: UserScopedSupabase):
        self.store = store

    @staticmethod
    def _draft_id(value: str) -> str:
        try:
            return str(uuid.UUID(value))
        except (TypeError, ValueError) as exc:
            raise DraftRequestError("Draft ID must be a UUID") from exc

    def create(self, access_token: str, payload: Any) -> dict[str, Any]:
        generated = generate_synthetic_draft(payload)
        owner_id = self.store.authenticate(access_token)
        request = payload
        row = self.store.create(access_token, owner_id, {
            "scenario": request["scenario"].strip(), "context": request.get("context", ""),
            "framework": request.get("framework", "playwright"), "language": request.get("language", "typescript"),
            "test_draft": generated["draft"], "rationale": generated["rationale"],
            "warnings": generated["warnings"], "generator_kind": "synthetic",
            "generator_name": "sutra-offline-synthetic", "generator_version": "1",
        })
        return row

    def get(self, access_token: str, draft_id: str) -> dict[str, Any]:
        draft_id = self._draft_id(draft_id)
        self.store.authenticate(access_token)
        return self.store.get(access_token, draft_id)

    def review(self, access_token: str, draft_id: str, payload: Any) -> dict[str, Any]:
        draft_id = self._draft_id(draft_id)
        if not isinstance(payload, dict) or set(payload) - {"decision", "edited_draft", "comment"}:
            raise DraftRequestError("Review accepts only decision, edited_draft, and comment")
        decision = payload.get("decision")
        comment = payload.get("comment", "")
        if not isinstance(decision, str) or decision not in {"accept", "edit", "reject"}:
            raise DraftRequestError("Decision must be accept, edit, or reject")
        if not isinstance(comment, str) or len(comment.encode()) > 2_000:
            raise DraftRequestError("Review comment must be text up to 2000 bytes")
        edited = payload.get("edited_draft")
        if decision == "edit":
            edited = validate_draft(edited)
        elif edited is not None:
            raise DraftRequestError("edited_draft is allowed only with the edit decision")
        owner_id = self.store.authenticate(access_token)
        stored = self.store.get(access_token, draft_id)
        if not stored:
            raise DraftNotFound
        row = {"decision": decision, "comment": comment, "edited_draft": edited}
        return self.store.review(access_token, owner_id, draft_id, row)

    def delete(self, access_token: str, draft_id: str) -> dict[str, Any]:
        draft_id = self._draft_id(draft_id)
        self.store.authenticate(access_token)
        return self.store.delete(access_token, draft_id)
