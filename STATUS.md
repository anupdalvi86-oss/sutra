# Sutra Status

Updated: 2026-09-28 (Europe/Stockholm)

## What is working

- The production Railway `sutra-api` service is online. Deployment `7050454e-466e-462d-a9df-b47cd7e45e2e` for merged commit `68ab9ee` is active and marked successful. The deploy log records container startup and a successful `/health` request. The API remains private; no public service URL is configured.
- A fresh message from the configured founder account to `@sutra86bot` received a company status response. The response reported 3 projects, 3 open tasks and 2 pending approvals.
- Supabase project `smqsrigsugjuvuombetq` is reachable. The Codex runner claim column and restricted RPC exist, and migration `20260927224724_claim_codex_runner_lease` is recorded as applied.
- The founder proposal workflow has durable project/approval records. One €500 proposal is ready for the founder decision and another is still awaiting CFO review. Neither approval was changed; no €500 spend is authorized.
- The metered Codex runner is deployed but opt-in and currently disabled. Its database policy checks the approved route and budget, and its loopback proxy records completed Responses API token usage before returning it to Codex. It can open PRs but cannot merge or deploy.

## Deployment

- Railway project: `valiant-liberation`, production environment.
- API service: `sutra-api`, private, online; active deployment ID above.
- Hermes service: `sutra` with persistent volume; previously observed online. Its API remains private.
- Telegram: founder-only bot responds to the configured founder account.
- Supabase: migrations through the runner claim are applied.
- GitHub: repository `anupdalvi86-oss/sutra`; PR #65 merged. CI deployment is active.

## Checks performed

- Local Python suite: `python3 -m pytest -q` — 102 passed.
- GitHub CI on PR #65: Python, database/pgTAP, container build and secret scan all passed.
- `python3 -m bandit -q -r sutra`: no medium or high findings; four low-severity notices relate to subprocess use in the opt-in task runner.
- Python compile check and `git diff --check` passed.
- Supabase connectivity and the new migration objects verified with a live read-only SQL query.
- Railway deploy success, container startup and `/health` were verified in Railway. Telegram status command was verified after deployment.
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
2. Merge the private PR/CI polling change and keep the API private.
3. Set the exact model pricing profile and monthly cap in Supabase, then enable the runner only after its health/readiness checks pass.
4. Submit one low-cost founder-approved test task, verify the cost reservation and audit trail, and review the resulting PR before any merge.
5. Verify the full QA/security evidence handoff and release readiness. Keep the €500 product proposal pending founder review; it is separate from engineering execution.
