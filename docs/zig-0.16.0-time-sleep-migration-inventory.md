# Phase 2 Time / Sleep Migration Inventory

This inventory captures every direct call to `std.time.*` and `std.Thread.sleep` in
`zig/src/` as of Phase 0 work item 3. Phase 0 introduced the wrappers in
`zig/src/compat/time.zig` (`nowMillis`, `nowSeconds`, `nowNanos`, `monotonicNanos`,
`sleepNs`, `sleepMs`) and migrated two representative low-risk call sites
(`zig/src/utils/retry.zig`, `zig/src/protocol/provider/types.zig`).

The remaining call sites listed here are deferred to Phase 2 work item 13
("Migrate time, sleep, and timestamp call sites through wrappers"). Each
remaining site must be ported either to the existing wrappers or to a
follow-up wrapper added in the same PR. After migration, the goal is for the
only direct `std.time.*` / `std.Thread.sleep` references in `zig/src/` to live
inside `zig/src/compat/time.zig` itself.

## Summary

- 277 remaining `std.time.{timestamp,milliTimestamp,nanoTimestamp,Timer,Instant}`
  occurrences across 36 files (excluding the wrapper module itself).
- 26 remaining `std.Thread.sleep` occurrences across 11 files (excluding the
  wrapper module itself).

The full breakdown is below. Counts were produced via ripgrep on the
`add-time-and-sleep-wrappers-on-0-15-2-phase-0-item-3` branch.

## `std.time.{timestamp,milliTimestamp,nanoTimestamp,Timer,Instant}` call sites

### Streaming core
- `zig/src/event_stream.zig` (2)
- `zig/src/agent/types.zig` (1)
- `zig/src/agent/agent.zig` (2)
- `zig/src/agent/agent_loop.zig` (4)
- `zig/src/agent/provider_protocol_bridge.zig` (5)

### Protocol layer
- `zig/src/protocol/provider/server.zig` (62)
- `zig/src/protocol/provider/client.zig` (26)
- `zig/src/protocol/provider/envelope.zig` (22)
- `zig/src/protocol/provider/runtime.zig` (3)
- `zig/src/protocol/agent/server.zig` (22)
- `zig/src/protocol/agent/client.zig` (7)
- `zig/src/protocol/agent/envelope.zig` (5)
- `zig/src/protocol/auth/server.zig` (15)
- `zig/src/protocol/auth/envelope.zig` (1)
- `zig/src/protocol/tool/runtime.zig` (4)
- `zig/src/protocol/tool/envelope.zig` (2)

### Providers
- `zig/src/providers/openai_completions_api.zig` (15)
- `zig/src/providers/openai_responses_api.zig` (12)
- `zig/src/providers/azure_openai_responses_api.zig` (2)
- `zig/src/providers/anthropic_messages_api.zig` (3)
- `zig/src/providers/google_generative_api.zig` (4)
- `zig/src/providers/google_vertex_api.zig` (4)
- `zig/src/providers/ollama_api.zig` (5)

### OAuth and auth
- `zig/src/oauth/mod.zig` (2)
- `zig/src/oauth/github_copilot.zig` (4)
- `zig/src/utils/oauth/anthropic.zig` (4)
- `zig/src/utils/oauth/google.zig` (3)
- `zig/src/utils/oauth/github_copilot.zig` (5)
- `zig/src/utils/oauth/storage.zig` (4)
- `zig/src/utils/oauth/callback_server.zig` (2)
- `zig/src/utils/oauth/refresh_lock.zig` (4)
- `zig/src/utils/auth_resolver.zig` (1)

### Utilities and tools
- `zig/src/utils/aws_sigv4.zig` (1)
- `zig/src/utils/pre_transform.zig` (1)
- `zig/src/tools/auth_cli.zig` (3)
- `zig/src/tools/makai.zig` (8)

## `std.Thread.sleep` call sites

- `zig/src/event_stream.zig` (1)
- `zig/src/agent/provider_protocol_bridge.zig` (2)
- `zig/src/protocol/provider/client.zig` (1)
- `zig/src/protocol/provider/server.zig` (1)
- `zig/src/transports/in_process.zig` (1)
- `zig/src/transports/stdio.zig` (1)
- `zig/src/utils/oauth/refresh_lock.zig` (6)
- `zig/src/utils/oauth/github_copilot.zig` (2)
- `zig/src/utils/oauth/callback_server.zig` (1)
- `zig/src/tools/auth_cli.zig` (2)
- `zig/src/tools/makai.zig` (8)

## Migration guidance for Phase 2 work item 13

- Wall-clock millisecond timestamps → `compat.time.nowMillis()`.
- Wall-clock second timestamps → `compat.time.nowSeconds()`.
- Wall-clock nanosecond timestamps → `compat.time.nowNanos()`.
- Monotonic durations / deadlines → `compat.time.monotonicNanos()` (do not
  reuse the wall-clock helpers for elapsed-duration math).
- Direct nanosecond sleeps → `compat.time.sleepNs(ns)`.
- Millisecond sleeps → `compat.time.sleepMs(ms)`. The convenience helper
  saturates to `std.math.maxInt(u64)` instead of overflowing on absurd inputs.
- Cancellable polling sleeps that already exist (e.g.
  `zig/src/utils/retry.zig:sleepMs(ms, cancel_token)`) should keep their own
  shape but call into `compat.time.sleepNs` internally; do **not** reintroduce
  direct `std.Thread.sleep` once a wrapper is available.
- `std.time.Timer.start()` and `std.time.Instant.now()` usages should be
  reviewed individually: most can switch to `compat.time.monotonicNanos()`,
  but a few keep their own `std.time.Timer` for elapsed-duration math local
  to a function and may simply gain a `// 0.16: route through default I/O
  context` comment instead.

After Phase 2 work item 13 lands, the only `std.time.*` and `std.Thread.sleep`
references in `zig/src/` should live inside `zig/src/compat/time.zig`. A grep
guardrail for that invariant can be added to `scripts/check-zig-patterns.sh`
in the same PR.
