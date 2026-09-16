# Tool-call lifecycle under event loss and id reuse (#279)

Date: 2026-09-15. Design-first deliverable for the reconciliation/occurrence layers carved
out of PR #275 (revert `8f7b1ca`); implementation follows this document. Baseline: `main`
@ `c3dc797`. Split source: `tui/273-persisted-tool-render` @ `b4a121a` (reference only —
its two-rule lookup is replaced here; do not build on it). Companion model:
`docs/persisted-tool-call-rendering.md` (#273) — row linking, renderers, persistence.
This document owns everything that model delegated to "the lifecycle": occurrence
identity, event loss, single emission, cost bounds.

## Root cause

The #275 rounds 3-5 each generated the next finding because the state layer never
answered one question uniformly: *which invocation does this event belong to?* Each event
path improvised — `upsertTool` reuses the first exact-id registry match, the result path
links rows by bare provider id, reconciliation targeted "the" tool by exact id — and every
improvisation diverged from the others exactly where events are lost or ids are reused.
The nine findings are the nine divergences. The fix is one resolution rule every path
shares, plus invariants that make loss safe rather than paths that patch each loss.

## The model

### 1. Occurrences and identity

A **provider id** (`tool_call_id` on the wire) correlates only concurrently in-flight
calls (`docs/oap-alignment.md`); a value reused in a later turn names a new invocation.
An **occurrence** is one invocation. The registry (`state.tools`) holds occurrences
append-only, keyed by an internal **occurrence key**: the provider id for a family's first
occurrence, `provider_id ++ "\x1f" ++ decimal(n)` for the n-th. All entries of one
provider id form its **family** — tracked by a `provider_id → youngest occurrence` map so
resolution never scans the registry. Occurrence keys are runtime-only — never
persisted; replay rebuilds them by the same rules. JSON string escapes make `\x1f`
impossible in a genuine provider id short of a deliberately hostile `\u001f` escape; the
residual collision mislabels rendering and cannot corrupt state, and is accepted.

An occurrence is **live** while `pending | running`, **terminal** after exactly one
terminal transition (`done | error | interrupted`). Terminal is monotone: evidence never
re-opens a live window, and `finalizeInterruptedTools` skips non-live occurrences.
Terminal state records which outcome halves have been seen: `none` (interrupted by
inference at `turn_end`/`agent_end`), `execution` (`tool_execution_end`), `result`
(`message_end.tool_result`), `both`. Status is set by the *first* arriving half; the
second half merges missing fields (output, telemetry, error card) and never flips it —
with one refinement landed with slice 2: a later failing half upgrades `done` to
`error` (failure evidence must not be rendered away; the reverse never happens).

At most one occurrence per family is live at any time: a live occurrence absorbs later
same-id live-intent events, so a second occurrence of a family is only ever allocated
after the previous one went terminal. (A provider reusing an id while its earlier call is
still in flight violates the wire contract; if it happens, the events attach to the one
live occurrence — degraded, not corrupting.)

### 2. The one resolution rule

Every tool-referencing event resolves through one function,
`resolveOccurrence(provider_id, class)`:

| Event | class | resolution |
|---|---|---|
| `tool_approval_requested`, `tool_execution_start`, `tool_execution_update` | live-intent | live occurrence of the family, else **allocate** |
| `tool_execution_end` | execution-outcome | live occurrence, else family's latest occurrence iff its evidence is `none` or `result` (this end is its missing/other half; slice 2), else **allocate terminal** |
| `message_end.tool_result` | result-outcome | live occurrence (terminalize — reconciliation proper), else family's latest iff evidence `none` (reconcile), else latest for **render-link only** if one exists, else **allocate terminal from the result** |

Slice 1 implements the live-intent row and the attach-or-allocate core of the
execution-outcome row (no evidence tracking exists yet, so an end arriving after the
family's youngest was terminalized — by evidence or by interrupt-inference — allocates
the next occurrence); the evidence-conditional branch and the whole result-outcome row
are slice 2.

Allocation always appends at the registry tail with the event's status; occurrence order
is first-reference order. Allocation from an outcome event is how end-only replay paths
(finding r4019429278) and orphan results get an occurrence instead of overwriting a
closed one (finding r4019270195).

The end-after-result merge (reverse replay order, `session_store.zig` dedupe cases) and
the result-after-end render-link (normal order — the end already terminalized the
occurrence) are both the same rule: the second half attaches to the occurrence the first
half produced and may not allocate again.

### 3. Event loss

Loss modes and what the model does with each:

- **Backpressure evicts `tool_execution_end`** (retained start + `turn_end`): `turn_end`
  marks the occurrence interrupted with evidence `none`; the tool-result `message_end`
  (emitted after `turn_end` by the agent loop) arrives, resolves to the `none`-evidence
  occurrence, and reconciles it — status, output, summary row, error card (finding
  r4019178997).
- **Result precedes end** (reverse replay): the result terminalizes the occurrence with
  evidence `result`; the later end attaches (execution-outcome, evidence `result`),
  merges telemetry/output, and rewrites the summary with the fuller data — one
  occurrence, one summary row, one error card (findings r4019178997, r4019429291).
- **Start and end both evicted, approval/update retained** (or pre-upgrade files): the
  approval/update allocated the occurrence; the retained result reconciles or render-links
  it. Because §4's write primitive guarantees a summary row exists for every terminal
  occurrence, the linked result row is never suppressed into invisibility (finding
  r4019270155).
- **Evicted start, retained failing result**: the result allocates the occurrence
  terminal `error` with readable detail and emits the error card exactly like the end
  path would (finding r4019270168).
- **Approval/update retained, run ends before any outcome**: `finalizeInterruptedTools`
  marks it interrupted *and* inserts its summary row via the same primitive — the
  invocation stays visible (finding r4019429304).
- **Crash window / resume**: unchanged from #273 §3 (`finalizeInterruptedTools` after
  replay); occurrence keys rebuild from the replayed events by §2.

Reconciliation positioning: a summary row written when the result row already exists is
inserted **before the first linked result row** of the occurrence, never appended after
it — summary-first is the rendering invariant both renderers assume.

### 4. Single-emission invariants

Per occurrence, across all orderings:

1. **One summary row.** Every terminal path (end, reconciliation, interruption) writes
   the occurrence's summary through one primitive: rewrite the linked summary row if one
   exists, else insert before the first linked result row, else append.
2. **One error card.** An `error` terminal with readable detail appends the error
   transcript row/card once (`error_card_emitted` on the occurrence; both the result half
   and the end half check it).
3. **One terminal transition.** First arriving half sets status; later halves merge
   fields only; `interrupted` is inference, always overridable by evidence, never
   overriding it.
4. **Suppression requires a summary.** A linked result row may only be suppressed
   (readable-error collapse, `done` collapse) when its occurrence has a summary row;
   the write primitive runs before suppression.

### 5. Cost bounds

The registry is append-only and occurrences finalize in first-reference order, so all
lifecycle work is linear in session length, no quadratic scans:

- **Resolution** is O(1) amortized: a `provider_id → latest occurrence index` map
  (updated on allocation only) jumps to the family's youngest occurrence; by §1 that is
  the only possible live member, so no registry walk is needed.
- **`finalizeInterruptedTools`** keeps the split source's `finalized_tool_count`
  watermark and scans only the unfinalized suffix (finding r4019338937).
- **Linked-row lookups** (rewrite/insert/remove) scan the transcript backwards only down
  to a `summary_scan_floor` watermark — the index of the earliest row still owned by an
  occurrence that is not fully terminal — because rows are created in occurrence order
  and rewrites are in place (finding r4019270180).

## Slices

One design, two PRs (~100 production lines each, per methodology):

1. **Identity** (#279, task #403): occurrence keys, family matching, the §2 resolution
   rule for live-intent and execution-outcome events, result rows linked to the resolved
   occurrence, `recoverToolArgs` by provider id, the family map. No behavior change for
   non-reused ids; reused ids stop overwriting earlier occurrences.
2. **Loss and emission** (#283 / task #404): result-outcome resolution (reconciliation
   proper), the §2 evidence-conditional merge, the §4 write primitive + positioning,
   error-card dedupe, interruption row insertion, the `finalized_tool_count` watermark,
   PTY loss-path assertions. Landed via PR #288 with two pieces deferred to #295 after
   its review loop: the `summary_scan_floor` transcript watermark with occurrence
   retirement (scans stay eager; §5's transcript bound is unimplemented until then),
   and the retained-payload merge matrix (output/artifact retention on reconciled
   entries), both as design-first follow-ups with the review findings as inputs.

## Non-goals

- No renderer mechanics change (both renderers already link by `tool_call_id`; §1 only
  changes which value rows carry — occurrence keys instead of provider ids).
- No persistence format change; occurrence keys are runtime-only.
- No provider-side id discipline (the wire contract is assumed as documented).
- No fix for a provider reusing an id *while the earlier call is still in flight* (§1).

## Traceability

| #279 finding | Resolved by |
|---|---|
| r3 r4019178997 retained-result reconciliation | §2 result-outcome + §3 first two loss modes |
| r4 r4019270195 P1 id-reuse occurrence scoping | §1 occurrence keys + §2 one resolution rule |
| r4 r4019270155 reconcile without summary row | §4.1/§4.4 write primitive before suppression |
| r4 r4019270168 reconciled error card | §2 result-outcome allocation + §4.2 |
| r4 r4019270180 legacy-replay scan cost | §5 `summary_scan_floor` |
| r4 r4019338937 turn_end registry rescan | §5 `finalized_tool_count` watermark |
| r5 r4019429278 end-only reused ids | §2 execution-outcome allocate-terminal |
| r5 r4019429291 duplicate error cards | §4.2 `error_card_emitted` |
| r5 r4019429304 terminal-without-result row | §3 loss mode 5 + §4.1 |

## Tests

- `state.zig` (slice 1): two full reuse cycles keep distinct entries/rows/links; end-only
  reuse allocates the next occurrence instead of rewriting the closed one; result rows
  link the resolved occurrence and suppression reads it; `recoverToolArgs` still matches
  by provider id for suffixed occurrences; `clearTools` resets occurrence numbering.
- `views/transcript.zig` (slice 1): reused-id rows render as two distinct balanced lines
  with per-occurrence status, and the later error does not rewrite the earlier line.
- `state.zig` (slice 2): each §3 loss mode as a scripted event sequence asserting §4
  invariants (row counts, card counts, status words); reverse order merges; watermarks
  bounded (long synthetic sessions stay linear — asserted via counters or sized smoke).
- PTY (slice 2): driver scenarios that drop/withhold `tool_execution_end` and replay
  reversed order assert the reconciled scrollback text.
- Guard: `tui_loc` delta reported against #266 (identity layer is plumbing; expected
  net near-flat against the deleted exact-match helpers).
