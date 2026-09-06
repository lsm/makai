# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-05

### Added

- Initial release of Makai, a unified multi-provider AI streaming abstraction layer.
- **Zig core library**: lock-free event queues, type-safe tagged unions, streaming JSON parser, SSE parser, and provider implementations for Anthropic, OpenAI (Completions & Responses), Google (Generative AI & Vertex), Azure OpenAI, AWS Bedrock (stub), and Ollama.
- **Distributed protocol**: client-server wire protocol with envelope-based messaging, partial serialization/reconstruction, and in-process/stdio/SSE/WebSocket transports.
- **Agent loop**: tool execution lifecycle with distributed runtime support.
- **OAuth flows**: GitHub Copilot, Anthropic, Google, and OpenAI Codex OAuth with PKCE.
- **TypeScript SDK**: stdio client transport, high-level APIs for provider completions, streaming, agent runs, auth flows, and model discovery.
- **CLI**: `makai` binary with auth and stdio protocol support.

## Unreleased

### Added

- Added a cross-compile smoke job to CI that compiles the non-native release targets (`aarch64-macos`, `x86_64-macos`, `aarch64-linux`, `x86_64-windows`) on every PR, so macOS/Windows target regressions surface before a release tag instead of failing the tagged release run (#196).
- Documented the Zig stream/result memory-ownership contract for package consumers in [`docs/zig-stream-memory-ownership.md`](docs/zig-stream-memory-ownership.md): event strings are borrowed by default (owned-event streams — `stream.owns_events == true`, e.g. OpenAI Completions — transfer each polled event to the consumer, which frees it with `deinitAssistantMessageEvent`), `wait()` returning `null` (not a `done` event) is the completion signal, and results are taken via `cloneResult()` before the stream is deinit'd. Linked from the README (#186).
- Added `EventStream.cloneResult(allocator)` on `AssistantMessageStream`: one-call deep copy of the completed result that is fully owned (`is_owned = true`), survives `deinit()`, and is safe to `AssistantMessage.deinit()`. Added `ai_types.cloneToolCall`/`deinitToolCall` for collecting `toolcall_end` tool calls, plus unit tests covering the safe consumer flow (stream → events → result → clean deinit) under `std.testing.allocator` (#186).
- Fixed `cloneAssistantMessage` leaking a partially built content block when a field dupe fails mid-block; `cloneResult()`'s OutOfMemory path is now leak-free (regression-tested with `std.testing.FailingAllocator`) (#186).
- Fixed the OpenAI Completions provider publishing completed results whose `api`/`provider`/`model` strings were borrowed from the thread-owned model freed by `ctx.deinit()` before `complete()` — the result dangled for any consumer reading it (including `cloneResult()`). Metadata is now duped into the result with `is_owned = true`, matching every other built-in provider (found in review of #186).
- Added `npm run check:declarations`: rebuilds the SDK into a clean `dist/`, then verifies the `makai` npm tarball ships `*.d.ts` declarations under `dist/src` (including `dist/src/index.d.ts` and a matching declaration for every shipped `.js`) and that a fresh-install consumer project type-checks cleanly under strict TS with `skipLibCheck` disabled. Wired into CI (`ts-sdk-e2e`) and the release packaging job so a build without declarations can no longer ship (#184).

### Changed

- Upgraded the Zig toolchain requirement from Zig 0.15.2 to Zig 0.16.0.
- Removed the unused `libxev` Zig package declaration; `zig/build.zig.zon` now declares no external Zig package dependencies.
- Routed Makai runtime I/O, HTTP, filesystem, random, stdio, timing, and networking internals through Zig 0.16 `std.Io`-based APIs while preserving Makai-owned wrapper boundaries for future backend evolution.
- Split and documented the expanded Zig unit test matrix used by CI, including the Makai CLI and agent subgroups.

### Fixed

- Fixed release builds for macOS targets, which failed with `unable to find framework 'Security'. searched paths: none`: Zig skips its native SDK/framework detection when an explicit `-Dtarget=*-macos` is passed. `build.zig` now resolves the macOS SDK (`$SDKROOT` when set, otherwise `xcrun --show-sdk-path` on macOS hosts) and passes it as the build sysroot plus framework search path for the Security/CoreFoundation frameworks; the release workflow exports `SDKROOT` on the macOS jobs (#196).
- Fixed cross-compiling for Windows, which failed with `no field named 'HOME' in struct 'Io.Threaded.Environ.String'`: `compat.getEnvVarOwned(_, "HOME")` now resolves the home directory per target — POSIX keeps the memoized `HOME` environ scan, Windows resolves `USERPROFILE`, then `HOMEDRIVE` ++ `HOMEPATH` (a plain `HOME`, e.g. from Git Bash, still wins as a last resort) (#196).

### Migration Notes

- See [`docs/zig-0.16.0-downstream-migration.md`](docs/zig-0.16.0-downstream-migration.md) for downstream source migration guidance for Makai Zig consumers.
