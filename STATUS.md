# Sutra status

Updated: 2026-09-29, after production verification of PR #177

## Working

- **Railway:** Production project `valiant-liberation` runs private `sutra` and `sutra-api` services. The API is Online; Railway shows the PR #177 deployment as ACTIVE and successful (deployment `b7b94383-410b-4c6e-8fdd-e872cc07df72`). Hermes data is stored on the persistent `/opt/data` volume.
- **Supabase:** Project `smqsrigsugjuvuombetq` is the authoritative company state and is `ACTIVE_HEALTHY`. The production migration `founder_sales_artifact_retry` is applied (server migration version `20260929103538`).
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) accepts private commands from founder ID `8776723105`. Live founder retry and CEO board-status commands both succeeded after the PR #177 deployment.
- **Founder review/recovery controls:** QA/Security deferral is founder-only, atomic, and audited. The Sales schema-failure recovery is founder-only, audit-logged, and limited to one requeue for the same already-approved task after three terminal schema failures and fully reconciled prior reservations. Each new model attempt still uses normal spend preflight.
- **Financial controls:** Database policy enforces configurable approval thresholds: automatic at/below €10, department head above €10 through €50, CFO + CEO above €50 and below €200, and founder at/above €200. The €10–50 band fails closed until a department approver is assigned. AI inference has an €8 monthly hard stop and 80% warning. No company-wide operating budget is configured.
- **GitHub:** Repository is public. Engineering tasks can dispatch to GitHub and Codex can open branches/PRs; Sutra cannot merge or release. CI requires Python, database/pgTAP/lint, container/runtime, and secret-scan jobs.

## Current operating state

Supabase has 1 approved project and 2 proposed projects. Across 11 tasks, 7 are done, 2 are blocked, and 2 are deferred. The approved project is **AI QA product opportunity**, with a €500 project ceiling. The two proposed-project CPO research tasks remain blocked; one €500 project-budget approval for a proposed duplicate is pending. Do not approve that duplicate unless the founder wants it.

Completed approved-project work includes CPO research, PM product plan, Architect design, Developer task #107 and merged PR #160, internal DevOps release/rollback plan, internal Marketing campaign draft, and internal Sales handoff. PR #160's merge CI evidence matched its exact head commit. Marketing and Sales outputs are drafts only; no external outreach, publication, expense beyond authorized model inference, or product release occurred.

QA and Security tasks remain deferred and incomplete by founder direction. Therefore the product has **not** passed QA/Security and is **not release-ready**. The DevOps plan is internal planning only.

The Sales handoff recovery is verified live. The initial artifact run ended after three schema-validation attempts. After the founder command `retry Sales task 8cb051cb-22c8-4a0d-b12f-9f57c39e9d61 after artifact schema fix`, the task completed and persisted a `sales_handoff` artifact. The new attempt reconciled at €0.01; all four attempts for that task total €0.04 actual spend. The founder retry is audit-logged against the founder ID; the retry granted no project-spend, merge, or release authority.

Eight unknown model-spend reservations totaling €0.74 remain held; none were changed by the Sales retry. Reconciled AI-inference spend this month is €0.27 against the €8 cap.

## Latest verification

- PR [#177](https://github.com/anupdalvi86-oss/sutra/pull/177) merged as `9db8f9279055ad6814ed0e43acae559f9f8293c3`. All five CI jobs passed: Python, database, containers, secret scan, and change detection.
- Local verification for PR #177: **204 Python tests passed**, **441 pgTAP assertions across 15 files passed**, Supabase database lint was clean, Bandit reported no medium/high findings, `compileall` passed, and `git diff --check` passed.
- Production verification for PR #177: Railway deployment is Online/ACTIVE/successful; the migration is applied; the founder-only retry function is unavailable to `anon` and `authenticated` and executable by `service_role` only.
- Live Telegram-to-Supabase verification: founder Sales recovery command returned success; task is `done`; exactly one `sales_handoff` artifact is persisted; new and prior reservations are reconciled; audit log names founder `8776723105` and records no added spend, merge, or release authority.
- Live CEO board status reflects 2 blocked CPO tasks, 2 deferred QA/Security reviews, the pending project approval, project budget controls, and the merged PR/CI evidence.

## Remaining work and blockers

1. The approved product is not release-ready until the founder restores and completes QA and Security reviews. Current deferral commands and restore IDs are available through the CEO Telegram brief.
2. Decide whether the two proposed duplicate projects should proceed. One €500 budget approval is pending; do not approve it automatically.
3. Resolve why the proposed-project CPO research tasks are blocked, or close those proposals if they are unwanted.
4. Railway logs previously warned that the internal API binds to `0.0.0.0` while Hermes uses a local, unsandboxed terminal backend. Railway currently lists the API as unexposed; runtime hardening remains outstanding.
5. Rotate credentials previously pasted into chat and replace them directly in private Railway variables. Do not commit credentials. The €8 cap covers AI inference, not all company operations.
6. Keep all 8 unknown reservations totaling €0.74 held until provider evidence supports exact reconciliation.
7. CEO and department Telegram reports give board-style portfolio, open-work, blocker, approval, and control details. A follow-up improvement is in progress to include recent completed tasks in these briefs.

## Deployment and links

- Railway production project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- API service: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce), private
- Hermes service: `sutra`, private; persistent volume mounted at `/opt/data`
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase: `smqsrigsugjuvuombetq`, `ACTIVE_HEALTHY`
