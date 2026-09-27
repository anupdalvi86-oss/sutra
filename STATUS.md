# Sutra Status

Updated: 2026-09-27 (Europe/Stockholm)

## What is working

- Main contains the operational company schema, 14 organizational roles, audited company state, configurable spending policies and budgets, Telegram command routing, the Railway API/Hermes container definitions, and a leased agent worker gated by database-backed model cost controls.
- Supabase is the authoritative company state. Proposal intake persists a project, objective, approval, audit record, sequential CEO → Product → CTO → CFO → Product Manager reviews, and a blocked research task. Founder approval produces the downstream PM → Architect → Developer → QA → Security → DevOps → Marketing → Sales task chain.
- Spending thresholds are stored in database policy: `<= €10` automatic, `> €10 to €50` department head, `> €50 to < €200` CFO and CEO, and `>= €200` founder. Period and scope limits cover transaction, company, project, department, agent, category, vendor, daily, monthly and lifetime budgets, with warnings and hard stops. Department-head spend stays blocked until an active department approver is assigned.
- The worker requires an active founder-configured provider/model price profile. Supabase calculates the maximum three-iteration reserve, snapshots rates and token ceilings, and calculates actual cost from reported usage. An approved reservation must begin before Hermes is called; successful review requires usage reconciliation. Unknown or out-of-profile usage retains the reserve and fails closed. The exact pinned Hermes API is patched to pass output-token caps and forbid model fallback.
- Supabase security checks confirm RLS is on for the model profile and spend reservation tables, neither `anon` nor `service_role` has direct SELECT, and the profile, reserve and reconciliation RPCs are executable by `service_role` only. There are zero active model profiles, so no agent model request can run.
- CI exercises the simulated founder → CEO/departments → CFO → founder approval workflow, budget gates, audit events, approval resumption, the review success gate, and spend reconciliation. This is a database-backed simulation, not a live Telegram/model session.
- No credentials or tokens are committed. `SUTRA_ENABLE_AGENT_WORKER` and Telegram polling remain off until the founder credentials and route are configured.

## Tests and security checks

- PR #11 CI run `36300280029` passed: Python unit tests and compile check, local Supabase migrations, pgTAP policy/workflow tests, database lint, Sutra API and Hermes image builds, Hermes request cap/route-lock verification, and Gitleaks secret scanning.
- Main post-merge CI run `36300434840` passed Python tests and compile check, local Supabase migrations, pgTAP policy/workflow tests, database lint, both container builds, Hermes request-control verification and Gitleaks.
- Python unit tests: 25 passed locally before merge. Python compile checks and `git diff --check` passed.
- Supabase pgTAP tests cover threshold boundaries, budget hard stops, founder-only governance changes, agent self-escalation denial, approval routing, reservation/reconciliation and audit records.
- Hosted Supabase migration `20260927063326 spend_gated_hermes_worker` was applied after PR #11 passed CI. Live catalog checks confirmed expected RLS/table grants and service-role-only RPC grants. Supabase connectivity and the empty active-profile state were verified.
- Supabase Security Advisor reports 17 informational RLS-enabled/no-policy findings for server-only tables whose API grants are withheld. Performance Advisor reports 31 unused indexes on this low-traffic project; review after real workload data exists rather than dropping indexes now. [RLS lint guidance](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy), [unused-index guidance](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index).
- Local Supabase startup could not complete because Docker ran out of disk while pulling images. No Docker cleanup or user data deletion was attempted; hosted database checks and GitHub-hosted database CI succeeded.

## Deployment and integrations

- **Supabase:** Project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is reachable on PostgreSQL 17.6. Hosted migration history now includes `20260927063326 spend_gated_hermes_worker`. The project displayed a grace-period/quota warning; no paid plan change or recovery point was confirmed. The authenticated Supabase connector applied the migrations; the local CLI is not authenticated.
- **Railway:** No Sutra API has been deployed. The existing `lovely-playfulness` project has a Hermes-only service connected to `praveen-ks-2001/hermes-agent-template`, not this repository. The last observed usage was `$1.54` current and `$4.81` estimated against `$5` included usage. Adding a service risks exceeding the no-spend limit, so deployment was not triggered. No Sutra API URL exists.
- **Hermes:** The repository pins and patches the runtime and CI builds/verifies its image. The separate existing Railway gateway last reported `gateway: stopped`; no live Sutra API-to-Hermes run has been verified.
- **Telegram:** Not configured. Telegram requires a bot token and the founder's numeric Telegram user ID in the Sutra API secret manager. The code restricts private commands to the configured founder, but no live bot command has been exercised.
- **Model provider:** No provider credential or active model profile/route exists. The model spend profile must be explicitly configured and founder-authorized before the worker can make a call.
- **Engineering execution:** Approved proposals create durable engineering-to-sales tasks, but Sutra does not yet dispatch them to Codex/GitHub, create issues/PRs, attach QA/security evidence or perform release handoff.

## Remaining blockers

1. A founder must add a provider key and an exact model route, then configure an audited model price profile and ceilings in Supabase.
2. A founder must add the Telegram bot token and numeric founder user ID to the API's secret manager.
3. Confirm Railway included usage/cost headroom before deploying the API service. The last observed allowance was almost exhausted, and no spend was authorized.
4. Supabase quota is in a grace-period warning; check the project remains available and establish a recovery option before further production schema changes.
5. Implement and validate the approved-task-to-Codex/GitHub issue/PR dispatcher and persistent QA, Security and release-readiness evidence.

## Recommended next steps

1. Add provider and Telegram secrets only in their service secret manager; never send them in chat or commit them.
2. Configure the founder-authorized provider/model price profile in Supabase and confirm budgets and department approvers.
3. Confirm Railway cost headroom, deploy the API, configure private Hermes access, and verify `/health` and a founder-only Telegram status command.
4. Add engineering dispatch and record PR, test, security review and release evidence in Supabase/GitHub; exercise the full approval flow with a non-spending test request.
5. Monitor Supabase quota and test a recovery path before future migrations.
