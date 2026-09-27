# Sutra

Sutra is a governed company operations runtime. Supabase holds authoritative company state and database-enforced approval policy; GitHub holds software artifacts; Hermes is the agent runtime; Telegram is the founder interface.

## Current implementation

- The Supabase migrations define all 14 organizational roles and the operational schema, enable RLS, withhold direct access from `anon` and `authenticated`, and limit service-role writes to audited database functions for financial and governance tables.
- Spending policies and budget limits live in Supabase. Defaults are `<= €10` automatic, `> €10 to €50` department head, `> €50 to < €200` CFO and CEO, and `>= €200` founder. All boundaries are configurable through founder-verified functions. Company, project, department, agent, category, vendor, transaction, daily, monthly and lifetime budgets support warnings and hard stops.
- Department-head approvals are disabled until the founder assigns an active agent to a department through the audited `sutra_set_company_setting` RPC (`department_head:<department UUID>` → agent UUID). This keeps the €10–50 tier fail-closed until a real approver is designated.
- A founder proposal persists a project, objective, approval, audit event, CEO/Product/CTO/CFO/PM handoffs and a blocked research task. CFO review is required before founder approval. Approval creates a durable, sequential PM → Architect → Developer → QA → Security → DevOps → Marketing → Sales task chain. After approval, the leased Hermes worker writes role-specific, private task artifacts for PM, Architect, COO, DevOps, CMO, Sales and Governance/Audit. It settles model usage against the database reservation before artifact persistence; exact task acceptance criteria and role contracts are checked by the database. Marketing/Sales deliverables are internal drafts only.
- The private Python service exposes health and token-protected internal spend, role-approval and task-update endpoints. Telegram polling is restricted to the configured founder in a private chat. Hermes runs in its own Railway service; its model and Telegram secrets are kept separate from the database service credential.
- Unit tests cover command routing, founder identity checks, malformed requests and the central authorization endpoint. PostgreSQL policy tests cover spending boundaries, project approvals, budget stops, RLS, role approvals, per-run model spend reservations and audit writes.

The SQL workflow stores real work items and approval evidence. It does not fabricate research results. An opt-in GitHub dispatcher claims only a ready Developer task in a founder-approved project, creates or recovers its linked GitHub issue, and audits the handoff. Signed GitHub webhooks can record a matching PR and CI workflow; Developer work completes only after merge and successful CI on the same commit, which releases QA. This does not itself implement code, complete QA/security review, or release the product.

The leased proposal/review/task-artifact worker runs only after a matching database model profile, exact provider/model route, Hermes URL and API key are configured. Before each provider request it reserves the profile's maximum three-iteration cost, waits for approval if required, begins the reservation, passes Hermes a bounded output-token cap and exact route lock, and reconciles observed usage before success. Unknown or out-of-profile usage keeps the full reserve and fails the run. The task-artifact reservation path uses the same central spending-policy RPC and additionally requires the run to belong to the assigned in-progress task of an approved project. The pinned Hermes image patch is source-checked at build time and CI verifies that `max_tokens` reaches `AIAgent` and model fallback is locked out. The model profile remains empty and `SUTRA_ENABLE_AGENT_WORKER` remains false until secrets and a founder-approved price/route are available. The separate GitHub issue dispatcher is opt-in and requires a least-privilege repo token. See [STATUS.md](STATUS.md) for current service blockers.

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
2. **Sutra API** (`sutra-api`) builds from root directory `/sutra` and `sutra/Dockerfile`, runs `python -m sutra.server` and listens on port 8080. It has `/health` configured as its Railway health check and is not publicly exposed. Add the Supabase service-role key, Telegram bot token, a random internal token, and other integration secrets in this service's Railway Variables page. The founder ID is already configured. Keep Telegram and agent worker flags disabled until each integration is verified.

The API's Railway `/health` probe returning HTTP 200 verifies process liveness only. `GET /ready` reports database readiness and checks each enabled integration, returning HTTP 503 with named blockers until they are usable. See [STATUS.md](STATUS.md) for current live checks and blockers.

See [deployment instructions](docs/DEPLOYMENT.md), [architecture](docs/ARCHITECTURE.md), [governance](docs/GOVERNANCE.md) and the live verification record in [STATUS.md](STATUS.md).

## Founder commands

- `CEO, give me company status.`
- `CEO, show my approvals.` — lists up to ten pending founder requests with the amount and outstanding department reviews; viewing the queue is audit logged and does not change approval state.
- `Investigate an AI QA product. Initial budget maximum €500. Prepare a proposal.`
- `approve <approval-id> [comment]` or `reject <approval-id> [comment]`

Approval replies include IDs that can be used in the explicit approval command. There is no automatic external marketing, sales outreach, payment or production release.
