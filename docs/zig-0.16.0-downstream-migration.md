# Zig 0.16.0 Downstream Migration Guide

This guide is for downstream Zig consumers that import Makai modules or instantiate Makai public types directly. It summarizes the public-source changes made while upgrading Makai from Zig 0.15.2 to Zig 0.16.0.

Makai now requires Zig 0.16.0. Downstream packages should update their local toolchain, CI setup, and `build.zig.zon` metadata before updating to a Makai revision after this migration.

## Build and dependency changes

- Use Zig 0.16.0 for all Makai builds and tests. The repository CI and release binary workflows both use `mlugg/setup-zig@v2` with `version: 0.16.0`.
- Run Zig commands from the `zig/` directory:
  - `zig build test` runs the full unit suite.
  - `zig build run` runs the demo application.
  - `zig build test-unit-<group>` runs grouped unit steps used by CI.
- `zig/build.zig.zon` no longer declares external Zig package dependencies. The previously declared `libxev` package was unused by Makai source and build wiring, so it was removed instead of repinned for Zig 0.16.0.

## Public API compatibility overview

The migration intentionally keeps Makai's domain model and protocol-facing abstractions stable where practical:

- Provider streaming entry points continue to use `stream(...)`, `streamSimple(...)`, `complete(...)`, and `completeSimple(...)` with Makai `Model`, `Context`, and stream option types.
- `ApiRegistry` registration and lookup patterns remain provider-name based.
- Core event and result types (`AssistantMessageEvent`, `AssistantMessage`, `ContentBlock`, `Usage`, `Model`, `StreamOptions`, `CancelToken`) keep their Makai-owned shapes rather than exposing raw Zig I/O handles.
- Transport interfaces (`Sender`, `Receiver`, `AsyncSender`, `AsyncReceiver`, `ByteStream`) remain the public protocol boundary. Some compatibility fields and methods remain intentionally for older callers; prefer the newer lifecycle-explicit APIs described below.

Most required source changes are in code that directly touched Makai compatibility wrappers or Zig standard-library handles.

## I/O wrapper and constructor changes

Zig 0.16 moves several blocking and nondeterministic operations behind `std.Io`. Makai keeps deliberate wrapper modules under `zig/src/compat/` so downstream callers do not need to thread raw `std.Io` contexts through Makai public APIs. These wrappers are no longer temporary Zig-version shims; they are the supported Makai boundary for I/O-adjacent functionality.

### Time and sleep

Use `compat.time` helpers instead of direct `std.time` calls in Makai-integrated code that should follow Makai's selected I/O context:

- `compat.time.nowMillis() -> i64`
- `compat.time.nowSeconds() -> i64`
- `compat.time.nowNanos() -> i64`
- `compat.time.monotonicNanos() -> !u64`
- `compat.time.sleepNs(ns: u64) -> void`
- `compat.time.sleepMs(ms: u64) -> void`

`monotonicNanos()` is fallible because it routes through the active Zig 0.16 I/O clock.

### Random and secure random

Security-sensitive code should use the secure helpers and ordinary non-security identifiers should use the ordinary helpers:

- `compat.random.fillSecureBytes(buf)`
- `compat.random.secureBytes(allocator, len)`
- `compat.random.secureIntRangeLessThan(T, upper_bound)`
- `compat.random.fillRandomBytes(buf)`
- `compat.random.randomBytes(allocator, len)`
- `compat.random.randomIntRangeLessThan(T, upper_bound)`
- `compat.random.int(T)`

OAuth state, PKCE, credentials, WebSocket keys, and protocol IDs should stay on the secure helpers.

### Filesystem and stdio

Makai filesystem helpers now wrap Zig 0.16 `std.Io` file and directory operations while keeping Makai-owned function names:

- `compat.fs.getCwd()`
- `compat.fs.openFile(dir, path, flags)`
- `compat.fs.readFileAlloc(allocator, dir, path, max_bytes)`
- `compat.fs.writeFile(dir, path, data)`
- `compat.fs.atomicReplace(dir, target_path, tmp_path, data)`
- `compat.fs.createDir(dir, path)`

`compat.fs.writeFile` and `compat.fs.atomicReplace` create files with restrictive `0o600` permissions where the platform exposes permissions. Consumers that previously relied on broader default modes should set or adjust permissions explicitly after writing.

For terminal and pipe operations, prefer:

- `compat.stdio.stdin()` / `stdout()` / `stderr()`
- `compat.stdio.writeAll(file, data)` / `writeLine(file, data)`
- `compat.stdio.read(file, buffer)`
- `compat.stdio.close(file)`
- `compat.stdio.pipe()`

`compat.stdio.File` is currently an alias of the Zig file handle used by the implementation, but callers should treat it as a Makai boundary and route operations through `compat.stdio` so future backend evolution does not require broad source changes.

### Networking

Use `compat.net` for TCP and address operations:

- `compat.net.resolveAddress(allocator, host, port)`
- `compat.net.resolveAddressList(allocator, host, port)` returning an owned list that must be deinitialized
- `compat.net.tcpConnect(address)`
- `compat.net.tcpConnectHost(allocator, host, port)`
- `compat.net.tcpConnectAny(list)`
- `compat.net.tcpListen(address, options)`
- `compat.net.accept(server)`
- `compat.net.listenAddress(server)`
- `compat.net.closeServer(server)`

`compat.net.Stream` wraps the Zig 0.16 stream and provides `read`, `write`, `writeAll`, and `close`. Do not depend on its internal field layout.

### HTTP

Use `compat.http.HttpClient` and response helpers instead of constructing Makai HTTP clients around older Zig standard-library request APIs:

- `compat.http.HttpClient.init(allocator)` constructs a Zig 0.16-backed HTTP client.
- `client.openRequest(method, uri, options)` opens a request using `compat.http.RequestOptions`.
- `compat.http.sendRequest(request, body)` sends a request with a body.
- `compat.http.sendBodilessRequest(request)` sends a request without a body.
- `compat.http.receiveResponse(request, redirect_buffer)` receives response metadata.
- `compat.http.responseReader(response, transfer_buf)` returns a Makai response reader.
- `compat.http.readResponse`, `readAllResponse`, and `allocRemainingResponse` read response bodies.

`RequestOptions.accept_encoding` is optional; pass `"identity"` when a caller needs to disable compressed response bodies.

## Transport lifecycle guidance

`AsyncReceiver.receiveStream(...)` remains available for compatibility, and `AsyncReceiver.read(...)` remains optional for callers that still need a synchronous read fallback. For new async transport code, prefer APIs that return an explicit lifecycle handle, such as stdio transport `receiveStreamWithHandle(...)`, so producer threads can be joined and cancellation ownership remains clear.

Code that used `receiveStream(...)` should be audited for detached producer lifetimes. The compatibility path is intentionally retained because it is part of the public transport abstraction, not because Makai still supports Zig 0.15.2.

## Agent and protocol notes

- `AgentOptions.protocol` remains required. Agent logic stays auth-agnostic; provider authentication remains owned by the provider/protocol boundary.
- `Agent` internals now use Zig 0.16 synchronization primitives through Makai defaults. Callers should continue using `Agent.init`, `run`, `runAsync`, `cancel`, and `wait` instead of depending on internal fields.
- `ProtocolClient` continues to support multiplexed streams with legacy single-stream mirrors (`current_stream_id`, `last_result`, `stream_complete`, and `sequence`) for older callers. New code should prefer per-stream request references and stream-specific result/error accessors where available.

## Source migration checklist

1. Update downstream CI and local development to Zig 0.16.0.
2. Remove any downstream direct dependency on Makai's old `libxev` package declaration; Makai does not expose or require it.
3. Replace direct Zig 0.15 standard-library I/O assumptions in Makai-integrated code with `compat.time`, `compat.random`, `compat.fs`, `compat.stdio`, `compat.net`, and `compat.http` helpers.
4. Treat `compat.*` wrappers as stable Makai boundaries even when a wrapper currently aliases a Zig standard-library type.
5. Prefer lifecycle-explicit async transport APIs over detached compatibility helpers in new code.
6. Run `zig build test` from `zig/` and, when changing Makai source, run `./scripts/check-zig-patterns.sh` from the repository root.
