# Sutra status

Updated: 2026-09-29 00:03 Europe/Stockholm

## Codex process failure correction (live)

PRs #133 and #134 merged the runner/status fix and rolling-deploy guard. Migration `20260928213518` is applied to Supabase project `smqsrigsugjuvuombetq`; production exposes the six-argument completion RPC only to `service_role`, while the legacy call fails closed. The live API and Hermes services restarted after the merged code; Railway logs show the API health probe returned HTTP 200 and Hermes gateway supervision started. The confirmed attempt 3 record was corrected with an audit event: the run/execution are failed, while the €0.01 spend reservation remains reconciled. CEO status can now identify this as an execution blocker and state that no automatic retry is queued. No project-spend, merge, or release authority was added.

PR #137 (`f203f32`) adds safe, allowlisted Codex failure categories without persisting provider response text. Its migration is applied in Supabase as `20260928215517`; production function grants remain restricted to `service_role`. Railway logs show the post-merge API `/health` check returned HTTP 200 and Hermes restarted under supervision. The checked-in migration filename matches production history.

## Working

- **Supabase:** project `smqsrigsugjuvuombetq` is reachable and `ACTIVE_HEALTHY`. PR #131 migration is applied; the database setting is 3 total attempts, marked governance-sensitive and founder-only. The getter/setter execute grants are restricted to `service_role`; anon execute is denied. Supabase remains the source of truth for projects, tasks, approvals, spending rules, reservations and audit events.
- **Railway:** production project `valiant-liberation` has Hermes `sutra` and API `sutra-api`. After PRs #133/#134 merged, Railway logs showed both services restart; Hermes gateway supervision started and API `/health` returned HTTP 200. Both services remain private. Hermes state uses the persistent volume at `/opt/data`.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is restricted to founder ID `8776723105`. Board-style CEO/department status, proposal intake, approval listing and founder-only retry commands have been exercised in the logged-in founder chat.
- **Founder command workflow:** an AI QA product proposal completed CEO → CPO → CTO → CFO → PM and persisted role artifacts. One project is approved with a requested ceiling of €500; two separate proposals remain proposed, with one project-budget approval pending. The approved project ceiling does not authorize individual purchases or external outreach.
- **Financial controls:** database-configured defaults remain automatic through €10, department-head review above €10 through €50, CFO + CEO above €50 through €200, and founder review at/above €200. A monthly €8 AI-inference hard stop has an 80% warning. The €10–50 band fails closed until a department head is assigned. No total company operating budget is configured. Unknown reservations remain held and are never estimated or released.
- **GitHub:** repository-scoped GitHub access verifies and signs existing issue [#107](https://github.com/anupdalvi86-oss/sutra/issues/107), and the runner checked out the repository. PR #127 added explicit Codex model-provider routing through the metering proxy. PR [#129](https://github.com/anupdalvi86-oss/sutra/pull/129) adds allowlisted Hermes completion metadata to missing-usage diagnostics; all four CI jobs passed and it was deployed. PR #131 (`1369c0d`) adds the founder-adjustable three-attempt gate; all four CI checks passed, the database migration was applied, and the feature is deployed and exercised through Telegram. No project-spend, merge, or release authority was added.

## Current engineering attempt

The founder-approved Developer task `269cd305-2a8c-46a7-abb7-3d00f271d78f` remains `in_progress`, linked to issue #107. PR #127 fixed Codex CLI routing through the metered loopback provider and is deployed. The founder-authorized third and final attempt ran against that fix. Supabase verified two earlier terminal attempts with zero requests and zero tokens; both unknown reservations were preserved. Attempt 3 received 3 metered provider requests (30,758 input tokens, 520 output tokens), reconciled at €0.01, and its reservation remains reconciled. The Codex process exited with return code 1 (`usage_recorded=true`, `usage_uncertain=false`). An audit-logged correction now records the run/execution as failed without changing the reservation. Issue #107 remains open, no implementation PR was created, and the Sutra task remains `in_progress` with the execution failure visible to CEO status. The three-attempt ceiling is exhausted; no additional retry was issued.

## Current operational counts

Latest live Supabase query:

- Projects: 1 approved, 2 proposed.
- Tasks: 2 done, 1 ready, 1 in progress, 5 backlog, 2 blocked (9 open total).
- Pending approvals: 1 project-budget approval (`539a8225-1230-4896-87d2-b48e7c28ae82`) for a separate proposed project.
- Latest founder-facing CEO status also reports 9 open tasks (5 backlog, 1 ready, 1 in progress, 2 blocked). The approved AI QA project has not been released. No real sales/marketing messages, purchases, agreements, or deployments of a product have occurred.
- QA and Security agent handoffs remain deferred by founder direction.

## Checks performed

- Full Python suite: `python3 -m unittest discover -s tests` — 160 passed after PR #133.
- Python compile check: `python3 -m compileall -q sutra tests` — passed.
- Bandit: no medium/high findings.
- Gitleaks 8.30.1: no leaks found.
- PR #127 GitHub CI run [36477574459](https://github.com/anupdalvi86-oss/sutra/actions/runs/36477574459) passed Python, database/pgTAP/lint, container/runtime, and secret-scan jobs.
- PR #129 GitHub CI run [36480418155](https://github.com/anupdalvi86-oss/sutra/actions/runs/36480418155) passed Python, database/pgTAP/lint, container/runtime, and secret-scan jobs. PR #131 GitHub CI run [36483408973](https://github.com/anupdalvi86-oss/sutra/actions/runs/36483408973) passed the same four jobs, including the new retry policy SQL tests. Local validation also passed Bandit 1.9.4 (`-ll`) and Gitleaks 8.30.1.
- PR #133 passed all four CI jobs; PR #134 passed all four CI jobs on workflow run [36486867292](https://github.com/anupdalvi86-oss/sutra/actions/runs/36486867292); PR #135 passed all four on run [36487639254](https://github.com/anupdalvi86-oss/sutra/actions/runs/36487639254). The SQL suite contains 324 pgTAP assertions across eight files. Migration filename `20260928213518` matches the version recorded by Supabase.
- PR #137 passed all four CI jobs on workflow run [36488946286](https://github.com/anupdalvi86-oss/sutra/actions/runs/36488946286): 163 Python tests, 329 pgTAP assertions across eight files, database lint, container/runtime checks, and secret scanning. Supabase migration `20260928215517` and the production function grants were verified against live migration history. PR #138 aligned the checked-in migration filename and status/deployment docs; its four CI jobs passed on run [36489585469](https://github.com/anupdalvi86-oss/sutra/actions/runs/36489585469).
- Codex CLI 0.157.1 isolated smoke: local test server received the Responses request at `/v1/responses`; the key was a dummy value and no production provider call was made.
- Railway after PR #127: both services showed Online and `sutra-api` `/health` returned HTTP 200.
- Supabase production project was queried for setting value, RPC grants, task state, three attempts, reservations and the corresponding audit records. Railway showed `sutra-api` and Hermes online; the Telegram founder chat verified the read/set commands and the 3/3 retry response. The CEO board status command was also rechecked.
- Production Supabase verified both completion RPC signatures: the six-argument RPC grants execute only to `service_role`, and anon/authenticated have no execute grant. Verified the failed Codex run/execution, unchanged reconciled reservation, and exactly one backfill audit row. Railway Chrome logs show Hermes restart/recovery and API `/health` HTTP 200 after the merged deploy.
- Railway Chrome logs after PR #137 show API `/health` HTTP 200 and Hermes gateway startup under restart supervision. Supabase confirms the founder retry-limit value remains 3; this setting change does not launch a run. The existing task has already consumed attempt 3 with metered provider requests, so it is ineligible for the narrowly scoped no-request retry path.

## Remaining work and blockers

1. **Developer task remains blocked:** attempt 3/3 reconciled provider usage but the Codex process exited 1 before producing a reviewable PR. The task still shows `in_progress`, but CEO status reports the persisted execution blocker. The no-request retry RPC rejects this run because it used provider requests and tokens; increasing the limit cannot make it eligible. A new Developer execution needs fresh founder-approved scope. The currently approved scope bars source-control write, deployment, and production operation, so Sutra must not create another issue/branch/PR for that product task until the founder authorizes that scope. Changing the limit alone never triggers a retry.
2. The `CEO, show Codex no-request retry limit.` and `CEO, set Codex no-request retry limit to <1-5> total attempts.` commands are live. Live founder chat verified the show command and that setting the existing value causes no change or retry. Database CI verifies an actual change is audit logged and creates no agent run. The €8 monthly hard cap and no-project-spend/no-merge/no-release safeguards remain unchanged.
3. If the task reaches implementation, the runner may create a branch and PR but cannot merge or release. Keep CI evidence attached to the PR. QA and Security role handoffs are deferred by founder direction.
4. The CPO-only Kimi route has no post-rollout usage-reconciliation evidence; an earlier €0.28 unknown reservation remains held. PR #129 improves sanitized diagnostics for a future database-reserved reproduction, but does not establish the historical cause. Kimi remains disabled. A separate proposed €500 project-budget approval remains pending.
5. Rotate credentials previously shared in chat after base-flow verification. The €8 cap covers AI inference only, not all company operations.

## Deployment and links

- Railway production project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- API service: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce), private
- Hermes service: `sutra`, private, persistent volume mounted at `/opt/data`
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase: `smqsrigsugjuvuombetq`, `ACTIVE_HEALTHY`
