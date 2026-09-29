# AI QA scope proposal (review evidence)

**Status:** Proposal for founder review only. This document does not validate a market, approve a build or expense, complete blocked database tasks, or establish release readiness.

## Decision context

One candidate straw scope, taken from a completed Architect artifact, is a tool that turns one user-provided end-to-end scenario into an editable Playwright test draft, explains how the draft maps to the scenario, and lets a person accept, edit, or reject it. The draft remains unverified and is never run by the tool. This is one hypothesis for review; it does not merge or replace the separately approved project scopes.

This is a hypothesis selected to make the proposed workflow concrete, not a validated product direction. Current records do not establish a target buyer, a repeated unmet need, differentiation from existing options, willingness to pay, or market size. Product work should remain at bounded, no-spend discovery unless the evidence gates below pass and the founder approves a separate proposal.

## Evidence and assumptions

| Type | Claim | Basis and limit |
| --- | --- | --- |
| Sourced evidence | Playwright documents test generation and, in its test-agent documentation, planning, generation, and healing workflows. | [Playwright test generator](https://playwright.dev/docs/codegen) and [Playwright Test Agents](https://playwright.dev/docs/test-agents), cited by the completed CPO market-research artifact (task `9033583d-0867-4dde-9f55-df9f58d51c71`). Existing framework features are direct substitutes to investigate. |
| Sourced evidence | Commercial products describe test creation, maintenance, and failure-triage capabilities. | The CPO artifact cites [mabl](https://www.mabl.com/pricing), [SmartBear Reflect](https://smartbear.com/product/reflect/pricing/), and [BrowserStack](https://www.browserstack.com/pricing?cycle=annual&product=low-code-automation). Vendor feature and pricing pages establish what those vendors report, not unmet demand or comparable prices. |
| Sourced evidence | Test maintenance and flaky tests are reported as workflow concerns. | The CPO artifact cites the [ACM flaky-test study](https://dl.acm.org/doi/10.1145/3510457.3513037) and vendor research. These sources support investigating a problem; they do not show that this proposed product solves it or that buyers will pay. |
| Sourced evidence | Untrusted test scenarios or pasted application context can create prompt-injection and unsafe-output risks. | The Architect artifact cites [OWASP LLM01](https://owasp.org/www-project-top-10-for-large-language-model-applications/2_0_vulns/LLM01_PromptInjection.html). This informs safeguards; it is not a completed Security review. |
| Sourced project evidence | The three approved €500 records preserve distinct scopes: a draft-only Playwright workflow, prerequisite-gated discovery with only a conditional small prototype evaluation, and a no-spend proposal/re-review. They are not interchangeable duplicate scopes or evidence of three validated products. | Current [`STATUS.md`](../../STATUS.md) and read-only task/approval records: project `58c52b74-8f15-4174-a079-e869e3df713c` (CPO `9033583d-0867-4dde-9f55-df9f58d51c71`, PM `38ab260a-9a72-4cc0-9de8-9ef2ffd6a5c6`, Architect `20030c5e-792c-4970-b12a-f9adc3036cf7`); project `93b43006-58f9-4096-9e72-df9aeaf350ff` (CPO `225f3fb1-3c8e-4d74-a138-160d7231f461`, PM `9fa934dc-60a3-482e-9f67-afc7d2506e51`, Architect `8b907901-3c46-4b1b-8ed1-d7570b3a4c6c`); and project `277a4042-b7a8-4461-a117-60c4ccecf52c` (CPO `3dde0907-1420-4832-a52d-f71dfc7307e6`, PM `6483e5d2-8c40-4a1e-9b91-c190dc253e96`, blocked Architect `8c59a877-ba5d-4a4e-aa8c-78181de1a265`). The original proposal `52fbf8a6-ab60-430f-80bf-212698ec6f76` was rejected and its cancelled task is retained. The records do not establish which hypothesis users need. |
| Sourced project evidence | The repo’s discovery gate requires an authoritative model-routing status before discovery or prototype work; it also calls for one workflow, disconfirming research, and a stop/continue recommendation. `STATUS.md` identifies Architecture and acceptance-criteria verification as blocked and QA/Security reviews as deferred by founder direction. | [`docs/AI_QA_OPPORTUNITY_DISCOVERY.md`](../AI_QA_OPPORTUNITY_DISCOVERY.md) and current [`STATUS.md`](../../STATUS.md). This proposal does not complete the blocked tasks or perform QA/Security reviews. |
| Assumption to test | Small teams using Playwright may have a costly test-authoring or maintenance workflow that is not adequately served by current tools. | Proposed in the approved CPO artifact as a candidate segment/workflow. Buyer, frequency, cost, unmet need, adoption, and payment intent remain unknown. |
| Assumption to test | A scenario-linked rationale and review controls may be useful differentiation for a Playwright draft. | A design choice from the PM and Architect artifacts, not evidence of customer preference or market gap. |

## Smallest proposed scope

If discovery supports proceeding, consider a single-user, draft-only workflow for one Playwright end-to-end scenario:

- Input: a user-provided scenario and only the minimum non-sensitive context needed to describe it.
- Output: one editable Playwright test draft, a rationale mapping its steps/assertions to the scenario, and explicit warnings or unknowns.
- Review: the user can accept, edit, or reject the draft in the same session. Acceptance means only that the user accepts the draft for their own next step; it does not mean the test is correct or verified.
- Data: use synthetic or explicitly approved, non-sensitive examples for any prototype. Keep scenario and output transient in the initial scope; do not add account, project, or long-term history features without evidence and a separate decision.

### Excluded from this proposal

No test execution, browser control, CI integration, repository write, test repair/healing, broad AI application evaluation, production/customer-system connection, team collaboration, persistent test library, performance guarantee, or commercial launch. These exclusions bound the hypothesis; they are not a claim that users would not need those capabilities.

## User workflow

1. A user enters one end-to-end scenario and confirms it contains no secrets or sensitive production data.
2. The system validates bounded input and asks a model to draft a Playwright test without tools or access to a browser, repository, or target application.
3. A validator checks output shape and size. The interface displays generated code as inert, untrusted text alongside rationale and warnings.
4. The user reviews the draft and chooses accept, edit, or reject. The system does not execute the result. A prototype evaluation records only the minimum review outcome needed for an approved study.

The target user, exact scenario type, and choice among the competing recorded hypotheses must be selected through founder review and discovery; this workflow is a testable framing, not a known user journey.

## Minimum logical architecture (conditional prototype)

- **Review client:** bounded scenario form and a view for draft, rationale, warnings, and accept/edit/reject.
- **API and input boundary:** authentication if any shared service is used; validate request size and fields; treat all user/context text as untrusted data; do not expose provider credentials.
- **Generation adapter:** one server-side model call behind a replaceable adapter, with provider, retention, and cost terms verified before use. Apply timeout and request/output limits. No tools, browser, shell, repository, or customer-system access.
- **Output validator:** require the agreed response schema and safe size; reject malformed output; render code as text, never execute it.
- **State:** no persistent scenario or draft store in the smallest prototype. Keep only consented, minimal evaluation notes if a separately approved study requires them, under an explicit retention rule.

This is a logical boundary only, not an implementation design approval or completion of the blocked Architecture task. One completed Architect artifact proposed a persistent tenant-scoped draft/review store and API; this proposal removes those elements from the first testable scope to reduce data and build surface. Another product-plan artifact instead proposes first checking model routing, interviewing up to eight users, and only then considering existing evaluation tools. The different proposals are not combined here. Add persistence or multi-user tenancy only if discovery justifies it and architecture, privacy, and Security reviews are authorized and completed.

## Acceptance gates

These proposed criteria are for deciding whether to advance a hypothesis. They are not QA results, do not complete the blocked acceptance-criteria verification task, and do not certify that any current product exists.

### Discovery decision gate

- Record model-routing readiness from an authoritative project/task source before discovery or prototyping; stop and surface the dependency if unknown or incomplete.
- Select one target user and one recent, concrete Playwright workflow. Record current tools, frequency, effort or failure cost, workaround, and who would own a decision to adopt; label all unverified details as hypotheses.
- Compare the selected workflow with relevant framework-native, open-source, and commercial alternatives. A claimed gap must cite observed evidence and include counter-evidence.
- Use a founder-approved, no-spend validation protocol that asks about recent behavior and outcomes, includes disconfirming questions, and does not imply purchase intent. No recruitment or external contact occurs without applicable authorization.
- Recommend stop, further discovery, or a separately reviewed prototype proposal. Continue only if evidence shows a repeated costly workflow, a specific gap not adequately addressed by alternatives, and a measurable user-valued outcome. Test-maintenance effort or meaningful-defect detection may be measures; generated-test count alone is not success.

### Conditional prototype gate

Only if the founder separately approves a prototype proposal:

- For each approved representative scenario, return an editable draft, scenario-linked rationale, and warnings/unknowns; label output unverified.
- Provide accept/edit/reject review controls and do not execute or transmit generated test code to another system.
- Evaluate at least 10 representative, approved scenarios with human review; report usefulness, correctness issues, and time-to-review with the rubric and limitations. Make no quality claim without recorded results.
- Use only synthetic or explicitly consented, non-sensitive inputs; document provider data retention and cost terms, limits, and deletion behavior before any model integration.
- Obtain separate database authorization for every expense. The project ceiling is not transaction authorization.

## Major risks

- **No validated opportunity:** user segment, buyer, payer, frequency, costly unmet need, differentiation, and willingness to pay are unknown; existing framework and vendor capabilities may make the feature redundant.
- **Incorrect or unsafe code:** generated tests may be wrong, destructive, or misleading. Keep output unexecuted and visibly unverified; require human inspection.
- **Prompt injection and data exposure:** pasted context can contain hostile instructions, secrets, or personal data. Minimize and reject sensitive data, isolate input as data, provide no execution tools, and define provider/log retention before integration.
- **Output quality and evaluation bias:** a small or unrepresentative scenario set can overstate usefulness. Predefine a rubric, include counterexamples, and report failures and uncertainty.
- **Cost and availability:** model calls can incur unbounded cost or fail. Use per-request limits, timeouts, and a verified provider/cost plan; do not infer spend permission from the project ceiling.
- **Governance and release status:** QA and Security are deferred by founder direction. Neither review has been performed by this work, and the proposal is not release-ready.

## Unresolved questions for founder review

1. Should the approved effort continue with bounded, no-spend discovery, or pause until the blocked Architecture/acceptance-criteria tasks are resolved?
2. If discovery continues, which single candidate should Product test: Playwright test drafting/maintenance, review of AI-proposed Playwright repairs, or regression evaluation for AI application changes? The existing artifacts support these as hypotheses only; they must not be combined without evidence.
3. What authoritative record will establish model-routing readiness, and is it complete?
4. May Product seek founder-approved participants and contact them for discovery? The existing research invitation and sales copy are drafts only; no outreach is authorized by this document.
5. If discovery passes, will the founder authorize a separately scoped prototype, including any required data handling and expense approvals?

Until those decisions and evidence gates are resolved, this file is review evidence only. It does not alter project/task records, unblock work, authorize outreach or spend, or claim QA/Security completion.
