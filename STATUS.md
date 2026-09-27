# Sutra Status

Updated: 2026-09-27 (Europe/Stockholm)

## What is working

- GitHub CLI is authenticated as `anupdalvi86-oss` with repository and workflow access. Main is at `61c7bfd` (`Add gated sequential agent review worker (#4)`). PR #4 is merged; its worker remains deliberately disabled until model-cost preflight and reconciliation are implemented.
- Supabase project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is reachable and healthy on PostgreSQL 17.6. Hosted migration history contains the initial schema, RLS setup, and operational foundation (`20260927012437`). The latest verified connection query succeeded.
- Supabase holds the company state, agent roles, approvals, audited spending policies and limits. The configurable EUR approval tiers and founder-only authority are in the database. Server-only tables have RLS enabled and direct API grants are withheld.
- The founder command router, proposal/approval persistence, internal authorization endpoints, health endpoint, Railway manifests and Hermes container configuration are implemented. The Python service tests cover founder identity, malformed requests, spending request routing, worker fail-closed behavior and artifact validation.
- The experimental review pipeline records sequential CEO → CPO → CTO → CFO → PM runs and gates founder project approval on their completion and CFO approval. It does not make model calls until database-backed model spend control is complete.
- Hermes startup configuration now caps API-server turns at three, model API retries at one attempt, and automatic recovery cycles at zero. The pinned Hermes OpenAI-compatible endpoint ignores request `max_tokens`; the runtime startup test verifies these controls and the `web`-only toolset.
- No credentials or tokens are committed.

## Tests and checks performed

- `python3 -m unittest discover -s tests -v` — 21 passed on 2026-09-27.
- `python3 -m compileall -q sutra tests` — passed.
- `git diff --check` — passed.
- Main CI run `36287532970` passed on the merged worker commit. CI includes Python tests, clean Supabase migrations and pgTAP policy tests, database lint, both container builds, and Gitleaks.
- Supabase connectivity was verified with a live SQL query; hosted migration history was read without applying a new migration.
- Supabase security advisor reports 15 informational `rls_enabled_no_policy` findings for tables that have no direct API grants. They are currently server-only. Review again if grants or exposed access change.
- The pinned Hermes image identifies upstream source revision `749220ef0007f8d87bd1531f1c24b0fe93816385` (2026-09-24). Its API source was checked to verify runtime lock support, retry/turn controls, usage metadata and the ignored `max_tokens` field.
- The public Railway Hermes health endpoint returned HTTP 200 with `gateway: stopped`.

## Deployment and integrations

- **Railway:** The existing project is `lovely-playfulness`; the visible service is based on `praveen-ks-2001/hermes-agent-template`, not Sutra. No Sutra API deployment was verified. The current usage page shows `$1.54` current and `$4.81` estimated against `$5` included usage. Do not add services or enable a paid provider call until the allowance and billing settings are checked. Railway repo-only authorization for `anupdalvi86-oss/sutra` is still needed if deployment is to use the GitHub source integration.
- **Supabase:** Connectivity works through the authenticated dashboard integration. Hosted migration `20260927013616_sutra_agent_worker` is not applied. No production schema was changed during this continuation.
- **Telegram:** Not configured. A bot token and the founder's numeric Telegram user ID are needed in Railway's secret manager before enabling polling.
- **Hermes/model provider:** The existing endpoint is stopped. No provider credential is available to Sutra. Model-backed work remains disabled pending provider/model locking, trusted pricing, bounded usage, atomic policy reservation and actual-usage reconciliation (tracked in [issue #5](https://github.com/anupdalvi86-oss/sutra/issues/5)).
- **Engineering execution:** GitHub CLI works, but Sutra has no task-to-Codex dispatcher that creates issues/PRs, runs QA/security reviews and records release evidence. The post-approval engineering handoff is not operational.

## Remaining blockers

1. Grant Railway repository-only access to `anupdalvi86-oss/sutra` if the project GitHub integration is to deploy from GitHub.
2. Provide secrets through their respective secret managers: Supabase server URL/service key, a random internal API token, Hermes API/provider credentials, and Telegram bot token plus founder numeric ID. Do not send credentials in chat or commit them.
3. Complete issue #5 and validate its bounded pricing and accounting path before enabling the worker or applying its migration to production.
4. Check Railway's current allowance and billing behavior before creating or starting services. The last observed estimate was near the included allowance; no paid plan or spend was initiated.
5. Complete the engineering dispatcher and end-to-end QA/security/release evidence flow. Until it exists, founder-approved proposals persist in Supabase but do not become validated PRs or releases.

## Recommended next steps

1. Add the missing secrets directly in Railway and authorize repository access.
2. Finish and CI-validate model spend reservation/reconciliation; then apply the additive migration only after the migration and recovery path are reviewed.
3. Deploy Sutra API and Hermes within the available allowance, verify health and Supabase connectivity, then configure the founder-only Telegram interface.
4. Exercise a simulated proposal through CEO, Product, CTO, CFO, PM and founder approval; then wire and verify engineering, QA, Security and release handoffs.
