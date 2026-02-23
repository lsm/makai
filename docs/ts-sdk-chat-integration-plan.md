# TS SDK Chat Integration Plan

## Objective

Replace demo-level provider-specific chat/auth logic with a high-level TypeScript SDK API that routes auth, chat, and streaming through the `makai` protocol runtime.

Reference spec: `docs/v1-sdk-agent-provider-spec.md`

## Verified Current State

- TS OAuth login/list APIs exist, but currently shell out to CLI auth commands.
- Demo chat still manually:
  - reads `~/.makai/auth.json`,
  - builds provider-specific HTTP headers/requests,
  - parses provider-specific responses.
- `MakaiStdioClient` currently provides transport primitives (`connect`, `send`, `nextFrame`) but no high-level chat API.
- `makai --stdio` currently returns `ready` and does not process protocol chat envelopes yet.
- TS tests pass locally (`npm test`), with binary-dependent e2e tests skipped when `MAKAI_BINARY_PATH` is unset.

## Plan

### Phase 1: Implement stdio protocol runtime in `makai`

- Wire auth/provider/agent protocol servers + runtimes into `makai --stdio`.
- Deserialize incoming envelopes, dispatch to protocol server, serialize replies.
- Pump auth/provider/agent events/results/errors back to stdio.
- Keep backward-compatible ready handshake semantics.

### Phase 1.25: Implement auth protocol runtime

- Add `protocol/auth` module (`types`, `envelope`, `server`, `runtime`).
- Implement auth providers listing request/response path.
- Implement interactive login flow:
  - `auth_login_start` -> auth events (`auth_url`, `prompt`, `progress`, `success`, `error`) -> terminal `auth_login_result`.
  - prompt loop (`auth_prompt_response`) and cancellation (`auth_cancel`).
  - map provider-specific manual-code callbacks (for example Google `onManualCodeInput`) into standard `auth_event.prompt`.
- Persist credentials through existing auth storage and never expose token/refresh secrets via protocol payloads.

### Phase 1.5: Implement model discovery and resolution primitives

- Add shared catalog types module (`model_catalog_types.zig`) and model ref helpers (`model_ref.zig`).
- Implement model catalog sources (dynamic listing + static fallback) with cache metadata.
- Implement provider protocol `models_request` / `models_response` handler, including exact `model_id` filter for resolve semantics.
- Implement agent passthrough for model discovery with the same typed response shape.
- Add resolver behavior for ambiguous matches (`invalid_request` when `api` is omitted and multiple models match).

### Phase 2a: Add auth resolution in binary request path

- Ownership:
  - Zig binary owns auth resolution and refresh.
  - TS client never reads token files and never handles refresh tokens directly.
- Credential resolution for provider requests:
  - use explicit request API key when provided,
  - otherwise load from auth storage by provider ID.

### Phase 2b: Add refresh and retry behavior

- Refresh flow:
  - if stored credentials are expired, perform refresh before upstream call,
  - if upstream returns auth failure and credentials are refreshable, refresh and retry once.
- Persistence:
  - write refreshed credentials atomically back to auth storage.
- Failure behavior:
  - return typed protocol error (`auth_refresh_failed`) for refresh failures.
  - if failure occurs before terminal event in streaming path, terminate stream with error envelope.

### Phase 2c: Harden concurrency and storage races

- Concurrency:
  - apply refresh lock per `(provider_id, user_id)` in multi-tenant contexts.
  - for single-tenant contexts, fallback lock key is `(provider_id)`.
- Lock timeout:
  - if refresh lock is held for more than 30s, release lock ownership and fail waiting requests.
  - fail pending requests with typed `auth_refresh_failed` error.
- Ensure refresh + persistence is race-safe under concurrent traffic.

### Phase 3: Add high-level TS SDK APIs

- Implement spec-aligned high-level APIs on top of stdio protocol envelopes:
  - `client.auth.listProviders()` / `client.auth.login()`
  - `client.provider.complete()` / `client.provider.stream()`
  - `client.agent.run()` / `client.agent.stream()`
- Keep `MakaiStdioClient` as low-level transport primitive.
- Add ergonomic request/response types that hide provider-specific headers and parsing.
- Replace TS auth subprocess execution path with auth protocol transport path.
- Implement auth-required retry policy for provider/agent requests:
  - default `auth_retry_policy = "manual"`: surface typed `auth_required` with `provider_id`.
  - optional `auth_retry_policy = "auto_once"`: run `client.auth.login(provider_id)` and retry the request once.

### Phase 4: Migrate demo to SDK chat APIs

- Replace `chatWithGitHubCopilot`, `chatWithAnthropic`, and related parsing helpers with a single SDK call path.
- Remove direct auth-file reads from demo chat request handling.
- Keep existing browser auth session HTTP polling UX, but back it with SDK `client.auth.*` over protocol runtime.

### Phase 5: Migrate CLI auth commands to protocol-wrapper mode

- Re-implement `makai auth providers` and `makai auth login` as thin wrappers over local auth protocol runtime.
- Ensure CLI wrapper output shape remains backward-compatible for current scripts.
- Remove duplicated OAuth orchestration logic from CLI command handlers.

### Phase 6: Testing and hardening

- Zig tests:
  - stdio protocol request/response loop tests across auth/provider/agent,
  - auth protocol flow tests (providers, login, prompt response, cancel, terminal result),
  - auth resolution and refresh tests.
  - concurrent refresh tests (single refresh for N simultaneous requests).
  - auth CLI wrapper tests to ensure `makai auth providers` and `makai auth login` route through protocol runtime.
- TS tests:
  - high-level `auth.listProviders` / `auth.login` / `provider.complete` / `provider.stream` / `agent.run` / `agent.stream` integration tests with fixtures,
  - demo tests updated to assert provider-agnostic chat path.
- End-to-end:
  - run binary smoke/e2e tests with `MAKAI_BINARY_PATH` configured in CI.

## Acceptance Criteria

- Demo chat code no longer contains provider-specific HTTP headers/request/parsing logic.
- TS SDK exposes protocol-backed auth + provider-agnostic chat APIs.
- `makai --stdio` handles auth/provider/agent protocol envelopes end-to-end.
- TS auth APIs do not shell out to CLI commands.
- `makai auth` commands function as wrapper commands over auth protocol runtime.
- Token refresh works transparently when using stored OAuth credentials.
- CI covers both fixture-based and real-binary integration paths.

## Risks and Mitigations

- Risk: protocol/runtime integration in `makai` introduces regressions in existing auth commands.
  - Mitigation: migrate auth commands to wrapper mode with compatibility tests for `auth providers` and `auth login`.
- Risk: auth refresh behavior differs across providers.
  - Mitigation: provider-specific contract tests for refresh and base URL/token derivation.
- Risk: cross-language protocol drift (Zig vs TS envelope assumptions).
  - Mitigation: shared fixture envelopes and strict version-mismatch tests.
