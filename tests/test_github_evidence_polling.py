import unittest
from unittest.mock import Mock

from sutra.github_dispatch import GitHubAPIError, GitHubIssues
from sutra.github_evidence_polling import GitHubEvidencePoller


REPOSITORY = "anupdalvi86-oss/sutra"
TASK_ID = "01942c8a-68b1-7c29-bf9b-63f02e97359e"
HEAD_SHA = "a" * 40


class GitHubEvidencePollingTests(unittest.TestCase):
    def setUp(self):
        self.github = GitHubIssues("token", REPOSITORY, "test-only-signing-secret-long-enough")
        self.store = Mock()
        self.store.rpc.return_value = {"accepted": True, "completed_tasks": 0}
        self.poller = GitHubEvidencePoller(self.store, self.github)

    def test_poll_records_only_normalized_sutra_pull_request_and_ci_events(self):
        pull_request = {
            "number": 42,
            "html_url": f"https://github.com/{REPOSITORY}/pull/42",
            "title": "Sutra: Implement the approved work",
            "body": f"Sutra-Task-ID: {TASK_ID}\n\nCloses #13",
            "state": "closed",
            "merged_at": "2026-09-27T22:00:00Z",
            "head": {"sha": HEAD_SHA},
            "base": {"ref": "main"},
        }
        workflow = {
            "id": 36_530_327_914,
            "name": "CI",
            "status": "completed",
            "conclusion": "success",
            "html_url": f"https://github.com/{REPOSITORY}/actions/runs/36530327914",
            "head_sha": HEAD_SHA,
            "pull_requests": [{"number": 42, "head": {"sha": HEAD_SHA}}],
        }
        stale_workflow = {
            **workflow,
            "id": 36_530_327_913,
            "html_url": f"https://github.com/{REPOSITORY}/actions/runs/36530327913",
            "head_sha": "b" * 40,
        }
        self.github._request = Mock(side_effect=[[pull_request], {"workflow_runs": [workflow, stale_workflow]}])

        self.assertEqual(self.poller.poll_once(), 2)
        self.assertEqual(self.github._request.call_count, 2)
        self.assertIn("per_page=20", self.github._request.call_args_list[0].args[0])
        self.assertIn("per_page=20", self.github._request.call_args_list[1].args[0])
        self.assertEqual(self.store.rpc.call_count, 2)
        pr_event = self.store.rpc.call_args_list[0].args[1]
        ci_event = self.store.rpc.call_args_list[1].args[1]
        self.assertEqual(pr_event["p_event_name"], "pull_request")
        self.assertEqual(pr_event["p_event"]["task_id"], TASK_ID)
        self.assertTrue(pr_event["p_event"]["merged"])
        self.assertEqual(ci_event["p_event_name"], "workflow_run")
        self.assertEqual(ci_event["p_event"]["conclusion"], "success")
        self.assertEqual(ci_event["p_event"]["pull_requests"][0]["head_sha"], HEAD_SHA)

    def test_delivery_identifiers_are_stable_for_idempotent_polling(self):
        event = {"kind": "workflow_run", "run_id": 101, "conclusion": "success"}
        self.poller._record("workflow_run", event)
        first_id = self.store.rpc.call_args.args[1]["p_delivery_id"]
        self.poller._record("workflow_run", event)
        second_id = self.store.rpc.call_args.args[1]["p_delivery_id"]
        self.assertEqual(first_id, second_id)

    def test_unlinked_or_unrelated_pr_is_ignored_without_database_write(self):
        self.github._request = Mock(side_effect=[
            [{"number": 43, "title": "unrelated", "body": "no Sutra marker"}],
            {"workflow_runs": []},
        ])
        self.assertEqual(self.poller.poll_once(), 0)
        self.store.rpc.assert_not_called()

    def test_poll_logs_only_endpoint_and_sanitized_error_code(self):
        self.github._request = Mock(side_effect=GitHubAPIError("malformed_github_response"))
        with self.assertLogs("sutra.github_evidence_polling", level="WARNING") as captured:
            with self.assertRaises(GitHubAPIError):
                self.poller.poll_once()
        self.assertEqual(captured.records[0].getMessage(),
                         "github_evidence_request_failed endpoint=pull_requests "
                         "error_code=malformed_github_response")


if __name__ == "__main__":
    unittest.main()
