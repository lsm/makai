# TigerBeetle Zig Patterns Research

> A focused study of [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle), at
> commit `47aeb22` (2026-09-01), to identify practices that can improve Makai.
>
> This replaces neither Makai's existing conventions nor Zig's standard-library guidance. It
> identifies patterns that fit a networked, dynamically configured AI streaming runtime.

## Executive summary

TigerBeetle is an excellent source for *how to make invariants, capacity, and failure modes
explicit*. Its primary goal is a deterministic, fixed-resource database, so copying its policies
literally would be counterproductive for Makai. In particular, Makai accepts variable-sized HTTP
and JSON input, has a public SDK, and deliberately allocates request/response data at runtime.

The high-value adaptation is:

1. Make each protocol/streaming state machine state its invariant in one small helper, and call it
   at public state transitions.
2. Add explicit, configurable limits at every externally driven accumulation point.
3. Separate malformed or over-limit external data (a returned error) from an impossible internal
   state (an assertion).
4. Test those bounds and transitions with deterministic adversarial chunking before considering
   broad allocator or container rewrites.

The first refactoring should target the small, contained parsers/transports, not `EventStream` or
provider implementations all at once.

## What TigerBeetle does

TigerBeetle's [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
sets safety, performance, then developer experience as design priorities. The source reinforces
that policy with three mutually supporting techniques:

| Pattern | Evidence in TigerBeetle | Why it works |
|---|---|---|
| Explicit contracts | `MessageBuffer.invariants()` checks ordering of all cursor positions; each mutating operation calls it after a transition. | A state-machine bug fails near its cause rather than later as corrupt output. |
| Bounded resources | `MessagePool` computes a capacity budget at initialization; `MessageBuffer` limits parsing to `message_size_max`. | The maximum work and memory cost can be reasoned about before an adversary or a load spike chooses input. |
| Validate at boundaries | The message parser turns invalid checksums/sizes into an `InvalidReason` and only asserts facts established by validation. | External failure remains an ordinary operating error; a violated internal promise is loud. |
| Compile-time layout checks | State-machine records assert their size, alignment, padding and field offsets. | Binary-format/layout regressions are rejected before execution. |
| Deterministic adversarial testing | VOPR substitutes clock, network and disk, injects faults, and records a seed plus Git revision for replay. | Rare interleavings and partial I/O become reproducible test cases. |
| Batching with a controlled pace | Their style distinguishes control plane from data plane and makes bounded batches a design primitive. | It limits work per scheduling turn and amortizes I/O without abandoning correctness checks. |

For a primary source discussion of the testing model, see TigerBeetle's [deterministic simulation
testing documentation](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md).

## Patterns to adopt in Makai

### 1. State-machine invariants at internal transitions

Makai already has an appropriate bounded core: `EventStream(T, R)` has a fixed ring capacity and
completion semantics. Its parsers and transports, however, have several related mutable fields
whose relationship is currently spread across methods. Model the TigerBeetle approach, not its
assertion count:

```zig
fn invariants(self: *const SSEParser) void {
    assert(self.line_buffer.items.len <= self.limits.line_bytes_max);
    assert(self.current_data.items.len <= self.limits.event_bytes_max);
}
```

Call this after internal transitions such as appending a chunk, completing an event, dequeuing an
event, `reset`, and `deinit`-adjacent cleanup where it is meaningful. Preconditions that are
already validated by the caller may be assertions; a provider's malformed SSE field, an oversized
line, or a failed allocation must remain an error path.

Start with [SSE parser](../zig/src/providers/sse_parser.zig), then use the same shape in
[WebSocket framing](../zig/src/transports/websocket.zig) and [stdio framing](../zig/src/transports/stdio.zig).

### 2. Name and enforce input budgets

`std.ArrayList` is appropriate for Makai's variable-size messages; it needs a policy boundary.
The most important unbounded accumulators are parser line/event buffers, WebSocket receive and
fragment buffers, stdio leftovers, and HTTP error/response buffers. Add a small `Limits` type at
the owning component rather than a global collection of unrelated constants:

```zig
pub const Limits = struct {
    line_bytes_max: usize = 64 * 1024,
    event_bytes_max: usize = 4 * 1024 * 1024,
};
```

Every append must check the *prospective* length with overflow-safe arithmetic and return a named
error such as `error{SSELineTooLarge, SSEEventTooLarge}`. The exact defaults
need product input: choose them from real provider payloads, document the unit and owner, and make
SDK/CLI callers able to override them where a large payload is legitimate.

Do not cap completed events merely because they were coalesced into one `feed()` call: provider
read boundaries are arbitrary, so identical wire bytes must not succeed or fail based on chunking.
If the returned batch itself needs a bound, redesign the parser/consumer boundary to drain or emit
batches independently of read calls.

This is a direct application of TigerBeetle's "put a limit on everything" rule, adapted to
Makai's public API instead of a fixed database message size.

### 3. Make ownership and transfer points structural

Makai has already adopted `OwnedSlice(T)` and a documented producer/consumer ownership boundary.
Keep that direction. The next improvement is to eliminate ownership flags only where a value can
become externally visible or cross a thread/stream boundary; do not rewrite every local slice.

Rules for new code:

* Borrow a slice only while the producer's backing storage is guaranteed to outlive its consumer.
* At an asynchronous hand-off, use a type that denotes ownership (`OwnedSlice`, a dedicated owned
  event type, or an explicit clone function), not a side comment or a boolean elsewhere.
* Give cloning a precise name: `clone`/`dupe` allocates an independent value; `borrow` never does.
* Pair each ownership-changing path with a test under `std.testing.allocator`.

The current [ownership convention](../CLAUDE.md) correctly warns not to make a *borrowed*
`EventStream` free event strings. The supported owned mode must still free cloned queued events in
`EventStream.deinit()`. TigerBeetle's message pool offers the relevant conceptual model—ownership is
explicit at the hand-off—but its intrusive reference-counted fixed pool is not a suitable drop-in
for Makai yet.

### 4. Use explicit domain state, not boolean combinations

TigerBeetle uses ordered cursors and enums (`iterator_state`, `invalid`) instead of a loose set of
booleans. In Makai, when a component has mutually exclusive lifecycle states, prefer a small enum
or tagged union over combinations such as `started`, `completed`, `failed`, and nullable callbacks.
This reduces invalid representable states and makes exhaustive `switch` handling compiler-checked.

Good candidates are streaming parser lifecycle and retry/transport connection state. This is not a
directive to replace simple independent feature flags with enums.

### 5. Put correctness tests around chunk boundaries and fault paths

TigerBeetle's full VOPR simulator is too large a first step, but its testing *shape* is immediately
usable. Build deterministic test helpers that feed a payload in every split pattern relevant to a
small payload: one byte at a time, at delimiters, before/after UTF-8 boundaries, and random seeded
partitions. Run the same assertions after every chunk.

First test matrix:

| Component | Valid cases | Negative cases |
|---|---|---|
| SSE parser | arbitrary chunks; CRLF/LF; multiple events; reset/dequeue; `id`/`retry`; unknown and colonless fields ignored | line/event/pending limits; final partial event |
| WebSocket parser | header/body splits; continuation frames; ping interleaving | declared oversized payload; bad opcode; fragmented-message limit |
| stdio transport | every newline split; many consecutive requests | overlong line; EOF partial request; output backpressure |
| EventStream | full/empty; completion; cancellation; producers/consumer ordering | full ring, double completion, completion-after-error, timeout boundary |

Record the seed in any randomized test failure. This gets most of the reproducibility benefit of
TigerBeetle's simulation discipline without pretending that a threaded, real-provider runtime is a
deterministic database simulator.

### 6. Use compile-time assertions for wire/layout facts only

TigerBeetle's `@sizeOf`, `@alignOf`, `@offsetOf`, `stdx.no_padding`, and enum-field assertions are
especially valuable where it writes fixed binary records. Makai should use them for any fixed
binary WebSocket frame header, C ABI, packed protocol record, or compile-time provider registry
assumption. JSON fields and heap-owned SDK objects do not benefit from forced layout constraints.

## Patterns deliberately not copied

| TigerBeetle policy | Why Makai should not copy it literally |
|---|---|
| No allocation after initialization | Makai must process variable-sized network/JSON data and return independently owned SDK values. Predictable *limits* are the right goal. |
| Fixed pools and intrusive reference counts everywhere | They add lifecycle complexity. Consider a pool only after a benchmark identifies allocation churn in a bounded hot path and ownership is fully specified. |
| Crash on all unexpected external input | Malformed provider/network input must surface as an error and preserve availability. Assert only after data becomes an internal invariant. |
| Two assertions per function / 70-line hard limit | Useful review prompts, not useful mechanical gates for a multi-provider application. Require material invariants, focused functions, and tests instead. |
| Zero dependencies | Makai has a different product boundary. Evaluate dependencies case by case for maintenance, security, portability, and measured value. |
| Whole-system deterministic simulator immediately | Valuable long term, but costly. Begin with deterministic parser/transport fault injection and a fake clock/I/O seam. |

## Recommended refactoring sequence

1. **Write a short limits policy and inventory.** List every externally driven buffer, its current
   failure behavior, its owner, and a proposed named limit. No behavior change yet.
2. **Harden `SSEParser`.** Add `Limits`, checked append helpers, named errors, `invariants()`, and
   exhaustive split/over-limit tests. This is self-contained and exercises the pattern on a real
   provider boundary.
3. **Apply the same boundary contract to WebSocket and stdio framing.** Keep limits local and
   preserve their existing public errors unless an API change is deliberate and documented.
4. **Add an owned-event audit at each asynchronous hand-off.** Start at `ByteStream` and provider
   event emission; document borrow/clone/consume responsibility beside the type definition and add
   leak/double-free regressions.
5. **Introduce a deterministic chunk/fault test harness.** Reuse it across the three framers; later
   extend it with fake time and partial writes for retry logic.
6. **Measure before pool/zero-copy work.** Profile allocation rate, retained bytes, and P95/P99
   latency under representative concurrent streams. Only then design a bounded reusable buffer or
   zero-copy path, with an explicit ownership proof and fallback behavior.

## Decision gates for the next discussion

Before implementation, decide these product-level choices:

1. What is the maximum accepted SSE event, WebSocket message, stdio request, and retained error
   body for the CLI and SDK respectively?
2. Should exceeding a limit terminate only one provider request, one transport connection, or the
   entire process? The safe default is the narrowest scope that preserves protocol integrity.
3. Are limits fixed defaults, caller-configurable, or both? Configuration needs a validation and
   compatibility policy.
4. Which stream hand-offs require the consumer to own data today? This must be written down before
   attempting zero-copy or pooling work.
5. What benchmark and workload establish that a fixed pool is worth its added complexity?

## Local baseline

Makai already has several foundations that fit this direction: a fixed-capacity `EventStream`,
`OwnedSlice`, two-pass `StringBuilder`, `HiveArray`, source-local tests, grouped build test steps,
and [`scripts/check-zig-patterns.sh`](../scripts/check-zig-patterns.sh). Preserve those instead of
introducing a second competing convention. The initial repository scan also shows extensive
`ArrayList` use in network and provider paths; that makes bounded append behavior the highest
leverage common refactoring, ahead of a general allocation rewrite.
