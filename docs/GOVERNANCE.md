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

## Model inference spend
Model inference is fail-closed unless an active `agent_model_spend_profiles` row exists for the exact provider/model. This table has no direct API grants. The founder configures EUR-per-million-token prices and maximum input/output tokens with `sutra_set_agent_model_spend_profile`. Reservation rows snapshot both rates and ceilings; database triggers verify the maximum reserve and calculate-check settled spend against provider-reported token usage. The worker cannot submit a cheaper quote or lower actual amount. The deployed Hermes API must enforce the same route and output cap before the worker may be enabled.

## Mandatory approval categories
Initially require founder approval for material spending, contracts/legal commitments, banking/payment access, destructive production operations, major pricing changes and governance-policy changes.
