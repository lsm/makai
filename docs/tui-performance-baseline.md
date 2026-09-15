# TUI PTY harness and performance baseline

`scripts/tui-pty-driver.py` drives the real `makai --tui` binary inside a
pseudo-terminal and measures it. It exists so every TUI polish or bug PR can
replay the same scripted session and compare numbers against a recorded
baseline, the same way `zig build bench` guards the streaming core (see
[performance-baseline.md](performance-baseline.md)).

## Deterministic fixture provider

The scenario must not depend on API keys or network access. When the
`MAKAI_TUI_FIXTURE` environment variable is set to a non-empty value, the TUI
entry point (`zig/src/tui/app.zig` `run()`) swaps the production provider
protocol client for the fixture provider in `zig/src/tui/fixture_provider.zig`:
every submitted turn streams the env value back as the assistant reply. The
driver rejects an empty `--fixture-text` for the same reason: an empty value
disables fixture mode inside the TUI and would let a submit reach real
providers. It also rejects degenerate marker values before launching:
non-printable, whitespace-only, leading/trailing-whitespace, or fence-opening
(````` ``` `````, `~~~`) fixture text — the renderer hides fence lines and
trims/pads rows, so such markers can never match or match too early — and
fixture or prompt text wider than one rendered transcript row (the
transcript caps and wraps rows near 106 columns regardless of the terminal
width). A `--prompt` that overlaps the fixture text is rejected because the
submitted prompt is echoed to the transcript before the reply streams, and a
slash-prefixed or whitespace-only prompt is rejected because the TUI would
dispatch it as a command (or nothing) instead of submitting a provider turn.
The driver also points `HOME` at a throwaway directory so session
storage, config, and credential stores start empty, and drops inherited
terminal-identification variables (`TERM_PROGRAM`, `TMUX`, `KITTY_WINDOW_ID`,
`TERM_FEATURES`, …) so the TUI's capability probing matches the declared
`TERM=xterm-256color` instead of the developer's outer terminal.

## Scenario

The default `core-loop` scenario (the perf baseline) is: launch → wait for the
welcome frame → type a prompt one keystroke at a time (recording
keypress-to-render latency per key) → Enter (submit) → wait for the fixture
reply to render → `/model` (model picker opens) → Escape → `/resume` (session
picker opens) → Escape → `/quit` (process exits with status 0). Each wait is an
assertion: the driver exits non-zero if any marker fails to appear, so the
scenario doubles as a regression gate.

## UX-sweep scenarios

`--scenario all` additionally runs the #264 UX-sweep scenarios, each in its own
subdirectory with `transcript.bin`, `batches.jsonl`, `frames.jsonl` (named
ANSI-stripped screen checkpoints), and `notes.json` (observed findings):

- `commands` — every ratified slash command: `/help` (asserts all ten usage
  strings render), `/status`, `/provider`, `/model` (picker + explicit switch),
  `/login` (picker, escape without triggering a real OAuth flow), `/permissions`
  (picker + `ask`/`bypass`/invalid-arg), `/resume` on an empty store, `/abort`
  while idle, an unknown command, `/clear`, `/quit`.
- `keys` — the kept keys: Ctrl+Y copy (asserts the raw stream carries an
  `OSC 52 ; c` clipboard sequence whose base64 payload decodes to the last
  reply; a malformed payload is itself a failure), Shift+Enter (kitty
  `CSI 13;2u` encoding) composer newline (asserted positively: the submitted
  draft must echo as two separate transcript rows), Up/Down history recall,
  PgUp/PgDn, Ctrl+T, Shift+Tab thinking cycle (status `think:` segment),
  Ctrl+C exit.
- `steer-abort` — a `hold` fixture step keeps the stream open so Enter mid-turn
  steers (queue indicator) and `/abort` cancels.
- `approval-deny` — `ask` mode + a tool fixture step: the approval view
  renders, `n` denies and the agent retries, `a` approves always and the tool
  runs.
- `approval-allow` — `y` approves once and the tool runs.
- `session-roundtrip` — two runs share one `HOME`: the first saves a session,
  the second lists it via `/resume` and replays the saved transcript; each half
  dumps its own artifacts under `session-roundtrip/save/` and
  `session-roundtrip/resume/`.

These scenarios use the fixture step encoding, which extends the plain
canned-reply value: `|`-separated steps `text:<body>`, `tool:<name>` or
`tool:<name>#<args-json>` (args default to `{}`), `hold` (block until
cancelled — for steer/abort coverage), and `error:<message>`. A literal `|`
or `\` inside a step payload (common in shell tool arguments) is escaped as
`\|` / `\\`. A value whose first segment carries no step prefix stays a single
text reply, so existing `MAKAI_TUI_FIXTURE` usage is unchanged.

## Metric definitions

All timings are wall-clock (`time.monotonic`) measured at the PTY master:

- `startup.first_output_ms` — process spawn to the first output byte batch.
- `startup.first_frame_ms` — process spawn to the first frame whose rendered
  plaintext contains the welcome banner (`Makai TUI`). The driver answers the
  TUI's startup capability probes (mode-2027 and primary device attributes)
  so this measures application work rather than queries timing out against a
  non-responsive terminal.
- `keypress.samples_ms` / `median_ms` / `p95_ms` — one sample per typed
  character: the sample clock starts immediately before the byte is written
  to the PTY and stops at the read of the first output batch of that key's
  render, so a render that completes between the write and the wait loop can
  never be excluded from the sample; the remainder of the frame is then
  drained (20 ms quiet gap) before the next key is sent, so a frame split
  across PTY reads cannot satisfy the next key's wait. The TUI renders only
  when the view changes and drains events on a 50 ms tick, so this measures
  perceived echo latency including tick coalescing, not just paint time.
- `phases.submit_to_reply_ms` — Enter on the prompt to the fixture reply
  appearing in the rendered transcript.
- `phases.model_picker_open_ms`, `phases.session_picker_open_ms` — Enter on the
  command to the picker title rendering.
- `phases.quit_ms` — Enter on `/quit` to process exit.
- `binary_size_bytes` — size of the measured `makai` binary.
- `tui_files`, `tui_loc` — `.zig` files and total lines under `zig/src/tui/`.

Artifacts per run: `metrics.json` (also printed to stdout), `transcript.bin`
(raw terminal bytes), `batches.jsonl` (one `{"t_ms", "bytes"}` line per read
batch); with `--scenario all`, a `summary.json` plus one subdirectory per
scenario (its own transcript/batches plus `frames.jsonl` and `notes.json`).

## Running it

```bash
zig build install -Doptimize=ReleaseFast --prefix /tmp/makai-pty
python3 scripts/tui-pty-driver.py --binary /tmp/makai-pty/bin/makai --output-dir tui-pty-out
python3 scripts/tui-pty-driver.py --binary /tmp/makai-pty/bin/makai --output-dir tui-pty-out --scenario all
```

CI runs the `--scenario all` invocation in the `TUI PTY Harness` job on every
pull request and records `metrics.json` and `summary.json` in the job summary
and run artifacts.

Timings are host-class dependent. Record baselines against a stable host class
(`github-ubuntu-latest` for the CI numbers) and re-measure before drawing
conclusions from a delta; single-run outliers on shared runners are common.
`tui_loc` is exact and host-independent. The binary size is exact for a given
target and build configuration (the table row names the CI's
`x86_64-linux` ReleaseFast build); comparing sizes across OSes or
architectures measures the target difference, not a TUI change.

## Baseline

The table below records the first CI-captured baseline of this harness. Each
row names the exact source revision and host class it was measured on.

| Revision | Host | Startup→first frame | Keypress median / p95 | Binary | tui/ LOC |
| --- | --- | --- | --- | --- | --- |
| `755325d` (PR #262, final harness semantics) | github `ubuntu-latest` (Linux 6.17 azure x86_64) | 51.1 ms | 13.2 / 13.5 ms | 21,262,152 B | 14,617 (22 files) |

Same run, phase timings: submit→fixture-reply 46.7 ms, `/model` picker open
13.4 ms, `/resume` picker open 13.3 ms, `/quit`→exit 13.0 ms. For comparison,
before the driver answered the TUI's startup capability probes, first-frame
was 457 ms — roughly 370 ms of that was the mode-2027 and primary-device-
attributes queries timing out against a non-responsive master, not
application work. Raw numbers for every run are in the `TUI PTY Harness` job
summary and artifacts (`tui-pty-harness`).
