# Governance

## Founder authority
The founder controls governance policy and may override normal agent decisions.

## Standing repository authority
The configured founder may record a standing authorization for the exact repository `anupdalvi86-oss/sutra`. The grant is stored in `founder_code_authorizations` through a founder-only RPC, has a fixed capability list for Developer task creation, branches, pull requests, merge, QA, Security, and deployment, and can be revoked only through a founder-only audited RPC. It is not an agent role, prompt instruction, budget, or spending grant. The grant record and each task scope derived from it are audit logged. A completed Architect design remains required before downstream engineering work is released.

Founder-authorized Developer tasks may attach to an existing Sutra initiative with a positive cap only while the project is active, has no legal hold or open legal escalation, and carries a current `within_cap` assessment recommending `proceed_within_cap`. Task creation snapshots the unchanged cap and assessment in its approval and audit records; it cannot create, increase, or otherwise grant spend authority. Provider and project costs still require the central ledger and configured policy checks.

The standing grant only replaces repeated one-task code-scope approvals. Project budgets, the shared initiative ledger, model reservations and hard caps remain in force. The production Sutra operating-model initiative has a founder-set all-in ceiling of €17.60 (the conservative EUR conversion of the approved US$20) and a recorded evidence-backed estimate of €15.97, assessed `within_cap` with `proceed_within_cap`; unresolved model reservations remain held against that budget. The founder can inspect or revoke the grant in Telegram with `CEO, show standing code authority.` and `CEO, revoke standing code authority <authorization-id> because <reason>.` Both actions are founder-only and audit logged. This code grant itself does not activate customer messaging, live sales or marketing, or legal commitments; those capabilities remain subject to their separate controls and credentials.

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

For an initiative with a founder-set all-in cap and a completed CFO estimate, ordinary costs inside that cap are delegated to the operating team and do not request another routine approval. The staged initiative-cost RPC still enforces the all-in project ceiling, active matching hard budgets, transaction limits, daily/monthly policy limits and audit records. New proposals remain blocked until the CFO estimate and PM review succeed. If the estimate exceeds the cap, requires legal review, or recommends stopping, paid work pauses; only the configured founder can increase the cap through an audited database function. This flow is deployed in production. The current Sutra implementation initiative is assessed within its unchanged €17.60 cap; see `STATUS.md` for the latest estimate, usage, deployment and verification details.

The stacked `feat/founder-legal-escalation-inbox` change persists a private legal case whenever a CFO budget assessment flags a legal question or possible binding commitment. Only the configured founder can list cases or record one of three dispositions: continue within the existing budget, stop the initiative, or seek legal counsel. Every disposition is audited. It does not restart the project, authorize legal commitments, or change spending authority; the project stays paused until the separate work state is explicitly resolved.

Initial EUR ranges use half-open explicit boundaries: up to and including €10; above €10 through €50; above €50 and below €200; €200 and above. Changing the ranges, approvers, warning threshold or hard-stop behavior is founder-only and audit logged.

Department-head approvals fail closed until the founder assigns a head with `sutra_set_company_setting`, using key `department_head:<department UUID>` and the selected active agent UUID as the value. The selected leader may belong to another department, which supports departments with no separate manager; the authority only applies to the department UUID in the setting. The assignment is audit logged. An agent cannot approve an expense it requested, even when it is the assigned head.

## QA and Security review deferral
Only the configured founder may defer an assigned QA task and its direct Security child through the audited Telegram command. The database validates both assignments and the approved project and changes both statuses in a single transaction. It preserves them as `deferred`, records the founder and reason, and creates no review evidence. The directly dependent internal DevOps planning task may proceed; this does not authorize spend, merge, deployment, release, or external communication. Agents cannot defer their own tasks. Restoring a deferred task requires its parent workflow stage to be complete, returns it to the ready queue, and leaves all completion evidence gates active.

## Model inference spend
Model inference is fail-closed unless an active `agent_model_spend_profiles` row exists for the exact provider/model. This table has no direct API grants. The founder configures EUR-per-million-token prices and per-completion input/output token ceilings with `sutra_set_agent_model_spend_profile`. The Hermes image limits an agent run to three model iterations, so the database reserves for three times each per-completion ceiling. Reservation rows snapshot rates and ceilings; database triggers verify the maximum reserve and calculate-check settled spend against reported total token usage. The worker cannot submit a cheaper quote or lower actual amount. The pinned Hermes image enforces the output cap and exact route; the application is enabled only after all route secrets and the active founder-configured profile are available.

## Escalation categories
The operating model escalates to the founder when an initiative has no approved budget for paid work, a cost would exceed an initiative's all-in cap, or an issue requires legal judgment or a binding legal commitment. Ordinary product, engineering, QA, Security, deployment, marketing and sales decisions within approved scope and budget do not require one-off founder approvals. Any production change must retain a verified recovery path, audit evidence and the existing budget checks.
