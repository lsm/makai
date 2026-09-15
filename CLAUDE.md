# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Makai is a Zig-first streaming AI runtime plus a TypeScript SDK. The Zig core (`zig/src/`) provides a unified multi-provider streaming abstraction (Anthropic, OpenAI Completions/Responses, Azure OpenAI, Google Generative AI/Vertex, OpenAI Codex, Gemini CLI, Ollama), four distributed wire protocols (auth, provider, agent, tool), an agent loop with local tool execution, OAuth flows with credential storage, pluggable transports, and a `makai` binary that runs as a stdio protocol host, a terminal UI, or a one-shot CLI. The TypeScript SDK (`typescript/`) spawns `makai --stdio` and exposes `auth`/`models`/`provider`/`agent` namespaces over newline-delimited JSON frames.

`DESIGN.md` is the authoritative design reference (layers, protocol boundaries, sequencing, ownership, transport posture, test strategy). `docs/v1-sdk-agent-provider-spec.md` is the normative SDK + protocol spec. Read those before changing protocol or SDK behavior.

## Build and Test Commands

All Zig commands run from the repo root (where `build.zig` and `build.zig.zon` live). Requires Zig 0.16.0 (`mlugg/setup-zig` in CI). Node 22 for the TypeScript SDK and scripts.

```bash
zig build                         # Build + install zig-out/bin/makai
zig build run -- --version        # Run the makai CLI (args after --)
zig build run-tui                 # Run the terminal UI
zig build test                    # Run every unit test module
zig build -Doptimize=ReleaseFast  # Optimized binary (used for the PTY harness and release)
```

### Grouped Unit Test Steps

There is no per-test filter; the smallest runnable unit is a group step (each maps to a CI matrix job, 3-minute timeout). Tests are inline `test "name" { ... }` blocks in each `.zig` file.

```bash
zig build test-unit-core          # event_stream, streaming_json, ai_types, tool_call_tracker, owned_slice, string_builder, hive_array, compat, artifact store, bench helpers
zig build test-unit-transport     # transport, stdio, sse, websocket, in_process, transport_retry
zig build test-unit-protocol      # provider/agent/auth/tool protocol types+envelope+server+client+runtime, partial serializer/reconstructor, model_ref, model catalog types, provider_base_url
zig build test-unit-providers     # api_registry, stream, register_builtins, sse_parser, every provider API, auth provider defs
zig build test-unit-utils         # oauth (pkce, openai_codex, refresh_lock, mod), github_copilot, overflow, retry, oom, sanitize, pre_transform, auth_resolver
zig build test-unit-makai-cli     # zig/src/tools/makai.zig + auth_cli
zig build test-unit-tui           # tui runtime/session/config/session_store/state/commands/login/app/views, model_catalog, scenario + e2e + mock transport tests
zig build test-unit-agent         # aggregate: permission, agent types/loop/mod/bridge, tools/*, tui runtime, zig/test/unit/*
zig build test-unit-agent-types | test-unit-agent-loop | test-unit-agent-mod | test-unit-agent-bridge | test-unit-agent-unit | test-unit-agent-chain
```

### E2E Steps

```bash
zig build test-e2e-protocol                     # mock-based, no keys; runs in CI
zig build test-e2e-distributed-fullstack        # mock-based, no keys
zig build test-e2e-anthropic                    # ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL
zig build test-e2e-openai                       # OPENAI_API_KEY, OPENAI_MODEL, OPENAI_RESPONSES_MODEL
zig build test-e2e-google                       # GOOGLE_API_KEY, GOOGLE_MODEL
zig build test-e2e-ollama                       # OLLAMA_API_KEY, OLLAMA_MODEL
zig build test-e2e-azure                        # AZURE_OPENAI_API_KEY, AZURE_OPENAI_BASE_URL, AZURE_OPENAI_MODEL (disabled in CI)
zig build test-e2e-github-copilot               # GH_COPILOT_REFRESH, GH_COPILOT_ACCESS (disabled in CI, quota)
zig build test-e2e-provider-protocol-fullstack-ollama | -github
zig build test-e2e-distributed-fullstack-github
zig build test-e2e                              # aggregate of the above (needs all keys)
```

See `.github/workflows/ci.yml` for the exact env wiring and which lanes are currently gated off.

### Guardrails (CI runs both before unit tests)

```bash
./scripts/check-zig-patterns.sh                  # no runtime `catch unreachable`, no direct std.crypto.random, deinit poisoning in critical types
node scripts/check-no-comments.mjs --check       # zero-comments policy over every tracked .zig/.ts (--stats for counts, --write to strip)
node --test scripts/check-no-comments.test.mjs   # checker self-tests
```

### TypeScript SDK

```bash
npm ci
npm run build:sdk                 # tsc -> dist/
npm run test:sdk                  # build + node --test dist/test/**/*.test.js; needs a makai binary
npm run check:declarations        # verifies the packed tarball ships .d.ts and type-checks in a fresh consumer
npm run demo:start                # builds then runs dist/demo/server.js
```

SDK tests resolve the binary from `MAKAI_BINARY_PATH`, then `./zig-out/bin/makai`, `./zig/zig-out/bin/makai`, then `PATH`. Run `zig build` first (CI uses `zig build install --prefix /tmp/makai-smoke`).

### TUI PTY Harness and Benchmarks

```bash
zig build install -Doptimize=ReleaseFast --prefix /tmp/makai-pty
python3 scripts/tui-pty-driver.py --binary /tmp/makai-pty/bin/makai --output-dir tui-pty-out --scenario all
zig build bench -Doptimize=ReleaseFast -- --mode latency --samples 30 --iterations 100 --host-class <host>
zig build bench-compare -Doptimize=ReleaseFast -- baseline.jsonl candidate.jsonl
./scripts/capture-benchmark-baseline.sh <out-dir> <host-class> [git-revision]
```

The PTY driver is deterministic: `MAKAI_TUI_FIXTURE` selects a canned reply (see `zig/src/tui/fixture_provider.zig`), so no keys or network are needed. It is Linux-only (rejects macOS). Details in `docs/tui-performance-baseline.md` and `docs/performance-baseline.md`.

## Build System Conventions

`build.zig` (~2000 lines) declares one `b.createModule` per source file with an explicit `.imports` list, then one `b.addTest` per module, then wires each test into `test` and the matching `test-unit-*` group. Consequences:

- Source files import by module name, not path: `@import("ai_types")`, `@import("oauth/storage")`, `@import("tools/registry")`, `@import("compat")`. The name is whatever `build.zig` assigned; `oauth/*` names map to `zig/src/utils/oauth/*`.
- Adding a file means: create the module in `build.zig`, list every import it needs, add an `addTest`, and add the run artifact to both `test_step` and the right group step. A missing import fails at compile time with "no module named ...".
- Only `zig/src/utils/oauth/` is the production OAuth tree (storage, refresh_lock, pkce, anthropic, github_copilot, google, openai_codex, callback_server). `zig/src/oauth/` is an older tree wired only into the utils test group.
- `zig/src/providers/bedrock_converse_stream_api.zig` exists but is not declared in `build.zig`; it is an unwired stub returning `error.NotImplemented`.
- The only external dependency is `zigzag`, a vendored TUI framework at `zig/vendor/zigzag` declared as a path dependency in `build.zig.zon`. It is subject to the zero-comments policy like everything else.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Hosts: zig/src/tools/makai.zig (CLI: --stdio, --tui, -p,    │
│         auth), zig/src/tui/ (zigzag TUI), typescript/ (SDK)  │
├──────────────────────────────────────────────────────────────┤
│  Agent Layer (agent/): agent.zig, agent_loop.zig, types.zig, │
│    provider_protocol_bridge.zig                              │
│  Local tools (tools/): shell, file, edit, search, workspace, │
│    artifact, hashline, mcp_bridge, registry, permission      │
├──────────────────────────────────────────────────────────────┤
│  Protocol Layer (protocol/): auth/, provider/, agent/, tool/ │
│    each = types + envelope + server (+ client) + runtime     │
│    model_ref.zig, model_catalog_types.zig                    │
├──────────────────────────────────────────────────────────────┤
│  Transport Layer: transport.zig (Sender/Receiver, ByteStream)│
│    transports/: stdio, sse, websocket, in_process, retry     │
├──────────────────────────────────────────────────────────────┤
│  Streaming Core: ai_types, event_stream, api_registry,       │
│    stream, streaming_json, tool_call_tracker, json/writer,   │
│    providers/sse_parser, model_catalog, provider_base_url    │
├──────────────────────────────────────────────────────────────┤
│  Providers (providers/): anthropic_messages, openai_          │
│    completions, openai_responses, azure_openai_responses,    │
│    google_generative, google_vertex, ollama; register_builtins│
├──────────────────────────────────────────────────────────────┤
│  Utils, auth, compat: utils/ (oauth/*, auth_resolver, retry, │
│    sanitize, overflow, pre_transform, aws_sigv4, ...),       │
│    auth/providers.zig, compat/ (time, random, fs, stdio,     │
│    http, net wrappers over Zig 0.16 std.Io)                  │
└──────────────────────────────────────────────────────────────┘
```

### Canonical Distributed Topology

```
End user code -> Agent Protocol Client -> transport -> Agent Protocol Server
  -> Agent -> Agent Loop -> Provider Protocol Client -> transport
  -> Provider Protocol Server -> Provider
Agent Loop -> Tool Protocol Client -> transport -> Tool Protocol Server -> Tool Runtime
```

Ownership and auth boundary (non-negotiable):
- **Agent layer is auth-agnostic**: no API keys or OAuth handling in agent logic.
- **Auth protocol/runtime owns interactive OAuth flows and credential persistence**; **providers own request-time credential consumption/refresh** (`utils/auth_resolver.zig`, `utils/oauth/storage.zig`).
- **Tool auth/permissions live at the tool protocol / tool runtime boundary** (`tools/permission.zig`, `protocol/tool/local_runtime.zig`).
- SDKs never see raw tokens and must not spawn `makai auth ...` subprocesses as their auth path.

### How the `makai --stdio` host is wired

`runStdioMode` in `zig/src/tools/makai.zig` hosts all three protocol servers (auth, provider, agent) in one process, each behind its own `in_process.SerializedPipe`, and routes inbound stdin frames by envelope type. The agent server drives `agent_loop` through `agent/provider_protocol_bridge.zig` (`InProcessProviderProtocolBridge`), so even in-process the agent talks to providers through the provider protocol. Distributed tools are executed by the SDK client: the host publishes `tool_execute`, waits for a correlated `tool_result` (`in_reply_to` must match the request `message_id`), and cancels parked waits on stdin EOF. `MAKAI_AGENT_SESSION_IDLE_TTL_MS` tunes server-side idle-session eviction (default 30 min, `0` disables).

### Protocol Normative Rules (from DESIGN.md §4-5)

- IDs: `session_id` is a 21-char NanoID; `message_id`, `stream_id`, `flow_id` are 26-char uppercase Crockford ULIDs. Treat all as opaque.
- Sequencing is per session/stream (provider: `stream_id`; auth: `stream_id` for queries, `flow_id` for login; agent: `session_id`), starts at 1, increments by exactly 1, no gaps or duplicates. A global counter is non-conformant.
- All protocols multiplex concurrent sessions over one transport; ordering is guaranteed only within a session/stream.
- Model refs are `provider_id/api@model_id` (`protocol/model_ref.zig`); SDK consumers must not parse or construct them.
- `session_id` is a correlation key, never a resume handle. Sessions are not resumable.

### Key Abstractions

**`ai_types.zig`**: `ContentBlock` (text, tool_use, thinking, image, tool_result), `AssistantMessageEvent` (start; text/thinking/toolcall start/delta/end; done; error; keepalive, each carrying a `partial: AssistantMessage`), `AssistantMessage`, `Usage` (+ `calculateCost`), `Model` (with `OpenAICompatOptions`), `StreamOptions`, `CancelToken`, `ToolCall`, plus `clone*`/`deinit*` helpers.

**`event_stream.zig`**: `EventStream(T, R)`, a 256-slot lock-free ring buffer with futex wakeups. `AssistantMessageStream = EventStream(AssistantMessageEvent, AssistantMessage)`. Methods: `push`, `poll`, `pollBatch`, `wait`, `complete`, `completeWithError`, `getError`, `getResult` (borrowed), `cloneResult` (owned). `owns_events` (default false) flips a stream into deep-copy-on-push mode where the consumer frees each polled event.

**`api_registry.zig` + `register_builtins.zig`**: providers register by API name. Built-ins: `anthropic-messages`, `openai-completions`, `openai-responses`, `azure-openai-responses`, `openai-codex-responses`, `google-generative-ai`, `google-gemini-cli`, `ollama`. `stream.zig` exposes `stream`/`streamSimple`/`complete`/`completeSimple` facades over the registry.

**`protocol/provider/client.zig`**: `ProtocolClient` is multiplexed. Per-stream lifecycle: `startStream` (keep the `stream_id`) -> `getEventStreamFor` -> `waitResultFor`/`getLastErrorFor` -> `closeStream` -> `removeStreamState`. `partial_serializer.zig`/`partial_reconstructor.zig` move `AssistantMessage` snapshots across the wire.

**`protocol/*/runtime.zig`** files are pump/orchestration runtimes hosted on the server side of each boundary, not protocol definitions.

**`agent/`**: `AgentEvent` (agent_start, turn_start, message_start/update, tool_execution_start/end, turn_end, agent_end, error), `AgentTool`, `AgentLoopConfig`, `AgentContext`, `AgentEventStream`. `agent_loop.zig` supports steering/follow-up messages and sequential tool execution with streaming updates. `zig/docs/agent-loop-design.md` describes the design.

**`tools/registry.zig`**: `ToolRegistry.registerDefaults()` installs the built-in local tools; `registerMcpBridge` adds MCP-provided tools. `tools/permission.zig` classifies calls (read/write/shell) into allow/deny/prompt decisions and drives the TUI approval flow.

**`compat/`**: Makai-owned wrappers over Zig 0.16 `std.Io` (time, random, fs, stdio, http, net). Per `docs/zig-0.16.0-io-architecture-decision.md`, public constructors and entry points must not take `std.Io` in their signatures; only internal helpers may. Use `compat.random` secure helpers for OAuth state, PKCE, WebSocket masks, and protocol IDs (the pattern script enforces this per file).

### Stream Completion and Memory Ownership (CRITICAL)

A stream ends via `complete(result)` / `completeWithError(msg)`. Never gate on a `.done` event: no built-in provider pushes one (pushing `.done` would alias the same `AssistantMessage` in an event and the result and double-free). Consumer pattern: drain `wait()` until it returns `null`, check `getError()`, then `cloneResult(allocator)` before `deinit()`.

**EventStream does not own event strings** unless `owns_events` is true. Provider events carry borrowed slices into SSE/JSON buffers owned by the producer thread. `ProtocolClient` deep-copies with `cloneAssistantMessageEvent()` before it queues. **Do not add `deinitAssistantMessageEvent()` to `EventStream.deinit()`**; that double-frees borrowed paths (CI, 2026-02-19). Providers and mocks must hand `complete()` a fully heap-owned result because the stream frees it at `deinit()`. Full contract: `docs/zig-stream-memory-ownership.md`.

All allocations take an explicit `std.mem.Allocator`; tests use `std.testing.allocator` for leak detection. The ring buffer never allocates during streaming.

## The `makai` Binary

```
makai --version
makai --stdio                                   # protocol host for the TS SDK (NDJSON frames on stdin/stdout)
makai --tui                                     # local-only terminal UI
makai -p [--agent] [--storage] "<prompt>" [--model <id>]   # print mode: stream one prompt, dump every event
makai auth providers [--json]                   # thin wrappers over the auth protocol runtime
makai auth login --provider <id> [--json]
```

On-disk state: credentials in `~/.makai/auth.json` (mode 0600, written via same-directory temp + rename; macOS keychain service `com.makai.auth`), TUI sessions in `~/.makai/sessions`, TUI config under `~/.makai`. `.makai/` is gitignored. `MAKAI_BASE_URL` (+ `MAKAI_BASE_URL_IS_PROXY`) and per-provider `*_BASE_URL` vars override endpoints (`provider_base_url.zig`). `MAKAI_DEBUG_PROVIDER_PAYLOAD=<path>` makes the OpenAI Completions provider write its request body to that file.

## Providers

**Adding a provider**: create `zig/src/providers/<name>_api.zig` with `stream*()` functions that build JSON via `json/writer.zig`, parse SSE with `providers/sse_parser.zig`, and push into an `AssistantMessageStream` honoring the `CancelToken`; register it in `register_builtins.zig`; declare the module and tests in `build.zig` (`test-unit-providers` group); add an E2E file under `zig/test/e2e/` and a CI lane if it needs keys.

**Adding a transport**: implement `Sender`/`Receiver` from `transport.zig` in `zig/src/transports/<name>.zig`; wire into `build.zig` with the `transport` import and the `test-unit-transport` group.

Notes: OpenAI Responses (`openai-responses`) and Completions (`openai-completions`) are separate wire formats; Google Generative uses API keys while Vertex needs `GOOGLE_CLOUD_PROJECT`/`GOOGLE_CLOUD_LOCATION` and ADC; Anthropic and Google support `thinking` blocks with `budget_tokens` (Google replays `thoughtSignature`); OpenAI Completions is an owned-event stream (`owns_events == true`). `model_catalog.zig` is the static fallback catalog behind `models.list`.

## TUI

`zig/src/tui/` is built on the vendored `zigzag` framework: `app.zig` (entry, approval waiter, fixture runtime), `runtime.zig` (`TuiRuntime` over the agent loop with local tools and a `PermissionMode` of ask/bypass), `session.zig`/`session_store.zig` (JSONL persistence, 8 MiB cap), `state.zig`, `commands.zig` (the ratified 10 slash commands), `views/` (transcript, composer, status_bar, approval, session_picker, menu_picker), `render.zig`, `text.zig`, `theme.zig`. The TUI is local-only (no remote backend). Deterministic tests use `fixture_provider.zig` and `tests/mock_transport.zig`; the PTY harness covers the real terminal path.

## Zig Conventions

- **Zero comments** in every tracked `.zig` and `.ts` file, including `build.zig`, tests, fixtures, and `zig/vendor`: no `//`, `///`, `//!`, block, or JSDoc comments. The only exemptions are functional directives: `// zig fmt: off|on`; in TypeScript, shebangs, file-leading `/// <reference>` and `@ts-check`/`@ts-nocheck`, `@ts-ignore`/`@ts-expect-error`, JSDoc `@deprecated`, `biome-ignore`, `eslint-*`, `oxlint-*`, knip `@public`/`knip-ignore`, and `v8`/`istanbul`/`c8` ignores. The allowlist ratchet is retired (`scripts/no-comments-allowlist.txt.retired`); there is no grandfathering. Rationale goes in commit messages, PR descriptions, `docs/`, and tests.
- snake_case functions/variables, PascalCase types, inline tests, error unions, comptime generics.
- **Poison after deinit**: critical `deinit()` methods end with `self.* = undefined;`. The pattern script requires it in event_stream, api_registry, agent, protocol client/server, tool_call_tracker, streaming_json, sse_parser, partial_reconstructor.
- **`OwnedSlice(T)`** (`owned_slice.zig`) instead of ad-hoc `owned_*: bool` flags.
- **`oom.unreachableOnOom(...)`** (`utils/oom.zig`) instead of `catch unreachable` (only `utils/retry.zig` is exempt).
- **Two-phase `StringBuilder`** (`string_builder.zig`): `count`/`countFmt`, one `allocate`, then `append`/`appendFmt`.
- **`HiveArray(T, capacity)`** (`hive_array.zig`) for bounded high-churn pools.
- Background reading: `docs/bun-zig-patterns.md`, `docs/tigerbeetle-zig-patterns.md` (invariant helpers, explicit limits at external accumulation points, validate-at-boundary vs assert-internal).

## Docs and PR Process

- Commits follow `type(scope): subject (#PR)` (e.g. `fix(tui): ...`, `feat(agent): ...`, `docs(spec): ...`). `CHANGELOG.md` follows Keep a Changelog; add entries under `Unreleased`.
- The PR template (`.github/PULL_REQUEST_TEMPLATE.md`) and `docs/review-process.md` require: linked spec clauses (`docs/v1-sdk-agent-provider-spec.md`, `docs/ts-sdk-chat-integration-plan.md`, `DESIGN.md`), updated rows in `docs/implementation-traceability-matrix.md`, a backward-compatibility statement, test evidence, and external review rounds with no unresolved P0/P1. If behavior changes, update the spec/docs in the same PR (no spec drift). Keep PRs to one phase/sub-phase.
- `docs/oap-alignment.md` is the Open Agent Protocol deviations ledger; `docs/zig-0.16.0-*.md` record the completed Zig 0.16 migration and its I/O decision; `docs/persisted-tool-call-rendering.md` and `docs/markdown-rendering-investigation.md` cover TUI rendering decisions.
- Release: tagging `v*` runs `.github/workflows/release-binaries.yml` (six targets) and `scripts/package-npm.ts` builds the `@makai/cli-<platform>` optional-dependency packages that `bin/makai.js` dispatches to. CI's cross-compile smoke job builds the non-native targets on every PR.
