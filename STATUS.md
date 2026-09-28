# Sutra status

Updated: 2026-09-28 22:18 Europe/Stockholm

## Working

- **Supabase:** project `smqsrigsugjuvuombetq` is reachable and `ACTIVE_HEALTHY`. Founder-gated Codex retry migration is applied. Supabase remains the source of truth for projects, tasks, approvals, spending rules, reservations and audit events.
- **Railway:** production project `valiant-liberation` has Hermes `sutra` and API `sutra-api` Online. The latest merged code is `b24230c` (PR #127); the API's `/health` probe returned HTTP 200 after deployment. Both services remain private. Hermes state uses the persistent volume at `/opt/data`.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) is restricted to founder ID `8776723105`. Board-style CEO/department status, proposal intake, approval listing and founder-only retry commands have been exercised in the logged-in founder chat.
- **Founder command workflow:** an AI QA product proposal completed CEO → CPO → CTO → CFO → PM and persisted role artifacts. One project is approved with a requested ceiling of €500; two separate proposals remain proposed, with one project-budget approval pending. The approved project ceiling does not authorize individual purchases or external outreach.
- **Financial controls:** database-configured defaults remain automatic through €10, department-head review above €10 through €50, CFO + CEO above €50 through €200, and founder review at/above €200. A monthly €8 AI-inference hard stop has an 80% warning. The €10–50 band fails closed until a department head is assigned. No total company operating budget is configured. Unknown reservations remain held and are never estimated or released.
- **GitHub:** repository-scoped GitHub access now verifies and signs existing issue [#107](https://github.com/anupdalvi86-oss/sutra/issues/107), and the runner checked out the repository. PR #127 added explicit Codex model-provider routing through the metering proxy; all four CI jobs passed and it was merged. It did not change project scope or financial authority.

## Current engineering attempt

The founder-approved Developer task `269cd305-2a8c-46a7-abb7-3d00f271d78f` remains `in_progress`, linked to issue #107. Its single permitted founder retry was accepted and audited. Railway claimed that run, but Codex CLI exited before it made a model request because it ignored the environment-only base URL and defaulted to the public endpoint with the runner's dummy key.

PR #127 fixes this by generating a private `$CODEX_HOME/config.toml` that selects Sutra's loopback Responses provider. Codex CLI 0.157.1 was smoke-tested with a dummy key and a local rejecting endpoint; its request reached the configured `/v1/responses` loopback endpoint. The change is deployed to Railway and both services are Online. **The production task has not been retried against the fix:** its database-enforced one-retry limit is exhausted. Supabase records zero model requests and zero tokens for the failed run; the old unknown reservation remains held, and the fresh retry reservation is also preserved. No production model usage or implementation PR resulted.

## Current operational counts

Latest live Supabase query:

- Projects: 1 approved, 2 proposed.
- Tasks: 2 done, 1 ready, 1 in progress, 5 backlog, 2 blocked.
- Pending approvals: 1 project-budget approval (`539a8225-1230-4896-87d2-b48e7c28ae82`) for a separate proposed project.
- The approved AI QA project has not been released. No real sales/marketing messages, purchases, agreements, or deployments of a product have occurred.
- QA and Security agent handoffs remain deferred by founder direction.

## Checks performed

- Full Python suite: `python3 -m unittest discover -s tests` — 155 passed.
- Python compile check: `python3 -m compileall -q sutra tests` — passed.
- Bandit: no medium/high findings.
- Gitleaks 8.30.1: no leaks found.
- PR #127 GitHub CI run [36477574459](https://github.com/anupdalvi86-oss/sutra/actions/runs/36477574459) passed Python, database/pgTAP/lint, container/runtime, and secret-scan jobs.
- Codex CLI 0.157.1 isolated smoke: local test server received the Responses request at `/v1/responses`; the key was a dummy value and no production provider call was made.
- Railway after PR #127: both services showed Online and `sutra-api` `/health` returned HTTP 200.
- Supabase production project was queried for task state, the retry execution, reservations and the corresponding audit record.

## Remaining work and blockers

1. **Additional founder authorization is required to retry:** the database intentionally permits only one no-request retry, and it has been used. To run the same approved scope again, the founder must authorize a narrowly scoped extension of the founder-only retry gate for one further zero-request attempt. Existing spend limits and project/task approvals must remain unchanged. No more execution should be triggered until that authorization is recorded.
2. After authorization, add and deploy the audited retry-gate migration, then verify the metering proxy receives the production run before any model response is returned. Continue only under the existing €8 monthly hard cap.
3. If the task reaches implementation, the runner may create a branch and PR but cannot merge or release. Keep CI evidence attached to the PR. QA and Security role handoffs are deferred by founder direction.
4. The CPO-only Kimi route has no post-rollout usage-reconciliation evidence; an earlier €0.28 unknown reservation remains held. A separate proposed €500 project-budget approval remains pending.
5. Rotate credentials previously shared in chat after base-flow verification. The €8 cap covers AI inference only, not all company operations.

## Deployment and links

- Railway production project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- API service: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce), private
- Hermes service: `sutra`, private, persistent volume mounted at `/opt/data`
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase: `smqsrigsugjuvuombetq`, `ACTIVE_HEALTHY`
