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

### Task 1a: Review, fix, and merge PR #23 (M-004)

**Agent:** coder
**Matrix rows:** M-004
**Spec clauses:** `§2.3`, `§5` (provider model catalog)
**Dependencies:** none

**Description:**

Review the open PR at https://github.com/lsm/makai/pull/23 for spec compliance, correctness, and test coverage. Fix any defects found and merge.

Verify the following spec requirements are met:
- `models_request` / `models_response` envelope serde roundtrip.
- Server emits `ack` then `models_response` (or `nack not_implemented`).
- Dynamic source precedence over static fallback, with `fetched_at_ms` and `cache_max_age_ms` required on all responses.
- Per-model `source` metadata (`dynamic` / `static_fallback`).
- Exact `model_id` filter with ambiguity (`nack invalid_request` when `api` omitted and multiple matches) and no-match (`nack invalid_request` "model not found") semantics.
- `include_deprecated` / `include_login_required` filter behavior.
- Provider runtime outbox pumping emits queued model responses.
- `build.zig` wired correctly; all test groups pass.

After verification, merge PR #23. Update the `M-004` row in `docs/implementation-traceability-matrix.md` with code paths, tests, issue, and PR links (status: done).

**Acceptance criteria:**
- PR #23 merged with no open defects.
- M-004 row in traceability matrix fully populated (status: done).
- `zig build test-unit-protocol` passes on main.

---

### Task 1b: Implement M-005 agent passthrough model discovery

**Agent:** coder
**Matrix rows:** M-005
**Spec clauses:** `§6` (agent passthrough)
**Dependencies:** Task 1a

**Description:**

Implement agent protocol passthrough for model discovery on a new feature branch:

- Add `models_request` / `models_response` payload variants to `zig/src/protocol/agent/types.zig`, reusing shared types from `protocol/model_catalog_types.zig`.
- Implement `models_request` handler in `zig/src/protocol/agent/server.zig`:
  - Forward request to provider protocol and return full typed `ModelsResponse`.
  - Return `nack not_implemented` when provider has no model discovery support.
  - Must return identical model set and shape as provider direct response (spec §6 normative rule: same `models`, `fetched_at_ms`, `cache_max_age_ms`, per-model `source`).
- Wire handler into `zig/src/protocol/agent/runtime.zig` and `zig/src/tools/makai.zig`.
- Add envelope serde (JSON serialize/deserialize) for agent `models_request` / `models_response` in `zig/src/protocol/agent/envelope.zig`.
- Tests: agent `models_request` roundtrip, passthrough returns same model set as provider direct, `nack not_implemented` path, filter propagation.
- Update `M-005` row in traceability matrix (status: done).
- Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- Agent `models_request` handler implemented and tested.
- Passthrough response shape is identical to provider direct response (same fields, same model entries).
- `zig build test-unit-protocol` passes.
- M-005 marked done in matrix with all fields populated.

---

### Task 2: Implement credential resolution and auth refresh/retry (M-006, M-007, M-008)

**Agent:** coder
**Matrix rows:** M-006, M-007, M-008
**Spec clauses:** `docs/ts-sdk-chat-integration-plan.md` Phase 2a–2c; `§8` error/auth semantics; `§2.3` missing-auth behavior
**Dependencies:** Task 1a

**Description:**

Implement the full auth resolution and refresh pipeline in the Zig binary request path. Three sub-items are grouped here because they form a single atomic "credential middleware" stack.

**Phase 2a — Credential resolution (M-006):**
- In `zig/src/tools/makai.zig` (or appropriate dispatch handler), resolve provider credentials before upstream request dispatch:
  - Use explicit request API key when provided.
  - Otherwise load from auth storage by `provider_id` (existing `oauth/storage.zig`).
- If no credentials are available and the provider requires auth: propagate `auth_required` error code.
- For model catalog requests (§2.3): missing auth must not hard-fail the whole response when static fallback is available; return partial results with `auth_status = "login_required"` per model.

**Phase 2b — Refresh + retry (M-007):**
- Before dispatching to upstream provider, check if stored credentials are expired.
- If expired and refreshable: perform refresh, write refreshed credentials atomically back to auth storage, then dispatch.
- If upstream returns auth failure and credentials are refreshable: refresh and retry once.
- On refresh failure: return typed `auth_refresh_failed` error code.
- If failure occurs before terminal event in streaming path: terminate the stream with an error envelope (do not leave stream open).
- Extend provider `ErrorCode` enum with `auth_required`, `auth_refresh_failed`, `auth_expired` (spec §8 normative).

**Phase 2c — Concurrency hardening (M-008):**
- Apply refresh lock per `provider_id` to prevent concurrent refresh storms.
- Lock timeout: if held > 30s, release lock and fail all waiting requests with `auth_refresh_failed`.
- Ensure refresh + persistence is race-safe under concurrent requests.

Tests for all three phases:
- Credential resolution: request succeeds with stored credentials.
- `auth_required` propagated when no credentials available and provider requires auth.
- Model catalog with missing auth: returns static fallback results (not hard failure) with `auth_status = "login_required"`.
- `auth_expired` error code present in `ErrorCode` enum.
- Auto-refresh on expired token before request dispatch.
- Retry-once after upstream auth failure.
- Streaming-path auth failure terminates stream with error envelope before any further events.
- Concurrent refresh: only one refresh executes for N simultaneous requests, others wait.
- Lock timeout after 30s returns `auth_refresh_failed` to waiting requests.
- `zig build test-unit-providers` and `zig build test-unit-utils` pass.

Update M-006, M-007, M-008 rows in traceability matrix (status: done).

Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- Provider requests resolve credentials from auth storage by default.
- `auth_required` error propagated when no credentials available.
- `auth_expired` error code defined in `ErrorCode` enum (§8 normative).
- Missing auth for model catalog requests returns static fallback, not hard failure.
- Expired credentials auto-refresh before dispatch.
- Streaming-path auth failure terminates stream with error envelope.
- Refresh failure returns `auth_refresh_failed` typed error.
- Concurrent refresh is serialized per `provider_id`.
- Lock timeout after 30s returns `auth_refresh_failed`.
- All tests pass.

---

### Task 3: Implement TS `client.auth.*` API (M-009a)

**Agent:** coder
**Matrix rows:** M-009a
**Spec clauses:** `§3.6`, `§4`; `docs/ts-sdk-chat-integration-plan.md` Phase 3
**Dependencies:** Task 1a (binary dep: M-002/PR #17 auth protocol runtime already merged)

**Description:**

Implement spec-aligned `MakaiAuthApi` in the TypeScript SDK on a new feature branch. The binary dependency for this task is M-002 (PR #17, already merged); Task 1a is required only for the overall feature branch sequencing within the plan.

- Implement `createMakaiClient()` factory returning `MakaiClient` (with `auth`, `models`, `provider`, `agent` namespaces).
- Implement `client.auth.listProviders()`:
  - Send `auth_providers_request` over stdio transport.
  - Await `auth_providers_response`, return `ProviderAuthInfo[]`.
- Implement `client.auth.login(providerId, handlers?)`:
  - Send `auth_login_start` over transport.
  - Route `auth_event` envelopes: flatten wire union shape to `MakaiAuthEvent` for `onEvent`.
  - Route `auth_event.prompt` to `onPrompt` and send `auth_prompt_response` with returned answer.
  - Handler resolution: per-call handlers > `MakaiClientOptions.auth.handlers` > none (normative §3.6).
  - Await terminal `auth_login_result`:
    - `success` → resolve `{ status: "success" }`.
    - `cancelled` → reject with `MakaiAuthError { kind: "cancelled" }`.
    - `failed` → reject with `MakaiAuthError` carrying `code` + `message` from preceding `auth_event.error`.
  - Expose cancellation via `AbortSignal` or explicit cancel handle (spec §4 rule 4: `auth_cancel` terminates targeted flow).
    - Cancellation must send `auth_cancel` envelope with the active `flow_id` and await `auth_login_result.status = cancelled`.
- Remove `makai auth ...` subprocess as primary auth path.
- Client-level `MakaiClientOptions.auth.handlers` stored and reused by auto_once retry.
- Tests: `listProviders` roundtrip, `login` success/cancelled/failed/prompt-loop fixtures, handler precedence, cancelled error type, `auth_cancel` sent on abort/cancel.
- Update M-009a in traceability matrix (status: done).
- Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- `client.auth.listProviders()` returns `ProviderAuthInfo[]` via protocol.
- `client.auth.login()` drives full OAuth flow with prompt callbacks.
- `auth_cancel` is sent when login is cancelled via AbortSignal or cancel handle (§4 rule 4).
- No subprocess execution in auth primary path.
- `npm test` passes with fixture-based tests.

---

### Task 4: Implement TS `client.models.*` API (M-009b)

**Agent:** coder
**Matrix rows:** M-009b
**Spec clauses:** `§3.5`; `docs/ts-sdk-chat-integration-plan.md` Phase 3
**Dependencies:** Task 1a (M-004 provides server-side models protocol; M-005 from Task 1b is not required for TS client)

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
- `not_implemented` handled gracefully (empty list, no throw).
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
- Agent stream: `agent_start` first, `agent_end` last; `agent_end` carries aggregate `usage` summed across all provider turns (§3.4).
- Exactly one terminal event per agent run: `agent_end` or `error`; `agent_end` must not be emitted on failure.
- Single surfaced failure per request (§3.4): for a given failure, exactly one terminal `error` event is visible to the SDK caller — no duplicate provider-level + agent-level terminal errors for the same failure.

**Auth retry policy (M-011):**
- On `auth_required` error from provider/agent call:
  - `auth_retry_policy = "manual"` (default): throw `MakaiAuthError` with `provider_id` field populated (§3.6 normative).
  - `auth_retry_policy = "auto_once"`: run `client.auth.login(provider_id)` with client-level handlers, then retry once.
  - `auto_once` with no handlers and interactive auth required: fail fast with typed `MakaiAuthError` (manual-login path), do not hang.
- Tests: `complete` roundtrip, `stream` event ordering, `agent.run` success, `agent_end` aggregate usage across turns, auth retry manual/auto_once, auto_once fast-fail with no handlers, single-error surfacing for same failure.
- Update M-009c, M-010, M-011 in traceability matrix (status: done).
- Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- `client.provider.complete/stream()` and `client.agent.run/stream()` work end-to-end.
- `agent_end` carries aggregate usage summed across all turns.
- Single surfaced failure per request: no duplicate provider+agent terminal errors for the same failure.
- `MakaiAuthError` in manual mode carries `provider_id` field (§3.6).
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
**Dependencies:** Task 1a (binary dep: M-002/PR #17 auth protocol runtime already merged)

**Description:**

Re-implement `makai auth providers` and `makai auth login` CLI commands as thin wrappers over the auth protocol runtime on a new feature branch. The auth protocol runtime required here was delivered by M-002 (PR #17, already merged).

- Remove duplicated OAuth orchestration logic from CLI command handlers.
- `makai auth providers`: call auth protocol runtime directly (not subprocess), format and print provider list.
- `makai auth login [provider_id]`: drive interactive login via auth protocol runtime, surfacing prompts to terminal, maintaining backward-compatible output shape for existing scripts.
- Add wrapper-path integration tests that invoke CLI commands end-to-end and validate output (not just direct runtime calls).
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
**Spec clauses:** `§10`, `§11`, `§12`; `docs/ts-sdk-chat-integration-plan.md` Phase 6
**Dependencies:** Tasks 2, 3, 4, 5, 6, 7

**Description:**

Add comprehensive end-to-end test coverage and validate all acceptance criteria on a new feature branch:

**Zig tests:**
- Stdio protocol request/response loop tests across auth/provider/agent paths.
- Auth protocol flow tests (providers, login, prompt response, cancel, terminal result).
- Auth resolution and refresh tests.
- Concurrent refresh tests (single refresh for N simultaneous requests).
- Auth CLI wrapper tests.

**TypeScript tests:**
- High-level `auth.listProviders` / `auth.login` / `provider.complete` / `provider.stream` / `agent.run` / `agent.stream` integration tests with fixtures.
- Demo tests updated to assert provider-agnostic path.
- Binary smoke/e2e integration with `MAKAI_BINARY_PATH` configured in CI.

**§11 scope coverage:**
- Assert `ModelsResponse` contains all matching results in a single response (no pagination).
- Verify that `list()` returns the full result set in one call for expected V1 scale (no `next_cursor` or `limit` support).

**§12 transport interruption coverage:**
- Simulate transport interruption mid-stream and verify the SDK surfaces a clean `MakaiStreamError` (not a hang, unhandled rejection, or silent data loss).
- Verify client behavior: clean error thrown; caller can retry with full context.

**§10 acceptance criteria verification:**
1. TS client completes OAuth + lists models + executes selected model without provider-specific app code.
2. Model list output is identical from provider endpoint vs agent passthrough.
3. Agent and provider execution accept the same `model_ref` format.
4. SDK auth APIs run over protocol transport (no CLI subprocess).
5. `makai auth providers/login` remains functional as wrapper commands.
6. Existing stream/complete flows remain functional.

Update M-014 in traceability matrix (status: done). Update Review Gate Tracking table.

Changes must be on a feature branch with a GitHub PR created via `gh pr create`.

**Acceptance criteria:**
- All six §10 acceptance criteria verified by automated tests.
- §11: `models.list()` returns full result set in single response; no pagination fields.
- §12: Transport interruption produces clean `MakaiStreamError`, not a hang or unhandled rejection.
- `zig build test` passes.
- `npm test` passes.
- CI passes end-to-end with real binary path.

---

## Task Dependency Graph

```
Task 1a (M-004 merge)
  ├── Task 1b (M-005 agent passthrough)      [depends on Task 1a]
  ├── Task 2  (M-006, M-007, M-008)          [depends on Task 1a]
  ├── Task 3  (M-009a, TS auth API)          [depends on Task 1a; binary dep: M-002/PR #17]
  ├── Task 4  (M-009b, TS models API)        [depends on Task 1a]
  └── Task 7  (M-013, CLI wrappers)          [depends on Task 1a; binary dep: M-002/PR #17]

Task 3 + Task 4
  └── Task 5 (M-009c, M-010, M-011)         [depends on Tasks 3 and 4]

Task 5
  └── Task 6 (M-012, demo migration)         [depends on Task 5]

Tasks 2, 3, 4, 5, 6, 7
  └── Task 8 (M-014, hardening)              [depends on all of Tasks 2–7]
```

Tasks 1b, 2, 3, 4, 7 can all start in parallel immediately after Task 1a completes.
Task 5 starts after both Tasks 3 and 4 complete.
Task 6 starts after Task 5 completes.
Task 8 starts after all of Tasks 2, 3, 4, 5, 6, 7 complete.
