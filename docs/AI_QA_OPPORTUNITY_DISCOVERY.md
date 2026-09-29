# AI QA opportunity: evidence-gated discovery

## Decision

Continue with no-spend discovery only. The current evidence establishes that AI application testing and evaluation tools already cover CI evaluations, regression checks, red teaming, observability, and human review. It does not establish a target buyer, a repeated unmet need, willingness to pay, or product differentiation. Do not start a general-purpose product build.

The project’s approved €500 amount is a project ceiling. It does not authorize an expense. Each expense still requires its own database authorization under the active spending policy and hard cap.

## Current evidence and limits

The completed Sutra CPO research artifact reports the following vendor capabilities, with primary vendor documentation as evidence:

- [Promptfoo](https://www.promptfoo.dev/docs/integrations/ci-cd/) documents evaluations and red-team scans in CI, reports, and build quality gates.
- [Braintrust](https://www.braintrust.dev/docs/evaluate) documents offline experiments, CI regression checks, online scoring, and turning production feedback into evaluation datasets.
- [Datadog LLM Observability](https://docs.datadoghq.com/llm_observability/investigate/evaluations/) documents managed and custom evaluations, integrations, and human annotation queues.
- [Playwright Test Agents](https://playwright.dev/docs/test-agents) documents agents for planning, generating, and healing end-to-end tests.

These sources show existing capabilities; they are not evidence that a new product is needed. The project’s completed research found no customer interviews or validated differentiation and did not estimate market size. Candidate segments and product wedges remain hypotheses.

## Gates

1. **Prerequisite:** record the model-routing status from an authoritative project/task record before discovery or prototype work. If it is incomplete or unknown, stop and surface that dependency.
2. **Choose one workflow:** state one target buyer, their current QA workflow, when and how often it occurs, the cost of failure or maintenance, and the existing tools they use. Compare both established products and open-source options.
3. **Validate without spending:** prepare a short, disconfirming interview guide for up to eight relevant users. Ask about observed recent behavior and outcomes, not hypothetical interest. No incentives, paid research, vendor use, or external outreach without the applicable authorization and founder-approved recruitment.
4. **Continue only on evidence:** require repeated evidence of a costly unmet workflow, a specific gap existing tools do not cover adequately, and measurable value such as lower test-maintenance effort or better detection of meaningful defects. Test-generation volume alone is not success.
5. **Prototype only after the gate:** if discovery passes, return with a separately reviewed, narrowly scoped, non-production prototype proposal. Use synthetic or consented data, existing free resources, and human review. Any API or vendor cost requires separate database authorization.
6. **Make a stop/continue decision:** report evidence, counter-evidence, uncertainty, costs, and a recommendation. A pilot requires a concrete commitment from at least one target user and a new explicit decision.

## Guardrails and owners

- Product/CPO owns the buyer hypothesis, interview protocol, evidence log, and recommendation.
- CTO/Architecture owns verification of model-routing readiness and technical feasibility.
- CFO checks proposed costs against database policy; the founder authorizes each required approval.
- Do not contact customers, publish a campaign, use paid services, incur expenses, deploy, merge, or release under this discovery plan.
- QA and Security reviews are deferred by the founder for this phase. This plan does not claim either review has passed.
- Preserve unknown model-usage reservations and terminal failed-run records. A failed automated research task is not evidence that its acceptance criteria passed.

## Required discovery record

For each interview or observed workflow, record only consented, necessary information: participant role/segment, current workflow, recent example, frequency, time/cost, existing tools, failure impact, workarounds, disconfirming evidence, and whether the participant would commit to a next step. Do not collect sensitive personal data. Summarize findings without identifying participants unless they explicitly consent.

The decision package must distinguish sourced facts, participant evidence, and hypotheses; link source material; show what would falsify the opportunity; and recommend stop, further discovery, or a separately reviewed prototype proposal.
