# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Makai is a Zig implementation of a unified multi-provider AI streaming abstraction layer. It provides a common interface for streaming responses from Anthropic, OpenAI (Completions & Responses APIs), Google (Generative AI & Vertex), Azure OpenAI, AWS Bedrock, and Ollama, with lock-free event queues, type-safe tagged unions, OAuth flows, and benchmarking infrastructure.

## Build Commands

All build commands run from the `zig/` directory. Requires Zig 0.13.0+.

```bash
cd zig
zig build test          # Run all unit tests (27 modules: 22 unit + 5 e2e)
zig build run           # Run the demo application
```

There is no single-test command. Tests are inline in each `.zig` file using Zig's built-in `test` blocks, and `zig build test` runs all modules.

## Dependencies

Managed via `zig/build.zig.zon` with automatic fetching and hash verification:
- **libxev**: Cross-platform event loop (epoll/kqueue/IOCP) for async I/O

## Architecture

### Module Dependency Graph

```
types.zig                    (core types, no deps)
  ├── ai_types.zig           (extended AI types: Model, Message, ContentBlock variants)
  │     ├── event_stream.zig (lock-free ring buffer event queue)
  │     │     ├── api_registry.zig (API provider registry)
  │     │     │     ├── providers/anthropic_messages_api.zig
  │     │     │     ├── providers/openai_completions_api.zig
  │     │     │     ├── providers/openai_responses_api.zig
  │     │     │     ├── providers/google_generative_api.zig
  │     │     │     ├── providers/google_vertex_api.zig
  │     │     │     ├── providers/azure_openai_responses_api.zig
  │     │     │     ├── providers/bedrock_converse_stream_api.zig
  │     │     │     └── providers/ollama_api.zig
  │     │     └── (used by all providers)
  │     └── oauth/mod.zig    (OAuth credentials and provider registry)
  │           ├── oauth/pkce.zig
  │           ├── oauth/github_copilot.zig
  │           └── oauth/google_*.zig, openai_codex.zig
  └── providers/config.zig   (per-provider configuration structs)

json/writer.zig              (JSON serialization, no deps)
providers/sse_parser.zig     (SSE parsing, no deps)
providers/http.zig           (async HTTP client, depends on libxev)
streaming_json.zig           (streaming JSON parsing)
tool_call_tracker.zig        (partial tool call assembly)

utils/
  ├── sanitize.zig           (UTF-16 surrogate sanitization)
  ├── overflow.zig           (context overflow error detection)
  ├── retry.zig              (exponential backoff, Retry-After parsing)
  ├── provider_caps.zig      (provider capability detection)
  ├── message_transform.zig  (thinking block format conversion)
  ├── pre_transform.zig      (cross-model thinking conversion)
  ├── tokens.zig             (token estimation utilities)
  ├── tool_utils.zig         (tool call ID normalization)
  └── aws_sigv4.zig          (AWS Signature v4 signing - for Bedrock)
```

### Key Abstractions

**`types.zig`** - Core domain types:
- `ContentBlock`: Tagged union — `text`, `tool_use`, `thinking`, `image`, `tool_result`
- `ToolResultContent`: Union of `text` and `image` for tool result payloads
- `MessageEvent`: 13-variant tagged union for streaming events (start, text_delta, thinking_delta, toolcall_delta, done, error, etc.)
- `Usage`: Token counting with `add()` and `total()` methods, includes cache read/write tokens
- `AssistantMessage`: Final result containing content blocks, usage, stop reason, model

**`ai_types.zig`** - Extended AI types:
- `Model`: Provider, name, context window, pricing, compatibility options (`OpenAICompatOptions`)
- `StreamOptions`: All streaming options including service_tier, reasoning_summary, thinking config, cache control
- `ServiceTier`: `default`, `flex` (0.5x cost), `priority` (2x cost)
- `CancelToken`: Atomic bool wrapper for request cancellation

**`event_stream.zig`** - `EventStream(T, R)`: Lock-free ring buffer (256 slots) with futex synchronization. Main type: `AssistantMessageStream = EventStream(MessageEvent, AssistantMessage)`. Key methods: `push`, `poll`, `pollBatch`, `wait` (blocking), `complete`, `completeWithError`.

**`api_registry.zig`** - Provider registry with `registerApiProvider()` for registering streaming API implementations by name (e.g., "anthropic-messages", "openai-responses").

**`providers/`** - Each provider implements streaming via SSE parsing over HTTP, building request JSON with `json/writer.zig`, and pushing events into an `AssistantMessageStream`. Providers support cancellation tokens and payload callbacks.

**`oauth/`** - OAuth implementations:
- `pkce.zig`: SHA-256 verifier/challenge generation
- `github_copilot.zig`: Device Flow (RFC 8628) with token exchange
- `google_gemini_cli.zig`, `google_antigravity.zig`, `openai_codex.zig`: Authorization Code Flow with PKCE

### Adding a New Provider

1. Create `zig/src/providers/<name>_api.zig` implementing `stream*()` functions
2. Register in `zig/src/register_builtins.zig` with the API registry
3. Add provider-specific config struct in `config.zig` if needed
4. Register the module in `zig/build.zig` (create module + add to test step)

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
