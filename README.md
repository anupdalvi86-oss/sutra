# Sutra

Sutra is a governed company operations runtime. Supabase holds authoritative company state and database-enforced approval policy; GitHub holds software artifacts; Hermes is the agent runtime; Telegram is the founder interface.

## Current implementation

- The Supabase migrations define all 14 organizational roles and the operational schema, enable RLS, withhold direct access from `anon` and `authenticated`, and limit service-role writes to audited database functions for financial and governance tables.
- Spending policies and budget limits live in Supabase. Defaults are `<= €10` automatic, `> €10 to €50` department head, `> €50 to < €200` CFO and CEO, and `>= €200` founder. All boundaries are configurable through founder-verified functions. Company, project, department, agent, category, vendor, transaction, daily, monthly and lifetime budgets support warnings and hard stops.
- Department-head approvals are disabled until the founder assigns an active agent to a department through the audited `sutra_set_company_setting` RPC (`department_head:<department UUID>` → agent UUID). This keeps the €10–50 tier fail-closed until a real approver is designated.
- A founder proposal persists a project, objective, approval, audit event, CEO/Product/CTO/CFO/PM handoffs and a blocked research task. CFO review is required before founder approval. Approval creates a durable, sequential PM → Architect → Developer → QA → Security → DevOps → Marketing → Sales task chain. After approval, the leased Hermes worker writes role-specific, private task artifacts for PM, Architect, COO, DevOps, CMO, Sales and Governance/Audit. It settles model usage against the database reservation before artifact persistence; exact task acceptance criteria and role contracts are checked by the database. Marketing/Sales deliverables are internal drafts only.
- The private Python service exposes health and token-protected internal spend, role-approval and task-update endpoints. Telegram polling is restricted to the configured founder in a private chat. The production Telegram bot identity and founder status command have been verified live. Supabase, Telegram and internal API credentials are stored on the private API service; Hermes model credentials stay on the separate Hermes service.
- Unit tests cover command routing, founder identity checks, malformed requests and the central authorization endpoint. PostgreSQL policy tests cover spending boundaries, project approvals, budget stops, RLS, role approvals, per-run model spend reservations and audit writes.

The SQL workflow stores real work items and approval evidence. It does not fabricate research results. An opt-in GitHub dispatcher claims only a ready Developer task in a founder-approved project, creates or recovers its linked GitHub issue, and audits the handoff. The opt-in Codex runner verifies the signed issue, obtains a one-time database claim, meters every OpenAI Responses request against its exact price profile, and can open a branch and PR; it cannot merge or deploy. Railway already contains the exact GitHub token and webhook secret most recently supplied by the founder. GitHub's token editor has the Sutra-only repository selection and minimum runner permissions staged, but the current token still returns HTTP 404 because the grant has not been saved; the dispatcher and runner stay disabled until saved access verifies. The same OpenAI key is configured for Sutra API and Hermes. Signed GitHub webhooks can record a matching PR and CI workflow; Developer work completes only after merge and successful CI on the same commit, which releases QA. The Codex runner implementation is not the same as verified production delivery; see [deployment instructions](docs/DEPLOYMENT.md) and [STATUS.md](STATUS.md) for live state.

The leased proposal/review/task-artifact worker is deployed and enabled. Before each provider request it reserves the profile's maximum three-iteration cost, waits for approval if required, begins the reservation, passes Hermes a bounded output-token cap and exact route lock, and reconciles observed usage before success. Unknown or out-of-profile usage keeps the full reserve and fails the run. The task-artifact reservation path additionally requires an assigned in-progress task in an approved project. The live database has founder-audited OpenAI GPT-6 Luna and Kimi K2.6 price profiles and an €8 monthly AI inference hard stop. A prior live Kimi CPO request could not be reconciled; its €0.28 reserve remains held. Kimi's key is present on the private Hermes service but production role routes are currently empty, so all roles use the OpenAI default until Kimi usage accounting is verified. The latest production PM review used three attempts; attempt two remains unknown at €0.03 and attempt three reconciled €0.01 but failed artifact validation. PR #62's provider JSON mode and explicit PM output object contract are deployed for future reviews. PR #63 makes Telegram polling recover after a transient startup check failure; the deployed API is ready and the bot replied to a live status check. The latest Telegram proposal completed CEO, CPO, CTO and CFO review; PM produced no persisted artifact. The €500 founder approval remains pending and authorizes no spending. See [STATUS.md](STATUS.md) for current evidence and blockers.

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

`GET /health` reports process and enabled integration status. `GET /ready` reports database readiness and checks each enabled integration, returning HTTP 503 with named blockers until usable. The latest production `/ready` check, issued over Railway's private network after PR #63, reported Supabase reachable, Telegram running and agent worker running, with readiness true. Hermes is Online. A proposal reached a live Kimi run which failed closed on unknown usage; see [STATUS.md](STATUS.md) for the current live verification and blockers.

See [deployment instructions](docs/DEPLOYMENT.md), [architecture](docs/ARCHITECTURE.md), [role contracts and handoffs](docs/OPERATING_MODEL.md), [governance](docs/GOVERNANCE.md) and the live verification record in [STATUS.md](STATUS.md).

## Founder commands

- `CEO, give me company status.`
- `CEO, show my approvals.` — lists up to ten pending founder requests with the amount and outstanding department reviews; viewing the queue is audit logged and does not change approval state. Ready requests include private-chat Approve/Reject buttons backed by the same founder-only audited database RPC as the command form.
- `retry PM review <run-id>` — a founder-only, audited retry for a failed PM stage after CEO, Product, CTO and CFO are complete and the project approval remains pending. It preserves every earlier spend reservation (including unknown usage), consumes one remaining bounded attempt, and subjects new model usage to the normal reservation and monthly hard stop. It never approves the project budget.
- `Investigate an AI QA product. Initial budget maximum €500. Prepare a proposal.`
- `approve <approval-id> [comment]` or `reject <approval-id> [comment]`

Approval replies include IDs that can be used in the explicit approval command. There is no automatic external marketing, sales outreach, payment or production release.
