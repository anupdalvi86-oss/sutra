# Sutra system status

Updated: 2026-09-30

## What works

- Supabase is the authoritative company state store. Database functions gate assignments, approvals, budget reservations and settlement, standing code authority, QA/Security evidence, merges, legal escalations, and audit records. Direct client roles cannot read the private operational tables.
- Telegram accepts founder commands only from ID `8776723105`. CEO and department status commands produce board-style, two-part reports with projects, objectives, task queues, completed work, blockers, pending approvals, legal escalations, budgets, held reservations, and relevant customer/campaign records. Data-source failures are reported as partial rather than hiding healthy sections.
- Railway runs private `sutra-api` and Hermes (`sutra`) services. The PR #219 deployment completed successfully; `sutra-api` is Online and Hermes remained Online. The API and Hermes services are not publicly exposed.
- The deployed workflow supports proposal intake, parallel CPO/CTO review, CFO estimate and PM plan, metered role artifacts, GitHub issue/branch/PR execution, CI evidence polling, QA and Security handoffs, and a separate exact-head release worker. The worker can merge only when the standing founder repository grant, project/task scope, CI, QA and Security evidence all pass.
- Spending controls use configurable Supabase policies and a shared all-in EUR initiative ledger. Reservations, actuals and unresolved usage are preserved. The live policy includes an €8 monthly AI-inference hard stop; the Sutra implementation initiative has a €0 all-in cap, so this work has incurred no paid implementation spend.
- The private customer-email outbox enforces consent, unsubscribe, task assignment, assessed initiative budget, project legal holds and legal escalations. The opt-in Resend worker uses atomic leases and a pre-send authorization recheck; ambiguous outcomes are terminal and retain unknown reservations. A founder-only audited database setting now defines the maximum reserved cost per message. It is intentionally unset, so enqueue and delivery fail closed. The worker remains disabled and no customer messages have been sent.
- Founder code authority is an audited database grant for this repository, with bounded task/branch/PR/merge/QA/Security/deploy capabilities. It does not increase budgets or spending authority. Exhausted task #107 was not retried.

## Production and PR state

- **Supabase:** Project `smqsrigsugjuvuombetq` is `ACTIVE_HEALTHY` in `eu-central-1` on PostgreSQL 17.6. Migration `20260930004959_customer_email_cost_ceiling` is applied; the ceiling remains unset and email queueing/delivery fail closed. The app connector requested reauthentication for a new live read in this session.
- **Railway:** The PR #219 runtime deployment was verified successful with `sutra-api` Online and Hermes `sutra` Online. PR #220 aligned the migration filename and refreshed status documentation; it did not trigger a runtime deployment. This release has not yet been deployed.
- **GitHub:** PRs [#209](https://github.com/anupdalvi86-oss/sutra/pull/209) and [#210](https://github.com/anupdalvi86-oss/sutra/pull/210) were already merged and were not recreated. PRs [#212](https://github.com/anupdalvi86-oss/sutra/pull/212) through [#220](https://github.com/anupdalvi86-oss/sutra/pull/220) are merged, covering same-head QA/Security release gates, all-in initiative budgeting, email delivery foundation and cost ceiling, legal holds, and operating-status improvements. Consolidated sprint PR #221 remains open and unmerged; it includes release-worker diagnostics, privacy-minimized Zendesk support-state intake, and the opt-in HubSpot contact-sync queue/worker with budget, assigned-task, consent and legal gates. No production migration, provider call or customer message has been made from this branch.
- **Telegram:** After PR #219 deployed and the migration was applied, the founder-only cost-ceiling command returned the expected unset-policy block. CEO/CFO board-status commands had returned complete reports after PR #215. No email was sent.

## Current operating picture

The latest live board report showed 6 active/approved/paused initiatives, 11 open tasks, 2 blocked tasks, 4 deferred QA/Security reviews, no pending approvals, and no open legal escalations. The blocked Architect and DevOps work is marked failed/blocked because provider usage could not be verified; its unknown reservations remain held and were not retried. The deferred quality reviews remain incomplete and have no passing evidence.

The same report showed no campaign records, no customer/lead records, and no queued email actions. It displayed €1.46 in combined requested/approved/paid expense records; that figure is not a claim that €1.46 has been paid. The ledger continues to distinguish actual, reserved and unknown amounts.

## Verification

- The Supabase app connector requested reauthentication for this work session; no live database changes were made by this release branch.
- Sprint PR #221 is open and unmerged. Final code head `a7866ec` passed all five required checks in CI run [#36658734710](https://github.com/anupdalvi86-oss/sutra/actions/runs/36658734710): secret scan, change detection, Python/security, migrations/pgTAP/database lint, and containers. This run includes the HubSpot queue migration and all policy tests. If merge triggers Railway deployment, check health and smoke test once; inspect logs only if deployment or smoke fails.
- Customer-email worker/provider tests: **11 passed**.
- Full Python suite after current CRM queue/worker additions: **283 passed**. Focused CRM/server/runtime suite: **150 passed**. `compileall`, `git diff --check`, and Bandit medium/high scan pass; Bandit reports only the existing B104 bind-address warning. Hosted pgTAP passed all 36 new HubSpot policy assertions, and database lint passed.
- `python3 -m compileall -q sutra tests`: passed.
- `git diff --check`: passed.
- Bandit 1.9.4 scan: no medium-or-higher findings (current local scan reports only the existing B104 Railway bind warning).
- PRs #219 and #220 each passed all five required CI checks — Python tests/compile/Bandit, Supabase migration and pgTAP tests/database lint, API and Hermes container builds/startup checks, change detection, and secret scan. PR #221's final-head checks are recorded above.
- Production connectivity and smoke checks were previously successful: Supabase reported `ACTIVE_HEALTHY`; Railway was Online after PR #219; the Telegram email-ceiling command returned the expected unset-policy block. A fresh Supabase read now requires app reauthentication.
- No real customer messages were sent and no paid integrations were activated.

## Remaining gaps and blockers

1. **Customer email activation:** the Resend adapter and worker are implemented but intentionally disabled, and the role-agent workflow is not yet wired to enqueue messages. The database ceiling currently remains unset; the founder can set it with `CEO, set customer email cost ceiling to €0.05 because <reason>.` Live delivery also requires a Resend account, verified sender/domain, private `RESEND_API_KEY`, explicit live runtime flags, and an initiative budget assessed within its cap. Provider billing reconciliation is still required because sent and ambiguous actions retain unknown reservations until reconciled. No real message was sent during this implementation.
2. **CRM and customer support:** the sprint branch adds an opt-in Zendesk webhook that records only ticket ID/status/priority/time, with signature/replay checks and idempotent audit logging. It does not retain customer messages or route work to agents. The HubSpot outbox/worker reserves through the all-in initiative ledger, enforces an assigned Sales task and founder-recorded consent, rechecks legal/budget state before its allowlisted contact upsert, and preserves ambiguous reservations without retry. Both features remain disabled and undeployed until PR #221 is merged; HubSpot additionally needs its migration, narrowly scoped private token, consent evidence and a nonzero assessed initiative budget that accounts for CRM plan costs. Support ticket triage/replies still need privacy/retention rules, task routing, legal escalation and an outbound support adapter. No provider calls were made.
3. **Provider usage reconciliation:** two live Kimi probe runs and the blocked Architect/DevOps attempts have unknown usage reservations. Keep those reservations held; resolve the provider response/usage evidence before retrying. The €8 monthly inference hard stop and each initiative cap remain in force.
4. **Quality handoffs:** four QA/Security reviews are recorded as deferred and incomplete. Restore them only through the founder workflow and when a fresh reservation fits the active project and monthly policy; no release may treat a deferral as a pass.
5. **Operating company budget:** no company-wide operating budget is configured. The Sutra implementation initiative is capped at €0; paid work on a new initiative needs an explicit all-in ceiling and CFO assessment first.
6. **Release worker diagnostic:** Railway previously showed repeated generic `IntegrationError` cycles while the API remained healthy. This branch adds safe stage/error categories and bounded retry backoff; the Supabase app connector currently requires reauthentication to recheck live release-attempt state.

No routine action approval is needed for code changes under the standing repository authorization. The Sutra implementation initiative still has a €0 all-in cap. Do not merge changes that trigger a potentially billable production deployment, or activate paid provider work, until the founder assigns an adequate all-in budget. Legal cases, contracts and binding commitments remain founder escalations.

## Recommended next steps

Finish PR #221 verification on the final code head. Before merge/deployment, provide an all-in budget for this implementation initiative if Railway deployment or other work could incur spend. Once funded, apply the CRM migration, keep CRM and email disabled until scoped credentials and approved budgets are configured, validate with a consented test contact, and implement support triage/replies. Reconcile existing unknown provider usage without releasing reservations.
