# Sutra Architecture

## Organization
Founder → CEO → CTO/CPO/CFO/CMO/Sales/COO.

Engineering includes architecture, development, QA, security and DevOps. Governance/Audit is independent and observes all departments.

## Sources of truth
- Supabase: projects, tasks, budgets, approvals, decisions, customers, company state and audit log.
- GitHub: engineering code, issues, pull requests and CI.
- Hermes memory: private working memory for individual agents; never authoritative corporate state.

## First workflow
Founder command → CEO → Product/Research → CTO → CFO → PM → Founder approval → execution.

The proposal function persists handoff records for CEO, CPO, CTO, CFO and Product Manager, including a `pending` evidence marker. It does not claim those agent runs have completed. Once CFO and founder approvals are recorded, the PM task becomes ready and the remaining task chain is released one stage at a time as its parent is marked done.

## Service boundaries

- `Dockerfile` pins the inspected official Hermes image, keeps its root s6 entrypoint active so it can drop privileges correctly, and runs the gateway with persistent state at `/opt/data`. Hermes' optional API server stays disabled until it can be integrated behind an authenticated boundary.
- `Dockerfile.api` runs a small standard-library-only Python service. Only this service receives the Supabase service-role key, Telegram bot token and an independent internal bearer token. The token-protected endpoints invoke central Supabase RPC policy functions; their caller is not allowed to pass an approval flag.
- The API health response reports database, Telegram and Hermes status separately. HTTP liveness does not imply that those external integrations are configured.
- Telegram identities are checked against the server configuration and bootstrapped once to a database setting. A later mismatch fails closed. A private one-to-one chat is required; denied identities are recorded as a one-way hash.

## Workflow boundaries

The current runtime accepts founder status, budgeted proposal, and explicit approval commands. The database makes work durable and gates execution by approval and parent-task completion. Codex/GitHub worker dispatch, live product research, test evidence ingestion, and release execution still require an attached engineering worker and their credentials; queued handoffs are not completed work.
