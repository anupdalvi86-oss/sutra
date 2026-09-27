# Deployment

## Supabase database

1. Install the Supabase CLI and Docker.
2. For local development, run `supabase start`, `supabase db reset`, `supabase test db`, and `supabase db lint --local --level error`.
3. For the existing `sutra` project, verify the project ref and database backup/recovery path before applying the additive migration. Link with the Supabase CLI and run `supabase db push` from an authorized operator session. The project service credential must stay in server-side Railway variables.
4. Confirm the founder Telegram ID, review default policies, and only then enable external founder commands.

Every public company table has RLS enabled. `anon` and `authenticated` have no table access. The service role has no direct write access to budgets, spending policies, company settings, expenses, approvals or audit records; use the explicit audited RPC functions.

## Railway services

The current Railway deployment is Hermes-only and remains connected to `praveen-ks-2001/hermes-agent-template`, not this repository. Connect Sutra's GitHub repository to the existing Hermes service only after confirming the intended branch and reviewing the provider's repository-access grant. Configure two services in the existing Railway project after checking current usage and free allowance:

| Service | Config | Volume | Allowed secrets |
| --- | --- | --- | --- |
| Hermes Agent | Root `railway.json`, `Dockerfile` | `/opt/data` | Model provider credentials only |
| Sutra API | `railway.api.json`, `Dockerfile.api` | None | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_FOUNDER_USER_ID`, `SUTRA_INTERNAL_TOKEN`, `HERMES_HEALTH_URL` |

Set a random independent `SUTRA_INTERNAL_TOKEN` on the API service. The token protects the narrow private API endpoints; do not give it to the language model. The API must not share the Supabase service-role key with Hermes. Set `SUTRA_ENABLE_TELEGRAM=true` only after the database founder identity matches the intended founder.

The Hermes image pins the inspected upstream digest, preserves the root s6 entrypoint so it can prepare the volume and drop privileges, and starts `gateway run`. Its optional API server stays disabled. Attach the persistent volume to `/opt/data`; restart-on-failure is configured. The Sutra API exposes `/health`, which separately reports database, Telegram, and Hermes integration state.

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
