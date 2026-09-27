import io
import json
import unittest
from unittest.mock import patch

from sutra.github_dispatch import GitHubAPIError, GitHubIssues, GitHubTaskDispatcher
from sutra.runtime import IntegrationError


TASK_ID = "01942c8a-68b1-7c29-bf9b-63f02e97359e"
LEASE = "01942c8a-68b1-7c29-bf9b-63f02e973590"
TASK = {
    "task_id": TASK_ID,
    "lease_token": LEASE,
    "title": "Implement approved API change",
    "description": "Deliver the founder-approved implementation. @random-user must not be notified.",
    "acceptance_criteria": ["Changes have tests", "No secret is committed"],
    "project_id": "01942c8a-68b1-7c29-bf9b-63f02e973591",
}


class Response:
    def __init__(self, body):
        self.body = json.dumps(body).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, _limit):
        return self.body


class GitHubIssueTests(unittest.TestCase):
    def test_task_issue_is_created_with_stable_marker_and_no_mentions(self):
        calls = []

        def fake_urlopen(request, timeout):
            calls.append(request)
            if request.get_method() == "GET":
                return Response({"items": []})
            body = json.loads(request.data)
            self.assertEqual(body["title"], "Sutra: Implement approved API change")
            self.assertIn(f"<!-- sutra-task-id:{TASK_ID} -->", body["body"])
            self.assertIn("@\u200brandom-user", body["body"])
            return Response({"number": 41, "html_url": "https://github.com/acme/sutra/issues/41"})

        client = GitHubIssues("never-logged-token", "acme/sutra")
        with patch("sutra.github_dispatch.urllib.request.urlopen", side_effect=fake_urlopen):
            result = client.create_or_find_issue(TASK)
        self.assertEqual(result, {"number": 41, "url": "https://github.com/acme/sutra/issues/41"})
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0].get_header("Authorization"), "Bearer never-logged-token")
        self.assertNotIn("never-logged-token", calls[0].full_url)

    def test_existing_issue_is_reused_after_worker_lease_recovery(self):
        calls = []

        def fake_urlopen(request, timeout):
            calls.append(request)
            return Response({"items": [{
                "number": 41,
                "html_url": "https://github.com/acme/sutra/issues/41",
                "body": f"<!-- sutra-task-id:{TASK_ID} -->\nexisting issue",
            }]})

        with patch("sutra.github_dispatch.urllib.request.urlopen", side_effect=fake_urlopen):
            result = GitHubIssues("token", "acme/sutra").create_or_find_issue(TASK)
        self.assertEqual(result["number"], 41)
        self.assertEqual(len(calls), 1)

    def test_invalid_repo_and_malformed_issue_response_fail_closed(self):
        with self.assertRaises(ValueError):
            GitHubIssues("token", "https://github.com/acme/sutra")
        with patch("sutra.github_dispatch.urllib.request.urlopen", return_value=Response({"items": []})):
            with self.assertRaises(GitHubAPIError):
                GitHubIssues("token", "acme/sutra").create_or_find_issue({**TASK, "title": ""})


class FakeStore:
    def __init__(self, claim=TASK):
        self.claim = claim
        self.completed = None
        self.failed = None

    def claim_github_task(self, worker_id):
        self.worker_id = worker_id
        return self.claim

    def complete_github_task(self, *args):
        self.completed = args
        return {"status": "in_progress"}

    def fail_github_task(self, *args):
        self.failed = args
        return {"status": "queued"}


class GitHubDispatcherTests(unittest.TestCase):
    def test_worker_completes_claim_and_persists_issue(self):
        store = FakeStore()

        class Issues:
            def create_or_find_issue(self, task):
                self.task = task
                return {"number": 41, "url": "https://github.com/acme/sutra/issues/41"}

        dispatcher = GitHubTaskDispatcher(store, Issues(), "sutra-github-worker-12345678")
        self.assertTrue(dispatcher.run_once())
        self.assertEqual(store.completed, (
            "sutra-github-worker-12345678", TASK_ID, LEASE, 41, "https://github.com/acme/sutra/issues/41"
        ))
        self.assertIsNone(store.failed)

    def test_worker_records_sanitized_api_failure(self):
        store = FakeStore()

        class Issues:
            def create_or_find_issue(self, task):
                raise GitHubAPIError("github_rate_limited")

        dispatcher = GitHubTaskDispatcher(store, Issues(), "sutra-github-worker-12345678")
        self.assertTrue(dispatcher.run_once())
        self.assertEqual(store.failed[-1], "github_rate_limited")
        self.assertIsNone(store.completed)

    def test_no_task_claim_is_idle_and_bad_identity_is_rejected(self):
        store = FakeStore(None)
        dispatcher = GitHubTaskDispatcher(store, object(), "sutra-github-worker-12345678")
        self.assertFalse(dispatcher.run_once())
        with self.assertRaises(ValueError):
            GitHubTaskDispatcher(store, object(), "admin")


if __name__ == "__main__":
    unittest.main()
