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

The proposal function persists a sequence of handoffs for CEO, CPO, CTO, CFO and Product Manager. The worker implementation claims each run with a 10-minute lease and writes bounded, validated artifacts plus audit events. It is experimental and must remain disabled until model usage has a database-backed reservation and reconciliation path. Product research must include direct HTTPS evidence. The next role cannot run until the prior review succeeds; retries are bounded. CFO approval remains a separate database authorization step, and founder approval is rejected until all five reviews complete.

## Service boundaries

- `Dockerfile` pins the inspected official Hermes image, keeps its root s6 entrypoint active so it can drop privileges correctly, and runs the gateway with persistent state at `/opt/data`. Its optional API server stays off by default. If enabled, it requires `API_SERVER_KEY`, binds on port 8642 for Railway private networking, and its `api_server` platform toolset is forcibly restricted to Hermes' `web` toolset at every startup. Startup also caps a review at three agent turns, one provider attempt per model iteration, and no automatic recovery cycles. The pinned Hermes `/v1/chat/completions` endpoint ignores request `max_tokens`, so this field is not treated as a cost limit. Hermes never receives the Supabase service key or a GitHub write token.
- `Dockerfile.api` runs a small standard-library-only Python service. Only this service receives the Supabase service-role key, Telegram bot token, Hermes API key, and independent internal bearer token. Token-protected endpoints invoke central Supabase RPC policy functions; their caller is not allowed to pass an approval flag. The experimental agent worker is disabled by default and is not safe to enable until each provider call is reserved against database spending policy.
- The API health response reports database, Telegram and Hermes status separately. HTTP liveness does not imply that those external integrations are configured.
- Telegram identities are checked against the server configuration and bootstrapped once to a database setting. A later mismatch fails closed. A private one-to-one chat is required; denied identities are recorded as a one-way hash.

## Workflow boundaries

The runtime accepts founder status, budgeted proposal, and explicit approval commands. CEO/Product/CTO/CFO/PM reviews are durably queued and gated in sequence. The database now provides reserve, start, and usage-reconciliation RPCs for model calls, and a review cannot succeed without a reconciled reservation. The experimental Hermes worker remains disabled until the worker is wired to these RPCs and a bounded, database-controlled model pricing/route is available. The Hermes reviewer has web access only and cannot write code, create GitHub artifacts, or run tests. Codex/GitHub engineering dispatch, QA/security evidence ingestion, and release execution still require an attached engineering worker and their credentials; queued engineering tasks are not completed work.
