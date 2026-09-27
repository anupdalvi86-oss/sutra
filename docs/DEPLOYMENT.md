# Deployment

## Supabase database

1. Install the Supabase CLI and Docker.
2. For local development, run `supabase start`, `supabase db reset`, `supabase test db`, and `supabase db lint --local --level error`.
3. Hosted migration history includes the operational foundation (`20260927012437`), agent worker (`20260927025955`), spend ledger (`20260927025959`), and founder-controlled model costs (`20260927061227`). The migrations were applied through the authenticated Supabase connector after CI passed. The Supabase CLI is not linked on this workstation; authenticate and compare versions before using `supabase db push` to avoid reapplying them. The project service credential must stay in server-side Railway variables.
4. The Supabase organization is on the free plan and the dashboard displays a grace-period warning; no backup/recovery point was visible during rollout. Establish and test a recovery path before future production schema changes.
5. Confirm the founder Telegram ID, review default policies, and only then enable Telegram founder commands.

Every public company table has RLS enabled. `anon` and `authenticated` have no table access. The service role has no direct write access to budgets, spending policies, company settings, expenses, approvals or audit records; use the explicit audited RPC functions.

## Railway services

The current Railway deployment is Hermes-only and remains connected to `praveen-ks-2001/hermes-agent-template`, not this repository. Railway must be granted access to the private Sutra repository in its GitHub integration before it can deploy Sutra. The last observed plan panel was near its `$5` included usage credit (`$1.54` current, `$4.81` estimated); recheck usage and plan before creating a second service:

| Service | Config | Volume | Allowed secrets |
| --- | --- | --- | --- |
| Hermes Agent | Root `railway.json`, `Dockerfile` | `/opt/data` | Model provider credentials; `API_SERVER_KEY` only if its optional API is enabled |
| Sutra API | `railway.api.json`, `Dockerfile.api` | None | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_FOUNDER_USER_ID`, `SUTRA_INTERNAL_TOKEN`, `HERMES_HEALTH_URL`, `HERMES_AGENT_API_URL`, `HERMES_AGENT_API_KEY`, `SUTRA_HERMES_PROVIDER`, `SUTRA_HERMES_MODEL` |

Set a random independent `SUTRA_INTERNAL_TOKEN` on the API service. The token protects the narrow private API endpoints; do not give it to the language model. The API must not share the Supabase service-role key with Hermes. Set `SUTRA_ENABLE_TELEGRAM=true` only after the database founder identity matches the intended founder.

The Hermes image pins the inspected upstream digest, preserves the root s6 entrypoint so it can prepare the volume and drop privileges, and starts `gateway run`. A build-time patch makes the OpenAI-compatible endpoint pass a validated `max_tokens` cap into Hermes and honors `require_model_lock` so the selected provider/model cannot fall back. CI verifies that patch against the pinned source. Attach the persistent volume to `/opt/data`; restart-on-failure is configured. Sutra's startup script forces API-server turns to at most three iterations, one provider attempt per model iteration, and zero automatic recovery cycles. Model profiles set per-completion token ceilings; database reservation and reconciliation account for all three possible model iterations. The worker calls database preflight, reserve, begin, and usage-reconciliation RPCs for every run. Pending approvals make no provider request; missing or invalid usage retains the full reserve and prevents run success. The `/health` endpoint reports database, Telegram, Hermes and worker state. Keep `SUTRA_ENABLE_AGENT_WORKER=false` until all secrets, exact provider/model route, active database profile, and deployment health are verified. To enable it later, set `API_SERVER_ENABLED=true` and `API_SERVER_KEY` only on Hermes, then set the matching `HERMES_AGENT_API_KEY`, private `HERMES_AGENT_API_URL`, `SUTRA_HERMES_PROVIDER`, and `SUTRA_HERMES_MODEL` on Sutra API.

For the API Railway service, configure `/health` as the deployment health check. The Hermes container uses the upstream runtime and may not expose a public health endpoint; do not route public traffic to its unauthenticated internal API. Check its Railway logs and upstream gateway status directly.

No Railway service or secret is created automatically by this repository. Creating a second service can consume paid resources, so verify the existing plan/usage before deploying.

## Telegram setup

Create/configure the founder bot using Telegram's normal BotFather flow, then place its token and the founder's numeric Telegram user ID only in Sutra API Railway variables. Keep `SUTRA_ENABLE_TELEGRAM=false` until the migration has been applied and founder identity registration is verified. The polling loop skips stale queued updates on startup, accepts only direct private founder messages, and records denied identity hashes without storing raw Telegram IDs.

The bot currently supports status, budgeted proposal, and explicit approval/rejection commands. It does not send campaigns or sales messages.

## Local API

```sh
cp .env.example .env
# Fill only local server-side values in .env.
SUTRA_BIND_HOST=127.0.0.1 python3 -m sutra.server
```

Do not place secrets in committed files, issue descriptions, agent inputs, Hermes state, or client-side code. The `.env` file is ignored by Git.
