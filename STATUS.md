# Sutra Status

Updated: 2026-09-28 00:08 Europe/Stockholm

## Overall

The production foundation is live: Supabase is authoritative, Telegram is founder-restricted, Railway hosts the private API and Hermes runtime, database spending rules are enforced, and the leased worker is enabled. PR #62's JSON-mode request and PM object-shape fix is deployed for future reviews; PR #63 makes Telegram recover from transient startup probe failures. After the PR #63 rollout, a live Telegram status command received a response and `/ready` from the Hermes service returned `ready: true` with database, Telegram and agent worker running. The latest product proposal completed CEO, CPO, CTO and CFO reviews with reconciled OpenAI usage. Its PM run exhausted three attempts without a valid saved artifact: attempt one reconciled at €0.01, attempt two has unknown usage and retains its €0.03 reserve, and the founder-triggered third attempt reconciled at €0.01 but failed artifact validation. Do not replay or duplicate the proposal automatically. Telegram shows a €500 founder request ready for decision; it is still pending and authorizes no project spend. Sutra is **operational for governed proposals and executive review, but not end-to-end operational for product delivery**.

## Working and verified

- **GitHub:** PRs #54–#63 are merged to `main`; PR #63 CI passed Python, database, container and secret-scan checks. Main is `fe46bba`.
- **Supabase:** Project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is `ACTIVE_HEALTHY` on PostgreSQL 17.6.1. All 19 migrations, including the founder PM retry RPC, are applied. The live public schema has 22 tables, all with RLS enabled. Direct `anon` and `authenticated` grants are withheld; sensitive ledger access is controlled by database functions.
- **Database governance:** Defaults are <= €10 automatic, > €10 to €50 department head, > €50 to < €200 CFO + CEO, and >= €200 founder. The monthly `ai_inference` budget is €8 with an 80% warning and hard stop. Three AI QA opportunity proposals have €500 ceilings; none has founder approval for spend. A project ceiling is not spending authorization.
- **Latest live proposal:** Project `93b43006-58f9-4096-9e72-df9aeaf350ff`; approval `539a8225-1230-4896-87d2-b48e7c28ae82`. CEO, CPO, CTO and CFO completed successfully on GPT-6 Luna. The PM run `242165f1-c8ba-4895-9ee6-580f7cebdc45` used three attempts: attempt one reconciled (€0.01), attempt two's usage is unknown and its €0.03 reserve remains held, and attempt three reconciled (€0.01) but failed with `invalid_artifact_schema`. The founder-only Telegram retry path was deployed and exercised; it preserved the previous unknown reserve, and the audit event was written. The founder approval is pending and ready for the founder's decision. No project spend is approved. Do not approve unless you intend to authorize this project budget.
- **Kimi:** `KIMI_API_KEY` is present on the private Railway Hermes service, and the database has an active Kimi K2.6 pricing profile. Production role routes are `{}`; all roles use the OpenAI GPT-6 Luna default. A previous Kimi CPO request failed closed with unknown usage and a €0.28 reserve still held. Kimi must remain off live routes until its usage response can be reconciled.
- **Railway:** Private services `sutra` (Hermes) and `sutra-api` are Online; Hermes has a persistent volume mounted at `/opt/data`. API deployment `05229d6b-3afb-46f2-99ec-f49dccb8e61b` for PR #63 is active and successful. From the Hermes Railway console, a private request to the API `/ready` returned `ready: true`; database, Telegram and agent worker were running. GitHub dispatcher is disabled and webhook is unconfigured. Neither service is publicly exposed.
- **Telegram:** `@sutra86bot` is running and accepts private messages only from the configured founder. Proposal intake, approval queue, founder-only retry and a live post-deploy status command were exercised in the logged-in Chrome session. The latest status reply reported 3 projects, 3 open tasks and 2 pending approvals. The retry queued only the failed PM review and left the €500 project approval untouched.
- **Audit and spend:** The latest workflow's proposal, run claims, budget reservations, model-call starts, reconciled usage, CFO approval, PM failure and founder retry are recorded in the Supabase audit log. No project approval was performed. Attempt two's unknown usage keeps its full reserve; the retry did not overwrite it. Diagnostics record only a code-owned failure category/detail code and usage state; they do not persist the provider response or exception text.
- **Worker safety:** Provider routes are locked to the requested database-approved profile. Each call must pass preflight, reservation and begin checks, then settle observed usage before artifacts are persisted. Task artifacts additionally require an approved project, active task lease and exact acceptance criteria. External marketing/sales messages and deployment remain disabled. Hermes logs a generic warning because its base runtime has a local unsandboxed terminal backend; the Sutra API server is configured to only the `web` toolset, so shell/process toolsets are not exposed to this endpoint. CI now asserts the resolved Hermes tool catalog, not only its YAML config.

**Supabase advisors:** Security advisor reports 22 INFO findings that RLS is enabled without row policies. Direct `anon`/`authenticated` table SELECT grants are zero (verified across all 22 public tables); application access is via audited service-side RPCs. These tables are deny-by-default; review if direct user access is introduced. Performance advisor reports 25 INFO unused indexes on this newly bootstrapped database; no indexes were removed.

## Tests and security checks

- Python suite on `main`: **86 passed** (`python3 -m unittest discover -s tests -v`).
- Bandit: **no medium/high issues** (`python3 -m bandit -r sutra -ll`). The expected Railway bind warning remains.
- `compileall` and `git diff --check`: passed after the latest source/documentation edits.
- GitHub CI through PR #63: Python, database migration/pgTAP/lint, container and secret-scan checks passed.
- Live checks: Supabase `ACTIVE_HEALTHY`, all 19 migrations applied, 22 public tables, zero direct table SELECT grants to `anon`/`authenticated`, live threshold policies and €8 monthly AI hard stop queried; run reservations and audit events queried. Railway PR #63 API deployment is active; `/ready` returned `ready: true` with database, Telegram and agent worker running. Telegram status, proposal intake, founder approval queue and founder PM retry responded. Attempt three failed artifact validation but reconciled spend.
- Docker on the local host was previously constrained by disk space; hosted container CI is green. No production data cleanup was performed.

## Deployment and integration state

| Component | Current status | Remaining gap |
| --- | --- | --- |
| GitHub `main` | PRs #54–#63 merged; CI green | Codex execution runner, issue dispatcher and signed webhook are not enabled |
| Supabase | Healthy, 19 migrations, RLS enabled | Review recovery plan; department-head and general operating budgets are unset |
| Railway API | Online and private; PR #63 active; `/ready` returned ready after the Telegram retry fix | None for basic service readiness |
| Railway Hermes | Online, private API, persistent `/opt/data` volume | Kimi key is stored but Kimi is not routed because usage accounting is unverified |
| Telegram | Founder-only status, proposal and approvals list respond | Latest proposal has no persisted PM artifact |
| Agent reviews | CEO → CPO → CTO → CFO succeeded and usage reconciled; JSON-mode PM fix is deployed | The historic PM artifact failed all three attempts; verify a future review on an existing founder-authorized workflow |
| Founder approval | Latest €500 request is pending and ready for decision after CFO review | Approval authorizes a project budget; do not approve unless intended; it does not mean spend has occurred |
| Coding / QA / Security / release | Guarded database stages and CI evidence checks exist | No production Codex runner, PR producer, public signed webhook receiver, or release path |
| Marketing / Sales | Internal draft artifact contracts exist | Workflow handoff not exercised; no external outreach enabled |

## Remaining blockers

1. **PM artifact and unknown usage:** The newest PM run is terminal after its third attempt returned a non-object artifact. One €0.03 attempt remains unknown and held; attempts one and three reconciled €0.01 each. PR #61 added a founder-authorized, audited retry; it was exercised through Telegram and preserved the unknown reservation. Do not reset it or release the reserve. PR #62's JSON mode/object contract is deployed, but that terminal run cannot be retried again under its attempt cap. The historical provider response was intentionally not retained. Do not create another proposal until the founder decides which existing €500 request to keep.
2. **Kimi metering:** The Kimi key and K2.6 profile are configured, but a Kimi call left a €0.28 unknown reserve. Keep the Kimi role route disabled until usage can be proven and reconciled.
3. **Founder decision:** Telegram shows a pending €500 project-budget approval ready for the founder. This is not approved. No spending occurred against the proposal. Founder approval is a human decision; no agent should take it.
4. **Engineering delivery:** No production Codex runner consumes approved tasks and opens PRs. GitHub issue dispatch and signed webhook are disabled/unconfigured, and the API has no public ingress for GitHub webhook delivery. A least-privilege GitHub credential and a safe public webhook endpoint/secret still need configuration.
5. **Operating authority:** No department-head approver or general company/department budgets are configured. The €10–50 tier correctly remains fail-closed without a real department head.
6. **Release operations:** Railway wait-for-CI and branch protection are not enabled. Confirm recoverable Supabase backup coverage. Keep the Hermes API toolset restricted to `web`; if Sutra ever needs shell tools, first isolate the terminal backend and prove the sandbox in CI.
7. **Credential hygiene:** User-supplied Telegram, OpenAI and Kimi credentials are held only as private Railway variables and were not added to Git. Rotate/revoke them after verification; do not send replacements in chat or the repository.

## Recommended next steps

1. Keep the terminal historical PM run and its unknown reserve unchanged. After deciding which existing €500 approval request is intended, verify a PM review on an authorized workflow with JSON mode enabled.
2. Keep the Kimi route disabled until its billing usage can reconcile against the database profile. The Kimi secret is installed; no additional key change is needed to resume this investigation.
3. The founder can inspect `CEO, show my approvals.` in the Telegram bot and decide whether the €500 project-budget request is intended. No decision has been made by Sutra.
4. Build a least-privilege Codex runner and signed webhook ingress with model reservation/reconciliation before turning on issue dispatch. Keep QA/Security gated on a merged Developer commit and same-SHA CI.
5. Configure a real department owner, ordinary budgets, Railway CI gating and Supabase recovery coverage.
6. Rotate shared credentials after the base workflow is verified, directly in Railway.
