# Sutra Status

Updated: 2026-09-28 (Europe/Stockholm)

## What is working

- Railway production `sutra-api` is online and the latest `/ready` check returned `ready: true`. The service stays private; there is no public application URL. [Open the Railway service](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce).
- `/ready` reports Supabase reachable, Telegram running, and the agent worker running. The GitHub dispatcher and Codex runner are disabled.
- A fresh founder-account message to `@sutra86bot` received the expected company-status reply: 3 projects, 3 open tasks, and 2 pending approvals. Telegram `getMe` also confirmed the configured bot identity.
- Private Railway `sutra-api` variables now include `GITHUB_TOKEN`, `GITHUB_WEBHOOK_SECRET`, and the existing Hermes `OPENAI_API_KEY`. Secret values are not stored in this repository or this status file.
- Supabase project `smqsrigsugjuvuombetq` is reachable. The runner claim column and restricted RPC exist, and migration `20260927224724_claim_codex_runner_lease` is recorded as applied.
- Three durable proposals and two pending €500 budget approvals are recorded. One proposal is ready for founder decision; another is waiting for CFO review. No approval or project spend was authorized.
- The metered Codex runner is deployed but opt-in. It checks approved routes and budgets, records completed Responses API usage through a loopback proxy, and can open PRs but cannot merge or deploy.

## Deployment

- Railway project: `valiant-liberation`, production environment.
- API service: `sutra-api`, private and online; current readiness check passed.
- Hermes service: `sutra` online with its persistent volume; its API remains private.
- Telegram: founder-only bot responds to the configured founder account.
- Supabase: migrations through the runner claim are applied.
- GitHub: repository `anupdalvi86-oss/sutra`; PRs #65–#70 merged. Python, database/pgTAP, container build and secret-scan CI checks passed.

## Checks performed

- Local Python suite after private evidence polling: `python3 -m pytest -q` — 105 passed.
- GitHub CI on PRs #67 and #68: Python, database/pgTAP, container build and secret scan all passed.
- `python3 -m bandit -q -r sutra`: no medium or high findings; four low-severity notices relate to subprocess use in the opt-in task runner.
- Python compile check and `git diff --check` passed.
- Live read-only Supabase checks verified connectivity, core tables, the one-time runner claim RPC, no direct `anon`/`authenticated` access, project/task counts, and pending approvals. `customers.status='lead'` represents leads in the same lifecycle table.
- Live GitHub API validation with the supplied token returned HTTP 404 for the private Sutra repository. The local GitHub CLI session can see the repository, but that session's credential was not copied into the service.
- Supabase security advisor reports 22 informational `rls_enabled_no_policy` findings. Tables intentionally have RLS enabled and no end-user policies; direct client grants are revoked and company writes use restricted server-side RPCs. Recheck if direct client access is introduced.

## Remaining blockers

1. The supplied GitHub token is configured but GitHub does not expose the private Sutra repository to it (HTTP 404). Confirm the token targets `anupdalvi86-oss/sutra`, then grant Metadata read, Contents read/write, Issues read, Pull requests read/write, and Actions read for this repository. The runner is not enabled.
2. Three projects are proposed and all three tasks are blocked. One €500 project-budget approval is ready for founder decision; another remains with CFO. A request to prepare a proposal is not approval to spend.
3. The full engineering handoff (approved task → GitHub branch/PR → CI evidence → QA/security/release readiness) has not been exercised live. It requires repository access and an approved task.
4. The current local machine did not have enough Docker disk space for a local Supabase container test. Hosted Supabase pgTAP passed in CI.

## Credentials / integrations still required

- A GitHub fine-grained token with access to this private repository and the repository permissions above. Keep using the local `gh` credential only for normal repository operations; do not copy it into Railway.
- Founder review of the ready €500 approval through Telegram if that project is intended to proceed. The second proposal requires CFO review first.
- Rotate the credentials previously pasted into chat after integration verification is complete. Keep all Railway values private.

## Recommended next steps

1. Correct the GitHub token's repository selection/permissions and re-run the private repository-access check.
2. Decide in Telegram whether to approve the ready project budget; leave it pending if no spend is intended.
3. After approved work and repository access exist, enable the dispatcher/runner, exercise one low-cost task under the active €8/month hard cap, and review the PR before any merge.
4. Verify the full QA/security evidence handoff and release readiness.
