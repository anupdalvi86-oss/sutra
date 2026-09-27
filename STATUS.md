# Sutra Status

Updated: 2026-09-27 (Europe/Stockholm)

## What works

- Branch `codex/e2e-operational` is published in [PR #2](https://github.com/anupdalvi86-oss/sutra/pull/2). It is not merged.
- The migration covers the existing company tables plus objectives, budgets, agent runs, customers and campaigns; seeds 14 named roles; adds indexes/constraints; enables RLS; removes direct public/authenticated access; and routes consequential financial/governance writes through audited, founder-checked database functions.
- EUR spending thresholds and budgets are stored in Supabase. Boundary behavior is `<= €10` automatic, `> €10–€50` department head, `> €50–< €200` CFO + CEO, and `>= €200` founder. Company/project/department/agent/category/vendor budgets support transaction/daily/monthly/lifetime limits, warning levels and hard stops. A department-head approval fails closed until the founder assigns that approver through the audited settings RPC.
- Founder status, budgeted proposal, and approve/reject command routing is implemented. Proposals persist CEO/Product/CTO/CFO/PM queued handoffs, a blocked research task, an approval, project budget and audit event. CFO review is required before founder approval. Once approved, PM → Architect → Developer → QA → Security → DevOps → Marketing → Sales tasks unlock one at a time with evidence required to complete a task.
- A separate non-root Python API container builds and its `/health` endpoint runs locally. Telegram is restricted to the configured founder in a private chat. The Supabase service credential and Telegram token are designed for the API service only.
- Hermes uses a pinned official image digest, keeps the upstream root s6 entrypoint active to prepare state and drop privileges, and leaves Hermes' optional API server disabled.
- README, architecture, deployment and governance docs describe actual boundaries and manual setup. No credentials are committed.

## Verification performed

- `python3 -m unittest discover -s tests -v`: 13 tests passed.
- `python3 -m compileall -q sutra tests`: passed.
- PostgreSQL 16: migration applied to a clean database and to a simulated copy of the original hosted schema including its 4 legacy spending policies. The local end-to-end SQL smoke passed threshold checks, the CFO/founder approval sequence, sequential PM/architecture/developer/QA task release, evidence requirements, hard-stop rejection, audit entries and anonymous-role denial.
- `.github/workflows/ci.yml` contains Python tests, Supabase local DB/pgtap/lint, API/Hermes container builds and Gitleaks scanning. At commit `76c6515`, hosted Python, database and secret-scan checks passed; the expanded run that adds container builds is pending.
- Gitleaks 8.30.1 scan: no leaks found. `git diff --check`: passed.
- `Dockerfile.api` built successfully. A local container returned the expected degraded health response when Supabase and other integrations were intentionally unconfigured.
- Hermes image verification did not finish locally: the Docker VM ran out of disk space while copying the upstream image. The workflow now builds both images on GitHub Actions. No Docker pruning was performed because that could remove unrelated user data.
- Supabase's authenticated connector verified project `sutra` (`smqsrigsugjuvuombetq`) is `ACTIVE_HEALTHY` on Postgres 17.6. It confirms the original legacy layout, the 4 existing EUR policy tiers, and only two hosted migrations. No hosted SQL changes were made. The dashboard showed no backups; the organization is on the free plan.
- Existing Railway service `hermes-agent-production-f50d.up.railway.app` previously returned HTTP 200 from `/health` but reported `gateway: stopped`; authenticated root/OpenAPI calls required credentials. No service or deployment was changed. The Railway usage panel showed $1.54 current and $4.81 estimated against a $5 Hobby usage credit, so an additional API service was not created.
- Telegram integration is unverified because no bot token or founder Telegram ID is configured in this workspace.

## Deployment status

- Railway: the existing Hermes service is present, but its source is `praveen-ks-2001/hermes-agent-template`, not this Sutra repository. Its public `/health` says `gateway: stopped`; no Sutra API is deployed.
- Supabase: hosted project is healthy in its dashboard; migration is not applied and authenticated API/database access is unverified.
- Telegram: not configured.
- GitHub: [PR #2](https://github.com/anupdalvi86-oss/sutra/pull/2) is open; the prior Python/database/secret checks passed, with image-build checks pending.

## Remaining blockers

1. **Hosted database rollout:** the Supabase connector can reach the production database, but no backup/recovery point is visible. The migration is additive and passed local clean/legacy-layout runs; it has not touched production. The repo version must be merged or otherwise pinned before applying it so hosted migration history remains aligned.
2. **Railway runtime/API:** the Hermes service is still connected to a different GitHub repository. Connecting this private Sutra repo requires a Railway GitHub authorization in the browser. The Sutra API is not deployed, and the project is close to its current $5 included-usage allowance. No new service was created.
3. **Telegram:** a bot token and founder numeric user ID must be placed in Railway variables. The database founder identity is not registered yet.
4. **Autonomous execution:** queued agent handoffs and gated tasks are persisted, but there is no worker that dispatches tasks to Hermes/Codex, creates GitHub issues/PRs, or records real research, QA and security evidence. This system stores workflow state but is not yet a self-operating company.
5. **Hermes image:** GitHub Actions is now building the pinned image. Verify a running gateway with the configured provider before any Railway rollout; the existing service currently reports `gateway: stopped`.

## Recommended next steps

1. Review the PR and all CI jobs, including image builds.
2. Establish a recoverable Supabase change path, then apply the merged migration and verify the service-role/RLS behavior on the hosted project.
3. Authorize Railway's GitHub connection to the Sutra repository, then deploy the existing Hermes service and verify its gateway. Check projected usage before provisioning the isolated API service.
4. Configure Telegram credentials and a founder ID, then verify founder bootstrap and the command/approval flow in a private chat.
5. Build a worker that consumes only ready tasks, creates GitHub artifacts, records real evidence and stops at the existing approval gates.
