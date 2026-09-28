"""Poll repository-authoritative PR and CI evidence without public webhooks."""

from __future__ import annotations

import json
import logging
import uuid
from typing import Any

from .github_dispatch import GitHubAPIError, GitHubIssues
from .github_webhook import normalize_github_event
from .runtime import IntegrationError

logger = logging.getLogger(__name__)


class GitHubEvidencePoller:
    """Persist bounded GitHub API evidence through Sutra's audited RPC."""

    def __init__(self, store: Any, github: GitHubIssues,
                 worker_id: str = "sutra-github-webhook-poll0001"):
        if not worker_id.startswith("sutra-github-webhook-"):
            raise ValueError("Invalid GitHub evidence poller worker ID")
        self.store = store
        self.github = github
        self.worker_id = worker_id

    def poll_once(self) -> int:
        recorded = 0
        repository = self.github.repository
        try:
            pull_requests = self.github.recent_pull_requests()
        except GitHubAPIError as exc:
            logger.warning("github_evidence_request_failed endpoint=pull_requests error_code=%s", exc.code)
            raise
        for pull_request in pull_requests:
            action = "closed" if pull_request.get("state") == "closed" else "synchronize"
            event = {"action": action, "repository": {"full_name": repository},
                     "pull_request": {**pull_request,
                                      "merged": bool(pull_request.get("merged_at"))}}
            normalized = normalize_github_event("pull_request", repository, event)
            if normalized is not None:
                self._record("pull_request", normalized)
                recorded += 1

        try:
            workflow_runs = self.github.recent_completed_workflows()
        except GitHubAPIError as exc:
            logger.warning("github_evidence_request_failed endpoint=workflow_runs error_code=%s", exc.code)
            raise
        for workflow_run in workflow_runs:
            event = {"action": "completed", "repository": {"full_name": repository},
                     "workflow_run": workflow_run}
            normalized = normalize_github_event("workflow_run", repository, event)
            if normalized is not None:
                self._record("workflow_run", normalized)
                recorded += 1
        return recorded

    def _record(self, event_name: str, event: dict[str, Any]) -> None:
        # Stable IDs make repeated API polling idempotent in the existing webhook
        # event ledger. Only the allowlisted normalized evidence is persisted.
        canonical = json.dumps(event, sort_keys=True, separators=(",", ":"))
        delivery_id = str(uuid.uuid5(uuid.NAMESPACE_URL,
                                     f"sutra:{self.github.repository}:{event_name}:{canonical}"))
        result = self.store.rpc("sutra_record_github_webhook_event", {
            "p_worker_id": self.worker_id,
            "p_delivery_id": delivery_id,
            "p_repository": self.github.repository,
            "p_event_name": event_name,
            "p_event": event,
        })
        if not isinstance(result, dict):
            raise IntegrationError("GitHub evidence RPC returned a malformed result")


__all__ = ["GitHubAPIError", "GitHubEvidencePoller"]
