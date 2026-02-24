# V1 Implementation Traceability Matrix

Status: active

## How to use

1. Each row maps one normative requirement to code and tests.
2. `Clause` must reference exact section IDs from spec/design/plan docs.
3. `Status` values: `not started`, `in progress`, `done`.
4. Every implementation PR must update rows it touches.

## Phase Mapping (Plan -> Spec Rollout)

This matrix is keyed by integration-plan phases and explicitly mapped to spec rollout phases.

| Integration Plan Phase | Spec Rollout Phase(s) | Notes |
|---|---|---|
| Phase 1 | prerequisite | Transport/runtime wiring prerequisite for all protocol surfaces. |
| Phase 1.25 | Phase A | Auth protocol runtime first (`auth_providers_request`, `auth_login_start`, auth event loop). |
| Phase 1.5 | Phase D, Phase E | Provider model discovery + agent model passthrough. |
| Phase 2a | cross-cutting prerequisite | Credential resolution in binary request path. |
| Phase 2b | cross-cutting (`§8` error/auth semantics) | Refresh + retry behavior and typed failures. |
| Phase 2c | cross-cutting hardening | Concurrency locks + persistence race safety. |
| Phase 3 | Phase B, Phase D | TS SDK surfaces (auth/models/provider/agent). |
| Phase 4 | Phase F | Demo migration to spec interfaces only. |
| Phase 5 | Phase C | CLI auth wrappers over auth protocol runtime. |
| Phase 6 | acceptance/hardening | End-to-end test and stability gate across all phases. |

## Matrix

| Row ID | Phase | Clause | Requirement Summary | Code Paths | Tests | Issue | PR | Status |
|---|---|---|---|---|---|---|---|---|
| M-001 | 1 | `DESIGN.md §3`; `docs/ts-sdk-chat-integration-plan.md` Phase 1 | Wire protocol runtimes under `makai --stdio` with ready handshake compatibility. | `zig/src/tools/makai.zig` (`StdioProtocolLoop`, `runStdioMode`, `main --stdio`); `zig/build.zig` (`makai_cli` protocol imports + `test-unit-makai-cli` target) | `zig/src/tools/makai.zig` tests: `stdio protocol loop decodes and dispatches provider and agent envelopes`; `stdio protocol loop forwards provider event result and error envelopes`; `stdio mode preserves ready handshake compatibility`; command: `zig build test-unit-makai-cli` | `n/a (no repo issues listed as of 2026-02-23)` | `TBD (branch: codex/phase1-stdio-runtime)` | in progress |
| M-002 | 1.25 | `docs/v1-sdk-agent-provider-spec.md §4`; `DESIGN.md §3`; `docs/ts-sdk-chat-integration-plan.md` Phase 1.25 | Implement auth protocol runtime (`types`, `envelope`, `server`, `runtime`) and stdio integration. | `zig/src/protocol/auth/types.zig`; `zig/src/protocol/auth/envelope.zig`; `zig/src/protocol/auth/server.zig`; `zig/src/protocol/auth/runtime.zig`; `zig/src/tools/makai.zig` (`StdioProtocolLoop` auth dispatch + background pump); `zig/build.zig` (auth protocol module/test wiring); `zig/src/utils/oauth/storage.zig` (safe provider-id key ownership on load). | `zig/src/tools/makai.zig` tests: `stdio protocol loop decodes and dispatches auth providers request and emits ack then response`; `stdio auth login flow supports prompt loop terminal ordering and no secret leakage`; `stdio auth login flow cancellation emits cancelled result and ignores late prompt responses`; `stdio auth login failure emits auth_event.error before auth_login_result`; command: `zig build test-unit-makai-cli`; command: `zig build test-unit-protocol` | `n/a (no repo issues listed as of 2026-02-23)` | `TBD (branch: codex/phase1-25-auth-stdio-runtime)` | in progress |
| M-003 | 1.5 | `docs/v1-sdk-agent-provider-spec.md §3.1`; `docs/ts-sdk-chat-integration-plan.md` Phase 1.5 | Implement `model_ref` parse/format helpers (`protocol/model_ref.zig`) and validation tests; TS diagnostic parser utility. | `zig/src/protocol/model_ref.zig`; `zig/build.zig` (model_ref module + `test-unit-protocol` wiring); `typescript/src/diagnostics/model_ref.ts`; `typescript/test/model_ref_diagnostics.test.ts` | `zig/src/protocol/model_ref.zig` tests: `model_ref format and parse roundtrip canonical refs`; `model_ref supports colons and reserved chars via percent encoding`; `model_ref supports UTF-8 model ids via percent encoding`; `model_ref parse rejects malformed refs`; command: `cd zig && zig test src/protocol/model_ref.zig`; command: `cd zig && zig build test-unit-protocol`; `typescript/test/model_ref_diagnostics.test.ts`: `parseModelRef parses canonical refs with reserved chars and UTF-8 model IDs`; `parseModelRef rejects malformed refs with Zig-matching error categories`; command: `node --test dist/test/model_ref_diagnostics.test.js`; command: `npm test` | [#20](https://github.com/lsm/makai/issues/20) | [#21](https://github.com/lsm/makai/pull/21) | in progress |
| M-004 | 1.5 | `docs/v1-sdk-agent-provider-spec.md §2.3`, `§5`; `docs/ts-sdk-chat-integration-plan.md` Phase 1.5 | Implement provider model catalog sources, caching metadata, and `models_request/models_response`. | `zig/src/protocol/model_catalog_types.zig`; `zig/src/protocol/provider/types.zig`; `zig/src/protocol/provider/envelope.zig`; `zig/src/protocol/provider/server.zig`; `zig/src/protocol/provider/runtime.zig`; `zig/src/tools/makai.zig`; `zig/build.zig` | `zig/src/protocol/model_catalog_types.zig` tests: `cloneModelDescriptor duplicates nested owned fields`; `zig/src/protocol/provider/types.zig` tests: `ModelsRequest getters return null for empty borrowed filters`, `ModelsRequest deinit frees owned filter strings`; `zig/src/protocol/provider/envelope.zig` tests: `serializeEnvelope and deserializeEnvelope roundtrip with models_request`, `serializeEnvelope and deserializeEnvelope roundtrip with models_response`; `zig/src/protocol/provider/server.zig` tests: `handleModelsRequest emits ack then models_response from static fallback`, `handleModelsRequest returns not_implemented nack when unsupported`, `handleModelsRequest applies provider api and exact model filters`, `handleModelsRequest returns invalid_request for ambiguous or missing model_id`, `handleModelsRequest prefers dynamic fetch and falls back to static catalog when unavailable`; command: `cd zig && zig build test-protocol-types`; command: `cd zig && zig build test-unit-makai-cli`; command: `cd zig && zig build test-unit-protocol`; command: `npm test` | [#22](https://github.com/lsm/makai/issues/22) | [#23](https://github.com/lsm/makai/pull/23) | in progress |
| M-005 | 1.5 | `docs/v1-sdk-agent-provider-spec.md §6`; `docs/ts-sdk-chat-integration-plan.md` Phase 1.5 | Implement agent passthrough model discovery with shared response shape. | TBD | TBD | TBD | TBD | not started |
| M-006 | 2a | `docs/ts-sdk-chat-integration-plan.md` Phase 2a | Implement credential resolution/load path in binary request handling. | TBD | TBD | TBD | TBD | not started |
| M-007 | 2b | `docs/v1-sdk-agent-provider-spec.md §8`; `docs/ts-sdk-chat-integration-plan.md` Phase 2b | Implement refresh, retry-once behavior, and typed `auth_refresh_failed`/`auth_expired` handling. | TBD | TBD | TBD | TBD | not started |
| M-008 | 2c | `docs/ts-sdk-chat-integration-plan.md` Phase 2c | Implement refresh lock scope/timeouts and race-safe persistence. | TBD | TBD | TBD | TBD | not started |
| M-009a | 3 | `docs/v1-sdk-agent-provider-spec.md §3.6`; `docs/ts-sdk-chat-integration-plan.md` Phase 3 | Implement TS `client.auth.*` API over protocol transport. | TBD | TBD | TBD | TBD | not started |
| M-009b | 3 | `docs/v1-sdk-agent-provider-spec.md §3.5`; `docs/ts-sdk-chat-integration-plan.md` Phase 3 | Implement TS `client.models.*` API including resolve mapping behavior. | TBD | TBD | TBD | TBD | not started |
| M-009c | 3 | `docs/v1-sdk-agent-provider-spec.md §3`; `docs/ts-sdk-chat-integration-plan.md` Phase 3 | Implement TS `client.provider.*` and `client.agent.*` APIs. | TBD | TBD | TBD | TBD | not started |
| M-010 | 3 | `docs/v1-sdk-agent-provider-spec.md §3.4` | Implement and test stream lifecycle guarantees (terminal events, usage aggregation, error dedupe, tool-call buffering). | TBD | TBD | TBD | TBD | not started |
| M-011 | 3 | `docs/v1-sdk-agent-provider-spec.md §3.6`, `§4`; `docs/ts-sdk-chat-integration-plan.md` Phase 3 | Implement auth retry policy + handler precedence + auth event flattening behavior in SDK. | TBD | TBD | TBD | TBD | not started |
| M-012 | 4 | `docs/v1-sdk-agent-provider-spec.md §9` Phase F; `docs/ts-sdk-chat-integration-plan.md` Phase 4 | Migrate demo to SDK-backed provider-agnostic path (no direct auth-file/provider-specific HTTP logic). | TBD | TBD | TBD | TBD | not started |
| M-013 | 5 | `docs/v1-sdk-agent-provider-spec.md §9` Phase C; `docs/ts-sdk-chat-integration-plan.md` Phase 5 | Migrate `makai auth` CLI commands to protocol-wrapper mode with compatibility output. | TBD | TBD | TBD | TBD | not started |
| M-014 | 6 | `docs/v1-sdk-agent-provider-spec.md §10`; `docs/ts-sdk-chat-integration-plan.md` Phase 6 | Hardening and acceptance tests across auth/provider/agent/CLI paths. | TBD | TBD | TBD | TBD | not started |

## Review Gate Tracking

| PR | External Round | Reviewer | Blocking Findings (P0/P1) | Resolved Commit | Status |
|---|---|---|---|---|---|
| TBD | TBD | TBD | TBD | TBD | open |
