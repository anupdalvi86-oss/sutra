# Sutra status

Updated: 2026-09-29 02:22 Europe/Stockholm

## Working

- **Production runtime:** Railway project `valiant-liberation` has both private services Online. The latest `main` deployment is PR [#150](https://github.com/anupdalvi86-oss/sutra/pull/150), marked successful for both `sutra-api` and Hermes `sutra`. Hermes keeps state on the persistent `/opt/data` volume.
- **Supabase:** project `smqsrigsugjuvuombetq` is `ACTIVE_HEALTHY`. Latest production migration is `20260929001756_codex_terminal_task_state`; the checked-in filename now matches that version. Supabase remains authoritative for tasks, approvals, spending policy, reservations, and audit records.
- **Founder controls:** the Codex no-request retry limit is set to 3 total attempts, with a hard maximum of 3. The configured founder can read or set it from Telegram; changes are founder-only and audit logged, and changing the value does not create an agent run or retry. Retries still require the same approved Developer task and scope, a terminal previous attempt with zero provider requests and tokens, preservation of unknown reservations, and a fresh reservation through the central spend policy and monthly hard cap.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is restricted to founder ID `8776723105`. CEO and department status commands report persisted projects, tasks, blockers, approvals, and financial controls. The founder approval queue and retry-limit commands are available.
- **Financial controls:** spending thresholds remain database-configurable: automatic through €10, department head above €10 through €50, CFO + CEO above €50 through €200, and founder at/above €200. A monthly €8 AI-inference hard stop has an 80% warning threshold. The €10–50 band fails closed until a department approver is assigned. No total company operating budget is configured.
- **GitHub:** repository is public. The runner can work only within an approved Developer task and can open a branch/PR; it cannot merge or release. CI requires Python, database/pgTAP/lint, container/runtime, and secret-scan jobs.

## Current operating state

Live Supabase counts: 1 approved project, 2 proposed projects; 2 completed tasks, 5 backlog, 4 blocked, and 9 open tasks. One project-budget approval is pending for a proposed €500 project. The approved AI QA project has not been released. No purchases, agreements, product releases, or external sales/marketing messages have been made.

Developer task [`269cd305-2a8c-46a7-abb7-3d00f271d78f`](https://github.com/anupdalvi86-oss/sutra/issues/107) is `blocked`. Its first two executions ended with zero provider requests/tokens; their unknown €0.03 reservations remain held. The third execution used 3 provider requests (30,758 input tokens and 520 output tokens), reconciled at €0.01, and the Codex process exited with code 1 before producing a PR. The reservation remains reconciled, and an audit event records the blocked task state. No retry is eligible: the third attempt had provider usage and the three-attempt total limit is exhausted. Raising or changing that limit cannot make this execution eligible.

The approved CPO market-research task is blocked after unknown Kimi usage. Its €0.28 reservation remains held. There are 8 unknown reservations totaling €0.74 across the company; none has been estimated or released. QA and Security role handoffs remain deferred by founder direction.

## Latest verification

- PR #150 merged at `35dc06d` and CI run [36502138333](https://github.com/anupdalvi86-oss/sutra/actions/runs/36502138333) passed Python, database/pgTAP/lint, container/runtime, and secret-scan jobs.
- Local validation for PR #150: 170 Python tests passed; `compileall` and Bandit (`-ll`) passed; local Supabase `test db` passed 362 assertions and database lint passed.
- Production Supabase reports `ACTIVE_HEALTHY`, migration `20260929001756` is applied, the retry limit is 3, and the Developer task has one `codex.task_blocked_after_terminal_failure` audit record. The current task execution has 3 requests and nonzero token usage, so the no-request retry RPC must reject it.
- Chrome Railway dashboard verification after PR #150 showed `sutra-api` and Hermes `sutra` Online, with both latest deployments marked successful.
- Founder interface commands: `CEO, show Codex no-request retry limit.` and `CEO, set Codex no-request retry limit to 3 total attempts.` The latter changes only the audited database control; it does not trigger a retry.

## Remaining work and blockers

1. **Developer implementation:** issue #107 has no implementation PR. The existing task cannot be retried under the zero-request safeguard. Continuing implementation requires a fresh founder-approved Developer scope that authorizes the intended source changes; the prior approved scope does not authorize them.
2. **CPO usage:** reconcile the unknown Kimi usage from provider evidence before releasing or retrying the reservation.
3. **Approval:** one separate €500 project-budget request remains pending. Approval would cover the project ceiling only, not individual purchases or outreach.
4. **QA and Security:** handoffs remain deferred until the founder resumes that work.
5. **Credentials:** rotate credentials previously shared in chat after base-flow validation and replace them directly in private Railway variables. The €8 cap covers AI inference only, not all company operations.

## Deployment and links

- Railway production project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- API service: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce), private
- Hermes service: `sutra`, private, persistent volume mounted at `/opt/data`
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase: `smqsrigsugjuvuombetq`, `ACTIVE_HEALTHY`
