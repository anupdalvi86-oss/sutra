# Deployment

## Supabase database

1. Install the Supabase CLI and Docker.
2. For local development, run `supabase start`, `supabase db reset`, `supabase test db`, and `supabase db lint --local --level error`.
3. Hosted migration history also includes the metered Codex authorization migration (`20260927182221`). Its execution table is RLS-protected; direct service-role table access is revoked and the authorization/usage RPCs are service-role-only. Main CI applies the full migration set, passes 170 pgTAP assertions and database lint. The local Supabase CLI is not linked on this workstation; compare hosted versions before any `supabase db push`.
4. Supabase was `ACTIVE_HEALTHY` on PostgreSQL 17.6 at the latest check. The project previously displayed a quota/grace-period warning; confirm current quota and a recovery point before future production schema changes.
5. Founder identity `8776723105` is registered and matches the Railway API configuration. Database spending policies are active, but there are no active general budget rows or department-head approver. Set those through the founder-only audited policy flow before routine spend.

Every public company table has RLS enabled. `anon` and `authenticated` have no table access. The service role has no direct write access to budgets, spending policies, company settings, expenses, approvals or audit records; use the explicit audited RPC functions.

## Railway services

Production Railway project `valiant-liberation` contains two private services connected to `anupdalvi86-oss/sutra` on `main`. Both services are Online. After the latest main deployment, `/health` reported Supabase reachable and Telegram running; `/ready` returned `ready: true` with no blockers for enabled integrations. The API has no public URL and neither service has public networking enabled.

| Service | Config | Volume | Allowed secrets |
| --- | --- | --- | --- |
| Hermes (`sutra`) | Repository-root `Dockerfile`, `railway.json` | `sutra-volume` mounted at `/opt/data` (default 0.5 GB) | Model provider credentials; API server key only when the private API is intentionally enabled |
| Sutra API (`sutra-api`) | Railway root directory `/sutra`, `Dockerfile` | None | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_FOUNDER_USER_ID`, `SUTRA_INTERNAL_TOKEN`, `HERMES_HEALTH_URL`, `HERMES_AGENT_API_URL`, `HERMES_AGENT_API_KEY`, `SUTRA_HERMES_PROVIDER`, `SUTRA_HERMES_MODEL`, optional `GITHUB_TOKEN`, `GITHUB_WEBHOOK_SECRET`, `GITHUB_REPOSITORY` |

The attached volume is required because Hermes state is stored under `/opt/data`. The API image is built by `sutra/Dockerfile`; do not select the old/nonexistent `Dockerfile.api` path. Hermes is Online with the volume mounted; it has no provider/API route configured and has not made a model request.

The API's liveness probe is `/health`, and the API service listens on port 8080. `GET /ready` separately returns HTTP 503 with named blockers while the database or an explicitly enabled integration is unusable. The current production response reports database reachable, Telegram running, worker disabled, GitHub dispatcher disabled, and GitHub webhook unconfigured. The `telegram` field distinguishes `disabled`, `unconfigured`, `founder_unverified`, `unreachable`, `invalid_response`, `starting`, and `running`. Startup validates the bot token with `getMe`; the poller reports running only after a successful update poll. The latest Chrome check verified the founder status command and approval-list reply. Keep the API private. Hermes' optional API server is off unless `SUTRA_HERMES_API_ENABLED=true`; its default bind is loopback. Never expose that endpoint publicly. The Sutra worker stays disabled until a provider key, private API key/URL, exact route, and founder-approved model price profile are configured.

The API already has the Supabase service-role credential, Telegram bot token, founder ID, and independent `SUTRA_INTERNAL_TOKEN` installed in Railway variables. Keep those values server-side and do not copy them into this repository, issues, agent input, or Hermes. Telegram is enabled (`SUTRA_ENABLE_TELEGRAM=true`) and founder identity verification succeeded. The API must not share its Supabase service-role credential with Hermes.

The Hermes image pins the inspected upstream digest, preserves the root s6 entrypoint so it can prepare the volume and drop privileges, and starts `gateway run`. A build-time patch makes the OpenAI-compatible endpoint pass a validated `max_tokens` cap into Hermes and honors `require_model_lock` so the selected provider/model cannot fall back. CI verifies that patch against the pinned source. Attach the persistent volume to `/opt/data`; restart-on-failure is configured. Sutra's startup script forces the API-server platform off unless `SUTRA_HERMES_API_ENABLED=true` is explicitly set, constrains its toolset to `web`, and caps reviews at three agent turns, one provider attempt per model iteration, and zero automatic recovery cycles. The API server binds to loopback by default; set `API_SERVER_HOST=0.0.0.0` only when deliberately enabling private Railway networking, and always require an API key. Model profiles set per-completion token ceilings; database reservation and reconciliation account for all three possible model iterations. The worker calls database preflight, reserve, begin, and usage-reconciliation RPCs for every run. Pending approvals make no provider request; missing or invalid usage retains the full reserve and prevents run success. When proposal and QA/Security queues are idle, it can claim ready PM, Architect, COO, DevOps, CMO, Sales and Governance/Audit tasks for spend-gated, private deliverable artifacts. The database requires the exact active task lease, an approved project, a reconciled model reservation and exact task criteria before persisting a role-specific artifact. CMO/Sales outputs stay internal drafts; this lane does not send messages or deploy. QA/Security work still requires a merged Developer PR and successful same-SHA CI. The live Supabase project has zero active model profiles, so the worker remains fail-closed until the founder configures an exact route and database price/token profile. The `/health` endpoint reports database, Telegram, Hermes and worker state. Keep `SUTRA_ENABLE_AGENT_WORKER=false` until all secrets, exact provider/model route, active database profile, and deployment health are verified. To enable Hermes later, set `SUTRA_HERMES_API_ENABLED=true`, `API_SERVER_HOST=0.0.0.0`, and a strong `API_SERVER_KEY` only on Hermes, then set the matching `HERMES_AGENT_API_KEY`, private `HERMES_AGENT_API_URL`, `SUTRA_HERMES_PROVIDER`, and `SUTRA_HERMES_MODEL` on Sutra API.

The GitHub task dispatcher is independently opt-in (`SUTRA_ENABLE_GITHUB_DISPATCHER=false`). Before enabling, add a fine-grained GitHub token with Issues read/write and Metadata read for `GITHUB_REPOSITORY`. Supabase claims only ready Developer tasks in approved/active projects, leases each dispatch, stores the issue URL, starts the task, and audits the handoff. Stable task UUID markers let a recovered worker reuse an issue; exact signed issue content fails closed if changed. Do not give GitHub credentials to Hermes. The Codex execution authorization, usage reservation and reconciliation RPCs are implemented and live, but there is no production runner that consumes authorized work and creates a PR. A provider/model price profile is also not active, so do not enable an unmetered coder workflow.

The signed webhook endpoint is `POST /webhooks/github`. It verifies GitHub's SHA-256 signature/repository, stores deduplicated events, and records PR/CI evidence. Developer completion requires a merged PR and matching successful `CI` on the same head SHA; QA/Security reviews require persistent evidence tied to that commit. No repository webhook is registered. The API is currently private, so GitHub cannot deliver events to it. Do not expose the whole internal API; choose and review a safe public ingress for this signed receiver before configuring a webhook. GitHub denied branch-protection access for this private repository; requiring CI through branch protection needs a plan that supports it.

Railway deploys from `main`, but wait-for-CI is not enabled because its GitHub app permission step is still pending. Verify the deployment and `/health` after releases. Keep Hermes and internal endpoints private.

## Telegram setup

The founder bot is `@sutra86bot`. Its token and the numeric founder ID are stored only in the private Sutra API Railway service; the founder ID is `8776723105`, registered in Supabase and verified at startup. Telegram is enabled and running. The live private chat has returned both `CEO, give me company status.` and `CEO, show my approvals.`; the latter reported no pending requests and produced the `founder.approvals_listed` audit event. The poller skips stale updates at startup, accepts only one-to-one founder messages, and records denied identity hashes rather than raw Telegram IDs. Rotate the shared bot token after validation, then replace it directly in Railway without sending it through chat or GitHub.

The bot currently supports status, budgeted proposal, a founder-only pending approval list (`CEO, show my approvals.`), and explicit approval/rejection commands. Listing pending requests is audit logged and does not change their state. It does not send campaigns or sales messages.

## Local API

```sh
cp .env.example .env
# Fill only local server-side values in .env.
SUTRA_BIND_HOST=127.0.0.1 python3 -m sutra.server
```

Do not place secrets in committed files, issue descriptions, agent inputs, Hermes state, or client-side code. The `.env` file is ignored by Git.
