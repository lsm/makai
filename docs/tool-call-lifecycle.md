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
3. **Payload merge + scan/flush mechanics** (#295 / task #410): the §6 merge matrix and
   the §7 reconciliation floor with the inline-flush cursor contract, including the
   retirement boundaries and the end-of-session flush release. Specified in the
   addendum below from the seven #295 findings; implemented after #288 landed.

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

## Addendum (#295): retained-payload merge + scan/flush mechanics

Date: 2026-09-16. Design-first deliverable for the two layers the coordinator pre-ruled
out of PR #288 (cycle 5). Baseline: `main` @ `85be234`. Inputs: the seven findings listed
on #295 — four from the cycle-5 payload/retirement layer and three from earlier PR #288
rounds. This addendum extends §3–§5; it changes no §2 resolution semantics.

### 6. Retained-payload merge matrix

An occurrence's retained payload is what later renders read after the half that carried
it is gone: `output` (final content bytes), `artifact_count`/`artifact_refs`, and the byte
telemetry (`raw_total_bytes`, `returned_total_bytes`, `estimated_returned_tokens`, derived
`truncated`). Three sources feed them: preview fragments
(`tool_execution_update.partial_result_json`, live occurrences only), the execution half
(`tool_execution_end`: `result_json` + telemetry + artifact count/refs), and the result
half (`message_end.tool_result`: detail source = `details_json` else `text`, plus
`artifacts_json`). Status/error merging stays exactly as #288 landed it.

One principle covers every cell: **a terminal half merges its payload per field without
erasing richer state the other half already recovered** — the field-level extension of
§1's "the second half merges missing fields".

| Arrival × field | `output` | artifacts | byte telemetry |
|---|---|---|---|
| execution half into an occurrence with previews (normal end) | append the final payload after the accumulated previews, skipping when the retained output already equals it (idempotence) | set from the payload | replace per field only when the incoming value is non-zero |
| result half, merge path (live occurrence, `none`-evidence reconcile, or allocate-from-result) | merge the detail source through the same idempotent append — the guard is equality, never emptiness (r4021914112) | count = max(retained, `artifacts_json` length) (r4021914118); refs stay absent on this wire; the derived `truncated` flag recomputes after any artifact recovery | none on this wire; retained values unchanged |
| execution half, merge path (reverse replay: end after result) | append `result_json` through the same idempotent append (dedupes the re-delivered payload) | count = max(retained, payload count); a zero never clobbers (r4021914125); refs replace on a count increase and are adopted when the counts tie and the result half left them empty (the tie case is the only refs source for a reversed replay) | replace per field only when non-zero — legacy/incomplete ends carry zeros that mean absent (r4021914125) |
| result half, render-link (evidence `execution` → `both`) | no merge | no merge | no merge — the row is display-only; in forward order the execution half is authoritative |

Previews append with a newline separator while the occurrence is live (unchanged). The
idempotent-append primitive is shared by both terminal paths, so a reversed replay of the
same run does not double the payload, and a final result over a preview-accumulated
occurrence still lands (the r4021914112 defect was guarding on emptiness).

**Rendering rule (r4021914118):** terminal summary rows render *after* the merge, from
merged entry state — byte telemetry and artifact count read the entry, the status/error
preview reads the half's own payload. A summary written before a field was recovered is
rewritten by the later half through the §4 primitive, so the stored row never omits
artifact indicators the entry knows about.

### 7. The reconciliation floor and the inline-flush cursor

Slice 2 left linked-row scans eager because §5's bound needed two things the review loop
showed were under-specified: when an occurrence stops being rewritable, and what the
inline renderer may flush. Both are contracts, not implementation details.

**Frozen.** An occurrence is *frozen* when its terminal evidence is `both` or it is
*retired*. Frozen occurrences are immutable: resolution never attaches to a retired
occurrence (a later half of the family allocates the next occurrence, as #288 already
does for `both`-evidence families), so no rewrite, insert, or removal ever targets a
frozen occurrence's rows again.

**Retirement boundaries.** Retirement marks terminal occurrences retired at the points
after which no further half can legally arrive: `turn_start` (a new turn's calls are new
invocations) and `agent_end` — the r4021914129 fix; a session whose last turn ends
without a next turn must still release its rows — plus the post-replay finalization on
resume (a crashed session replays without an `agent_end` record; after the replay drain,
the same boundary holds). `turn_end` never retires: the agent loop emits tool-result
`message_end`s after `turn_end` (§3 loss mode 1), so the reconcile window spans the turn
boundary. A retired occurrence's late half arrives as a **corrected row**: a fresh
occurrence with fresh rows, never a rewrite of scrollback. Retirement itself drains a
**retire-candidate list**: an occurrence appends its registry index exactly once, at
the moment it becomes terminal — a terminal allocation (orphan results, id-reuse
outcomes), the live→terminal terminalization, or the interruption inference — and
retirement retires the drained set. The enqueue happens before the terminal state is
committed (and the allocation enqueue before the registry append, with an error-path
pop), so an allocation failure leaves the occurrence live and the transition retryable
— a terminal-but-untracked occurrence, which nothing could re-enqueue, is
unrepresentable. Each occurrence is visited once, so a live gap (an
occurrence whose boundaries were evicted, blocking any monotone watermark) cannot make
retirement rescan the suffix it already processed.

**The floor.** `summary_scan_floor` is one watermark: the index of the earliest
transcript row *owned* by an unfrozen occurrence (a `.tool` row whose `tool_call_id`
names one), or `transcript.items.len` when there is none. Error cards need no separate
ownership: §4 orders the write primitive before card emission, so a card always sits
above its occurrence's summary row and is covered transitively. Consequences:

- Every rewrite, insert, and removal of *owned* rows targets rows ≥ the floor, because
  targets belong to the occurrence being handled, which is unfrozen at handling time,
  and the floor is the minimum over all unfrozen occurrences. The one exception is the
  pending tool-result placeholder: an unowned row that can sit below the floor. A
  summary insert before it clamps the floor down to the insert index, and its removal
  decrements the floor — two mechanical index adjustments at those two sites; every
  other insert/remove site performs **no** floor maintenance (the c3/c4 finding
  family), and `advanceSummaryScanFloor` is the floor's only other writer. Without the
  insert clamp, a later half's rewrite would miss the summary row below the floor and
  duplicate it.
- Linked-row scans (`replaceLinkedSummaryRow`, `insertBeforeLinkedResultRow`,
  `removeLinkedResultRows`, the error-card refresh scan) stop at the floor (§5,
  r4019270180). The advance itself walks forward only past rows it proves unowned —
  amortized linear over the session — and proves ownership with an occurrence-key
  membership set over the unfrozen suffix (`unfrozen_occurrence_ids`, keys borrowed
  from the registry entries), maintained at exactly the three points frozen-ness
  changes: allocation inserts, the `both`-evidence transition (terminalize and the
  render-link flip) removes, retirement removes. One O(1) set lookup per row visited;
  no registry rescan. It runs where ownership changes: after each terminal half, after
  `finalizeInterruptedTools`, and after retirement. Allocation and append sites do not
  call it: appended rows land at or above the floor, and a floor already at
  `items.len` correctly points at the first row the new occurrence appends. The flush
  tick also runs it before reading the stop — rows can append with no tool event at
  all (welcome banner, plain-chat turns), and the walk is amortized O(1) (it stops at
  the first owned row and re-walks nothing), so the stop stays a read of a maintained
  watermark rather than a per-row lookup (PR #288 c2 P2).

**The inline-flush cursor contract.** The inline renderer flushes transcript rows into
immutable scrollback sequentially from `inline_history_flushed`; a rewrite of a row the
cursor has passed would be invisible (PR #288 c1 P1). The contract:

1. The flush stop is `min(earliest active entry, summary_scan_floor)` — one O(1) read of
   the watermark, no per-row registry lookups during flush ticks (PR #288 c2 P2).
2. Held rows stay visible: the live region renders the whole unflushed range from
   `inline_history_flushed`, tail-clipped to the live window, so withholding a row from
   scrollback never withholds it from the screen.
3. Release is the floor advancing: a frozen or retired occurrence's rows flush on the
   next tick once the cursor may pass them. `agent_end` retires everything, so a session
   that ends without a next turn still flushes its full rewritable prefix (the
   end-of-session flush release, asserted by PTY).
4. The final flush at quit bypasses the stop — exit always dumps the transcript.
5. Rows below the cursor are immutable by construction (stop ≤ floor); the corrected-row
   rule above is the only post-release path, and it appends rather than rewrites.

### Addendum traceability

| #295 finding | Resolved by |
|---|---|
| r4021914112 retained output dropped behind previews | §6 idempotent append (equality guard) |
| r4021914118 summary omits result-recovered artifacts | §6 artifact max-merge + rendering rule |
| r4021914125 legacy-end telemetry zeros clobber | §6 non-zero per-field replace + max-retain |
| r4021914129 rows held forever at session end | §7 agent_end/retirement boundary + release |
| PR #288 c1 P1 rewrites of flushed rows invisible | §7 flush stop + held-row rendering |
| PR #288 c2 P2 per-row lookups in flush ticks | §7 stop = O(1) watermark read |
| PR #288 c3/c4 floor under insert/remove | §7 single-writer floor, no per-site maintenance |

### Addendum tests

- `state.zig`: matrix cells — final result over preview-accumulated output; result
  artifact recovery rendering into the stored row; legacy-zero end after result-recovered
  telemetry/artifacts; reversed-replay payload dedupe. Retirement — turn_start and
  agent_end retire; results after retirement allocate; the floor advances over frozen
  families, stays put below interleaved unfrozen ones, and releases to `items.len` at
  agent_end.
- `app.zig`: the flush stop reads the floor and releases when the occurrence freezes;
  held rows render above the active entries.
- PTY: a resumed session whose final turn drops the tool-result half (execution-evidence
  occurrence at `agent_end`) with enough trailing rows for flush pressure asserts the
  end-of-session release — the early rows land in scrollback instead of being clipped
  out of the held window.
