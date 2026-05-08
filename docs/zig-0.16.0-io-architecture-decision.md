# Zig 0.16.0 I/O Architecture Decision

Date: 2026-05-08  
Status: Accepted for the Zig 0.15.2 -> 0.16.0 migration  
Scope: Makai `zig/` public APIs, compatibility wrappers, CLI/tools, tests, providers, OAuth, transports, and protocol/agent runtime paths

## Decision summary

Makai will migrate to Zig 0.16.0 using a Makai-owned default I/O context rather than exposing `std.Io` directly in public API signatures.

The default backend for the initial migration is Zig's standard blocking/thread-compatible I/O implementation: `std.Io.Threaded` when a concrete backend is needed directly, and `std.Io.Dispatch` only where platform dispatch is explicitly required by Zig's standard-library constructors. Makai will not use libxev as a `std.Io` backend in the initial migration.

The binding API rule for Phase 0 and later wrapper work is:

- Public Makai constructors, registry entry points, provider APIs, OAuth helpers, transport constructors, and agent/protocol entry points MUST NOT expose `std.Io` in their public signatures.
- Public entry points should accept a Makai-owned context/configuration object or use a Makai default I/O context provided by the caller's higher-level runtime.
- Internal helpers MAY accept explicit `std.Io` handles when the Zig 0.16 implementation requires them, but those helpers must remain below the public API boundary.
- Zig 0.15.2 source compatibility is not promised after Phase 1. Public signatures may change to context/default-I/O patterns if needed, but not to raw public `std.Io` parameters.

This decision is intended to unblock Phase 0 wrapper PRs from `docs/zig-0.16.0-migration-plan.md` by fixing backend choice, ownership, wrapper naming, and parameter-order conventions up front.

## Rationale

1. **Preserve Makai's provider-agnostic API shape.** Makai's public value is a unified provider, protocol, transport, and agent abstraction. Requiring every downstream caller to thread `std.Io` through public calls would leak Zig standard-library implementation details into that abstraction and create high-volume downstream churn.

2. **Keep the initial Zig 0.16 migration focused on parity.** The migration goal is compile/test parity and behavior preservation, not a broad evented-I/O redesign. A blocking/thread-compatible standard backend is the lowest-risk first step for current provider HTTP streaming, OAuth flows, stdio, and loopback networking behavior.

3. **Avoid depending on libxev for `std.Io`.** The current codebase does not actively import or build against libxev, and libxev is not a ready `std.Io` implementation for this migration. Phase 1 should remove the unused libxev dependency rather than make it part of the initial I/O architecture.

4. **Make ownership explicit.** The component that creates a Makai runtime/context owns the default I/O backend lifetime. Borrowed I/O views can flow into internal helpers for a single operation, but no long-lived public object should implicitly outlive the I/O context that created it.

5. **Allow future backend evolution.** Hiding `std.Io` behind Makai contexts and wrappers lets Makai later evaluate `Io.Dispatch`, platform-specific backends, or a future libxev adapter without another public API break.

## Backend selection and networking support

### Selected initial backend

Use Zig 0.16 standard-library blocking/thread-compatible I/O as the default:

- Concrete default: `std.Io.Threaded` for owned runtime/test contexts when constructing an I/O backend explicitly.
- Dispatch use: `std.Io.Dispatch` may be used internally if Zig standard-library APIs require dispatch-mediated construction on a supported platform, but it is not the public architecture boundary.
- Test default: `std.testing.io` or a Makai `TestIoContext` wrapper around it for tests that need deterministic/failing I/O behavior.
- Explicit non-goal: no libxev-backed `std.Io` adapter in the initial migration.

### Networking capability confirmation

The selected standard blocking/thread-compatible I/O path is expected to support the networking paths required by the migration:

- HTTP providers: `std.http.Client` in Zig 0.16 accepts an I/O instance and uses standard networking/TLS behavior through the selected backend.
- OAuth HTTP flows: token exchange, user-info requests, and provider-specific HTTP helpers can share the same HTTP wrapper and default context model as providers.
- OAuth callback server: loopback listen/accept/read/write should use Zig 0.16 `std.Io` networking APIs through Makai networking wrappers.
- WebSocket transport: TCP connect, address resolution, stream read/write, and frame I/O should use Zig 0.16 `std.Io` networking APIs through Makai networking wrappers.

Do not choose `std.Io.Evented` as the initial default because the Zig 0.16 impact assessment notes networking limitations for that backend. Evented I/O can be evaluated after functional parity is established.

## Ownership model

Makai will introduce project-level runtime/context objects during the wrapper phases. Names may be adjusted during implementation, but the ownership model is fixed:

- `MakaiContext` or `MakaiRuntimeContext` owns the default allocator reference, default I/O backend, and cross-cutting defaults needed by providers, OAuth, transports, and protocol/agent runtime paths.
- `MakaiTestContext` or `TestIoContext` owns test-specific I/O, allocator, deterministic random sources where applicable, and cleanup checks.
- Public objects that need I/O store a borrowed pointer/reference to the Makai context, not an owned raw `std.Io` handle.
- Internal operation helpers may accept an explicit borrowed I/O handle as their second parameter when needed for a narrow operation.
- Any object that stores a borrowed context must document that it must be deinitialized before the context is deinitialized.
- Functions that allocate or own resources continue to take `std.mem.Allocator` explicitly, preserving existing Makai memory-management conventions.

The I/O backend lifetime is therefore rooted in the top-level runtime/test/CLI owner and flows inward through contexts and wrapper calls.

## Default I/O creation points

| Area | Creation point | Ownership and flow |
|---|---|---|
| CLI runs (`zig/src/tools/makai.zig`, demo/run entry points) | CLI `main`/top-level command runner creates a Makai runtime context before parsing commands that need I/O. | CLI owns the context for the process lifetime or command invocation. File, stdio, provider, OAuth, and protocol helper calls borrow it. |
| Tests | Test fixture creates `MakaiTestContext` backed by `std.testing.io` where practical; pure unit tests that do not need real I/O may use failing/no-op test I/O. | Each test owns and deinitializes its context. Tests should not expose raw `std.Io` outside test-only helpers. |
| Providers | Provider registry/stream entry point receives or creates a provider operation context from the caller's Makai context. | Public provider APIs remain context/default-I/O based. Internal HTTP helpers borrow explicit I/O when constructing `std.http.Client` or request/response streams. |
| OAuth flows | OAuth login/token/refresh helpers receive a Makai context or OAuth context derived from it. | OAuth owns credentials/auth concerns, borrows context I/O for HTTP, filesystem storage, callback networking, and user prompts. Agent logic remains auth-agnostic. |
| Transports | Transport constructors receive a Makai context or transport config. | Stdio and WebSocket transports borrow default I/O through wrapper types. In-process transport remains memory-only and should not require real I/O. |
| Protocol runtime | Provider/agent protocol clients and servers receive a runtime context when they need transport I/O. | Protocol envelope/state logic remains independent of concrete I/O; transport adapters borrow context I/O. |
| Agent runtime | Agent constructors/loop configuration accept Makai context or agent context, not raw `std.Io`. | Agent loop remains provider/auth agnostic. It borrows context only to drive protocol/transport/provider clients that need I/O. |

## Public API signature posture

The migration will classify signatures into three groups.

### Expected to stay stable where possible

These APIs should avoid source churn unless the compiler or wrapper rollout requires changes:

- Core domain data types in `ai_types.zig`, such as `ContentBlock`, `MessageEvent`, `AssistantMessage`, `Usage`, `Model`, and `StreamOptions`.
- `CancelToken` semantics.
- Event stream polling/result APIs where possible, although internal synchronization will migrate to Zig 0.16 primitives.
- Protocol envelope and payload data shapes.
- Provider registry names and provider selection strings such as `anthropic-messages`, `openai-responses`, and `openai-completions`.

### Expected to change to context/default-I/O patterns

These public entry points may receive Makai context parameters, options structs, or constructor overloads, but must not expose raw `std.Io`:

- Provider stream constructors and functions that currently construct `std.http.Client` internally.
- OAuth login, refresh, token exchange, callback server, and credential storage entry points.
- Stdio and WebSocket transport constructors.
- CLI command-runner helpers that currently directly open files, stdin/stdout, or providers.
- Agent and protocol runtime constructors that need transport or provider I/O.

### Transitional overloads allowed

During Phase 0/Phase 1, wrappers may offer transitional overloads to reduce dependent PR friction:

- `init(...)` or `create(...)` using a Makai context/default I/O path.
- `initWithContext(...)` when an existing `init(...)` must be retained temporarily.
- Internal-only `initWithIo(...)` or `runWithIo(...)` helpers, kept unexported or documented as non-public migration seams.

Do not promise these transitional overloads beyond the migration series. The final public shape should prefer one context/default-I/O constructor per component.

## Wrapper naming conventions

Wrapper modules should live under `zig/src/utils` or `zig/src/compat` as decided by the Phase 0 skeleton PR. Use names that describe Makai intent rather than Zig version details.

Recommended module/function families:

- `io_context.zig`: `MakaiContext`, `MakaiRuntimeContext`, `MakaiTestContext`, `initDefault`, `initTesting`, `deinit`.
- `time.zig` or `clock.zig`: `nowMillis`, `nowSeconds`, `nowNanos`, `monotonicNowNanos`, `sleepNanos`.
- `random.zig`: `secureBytes`, `randomBytes`, deterministic test-source helpers, and ID-generation helpers where appropriate.
- `fs.zig` or `file_io.zig`: `cwd`, `openFile`, `readFileAlloc`, `writeFileAtomic`, `createDirAll`, `renameAtomic`.
- `stdio.zig`: `stdin`, `stdout`, `stderr`, `readStdin`, `writeStdout`, `writeStderr`.
- `http.zig`: `HttpClient`, `HttpRequestOptions`, `openRequest`, `sendRequest`, `readResponseChunk`, `readErrorBodyAlloc`.
- `net.zig`: `resolveIp`, `tcpConnect`, `listenTcp`, `accept`, `readStream`, `writeStream`.

Avoid versioned names such as `zig016HttpClient` in public wrapper APIs. Version-specific implementation details should remain inside wrapper modules.

## Parameter order conventions

To reduce review friction across dependent PRs, use this order for new and changed wrapper APIs:

1. Allocator or Makai context first.
2. Explicit internal I/O handle second, only for non-public/internal helpers that require it.
3. Operation-specific parameters next.
4. Options/config structs after required operation parameters.
5. Callback/context pairs last, using existing Makai callback conventions where applicable.

Examples:

```zig
// Public/context path: no raw std.Io in signature.
pub fn streamMessages(ctx: *MakaiContext, allocator: std.mem.Allocator, options: StreamOptions) !AssistantMessageStream;

// Internal helper path: explicit I/O allowed below public boundary.
fn sendHttpRequest(allocator: std.mem.Allocator, io: *std.Io, request: HttpRequestOptions) !HttpResponse;

// Test helper path: test context owns I/O.
fn initProviderTestContext(allocator: std.mem.Allocator) !MakaiTestContext;
```

When both allocator and context are present, prefer existing ownership semantics:

- Use `allocator` first for functions whose primary job is allocation or construction.
- Use `ctx` first for operations whose primary job is executing I/O through an existing runtime.
- Do not duplicate allocator sources ambiguously; if `ctx` owns/provides the allocator, either use `ctx` only or document why a separate allocator is required.

## Wrapper behavior guardrails

- Wrappers hide Zig 0.15.2/0.16.0 API drift but should not hide semantic differences. If a timeout, random source, filesystem atomicity guarantee, or network capability differs after the compiler switch, document it in the wrapper implementation and PR body.
- Public wrappers should preserve provider/OAuth/auth boundary rules: providers and OAuth own credentials; agent logic remains auth-agnostic; tool auth belongs at the tool protocol/runtime boundary.
- Security-sensitive randomness must use secure entropy (`io.randomSecure` or a wrapper that maps to it) for OAuth PKCE/state, WebSocket nonces/masks where required by protocol/security expectations, and any credential/token material.
- OAuth storage filesystem wrappers must preserve atomic replacement behavior and file mode expectations documented in the migration plan.
- Transport wrappers must preserve byte-level behavior and avoid silently changing framing semantics.

## Deferred decisions

This decision intentionally does not choose:

- A long-term evented-I/O architecture.
- A libxev-to-`std.Io` adapter.
- A proving provider for the shared HTTP abstraction PR.
- Final public names for every context/wrapper type.
- Whether all current public constructors survive after the migration series.

Those should be handled by the relevant follow-up work items, but they must remain consistent with the core rule that public APIs do not expose raw `std.Io`.
