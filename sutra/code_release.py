"""Founder-authorized squash merge worker for reviewed Sutra Developer PRs."""

from __future__ import annotations

import logging
import re
import threading
from typing import Any

from .github_dispatch import GitHubAPIError, GitHubIssues
from .github_evidence_polling import GitHubEvidencePoller
from .runtime import IntegrationError

logger = logging.getLogger(__name__)

_SAFE_RELEASE_ERRORS = {
    "authorization_revoked", "github_api_error", "github_closed_unmerged",
    "github_merge_conflict", "github_network_error", "github_permission_denied",
    "github_stale_head",
}


class CodeReleaseWorker:
    """Merge only PR commits authorized by Supabase after CI, QA and Security pass."""

    def __init__(self, store: Any, github: GitHubIssues,
                 worker_id: str = "sutra-worker-release0001"):
        if not re.fullmatch(r"sutra-worker-[a-z0-9]{8,64}", worker_id):
            raise ValueError("Invalid code release worker ID")
        self.store = store
        self.github = github
        self.worker_id = worker_id
        self.evidence_poller = GitHubEvidencePoller(store, github)

    def run_once(self) -> bool:
        self.evidence_poller.poll_once()
        claim = self.store.claim_ready_code_release(self.worker_id)
        if claim is None:
            return False
        if not isinstance(claim, dict):
            raise IntegrationError("Code release claim is malformed")
        attempt_id, token = claim.get("attempt_id"), claim.get("claim_token")
        repository, pr_number, expected_sha = (
            claim.get("repository"), claim.get("pull_request_number"), claim.get("head_sha")
        )
        if (not isinstance(attempt_id, str) or not isinstance(token, str)
                or repository != self.github.repository
                or isinstance(pr_number, bool) or not isinstance(pr_number, int)
                or not isinstance(expected_sha, str)
                or not re.fullmatch(r"[a-f0-9]{40}", expected_sha)):
            raise IntegrationError("Code release claim is malformed")

        if not self.store.validate_code_release_claim(self.worker_id, attempt_id, token):
            self.store.finish_code_release(self.worker_id, attempt_id, token, "blocked",
                                           detail_code="authorization_revoked")
            return False

        try:
            state = self.github.pull_request_release_state(pr_number)
            if state["merged"]:
                # A prior merge whose response was lost is reconciled through the
                # live PR state; the immutable tested head still has to match.
                merge_sha = state.get("merge_commit_sha")
                if not isinstance(merge_sha, str) or not re.fullmatch(r"[a-f0-9]{40}", merge_sha):
                    self.store.finish_code_release(self.worker_id, attempt_id, token, "blocked",
                                                   detail_code="github_stale_head")
                    return False
                self.store.finish_code_release(self.worker_id, attempt_id, token, "merged",
                                               merge_commit_sha=merge_sha)
                return True
            if (state["state"] != "open" or state["base_ref"] != "main"
                    or state["head_sha"] != expected_sha or state["draft"]):
                detail = "github_closed_unmerged" if state["state"] == "closed" else "github_stale_head"
                self.store.finish_code_release(self.worker_id, attempt_id, token, "blocked",
                                               detail_code=detail)
                return False

            # Recheck the audited grant immediately before the external write.
            if not self.store.validate_code_release_claim(self.worker_id, attempt_id, token):
                self.store.finish_code_release(self.worker_id, attempt_id, token, "blocked",
                                               detail_code="authorization_revoked")
                return False
            result = self.github.merge_pull_request(pr_number, expected_sha)
            self.store.finish_code_release(self.worker_id, attempt_id, token, "merged",
                                           merge_commit_sha=result["merge_commit_sha"])
            logger.info("code_release_merged task_id=%s pull_request=%s head_sha=%s",
                        claim.get("task_id"), pr_number, expected_sha)
            return True
        except GitHubAPIError as exc:
            detail = self._release_error_code(exc.code)
            self.store.finish_code_release(self.worker_id, attempt_id, token, "blocked",
                                           detail_code=detail)
            logger.warning("code_release_blocked task_id=%s pull_request=%s error_code=%s",
                           claim.get("task_id"), pr_number, detail)
            return False

    @staticmethod
    def _release_error_code(code: str) -> str:
        if code == "github_permission_denied" or code == "github_forbidden":
            return "github_permission_denied"
        if code == "github_network_error" or code == "github_rate_limited":
            return "github_network_error"
        if code in {"github_http_404", "github_http_410"}:
            return "github_closed_unmerged"
        if code in {"github_http_405", "github_http_409"}:
            return "github_merge_conflict"
        if code in {"github_http_422", "malformed_github_response"}:
            return "github_stale_head"
        return "github_api_error" if code in _SAFE_RELEASE_ERRORS else "github_api_error"

    def run(self, stop: threading.Event, idle_seconds: float = 30.0) -> None:
        while not stop.is_set():
            try:
                worked = self.run_once()
            except (IntegrationError, GitHubAPIError, OSError, ValueError) as exc:
                logger.warning("code_release_cycle_failed error_type=%s", type(exc).__name__)
                worked = False
            if not worked:
                stop.wait(idle_seconds)
