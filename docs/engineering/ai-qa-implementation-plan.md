# AI QA implementation plan

## Status and scope gate

This document is an implementation map only. It does not authorize product behavior or implementation.

At the `origin/main` snapshot reviewed for this plan (`5c3068e`, 2026-09-29), `STATUS.md` says QA and Security reviews are deferred and incomplete. The merged [AI QA opportunity discovery plan](../AI_QA_OPPORTUNITY_DISCOVERY.md) authorizes no-spend discovery and explicitly makes a prototype contingent on a separately reviewed proposal. PR #188 added that discovery plan; it did not accept a product implementation scope. There was no open PR in `anupdalvi86-oss/sutra` when this plan was prepared. Treat any later product-scope PR as a prerequisite: first confirm that it is merged and use its accepted requirements and acceptance criteria to revise this plan. Start implementation only after the founder or coordinator explicitly asks for it.

The merged PR #160 contains an existing local synthetic draft workflow. It is a technical starting point, not evidence that an AI-backed product has been approved. Today it makes no model calls, stores only synthetic generator metadata, exposes inert manual plans, and is disabled unless development mode and local loopback Supabase are both selected. Do not weaken those boundaries based on this plan.

## Current implementation map

| Area | Current responsibility | Relevance to a narrow AI QA slice |
| --- | --- | --- |
| `sutra/drafts.py` | Scenario validation, synthetic manual-plan construction, strict draft validation, caller-JWT Supabase access, persistence, and append-only review decisions | Smallest backend seam if accepted scope extends the existing draft/review workflow. Keep generation, output validation, and persistence here unless accepted requirements demonstrate a separate service boundary. |
| `sutra/server.py` | Development/local-database feature gate and `POST/GET/PATCH/DELETE /v1/drafts` HTTP routes | Touch only if accepted behavior requires a route or explicit opt-in setting. Current feature gate intentionally rejects hosted Supabase. |
| `supabase/migrations/20260929080935_create_test_draft_workflow.sql` and `20260929080943_draft_owner_delete_policy.sql` | Draft and review storage, bounds, RLS, owner access, append-only review history, and owner deletion | Existing schema is synthetic-only (`generator_kind = 'synthetic'`). Any persistence or authorization change needs a separately reviewed migration/policy proposal; none is authorized here. |
| `tests/test_drafts.py` | Generator, validation, user-scoped Supabase client, service behavior, route authentication, and fail-closed feature gate | Primary focused Python test target for changes to the draft workflow. |
| `tests/test_server.py` | Service configuration and internal HTTP endpoint behavior | Target only if app initialization, feature gating, or route wiring changes. |
| `supabase/tests/test_draft_workflow_test.sql` | RLS, grants, owner isolation, append-only reviews, and deletion behavior | Target only if the schema or access policy changes. |
| `scripts/draft_auth_e2e.py` | Local Auth/PostgREST two-user isolation and persistence check | Target if accepted behavior changes the stored draft/review path. It runs against local disposable Supabase only. |

`sutra/worker.py`, `sutra/codex_runner.py`, and `sutra/codex_metering.py` implement the separate agent/task execution and metered Codex paths. Do not route a user-facing draft through those subsystems simply because they already call a model. If the accepted product requires inference, first compare its exact routing and spend requirements with the existing metering/profile contract; any required metering or model-route work must be explicitly included in accepted scope. Never add a direct provider call that bypasses the applicable database reservation, usage reconciliation, and hard cap.

## Narrow implementation path, contingent on accepted scope

Prefer extending the existing draft workflow instead of adding a second product API, a new worker lane, or a general-purpose test execution service. Preserve caller-JWT/RLS ownership and the current inert manual-plan boundary unless the merged scope explicitly changes them and separately addresses the resulting safety and policy requirements.

1. **Translate accepted scope into a bounded contract.** Record target user, input/output shape, supported workflow, human review point, explicit non-goals, data handling, success measure, and acceptance criteria from the merged scope. Resolve the discovery prerequisite by checking authoritative task/project records for model-routing readiness before any prototype or provider work. If routing is unknown/incomplete, stop provider work and surface the dependency.
2. **Choose the smallest generation seam.** If the accepted behavior still produces a manual draft, introduce only the required generator seam at `DraftService.create` / `generate_synthetic_draft` in `sutra/drafts.py`. Keep request/output bounds, structural validation, and reviewer accept/edit/reject behavior. Preserve deterministic synthetic generation as a no-provider path if the accepted contract still needs it.
3. **Add a provider path only if explicitly accepted.** Reuse or extend an approved metered route only after confirming it enforces the active provider/model profile, reservation, usage reconciliation, token/output limits, failure behavior, and monthly hard stop for this exact feature. Do not place provider secrets in the child/runtime request or rely on prompt text for cost controls. Keep provider calls disabled by default and local-development-only until scope explicitly authorizes another environment and its controls are separately approved.
4. **Persist only the accepted result.** Keep user identity derived from Supabase Auth and use the user's JWT for table operations. Validate the exact accepted output before insert. Any new generator provenance fields, status, retention, or access paths require a separate schema/policy review before code is built against them.
5. **Wire only required routes/configuration.** Change `sutra/server.py` only if the accepted contract needs an additional route or opt-in. Keep authentication, request-size limits, no-store responses, development/environment gates, and fail-closed configuration behavior.
6. **Verify focused behavior and integration.** Add the targeted tests below based on the actual changed path. Do not claim QA or Security is complete: those reviews remain deferred per `STATUS.md` and must be restored through the authorized workflow before release readiness can be asserted.

## Proposed implementation task breakdown

| Task | Deliverable | Depends on |
| --- | --- | --- |
| 0. Scope reconciliation | Implementation-ready acceptance criteria copied from the merged product-scope PR; verify model-routing readiness and identify any unresolved requirements | Product-scope PR merged; explicit founder/coordinator implementation request; authoritative task/project state available |
| 1. Contract and design | Small request/response contract and data-flow notes for the existing draft endpoint; define whether generation is synthetic, model-assisted, or both; specify human review and safety boundaries | Task 0; accepted user workflow and data-handling requirements |
| 2. Generation and validation | Implement only the accepted generation path and strict validation in `sutra/drafts.py`; no browser execution unless accepted scope separately authorizes it | Task 1; for model use, approved route/profile, reservation and settlement path, and explicit spend authorization |
| 3. HTTP integration | Add/adjust only required routes and fail-closed configuration in `sutra/server.py` | Task 1; Task 2 contract stable |
| 4. Persistence / policy proposal (if needed) | Separate migration and access-policy design for accepted provenance, lifecycle, retention, or multi-user needs; submit for review before implementation | Task 1; accepted data and lifecycle requirements; explicit database/policy approval |
| 5. Focused verification | Python, local database, and local Auth/PostgREST checks for the changed behavior; report QA/Security status separately | Relevant implementation tasks complete; approved local test setup |

Tasks 2–3 are the likely minimal code slice if accepted requirements fit the existing owner-scoped draft contract. Task 4 is not assumed and must not be folded into source implementation without separate approval. If the accepted scope requires integrations, executable tests, customer systems, production access, external outreach, or a different buyer workflow, stop and update the plan before broadening the surface.

## Likely targeted tests after scope acceptance

- `tests/test_drafts.py`: add narrow tests for each accepted input and output rule; malformed/oversized provider response; validation failure; provider-disabled behavior; persistence metadata; and ensuring review decisions remain append-only. Retain the existing tests for inert output, user JWT forwarding, authentication, and disabled-feature behavior.
- `tests/test_server.py`: only if configuration or routes change. Cover default-off and fail-closed behavior, authentication, status codes, body limits, and that disallowed deployment/database combinations cannot activate the feature.
- `supabase/tests/test_draft_workflow_test.sql`: only for an approved migration or policy change. Cover grants, owner/tenant isolation, accepted provenance constraints, review immutability, retention/deletion semantics, and unauthorized access.
- `scripts/draft_auth_e2e.py`: run only against local disposable Supabase if the authenticated persistence path changes; cover two-user isolation and the accepted review/delete lifecycle.
- Existing CI Python and database jobs: require them for implementation PR validation. Do not treat a local unit test as evidence of production migration application, QA sign-off, Security review, or release approval.

## Separate database, policy, and operational decisions

The current database constrains `test_drafts.generator_kind` to `synthetic` and stores bounded JSON drafts with owner/tenant RLS; reviewers can append decisions, and owners can delete a draft with its review history. If an accepted scope adds model-generated provenance, additional draft states, team access, retention controls, or execution results, those are database/policy changes requiring their own reviewed migration and tests. The plan does not request or make them.

Any inference requires verified model routing and an authorized spending path under existing database policy. Product-scope approval alone must not be treated as spend authorization. Production enablement, changes to credentials/settings, external outreach, QA/Security completion, merge authority, and release authority are outside this plan. QA and Security remain deferred until explicitly restored and completed through their independent workflow.
