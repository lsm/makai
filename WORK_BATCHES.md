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
- [ ] Add CI job split for websocket-heavy test lanes (if needed)

Progress note:
- Added reconnect precondition coverage (`closed` state can reconnect path), guard coverage for non-reconnectable states, and close idempotence test coverage.
- Added reconnect retryability + stale-buffer clearing coverage for reconnect/resubscribe-ready attempts.
- Added ping timeout state coverage (timeout threshold trigger and pong-reset behavior).
- Added close-frame receive and closing->closed cleanup robustness coverage.

### Batch C — Provider Client Multiplexing API Cleanup
- [ ] Add explicit stream lifecycle helpers (`closeStream`, `removeStreamState`)
- [ ] Add tests for per-stream cleanup (no leaks after stream terminal)
- [ ] Add tests for interleaved done/error/result across 2+ streams
- [ ] Add docs/examples for new `startStream` + `getEventStreamFor` flow

### Batch D — Agent Client Multiplexing Ergonomics
- [ ] Add explicit per-session helpers (query completion/error by session)
- [ ] Add session lifecycle cleanup APIs
- [ ] Add tests for multi-session stop/restart with strict per-session sequence continuity

### Batch E — Tool Protocol Design -> Implementation Slice 1
- [ ] Define tool protocol message types (request/response/events)
- [ ] Add envelope serialization/deserialization tests
- [ ] Add negative tests (unknown tool, malformed args, timeout)
- [ ] Add runtime pump path for tool protocol messages

### Batch F — Tool Protocol Integration Slice 2
- [ ] Integrate tool protocol with agent loop execution path
- [ ] Add distributed chain integration test including tool execution
- [ ] Add cancellation and terminal guarantees tests

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
