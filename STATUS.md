# Sutra Status

Updated: 2026-09-28 (Europe/Stockholm)

## What is working

- Railway production `sutra-api` is online and reports `ready: true`. A direct probe from its Railway console returned HTTP 200. The readiness response showed Supabase reachable, Telegram running, and the agent worker running. The service is private; there is no public application URL. [Open the Railway service](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce).
- The production `sutra` Hermes service is online with its persistent Railway volume. Its API remains private.
- Telegram founder interface `@sutra86bot` works for the configured founder account. Status and approval-queue commands were exercised in the founder's logged-in session.
- The proposal review workflow completed in production for the AI QA opportunity: CEO → CPO → CTO → CFO → Product Manager. Each stage persisted a successful run and role artifact. The CPO retry used the founder-only recovery command on attempt 2 of the existing 3-attempt bound; its action was audit logged.
- The PM result is a research-only opportunity assessment. The €500 project budget remains only a proposed maximum, not spending authorization. The project is still proposed and its approval is pending founder decision. Telegram says it is ready for a decision. No project expense or development work has been authorized.
- Database spending controls remain authoritative and configurable. Current defaults are a €8 monthly AI inference hard cap with an 80% warning threshold. The current-month model ledger reports €0.15 reconciled actual usage and €0.31 retained as unknown-usage reservations.
- Supabase project `smqsrigsugjuvuombetq` is reachable. Migration `20260928012624_founder_retry_failed_review_stage` is applied. Direct `anon`/`authenticated` table access remains revoked; consequential operations use restricted RPCs.
- Railway has the current founder-provided GitHub token and webhook secret in private service variables. The repository token still grants access to zero repositories (service-side private-repository check returned 404). The GitHub settings page has the Sutra-only permission grant staged, but its final action-time confirmation is still outstanding.
- GitHub issue/PR evidence handling and the metered Codex runner are implemented. The GitHub dispatcher and Codex runner remain disabled until repository access is verified and a founder-approved task is ready.

## Deployment

- Railway project: `valiant-liberation`, production environment.
- API service: `sutra-api`, private, online. Railway reports PR #84 deployed successfully. The live `/ready` probe returned HTTP 200 and `ready: true` after deployment. Founder-provided GitHub token and webhook secret are stored in private variables; the repository permission grant remains unverified.
- Hermes service: `sutra`, online with persistent volume.
- Telegram: `@sutra86bot`, founder-only; successful status, retry, and approval-queue messages verified.
- Supabase: reachable; migrations through `20260928012624_founder_retry_failed_review_stage` are applied.
- GitHub: `anupdalvi86-oss/sutra`; PR #83 merged. The updated PR CI passed Python, database/pgTAP/lint, container and secret-scan jobs.

## Checks performed

- `python3 -m pytest -q` on merged `main`: 111 passed.
- `python3 -m compileall -q sutra tests`: passed.
- `python3 -m bandit -ll -q -r sutra`: passed with no medium/high findings. Four low-severity notices remain in the opt-in Codex runner for bounded subprocess execution; one existing `nosec` annotation is reported as not needed by the current Bandit version.
- `git diff --check`: passed.
- GitHub Actions runs for PRs #83 and #84 passed Python, database/pgTAP/lint, containers and secret scanning.
- Live Supabase checks verified the retry RPC exists, the configured founder identity matches, the retry audit entry exists, all five proposal-review runs succeeded, the €500 approval is still pending, and no project spend was authorized.
- Live Supabase spending ledger after the workflow: €0.15 reconciled actual usage; €0.31 remains reserved because prior provider usage could not be verified. The €8 monthly hard cap remains active.
- Supabase security advisor reports 22 informational `rls_enabled_no_policy` findings. The company tables have RLS enabled, no user-facing policies, and direct client grants revoked; writes go through restricted server RPCs. Performance advisor reports unused indexes on lightly used/early-stage tables.
- Railway console probe of `http://127.0.0.1:8080/ready` returned HTTP 200 with database, Telegram and agent worker healthy; GitHub webhook configured; GitHub dispatcher and Codex runner disabled.
- Earlier attempt to run the local Supabase Docker stack failed because the Docker VM ran out of storage while pulling images. Hosted PostgreSQL migration, pgTAP and lint jobs pass in CI.

## Remaining blockers

1. **Founder project decision:** Telegram now presents the AI QA opportunity's €500 budget proposal as ready for your decision. Approve or reject it in Telegram. Approval is not automatic, and approving the proposed ceiling does not itself authorize an individual expense beyond the configured spending policy.
2. **GitHub repository permission:** the Railway token currently has no repository grant. The one-repository grant for `anupdalvi86-oss/sutra` is staged in GitHub with the runner's minimum permissions. Confirm the exact permission update in the open GitHub browser session, then verify the Railway service can access the repository. Until then, the dispatcher and Codex runner stay disabled.
3. **Engineering-to-release workflow:** after a founder-approved project/task and verified GitHub access, enable the gated dispatcher/runner for one low-cost task, then validate PR → CI → QA → security → release readiness. No real sales or marketing messages have been sent.
4. **Credential hygiene:** rotate the credentials previously shared in chat after verification is complete, then update only the corresponding private Railway variables. Secret values are not in this repository.

## Recommended next steps

1. Review the AI QA research assessment and choose approve or reject in the Telegram approval queue.
2. In GitHub's open fine-grained-token editor, save the staged Sutra-only permission grant and verify private repo access from Railway.
3. Only after those two gates, enable the GitHub dispatcher and Codex runner for one explicitly approved task and exercise the engineering/QA/security handoff.
4. Rotate the exposed credentials and update the relevant Railway private variables.
