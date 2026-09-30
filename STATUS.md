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
- **GitHub:** PRs [#209](https://github.com/anupdalvi86-oss/sutra/pull/209) and [#210](https://github.com/anupdalvi86-oss/sutra/pull/210) were already merged and were not recreated. PRs [#212](https://github.com/anupdalvi86-oss/sutra/pull/212) through [#220](https://github.com/anupdalvi86-oss/sutra/pull/220) are merged, covering same-head QA/Security release gates, all-in initiative budgeting, email delivery foundation and cost ceiling, legal holds, and operating-status improvements.
- **Telegram:** After PR #219 deployed and the migration was applied, the founder-only cost-ceiling command returned the expected unset-policy block. CEO/CFO board-status commands had returned complete reports after PR #215. No email was sent.

## Current operating picture

The latest live board report showed 6 active/approved/paused initiatives, 11 open tasks, 2 blocked tasks, 4 deferred QA/Security reviews, no pending approvals, and no open legal escalations. The blocked Architect and DevOps work is marked failed/blocked because provider usage could not be verified; its unknown reservations remain held and were not retried. The deferred quality reviews remain incomplete and have no passing evidence.

The same report showed no campaign records, no customer/lead records, and no queued email actions. It displayed €1.46 in combined requested/approved/paid expense records; that figure is not a claim that €1.46 has been paid. The ledger continues to distinguish actual, reserved and unknown amounts.

## Verification

- The Supabase app connector requested reauthentication for this work session; no live database changes were made by this release branch.
- Current code-only release-worker sprint: 118 focused Python tests and the full 268-test Python suite passed; `compileall`, `git diff --check`, and Bandit medium/high severity scan passed. Bandit reports only the existing B104 bind-all-interface warning for the Railway API server. This branch adds no database migration and made no production changes.
- Customer-email worker/provider tests: **11 passed**.
- Full Python suite before this code-only sprint: **265 passed** on the PR #220 release state; **268 passed** with this sprint's changes.
- `python3 -m compileall -q sutra tests`: passed.
- `git diff --check`: passed.
- Bandit 1.9.4 scan: no medium-or-higher findings (current local scan reports only the existing B104 Railway bind warning).
- PRs #219 and #220 each passed all five required CI checks — Python tests/compile/Bandit, Supabase migration and pgTAP tests/database lint, API and Hermes container builds/startup checks, change detection, and secret scan. Current sprint CI is pending.
- Production connectivity and smoke checks were previously successful: Supabase reported `ACTIVE_HEALTHY`; Railway was Online after PR #219; the Telegram email-ceiling command returned the expected unset-policy block. A fresh Supabase read now requires app reauthentication.
- No real customer messages were sent and no paid integrations were activated.

## Remaining gaps and blockers

1. **Customer email activation:** the Resend adapter and worker are implemented but intentionally disabled, and the role-agent workflow is not yet wired to enqueue messages. The database ceiling currently remains unset; the founder can set it with `CEO, set customer email cost ceiling to €0.05 because <reason>.` Live delivery also requires a Resend account, verified sender/domain, private `RESEND_API_KEY`, explicit live runtime flags, and an initiative budget assessed within its cap. Provider billing reconciliation is still required because sent and ambiguous actions retain unknown reservations until reconciled. No real message was sent during this implementation.
2. **CRM and customer support:** `customers` is an internal table, not a connected CRM or support desk. Choose the CRM and support system and provide scoped credentials/webhook access when ready to activate synchronization and inbound handling.
3. **Provider usage reconciliation:** two live Kimi probe runs and the blocked Architect/DevOps attempts have unknown usage reservations. Keep those reservations held; resolve the provider response/usage evidence before retrying. The €8 monthly inference hard stop and each initiative cap remain in force.
4. **Quality handoffs:** four QA/Security reviews are recorded as deferred and incomplete. Restore them only through the founder workflow and when a fresh reservation fits the active project and monthly policy; no release may treat a deferral as a pass.
5. **Operating company budget:** no company-wide operating budget is configured. The Sutra implementation initiative is capped at €0; paid work on a new initiative needs an explicit all-in ceiling and CFO assessment first.
6. **Release worker diagnostic:** Railway previously showed repeated generic `IntegrationError` cycles while the API remained healthy. This branch adds safe stage/error categories and bounded retry backoff; the Supabase app connector currently requires reauthentication to recheck live release-attempt state.

No additional founder decision is needed for the code changes merged in this sprint. To activate live customer communications and CRM/support synchronization later, the founder will need to choose providers, supply their scoped credentials and approve any all-in budget needed for paid tiers or usage. Legal cases, contracts and binding commitments remain founder escalations.

## Recommended next steps

Resolve provider usage reconciliation without releasing unknown reservations; add CRM and inbound support integrations after choosing providers and supplying scoped credentials. Keep outbound email disabled until the founder configures the ceiling and sender, provider billing reconciliation and initiative budget are in place. Then use a consented test contact to validate end-to-end delivery before normal outreach.
