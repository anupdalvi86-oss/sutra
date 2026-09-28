# Sutra status

Updated: 2026-09-28 23:00 Europe/Stockholm

## Working

- **Supabase:** project `smqsrigsugjuvuombetq` is reachable and `ACTIVE_HEALTHY`. The live project is healthy; the new founder-adjustable retry-limit migration is in PR #131 and is not yet applied. Supabase remains the source of truth for projects, tasks, approvals, spending rules, reservations and audit events.
- **Railway:** production project `valiant-liberation` has Hermes `sutra` and API `sutra-api` Online. The latest merged code is `39c27f8` (PR #129); Railway shows its deployment active/successful and the API's `/health` probe returned HTTP 200. Both services remain private. Hermes state uses the persistent volume at `/opt/data`.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is restricted to founder ID `8776723105`. Board-style CEO/department status, proposal intake, approval listing and founder-only retry commands have been exercised in the logged-in founder chat.
- **Founder command workflow:** an AI QA product proposal completed CEO → CPO → CTO → CFO → PM and persisted role artifacts. One project is approved with a requested ceiling of €500; two separate proposals remain proposed, with one project-budget approval pending. The approved project ceiling does not authorize individual purchases or external outreach.
- **Financial controls:** database-configured defaults remain automatic through €10, department-head review above €10 through €50, CFO + CEO above €50 through €200, and founder review at/above €200. A monthly €8 AI-inference hard stop has an 80% warning. The €10–50 band fails closed until a department head is assigned. No total company operating budget is configured. Unknown reservations remain held and are never estimated or released.
- **GitHub:** repository-scoped GitHub access verifies and signs existing issue [#107](https://github.com/anupdalvi86-oss/sutra/issues/107), and the runner checked out the repository. PR #127 added explicit Codex model-provider routing through the metering proxy. PR [#129](https://github.com/anupdalvi86-oss/sutra/pull/129) adds allowlisted Hermes completion metadata to missing-usage diagnostics; all four CI jobs passed and it was deployed. Neither PR changed project scope or financial authority.

## Current engineering attempt

The founder-approved Developer task `269cd305-2a8c-46a7-abb7-3d00f271d78f` remains `in_progress`, linked to issue #107. Its single permitted founder retry was accepted and audited. Railway claimed that run, but Codex CLI exited before it made a model request because it ignored the environment-only base URL and defaulted to the public endpoint with the runner's dummy key.

PR #127 fixes this by generating a private `$CODEX_HOME/config.toml` that selects Sutra's loopback Responses provider. Codex CLI 0.157.1 was smoke-tested with a dummy key and a local rejecting endpoint; its request reached the configured `/v1/responses` loopback endpoint. The change is deployed to Railway and both services are Online. **The production task has not yet been retried against the fix:** the live database still has the old retry ceiling. PR #131 adds a three-total-attempt default and founder-only audited control, pending CI and production migration. Supabase records zero model requests and zero tokens for the failed run; the old unknown reservation remains held, and the fresh retry reservation is also preserved. No production model usage or implementation PR resulted.

## Current operational counts

Latest live Supabase query:

- Projects: 1 approved, 2 proposed.
- Tasks: 2 done, 1 ready, 1 in progress, 5 backlog, 2 blocked.
- Pending approvals: 1 project-budget approval (`539a8225-1230-4896-87d2-b48e7c28ae82`) for a separate proposed project.
- The approved AI QA project has not been released. No real sales/marketing messages, purchases, agreements, or deployments of a product have occurred.
- QA and Security agent handoffs remain deferred by founder direction.

## Checks performed

- Full Python suite: `python3 -m unittest discover -s tests` — 156 passed.
- Python compile check: `python3 -m compileall -q sutra tests` — passed.
- Bandit: no medium/high findings.
- Gitleaks 8.30.1: no leaks found.
- PR #127 GitHub CI run [36477574459](https://github.com/anupdalvi86-oss/sutra/actions/runs/36477574459) passed Python, database/pgTAP/lint, container/runtime, and secret-scan jobs.
- PR #129 GitHub CI run [36480418155](https://github.com/anupdalvi86-oss/sutra/actions/runs/36480418155) passed Python, database/pgTAP/lint, container/runtime, and secret-scan jobs. Local validation also passed Bandit 1.9.4 (`-ll`) and Gitleaks 8.30.1.
- Codex CLI 0.157.1 isolated smoke: local test server received the Responses request at `/v1/responses`; the key was a dummy value and no production provider call was made.
- Railway after PR #127: both services showed Online and `sutra-api` `/health` returned HTTP 200.
- Supabase production project was queried for task state, the retry execution, reservations and the corresponding audit record.

## Remaining work and blockers

1. PR #131 implements the already founder-authorized extension to three total attempts for this same approved Developer task and scope. Its production migration and Telegram command are pending passing CI, database application, and Railway deployment. Changing the setting will not itself retry the task.
2. Once the setting and code are live, verify the stored limit and audit trail, then request the final permitted attempt only if Supabase still confirms a terminal failure with zero requests/tokens. Preserve the unknown reservation and reserve fresh spend under the existing €8 monthly hard cap.
3. If the task reaches implementation, the runner may create a branch and PR but cannot merge or release. Keep CI evidence attached to the PR. QA and Security role handoffs are deferred by founder direction.
4. The CPO-only Kimi route has no post-rollout usage-reconciliation evidence; an earlier €0.28 unknown reservation remains held. PR #129 improves sanitized diagnostics for a future database-reserved reproduction, but does not establish the historical cause. Kimi remains disabled. A separate proposed €500 project-budget approval remains pending.
5. Rotate credentials previously shared in chat after base-flow verification. The €8 cap covers AI inference only, not all company operations.

## Deployment and links

- Railway production project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- API service: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce), private
- Hermes service: `sutra`, private, persistent volume mounted at `/opt/data`
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase: `smqsrigsugjuvuombetq`, `ACTIVE_HEALTHY`
