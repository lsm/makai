# Implementation Review Process (Normative for V1 Rollout)

Status: active

## 1. Goal

Ship V1 protocol + SDK in small, auditable increments with strict alignment to:
- `docs/v1-sdk-agent-provider-spec.md`
- `docs/ts-sdk-chat-integration-plan.md`
- `DESIGN.md`

## 2. Scope

This process is required for all implementation PRs tied to the V1 phases (Phase 1 through Phase 5).

## 3. Required Workflow

1. Create/assign a scoped issue for one phase sub-task.
2. Link exact spec clauses in the issue before coding starts.
3. Implement only that scoped task.
4. Add or update tests for every touched normative clause.
5. Update the traceability matrix in `docs/implementation-traceability-matrix.md`.
6. Open PR with required checklist evidence.
7. Run external review rounds until no blocking findings remain.
8. Merge only when all exit criteria pass.

## 4. External Multi-Round Review Gate

Minimum review rounds:
- at least 2 external rounds, or
- until a round returns no blocking findings (P0/P1), whichever is greater.

Per round, PR author must:
1. Capture findings grouped by severity (P0-P3).
2. Mark each finding as one of:
   - fixed
   - accepted with follow-up issue
   - rejected with rationale
3. Push follow-up commits.
4. Request next round with updated context.

Blocking policy:
- Any unresolved P0/P1 finding blocks merge.
- Regressions from previous resolved findings block merge.

## 5. Severity Model

- P0: correctness/security/data-loss break.
- P1: high-probability behavior/spec mismatch.
- P2: medium risk or edge-case bug.
- P3: clarity/maintainability/nit.

## 6. Exit Criteria (All Required)

1. PR scope matches a single planned phase/sub-phase.
2. All linked spec clauses have implementation references.
3. All linked spec clauses have test references.
4. CI passes.
5. Traceability matrix rows are updated to `done` or `in progress` with PR link.
6. External review gate passes with no unresolved P0/P1.
7. If behavior changed, docs changed in same PR.

## 7. Required Artifacts in PR Description

1. Spec clauses implemented.
2. Test evidence (unit/integration/contract/concurrency as applicable).
3. Matrix row IDs updated.
4. External review rounds log:
   - reviewer
   - round number
   - blocking findings count
   - resolution commit(s)

## 8. Non-Negotiable Rules

- No large mixed PRs across multiple phases.
- No merge with unresolved blocking review findings.
- No spec drift: code behavior must match spec, or spec must be updated in same PR.
