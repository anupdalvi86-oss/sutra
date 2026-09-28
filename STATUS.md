# Sutra status

Updated: 2026-09-28 (Europe/Stockholm)

## Working

- **Production services:** Railway production project `valiant-liberation` has both `sutra-api` and Hermes `sutra` Online. Hermes has a persistent Railway volume at `/opt/data`; internal endpoints are private. After PR #109, the API `/ready` probe returned HTTP 200, `ready: true`, with Supabase, Telegram, the Hermes gateway, agent worker, GitHub dispatcher, Codex runner and webhook configured. The production Developer dispatch is enabled but currently stuck leasing its founder-approved task; see blockers below.
- **Telegram:** `@sutra86bot` is running and restricted to founder ID `8776723105`. Board-style status commands, the approval queue, proposal intake, and founder-only retry flows have been exercised in the logged-in Telegram session. Status summaries include projects, tasks, blockers, approvals, and financial controls from persisted Supabase data.
- **Supabase:** project `smqsrigsugjuvuombetq` is `ACTIVE_HEALTHY`, PostgreSQL 17.6. The latest hosted migration is `20260928101448_founder_scope_design_context`; 31 migrations are recorded. Public operational tables have RLS enabled; client roles have no direct table access. Founder approvals and policy changes use audited, restricted database functions.
- **Configured financial authority:** live database policies implement automatic spend through €10, department-head review above €10 through €50, CFO + CEO above €50 through €200, and founder review from €200. The €10–50 band fails closed until a department head is assigned. A monthly €8 AI inference budget has an 80% warning and hard stop. Three €500 project ceilings exist from duplicate proposal records; only project `58c52b74-8f15-4174-a079-e869e3df713c` is approved. No total company operating budget is configured.
- **Audit and model spend:** the latest live query returned 190 audit events. The earlier provider ledger query recorded €0.19 reconciled actual usage and €0.40 in unknown-usage reservations under the €8 monthly hard cap. Unknown amounts remain reserved. Production is configured to route roles to OpenAI GPT-6 Luna; Kimi is not routed.
- **GitHub delivery controls:** PRs #101–#109 are merged. PR #109's Python, database/pgTAP/lint, container/runtime and secret-scan jobs passed, as did post-merge `main` run [36413601423](https://github.com/anupdalvi86-oss/sutra/actions/runs/36413601423). The GitHub token is repository-scoped to Sutra with Metadata read, Issues read/write, Contents read/write, Pull Requests read/write, and Actions read; no Administration permission is present. Production dispatch and Codex runner are enabled, but no production Codex execution row or PR has been created yet.

## Current project and workflow

The AI QA opportunity has three proposal records from repeated submissions: one €500 request was rejected, one €500 request is approved, and one duplicate €500 request remains pending. The approved project is `AI QA product opportunity` (`58c52b74-8f15-4174-a079-e869e3df713c`). PM and Architect planning tasks have persisted artifacts. The PM plan is research-first and gates prototype implementation on a founder-reviewed scope, validation evidence, and approved representative scenarios. The approved project ceiling does not itself authorize individual purchases or external research outreach.

A successful PM planning artifact and an Architect design are persisted. The design limits the proposal to a non-executing Playwright test-draft workflow and records target-user, data-handling, provider, validation and retention decisions still needed. Founder scope approval `971fe1e2-d4cb-41d7-bcfb-3c38f097342e` is now approved and the Developer task `269cd305-2a8c-46a7-abb7-3d00f271d78f` is ready; the approval authorizes scoped implementation start but not spend or release. Live counts are 9 open tasks (5 backlog, 2 ready, 2 blocked) and 1 pending approval: a separate proposed €500 project (`93b43006-58f9-4096-9e72-df9aeaf350ff`, approval `539a8225-1230-4896-87d2-b48e7c28ae82`). The CPO research task is also ready. The approved project remains limited to draft-only work; no product release, external outreach or campaign has occurred.

## Checks performed

- Production Supabase connectivity, migration history, RLS/table inventory, spending policies, budgets, project/task/approval state, spend reservations, and audit count were queried on 2026-09-28.
- After the #109 deployment, a fresh production probe from the Railway `sutra-api` console returned `/ready` with `ready: true`, no blockers, and database, Telegram, Hermes gateway, agent worker, GitHub dispatcher and Codex runner all running/configured; both Railway services showed Online. Database inspection confirms the approved Developer task is still `ready`; its dispatch row remains `creating` with no issue number, no PR and no Codex execution. The latest snapshot shows attempt 3 with a lease expiring at 2026-09-28 11:27:35 UTC.
- After PR #104, the Railway UI showed `sutra-api` and Hermes `sutra` Online, with the #104 deployment successful. Telegram rendered the scoped Developer approval with its design excerpt and risks.
- Founder Telegram status and approval commands were exercised. The run that generated the PM artifact reconciled €0.01 and persisted an artifact; the Architect attempt failed closed on unknown usage and retained its reserve.
- PRs #101–#106 passed CI before merge. PR #106 passed all four jobs; its main-branch run is listed at [run 36411707540](https://github.com/anupdalvi86-oss/sutra/actions/runs/36411707540).
- Local Python suite: `python3 -m unittest discover -s tests -q` (132 passed); `python3 -m compileall -q sutra tests`; Bandit (`python3 -m bandit -q -r sutra -ll`, no medium/high findings; existing network-binding B104 warning); and `git diff --check` passed.
- Production Supabase connectivity, migration history, founder scope gate/task state, approval context and audit state were verified after both hosted migrations. The local Supabase Docker stack could not start because the Docker VM ran out of storage while downloading images; hosted migrations, pgTAP and lint passed. Supabase advisor findings previously included informational RLS-without-policy notices; direct client grants remain revoked.

## Blockers and remaining work

1. **Production execution (critical):** the founder scope gate is approved and the Railway GitHub dispatcher/Codex runner are enabled, but dispatch repeatedly remains in `creating` until its lease expires. The canonical GitHub issue #107 is open but unsigned; duplicate #108 was closed. No Codex execution, implementation PR, QA/security evidence or release readiness exists yet. Diagnose the worker's stalled create/sign/complete path before retrying again; do not bypass issue signing or any authorization gate.
2. **Product discovery and boundaries:** the CPO research task is ready. Target users, research participants, representative non-sensitive scenarios, data classification, provider retention and evaluation rubric still need evidence or founder input before external research or any product release. Current approved scope is non-executing draft-only.
3. **Separate proposal:** approval `539a8225-1230-4896-87d2-b48e7c28ae82` is pending for the separate proposed €500 project; this is unrelated to the already-approved project and creates no spend authority.
4. **Launch handoff:** Marketing and Sales outputs are internal drafts only. No real outreach, payment, agreement, or product release has occurred.
5. **Credential hygiene and budgets:** rotate credentials previously shared in chat after base-flow verification. The €8/month limit is the AI inference cap, not a total company operating budget. The €10–50 spend tier remains fail-closed until a department head is assigned; configure other company/department/agent/vendor budgets if needed.

## Deployment and links

- Railway production project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- API service: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce), private; no public API URL
- Hermes: `sutra`, private; volume mounted at `/opt/data`
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase: `smqsrigsugjuvuombetq`, `ACTIVE_HEALTHY`
