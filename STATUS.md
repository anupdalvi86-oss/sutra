# Sutra Status

Updated: 2026-09-27 (Europe/Stockholm)

## Overall

The governed company-state foundation is merged (PR #46; feature commit `a279193`). Follow-up live-state documentation and migration-history alignment were merged in PRs #47–51. Supabase and the private Railway API are connected, and the founder-only Telegram status command has replied successfully. Founder-audited pricing profiles are now active for OpenAI GPT-6 Luna and Kimi K2.6, with an €8/month AI-inference hard stop. Sutra is **operational for health/status checks and database-enforced governance workflows**, but it is **not yet an autonomous operating company**: Hermes model access and the worker route are not live yet, and no live proposal-to-release run has been completed.

## Working and verified

- **GitHub:** The feature foundation (PR #46) and live-state documentation/migration-history updates (PRs #47–48) are merged. PR #51 CI passed all four jobs: Python/compile/Bandit, database migrations + 170 pgTAP assertions + database lint, container checks, and secret scanning. No credentials are committed.
- **Supabase:** Project `sutra` (`smqsrigsugjuvuombetq`, `eu-central-1`) is `ACTIVE_HEALTHY` on PostgreSQL 17.6. The API connected successfully. A live audit-log read returned the founder approval-queue access and founder-identity bootstrap entries. Company state, 14 roles, approval flows, audit records, and configurable spending rules live in Supabase. The metered Codex execution migration (`20260927182221`) and approval FK index migration (`20260927191656`) are live. The protected table has RLS and the service role cannot directly read/write execution rows. A fresh Performance Advisor check found zero unindexed foreign keys; 34 unused indexes remain informational on this low-traffic project.
- **Financial governance:** Threshold policies are database-backed and configurable: `<= €10` automatic, `> €10 to €50` department head, `> €50 to < €200` CFO + CEO, and `>= €200` founder. Limits support transaction, period, company, project, department, agent, category and vendor scopes, warnings and hard stops. Founder-only audited functions prevent agent self-escalation. A monthly `ai_inference` budget is active at €8 with an 80% warning and hard stop. Current DB prices are GPT-6 Luna €0.0877/€0.4385 per million input/output tokens and Kimi K2.6 €0.8332/€3.5079, with 100k input/2,200 output token ceilings; both profile changes and the budget update appear in the founder audit log. General operating budgets and a department-head approver still need founder configuration before non-AI routine spend.
- **Workflow foundation:** Automated database tests simulate Founder → CEO/Product/CTO/CFO/PM review → founder approval → PM/Architect/Developer/QA/Security/DevOps/Marketing/Sales task chain. GitHub PR/CI evidence gates Developer completion; QA and Security evidence gates later handoffs. This is a CI/database simulation, not a live Telegram proposal or production release.
- **Railway:** Production project has two private services, `sutra-api` and Hermes `sutra`, with persistent Hermes volume. Latest API deployment is Active; both services are Online. There is no public API deployment URL because the API remains private. The protected Hermes API is listening on Railway private networking. Its log showed a stale `API_SERVER_KEY` in the mounted `/opt/data/.env` overriding the newly configured service variable. The Sutra startup fix removes that duplicate; it is awaiting PR CI/merge and a Hermes redeploy. The Sutra worker is disabled, and no model request has been exercised.
- **Telegram:** `@sutra86bot` is validated through Telegram Bot API `getMe`. Founder identity is configured as `8776723105` in the application and Supabase. The private API reports `telegram: running`; `/ready` returned `ready` with no blockers for currently enabled integrations. The founder sent “CEO, give me company status.” in Chrome and received a reply showing 0 projects, 0 open tasks and 0 pending approvals. This verifies founder routing and status lookup, not model-driven delegation. Secrets remain in Railway variables and are not recorded here.
- **HTTP checks:** Railway API `/health` reports `status: ok`, database reachable and Telegram running. `/ready` reported `ready: true`; Hermes gateway integration is not configured, and the model worker, GitHub dispatcher and webhook are disabled/unconfigured.

## Tests and security

- PR #51 CI passed all four jobs, including 170 pgTAP assertions, all Python tests (68), Bandit 1.9.4, API/Hermes container checks, DB lint, and Gitleaks. Latest local run of the expanded suite: 76 passed; Bandit 1.9.4 reports zero medium/high issues.
- The CI policy tests cover threshold boundaries, exhausted budgets, founder-only governance actions, agent self-escalation denial, approvals, reservations/reconciliation, RLS/grants and audit logging.
- The same workflow CI includes application routing/authentication, malformed request, Codex task signing/dispatch, and API readiness tests.
- Live checks confirm all 22 public tables have RLS, `anon` cannot read Codex execution rows or call its authorization RPC, and `service_role` can call the RPC but has no direct table SELECT/INSERT. The new approval FK index is visible and the Performance Advisor now reports no unindexed foreign keys. No Codex executions were created during verification.
- Local Supabase Docker startup has previously failed because the host ran out of Docker disk; this turn's Hermes image build also failed locally with Colima `no space left on device`. Hosted Supabase connectivity and GitHub-hosted migration/policy CI are healthy. No Docker cleanup was attempted.

## Deployment and integration state

| Component | State | Notes |
| --- | --- | --- |
| GitHub main | Feature foundation and follow-up docs/index PRs #46–51 | CI green |
| Supabase | Healthy / reachable | Latest migration `20260927191656`; two active model profiles; €8 monthly AI-inference hard stop; no unindexed FKs |
| Railway `sutra-api` | Online / private | `/health` OK, `/ready` ready; DB and Telegram verified |
| Railway Hermes `sutra` | Online | Persistent volume; protected API on private network; stale-key override fix pending deploy |
| Telegram `@sutra86bot` | Running | Founder-only status request/reply verified |
| Agent/model worker | Disabled | Database profiles and €8 hard stop active; worker waits for matching Hermes key verification |
| Codex execution | Guarded foundation only | Spend-reserved DB authorization exists; no live execution has been run |
| GitHub dispatcher/webhook | Disabled / unconfigured | Needs a least-privilege token, webhook secret/registration and enablement |
| Marketing/Sales | Internal artifacts only | No external messages sent |

## Remaining blockers

1. **Model execution:** Merge/deploy the persistent-key fix, verify the private key handshake and Hermes health probe, then enable the role-routed worker. Run only a capped, audited founder-requested workflow under the €8 database hard stop.
2. **Engineering automation:** Configure a least-privilege GitHub issue token, webhook secret and repository webhook for `pull_request` and `workflow_run`; then validate signed evidence before enabling the dispatcher. PR/CI evidence and spend-gated Codex authorization are implemented, but no live Codex task has produced a PR.
3. **Real approval journey:** Send and exercise a real bounded proposal through Telegram, complete research and CFO review, and test founder approve/reject. This depends on model execution. The end-to-end approval chain currently has CI/database evidence only.
4. **Financial operating limits:** Founder must set actual company and relevant department/project/agent/category/vendor/period budget amounts, warning thresholds and active department approver. Current schema/policies enforce controls, but zero active general budget rows means routine spend should remain blocked.
5. **Railway release gating:** Enable wait-for-CI after resolving Railway's pending GitHub app permission step. Until then, deployments are not gated on CI.
6. **Recovery:** Recheck Supabase quota/plan warning and confirm a recovery point/restore path before future production schema changes. No paid plan was changed.
7. **Credential hygiene:** The Telegram token was shared in chat and installed at the user's direction. Revoke/rotate it after setup validation, along with any other credentials the founder considers exposed. Do not place replacement credentials in chat or GitHub.

## Recommended next steps

1. Set real operating budget caps and designate a department approver using the founder-only audited policy flow.
2. Deploy the private Hermes API with the staged provider secrets and validate exact-route Kimi/OpenAI calls through the spend-gated worker.
3. Run the Telegram proposal → CFO → founder approval journey; confirm audit and approval rows in Supabase.
4. Configure the GitHub webhook/token and validate a test task through Codex, PR, CI, QA and Security evidence before enabling autonomous dispatch.
5. Enable Railway wait-for-CI and confirm Supabase recovery coverage.
6. Rotate shared credentials, then update the Railway variables directly with the replacements.
