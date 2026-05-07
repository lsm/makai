# Zig 0.15.2 → 0.16.0 Upgrade Impact Assessment

Date: 2026-05-07  
Scope: Makai `zig/` codebase (`zig/src/**`, `zig/test/**`, `zig/build.zig`, `zig/build.zig.zon`)  
Target release: Zig 0.16.0, released 2026-04-14, “Juicy Main”

## Summary verdict

Upgrading Makai from Zig 0.15.2 to Zig 0.16.0 is feasible, but it is **not a small version bump**. Zig 0.16.0 moves blocking and nondeterministic standard-library APIs behind the new `std.Io` interface and also changes container, filesystem, networking, process, time, entropy, formatting, and synchronization APIs. Makai uses many of those areas directly.

Recommended classification: **medium-to-large migration**, roughly **1-2 focused engineering weeks** for compile/test parity, plus additional time if the project chooses to redesign around `std.Io` instead of making compatibility shims.

Highest-impact findings:

1. **I/O interface migration is the main risk.** Makai uses `std.http.Client`, `std.fs.File`, `std.io.getStdIn/getStdOut`, `std.net`, file `reader`/`writer` APIs, and many blocking sleeps/threads. These are directly affected by Zig 0.16.0's `std.Io` migration.
2. **Thread synchronization APIs used by Makai moved.** Release notes say `std.Thread.Futex`, `std.Thread.Mutex`, `std.Thread.Condition`, `std.Thread.ResetEvent`, and related primitives are replaced by `std.Io.*` equivalents. Makai's `EventStream` and OAuth refresh/auth protocol code rely on these.
3. **HTTP provider implementations need nontrivial updates.** All provider HTTP clients instantiate `std.http.Client{ .allocator = ... }`; release notes show `std.http.Client` now takes an `io` field and uses a new request flow.
4. **`std.mem.indexOf*` rename is a high-volume breaking change.** The Zig 0.16.0 release notes list “mem: introduce cut functions; rename 'index of' to 'find'”; Makai has 263 `std.mem.indexOf` calls across 37 files plus related `indexOfScalar`, `indexOfAny`, and `indexOfPos` calls.
5. **`std.ArrayList` migration risk needs compile verification.** Makai has 240 `std.ArrayList` mentions in `zig/src/**` and hundreds of calls to `append`, `appendSlice`, `toOwnedSlice`, `clearRetainingCapacity`, etc. The 0.16.0 notes discuss unmanaged-container migration for priority queues, while ArrayList deprecation started in 0.15.x; whether Makai's exact aliases are removed in 0.16.0 must be verified by compiling.
6. **Dependency status is mixed, not solved.** The currently pinned libxev commit in `zig/build.zig.zon` targets `0.15.2`. Current libxev appears to compile with Zig 0.16, but it explicitly does **not** implement `std.Io`; issue #219 tracks `std.Io` support and is open.
7. **No evidence of some feared blockers.** Makai does not use `@cImport`, direct `@Type(...)` reification, `std.heap.ThreadSafeAllocator`, `SegmentedList`, `FixedBufferStream`, `std.os`, `@Vector`, packed structs/unions, or extern structs/unions in `zig/**/*.zig`.

## Sources used

- Zig 0.16.0 release notes: <https://ziglang.org/download/0.16.0/release-notes.html>
- libxev issue #218: <https://github.com/mitchellh/libxev/issues/218>
- libxev repository README: <https://github.com/mitchellh/libxev>
- libxev issue #219: <https://github.com/mitchellh/libxev/issues/219>
- Local code scan in this worktree.

## Codebase scan methodology

I scanned `zig/**/*.zig`, `zig/build.zig`, and `zig/build.zig.zon` for APIs and patterns called out by the Zig 0.16.0 release notes. Counts below include tests unless otherwise stated.

Notable pattern counts:

| Pattern | Count / files | Notes |
|---|---:|---|
| `std.http.Client{` | 19 occurrences | Provider/OAuth HTTP stack likely needs new `io` construction and request flow. |
| `std.fs` | 106 occurrences | Mostly CLI/test file handling and OAuth storage. |
| `std.net` | 9 occurrences | WebSocket transport and OAuth callback server. |
| `std.process` | 43 occurrences | Mostly args/env/exit; less risky than child-process APIs. |
| `std.io` | 12 occurrences | stdin/stdout and `std.io.Limit`; likely renamed/moved. |
| `std.Thread.Futex` | 8 occurrences | Breaking: release notes move sync primitives to `std.Io`. |
| `std.Thread.Mutex` | 5 occurrences | Breaking/migration item. |
| `std.Thread.Condition` | 2 occurrences | Breaking/migration item. |
| `std.Thread.ResetEvent` | 2 occurrences | Breaking/migration item. |
| `std.Thread.spawn` | 33 occurrences | Needs validation; release notes specifically call out sync primitive moves, not necessarily thread spawn removal. |
| `std.Thread.sleep` | 48 occurrences | Release notes promote `Io.Clock`/timeouts; direct sleep may need API updates. |
| `std.time.milliTimestamp` | 279 occurrences / 39 files | Not explicitly listed in release notes; needs compile-time verification. |
| `std.time.timestamp` | 25 occurrences | Release notes list `std.time.timestamp` → `std.Io.Timestamp.now`. |
| `std.time.nanoTimestamp` | 5 occurrences | Not explicitly listed in release notes; verify with 0.16.0 stdlib. |
| `std.crypto.random` | 11 occurrences | Release notes say entropy should come from `io.random` / `Io.randomSecure`. |
| `std.mem.indexOf` | 263 occurrences / 37 files | Release notes list “index of” → `find` rename. |
| `std.mem.indexOfScalar` and variants | 32 occurrences | Related rename family; verify exact 0.16.0 function names. |
| `std.ArrayList` | 240 occurrences / 48 files in `zig/src/**` | Container migration risk; ArrayList-specific removal needs compile verification. |
| `std.json` | 144 occurrences | Needs validation against 0.16.0 JSON API. |
| `std.fmt.format` | 5 occurrences | Release notes say `fmt.format` → `std.Io.Writer.print`. |
| `std.posix` | 27 occurrences | Mostly pipe/env helpers in tests/transports; verify against 0.16.0. |

Negative scan results:

- `@cImport`: 0
- direct `@Type(`: 0
- `@hasField`: 0
- `std.os`: 0
- `FixedBufferStream`: 0
- `SegmentedList`: 0
- `std.heap.ThreadSafeAllocator`: 0
- `packed struct` / `packed union`: no production hits in scan output
- `extern struct` / `extern union`: no production hits in scan output

## Breaking changes and Makai impact

### 1. New `std.Io` interface

Severity: **breaking**  
Release note basis: Zig 0.16.0 introduces I/O as an interface. Blocking or nondeterministic I/O now requires a `std.Io` instance. Implementations include `Io.Threaded`, `Io.Evented`, `Io.Uring`, `Io.Kqueue`, `Io.Dispatch`, and `Io.failing`. Tests should use `std.testing.io`.

Affected Makai areas:

- Provider HTTP clients:
  - `zig/src/providers/openai_completions_api.zig:1071`
  - `zig/src/providers/openai_responses_api.zig:646`
  - `zig/src/providers/anthropic_messages_api.zig:1081`
  - `zig/src/providers/google_generative_api.zig:757`
  - `zig/src/providers/google_vertex_api.zig:712`
  - `zig/src/providers/azure_openai_responses_api.zig:236`
  - `zig/src/providers/ollama_api.zig:579`
- OAuth HTTP clients:
  - `zig/src/oauth/github_copilot.zig:99`, `:184`, `:286`, `:414`
  - `zig/src/utils/oauth/github_copilot.zig:107`, `:375`, `:451`, `:529`
  - `zig/src/utils/oauth/anthropic.zig` response-reading call sites
- File and stdio APIs:
  - `zig/src/transports/stdio.zig:8`, `:37`, `:145`, `:172`
  - `zig/src/tools/makai.zig` uses `std.fs.File` extensively for CLI I/O.
- Networking:
  - `zig/src/transports/websocket.zig:16`, `:93`, `:98`
  - `zig/src/utils/oauth/callback_server.zig:7`, `:14`, `:95`

Expected work:

- Decide on the project's I/O root: likely initialize a default `std.Io` in CLI/tools and tests, then thread it into provider/OAuth/transport constructors.
- Add a compatibility layer around time, sleep, entropy, file, HTTP, and stdio to avoid rewriting every call site independently.
- Update tests to use `std.testing.io` or a project-level test I/O fixture where practical.

Risk level: **high**, because this touches provider streaming, OAuth, transports, and CLI entry points.

### 2. `std.http.Client` API changes

Severity: **breaking**  
Release note basis: The 0.16.0 notes show `std.http.Client` constructed with both `.allocator` and `.io`, and a new request flow using operations such as `request`, `sendBodiless`, and `receiveHead`.

Makai patterns:

```zig
var client = std.http.Client{ .allocator = allocator };
```

Representative files:

- `zig/src/providers/openai_completions_api.zig:1071`
- `zig/src/providers/openai_responses_api.zig:646`
- `zig/src/providers/anthropic_messages_api.zig:1081`
- `zig/src/providers/google_generative_api.zig:757`
- `zig/src/providers/google_vertex_api.zig:712`
- `zig/src/providers/ollama_api.zig:579`
- `zig/src/oauth/github_copilot.zig:99`
- `zig/src/utils/oauth/github_copilot.zig:107`

Additional reader patterns:

- `response.reader(&transfer_buf)` appears across all streaming providers.
- `allocRemaining(..., std.io.Limit.limited(8192))` appears in provider/OAuth error-body handling.

Expected work:

- Update all provider streaming implementations to the 0.16 HTTP request/response API.
- Re-check SSE streaming reader behavior under `std.Io.Reader` because provider implementations are built around incremental reads.
- Keep current custom SSE parser, but adapt its input reader loop.

Risk level: **high**. This is the critical path for all external provider functionality.

### 3. Filesystem API moved to `std.Io`

Severity: **breaking**  
Release note basis: `fs.Dir` and `fs.File` migrated to `std.Io.Dir` and `std.Io.File`. Notable renames include `fs.cwd` → `std.Io.Dir.cwd`, `fs.openFileAbsolute` → `std.Io.Dir.openFileAbsolute`, `fs.makeDirAbsolute` → `std.Io.Dir.createDirAbsolute`, and file read/write methods such as `read`/`write` becoming streaming/positional forms.

Makai patterns:

- `std.fs.cwd()` in `zig/src/utils/oauth/storage.zig:52`, `:123`, `:134`, `:198`
- `std.fs.openFileAbsolute` in `zig/test/e2e/test_helpers.zig:282`, `:366`, `:479`, `:599`
- `std.fs.File` in CLI harness and stdio abstractions, especially `zig/src/tools/makai.zig`
- `file.readToEndAlloc(...)` in `zig/src/utils/oauth/storage.zig:62` and test helper files
- `file.writeAll(...)` appears 107 times, mostly CLI/protocol/test utilities.

Expected work:

- Introduce file helper functions that accept `std.Io`/`std.Io.Dir` and hide old/new method names.
- Migrate OAuth credential storage first (`zig/src/utils/oauth/storage.zig`) because it contains real user data file operations and atomic rename behavior.
- Update CLI/test harness file wrappers after production storage compiles.

Risk level: **medium-high**. Mostly mechanical but widespread and easy to get wrong around ownership and atomic writes.

### 4. Networking API moved to `std.Io`

Severity: **breaking**  
Release note basis: all `std.net` APIs moved to `Io`; Windows networking was rewritten; `Io.Evented` still lacks networking implementation; `Io.net` still lacks non-IP networking.

Affected files:

- `zig/src/transports/websocket.zig:16`: `tcp_stream: ?std.net.Stream`
- `zig/src/transports/websocket.zig:93`: `std.net.Address.resolveIp`
- `zig/src/transports/websocket.zig:98`: `std.net.tcpConnectToAddress`
- `zig/src/utils/oauth/callback_server.zig:7`: `std.net.Server`
- `zig/src/utils/oauth/callback_server.zig:14`: `std.net.Address.parseIp4`
- `zig/src/utils/oauth/callback_server.zig:95`: `std.net.Stream`

Expected work:

- Port WebSocket transport connection setup to `std.Io.net` equivalents.
- Port OAuth callback listener/server to the new listener and stream APIs.
- Decide which `Io` implementation to use for network support. The release note caveat that `Io.Evented` lacks networking matters if Makai expects evented networking soon.

Risk level: **medium-high** for WebSocket/callback server, lower for current in-process/stdout protocol tests.

### 5. Synchronization primitives moved from `std.Thread.*` to `std.Io.*`

Severity: **breaking**  
Release note basis: release notes list replacements: `ResetEvent` → `Io.Event`, `WaitGroup` → `Io.Group`, `Futex` → `Io.Futex`, `Mutex` → `Io.Mutex`, `Condition` → `Io.Condition`, `Semaphore` → `Io.Semaphore`, `RwLock` → `Io.RwLock`, and `std.once` removed.

Affected files:

- `zig/src/event_stream.zig`
  - `std.Thread.Mutex`: line 19
  - `std.Thread.Futex.wake`: lines 138, 152, 166, 172
  - `std.Thread.Futex.timedWait`: line 191
  - `std.Thread.Futex.wait`: line 285
- `zig/src/stream.zig`
  - `std.Thread.Futex.wait`: lines 42, 63
- `zig/src/agent/agent.zig`
  - `std.Thread.ResetEvent`: lines 88, 122
  - `std.Thread.Mutex`: line 89
- `zig/src/protocol/auth/server.zig`
  - `std.Thread.Mutex`: lines 19, 49
  - `std.Thread.Condition`: line 20
- `zig/src/utils/oauth/refresh_lock.zig`
  - `std.Thread.Condition`: line 22
  - `std.Thread.Mutex`: line 44

Expected work:

- Start with `EventStream`; it is central and has lock-free/futex semantics. Verify 0.16 `Io.Futex` has matching memory-ordering and wait timeout semantics.
- Port `RefreshCoordinator`/auth protocol locks and conditions.
- Add stress tests around `EventStream.wait`, `pollBatch`, completion/error behavior, and OAuth refresh locking after migration.

Risk level: **high** because these are concurrency primitives and can fail subtly.

### 6. Threads, sleeps, timers, and timestamps

Severity: **breaking/deprecated/migration** depending on API  
Release note basis: time APIs move conceptually to `std.Io.Timestamp`; `std.time.Instant`/`Timer` replacements are listed. `Io.Clock`, `Duration`, `Timestamp`, `Timeout` are introduced.

Makai patterns:

- `std.Thread.spawn`: 33 occurrences
- `std.Thread.sleep`: 48 occurrences
- `std.time.milliTimestamp`: 279 occurrences
- `std.time.timestamp`: 25 occurrences
- `std.time.nanoTimestamp`: 5 occurrences

Representative files:

- `zig/src/event_stream.zig:176`, `:182`, `:488`, `:498`
- `zig/src/utils/retry.zig:24`, `:394`, `:596`, `:598`, `:617`
- `zig/src/tools/makai.zig` multiple polling loops and test harness threads
- Provider stream thread launchers in all provider files

Expected work:

- Add project-level wrappers such as `timeNowMillis(io)`, `timeNowSeconds(io)`, `sleepNs(io, ns)`, and `monotonicNowNs(io)`.
- Replace busy polling sleeps in CLI/protocol harnesses with `Io`-aware sleep/timeouts where possible.
- Validate whether `std.Thread.spawn` itself remains usable unchanged in 0.16.0. Release notes emphasize moved synchronization primitives more than thread creation, so this may be lower-risk than mutex/futex/time.

Risk level: **medium**, but high-volume. Treat `std.time.timestamp` as confirmed by release notes; treat `milliTimestamp` and `nanoTimestamp` as high-volume **unconfirmed** compatibility checks until Zig 0.16.0 compilation or stdlib source inspection proves removal/renaming.

### 7. `std.mem.indexOf*` renamed to `std.mem.find*`

Severity: **breaking**  
Release note basis: the Zig 0.16.0 release notes include “mem: introduce cut functions; rename 'index of' to 'find'”.

Makai patterns:

- `std.mem.indexOf`: 263 occurrences across 37 files
- `std.mem.indexOfScalar`: 23 occurrences
- `std.mem.indexOfAny`: 3 occurrences
- `std.mem.indexOfPos`: 6 occurrences

Representative files:

- `zig/src/tool_call_tracker.zig:372`
- `zig/src/transport.zig:1389`, `:1390`, `:1480`, `:1481`, `:1482`
- `zig/src/tools/makai.zig:817`, `:818`, `:1434`, `:1435`, `:1436`, `:1490`, `:1495`, `:1498-1501`, `:1522`
- `zig/src/tools/auth_cli.zig:560`, `:679`, `:734`
- `zig/src/providers/sse_parser.zig:102`
- `zig/src/transports/websocket.zig:648`, `:653`, `:657`
- `zig/src/protocol/model_ref.zig:48`, `:51`, `:57`, `:60`, `:63`, `:66`
- `zig/src/utils/oauth/anthropic.zig:124`, `:157`
- `zig/src/utils/oauth/google.zig:134`

Expected work:

- Replace `std.mem.indexOf` with the corresponding `std.mem.find` API.
- Verify the exact replacements for scalar/pos/any variants against Zig 0.16.0 (`findScalar`, positional start arguments, and any/none equivalents may not be 1:1 by name).
- Do this before deeper I/O migration because it is high-volume but mostly mechanical and will otherwise obscure more complex compile errors.

Risk level: **medium-high** due to volume, but low conceptual complexity.

### 8. Entropy/randomness moved behind `std.Io`

Severity: **breaking/migration**  
Release note basis: `std.crypto.random.bytes` and `posix.getrandom` are replaced by `io.random`; `Io.randomSecure` is available for fresh external entropy. The release notes show the explicit `std.Random.IoSource` migration pattern:

```zig
const rng_impl: std.Random.IoSource = .{ .io = io };
const rng = rng_impl.interface();
```

Use that two-step pattern when code needs a `std.Random` interface rather than direct `io.random`/`io.randomSecure` calls.

Affected files:

- `zig/src/oauth/pkce.zig:14`
- `zig/src/oauth/openai_codex.zig:63`
- `zig/src/oauth/google_gemini_cli.zig:70`
- `zig/src/oauth/google_antigravity.zig:73`
- `zig/src/utils/oauth/pkce.zig:19`
- `zig/src/transports/websocket.zig:450`, `:546`
- `zig/src/utils/tool_utils.zig:97`
- `zig/src/protocol/provider/types.zig:32`, `:100`
- `zig/src/utils/oauth/storage.zig:130`

Expected work:

- Use `io.randomSecure` for PKCE verifiers, OAuth state, WebSocket nonce/masks where security-sensitive.
- Use `io.random` or deterministic test source only for non-security session IDs if acceptable.
- Thread `io` into protocol ID generation or add a central ID generator API.

Risk level: **medium**, with security review required for OAuth and protocol IDs.

### 9. Container migration: managed → unmanaged `std.ArrayList`

Severity: **unconfirmed breaking/migration risk**  
Release note basis: Zig 0.16.0 release notes mention migration to unmanaged containers, but the visible release-note item specifically covers `PriorityQueue`/`PriorityDequeue`, not `ArrayList`. The `ArrayList` managed/unmanaged transition started in the 0.15.x timeframe. Therefore this should be treated as a compile-time verification item: Makai's exact `std.ArrayList(T){}` usage may still compile through compatibility aliases, or those aliases may be removed/changed in 0.16.0.

Makai patterns:

- `std.ArrayList`: 240 occurrences across 48 files in `zig/src/**`
- `append`: 310 calls across 35 files
- `appendSlice`: 154 calls across 25 files
- `toOwnedSlice`: 36 calls across 19 files
- `initCapacity`: 23 calls across 13 files
- `clearRetainingCapacity`: 69 calls across 16 files

Representative high-volume files:

- `zig/src/providers/openai_completions_api.zig`
- `zig/src/providers/google_vertex_api.zig`
- `zig/src/providers/google_generative_api.zig`
- `zig/src/providers/ollama_api.zig`
- `zig/src/providers/anthropic_messages_api.zig`
- `zig/src/tools/auth_cli.zig`
- `zig/src/agent/agent.zig`
- `zig/src/protocol/provider/envelope.zig`

Expected work:

- Compile with Zig 0.16.0 to identify exact changed method signatures.
- Convert remaining managed-style initialization patterns if necessary.
- Avoid mixing owned slices and ArrayList-backed buffers during migration; Makai's `OwnedSlice(T)` patterns depend on clear ownership semantics.

Risk level: **medium-high** due to volume, but likely mechanical.

### 10. Formatting and writer APIs

Severity: **breaking/deprecated**  
Release note basis: `fmt.format` → `std.Io.Writer.print`; `Formatter` → `Alt`; `FormatOptions` → `Options`; `bufPrintZ` → `bufPrintSentinel`; `Io.GenericWriter`, `Io.AnyWriter`, `Io.null_writer`, `Io.CountingReader`, `Io.GenericReader`, and `FixedBufferStream` removed.

Makai patterns:

- `std.fmt.format` in:
  - `zig/src/json/writer.zig:64`, `:71`, `:128`, `:134`
  - `zig/src/protocol/provider/envelope.zig:559`
- `buffer.writer(allocator)` custom JSON writer patterns:
  - `zig/src/json/writer.zig`
  - `zig/src/utils/streaming_json.zig:118`
  - `zig/src/protocol/provider/envelope.zig:558`

Expected work:

- Port custom `json/writer.zig` to `std.Io.Writer.print` or the new buffer writer API.
- Validate that `std.ArrayList(u8).writer(allocator)` still returns the expected writer type.

Risk level: **medium**. The custom JSON writer is small but central.

### 11. `std.json` parsing/stringification

Severity: **unknown/minor-to-medium**  
Release note basis: I did not find a direct 0.16.0 release-note entry that says `std.json.parseFromSlice` or `std.json.Stringify.valueAlloc` was renamed/removed. However, JSON-adjacent code is still exposed to two confirmed 0.16.0 changes: `fmt.format` → `std.Io.Writer.print`, and broader `Io.Reader`/`Io.Writer` migration seen in other stdlib serialization/compression APIs. Treat JSON parse APIs as unknown until compile-tested, and treat custom JSON serialization as higher risk because it depends on writer APIs.

Makai patterns:

- `std.json`: 144 occurrences
- `std.json.parseFromSlice` and `parseFromSliceLeaky` throughout providers, protocol envelopes, OAuth, transports, CLI tests
- `std.json.Stringify.valueAlloc` in:
  - `zig/src/tools/makai.zig:282`
  - `zig/src/tools/auth_cli.zig:507`, `:519`, `:521`

Expected work:

- Compile against 0.16.0 and fix parse/stringify API drift.
- Prioritize envelope/protocol parse tests because they cover core serialization.
- Keep custom `json/writer.zig` for provider request generation if easier than migrating all request construction to stdlib JSON writer.

Risk level: **medium** until exact 0.16 JSON API errors are known.

### 12. `heap.ArenaAllocator` thread-safety change

Severity: **minor behavioral/performance change**  
Release note basis: Zig 0.16.0 says `heap.ArenaAllocator` becomes thread-safe and lock-free.

Makai patterns:

- `zig/src/streaming_json.zig:45`: `arena: std.heap.ArenaAllocator`
- `zig/src/streaming_json.zig:59`: `std.heap.ArenaAllocator.init(allocator)`

Expected work:

- No source change is expected solely from this release-note item.
- Re-run streaming JSON tests and watch for changed performance or any tests that assumed arena allocation was not thread-safe.

Risk level: **low**.

### 13. Process APIs

Severity: **minor-to-medium**  
Release note basis: `std.process.Child.*` moved to `std.process.spawn` / `std.process.run`; `std.process.execv` → `std.process.replace`; `main` can receive `std.process.Init`.

Makai usage:

- `std.process.argsAlloc` / `argsFree` in `zig/src/tools/makai.zig:1534-1535`
- `std.process.exit` in login tools
- `std.process.getEnvVarOwned` in providers, tests, and OAuth helpers
- No scan hits for `std.process.Child` or `execv`.

Expected work:

- Likely low-risk unless `argsAlloc`, `getEnvVarOwned`, or `exit` signatures changed under `std.process.Init`.
- Consider using `std.process.Init` for CLI `main` to obtain default `io`, allocator, arena, and env in one place.

Risk level: **low-to-medium**.

### 14. Build system and package manager

Severity: **minor-to-medium**  
Release note basis: `@cImport` deprecated in favor of `b.addTranslateC`; local package overrides supported; packages fetched into a project-local directory; unit test timeouts and diagnostic flags added.

Makai impact:

- `zig/build.zig` already uses modern patterns such as `b.createModule`, `.root_module =`, `b.addTest`, `b.addExecutable`, and `b.addRunArtifact`.
- No `@cImport` usage was found.
- `zig/build.zig.zon` currently says:

```zig
.version = "0.15.2",
.dependencies = .{
    .libxev = .{
        .url = "git+https://github.com/mitchellh/libxev#42d4ead52667e03619dcd5b1a3ca8ef7d5dd24ed",
        .hash = "libxev-0.0.0-86vtc0IbEwBzMSXa-ZPZ8JpcV4Mw1SrsTuvtJmFAQ7Uu",
    },
},
```

Expected work:

- Update `.version` to `0.16.0`.
- Update libxev URL/hash to a 0.16-compatible commit or release.
- Run `zig fetch`/`zig build` with 0.16.0 to refresh dependency hash.
- Consider adding unit test timeouts once build compiles.

Risk level: **medium**, mainly because package hash and libxev pin must be coordinated.

### 15. `@import`, module system, and `@cImport`

Severity: **minor** for Makai  
Release note basis: `@cImport` is deprecated and moved to build-system `addTranslateC`.

Makai impact:

- No `@cImport` hits.
- `@import` module usage is explicit via `b.createModule` and `addImport`; no obvious release-note blocker found.

Risk level: **low**.

### 16. `@Type`, error sets/unions, and comptime introspection

Severity: **low-to-medium**  
Release note basis: direct `@Type` reification is removed and replaced with `@EnumLiteral`, `@Int`, `@Tuple`, `@Pointer`, `@Fn`, `@Struct`, `@Union`, `@Enum`; error sets can no longer be reified; various comptime/type rules changed.

Makai impact:

- No direct `@Type(...)` calls found.
- `@TypeOf` is widely used; this is not the removed builtin.
- `@hasDecl` appears in:
  - `zig/src/event_stream.zig:63`, `:85`
  - `zig/src/owned_slice.zig:55`
- `@typeInfo` appears in:
  - `zig/src/event_stream.zig:82`
  - `zig/src/owned_slice.zig:52`
  - `zig/src/utils/oom.zig:11`, `:13`
- `zig/src/utils/oom.zig:11` uses `@typeInfo(@TypeOf(value)).error_union.payload`; line 13 stores `const info = @typeInfo(T);`. These may need enum-field spelling updates if `@typeInfo` tags changed in 0.16.0.

Expected work:

- Compile-check `@typeInfo` tag names/fields. The scan does not indicate a major `@Type` migration.
- No error-set reification patterns found.

Risk level: **low-to-medium**.

### 17. Packed types, vectors, C interop, ABI

Severity: **low** for Makai  
Release note basis: 0.16.0 changes packed union/struct behavior, forbids pointers in packed types, changes extern validity for inferred backing/tag types, forbids runtime vector indexes, and changes alignment/type coercion behavior.

Makai impact:

- No relevant packed struct/union, extern struct/union, or vector patterns found in the scan.
- No C interop usage found.

Risk level: **low**.

## Dependency compatibility

### libxev

Current Makai pin:

- `zig/build.zig.zon:5` pins `git+https://github.com/mitchellh/libxev#42d4ead52667e03619dcd5b1a3ca8ef7d5dd24ed`
- `zig/build.zig.zon:2` declares `.version = "0.15.2"`

Research findings:

- libxev issue #218 requested Zig 0.16.0 support on 2026-04-14 after the Zig release. The issue is closed, with no detailed public discussion visible in the issue page extraction.
- Current libxev README indicates libxev is Zig 0.16-aware/buildable, but it explicitly says libxev **does not implement** the `std.Io` interface and does not accept `std.Io` for operations; it calls I/O directly.
- libxev issue #219, “Implement std.Io interface,” is open. That means upstream `std.Io` integration is not available today.

Impact:

- The currently pinned commit/hash probably should be replaced with a current 0.16-compatible libxev commit or release.
- Makai should **not** plan on using libxev directly as a `std.Io` backend during the initial Zig 0.16 upgrade unless the project implements/maintains that adapter itself or waits for upstream issue #219.
- If Makai wants full `std.Io` integration, libxev is a dependency risk rather than a ready-made solution.

Risk level: **medium-high**. Compiling libxev with Zig 0.16 appears feasible, but `std.Io` integration remains an open upstream feature request.

### Other dependencies

No other dependencies are declared in `zig/build.zig.zon`.

## Estimated effort

### Small / mechanical work items

- Update `zig/build.zig.zon` version and dependency hash.
- Compile against Zig 0.16.0 and collect first-pass errors.
- Fix process/env/args call sites if signatures changed.
- Replace `std.mem.indexOf*` calls with the new `std.mem.find*` family.
- Replace `std.fmt.format` call sites.
- Validate `@typeInfo` and `@hasDecl` call sites.

Estimated effort: **0.5-1 day**.

### Medium work items

- Verify and update `std.ArrayList` usage across providers/protocol/CLI if 0.16.0 removes or changes the compatibility aliases.
- Migrate custom JSON writer and JSON stringify/parse drift.
- Add project wrappers for time, sleep, random, and file helpers.
- Port OAuth storage filesystem operations.
- Port `std.io.getStdIn/getStdOut` and stdio transport wrappers.

Estimated effort: **2-4 days**.

### Large / high-risk work items

- Port provider and OAuth `std.http.Client` usage to the new `std.Io` request/response flow.
- Port `EventStream` futex/wait implementation to `std.Io.Futex` or an equivalent concurrency primitive.
- Port WebSocket transport and OAuth callback server networking to `std.Io.net`.
- Re-run and stabilize unit tests and mock E2E protocol tests.

Estimated effort: **4-7 days**.

### Total estimate

- Compile/test parity with current architecture: **1-2 engineering weeks**.
- A deeper redesign that fully embraces `std.Io` throughout public APIs and transports: **2-4 engineering weeks**, depending on how much async/networking behavior is modernized.

## Recommended migration approach

Use a **staged migration branch**, not a big-bang rewrite. Zig itself requires a big-bang compiler switch at the end, but the code changes should be staged behind wrappers to reduce risk.

Recommended sequence:

1. **Preparation PRs on Zig 0.15.2 if possible**
   - Introduce project-local wrappers for time, sleep, random, file reads/writes, and HTTP client construction.
   - Keep wrappers implemented with 0.15.2 APIs initially.
   - Add focused tests around `EventStream`, OAuth storage, WebSocket frame handling, provider SSE parsing, and protocol envelope JSON.

2. **Dependency and compiler switch branch**
   - Update `zig/build.zig.zon` to `0.16.0`.
   - Move libxev pin/hash to a 0.16-compatible upstream commit.
   - Run `zig build test-unit-core` first to isolate core and concurrency errors.

3. **Core/std migration**
   - Port `EventStream` futex/mutex code.
   - Port `std.mem.indexOf*`, `ArrayList`, and custom writer APIs.
   - Port time/random wrappers.

4. **I/O stack migration**
   - Port filesystem/stdio storage and CLI harness code.
   - Port `std.http.Client` provider/OAuth implementations.
   - Port `std.net` WebSocket and callback server.

5. **Validation**
   - Run grouped unit steps:
     - `zig build test-unit-core`
     - `zig build test-unit-transport`
     - `zig build test-unit-protocol`
     - `zig build test-unit-providers`
     - `zig build test-unit-utils`
     - `zig build test-unit-agent`
   - Run mock-based E2E protocol tests (`zig build test-e2e-protocol`).
   - Per standing instruction, skip external provider E2E unless separately requested/configured.

Recommendation: **avoid attempting to redesign all of Makai around evented I/O in the first upgrade PR**. First get functional parity using the simplest supported `std.Io` backend, then follow up with targeted I/O improvements. Do not assume libxev can serve as that backend until upstream issue #219 is resolved or Makai owns an adapter.

## Upgrade checklist

- [ ] Install/use Zig 0.16.0 in a migration branch.
- [ ] Update `zig/build.zig.zon` `.version` to `0.16.0`.
- [ ] Update libxev pin/hash to a 0.16-compatible commit or release.
- [ ] Choose default `std.Io` implementation for CLI/tests/providers.
- [ ] Add or port project wrappers for:
  - [ ] HTTP client/request/response
  - [ ] file and stdio I/O
  - [ ] network connect/listen/stream
  - [ ] random/secure random
  - [ ] time and sleep
- [ ] Port `EventStream` futex/mutex usage.
- [ ] Port auth protocol and refresh lock synchronization.
- [ ] Port provider HTTP streaming loops.
- [ ] Port OAuth HTTP flows and callback server.
- [ ] Port WebSocket transport.
- [ ] Replace `std.mem.indexOf*` with the 0.16.0 `std.mem.find*` family.
- [ ] Verify and fix `std.ArrayList` method/signature changes.
- [ ] Fix formatting/writer APIs in custom JSON writer.
- [ ] Validate `std.json` parse/stringify APIs.
- [ ] Run all grouped unit tests and mock E2E protocol tests.

## Open questions for implementation phase

1. Which `std.Io` backend should Makai use by default in CLI and tests: `Io.Threaded`, `Io.Dispatch`, or another backend?
2. Should provider APIs accept an explicit `std.Io` parameter, or should the registry/context own a default I/O instance?
3. Should `CancelToken` and `EventStream` remain atomics/futex-based, or be redesigned around `std.Io.Queue`, `Io.Event`, or `Io.Group`?
4. Should Makai wait for libxev issue #219, implement its own libxev-to-`std.Io` adapter, or keep libxev independent of `std.Io` for the initial upgrade?
5. Do public Makai APIs need to stay source-compatible for downstream users, or can they change to pass `std.Io` explicitly?
6. Does `std.time.milliTimestamp` still exist in Zig 0.16.0, or should Makai introduce a `Timestamp.now`-based millisecond wrapper?
