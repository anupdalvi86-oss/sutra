# Sutra status

Updated: 2026-09-29 10:02 Europe/Stockholm

## Working

- **Production runtime:** Railway project `valiant-liberation` has both private services Online. Railway's latest `sutra-api` deployment is successful for PR [#166](https://github.com/anupdalvi86-oss/sutra/pull/166), commit `a3d5541`; it includes the exact workflow-run-to-PR-head evidence check. Hermes is Online and keeps state on the persistent `/opt/data` volume.
- **Supabase:** project `smqsrigsugjuvuombetq` is `ACTIVE_HEALTHY`. Latest production migration is `20260929075943_bind_workflow_evidence_to_exact_head`. Supabase remains authoritative for tasks, approvals, spending policy, reservations, and audit records.
- **Founder controls:** the Codex no-request retry limit is set to 3 total attempts, with a hard maximum of 3. The configured founder can read or set it from Telegram; changes are founder-only and audit logged, and changing the value does not create an agent run or retry. Retries still require the same approved Developer task and scope, a terminal previous attempt with zero provider requests and tokens, preservation of unknown reservations, and a fresh reservation through the central spend policy and monthly hard cap.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is restricted to founder ID `8776723105`. Live founder-chat checks confirmed the CEO brief includes project objectives and the CMO and Sales briefs show their empty campaign and lead pipelines explicitly. Reports include task queues, blockers, approvals, and financial controls.
- **Financial controls:** spending thresholds remain database-configurable: automatic at/below €10, department head above €10 through €50, CFO + CEO above €50 and below €200, and founder at/above €200. A monthly €8 AI-inference hard stop has an 80% warning threshold. The €10–50 band fails closed until a department approver is assigned. No total company operating budget is configured.
- **GitHub:** repository is public. The runner can work only within an approved Developer task and can open a branch/PR; it cannot merge or release. CI requires Python, database/pgTAP/lint, container/runtime, and secret-scan jobs.

## Current operating state

Live Supabase counts: 1 approved project, 2 proposed projects; 2 completed tasks, 5 backlog, 4 blocked, and 9 open tasks (no ready, in-progress, or review tasks). There are no campaign or customer/lead records. One project-budget approval is pending for a proposed €500 project; its CFO review is complete and founder approval is outstanding. The approved AI QA project has not been released. No purchases, agreements, product releases, or external sales/marketing messages have been made.

Developer task [`269cd305-2a8c-46a7-abb7-3d00f271d78f`](https://github.com/anupdalvi86-oss/sutra/issues/107) remains `blocked`. Its first two executions ended with zero provider requests/tokens; their unknown €0.03 reservations remain held. The third execution used 3 provider requests (30,758 input tokens and 520 output tokens), reconciled at €0.01, and the Codex process exited with code 1. That execution cannot be retried: it used provider tokens and exhausted the three-attempt limit. The founder separately authorized branch/PR creation for the same local synthetic prototype; this scope expansion is recorded in audit log row 342. The resulting [PR #160](https://github.com/anupdalvi86-oss/sutra/pull/160) is open and unmerged, and all five GitHub CI checks pass. Supabase records PR #160 CI run [36538351703](https://github.com/anupdalvi86-oss/sutra/actions/runs/36538351703) as `success`; its stored `ci_head_sha` exactly matches PR #160's current head `6c79a50f6d33ba04b4af6dafdec6811279499398`. PR #166 added validation of workflow-run IDs, URLs and associated PR head SHAs. Its production migration found no invalid evidence rows to clear. No merge or release authority was granted for task #107.

The approved CPO market-research task is blocked after unknown Kimi usage. Its €0.28 reservation remains held. There are 8 unknown reservations totaling €0.74 across the company; none has been estimated or released. PRs [#152](https://github.com/anupdalvi86-oss/sutra/pull/152) and [#153](https://github.com/anupdalvi86-oss/sutra/pull/153) deployed bounded usage-envelope shape diagnostics for future failures; they cannot recover evidence missing from this historical run. Kimi remains disabled for production role routes. QA and Security role handoffs remain deferred by founder direction.

## Latest verification

- PRs #152 and #153 passed all four pull-request CI jobs: Python tests/security analysis, database policy tests/lint, container checks, and secret scan. PR #153's full end-to-end diagnostic test confirms a missing Hermes usage envelope stays unverified, passes no guessed usage to settlement, preserves the reservation, and stores no response content.
- Local validation after PR #152: 170 Python tests passed; `compileall` and Bandit (`-ll`) passed. Local Supabase `test db` passed 362 assertions and database lint passed after PR #151; no schema changed in PRs #152–153.
- Production Supabase reports `ACTIVE_HEALTHY`, the retry limit is 3, and the Developer task has one `codex.task_blocked_after_terminal_failure` audit record. The latest execution has 3 requests and nonzero token usage, so the no-request retry RPC must reject it. The production dispatch row records CI `success` for run URL 36538351703, and its CI head SHA exactly matches PR #160.
- PRs [#155](https://github.com/anupdalvi86-oss/sutra/pull/155)–[#157](https://github.com/anupdalvi86-oss/sutra/pull/157) and [#161](https://github.com/anupdalvi86-oss/sutra/pull/161) passed all four CI jobs and were merged. PR #155 added board objectives and marketing/sales pipelines; #156 and #157 clarified empty states; #161 makes linked open PRs visible before CI evidence arrives. Live Telegram checks verified CEO, CMO, and Sales output. PR #160's green CI result is reflected in the production Supabase evidence ledger; PR #166 additionally binds every accepted workflow run to the exact PR head SHA.
- PR #166 passed all five checks (Python suite, database migration/pgTAP/lint, containers/runtime, secret scan and change detection). The 176-test Python suite completed in about 2 seconds of test execution (12 seconds including CI setup). Main CI run [36539890109](https://github.com/anupdalvi86-oss/sutra/actions/runs/36539890109) passed after merge. The database job takes about 2m38s and container validation about 1m25s, in parallel; Markdown-only changes skip those jobs while retaining secret scanning.
- Chrome Railway verification after PR #166 showed `sutra-api` and Hermes `sutra` Online, with the API deployment marked successful for commit `a3d5541`. Supabase is `ACTIVE_HEALTHY`; its webhook evidence function contains both run-ID and exact-head validations.
- Founder interface commands: `CEO, show Codex no-request retry limit.` and `CEO, set Codex no-request retry limit to 3 total attempts.` The live value is 3, the hard maximum is 3, and the setter is founder-only and audit logged when the value changes; changing it never triggers a retry.

## Remaining work and blockers

1. **GitHub implementation:** issue #107's implementation PR #160 is open, unmerged, and CI-green; Supabase now records matching success evidence. The task cannot be retried due to its nonzero prior usage and exhausted attempt limit. Founder review and any separate merge/release authorization remain outstanding.
2. **Codex execution:** task #107 cannot be retried because its last execution used 3 requests and nonzero tokens and the configured three-attempt ceiling is exhausted. Scope expansion permits branch/PR creation only; no merge or release authority was granted.
3. **CPO usage:** reconcile the unknown Kimi usage from provider evidence before releasing or retrying the reservation.
4. **Approval:** one separate €500 project-budget request remains pending. Approval would cover the project ceiling only, not individual purchases or outreach.
5. **QA and Security:** handoffs remain deferred until the founder resumes that work.
6. **Credentials:** rotate credentials previously shared in chat after base-flow validation and replace them directly in private Railway variables. The €8 cap covers AI inference only, not all company operations.

## Deployment and links

- Railway production project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- API service: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce), private
- Hermes service: `sutra`, private, persistent volume mounted at `/opt/data`
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase: `smqsrigsugjuvuombetq`, `ACTIVE_HEALTHY`
