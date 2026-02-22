# Testing Gap Findings

This document captures cross-layer testing gaps identified on 2026-02-22.

## Priority 1 (implement first)

### Streaming core
- `zig/src/event_stream.zig`
  - Missing queue saturation (`QueueFull`) coverage.
  - Missing ring-buffer wraparound coverage near 256-slot boundary.
  - Missing blocking `wait()` wake-up coverage.
- `zig/src/stream.zig`
  - Missing direct delegation coverage for `stream()`, `streamSimple()`, and `completeSimple()`.
- `zig/src/api_registry.zig`
  - Missing explicit `clearApiProviders()` coverage.

### Protocol
- `zig/src/protocol/provider/server.zig`
  - Missing duplicate stream-id rejection assertion (`stream_already_exists`).
  - Missing explicit ACK sequence assertion in abort success path.
- `zig/src/protocol/provider/envelope.zig`
  - Missing invalid `in_reply_to` UUID rejection test.
- `zig/src/protocol/provider/partial_reconstructor.zig`
  - Missing delta-without-start resilience test.

## Priority 2

### Providers
- `zig/src/providers/azure_openai_responses_api.zig`
  - No unit coverage for `parseEvent()` text delta, completion stop reason, and usage extraction.

### Agent
- `zig/test/unit/agent.zig`
  - Event coverage verifies presence, not strict ordering.
  - Missing outer-loop cancellation short-circuit test.
  - Missing explicit max-iteration termination test.

## Priority 3

### Transport
- Add targeted concurrency/backpressure stress tests across `stdio`, `sse`, `websocket`, and `in_process`.

## Execution notes
- Start with Priority 1 and run corresponding unit groups after each slice.
- Keep tests deterministic and fast to preserve CI stability.
