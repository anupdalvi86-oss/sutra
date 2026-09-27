import copy
import unittest

from sutra.codex_dispatch import seal_codex_issue_body, verify_codex_issue_event


REPOSITORY = "anupdalvi86-oss/sutra"
SECRET = "test-only-signing-secret-that-is-long-enough"
TASK_ID = "01942c8a-68b1-7c29-bf9b-63f02e97359e"
TITLE = "Sutra: Implement approved API change"
BODY = f"<!-- sutra-task-id:{TASK_ID} -->\n\nApproved task body"


def event():
    signed_body = seal_codex_issue_body(REPOSITORY, TASK_ID, 41, TITLE, BODY, SECRET)
    return {
        "action": "edited",
        "repository": {"full_name": REPOSITORY, "owner": {"login": "anupdalvi86-oss"}},
        "sender": {"login": "anupdalvi86-oss"},
        "issue": {
            "number": 41,
            "state": "open",
            "title": TITLE,
            "body": signed_body,
            "user": {"login": "anupdalvi86-oss"},
        },
    }


class CodexDispatchSignatureTests(unittest.TestCase):
    def test_verifies_owner_authored_exact_issue_bound_to_repository_and_number(self):
        self.assertEqual(
            verify_codex_issue_event(event(), SECRET, REPOSITORY),
            {"task_id": TASK_ID, "issue_number": 41},
        )

    def test_rejects_body_title_or_issue_number_tampering(self):
        for mutate in (
            lambda value: value["issue"].update(body=value["issue"]["body"] + "\nextra"),
            lambda value: value["issue"].update(title="Sutra: different task"),
            lambda value: value["issue"].update(number=42),
        ):
            changed = copy.deepcopy(event())
            mutate(changed)
            with self.subTest(changed=changed["issue"]):
                with self.assertRaises(ValueError):
                    verify_codex_issue_event(changed, SECRET, REPOSITORY)

    def test_rejects_nonowner_events_other_repositories_closed_issues_and_wrong_action(self):
        mutators = (
            lambda value: value["sender"].update(login="untrusted-contributor"),
            lambda value: value["issue"]["user"].update(login="untrusted-contributor"),
            lambda value: value["repository"].update(full_name="other/repo"),
            lambda value: value["issue"].update(state="closed"),
            lambda value: value.update(action="opened"),
        )
        for mutate in mutators:
            changed = copy.deepcopy(event())
            mutate(changed)
            with self.subTest(changed=changed):
                with self.assertRaises(ValueError):
                    verify_codex_issue_event(changed, SECRET, REPOSITORY)

    def test_rejects_unsigned_and_malformed_events_or_short_secret(self):
        changed = event()
        changed["issue"]["body"] = BODY
        with self.assertRaises(ValueError):
            verify_codex_issue_event(changed, SECRET, REPOSITORY)
        for invalid in (None, [], {"action": "edited", "repository": None}):
            with self.assertRaises(ValueError):
                verify_codex_issue_event(invalid, SECRET, REPOSITORY)
        with self.assertRaises(ValueError):
            verify_codex_issue_event(event(), "too-short", REPOSITORY)

    def test_sealer_rejects_invalid_repository_task_issue_number_and_duplicate_markers(self):
        for args in (
            ("https://github.com/anupdalvi86-oss/sutra", TASK_ID, 41, TITLE, BODY, SECRET),
            ("owner/../sutra", TASK_ID, 41, TITLE, BODY, SECRET),
            (REPOSITORY, "bad-task-id", 41, TITLE, BODY, SECRET),
            (REPOSITORY, TASK_ID, True, TITLE, BODY, SECRET),
            (REPOSITORY, TASK_ID, 41, TITLE, BODY + "\n<!-- sutra-task-id:" + TASK_ID + " -->", SECRET),
        ):
            with self.subTest(args=args[:3]):
                with self.assertRaises(ValueError):
                    seal_codex_issue_body(*args)


if __name__ == "__main__":
    unittest.main()
