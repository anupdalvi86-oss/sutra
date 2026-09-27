# Sutra Status

Updated: 2026-09-27 (Europe/Stockholm)

## What is working

- Main is at `b9948ec` (PR #8). The repository contains the founder-controlled company schema, audit trail, configurable spend policies, sequential CEO → CPO → CTO → CFO → Product Manager proposal reviews, and post-approval task handoffs through engineering, QA, Security, DevOps, Marketing and Sales.
- Supabase is the authoritative state model. Founder-only functions change governance settings and budgets; agent self-escalation is rejected. Service tables use RLS and expose no direct access to `anon` or `authenticated`.
- Financial defaults remain in database policy: up to €10 automatic, above €10 to €50 department head, above €50 to below €200 CFO and CEO, €200 and above founder. Per-transaction and company/project/department/agent/category/vendor period limits support warning thresholds and hard stops.
- Migration `20260927024104_agent_run_spend_ledger.sql` adds a spend reservation ledger linked to each leased review run. A provider call needs a valid lease and approved reservation; a review cannot succeed until usage is reconciled. Pending spend approvals block and then resume runs. Unknown usage keeps the full reserved expense and is audited.
- Telegram command routing, founder identity checks, proposal persistence, internal authorized endpoints, health endpoint, Railway manifests and pinned Hermes container startup are implemented. Hermes runtime configuration limits turns/retries and keeps the API toolset web-only.
- No credentials or tokens are committed. The experimental model worker is intentionally disabled; repository PR/CI work does not make model calls.

## Tests and checks performed

- `python3 -m unittest discover -s tests -v` — 21 passed.
- `python3 -m compileall -q sutra tests` — passed.
- `git diff --check` — passed.
- PR #8 CI run `36289846393` — passed Python tests, local Supabase migrations, pgTAP policy/workflow tests, database lint, both container builds and Gitleaks. Main post-merge run `36289935100` also passed all jobs.
- pgTAP exercises the proposal run sequence, an €11 model reserve, department-head approval/requeue, reservation reuse, usage reconciliation before success, founder approval sequencing, policy boundaries, budget hard stops and audit events.
- The authenticated Supabase dashboard ran a read-only catalog query showing 15 public tables with RLS enabled, no `anon`/`authenticated` select grants and service-role read-only access. The project remains reachable. No production schema change was made.
- The Supabase Security Advisor previously reported 15 informational RLS-without-policy results on server-only tables; direct API grants are withheld.
- The exact pinned Hermes source was checked: its OpenAI-compatible API ignores `max_tokens`. The startup image test verifies the configured turn and retry limits.

## Deployment and integrations

- **Supabase:** Project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is reachable on PostgreSQL 17.6. Hosted history has the base schema and operational foundation (`20260927012437`); the agent-worker migration (`20260927013616`) and spend-ledger migration (`20260927024104`) are not applied. The Supabase CLI is installed but logged out and requires an access token. The logged-in dashboard displays “Grace period is over” and warns that requests may stop when quota is exhausted. No paid upgrade was made. No visible backup/recovery point was confirmed.
- **Railway:** Existing project `lovely-playfulness` still runs a Hermes-only service from `praveen-ks-2001/hermes-agent-template`, not this repository. The authenticated usage page shows `$1.54` current and `$4.81` estimated against `$5` included usage. A Sutra API service was not added because it could exceed included usage. The Railway CLI is unavailable. No Hermes provider credential is configured for Sutra.
- **Telegram:** Not configured. A bot token and founder’s numeric Telegram user ID must be added in the API secret manager before enabling polling.
- **Model provider:** No usable provider credential/route is configured. The bounded pricing and exact provider/model lock must be set up before the disabled worker can call Hermes. `max_tokens` is not an effective cap in the pinned API.
- **Engineering execution:** Approved proposals create durable engineering-through-sales tasks, but Sutra does not yet dispatch tasks to Codex, create PRs, attach QA/security evidence or perform release handoff.
- **URLs:** No Sutra API deployment URL is available. The existing Hermes endpoint reported HTTP 200 with `gateway: stopped` in the last runtime probe.

## Remaining blockers

1. Apply the two validated additive agent-worker migrations to Supabase using an authenticated CLI/deployment path. First establish a safe recovery point; the dashboard currently shows the free-plan grace-period warning and no backup was verified.
2. Configure a bounded, database-controlled provider/model price and exact route, then wire the worker to reserve, start and reconcile each call. Keep `SUTRA_ENABLE_AGENT_WORKER=false` until verified.
3. Deploy Sutra API on Railway only after confirming an allowance or free deployment option that does not exceed the no-spend constraint. The current service is attached to another repository and usage is near the included limit.
4. Add Telegram bot token and founder numeric ID through Railway’s secret manager. Never send them in chat.
5. Build the approved-task-to-Codex/GitHub issue/PR dispatcher, then capture real QA, Security and release-readiness artifacts.

## Recommended next steps

1. Check Supabase project quota and backups; use the Supabase CLI with an authorized access token to apply `20260927013616` and `20260927024104` after recovery is available.
2. Add a database-controlled model price/route profile with hard token bounds and connect the Hermes worker to the spend RPCs. Exercise approval, hard-stop, unknown-usage and audit paths before enabling it.
3. Confirm Railway costs before adding the API service. Then add provider and Telegram secrets only in their destination secret managers and verify `/health`.
4. Implement Codex engineering dispatch and record pull request, test, security review and release evidence in Supabase/GitHub.
