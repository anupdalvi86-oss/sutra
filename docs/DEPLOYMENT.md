# Deployment and operations

## Production overview

Production runs in Railway project `valiant-liberation` with two private services connected to `anupdalvi86-oss/sutra` on `main`:

| Service | Runtime | Persistent state | Secrets/config |
| --- | --- | --- | --- |
| `sutra` | Pinned, patched Hermes gateway | `sutra-volume` at `/opt/data` | Model provider credentials and its private API key |
| `sutra-api` | Python API/Telegram/worker on port 8080, built from `sutra/Dockerfile` | None | Supabase service-role, Telegram bot + founder ID, independent internal/Hermes credentials, GitHub token + webhook secret, worker configuration |

Both services are Online. The PR #117 code deployment and the later CPO-route deployment completed successfully on 2026-09-28; the route deployment health check returned HTTP 200 from `/health`. The API liveness probe is `/health`; `/ready` additionally checks Supabase and every enabled integration. When the agent worker is enabled, `/ready` requires both a running worker and a healthy private Hermes health endpoint. The API and Hermes endpoints are private; no public API URL is configured. Hermes has restart-on-failure and the mounted volume. Keep the Supabase service-role credential only on `sutra-api`.

Railway variables must be set in the service environment, not committed. API integration variables include `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_FOUNDER_USER_ID`, `SUTRA_INTERNAL_TOKEN`, `HERMES_AGENT_API_URL`, `HERMES_AGENT_API_KEY`, `HERMES_HEALTH_URL` (private Hermes `/health` URL), `SUTRA_HERMES_PROVIDER`, `SUTRA_HERMES_MODEL`, optional `SUTRA_HERMES_ROLE_ROUTES`, `GITHUB_TOKEN`, `GITHUB_WEBHOOK_SECRET`, `GITHUB_REPOSITORY`, and opt-in dispatcher/Codex settings. Hermes keeps its provider credentials separately. Never paste replacement secrets into Telegram, GitHub, logs, prompts, or this repository.

## Hermes and worker safety

Hermes uses a pinned upstream image and the persistent volume at `/opt/data`. Sutra's startup constrains the API toolset to `web`; it does not expose terminal, process, or file-write tools. Do not expand that toolset without a sandboxed backend. The private API always requires an API key. Model execution is locked to an active database price profile and bounded token/iteration limits. The worker reserves the profile maximum before provider calls and reconciles observed usage afterward. Approval-pending work makes no provider call. Unknown or out-of-profile usage fails closed and retains the full reservation. Missing or malformed usage emits only an allowlisted provider/model label and token-field shape; token counts and raw provider response content are not logged.

Only an assigned in-progress task in an approved project can write a role artifact. After the Architect records a technical design, the Developer task remains blocked until the configured founder approves that exact task scope through Telegram. The database gates task release, GitHub dispatch and Codex authorization on that founder decision; approval is audit logged and does not grant spend or release authority. Marketing and Sales artifacts remain internal drafts. By founder direction, QA and Security role handoffs are deferred for later implementation; the current path requires successful CI for the same PR commit and does not authorize a merge or release. The worker does not send sales or marketing messages, make payments, sign agreements, merge PRs, or deploy product releases.

## Supabase

The live project is `smqsrigsugjuvuombetq` in `eu-central-1`, PostgreSQL 17.6, status `ACTIVE_HEALTHY`. The last verified migration history contained 32 applied migrations, including `persist_github_permission_denied`. Its bounded GitHub dispatch health RPC is executable only by `service_role`; production checks confirmed `anon` and `authenticated` cannot execute it. All public company tables observed have RLS enabled. `anon` and `authenticated` have no direct table access; consequential financial and governance writes go through restricted audited functions.

Live database defaults are configurable policy rows: automatic through €10, department head above €10 through €50, CFO + CEO above €50 through €200, and founder at/above €200. The €10–50 band fails closed until a department approver is assigned. A monthly €8 AI inference hard stop has an 80% warning threshold. Three project ceilings of €500 remain from repeated AI QA submissions; one project is approved, one duplicate is pending, and one was rejected. No total company operating budget is configured. Railway currently routes CPO only to `kimi-coding:kimi-k2.6`; other agent roles use OpenAI GPT-6 Luna. No post-rollout CPO usage reconciliation has been verified, and an earlier €0.28 unknown Kimi reserve remains held. See [STATUS.md](../STATUS.md) for exact workflow and ledger state.

The Supabase security advisor currently reports 22 informational `rls_enabled_no_policy` findings. These tables are intentionally closed to direct client roles; do not add broad client policies to silence the notice. The performance advisor reports 21 unused indexes on this early-stage database. Review future advisor output before any schema/index change. Main CI applies migrations, executes pgTAP and runs database lint. A previous local Supabase Docker attempt stopped when the Docker VM ran out of storage; the hosted CI database checks pass.

## GitHub and Codex

The repository is public, so an anonymous repository GET alone does not prove token identity. The latest verified GitHub settings page has only Sutra selected, with Metadata read, Issues read/write, Contents read/write, Pull Requests read/write and Actions read; the token has no repository Administration permission. After the founder updated token access, production verified and signed the existing issue #107 and checked out the repository for the already-approved task. The latest Codex attempt stopped before any provider request because the CLI was not pinned to the metering proxy. That routing fix is being validated before any further founder-authorized attempt. Do not enable broader permissions as a workaround.

The dispatcher creates/reuses a GitHub issue for an approved Developer task and audits the handoff. The metered Codex runner verifies signed issue content, obtains a one-time database claim and can push a task branch/open a PR; it cannot merge or deploy. For every run it writes a private `$CODEX_HOME/config.toml` that selects the custom `sutra_metered` Responses provider and the loopback proxy URL. `OPENAI_BASE_URL` alone is not sufficient to route Codex CLI traffic. The child receives only a dummy `OPENAI_API_KEY`; its model requests must reach the metering proxy, which applies the live database price profile and request authorization before forwarding them with the server-held key. WebSocket and automatic request retries are disabled so each admitted request is explicitly metered. PR/CI evidence must match the same SHA before Developer completion. QA and Security work is deferred by founder direction. The webhook endpoint is `POST /webhooks/github`; it validates the SHA-256 signature and repository. Railway's API can remain private when its server-side GitHub poller is used.

Railway API logs provide bounded Codex runner diagnostics (`codex_issue_rejected`, `codex_task_authorization_not_ready`, `codex_task_claim_rejected`, and `codex_runner_cycle_failed`). Exception text, issue bodies, credentials, and model prompts are excluded. Set `SUTRA_LOG_LEVEL` to adjust process log verbosity; the default is `INFO`.

PR #117 CI and main run [36463003360](https://github.com/anupdalvi86-oss/sutra/actions/runs/36463003360) passed; checks include Python, database/pgTAP/lint, container/runtime, and secret scanning. See [STATUS.md](../STATUS.md) for current proof and outstanding gates.

## Telegram

Founder interface: [@sutra86bot](https://t.me/sutra86bot). Production startup validates the bot identity and the registered founder ID. The bot only accepts one-to-one messages from the configured founder. The approval list and status reads are audit logged; approval/rejection actions are founder-only audited operations. The bot supports status, proposal intake, approval listing/decisions, and bounded recovery commands.

Use `CEO, give me company status.` for a board-style company report. Other roles accept `ROLE, give me department status.`. The report is sourced from persisted projects, tasks, blockers, approvals, and financial controls. `CEO, show my approvals.` lists founder decisions ready or pending. `retry GitHub dispatch <task-id>` requeues only an exhausted permission-denied dispatch for the same founder-approved Developer task, with a three-cycle lifetime bound and an audit record. `retry Codex task <task-id>` permits one founder-audited retry only when database metering proves no provider request or token usage occurred; it preserves the old unknown reservation and creates a new spend-policy-checked reservation. Campaign and sales drafting is internal only. Rotate credentials previously shared in chat after validation and replace them directly in their private Railway variables.

## Local development and verification

Python 3.12+:

```sh
python3 -m unittest discover -s tests -v
python3 -m compileall -q sutra tests
python3 -m bandit -q -r sutra -ll
```

With Docker and Supabase CLI, discover command options using `supabase --help`, then run local migrations, `supabase test db`, and database lint. CI runs the hosted migration/pgTAP/lint workflow. For the API, copy `.env.example` to `.env`, add only local server-side values, then run `SUTRA_BIND_HOST=127.0.0.1 python3 -m sutra.server`. `.env` is ignored by Git. Never commit credentials or tokens.
