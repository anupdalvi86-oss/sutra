# Sutra Status

Updated: 2026-09-27 (Europe/Stockholm)

## What is working

- Main contains the operational company schema, 14 organizational roles, audited company state, configurable spending policies and budgets, Telegram command routing, the Railway API/Hermes container definitions, and a leased agent worker gated by database-backed model cost controls.
- Supabase is the authoritative company state. Proposal intake persists a project, objective, approval, audit record, sequential CEO → Product → CTO → CFO → Product Manager reviews, and a blocked research task. Founder approval produces the downstream PM → Architect → Developer → QA → Security → DevOps → Marketing → Sales task chain.
- Spending thresholds are stored in database policy: `<= €10` automatic, `> €10 to €50` department head, `> €50 to < €200` CFO and CEO, and `>= €200` founder. Period and scope limits cover transaction, company, project, department, agent, category, vendor, daily, monthly and lifetime budgets, with warnings and hard stops. Department-head spend stays blocked until an active department approver is assigned.
- The worker requires an active founder-configured provider/model price profile. Supabase calculates the maximum three-iteration reserve, snapshots rates and token ceilings, and calculates actual cost from reported usage. An approved reservation must begin before Hermes is called; successful review requires usage reconciliation. Unknown or out-of-profile usage retains the reserve and fails closed. The exact pinned Hermes API is patched to pass output-token caps and forbid model fallback.
- Supabase security checks confirm RLS is on for the model profile and spend reservation tables, neither `anon` nor `service_role` has direct SELECT, and the profile, reserve and reconciliation RPCs are executable by `service_role` only. There are zero active model profiles, so no agent model request can run.
- A separate opt-in GitHub dispatcher leases only ready Developer tasks in founder-approved/active projects. It creates or recovers a repository issue with a stable full-task UUID marker, persists the issue link, advances the task, and audits the handoff. The dispatcher stays off until a least-privilege `GITHUB_TOKEN`, repository, and explicit enable flag are installed on Sutra API.
- Signed GitHub `pull_request` and `workflow_run` webhooks are implemented and the migrations are live. Normalized events are deduplicated and retained in Supabase; a Developer task completes only after a merged main-branch PR and successful `CI` run on the same head SHA. A database trigger also rejects completion through the generic task RPC without that evidence. This releases QA and writes audit/run evidence. QA, Security and release-readiness execution remain manual/unimplemented.
- CI exercises the simulated founder → CEO/departments → CFO → founder approval workflow, budget gates, audit events, approval resumption, the review success gate, and spend reconciliation. This is a database-backed simulation, not a live Telegram/model session.
- No credentials or tokens are committed. `SUTRA_ENABLE_AGENT_WORKER` and Telegram polling remain off until the founder credentials and route are configured.

## Tests and security checks

- PR #11 CI run `36300280029` passed: Python unit tests and compile check, local Supabase migrations, pgTAP policy/workflow tests, database lint, Sutra API and Hermes image builds, Hermes request cap/route-lock verification, and Gitleaks secret scanning.
- PR #13 CI run `36301614299` passed: 33 Python tests, migration application, pgTAP approval/dispatch authorization and audit tests, DB lint, API/Hermes image builds, request-control checks, and Gitleaks. The migration was applied to hosted Supabase as `20260927065915 github_approved_task_dispatch`.
- PR #15 CI run `36302817569` passed all four jobs: Python/compile, Supabase migration + 99 pgTAP assertions + database lint, API/Hermes images and runtime control checks, and Gitleaks. PR #15 merged as main commit `c4faa10`; the webhook migration is live as `20260927072312 github_pr_ci_evidence`.
- PR #17 CI run `36303483761` passed all four jobs, including 100 pgTAP assertions that reject generic Developer completion with fake PR/CI evidence. The live database guard migration is `20260927073600 developer_completion_requires_verified_github_evidence`.
- Main post-merge CI run `36301702613` passed all Python, database, container and secret-scan jobs.
- Main post-merge CI run `36302930432` passed after PR #15: all four Python, database, container and secret-scan jobs.
- Main post-merge CI run `36300434840` passed Python tests and compile check, local Supabase migrations, pgTAP policy/workflow tests, database lint, both container builds, Hermes request-control verification and Gitleaks.
- Python unit tests: 38 passed locally after signed webhook support. Python compile checks and `git diff --check` passed.
- Supabase pgTAP tests cover threshold boundaries, budget hard stops, founder-only governance changes, agent self-escalation denial, approval routing, reservation/reconciliation and audit records.
- Hosted Supabase migration `20260927063326 spend_gated_hermes_worker` was applied after PR #11 passed CI. Live catalog checks confirmed expected RLS/table grants and service-role-only RPC grants. Supabase connectivity and the empty active-profile state were verified.
- Live GitHub dispatch checks confirm the new table has RLS and no direct `anon` or `service_role` SELECT, the three dispatch RPCs are service-role-only, the live queue is empty, and the RPC returns no task when idle.
- Live webhook security checks confirm RLS is enabled, neither `anon` nor `service_role` can read delivery rows directly, `anon` cannot call the ingestion RPC, and `service_role` can. The migration is present in hosted history; the dispatch queue is empty.
- Live catalog checks confirm the Developer completion trigger is installed and the trigger function is not directly executable by `anon` or `service_role`. No production dispatches or webhook deliveries exist yet.
- Supabase Security Advisor reports 19 informational RLS-enabled/no-policy findings for server-only tables whose API grants are withheld. Performance Advisor reports 30 unused indexes on this low-traffic project; review after real workload data exists rather than dropping indexes now. [RLS lint guidance](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy), [unused-index guidance](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index).
- Local Supabase startup could not complete because Docker ran out of disk while pulling images. No Docker cleanup or user data deletion was attempted; hosted database checks and GitHub-hosted database CI succeeded.

## Deployment and integrations

- **Supabase:** Project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is reachable on PostgreSQL 17.6. Hosted migration history includes `20260927063326 spend_gated_hermes_worker`, `20260927065915 github_approved_task_dispatch`, `20260927072312 github_pr_ci_evidence`, and `20260927073600 developer_completion_requires_verified_github_evidence`. The project displayed a grace-period/quota warning; no paid plan change or recovery point was confirmed. The authenticated Supabase connector applied migrations; the local CLI is not authenticated.
- **Railway:** No Sutra API has been deployed. The existing `lovely-playfulness` project has a Hermes service connected to `praveen-ks-2001/hermes-agent-template`, not this repository; it currently appears Online at [hermes-agent-production-f50d.up.railway.app](https://hermes-agent-production-f50d.up.railway.app). Current usage is `$1.56` and estimated usage is `$4.76` against `$5` included. Adding another service could exceed the no-spend limit, so deployment was not triggered. No Sutra API URL exists.
- **Hermes:** The repository pins and patches the runtime and CI builds/verifies its image. The separate existing Railway Hermes gateway is Online, but no live Sutra API-to-Hermes run has been verified and its cost headroom does not support adding Sutra safely.
- **Telegram:** Not configured. Telegram requires a bot token and the founder's numeric Telegram user ID in the Sutra API secret manager. The code restricts private commands to the configured founder, but no live bot command has been exercised.
- **Model provider:** No provider credential or active model profile/route exists. The model spend profile must be explicitly configured and founder-authorized before the worker can make a call.
- **Engineering execution:** Approved engineering work can be dispatched to GitHub issues after deployment and least-privilege token configuration. Signed PR/CI evidence ingestion is implemented, but no production webhook is registered or configured. Codex task execution, QA/Security review automation and release readiness remain unimplemented.
- **GitHub:** The code uses `GITHUB_TOKEN` only in the Sutra API and only when `SUTRA_ENABLE_GITHUB_DISPATCHER=true`. No production token, webhook secret, or repository webhook is configured; dispatch and webhook endpoint remain disabled. GitHub returned 403 for branch protection because this private repository requires GitHub Pro or public visibility for that feature. The hooks API currently returns an empty list.

## Remaining blockers

1. A founder must add a provider key and an exact model route, then configure an audited model price profile and ceilings in Supabase.
2. A founder must add the Telegram bot token and numeric founder user ID to the API's secret manager.
3. Provide authorized Railway cost headroom (or another no-cost deployment target) before deploying the API. Current estimate is `$4.76` against `$5` included; no spend was authorized.
4. Supabase quota is in a grace-period warning; check the project remains available and establish a recovery option before further production schema changes.
5. Configure the GitHub issue token and enable dispatch after API deployment; then build Codex implementation and PR/CI evidence ingestion, persist QA/Security/release readiness, and retain release gates.

## Recommended next steps

1. Add provider, Telegram, and least-privilege GitHub issue secrets only in their service secret manager; never send them in chat or commit them.
2. Configure the founder-authorized provider/model price profile in Supabase and confirm budgets and department approvers.
3. Confirm Railway cost headroom, deploy the API, configure private Hermes access, and verify `/health` and a founder-only Telegram status command.
4. Configure the least-privilege GitHub issue token, webhook secret and repository webhook. To require CI for merges, enable an eligible GitHub plan or make the repository public; then add Codex execution and record QA, Security and release evidence in Supabase/GitHub. Exercise the founder approval flow in live Telegram with a non-spending test request.
5. Monitor Supabase quota and test a recovery path before future migrations.
