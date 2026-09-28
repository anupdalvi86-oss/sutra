# Sutra operating model

Supabase stores the role registry, assigned work, approvals, budgets and audit trail. The role permissions and `can_delegate_to` arrays are catalog metadata; they do not grant a process direct database, GitHub, shell, payment or messaging authority. Runtime handoffs are created by the fixed, database-backed workflows below. Every operation still passes through the service boundary and its authorization RPCs.

## Role contracts

| Role | Responsibilities | Catalog permissions | Catalog delegation targets | Inputs and persisted outputs |
|---|---|---|---|---|
| CEO | Translate founder objectives into accountable plans; coordinate and report | Read company state; create project proposal; delegate work (workflow metadata only) | CPO, CTO, CFO, COO, CMO, Sales, Governance/Audit | Founder request, company state and reviewed department artifacts → bounded decision review (`summary`, `recommendation`, `evidence`, `assumptions`, `risks`, `milestones`, `acceptance_criteria`) |
| CTO | Technical direction; engineering sequence | Read company state; create engineering tasks; request technical approval | Architect, Developer, QA, Security, DevOps | Approved/reviewed proposal and technical risks → bounded decision review; approved engineering work → task assignments and acceptance criteria through the workflow |
| CPO | Customer/problem research; product scope | Read product state; create product artifacts | Product Manager, Sales, CMO | Founder request and research context → cited HTTPS evidence in a bounded decision review |
| CFO | Evaluate budgets and financial controls | Read financial state; request budget approval | Governance/Audit | Requested budget, active database policies and matching budgets → `decision` plus rationale; this role decision is not spend authorization |
| COO | Operational readiness and incident response | Read company state; create operations tasks | DevOps, Governance/Audit | Approved task and service context → `operations_plan` with `operational_dependencies`, `readiness_checklist`, `incident_plan` |
| Product Manager | Roadmap, requirements, acceptance outcomes | Read product state; create product artifacts | Architect, Developer, QA | Approved project and prior reviews → `product_plan` with `scope`, `milestones`, `acceptance_criteria`; this plan gates founder approval and engineering task creation |
| Architect | Technical design and interfaces | Read engineering state; create design artifacts | Developer, Security, DevOps | Approved assigned task and acceptance criteria → `technical_design` with `design`, `components`, `security_risks` |
| Developer | Implement approved work in GitHub branch/PR | Read assigned tasks; propose code changes | None | Founder-approved, dispatched task → branch, GitHub PR and CI evidence; completion is accepted only after merge and successful CI on the same SHA |
| QA | Acceptance verification | Read review tasks; record test results | None | Completed Developer task, verified SHA and acceptance criteria → named reproducible test evidence; a pass needs direct GitHub evidence |
| Security | Threat, dependency and release review | Read security scope; record reviews | None | QA-passed task and verified SHA → bounded security checks, findings with severity/owner/remediation and explicit release blockers |
| DevOps | Deployment configuration, observability and recovery | Read deployment state; propose deployment changes | None | Approved assigned work → `release_plan` with `deployment_steps`, `health_checks`, `rollback_steps`; proposal alone cannot deploy |
| CMO / Marketing | Positioning and campaign proposals | Read marketing state; draft campaigns | Product Manager, Sales | Approved project/task context → internal `campaign_draft` (`audience`, `positioning`, `draft_copy`, `claims`, `success_metrics`) for review only |
| Sales | Qualification and sales artifacts | Read sales state; draft lead artifacts | Product Manager, CMO | Approved project/task context → internal `sales_handoff` (`ideal_customer_profile`, `lead_criteria`, `qualification_questions`, `first_contact_draft`); no real lead or outreach is created |
| Governance / Audit | Independent controls assessment | Read audit state; record findings | None | Assigned control scope and evidence → `governance_review` with `controls_checked`, `findings`, `recommendation`; cannot change policy or approve spend |

Catalog permissions describe intended capabilities, not a tool allowlist. Persisted effects are limited to the workflow RPCs: proposal/review artifacts, assigned tasks, metered runs, audited decisions and evidence. The Developer runner can open a PR but cannot merge or deploy. CMO/Sales create private drafts only. Finance policy, budgets, approvals and audit records are changed only by founder-checked database functions; all inference and infrastructure spending is subject to configured policy and budget limits.

## Handoff sequence

1. Founder-only Telegram identity submits a bounded proposal.
2. Durable reviews run CEO → CPO (research) → CTO → CFO → Product Manager. A failed/invalid artifact blocks the next stage; retries are bounded and metered.
3. Founder approval is available only after all reviews complete and policy requirements are satisfied. Approval is a budget ceiling, not permission to spend outside the central spending layer.
4. Approved project tasks flow through Architect/Developer. GitHub PR plus matching successful CI evidence releases QA; passing QA releases Security; passing Security releases DevOps/release readiness.
5. Product/operations/release/campaign/sales/governance task artifacts are available only for approved, assigned tasks and are stored as private artifacts. Marketing and sales handoffs remain internal drafts.

The metadata graph is checked by `supabase/tests/agent_delegation_test.sql`; `can_delegate_to` is not a generic runtime delegation API. The actual workflow transitions are server-owned and database-gated, which prevents an agent from self-assigning work or widening its authority by editing role metadata.
