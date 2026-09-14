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
driver also points `HOME` at a throwaway directory so session storage, config,
and credential stores start empty and the run leaves no state behind.

## Scenario

Launch → wait for the welcome frame → type a prompt one keystroke at a time
(recording keypress-to-render latency per key) → Enter (submit) → wait for the
fixture reply to render → `/model` (model picker opens) → Escape → `/resume`
(session picker opens) → Escape → `/quit` (process exits with status 0). Each
wait is an assertion: the driver exits non-zero if any marker fails to appear,
so the scenario doubles as a regression gate.

## Metric definitions

All timings are wall-clock (`time.monotonic`) measured at the PTY master:

- `startup.first_output_ms` — process spawn to the first output byte batch.
- `startup.first_frame_ms` — process spawn to the first frame whose rendered
  plaintext contains the welcome banner (`Makai TUI`). The driver answers the
  TUI's startup capability probes (mode-2027 and primary device attributes)
  so this measures application work rather than queries timing out against a
  non-responsive terminal.
- `keypress.samples_ms` / `median_ms` / `p95_ms` — one sample per typed
  character: the moment the byte is written to the PTY until the first output
  batch of that key's render arrives; the remainder of the frame is then
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
batch).

## Running it

```bash
zig build install -Doptimize=ReleaseFast --prefix /tmp/makai-pty
python3 scripts/tui-pty-driver.py --binary /tmp/makai-pty/bin/makai --output-dir tui-pty-out
```

CI runs the same command in the `TUI PTY Harness` job on every pull request
and records `metrics.json` in the job summary and run artifacts.

Timings are host-class dependent. Record baselines against a stable host class
(`github-ubuntu-latest` for the CI numbers) and re-measure before drawing
conclusions from a delta; single-run outliers on shared runners are common.
The binary size and `tui_loc` figures are exact and host-independent.

## Baseline

The table below records the first CI-captured baseline of this harness. Each
row names the exact source revision and host class it was measured on.

| Revision | Host | Startup→first frame | Keypress median / p95 | Binary | tui/ LOC |
| --- | --- | --- | --- | --- | --- |
| _(recorded from the PR introducing this file; see its CI `TUI PTY Harness` job and PR body)_ | | | | | |
