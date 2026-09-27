import unittest
import urllib.error
import urllib.request
from unittest.mock import Mock, patch

from sutra.runtime import (
    FounderCommandRouter,
    IntegrationError,
    SupabaseREST,
    parse_founder_command,
    proposal_name,
    telegram_poll_loop,
    validate_outbound_request,
)


FOUNDER = "123456789"
APPROVAL = "00000000-0000-4000-8000-000000000001"


class FounderCommandTests(unittest.TestCase):
    def setUp(self):
        self.store = Mock()
        self.router = FounderCommandRouter(self.store, FOUNDER)

    def test_status_reads_authoritative_counts(self):
        self.store.company_status.return_value = {"projects": 2, "open_tasks": 3, "pending_approvals": 1}
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, give me company status.")
        self.assertIn("Projects: 2", reply)
        self.assertIn("Pending approvals: 1", reply)
        self.store.company_status.assert_called_once_with()

    def test_status_database_failure_returns_a_clear_fail_closed_reply(self):
        self.store.company_status.side_effect = IntegrationError("unavailable")
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, give me company status.")
        self.assertIn("couldn't load company status", reply)
        self.assertIn("No company state was changed", reply)

    def test_proposal_creates_persisted_approval_request(self):
        self.store.rpc.return_value = {"project_id": "project-1", "approval_id": "approval-1"}
        text = "Investigate an AI QA product. Initial budget maximum €500. Prepare a proposal."
        reply = self.router.handle(FOUNDER, FOUNDER, text)
        self.assertIn("No spending is authorized until approval", reply)
        args = self.store.rpc.call_args
        self.assertEqual(args.args[0], "sutra_submit_proposal")
        self.assertEqual(args.args[1]["p_founder_telegram_user_id"], FOUNDER)
        self.assertEqual(args.args[1]["p_requested_budget"], 500)
        self.assertEqual(args.args[1]["p_name"], "AI QA product opportunity")

    def test_founder_can_decide_only_explicit_approval_command(self):
        self.store.rpc.return_value = {"status": "approved", "approval_id": APPROVAL}
        reply = self.router.handle(FOUNDER, FOUNDER, f"approve {APPROVAL} go ahead")
        self.assertIn("approved", reply)
        self.assertEqual(self.store.rpc.call_args.args[0], "sutra_founder_decide_approval")
        self.assertEqual(self.store.rpc.call_args.args[1]["p_comment"], "go ahead")

    def test_founder_can_list_pending_approvals_without_deciding_them(self):
        self.store.founder_pending_approvals.return_value = [{
            "approval_id": APPROVAL, "summary": "AI QA opportunity", "amount": 500,
            "currency": "EUR", "pending_roles": ["cfo"], "ready": False,
        }]
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, show my approvals.")
        self.assertIn("AI QA opportunity", reply)
        self.assertIn("waiting for cfo", reply)
        self.assertIn(APPROVAL, reply)
        self.store.founder_pending_approvals.assert_called_once_with(FOUNDER)
        self.store.rpc.assert_not_called()

    def test_approval_queue_failure_fails_closed(self):
        self.store.founder_pending_approvals.side_effect = IntegrationError("unavailable")
        reply = self.router.handle(FOUNDER, FOUNDER, "show my approvals")
        self.assertIn("No approval was changed", reply)
        self.store.rpc.assert_not_called()

    def test_rejects_nonfounder_and_group_chats(self):
        self.store.record_denied_identity.return_value = None
        response = self.router.handle("987654321", "987654321", "CEO, give me company status")
        self.assertIn("restricted", response)
        self.store.company_status.assert_not_called()
        self.store.rpc.assert_not_called()
        self.store.record_denied_identity.assert_called_once()
        self.assertEqual(len(self.store.record_denied_identity.call_args.args[0]), 24)

        group_response = self.router.handle(FOUNDER, "-100123", "CEO, give me company status")
        self.assertIn("restricted", group_response)
        self.store.company_status.assert_not_called()

    def test_malformed_or_unbudgeted_proposals_do_not_write(self):
        self.assertEqual(parse_founder_command("Investigate a product").kind, "unsupported")
        with self.assertRaises(ValueError):
            parse_founder_command(" ")
        with self.assertRaises(ValueError):
            parse_founder_command("x" * 3001)
        self.router.handle(FOUNDER, FOUNDER, "change everything")
        self.store.rpc.assert_not_called()

    def test_money_and_name_parsing(self):
        parsed = parse_founder_command("Research QA tooling; maximum EUR 50.25")
        self.assertEqual(parsed.budget, 50.25)
        self.assertEqual(proposal_name("Investigate a safer QA product. Budget max €25."), "safer QA product opportunity")

    def test_budget_amount_must_fit_supported_range(self):
        for command in (
            "Investigate product with budget €999999999999999999999999",
            "Investigate product with budget €0",
        ):
            with self.subTest(command=command), self.assertRaises(ValueError):
                parse_founder_command(command)

    def test_unavailable_audit_store_does_not_grant_access(self):
        self.store.record_denied_identity.side_effect = IntegrationError("unavailable")
        response = self.router.handle("1", "1", "CEO status")
        self.assertIn("restricted", response)
        self.store.company_status.assert_not_called()


class OutboundRequestSecurityTests(unittest.TestCase):
    def test_outbound_requests_allow_https_and_railway_private_http_only(self):
        urls = ("https://api.example.test/resource", "http://sutra.railway.internal:8642/health")
        for url in urls:
            with self.subTest(url=url):
                validate_outbound_request(urllib.request.Request(url))

    def test_outbound_requests_reject_unsafe_schemes_and_authorities(self):
        for url in (
            "file:///etc/passwd",
            "ftp://example.test/file",
            "http://example.test/resource",
            "https://user:password@example.test/resource",
        ):
            with self.subTest(url=url), self.assertRaises(urllib.error.URLError):
                validate_outbound_request(urllib.request.Request(url))


class TaskReviewStoreTests(unittest.TestCase):
    def test_worker_claim_falls_back_to_task_queues_only_when_prior_queues_are_idle(self):
        store = SupabaseREST("https://sutra.example", "server-key")
        artifact_run = {"run_id": "artifact-run", "agent": {"slug": "product_manager"}}
        store.request = Mock(side_effect=[None, None, artifact_run])
        self.assertEqual(store.claim_agent_run("sutra-worker-12345678"), artifact_run)
        self.assertEqual(store.request.call_args_list[0].args[0], "rpc/sutra_claim_agent_run")
        self.assertEqual(store.request.call_args_list[1].args[0], "rpc/sutra_claim_task_review_agent_run")
        self.assertEqual(store.request.call_args_list[2].args[0], "rpc/sutra_claim_task_agent_run")

    def test_task_review_submission_uses_database_claimed_owner_and_task(self):
        store = SupabaseREST("https://sutra.example", "server-key")
        store.rpc = Mock(return_value={"status": "done"})
        run = {"agent": {"id": "agent-id"}, "task_review": {"task_id": "task-id"}}
        evidence = {"result": "pass"}
        self.assertEqual(store.submit_task_review(run, evidence), {"status": "done"})
        store.rpc.assert_called_once_with("sutra_submit_task_review", {
            "p_task_id": "task-id", "p_actor_agent_id": "agent-id", "p_evidence": evidence,
        })

    def test_task_artifact_submission_passes_worker_lease_to_authoritative_rpc(self):
        store = SupabaseREST("https://sutra.example", "server-key")
        store.rpc = Mock(return_value={"status": "succeeded"})
        run = {"run_id": "run-id", "lease_token": "lease-id"}
        artifact = {"summary": "Stored", "artifact": {"scope": "bounded"}}
        self.assertEqual(store.submit_task_agent_artifact("sutra-worker-12345678", run, artifact), {"status": "succeeded"})
        store.rpc.assert_called_once_with("sutra_submit_task_agent_artifact", {
            "p_worker_id": "sutra-worker-12345678", "p_run_id": "run-id",
            "p_lease_token": "lease-id", "p_output": artifact,
        })


class TelegramPollingTests(unittest.TestCase):
    def test_health_status_tracks_poll_recovery_without_logging_or_stopping(self):
        class StopAfterTwoPolls:
            def __init__(self):
                self.checks = 0

            def is_set(self):
                self.checks += 1
                return self.checks > 2

            def wait(self, _seconds):
                return None

        statuses = []
        replies = [[], IntegrationError("temporary outage"), []]
        with patch("sutra.runtime.telegram_call", side_effect=replies):
            telegram_poll_loop("unit-test-token", Mock(), StopAfterTwoPolls(), statuses.append)
        self.assertEqual(statuses, ["unreachable", "running"])


if __name__ == "__main__":
    unittest.main()
