import hashlib
import hmac
import unittest

from sutra.github_webhook import normalize_github_event, verify_github_signature


REPO = "acme/sutra"
TASK_ID = "01942c8a-68b1-7c29-bf9b-63f02e97359e"
HEAD_SHA = "a" * 40


def pull_request_event(**overrides):
    payload = {
        "action": "closed",
        "repository": {"full_name": REPO},
        "pull_request": {
            "number": 88,
            "html_url": "https://github.com/acme/sutra/pull/88",
            "body": f"Sutra-Task-ID: {TASK_ID}\nCloses #41",
            "merged": True,
            "head": {"sha": HEAD_SHA},
            "base": {"ref": "main"},
        },
    }
    payload.update(overrides)
    return payload


def workflow_run_event(**run_overrides):
    run = {
        "id": 201,
        "name": "CI",
        "status": "completed",
        "conclusion": "success",
        "head_sha": HEAD_SHA,
        "html_url": "https://github.com/acme/sutra/actions/runs/201",
        "pull_requests": [{"number": 88, "head": {"sha": HEAD_SHA}}],
    }
    run.update(run_overrides)
    return {"action": "completed", "repository": {"full_name": REPO}, "workflow_run": run}


class GitHubWebhookTests(unittest.TestCase):
    def test_signature_verification_uses_raw_body_and_constant_time_expected_digest(self):
        body = b'{"event":"signed exact bytes"}'
        signature = "sha256=" + hmac.new(b"secret-value", body, hashlib.sha256).hexdigest()
        self.assertTrue(verify_github_signature("secret-value", body, signature))
        self.assertFalse(verify_github_signature("wrong-secret", body, signature))
        self.assertFalse(verify_github_signature("secret-value", body + b" ", signature))
        self.assertFalse(verify_github_signature("secret-value", body, "sha1=bad"))

    def test_pr_event_requires_task_marker_closing_issue_and_main_base(self):
        normalized = normalize_github_event("pull_request", REPO, pull_request_event())
        self.assertEqual(normalized["kind"], "pull_request")
        self.assertEqual(normalized["task_id"], TASK_ID)
        self.assertEqual(normalized["issue_number"], 41)
        self.assertEqual(normalized["pull_request_number"], 88)
        self.assertTrue(normalized["merged"])
        self.assertEqual(normalized["head_sha"], HEAD_SHA)

        no_link = pull_request_event()
        no_link["pull_request"]["body"] = "A change without a Sutra task link"
        self.assertIsNone(normalize_github_event("pull_request", REPO, no_link))
        wrong_branch = pull_request_event()
        wrong_branch["pull_request"]["base"]["ref"] = "release"
        self.assertIsNone(normalize_github_event("pull_request", REPO, wrong_branch))

    def test_workflow_run_binds_ci_result_to_the_pr_head_sha(self):
        normalized = normalize_github_event("workflow_run", REPO, workflow_run_event())
        self.assertEqual(normalized["workflow_name"], "CI")
        self.assertEqual(normalized["conclusion"], "success")
        self.assertEqual(normalized["head_sha"], HEAD_SHA)
        self.assertEqual(normalized["pull_requests"], [{"number": 88, "head_sha": HEAD_SHA}])

    def test_workflow_run_rejects_stale_run_with_current_pr_association(self):
        stale = workflow_run_event(head_sha="b" * 40)
        self.assertIsNone(normalize_github_event("workflow_run", REPO, stale))

    def test_workflow_run_accepts_real_github_64_bit_run_ids(self):
        run_id = 36_530_327_914
        normalized = normalize_github_event(
            "workflow_run", REPO,
            workflow_run_event(
                id=run_id,
                html_url=f"https://github.com/{REPO}/actions/runs/{run_id}",
            ),
        )
        self.assertIsNotNone(normalized)
        self.assertEqual(normalized["run_id"], run_id)

        mismatched_url = workflow_run_event(
            id=run_id,
            html_url=f"https://github.com/{REPO}/actions/runs/201",
        )
        self.assertIsNone(normalize_github_event("workflow_run", REPO, mismatched_url))
        too_large = workflow_run_event(id=9_223_372_036_854_775_808)
        self.assertIsNone(normalize_github_event("workflow_run", REPO, too_large))
        boolean_id = workflow_run_event(id=True)
        self.assertIsNone(normalize_github_event("workflow_run", REPO, boolean_id))

    def test_other_repositories_workflows_and_malformed_pull_requests_are_ignored(self):
        foreign = pull_request_event()
        foreign["repository"]["full_name"] = "other/repo"
        self.assertIsNone(normalize_github_event("pull_request", REPO, foreign))
        self.assertIsNone(normalize_github_event("workflow_run", REPO, workflow_run_event(name="Deploy")))
        malformed = workflow_run_event()
        malformed["workflow_run"]["pull_requests"][0]["head"]["sha"] = "not-a-commit"
        self.assertIsNone(normalize_github_event("workflow_run", REPO, malformed))
        self.assertIsNone(normalize_github_event("issues", REPO, {}))


if __name__ == "__main__":
    unittest.main()
