# One model for persisted tool-call rendering (#273)

Date: 2026-09-15. Design-first deliverable for the replay/rejection tail split out of
PR #272 (revert `21f3f78`); implementation follows this document. Baseline: `main` @
`9f99410`. Reference implementation preserved on `tui/386-transcript-polish` @ `8a1a6ca`
(starting point only — its ordering/consumption model is replaced here).

## Root cause

All five #273 concerns plus the `/clear` desync noted on the issue are symptoms of one
fact: the fallback renderer pairs transcript tool clusters with `state.tools` entries
**positionally**. `buildVisibleEntries` (`zig/src/tui/views/transcript.zig:94`) walks
clusters in order and `appendBalancedToolCluster` (`:110`) consumes `state.tools` through
a running `tool_index`, advancing by `@max(countToolStarts(cluster), 1)` (`:127`). That
correspondence is guaranteed by nothing. It breaks whenever transcript rows and tools-list
entries do not map 1:1 in order — which is exactly the rejected-result row (review
5212763222), the stale entries after `/clear` (issue comment), the missing starts in
pre-upgrade session files, and the interrupted start after a crash. Two fix rounds on
this seam in #272 each produced the next round's finding because each fix patched one
divergence while the positional pairing remained.

## The model

**Identity, not position.** Every `.tool` transcript row carries the `tool_call_id` it
belongs to. Both renderers derive membership, order, identity, and status from that link.
Neither consumes `state.tools` positionally; `tool_index`, `@max(count, 1)`, and
`countToolStarts` are deleted. Ordering becomes transcript order by construction, so a
row can never render at another call's position.

### 1. What the transcript contains (`zig/src/tui/state.zig`)

`TranscriptEntry` gains an owned `tool_call_id: []u8` (empty = unlinked). A tool call
produces at most two rows, both linked:

- **Summary row** (`tool_summary = true`, from `tool_execution_start`): live text
  `◈ <Label> "<primary arg>"`, held active; finalized in place by `tool_execution_end`
  as `◈ <Label> "<arg>" ok|failed <stats>`, or by interruption finalization as
  `◈ <Label> "<arg>" interrupted`. If no start was seen (pre-upgrade files, budget-dropped
  start) the end event appends the finalized row directly (`finalizeToolSummaryEntry`'s
  append path).
- **Result row** (`tool_summary = false`, from `message_end.tool_result`): text = result
  content. Suppressed (empty text → active row removed) when the linked tool failed
  **with a readable detail** — the `err` field unwrapped by `toolErrorMessage`
  (`state.zig:981`) — because the summary preview and the error card already carry it.
  A rejection (`details_json` is `{"rejected":true}`, no `err`) is not readable: the row
  is kept, so "Tool execution rejected by user" stays visible. This is the r3 readability
  finding; unlike `8a1a6ca` it cannot corrupt the fallback view, because §2 no longer
  consumes positions.

`ToolEntry.status` stays the single status source: `pending | running | done | error |
interrupted` (new variant). The summary row text is a snapshot written from status at
finalization time. The inline path renders row text and never consults `ToolEntry` — so
any terminal status must be written **into the row text** by the finalizer (r4 discussion
r4017836355). `ToolEntry` also gains `error_detail_readable: bool` (set at
`tool_execution_end`: true iff the error envelope unwrapped to an `err` message) — the
one predicate both the state layer's suppression and the renderer's collapse read.

### 2. What each renderer derives (`zig/src/tui/views/transcript.zig`)

Cluster membership is unchanged: a maximal run of `.tool` rows. Emission is per row, by
link:

| Row | Link | Balanced renderer |
|---|---|---|
| summary | ToolEntry found | balanced line `▸ <description> [status, sizes]` from the ToolEntry; status word now includes `interrupted` |
| summary | not found | row text as-is (defensive; `applyEvent` cannot produce this) |
| result | found, `done` | suppressed — collapsed into the call's summary line |
| result | found, `error`, readable | suppressed — error card + summary preview carry it |
| result | found, `error`, not readable (rejected) | kept, original text, header uses the linked tool's real name/label |
| result | not found | kept, original text |

The inline (real-terminal) path is unchanged mechanically (rows render in order; the
flush barrier stops at active entries). Its correctness comes from §1: finalizers write
status into row text before the active marker clears, so scrollback and the transcript
agree.

### 3. Persistence and replay (`zig/src/tui/app.zig`)

- `saveEvent` (`:828`) moves `tool_execution_start` from the drop list to a
  budget-checked arm (`toolRequestPayloadSize`, same cap as approval requests). The
  session store already round-trips the event (`session_store.zig:484`, `:581`).
- **New-format files**: replay applies the persisted start (live summary row), the end
  finalizes it. **Crash window** (start persisted, end never — e.g. kill during a pending
  approval): replay leaves a running `ToolEntry` plus an active summary row;
  `resumeSelectedSession` (`:484`) calls `finalizeInterruptedTools()` after the event
  loop, before the first inline flush, so the barrier never wedges.
- **Pre-upgrade files** (no persisted start, and `tool_call_delta` no longer echoes):
  `tool_execution_end` creates the `ToolEntry` with empty args. Recovery: assistant
  `message_end.tool_calls_json` (already persisted) is remembered on the state; on end,
  an id-match against that list fills `args_json` **before** the summary is computed, so
  replayed summaries keep their command/path/query. Sessions recorded in ask-mode
  already recover args from the persisted `tool_approval_requested`.
- `finalizeInterruptedTools()` marks `pending`/`running` tools `.interrupted`, rewrites
  each interrupted tool's summary row **text** in place (row located by id), and clears
  active markers. It is idempotent and also runs on terminal `agent_end` (cancelled /
  error), so a live abort mid-execution finalizes the same way a resume does.

### 4. What the tools list owes the transcript

`state.tools` is conversation-scoped derived state: it resets exactly when the transcript
resets. `resetReplayState` (`state.zig:427`) already clears both; `/clear`
(`app.zig:1146`) now clears both. With link-based rendering stale entries are already
unreachable (no row links to them); clearing keeps the registry truthful and bounded.

## Traceability

| #273 concern | Resolved by |
|---|---|
| 1 replay args (r3 5212585787) | §3: persisted starts (new files) + `tool_calls_json` id-match recovery (old files) |
| 2 persisted-start crash window (r3) | §3: `finalizeInterruptedTools` after replay; barrier cleared before first flush |
| 3 interrupted status in scrollback (r4017836355) | §1/§3: finalizer rewrites row text; inline renders text |
| 4 result-only clusters (r4 5212763222) | §2: link-based rendering; positional consumption deleted |
| 5 rejected-call readability (r3) | §1/§2: result row kept when the error detail is not readable |
| `/clear` desync (issue comment) | §4 + §2: `/clear` clears tools; links make residual staleness unrenderable |

## Addendum: model extensions from review rounds 2-5

Three rounds extended the posted model where its assumptions were too narrow. These are
parts of the model now, recorded with their fixes:

- **Readability of error details** (§1 refinement): "readable" means the summary preview
  and error card actually carry a human-readable sentence — an unwrapped `err`, or a
  payload that is not a JSON object (plain text renders verbatim in both). Object
  envelopes without a readable `err` (`{"rejected":true}`) and absent details (parsed
  `null`) keep their result row.
- **Occurrence-scoped identity** (§2 refinement): provider `tool_call_id`s correlate
  only concurrently in-flight calls (`docs/oap-alignment.md`); a reused id in a later
  turn is a new call. `ToolEntry` identity is occurrence-qualified (`id`, `id␟2`, …):
  live-intent events (start/update/approval) reuse only a live entry, end events resolve
  live-else-latest, and every row link, linked-row removal, and replay args recovery
  binds to the occurrence key (recovery matches the bare provider id).
- **Backpressure is the live twin of the replay crash window** (§3 refinement): a
  retained tool-result `message_end` reconciles a pending/running/interrupted call
  (status from `is_error`, output from the details envelope, the normal error card, and
  a summary row — inserted before a pending result row); `turn_end` finalizes
  interrupted tools before the inline flush barrier releases; a result row persisted
  before its end is removed once the end establishes a readable error; and
  finalization scans only the tools created since the previous pass (live entries are
  provably a suffix of the registry), keeping long sessions linear.

## Non-goals

- No change to the balanced summary line format beyond the `interrupted` status word.
- No change to inline rendering mechanics (active entries, flush barrier, scroll).
- No persistence format change beyond no-longer-dropping `tool_execution_start`; old
  files replay through the recovery path with no migration.

## Tests

- `state.zig`: rejected text retained and linked; rejected + later call keep their own
  rows; replay args recovered from `tool_calls_json`; unmatched start finalized as
  interrupted with rewritten row text and cleared markers; persisted start round-trips
  through `saveEvent`; `/clear` clears `state.tools`.
- `views/transcript.zig`: rejected result row renders with the real tool label and no
  wrong-position summary; zero-summary cluster renders no synthetic entry; interrupted
  balanced status word.
- PTY (`scripts/tui-pty-driver.py`): `approval-deny` asserts the readable rejection text
  renders after `n`.
- Guard: measured `tui_loc` 14,885 → 15,693 on this branch (production for the id-link plumbing plus its
  occurrence-scoping and reconciliation extensions over the deleted positional
  machinery, and tests). The #266 guard asked for
  flat-to-shrinking; this PR trades that for the identity model and the five #273
  behaviors, and reports the delta rather than claiming it passes.
