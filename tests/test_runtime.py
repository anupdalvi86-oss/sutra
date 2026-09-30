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
    telegram_message_parts,
    telegram_poll_loop,
    validate_outbound_request,
)


FOUNDER = "123456789"
APPROVAL = "00000000-0000-4000-8000-000000000001"


def status_fixture():
    return {
        "projects": [{"id": "project-1", "name": "AI QA opportunity", "status": "approved",
                      "requested_budget": 500, "currency": "EUR", "department_id": "finance-dept",
                      "owner_agent_id": "ceo-id", "budget_assessment_status": "within_cap",
                      "legal_hold": False,
                      "budget_assessment": {"estimated_total_eur": 400, "confidence": "medium",
                                            "recommended_action": "proceed_within_cap"}}],
        "objectives": [{"id": "objective-1", "project_id": "project-1",
                        "title": "Validate buyer demand", "status": "active",
                        "owner_agent_id": "cpo-id"}],
        "tasks": [{"id": "task-1", "title": "Review product plan", "status": "blocked",
                   "project_id": "project-1", "owner_agent_id": "pm-id"}],
        "completed_tasks": [],
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
        "budget_ledger": [{"project_id": "project-1", "category": "ai_model_usage",
                           "reserved_amount": 0, "actual_amount": 0.15, "status": "actual",
                           "currency": "EUR"}],
        "campaigns": [{"id": "campaign-1", "project_id": "project-1", "name": "QA pilot positioning",
                       "channel": "internal", "status": "draft", "budget_amount": 0, "currency": "EUR"}],
        "customers": [{"id": "lead-1", "name": "Synthetic lead", "company": "Example Co",
                       "source": "test fixture", "status": "qualified"}],
        "customer_email_actions": [],
        "support_case_status": {
            "total": 4, "open": 3,
            "by_status": {"open": 2, "pending": 1, "solved": 1},
            "open_by_priority": {"urgent": 2, "normal": 1},
        },
        "legal_escalations": [],
        "github_dispatches": [],
    }


class FounderCommandTests(unittest.TestCase):
    def setUp(self):
        self.store = Mock()
        self.store.founder_legal_escalations.return_value = []
        self.router = FounderCommandRouter(self.store, FOUNDER)

    def test_kimi_probe_command_queues_one_founder_only_bounded_request(self):
        self.store.rpc.return_value = {"probe_id": "probe-1", "maximum_reservation_eur": 0.10}
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, run one bounded Kimi usage probe.").text
        self.assertIn("One-shot Kimi usage probe queued: probe-1", reply)
        self.assertIn("Maximum reservation: €0.10", reply)
        self.assertIn("up to three model iterations", reply)
        self.assertNotIn("one provider request", reply)
        self.assertIn("does not enable Kimi for ordinary role work", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_queue_kimi_usage_probe", {
            "p_founder_telegram_user_id": FOUNDER,
        })

    def test_kimi_probe_command_is_founder_only_and_database_failure_is_fail_closed(self):
        reply = self.router.handle("987654321", "987654321",
                                   "CEO, run one bounded Kimi usage probe.").text
        self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

        self.store.rpc.side_effect = IntegrationError("probe denied")
        reply = self.router.handle(FOUNDER, FOUNDER,
                                   "CEO, run one bounded Kimi usage probe.").text
        self.assertIn("probe was not queued", reply)
        self.assertIn("No provider request was made", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_queue_kimi_usage_probe", {
            "p_founder_telegram_user_id": FOUNDER,
        })

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
        self.store.founder_legal_escalations.assert_called_once_with(FOUNDER)

    def test_legal_escalation_commands_are_founder_only_and_persist_disposition(self):
        case_id = "00000000-0000-4000-8000-000000000019"
        parsed = parse_founder_command("CEO, show legal escalations.")
        self.assertEqual(parsed.kind, "legal_escalations")
        self.store.founder_legal_escalations.return_value = [{
            "id": case_id, "project_id": "project-1", "project_name": "AI QA opportunity",
            "project_status": "paused", "budget_cap": 500, "currency": "EUR",
            "summary": "Founder review is required before work resumes.", "status": "open",
        }]
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, show legal escalations.").text
        self.assertIn("Open legal escalations (1 shown)", reply)
        self.assertIn(case_id, reply)
        self.assertIn("project remains paused", reply)
        self.assertIn("does not resume work", reply)
        self.store.founder_legal_escalations.assert_called_with(FOUNDER)

        command = f"record legal case {case_id} as continue within budget because Counsel reviewed the proposed terms."
        parsed = parse_founder_command(command)
        self.assertEqual(parsed.kind, "record_legal_disposition")
        self.assertEqual(parsed.legal_case_id, case_id)
        self.assertEqual(parsed.legal_disposition, "continue_within_budget")
        self.store.rpc.return_value = {
            "case_id": case_id, "status": "reviewed", "disposition": "continue_within_budget",
            "project_id": "project-1", "project_status": "paused",
        }
        reply = self.router.handle(FOUNDER, FOUNDER, command).text
        self.assertIn("Founder disposition recorded", reply)
        self.assertIn("initiative remains paused", reply)
        self.assertIn("does not restart work", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_record_legal_disposition", {
            "p_founder_telegram_user_id": FOUNDER, "p_case_id": case_id,
            "p_disposition": "continue_within_budget",
            "p_reason": "Counsel reviewed the proposed terms",
        })

    def test_legal_escalation_command_fails_closed_for_nonfounder_and_bad_disposition(self):
        command = "CEO, show legal escalations."
        reply = self.router.handle("other-user", "other-user", command).text
        self.assertIn("restricted", reply)
        self.store.founder_legal_escalations.assert_not_called()
        self.store.rpc.assert_not_called()
        case_id = "00000000-0000-4000-8000-000000000019"
        for malformed in (
            f"record legal case {case_id} as sign because this must never be accepted",
            "record legal case not-a-uuid as stop because the input is malformed",
        ):
            with self.subTest(malformed=malformed):
                self.assertEqual(parse_founder_command(malformed).kind, "unsupported")
        with self.assertRaisesRegex(ValueError, "8 to 500 characters"):
            parse_founder_command(f"record legal case {case_id} as stop because short")
        self.store.rpc.side_effect = IntegrationError("case already closed")
        reply = self.router.handle(
            FOUNDER, FOUNDER,
            f"record legal case {case_id} as stop because the initiative should not proceed.",
        ).text
        self.assertIn("case remains open", reply)
        self.assertIn("only the configured founder", reply)

    def test_project_legal_hold_commands_are_founder_only_and_audited(self):
        project_id = "00000000-0000-4000-8000-000000000029"
        command = f"set legal hold {project_id} because a contract question needs review."
        parsed = parse_founder_command(command)
        self.assertEqual(parsed.kind, "set_project_legal_hold")
        self.assertEqual(parsed.project_id, project_id)
        self.assertIs(parsed.project_legal_hold, True)
        self.assertEqual(parsed.legal_reason, "a contract question needs review")
        self.store.rpc.return_value = {"project_id": project_id, "legal_hold": True, "changed": True}
        reply = self.router.handle(FOUNDER, FOUNDER, command).text
        self.assertIn("Audited legal hold set", reply)
        self.assertIn("blocks outbound customer email", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_set_project_legal_hold", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_project_id": project_id,
            "p_legal_hold": True,
            "p_reason": "a contract question needs review",
        })

        self.store.rpc.reset_mock()
        clear_command = f"clear legal hold for {project_id} because founder reviewed the question."
        self.store.rpc.return_value = {"project_id": project_id, "legal_hold": False, "changed": True}
        reply = self.router.handle(FOUNDER, FOUNDER, clear_command).text
        self.assertIn("legal hold cleared", reply)
        self.assertIn("does not resume a paused initiative", reply)

        self.store.rpc.reset_mock()
        reply = self.router.handle("other-user", "other-user", command).text
        self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()
        self.assertEqual(parse_founder_command(f"set legal hold not-a-uuid because this input is malformed").kind, "unsupported")
        with self.assertRaisesRegex(ValueError, "8 to 500 characters"):
            parse_founder_command(f"clear legal hold {project_id} because short")

    def test_founder_can_record_or_withdraw_audited_customer_crm_consent(self):
        customer_id = "00000000-0000-4000-8000-000000000031"
        record = f"CEO, record CRM consent for {customer_id} because customer signed CRM sharing form 42."
        parsed = parse_founder_command(record)
        self.assertEqual(parsed.kind, "set_customer_crm_consent")
        self.assertEqual(parsed.crm_customer_id, customer_id)
        self.assertIs(parsed.crm_consent, True)
        self.assertEqual(parsed.crm_consent_evidence, "customer signed CRM sharing form 42")
        self.store.rpc.return_value = {"customer_id": customer_id, "crm_sync_consent": True, "changed": True}
        self.assertIn("does not start a CRM sync", self.router.handle(FOUNDER, FOUNDER, record).text)
        self.store.rpc.assert_called_once_with("sutra_founder_set_customer_crm_consent", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_customer_id": customer_id,
            "p_consent": True,
            "p_evidence_source": "customer signed CRM sharing form 42",
        })

        self.store.rpc.reset_mock()
        self.store.rpc.return_value = {"customer_id": customer_id, "crm_sync_consent": False,
                                      "queued_actions_cancelled": 2, "changed": True}
        withdraw = f"withdraw customer CRM consent for {customer_id} because customer asked us to stop."
        reply = self.router.handle(FOUNDER, FOUNDER, withdraw).text
        self.assertIn("2 queued sync action(s) were cancelled", reply)
        self.assertIn("reservations released", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_set_customer_crm_consent", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_customer_id": customer_id,
            "p_consent": False,
            "p_evidence_source": "customer asked us to stop",
        })

        self.store.rpc.reset_mock()
        reply = self.router.handle("other-user", "other-user", record).text
        self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()
        self.assertEqual(parse_founder_command("record CRM consent for not-a-uuid because invalid record").kind,
                         "unsupported")
        with self.assertRaisesRegex(ValueError, "8 to 500 characters"):
            parse_founder_command(f"record CRM consent for {customer_id} because short")

    def test_board_status_explains_blocked_work_waiting_on_proposed_project_approval(self):
        snapshot = status_fixture()
        snapshot["projects"].append({
            "id": "proposed-project", "name": "Duplicate proposal", "status": "proposed",
            "requested_budget": 500, "currency": "EUR", "department_id": "product-dept",
            "owner_agent_id": "ceo-id",
        })
        snapshot["tasks"].append({
            "id": "proposed-cpo-task", "title": "Research duplicate proposal", "status": "blocked",
            "project_id": "proposed-project", "owner_agent_id": "cpo-id",
        })
        snapshot["approvals"].append({
            "id": "proposed-project-approval", "project_id": "proposed-project",
            "summary": "CFO review followed by founder approval", "amount": 500,
            "currency": "EUR", "status": "pending", "required_roles": ["cfo", "founder"],
            "decisions": {},
        })
        snapshot["agents"].append({
            "id": "cpo-id", "slug": "cpo", "display_name": "CPO", "department_id": "product-dept",
        })

        reply = render_status_brief(snapshot, "ceo")

        self.assertIn(
            "Research duplicate proposal — owned by CPO; its project is still proposed and awaits "
            "project-budget approval; no execution run or model spend was started.", reply,
        )
        self.assertIn("CFO review followed by founder approval — EUR 500; awaiting cfo, founder", reply)

    def test_board_status_explains_blocked_work_on_role_rejected_project(self):
        snapshot = status_fixture()
        snapshot["projects"][0]["status"] = "rejected"
        snapshot["tasks"][0]["project_id"] = "project-1"
        snapshot["tasks"][0]["status"] = "blocked"
        snapshot["agent_runs"] = []

        reply = render_status_brief(snapshot, "ceo")

        self.assertIn(
            "Review product plan — owned by Product Manager; its project-budget approval was rejected; "
            "no execution run or model spend was started.", reply,
        )

    def test_board_status_includes_objectives_campaigns_and_customer_pipeline(self):
        reply = render_status_brief(status_fixture(), "ceo")
        self.assertIn("Objective [active]: Validate buyer demand", reply)
        self.assertIn("Marketing pipeline", reply)
        self.assertIn("[draft] QA pilot positioning — internal", reply)
        self.assertIn("Customer communications", reply)
        self.assertIn("No budgeted customer email actions are queued or recorded", reply)
        self.assertIn("Customer support queue", reply)
        self.assertIn("3 open; 1 solved or closed; 4 total", reply)
        self.assertIn("Open priority: normal: 1, urgent: 2", reply)

    def test_status_reports_customer_email_action_state_without_disclosing_content(self):
        snapshot = status_fixture()
        snapshot["customer_email_actions"] = [{
            "id": "action-1", "project_id": "project-1", "purpose": "sales",
            "status": "queued", "subject": "private subject", "body_text": "private content",
        }]
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("[queued] sales email action — ID action-1", reply)
        self.assertNotIn("private subject", reply)
        self.assertNotIn("private content", reply)

        snapshot["projects"][0]["legal_hold"] = True
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("Legal hold active: external customer email is blocked", reply)
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
        self.assertIn("Customer support queue", sales)
        self.assertNotIn("Customer support queue", marketing)

    def test_support_status_is_scoped_to_operations_and_empty_queue_is_explicit(self):
        snapshot = status_fixture()
        snapshot["support_case_status"] = {
            "total": 0, "open": 0, "by_status": {}, "open_by_priority": {},
        }
        company = render_status_brief(snapshot, "ceo")
        operations = render_status_brief(snapshot, "coo")
        developer = render_status_brief(snapshot, "developer")
        self.assertIn("No support tickets recorded", company)
        self.assertIn("No support tickets recorded", operations)
        self.assertNotIn("Customer support queue", developer)

    def test_support_status_failure_is_not_reported_as_an_empty_queue(self):
        snapshot = status_fixture()
        snapshot["support_case_status"] = None
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("Support queue data is unavailable; no case counts inferred", reply)

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
        self.assertNotIn("\n• \n", company)
        self.assertNotIn("\n• \n", marketing)
        self.assertNotIn("\n• \n", sales)

    def test_company_status_surfaces_github_permission_blocker(self):
        snapshot = status_fixture()
        snapshot["github_dispatches"] = [{
            "task_id": "developer-task", "task_title": "Implement approved product tasks",
            "status": "failed", "attempts": 3, "last_error": "github_permission_denied",
        }]
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("Engineering delivery", reply)
        self.assertIn("GitHub rejected the issue write using the configured repository token; verify its Issues write permission is active", reply)
        self.assertIn("dispatch attempts 3/3", reply)

    def test_company_status_reports_verified_merged_delivery_without_false_blocker(self):
        snapshot = status_fixture()
        sha = "a" * 40
        snapshot["github_dispatches"] = [{
            "task_id": "developer-task", "task_title": "Implement approved product tasks",
            "status": "created", "attempts": 1, "last_error": None,
            "pull_request_number": 160,
            "pull_request_url": "https://github.com/anupdalvi86-oss/sutra/pull/160",
            "pull_request_merged": True, "pull_request_head_sha": sha,
            "ci_conclusion": "success", "ci_head_sha": sha,
        }]

        reply = render_status_brief(snapshot, "ceo")

        self.assertIn("merged PR passed CI on the same commit", reply)
        self.assertIn("PR #160 merged", reply)
        self.assertIn("CI: success", reply)
        self.assertNotIn("GitHub delivery needs attention", reply)
        self.assertNotIn("attempt 1/3", reply)
        self.assertIn("dispatch attempts 1/3", reply)

    def test_company_status_does_not_call_ci_success_matching_if_commit_differs(self):
        snapshot = status_fixture()
        snapshot["github_dispatches"] = [{
            "task_id": "developer-task", "task_title": "Implement approved product tasks",
            "status": "created", "pull_request_number": 160,
            "pull_request_merged": False, "pull_request_head_sha": "a" * 40,
            "ci_conclusion": "success", "ci_head_sha": "b" * 40,
        }]

        reply = render_status_brief(snapshot, "ceo")

        self.assertIn("matching successful CI or merge evidence is pending", reply)
        self.assertNotIn("open PR passed CI on the same commit", reply)

    def test_company_status_reports_premerge_review_and_release_state(self):
        snapshot = status_fixture()
        snapshot["github_dispatches"] = [{
            "task_id": "developer-task", "task_title": "Implement approved product tasks",
            "status": "created", "pull_request_number": 160,
            "pull_request_merged": False, "pull_request_head_sha": "a" * 40,
            "ci_conclusion": "success", "ci_head_sha": "a" * 40,
        }]
        snapshot["code_releases"] = [{
            "task_id": "developer-task", "status": "blocked",
            "detail_code": "github_permission_denied",
        }]
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("automatic merge is blocked (github_permission_denied)", reply)
        self.assertNotIn("open PR passed CI on the same commit; QA/Security review or merge is pending", reply)

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

    def test_company_status_reports_open_pr_when_codex_run_failed_and_ci_is_unrecorded(self):
        snapshot = status_fixture()
        task = {"id": "codex-task", "title": "Implement approved task", "status": "blocked",
                "project_id": "project-1", "owner_agent_id": "pm-id"}
        snapshot["tasks"].append(task)
        snapshot["agent_runs"].append({"task_id": "codex-task", "status": "failed",
                                       "output": {"error_code": "codex_process_failed",
                                                  "process_exit_code": 1,
                                                  "codex_execution_status": "reconciled"}})
        snapshot["github_dispatches"] = [{
            "task_id": "codex-task", "task_title": "Implement approved task", "status": "created",
            "pull_request_number": 160,
            "pull_request_url": "https://github.com/anupdalvi86-oss/sutra/pull/160",
            "pull_request_merged": False, "ci_conclusion": None,
        }]

        reply = render_status_brief(snapshot, "ceo")

        self.assertIn("Implement approved task — owned by Product Manager; latest failed run recorded codex_process_failed; GitHub PR #160 is not merged and CI evidence has not been recorded.", reply)
        self.assertIn("PR #160 not merged (https://github.com/anupdalvi86-oss/sutra/pull/160); CI evidence not recorded", reply)
        self.assertNotIn("no PR was produced", reply)

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
        self.assertIn("Legal escalations requiring founder review: 0", reply)

    def test_board_status_includes_objectives_campaigns_and_customer_pipeline(self):
        reply = render_status_brief(status_fixture(), "ceo")
        self.assertIn("Objective [active]: Validate buyer demand", reply)
        self.assertIn("Marketing pipeline", reply)
        self.assertIn("[draft] QA pilot positioning — internal", reply)
        self.assertIn("Customer and lead pipeline", reply)
        self.assertIn("[qualified] Synthetic lead (Example Co) — test fixture", reply)

    def test_board_status_includes_legal_escalations_and_scopes_them_to_department(self):
        snapshot = status_fixture()
        snapshot["agents"].append({
            "id": "cpo-id", "slug": "cpo", "display_name": "CPO", "department_id": "product-dept",
        })
        snapshot["projects"].append({
            "id": "product-project", "name": "Product initiative", "status": "paused",
            "requested_budget": 500, "currency": "EUR", "department_id": "product-dept",
            "owner_agent_id": "cpo-id",
        })
        snapshot["legal_escalations"] = [{
            "id": "legal-case-1", "project_id": "product-project", "project_name": "Product initiative",
            "summary": "CFO flagged proposed binding terms for founder review.",
        }, {
            "id": "legal-case-2", "project_id": "another-project", "project_name": "Other project",
            "summary": "Different department case.",
        }]
        company = render_status_brief(snapshot, "ceo")
        self.assertIn("Legal escalations requiring founder review: 2", company)
        self.assertIn("legal-case-1", company)
        self.assertIn("legal-case-2", company)
        product = render_status_brief(snapshot, "cpo")
        self.assertIn("Product initiative — CFO flagged proposed binding terms", product)
        self.assertNotIn("Other project", product)

    def test_marketing_and_sales_statuses_include_their_operating_pipelines(self):
        snapshot = status_fixture()
        marketing = render_status_brief(snapshot, "cmo")
        self.assertIn("Marketing pipeline", marketing)
        self.assertNotIn("Customer and lead pipeline", marketing)
        sales = render_status_brief(snapshot, "sales")
        self.assertIn("Customer and lead pipeline", sales)
        self.assertNotIn("Marketing pipeline", sales)
        self.assertNotIn("Engineering delivery", sales)

    def test_board_status_lists_backlog_work_and_project_owners(self):
        snapshot = status_fixture()
        snapshot["tasks"].append({"id": "backlog-task", "title": "Prepare user interview plan",
                                  "status": "backlog", "project_id": "project-1",
                                  "owner_agent_id": "pm-id"})
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("Projects in motion", reply)
        self.assertIn("AI QA opportunity — approved; owner Chief Executive; all-in cap EUR 500.00", reply)
        self.assertIn("CFO estimated all-in cost EUR 400.00; confidence medium", reply)
        self.assertIn("Open tasks", reply)
        self.assertIn("[backlog] Prepare user interview plan — Product Manager", reply)
        self.assertIn("[blocked] Review product plan — Product Manager", reply)

    def test_board_status_lists_recent_completions_without_counting_them_as_open(self):
        snapshot = status_fixture()
        snapshot["completed_tasks"].append({"id": "done-task", "title": "Prepare sales handoff",
                                            "status": "done", "project_id": "project-1",
                                            "owner_agent_id": "sales-id", "updated_at": "2026-09-29T10:00:00Z"})
        snapshot["agents"].append({"id": "sales-id", "slug": "sales", "display_name": "Sales",
                                   "department_id": "sales-dept"})

        reply = render_status_brief(snapshot, "ceo")

        self.assertIn("1 tasks — 0 backlog, 0 ready, 0 in progress, 0 in review, 1 blocked", reply)
        self.assertIn("Recent completions", reply)
        self.assertIn("Prepare sales handoff — Sales — AI QA opportunity", reply)
        self.assertNotIn("[done] Prepare sales handoff", reply)

    def test_board_status_reports_how_many_open_tasks_are_omitted(self):
        snapshot = status_fixture()
        snapshot["tasks"].extend({"id": f"backlog-{index}", "title": f"Backlog task {index}",
                                  "status": "backlog", "project_id": "project-1",
                                  "owner_agent_id": "pm-id"} for index in range(15))
        reply = render_status_brief(snapshot, "ceo")
        self.assertIn("16 tasks — 15 backlog", reply)
        self.assertIn("4 more open tasks omitted; see the Supabase task list", reply)

    def test_board_status_reports_deferred_reviews_as_incomplete(self):
        snapshot = status_fixture()
        snapshot["tasks"].append({"id": "deferred-qa", "title": "Verify acceptance criteria",
                                  "status": "deferred", "project_id": "project-1",
                                  "owner_agent_id": "qa-id",
                                  "deferred_reason": "Founder deferred QA temporarily; no pass is claimed."})
        snapshot["agents"].append({"id": "qa-id", "slug": "qa", "display_name": "Quality Assurance",
                                   "department_id": "product-dept"})

        reply = render_status_brief(snapshot, "ceo")

        self.assertIn("Deferred quality reviews", reply)
        self.assertIn("[deferred; incomplete] Verify acceptance criteria — Quality Assurance", reply)
        self.assertIn("Founder deferred QA temporarily", reply)
        self.assertIn("Deferred QA/Security reviews: 1 (incomplete)", reply)

    def test_founder_can_defer_and_restore_review_task_through_audited_database_commands(self):
        self.store.rpc.return_value = {
            "task_id": APPROVAL, "status": "deferred", "role": "qa",
            "released_internal_planning_tasks": [{"task_id": "child-task", "role": "security"}],
        }
        reply = self.router.handle(
            FOUNDER, FOUNDER,
            f"defer review task {APPROVAL} because Founder directed QA to wait; no pass is claimed.",
        ).text
        self.assertIn("Founder deferral recorded", reply)
        self.assertIn("remains incomplete", reply)
        self.assertIn("1 directly dependent internal planning task", reply)
        self.assertIn("no spending, merge, or release authority", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_defer_task", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_task_id": APPROVAL,
            "p_reason": "Founder directed QA to wait; no pass is claimed",
        })

        self.store.rpc.reset_mock()
        self.store.rpc.return_value = {"task_id": APPROVAL, "status": "ready", "role": "qa"}
        reply = self.router.handle(
            FOUNDER, FOUNDER,
            f"restore review task {APPROVAL} because Founder is ready to resume QA review.",
        ).text
        self.assertIn("restored the qa task to the ready queue", reply)
        self.assertIn("no spending, merge, or release authority", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_restore_deferred_task", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_task_id": APPROVAL,
            "p_reason": "Founder is ready to resume QA review",
        })

    def test_review_deferral_commands_require_founder_private_chat_and_valid_reason(self):
        command = f"defer review task {APPROVAL} because Founder temporarily pauses QA."
        for user_id, chat_id in (("987654321", "987654321"), (FOUNDER, "-100123")):
            with self.subTest(user_id=user_id, chat_id=chat_id):
                reply = self.router.handle(user_id, chat_id, command).text
                self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

        for bad_command in (
            "defer review task not-a-uuid because a valid reason is supplied",
            f"defer review task {APPROVAL} without a reason",
        ):
            with self.subTest(command=bad_command):
                self.assertEqual(parse_founder_command(bad_command).kind, "unsupported")
                self.router.handle(FOUNDER, FOUNDER, bad_command)
        with self.assertRaisesRegex(ValueError, "8 to 500 characters"):
            parse_founder_command(f"defer review task {APPROVAL} because short")
        self.store.rpc.assert_not_called()

    def test_review_deferral_database_failure_fails_closed(self):
        self.store.rpc.side_effect = IntegrationError("not eligible")
        reply = self.router.handle(
            FOUNDER, FOUNDER,
            f"defer review task {APPROVAL} because Founder temporarily defers this QA review.",
        ).text
        self.assertIn("couldn't defer that review task", reply)
        self.assertIn("check the task status before trying again", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_defer_task", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_task_id": APPROVAL,
            "p_reason": "Founder temporarily defers this QA review",
        })

    def test_founder_can_atomically_defer_qa_and_security_without_releasing_security_between_steps(self):
        self.store.rpc.return_value = {
            "qa": {"status": "deferred"},
            "security": {"status": "deferred", "released_internal_planning_tasks": [
                {"task_id": "devops-task", "role": "devops"},
            ]},
            "qa_and_security_incomplete": True,
            "release_authority_granted": False,
        }
        command = (
            f"defer QA and Security reviews for task {APPROVAL} because "
            "Founder directed both reviews to pause temporarily; neither passes."
        )
        reply = self.router.handle(FOUNDER, FOUNDER, command).text

        self.assertIn("Founder deferral recorded for QA and Security", reply)
        self.assertIn("Both reviews remain incomplete", reply)
        self.assertIn("1 directly dependent internal DevOps planning task", reply)
        self.assertIn("no spending, merge, or release authority", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_defer_quality_chain", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_qa_task_id": APPROVAL,
            "p_reason": "Founder directed both reviews to pause temporarily; neither passes",
        })

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

    def test_supabase_http_errors_expose_only_a_safe_status_category(self):
        store = SupabaseREST("https://sutra.example", "server-key")
        upstream = urllib.error.HTTPError(
            "https://sutra.example/rest/v1/rpc/secret", 403, "private database detail",
            {}, None,
        )
        with patch("sutra.runtime.open_outbound_request", side_effect=upstream):
            with self.assertRaises(IntegrationError) as caught:
                store.request("rpc/sutra_claim_ready_code_release", "POST", {})

        self.assertEqual(caught.exception.code, "supabase_http_403")
        self.assertNotIn("private database detail", str(caught.exception))
        self.assertNotIn("secret", str(caught.exception))

    def test_status_snapshot_reads_projects_tasks_approvals_and_financial_controls(self):
        expected = status_fixture()
        expected["code_releases"] = []
        expected["status_errors"] = []
        store = SupabaseREST("https://sutra.example", "server-key")
        request_order = (
            "projects", "objectives", "tasks", "completed_tasks", "approvals", "agent_runs",
            "agents", "departments", "budgets", "expenses", "budget_ledger", "campaigns",
            "customers", "customer_email_actions",
        )
        store.request = Mock(side_effect=[expected[key] for key in request_order] + [
            expected["support_case_status"], expected["code_releases"],
        ])
        store.rpc = Mock(return_value={"dispatches": expected["github_dispatches"]})
        expected.pop("legal_escalations")
        self.assertEqual(store.company_status(), expected)
        requested_paths = [call.args[0] for call in store.request.call_args_list]
        self.assertTrue(any(path.startswith("projects?") and "requested_budget" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("objectives?") and "title" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("tasks?") and "owner_agent_id" in path
                            and "deferred_reason" in path and "deferred" in path and "done" not in path
                            for path in requested_paths))
        self.assertTrue(any(path.startswith("tasks?") and "status=eq.done" in path
                            and "limit=20" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("approvals?") and "required_roles" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("budgets?") and "hard_stop" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("initiative_budget_ledger?") and "actual_amount" in path
                            for path in requested_paths))
        self.assertTrue(any(path.startswith("campaigns?") and "budget_amount" in path for path in requested_paths))
        self.assertTrue(any(path.startswith("customers?") and "email" not in path for path in requested_paths))
        self.assertTrue(any(path.startswith("customer_email_actions?") and "body_text" not in path
                            and "recipient_email" not in path for path in requested_paths))
        self.assertIn("rpc/sutra_company_support_case_status", requested_paths)
        self.assertEqual(store.request.call_args_list[-1], unittest.mock.call(
            "rpc/sutra_company_code_release_status", "POST", {}))
        self.assertEqual(store.rpc.call_args_list, [
            unittest.mock.call("sutra_company_github_dispatch_status", {}),
        ])

    def test_status_snapshot_keeps_healthy_sections_when_one_source_is_unavailable(self):
        store = SupabaseREST("https://sutra.example", "server-key")
        malformed_responses = [[] for _ in range(16)]
        malformed_responses[6] = None
        store.request = Mock(side_effect=malformed_responses)
        store.rpc = Mock(return_value={"dispatches": []})
        status = store.company_status()
        self.assertEqual(status["status_errors"], ["agents", "support_cases"])
        self.assertEqual(status["agents"], [])
        self.assertEqual(status["projects"], [])
        self.assertEqual(status["code_releases"], [])

    def test_status_snapshot_records_failed_rpc_without_discarding_other_sources(self):
        store = SupabaseREST("https://sutra.example", "server-key")
        store.request = Mock(return_value=[])
        store.rpc = Mock(side_effect=IntegrationError("unavailable"))
        status = store.company_status()
        self.assertEqual(status["status_errors"], ["support_cases", "github_dispatches"])
        self.assertEqual(status["github_dispatches"], [])
        self.assertEqual(status["code_releases"], [])

    def test_status_render_warns_that_partial_counts_are_incomplete(self):
        snapshot = status_fixture()
        snapshot["status_errors"] = ["projects", "customer_email_actions"]
        reply = render_status_brief(snapshot, "CEO")
        self.assertIn("Data completeness warning", reply)
        self.assertIn("projects, customer_email_actions", reply)
        self.assertIn("Counts below reflect returned data only", reply)

    def test_founder_legal_escalation_adapter_validates_database_response(self):
        store = SupabaseREST("https://sutra.example", "server-key")
        store.rpc = Mock(return_value={"escalations": [{"id": "legal-case-1"}]})
        self.assertEqual(store.founder_legal_escalations(FOUNDER), [{"id": "legal-case-1"}])
        store.rpc.assert_called_once_with("sutra_founder_list_legal_escalations", {
            "p_founder_telegram_user_id": FOUNDER,
        })
        store.rpc.return_value = {"escalations": {"bad": "shape"}}
        with self.assertRaises(IntegrationError):
            store.founder_legal_escalations(FOUNDER)

    def test_proposal_creates_persisted_approval_request(self):
        self.store.rpc.return_value = {"project_id": "project-1", "approval_id": "approval-1"}
        text = "Investigate an AI QA product. Initial budget maximum €500. Prepare a proposal."
        reply = self.router.handle(FOUNDER, FOUNDER, text).text
        self.assertIn("All-in initiative ceiling", reply)
        self.assertIn("Any increase pauses for your decision", reply)
        self.assertIn("CEO → Product → CTO → CFO → PM review", reply)
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
        self.assertNotIn("final attempt", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_retry_pm_review", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_run_id": APPROVAL,
        })

    def test_founder_pm_final_recovery_explains_fresh_capped_reservation(self):
        self.store.rpc.return_value = {
            "run_id": APPROVAL, "status": "queued", "final_recovery_attempt": True,
            "attempts_remaining": 1, "preserved_unknown_reservations": 1,
        }
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry PM review {APPROVAL}").text
        self.assertIn("final attempt", reply)
        self.assertIn("fresh reservation", reply)
        self.assertIn("monthly hard cap", reply)
        self.assertIn("Unknown earlier usage remains reserved", reply)
        self.assertIn("project spending is not authorized", reply)

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

    def test_founder_can_request_one_time_sales_artifact_recovery(self):
        self.store.rpc.return_value = {"task_id": APPROVAL, "status": "ready"}
        reply = self.router.handle(
            FOUNDER, FOUNDER, f"retry Sales task {APPROVAL} after artifact schema fix"
        ).text
        self.assertIn("Sales task queued", reply)
        self.assertIn("one-time recovery", reply)
        self.assertIn("normal three-attempt limit", reply)
        self.assertIn("monthly hard cap", reply)
        self.assertIn("No project spending, merge, or release authority", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_retry_sales_task_artifact", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_task_id": APPROVAL,
        })

    def test_sales_artifact_recovery_rejects_wrong_founder_or_group_chat(self):
        command = f"retry Sales task {APPROVAL} after artifact schema fix"
        for user_id, chat_id in (("987654321", "987654321"), (FOUNDER, "-100123")):
            with self.subTest(user_id=user_id, chat_id=chat_id):
                reply = self.router.handle(user_id, chat_id, command).text
                self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

    def test_sales_artifact_recovery_rejects_malformed_task_id(self):
        self.assertEqual(
            parse_founder_command("retry Sales task not-a-uuid after artifact schema fix").kind,
            "unsupported",
        )
        self.router.handle(
            FOUNDER, FOUNDER,
            "retry Sales task 00000000-0000-4000-8000-00000000000z after artifact schema fix",
        )
        self.store.rpc.assert_not_called()

    def test_sales_artifact_recovery_database_rejection_is_fail_closed(self):
        self.store.rpc.side_effect = IntegrationError("not eligible")
        reply = self.router.handle(
            FOUNDER, FOUNDER, f"retry Sales task {APPROVAL} after artifact schema fix"
        ).text
        self.assertIn("Sales task was not retried", reply)
        self.store.rpc.assert_called_once()

    def test_founder_can_retry_the_same_cpo_research_task(self):
        self.store.rpc.return_value = {"task_id": APPROVAL, "status": "ready", "model": "gpt-6-luna"}
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry CPO research {APPROVAL}").text
        self.assertIn("CPO research task queued", reply)
        self.assertIn("OpenAI GPT-6 Luna", reply)
        self.assertIn("prior unknown reservation remains held", reply)
        self.assertIn("monthly hard cap", reply)
        self.assertIn("no project spending, merge, or release authority", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_retry_cpo_research_task", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_task_id": APPROVAL,
        })

    def test_cpo_research_retry_rejects_wrong_founder_or_group_chat(self):
        for user_id, chat_id in (("987654321", "987654321"), (FOUNDER, "-100123")):
            with self.subTest(user_id=user_id, chat_id=chat_id):
                reply = self.router.handle(user_id, chat_id, f"retry CPO research {APPROVAL}").text
                self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

    def test_cpo_research_retry_rejects_malformed_task_id(self):
        self.assertEqual(parse_founder_command("retry CPO research not-a-uuid").kind, "unsupported")
        self.router.handle(FOUNDER, FOUNDER, "retry CPO research 00000000-0000-4000-8000-00000000000z")
        self.store.rpc.assert_not_called()

    def test_cpo_research_retry_database_rejection_is_fail_closed(self):
        self.store.rpc.side_effect = IntegrationError("not eligible")
        reply = self.router.handle(FOUNDER, FOUNDER, f"retry CPO research {APPROVAL}").text
        self.assertIn("CPO research was not retried", reply)
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

    def test_founder_can_read_and_set_audited_email_cost_ceiling_without_sending(self):
        self.store.rpc.return_value = {"configured": True, "previous_max_message_cost_eur": None,
                                      "max_message_cost_eur": 0.05, "changed": True, "no_email_sent": True}
        command = "CEO, set customer email cost ceiling to €0.05 because bounded provider cost per message."
        parsed = parse_founder_command(command)
        self.assertEqual(parsed.kind, "set_email_cost_ceiling")
        self.assertEqual(parsed.email_cost_ceiling, 0.05)
        self.assertEqual(parsed.email_cost_reason, "bounded provider cost per message")
        reply = self.router.handle(FOUNDER, FOUNDER, command).text
        self.assertIn("changed to EUR 0.05", reply)
        self.assertIn("audit logged", reply)
        self.assertIn("no email was sent", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_set_customer_email_cost_ceiling", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_max_message_cost_eur": 0.05,
            "p_reason": "bounded provider cost per message",
        })

        self.store.rpc.reset_mock()
        self.store.rpc.return_value = {"configured": True, "max_message_cost_eur": 0.05}
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, show customer email cost ceiling.").text
        self.assertIn("EUR 0.05", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_get_customer_email_cost_ceiling", {
            "p_founder_telegram_user_id": FOUNDER,
        })

    def test_email_cost_ceiling_commands_fail_closed_for_nonfounder_and_bad_values(self):
        for amount in ("0", "100.01"):
            with self.subTest(amount=amount), self.assertRaises(ValueError):
                parse_founder_command(f"set customer email cost ceiling to €{amount} because valid audit reason")
        for amount in ("0.005", "1.001", "NaN"):
            with self.subTest(amount=amount), self.assertRaisesRegex(ValueError, "in cents"):
                parse_founder_command(f"set customer email cost ceiling to €{amount} because valid audit reason")
        with self.assertRaisesRegex(ValueError, "8 to 500 characters"):
            parse_founder_command("set customer email cost ceiling to €0.05 because short")
        self.assertEqual(parse_founder_command("set customer email ceiling to €0.05 because reason long enough").kind,
                         "unsupported")
        reply = self.router.handle("987654321", "987654321",
                                   "CEO, set customer email cost ceiling to €0.05 because test reason is long enough.").text
        self.assertIn("restricted", reply)
        self.store.rpc.assert_not_called()

        self.store.rpc.side_effect = IntegrationError("database rejects setting")
        reply = self.router.handle(FOUNDER, FOUNDER,
                                   "CEO, set customer email cost ceiling to €0.05 because test reason is long enough.").text
        self.assertIn("ceiling unchanged", reply)
        self.assertIn("Only the configured founder", reply)

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

    def test_founder_can_review_and_revoke_standing_code_authority(self):
        authorization_id = "00000000-0000-4000-8000-0000000000ab"
        parsed = parse_founder_command("CEO, show standing code authority.")
        self.assertEqual(parsed.kind, "code_authority_status")
        self.store.rpc.return_value = {
            "authorization_id": authorization_id, "active": True,
            "repository": "anupdalvi86-oss/sutra",
            "capabilities": ["create_developer_tasks", "create_branches", "open_pull_requests",
                             "merge_pull_requests", "run_qa", "run_security", "deploy"],
        }
        reply = self.router.handle(FOUNDER, FOUNDER, "CEO, show standing code authority.").text
        self.assertIn("Standing code authority is active", reply)
        self.assertIn("does not change spending limits or budgets", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_code_authorization_status", {
            "p_founder_telegram_user_id": FOUNDER,
        })

        command = f"CEO, revoke standing code authority {authorization_id} because Founder is ending this grant."
        parsed = parse_founder_command(command)
        self.assertEqual(parsed.kind, "revoke_code_authority")
        self.assertEqual(parsed.authorization_id, authorization_id)
        self.assertEqual(parsed.authorization_reason, "Founder is ending this grant")
        self.store.rpc.reset_mock()
        self.store.rpc.return_value = {"authorization_id": authorization_id, "active": False}
        reply = self.router.handle(FOUNDER, FOUNDER, command).text
        self.assertIn("is revoked and the change is audit logged", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_revoke_code_authorization", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_authorization_id": authorization_id,
            "p_reason": "Founder is ending this grant",
        })

    def test_standing_code_authority_commands_reject_malformed_or_nonfounder_requests(self):
        self.assertEqual(parse_founder_command("revoke code authority not-a-uuid because invalid").kind, "unsupported")
        authorization_id = "00000000-0000-4000-8000-0000000000ab"
        with self.assertRaisesRegex(ValueError, "8 to 500 characters"):
            parse_founder_command(f"revoke standing code authority {authorization_id} because short")
        reply = self.router.handle("other-user", "other-user", "CEO, show standing code authority.").text
        self.assertIn("restricted", reply)
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
        self.assertEqual(parse_founder_command("Investigate a product").kind, "budget_required")
        self.assertEqual(parse_founder_command("Build a customer support product for small teams.").kind, "budget_required")
        with self.assertRaises(ValueError):
            parse_founder_command(" ")
        with self.assertRaises(ValueError):
            parse_founder_command("x" * 3001)
        self.router.handle(FOUNDER, FOUNDER, "change everything")
        self.store.rpc.assert_not_called()

    def test_founder_can_change_initiative_budget_with_reason(self):
        project_id = "00000000-0000-4000-8000-000000000004"
        parsed = parse_founder_command(
            f"Increase initiative budget {project_id} to €750 because supplier estimate increased."
        )
        self.assertEqual(parsed.kind, "set_project_budget")
        self.assertEqual(parsed.project_id, project_id)
        self.assertEqual(parsed.new_budget, 750)
        self.store.rpc.return_value = {
            "project_id": project_id, "old_budget": 500, "new_budget": 750,
            "committed": 200, "remaining_budget": 550,
        }
        reply = self.router.handle(
            FOUNDER, FOUNDER,
            f"Increase initiative budget {project_id} to €750 because supplier estimate increased.",
        ).text
        self.assertIn("Audited all-in budget change", reply)
        self.assertIn("€550.00 remains", reply)
        self.store.rpc.assert_called_once_with("sutra_founder_set_project_budget", {
            "p_founder_telegram_user_id": FOUNDER,
            "p_project_id": project_id,
            "p_new_budget": 750,
            "p_reason": "supplier estimate increased",
        })

    def test_non_founder_cannot_change_initiative_budget(self):
        project_id = "00000000-0000-4000-8000-000000000004"
        response = self.router.handle("not-founder", "not-founder", "change budget").text
        self.assertIn("restricted", response)
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
    def test_long_status_is_sent_as_bounded_messages_with_markup_on_last_part(self):
        class StopAfterOneUpdate:
            def __init__(self):
                self.checks = 0

            def is_set(self):
                self.checks += 1
                return self.checks > 1

            def wait(self, _seconds):
                return None

        router = Mock()
        router.handle.return_value = type("Reply", (), {
            "text": "Projects\n" + "x" * 5000 + "\nFinancial controls\n€8 monthly hard cap",
            "reply_markup": {"inline_keyboard": []},
        })()
        update = {"update_id": 13, "message": {
            "from": {"id": int(FOUNDER)}, "chat": {"id": int(FOUNDER)}, "text": "CEO status",
        }}
        with patch("sutra.runtime.telegram_call", side_effect=[[], [update], {"ok": True}, {"ok": True}, {"ok": True}]) as call:
            telegram_poll_loop("unit-test-token", router, StopAfterOneUpdate())

        sends = [item.args[2] for item in call.call_args_list if item.args[1] == "sendMessage"]
        self.assertEqual(len(sends), 3)
        self.assertTrue(all(len(item["text"]) <= 3900 for item in sends))
        self.assertIn("part 1 of 3", sends[0]["text"])
        self.assertIn("part 3 of 3", sends[2]["text"])
        self.assertNotIn("reply_markup", sends[0])
        self.assertNotIn("reply_markup", sends[1])
        self.assertEqual(sends[2]["reply_markup"], {"inline_keyboard": []})
        self.assertIn("Financial controls", sends[2]["text"])
        self.assertIn("€8 monthly hard cap", sends[2]["text"])

    def test_telegram_message_parts_keep_short_text_and_bound_long_text(self):
        self.assertEqual(telegram_message_parts("short report"), ["short report"])
        parts = telegram_message_parts("first\n" + ("long detail " * 1000) + "\nlast", max_chars=256)
        self.assertGreater(len(parts), 2)
        self.assertTrue(all(len(part) <= 256 for part in parts))
        self.assertIn("first", parts[0])
        self.assertIn("last", parts[-1])
        self.assertTrue(all(part.startswith("Status update — part ") for part in parts))

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
