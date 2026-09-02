# Zig Reliability 80/20 Improvement Plan

## Goal

Deliver the largest reliability and resource-safety improvement for Makai's streaming boundaries
with a deliberately small, reviewable change set. Stop after the first tranche, measure it, and
retrospect before broadening scope.

This plan applies the relevant TigerBeetle ideas from
[TigerBeetle Zig Patterns Research](tigerbeetle-zig-patterns.md): explicit contracts, bounded
resources, deterministic failure tests, and clear ownership at asynchronous hand-offs.

## Why this is the first 20%

The audit found that Makai already has several sound foundations: `EventStream` is bounded (1,023
usable slots), code has grouped test steps, and ownership conventions are documented. The clearest
common exposure is instead externally controlled growth in framing/parsing buffers:

| Priority | Boundary | Evidence | Failure mode addressed |
|---|---|---|---|
| P0 | SSE parser | `line_buffer` and `current_data` are `ArrayList`s with no per-parser input budget. | A peer can make a request retain unbounded bytes before a delimiter arrives. |
| P1 | stdio receiver | `leftover` accumulates bytes until a newline or EOF. | A malformed or hostile line can consume unbounded CLI-server memory. |
| P1 | WebSocket receiver | `recv_buffer` and `fragment_buffer` grow as frames/fragments arrive. | An oversized or indefinitely fragmented peer can grow connection memory. |
| P2 | Async event ownership | Some producer/consumer paths require cloned events while others borrow them. | A later performance rewrite can introduce a lifetime bug unless each hand-off is explicit. |

The P0 parser is the best first slice: it is small, pure with respect to I/O, has inline tests,
and every provider depends on its correctness. The P1 work reuses the same proven pattern. No pool,
allocator, protocol schema, or provider-response rewrite belongs in this tranche.

## Constraints and non-goals

* Preserve the existing public API and ordinary valid-provider behavior.
* Treat malformed and over-limit peer input as recoverable errors, never assertions.
* Do not set arbitrary production limits without first collecting representative payload sizes and
  choosing a documented compatibility policy.
* Do not convert all `ArrayList`s to fixed buffers or introduce a general-purpose buffer pool.
* Do not change `EventStream`'s established borrowed-event default in this work.
* Keep every implementation step independently testable and revertible.

## First tranche: bounded framing (the 20%)

### Step 0 — Baseline and budget decision

**Deliverable:** a short limits table beside the owning types, with proposed defaults, rationale,
units, and API exposure. Use observed fixture/test and representative provider traffic sizes; do
not log credentials or payload bodies.

**Questions to resolve before changing behavior:**

1. What maximum SSE line and complete event are supported by the SDK and CLI?
2. What maximum stdio line and WebSocket message/fragment are supported?
3. Are limits fixed defaults, caller-configurable, or both?
4. Does a limit breach fail one request, close one connection, or terminate the process?

**Acceptance:** written decisions, plus a baseline of test runtime and a small benchmark or
instrumented test for normal SSE throughput/allocation count. This makes a later regression
detectable. The implementation and rollout of that baseline are specified in
[Performance and Memory Baseline Plan](performance-memory-baseline-plan.md); if it has not landed,
record the temporary test-runtime baseline and schedule that plan before any pooling or zero-copy
work.

### Step 1 — Harden `SSEParser`

**Scope:** `zig/src/providers/sse_parser.zig`, every provider parser call site that currently
collapses parser errors, the corresponding provider integration tests, and any required build/test
wiring.

1. Add a `Limits` configuration with separate maximums for line and complete-event bytes. `init()`
   keeps sensible compatibility defaults; a second initializer may take limits. Do not limit
   completed events based on one `feed()` call: read chunking is arbitrary. A bounded output batch
   requires a separately designed drain/emit API.
2. Centralize checked growth in helpers such as `append_line_byte`, `append_event_data`, and
   `append_pending_event`. Check the prospective length before appending and use overflow-safe
   arithmetic.
3. Return precise errors (`LineTooLarge`, `EventTooLarge`) rather than silently truncating or
   relying on allocator failure. Propagate them through every provider call site with useful
   context; do not collapse them to the current generic parse-error text.
4. Add an `invariants()` helper for relationships that are *internal facts*—for example every
   retained buffer is within its configured limit. Call it after state transitions, not on
   unvalidated peer bytes.
5. Preserve the documented lifetime of the `feed()` result. Make cleanup on error explicit so no
   event type or event payload leaks.

**Tests:** one-byte feeds, splits at every delimiter of a small fixture, CRLF/LF/bare-CR handling
(including a CR boundary split across feeds), multi-line events, many completed events coalesced in
one feed, each byte limit exactly at and one byte over, repeated feeds after an error/reset,
provider-level propagation, and
`std.testing.allocator` leak coverage.

**Acceptance:** `zig build test-unit-providers` passes; existing valid-parser tests are unchanged
or improved; a test proves each bound returns the intended error before allocation growth beyond
the bound. Wire `sse_parser.zig` itself into the provider test step so its inline limit/chunk/leak
tests execute under this command.

### Step 2 — Generalize only the tested pattern

**Scope:** `zig/src/transports/stdio.zig` (the blocking receiver, async producer, and async
compatibility `read()` callback, preferably through one tested framing helper) and
`zig/src/transports/websocket.zig` in separate PRs or commits.

For each component, introduce one local limit type and one checked append path. Keep the semantics
specific:

* stdio: maximum retained incomplete line; process delimiters incrementally so several complete,
  individually valid requests coalesced in one read do not count against that limit. A breach returns
  a transport framing error and clears or closes the affected receiver according to the Step 0
  decision.
* WebSocket: maximum accepted frame payload, aggregate fragmented-message bytes, and undecoded
  receive-buffer bytes; validate declared lengths before buffering payload data and drain decoded
  frames incrementally so a read coalescing several valid frames is not rejected by its aggregate
  byte count.

**Tests:** all useful small-payload split positions; exact-boundary and over-boundary cases on every
public stdio framing path (or one shared framing helper); a coalesced stdio read whose total bytes
exceed the line limit but whose individual lines do not; a coalesced WebSocket read whose
individual frames/messages are valid but aggregate bytes exceed the receive limit; normal
continuation/ping behavior for WebSocket; EOF/cancellation behavior for stdio.

**Acceptance:** `zig build test-unit-transport` passes. The change must not alter normal
connection-state transitions or message ownership.

### Step 3 — Lightweight ownership ledger

**Scope:** documentation/comments and tests, not a generic ownership framework.

For each async boundary (`provider → AssistantMessageStream`, `ByteStream → transport consumer`,
and protocol forwarding), record:

| Boundary | Producer retains/frees | Consumer owns/frees | Required operation |
|---|---|---|---|
| Example only | producer buffer | no | borrow; producer outlives consumption |
| Example only | no | stream/consumer | clone before enqueue |

Fill this with the actual current behavior, then add one regression test for every clone path and
one for every borrowed path whose lifetime is non-obvious. Consolidate duplicate comments only
when the ledger reveals a genuine disagreement.

**Acceptance:** no ownership behavior changes; all affected grouped tests pass; reviewers can
identify the owner at every cross-thread or retained-data transition without tracing a provider
thread's lifetime.

## Stop point and retrospective

Stop after Steps 0–3. Do not automatically proceed to pooling, zero-copy, or a whole-runtime
simulator.

Review the tranche against these questions:

1. Did valid fixtures and representative streams remain below the limits with useful headroom?
2. Did parser/transport tests expose real defects or ambiguities in the existing contracts?
3. What changed in throughput, allocation rate, peak retained bytes, and P95/P99 latency for the
   baseline workload?
4. Were new errors sufficiently actionable for SDK and CLI users?
5. Did the ownership ledger reveal an actual lifetime defect or merely documentation debt?

Publish the findings in the PR/release notes. Continue only if a measured problem remains.

## Possible second tranche, gated by evidence

| Candidate | Evidence required before approval | Likely shape |
|---|---|---|
| Reusable bounded buffers | Allocation profiling identifies a specific high-churn, bounded hot path. | Component-local pool with an ownership proof, maximum capacity, exhaustion behavior, and stress tests. |
| Deterministic I/O fault harness | Repeated bugs depend on partial reads/writes, timing, cancellation, or retries. | Fake clock and scripted reader/writer shared by SSE, stdio, WebSocket, and retry tests. |
| EventStream contract tightening | A targeted concurrency test or production issue shows a transition/liveness gap. | Small invariant/state update and stress regression—never a speculative lock-free rewrite. |
| Wire-layout checks | Makai adds a fixed binary protocol/C ABI or a binary framing regression occurs. | Focused comptime size/alignment/offset assertions at that boundary. |

## Execution order and review gates

1. Review and approve the limits policy (Step 0).
2. Implement and review the isolated SSE change (Step 1).
3. Measure and decide whether the two other framers merit identical treatment (Step 2).
4. Complete the ownership ledger and regressions (Step 3).
5. Retrospect. Explicit approval is required before any second-tranche work.

This ordering makes the first change valuable even if the team decides the later changes are not
worth their complexity.
