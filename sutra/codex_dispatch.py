"""Sign and verify the narrow GitHub issue handoff to the Codex runner."""

from __future__ import annotations

import hashlib
import hmac
import json
import re
import uuid
from typing import Any


_TASK_MARKER = re.compile(r"(?m)^<!-- sutra-task-id:([0-9a-f-]{36}) -->$")
_SIGNATURE_MARKER = re.compile(
    r"(?m)^<!-- sutra-codex-dispatch:v1 task=([0-9a-f-]{36}) number=([1-9][0-9]*) signature=([a-f0-9]{64}) -->$"
)
_REPOSITORY = re.compile(r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}")


def _signature(secret: str, repository: str, task_id: str, issue_number: int,
               title: str, body: str) -> str:
    if not isinstance(secret, str) or len(secret) < 32:
        raise ValueError("Codex dispatch signing secret must contain at least 32 characters")
    data = json.dumps(
        {
            "version": 1,
            "repository": repository.lower(),
            "task_id": task_id,
            "issue_number": issue_number,
            "title": title,
            "body": body,
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hmac.new(secret.encode(), data, hashlib.sha256).hexdigest()


def seal_codex_issue_body(repository: str, task_id: str, issue_number: int,
                          title: str, unsigned_body: str, secret: str) -> str:
    """Bind an approved task's exact body and number to the GitHub webhook secret."""
    if (not isinstance(task_id, str) or not isinstance(repository, str)
            or not _REPOSITORY.fullmatch(repository)):
        raise ValueError("Invalid approved GitHub task issue")
    if any(part in {".", ".."} for part in repository.split("/")):
        raise ValueError("Invalid approved GitHub task issue")
    try:
        task_id = str(uuid.UUID(task_id))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ValueError("Invalid approved GitHub task issue") from exc
    if (isinstance(issue_number, bool) or not isinstance(issue_number, int) or issue_number < 1
            or not isinstance(title, str) or not title.startswith("Sutra: ") or len(title) > 320
            or not isinstance(unsigned_body, str) or len(unsigned_body) > 20_000
            or _SIGNATURE_MARKER.search(unsigned_body)):
        raise ValueError("Invalid approved GitHub task issue")
    if len(_TASK_MARKER.findall(unsigned_body)) != 1 or f"<!-- sutra-task-id:{task_id} -->" not in unsigned_body:
        raise ValueError("Task marker does not match the approved task")
    signature = _signature(secret, repository, task_id, issue_number, title, unsigned_body)
    return f"{unsigned_body.rstrip()}\n\n<!-- sutra-codex-dispatch:v1 task={task_id} number={issue_number} signature={signature} -->"


def verify_codex_issue_event(event: Any, secret: str, repository: str) -> dict[str, Any]:
    """Accept only an owner-authored, open, signed issue edit from Sutra's dispatcher."""
    if (not isinstance(repository, str) or not _REPOSITORY.fullmatch(repository)
            or any(part in {".", ".."} for part in repository.split("/"))):
        raise ValueError("Malformed configured repository")
    if not isinstance(event, dict) or event.get("action") != "edited":
        raise ValueError("Only the signed issue-edit event can start Codex")
    repo = event.get("repository")
    issue = event.get("issue")
    sender = event.get("sender")
    if not isinstance(repo, dict) or not isinstance(issue, dict) or not isinstance(sender, dict):
        raise ValueError("Malformed GitHub issue event")
    owner = repo.get("owner")
    owner_login = owner.get("login") if isinstance(owner, dict) else None
    issue_user = issue.get("user")
    sender_login = sender.get("login")
    issue_login = issue_user.get("login") if isinstance(issue_user, dict) else None
    repo_name = repo.get("full_name")
    if (not isinstance(repo_name, str) or repo_name.lower() != repository.lower()
            or not isinstance(owner_login, str) or not isinstance(sender_login, str)
            or not isinstance(issue_login, str)
            or sender_login.lower() != owner_login.lower()
            or issue_login.lower() != owner_login.lower()
            or issue.get("state") != "open"):
        raise ValueError("GitHub task issue is not an open owner-authored issue in this repository")
    title, body, number = issue.get("title"), issue.get("body"), issue.get("number")
    if (not isinstance(title, str) or not title.startswith("Sutra: ") or len(title) > 320
            or not isinstance(body, str) or len(body) > 22_000
            or isinstance(number, bool) or not isinstance(number, int) or number < 1):
        raise ValueError("Malformed signed GitHub task issue")
    task_markers = list(_TASK_MARKER.finditer(body))
    signature_markers = list(_SIGNATURE_MARKER.finditer(body))
    if len(task_markers) != 1 or len(signature_markers) != 1:
        raise ValueError("GitHub task issue must contain one task marker and one signature")
    task_id = task_markers[0].group(1)
    signature_marker = signature_markers[0]
    try:
        task_id = str(uuid.UUID(task_id))
    except ValueError as exc:
        raise ValueError("Malformed Sutra task ID") from exc
    if (signature_marker.group(1) != task_id or int(signature_marker.group(2)) != number
            or body[signature_marker.end():].strip()):
        raise ValueError("Signed GitHub task issue metadata does not match")
    unsigned_body = body[:signature_marker.start()].rstrip()
    expected = _signature(secret, repository, task_id, number, title, unsigned_body)
    if not hmac.compare_digest(signature_marker.group(3), expected):
        raise ValueError("GitHub task issue signature is invalid")
    return {"task_id": task_id, "issue_number": number}
