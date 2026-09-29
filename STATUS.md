# Sutra system status

Updated: 2026-09-29, after PR #194 and the final Architect retry

## What is working

- **Supabase:** The existing project `smqsrigsugjuvuombetq` is reachable. Production schema migrations are applied through `20260929131847 legacy_cpo_retry_recovery`. Supabase remains Sutra's authoritative company state.
- **Financial controls:** Spend policy and budgets are database-backed. AI inference has a monthly €8 hard stop and 80% warning. The live ledger currently shows €0.40 reconciled actual spend and €0.89 reserved as unknown; unknown reservations remain held and are not treated as zero-cost.
- **Railway:** Production project `valiant-liberation` has Hermes (`sutra`) and API (`sutra-api`) services. Hermes is Online and uses the persistent `sutra-volume`. API deployment `c89e88eb-ec38-4fc5-aa14-8215861e14fe`, for PR #193's commit, reports Deployment successful; its `/health` endpoint returned HTTP 200.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is configured for founder ID `8776723105`. Founder-only commands and the board-style CEO status response have been exercised. The response lists projects, open tasks, blockers, approvals, engineering evidence, deferred QA/Security work, and spend controls.
- **GitHub/Codex:** Sutra can dispatch founder-approved Developer tasks and create branches and PRs. It cannot merge or release. Merged implementation work includes PRs [#160](https://github.com/anupdalvi86-oss/sutra/pull/160) and [#188](https://github.com/anupdalvi86-oss/sutra/pull/188), each with successful CI evidence.
- **Governance:** Founder-adjustable Codex no-request retry limit is database-controlled, founder-only, audited, and capped at three total attempts per execution. Changing the limit does not itself retry a task.

## Live company snapshot

Production counts queried from Supabase on 2026-09-29:

- **Projects:** 3 approved and 1 rejected. The approved records are duplicate variants of the same AI QA opportunity, each showing a €500 requested ceiling; they are not three distinct validated opportunities and do not mean €1,500 was spent.
- **Approvals:** 5 approved, 1 rejected, and none pending.
- **Tasks:** 28 total: 13 done, 10 backlog, 2 blocked, 0 in progress, 2 deferred, and 1 cancelled. Duplicate project records repeat backlog work.
- **Agent runs:** 68 succeeded, 14 failed, and 10 blocked.
- **Canonical delivery record:** One approved AI QA opportunity has completed CPO research, PM plan, architecture, Developer/Codex work, and internal CMO, Sales, and DevOps handoffs. The Developer work is represented by merged PR #160. QA and Security reviews are deferred and incomplete. Other duplicate project records have redundant backlog work; PR #188 records the approved discovery-plan work.
- **Customer and campaign records:** none recorded. No external sales or marketing messages have been sent.

## Current recovery and deployment

PR [#193](https://github.com/anupdalvi86-oss/sutra/pull/193) was merged to `main` as `75b636f0e1cf9a20b26820f1e3885ab15881f1d9`. It clarifies the Architect's required technical-design artifact schema and adds a regression test. The main-branch CI run [36589815215](https://github.com/anupdalvi86-oss/sutra/actions/runs/36589815215) passed all five jobs: change detection, secret scanning, containers, database/pgTAP/lint, and Python tests plus Python security analysis.

Railway deployment `c89e88eb-ec38-4fc5-aa14-8215861e14fe` completed successfully after a prolonged platform incident. The new API process returned HTTP 200 from `/health`, and deployment details identify commit `75b636f0e1cf9a20b26820f1e3885ab15881f1d9`.

After the deployment, the founder-authorized final retry was exercised for Architect task `8c59a877-ba5d-4a4e-aa8c-78181de1a265`. It failed with `invalid_artifact_schema`; provider usage could not be verified. All three €0.03 reservations for this task remain unknown, for €0.09 held in total. The retry function's three-attempt limit is exhausted. The stale task status was reconciled to `blocked` by Sutra's existing `sutra_update_task` transition, with an audit event; no direct table update, additional model request, or hidden retry occurred. Project-spend, merge, and release authority were not changed.

## Remaining work and blockers

1. **Architect artifact and retry bound:** The last permitted run failed with an invalid schema and usage is unknown. The task is now correctly `blocked`; its three-attempt retry limit is exhausted. A future recovery must preserve the founder-adjustable attempt limit and use an explicitly authorized audited recovery path. The three unknown reservations remain held.
2. **Workflow proof and record cleanup:** The canonical project has completed internal research, plan, architecture, engineering, and non-external marketing/sales/operations deliverables. Consolidate the duplicate approved project records only through a reviewed, auditable operation that preserves history and budgets. No deduplication has been performed.
3. **Supabase billing continuity:** The logged-in Supabase dashboard showed the free organization's grace period had ended and warned the project could stop serving requests after quota exhaustion. Supabase is reachable now, but continued service may require the founder to select a paid plan or otherwise address quota. No purchase or plan change has been made.
4. **QA/Security:** Security review and QA acceptance verification are deferred and incomplete. Sutra is not release-ready until those gates are restored and pass.
5. **Credentials:** Credentials previously pasted into chat should be rotated directly in their providers and updated in Railway by the founder. No credential values are recorded in this file.

## Verification performed

- PR #193 checks and the merged `main` CI run passed all five CI jobs, including the full Python suite, Python security analysis, database migrations with pgTAP/lint, and container builds.
- Supabase production connectivity was verified with live SQL queries; all expected migrations through `20260929131847` are recorded.
- Production spend policy and reservation totals were queried. Current monthly ledger: €0.40 reconciled actual, €0.89 unknown reservations held, against the active €8 inference hard stop.
- Telegram founder status returned a structured board-style report with the Architect task blocked, both incomplete QA/Security reviews visible, and no pending approvals. Supabase records the final attempt's terminal validation failure, unknown usage, €0.03 held reservation, and founder/audit events. The task transition to blocked was recorded through the existing function. All three attempts for this task are exhausted.
- Railway dashboard confirms Hermes Online and API deployment `c89e88eb-ec38-4fc5-aa14-8215861e14fe` successful. The new API's `/health` check returned HTTP 200.
- Live Supabase RLS/grant inspection previously confirmed RLS enabled and table privileges limited to `service_role`; anon/authenticated have no table grants. This is fail-closed, though policy and authorization tests should remain part of every schema change.

## Deployment and service links

- Railway project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- Railway API: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase project ID: `smqsrigsugjuvuombetq`

## Current readiness

The core operating foundation is deployed: company state, founder-gated workflow, spending controls, Telegram status, and GitHub/Codex PR execution. The system is **operational for controlled internal planning and engineering work, but not fully release-ready**. A completed canonical project demonstrates internal handoff through Marketing, Sales, and DevOps; QA and Security remain intentionally deferred. A duplicate Architect task is blocked after its third invalid-schema failure, with three unknown reservations retained and retry capacity exhausted. Full release readiness also depends on resolving Supabase service continuity and consolidating duplicate project records.
