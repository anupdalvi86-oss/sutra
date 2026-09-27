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

The proposal function persists a sequence of handoffs for CEO, CPO, CTO, CFO and Product Manager. The review worker claims each run with a 10-minute lease and writes bounded, validated artifacts plus audit events. Every provider request is gated by a database-backed spend reservation, founder-configured route and token ceilings, and usage reconciliation. Product research must include direct HTTPS evidence. The next role cannot run until the prior review succeeds; retries are bounded. CFO approval remains a separate database authorization step, and founder approval is rejected until all five reviews complete.

## Service boundaries

- `Dockerfile` pins the inspected official Hermes image, keeps its root s6 entrypoint active so it can drop privileges correctly, and runs the gateway with persistent state at `/opt/data`. Its optional API server is explicitly disabled in persistent config unless `SUTRA_HERMES_API_ENABLED=true`; the default bind address is loopback. If deliberately enabled, it requires `API_SERVER_KEY`, binds on port 8642 for Railway private networking, and its `api_server` platform toolset is forcibly restricted to Hermes' `web` toolset at every startup. Startup also caps a review at three agent turns, one provider attempt per model iteration, and no automatic recovery cycles. The pinned Hermes `/v1/chat/completions` endpoint ignores request `max_tokens`, so this field is not treated as a cost limit. Hermes never receives the Supabase service key or a GitHub write token.
- `Dockerfile.api` runs a small standard-library-only Python service. Only this service receives the Supabase service-role key, Telegram bot token, Hermes API key, optional least-privilege GitHub issue token, and independent internal bearer token. Token-protected endpoints invoke central Supabase RPC policy functions; their caller is not allowed to pass an approval flag. Hermes never receives the GitHub or Supabase credential.
- The API health response reports database, Telegram and Hermes status separately. HTTP liveness does not imply that those external integrations are configured.
- Telegram identities are checked against the server configuration and bootstrapped once to a database setting. A later mismatch fails closed. A private one-to-one chat is required; denied identities are recorded as a one-way hash.

## Workflow boundaries

The runtime accepts founder status, budgeted proposal, pending-approval list, and explicit approval commands. The approval list uses a founder-identity-checked RPC, exposes only pending requests and outstanding reviewer roles, and writes an audit event; viewing never changes approval state. CEO/Product/CTO/CFO/PM reviews are durably queued and gated in sequence. The database provides reserve, start, and usage-reconciliation RPCs for model calls; a review cannot succeed without a reconciled reservation. A separate opt-in GitHub dispatcher leases ready Developer tasks only from founder-approved projects, creates or reuses a GitHub issue marked with the full task UUID, updates task state and audits the handoff. Signed webhook events link a PR only to that task; Developer completion requires both a merged PR and successful `CI` on the same head SHA. A database trigger enforces this condition for all task update paths. This releases QA. The same leased, spend-gated Hermes worker claims only ready QA/Security tasks with verified Developer ancestry and submits role-specific evidence through a service-role-only RPC, including acceptance criteria and the verified commit SHA. QA records named test results and links; Security records checks, findings with severity/owner/remediation, and release blockers. Evidence is stored in an RLS-protected table unavailable for direct API reads. Failed reviews block the task; passing QA releases Security and passing Security releases DevOps. Generic task updates cannot bypass these gates. The webhook cannot approve spending or merge code; branch protection must require CI.
