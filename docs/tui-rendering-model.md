# TUI rendering model

Date: 2026-09-15. Describes how `makai --tui` paints the terminal after the inline
renderer rewrite, what each layer owns, and the invariants tests and future changes
must keep. The previous scroll-region design (bottom-anchored frame plus DECSTBM
history insertion) is gone; this document replaces the implicit contract it had.

## Why it changed

The old inline path (`zigzag` `Program.render` with `inline_bottom_viewport`) anchored
the live frame at the bottom of the screen and, when the frame shrank, drew the new
frame at the *old* top row while clearing below it. The next paint anchored at the
bottom again, so a stale copy of the frame stayed on screen above the live one. The
app then inserted flushed history into a scroll region above the frame, which
scrolled the stale copy into scrollback. Closing the model picker was enough to
trigger it, and every turn left a stale composer/status pair in the terminal
history. Frame growth also overwrote visible history rows because the renderer never
scrolled the terminal before drawing a taller frame.

## Layers

### `zigzag` Program (vendored, `zig/vendor/zigzag/src/core/program.zig`)

`Options.inline_bottom_viewport = true` now means **cursor-relative inline live
region**, the same model Bubble Tea's standard renderer and Ink's `<Static>` use:

- The Program tracks `last_line_count`, the number of rows the live frame currently
  occupies. The cursor rests on the frame's last row after every paint.
- A paint moves to the top of the live region (`CUU last_line_count-1`, `CR`), writes
  any queued print-above text, then the frame, then `ED 0` (erase below) so a shorter
  frame leaves nothing behind. Rows are written with `\r\n`; when the cursor is on the
  bottom row the terminal scrolls naturally, which is how history reaches scrollback.
- The Program keeps the previous frame's rows. When nothing was printed above and the
  live region has not moved, a row identical to the one already on screen is skipped
  with a bare line feed instead of being rewritten (the last row is always rewritten,
  since `ED 0` precedes it). A spinner tick therefore costs one or two rows rather
  than a whole screen, and modal panels are emitted once, not on every animation
  frame — this is what keeps the PTY harness's "no second approval prompt" assertion
  meaningful.
- Frame lines are clamped to the terminal width (ANSI-aware) so an over-wide line can
  never wrap and desynchronise the row count. A frame taller than the terminal keeps
  its tail. `EL 0` is only emitted after lines narrower than the terminal: some
  terminals (xterm) erase the last column when `EL` runs from the pending-wrap
  position, which used to eat the right border of full-width panels.
- `Context.printAbove(text)` queues persistent lines. They are written on the next
  paint, above the frame, inside the same synchronized-output block, so a transcript
  entry that moves from the live frame into history never visibly moves.
- `Context.requestClearScreen()` clears the screen and scrollback (`ED 2`, `ED 3`)
  before the next paint and resets the live region. `Cmd.println` routes through
  `printAbove` in inline mode; a full-screen program (`inline_bottom_viewport = false`)
  keeps the immediate cursor-save/home/restore write, since its render path never
  drains the print-above queue.
- Quitting erases the live region with the same reflow-aware row estimate the resize
  relayout uses (`last_line_widths` against the current width), so a `/quit` that lands
  inside the 150 ms resize debounce still clears every row the terminal rewrapped the
  old frame into instead of counting on the pre-resize row count.
- Resize is debounced (150 ms after the last `SIGWINCH`; nothing is painted while a
  resize is pending, because terminals reflow the old rows and a cursor-relative
  repaint would land in the wrong place). When it fires the Program performs a
  relayout inside one synchronized-output block: it moves to the top of the old live
  region, erases it, writes any print-above text that was queued during the debounce
  window, scrolls the whole screen into scrollback with `height` line feeds, homes the
  cursor and resets the live region. Before that it dispatches `window_size` to the
  model, and the app answers by rewinding its flush cursor so the frame itself carries
  the tail of the transcript at the new width; the screen is repainted from the top as
  `[history tail][frame]` with the status line back on the bottom row and no blank rows
  pushed into scrollback — at most one screenful of pre-resize output is duplicated in
  scrollback per resize gesture.
- The top of the old live region is estimated for reflowing terminals (iTerm2,
  Terminal.app, Kitty, VS Code, tmux rewrap hard lines when the window narrows): the
  Program remembers the ink width of every painted row (trailing padding excluded) and
  counts `ceil(width / new_width)` rows per line. Terminals differ on whether written
  trailing spaces rewrap, so the estimate deliberately ignores them: undercounting
  leaves an invisible blank row in scrollback, overcounting would erase real history.
- When the program exits in inline mode it erases the live region and drains queued
  print-above text, leaving only the transcript in the terminal followed by the shell
  prompt on a fresh line. The real cursor is hidden; the composer draws its own caret.

`Context.deinit()` frees the print-above buffer; anything that builds a `Context` by
hand (tests) must call it.

**The TUI owns the terminal.** The renderer tracks the cursor by counting the rows it
wrote; any other write to the terminal shifts the cursor and every later paint lands
in the wrong place (and, since paints rewrite only changed rows, stale rows of an
earlier frame stay on screen). One stray line printed from the end of a full-width
status row costs two rows: the wrap plus the newline. `tui_app.run` therefore
redirects fd 2 to `~/.makai/tui-stderr.log` (append, mode 0600; `/dev/null` when the
home directory is unavailable) for the whole session and restores it on exit, so
`std.debug.print`/`std.log` output from libraries — the OAuth token exchange warns
this way — is recorded instead of drawn. Never write to stdout or stderr from TUI
code paths; add a transcript row instead.

### App (`zig/src/tui/app.zig`)

- `TuiModel.render_mode`: `.auto` (inline when a terminal is attached, full-transcript
  otherwise), `.inline_history` (forced, used by the e2e driver), `.full_transcript`.
- The transcript is treated as a **row stream**: each entry renders to a block of rows
  (a blank separator row for detached entries, none between consecutive tool rows,
  then the entry's rows). `App.inline_history_flushed` is the index of the first entry
  with unflushed rows and `App.inline_flushed_rows` is how many rows of that block are
  already in scrollback, so flushing is row-granular. Rows go to scrollback (via
  `printAbove`) only when the unflushed stream overflows the **flush budget**, the rows
  left on screen once the blank separator, composer and status line are subtracted —
  and never from active entries (assistant, thinking, tool summary, tool result, user
  echo). Quitting flushes everything, including active entries.
- The live frame is the **tail of the unflushed stream** that fits above the chrome,
  followed by a blank row, the modal panel (approval, picker, command palette) if any,
  the composer and the status line. The frame is therefore bottom-anchored once the
  transcript fills the screen: opening a modal covers the tail of the history instead
  of scrolling it into scrollback (the flush budget ignores modals, so covered rows
  are never flushed), and closing it repaints the same rows with the composer back on
  the bottom row. Because scrollback rows plus frame rows are always a prefix of the
  stream, the terminal never shows a duplicated or missing row. The frame is padded
  with blank rows at the top to exactly `height`, so it is bottom-anchored from the
  first paint rather than only once the transcript fills the screen: without the
  padding a short transcript left the frame the height of its own content and the
  status line sat wherever the shell cursor happened to be, with the rest of the
  viewport blank below it. The cost is that content growth shifts every row up, so a
  paint that adds a transcript row rewrites the whole frame instead of only the rows
  below the insertion; a paint that changes no heights (a spinner tick) still rewrites
  only what changed, because rows keep their index.
- Active entries render with `live = true` (spinner, caret, tail-clipped thinking, the
  "waiting for <model>" line when streaming with nothing active); inactive rows render
  identically whether painted in the frame or flushed above it.
- On `window_size` the app rewinds the flush cursor so the unflushed stream fills the
  flush budget at the new width; the Program's relayout then paints that window from
  the top of the cleared screen.
- `/clear` empties the transcript, resets the flush index and requests a screen
  clear; the "transcript cleared" row is the first thing printed afterwards.

### State (`zig/src/tui/state.zig`)

- `TranscriptKind.welcome` renders the start banner. `active_thinking_entry` tracks
  streamed reasoning; a thinking block that starts while the assistant placeholder is
  still empty is inserted **before** the placeholder so reasoning precedes the answer.
- `StatusState.streaming_since_ms` / `streaming_elapsed_ms` drive the elapsed timer in
  the status line (the app refreshes the elapsed value every tick).
- `ComposerState` gained word/line editing: `moveCursorWordPrev/Next`,
  `deleteWordBeforeCursor`, `deleteToLineStart/End`, `deleteAtCursor`.

## Visual language (`zig/src/tui/theme.zig`, `views/`)

- Entries: one-space gutter, role glyph and name in the role colour, dim `· HH:MM`
  timestamp, body indented three columns and capped at 108 columns. User text is a
  left-aligned soft block; assistant prose gets inline styling (bold, italic, code
  spans), bullets, numbered lists, headings, block quotes, and fenced code blocks with
  a language tag — all applied to rows *after* the #254 sanitizer and wrapper, one
  self-contained styled row at a time. `renderAssistantPlain` remains the unstyled
  wrap engine and its exact-output tests are unchanged.
- Tool calls: one row, `◆ Label  argument` on the left, status on the right
  (`⠋ running`, `◌ awaiting approval`, `✓ 342B · ~87 tok`, `✗ failed`,
  `■ interrupted`). Result rows render as dim `⎿` lines capped at eight rows. The row
  text still comes from `state.zig` (`◈ Label "arg" ok output=NB …`); the renderer
  parses it, so the persisted-tool-call model of #273 is unchanged.
- Live assistant entries show a spinner in the header and a caret after the last
  character. Thinking shows dim italic text, tail-clipped while live.
- System rows: a short single-line note renders as one muted `•` row. Anything longer
  or multi-line (the OAuth login prompt, restore summaries) renders under a `System`
  header and is **wrapped, never truncated** — over-long tokens are hard-broken at the
  column limit. URL tokens become OSC 8 hyperlinks: every visible fragment of a wrapped
  URL carries the full target and a shared `id=`, so terminals that support OSC 8
  (iTerm2, Kitty, WezTerm, Ghostty, VS Code, Windows Terminal, VTE) treat the pieces
  as one clickable link, and each fragment opens and closes its link inside its own
  row so the renderer's row-diff paints never leak link state into other rows.
- Composer: rounded panel whose border colour tracks state (idle grey, typing accent,
  streaming pulse, approval warning, login magenta). Typing `/` opens a command palette
  above it; `Tab` completes the first match.
- Status line: `provider/model`, context gauge, state (`idle` or spinner + elapsed),
  queue, permission, cost (once tokens are known), thinking level, turns, and a
  right-aligned key hint. Segments truncate whole; the hint outranks the trailing
  segments but never the first three, and is dropped entirely when even that does not
  fit.

## Credentials and the model catalog

- Credentials stay in the macOS keychain (item label "makai credentials", service
  `ai.hyperneo.oap`, account `auth.shared.json`; the pre-existing `auth.json` item is
  migrated on first read). Keychain access lists are bound to the accessing app's
  signing identity: a Developer ID signed release is identified by its team ID, so
  "Always Allow" persists across updates, whereas an unsigned local build is identified
  by its code hash and every new build is a new application to securityd (a
  `partition_id` entry it adds for non-Apple-signed apps enforces this even when the
  ACL lists no applications). Expect one login-password prompt per new dev binary;
  identical rebuilds do not re-prompt. `MAKAI_KEYCHAIN_SERVICE` overrides the service
  name so tests can use an isolated item; the 0600 `~/.makai/auth.json` file remains
  the fallback only when the keychain is unavailable.
- `/login` shows each provider's state: `✓ logged in` (OAuth), `✓ api key` (stored key),
  `✓ env key` (key in the environment), or `expired · login again`. The state is read
  when the picker opens and after a login completes; when stored auth cannot be loaded
  (no `HOME`, unreadable or malformed store) the environment scan still runs, so an
  `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` user sees `✓ env key` rather than nothing.
- The model catalog lists Anthropic models whenever Anthropic credentials exist
  (OAuth in storage or `ANTHROPIC_API_KEY`): it fetches `/v1/models` with the stored
  token, caches the response under `~/.makai/model_catalog/anthropic.json`, and falls
  back to a static Claude list when the fetch fails. A cached response is reused at
  startup for 24 hours; after that startup fetches again and only falls back to the
  stale copy when the fetch fails, and `/model` always fetches. Prices come from a
  small table keyed by model prefix; for an unknown model the status bar hides the cost
  instead of guessing a rate. Dated aliases of the default model are folded into it,
  and the fold keeps the catalog entry's limits (max output tokens, context window,
  reasoning flag, and price when known) on the default entry, so the built-in fallback's
  conservative `max_tokens` only applies when no catalog entry matched.
- Tool rows take their status (`running`, `✓`, `✗ failed`, `■ interrupted`) from the
  linked `ToolEntry`, never from words in the row text; the status word written into
  the row is parsed only for rows without a live link (a resumed session's transcript),
  and that parse skips the known label so a tool named "Deployment failed checks" is
  not read as failed.

## Keys

`Enter` send (steer while streaming), `Shift+Enter` newline, `Esc` clear draft →
abort turn → close modal, `Ctrl+C` abort/clear first and quit on a second press
within ~1.5 s (immediate quit when idle with an empty composer), `Ctrl+D` quit on an
empty idle composer, `Tab` complete a slash command, `Ctrl+Y` copy the last reply,
`Shift+Tab` cycle thinking, `Up/Down` history, `PgUp/PgDn` (and the mouse wheel when
mouse reporting is on) scroll the live window over the whole transcript row stream,
`Ctrl+A/E` home/end, `Ctrl+U/K` cut to line start/end, `Ctrl+W` / `Alt+Backspace`
delete word, `Ctrl+Left/Right`, `Alt+Left/Right`, `Alt+B/F` word moves, `Delete`.

Scrolling: while `transcript_scroll` is non-zero the inline body is a window over the
full transcript rendered at the current width (rows already flushed into terminal
scrollback are re-rendered inside the window while it is scrolled), topped by a
`↑ SCROLL n% · PgDn to return` row. The offset is clamped to the rows above the tail
and written back, so paging past the top and then back down returns in one step;
submitting anything, resizing, or `/clear` snaps the window back to the tail. Key
updates do not reset the offset, so paging is not undone by the flush that follows
every update.

## Testing

- Unit tests build a real `zz.Context` (`TestContext` in `app.zig`) instead of passing
  `undefined`; the e2e driver runs in `.inline_history` mode and concatenates drained
  print-above text with the live view, so it exercises the production path.
- `scripts/tui-pty-driver.py` (Linux CI) drives the real binary. Because the renderer
  only rewrites rows that changed, the byte stream no longer carries a copy of the
  screen on every paint, so the harness feeds every chunk into a small VT screen model
  (`VtScreen`: cursor movement, erase, scroll regions, wrap, scrollback) and makes
  row-level assertions against `screen_text()` / `visible_text()` — "exactly one
  finalized tool row", "the steer echo sits directly above the abort row", "no approval
  panel on screen after `a`". Stream-based `wait_for` remains for *new* output and
  takes `since=` when two markers arrive in the same paint. Every recorded frame also
  stores the visible rows. The fixture provider accepts `<think>…</think>` at the start
  of a `text:` step to emit reasoning deltas.
