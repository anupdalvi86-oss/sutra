import json
import unittest
from unittest.mock import Mock, patch

from sutra.runtime import IntegrationError
from sutra.worker import AgentOutputError, AgentWorker, HermesAgentClient, validate_agent_artifact


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
    if role == "cfo":
        result.update(decision="approve", decision_rationale="The requested budget is reviewable under current policy.")
    return result


def claimed_run(role="ceo"):
    return {
        "run_id": "00000000-0000-4000-8000-000000000001",
        "lease_token": "00000000-0000-4000-8000-000000000002",
        "agent": {"id": "00000000-0000-4000-8000-000000000003", "slug": role, "responsibilities": ["review"]},
        "project": {"name": "AI QA product opportunity", "description": "Investigate product demand.", "requested_budget": 500, "currency": "EUR"},
        "input": {"request": "Founder proposal."},
        "spending_policies": [{"name": "Founder tier", "min_amount": 200}],
        "applicable_budgets": [],
        "prior_results": [],
    }


class AgentArtifactTests(unittest.TestCase):
    def test_product_research_requires_https_evidence(self):
        self.assertEqual(len(validate_agent_artifact("cpo", artifact("cpo"))["evidence"]), 1)
        invalid = artifact("cpo")
        invalid["evidence"][0]["url"] = "http://example.com"
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("cpo", invalid)

    def test_product_research_cannot_succeed_without_sources(self):
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("cpo", artifact())

    def test_cfo_artifact_requires_explicit_decision(self):
        value = artifact("cfo")
        validate_agent_artifact("cfo", value)
        value["decision"] = "founder_can_approve"
        with self.assertRaises(AgentOutputError):
            validate_agent_artifact("cfo", value)

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
            {"summary": "Hermes artifact was invalid and usage could not be verified"}, "unknown_or_overrun_spend",
        )

    def test_unavailable_hermes_retains_reserve_and_fails_run(self):
        store = self.approved_store()
        hermes = Mock()
        hermes.review.side_effect = IntegrationError("offline")
        worker = AgentWorker(store, hermes, "openai", "gpt-4o-mini", worker_id="sutra-worker-12345678")
        self.assertEqual(worker.run_once(), "failed_unknown_spend")
        self.assertEqual(store.reconcile_agent_run_spend.call_args.args[-1], None)
        self.assertEqual(store.complete_agent_run.call_args.args[2], "failed")
        self.assertEqual(store.complete_agent_run.call_args.args[4], "unknown_spend")

    def test_pending_database_spend_approval_never_calls_hermes(self):
        store = self.approved_store()
        store.reserve_agent_run_spend.return_value = {"status": "requested", "approval_id": "approval-1"}
        hermes = Mock()
        worker = AgentWorker(store, hermes, "openai", "gpt-4o-mini", worker_id="sutra-worker-12345678")
        self.assertEqual(worker.run_once(), "blocked_spend_approval")
        hermes.review.assert_not_called()
        store.begin_agent_run_spend.assert_not_called()

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


if __name__ == "__main__":
    unittest.main()
