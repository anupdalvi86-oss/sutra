# Sutra system status

Updated: 2026-09-29, after PR #189 and production verification

## Operational state

- **Railway:** Production project `valiant-liberation` shows both private services, `sutra` (Hermes) and `sutra-api`, Online. Hermes state is stored on the persistent `/opt/data` volume.
- **Supabase:** Project `smqsrigsugjuvuombetq` is the authoritative company state. Production migrations are applied through `20260929131847 legacy_cpo_retry_recovery`; the project was previously verified `ACTIVE_HEALTHY`.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is configured for founder ID `8776723105`. Founder commands and detailed CEO/department status reports have been exercised in the logged-in Telegram session.
- **GitHub/Codex:** Sutra can dispatch approved Developer work and open branches/PRs. Sutra cannot merge or release. The public repository requires CI checks for Python, database/pgTAP/lint, containers, secret scanning, and change detection.
- **Financial governance:** Database-backed thresholds, founder-audited policy controls, reservations and hard stops are active. The AI inference monthly cap is €8, with an 80% warning. No company-wide operating budget is configured.

## Live company snapshot

- **Projects:** 4 records: 3 approved and 1 rejected. All three approved records request €500 and describe the same AI QA opportunity with duplicate variants; treat them as duplicate planning records, not three distinct validated products. No approval is pending (5 approved, 1 rejected).
- **Tasks:** 28 total: 13 done, 10 backlog, 2 blocked, 2 deferred, and 1 cancelled. Backlog and blocker counts include repeated work across the duplicate approved projects.
- **Current blockers:** “Produce architecture and technical design” and “Verify acceptance criteria” are blocked. QA and Security reviews are deferred by founder direction and remain incomplete.
- **Spend ledger:** €0.40 reconciled actual inference spend. Eleven unknown reservations totaling €0.83 remain held; they have not been released or assumed spent.
- **No external launch:** Marketing and Sales work is internal planning/draft work only. There has been no external outreach, publication, product release, or grant of merge/release authority.

## Latest completed recovery

PR [#189](https://github.com/anupdalvi86-oss/sutra/pull/189) merged as `9972b1d67bc13846afa7d2360eaf92d439952593`; all five CI jobs passed. It repaired project status synchronization after role-based budget rejection and added a narrowly scoped legacy CPO retry recovery.

In production, the stale CFO-rejected project is now marked rejected and its unstarted research task is cancelled. The founder-authorized retry for the same already-approved CPO task completed successfully and persisted a `market_research` artifact. Its output found established AI testing competitors and did not claim that a new product opportunity or market size had been validated. The retry is audit-logged, used the existing OpenAI GPT-6 Luna profile, preserved its unknown reservation, and granted no project-spend, merge, or release authority.

The applied migrations are `20260929131820 sync_rejected_project_budget_status` and `20260929131847 legacy_cpo_retry_recovery`.

## Verification

- PR #189 CI passed all five jobs: changes, secret scan, Python, database, and containers.
- Isolated local Supabase reproduction: all 468 pgTAP assertions across 16 files passed; database lint was clean.
- Local compile checks and `git diff --check` passed.
- Production verification confirmed the migrations are recorded, project/task states are consistent, the CPO run succeeded with its research artifact, approval queue has zero pending items, and audit events record the rejection, cancellation, retry, and completion.
- Railway currently displays both production services Online. Telegram founder status and task flows were exercised earlier; the successful CPO completion is visible in authoritative Supabase state.

## What remains

1. Resolve the two blocked architecture/acceptance-criteria tasks, then continue the approved product work through Developer/Codex PR creation and release planning.
2. Deduplicate the three approved €500 project records so tasks and budgets represent one authorized product effort. No €1,500 total spend has occurred; the displayed amounts are requested project ceilings.
3. Restore QA and Security reviews when the founder is ready. Until completed, Sutra's product is not security-reviewed or release-ready.
4. Verify the latest Railway deployment commit and exercise the full Founder → CEO → CPO → CTO → CFO → PM → founder-approval → Developer/Codex PR workflow after this recovery. Both Railway services are Online, but the UI status does not identify which source commit each currently runs.
5. Finish operational hardening and release evidence (including health/recovery checks and QA/Security evidence) before claiming production readiness.
6. Rotate credentials previously pasted into chat by replacing them directly in their providers and Railway variables. No credential values are recorded here.
7. Keep all 11 unknown reservations totaling €0.83 held until provider evidence permits exact reconciliation. The €8 monthly cap covers AI inference, not all operating costs.

## Completion estimate

The core deployed foundation and a live CPO research recovery are working. A reasonable estimate to finish the currently authorized non-QA/Security workflow, reconcile the duplicate project records, and verify the remaining handoffs is **about 2–4 focused engineering hours**, assuming services remain healthy and no new provider/runtime issue appears. Full release readiness adds QA, Security, and deployment hardening; the founder explicitly deferred QA/Security, so that part has no firm completion date.

## Links

- Railway project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- API service: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase project ID: `smqsrigsugjuvuombetq`
