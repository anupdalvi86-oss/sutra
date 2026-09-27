# Sutra Status

Updated: 2026-09-27 (Europe/Stockholm)

## What works

- Branch `codex/e2e-operational` contains the implementation and is intended for review before any production migration or deployment.
- The migration covers the existing company tables plus objectives, budgets, agent runs, customers and campaigns; seeds 14 named roles; adds indexes/constraints; enables RLS; removes direct public/authenticated access; and routes consequential financial/governance writes through audited, founder-checked database functions.
- EUR spending thresholds and budgets are stored in Supabase. Boundary behavior is `<= €10` automatic, `> €10–€50` department head, `> €50–< €200` CFO + CEO, and `>= €200` founder. Company/project/department/agent/category/vendor budgets support transaction/daily/monthly/lifetime limits, warning levels and hard stops. A department-head approval fails closed until the founder assigns that approver through the audited settings RPC.
- Founder status, budgeted proposal, and approve/reject command routing is implemented. Proposals persist CEO/Product/CTO/CFO/PM queued handoffs, a blocked research task, an approval, project budget and audit event. CFO review is required before founder approval. Once approved, PM → Architect → Developer → QA → Security → DevOps → Marketing → Sales tasks unlock one at a time with evidence required to complete a task.
- A separate non-root Python API container builds and its `/health` endpoint runs locally. Telegram is restricted to the configured founder in a private chat. The Supabase service credential and Telegram token are designed for the API service only.
- README, architecture, deployment and governance docs describe actual boundaries and manual setup. No credentials are committed.

## Verification performed

- `python3 -m unittest discover -s tests -v`: 13 tests passed.
- `python3 -m compileall -q sutra tests`: passed.
- PostgreSQL 16: migration applied to a clean database and to a simulated copy of the original hosted schema including its 4 legacy spending policies. The local end-to-end SQL smoke passed threshold checks, the CFO/founder approval sequence, sequential PM/architecture/developer/QA task release, evidence requirements, hard-stop rejection, audit entries and anonymous-role denial.
- `.github/workflows/ci.yml` contains Python tests, Supabase local DB/pgtap/lint jobs and Gitleaks scanning. Hosted CI result is pending until the branch PR runs.
- Gitleaks 8.30.1 scan: no leaks found. `git diff --check`: passed.
- `Dockerfile.api` built successfully. A local container returned the expected degraded health response when Supabase and other integrations were intentionally unconfigured.
- Hermes image verification did not finish: the local Docker VM ran out of disk space while copying a file after pulling the upstream image. No Docker pruning was performed because that could remove unrelated user data.
- Supabase dashboard showed the existing `sutra` project (`smqsrigsugjuvuombetq`) as healthy. Its current schema has the original legacy layout and all ten original tables have RLS enabled. No hosted SQL changes were made. The dashboard showed no backups, and the direct unauthenticated health request returned 401; authenticated database connectivity is not verified.
- Existing Railway service `hermes-agent-production-f50d.up.railway.app` previously returned HTTP 200 from `/health` but reported `gateway: stopped`; authenticated root/OpenAPI calls required credentials. No service or deployment was changed. The Railway usage panel showed $1.54 current and $4.81 estimated against a $5 Hobby usage credit, so an additional API service was not created.
- Telegram integration is unverified because no bot token or founder Telegram ID is configured in this workspace.

## Deployment status

- Railway: the pre-existing Hermes service is present; its gateway was reported stopped. No Sutra API is deployed.
- Supabase: hosted project is healthy in its dashboard; migration is not applied and authenticated API/database access is unverified.
- Telegram: not configured.
- GitHub: feature branch and PR/CI status to be added after publication.

## Remaining blockers

1. **Hosted database rollout:** no backup/recovery point was visible in Supabase, and no database credential is available in the environment. Before applying the migration, the founder/operator needs to establish a recovery point and run the migration through the authorized Supabase path. The migration passed local clean and legacy-layout runs but has not touched production.
2. **Railway runtime/API:** the Hermes gateway is currently stopped. The Sutra API is not deployed, and the project is close to its current $5 included-usage allowance. Do not add a service or deploy until projected use stays within the founder's no-spend constraint.
3. **Telegram:** a bot token and founder numeric user ID must be placed in Railway variables. The database founder identity is not registered yet.
4. **Autonomous execution:** queued agent handoffs and gated tasks are persisted, but there is no worker that dispatches tasks to Hermes/Codex, creates GitHub issues/PRs, or records real research, QA and security evidence. This system stores workflow state but is not yet a self-operating company.
5. **Hermes build:** re-run the local image build after freeing Docker VM disk space safely, then validate the upstream entrypoint, state volume and health behavior before any Railway rollout.

## Recommended next steps

1. Review and merge the PR only after GitHub CI passes and the Hermes image/runtime path is validated.
2. Confirm a Supabase recovery path and apply the migration; run policy tests and verify service-role/RLS behavior on the hosted project.
3. Restore Hermes gateway health, then check Railway billing before provisioning the isolated API service.
4. Configure Telegram credentials and a founder ID, then verify founder bootstrap and the command/approval flow in a private chat.
5. Build a worker that consumes only ready tasks, creates GitHub artifacts, records real evidence and stops at the existing approval gates.
