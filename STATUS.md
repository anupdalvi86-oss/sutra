# Sutra Status

Updated: 2026-09-28 (Europe/Stockholm)

## What is working

- Railway production `sutra-api` is online and the latest `/ready` check returned `ready: true`. The service stays private; there is no public application URL. [Open the Railway service](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce).
- `/ready` reports Supabase reachable, Telegram running, and the agent worker running. The GitHub dispatcher and Codex runner are disabled.
- A fresh founder-account message to `@sutra86bot` received the expected company-status reply: 3 projects, 3 open tasks, and 2 pending approvals. Telegram `getMe` also confirmed the configured bot identity.
- Private Railway `sutra-api` variables include the repository token, webhook secret, and the same OpenAI key used by Hermes. GitHub confirms the configured fine-grained token has access to zero repositories, which explains the service-side HTTP 404. A grant limited to this repository is staged in GitHub and awaits founder confirmation before it can be saved. Secret values are not stored in this repository or this status file.
- Supabase project `smqsrigsugjuvuombetq` is reachable. The runner claim column and restricted RPC exist, and migration `20260927224724_claim_codex_runner_lease` is recorded as applied.
- Three durable proposals and two pending €500 budget approvals are recorded. The founder queue now correctly shows one proposal waiting for PM review and another waiting for CFO and PM review. The latest PM run exhausted its three bounded attempts on artifact validation; no project approval or spend was authorized.
- The Supabase model ledger records €0.42 in current-month committed inference expenses: €0.11 reconciled actual and €0.31 retained as unknown-use reservations. The active monthly AI inference hard cap is €8 with an 80% warning threshold.
- The metered Codex runner is deployed but opt-in. It checks approved routes and budgets, records completed Responses API usage through a loopback proxy, and can open PRs but cannot merge or deploy.

## Deployment

- Railway project: `valiant-liberation`, production environment.
- API service: `sutra-api`, private and online; current readiness check passed.
- Hermes service: `sutra` online with its persistent volume; its API remains private.
- Telegram: founder-only bot responds to the configured founder account.
- Supabase: migrations through `20260927234945_founder_pm_approval_readiness` are applied.
- GitHub: repository `anupdalvi86-oss/sutra`; PRs #65–#77 merged. PR #73 tightened PM artifact validation diagnostics. PRs #75–#76 expanded pgTAP coverage for scoped budget limits, accumulated spend, warning/soft-stop behavior, founder-only financial changes, audit logging, and agent self-escalation denial. Python, database/pgTAP, container build, secret-scan, and Python security-analysis checks passed.

## Checks performed

- Local Python suite after PM artifact diagnostics: `python3 -m pytest -q` — 106 passed.
- GitHub CI on PRs #67 and #68: Python, database/pgTAP, container build and secret scan all passed.
- GitHub CI on PRs #75 and #76: all checks passed, including hosted PostgreSQL migration/test runs and Python security analysis. SQL tests cover company/project/department/agent/category/vendor budgets; transaction/daily/monthly/lifetime periods; accumulated spend; hard and soft stops; warnings; and founder-only authority changes.
- `python3 -m bandit -q -r sutra`: no medium or high findings; four low-severity notices relate to subprocess use in the opt-in task runner.
- Python compile check and `git diff --check` passed.
- Live read-only Supabase checks verified connectivity, core tables, the one-time runner claim RPC, no direct `anon`/`authenticated` access, project/task counts, and pending approvals. `customers.status='lead'` represents leads in the same lifecycle table.
- Live GitHub API validation from the Railway service with the configured repository token returned HTTP 404 for the private Sutra repository. The signed-in GitHub settings page confirmed that the token has no repository permissions and selects no repositories. The local GitHub CLI session can see the repository, but that session's credential was not copied into the service.
- Applied migration `20260927234945_founder_pm_approval_readiness`; Supabase and Telegram now both show the PM review as outstanding and withhold the founder approval action.
- Supabase `agent_run_spend_reservations` shows three attempts on the latest PM run. One attempt's usage is unknown and remains reserved; the other two are reconciled. The system correctly refuses an additional retry after its bounded attempt limit.
- Supabase security advisor reports 22 informational `rls_enabled_no_policy` findings. Tables intentionally have RLS enabled and no end-user policies; direct client grants are revoked and company writes use restricted server-side RPCs. Recheck if direct client access is introduced.

## Remaining blockers

1. The supplied GitHub token is configured but currently grants access to zero repositories (HTTP 404). The token editor is staged for only `anupdalvi86-oss/sutra`, with Contents read/write, Issues read/write, Pull requests read/write, Actions read and required Metadata read. Founder confirmation is required before saving this access change. The dispatcher and runner remain disabled.
2. The latest PM proposal review exhausted its three bounded attempts and failed artifact validation. The queue correctly blocks founder approval until PM succeeds; the retry limit must not be bypassed without a founder-authorized control change.
3. Three projects are proposed and all three tasks are blocked. One €500 project-budget approval is waiting for PM; another is waiting for CFO and PM. No project spending is authorized.
4. The full engineering handoff (approved task → GitHub branch/PR → CI evidence → QA/security/release readiness) has not been exercised live. It requires repository access, a successful PM review, and founder approval.
5. The local Supabase Docker stack could not start because the Docker VM ran out of storage while pulling images. Hosted Supabase pgTAP passed on PR #72.

## Credentials / integrations still required

- Founder confirmation to save the staged repository-specific token grant. Keep using the local `gh` credential only for normal repository operations; do not copy it into Railway.
- The PM review needs a supported path forward under the existing retry bound. No additional inference attempt has been scheduled.
- Founder approval remains a separate gate after PM review; a €500 budget ceiling does not authorize spending.
- Rotate the credentials previously pasted into chat after integration verification is complete. Keep all Railway values private.

## Recommended next steps

1. Correct the GitHub token's repository selection/permissions and re-run the private repository-access check.
2. Resolve the PM review failure without bypassing the current retry or spending controls; make a founder decision only after the PM gate becomes ready.
3. After approved work and repository access exist, enable the dispatcher/runner, exercise one low-cost task under the active €8/month hard cap, and review the PR before any merge.
4. Verify the full QA/security evidence handoff and release readiness.
