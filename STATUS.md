# Sutra Status

Updated: 2026-09-27 22:54 Europe/Stockholm

## Overall

The production foundation is live: Supabase is authoritative, Telegram is founder-restricted, Railway hosts the private API and Hermes runtime, database spending rules are enforced, and the leased worker is enabled. The Telegram status, proposal and approval-list flows work. The latest proposal completed CEO, CPO, CTO and CFO reviews with reconciled OpenAI usage. PM did not produce a valid saved artifact: its first output failed validation and the second call's usage could not be verified, so it was failed closed. Telegram marks the €500 founder request ready for decision after CFO review. That request is still pending and authorizes no spend. Sutra is **operational for governed proposals and executive review, but not end-to-end operational for product delivery**.

## Working and verified

- **GitHub:** PR #54 (`b59441b`) and docs PR #55 (`40da1c8`) are merged to `main`. Both had green Python, database, container and secret-scan checks. Current main CI passed after PR #55.
- **Supabase:** Project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is `ACTIVE_HEALTHY` on PostgreSQL 17.6.1. All 18 repository migrations are applied. The live public schema has 22 tables, all with RLS enabled. Direct `anon` and `authenticated` grants are withheld; sensitive ledger access is controlled by database functions.
- **Database governance:** Defaults are <= €10 automatic, > €10 to €50 department head, > €50 to < €200 CFO + CEO, and >= €200 founder. The monthly `ai_inference` budget is €8 with an 80% warning and hard stop. Three AI QA opportunity proposals have €500 ceilings; none has founder approval for spend. A project ceiling is not spending authorization.
- **Latest live proposal:** Project `93b43006-58f9-4096-9e72-df9aeaf350ff`; approval `539a8225-1230-4896-87d2-b48e7c28ae82`. CEO, CPO, CTO and CFO completed successfully on GPT-6 Luna. PM attempt one had valid usage reconciled (€0.01 actual) but its artifact failed validation. PM attempt two's response/usage could not be verified; the run failed closed and its €0.03 reserve remains `unknown`. The founder approval is pending, CFO has approved review only, and Telegram lists it as ready for the founder's decision. No project spend is approved. Do not approve unless you intend to authorize this project budget.
- **Kimi:** `KIMI_API_KEY` is present on the private Railway Hermes service, and the database has an active Kimi K2.6 pricing profile. Production role routes are `{}`; all roles use the OpenAI GPT-6 Luna default. A previous Kimi CPO request failed closed with unknown usage and a €0.28 reserve still held. Kimi must remain off live routes until its usage response can be reconciled.
- **Railway:** Private services `sutra` (Hermes) and `sutra-api` are Online; Hermes has a persistent volume mounted at `/opt/data`. On the latest API deployment, Railway logs recorded `GET /health` with HTTP 200. A previous `/ready` response was ready; `/ready` was not rechecked after the most recent documentation deployment. Neither service is publicly exposed. The latest successful API deployment is associated with main commit `40da1c8`.
- **Telegram:** `@sutra86bot` is running and accepts private messages only from the configured founder. In the logged-in Chrome session, proposal intake and the founder approval queue were exercised. The latest queue response showed the current €500 request ready for founder decision and an older Kimi-blocked request waiting for CFO.
- **Audit and spend:** The latest workflow's proposal, run claims, budget reservations, model-call starts, reconciled usage, CFO approval and PM failure are recorded in the Supabase audit log. No approval was performed. Unknown usage keeps its full reserve and blocks successful run handoff.
- **Worker safety:** Provider routes are locked to the requested database-approved profile. Each call must pass preflight, reservation and begin checks, then settle observed usage before artifacts are persisted. Task artifacts additionally require an approved project, active task lease and exact acceptance criteria. External marketing/sales messages and deployment remain disabled.

## Tests and security checks

- Python suite: last completed **77 passed**; rerun after this documentation update before merging.
- Bandit: last run reported no medium/high issues; rerun before merging.
- `compileall` and `git diff --check`: passed before this documentation update; rerun before merging.
- GitHub CI on PRs #54 and #55: Python, database migration/pgTAP/lint, container and secret-scan checks passed.
- Live checks: Supabase status, migrations, RLS, budget limits, model reservations and audit events queried; latest Railway deployment showed API `/health` HTTP 200; Telegram proposal intake and approval queue responded.
- Docker on the local host was previously constrained by disk space; hosted container CI is green. No production data cleanup was performed.

## Deployment and integration state

| Component | Current status | Remaining gap |
| --- | --- | --- |
| GitHub `main` | PRs #54 and #55 merged; CI green | Codex execution runner, issue dispatcher and signed webhook are not enabled |
| Supabase | Healthy, 18 migrations, RLS enabled | Review recovery plan; department-head and general operating budgets are unset |
| Railway API | Online and private; latest `/health` returned 200 | Recheck `/ready` after deployment |
| Railway Hermes | Online, private API, persistent `/opt/data` volume | Kimi key is stored but Kimi is not routed because usage accounting is unverified |
| Telegram | Founder-only status, proposal and approvals list respond | Latest proposal has no persisted PM artifact |
| Agent reviews | CEO → CPO → CTO → CFO succeeded and usage reconciled | PM artifact failure blocks the intended PM handoff |
| Founder approval | Latest €500 request is pending and ready for decision after CFO review | Approval authorizes a project budget; do not approve unless intended; it does not mean spend has occurred |
| Coding / QA / Security / release | Guarded database stages and CI evidence checks exist | No production Codex runner, PR producer, public signed webhook receiver, or release path |
| Marketing / Sales | Internal draft artifact contracts exist | Workflow handoff not exercised; no external outreach enabled |

## Remaining blockers

1. **PM artifact and unknown usage:** The newest PM attempt failed closed after its usage could not be verified. The run is terminal after its bounded retry; there is no safe Telegram retry command. Diagnose the live Hermes/OpenAI response path and add safe diagnostic detail without recording prompts, secrets or untrusted content. Do not manually reset the run or release unknown reserves.
2. **Kimi metering:** The Kimi key and K2.6 profile are configured, but a Kimi call left a €0.28 unknown reserve. Keep the Kimi role route disabled until usage can be proven and reconciled.
3. **Founder decision:** Telegram shows a pending €500 project-budget approval ready for the founder. This is not approved. No spending occurred against the proposal. Founder approval is a human decision; no agent should take it.
4. **Engineering delivery:** No production Codex runner consumes approved tasks and opens PRs. GitHub issue dispatch and signed webhook are disabled/unconfigured, and the API has no public ingress for GitHub webhook delivery.
5. **Operating authority:** No department-head approver or general company/department budgets are configured. The €10–50 tier correctly remains fail-closed without a real department head.
6. **Release operations:** Railway wait-for-CI and branch protection are not enabled. Confirm recoverable Supabase backup coverage. Avoid untrusted Hermes shell execution; the Sutra API toolset remains restricted.
7. **Credential hygiene:** User-supplied Telegram, OpenAI and Kimi credentials are held only as private Railway variables and were not added to Git. Rotate/revoke them after verification; do not send replacements in chat or the repository.

## Recommended next steps

1. Reproduce and diagnose why the PM retry returned no verifiable usage; instrument only safe error categories and response metadata, then rerun automated tests and deploy.
2. Keep the Kimi route disabled until its billing usage can reconcile against the database profile. The Kimi secret is installed; no additional key change is needed to resume this investigation.
3. The founder can inspect `CEO, show my approvals.` in the Telegram bot and decide whether the €500 project-budget request is intended. No decision has been made by Sutra.
4. Build a least-privilege Codex runner and signed webhook ingress with model reservation/reconciliation before turning on issue dispatch. Keep QA/Security gated on a merged Developer commit and same-SHA CI.
5. Configure a real department owner, ordinary budgets, Railway CI gating and Supabase recovery coverage.
6. Rotate shared credentials after the base workflow is verified, directly in Railway.
