import io
import json
import unittest
from unittest.mock import Mock, patch

from sutra.codex_dispatch import seal_codex_issue_body
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
SIGNING_SECRET = "test-only-github-webhook-secret-long-enough"


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
    def test_task_issue_is_created_then_bound_to_signed_issue_number(self):
        calls = []

        def fake_urlopen(request, timeout):
            calls.append(request)
            if request.get_method() == "GET":
                return Response({"items": []})
            body = json.loads(request.data)
            if request.get_method() == "POST":
                self.assertEqual(body["title"], "Sutra: Implement approved API change")
                self.assertIn(f"<!-- sutra-task-id:{TASK_ID} -->", body["body"])
                self.assertIn("@\u200brandom-user", body["body"])
                self.assertNotIn("sutra-codex-dispatch", body["body"])
                self.assertIn("/issues", request.full_url)
                return Response({"number": 41, "html_url": "https://github.com/acme/sutra/issues/41"})
            self.assertEqual(request.get_method(), "PATCH")
            signature = f"<!-- sutra-codex-dispatch:v1 task={TASK_ID} number=41 signature="
            self.assertIn(signature, body["body"])
            return Response({
                "number": 41,
                "html_url": "https://github.com/acme/sutra/issues/41",
                "title": body["title"] if "title" in body else "Sutra: Implement approved API change",
                "body": body["body"],
            })

        client = GitHubIssues("never-logged-token", "acme/sutra", SIGNING_SECRET)
        with patch("sutra.github_dispatch.urllib.request.urlopen", side_effect=fake_urlopen):
            result = client.create_or_find_issue(TASK)
        self.assertEqual(result, {"number": 41, "url": "https://github.com/acme/sutra/issues/41"})
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0].get_header("Authorization"), "Bearer never-logged-token")
        self.assertNotIn("never-logged-token", calls[0].full_url)

    def test_existing_unsigned_issue_is_sealed_after_worker_lease_recovery(self):
        calls = []
        client = GitHubIssues("token", "acme/sutra", SIGNING_SECRET)
        unsigned_body = client._issue_body(TASK, TASK_ID)

        def fake_urlopen(request, timeout):
            calls.append(request)
            if request.get_method() == "GET":
                return Response({"items": [{
                    "number": 41,
                    "html_url": "https://github.com/acme/sutra/issues/41",
                    "title": "Sutra: Implement approved API change",
                    "body": unsigned_body,
                }]})
            self.assertEqual(request.get_method(), "PATCH")
            body = json.loads(request.data)["body"]
            self.assertIn("<!-- sutra-codex-dispatch:v1", body)
            return Response({
                "number": 41,
                "html_url": "https://github.com/acme/sutra/issues/41",
                "title": "Sutra: Implement approved API change",
                "body": body,
            })

        with patch("sutra.github_dispatch.urllib.request.urlopen", side_effect=fake_urlopen):
            result = client.create_or_find_issue(TASK)
        self.assertEqual(result["number"], 41)
        self.assertEqual(len(calls), 2)

    def test_existing_signed_issue_is_reused_and_modified_issue_is_rejected(self):
        client = GitHubIssues("token", "acme/sutra", SIGNING_SECRET)
        unsigned_body = client._issue_body(TASK, TASK_ID)
        signed_body = seal_codex_issue_body(
            "acme/sutra", TASK_ID, 41, "Sutra: Implement approved API change", unsigned_body, SIGNING_SECRET
        )
        existing = {
            "number": 41,
            "html_url": "https://github.com/acme/sutra/issues/41",
            "title": "Sutra: Implement approved API change",
            "body": signed_body,
        }
        with patch("sutra.github_dispatch.urllib.request.urlopen", return_value=Response({"items": [existing]})) as request:
            result = client.create_or_find_issue(TASK)
        self.assertEqual(result["number"], 41)
        request.assert_called_once()

        existing["body"] += "\nchanged"
        with patch("sutra.github_dispatch.urllib.request.urlopen", return_value=Response({"items": [existing]})):
            with self.assertRaises(GitHubAPIError) as caught:
                client.create_or_find_issue(TASK)
        self.assertEqual(caught.exception.code, "malformed_github_response")

    def test_invalid_repo_and_malformed_issue_response_fail_closed(self):
        with self.assertRaises(ValueError):
            GitHubIssues("token", "https://github.com/acme/sutra", SIGNING_SECRET)
        with self.assertRaises(ValueError):
            GitHubIssues("token", "acme/sutra", "short")
        with patch("sutra.github_dispatch.urllib.request.urlopen", return_value=Response({"items": []})):
            with self.assertRaises(GitHubAPIError):
                GitHubIssues("token", "acme/sutra", SIGNING_SECRET).create_or_find_issue({**TASK, "title": ""})

    def test_codex_runner_lists_only_open_sutra_issues(self):
        client = GitHubIssues("token", "acme/sutra", SIGNING_SECRET)
        client._request = Mock(return_value=[
            {"number": 1, "title": "Sutra: signed task"},
            {"number": 2, "title": "Sutra: PR masquerading", "pull_request": {"url": "ignored"}},
            {"number": 3, "title": "Unrelated"},
            "malformed",
        ])
        self.assertEqual(client.open_task_issues(), [{"number": 1, "title": "Sutra: signed task"}])
        client._request.assert_called_once_with(
            "/repos/acme/sutra/issues?state=open&per_page=100&sort=created&direction=asc")

    def test_pull_request_creation_is_bound_to_task_branch_and_main(self):
        client = GitHubIssues("token", "acme/sutra", SIGNING_SECRET)
        client._request = Mock(return_value={"number": 12, "html_url": "https://github.com/acme/sutra/pull/12"})
        result = client.create_pull_request(
            "Sutra: Implement task", "Sutra-Task-ID: 01942c8a-68b1-7c29-bf9b-63f02e97359e",
            "sutra/task-01942c8a-68b1-7c29-bf9b-63f02e97359e",
        )
        self.assertEqual(result, {"number": 12, "url": "https://github.com/acme/sutra/pull/12"})
        self.assertEqual(client._request.call_args.args[:2], ("/repos/acme/sutra/pulls", "POST"))
        with self.assertRaises(GitHubAPIError):
            client.create_pull_request("bad title", "body", "main")


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
