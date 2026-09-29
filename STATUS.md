# Sutra status

Updated: 2026-09-29 11:42 Europe/Stockholm

## Working

- **Production runtime:** Railway project `valiant-liberation` has the private Hermes `sutra` and `sutra-api` services online. The API deployment for PR [#174](https://github.com/anupdalvi86-oss/sutra/pull/174) is active and successful (deployment `53554713-c92f-42a1-8a72-0c17c594cd70`). A live Telegram status request completed through the deployed worker. Hermes state is on the persistent `/opt/data` volume.
- **Supabase:** project `smqsrigsugjuvuombetq` is `ACTIVE_HEALTHY`. The founder-only CPO recovery migration is applied. Supabase remains authoritative for company tasks, project approvals, model spend reservations, spending policy, and audit history.
- **Telegram:** [@sutra86bot](https://t.me/sutra86bot) responds to the configured founder ID `8776723105`. CEO and department briefs include projects, objectives, task queues, blockers, approvals, and budget controls. The founder-adjustable Codex no-request retry limit is 3 total attempts (hard maximum 3); changing it is audited and does not retry work.
- **Financial controls:** database policies enforce configurable thresholds: automatic at/below €10, department head above €10 through €50, CFO + CEO above €50 and below €200, and founder at/above €200. The €10–50 band fails closed until a department approver is assigned. AI inference has an €8 monthly hard stop and 80% warning. No company-wide operating budget is configured.
- **GitHub:** repository is public. Sutra dispatches founder-approved engineering tasks to GitHub and Codex can open a branch and PR, but cannot merge or release. CI requires Python, database/pgTAP/lint, container/runtime and secret-scan jobs.

## Current operating state

Supabase currently has 1 approved project and 2 proposed projects. Of 11 tasks, 4 are done and 7 are open: 4 backlog and 3 blocked. One €500 project-budget approval is pending for a proposed duplicate project. No campaign or customer/lead records are present.

The approved CPO research task `9033583d-0867-4dde-9f55-df9f58d51c71` completed through the Telegram retry command. Its market-research artifact is persisted. The new OpenAI GPT-6 Luna reservation was €0.03 and reconciled to €0.01 for 52,154 input and 1,991 output tokens. The earlier malformed Kimi response remains unverified; its €0.28 reservation is still held and has not been estimated or released. Across the company, 8 unknown reservations totaling €0.74 remain held. Reconciled AI-inference spend this month is €0.21 against the €8 cap.

Developer task [#107](https://github.com/anupdalvi86-oss/sutra/issues/107) is now `done`. PR [#160](https://github.com/anupdalvi86-oss/sutra/pull/160) is merged, and its successful CI run `36541235879` used the same head SHA as the merged PR. The task was reconciled through the guarded `sutra_update_task` workflow and the change was audit logged. Its earlier Codex process used three metered requests and failed, so that execution remains in history and is not retry eligible.

The founder deferred QA and Security handoffs. The QA task is blocked at spend preflight (`spend_preflight_unavailable`), before any provider request or reservation; no QA model call occurred. Security, DevOps release/rollback, Marketing, and Sales handoffs remain in backlog. Two proposed-project CPO research tasks are blocked without linked execution evidence; do not treat these as completed research. The approved AI QA product is not released. No real sales/marketing messages, purchases, agreements or product release were made.

## Latest verification

- PR #174 passed all five CI jobs: Python, database/pgTAP/lint, containers, secret scan and change detection. Its 73 focused runtime tests and the full CI Python suite passed; `compileall` and `git diff --check` passed locally.
- Local validation for the CPO recovery change passed 193 Python tests, 406 database assertions, database lint, `compileall`, and `git diff --check`.
- Production Supabase accepted the recovery migration. Live CPO execution completed, persisted the artifact, and reconciled known usage while preserving the earlier unknown Kimi reservation.
- PR #160 is merged with successful CI evidence bound to its exact head SHA. Its linked Developer task is complete in Supabase.
- Railway reports `sutra-api` Online on PR #174’s successful deployment. A live Telegram founder status request returned the updated board brief, including PR #160 merged and CI success on the same commit, with no false GitHub delivery warning. Hermes remains Online with its persistent volume configured.
- Live financial state: €0.21 reconciled AI-inference spend this month, €8 hard stop, 8 unknown reservations totaling €0.74 still held, and 1 pending project-budget approval.

## Remaining work and blockers

1. Complete remaining CEO/department work and internal Marketing/Sales drafts. Keep all outreach internal until the founder explicitly authorizes external messages.
2. Resolve the pending €500 project-budget approval only if the founder wants the proposed duplicate project; the already-approved project remains separately capped at €500.
3. QA and Security agent reviews remain deferred by founder direction. QA was blocked before making a provider request. Two proposed-project CPO research tasks also need a founder decision on whether those duplicate proposals should proceed.
4. Railway logs warn that the internal API is bound to `0.0.0.0` while Hermes uses a local, unsandboxed terminal backend. Railway lists the API as unexposed, but this runtime hardening remains outstanding.
5. Rotate credentials previously shared in chat after base-flow validation and replace them directly in private Railway variables. The €8 cap covers AI inference only, not all company operations.
6. Unknown reservations must stay held unless provider evidence permits exact reconciliation.

## Deployment and links

- Railway production project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- API service: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce), private
- Hermes service: `sutra`, private, persistent volume mounted at `/opt/data`
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase: `smqsrigsugjuvuombetq`, `ACTIVE_HEALTHY`
