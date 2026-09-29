# Sutra system status

Updated: 2026-09-30

## Current state

Sutra is a working internal, budget-gated agent workflow, not yet an autonomous operating business. Production Supabase remains the company-state authority. Telegram is the founder command interface. Railway hosts the private API and Hermes runtime. GitHub Actions validates changes and the Codex runner can open issues, branches, and PRs.

The founder has granted standing authority for real code work in anupdalvi86-oss/sutra, including task creation, branches, PRs, merges, QA, Security, and deployment. It does not increase any initiative budget or authorize customer contact, paid work without a budget, contracts, or legal commitments. This change records that grant in Supabase with a fixed repository/capability scope, founder-only revocation, and audit events. A fresh Developer task is created under an explicit EUR 0 all-in budget; provider execution must remain blocked until a non-zero budget is separately authorized. Task #107 is exhausted and is not retried.

## Verified production state

- **Supabase:** Project smqsrigsugjuvuombetq is reachable. The initiative ledger and two-slot worker lease schema are present. Migration history contains 58 versions through parallel_proposal_reviews. There are 40 actual ledger rows and 16 unknown reservations; the unknown reservations total EUR 1.06 and remain held. Reconciled actual ledger amounts total EUR 0.40.
- **Company records:** 5 approved and 1 rejected project; 13 done, 8 backlog, 2 blocked, 4 deferred, and 1 cancelled task. There are 5 approved and 1 rejected approval records, with no pending approvals.
- **Financial controls:** Configurable Supabase policies govern spend approval bands and company/project/department/agent/category/vendor/time limits. The AI inference monthly hard stop is EUR 8. The initiative ledger covers model use and operating costs, preserves unknown amounts, and enforces each initiative's explicit all-in ceiling.
- **Railway:** sutra-api is Online in production and remains private/unexposed; /health returned 200 for the active PR #210 deployment. Hermes is Online and uses the persistent sutra-volume at /opt/data. Keep API worker concurrency at one because the provider account was observed to allow one concurrent request.
- **GitHub:** PR [#209](https://github.com/anupdalvi86-oss/sutra/pull/209) (all-in initiative budget) and PR [#210](https://github.com/anupdalvi86-oss/sutra/pull/210) (parallel proposal reviews and bounded worker slots) are merged. Their required checks passed. Both production migrations are applied.
- **Telegram:** Founder ID 8776723105 is the configured founder. Existing status and approval commands are implemented. The legal inbox and standing-code-authority commands are included in this pending change and will be live after merge, migration, and audit-log activation.
- **Usage preservation:** The existing 16 unknown ledger reservations remain unknown and held. No retry of task #107 was performed.

## Verification in this stage

- Python suite: 233 tests passed.
- SQL suite on a fresh disposable Supabase database: 20 pgTAP files, 574 assertions passed.
- Bandit at medium/high severity: no findings; one existing B104 test-code warning remains.
- Python compilation and git diff --check: passed.
- GitHub CI for PR #210: all five jobs passed (changes, secret scan, Python, database, containers).
- Production Supabase read-only connectivity and ledger counts: verified.
- Railway browser session: production sutra-api and Hermes Online; /health returned 200 on the active PR #209 deployment; PR #210 then became the active successful deployment.
- Standing-authority Telegram command, production RPC grant, and fresh Developer task creation: not yet activated; the reviewed PR must merge first.

## Pending after this code-control stage

1. Merge this standing-authorization/legal-escalation change after all required checks pass.
2. Apply its additive migrations to production Supabase; record the founder grant in audit_log and create the fresh Developer task. Paid provider calls remain stopped because the Sutra implementation project is budgeted at EUR 0.
3. Verify the grant and task in the founder-only Supabase/Telegram surfaces and confirm no approval queue item was added.
4. Complete autonomous engineering release gates and evidence handoffs, including real QA and Security execution. The user authorized these; they are not yet a complete automatic code-to-release path.
5. Add CRM, customer support, and email adapters and verify credentials privately. No real customer/prospect messages or live marketing/sales are authorized by the implementation request.
6. Extend company-wide coordination beyond the fixed proposal/task workflow. Sales, marketing, support, campaign execution, and legal escalation still need provider-specific integration and operating limits.
7. Review earlier provider credentials and rotate any user-shared secrets through their respective providers when convenient; secrets are not included in Git.

## Human-only blockers

- A paid Sutra platform/model task needs a founder-approved non-zero all-in implementation budget. Existing EUR 500 AI QA initiative budgets are reserved for those separate initiatives and cannot be used for Sutra platform work.
- CRM/support/email work will need the founder to choose providers and supply any account credentials privately. No credentials are needed to merge and activate this code-control stage.
- Legal judgment, contracts, and binding commitments remain founder/legal-counsel matters.

## Next steps

Proceed with the standing-authorization PR, merge after required checks pass, apply the additive Supabase migrations, write the founder authorization audit record, and create the zero-budget Developer task. Continue free code, tests, and documentation work. Do not dispatch paid provider work or contact external customers until the required budget/integration setup exists.
