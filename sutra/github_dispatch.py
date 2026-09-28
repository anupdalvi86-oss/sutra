"""Idempotent, founder-approval-gated handoff of engineering tasks to GitHub."""

from __future__ import annotations

import json
import logging
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any

from .codex_dispatch import seal_codex_issue_body
from .runtime import IntegrationError, open_outbound_request

logger = logging.getLogger(__name__)
_PERSISTABLE_GITHUB_ERROR_CODES = frozenset({
    "github_api_error",
    "github_permission_denied",
    "github_network_error",
    "github_rate_limited",
    "malformed_github_response",
})


class GitHubAPIError(IntegrationError):
    def __init__(self, code: str):
        super().__init__("GitHub task issue request failed")
        self.code = code


class GitHubIssues:
    """Uses a narrowly scoped server token; task text and secrets never mix."""

    def __init__(self, token: str, repository: str, task_signing_secret: str, timeout: float = 12.0):
        if not token or not isinstance(repository, str) or not re.fullmatch(
            r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}", repository
        ) or any(segment in {".", ".."} for segment in repository.split("/")):
            raise ValueError("GitHub token and owner/repository are required")
        if not isinstance(task_signing_secret, str) or len(task_signing_secret) < 32:
            raise ValueError("GitHub task signing secret must contain at least 32 characters")
        self.token = token
        self.repository = repository
        self.task_signing_secret = task_signing_secret
        self.timeout = timeout

    def _request(self, path: str, method: str = "GET", payload: dict[str, Any] | None = None) -> Any:
        if not path.startswith("/") or ".." in path:
            raise GitHubAPIError("github_api_error")
        body = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(
            "https://api.github.com" + path,
            data=body,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "User-Agent": "sutra-task-dispatcher",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with open_outbound_request(request, timeout=self.timeout) as response:
                raw = response.read(1_000_001)
                if len(raw) > 1_000_000:
                    raise GitHubAPIError("malformed_github_response")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            if exc.code in {403, 429} and exc.headers.get("X-RateLimit-Remaining") == "0":
                raise GitHubAPIError("github_rate_limited") from exc
            # Categorize only GitHub's exact generic messages. Never persist or log
            # the response body: GitHub can echo request content there.
            if exc.code == 403:
                try:
                    payload = json.loads(exc.read(16_384))
                except (OSError, json.JSONDecodeError):
                    payload = None
                message = payload.get("message") if isinstance(payload, dict) else None
                if message == "Resource not accessible by personal access token":
                    code = "github_permission_denied"
                elif message == "Must have admin rights to Repository.":
                    code = "github_permission_denied"
                else:
                    code = "github_forbidden"
                raise GitHubAPIError(code) from exc
            raise GitHubAPIError(f"github_http_{exc.code}") from exc
        except GitHubAPIError:
            raise
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise GitHubAPIError("github_network_error") from exc

    def open_task_issues(self) -> list[dict[str, Any]]:
        """Read open Sutra task issues for the private polling Codex dispatcher."""
        # The API response is capped at 1 MB in _request; 20 leaves headroom
        # for long task bodies while retaining a bounded runner candidate set.
        path = f"/repos/{self.repository}/issues?state=open&per_page=20&sort=created&direction=asc"
        result = self._request(path)
        if not isinstance(result, list):
            raise GitHubAPIError("malformed_github_response")
        return [issue for issue in result if isinstance(issue, dict)
                and not issue.get("pull_request")
                and isinstance(issue.get("title"), str)
                and issue["title"].startswith("Sutra: ")]

    def recent_pull_requests(self) -> list[dict[str, Any]]:
        """Read a bounded window of PR evidence for the private poller."""
        result = self._request(
            f"/repos/{self.repository}/pulls?state=all&per_page=20&sort=updated&direction=desc"
        )
        if not isinstance(result, list) or len(result) > 100:
            raise GitHubAPIError("malformed_github_response")
        return [item for item in result if isinstance(item, dict)]

    def recent_completed_workflows(self) -> list[dict[str, Any]]:
        """Read only completed CI workflows needed to reconcile PR evidence."""
        result = self._request(
            f"/repos/{self.repository}/actions/runs?status=completed&per_page=20"
        )
        if not isinstance(result, dict) or not isinstance(result.get("workflow_runs"), list):
            raise GitHubAPIError("malformed_github_response")
        runs = result["workflow_runs"]
        if len(runs) > 100:
            raise GitHubAPIError("malformed_github_response")
        return [item for item in runs if isinstance(item, dict)
                and item.get("name") == "CI" and item.get("status") == "completed"]

    def create_pull_request(self, title: str, body: str, head: str,
                            base: str = "main") -> dict[str, Any]:
        if (not isinstance(title, str) or not title.startswith("Sutra: ") or len(title) > 300
                or not isinstance(body, str) or len(body) > 10_000
                or not re.fullmatch(r"sutra/task-[0-9a-f-]{36}", head)
                or base != "main"):
            raise GitHubAPIError("malformed_pull_request_request")
        result = self._request(f"/repos/{self.repository}/pulls", "POST", {
            "title": title, "body": body, "head": head, "base": base,
        })
        if (not isinstance(result, dict) or isinstance(result.get("number"), bool)
                or not isinstance(result.get("number"), int) or result["number"] < 1
                or not isinstance(result.get("html_url"), str)
                or not result["html_url"].startswith(f"https://github.com/{self.repository}/pull/")):
            raise GitHubAPIError("malformed_github_response")
        return {"number": result["number"], "url": result["html_url"]}

    @staticmethod
    def _safe_markdown(value: str) -> str:
        # Do not let imported project content notify arbitrary GitHub users.
        return value.replace("@", "@\u200b")

    def _issue_body(self, task: dict[str, Any], task_id: str) -> str:
        title = task.get("title")
        description = task.get("description")
        criteria = task.get("acceptance_criteria")
        if not isinstance(title, str) or not title.strip() or len(title) > 300:
            raise GitHubAPIError("malformed_github_response")
        if not isinstance(description, str) or not description.strip() or len(description) > 8000:
            raise GitHubAPIError("malformed_github_response")
        if not isinstance(criteria, list) or len(criteria) > 30 or any(
            not isinstance(item, str) or not item.strip() or len(item) > 1000 for item in criteria
        ):
            raise GitHubAPIError("malformed_github_response")
        project_id = task.get("project_id")
        try:
            project_id = str(uuid.UUID(str(project_id)))
        except (ValueError, TypeError, AttributeError) as exc:
            raise GitHubAPIError("malformed_github_response") from exc
        checklist = "\n".join(f"- [ ] {self._safe_markdown(item)}" for item in criteria)
        return (
            f"<!-- sutra-task-id:{task_id} -->\n"
            "## Sutra approved engineering task\n\n"
            f"**Task ID:** `{task_id}`  \n**Project ID:** `{project_id}`\n\n"
            "### Description\n\n"
            f"{self._safe_markdown(description)}\n\n"
            "### Acceptance criteria\n\n"
            f"{checklist or '- No acceptance criteria provided'}\n\n"
            "### Governance\n\n"
            "This issue was dispatched from a founder-approved Sutra project. Record implementation, "
            "tests and review evidence in the linked pull request. In the PR description include "
            f"`Sutra-Task-ID: {task_id}` and `Closes #<this issue number>` so Sutra can attach signed merge/CI evidence. "
            "This issue does not authorize "
            "spending, deployment, external outreach or a production release."
        )

    def _existing_issue(self, task_id: str) -> dict[str, Any] | None:
        query = f'repo:{self.repository} is:issue in:body "{task_id}"'
        path = "/search/issues?" + urllib.parse.urlencode({"q": query, "per_page": 10})
        result = self._request(path)
        items = result.get("items") if isinstance(result, dict) else None
        if not isinstance(items, list):
            raise GitHubAPIError("malformed_github_response")
        for item in items:
            if not isinstance(item, dict) or item.get("pull_request"):
                continue
            body = item.get("body")
            number = item.get("number")
            url = item.get("html_url")
            title = item.get("title")
            if (isinstance(body, str) and f"<!-- sutra-task-id:{task_id} -->" in body
                    and isinstance(title, str)
                    and isinstance(number, int) and not isinstance(number, bool)
                    and isinstance(url, str)
                    and re.fullmatch(rf"https://github\.com/{re.escape(self.repository)}/issues/{number}", url, re.IGNORECASE)):
                return {"number": number, "url": url, "title": title, "body": body}
        # GitHub search indexing is eventually consistent. A dispatch retry may
        # run seconds after a successful POST but before Search sees the issue.
        # Consult the repository issue listing before creating another copy.
        result = self._request(
            f"/repos/{self.repository}/issues?state=all&per_page=100&sort=created&direction=asc"
        )
        if not isinstance(result, list) or len(result) > 100:
            raise GitHubAPIError("malformed_github_response")
        marker = f"<!-- sutra-task-id:{task_id} -->"
        for item in result:
            if not isinstance(item, dict) or item.get("pull_request"):
                continue
            body = item.get("body")
            number = item.get("number")
            url = item.get("html_url")
            title = item.get("title")
            if (isinstance(body, str) and marker in body and isinstance(title, str)
                    and isinstance(number, int) and not isinstance(number, bool)
                    and isinstance(url, str)
                    and re.fullmatch(rf"https://github\.com/{re.escape(self.repository)}/issues/{number}", url, re.IGNORECASE)):
                return {"number": number, "url": url, "title": title, "body": body}
        return None

    def create_or_find_issue(self, task: dict[str, Any]) -> dict[str, Any]:
        try:
            task_id = str(uuid.UUID(str(task.get("task_id"))))
        except (ValueError, TypeError, AttributeError) as exc:
            raise GitHubAPIError("malformed_github_response") from exc
        # Search by a stable full UUID marker before create. If a worker lost its
        # DB lease after GitHub accepted a request, the next claim reuses the issue.
        title = task.get("title")
        if not isinstance(title, str) or not title.strip() or len(title) > 300:
            raise GitHubAPIError("malformed_github_response")
        safe_title = self._safe_markdown(title.strip())
        issue_title = f"Sutra: {safe_title}"
        unsigned_body = self._issue_body(task, task_id)
        logger.warning("github_task_issue_lookup_started task_id=%s", task_id)
        existing = self._existing_issue(task_id)
        logger.warning(
            "github_task_issue_lookup_completed task_id=%s issue_number=%s",
            task_id, existing["number"] if existing else "none",
        )
        if existing:
            existing_signed_body = seal_codex_issue_body(
                self.repository, task_id, existing["number"], issue_title,
                unsigned_body, self.task_signing_secret,
            )
            if (existing["title"] != issue_title
                    or existing["body"] not in {unsigned_body, existing_signed_body}):
                # Do not sign or reuse content changed after its database-approved dispatch.
                raise GitHubAPIError("malformed_github_response")
            result = existing
        else:
            logger.warning("github_task_issue_create_started task_id=%s", task_id)
            result = self._request(
                f"/repos/{self.repository}/issues",
                "POST",
                {"title": issue_title, "body": unsigned_body},
            )
        if not isinstance(result, dict):
            raise GitHubAPIError("malformed_github_response")
        number = result.get("number")
        url = result.get("url") if existing else result.get("html_url")
        if (not isinstance(number, int) or isinstance(number, bool) or number < 1
                or not isinstance(url, str)
                or not re.fullmatch(rf"https://github\.com/{re.escape(self.repository)}/issues/{number}", url, re.IGNORECASE)):
            raise GitHubAPIError("malformed_github_response")
        signed_body = seal_codex_issue_body(
            self.repository, task_id, number, issue_title, unsigned_body, self.task_signing_secret
        )
        if existing and existing["body"] == signed_body:
            logger.warning("github_task_issue_already_signed task_id=%s issue_number=%s", task_id, number)
            return {"number": number, "url": url}
        logger.warning("github_task_issue_sign_started task_id=%s issue_number=%s", task_id, number)
        updated = self._request(
            f"/repos/{self.repository}/issues/{number}", "PATCH", {"body": signed_body}
        )
        if (not isinstance(updated, dict) or updated.get("number") != number
                or updated.get("title") != issue_title or updated.get("body") != signed_body
                or updated.get("html_url") != url):
            raise GitHubAPIError("malformed_github_response")
        logger.warning("github_task_issue_sign_completed task_id=%s issue_number=%s", task_id, number)
        return {"number": number, "url": url}


class GitHubTaskDispatcher:
    def __init__(self, store: Any, issues: GitHubIssues, worker_id: str | None = None):
        self.store = store
        self.issues = issues
        self.worker_id = worker_id or "sutra-github-worker-" + uuid.uuid4().hex
        if not re.fullmatch(r"sutra-github-worker-[a-z0-9]{8,64}", self.worker_id):
            raise ValueError("Invalid GitHub dispatcher worker ID")

    def run_once(self) -> bool:
        task = self.store.claim_github_task(self.worker_id)
        if task is None:
            return False
        if not isinstance(task, dict):
            raise IntegrationError("Supabase returned an invalid GitHub task claim")
        task_id, lease_token = task.get("task_id"), task.get("lease_token")
        if not isinstance(task_id, str) or not isinstance(lease_token, str):
            raise IntegrationError("Supabase returned a malformed GitHub task lease")
        started = time.monotonic()
        logger.warning("github_task_dispatch_started task_id=%s", task_id)
        try:
            issue = self.issues.create_or_find_issue(task)
            logger.warning(
                "github_task_issue_ready task_id=%s issue_number=%s elapsed_ms=%d",
                task_id, issue["number"], int((time.monotonic() - started) * 1000),
            )
            logger.warning("github_task_completion_record_started task_id=%s", task_id)
            self.store.complete_github_task(self.worker_id, task_id, lease_token, issue["number"], issue["url"])
            logger.warning(
                "github_task_dispatch_completed task_id=%s issue_number=%s elapsed_ms=%d",
                task_id, issue["number"], int((time.monotonic() - started) * 1000),
            )
        except GitHubAPIError as exc:
            persisted_error_code = (
                exc.code if exc.code in _PERSISTABLE_GITHUB_ERROR_CODES else "github_api_error"
            )
            logger.warning(
                "github_task_dispatch_github_failed task_id=%s error_code=%s persisted_error_code=%s elapsed_ms=%d",
                task_id, exc.code, persisted_error_code, int((time.monotonic() - started) * 1000),
            )
            try:
                self.store.fail_github_task(self.worker_id, task_id, lease_token, persisted_error_code)
            except IntegrationError as store_error:
                logger.warning(
                    "github_task_dispatch_failure_record_failed task_id=%s error_type=%s",
                    task_id, type(store_error).__name__,
                )
        except IntegrationError as exc:
            # Unknown post-create failures are recoverable through the stable
            # GitHub issue marker when Supabase reclaims the expired lease.
            logger.warning(
                "github_task_dispatch_integration_failed task_id=%s error_type=%s elapsed_ms=%d",
                task_id, type(exc).__name__, int((time.monotonic() - started) * 1000),
            )
            try:
                self.store.fail_github_task(self.worker_id, task_id, lease_token, "dispatch_unknown")
            except IntegrationError as store_error:
                logger.warning(
                    "github_task_dispatch_failure_record_failed task_id=%s error_type=%s",
                    task_id, type(store_error).__name__,
                )
        return True

    def run(self, stop: threading.Event, idle_seconds: float = 8.0) -> None:
        while not stop.is_set():
            try:
                claimed = self.run_once()
            except IntegrationError:
                claimed = False
            if not claimed:
                stop.wait(idle_seconds)
            else:
                stop.wait(2.0)
