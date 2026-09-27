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
        payload = {"choices": [{"message": {"content": json.dumps(artifact())}}]}
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = json.dumps(payload).encode()
        with patch("sutra.worker.urllib.request.urlopen", return_value=response) as request:
            client = HermesAgentClient("https://hermes.example", "hermes-key")
            result = client.review(claimed_run())
        self.assertEqual(result["summary"], artifact()["summary"])
        request_body = json.loads(request.call_args.args[0].data)
        system_prompt = request_body["messages"][0]["content"]
        self.assertIn("untrusted data", system_prompt)
        self.assertIn("no spending", system_prompt)
        self.assertNotIn("SUPABASE_SERVICE_ROLE_KEY", request_body["messages"][1]["content"])
        self.assertNotIn("tools", request_body)
        self.assertEqual(request.call_args.kwargs["timeout"], 180.0)

    def test_invalid_model_artifact_is_retried_and_not_marked_succeeded(self):
        store = Mock()
        store.claim_agent_run.return_value = claimed_run("cpo")
        hermes = Mock()
        hermes.review.side_effect = AgentOutputError("bad output")
        worker = AgentWorker(store, hermes, worker_id="sutra-worker-12345678")
        self.assertEqual(worker.run_once(), "retry")
        store.complete_agent_run.assert_called_once_with(
            "sutra-worker-12345678", claimed_run("cpo"), "retry",
            {"summary": "Agent output failed schema or evidence validation"}, "invalid_agent_output",
        )

    def test_hermes_failure_retries_claimed_job(self):
        store = Mock()
        store.claim_agent_run.return_value = claimed_run()
        hermes = Mock()
        hermes.review.side_effect = IntegrationError("offline")
        worker = AgentWorker(store, hermes, worker_id="sutra-worker-12345678")
        self.assertEqual(worker.run_once(), "retry")
        self.assertEqual(store.complete_agent_run.call_args.args[2], "retry")
        self.assertEqual(store.complete_agent_run.call_args.args[4], "hermes_unavailable")


if __name__ == "__main__":
    unittest.main()
