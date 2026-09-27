# Deployment

## Supabase database

1. Install the Supabase CLI and Docker.
2. For local development, run `supabase start`, `supabase db reset`, `supabase test db`, and `supabase db lint --local --level error`.
3. Hosted migration history includes the operational foundation (`20260927012437`), agent worker (`20260927025955`), spend ledger (`20260927025959`), founder-controlled model costs (`20260927061227`), spend-gated Hermes worker (`20260927063326`), GitHub approved-task dispatch (`20260927065915`), signed PR/CI evidence (`20260927072312`), Developer completion guard (`20260927073600`), persistent QA/Security evidence gate (`20260927075736`), review-evidence FK indexes (`20260927080205`), and the leased QA/Security worker queue (`20260927082100`). PR #19 CI passed all four jobs, including 115 pgTAP assertions, before the review gate was applied. Live checks confirmed the review table has RLS enabled with no direct `anon`, `authenticated`, or `service_role` SELECT; the submission RPC is callable only by `service_role`; and both Developer and QA/Security completion triggers are installed. PR #20 passed all CI jobs and its additive indexes were then applied. PR #22 passed all CI jobs with the worker queue and QA → Security → DevOps workflow, then its migration was applied. Live checks confirmed the queue RPC is service-role-only, the review table has RLS on and no direct service-role reads, and there are zero review rows/runs. The Supabase CLI is not linked on this workstation; authenticate and compare versions before using `supabase db push` to avoid reapplying them. The project service credential must stay in server-side Railway variables.
4. The Supabase organization is on the free plan and the dashboard displays a grace-period warning; no backup/recovery point was visible during rollout. Establish and test a recovery path before future production schema changes.
5. Confirm the founder Telegram ID, review default policies, and only then enable Telegram founder commands.

Every public company table has RLS enabled. `anon` and `authenticated` have no table access. The service role has no direct write access to budgets, spending policies, company settings, expenses, approvals or audit records; use the explicit audited RPC functions.

## Railway services

Production Railway project `valiant-liberation` contains two private services connected to `anupdalvi86-oss/sutra` on `main`. Both were observed Online on 2026-09-27. The API deployment's `/health` check returned HTTP 200. That endpoint confirms process availability only; it does not verify external integrations. No service has public networking enabled and no public API URL exists.

| Service | Config | Volume | Allowed secrets |
| --- | --- | --- | --- |
| Hermes (`sutra`) | Repository-root `Dockerfile`, `railway.json` | `sutra-volume` mounted at `/opt/data` (default 0.5 GB) | Model provider credentials; API server key only when the private API is intentionally enabled |
| Sutra API (`sutra-api`) | Railway root directory `/sutra`, `Dockerfile` | None | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_FOUNDER_USER_ID`, `SUTRA_INTERNAL_TOKEN`, `HERMES_HEALTH_URL`, `HERMES_AGENT_API_URL`, `HERMES_AGENT_API_KEY`, `SUTRA_HERMES_PROVIDER`, `SUTRA_HERMES_MODEL`, optional `GITHUB_TOKEN`, `GITHUB_WEBHOOK_SECRET`, `GITHUB_REPOSITORY` |

Railway currently lists volume storage at `$0.15/GB-month`; 0.5 GB would cost at most about `$0.08/month` if the full allocation is used. The attached volume is required because Hermes state is stored under `/opt/data`. The API image is built by `sutra/Dockerfile`; do not select the old/nonexistent `Dockerfile.api` path.

The API's health probe is `/health`, and the API service listens on port 8080. Keep it private until the authenticated interface and deployment controls are fully verified. Railway's Hermes logs reported that its optional API server is network-accessible and uses the local terminal backend. Hermes itself is private; do not expose this endpoint publicly. The Sutra worker stays disabled until its private API key, exact route and founder-approved model price profile are configured. Review this warning before enabling agent calls.

Set a random independent `SUTRA_INTERNAL_TOKEN` on the API service. The token protects the narrow private API endpoints; do not give it to the language model. The API must not share the Supabase service-role key with Hermes. Set `SUTRA_ENABLE_TELEGRAM=true` only after the database founder identity matches the intended founder.

The Hermes image pins the inspected upstream digest, preserves the root s6 entrypoint so it can prepare the volume and drop privileges, and starts `gateway run`. A build-time patch makes the OpenAI-compatible endpoint pass a validated `max_tokens` cap into Hermes and honors `require_model_lock` so the selected provider/model cannot fall back. CI verifies that patch against the pinned source. Attach the persistent volume to `/opt/data`; restart-on-failure is configured. Sutra's startup script forces the API-server platform off unless `SUTRA_HERMES_API_ENABLED=true` is explicitly set, constrains its toolset to `web`, and caps reviews at three agent turns, one provider attempt per model iteration, and zero automatic recovery cycles. The API server binds to loopback by default; set `API_SERVER_HOST=0.0.0.0` only when deliberately enabling private Railway networking, and always require an API key. Model profiles set per-completion token ceilings; database reservation and reconciliation account for all three possible model iterations. The worker calls database preflight, reserve, begin, and usage-reconciliation RPCs for every run. Pending approvals make no provider request; missing or invalid usage retains the full reserve and prevents run success. When the proposal queue is idle, it claims ready QA/Security tasks only if the Developer ancestor has a merged PR and successful same-SHA CI. It validates evidence against task criteria and submits it through the guarded review RPC. The live Supabase project has zero active model profiles, so this path remains fail-closed until the founder configures an exact route and database price/token profile. The `/health` endpoint reports database, Telegram, Hermes and worker state. Keep `SUTRA_ENABLE_AGENT_WORKER=false` until all secrets, exact provider/model route, active database profile, and deployment health are verified. To enable Hermes later, set `SUTRA_HERMES_API_ENABLED=true`, `API_SERVER_HOST=0.0.0.0`, and a strong `API_SERVER_KEY` only on Hermes, then set the matching `HERMES_AGENT_API_KEY`, private `HERMES_AGENT_API_URL`, `SUTRA_HERMES_PROVIDER`, and `SUTRA_HERMES_MODEL` on Sutra API.

The GitHub task dispatcher is independently opt-in (`SUTRA_ENABLE_GITHUB_DISPATCHER=false` by default). To enable it, add a fine-grained GitHub token with only Issues read/write and Metadata read access for `GITHUB_REPOSITORY`, then set those values on Sutra API. Supabase claims only ready Developer tasks from approved/active projects, leases each dispatch, stores the resulting issue URL, starts the task, and writes an audit event. Stable task UUID markers let a recovered worker reuse an issue if GitHub accepted a create request before the database lease expired. Do not give this token to Hermes. The dispatcher creates issues only; it does not run Codex.

The signed webhook endpoint is `POST /webhooks/github`. Add a repository webhook for `pull_request` and `workflow_run` events, set its random webhook secret as `GITHUB_WEBHOOK_SECRET` on Sutra API, and use JSON content type. The service checks GitHub's SHA-256 signature and repository, stores deduplicated normalized events, and records PR/CI evidence in Supabase. A Developer task completes only after a PR closes as merged and the matching `CI` workflow succeeds on the same head SHA; the database also blocks generic task updates from bypassing this gate. QA and Security completion require persisted role-specific evidence through `/internal/task-review`, tied to that exact merged Developer SHA. Configure repository branch protection to require the `CI` checks for safe merges. GitHub currently denies branch-protection access for this private repository with HTTP 403 and requires GitHub Pro or public visibility; no repository webhook is registered yet.

Configure Railway to wait for successful GitHub CI before automatically deploying `main`. Verify the active deployment and its `/health` request in Railway logs after each release. Never make Hermes or the internal API publicly reachable.

## Telegram setup

Create/configure the founder bot using Telegram's normal BotFather flow, then place its token and the founder's numeric Telegram user ID only in Sutra API Railway variables. The founder numeric ID is already configured in Railway and registered in Supabase; the bot token and Supabase service-role key still need to be entered in Railway. Keep `SUTRA_ENABLE_TELEGRAM=false` until the API has restarted and its health response reports database and Telegram ready. The polling loop skips stale queued updates on startup, accepts only direct private founder messages, and records denied identity hashes without storing raw Telegram IDs.

The bot currently supports status, budgeted proposal, and explicit approval/rejection commands. It does not send campaigns or sales messages.

## Local API

```sh
cp .env.example .env
# Fill only local server-side values in .env.
SUTRA_BIND_HOST=127.0.0.1 python3 -m sutra.server
```

Do not place secrets in committed files, issue descriptions, agent inputs, Hermes state, or client-side code. The `.env` file is ignored by Git.
