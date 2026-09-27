# Sutra Status

Updated: 2026-09-27 (Europe/Stockholm)

## What is working

- Main contains PR #8’s spend-ledger changes. The repository contains the founder-controlled company schema, audit trail, configurable spend policies, sequential CEO → CPO → CTO → CFO → Product Manager proposal reviews, and post-approval task handoffs through engineering, QA, Security, DevOps, Marketing and Sales.
- Supabase is the authoritative state model. Founder-only functions change governance settings and budgets; agent self-escalation is rejected. Service tables use RLS and expose no direct access to `anon` or `authenticated`.
- Financial defaults remain in database policy: up to €10 automatic, above €10 to €50 department head, above €50 to below €200 CFO and CEO, €200 and above founder. Per-transaction and company/project/department/agent/category/vendor period limits support warning thresholds and hard stops.
- Hosted migrations include `20260927025955 sutra_agent_worker`, `20260927025959 agent_run_spend_ledger`, and `20260927061227 trusted_model_cost_profiles`. A spend reservation ledger links each leased review run. A provider call needs a valid lease and approved reservation; a review cannot succeed until usage is reconciled. Pending spend approvals block and then resume runs. Unknown usage keeps the full reserved expense and is audited.
- Founder-only, audit-logged model price profiles have hard input/output token ceilings. Reservations snapshot profile rates and ceilings; the database calculates the maximum reserve and validates actual cost from reported tokens. The hosted profile table is empty, so no route is authorized until the founder configures exact rates and limits.
- Telegram command routing, founder identity checks, proposal persistence, internal authorized endpoints, health endpoint, Railway manifests and pinned Hermes container startup are implemented. Hermes runtime configuration limits turns/retries and keeps the API toolset web-only.
- No credentials or tokens are committed. The experimental model worker is intentionally disabled; repository PR/CI work does not make model calls.

## Tests and checks performed

- `python3 -m unittest discover -s tests -v` — 21 passed.
- `python3 -m compileall -q sutra tests` — passed.
- `git diff --check` — passed.
- PR #8 CI run `36289846393` — passed Python tests, local Supabase migrations, pgTAP policy/workflow tests, database lint, both container builds and Gitleaks. Main post-merge run `36289935100` also passed all jobs.
- PR #10 CI run `36299288049` — passed Python tests, local Supabase migrations, all 89 pgTAP policy/workflow assertions, database lint, both container builds and Gitleaks. Live Supabase verification confirms the profile table has RLS and no direct select grants to `anon` or `service_role`; only `service_role` can call the profile-derived reserve RPC; there are zero configured routes. The founder-profile update and reserve/reconcile triggers are live.
- pgTAP exercises the proposal run sequence, an €11 model reserve, department-head approval/requeue, reservation reuse, usage reconciliation before success, founder approval sequencing, policy boundaries, budget hard stops and audit events.
- The authenticated Supabase dashboard ran a read-only catalog query showing 15 public tables with RLS enabled, no `anon`/`authenticated` select grants and service-role read-only access. After CI passed, both additive migrations were applied through the authenticated Supabase connector. Live SQL verification confirmed migration history, ledger RLS, no direct ledger table select grants, service-role-only RPC execution, `expenses.actual_amount`, and both approval/success-gate triggers.
- The Supabase Security Advisor reports 17 informational RLS-without-policy results on server-only tables; direct API grants are withheld. The performance advisor reports 31 unused indexes on this low-traffic project, including the new ledger indexes; re-evaluate against production query patterns before removing indexes. [RLS lint guidance](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy) and [unused-index guidance](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index).
- The exact pinned Hermes source was checked: its OpenAI-compatible API ignores `max_tokens`. The startup image test verifies the configured turn and retry limits.
- The new model-cost migration and its pgTAP fixtures are being validated in CI. Local Supabase startup could not complete because the Docker image pull exhausted available disk (`no space left on device`); the retry was stopped without running Docker cleanup or deleting user data.

## Deployment and integrations

- **Supabase:** Project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is active and reachable on PostgreSQL 17.6. Hosted history contains base schema, operational foundation (`20260927012437`), agent worker (`20260927025955`) and spend ledger (`20260927025959`). The Supabase CLI is installed but logged out and requires an access token for future CLI deployments; the managed connector applied these two migrations. The dashboard displays “Grace period is over” and warns requests may stop when quota is exhausted. No paid upgrade was made. No visible backup/recovery point was confirmed.
- **Railway:** Existing project `lovely-playfulness` still runs a Hermes-only service from `praveen-ks-2001/hermes-agent-template`, not this repository. The authenticated usage page shows `$1.54` current and `$4.81` estimated against `$5` included usage. A Sutra API service was not added because it could exceed included usage. The Railway CLI is unavailable. No Hermes provider credential is configured for Sutra.
- **Telegram:** Not configured. A bot token and founder’s numeric Telegram user ID must be added in the API secret manager before enabling polling.
- **Model provider:** No usable provider credential/route is configured. Add a founder-configured model price profile and an exact route before enabling the worker. `max_tokens` is not an effective cap in the pinned API, so runtime output-token enforcement is still required before any provider call.
- **Engineering execution:** Approved proposals create durable engineering-through-sales tasks, but Sutra does not yet dispatch tasks to Codex, create PRs, attach QA/security evidence or perform release handoff.
- **URLs:** No Sutra API deployment URL is available. The existing Hermes endpoint reported HTTP 200 with `gateway: stopped` in the last runtime probe.

## Remaining blockers

1. Finish and merge the database-controlled model-price profile migration; patch and test the pinned Hermes API so exact route and output-token ceilings are enforced, then wire the worker to reserve, start and reconcile each call. Keep `SUTRA_ENABLE_AGENT_WORKER=false` until verified.
2. Deploy Sutra API on Railway only after confirming an allowance or free deployment option that does not exceed the no-spend constraint. The current service is attached to another repository and usage is near the included limit.
3. Add Telegram bot token and founder numeric ID through Railway’s secret manager. Never send them in chat.
4. Build the approved-task-to-Codex/GitHub issue/PR dispatcher, then capture real QA, Security and release-readiness artifacts.
5. Check Supabase quota and configure a tested recovery option before future schema changes; the project currently displays the grace-period warning.

## Recommended next steps

1. Validate and deploy the database-controlled model price profile; add exact route and output-token enforcement to the pinned Hermes API. Exercise approval, hard-stop, unknown-usage and audit paths before enabling model calls.
2. Confirm Railway costs before adding the API service. Then add provider and Telegram secrets only in their destination secret managers and verify `/health`.
3. Implement Codex engineering dispatch and record pull request, test, security review and release evidence in Supabase/GitHub.
4. Monitor Supabase quota and establish a tested recovery option before subsequent schema changes.
