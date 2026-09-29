# Sutra system status

Updated: 2026-09-30

## Current state

Sutra runs a budget-gated internal workflow with Supabase as company-state authority, Telegram as the founder interface, and a private Railway API/Hermes deployment. It is not yet a fully autonomous operating business. CRM, customer support, and email integrations are not configured, and this implementation has not sent customer messages or launched live marketing.

The founder's standing authorization for real work in `anupdalvi86-oss/sutra` covers scoped Developer tasks, branches, PRs, merges, QA, Security, and deployment. It does not grant spending authority. Supabase records the active grant and audits actions. The fresh Sutra Developer task is scoped to an explicit EUR 0 initiative budget; paid provider work remains blocked until the founder sets a budget. Exhausted task #107 was not retried. Unknown reservations remain held and unchanged.

## Verified production state before this sprint PR

- **Supabase:** Production project `smqsrigsugjuvuombetq` is reachable and healthy. Production history includes the all-in initiative ledger, bounded agent leases, legal escalation, and founder standing code authorization. The new pre-merge release-gate migration is not yet applied.
- **Financial controls:** Database-configured limits and the EUR 8 monthly AI-inference hard stop are active. The Sutra implementation initiative has EUR 0 paid-work authority. Existing unknown reservations have not been changed.
- **Railway:** After merged PR #211, `sutra-api` and Hermes were Online; `/health` returned 200 and the founder's standing-authority Telegram command worked. The API and Hermes services are private. The new release worker is not yet deployed or enabled.
- **GitHub:** PR #209 (all-in initiative budget), #210 (bounded parallel proposal reviews), and #211 (standing founder code authorization) are already merged. Do not recreate them. There was no open PR before this sprint branch.
- **Telegram:** The registered founder identity remains restricted to Telegram user `8776723105`. Board-style status, approval, governance, and bounded recovery commands are available.

## This sprint release gate

The branch adds pre-merge QA and Security tasks tied to the exact open PR head, plus a separate opt-in merge worker. Matching successful CI releases QA; passing QA releases Security; merge requires both passing records, the same tested SHA, an active standing founder grant, an approved in-scope task/project, and a last-moment policy check. A changed PR head invalidates old review evidence. The GitHub merge request is squash-only to `main` with the expected head SHA. Database claims, outcomes, and the company status snapshot are audited. The worker has no model-provider access and defaults off until explicitly enabled.

This stage does not provide CRM, customer support, or email integrations. It does not send real customer messages or run paid operations.

## Verification in this stage

- Python suite: **246 passed**.
- Bandit (`-ll`): passed; one existing B104 bind-address warning is reported as a test-code warning.
- Python compilation: passed.
- `git diff --check`: passed.
- Fresh disposable Supabase local reset: attempted but the Docker/Postgres container did not become reachable; local pgTAP and database lint are **not verified** in this environment. The final hosted PR database workflow must pass before merge.
- Railway state for this new release-gate PR: not yet deployed or checked.

## Remaining work and blockers

1. Pass hosted CI, including full Python, security, migration/pgTAP, database lint, container, and secret checks.
2. Apply the reviewed migration, merge the consolidated sprint PR, then check Railway once if the merge triggers a deployment; confirm health and a quick smoke check.
3. Enable the release worker only after the migration is live and deployment health is confirmed. The worker is opt-in and uses existing private GitHub/Supabase credentials; enabling it does not authorize paid model work.
4. CRM, customer-support, and email providers still need implementation and founder-provided credentials. Until then, Sutra cannot execute real customer lifecycle work.
5. Paid implementation work needs a separate non-zero, all-in initiative budget; the current Sutra project budget is EUR 0. No budget authority was changed.

## Next steps

Finish SQL verification through hosted CI, open one consolidated sprint PR, merge only after required checks pass, apply/verify the production migration, and perform the one-time Railway health/smoke check if a deployment occurs. Then continue free implementation within the current zero-spend boundary and report provider credentials or budget decisions only where they are actually needed.
