# V1 Implementation Traceability Matrix

Status: active

## How to use

1. Each row maps one normative requirement to code and tests.
2. `Clause` should reference section IDs from the spec docs (for example `Spec §3.6`).
3. `Status` values: `not started`, `in progress`, `done`.
4. Every implementation PR must update rows it touches.

## Matrix

| Row ID | Phase | Clause | Requirement Summary | Code Paths | Tests | Issue | PR | Status |
|---|---|---|---|---|---|---|---|---|
| M-001 | 1 | Design runtime wiring | Wire protocol runtimes under `makai --stdio` | TBD | TBD | TBD | TBD | not started |
| M-002 | 1.5 | Spec §3.1, §3.2, §5 | Model catalog + resolver + `models_request` handling | TBD | TBD | TBD | TBD | not started |
| M-003 | 2a | Spec §2.2, §5 | Credential resolution/load in provider path | TBD | TBD | TBD | TBD | not started |
| M-004 | 2b | Spec §5, §7 | Expiry refresh + retry-once behavior | TBD | TBD | TBD | TBD | not started |
| M-005 | 2c | Plan Phase 2c | Per-key refresh lock + safe persistence | TBD | TBD | TBD | TBD | not started |
| M-006 | 3 | Spec §3.0, §3.6 | TS SDK APIs (`auth/models/provider/agent`) | TBD | TBD | TBD | TBD | not started |
| M-007 | 3 | Spec §3.6 | `auth_retry_policy` behavior + handler precedence | TBD | TBD | TBD | TBD | not started |
| M-008 | 3 | Spec §4 | Auth protocol mapping + event flattening | TBD | TBD | TBD | TBD | not started |
| M-009 | 4 | Plan Phase 4 | Demo migration to SDK APIs | TBD | TBD | TBD | TBD | not started |
| M-010 | 5 | Spec §2.2, Plan Phase 5 | CLI auth wrappers over auth protocol runtime | TBD | TBD | TBD | TBD | not started |

## Review Gate Tracking

| PR | External Round | Reviewer | Blocking Findings (P0/P1) | Resolved Commit | Status |
|---|---|---|---|---|---|
| TBD | TBD | TBD | TBD | TBD | open |
