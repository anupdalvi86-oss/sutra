# Deployment and operations

## Production overview

Production runs in Railway project `valiant-liberation` with two private services connected to `anupdalvi86-oss/sutra` on `main`:

| Service | Runtime | Persistent state | Secrets/config |
| --- | --- | --- | --- |
| `sutra` | Pinned, patched Hermes gateway | `sutra-volume` at `/opt/data` | Model provider credentials and its private API key |
| `sutra-api` | Python API/Telegram/worker on port 8080, built from `sutra/Dockerfile` | None | Supabase service-role, Telegram bot + founder ID, independent internal/Hermes credentials, GitHub token + webhook secret, worker configuration |

Both services were Online at the 2026-09-28 check. The API liveness probe is `/health`; `/ready` additionally checks Supabase and every enabled integration. When the agent worker is enabled, `/ready` requires both a running worker and a healthy private Hermes health endpoint. The API and Hermes endpoints are private; no public API URL is configured. Hermes has restart-on-failure and the mounted volume. Keep the Supabase service-role credential only on `sutra-api`.

Railway variables must be set in the service environment, not committed. API integration variables include `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_FOUNDER_USER_ID`, `SUTRA_INTERNAL_TOKEN`, `HERMES_AGENT_API_URL`, `HERMES_AGENT_API_KEY`, `HERMES_HEALTH_URL` (private Hermes `/health` URL), `SUTRA_HERMES_PROVIDER`, `SUTRA_HERMES_MODEL`, optional `SUTRA_HERMES_ROLE_ROUTES`, `GITHUB_TOKEN`, `GITHUB_WEBHOOK_SECRET`, `GITHUB_REPOSITORY`, and opt-in dispatcher/Codex settings. Hermes keeps its provider credentials separately. Never paste replacement secrets into Telegram, GitHub, logs, prompts, or this repository.

## Hermes and worker safety

Hermes uses a pinned upstream image and the persistent volume at `/opt/data`. Sutra's startup constrains the API toolset to `web`; it does not expose terminal, process, or file-write tools. Do not expand that toolset without a sandboxed backend. The private API always requires an API key. Model execution is locked to an active database price profile and bounded token/iteration limits. The worker reserves the profile maximum before provider calls and reconciles observed usage afterward. Approval-pending work makes no provider call. Unknown or out-of-profile usage fails closed and retains the full reservation.

Only an assigned in-progress task in an approved project can write a role artifact. After the Architect records a technical design, the Developer task remains blocked until the configured founder approves that exact task scope through Telegram. The database gates task release, GitHub dispatch and Codex authorization on that founder decision; approval is audit logged and does not grant spend or release authority. Marketing and Sales artifacts remain internal drafts. QA and Security require a merged Developer PR and successful CI evidence for the same SHA. The worker does not send sales or marketing messages, make payments, sign agreements, merge PRs, or deploy product releases.

## Supabase

The live project is `smqsrigsugjuvuombetq` in `eu-central-1`, PostgreSQL 17.6, status `ACTIVE_HEALTHY`. The last verified migration history contained 31 applied migrations through `20260928101448_founder_scope_design_context`. All public company tables observed have RLS enabled. `anon` and `authenticated` have no direct table access; consequential financial and governance writes go through restricted audited functions.

Live database defaults are configurable policy rows: automatic through €10, department head above €10 through €50, CFO + CEO above €50 through €200, and founder at/above €200. The €10–50 band fails closed until a department approver is assigned. A monthly €8 AI inference hard stop has an 80% warning threshold. Three project ceilings of €500 remain from repeated AI QA submissions; one project is approved, one duplicate is pending, and one was rejected. No total company operating budget is configured. See [STATUS.md](../STATUS.md) for exact workflow and ledger state.

The Supabase security advisor currently reports 22 informational `rls_enabled_no_policy` findings. These tables are intentionally closed to direct client roles; do not add broad client policies to silence the notice. The performance advisor reports 21 unused indexes on this early-stage database. Review future advisor output before any schema/index change. Main CI applies migrations, executes pgTAP and runs database lint. A previous local Supabase Docker attempt stopped when the Docker VM ran out of storage; the hosted CI database checks pass.

## GitHub and Codex

The repository is public, so an anonymous repository GET alone does not prove token identity. The configured Railway token was separately verified through GitHub `/user` and the GitHub settings page: only Sutra is selected, with Metadata read, Issues read/write, Contents read/write, Pull Requests read/write and Actions read. It has no repository Administration permission. Keep `SUTRA_ENABLE_GITHUB_DISPATCHER` and `SUTRA_ENABLE_CODEX_RUNNER` disabled until the founder confirms a concrete Developer scope.

The dispatcher creates/reuses a GitHub issue for an approved Developer task and audits the handoff. The metered Codex runner verifies signed issue content, obtains a one-time database claim and can push a task branch/open a PR; it cannot merge or deploy. It uses the database price profile, spend authorization, and metering proxy for provider calls. PR/CI evidence must match the same SHA before Developer completion; persistent QA and Security reviews follow. The webhook endpoint is `POST /webhooks/github`; it validates the SHA-256 signature and repository. Railway's API can remain private when its server-side GitHub poller is used.

PRs #97–#99 are merged. Required CI passed Python, database/pgTAP/lint, container, and secret-scanning jobs. See [STATUS.md](../STATUS.md) for current proof and outstanding gates.

## Telegram

Founder interface: [@sutra86bot](https://t.me/sutra86bot). Production startup validates the bot identity and the registered founder ID. The bot only accepts one-to-one messages from the configured founder. The approval list and status reads are audit logged; approval/rejection actions are founder-only audited operations. The bot supports status, proposal intake, approval listing/decisions, and bounded recovery commands.

Use `CEO, give me company status.` for a board-style company report. Other roles accept `ROLE, give me department status.`. The report is sourced from persisted projects, tasks, blockers, approvals, and financial controls. `CEO, show my approvals.` lists founder decisions ready or pending. Campaign and sales drafting is internal only. Rotate credentials previously shared in chat after validation and replace them directly in their private Railway variables.

## Local development and verification

Python 3.12+:

```sh
python3 -m unittest discover -s tests -v
python3 -m compileall -q sutra tests
python3 -m bandit -q -r sutra -ll
```

With Docker and Supabase CLI, discover command options using `supabase --help`, then run local migrations, `supabase test db`, and database lint. CI runs the hosted migration/pgTAP/lint workflow. For the API, copy `.env.example` to `.env`, add only local server-side values, then run `SUTRA_BIND_HOST=127.0.0.1 python3 -m sutra.server`. `.env` is ignored by Git. Never commit credentials or tokens.
