# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Makai is a Zig implementation of a unified multi-provider AI streaming abstraction layer. It provides a common interface for streaming responses from Anthropic Claude, OpenAI GPT, and Ollama, with lock-free event queues, type-safe tagged unions, and benchmarking infrastructure.

## Build Commands

All build commands run from the `zig/` directory. Requires Zig 0.13.0+.

```bash
cd zig
zig build test          # Run all unit tests (10 test modules)
zig build run           # Run the demo application
zig build bench         # Run core benchmarks (ReleaseFast)
zig build fiber-bench   # Fiber vs thread benchmarks
zig build xev-bench     # libxev vs ZIO vs threads benchmarks
zig build mt-xev-bench  # Multi-threaded libxev benchmarks
zig build shared-bench  # ZIO shared runtime benchmarks
```

There is no single-test command. Tests are inline in each `.zig` file using Zig's built-in `test` blocks, and `zig build test` runs all modules.

## Dependencies

Managed via `zig/build.zig.zon` with automatic fetching and hash verification:
- **zio** (v0.7.0): Fiber-based async runtime for structured concurrency
- **libxev**: Cross-platform event loop (epoll/kqueue/IOCP)

## Architecture

### Module Dependency Graph

```
types.zig                    (core types, no deps)
  ├── event_stream.zig       (lock-free ring buffer event queue)
  │     ├── provider.zig     (provider registry abstraction)
  │     │     ├── mock_provider.zig / fiber_mock_provider.zig
  │     │     └── providers/anthropic.zig, openai.zig, ollama.zig
  │     └── (used by all providers)
  └── providers/config.zig   (per-provider configuration structs)

json/writer.zig              (JSON serialization, no deps)
providers/sse_parser.zig     (SSE parsing, no deps)
providers/http.zig           (async HTTP client, depends on libxev)
```

### Key Abstractions

**`types.zig`** - Core domain types used everywhere:
- `ContentBlock`: Tagged union — `text`, `tool_use`, `thinking`, `image`
- `MessageEvent`: 13-variant tagged union for streaming events (start, text_delta, toolcall_delta, done, error, etc.)
- `Usage`: Token counting with `add()` and `total()` methods
- `AssistantMessage`: Final result containing content blocks, usage, stop reason, model

**`event_stream.zig`** - `EventStream(T, R)`: Lock-free ring buffer (256 slots) with futex synchronization. The main concrete type is `AssistantMessageStream = EventStream(MessageEvent, AssistantMessage)`. Key methods: `push`, `poll`, `pollBatch`, `wait` (blocking), `complete`, `completeWithError`.

**`provider.zig`** - Two provider interfaces:
- `Provider` (legacy): Simple struct with `stream_fn`
- `ProviderV2` (current): Adds `context: *anyopaque` for configuration and optional `deinit_fn`
- Both have `Registry`/`RegistryV2` for string-keyed lookup

**`providers/`** - Each provider (anthropic, openai, ollama) implements streaming via SSE parsing over HTTP, building request JSON with `json/writer.zig`, and pushing events into an `AssistantMessageStream`.

### Adding a New Provider

1. Create `zig/src/providers/<name>.zig`
2. Implement a `createProvider()` function returning `ProviderV2`
3. Add provider-specific config struct in `config.zig`
4. Register the module in `zig/build.zig` (create module + add to test step)

### Memory Management

All allocations go through explicit `std.mem.Allocator` parameters. Tests use `std.testing.allocator` which detects leaks. The event stream ring buffer is fixed-size (no dynamic allocation during streaming).

## Zig Conventions in This Codebase

- snake_case for functions/variables, PascalCase for types
- Inline tests in source files (`test "name" { ... }`)
- Error unions for fallible operations
- Comptime generics (e.g., `EventStream(T, R)`)
