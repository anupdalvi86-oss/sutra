from __future__ import annotations

import unittest
from unittest.mock import Mock

from sutra.code_release import CodeReleaseWorker
from sutra.github_dispatch import GitHubAPIError, GitHubIssues


SHA = "a" * 40
MERGE_SHA = "b" * 40
TASK_ID = "11111111-1111-4111-8111-111111111111"
ATTEMPT_ID = "22222222-2222-4222-8222-222222222222"
CLAIM_TOKEN = "33333333-3333-4333-8333-333333333333"


class CodeReleaseWorkerTests(unittest.TestCase):
    def setUp(self):
        self.store = Mock()
        self.github = Mock()
        self.worker = CodeReleaseWorker(self.store, self.github)
        self.worker.evidence_poller = Mock()
        self.store.claim_ready_code_release.return_value = {
            "attempt_id": ATTEMPT_ID,
            "claim_token": CLAIM_TOKEN,
            "task_id": TASK_ID,
            "repository": "anupdalvi86-oss/sutra",
            "pull_request_number": 211,
            "pull_request_url": "https://github.com/anupdalvi86-oss/sutra/pull/211",
            "head_sha": SHA,
        }
        self.store.validate_code_release_claim.return_value = True
        self.github.repository = "anupdalvi86-oss/sutra"

    def test_merges_only_validated_exact_head_and_records_result(self):
        self.github.pull_request_release_state.return_value = {
            "head_sha": SHA, "base_ref": "main", "state": "open",
            "merged": False, "draft": False,
        }
        self.github.merge_pull_request.return_value = {
            "merged": True, "merge_commit_sha": MERGE_SHA,
        }

        self.assertTrue(self.worker.run_once())
        self.github.merge_pull_request.assert_called_once_with(211, SHA)
        self.assertEqual(self.store.validate_code_release_claim.call_count, 2)
        self.store.finish_code_release.assert_called_once_with(
            self.worker.worker_id, ATTEMPT_ID, CLAIM_TOKEN, "merged",
            merge_commit_sha=MERGE_SHA,
        )

    def test_no_ready_release_does_nothing(self):
        self.store.claim_ready_code_release.return_value = None
        self.assertFalse(self.worker.run_once())
        self.github.pull_request_release_state.assert_not_called()

    def test_revoked_founder_authority_fails_before_github_read(self):
        self.store.validate_code_release_claim.return_value = False
        self.assertFalse(self.worker.run_once())
        self.github.pull_request_release_state.assert_not_called()
        self.github.merge_pull_request.assert_not_called()
        self.store.finish_code_release.assert_called_once_with(
            self.worker.worker_id, ATTEMPT_ID, CLAIM_TOKEN, "blocked",
            detail_code="authorization_revoked",
        )

    def test_stale_or_wrong_base_commit_is_never_merged(self):
        self.github.pull_request_release_state.return_value = {
            "head_sha": "c" * 40, "base_ref": "main", "state": "open",
            "merged": False, "draft": False,
        }
        self.assertFalse(self.worker.run_once())
        self.github.merge_pull_request.assert_not_called()
        self.store.finish_code_release.assert_called_once_with(
            self.worker.worker_id, ATTEMPT_ID, CLAIM_TOKEN, "blocked",
            detail_code="github_stale_head",
        )

    def test_draft_pull_request_is_never_merged(self):
        self.github.pull_request_release_state.return_value = {
            "head_sha": SHA, "base_ref": "main", "state": "open",
            "merged": False, "draft": True,
        }
        self.assertFalse(self.worker.run_once())
        self.github.merge_pull_request.assert_not_called()

    def test_permissions_failure_is_sanitized_and_audited(self):
        self.github.pull_request_release_state.side_effect = GitHubAPIError("github_permission_denied")
        self.assertFalse(self.worker.run_once())
        self.store.finish_code_release.assert_called_once_with(
            self.worker.worker_id, ATTEMPT_ID, CLAIM_TOKEN, "blocked",
            detail_code="github_permission_denied",
        )

    def test_malformed_claim_fails_closed(self):
        self.store.claim_ready_code_release.return_value = {"repository": "attacker/repo"}
        with self.assertRaises(Exception):
            self.worker.run_once()
        self.github.pull_request_release_state.assert_not_called()


class GitHubReleaseApiTests(unittest.TestCase):
    def setUp(self):
        self.github = GitHubIssues("token", "anupdalvi86-oss/sutra", "s" * 48)

    def test_reads_minimum_release_facts(self):
        self.github._request = Mock(return_value={
            "head": {"sha": SHA}, "base": {"ref": "main"},
            "state": "open", "merged": False, "draft": False,
        })
        self.assertEqual(self.github.pull_request_release_state(42), {
            "head_sha": SHA, "base_ref": "main", "state": "open",
            "merged": False, "draft": False, "merge_commit_sha": None,
        })
        self.github._request.assert_called_once_with("/repos/anupdalvi86-oss/sutra/pulls/42")

    def test_merge_uses_compare_and_merge_sha(self):
        self.github._request = Mock(return_value={"merged": True, "sha": MERGE_SHA})
        self.assertEqual(self.github.merge_pull_request(42, SHA), {
            "merged": True, "merge_commit_sha": MERGE_SHA,
        })
        self.github._request.assert_called_once_with(
            "/repos/anupdalvi86-oss/sutra/pulls/42/merge", method="PUT",
            payload={"sha": SHA, "merge_method": "squash"},
        )

    def test_invalid_release_inputs_do_not_call_github(self):
        self.github._request = Mock()
        with self.assertRaises(GitHubAPIError):
            self.github.merge_pull_request(42, "bad-sha")
        with self.assertRaises(GitHubAPIError):
            self.github.pull_request_release_state(True)
        self.github._request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
