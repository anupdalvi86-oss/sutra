# Sutra status

Updated: 2026-09-28 (Europe/Stockholm)

## Working

- **Production services:** Railway production project `valiant-liberation` has both `sutra-api` and the Hermes `sutra` service online. Hermes has a persistent Railway volume mounted at `/opt/data`; internal endpoints are private. The API `/ready` endpoint was probed from its live Railway console on 2026-09-28 and returned HTTP 200, `ready: true`, with Supabase reachable, Telegram and the worker running, and the signed GitHub webhook configured.
- **Telegram:** `@sutra86bot` is running and restricted to founder ID `8776723105`. Board-style status commands, the approval queue, proposal intake, and founder-only retry flows have been exercised in the logged-in Telegram session. Status summaries include projects, tasks, blockers, approvals, and financial controls from persisted Supabase data.
- **Supabase:** project `smqsrigsugjuvuombetq` is `ACTIVE_HEALTHY`, PostgreSQL 17.6. The latest hosted migration is `20260928092906_task_artifact_approval_context`; all 29 repository migrations are recorded. Public operational tables have RLS enabled; client roles have no direct table access. Founder approvals and policy changes use audited, restricted database functions.
- **Configured financial authority:** live database policies implement automatic spend through €10, department-head review above €10 through €50, CFO + CEO above €50 through €200, and founder review from €200. The €10–50 band fails closed until a department head is assigned. A monthly €8 AI inference budget has an 80% warning and hard stop. Three €500 project ceilings exist from duplicate proposal records; only project `58c52b74-8f15-4174-a079-e869e3df713c` is approved. No total company operating budget is configured.
- **Audit and model spend:** the live audit table contains 184 records at the latest query. The provider ledger has €0.19 reconciled actual usage and €0.40 in five unknown-usage reservations, all retained under the €8 monthly cap. This includes a €0.28 Kimi HTTP 429 with unverifiable usage and four OpenAI reservations. No unknown amount has been estimated or released. Production routes all roles to OpenAI GPT-6 Luna; Kimi is not routed.
- **GitHub delivery controls:** PRs #97, #98 and #99 are merged. CI passed Python, database/pgTAP/lint, container and secret-scan jobs. The Railway token authenticated through GitHub `/user` as the repository owner. Its GitHub settings show only Sutra selected, with Metadata read, Issues read/write, Contents read/write, Pull Requests read/write, and Actions read; no Administration permission is present. Dispatcher and Codex runner remain disabled until the founder confirms the product scope. No production Codex task has run.

## Current project and workflow

The AI QA opportunity has three proposal records from repeated submissions: one €500 request was rejected, one €500 request is approved, and one duplicate €500 request remains pending. The approved project is `AI QA product opportunity` (`58c52b74-8f15-4174-a079-e869e3df713c`). PM and Architect planning tasks have persisted artifacts. The PM plan is research-first and gates prototype implementation on a founder-reviewed scope, validation evidence, and approved representative scenarios. The approved project ceiling does not itself authorize individual purchases or external research outreach.

A successful PM planning artifact exists and the approved project has a bounded task chain. The Architect recovery succeeded and persisted a technical design after the latest migration supplied the founder-approved project flag and prior PM/CPO artifact context. The two new provider attempts reconciled at €0.02 total; the old €0.03 unknown reservation remains held. The successful Architect artifact is a draft and explicitly requires target-user, data-handling, evaluation-scope and validation decisions before prototype work. The CPO research task and generic Developer task are marked ready; five QA/Security/DevOps/Marketing/Sales tasks remain backlog. The Codex dispatcher/runner are disabled. The Developer task's database ready state does not itself mean the unreviewed PM scope is approved. No product-code PR, release, external sales message, or marketing campaign has been produced.

## Checks performed

- Production Supabase connectivity, migration history, RLS/table inventory, spending policies, budgets, project/task/approval state, spend reservations, and audit count were queried on 2026-09-28.
- Production Railway `/ready` returned HTTP 200 and `ready: true`; both Railway services showed Online.
- Founder Telegram status and approval commands were exercised. The run that generated the PM artifact reconciled €0.01 and persisted an artifact; the Architect attempt failed closed on unknown usage and retained its reserve.
- PRs #97–#99 passed all required GitHub Actions checks before merge.
- Local Python suite after PR #99: `python3 -m unittest discover -s tests -q` (128 passed); `python3 -m compileall -q sutra tests`; Bandit (`python3 -m bandit -q -r sutra -ll`, no high/medium findings; existing network-binding B104 warning); and `git diff --check` passed.
- An earlier local Supabase Docker stack attempt could not complete because the Docker VM ran out of storage. Hosted database migration, pgTAP, and lint jobs pass in CI. Supabase advisor findings previously included informational RLS-without-policy notices; direct client grants remain revoked.

## Blockers and remaining work

1. **Founder scope decision:** review the PM plan and Architect design; confirm target user, QA workflow, validation scenarios, data handling and whether founder-provided research participants are available. Until then, no product prototype or external research outreach should begin.
2. **Codex engineering lane:** the production fine-grained token now authenticates and has the narrow repository permissions listed above. Keep the opt-in dispatcher/runner disabled until the founder confirms the specific product scope. Then exercise issue → branch/PR → same-SHA CI → QA → Security evidence. No live Codex task has run.
3. **Launch handoff:** Marketing and Sales outputs are internal drafts only. No real outreach, payment, agreement, or production release has occurred.
4. **Credential hygiene:** credentials previously shared in chat should be rotated after the base flow is verified. Keep replacement values only in the relevant private Railway variables; do not put them in chat, GitHub, or this repository.
5. **Budgets:** assign a department head through the founder-audited flow before using the €10–50 approval tier, and set company/department/agent/vendor limits if required. Current €8 is specifically an inference budget, not the total company budget.

## Deployment and links

- Railway production project: [valiant-liberation](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce)
- API service: [sutra-api](https://railway.com/project/462f22f9-9a79-4259-baf6-46af692c994b/service/9446fcb9-cf68-49d8-b998-3e1d4bef3019?environmentId=79e08b42-8d33-4cf2-a61c-08efa16075ce), private; no public API URL
- Hermes: `sutra`, private; volume mounted at `/opt/data`
- Telegram: [@sutra86bot](https://t.me/sutra86bot)
- GitHub: [anupdalvi86-oss/sutra](https://github.com/anupdalvi86-oss/sutra)
- Supabase: `smqsrigsugjuvuombetq`, `ACTIVE_HEALTHY`
