# Sutra Status

Updated: 2026-09-27 (Europe/Stockholm)

## What is working

- GitHub repository access is authenticated as `anupdalvi86-oss`; PRs #1, #2 and #3 are merged. `main` is `67c97185ffb776eb5431c019c69124e840a09b4b`.
- The Supabase project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is `ACTIVE_HEALTHY` on Postgres 17. Migration `20260927012437` is applied. RLS and server-only table grants were verified. The four EUR spending tiers and audited authorization functions are present.
- Founder status/proposal/approval commands persist company state. The database defines 14 agent roles, workflow gates, project/department/agent/category/vendor budgets, approval records and audit logging. Proposals create durable CEO → CPO → CTO → CFO → PM handoffs; approval requires all five reviews and CFO approval.
- The Python API, private Telegram identity checks, proposal/approval routing, health endpoint, Hermes container configuration and Railway manifests are in the repository. Telegram and the optional Hermes worker default to disabled.
- An experimental leased Hermes review worker and its additive database migration are under development on `codex/agent-worker`. They are not deployed or merged. Keep the worker disabled until each model call is reserved and reconciled through database spending policy.
- No secrets are committed. Architecture, deployment and governance docs describe the current boundaries.

## Tests and checks performed

- `python3 -m unittest discover -s tests -v` — 20 passed.
- `python3 -m compileall -q sutra tests` — passed.
- `git diff --check` — passed.
- The previous main-branch CI run `36285703290` passed Python, clean Supabase/pgtap/lint, container builds and Gitleaks for commit `67c9718`.
- Attempted `supabase start` to validate the new worker migration locally. Docker ran out of disk while downloading Supabase images (`no space left on device`); it was stopped without pruning or deleting Docker data. New migration and pgtap changes are not yet validated by CI.
- The hosted Supabase project was verified after the previous migration. The new worker migration is not applied; hosted schema remains at `20260927012437`.
- Supabase advisors report 15 informational `rls_enabled_no_policy` notices (expected for server-only tables with no direct API grants), plus 17 missing foreign-key indexes. The new worker migration now adds those 17 indexes; hosted status will be rechecked after its CI validation and release. Eleven unused-index notices are informational on this nearly empty project.

## Deployment and integrations

- **Railway:** [Existing Hermes URL](https://hermes-agent-production-f50d.up.railway.app) is connected to `praveen-ks-2001/hermes-agent-template`, not Sutra. Its last observed health body reported `gateway: stopped`. Sutra API is not deployed. Last observed usage was `$1.54` current / `$4.81` estimated against `$5` included credit; recheck before creating services. Railway's GitHub integration still needs access to the Sutra repository.
- **Supabase:** project is healthy and the operational foundation migration is applied. The worker migration and an API service-role connectivity probe have not yet been run.
- **Telegram:** not configured. Bot token and numeric founder Telegram ID must be added only through the Railway secret manager; founder bootstrap and polling are disabled.
- **Hermes/model provider:** there is no configured provider credential available in this workspace. Gateway status on the existing Railway service was stopped.
- **GitHub:** CLI access is authorized. There is no Sutra Codex/GitHub engineering dispatcher yet; approved engineering tasks do not automatically become issues/PRs.

## Blockers and next steps

1. Railway repo permission is a human approval in the logged-in Railway/GitHub integration. Approve repository-only access for `anupdalvi86-oss/sutra` if Railway offers that scope. Then recheck Railway usage before deploying services; do not exceed included credits or purchase a plan.
2. Add Supabase server credentials, a random internal API token, Hermes provider credentials, and Telegram bot token/founder numeric ID through Railway secrets. Do not send these in chat or commit them.
3. Finish database-backed model cost reservation/reconciliation before enabling the Hermes worker. The current worker prototype could otherwise incur unbounded provider usage.
4. Run CI for the pending worker migration, address any failures, and only then apply the additive migration to Supabase. A database backup/recovery path should be established before further production schema changes; the prior Supabase account had no visible backup point.
5. Deploy/verify Sutra API and Hermes, enable Telegram only after the founder identity is verified, and exercise the simulated CEO → product research → CTO → CFO → PM → founder approval flow. The post-approval engineering, PR, QA/security and release chain still needs a controlled execution worker.

## Morning handoff

No action is needed for the local unit test run. The human-only items are Railway repository access and supplying integration credentials through provider secret managers. Do not enable the experimental Hermes worker until model-call spending is policy-authorized in Supabase.
