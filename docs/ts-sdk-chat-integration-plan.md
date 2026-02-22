# TS SDK Chat Integration Plan

## Objective

Replace demo-level provider-specific chat HTTP logic with a high-level TypeScript SDK API that routes chat and streaming through the `makai` binary over stdio.

Reference spec: `docs/v1-sdk-agent-provider-spec.md`

## Verified Current State

- OAuth login/list flows are already abstracted in TS SDK (`loginWithMakaiAuth`, `listMakaiAuthProviders`).
- Demo chat still manually:
  - reads `~/.makai/auth.json`,
  - builds provider-specific HTTP headers/requests,
  - parses provider-specific responses.
- `MakaiStdioClient` currently provides transport primitives (`connect`, `send`, `nextFrame`) but no high-level chat API.
- `makai --stdio` currently returns `ready` and does not process protocol chat envelopes yet.
- TS tests pass locally (`npm test`), with binary-dependent e2e tests skipped when `MAKAI_BINARY_PATH` is unset.

## Plan

### Phase 1: Implement stdio protocol runtime in `makai`

- Wire provider protocol server + runtime into `makai --stdio`.
- Deserialize incoming envelopes, dispatch to protocol server, serialize replies.
- Pump provider stream events/results/errors back to stdio.
- Keep backward-compatible ready handshake semantics.

### Phase 2: Add auth resolution in binary request path

- Ownership:
  - Zig binary owns auth resolution and refresh.
  - TS client never reads token files and never handles refresh tokens directly.
- Credential resolution for provider requests:
  - use explicit request API key when provided,
  - otherwise load from auth storage by provider ID.
- Refresh flow:
  - if stored credentials are expired, perform refresh before upstream call,
  - if upstream returns auth failure and credentials are refreshable, refresh and retry once.
- Concurrency:
  - apply per-provider refresh lock to prevent concurrent refresh storms.
- Persistence:
  - write refreshed credentials atomically back to auth storage.
- Failure behavior:
  - return protocol error with `provider_error` and reason prefix `auth:refresh_failed`.
  - if failure occurs before terminal event in streaming path, terminate stream with error envelope.

### Phase 3: Add high-level TS SDK APIs

- Introduce `chat()` (non-streaming) and `streamChat()` (streaming) APIs on top of stdio protocol envelopes.
- Keep `MakaiStdioClient` as low-level transport primitive.
- Add ergonomic request/response types that hide provider-specific headers and parsing.

### Phase 4: Migrate demo to SDK chat APIs

- Replace `chatWithGitHubCopilot`, `chatWithAnthropic`, and related parsing helpers with a single SDK call path.
- Remove direct auth-file reads from demo chat request handling.
- Keep existing auth session HTTP polling flow for browser UX.

### Phase 5: Testing and hardening

- Zig tests:
  - stdio protocol request/response loop tests,
  - auth resolution and refresh tests.
  - concurrent refresh tests (single refresh for N simultaneous requests).
  - auth/stdio coexistence tests to ensure `makai auth providers` and `makai auth login` still work.
- TS tests:
  - high-level `chat()`/`streamChat()` integration tests with fixtures,
  - demo tests updated to assert provider-agnostic chat path.
- End-to-end:
  - run binary smoke/e2e tests with `MAKAI_BINARY_PATH` configured in CI.

## Acceptance Criteria

- Demo chat code no longer contains provider-specific HTTP headers/request/parsing logic.
- TS SDK exposes provider-agnostic high-level chat APIs.
- `makai --stdio` handles provider protocol envelopes end-to-end.
- Token refresh works transparently when using stored OAuth credentials.
- CI covers both fixture-based and real-binary integration paths.

## Risks and Mitigations

- Risk: protocol/runtime integration in `makai` introduces regressions in existing auth commands.
  - Mitigation: keep auth command paths isolated; add regression tests for `auth providers` and `auth login`.
- Risk: auth refresh behavior differs across providers.
  - Mitigation: provider-specific contract tests for refresh and base URL/token derivation.
- Risk: cross-language protocol drift (Zig vs TS envelope assumptions).
  - Mitigation: shared fixture envelopes and strict version-mismatch tests.
