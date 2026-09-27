"""Signature verification and allowlisted normalization for GitHub webhooks."""

from __future__ import annotations

import hashlib
import hmac
import re
import uuid
from typing import Any


UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}")
SHA_RE = re.compile(r"[0-9a-fA-F]{40}")
PR_URL_RE = re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*", re.IGNORECASE)
RUN_URL_RE = re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[1-9][0-9]*", re.IGNORECASE)
CLOSING_ISSUE_RE = re.compile(r"\b(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?)\s+#([1-9][0-9]*)\b", re.IGNORECASE)


def verify_github_signature(secret: str, body: bytes, signature: str) -> bool:
    if not secret or not isinstance(body, bytes) or not isinstance(signature, str):
        return False
    if not re.fullmatch(r"sha256=[0-9a-f]{64}", signature):
        return False
    expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


def _positive_int(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 2_147_483_647:
        return None
    return value


def normalize_github_event(event_name: str, repository: str, payload: Any) -> dict[str, Any] | None:
    """Discard unrelated events and return only bounded fields used by SQL policy."""
    if not isinstance(payload, dict) or not isinstance(repository, str):
        return None
    repo = payload.get("repository")
    if not isinstance(repo, dict) or not isinstance(repo.get("full_name"), str):
        return None
    if repo["full_name"].casefold() != repository.casefold():
        return None

    if event_name == "pull_request":
        action = payload.get("action")
        if action not in {"opened", "edited", "synchronize", "reopened", "closed"}:
            return None
        pr = payload.get("pull_request")
        if not isinstance(pr, dict):
            return None
        number = _positive_int(pr.get("number"))
        url = pr.get("html_url")
        body = pr.get("body")
        merged = pr.get("merged")
        head, base = pr.get("head"), pr.get("base")
        if number is None or not isinstance(url, str) or not PR_URL_RE.fullmatch(url):
            return None
        if not url.casefold().startswith(f"https://github.com/{repository}/pull/".casefold()):
            return None
        if not isinstance(body, str) or len(body) > 20_000 or not isinstance(merged, bool):
            return None
        if not isinstance(head, dict) or not isinstance(head.get("sha"), str) or not SHA_RE.fullmatch(head["sha"]):
            return None
        if not isinstance(base, dict) or base.get("ref") != "main":
            return None
        task_matches = re.findall(r"(?im)^\s*Sutra-Task-ID:\s*(" + UUID_RE.pattern + r")\s*$", body)
        issue_matches = CLOSING_ISSUE_RE.findall(body)
        if len(task_matches) != 1 or len(issue_matches) != 1:
            return None
        try:
            task_id = str(uuid.UUID(task_matches[0]))
            issue_number = _positive_int(int(issue_matches[0]))
        except (ValueError, TypeError):
            return None
        if issue_number is None:
            return None
        return {
            "kind": "pull_request", "action": action, "task_id": task_id,
            "issue_number": issue_number, "pull_request_number": number,
            "pull_request_url": url, "head_sha": head["sha"].lower(),
            "merged": merged, "base_ref": "main",
        }

    if event_name == "workflow_run":
        if payload.get("action") != "completed":
            return None
        run = payload.get("workflow_run")
        if not isinstance(run, dict) or run.get("name") != "CI" or run.get("status") != "completed":
            return None
        conclusion = run.get("conclusion")
        allowed_conclusions = {"success", "failure", "cancelled", "timed_out", "action_required", "stale", "skipped", "neutral"}
        if conclusion not in allowed_conclusions:
            return None
        run_sha = run.get("head_sha")
        url = run.get("html_url")
        run_id = _positive_int(run.get("id"))
        if not isinstance(run_sha, str) or not SHA_RE.fullmatch(run_sha):
            return None
        if (run_id is None or not isinstance(url, str) or not RUN_URL_RE.fullmatch(url)
                or not url.casefold().startswith(f"https://github.com/{repository}/actions/runs/".casefold())):
            return None
        prs = run.get("pull_requests")
        if not isinstance(prs, list) or len(prs) > 30:
            return None
        pull_requests = []
        for item in prs:
            head = item.get("head") if isinstance(item, dict) else None
            number = _positive_int(item.get("number")) if isinstance(item, dict) else None
            sha = head.get("sha") if isinstance(head, dict) else None
            if number is None or not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
                return None
            pull_requests.append({"number": number, "head_sha": sha.lower()})
        if len({item["number"] for item in pull_requests}) != len(pull_requests):
            return None
        return {
            "kind": "workflow_run", "workflow_name": "CI", "conclusion": conclusion,
            "run_url": url, "run_id": run_id, "head_sha": run_sha.lower(),
            "pull_requests": pull_requests,
        }
    return None
