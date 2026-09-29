# Governance

## Founder authority
The founder controls governance policy and may override normal agent decisions.

## Financial controls
Spending authority is data-driven and configurable. Policies can be scoped by company, project, department, agent, category, vendor and time period.

Supported controls include:
- per-transaction limit
- daily/monthly limits
- project budget
- department budget
- per-agent budget
- category budgets (AI/API, infrastructure, marketing, etc.)
- warning thresholds
- hard-stop thresholds
- approval chains

No agent may raise its own authority or modify policies that govern itself. Service-role clients cannot directly insert, update or delete spending policies, budgets, company settings, expenses, approvals or audit records. Founder-only database functions perform those changes and append audit records. RLS is enabled for every public company table; the public and authenticated API roles have no table access.

The central spending RPC validates actor identity, project approval, the matching configurable policy, and every matching active budget while serializing concurrent budget checks. Pending and approved expenses count against budget use. Hard stops reject the request; warning thresholds are returned with the decision. Requests that need approval create a pending expense and approval record. Founder approval does not skip required CFO/CEO review.

Initial EUR ranges use half-open explicit boundaries: up to and including €10; above €10 through €50; above €50 and below €200; €200 and above. Changing the ranges, approvers, warning threshold or hard-stop behavior is founder-only and audit logged.

Department-head approvals fail closed until the founder assigns a head with `sutra_set_company_setting`, using key `department_head:<department UUID>` and the selected agent UUID as the value. This prevents any active department agent from approving requests by default. The assignment is audit logged.

## QA and Security review deferral
Only the configured founder may defer an assigned QA task and its direct Security child through the audited Telegram command. The database validates both assignments and the approved project and changes both statuses in a single transaction. It preserves them as `deferred`, records the founder and reason, and creates no review evidence. The directly dependent internal DevOps planning task may proceed; this does not authorize spend, merge, deployment, release, or external communication. Agents cannot defer their own tasks. Restoring a deferred task requires its parent workflow stage to be complete, returns it to the ready queue, and leaves all completion evidence gates active.

## Model inference spend
Model inference is fail-closed unless an active `agent_model_spend_profiles` row exists for the exact provider/model. This table has no direct API grants. The founder configures EUR-per-million-token prices and per-completion input/output token ceilings with `sutra_set_agent_model_spend_profile`. The Hermes image limits an agent run to three model iterations, so the database reserves for three times each per-completion ceiling. Reservation rows snapshot rates and ceilings; database triggers verify the maximum reserve and calculate-check settled spend against reported total token usage. The worker cannot submit a cheaper quote or lower actual amount. The pinned Hermes image enforces the output cap and exact route; the application is enabled only after all route secrets and the active founder-configured profile are available.

## Mandatory approval categories
Initially require founder approval for material spending, contracts/legal commitments, banking/payment access, destructive production operations, major pricing changes and governance-policy changes.
