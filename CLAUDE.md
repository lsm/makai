# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Makai is a Zig implementation of a unified multi-provider AI streaming abstraction layer. It provides a common interface for streaming responses from Anthropic, OpenAI (Completions & Responses APIs), Google (Generative AI & Vertex), Azure OpenAI, AWS Bedrock, and Ollama, with lock-free event queues, type-safe tagged unions, a distributed client-server protocol, an agent loop with tool execution, OAuth flows, and multiple transport backends.

## Build Commands

All build commands run from the `zig/` directory. Requires Zig 0.15.2.

```bash
cd zig
zig build test                    # Run all unit tests
zig build run                     # Run the demo application
```

### Grouped Test Steps

Unit tests are split into groups for parallel CI:

```bash
zig build test-unit-core          # event_stream, streaming_json, ai_types, tool_call_tracker
zig build test-unit-transport     # transport, stdio, sse, websocket, in_process
zig build test-unit-protocol      # content_partial, partial_serializer, protocol types/envelope/reconstructor, server, client, agent types, tool types
zig build test-unit-providers     # api_registry, stream, register_builtins, all provider APIs
zig build test-unit-utils         # github_copilot, oauth/pkce, oauth/mod, overflow, retry, sanitize, pre_transform
zig build test-unit-agent         # agent types, agent_loop, agent module, agent unit test
```

E2E tests require API keys (set via env vars, see `.github/workflows/ci.yml`):

```bash
zig build test-e2e-anthropic
zig build test-e2e-openai
zig build test-e2e-google
zig build test-e2e-ollama
zig build test-e2e-github-copilot
zig build test-e2e-protocol                     # mock-based, no API keys needed
zig build test-e2e-provider-protocol-fullstack-ollama
zig build test-e2e-provider-protocol-fullstack-github
```

There is no single-test command. Tests are inline in each `.zig` file using Zig's built-in `test` blocks, and `zig build test` runs all modules.

## Dependencies

Managed via `zig/build.zig.zon` with automatic fetching and hash verification:
- **libxev**: Cross-platform event loop (epoll/kqueue/IOCP) for async I/O

## Architecture

The system is organized into four layers, each building on the one below:

```
┌─────────────────────────────────────────────┐
│  Agent Layer (agent/)                       │  ← Agent loop with tool execution
│    agent.zig, agent_loop.zig, types.zig     │
├─────────────────────────────────────────────┤
│  Protocol Layer (protocol/)                 │  ← Client-server wire protocol
│    provider/ (server, client, envelope,     │
│      partial_serializer, partial_recon-     │
│      structor, content_partial, types)      │
│    agent/types.zig   tool/types.zig         │
├─────────────────────────────────────────────┤
│  Transport Layer (transports/)              │  ← Pluggable byte-level I/O
│    stdio, sse, websocket, in_process        │
│  transport.zig (interfaces + ByteStream)    │
├─────────────────────────────────────────────┤
│  Streaming Core                             │  ← Provider-agnostic streaming
│    ai_types.zig, event_stream.zig,          │
│    api_registry.zig, stream.zig,            │
│    streaming_json.zig, tool_call_tracker.zig│
│    json/writer.zig, providers/sse_parser.zig│
├─────────────────────────────────────────────┤
│  Providers (providers/)                     │  ← Per-API streaming impls
│    anthropic, openai (completions+responses)│
│    google (generative+vertex), azure, ollama│
│    register_builtins.zig                    │
├─────────────────────────────────────────────┤
│  Utils & OAuth                              │
│    sanitize, overflow, retry, provider_caps │
│    pre_transform, tokens, tool_utils,       │
│    aws_sigv4, oauth/ (pkce, github_copilot, │
│    anthropic, google_*, openai_codex)       │
└─────────────────────────────────────────────┘
```

### Target Distributed Agent Topology (Canonical)

Use this as the default end-to-end architecture when implementing distributed agent execution:

```
End user code
  -> Agent Protocol Client
  -> Agent Protocol Transport
  -> Agent Protocol Server
  -> Agent
  -> Agent Loop
  -> Provider Protocol Client
  -> Provider Protocol Transport
  -> Provider Protocol Server
  -> Provider
```

Distributed tool execution extension (when tools are remote):

```
Agent Loop
  -> Tool Protocol Client
  -> Tool Protocol Transport
  -> Tool Protocol Server
  -> Tool Runtime
```

Ownership and auth boundary:
- **Agent layer is auth-agnostic** (no provider API key/OAuth handling in agent logic).
- **Provider layer owns authentication/credentials** (API keys, OAuth tokens, signing).
- **Tool auth/permissions are handled in the tool protocol/tool runtime boundary** (not in provider auth).

### Key Abstractions

**`ai_types.zig`** - Core domain types:
- `ContentBlock`: Tagged union — `text`, `tool_use`, `thinking`, `image`, `tool_result`
- `MessageEvent` / `AssistantMessageEvent`: 13-variant tagged union for streaming events (start, text_delta, thinking_delta, toolcall_delta, done, error, etc.)
- `Usage`: Token counting with `add()` and `total()` methods, includes cache read/write tokens
- `AssistantMessage`: Final result containing content blocks, usage, stop reason, model
- `Model`: Provider, name, context window, pricing, compatibility options (`OpenAICompatOptions`)
- `StreamOptions`: All streaming options including service_tier, reasoning_summary, thinking config, cache control
- `CancelToken`: Atomic bool wrapper for request cancellation

**`event_stream.zig`** - `EventStream(T, R)`: Lock-free ring buffer (256 slots) with futex synchronization. Main type: `AssistantMessageStream = EventStream(MessageEvent, AssistantMessage)`. Key methods: `push`, `poll`, `pollBatch`, `wait` (blocking), `complete`, `completeWithError`.

**`transport.zig`** - Defines transport interfaces (`Sender`, `Receiver`, `AsyncSender`, `AsyncReceiver`) and wire message types (`MessageOrControl`, `ControlMessage`). Also defines `ByteStream = EventStream(ByteChunk, void)` for async byte-level I/O. Transports implement these interfaces over different backends.

**`protocol/provider/`** - Client-server wire protocol:
- `types.zig`: UUID generation, `Envelope` (stream_id, message_id, sequence, timestamp, payload), `ErrorCode` enum
- `envelope.zig`: JSON serialization/deserialization of protocol envelopes, creation helpers (createStreamStart, createAck, createNack, etc.)
- `server.zig`: Server-side protocol handler — validates sequences, manages streams, routes envelopes to providers
- `client.zig`: Client-side `ProtocolClient` — sends requests via transport, reconstructs `AssistantMessage` from streamed events, manages pending requests. v1.0: single-stream only
- `partial_serializer.zig`: Converts `MessageEvent` stream into partial `AssistantMessage` snapshots for protocol transmission
- `partial_reconstructor.zig`: Rebuilds `AssistantMessage` from partial snapshots on the client side
- `content_partial.zig`: Content block partial state tracking

**`protocol/agent/`** - Distributed agent protocol runtime:
- `types.zig`: wire types/envelopes/payloads
- `envelope.zig`: JSON serialization/deserialization helpers
- `server.zig`: `AgentProtocolServer` session/state handler + outbox
- `client.zig`: `AgentProtocolClient` sender/state/event collector
- `runtime.zig`: `AgentProtocolRuntime` pump for client/server over transport

**`protocol/tool/types.zig`** - Tool protocol types (for distributed tool execution)

**`agent/`** - Agent loop system:
- `types.zig`: `AgentEvent` (agent_start, turn_start, message_start, message_update, tool_execution_start/end, turn_end, agent_end, error), `AgentTool`, `AgentLoopConfig`, `AgentContext`, `AgentEventStream`
- `agent_loop.zig`: Core agentic loop — sends messages to LLM, processes tool calls, feeds results back. Uses `ProtocolClient` or direct streaming
- `agent.zig`: `Agent` struct — high-level API wrapping the agent loop with configuration and state management

**`providers/`** - Each provider implements streaming via SSE parsing over HTTP, building request JSON with `json/writer.zig`, and pushing events into an `AssistantMessageStream`. Providers support cancellation tokens and payload callbacks.

**`api_registry.zig`** - Provider registry with `registerApiProvider()` for registering streaming API implementations by name (e.g., "anthropic-messages", "openai-responses").

### Adding a New Provider

1. Create `zig/src/providers/<name>_api.zig` implementing `stream*()` functions
2. Register in `zig/src/register_builtins.zig` with the API registry
3. Add provider-specific config struct in `config.zig` if needed
4. Create module in `zig/build.zig`, add to test step and appropriate test group

### Adding a New Transport

1. Create `zig/src/transports/<name>.zig` implementing `Sender`/`Receiver` from `transport.zig`
2. Create module in `zig/build.zig` with `transport` import, add to test step and `test-unit-transport` group

### Provider-Specific Notes

**OpenAI Responses vs Completions**: Two separate APIs with different request/response formats. Responses API is newer and supports session-based caching. Use `openai-responses` API name for Responses, `openai-completions` for chat completions.

**Google Generative vs Vertex**: Generative AI uses API keys directly. Vertex requires GCP project/location and uses Application Default Credentials.

**AWS Bedrock**: Currently a stub returning `error.NotImplemented`. Full implementation requires AWS Signature v4 signing.

**Extended Thinking**: Anthropic and Google providers support `thinking` blocks with `budget_tokens` configuration. Google uses `thoughtSignature` for context replay.

### Memory Management

All allocations go through explicit `std.mem.Allocator` parameters. Tests use `std.testing.allocator` which detects leaks. The event stream ring buffer is fixed-size (no dynamic allocation during streaming).

#### EventStream Memory Ownership (CRITICAL)

**EventStream does NOT own event strings.** Events pushed by providers contain **borrowed** string slices (delta, content, id, name, etc.) that point into provider-managed temporary buffers (SSE parser buffers, JSON buffers). The stream's `deinit()` does NOT call `deinitAssistantMessageEvent()`.

| Component | Ownership Model |
|-----------|-----------------|
| **Providers** | Push events with borrowed strings; manage buffer lifetimes in producer thread |
| **ProtocolClient** | Deep-copies via `cloneAssistantMessageEvent()` before push; manages cleanup separately |
| **EventStream** | Does NOT own event strings; only drains ring buffer slots |

**DO NOT** add `deinitAssistantMessageEvent()` to `EventStream.deinit()` - this causes double-free panics. See CI failures from 2026-02-19.

## Zig Conventions in This Codebase

- snake_case for functions/variables, PascalCase for types
- Inline tests in source files (`test "name" { ... }`)
- Error unions for fallible operations
- Comptime generics (e.g., `EventStream(T, R)`)

### Adopted Bun-Inspired Patterns (Use When Appropriate)

- **Poison after deinit**: end critical `deinit()` methods with `self.* = undefined;` to catch use-after-free bugs in debug builds.
- **`OwnedSlice(T)` for ownership-tracked slices** (`zig/src/owned_slice.zig`): prefer this over ad-hoc `owned_*: bool` fields when values may be borrowed or owned.
- **Prefer `oom.unreachableOnOom(...)` over raw `catch unreachable`** (`zig/src/utils/oom.zig`): use this for truly OOM-only allocator init paths so intent is explicit.
- **Two-phase `StringBuilder`** (`zig/src/string_builder.zig`): use `count/countFmt` then single `allocate`, followed by `append/appendFmt` when building strings with known composition to avoid repeated reallocations.
- **`HiveArray(T, capacity)` fixed pool** (`zig/src/hive_array.zig`): use for bounded, high-churn resources where fixed-capacity slot reuse is preferable to heap allocation.
- **Pattern guardrails script**: keep `./scripts/check-zig-patterns.sh` passing (CI runs it before unit tests).
