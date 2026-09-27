# Sutra

Sutra is a governed company operations runtime. Supabase holds authoritative company state and database-enforced approval policy; GitHub holds software artifacts; Hermes is the agent runtime; Telegram is the founder interface.

## Current implementation

- The Supabase migrations define all 14 organizational roles and the operational schema, enable RLS, withhold direct access from `anon` and `authenticated`, and limit service-role writes to audited database functions for financial and governance tables.
- Spending policies and budget limits live in Supabase. Defaults are `<= €10` automatic, `> €10 to €50` department head, `> €50 to < €200` CFO and CEO, and `>= €200` founder. All boundaries are configurable through founder-verified functions. Company, project, department, agent, category, vendor, transaction, daily, monthly and lifetime budgets support warnings and hard stops.
- Department-head approvals are disabled until the founder assigns an active agent to a department through the audited `sutra_set_company_setting` RPC (`department_head:<department UUID>` → agent UUID). This keeps the €10–50 tier fail-closed until a real approver is designated.
- A founder proposal persists a project, objective, approval, audit event, CEO/Product/CTO/CFO/PM handoffs and a blocked research task. CFO review is required before founder approval. Approval creates a durable, sequential PM → Architect → Developer → QA → Security → DevOps → Marketing → Sales task chain.
- The private Python service exposes health and token-protected internal spend, role-approval and task-update endpoints. Telegram polling is restricted to the configured founder in a private chat. Hermes runs in its own Railway service; its model and Telegram secrets are kept separate from the database service credential.
- Unit tests cover command routing, founder identity checks, malformed requests and the central authorization endpoint. PostgreSQL policy tests cover spending boundaries, project approvals, budget stops, RLS, role approvals, per-run model spend reservations and audit writes.

The SQL workflow stores real work items and approval evidence. It does not fabricate research results or independently execute tasks. A worker must consume ready tasks, produce GitHub issues/PRs and record QA/security evidence before release.

The leased worker runs only after a matching database model profile, exact provider/model route, Hermes URL and API key are configured. Before each provider request it reserves the profile's maximum three-iteration cost, waits for approval if required, begins the reservation, passes Hermes a bounded output-token cap and exact route lock, and reconciles observed usage before success. Unknown or out-of-profile usage keeps the full reserve and fails the run. The pinned Hermes image patch is source-checked at build time and CI verifies that `max_tokens` reaches `AIAgent` and model fallback is locked out. The model profile remains empty and `SUTRA_ENABLE_AGENT_WORKER` remains false until secrets and a founder-approved price/route are available. The worker produces proposal-review artifacts only; approved engineering tasks are not yet dispatched to Codex/GitHub. See [STATUS.md](STATUS.md) for current service blockers.

## Local verification

Python 3.12+ has no third-party dependencies:

```sh
python3 -m unittest discover -s tests -v
```

Install Docker and the Supabase CLI, then run:

```sh
supabase start
supabase db reset
supabase test db
```

For the API, copy `.env.example` to `.env`, fill only the server-side integration values, then run `python3 -m sutra.server`. Never commit `.env` or place a Supabase service-role key in Hermes, a Telegram message, GitHub, or an agent prompt.

## Railway services

Use two services in the existing Railway project:

1. **Hermes Agent** builds from `Dockerfile` with `railway.json`; mount its persistent volume at `/opt/data`. Configure only Hermes model-provider credentials here.
2. **Sutra API** builds from `Dockerfile.api` with `railway.api.json`; configure Supabase URL/service-role key, founder Telegram user ID, Telegram bot token, internal token and Hermes health URL here. Set `SUTRA_ENABLE_TELEGRAM=true` only after verifying the founder ID and bot token.

See [deployment instructions](docs/DEPLOYMENT.md), [architecture](docs/ARCHITECTURE.md), [governance](docs/GOVERNANCE.md) and the live verification record in [STATUS.md](STATUS.md).

## Founder commands

- `CEO, give me company status.`
- `Investigate an AI QA product. Initial budget maximum €500. Prepare a proposal.`
- `approve <approval-id> [comment]` or `reject <approval-id> [comment]`

Approval replies include IDs that can be used in the explicit approval command. There is no automatic external marketing, sales outreach, payment or production release.
