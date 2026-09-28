# Sutra Status

Updated: 2026-09-28 (Europe/Stockholm)

## What is working

- Railway production `sutra-api` is online and the latest `/ready` check returned `ready: true`. The service stays private; there is no public application URL. [Open the Railway service](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce).
- Post-PR #79 `/ready` returned HTTP 200 with `ready: true`: Supabase reachable, Telegram running, and the agent worker running. The GitHub dispatcher and Codex runner are disabled; webhook signing is configured.
- A fresh founder-account message to `@sutra86bot` received the expected company-status reply: 3 projects, 3 open tasks, and 2 pending approvals. Telegram `getMe` also confirmed the configured bot identity.
- Private Railway `sutra-api` variables already match the GitHub token and webhook secret most recently supplied by the founder; the same OpenAI key is used by Hermes. GitHub's token editor has `anupdalvi86-oss/sutra` selected with the runner's minimum permissions, but the persisted token grant still has zero repositories, which explains the service-side HTTP 404. Saving the staged one-repository grant and rechecking access are pending. Secret values are not stored in this repository or this status file.
- Supabase project `smqsrigsugjuvuombetq` is reachable. The runner claim column and restricted RPC exist, and migration `20260927224724_claim_codex_runner_lease` is recorded as applied.
- Three durable proposals and two pending €500 budget approvals are recorded. The founder queue now correctly shows one proposal waiting for PM review and another waiting for CFO and PM review. The latest PM run exhausted its three bounded attempts on artifact validation; no project approval or spend was authorized.
- The Supabase model ledger records €0.42 in current-month committed inference expenses: €0.11 reconciled actual and €0.31 retained as unknown-use reservations. The active monthly AI inference hard cap is €8 with an 80% warning threshold.
- The metered Codex runner is deployed but opt-in. It checks approved routes and budgets, records completed Responses API usage through a loopback proxy, and can open PRs but cannot merge or deploy.
- PR #81 repaired the live CPO/Sales delegation targets to the active `cmo` agent slug. A post-migration Supabase query found zero missing or inactive delegation targets.

## Deployment

- Railway project: `valiant-liberation`, production environment.
- API service: `sutra-api`, private and online; Railway reports the PR #81 main-branch deployment successful. The last explicit `/ready` probe returned HTTP 200 with `ready: true` after PR #79.
- Hermes service: `sutra` online with its persistent volume; its API remains private.
- Telegram: founder-only bot responds to the configured founder account.
- Supabase: migrations through `20260928010406_repair_agent_delegation_targets` are applied.
- GitHub: repository `anupdalvi86-oss/sutra`; PRs #65–#81 merged. PR #73 tightened PM artifact validation diagnostics; PR #79 gives non-object model output a more specific safe diagnostic; PR #81 documents role contracts and repairs live delegation metadata. PRs #75–#76 expanded pgTAP coverage for scoped budget limits, accumulated spend, warning/soft-stop behavior, founder-only financial changes, audit logging, and agent self-escalation denial. Python, database/pgTAP, container build, secret-scan, and Python security-analysis checks passed.

## Checks performed

- Local Python suite after PM root-shape diagnostics: `python3 -m pytest -q` — 107 passed.
- GitHub CI on PRs #67 and #68: Python, database/pgTAP, container build and secret scan all passed.
- GitHub CI on PRs #75 and #76: all checks passed, including hosted PostgreSQL migration/test runs and Python security analysis. SQL tests cover company/project/department/agent/category/vendor budgets; transaction/daily/monthly/lifetime periods; accumulated spend; hard and soft stops; warnings; and founder-only authority changes.
- GitHub CI on PR #79: Python, hosted database, container build and secret scan all passed. Railway deployed commit `ebd0c58` successfully; a fresh in-container `/ready` probe returned HTTP 200 and `ready: true`.
- GitHub CI on PR #81: Python (107 tests, compile and Bandit), hosted database migration/pgTAP/lint, container images and secret scan all passed. The production data migration applied as version `20260928010406`; the post-apply query confirmed zero invalid delegation targets.
- `python3 -m bandit -q -r sutra`: no medium or high findings; four low-severity notices relate to subprocess use in the opt-in task runner.
- Python compile check and `git diff --check` passed.
- Live read-only Supabase checks verified connectivity, core tables, the one-time runner claim RPC, no direct `anon`/`authenticated` access, project/task counts, and pending approvals. `customers.status='lead'` represents leads in the same lifecycle table.
- Live GitHub API validation from the Railway service with the configured repository token returned HTTP 404 for the private Sutra repository. The signed-in GitHub settings page confirmed that the token has no repository permissions and selects no repositories. The local GitHub CLI session can see the repository, but that session's credential was not copied into the service.
- Applied migration `20260927234945_founder_pm_approval_readiness`; Supabase and Telegram now both show the PM review as outstanding and withhold the founder approval action.
- Supabase `agent_run_spend_reservations` shows three attempts on the latest PM run. One attempt's usage is unknown and remains reserved; the other two are reconciled. The system correctly refuses an additional retry after its bounded attempt limit.
- Supabase security advisor reports 22 informational `rls_enabled_no_policy` findings. Tables intentionally have RLS enabled and no end-user policies; direct client grants are revoked and company writes use restricted server-side RPCs. Recheck if direct client access is introduced.

## Remaining blockers

1. The current Railway GitHub token grants access to zero repositories (HTTP 404). GitHub has the Sutra-only grant staged with Contents, Issues and Pull requests read/write, Actions and Metadata read. Founder action-time confirmation to save this security access change is outstanding. The dispatcher and runner remain disabled.
2. The latest PM proposal review exhausted its three bounded attempts and failed artifact validation. The queue correctly blocks founder approval until PM succeeds; the retry limit must not be bypassed without a founder-authorized control change.
3. Three projects are proposed and all three tasks are blocked. One €500 project-budget approval is waiting for PM; another is waiting for CFO and PM. No project spending is authorized.
4. The full engineering handoff (approved task → GitHub branch/PR → CI evidence → QA/security/release readiness) has not been exercised live. It requires repository access, a successful PM review, and founder approval.
5. The local Supabase Docker stack could not start because the Docker VM ran out of storage while pulling images. Hosted Supabase pgTAP passed on PR #72.

## Credentials / integrations still required

- Save the staged Sutra-only repository grant in GitHub, then verify the Railway token against `anupdalvi86-oss/sutra`; keep the local `gh` credential separate from Railway.
- The PM review needs a supported path forward under the existing retry bound. No additional inference attempt has been scheduled.
- Founder approval remains a separate gate after PM review; a €500 budget ceiling does not authorize spending.
- Rotate the credentials previously pasted into chat after integration verification is complete. Keep all Railway values private.

## Recommended next steps

1. Correct the GitHub token's repository selection/permissions and re-run the private repository-access check.
2. Resolve the PM review failure without bypassing the current retry or spending controls; make a founder decision only after the PM gate becomes ready.
3. After approved work and repository access exist, enable the dispatcher/runner, exercise one low-cost task under the active €8/month hard cap, and review the PR before any merge.
4. Verify the full QA/security evidence handoff and release readiness.
