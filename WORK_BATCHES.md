# Work Batches Tracker

Status: active
Purpose: track remaining work in small CI-friendly batches and keep this file updated as execution progresses.

## Rules
- Keep batches small and independently shippable.
- Commit + push each completed batch.
- Update this file in every batch commit.
- If quota is reached, resume from the next unchecked item with another model/provider.

## Current Progress Snapshot
- [x] Design consolidation to `DESIGN.md`
- [x] Per-session sequence tracking (agent protocol client)
- [x] Provider client per-stream state maps + stream APIs
- [x] Provider client per-stream event streams + terminal leak fix

---

## Batch Queue (Next)

### Batch A — WebSocket Transport Hardening Tests (Phase 1)
- [x] Add websocket malformed-frame rejection tests
- [x] Add websocket fragmented/partial frame handling tests
- [x] Add websocket ordering guarantees tests (single stream)
- [x] Add websocket multiplex ordering tests (multi stream)
- [x] Add websocket backpressure behavior tests

### Batch B — WebSocket Transport Hardening Tests (Phase 2)
- [x] Add reconnect/resubscribe behavior tests
- [x] Add ping/pong timeout behavior tests
- [x] Add close-handshake robustness tests
- [x] Add CI job split for websocket-heavy test lanes (if needed)

Progress note:
- Added reconnect precondition coverage (`closed` state can reconnect path), guard coverage for non-reconnectable states, and close idempotence test coverage.
- Added reconnect retryability + stale-buffer clearing coverage for reconnect/resubscribe-ready attempts.
- Added ping timeout state coverage (timeout threshold trigger and pong-reset behavior).
- Added close-frame receive and closing->closed cleanup robustness coverage.
- Evaluated CI split need: no extra websocket-only lane needed now (unit matrix already isolates transport; recent failures were external E2E Anthropic 429s).

### Batch C — Provider Client Multiplexing API Cleanup
- [x] Add explicit stream lifecycle helpers (`closeStream`, `removeStreamState`)
- [x] Add tests for per-stream cleanup (no leaks after stream terminal)
- [x] Add tests for interleaved done/error/result across 2+ streams
- [x] Add docs/examples for new `startStream` + `getEventStreamFor` flow

Progress note:
- Added explicit provider client stream lifecycle APIs (`closeStream`, `removeStreamState`) and tests for cleanup + interleaved stream terminal isolation; documented normative `startStream` per-stream flow in `DESIGN.md`.

### Batch D — Agent Client Multiplexing Ergonomics
- [x] Add explicit per-session helpers (query completion/error by session)
- [x] Add session lifecycle cleanup APIs
- [x] Add tests for multi-session stop/restart with strict per-session sequence continuity

Progress note:
- Added per-session completion/result/error tracking and `removeSessionState` lifecycle cleanup API in `protocol/agent/client.zig`, plus continuity tests for independent per-session sequence counters across stop/restart.

### Batch E — Tool Protocol Design -> Implementation Slice 1
- [x] Define tool protocol message types (request/response/events)
- [x] Add envelope serialization/deserialization tests
- [x] Add negative tests (unknown tool, malformed args, timeout)
- [x] Add runtime pump path for tool protocol messages

Progress note:
- Added `protocol/tool/envelope.zig` with roundtrip + negative tests, added `protocol/tool/runtime.zig` runtime pump, wired both into `zig/build.zig` protocol unit lane, and tightened tool payload deinit ownership for `tool_status_response`.

### Batch F — Tool Protocol Integration Slice 2
- [x] Integrate tool protocol with agent loop execution path
- [x] Add distributed chain integration test including tool execution
- [x] Add cancellation and terminal guarantees tests

Progress note:
- Added `zig/test/e2e/distributed_fullstack.zig` and wired `test-e2e-distributed-fullstack` into the mock-based protocol E2E lane to cover agent loop + provider protocol bridge + tool protocol execution path in one end-to-end test.
- Added agent-loop protocol tool execution hook (`execute_tool_via_protocol_fn`) and coverage for protocol-path execution, cancellation, and terminal start/end event guarantees.
- Added `zig/test/e2e/distributed_fullstack_github.zig` and wired it into `test-e2e-provider-protocol-fullstack-github` so CI now runs a non-mock provider distributed fullstack path.
- Split non-mock distributed fullstack into its own CI lane: `E2E - Distributed Fullstack (GitHub Copilot)`.

### Batch G — Bun-inspired WebSocket Evaluation
- [ ] Add short design note on low-level socket/C-C++ interop options
- [ ] Define objective benchmark + reliability criteria
- [ ] Build minimal POC decision gate (go/no-go)

---

## Resume Notes (for provider/model switch)
- Resume at first unchecked item in top-most active batch.
- Keep one batch per PR-sized commit group.
- Preserve CI-first policy.

## Last Updated
- 2026-02-22
- By: coding agent
