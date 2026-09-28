# Sutra status

Updated: 2026-09-28 23:26 Europe/Stockholm

## In-progress platform correction

PR #133 merged the runner/status correction to `main`. The former completion RPC used one boolean for both trusted usage settlement and CLI success, so attempt 3 was financially reconciled but incorrectly recorded as a successful agent run when Codex exited 1. The new RPC records those outcomes separately, keeps the €0.01 reservation reconciled, marks the agent run and execution failed, and writes a sanitized audit event. CEO status now surfaces that in-progress task as blocked by execution and says no automatic retry is queued. A follow-up fail-closed migration guard is being validated before applying the database change. Until that guard is merged and the migration is applied, production DB and runtime versions are mismatched: the exhausted task cannot run, and no retry was issued. No project-spend, merge, or release authority is added by this change.

## Working

- **Supabase:** project `smqsrigsugjuvuombetq` is reachable and `ACTIVE_HEALTHY`. PR #131 migration is applied; the database setting is 3 total attempts, marked governance-sensitive and founder-only. The getter/setter execute grants are restricted to `service_role`; anon execute is denied. Supabase remains the source of truth for projects, tasks, approvals, spending rules, reservations and audit events.
- **Railway:** production project `valiant-liberation` has Hermes `sutra` and API `sutra-api` Online. The latest merged code is `1369c0d` (PR #131); Railway shows both services Online; the new Telegram control responds, and the API `/health` probe returned HTTP 200. Both services remain private. Hermes state uses the persistent volume at `/opt/data`.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is restricted to founder ID `8776723105`. Board-style CEO/department status, proposal intake, approval listing and founder-only retry commands have been exercised in the logged-in founder chat.
- **Founder command workflow:** an AI QA product proposal completed CEO → CPO → CTO → CFO → PM and persisted role artifacts. One project is approved with a requested ceiling of €500; two separate proposals remain proposed, with one project-budget approval pending. The approved project ceiling does not authorize individual purchases or external outreach.
- **Financial controls:** database-configured defaults remain automatic through €10, department-head review above €10 through €50, CFO + CEO above €50 through €200, and founder review at/above €200. A monthly €8 AI-inference hard stop has an 80% warning. The €10–50 band fails closed until a department head is assigned. No total company operating budget is configured. Unknown reservations remain held and are never estimated or released.
- **GitHub:** repository-scoped GitHub access verifies and signs existing issue [#107](https://github.com/anupdalvi86-oss/sutra/issues/107), and the runner checked out the repository. PR #127 added explicit Codex model-provider routing through the metering proxy. PR [#129](https://github.com/anupdalvi86-oss/sutra/pull/129) adds allowlisted Hermes completion metadata to missing-usage diagnostics; all four CI jobs passed and it was deployed. PR #131 (`1369c0d`) adds the founder-adjustable three-attempt gate; all four CI checks passed, the database migration was applied, and the feature is deployed and exercised through Telegram. No project-spend, merge, or release authority was added.

## Current engineering attempt

The founder-approved Developer task `269cd305-2a8c-46a7-abb7-3d00f271d78f` remains `in_progress`, linked to issue #107. PR #127 fixed Codex CLI routing through the metered loopback provider and is deployed. The founder-authorized third and final attempt ran against that fix. Supabase verified two earlier terminal attempts with zero requests and zero tokens; both unknown reservations were preserved. Attempt 3 received 3 metered provider requests (30,758 input tokens, 520 output tokens), reconciled at €0.01, and its reservation was reconciled. The Codex process then exited with return code 1 (`usage_recorded=true`, `usage_uncertain=false`). Issue #107 is still open, no implementation PR was created, and the Sutra task remains `in_progress`. The configured three-attempt ceiling is now exhausted; no additional retry was issued.

## Current operational counts

Latest live Supabase query:

- Projects: 1 approved, 2 proposed.
- Tasks: 2 done, 1 ready, 1 in progress, 5 backlog, 2 blocked (9 open total).
- Pending approvals: 1 project-budget approval (`539a8225-1230-4896-87d2-b48e7c28ae82`) for a separate proposed project.
- Latest founder-facing CEO status also reports 9 open tasks (5 backlog, 1 ready, 1 in progress, 2 blocked). The approved AI QA project has not been released. No real sales/marketing messages, purchases, agreements, or deployments of a product have occurred.
- QA and Security agent handoffs remain deferred by founder direction.

## Checks performed

- Full Python suite: `python3 -m unittest discover -s tests` — 159 passed after PR #131.
- Python compile check: `python3 -m compileall -q sutra tests` — passed.
- Bandit: no medium/high findings.
- Gitleaks 8.30.1: no leaks found.
- PR #127 GitHub CI run [36477574459](https://github.com/anupdalvi86-oss/sutra/actions/runs/36477574459) passed Python, database/pgTAP/lint, container/runtime, and secret-scan jobs.
- PR #129 GitHub CI run [36480418155](https://github.com/anupdalvi86-oss/sutra/actions/runs/36480418155) passed Python, database/pgTAP/lint, container/runtime, and secret-scan jobs. PR #131 GitHub CI run [36483408973](https://github.com/anupdalvi86-oss/sutra/actions/runs/36483408973) passed the same four jobs, including the new retry policy SQL tests. Local validation also passed Bandit 1.9.4 (`-ll`) and Gitleaks 8.30.1.
- Codex CLI 0.157.1 isolated smoke: local test server received the Responses request at `/v1/responses`; the key was a dummy value and no production provider call was made.
- Railway after PR #127: both services showed Online and `sutra-api` `/health` returned HTTP 200.
- Supabase production project was queried for setting value, RPC grants, task state, three attempts, reservations and the corresponding audit records. Railway showed `sutra-api` and Hermes online; the Telegram founder chat verified the read/set commands and the 3/3 retry response. The CEO board status command was also rechecked.

## Remaining work and blockers

1. **Developer task is blocked:** attempt 3/3 reconciled provider usage but the Codex process exited 1 before producing a reviewable PR. The issue remains open and the company status currently reports the task in progress. Diagnose the runner exit path; do not retry under the current limit. The no-request retry RPC will reject this execution because it used provider requests and tokens; increasing the limit cannot make it eligible. Diagnose the runner exit path before proposing any new Developer scope, which would require its own approval. Changing the limit alone never triggers a retry.
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
