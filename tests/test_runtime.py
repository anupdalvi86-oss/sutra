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
    render_status_brief,
    telegram_poll_loop,
    validate_outbound_request,
)


FOUNDER = "123456789"
APPROVAL = "00000000-0000-4000-8000-000000000001"


def status_fixture():
    return {
        "projects": [{"id": "project-1", "name": "AI QA opportunity", "status": "approved",
                      "requested_budget": 500, "currency": "EUR", "department_id": "finance-dept",
                      "owner_agent_id": "ceo-id"}],
        "objectives": [{"id": "objective-1", "project_id": "project-1",
                        "title": "Validate buyer demand", "status": "active",
                        "owner_agent_id": "cpo-id"}],
        "tasks": [{"id": "task-1", "title": "Review product plan", "status": "blocked",
                   "project_id": "project-1", "owner_agent_id": "pm-id"}],
        "approvals": [{"id": APPROVAL, "project_id": "project-1", "summary": "Approval waiting for CFO",
                        "amount": 500, "currency": "EUR", "status": "pending",
                        "required_roles": ["cfo", "founder"], "decisions": {"cfo": {"decision": "approve"}}}],
        "agent_runs": [{"task_id": "task-1", "status": "blocked", "output": {}},
                        {"task_id": "task-1", "status": "failed",
                         "output": {"error_code": "unknown_or_overrun_spend", "failure_detail_code": "invalid_evidence"}}],
        "agents": [{"id": "ceo-id", "slug": "ceo", "display_name": "Chief Executive", "department_id": "executive-dept"},
                   {"id": "cfo-id", "slug": "cfo", "display_name": "Chief Financial Officer", "department_id": "finance-dept"},
                   {"id": "pm-id", "slug": "product_manager", "display_name": "Product Manager", "department_id": "product-dept"}],
        "departments": [{"id": "finance-dept", "slug": "finance", "name": "Finance"}],
        "budgets": [{"scope": "company", "scope_key": "*", "period": "monthly", "currency": "EUR",
                     "limit_amount": 8.0, "warning_percent": 80, "hard_stop": True}],
        "expenses": [{"amount": 0.15, "currency": "EUR", "status": "paid", "category": "ai_inference"}],
        "campaigns": [{"id": "campaign-1", "project_id": "project-1", "name": "QA pilot positioning",
                       "channel": "internal", "status": "draft", "budget_amount": 0, "currency": "EUR"}],
        "customers": [{"id": "lead-1", "name": "Synthetic lead", "company": "Example Co",
                       "source": "test fixture", "status": "qualified"}],
        "github_dispatches": [],
    }


class FounderCommandTests(unittest.TestCase):
    def setUp(self):
        self.store = Mock()
        self.router = FounderCommandRouter(self.store, FOUNDER)

    def test_status_reads_authoritative_counts(self):
        self.store.company_status.return_value = status_fixture()
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, give me company status.").text
        self.assertIn("CEO operating brief — board update", reply)
        self.assertIn("AI QA opportunity — approved", reply)
        self.assertIn("1 tasks — 0 backlog, 0 ready, 0 in progress, 0 in review, 1 blocked", reply)
        self.assertIn("model usage could not be verified within its reservation", reply)
        self.assertIn("Approval waiting for CFO", reply)
        self.assertIn("company / * / monthly: EUR 8.0", reply)
        self.store.company_status.assert_called_once_with()

    def test_board_status_includes_objectives_campaigns_and_customer_pipeline(self):
        reply = render_status_brief(status_fixture(), "ceo")
        self.assertIn("Objective [active]: Validate buyer demand", reply)
        self.assertIn("Marketing pipeline", reply)
        self.assertIn("[draft] QA pilot positioning — internal", reply)
        self.assertIn("Customer and lead pipeline", reply)
        self.assertIn("[qualified] Synthetic lead (Example Co) — test fixture", reply)

    def test_marketing_and_sales_statuses_include_their_operating_pipelines(self):
        snapshot = status_fixture()
        marketing = render_status_brief(snapshot, "cmo")
        self.assertIn("Marketing pipeline", marketing)
        self.assertNotIn("Customer and lead pipeline", marketing)
        sales = render_status_brief(snapshot, "sales")
        self.assertIn("Customer and lead pipeline", sales)
        self.assertNotIn("Marketing pipeline", sales)
        self.assertNotIn("Engineering delivery", sales)

    def test_empty_marketing_and_sales_pipelines_are_explicit(self):
        snapshot = status_fixture()
        snapshot["campaigns"] = []
        snapshot["customers"] = []
        company = render_status_brief(snapshot, "ceo")
        marketing = render_status_brief(snapshot, "cmo")
        sales = render_status_brief(snapshot, "sales")
        self.assertIn("Marketing pipeline", company)
        self.assertIn("No campaign records are currently recorded", company)
        self.assertIn("No campaign records are currently recorded", marketing)
        self.assertIn("Customer and lead pipeline", company)
        self.assertIn("No customer or lead records are currently recorded", company)
        self.assertIn("No customer or lead records are currently recorded", sales)

    def test_company_status_surfaces_github_permission_blocker(self):
        snapshot = status_fixture()
        snapshot["github_dispatches"] = [{
            "task_id": "developer-task", "task_title": "Implement approved product tasks",
            "status": "failed", "attempts": 3, "last_error": "github_permission_denied",
        }]
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("Engineering delivery", reply)
        self.assertIn("GitHub rejected the issue write using the configured repository token; verify its Issues write permission is active", reply)
        self.assertIn("attempt 3/3", reply)

    def test_company_status_surfaces_metered_codex_process_failure(self):
        snapshot = status_fixture()
        snapshot["tasks"].append({"id": "codex-task", "title": "Implement approved task",
                                  "status": "in_progress", "project_id": "project-1",
                                  "owner_agent_id": "pm-id"})
        snapshot["agent_runs"].append({"task_id": "codex-task", "status": "failed",
                                       "output": {"error_code": "codex_process_failed",
                                                  "failure_detail_code": "provider_rate_limited",
                                                  "process_exit_code": 1,
                                                  "codex_execution_status": "reconciled"}})
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("Codex execution failed (Codex exit code 1)", reply)
        self.assertIn("diagnostic provider_rate_limited", reply)
        self.assertIn("provider usage was reconciled, no PR was produced", reply)
        self.assertIn("no automatic retry is queued", reply)

    def test_delivery_health_is_scoped_to_company_and_engineering_roles(self):
        snapshot = status_fixture()
        snapshot["github_dispatches"] = [{
            "task_id": "developer-task", "task_title": "Implement approved product tasks",
            "status": "failed", "attempts": 3, "last_error": "github_permission_denied",
        }]
        self.assertNotIn("Engineering delivery", render_status_brief(snapshot, "sales"))
        self.assertIn("Engineering delivery", render_status_brief(snapshot, "cto"))

    def test_department_status_is_detailed_and_scoped_to_its_work(self):
        self.store.company_status.return_value = status_fixture()
        reply = self.router.handle(FOUNDER, FOUNDER, "CFO, give me department status.").text
        self.assertIn("CFO operating brief — board update", reply)
        self.assertIn("Active/approved/paused projects: 1", reply)
        self.assertIn("AI QA opportunity", reply)

    def test_board_status_lists_backlog_work_and_project_owners(self):
        snapshot = status_fixture()
        snapshot["tasks"].append({"id": "backlog-task", "title": "Prepare user interview plan",
                                  "status": "backlog", "project_id": "project-1",
                                  "owner_agent_id": "pm-id"})
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("Projects in motion", reply)
        self.assertIn("AI QA opportunity — approved; owner Chief Executive; requested ceiling EUR 500", reply)
        self.assertIn("Open tasks", reply)
        self.assertIn("[backlog] Prepare user interview plan — Product Manager", reply)
        self.assertIn("[blocked] Review product plan — Product Manager", reply)

    def test_board_status_reports_how_many_open_tasks_are_omitted(self):
        snapshot = status_fixture()
        snapshot["tasks"].extend({"id": f"backlog-{index}", "title": f"Backlog task {index}",
                                  "status": "backlog", "project_id": "project-1",
                                  "owner_agent_id": "pm-id"} for index in range(15))
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("16 tasks — 15 backlog", reply)
        self.assertIn("4 more open tasks omitted; see the Supabase task list", reply)

    def test_role_status_commands_cover_operating_roles(self):
        for role, expected in (("CTO", "cto"), ("Product Manager", "product manager"),
                               ("QA", "qa"), ("CMO", "cmo"), ("Governance", "governance")):
            with self.subTest(role=role):
                self.assertEqual(parse_founder_command(f"{role}, give me status").status_role, expected)

    def test_blocker_without_any_run_is_reported_as_missing_execution_evidence(self):
        snapshot = status_fixture()
        snapshot["tasks"].append({"id": "task-without-run", "title": "Unstarted review", "status": "blocked",
                                  "project_id": "project-1", "owner_agent_id": "cpo-id"})
        reply = render_status_brief(snapshot)
        self.assertIn("no execution run is linked to this task", reply)

    def test_status_database_failure_returns_a_clear_fail_closed_reply(self):
        self.store.company_status.side_effect = IntegrationError("unavailable")
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, give me company status.").text
        self.assertIn("couldn't load company status", reply)
        self.assertIn("No company state was changed", reply)

    def test_status_snapshot_reads_projects_tasks_approvals_and_financial_controls(self):
        expected = status_fixture()
        store = SupabaseREST("https://sutra.example", "server-key")
        store.request = Mock(side_effect=[expected[key] for key in expected if key != "github_dispatches"])
        store.rpc = Mock(return_value={"dispatches": expected["github_dispatches"]})
        self.assertEqual(store.company_status(), expected)
        requested_paths = [call.args[0] for call in store.request.call_args_list]
        self.assertTrue(any(path.startswith("projects?") and "requested_budget" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("objectives?") and "title" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("tasks?") and "owner_agent_id" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("approvals?") and "required_roles" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("budgets?") and "hard_stop" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("campaigns?") and "budget_amount" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("customers?") and "email" not in path for path in requested_paths))
        store.rpc.assert_called_once_with("sutra_company_github_dispatch_status", {})

    def test_status_snapshot_rejects_partial_or_malformed_database_responses(self):
        store = SupabaseREST("https://sutra.example", "server-key")
        malformed_responses = [[] for _ in range(11)]
        malformed_responses[6] = None
        store.request = Mock(side_effect=malformed_responses)
        store.rpc = Mock(return_value={"dispatches": []})
        with self.assertRaises(IntegrationError):
            store.company_status()

    def test_proposal_creates_persisted_approval_request(self):
        self.store.rpc.return_value = {"project_id": "project-1", "approval_id": "approval-1"}
        text = "Investigate an AI QA product. Initial budget maximum €500. Prepare a proposal."
        reply = self.router.handle(FOUNDER, FOUNDER, text).text
        self.assertIn("No spending is authorized until approval", reply)
        args = self.store.rpc.call_args
        self.assertEqual(args.args[0], "sutra_submit_proposal")
        self.assertEqual(args.args[1]["p_founder_telegram_user_id"], FOUNDER)
        self.assertEqual(args.args[1]["p_requested_budget"], 500)
        self.assertEqual(args.args[1]["p_name"], "AI QA product opportunity")

    def test_founder_can_decide_only_explicit_approval_command(self):
        self.store.rpc.return_value = {"status": "approved", "approval_id": APPROVAL}
        reply = self.router.handle(FOUNDER, FOUNDER, f"approve {APPROVAL} go ahead").text
        self.assertIn("approved", reply)
        self.assertEqual(self.store.rpc.call_args.args[0], "sutra_founder_decide_approval")
        self.assertEqual(self.store.rpc.call_args.args[1]["p_comment"], "go ahead")

    def test_founder_can_request_bounded_pm_review_retry(self):
        self.store.rpc.return_value = {"run_id": APPROVAL, "status": "queued"}
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry PM review {APPROVAL}").text
        self.assertIn("Unknown earlier usage remains reserved", reply)
        self.assertIn("project spending is not authorized", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_retry_pm_review", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_run_id": APPROVAL,
        })

    def test_pm_review_retry_rejects_wrong_founder_or_group_chat(self):
        for user_id, chat_id in (("987654321", "987654321"), (FOUNDER, "-100123")):
            with self.subTest(user_id=user_id, chat_id=chat_id):
                reply = self.router.handle(user_id, chat_id, f"retry PM review {APPROVAL}").text
                self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

    def test_pm_review_retry_rejects_malformed_run_id(self):
        self.assertEqual(parse_founder_command("retry PM review not-a-uuid").kind, "unsupported")
        self.router.handle(FOUNDER, FOUNDER, "retry PM review 00000000-0000-4000-8000-00000000000z")
        self.store.rpc.assert_not_called()

    def test_pm_review_retry_database_rejection_is_fail_closed(self):
        self.store.rpc.side_effect = IntegrationError("not eligible")
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry PM review {APPROVAL}").text
        self.assertIn("was not retried", reply)
        self.store.rpc.assert_called_once()

    def test_founder_can_request_bounded_pm_product_task_retry(self):
        self.store.rpc.return_value = {"task_id": APPROVAL, "status": "ready"}
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry PM task {APPROVAL}").text
        self.assertIn("PM task queued", reply)
        self.assertIn("Unknown earlier usage remains reserved", reply)
        self.assertIn("spending authority are unchanged", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_retry_product_task_artifact", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_task_id": APPROVAL,
        })

    def test_pm_product_task_retry_rejects_wrong_founder_or_group_chat(self):
        for user_id, chat_id in (("987654321", "987654321"), (FOUNDER, "-100123")):
            with self.subTest(user_id=user_id, chat_id=chat_id):
                reply = self.router.handle(user_id, chat_id, f"retry PM task {APPROVAL}").text
                self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

    def test_pm_product_task_retry_rejects_malformed_task_id(self):
        self.assertEqual(parse_founder_command("retry PM task not-a-uuid").kind, "unsupported")
        self.router.handle(FOUNDER, FOUNDER, "retry PM task 00000000-0000-4000-8000-00000000000z")
        self.store.rpc.assert_not_called()

    def test_pm_product_task_retry_database_rejection_is_fail_closed(self):
        self.store.rpc.side_effect = IntegrationError("not eligible")
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry PM task {APPROVAL}").text
        self.assertIn("task was not retried", reply)
        self.store.rpc.assert_called_once()

    def test_founder_can_request_bounded_architect_task_retry(self):
        self.store.rpc.return_value = {"task_id": APPROVAL, "status": "ready"}
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry Architect task {APPROVAL}").text
        self.assertIn("Architect task queued", reply)
        self.assertIn("Unknown earlier usage remains reserved", reply)
        self.assertIn("spending authority are unchanged", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_retry_architecture_task_artifact", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_task_id": APPROVAL,
        })

    def test_architect_task_retry_rejects_wrong_founder_or_group_chat(self):
        for user_id, chat_id in (("987654321", "987654321"), (FOUNDER, "-100123")):
            with self.subTest(user_id=user_id, chat_id=chat_id):
                reply = self.router.handle(user_id, chat_id, f"retry Architect task {APPROVAL}").text
                self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

    def test_architect_task_retry_rejects_malformed_task_id(self):
        self.assertEqual(parse_founder_command("retry Architect task not-a-uuid").kind, "unsupported")
        self.router.handle(FOUNDER, FOUNDER, "retry Architect task 00000000-0000-4000-8000-00000000000z")
        self.store.rpc.assert_not_called()

    def test_architect_task_retry_database_rejection_is_fail_closed(self):
        self.store.rpc.side_effect = IntegrationError("not eligible")
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry Architect task {APPROVAL}").text
        self.assertIn("Architect task was not retried", reply)
        self.store.rpc.assert_called_once()

    def test_founder_can_request_bounded_github_dispatch_retry(self):
        self.store.rpc.return_value = {"task_id": APPROVAL, "status": "queued", "founder_retry_number": 1}
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry GitHub dispatch {APPROVAL}").text
        self.assertIn("GitHub issue dispatch queued (founder retry 1/3)", reply)
        self.assertIn("no spending, merge, or release authority", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_retry_github_task_dispatch", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_task_id": APPROVAL,
        })

    def test_github_dispatch_retry_rejects_wrong_founder_or_group_chat(self):
        for user_id, chat_id in (("987654321", "987654321"), (FOUNDER, "-100123")):
            with self.subTest(user_id=user_id, chat_id=chat_id):
                reply = self.router.handle(user_id, chat_id, f"retry GitHub dispatch {APPROVAL}").text
                self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

    def test_github_dispatch_retry_rejects_malformed_task_id(self):
        self.assertEqual(parse_founder_command("retry GitHub dispatch not-a-uuid").kind, "unsupported")
        self.router.handle(FOUNDER, FOUNDER, "retry GitHub dispatch 00000000-0000-4000-8000-00000000000z")
        self.store.rpc.assert_not_called()

    def test_github_dispatch_retry_database_rejection_is_fail_closed(self):
        self.store.rpc.side_effect = IntegrationError("not eligible")
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry GitHub dispatch {APPROVAL}").text
        self.assertIn("GitHub dispatch was not retried", reply)
        self.store.rpc.assert_called_once()

    def test_founder_can_request_verified_no_request_codex_retry(self):
        self.store.rpc.return_value = {"task_id": APPROVAL, "status": "queued", "retry_number": 2,
                                      "attempt_number": 3, "max_total_attempts": 3}
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry Codex task {APPROVAL}").text
        self.assertIn("Codex attempt 3 of 3 queued", reply)
        self.assertIn("previous unknown reservation remains preserved", reply)
        self.assertIn("No project spending, merge, or release authority", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_retry_codex_task_execution", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_task_id": APPROVAL,
        })

    def test_codex_retry_approval_is_reported_without_launching(self):
        self.store.rpc.return_value = {"task_id": APPROVAL, "status": "awaiting_approval", "approval_id": APPROVAL,
                                      "attempt_number": 3, "max_total_attempts": 3}
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry Codex task {APPROVAL}").text
        self.assertIn(f"Codex attempt 3 of 3 is waiting for model-spend approval: {APPROVAL}", reply)
        self.store.rpc.assert_called_once()

    def test_founder_can_read_and_set_audited_codex_retry_limit_without_retrying(self):
        self.store.rpc.return_value = {"previous_total_attempts": 1, "max_total_attempts": 3,
                                      "changed": True, "no_retry_triggered": True}
        reply = self.router.handle(FOUNDER, FOUNDER,
                                  "CEO, set Codex no-request retry limit to 3 total attempts.").text
        self.assertIn("limit changed: 3 total attempts per execution", reply)
        self.assertIn("did not trigger a retry", reply)
        self.assertIn("monthly hard cap", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_set_codex_retry_limit", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_total_attempts": 3,
        })

        self.store.rpc.reset_mock()
        self.store.rpc.return_value = {"max_total_attempts": 3, "changed": False,
                                      "no_retry_triggered": True}
        reply = self.router.handle(FOUNDER, FOUNDER,
                                  "CEO, set Codex no-request retry limit to 3 total attempts.").text
        self.assertIn("already set to that value", reply)
        self.assertIn("no change or retry occurred", reply)
        self.store.rpc.assert_called_once()

        self.store.rpc.reset_mock()
        self.store.rpc.return_value = {"max_total_attempts": 3}
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, show Codex no-request retry limit.").text
        self.assertIn("Current Codex no-request retry limit: 3 total attempts", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_get_codex_retry_limit", {
            "p_founder_telegram_user_id": FOUNDER,
        })

    def test_codex_retry_limit_commands_validate_bounds_and_founder_identity(self):
        for value in ("0", "4", "6", "999"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_founder_command(f"set Codex no-request retry limit to {value}")
        self.assertEqual(parse_founder_command("set Codex retry limit to three").kind, "unsupported")
        reply = self.router.handle("987654321", "987654321",
                                   "CEO, set Codex no-request retry limit to 3 total attempts.").text
        self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

    def test_codex_retry_limit_database_rejection_does_not_retry_or_escalate(self):
        self.store.rpc.side_effect = IntegrationError("not founder")
        reply = self.router.handle(FOUNDER, FOUNDER,
                                   "CEO, set Codex no-request retry limit to 3 total attempts.").text
        self.assertIn("limit unchanged", reply)
        self.assertIn("Only the configured founder", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_set_codex_retry_limit", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_total_attempts": 3,
        })

    def test_codex_retry_rejects_wrong_founder_or_group_chat(self):
        for user_id, chat_id in (("987654321", "987654321"), (FOUNDER, "-100123")):
            with self.subTest(user_id=user_id, chat_id=chat_id):
                reply = self.router.handle(user_id, chat_id, f"retry Codex task {APPROVAL}").text
                self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

    def test_codex_retry_rejects_malformed_task_id(self):
        self.assertEqual(parse_founder_command("retry Codex task not-a-uuid").kind, "unsupported")
        self.router.handle(FOUNDER, FOUNDER, "retry Codex task 00000000-0000-4000-8000-00000000000z")
        self.store.rpc.assert_not_called()

    def test_codex_retry_database_rejection_is_fail_closed(self):
        self.store.rpc.side_effect = IntegrationError("not eligible")
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry Codex task {APPROVAL}").text
        self.assertIn("Codex was not retried", reply)
        self.store.rpc.assert_called_once()

    def test_founder_can_request_bounded_early_review_retry(self):
        self.store.rpc.return_value = {"run_id": APPROVAL, "status": "queued", "review_role": "cpo"}
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry agent review {APPROVAL}").text
        self.assertIn("CPO review queued", reply)
        self.assertIn("monthly hard cap", reply)
        self.assertIn("Unknown earlier usage remains reserved", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_retry_agent_review", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_run_id": APPROVAL,
        })

    def test_early_review_retry_rejects_wrong_founder_or_group_chat(self):
        for user_id, chat_id in (("987654321", "987654321"), (FOUNDER, "-100123")):
            with self.subTest(user_id=user_id, chat_id=chat_id):
                reply = self.router.handle(user_id, chat_id, f"retry agent review {APPROVAL}").text
                self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

    def test_early_review_retry_rejects_malformed_run_id(self):
        self.assertEqual(parse_founder_command("retry agent review not-a-uuid").kind, "unsupported")
        self.router.handle(FOUNDER, FOUNDER, "retry agent review 00000000-0000-4000-8000-00000000000z")
        self.store.rpc.assert_not_called()

    def test_early_review_retry_database_rejection_is_fail_closed(self):
        self.store.rpc.side_effect = IntegrationError("not eligible")
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry agent review {APPROVAL}").text
        self.assertIn("was not retried", reply)
        self.store.rpc.assert_called_once()

    def test_founder_can_list_pending_approvals_without_deciding_them(self):
        self.store.founder_pending_approvals.return_value = [{
            "approval_id": APPROVAL, "summary": "AI QA opportunity", "amount": 500,
            "currency": "EUR", "pending_roles": ["cfo"], "ready": False,
        }]
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, show my approvals.").text
        self.assertIn("AI QA opportunity", reply)
        self.assertIn("waiting for cfo", reply)
        self.assertIn(APPROVAL, reply)
        self.store.founder_pending_approvals.assert_called_once_with(FOUNDER)
        self.store.rpc.assert_not_called()

    def test_ready_founder_approval_queue_includes_inline_decision_buttons(self):
        self.store.founder_pending_approvals.return_value = [{
            "approval_id": APPROVAL, "summary": "AI QA opportunity", "amount": 500,
            "currency": "EUR", "pending_roles": [], "ready": True,
        }]
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, show my approvals.")
        self.assertIn("ready for your decision", reply.text)
        self.assertEqual(reply.reply_markup, {"inline_keyboard": [[
            {"text": "Approve", "callback_data": f"approve:{APPROVAL}"},
            {"text": "Reject", "callback_data": f"reject:{APPROVAL}"},
        ]]})
        self.store.rpc.assert_not_called()

    def test_developer_scope_approval_shows_concrete_design_and_security_risks(self):
        design = "Scoped interface design. " * 100
        self.store.founder_pending_approvals.return_value = [{
            "approval_id": APPROVAL, "approval_type": "developer_scope",
            "summary": "Founder scope review required before engineering",
            "amount": 0, "currency": "EUR", "pending_roles": [], "ready": True,
            "scope_review": {"design": design,
                             "security_risks": ["Protect service credentials"]},
        }]
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, show my approvals.")
        self.assertIn("Proposed implementation design: " + design[:1399] + "…", reply.text)
        self.assertNotIn(design[:1401], reply.text)
        self.assertIn("Security risks to review: Protect service credentials", reply.text)
        self.assertIn("does not approve spend or release", reply.text)
        self.assertLess(len(reply.text), 4096)
        self.assertEqual(reply.reply_markup["inline_keyboard"][0][0]["callback_data"], f"approve:{APPROVAL}")

    def test_approval_callback_records_founder_decision_through_database_rpc(self):
        self.store.rpc.return_value = {"status": "approved", "approval_id": APPROVAL}
        reply = self.router.handle_callback(FOUNDER, FOUNDER, f"approve:{APPROVAL}")
        self.assertEqual(reply, f"Approval approved: {APPROVAL}")
        self.store.rpc.assert_called_once_with("sutra_founder_decide_approval", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_approval_id": APPROVAL,
            "p_decision": "approve",
            "p_comment": "Approved from the founder's Telegram approval button.",
        })

    def test_approval_callback_rejects_nonfounder_group_and_malformed_actions(self):
        denied = self.router.handle_callback("987654321", "987654321", f"approve:{APPROVAL}")
        self.assertIn("restricted", denied)
        group = self.router.handle_callback(FOUNDER, "-100123", f"approve:{APPROVAL}")
        self.assertIn("restricted", group)
        malformed = self.router.handle_callback(FOUNDER, FOUNDER, f"approve:{APPROVAL[:-1]}z")
        self.assertIn("Invalid", malformed)
        self.store.rpc.assert_not_called()
        self.assertEqual(self.store.record_denied_identity.call_count, 2)

    def test_approval_callback_database_rejection_fails_closed(self):
        self.store.rpc.side_effect = IntegrationError("not ready")
        reply = self.router.handle_callback(FOUNDER, FOUNDER, f"approve:{APPROVAL}")
        self.assertIn("Approval unchanged", reply)

    def test_approval_queue_failure_fails_closed(self):
        self.store.founder_pending_approvals.side_effect = IntegrationError("unavailable")
        reply = self.router.handle(FOUNDER, FOUNDER, "show my approvals").text
        self.assertIn("No approval was changed", reply)
        self.store.rpc.assert_not_called()

    def test_rejects_nonfounder_and_group_chats(self):
        self.store.record_denied_identity.return_value = None
        response = self.router.handle("987654321", "987654321", "CEO, give me company status").text
        self.assertIn("restricted", response)
        self.store.company_status.assert_not_called()
        self.store.rpc.assert_not_called()
        self.store.record_denied_identity.assert_called_once()
        self.assertEqual(len(self.store.record_denied_identity.call_args.args[0]), 24)

        group_response = self.router.handle(FOUNDER, "-100123", "CEO, give me company status").text
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
        response = self.router.handle("1", "1", "CEO status").text
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
    def test_worker_execution_lease_rpc_requires_boolean_response(self):
        store = SupabaseREST("https://sutra.example", "server-key")
        store.request = Mock(side_effect=[True, True])
        worker_id = "sutra-worker-12345678"

        self.assertTrue(store.acquire_agent_worker_execution_lease(worker_id))
        self.assertTrue(store.release_agent_worker_execution_lease(worker_id))
        self.assertEqual(store.request.call_args_list[0].args, (
            "rpc/sutra_acquire_agent_worker_execution_lease", "POST", {"p_worker_id": worker_id},
        ))
        self.assertEqual(store.request.call_args_list[1].args, (
            "rpc/sutra_release_agent_worker_execution_lease", "POST", {"p_worker_id": worker_id},
        ))

        store.request.side_effect = None
        store.request.return_value = "true"
        with self.assertRaises(IntegrationError):
            store.acquire_agent_worker_execution_lease(worker_id)

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

    def test_codex_proxy_calls_use_database_leases_and_exact_token_usage(self):
        store = SupabaseREST("https://sutra.example", "server-key")
        store.rpc = Mock(side_effect=[{"authorized": True}, {"recorded": True},
                                     {"status": "reconciled"}, {"claimed": True}])
        worker_id, run_id, lease = "sutra-worker-12345678", "run-id", "lease-id"
        store.codex_start_request(worker_id, run_id, lease, "gpt-6-luna", 500, 128)
        store.codex_record_usage(worker_id, run_id, lease, 120, 40)
        store.codex_finish_run(worker_id, run_id, lease, True, True, 0, None)
        store.claim_codex_execution(worker_id, run_id, lease)
        self.assertEqual(store.rpc.call_args_list[0].args, ("sutra_codex_start_request", {
            "p_worker_id": worker_id, "p_run_id": run_id, "p_lease_token": lease,
            "p_model": "gpt-6-luna", "p_output_tokens": 500, "p_request_bytes": 128,
        }))
        self.assertEqual(store.rpc.call_args_list[1].args, ("sutra_codex_record_usage", {
            "p_worker_id": worker_id, "p_run_id": run_id, "p_lease_token": lease,
            "p_input_tokens": 120, "p_output_tokens": 40,
        }))
        self.assertEqual(store.rpc.call_args_list[2].args, ("sutra_codex_finish_run", {
            "p_worker_id": worker_id, "p_run_id": run_id, "p_lease_token": lease,
            "p_usage_trusted": True, "p_process_succeeded": True, "p_process_exit_code": 0,
            "p_failure_detail_code": None,
        }))
        self.assertEqual(store.rpc.call_args_list[3].args, ("sutra_claim_codex_execution", {
            "p_worker_id": worker_id, "p_run_id": run_id, "p_lease_token": lease,
        }))


class TelegramPollingTests(unittest.TestCase):
    def test_polling_routes_founder_approval_buttons_and_clears_them(self):
        class StopAfterOneUpdate:
            def __init__(self):
                self.checks = 0

            def is_set(self):
                self.checks += 1
                return self.checks > 1

            def wait(self, _seconds):
                return None

        store = Mock()
        store.rpc.return_value = {"status": "approved", "approval_id": APPROVAL}
        router = FounderCommandRouter(store, FOUNDER)
        update = {"update_id": 12, "callback_query": {
            "id": "callback-1", "data": f"approve:{APPROVAL}",
            "from": {"id": int(FOUNDER)},
            "message": {"message_id": 7, "chat": {"id": int(FOUNDER)}},
        }}
        with patch("sutra.runtime.telegram_call", side_effect=[[], [update], {"ok": True}, {"ok": True}]) as call:
            telegram_poll_loop("unit-test-token", router, StopAfterOneUpdate())
        methods = [item.args[1] for item in call.call_args_list]
        self.assertEqual(methods, ["getUpdates", "getUpdates", "answerCallbackQuery", "editMessageReplyMarkup"])
        store.rpc.assert_called_once_with("sutra_founder_decide_approval", {
            "p_founder_telegram_user_id": FOUNDER, "p_approval_id": APPROVAL,
            "p_decision": "approve", "p_comment": "Approved from the founder's Telegram approval button.",
        })

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
