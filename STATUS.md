# Sutra system status

Updated: 2026-09-30

## What works

- Supabase is the authoritative company state store. Database functions gate assignments, approvals, budget reservations and settlement, standing code authority, QA/Security evidence, merges, legal escalations, and audit records. Direct client roles cannot read the private operational tables.
- Telegram accepts founder commands only from ID `8776723105`. CEO and department status commands produce board-style, two-part reports with projects, objectives, task queues, completed work, blockers, pending approvals, legal escalations, budgets, held reservations, and relevant customer/campaign records. Data-source failures are reported as partial rather than hiding healthy sections.
- Railway runs private `sutra-api` and Hermes (`sutra`) services. After PR #215, Railway marked the deployment successful and `sutra-api` Online; Hermes was also Online in the project view. The API and Hermes services are not publicly exposed.
- The deployed workflow supports proposal intake, parallel CPO/CTO review, CFO estimate and PM plan, metered role artifacts, GitHub issue/branch/PR execution, CI evidence polling, QA and Security handoffs, and a separate exact-head release worker. The worker can merge only when the standing founder repository grant, project/task scope, CI, QA and Security evidence all pass.
- Spending controls use configurable Supabase policies and a shared all-in EUR initiative ledger. Reservations, actuals and unresolved usage are preserved. The live policy includes an €8 monthly AI-inference hard stop; the Sutra implementation initiative has a €0 all-in cap, so this work has incurred no paid implementation spend.
- The private customer-email outbox enforces consent, unsubscribe, task assignment, initiative budget, project legal holds and legal escalations. It is a queue only: no provider delivery worker is configured and it has not sent customer messages.
- Founder code authority is an audited database grant for this repository, with bounded task/branch/PR/merge/QA/Security/deploy capabilities. It does not increase budgets or spending authority. Exhausted task #107 was not retried.

## Production and PR state

- **Supabase:** Project `smqsrigsugjuvuombetq` is `ACTIVE_HEALTHY` in `eu-central-1` on PostgreSQL 17.6. The company schema, all-in budget ledger, code release gate, legal escalation inbox, and customer email queue are deployed. The code-release status RPC returns arrays; PR #215 corrected the client to read that response type directly.
- **Railway:** PR #215 is the latest verified API deployment. Railway marked it successful and `sutra-api` Online. The `sutra` Hermes service was Online in the same project view. No API public URL is configured.
- **GitHub:** PRs [#209](https://github.com/anupdalvi86-oss/sutra/pull/209) and [#210](https://github.com/anupdalvi86-oss/sutra/pull/210) were already merged and were not recreated. PRs [#212](https://github.com/anupdalvi86-oss/sutra/pull/212) (same-head QA/Security release gate), [#213](https://github.com/anupdalvi86-oss/sutra/pull/213) (budgeted customer email queue and legal holds), [#214](https://github.com/anupdalvi86-oss/sutra/pull/214) (partial company-status reporting), and [#215](https://github.com/anupdalvi86-oss/sutra/pull/215) (array-valued code-release status) are merged.
- **Telegram:** After PR #215 deployed, `CEO, give me company status.` and `CFO, give me department status.` both returned the complete operating brief. Neither included a data-completeness warning.

## Current operating picture

The latest live board report showed 6 active/approved/paused initiatives, 11 open tasks, 2 blocked tasks, 4 deferred QA/Security reviews, no pending approvals, and no open legal escalations. The blocked Architect and DevOps work is marked failed/blocked because provider usage could not be verified; its unknown reservations remain held and were not retried. The deferred quality reviews remain incomplete and have no passing evidence.

The same report showed no campaign records, no customer/lead records, and no queued email actions. It displayed €1.46 in combined requested/approved/paid expense records; that figure is not a claim that €1.46 has been paid. The ledger continues to distinguish actual, reserved and unknown amounts.

## Verification

- Focused runtime tests: **103 passed**.
- Full Python suite on the integrated PR #215 branch: **252 passed**.
- `python3 -m compileall -q sutra tests`: passed.
- `git diff --check`: passed.
- PR #215 CI: all five required checks passed — Python tests/compile/Bandit, Supabase migration and policy tests/database lint, API and Hermes container builds/startup checks, change detection, and secret scan.
- Production Supabase connectivity: project reports `ACTIVE_HEALTHY`; live schema and status RPC were queried successfully.
- Production smoke checks: Railway deployment successful and API Online; founder CEO and CFO status commands returned complete reports.
- No real customer messages were sent and no paid integrations were activated.

## Remaining gaps and blockers

1. **Customer email delivery:** the outbox has no provider adapter or dispatch worker. A provider account, verified sending domain, scoped API credential and provider webhook/signature secret will be needed before live sends. Add an initiative-specific all-in budget before any paid provider usage.
2. **CRM and customer support:** `customers` is an internal table, not a connected CRM or support desk. Choose the CRM and support system and provide scoped credentials/webhook access when ready to activate synchronization and inbound handling.
3. **Provider usage reconciliation:** two live Kimi probe runs and the blocked Architect/DevOps attempts have unknown usage reservations. Keep those reservations held; resolve the provider response/usage evidence before retrying. The €8 monthly inference hard stop and each initiative cap remain in force.
4. **Quality handoffs:** four QA/Security reviews are recorded as deferred and incomplete. Restore them only through the founder workflow and when a fresh reservation fits the active project and monthly policy; no release may treat a deferral as a pass.
5. **Operating company budget:** no company-wide operating budget is configured. The Sutra implementation initiative is capped at €0; paid work on a new initiative needs an explicit all-in ceiling and CFO assessment first.

No additional founder decision is needed for the code changes merged in this sprint. To activate live customer communications and CRM/support synchronization later, the founder will need to choose providers, supply their scoped credentials and approve any all-in budget needed for paid tiers or usage. Legal cases, contracts and binding commitments remain founder escalations.

## Recommended next steps

Resolve provider usage reconciliation without releasing unknown reservations; continue no-spend code and documentation work under the €0 Sutra cap; then implement CRM/support and email adapters behind explicit configuration and budget gates. Keep live customer outreach disabled until the provider dispatch, consent, unsubscribe, legal, cost-settlement and recovery checks are verified.
