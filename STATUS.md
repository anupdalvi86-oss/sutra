# Sutra system status

Updated: 2026-09-29 17:52 UTC, after Railway rollout and live Telegram verification

## What is working

- **Supabase:** The existing project `smqsrigsugjuvuombetq` reports `ACTIVE_HEALTHY` on PostgreSQL 17.6.1. Production migration history ends at `20260929131847 legacy_cpo_retry_recovery`. Supabase remains Sutra's authoritative company state. The organization is on the Free plan and the dashboard warns service requests may stop after quota exhaustion.
- **Financial controls:** Spend policy and budgets are database-backed. AI inference has a monthly €8 hard stop and 80% warning. The live ledger currently shows €0.40 reconciled actual spend and €0.92 reserved as unknown; unknown reservations remain held and are not treated as zero-cost.
- **Railway:** Production project `valiant-liberation` has Hermes (`sutra`) and API (`sutra-api`) services. Hermes is Online with persistent volume `sutra-volume`. API deployment `6b2c9d7e-96a7-44ba-ad36-673fa5cfe77c`, for PR #201 commit `42cd8127efd4b63f7a00dbe6b87d1c7a59d081a8`, is Active and successful; `/health` passed. Railway's dashboard still shows its service incident banner, but this deployment completed.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is configured for founder ID `8776723105`. Founder-only commands and board-style status reports are exercised. PR [#197](https://github.com/anupdalvi86-oss/sutra/pull/197) removes the 3,800-character report truncation and sends long reports as bounded, ordered Telegram messages, with approval controls retained on the final part. Production verification returned the CEO report in two labeled messages, with all budget rows and the final “Next focus” section intact.
- **GitHub/Codex:** Sutra can dispatch founder-approved Developer tasks and create branches and PRs. It cannot merge or release. Merged implementation work includes PRs [#160](https://github.com/anupdalvi86-oss/sutra/pull/160) and [#188](https://github.com/anupdalvi86-oss/sutra/pull/188), each with successful CI evidence. The AI QA scope and implementation-plan review documents merged in [#192](https://github.com/anupdalvi86-oss/sutra/pull/192) and [#191](https://github.com/anupdalvi86-oss/sutra/pull/191); these documents do not validate the product opportunity.
- **Governance:** Founder-adjustable Codex no-request retry limit is database-controlled, founder-only, audited, and capped at three total attempts per execution. Changing the limit does not itself retry a task.

During the 2026-09-29 follow-up, Railway displayed “API degradation causing slow or stuck deployments” and temporarily showed **Limited Access — Deploys have been paused temporarily**. Deployment `6b2c9d7e-96a7-44ba-ad36-673fa5cfe77c` later completed successfully and became Active. Its health-check phase passed; no manual restart, variable edit, or rollback was made. The logged-in Telegram session then returned the CEO board report in two labeled messages after a new read-only status request at 17:48 UTC.

## Live company snapshot

Production counts queried from Supabase on 2026-09-29:

- **Projects:** 3 approved and 1 rejected, each with a €500 requested project ceiling. The approved records are separate scopes: (1) the original draft-only Playwright workflow, (2) prerequisite-gated discovery with only a conditional small prototype evaluation, and (3) a founder-approved no-spend proposal/re-review. They do not establish three validated product opportunities, and their ceilings do not mean €1,500 was spent or authorize transactions. The rejected submission is retained as history.
- **Approvals:** 5 approved, 1 rejected, and none pending.
- **Tasks:** 28 total: 13 done, 8 backlog, 2 blocked, 0 in progress, 4 deferred, and 1 cancelled. Two project reviews have been deferred through the founder-only audited workflow.
- **Agent runs:** 69 succeeded, 15 failed, and 12 blocked, including the two recent failed-usage events and the resulting blocked task records.
- **Delivery records:** The original draft-only scope has completed CPO research, PM plan, architecture, Developer/Codex work, and internal CMO, Sales, and DevOps handoffs; Developer work is represented by merged PR #160. QA and Security reviews on that project are deferred and incomplete. The second, discovery-gated scope has its own completed CPO/PM/Architect/Developer artifacts; its QA and Security reviews are now deferred and incomplete. The founder deferral released the dependent internal DevOps planning task, whose run then failed with unverified spend and is now blocked; its €0.03 reservation remains unknown. Marketing and Sales tasks remain backlog. The newest no-spend proposal has completed CPO/PM work, while its Architect task is blocked after exhausting retries. PR #188 records the discovery-plan work. These records preserve different founder decisions and should not be merged as duplicates.
- **Customer and campaign records:** none recorded. No external sales or marketing messages have been sent.

## Current recovery and deployment

PR [#193](https://github.com/anupdalvi86-oss/sutra/pull/193) was merged to `main` as `75b636f0e1cf9a20b26820f1e3885ab15881f1d9`. It clarifies the Architect's required technical-design artifact schema and adds a regression test. The main-branch CI run [36589815215](https://github.com/anupdalvi86-oss/sutra/actions/runs/36589815215) passed all five jobs: change detection, secret scanning, containers, database/pgTAP/lint, and Python tests plus Python security analysis.

PR [#197](https://github.com/anupdalvi86-oss/sutra/pull/197) was merged as `e3cadff0f1e1eaa1f173585ffc59279a80d80b99`. Main CI run [36596008207](https://github.com/anupdalvi86-oss/sutra/actions/runs/36596008207) passed all five jobs. Railway deployment `2b3b596d-a532-4a4d-a102-5dedbeb43675` for this commit completed successfully after a provider delay. Railway reports the API Online; its configured `/health` network health-check stage passed. From the logged-in founder Telegram session, a CEO status request returned parts 1/2 and 2/2. The final part contained the remaining project budgets, expense summary, and “Next focus” section; there was no truncation marker.

PRs [#191](https://github.com/anupdalvi86-oss/sutra/pull/191) and [#192](https://github.com/anupdalvi86-oss/sutra/pull/192) merged the proposed AI QA implementation plan and scope document. They preserve open product-validation questions and do not authorize spending or mark QA/Security complete.

PR [#201](https://github.com/anupdalvi86-oss/sutra/pull/201) merged to `main` as `42cd8127efd4b63f7a00dbe6b87d1c7a59d081a8`. It persists bounded Hermes usage-envelope and response-shape labels when spend reconciliation remains unknown, without persisting provider response text or token values. Unknown reservations remain held, and reconciliation remains fail-closed. All five PR checks passed: Python tests/security analysis, 468 database policy tests and lint, container/Hermes checks, change detection, and secret scan. Railway deployment `6b2c9d7e-96a7-44ba-ad36-673fa5cfe77c` is Active and successful; `/health` passed.

Railway deployment `c89e88eb-ec38-4fc5-aa14-8215861e14fe` completed successfully after a prolonged platform incident. The new API process returned HTTP 200 from `/health`, and deployment details identify commit `75b636f0e1cf9a20b26820f1e3885ab15881f1d9`.

After the deployment, the founder-authorized final retry was exercised for Architect task `8c59a877-ba5d-4a4e-aa8c-78181de1a265`. It failed with `invalid_artifact_schema`; provider usage could not be verified. All three €0.03 reservations for this task remain unknown, for €0.09 held in total. The retry function's three-attempt limit is exhausted. The stale task status was reconciled to `blocked` by Sutra's existing `sutra_update_task` transition, with an audit event; no direct table update, additional model request, or hidden retry occurred. Project-spend, merge, and release authority were not changed.

Later, the founder-authorized QA/Security deferral for the discovery-gated project was recorded in Telegram through the audited database function. Both reviews remain incomplete. The function released one directly dependent internal DevOps planning task without granting release authority. The worker then attempted that bounded artifact, could not reconcile usage, retained its €0.03 reservation as unknown, and blocked the task after the run's artifact attempts were exhausted. No release, external outreach, merge, or additional authority resulted. Current unknown reservations total €0.92.

## Remaining work and blockers

1. **Usage reconciliation and blocked task recovery:** The Architect task failed schema validation and the newly released DevOps planning task could not reconcile model usage. Both are blocked; all unknown reservations remain held. Their current retry/attempt capacity is exhausted. Do not retry or release the reservations without an audited recovery path and verified provider usage.
2. **Scope-specific workflow completion:** The approved project records are separate scopes with different gates and deliverables, not interchangeable duplicates. Continue or close each only against its own approval and acceptance criteria. Do not merge records or transfer tasks/budgets between them without a new audited founder decision.
3. **Supabase billing continuity:** The logged-in Supabase dashboard showed the free organization's grace period had ended and warned the project could stop serving requests after quota exhaustion. Supabase is reachable now, but continued service may require the founder to select a paid plan or otherwise address quota. No purchase or plan change has been made.
4. **QA/Security:** QA and Security are now deferred and incomplete on two projects, per founder direction. Sutra is not release-ready until the applicable gates are restored and pass.
5. **Credentials:** Credentials previously pasted into chat should be rotated directly in their providers and updated in Railway by the founder. No credential values are recorded in this file.
6. **Kimi usage validation:** The active Kimi price profile is not routed to an operating role. Production has two Kimi reservations totaling €0.56 with unknown usage; preserve both. Do not route role work to Kimi until a fresh, database-reserved reproduction through [issue #86](https://github.com/anupdalvi86-oss/sutra/issues/86) reconciles through Sutra's usage RPC. There are currently no ready tasks, and no scope-matched Kimi probe is queued.

## Verification performed

- PR #193 checks and the merged `main` CI run passed all five CI jobs, including the full Python suite, Python security analysis, database migrations with pgTAP/lint, and container builds.
- PR #197 and main CI run [36596008207](https://github.com/anupdalvi86-oss/sutra/actions/runs/36596008207) passed all five jobs. Local validation included 212 Python tests, compile checks, Bandit, Gitleaks, and `git diff --check`. Railway deployment `2b3b596d-a532-4a4d-a102-5dedbeb43675` is successful and Online. A live Telegram founder status request was verified across two messages, including financial controls and the final next-focus section.
- PR #201 CI passed all five jobs. Local checks passed: 212 Python tests, compile check, `git diff --check`, and Bandit (no issues identified). CI additionally passed 468 SQL policy tests, database lint, both container builds and Hermes startup checks, and Gitleaks. Railway API deployment `6b2c9d7e-96a7-44ba-ad36-673fa5cfe77c` is Active and successful; its health-check phase passed.
- Supabase production connectivity was verified with live SQL queries; all expected migrations through `20260929131847` are recorded.
- Production spend policy and reservation totals were queried after the latest worker run. Current ledger: €0.40 reconciled actual, €0.92 in unknown reservations held (€0.56 Kimi; €0.36 OpenAI), against the active €8 inference hard stop. Recorded expenses total €1.32 requested and €0.40 actual; requests and budget ceilings are not actual spend.
- Telegram founder status returned a structured board-style report with the Architect task blocked, both incomplete QA/Security reviews visible, and no pending approvals. Supabase records the final attempt's terminal validation failure, unknown usage, €0.03 held reservation, and founder/audit events. The task transition to blocked was recorded through the existing function. All three attempts for this task are exhausted.
- Railway dashboard confirms Hermes Online and API deployment `6b2c9d7e-96a7-44ba-ad36-673fa5cfe77c` successful. Railway's configured `/health` network health-check stage passed.
- Live Supabase grant inspection found 24 public tables, with zero tables directly accessible to `anon` or `authenticated`; 15 are directly accessible to `service_role` and the rest are RPC-only. The security advisor reports 24 informational `rls_enabled_no_policy` findings: RLS is enabled without direct policies, while public API table grants remain absent. Continue the database policy and authorization tests with every schema change.

## Deployment and service links

- Railway project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- Railway API: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase project ID: `smqsrigsugjuvuombetq`

## Current readiness

The core operating foundation is deployed: company state, founder-gated workflow, spending controls, Telegram status, and GitHub/Codex PR execution. The system is **operational for controlled internal planning and engineering work, but not fully release-ready**. The 17:48 UTC Telegram board report listed 10 open tasks (8 backlog, 2 blocked), four deferred QA/Security reviews, and no pending approvals. Marketing/Sales work remains internal and unsent. The blocked Architect and DevOps tasks still have unknown reservations and exhausted attempt capacity. Full release readiness depends on restoring QA/Security gates, resolving individual blocked tasks through verified usage/schema recovery, and confirming Supabase service continuity.
