# Sutra

Sutra is a governed company operations runtime. Supabase holds authoritative company state and database-enforced approval policy; GitHub holds software artifacts; Hermes is the agent runtime; Telegram is the founder interface.

## Current implementation

- The Supabase migrations define all 14 organizational roles and the operational schema, enable RLS, withhold direct access from `anon` and `authenticated`, and limit service-role writes to audited database functions for financial and governance tables.
- Spending policies and budget limits live in Supabase. Defaults are `<= €10` automatic, `> €10 to €50` department head, `> €50 to < €200` CFO and CEO, and `>= €200` founder. All boundaries are configurable through founder-verified functions. Company, project, department, agent, category, vendor, transaction, daily, monthly and lifetime budgets support warnings and hard stops. Current live budget rows include the €8 monthly AI-inference hard stop and €500 ceilings for the three proposal records; no overall company operating budget is set.
- Department-head approvals are disabled until the founder assigns an active agent to a department through the audited `sutra_set_company_setting` RPC (`department_head:<department UUID>` → agent UUID). This keeps the €10–50 tier fail-closed until a real approver is designated.
- A founder proposal persists a project, objective, approval, audit event, CEO/Product/CTO/CFO/PM handoffs and a blocked research task. CFO review is required before founder approval. Approval creates a durable task chain. Founder direction currently defers QA and Security role handoffs; the active engineering path ends at Developer PR and matching successful CI evidence. After approval, the leased Hermes worker writes role-specific, private task artifacts for PM, Architect, COO, DevOps, CMO, Sales and Governance/Audit. It settles model usage against the database reservation before artifact persistence; exact task acceptance criteria and role contracts are checked by the database. Marketing/Sales deliverables are internal drafts only.
- The private Python service exposes health and token-protected internal spend, role-approval and task-update endpoints. Telegram polling is restricted to the configured founder in a private chat. Company status briefs include bounded GitHub delivery health through a service-role-only RPC and report allowlisted failure categories without raw provider response text. The production Telegram bot identity and founder status command have been verified live. Supabase, Telegram and internal API credentials are stored on the private API service; Hermes model credentials stay on the separate Hermes service.
- The maximum total attempts for a Codex execution after verified no-request failures is a founder-adjustable, audited Supabase setting (default 3, hard maximum 3; founder may lower it to 1 or 2). Telegram commands are `CEO, show Codex no-request retry limit.` and `CEO, set Codex no-request retry limit to 3 total attempts.` Changing the setting only changes the limit; it never starts a retry. Every retry still requires the same founder-approved Developer task and scope, a terminal prior attempt with zero provider requests/tokens, preservation of the unknown reservation, and a fresh reservation through existing spend policies and the monthly hard cap. It adds no project-spend, merge, or release authority.
- Unit tests cover command routing, founder identity checks, malformed requests and the central authorization endpoint. PostgreSQL policy tests cover spending boundaries, project approvals, budget stops, RLS, role approvals, per-run model spend reservations and audit writes.

The SQL workflow stores real work items and approval evidence. It does not fabricate research results. In production, the GitHub dispatcher and Codex runner are enabled behind the founder-approved Developer scope gate. The dispatcher claims only a ready Developer task in a founder-approved project, creates or recovers its linked GitHub issue, signs it, and audits the handoff. The runner verifies that signature, obtains a one-time database claim, meters every OpenAI Responses request against its exact price profile, and can open a branch and PR; it cannot merge or deploy. The founder's Sutra-only GitHub token now has Issues, Contents and Pull requests read/write. Retrying the approved Developer task created signed issue #107 and was recorded in Supabase. The latest Codex execution used three metered requests and then exited with code 1 without a PR. The execution ceiling is exhausted, so no further run is queued. Metering settlement and process success are tracked independently; a failed process is reported as a failed run while trusted spend remains reconciled and unknown reservations remain held. The same OpenAI key is configured for Sutra API and Hermes. Signed GitHub webhooks can record a matching PR and CI workflow. Founder direction defers QA and Security role handoffs for now; successful CI and financial/authorization controls remain in force. See [deployment instructions](docs/DEPLOYMENT.md) and [STATUS.md](STATUS.md) for live state.

The leased proposal/review/task-artifact worker is deployed and enabled. A service-role-only Supabase execution lease serializes the worker across overlapping Railway replicas before it claims work or reserves model spend; the lease expires after ten minutes if a process crashes. Before each provider request the worker reserves the profile's maximum three-iteration cost, waits for approval if required, begins the reservation, passes Hermes a bounded output-token cap and exact route lock, and reconciles observed usage before success. Unknown or out-of-profile usage keeps the full reserve and fails the run. The task-artifact reservation path additionally requires an assigned in-progress task in an approved project. The live database has founder-audited OpenAI GPT-6 Luna and Kimi K2.6 price profiles and an €8 monthly AI inference hard stop. A production AI QA proposal completed CEO → CPO → CTO → CFO → PM; all five stages persisted successful runs and role artifacts. Three proposal records now exist: one was rejected, one €500 request is approved, and one duplicate remains pending. A CPO-only Kimi K2.6 route is configured in Railway. Its first live research attempt failed with provider HTTP 429 and usage could not be verified; the €0.28 reservation remains held and the task is blocked. Unknown usage is never estimated or released. All other production roles use the OpenAI GPT-6 Luna default. See [STATUS.md](STATUS.md) for current evidence and blockers.

PM review requests use provider JSON mode and a strict single-object contract for the product plan. The founder can request a bounded retry from Telegram only while the project budget request is pending; each attempt still passes the database spend reservation and monthly hard stop. Unknown earlier usage remains reserved.

## Local verification

Python 3.12+ has no third-party dependencies:

```sh
python3 -m unittest discover -s tests -v
```

CI also runs Bandit 1.9.4 at medium severity or higher. Outbound HTTP requests are restricted to HTTPS or Railway's private `.railway.internal` network; the API binds to the container interface for Railway's health probe while public networking remains disabled.

Install Docker and the Supabase CLI, then run:

```sh
supabase start
supabase db reset
supabase test db
```

For the API, copy `.env.example` to `.env`, fill only the server-side integration values, then run `python3 -m sutra.server`. Never commit `.env` or place a Supabase service-role key in Hermes, a Telegram message, GitHub, or an agent prompt.

## Railway services

The production Railway project uses two private services connected to this repository:

1. **Hermes** (`sutra`) builds from the repository root `Dockerfile` and starts the pinned, patched Hermes gateway. A Railway volume is mounted at `/opt/data` for persistent runtime state. Keep its model-provider credentials here, separate from Supabase credentials.
2. **Sutra API** (`sutra-api`) builds from root directory `/sutra` and `sutra/Dockerfile`, runs `python -m sutra.server` and listens on port 8080. It has `/health` configured as its Railway health check and is not publicly exposed. The Supabase service-role key, Telegram bot token, internal token and Hermes private API credentials are configured as Railway service variables; the founder ID is configured in both the API environment and Supabase. The proposal/task-artifact worker is enabled and uses database-approved model profiles and per-role routes.

`GET /health` reports process and integration status. `GET /ready` reports database readiness and checks each enabled integration, returning HTTP 503 with named blockers until usable. When the agent worker is enabled, readiness also requires a successful probe of the configured private `HERMES_HEALTH_URL`; a running Sutra worker alone is not sufficient. The probe accepts HTTPS or Railway's private `.railway.internal` HTTP network and never returns credentials. See [STATUS.md](STATUS.md) for current live verification and blockers.

See [deployment instructions](docs/DEPLOYMENT.md), [architecture](docs/ARCHITECTURE.md), [role contracts and handoffs](docs/OPERATING_MODEL.md), [governance](docs/GOVERNANCE.md) and the live verification record in [STATUS.md](STATUS.md).

## Founder commands

- `CEO, give me company status.`
- `CFO, give me department status.` (also CTO, CPO, COO, Product Manager/PM, Architect, Developer, QA, Security, DevOps, CMO/Marketing, Sales, Governance/Audit) — returns a persisted-data operating brief with portfolio, project budgets, task queues and owners, blockers, pending approvals and active financial controls. CEO/CFO/COO briefs are company-wide; other roles are scoped to their department. Lists are bounded for Telegram and point back to Supabase for the full queue.
- `CEO, show my approvals.` — lists up to ten pending founder requests with the amount and outstanding department reviews; viewing the queue is audit logged and does not change approval state. Ready requests include private-chat Approve/Reject buttons backed by the same founder-only audited database RPC as the command form.
- `retry PM review <run-id>` — a founder-only, audited retry for a failed PM stage after CEO, Product, CTO and CFO are complete and the project approval remains pending. It preserves every earlier spend reservation (including unknown usage), consumes one remaining bounded attempt, and subjects new model usage to the normal reservation and monthly hard stop. It never approves the project budget.
- `retry PM task <task-id>` — a founder-only, audited recovery for a blocked Product Manager planning task in a founder-approved project after a recognized artifact-validation failure. It preserves unknown reservations, permits at most three artifact runs total, and leaves all new inference subject to the existing spending policy and monthly hard stop. It does not approve further project spend.
- `retry agent review <run-id>` — a founder-only, audited retry for a recoverable failed CEO/CPO/CTO/CFO review stage when all prior stages succeeded. It uses only the same three-attempt ceiling, preserves unknown reservations, and still passes through the central spend reservation and monthly hard stop. PM retries keep their stricter CFO-complete gate.
- `retry GitHub dispatch <task-id>` — a founder-only, audited retry only for an exhausted GitHub permission-denied dispatch of the same approved Developer task. It resets one bounded three-attempt cycle, allows at most three founder retry cycles, and grants no spend, merge, or release authority.
- `retry Codex task <task-id>` — a founder-only, audited retry for the existing approved Developer task only after the metering database records zero provider requests and zero tokens. The prior unknown reservation is preserved and each retry uses a fresh database-priced reservation. Retries are bounded by the current founder-adjustable database limit of 1–3 total attempts per execution (default and hard maximum 3); changing that limit never starts a retry. The command grants no project spend, merge, or release authority.
- `Investigate an AI QA product. Initial budget maximum €500. Prepare a proposal.`
- `approve <approval-id> [comment]` or `reject <approval-id> [comment]`

Approval replies include IDs that can be used in the explicit approval command. There is no automatic external marketing, sales outreach, payment or production release.
