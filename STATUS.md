# Sutra system status

Updated: 2026-09-29, after PR #193 merged and live production checks

## What is working

- **Supabase:** The existing project `smqsrigsugjuvuombetq` is reachable. Production schema migrations are applied through `20260929131847 legacy_cpo_retry_recovery`. Supabase remains Sutra's authoritative company state.
- **Financial controls:** Spend policy and budgets are database-backed. AI inference has a monthly €8 hard stop and 80% warning. The live ledger currently shows €0.40 reconciled actual spend and €0.86 reserved as unknown; unknown reservations remain held and are not treated as zero-cost.
- **Railway:** Production project `valiant-liberation` has Hermes (`sutra`) and API (`sutra-api`) services. Hermes is Online and uses the persistent `sutra-volume`. The API's previous deployment remains Online while a new deployment builds.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is configured for founder ID `8776723105`. Founder-only commands and the board-style CEO status response have been exercised. The response lists projects, open tasks, blockers, approvals, engineering evidence, deferred QA/Security work, and spend controls.
- **GitHub/Codex:** Sutra can dispatch founder-approved Developer tasks and create branches and PRs. It cannot merge or release. Merged implementation work includes PRs [#160](https://github.com/anupdalvi86-oss/sutra/pull/160) and [#188](https://github.com/anupdalvi86-oss/sutra/pull/188), each with successful CI evidence.
- **Governance:** Founder-adjustable Codex no-request retry limit is database-controlled, founder-only, audited, and capped at three total attempts per execution. Changing the limit does not itself retry a task.

## Live company snapshot

Production counts queried from Supabase on 2026-09-29:

- **Projects:** 3 approved and 1 rejected. The approved records are duplicate variants of the same AI QA opportunity, each showing a €500 requested ceiling; they are not three distinct validated opportunities and do not mean €1,500 was spent.
- **Approvals:** 5 approved, 1 rejected, and none pending.
- **Tasks:** 28 total: 13 done, 10 backlog, 1 blocked, 1 in progress, 2 deferred, and 1 cancelled. The one in-progress task is the Architect recovery below. Duplicate project records repeat backlog work.
- **Agent runs:** 67 succeeded, 13 failed, and 10 blocked.
- **Customer and campaign records:** none recorded. No external sales or marketing messages have been sent.

## Current recovery and deployment

PR [#193](https://github.com/anupdalvi86-oss/sutra/pull/193) was merged to `main` as `75b636f0e1cf9a20b26820f1e3885ab15881f1d9`. It clarifies the Architect's required technical-design artifact schema and adds a regression test. The main-branch CI run [36589815215](https://github.com/anupdalvi86-oss/sutra/actions/runs/36589815215) passed all five jobs: change detection, secret scanning, containers, database/pgTAP/lint, and Python tests plus Python security analysis.

Railway deployment `c89e88eb-ec38-4fc5-aa14-8215861e14fe` for that commit is still building. The Railway dashboard shows an active platform incident for slow or stuck deployments. The API service's earlier deployment remains Online; no manual redeploy or rollback has been triggered. The new artifact prompt is not yet live.

After deployment is healthy, one final founder-authorized retry remains for Architect task `8c59a877-ba5d-4a4e-aa8c-78181de1a265`. Its two failed attempts each have an unknown €0.03 reservation and no verified token totals. Both unknown reservations remain reserved. A third attempt must use a fresh spend reservation under the existing €8 monthly cap; it will not change project spend, merge, or release authority. No attempt should be made until the prompt fix is live.

## Remaining work and blockers

1. **Railway platform incident:** Wait for deployment `c89e88eb-ec38-4fc5-aa14-8215861e14fe` to finish and verify the API health check at `/health`. The prior version remains Online in the meantime.
2. **Architect artifact:** After the new version is live, make at most the one remaining authorized retry. Verify the design artifact, task state, reservation reconciliation, and audit event in Supabase.
3. **Workflow proof:** Exercise the complete founder → CEO → Product/Research → CTO/Architect → CFO → PM → founder approval flow and the approved Developer/Codex → PR → release-readiness handoff. Developer PRs already exist and CI passed; QA and Security stages remain deferred at the founder's direction.
4. **Duplicate planning records:** Consolidate the three approved AI QA project variants only through a reviewed, auditable data operation that preserves their history and budgets. No deduplication has been performed.
5. **Supabase billing continuity:** The logged-in Supabase dashboard showed the free organization's grace period had ended and warned the project could stop serving requests after quota exhaustion. Supabase is reachable now, but continued service may require the founder to select a paid plan or otherwise address quota. No purchase or plan change has been made.
6. **QA/Security:** Security review and QA acceptance verification are deferred and incomplete. Sutra is not release-ready until those gates are restored and pass.
7. **Credentials:** Credentials previously pasted into chat should be rotated directly in their providers and updated in Railway by the founder. No credential values are recorded in this file.

## Verification performed

- PR #193 checks and the merged `main` CI run passed all five CI jobs, including the full Python suite, Python security analysis, database migrations with pgTAP/lint, and container builds.
- Supabase production connectivity was verified with live SQL queries; all expected migrations through `20260929131847` are recorded.
- Production spend policy and reservation totals were queried. Current monthly ledger: €0.40 reconciled actual, €0.86 unknown reservations held, against the active €8 inference hard stop.
- Telegram founder status was exercised and returned a structured board-style report. The most recent Architect retry request was accepted; production state records the attempt as failed with unknown usage, so the single remaining attempt is gated on deploying PR #193.
- Railway dashboard confirms Hermes Online and the prior API deployment Online. The new API deployment remains in progress due to the platform incident, so its health and prompt changes are not yet verified live.
- Live Supabase RLS/grant inspection previously confirmed RLS enabled and table privileges limited to `service_role`; anon/authenticated have no table grants. This is fail-closed, though policy and authorization tests should remain part of every schema change.

## Deployment and service links

- Railway project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- Railway API: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase project ID: `smqsrigsugjuvuombetq`

## Current readiness

The core operating foundation is deployed: company state, founder-gated workflow, spending controls, Telegram status, and GitHub/Codex PR execution. The system is **operational for controlled internal planning and engineering work, but not fully release-ready**. The next concrete milestone is the Railway API rollout followed by the single remaining Architect artifact recovery. Full release readiness depends on restoring QA/Security review, confirming Supabase service continuity, and recording end-to-end workflow evidence.
