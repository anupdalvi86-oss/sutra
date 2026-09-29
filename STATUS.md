# Sutra system status

Updated: 2026-09-30

## What works

- Supabase is the authoritative company state store. Database policy gates role work, task assignment, approvals, spending, code authority, release gates, audit events, and unresolved reservations.
- Telegram is restricted to founder `8776723105`. Board-style status reports projects, objectives, open tasks, blockers, pending approvals, spending and model reservations, customer/campaign pipeline, code dispatches and release state.
- Railway runs the private Sutra API and Hermes services. Before this sprint, `/health` and the founder Telegram status flow were verified against the live deployment. The merge of PR #213 will be the next code deployment; the new email endpoint is not live until then.
- GitHub Developer execution, exact-SHA CI evidence, QA/Security handoffs and the separate policy-gated merge worker are implemented. PR #209 and #210 are already merged and were not recreated. PR #212 added the same-SHA pre-merge QA/Security release gate and was merged/deployed; no live business release was triggered by its verification.
- Initiative spend uses a shared all-in EUR ledger, including actual, reserved and unknown costs. The Sutra implementation initiative has a €0 paid-work cap. Existing unknown reservations are unchanged; exhausted task #107 was not retried.
- The current sprint adds a private, consent-gated customer email outbox. Queueing requires an active initiative, the exact assigned Sales/Marketing task, valid and opted-in non-unsubscribed customer email, no legal hold or open legal escalation, and a new reservation through the existing central spend policy. Audit records omit message content. Board status reports action IDs/status only.
- Founder commands `CEO, set legal hold <project-id> because <reason>.` and `CEO, clear legal hold <project-id> because <reason>.` update an audited project-level hold. Clearing it does not resume a paused project or close a legal case.

## Production and PR state

- **Supabase:** Production project `smqsrigsugjuvuombetq` is reachable. The additive customer-email outbox migration and its foreign-key index migration are applied. A live privilege check confirmed RLS enabled, anon cannot read or enqueue, and only `service_role` can call the enqueue RPC. New agent/customer/task foreign-key indexes are present.
- **Railway:** Sutra API and Hermes were Online at the last pre-sprint health check. The current code release is PR #212; no post-merge check has been made for PR #213 yet. The API remains private; no public service URL is configured for this internal runtime.
- **GitHub:** Consolidated sprint PR [#213](https://github.com/anupdalvi86-oss/sutra/pull/213) contains the customer email control plane and documentation in three organized commits. All required checks passed on head `536f127`: Python, database migrations/pgTAP, container builds, change detection and secret scan. It is ready to merge; the planned post-merge Railway health/smoke check is pending.
- **Telegram:** Founder identity remains `8776723105`; live founder status was verified before this sprint. PR #213's legal-hold command and outbox status require the merge deployment before they are available in production.

## Verification in this sprint

- Focused Python server/runtime tests: **133 passed**.
- Full Python suite: **250 passed**.
- Python compile check: passed.
- Bandit (`-ll`): passed; it reports the existing B104 test-server bind-address warning.
- `git diff --check`: passed.
- GitHub CI: all PR #213 checks passed, including container builds, Supabase migrations and SQL policy tests, and Gitleaks secret scan.
- Production Supabase connectivity, RLS and function-grant checks: passed. Security advisor findings about service-only tables with no RLS policies are intentional deny-by-default access; the new outbox has no anon/authenticated policy. Performance advisor no longer reports missing indexes for the new foreign keys.
- No customer messages were sent. The outbox has no delivery worker or provider integration and remains queued-only.

## Remaining gaps and blockers

1. Merge PR #213. If that merge triggers Railway deployment, check service health once and run a founder-interface smoke check. Investigate logs only if health or smoke fails.
2. Connect the Hermes Sales/Marketing workflow to the new enqueue path. At present those roles still produce internal artifacts; the private endpoint is not called by agents.
3. Implement and verify an email delivery worker with provider-side message IDs, safe retries, reconciliation/unknown handling and reliable per-message cost estimates. No provider is configured, so there is no live email delivery.
4. Add CRM synchronization and inbound customer-support ingestion/response handling. The existing `customers` table is an internal pipeline, not a connected CRM or support desk.
5. To activate paid messaging or other paid external operations, the founder must set an explicit all-in initiative budget that covers delivery/provider costs. Current Sutra implementation budget is €0; no paid work or provider account was activated.
6. Email/CRM/support provider selection and credentials are not present. Do not send real messages until the delivery path, consent evidence, unsubscribes, legal escalation and spending reconciliation are implemented and verified.

## Next steps

Merge PR #213 after its green checks, then perform the single requested Railway health and Telegram smoke check if Railway deploys. Continue the next sprint with agent-to-outbox orchestration, costed email delivery, and CRM/support adapters. Keep implementation work within the €0 cap; before paid provider use, request an all-in initiative ceiling. Route legal questions, contracts and binding terms to the founder.
