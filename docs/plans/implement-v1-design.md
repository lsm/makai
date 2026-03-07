# Implement V1 Design Plan

## Goal

Continue implementing the V1 SDK + Agent/Provider protocol spec defined in:
- `docs/v1-sdk-agent-provider-spec.md`
- `docs/implementation-traceability-matrix.md`

Starting from the current state: M-001 (Phase 1), M-002 (Phase 1.25), and M-003 (Phase 1.5 model_ref) are complete via merged PRs. PR #23 (M-004) is open.

## Current State

| Row ID | Status | Notes |
|---|---|---|
| M-001 | done | PR #16 merged |
| M-002 | done | PR #17 merged |
| M-003 | done | PR #21 merged |
| M-004 | in progress | PR #23 open, no review yet |
| M-005–M-014 | not started | |

---

## Tasks

### Task 1: Review, fix, and merge PR #23 (M-004), then implement M-005 agent passthrough model discovery

**Agent:** coder
**Matrix rows:** M-004, M-005
**Spec clauses:** `§2.3`, `§5` (provider model catalog), `§6` (agent passthrough)
**Dependencies:** none

**Description:**

**Part A — PR #23 (M-004):**
- Review the open PR at https://github.com/lsm/makai/pull/23 for spec compliance, correctness, and test coverage.
- Fix any defects found (build errors, spec mismatches, missing test cases).
- Verify the following spec requirements are met:
  - `models_request` / `models_response` envelope serde roundtrip.
  - Server emits `ack` then `models_response` (or `nack not_implemented`).
  - Dynamic source precedence over static fallback, with `fetched_at_ms` and `cache_max_age_ms` required.
  - Per-model `source` metadata (`dynamic` / `static_fallback`).
  - Exact `model_id` filter with ambiguity and no-match `nack invalid_request` semantics.
  - `include_deprecated` / `include_login_required` filter behavior.
  - Provider runtime outbox pumping emits queued model responses.
  - `build.zig` wired correctly, all test groups pass.
- Merge PR #23 after verification.
- Update `M-004` row in `docs/implementation-traceability-matrix.md` with code paths, tests, issue, and PR links (status: done).

**Part B — M-005 (agent passthrough):**
After merging PR #23, implement agent protocol passthrough for model discovery on a new feature branch:
- Add `models_request` / `models_response` payload variants to `zig/src/protocol/agent/types.zig`, reusing shared types from `protocol/model_catalog_types.zig`.
- Implement `models_request` handler in `zig/src/protocol/agent/server.zig`:
  - Forward request to provider protocol and return full typed `ModelsResponse`.
  - Return `nack not_implemented` when provider has no model discovery support.
  - Must return identical model set and shape as provider direct response (spec §6 normative rule).
- Wire handler into `zig/src/protocol/agent/runtime.zig` and `zig/src/tools/makai.zig`.
- Add envelope serde (JSON serialize/deserialize) for agent `models_request` / `models_response` in `zig/src/protocol/agent/envelope.zig`.
- Tests: agent `models_request` roundtrip, passthrough returns same model set as provider direct, `nack not_implemented` path, filter propagation.
- Update `M-005` row in traceability matrix (status: done).
- Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- PR #23 merged, M-004 marked done in matrix.
- Agent `models_request` handler implemented and tested.
- `zig build test-unit-protocol` passes.
- M-005 marked done in matrix with all fields populated.

---

### Task 2: Implement credential resolution and auth refresh/retry (M-006, M-007, M-008)

**Agent:** coder
**Matrix rows:** M-006, M-007, M-008
**Spec clauses:** `docs/ts-sdk-chat-integration-plan.md` Phase 2a–2c; `§8` error/auth semantics
**Dependencies:** Task 1

**Description:**

Implement the full auth resolution and refresh pipeline in the Zig binary request path. Three sub-items are grouped here because they form a single atomic "credential middleware" stack.

**Phase 2a — Credential resolution (M-006):**
- In `zig/src/tools/makai.zig` (or appropriate dispatch handler), resolve provider credentials before upstream request dispatch:
  - Use explicit request API key when provided.
  - Otherwise load from auth storage by `provider_id` (existing `oauth/storage.zig`).
- Propagate `auth_required` protocol error if no credentials are available and the provider requires auth.

**Phase 2b — Refresh + retry (M-007):**
- Before dispatching to upstream provider, check if stored credentials are expired.
- If expired and refreshable: perform refresh, write refreshed credentials atomically back to auth storage, then dispatch.
- If upstream returns auth failure and credentials are refreshable: refresh and retry once.
- On refresh failure: return typed `auth_refresh_failed` error code (extend `ErrorCode` enum per spec §8).
- If failure occurs before terminal event in streaming path: terminate stream with error envelope.
- Extend provider `ErrorCode` enum with `auth_required`, `auth_refresh_failed`, `auth_expired`.

**Phase 2c — Concurrency hardening (M-008):**
- Apply refresh lock per `provider_id` to prevent concurrent refresh storms.
- Lock timeout: if held > 30s, release lock and fail waiting requests with `auth_refresh_failed`.
- Ensure refresh + persistence is race-safe under concurrent requests.

Tests for all three phases:
- Credential resolution with and without stored credentials.
- Auto-refresh on expired token before request.
- Retry-once after upstream auth failure.
- Concurrent refresh: only one refresh executes for N simultaneous requests.
- Lock timeout behavior.
- `zig build test-unit-providers` and `zig build test-unit-utils` pass.

Update M-006, M-007, M-008 rows in traceability matrix (status: done).

Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- Provider requests resolve credentials from auth storage by default.
- Expired credentials auto-refresh before dispatch.
- Refresh failure returns `auth_refresh_failed` typed error.
- Concurrent refresh is serialized per `provider_id`.
- All tests pass.

---

### Task 3: Implement TS `client.auth.*` API (M-009a)

**Agent:** coder
**Matrix rows:** M-009a
**Spec clauses:** `§3.6`, `§4`; `docs/ts-sdk-chat-integration-plan.md` Phase 3
**Dependencies:** Task 1 (auth protocol already merged in Phase 1.25 PR #17)

**Description:**

Implement spec-aligned `MakaiAuthApi` in the TypeScript SDK on a new feature branch:

- Implement `createMakaiClient()` factory returning `MakaiClient` (with `auth`, `models`, `provider`, `agent` namespaces).
- Implement `client.auth.listProviders()`:
  - Send `auth_providers_request` over stdio transport.
  - Await `auth_providers_response`, return `ProviderAuthInfo[]`.
- Implement `client.auth.login(providerId, handlers?)`:
  - Send `auth_login_start` over transport.
  - Route `auth_event` envelopes: flatten wire union shape to `MakaiAuthEvent` for `onEvent`.
  - Route `auth_event.prompt` to `onPrompt` and send `auth_prompt_response` with returned answer.
  - Handler resolution: per-call handlers > `MakaiClientOptions.auth.handlers` > none.
  - Await terminal `auth_login_result`:
    - `success` → resolve `{ status: "success" }`.
    - `cancelled` → reject with `MakaiAuthError { kind: "cancelled" }`.
    - `failed` → reject with `MakaiAuthError` carrying `code` + `message` from preceding `auth_event.error`.
- Remove `makai auth ...` subprocess as primary auth path.
- Client-level `MakaiClientOptions.auth.handlers` stored and reused by auto_once retry.
- Tests: `listProviders` roundtrip, `login` success/cancelled/failed/prompt-loop fixtures, handler precedence, cancelled error type.
- Update M-009a in traceability matrix (status: done).
- Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- `client.auth.listProviders()` returns `ProviderAuthInfo[]` via protocol.
- `client.auth.login()` drives full OAuth flow with prompt callbacks.
- No subprocess execution in auth primary path.
- `npm test` passes with fixture-based tests.

---

### Task 4: Implement TS `client.models.*` API (M-009b)

**Agent:** coder
**Matrix rows:** M-009b
**Spec clauses:** `§3.5`; `docs/ts-sdk-chat-integration-plan.md` Phase 3
**Dependencies:** Task 1 (M-004 + M-005 provide server-side models protocol)

**Description:**

Implement `MakaiModelsApi` in the TypeScript SDK on a new feature branch:

- Implement `client.models.list(request?)`:
  - Send `models_request` with optional `provider_id`, `api`, `include_deprecated`, `include_login_required` filters.
  - Await `models_response`, return `ListModelsResponse` with `models[]`, `fetched_at_ms`, `cache_max_age_ms`.
  - Handle `nack not_implemented` as capability absence (return empty list, not throw).
- Implement `client.models.resolve(request)`:
  - Send `models_request` with required `provider_id` + exact `model_id` + optional `api`.
  - If server returns 0 results: throw `invalid_request` "model not found".
  - If server returns >1 result: throw `invalid_request` (ambiguous).
  - On success: return `ResolveModelResponse { model }`.
- Map `ModelDescriptor` wire fields to TS `ModelDescriptor` interface.
- Tests: `list` with/without filters, `resolve` success/not-found/ambiguous, `not_implemented` handling, cache fields passed through.
- Update M-009b in traceability matrix (status: done).
- Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- `client.models.list()` returns model catalog with cache metadata.
- `client.models.resolve()` returns single model or throws typed error.
- `not_implemented` handled gracefully.
- `npm test` passes.

---

### Task 5: Implement TS `client.provider.*` + `client.agent.*` + stream lifecycle + auth retry (M-009c, M-010, M-011)

**Agent:** coder
**Matrix rows:** M-009c, M-010, M-011
**Spec clauses:** `§3`, `§3.4`, `§3.6`; `docs/ts-sdk-chat-integration-plan.md` Phase 3
**Dependencies:** Tasks 3, 4

**Description:**

Implement provider and agent execution APIs plus stream lifecycle and auth retry on a new feature branch:

**Provider API (M-009c partial):**
- `client.provider.complete(request)`: send `complete_request` with `model_ref`, `messages`, `tools`, `options`; await terminal `complete_response` or `nack`; return `ProviderCompleteResponse`.
- `client.provider.stream(request)`: send `stream_request`; iterate `MessageEvent` envelopes; yield `ProviderStreamEvent` via `AsyncIterable`; throw `MakaiStreamError` on terminal `error` or envelope nack.

**Agent API (M-009c partial):**
- `client.agent.run(request)`: send `agent_run_request`; await terminal agent response; return `AgentRunResponse`.
- `client.agent.stream(request)`: iterate `AgentEvent` envelopes; yield `AgentStreamEvent` via `AsyncIterable`.

**Stream lifecycle (M-010):**
- Each provider stream emits exactly one terminal event: `message_end` or `error` (enforce in TS adapter).
- `tool_call` emitted only after full argument buffering (non-incremental).
- `message_start` carries resolved `provider_id`, `api`, `model_id` when available.
- Agent stream: `agent_start` first, `agent_end` last (aggregate usage); exactly one terminal per run.
- Single surfaced failure per request: no duplicate provider+agent terminal errors for same failure.

**Auth retry policy (M-011):**
- On `auth_required` error from provider/agent call:
  - `auth_retry_policy = "manual"` (default): throw `MakaiAuthError` with `provider_id`.
  - `auth_retry_policy = "auto_once"`: run `client.auth.login(provider_id)` with client-level handlers, then retry once.
  - `auto_once` with no handlers and interactive auth required: fail fast as `auth_required`, do not hang.
- Tests: `complete` roundtrip, `stream` event ordering, `agent.run` success, auth retry manual/auto_once, auto_once fast-fail with no handlers.
- Update M-009c, M-010, M-011 in traceability matrix (status: done).
- Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- `client.provider.complete/stream()` and `client.agent.run/stream()` work end-to-end.
- Stream lifecycle invariants enforced.
- Auth retry policy works correctly in both modes.
- `npm test` passes.

---

### Task 6: Migrate demo to SDK-backed provider-agnostic path (M-012)

**Agent:** coder
**Matrix rows:** M-012
**Spec clauses:** `§9` Phase F; `docs/ts-sdk-chat-integration-plan.md` Phase 4
**Dependencies:** Task 5

**Description:**

Migrate demo chat code to use the high-level SDK on a new feature branch:

- Replace `chatWithGitHubCopilot`, `chatWithAnthropic`, and similar provider-specific helpers with a single `client.provider.complete()` or `client.agent.run()` call using a `model_ref` obtained from `client.models.resolve()`.
- Remove all direct reads of `~/.makai/auth.json` from demo chat request handling.
- Remove provider-specific HTTP header/request building and response parsing from demo.
- Retain existing browser auth session UX, backed by `client.auth.*` over protocol runtime.
- Verify demo still works end-to-end (with `MAKAI_BINARY_PATH` set if applicable).
- Update demo tests to assert provider-agnostic chat path.
- Update M-012 in traceability matrix (status: done).
- Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- Demo chat code contains no provider-specific HTTP headers/request/parsing logic.
- Demo chat routes through `client.provider.*` or `client.agent.*`.
- Direct auth-file reads removed from demo.
- Demo tests pass.

---

### Task 7: Migrate CLI auth commands to protocol-wrapper mode (M-013)

**Agent:** coder
**Matrix rows:** M-013
**Spec clauses:** `§9` Phase C; `docs/ts-sdk-chat-integration-plan.md` Phase 5
**Dependencies:** Task 1 (auth protocol runtime already implemented in M-002)

**Description:**

Re-implement `makai auth providers` and `makai auth login` CLI commands as thin wrappers over the auth protocol runtime on a new feature branch:

- Remove duplicated OAuth orchestration logic from CLI command handlers.
- `makai auth providers`: call auth protocol runtime directly (not subprocess), format and print provider list.
- `makai auth login [provider_id]`: drive interactive login via auth protocol runtime, surfacing prompts to terminal, maintaining backward-compatible output shape for existing scripts.
- Add wrapper-path integration tests that invoke CLI commands and validate output (not just direct runtime calls).
- CLI wrapper output shape must remain backward-compatible.
- Update M-013 in traceability matrix (status: done).
- Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- `makai auth providers` routes through auth protocol runtime.
- `makai auth login` routes through auth protocol runtime with interactive terminal prompts.
- No duplicate OAuth logic in CLI handlers.
- CLI output is backward-compatible.
- Wrapper integration tests pass.

---

### Task 8: End-to-end hardening and acceptance tests (M-014)

**Agent:** coder
**Matrix rows:** M-014
**Spec clauses:** `§10`; `docs/ts-sdk-chat-integration-plan.md` Phase 6
**Dependencies:** Tasks 2–7

**Description:**

Add comprehensive end-to-end test coverage and validate all acceptance criteria on a new feature branch:

- Zig tests:
  - Stdio protocol request/response loop tests across auth/provider/agent paths.
  - Auth protocol flow tests (providers, login, prompt response, cancel, terminal result).
  - Auth resolution and refresh tests.
  - Concurrent refresh tests (single refresh for N simultaneous requests).
  - Auth CLI wrapper tests.
- TypeScript tests:
  - High-level `auth.listProviders` / `auth.login` / `provider.complete` / `provider.stream` / `agent.run` / `agent.stream` integration tests with fixtures.
  - Demo tests updated to assert provider-agnostic path.
  - Binary smoke/e2e integration with `MAKAI_BINARY_PATH` configured in CI.
- Verify all 6 acceptance criteria from `§10`:
  1. TS client completes OAuth + lists models + executes selected model without provider-specific app code.
  2. Model list output is identical from provider endpoint vs agent passthrough.
  3. Agent and provider execution accept the same `model_ref` format.
  4. SDK auth APIs run over protocol transport (no CLI subprocess).
  5. `makai auth providers/login` remains functional as wrapper commands.
  6. Existing stream/complete flows remain functional.
- Update M-014 in traceability matrix (status: done).
- Update Review Gate Tracking table in traceability matrix.
- Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- All `§10` acceptance criteria verified by automated tests.
- `zig build test` passes.
- `npm test` passes.
- CI passes end-to-end with real binary path.

---

## Task Dependency Graph

```
Task 1 (M-004 merge + M-005)
  ├── Task 2 (M-006, M-007, M-008)   [depends on Task 1]
  ├── Task 3 (M-009a)                 [no binary dep; auth proto from PR #17]
  ├── Task 4 (M-009b)                 [depends on Task 1]
  └── Task 7 (M-013)                  [no binary dep; auth proto from PR #17]

Task 3 + Task 4
  └── Task 5 (M-009c, M-010, M-011)  [depends on Tasks 3, 4]

Task 5
  └── Task 6 (M-012)                  [depends on Task 5]

Tasks 2-7
  └── Task 8 (M-014)                  [depends on all of Tasks 2-7]
```

Tasks 2, 3, 4, 7 can start in parallel after Task 1 completes.
Task 5 starts after Tasks 3 and 4.
Task 6 starts after Task 5.
Task 8 starts after all of Tasks 2–7.
