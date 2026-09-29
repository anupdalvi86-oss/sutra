# Sutra system status

Updated: 2026-09-29; live snapshot below is the PR #206 production state, with staged PR #210 verification added

## Staged initiative-budget change (review branch; not live)

Branch `feat/all-in-initiative-budget` adds a founder-set all-in EUR ceiling for each new initiative, an auditable shared project-cost ledger, a structured CFO estimate, and automatic activation after the estimate fits the ceiling and the PM review succeeds. Routine in-cap expenses pass the central authorization RPC without a second approval. Matching company, project, department, agent, category, vendor, per-transaction, daily and monthly hard limits remain enforced. Unverified costs stay held. A budget gap pauses the initiative and records the estimated shortfall; the Telegram founder command to change a cap is `Increase initiative budget <project-id> to €<amount> because <reason>.` Only the configured founder can call the audited budget-change RPC.

This change is isolated in a managed worktree and is not applied to production Supabase or deployed to Railway. Production continues to use the founder approval flow described below. Before deploying the API version from this branch, apply migration `20260929194504_initiative_budget_ledger.sql`. No money was spent and no customer or prospect was contacted during this work.

Validation of this branch on 2026-09-29: a fresh disposable Supabase database reset applied all migrations; 18 pgTAP files passed all 525 assertions; the Python suite passed 224 tests; Bandit passed at medium severity or higher; `compileall`, `git diff --check`, and a diff secret-pattern scan passed. Public-schema database lint reported 0 errors and 18 warnings in existing functions outside the new initiative authorization function. Production Supabase, Railway, Telegram and customer systems were not changed or exercised for this branch.

Hosted verification for [PR #209](https://github.com/anupdalvi86-oss/sutra/pull/209) also passed all five required jobs: change detection, Python/security, database migration/pgTAP/lint, container builds, and secret scan. GitHub emitted existing Node.js 20 action deprecation notices; they did not fail the run.

The branch implements only the budget/review foundation. Parallel cross-department delegation, autonomous GitHub merge and release, deployment authorization, CRM/customer support integrations, and live marketing/sales execution still need separate stages. Legal escalation currently pauses and records the issue; a clear founder Telegram decision flow and legal document review path remain future work. Required founder setup to activate customer work includes selecting the CRM/support provider, supplying credentials privately, and defining approved customer-contact terms and limits. No live outreach or legal commitment is authorized by this change.

## Staged parallel-agent change (review branch; not live)

Branch `feat/parallel-agent-reviews` lets CPO market research and CTO feasibility start at the same proposal stage after CEO scoping; CFO waits for both and PM remains stage 5. It also replaces the single global Hermes worker lease with two database-coordinated slots. The API defaults to one worker and accepts an explicit concurrency of two only when configured, because the OpenAI account's observed provider limit is one concurrent request. Spend reservations remain serialized against the EUR ledger lock, unknown reservations stay held, and existing policy/budget authorization applies unchanged. No approval, project budget, merge, release or customer-contact authority is added. The branch is not merged or deployed; production still uses the serial review and single worker.

Local verification for this branch before the worker-default follow-up: 220 Python tests passed; a fresh disposable Supabase reset applied the complete migration set; all 17 pgTAP files passed 348 assertions; Bandit, `compileall`, and `git diff --check` passed. Database lint found zero errors and only existing warnings outside the new functions. Supabase advisors reported three existing duplicate-index warnings on `agents`, `projects`, and `spending_policies`; this branch adds no indexes. Hosted CI runs `36631248892` and `36631703249` passed all five jobs before the worker-default follow-up. The follow-up adds two unit tests; Python passes 221 tests locally, compile checks and Bandit at medium severity pass, and `git diff --check` passes. Hosted CI run `36632390126` passed all five jobs on the latest code commit. Production was not changed.

Read-only Railway inspection on 2026-09-29 showed `sutra-api` and Hermes online with the persistent volume; an API build for PR #208 was in progress while PR #206 remained the last active API deployment. Hermes logs reported an OpenAI organization concurrency limit of one and warned that its API listener binds `0.0.0.0` while the terminal backend is local and unsandboxed. These observations are not configuration changes. Keep worker concurrency at one; resolve and review the Hermes warning before broadening runtime access.

## Gaps against the expanded operating model

- [PR #209](https://github.com/anupdalvi86-oss/sutra/pull/209) adds an initiative-level all-in budget and shared spend checks. It remains open and is not live. The company has no overall operating budget configured.
- [PR #210](https://github.com/anupdalvi86-oss/sutra/pull/210) stages CPO and CTO reviews together and allows two database lease slots; it remains open and is not live. Provider concurrency currently supports one worker, so the safe default is one.
- Current delegation is a fixed proposal/task workflow, not a general-purpose DAG that dynamically assigns arbitrary tasks to agents.
- The Codex workflow can open branches and PRs and collect CI evidence, but cannot merge or deploy releases. QA and Security remain deferred by founder direction.
- Marketing and Sales persist internal drafts. No CRM, customer support, email, advertising, or outbound messaging provider is connected. No live customer messages have been sent.
- There is no complete legal case/document review queue. Sutra can pause on flagged budget/legal blockers, but legal questions and proposed commitments still need a founder workflow.
- These implementation changes did not alter production, send customer messages, spend money, or start live business activity. Production activation is intentionally left for a reviewed deployment after the remaining release, customer, and legal controls are built and configured.

## Working

- **Supabase:** Production project `smqsrigsugjuvuombetq` is `ACTIVE_HEALTHY` on PostgreSQL 17.6. Production migrations are applied through `20260929191403_clarify_kimi_probe_iteration_audit`. Supabase remains the authoritative company state.
- **Financial governance:** Database policy controls the €10, €50, and €200 approval bands, budgets, reservations, and audit records. AI inference has a configurable-policy €8 monthly hard stop with an 80% warning. The Codex no-request retry limit is founder-adjustable, audited, and capped at three total attempts. Agents cannot raise their own authority.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is restricted to founder ID `8776723105`. The CEO board brief reports persisted projects, objectives, task queues, blockers, approvals, spending controls, and pipeline counts. Department commands provide role-scoped status. The brief was verified in the founder chat in two ordered messages.
- **GitHub/Codex:** Founder-approved Developer work can create a branch and PR. It cannot merge or release. The local synthetic draft workflow for task #107 is merged as [PR #160](https://github.com/anupdalvi86-oss/sutra/pull/160); task #107 is marked done. The draft API remains development-only and disabled in production.
- **Railway:** Production project `valiant-liberation` has the `sutra-api` and Hermes `sutra` services Online. Hermes uses the persistent `sutra-volume` at `/opt/data`. API deployment `05593c36-7135-483c-8a4b-52edf9204ea7` for [PR #206](https://github.com/anupdalvi86-oss/sutra/pull/206) is Active; its `/health` check succeeded.

## Live company snapshot

Latest read-only Supabase queries on 2026-09-29:

- **Projects:** 5 approved, 1 rejected. Three approved records are AI QA opportunity scopes; two are bounded Kimi probe records. The €500 ceilings authorize proposal scope only and do not authorize unrestricted purchases.
- **Approvals:** 5 approved, 1 rejected, none pending.
- **Tasks:** 28 total — 13 done, 8 backlog, 2 blocked, 4 deferred, and 1 cancelled. The two blocked tasks are Architect technical design and DevOps release/rollback planning. Four QA/Security reviews are deferred or incomplete under founder direction.
- **Agent runs:** 69 succeeded, 17 failed, and 12 blocked.
- **AI inference reservations:** €0.40 actual usage reconciled. Unknown reservations totaling €1.06 remain held: €0.70 Kimi and €0.36 OpenAI. No unknown reservation has been estimated or released.
- **Campaigns and customers/leads:** No records are present. No external sales or marketing messages have been sent.

## Latest deployment and probe outcome

PR #206 merged as `ca2243b84495dcbed189e1748ac8b7e9ebe1dd52`; all five CI jobs passed. Its production migration clarifies the audit record to state that one Sutra-to-Hermes run may use up to three model iterations. Railway deployment `05593c36-7135-483c-8a4b-52edf9204ea7` is Active and passed `/health`.

After that deployment, one new founder-authorized Kimi probe was queued from Telegram as `fcccfaf4-bf62-4b1e-ab3b-d7532fd747f5`. It failed with `unknown_or_overrun_spend`; safe diagnostics recorded only the integer types of `prompt_tokens`, `completion_tokens`, and `total_tokens`. No response body or token values were stored. Its €0.07 reservation is unknown and held. The earlier probe `4d75d5cf-2d1d-41ae-ba05-538a615caf71` also remains unknown and held at €0.07. These were separate one-shot runs, not retries. Kimi remains disabled for ordinary role work. [Issue #86](https://github.com/anupdalvi86-oss/sutra/issues/86) records both outcomes. No further probe was queued.

## Remaining work and blockers

1. **Blocked internal plans:** The Architect design and DevOps release/rollback tasks stopped because provider usage could not be verified. Their existing bounded attempts are exhausted and their unknown reservations remain held. They cannot be retried through the current flow.
2. **Open work:** Eight backlog tasks remain, including Developer follow-up and internal Marketing/Sales handoffs across the approved AI QA scopes. These produce internal artifacts only; no outreach has occurred.
3. **QA and Security:** The founder asked to defer these reviews. They remain incomplete, so Sutra is not release-ready. Restore and pass the required checks before a product release.
4. **Kimi metering:** Two independent probes failed closed. Reconcile provider usage from trustworthy evidence or fix the Hermes usage contract before enabling Kimi for normal roles or making another probe.
5. **Supabase continuity:** The project is healthy, but its organization is on the Free plan and the dashboard warned requests may stop after quota exhaustion. No paid plan change or purchase has been made.
6. **Credentials:** Credentials previously shared in chat should be rotated in their providers and replaced directly in private Railway variables. This file contains no credential values.

There are no pending approvals. No product release, purchase, agreement, or external campaign has been made. The founder workflow through PM planning and a Developer PR is operational; full release readiness still depends on deferred reviews, blocked plans, and reliable usage reconciliation.

## Verification

- PR #206 CI passed all five jobs: change detection, Python suite and Bandit, database migrations/pgTAP/lint, containers, and secret scan. The Python suite passed 217 tests on the PR head; compile checks and `git diff --check` passed locally.
- Production Supabase connectivity and migration history were verified with read-only queries; the project reports `ACTIVE_HEALTHY`.
- Railway dashboard shows the API deployment Active and the `/health` check succeeded. Hermes is Online with its persistent volume.
- Telegram founder chat verified the detailed CEO status report and the updated Kimi-probe acknowledgement, including the three-iteration bound. Both probe outcomes were verified against Supabase; each remains failed with an unknown held reservation.

## Service links

- Railway project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- Railway API: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase project ID: `smqsrigsugjuvuombetq`
