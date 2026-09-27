# Sutra Status

Updated: 2026-09-27 (Europe/Stockholm)

## What works

- The operational foundation is merged to `main` at `7a534ee` from [PR #2](https://github.com/anupdalvi86-oss/sutra/pull/2).
- The existing Supabase project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is `ACTIVE_HEALTHY` on Postgres 17. The operational migration is applied and recorded as `20260927012437` (`sutra_operational_foundation`).
- All 15 public company tables have RLS enabled. Direct table privileges are revoked from `anon`, `authenticated`, and `service_role` where writes would bypass policy; audited security-definer RPCs are the server-side write path. Four EUR spending tiers are present: `<= €10`, `> €10–€50`, `> €50–< €200`, and `>= €200`. The migration also seeds company/project/department/agent/category/vendor budget support, warning thresholds, and hard stops.
- The database contains 14 named agent roles across 10 departments. Proposals create durable project, objective, approval, research task, agent handoffs, and audit records. Founder approval is gated on the CFO decision. Approval releases sequential PM → Architect → Developer → QA → Security → DevOps → Marketing → Sales work with evidence requirements.
- The Python API supports founder status/proposal/approval commands, private-chat identity checks, fail-closed spend authorization, role approvals, task updates, and health reporting. The Telegram polling integration is implemented but disabled until credentials and founder identity are configured.
- Hermes uses a pinned upstream image and its normal privileged startup entrypoint. Docker/Railway configs and recovery/health behavior are in the repository.
- No secrets are committed. README, architecture, governance, deployment and this status file document current state.

## Verification performed

- Local Python suite: `python3 -m unittest discover -s tests -v` — 13 passed.
- `python3 -m compileall -q sutra tests` and `git diff --check` passed.
- PR #2 and post-merge `main` CI passed all four jobs: Python tests, Supabase local DB/pgtap/lint, API and Hermes image builds, and secret scanning.
- Database tests ran against clean PostgreSQL and a simulated legacy schema. They exercised the spend boundaries, budget hard stops, founder-only actions, CFO/founder approval sequence, child task release/evidence gates, malformed requests, and audit records.
- Supabase production migration history, tables, row-level-security flags, role/policy seeds, and live project health were verified after applying the migration. Preserved legacy policy rows were normalized into the four documented tiers.
- Supabase security advisor returns 15 informational [`rls_enabled_no_policy`](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy) findings. This is intentional for server-only tables: direct API roles have no table grants and the service role uses audited RPCs. Review this if adding a new access path.
- GitHub Actions secret scan passed with no findings. The local shell currently has no `gitleaks` executable.
- Railway's existing Hermes URL previously returned HTTP 200 but `gateway: stopped`. The API and a running Hermes gateway have not been deployed/verified.

## Deployment status

- **GitHub:** PR #2 is merged to `main` at `7a534ee`. The post-merge CI run passed all four jobs.
- **Supabase:** migration applied successfully; project remains `ACTIVE_HEALTHY`. Company workflow data is empty until the founder submits the first command. Production API-key connectivity has not been tested because no key is configured in this workspace.
- **Railway:** existing Hermes URL: [hermes-agent-production-f50d.up.railway.app](https://hermes-agent-production-f50d.up.railway.app). Its service is connected to `praveen-ks-2001/hermes-agent-template`, not Sutra, and `/health` reported `gateway: stopped`. No Sutra API service is deployed. The usage panel showed `$1.54` current and `$4.81` estimated against `$5` included credit; no additional service was created.
- **Telegram:** not configured. No bot token or founder numeric user ID is available; founder bootstrap and polling remain disabled.

## Remaining blockers

1. **Railway repository permission and deployment:** the Railway GitHub integration must be granted access to private `anupdalvi86-oss/sutra` to deploy it. That provider permission grant needs your action in the logged-in browser. Before creating/starting an additional API service, recheck usage so it does not incur spending beyond the included allowance.
2. **Founder interface:** provide a Telegram bot token and numeric founder user ID through Railway's secret-variable UI. The database founder identity is unset. Keep Telegram disabled until the founder identity is bootstrapped and verified.
3. **Autonomous execution:** persisted role handoffs and gated work do not yet have an agent worker. Sutra does not yet dispatch work to Hermes/Codex, create GitHub issues/PRs from approved projects, or capture real research, QA and security evidence. Marketing and sales actions are proposal-only; no external messages are sent.
4. **Runtime verification:** confirm Hermes gateway and Sutra API health after Railway access, variables and budget are settled. The Hermes endpoint currently reports a stopped gateway.
5. **Recovery path:** this Supabase organization is on the free plan and showed no backup/recovery point before migration. The migration was additive and preserved existing data; establish a recoverable backup/restore path before future production schema changes.

## Recommended next steps

1. In Railway, authorize the private Sutra repository for the existing project, then choose the API/Hermes service layout after checking included usage and current plan.
2. Add server-only Supabase credentials, a random `SUTRA_INTERNAL_TOKEN`, Hermes provider credentials, and the Telegram token/founder ID through Railway's secret manager. Never commit them.
3. Verify one private Telegram status command, submit a budgeted proposal, approve it through CFO then founder, and inspect project/tasks/approval/audit rows.
4. Implement a worker with explicit provider credentials and task leases; have it produce GitHub artifacts and test evidence before tasks can advance. Keep marketing/sales external actions behind founder approvals.
5. Set up and test database recovery before further production migrations.
