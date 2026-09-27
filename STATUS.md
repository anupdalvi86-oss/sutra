# Sutra Status

Updated: 2026-09-27 22:40 Europe/Stockholm

## Overall

The production foundation is running: Supabase is authoritative, Telegram is founder-restricted, Railway hosts the private API and Hermes runtime, configurable spending policies are live, and the agent worker is enabled. GitHub PR #54 is merged with green CI. The first live model calls verified OpenAI metering, but the current founder proposal stopped at Kimi because the response usage could not be verified. Sutra is **operational for founder status/proposal intake and governed agent execution, but not yet end-to-end operational for product delivery**.

## Working and verified

- **GitHub:** PR #54 (`fix: preserve founder approval after CFO review`) merged as `b59441b`. Its Python, database, container and secret-scan checks all passed; main CI run `36347900567` also passed. The CFO guidance now treats founder approval as a separate next gate rather than a prerequisite for CFO review.
- **Supabase:** Project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is `ACTIVE_HEALTHY` on PostgreSQL 17.6.1. All 18 repository migrations are applied. The live public schema has 22 tables and all have RLS enabled. Agent profiles, projects, tasks, budgets, decisions, expenses, approvals, agent runs, customers, campaigns, settings, model spend profiles and audit history are present. The model spend reservation table denies direct API access; its ledger is read through controlled operations.
- **Database governance:** The four default spending tiers are live: up to €10 automatic, over €10 to €50 department head, over €50 to under €200 CFO + CEO, and €200 or more founder. An active `ai_inference` budget is €8 per month with an 80% warning and hard stop. The two AI QA proposal projects each have a €500 project ceiling; neither ceiling authorizes project spending. No approval for the €500 project budget has been granted.
- **Financial ledger:** OpenAI GPT-6 Luna calls by CEO/CPO/CTO/CFO in earlier runs and CEO in the latest run reconciled to token usage and actual cost. The current Kimi K2.6 CPO run reserved €0.28, then failed closed with spend status `unknown`; usage and actual cost are null, and the reserve remains held. Audit events record the reservation, model-call start, unknown spend and failed run. Do not retry Kimi until its usage reporting is understood; unknown spend is never treated as zero.
- **Railway:** Production project `valiant-liberation` has Hermes `sutra` and API `sutra-api` online. Hermes has a persistent volume at `/opt/data`; its API key is private-network-only. API `/health` previously reported Supabase reachable, Telegram running, Hermes gateway running and agent worker running. `/ready` returned ready with no blockers. The API is deliberately private and has no public URL. Current exact role routes include OpenAI GPT-6 Luna by default and Kimi K2.6 for CPO, Architect and DevOps.
- **Telegram:** `@sutra86bot` is running and restricted to the configured founder in a one-to-one chat. In Chrome, the founder status command and proposal flow were verified. The latest founder proposal produced a project, objective, approval request and audit record. The latest approval is pending; it is not ready for founder decision because the CPO review failed and CFO/PM remain queued.
- **Worker safeguards:** Each model request reserves against the database-configured model profile and spending budget before reaching Hermes, then requires observed usage reconciliation before an artifact can succeed. Unknown usage keeps the maximum reserve and blocks handoff. QA and Security require GitHub evidence tied to the Developer commit. External marketing, sales, purchasing and publishing remain unavailable to the review worker.
- **Security advisor:** Supabase Security Advisor reports only its informational “RLS enabled, no policy” finding on the 22 private tables. Direct grants to `anon` and `authenticated` are withheld, and sensitive tables also have no direct service-role access. Performance Advisor reports 26 unused indexes on this new, low-traffic project; no production table access is exposed by those findings.

## Tests and security checks

- Local Python suite: **77 passed** (`python3 -m unittest discover -s tests -v`).
- Local Bandit 1.9.4: **no medium/high issues** (`python3 -m bandit -r sutra -ll`). The only warning concerns the intentional Railway bind address suppression.
- Local `compileall` and `git diff --check`: passed.
- GitHub CI on PR #54: Python, database, container and secret-scan checks passed. Database job applies migrations, executes the pgTAP policy/workflow assertions and runs database lint. Main CI after merge passed.
- Live Supabase connectivity, project status, migration history, public table/RLS inventory, spending thresholds, monthly hard stop, recent workflow rows, reservations and audit entries were queried directly.
- Local Docker is still constrained by host disk space, so hosted database/container CI is the reliable clean-environment test. No Docker cleanup or production data cleanup was performed.

## Deployment and integration state

| Component | Current status | Remaining gap |
| --- | --- | --- |
| GitHub `main` | PR #54 merged; CI green | Developer execution runner and webhook remain unconfigured |
| Supabase | Healthy; 18 migrations; 22 RLS-enabled public tables | Founder should review quota/recovery plan; general operating budgets and department-head approver are unset |
| Railway `sutra-api` | Online; private; health/readiness previously green | Recheck after next deployment; no public URL by design |
| Railway Hermes `sutra` | Online; persistent volume; private API responding | Kimi usage reporting is unresolved |
| Telegram | Running; founder-only status/proposal flow verified | Latest project approval is pending CPO/CFO reviews |
| Agent worker | Enabled; OpenAI reconciles; Kimi run fails closed | Do not route live work to Kimi until usage is accurately surfaced |
| Founder proposal | Two €500 AI QA opportunity proposals recorded; latest one is pending | Latest CPO run failed; CFO and PM are queued; no project budget approved |
| Codex/GitHub delivery | Database authorization and CI evidence gates exist | No production Codex runner, GitHub dispatcher or signed webhook delivery |
| Marketing/Sales | Role definitions and internal draft artifacts exist | Handoffs require completed workflow; no external outreach is enabled |

## Remaining blockers

1. **Kimi accounting:** The Kimi K2.6 call returned no usage shape that Sutra could reconcile. A €0.28 reserve remains unknown/held. Inspect the exact Hermes/Kimi response path before retrying. For production proposals, route all roles to OpenAI GPT-6 Luna until Kimi usage is verified; changing this route requires a Railway deployment/config update.
2. **Live approval journey:** The current proposal is pending because CPO failed; CFO and PM have not run, so founder approval controls are not yet exercised end to end after the CFO fix. Do not approve the €500 request automatically.
3. **Engineering delivery:** No production Codex runner consumes approved tasks and creates PRs. The GitHub issue dispatcher and signed webhooks are disabled/unconfigured, and the API intentionally has no public ingress for GitHub webhook delivery.
4. **Operating budgets:** No department-head approver or general company/department operating budget is configured. Amounts in the €10–50 tier remain fail-closed until the founder designates a department head.
5. **Release operations:** Railway wait-for-CI and branch protection are not enabled. Confirm a recoverable Supabase backup point before future production DDL. Hermes logs have a generic warning about its local terminal backend; Sutra's API server toolset is restricted, but avoid giving Hermes untrusted shell execution until that runtime setting is hardened.
6. **Credential hygiene:** The founder supplied Telegram, OpenAI and Kimi credentials directly in this thread and authorized their use on Railway. They are not in Git. Replace/revoke these keys when convenient; do not post replacements in chat or the repository.

## Recommended next steps

1. Inspect Hermes' exact Kimi response/usage behavior and keep unknown reservations held until trustworthy token counts or provider invoice usage can be matched.
2. Use the Railway private console or service variables to move CPO off Kimi before retrying any live proposal; keep the monthly €8 hard stop active.
3. Retry/re-submit the opportunity proposal through Telegram only after the model route is fixed. Verify CEO → CPO → CTO → CFO → PM; then let the founder decide on the displayed approval request.
4. Before any product build, enable a least-privilege GitHub issue token, secure webhook ingress and deploy a Codex runner with the existing authorization and metering gates.
5. Configure department ownership, ordinary operating budgets, Railway CI gating and Supabase recovery coverage.
6. Rotate credentials after the base workflow is verified and update Railway variables directly.
