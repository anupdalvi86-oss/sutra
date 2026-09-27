# Sutra Status

Updated: 2026-09-28 (Europe/Stockholm)

## What is working

- The production Railway `sutra-api` service is online; the Railway dashboard marks the current deployment successful. The API remains private, with no public application URL. [Open the Railway service](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce).
- A fresh message from the configured founder account to `@sutra86bot` received a company status response. The response reported 3 projects, 3 open tasks and 2 pending approvals.
- Supabase project `smqsrigsugjuvuombetq` is reachable. The Codex runner claim column and restricted RPC exist, and migration `20260927224724_claim_codex_runner_lease` is recorded as applied.
- The founder proposal workflow has durable project/approval records. One €500 proposal is ready for the founder decision and another is still awaiting CFO review. Neither approval was changed; no €500 spend is authorized.
- The metered Codex runner is deployed but opt-in and currently disabled. Its database policy checks the approved route and budget, and its loopback proxy records completed Responses API token usage before returning it to Codex. It can open PRs but cannot merge or deploy.

## Deployment

- Railway project: `valiant-liberation`, production environment.
- API service: `sutra-api`, private and online; deployment state is shown in the Railway link above.
- Hermes service: `sutra` online with its persistent volume; its API remains private.
- Telegram: founder-only bot responds to the configured founder account.
- Supabase: migrations through the runner claim are applied.
- GitHub: repository `anupdalvi86-oss/sutra`; PRs #65–#68 merged. Python, database/pgTAP, container and secret-scan CI checks passed.

## Checks performed

- Local Python suite after private evidence polling: `python3 -m pytest -q` — 105 passed.
- GitHub CI on PR #67 and PR #68: Python, database/pgTAP, container build and secret scan all passed.
- `python3 -m bandit -q -r sutra`: no medium or high findings; four low-severity notices relate to subprocess use in the opt-in task runner.
- Python compile check and `git diff --check` passed.
- Supabase connectivity, all requested core tables, the one-time runner claim RPC, and no direct `anon`/`authenticated` access were verified with live read-only SQL queries. `customers.status='lead'` represents leads in the same lifecycle table.
- Railway's current release is marked successful and both services are online. Telegram status command was verified after the current release and returned 3 projects, 3 open tasks, and 2 pending approvals.
- Supabase security advisor reports 22 informational `rls_enabled_no_policy` findings. Tables intentionally have RLS enabled and no end-user policies; direct client grants are revoked and company writes use restricted server-side RPCs. Recheck if direct client access is introduced.

## Remaining blockers

1. The live Codex/GitHub execution path is not enabled. The private Railway `sutra-api` does not have `OPENAI_API_KEY`, `GITHUB_TOKEN`, or `GITHUB_WEBHOOK_SECRET`; `SUTRA_ENABLE_CODEX_RUNNER` remains false. The user-provided OpenAI key was authorized for the separate Hermes service only, not for transfer to `sutra-api`.
2. A repo-scoped GitHub token is needed for the runner to read approved issues, push task branches, create PRs and poll CI. It should have only Metadata read, Contents read/write, Issues read, Pull requests read/write, and Actions read for this repository.
3. Private PR/CI evidence polling is included in the current Railway release. It remains dormant until the Codex runner is configured and enabled. This keeps the API private; direct webhook ingress is optional.
4. The current local machine did not have enough Docker disk space for a local Supabase container test. Hosted Supabase pgTAP passed in CI.

## Credentials / integrations still required

- Authorization to copy the already supplied OpenAI key from Railway service `sutra` to Railway service `sutra-api`, or a separate limited key entered directly into Railway for that service.
- A fine-grained GitHub token with the repository-only permissions above. Do not reuse or expose the local `gh` credential.
- A random `GITHUB_WEBHOOK_SECRET` for signing founder-approved task issues. Direct webhook delivery is optional; the private poller is preferred and needs no public ingress.
- Keep the Telegram, Supabase and model credentials private. Rotate the keys previously pasted into chat after verification is complete.

## Recommended next steps

1. Provide/authorize the `sutra-api` OpenAI credential and repository-scoped GitHub token.
2. The private PR/CI polling change is merged; keep the API private.
3. The exact model profiles and €8/month hard cap are already active in Supabase. Enable the runner only after its health/readiness checks pass.
4. Submit one low-cost founder-approved test task, verify the cost reservation and audit trail, and review the resulting PR before any merge.
5. Verify the full QA/security evidence handoff and release readiness. Keep the €500 product proposal pending founder review; it is separate from engineering execution.
