import json
import unittest
from unittest.mock import Mock, patch

from sutra.runtime import IntegrationError
from sutra.worker import AgentOutputError, AgentWorker, HermesAgentClient, _safe_failure_detail_code, validate_agent_artifact


def artifact(role="ceo"):
    result = {
        "summary": "A bounded review of the founder's stated proposal.",
        "recommendation": "Collect customer evidence before committing delivery effort.",
        "evidence": [],
        "risks": ["The brief does not identify target buyers."],
    }
    if role == "cpo":
        result["evidence"] = [{
            "source": "Primary product documentation",
            "url": "https://example.com/docs",
            "claim": "The product describes its target workflow.",
        }]
    if role == "product_manager":
        result["evidence"] = [{
            "source": "Primary product documentation",
            "url": "https://example.com/docs",
            "claim": "The existing workflow supports the proposed product scope.",
        }]
        result["milestones"] = ["Validate buyer problem", "Define prototype scope"]
        result["acceptance_criteria"] = ["Buyer evidence is documented", "Prototype outcomes are measurable"]
    if role == "cfo":
        result.update(decision="approve", decision_rationale="The requested budget is reviewable under current policy.")
    return result


def claimed_run(role="ceo"):
    return {
        "run_id": "00000000-0000-4000-8000-000000000001",
        "lease_token": "00000000-0000-4000-8000-000000000002",
        "agent": {"id": "00000000-0000-4000-8000-000000000003", "slug": role, "responsibilities": ["review"]},
        "project": {"name": "AI QA product opportunity", "description": "Investigate product demand.",
                    "status": "approved", "founder_project_budget_approved": True,
                    "requested_budget": 500, "currency": "EUR"},
        "input": {"request": "Founder proposal."},
        "spending_policies": [{"name": "Founder tier", "min_amount": 200}],
        "applicable_budgets": [],
        "prior_results": [],
    }


def task_review_run(role="qa"):
    run = claimed_run(role)
    run["task_review"] = {
        "task_id": "00000000-0000-4000-8000-000000000010",
        "title": "Verify acceptance criteria",
        "acceptance_criteria": ["Acceptance criteria have evidence", "Failures are recorded"],
        "tested_commit_sha": "a" * 40,
        "pull_request_url": "https://github.com/acme/sutra/pull/88",
        "ci_run_url": "https://github.com/acme/sutra/actions/runs/201",
    }
    return run


def task_review_artifact(role="qa"):
    result = {
        "summary": "The implementation passes the assigned acceptance checks.",
        "recommendation": "Release to the Security review stage.",
        "result": "pass",
        "tested_commit_sha": "a" * 40,
        "acceptance_criteria": [
            {"criterion": criterion, "result": "pass", "evidence_url": "https://github.com/acme/sutra/actions/runs/201"}
            for criterion in task_review_run(role)["task_review"]["acceptance_criteria"]
        ],
    }
    if role == "qa":
        result["tests"] = [{"name": "automated regression suite", "result": "pass", "evidence_url": "https://github.com/acme/sutra/actions/runs/201"}]
    else:
        result.update(checks=[{"name": "dependency scan", "result": "pass", "evidence_url": "https://github.com/acme/sutra/actions/runs/201"}],
                      findings=[], release_blockers=[])
    return result


def task_artifact_run(role="product_manager"):
    artifact_types = {
        "product_manager": "product_plan", "architect": "technical_design", "coo": "operations_plan",
        "devops": "release_plan", "cmo": "campaign_draft", "sales": "sales_handoff",
        "governance_audit": "governance_review",
    }
    run = claimed_run(role)
    run["task_artifact"] = {
        "task_id": "00000000-0000-4000-8000-000000000010", "role": role,
        "artifact_type": artifact_types[role], "title": "Prepare an internal task deliverable",
        "description": "Create a specific, reviewable output for the approved project.",
        "acceptance_criteria": ["The output is recorded", "The handoff is actionable"],
    }
    run["prior_results"] = [{
        "role": "cpo", "stage": "founder_proposal",
        "evidence": [{"source": "CPO source", "url": "https://example.com/cpo", "claim": "CPO claim."}],
    }]
    return run


def task_artifact_output(role="product_manager"):
    role_artifacts = {
        "product_manager": {"scope": "A bounded product scope for the approved proposal.", "milestones": ["Discovery"], "acceptance_criteria": ["Buyer need documented"]},
        "architect": {"design": "A clear component and interface design.", "components": ["API service"], "security_risks": ["Protect service credentials"]},
        "coo": {"operational_dependencies": ["On-call owner"], "readiness_checklist": ["Recovery procedure"], "incident_plan": "Route incidents to the service owner."},
        "devops": {"deployment_steps": ["Deploy candidate"], "health_checks": ["Verify health endpoint"], "rollback_steps": ["Restore previous image"]},
        "cmo": {"audience": "Engineering leaders evaluating quality tooling.", "positioning": "Reduce repetitive quality checks.", "draft_copy": "A draft for founder review only.", "claims": ["Supports this workflow"], "success_metrics": ["Qualified interest"]},
        "sales": {"ideal_customer_profile": "Software teams with repeatable release processes.", "lead_criteria": ["Relevant team size"], "qualification_questions": ["How do you verify releases?"], "first_contact_draft": "Internal draft; do not send without approval."},
        "governance_audit": {"controls_checked": ["Approval gate"], "findings": ["No open finding"], "recommendation": "Retain the existing founder approval gate."},
    }
    result = {
        "summary": "A durable role-specific artifact has been prepared.",
        "recommendation": "Proceed to the next assigned review stage.",
        "evidence": [],
        "task_acceptance": [
            {"criterion": criterion, "evidence": "Recorded in the bounded role artifact."}
            for criterion in task_artifact_run(role)["task_artifact"]["acceptance_criteria"]
        ],
        "artifact": role_artifacts[role],
    }
    if role == "cmo":
        result["evidence"] = [{"source": "Primary source", "url": "https://example.com/product", "claim": "The source supports the campaign claim."}]
    if role == "product_manager":
        result["evidence"] = [{"source": "Primary source", "url": "https://example.com/product", "claim": "The source supports the product planning assumption."}]
    return result


class AgentArtifactTests(unittest.TestCase):
    def test_task_artifact_contracts_cover_internal_role_handoffs(self):
        roles = ("product_manager", "architect", "coo", "devops", "cmo", "sales", "governance_audit")
        for role in roles:
            with self.subTest(role=role):
                result = validate_agent_artifact(role, task_artifact_output(role), task_artifact_run(role))
                self.assertEqual(len(result["task_acceptance"]), 2)
                self.assertTrue(result["artifact"])

    def test_task_artifacts_require_matching_acceptance_criteria_and_cited_campaign_claims(self):
        run = task_artifact_run("architect")
        invalid = task_artifact_output("architect")
        invalid["task_acceptance"][0]["criterion"] = "not assigned"
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("architect", invalid, run)
        campaign = task_artifact_output("cmo")
        campaign["evidence"] = []
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("cmo", campaign, task_artifact_run("cmo"))

    def test_product_plan_task_requires_at_least_one_direct_https_source(self):
        result = task_artifact_output("product_manager")
        result["evidence"] = []
        with self.assertRaisesRegex(AgentOutputError, "at least one cited HTTPS source"):
            validate_agent_artifact("product_manager", result, task_artifact_run("product_manager"))

    def test_task_artifact_prompt_has_no_external_action_authority(self):
        response = {"choices": [{"message": {"content": json.dumps(task_artifact_output("sales"))}}],
                    "usage": {"prompt_tokens": 20, "completion_tokens": 30}}
        fake_response = Mock()
        fake_response.__enter__ = Mock(return_value=fake_response)
        fake_response.__exit__ = Mock(return_value=False)
        fake_response.read.return_value = json.dumps(response).encode()
        with patch("sutra.worker.urllib.request.urlopen", return_value=fake_response) as request:
            client = HermesAgentClient("https://hermes.example", "hermes-key", "openai", "gpt-4o-mini")
            client.review(task_artifact_run("sales"), max_output_tokens=500)
        prompt = json.loads(request.call_args.args[0].data)["messages"][0]["content"]
        self.assertIn("Do not invent actual leads, contact anyone, or send messages", prompt)
        self.assertIn("task_acceptance", request.call_args.args[0].data.decode())

    def test_product_task_prompt_shows_exact_criterion_evidence_contract(self):
        response = {"choices": [{"message": {"content": json.dumps(task_artifact_output())}}],
                    "usage": {"prompt_tokens": 20, "completion_tokens": 30}}
        fake_response = Mock()
        fake_response.__enter__ = Mock(return_value=fake_response)
        fake_response.__exit__ = Mock(return_value=False)
        fake_response.read.return_value = json.dumps(response).encode()
        with patch("sutra.worker.urllib.request.urlopen", return_value=fake_response) as request:
            client = HermesAgentClient("https://hermes.example", "hermes-key", "openai", "gpt-4o-mini")
            client.review(task_artifact_run("product_manager"), max_output_tokens=500)
        messages = json.loads(request.call_args.args[0].data)["messages"]
        prompt = messages[0]["content"]
        task_context = messages[1]["content"]
        self.assertIn('"criterion":"COPY THE ASSIGNED CRITERION VERBATIM"', prompt)
        self.assertIn('"evidence":"Explain where the persisted deliverable satisfies it"', prompt)
        self.assertIn("Do not claim project approval is missing when the supplied flag is true", prompt)
        self.assertIn("The output is recorded", task_context)
        self.assertIn("The handoff is actionable", task_context)
        self.assertIn('"status":"approved"', task_context)
        self.assertIn('"founder_project_budget_approved":true', task_context)
        self.assertIn("https://example.com/cpo", task_context)

    def test_qa_and_security_artifacts_are_bound_to_database_claim_and_have_complete_evidence(self):
        for role in ("qa", "security"):
            result = validate_agent_artifact(role, task_review_artifact(role), task_review_run(role))
            self.assertEqual(result["tested_commit_sha"], "a" * 40)
            self.assertEqual(len(result["acceptance_criteria"]), 2)
        invalid = task_review_artifact("qa")
        invalid["tested_commit_sha"] = "b" * 40
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("qa", invalid, task_review_run("qa"))

    def test_qa_cannot_pass_failed_test_and_security_cannot_pass_open_high_finding(self):
        qa = task_review_artifact("qa")
        qa["tests"][0]["result"] = "fail"
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("qa", qa, task_review_run("qa"))
        security = task_review_artifact("security")
        security["findings"] = [{"severity": "high", "status": "open", "summary": "Exposed secret", "owner": "Security", "remediation": "Rotate credential"}]
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("security", security, task_review_run("security"))

    def test_product_research_requires_https_evidence(self):
        self.assertEqual(len(validate_agent_artifact("cpo", artifact("cpo"))["evidence"]), 1)
        invalid = artifact("cpo")
        invalid["evidence"][0]["url"] = "http://example.com"
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("cpo", invalid)

    def test_product_manager_plan_requires_evidence_milestones_and_acceptance_criteria(self):
        plan = validate_agent_artifact("product_manager", artifact("product_manager"))
        self.assertEqual(len(plan["milestones"]), 2)
        self.assertEqual(len(plan["acceptance_criteria"]), 2)
        for field in ("evidence", "milestones", "acceptance_criteria"):
            invalid = artifact("product_manager")
            invalid[field] = []
            with self.subTest(field=field), self.assertRaises(AgentOutputError):
                validate_agent_artifact("product_manager", invalid)

    def test_failure_diagnostics_name_product_plan_contract_field_without_model_text(self):
        self.assertEqual(
            _safe_failure_detail_code("Artifact milestones must be a bounded string list"),
            "invalid_milestones",
        )
        self.assertEqual(
            _safe_failure_detail_code("Artifact acceptance_criteria must be a bounded string list"),
            "invalid_acceptance_criteria",
        )
        self.assertEqual(
            _safe_failure_detail_code("Product plan requires milestones and acceptance criteria"),
            "missing_product_plan_sections",
        )

    def test_top_level_non_object_model_output_has_safe_specific_diagnostic(self):
        with self.assertRaises(AgentOutputError) as raised:
            validate_agent_artifact("product_manager", [{"summary": "not the contract"}], claimed_run("product_manager"))
        self.assertEqual(raised.exception.failure_detail_code, "invalid_top_level_json_object")
        self.assertNotIn("not the contract", str(raised.exception))

    def test_product_research_cannot_succeed_without_sources(self):
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("cpo", artifact())

    def test_cfo_artifact_requires_explicit_decision(self):
        value = artifact("cfo")
        validate_agent_artifact("cfo", value)
        value["decision"] = "founder_can_approve"
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("cfo", value)

    def test_cfo_prompt_keeps_founder_threshold_as_the_next_approval_gate(self):
        response_body = {"choices": [{"message": {"content": json.dumps(artifact("cfo"))}}],
                         "usage": {"prompt_tokens": 20, "completion_tokens": 30}}
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(response_body).encode()
        with patch("sutra.worker.urllib.request.urlopen", return_value=response) as request:
            HermesAgentClient("https://hermes.example", "hermes-key", "openai", "gpt-6-luna").review(
                claimed_run("cfo"), max_output_tokens=500)
        system_prompt = json.loads(request.call_args.args[0].data)["messages"][0]["content"]
        self.assertIn("never reject solely because founder approval has not happened yet", system_prompt)
        self.assertIn("no spending occurs until that gate is approved", system_prompt)

    def test_hermes_only_allows_https_or_private_railway_url(self):
        with self.assertRaises(ValueError):
            HermesAgentClient("http://public.example", "secret")
        with self.assertRaises(ValueError):
            HermesAgentClient("https://user:pass@example.com", "secret")
        self.assertEqual(
            HermesAgentClient("http://hermes.railway.internal:8642", "secret").endpoint,
            "http://hermes.railway.internal:8642/v1/chat/completions",
        )

    def test_model_call_uses_untrusted_input_boundary_and_no_database_secret(self):
        usage = {"prompt_tokens": 30, "completion_tokens": 40, "total_tokens": 70}
        payload = {"choices": [{"message": {"content": json.dumps(artifact())}}], "usage": usage}
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(payload).encode()
        with patch("sutra.worker.urllib.request.urlopen", return_value=response) as request:
            client = HermesAgentClient("https://hermes.example", "hermes-key", "openai", "gpt-4o-mini")
            result, observed_usage = client.review(claimed_run(), max_output_tokens=500)
        self.assertEqual(result["summary"], artifact()["summary"])
        self.assertEqual(observed_usage["completion_tokens"], 40)
        request_body = json.loads(request.call_args.args[0].data)
        self.assertEqual(request_body["model"], "gpt-4o-mini")
        self.assertEqual(request_body["provider"], "openai")
        self.assertTrue(request_body["require_model_lock"])
        self.assertEqual(request_body["max_tokens"], 500)
        system_prompt = request_body["messages"][0]["content"]
        self.assertIn("untrusted data", system_prompt)
        self.assertIn("no spending", system_prompt)
        self.assertNotIn("SUPABASE_SERVICE_ROLE_KEY", request_body["messages"][1]["content"])
        self.assertNotIn("tools", request_body)
        self.assertEqual(request.call_args.kwargs["timeout"], 180.0)

    def test_missing_or_malformed_hermes_usage_envelope_is_not_known_usage(self):
        cases = (("absent", None, "usage_missing"), ("malformed", ["private-response-marker"],
                  "usage_not_object:list"))
        for label, usage, expected_shape in cases:
            with self.subTest(label=label):
                payload = {"choices": [{"message": {"content": json.dumps(artifact())}}]}
                if label != "absent":
                    payload["usage"] = usage
                response = Mock()
                response.__enter__ = Mock(return_value=response)
                response.__exit__ = Mock(return_value=False)
                response.read.return_value = json.dumps(payload).encode()
                with patch("sutra.worker.urllib.request.urlopen", return_value=response), \
                     self.assertLogs("sutra.worker", level="WARNING") as captured:
                    _result, observed_usage = HermesAgentClient(
                        "https://hermes.example", "hermes-key", "kimi-coding", "kimi-k2.6"
                    ).review(claimed_run(), max_output_tokens=500)
                self.assertIsNone(observed_usage)
                diagnostic = "\n".join(captured.output)
                self.assertIn("provider=kimi-coding", diagnostic)
                self.assertIn("model=kimi-k2.6", diagnostic)
                self.assertIn(f"shape={expected_shape}", diagnostic)
                self.assertNotIn("private-response-marker", diagnostic)

    def test_malformed_usage_object_logs_only_field_types_not_values(self):
        payload = {"choices": [{"message": {"content": json.dumps(artifact())}}],
                   "usage": {"prompt_tokens": "private-token-count", "completion_tokens": 40}}
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(payload).encode()
        with patch("sutra.worker.urllib.request.urlopen", return_value=response), \
             self.assertLogs("sutra.worker", level="WARNING") as captured:
            _result, observed_usage = HermesAgentClient(
                "https://hermes.example", "hermes-key", "kimi-coding", "kimi-k2.6"
            ).review(claimed_run(), max_output_tokens=500)
        self.assertEqual(observed_usage["prompt_tokens"], "private-token-count")
        self.assertIn("prompt_tokens=string", captured.output[0])
        self.assertIn("completion_tokens=int", captured.output[0])
        self.assertIn("total_tokens=missing", captured.output[0])
        self.assertNotIn("private-token-count", captured.output[0])

    def test_unrecognized_model_route_is_redacted_from_usage_diagnostics(self):
        payload = {"choices": [{"message": {"content": json.dumps(artifact())}}]}
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(payload).encode()
        secret_like_model = "sk-production-secret-marker-123456"
        with patch("sutra.worker.urllib.request.urlopen", return_value=response), \
             self.assertLogs("sutra.worker", level="WARNING") as captured:
            HermesAgentClient(
                "https://hermes.example", "hermes-key", "custom-provider", secret_like_model
            ).review(claimed_run(), max_output_tokens=500)
        self.assertIn("provider=other model=other", captured.output[0])
        self.assertNotIn(secret_like_model, captured.output[0])

    def test_product_manager_requests_json_mode_and_explicit_object_contract(self):
        payload = {"choices": [{"message": {"content": json.dumps(artifact("product_manager"))}}],
                   "usage": {"prompt_tokens": 30, "completion_tokens": 40}}
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(payload).encode()
        with patch("sutra.worker.urllib.request.urlopen", return_value=response) as request:
            result, _usage = HermesAgentClient(
                "https://hermes.example", "hermes-key", "openai", "gpt-6-luna"
            ).review(claimed_run("product_manager"), max_output_tokens=500)
        request_body = json.loads(request.call_args.args[0].data)
        self.assertEqual(request_body["model_options"]["response_format"], {"type": "json_object"})
        system_prompt = request_body["messages"][0]["content"]
        self.assertIn("exactly one JSON object", system_prompt)
        self.assertIn("must be a string, never an object or nested array", system_prompt)
        self.assertIn("acceptance_criteria", result)

    def test_model_call_accepts_whitespace_around_a_fenced_json_object(self):
        content = "  \n```json\n" + json.dumps(artifact()) + "\n```  \n"
        payload = {"choices": [{"message": {"content": content}}],
                   "usage": {"prompt_tokens": 30, "completion_tokens": 40}}
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(payload).encode()
        with patch("sutra.worker.urllib.request.urlopen", return_value=response):
            result, usage = HermesAgentClient(
                "https://hermes.example", "hermes-key", "openai", "gpt-4o-mini"
            ).review(claimed_run(), max_output_tokens=500)
        self.assertEqual(result["summary"], artifact()["summary"])
        self.assertEqual(usage["completion_tokens"], 40)

    def test_malformed_fenced_json_is_rejected_with_a_safe_detail_code(self):
        payload = {"choices": [{"message": {"content": "```json\n{}\n``` trailing text"}}],
                   "usage": {"prompt_tokens": 30, "completion_tokens": 40}}
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(payload).encode()
        with patch("sutra.worker.urllib.request.urlopen", return_value=response):
            with self.assertRaises(AgentOutputError) as raised:
                HermesAgentClient(
                    "https://hermes.example", "hermes-key", "openai", "gpt-4o-mini"
                ).review(claimed_run(), max_output_tokens=500)
        self.assertEqual(raised.exception.failure_category, "invalid_hermes_response")
        self.assertEqual(raised.exception.failure_detail_code, "malformed_json")
        self.assertEqual(raised.exception.usage["completion_tokens"], 40)

    def test_model_request_over_input_ceiling_never_reaches_hermes(self):
        client = HermesAgentClient("https://hermes.example", "hermes-key", "openai", "gpt-4o-mini")
        with patch("sutra.worker.urllib.request.urlopen") as request:
            with self.assertRaises(AgentOutputError):
                client.review(claimed_run(), max_input_tokens=1)
        request.assert_not_called()

    def approved_store(self, role="ceo"):
        store = Mock()
        store.claim_agent_run.return_value = claimed_run(role)
        store.reserve_agent_run_spend.return_value = {
            "status": "approved", "reservation_id": "reservation-1",
            "max_input_tokens": 100_000, "max_output_tokens": 500,
        }
        store.reconcile_agent_run_spend.side_effect = lambda *_args: {
            "status": "unknown" if _args[-1] is None else "reconciled"}
        return store

    def test_invalid_model_artifact_is_retried_and_not_marked_succeeded(self):
        store = self.approved_store("cpo")
        hermes = Mock()
        hermes.review.side_effect = AgentOutputError("bad output")
        worker = AgentWorker(store, hermes, "openai", "gpt-4o-mini", worker_id="sutra-worker-12345678")
        self.assertEqual(worker.run_once(), "failed_unknown_spend")
        store.begin_agent_run_spend.assert_called_once_with("sutra-worker-12345678", claimed_run("cpo"), "reservation-1")
        store.reconcile_agent_run_spend.assert_called_once_with(
            "sutra-worker-12345678", claimed_run("cpo"), "reservation-1", "openai", "gpt-4o-mini", None)
        store.complete_agent_run.assert_called_once_with(
            "sutra-worker-12345678", claimed_run("cpo"), "failed",
            {
                "summary": "Hermes artifact failed validation and usage could not be verified",
                "failure_category": "invalid_agent_artifact",
                "failure_detail_code": "invalid_agent_output",
                "usage_state": "unverified",
            }, "unknown_or_overrun_spend",
        )

    def test_invalid_hermes_response_records_only_a_safe_failure_category(self):
        store = self.approved_store("cpo")
        hermes = Mock()
        hermes.review.side_effect = AgentOutputError("Hermes returned malformed JSON including untrusted response")
        worker = AgentWorker(store, hermes, "openai", "gpt-4o-mini", worker_id="sutra-worker-12345678")

        self.assertEqual(worker.run_once(), "failed_unknown_spend")
        output = store.complete_agent_run.call_args.args[3]
        self.assertEqual(output["failure_category"], "invalid_hermes_response")
        self.assertEqual(output["failure_detail_code"], "malformed_json")
        self.assertEqual(output["usage_state"], "unverified")
        self.assertNotIn("untrusted response", str(output))

    def test_unavailable_hermes_retains_reserve_and_fails_run(self):
        store = self.approved_store()
        hermes = Mock()
        hermes.review.side_effect = IntegrationError("offline")
        worker = AgentWorker(store, hermes, "openai", "gpt-4o-mini", worker_id="sutra-worker-12345678")
        self.assertEqual(worker.run_once(), "failed_unknown_spend")
        self.assertEqual(store.reconcile_agent_run_spend.call_args.args[-1], None)
        self.assertEqual(store.complete_agent_run.call_args.args[2], "failed")
        self.assertEqual(store.complete_agent_run.call_args.args[4], "unknown_spend")

    def test_incomplete_provider_usage_retries_reconciliation_as_unknown(self):
        store = self.approved_store("cpo")
        store.reconcile_agent_run_spend.side_effect = [
            IntegrationError("database rejected malformed provider usage"),
            {"status": "unknown"},
        ]
        payload = {
            "choices": [{"message": {"content": json.dumps(artifact("cpo"))}}],
            "usage": {"prompt_tokens": 20},
        }
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(payload).encode()
        hermes = HermesAgentClient("https://hermes.example", "hermes-key", "openai", "gpt-6-luna")
        worker = AgentWorker(store, hermes, "openai", "gpt-6-luna", worker_id="sutra-worker-12345678")

        with patch("sutra.worker.urllib.request.urlopen", return_value=response):
            self.assertEqual(worker.run_once(), "failed_unknown_spend")

        calls = store.reconcile_agent_run_spend.call_args_list
        self.assertEqual(len(calls), 2)
        self.assertIsNone(calls[1].args[-1])
        self.assertEqual(store.complete_agent_run.call_args.args[2], "failed")
        self.assertEqual(store.complete_agent_run.call_args.args[4], "unknown_or_overrun_spend")

    def test_pending_database_spend_approval_never_calls_hermes(self):
        store = self.approved_store()
        store.reserve_agent_run_spend.return_value = {"status": "requested", "approval_id": "approval-1"}
        hermes = Mock()
        worker = AgentWorker(store, hermes, "openai", "gpt-4o-mini", worker_id="sutra-worker-12345678")
        self.assertEqual(worker.run_once(), "blocked_spend_approval")
        hermes.review.assert_not_called()
        store.begin_agent_run_spend.assert_not_called()

    def test_role_route_is_used_for_preflight_instead_of_default_provider(self):
        store = self.approved_store("architect")
        hermes = Mock()
        hermes.review.return_value = (artifact("architect"), {"prompt_tokens": 20, "completion_tokens": 30})
        store.reconcile_agent_run_spend.return_value = {"status": "reconciled"}
        routes = {"architect": ("kimi-coding", "kimi-k2.6")}
        worker = AgentWorker(store, hermes, "openai", "gpt-6-luna",
                             worker_id="sutra-worker-12345678", role_routes=routes)
        self.assertEqual(worker.run_once(), "succeeded")
        store.reserve_agent_run_spend.assert_called_once_with(
            "sutra-worker-12345678", claimed_run("architect"), "kimi-coding", "kimi-k2.6")
        hermes.review.assert_called_once_with(claimed_run("architect"), "kimi-coding", "kimi-k2.6", 500, 100_000)
        store.reconcile_agent_run_spend.assert_called_once_with(
            "sutra-worker-12345678", claimed_run("architect"), "reservation-1",
            "kimi-coding", "kimi-k2.6", {"prompt_tokens": 20, "completion_tokens": 30})

    def test_success_requires_spend_reserve_start_usage_settlement_then_completion(self):
        events = []
        store = self.approved_store()
        store.reserve_agent_run_spend.side_effect = lambda *_args: (events.append("reserve") or store.reserve_agent_run_spend.return_value)
        store.begin_agent_run_spend.side_effect = lambda *_args: events.append("begin")
        store.reconcile_agent_run_spend.side_effect = lambda *_args: (events.append("reconcile") or {"status": "reconciled"})
        store.complete_agent_run.side_effect = lambda *_args: events.append("complete")
        hermes = Mock()
        hermes.review.side_effect = lambda *_args: (events.append("hermes") or (artifact(), {"prompt_tokens": 20, "completion_tokens": 30}))
        worker = AgentWorker(store, hermes, "openai", "gpt-4o-mini", worker_id="sutra-worker-12345678")
        self.assertEqual(worker.run_once(), "succeeded")
        self.assertEqual(events, ["reserve", "begin", "hermes", "reconcile", "complete"])

    def test_qa_worker_submits_persisted_review_only_after_usage_reconciliation(self):
        events = []
        store = self.approved_store("qa")
        store.claim_agent_run.return_value = task_review_run("qa")
        store.reconcile_agent_run_spend.side_effect = lambda *_args: (events.append("reconcile") or {"status": "reconciled"})
        store.submit_task_review.side_effect = lambda *_args: events.append("submit_review")
        store.complete_agent_run.side_effect = lambda *_args: events.append("complete_run")
        hermes = Mock()
        hermes.review.side_effect = lambda *_args: (events.append("hermes") or (task_review_artifact("qa"), {"prompt_tokens": 20, "completion_tokens": 30}))
        worker = AgentWorker(store, hermes, "openai", "gpt-4o-mini", worker_id="sutra-worker-12345678")
        self.assertEqual(worker.run_once(), "succeeded")
        self.assertEqual(events, ["hermes", "reconcile", "submit_review", "complete_run"])
        evidence = store.submit_task_review.call_args.args[1]
        self.assertEqual(evidence["tested_commit_sha"], "a" * 40)
        self.assertEqual(store.complete_agent_run.call_args.args[2], "succeeded")

    def test_task_artifact_submission_follows_spend_settlement_and_bypasses_generic_completion(self):
        events = []
        store = self.approved_store("product_manager")
        store.claim_agent_run.return_value = task_artifact_run("product_manager")
        store.reconcile_agent_run_spend.side_effect = lambda *_args: (events.append("reconcile") or {"status": "reconciled"})
        store.submit_task_agent_artifact.side_effect = lambda *_args: events.append("persist_artifact")
        hermes = Mock()
        hermes.review.side_effect = lambda *_args: (events.append("hermes") or (task_artifact_output(), {"prompt_tokens": 20, "completion_tokens": 30}))
        worker = AgentWorker(store, hermes, "openai", "gpt-4o-mini", worker_id="sutra-worker-12345678")
        self.assertEqual(worker.run_once(), "task_artifact_succeeded")
        self.assertEqual(events, ["hermes", "reconcile", "persist_artifact"])
        store.submit_task_agent_artifact.assert_called_once_with(
            "sutra-worker-12345678", task_artifact_run("product_manager"), task_artifact_output())
        store.complete_agent_run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
