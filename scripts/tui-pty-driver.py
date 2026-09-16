#!/usr/bin/env python3
# PTY driver for the Makai TUI (#259): launches `makai --tui` inside a
# pseudo-terminal, replays scripted scenarios, captures every rendered byte
# stream with timestamps, and reports a performance baseline. Determinism
# comes from MAKAI_TUI_FIXTURE (see zig/src/tui/fixture_provider.zig): the
# env value is the canned assistant reply, so no API keys or network access
# are involved.
#
# The default `core-loop` scenario (launch -> type prompt -> submit -> stream
# -> /model picker -> /resume picker -> /quit) feeds the performance baseline.
# The UX-sweep scenarios (#264) cover the ratified surface: every slash
# command, every kept key, the approval flow (y/a/n), and a session
# save+resume round-trip. Fixture values for those scenarios use the step
# encoding `text:...|tool:<name>[#<args-json>]|hold|error:...` (see
# FixtureRuntime in zig/src/tui/app.zig); plain values stay a single canned
# reply. A literal `|` or `\` inside a step payload is escaped as `\|` / `\\`.
#
# Usage:
#   zig build install -Doptimize=ReleaseFast --prefix /tmp/makai-pty
#   python3 scripts/tui-pty-driver.py --binary /tmp/makai-pty/bin/makai \
#       --output-dir tui-pty-out
#   python3 scripts/tui-pty-driver.py --binary ... --scenario all
#
# Output: one JSON object on stdout (also written to <output-dir>/metrics.json
# for core-loop), the raw terminal transcript in <output-dir>/transcript.bin,
# one {"t_ms", "bytes"} line per read batch in <output-dir>/batches.jsonl,
# and one {"name", "t_ms", "tail"} checkpoint per named frame in
# <output-dir>/frames.jsonl. With --scenario all, each scenario writes its own
# subdirectory under --output-dir and a summary.json lands at the top level;
# session-roundtrip dumps each half into its own save/ and resume/
# subdirectory so a passing round-trip keeps both transcripts.
# The script exits non-zero when any scenario assertion fails, so CI can gate
# on it. Timings are wall-clock (time.monotonic) and host-dependent: record
# them against a stable host class, like the bench harness baseline.
#
# The driver answers the terminal capability probes the TUI sends at startup
# (mode-2027 DECRQM and the primary device attributes query) so the startup
# metric measures application work, not the probes timing out against a
# non-responsive master. After each timed keypress it drains the remainder of
# that render (until a 20 ms quiet gap) so a frame split across PTY reads can
# never satisfy the next keypress's wait.

import argparse
import base64
import fcntl
import json
import os
import platform
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unicodedata

FIXTURE_ENV_VAR = "MAKAI_TUI_FIXTURE"
WELCOME_MARKER = b"Makai TUI"
MODEL_PICKER_MARKER = b"Select model"
SESSION_PICKER_MARKER = b"Sessions"
READ_CHUNK = 65536
PROBE_CARRY = 16
TERMINAL_PROBE_REPLIES = (
    (b"\x1b[?2027$p", b"\x1b[?2027;2$y"),
    (b"\x1b[c", b"\x1b[?62;9c"),
)
TERMINAL_IDENTIFICATION_VARS = (
    "COLORFGBG",
    "COLORTERM",
    "KITTY_WINDOW_ID",
    "LC_TERMINAL",
    "NO_COLOR",
    "TERM_FEATURES",
    "TERM_PROGRAM",
    "TMUX",
    "ZELLIJ",
    "ZZ_UNICODE_WIDTH",
)
CREDENTIAL_ENV_VARS = (
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "AZURE_OPENAI_API_KEY",
    "GH_COPILOT_ACCESS",
    "GH_COPILOT_REFRESH",
    "GOOGLE_API_KEY",
    "KIMI_API_KEY",
    "OLLAMA_API_KEY",
    "OPENAI_API_KEY",
)

ANSI_RE = re.compile(
    rb"\x1b\[[0-9;?<=>! \-/]*[@-~]"
    rb"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
    rb"|\x1b[PX^_][^\x1b]*\x1b\\"
    rb"|\x1b[@-Z\\-_]"
)
CONTROL_RE = re.compile(rb"[\x00-\x1f\x7f]")
OSC52_RE = re.compile(rb"\x1b\]52;c;([^\x07\x1b]*)(?:\x07|\x1b\\)")


class ScenarioError(Exception):
    pass


def plain_text(chunk):
    stripped = ANSI_RE.sub(b"", chunk)
    return CONTROL_RE.sub(b" ", stripped)


def percentile(sorted_samples, fraction):
    if not sorted_samples:
        return None
    index = max(0, min(len(sorted_samples) - 1, int(round(fraction * (len(sorted_samples) - 1)))))
    return sorted_samples[index]


def median(sorted_samples):
    if not sorted_samples:
        return None
    middle = len(sorted_samples) // 2
    if len(sorted_samples) % 2 == 1:
        return sorted_samples[middle]
    return (sorted_samples[middle - 1] + sorted_samples[middle]) / 2.0


def terminal_cell_width(text):
    width = 0
    for char in text:
        if unicodedata.combining(char):
            continue
        width += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return width


class PtySession:
    def __init__(self, args, fixture_text=None, home=None):
        self.binary = args.binary
        self.width = args.width
        self.height = args.height
        self.fixture_text = args.fixture_text if fixture_text is None else fixture_text
        self.owns_home = home is None
        self.home = home if home is not None else tempfile.mkdtemp(prefix="makai-pty-home-")
        self.chunks = []
        self.plain = b""
        self.first_output_ms = None
        self.last_read_at = time.monotonic()
        self.probe_carry = b""
        self.master = None
        self.proc = None
        try:
            self.master, slave = pty.openpty()
            try:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", self.height, self.width, 0, 0))
                env = dict(os.environ)
                for name in TERMINAL_IDENTIFICATION_VARS:
                    env.pop(name, None)
                for name in CREDENTIAL_ENV_VARS:
                    env.pop(name, None)
                env["HOME"] = self.home
                env["TERM"] = "xterm-256color"
                env[FIXTURE_ENV_VAR] = self.fixture_text
                self.spawned_at = time.monotonic()
                self.proc = subprocess.Popen(
                    [self.binary, "--tui"],
                    stdin=slave,
                    stdout=slave,
                    stderr=slave,
                    start_new_session=True,
                    env=env,
                )
            finally:
                os.close(slave)
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.proc is not None:
            if self.proc.poll() is None:
                self.proc.kill()
            self.proc.wait()
        if self.master is not None:
            try:
                os.close(self.master)
            except OSError:
                pass
            self.master = None
        if self.owns_home:
            shutil.rmtree(self.home, ignore_errors=True)

    def _read_once(self, timeout):
        ready, _, _ = select.select([self.master], [], [], timeout)
        if not ready:
            return None
        try:
            chunk = os.read(self.master, READ_CHUNK)
        except OSError:
            raise ScenarioError("TUI closed the terminal early (process exited)")
        if not chunk:
            raise ScenarioError("TUI closed the terminal early (process exited)")
        now = time.monotonic()
        self.last_read_at = now
        if self.first_output_ms is None:
            self.first_output_ms = (now - self.spawned_at) * 1000.0
        self.chunks.append((now, chunk))
        self.plain += plain_text(chunk)
        self.answerTerminalProbes(chunk)
        return now

    def answerTerminalProbes(self, chunk):
        self.probe_carry = (self.probe_carry + chunk)[-PROBE_CARRY:]
        for probe, reply in TERMINAL_PROBE_REPLIES:
            index = self.probe_carry.find(probe)
            if index < 0:
                continue
            self.probe_carry = self.probe_carry[index + len(probe):]
            try:
                os.write(self.master, reply)
            except OSError as err:
                raise ScenarioError(f"failed to answer terminal probe {probe!r}: {err}")

    def wait_for(self, marker, timeout, what):
        marker = plain_text(marker)
        if not marker:
            raise ScenarioError(f"empty marker for {what}")
        search_from = len(self.plain)
        deadline = time.monotonic() + timeout
        while True:
            if marker in self.plain[search_from:]:
                return self.last_read_at
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                tail = self.plain[-400:].decode("ascii", "replace")
                raise ScenarioError(
                    f"timed out after {timeout}s waiting for {what} ({marker!r}); "
                    f"process alive={self.proc.poll() is None}; plain tail: {tail!r}"
                )
            self._read_once(min(0.05, remaining))

    def wait_next_batch(self, timeout, what, since):
        deadline = since + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ScenarioError(f"timed out after {timeout}s waiting for render after {what}")
            if self._read_once(min(0.05, remaining)) is not None:
                return (self.last_read_at - since) * 1000.0

    def quiesce(self, quiet_seconds, hard_timeout=20.0):
        deadline = time.monotonic() + hard_timeout
        while True:
            if self._read_once(quiet_seconds) is None:
                return
            if time.monotonic() > deadline:
                raise ScenarioError(f"TUI kept rendering for {hard_timeout}s without going quiet")

    def send(self, payload, what):
        try:
            os.write(self.master, payload)
        except OSError as err:
            raise ScenarioError(f"failed to send {what}: {err}")

    def type_text(self, text, measure=False):
        latencies = []
        for char in text:
            sent_at = time.monotonic()
            self.send(char.encode(), f"key {char!r}")
            elapsed = self.wait_next_batch(2.0, f"key {char!r}", since=sent_at)
            self.drain_frame_tail()
            if measure:
                latencies.append(elapsed)
        return latencies

    def drain_frame_tail(self, quiet_seconds=0.02, max_drain_seconds=0.5):
        deadline = time.monotonic() + max_drain_seconds
        while time.monotonic() < deadline:
            if self._read_once(quiet_seconds) is None:
                return

    def wait_exit(self, timeout):
        deadline = time.monotonic() + timeout
        saw_eof = False
        while self.proc.poll() is None and time.monotonic() < deadline:
            try:
                self._read_once(0.05)
            except ScenarioError:
                saw_eof = True
                break
        if saw_eof:
            try:
                self.proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                pass
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
            raise ScenarioError(f"TUI did not exit within {timeout}s")
        return self.proc.returncode


def count_tui_loc(repo_root):
    tui_dir = os.path.join(repo_root, "zig", "src", "tui")
    files = 0
    lines = 0
    for dirpath, _, filenames in os.walk(tui_dir):
        for name in filenames:
            if not name.endswith(".zig"):
                continue
            files += 1
            with open(os.path.join(dirpath, name), "rb") as handle:
                lines += sum(1 for _ in handle)
    return files, lines


def git_revision(repo_root):
    try:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if head.returncode != 0:
            return None
        status = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if status.returncode == 0 and status.stdout.strip():
            return head.stdout.strip() + "-dirty"
        return head.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def run_scenario(args, repo_root):
    check_binary(args.binary)

    try:
        session = PtySession(args)
    except OSError as err:
        raise ScenarioError(f"failed to start {args.binary} in a pseudo-terminal: {err}")
    error = None
    try:
        session.wait_for(WELCOME_MARKER, args.startup_timeout, "first frame (welcome banner)")
        first_frame_ms = (session.last_read_at - session.spawned_at) * 1000.0
        session.quiesce(0.4)

        prompt_echo_from = len(session.plain)
        keypress_ms = session.type_text(args.prompt, measure=True)
        if plain_text(args.prompt.encode()) not in session.plain[prompt_echo_from:]:
            raise ScenarioError("typed prompt did not appear in the composer render")

        submit_sent_at = time.monotonic()
        session.send(b"\r", "Enter (submit)")
        session.wait_for(args.fixture_text.encode(), args.stream_timeout, "fixture reply after submit")
        submit_to_reply_ms = (session.last_read_at - submit_sent_at) * 1000.0
        session.quiesce(1.0)

        session.type_text("/model")
        model_sent_at = time.monotonic()
        session.send(b"\r", "Enter (/model)")
        session.wait_for(MODEL_PICKER_MARKER, 5.0, "model picker")
        model_picker_ms = (session.last_read_at - model_sent_at) * 1000.0
        session.send(b"\x1b", "Escape (close model picker)")
        session.quiesce(0.4)

        session.type_text("/resume")
        resume_sent_at = time.monotonic()
        session.send(b"\r", "Enter (/resume)")
        session.wait_for(SESSION_PICKER_MARKER, 5.0, "session picker")
        session_picker_ms = (session.last_read_at - resume_sent_at) * 1000.0
        session.send(b"\x1b", "Escape (close session picker)")
        session.quiesce(0.4)

        session.type_text("/quit")
        quit_started = time.monotonic()
        session.send(b"\r", "Enter (/quit)")
        exit_code = session.wait_exit(5.0)
        quit_ms = (time.monotonic() - quit_started) * 1000.0
        if exit_code != 0:
            raise ScenarioError(f"TUI exited with code {exit_code}, expected 0")

        sorted_latencies = sorted(keypress_ms)
        tui_files, tui_loc = count_tui_loc(repo_root)
        metrics = {
            "schema": 1,
            "harness": "scripts/tui-pty-driver.py",
            "git_revision": git_revision(repo_root),
            "host": {
                "platform": platform.platform(),
                "machine": platform.machine(),
                "python": platform.python_version(),
            },
            "binary": os.path.abspath(args.binary),
            "binary_size_bytes": os.path.getsize(args.binary),
            "tui_files": tui_files,
            "tui_loc": tui_loc,
            "pty": {"width": args.width, "height": args.height, "term": "xterm-256color"},
            "fixture_text": args.fixture_text,
            "startup": {
                "first_output_ms": round(session.first_output_ms, 3) if session.first_output_ms is not None else None,
                "first_frame_ms": round(first_frame_ms, 3),
            },
            "keypress": {
                "samples": len(sorted_latencies),
                "samples_ms": [round(v, 3) for v in keypress_ms],
                "median_ms": round(median(sorted_latencies), 3) if sorted_latencies else None,
                "p95_ms": round(percentile(sorted_latencies, 0.95), 3) if sorted_latencies else None,
                "max_ms": round(sorted_latencies[-1], 3) if sorted_latencies else None,
            },
            "phases": {
                "submit_to_reply_ms": round(submit_to_reply_ms, 3),
                "model_picker_open_ms": round(model_picker_ms, 3),
                "session_picker_open_ms": round(session_picker_ms, 3),
                "quit_ms": round(quit_ms, 3),
            },
            "exit_code": session.proc.returncode,
        }
    except ScenarioError as err:
        error = err
    finally:
        session.close()
    return session, metrics if error is None else None, error


def check_binary(binary):
    if not os.path.isfile(binary):
        raise ScenarioError(f"binary not found: {binary} (build with: zig build install -Doptimize=ReleaseFast)")


def check_output_dir(output_dir):
    os.makedirs(output_dir, exist_ok=True)
    try:
        probe_fd, probe_path = tempfile.mkstemp(prefix=".write-probe-", dir=output_dir)
        os.close(probe_fd)
        os.unlink(probe_path)
    except OSError as err:
        raise ScenarioError(f"--output-dir is not writable: {output_dir}: {err}") from err


KEY_ENTER = b"\r"
KEY_SHIFT_ENTER_KITTY = b"\x1b[13;2u"
KEY_UP = b"\x1b[A"
KEY_DOWN = b"\x1b[B"
KEY_PGUP = b"\x1b[5~"
KEY_PGDN = b"\x1b[6~"
KEY_ESC = b"\x1b"
KEY_CTRL_C = b"\x03"
KEY_CTRL_T = b"\x14"
KEY_CTRL_Y = b"\x19"
KEY_SHIFT_TAB = b"\x1b[Z"

RATIFIED_COMMANDS = (
    "/help",
    "/model",
    "/login",
    "/provider",
    "/permissions",
    "/resume",
    "/status",
    "/abort",
    "/clear",
    "/quit",
)

STATUS_BAR_ELLIPSIS = b"\xe2\x80\xa6"
STATUS_BAR_CUT_MARKER = b" \xe2\x94\x82 " + STATUS_BAR_ELLIPSIS
STATUS_BAR_PARTIAL_SEGMENTS = (
    b"ctx:" + STATUS_BAR_ELLIPSIS,
    b"perm:" + STATUS_BAR_ELLIPSIS,
    b"perm:bypas" + STATUS_BAR_ELLIPSIS,
    b"think:" + STATUS_BAR_ELLIPSIS,
    b"think:medi" + STATUS_BAR_ELLIPSIS,
    b"think:mediu" + STATUS_BAR_ELLIPSIS,
    b"turns:" + STATUS_BAR_ELLIPSIS,
)


def assert_status_bar_whole_segments(run, what):
    for partial in STATUS_BAR_PARTIAL_SEGMENTS:
        if partial in run.session.plain:
            raise ScenarioError(
                f"keys: status bar rendered partial segment {partial!r} at 100 columns ({what}); "
                "segments must truncate whole (#268)"
            )
    if STATUS_BAR_CUT_MARKER not in run.session.plain:
        raise ScenarioError(
            f"keys: status bar never rendered its ' <sep> {STATUS_BAR_ELLIPSIS.decode()}' cut marker at 100 columns ({what})"
        )


class SweepRun:
    def __init__(self, args, name, fixture_text, width=None, height=None, home=None):
        self.args = args
        self.name = name
        self.notes = []
        self.frames = []
        self.error = None
        self.dump_dir = None
        frame_args = argparse.Namespace(**vars(args))
        if width is not None:
            frame_args.width = width
        if height is not None:
            frame_args.height = height
        try:
            self.session = PtySession(frame_args, fixture_text=fixture_text, home=home)
        except OSError as err:
            raise ScenarioError(f"failed to start {args.binary} in a pseudo-terminal: {err}")

    def note(self, text):
        self.notes.append(text)

    def frame(self, name):
        self.frames.append({
            "name": name,
            "t_ms": round((self.session.last_read_at - self.session.spawned_at) * 1000.0, 3),
            "tail": self.session.plain[-800:].decode("utf-8", "replace"),
        })
        return self.frames[-1]

    def settle(self, secs=0.3):
        self.session.drain_frame_tail(quiet_seconds=secs, max_drain_seconds=secs * 4)

    def command(self, text, marker, timeout=6.0, what=None):
        self.session.type_text(text)
        self.session.send(KEY_ENTER, f"Enter ({text})")
        self.session.wait_for(marker.encode(), timeout, what or f"{text} output")
        self.settle()
        return self.frame(text.strip("/").replace(" ", "-"))

    def key(self, payload, what, timeout=3.0):
        self.session.send(payload, what)
        self.settle(timeout)

    def key_wait(self, payload, what, marker, timeout=6.0):
        self.session.send(payload, what)
        self.session.wait_for(marker.encode(), timeout, what)
        self.settle()
        return self.frame(what)

    def submit(self, prompt, reply_marker, timeout=10.0):
        self.session.type_text(prompt)
        self.session.send(KEY_ENTER, f"Enter (submit {prompt!r})")
        self.session.wait_for(reply_marker.encode(), timeout, f"reply {reply_marker!r}")
        self.settle()

    def seen(self, needle, from_index=0):
        return plain_text(needle.encode()) in self.session.plain[from_index:]

    def try_wait(self, marker, timeout):
        try:
            self.session.wait_for(marker.encode(), timeout, f"optional {marker!r}")
            return True
        except ScenarioError:
            return False

    def assert_clipboard(self, from_chunk, expected, what):
        stream = b"".join(chunk for _, chunk in self.session.chunks[from_chunk:])
        payloads = []
        for match in OSC52_RE.finditer(stream):
            encoded = match.group(1)
            try:
                decoded = base64.b64decode(encoded, validate=True)
            except ValueError as err:
                raise ScenarioError(
                    f"{self.name}: {what} emitted a malformed OSC 52 clipboard payload {encoded!r}: {err}"
                ) from err
            if base64.b64encode(decoded) != encoded:
                raise ScenarioError(
                    f"{self.name}: {what} emitted a non-canonical OSC 52 clipboard payload {encoded!r} "
                    f"(decodes to {decoded!r} but re-encodes to {base64.b64encode(decoded)!r})"
                )
            payloads.append(decoded)
        if payloads != [expected]:
            tail = plain_text(stream[-400:]).decode("ascii", "replace")
            raise ScenarioError(
                f"{self.name}: {what} must emit exactly one OSC 52 clipboard write decoding to {expected!r} "
                f"(saw {payloads!r}); transcript tail: {tail!r}"
            )

    def quit(self):
        self.session.type_text("/quit")
        self.session.send(KEY_ENTER, "Enter (/quit)")
        exit_code = self.session.wait_exit(5.0)
        if exit_code != 0:
            raise ScenarioError(f"{self.name}: TUI exited with code {exit_code}, expected 0")

    def close(self):
        self.session.close()

    def dump(self, output_dir):
        os.makedirs(output_dir, exist_ok=True)
        with open(os.path.join(output_dir, "transcript.bin"), "wb") as handle:
            for _, chunk in self.session.chunks:
                handle.write(chunk)
        with open(os.path.join(output_dir, "batches.jsonl"), "w") as handle:
            for timestamp, chunk in self.session.chunks:
                handle.write(json.dumps({"t_ms": round((timestamp - self.session.spawned_at) * 1000.0, 3), "bytes": len(chunk)}) + "\n")
        with open(os.path.join(output_dir, "frames.jsonl"), "w") as handle:
            for frame in self.frames:
                handle.write(json.dumps(frame) + "\n")
        with open(os.path.join(output_dir, "notes.json"), "w") as handle:
            json.dump({"scenario": self.name, "error": self.error, "notes": self.notes}, handle, indent=2)
            handle.write("\n")


def scenario_commands(args):
    run = SweepRun(args, "commands", "commands-fixture-reply")
    try:
        run.session.wait_for(WELCOME_MARKER, args.startup_timeout, "welcome banner")
        run.settle()
        run.frame("welcome")

        run.session.type_text("/help")
        help_from = len(run.session.plain)
        run.session.send(KEY_ENTER, "Enter (/help)")
        run.session.wait_for(b"Available commands:", 6.0, "/help output")
        run.settle()
        run.frame("help")
        help_text = run.session.plain[help_from:].decode("utf-8", "replace")
        for usage in RATIFIED_COMMANDS:
            if usage not in help_text:
                raise ScenarioError(f"commands: /help output does not list {usage}")
        run.note(f"/help lists all {len(RATIFIED_COMMANDS)} ratified commands")

        status_from = len(run.session.plain)
        run.command("/status", "session:")
        field_positions = []
        for field in ("session:", "model:", "provider:", "turns:", "context:", "streaming:"):
            position = run.session.plain.find(plain_text(field.encode()), status_from)
            if position < 0:
                raise ScenarioError(f"commands: /status output missing {field!r}")
            field_positions.append(position)
        if field_positions != sorted(field_positions) or field_positions[-1] - field_positions[0] > 6 * (args.width + 8):
            raise ScenarioError("commands: /status fields did not render as one contiguous status block")

        run.command("/provider", "current provider:")
        if not run.seen("available providers:"):
            raise ScenarioError("commands: /provider output missing available providers list")

        run.command("/model", "Select model")
        run.key(KEY_ESC, "Escape closes model picker")
        picker_closed_from = len(run.session.plain)
        run.session.type_text("zz")
        if not run.seen("zz", picker_closed_from):
            raise ScenarioError("commands: composer input not restored after Escape closed the model picker")
        run.session.send(b"\x7f\x7f", "Backspace clears the echo probe")
        run.settle()
        run.command("/model claude-sonnet-4-5", "model switched to claude-sonnet-4-5")

        run.command("/login", "Login provider")
        run.key(KEY_ESC, "Escape closes login picker")

        run.command("/permissions", "Tool permissions")
        run.key(KEY_ESC, "Escape closes permission picker")
        run.command("/permissions ask", "permission mode set to ask")
        run.command("/permissions frobnicate", "unknown permission mode: frobnicate")
        run.command("/permissions bypass", "permission mode set to bypass")

        run.command("/resume", "no saved sessions")
        run.command("/abort", "Nothing to abort")
        run.command("/bogus", "unknown command: /bogus")
        run.command("/clear", "transcript cleared")

        run.quit()
    except ScenarioError as err:
        run.error = str(err)
    finally:
        run.close()
    return run


def scenario_keys(args):
    run = SweepRun(args, "keys", "keys-fixture-reply", width=100, height=15)
    run.note("status bar truncates on whole-segment boundaries at 100 columns (#268): trailing segments drop cleanly behind an ellipsis marker and no segment renders half-word; think/turns sit at the tail, so the Shift+Tab level cycle itself is covered by unit tests rather than a visible marker")
    try:
        run.session.wait_for(WELCOME_MARKER, args.startup_timeout, "welcome banner")
        run.settle()
        run.frame("welcome")

        run.submit("alpha turn one", "keys-fixture-reply")
        run.submit("alpha turn two", "keys-fixture-reply")
        run.submit("alpha turn three", "keys-fixture-reply")
        run.frame("three-turns")
        assert_status_bar_whole_segments(run, "three turns in")

        copy_from = len(run.session.plain)
        copy_chunks = len(run.session.chunks)
        run.key(KEY_CTRL_Y, "Ctrl+Y copy last reply")
        run.assert_clipboard(copy_chunks, b"keys-fixture-reply", "Ctrl+Y copy last reply")
        if run.seen("copied last reply to clipboard", copy_from):
            run.note("Ctrl+Y with a reply present writes the reply via an OSC 52 clipboard sequence (exactly one write, asserted against the raw stream) and appends 'copied last reply to clipboard' to the transcript")
        else:
            run.note("FINDING: Ctrl+Y wrote the asserted OSC 52 clipboard payload but the transcript lacks the 'copied last reply to clipboard' status line")

        run.session.type_text("first line")
        run.key(KEY_SHIFT_ENTER_KITTY, "Shift+Enter (kitty encoding)")
        run.session.type_text("second line")
        run.settle()
        run.frame("shift-enter-draft")
        echo_from = len(run.session.plain)
        run.session.send(KEY_ENTER, "Enter (submit two-line draft)")
        run.session.wait_for(b"keys-fixture-reply", 10.0, "reply after two-line submit")
        run.settle()
        echo = run.session.plain[echo_from:]
        row_gap = run.session.width // 2
        first_at = echo.find(plain_text(b"first line"))
        second_at = echo.find(plain_text(b"second line"), first_at + len(b"first line"))
        if first_at < 0 or second_at < 0 or second_at - first_at < row_gap:
            gap = second_at - first_at if second_at >= 0 else None
            raise ScenarioError(
                f"keys: Shift+Enter (kitty CSI 13;2u) did not produce a two-line draft: the submitted "
                f"echo must render 'first line' and 'second line' on separate transcript rows "
                f"(first_at={first_at}, second_at={second_at}, gap={gap}, need at least {row_gap})"
            )
        run.note("Shift+Enter (kitty CSI 13;2u) inserts a composer newline: the submitted draft echoes as two transcript rows")

        run.key_wait(KEY_UP, "Up history (latest)", "second line")
        run.key_wait(KEY_UP, "Up history (previous)", "alpha turn three")
        run.key_wait(KEY_DOWN, "Down history (latest)", "second line")
        run.frame("history-recall")

        pgup_from = len(run.session.plain)
        run.key(KEY_PGUP, "PageUp scroll")
        if run.seen("SCROLL", pgup_from):
            run.note("PageUp shows a scroll indicator")
        else:
            run.note("FINDING: PgUp has no visible effect — the transcript SCROLL indicator renders only in the non-TTY fallback view path; in a real terminal history is flushed inline and transcript_scroll is never read, so terminal-native scrollback is the only scroll")
        run.key(KEY_PGDN, "PageDown scroll")
        run.frame("after-paging")

        run.key(KEY_CTRL_T, "Ctrl+T expand latest tool")
        run.note("FINDING: Ctrl+T (ratified keep-list: expand latest tool) is unbound in the TUI — 4ed8207 dropped the handler and trim 6/6 recorded it as already absent")
        alive_from = len(run.session.plain)
        run.session.type_text("z")
        run.settle()
        if plain_text(b"z") not in run.session.plain[alive_from:]:
            raise ScenarioError("keys: TUI stopped echoing after Ctrl+T (input loop wedged)")

        run.key(KEY_SHIFT_TAB, "Shift+Tab thinking level")
        run.key(KEY_SHIFT_TAB, "Shift+Tab thinking level again")
        run.frame("thinking-cycled")
        assert_status_bar_whole_segments(run, "after thinking cycle")

        run.session.send(KEY_CTRL_C, "Ctrl+C quit")
        exit_code = run.session.wait_exit(5.0)
        if exit_code != 0:
            raise ScenarioError(f"keys: Ctrl+C exited with code {exit_code}, expected 0")
        run.note("Ctrl+C exits cleanly with code 0")
    except ScenarioError as err:
        run.error = str(err)
    finally:
        run.close()
    return run


def findUserEntryEcho(plain, text, from_index):
    needle = plain_text(text.encode())
    header = plain_text(b"You")
    search_from = from_index
    while True:
        header_at = plain.find(header, search_from)
        if header_at < 0:
            return -1
        text_at = plain.find(needle, header_at)
        if text_at >= 0 and text_at - header_at <= 160:
            return text_at
        search_from = header_at + len(header)


def scenario_steer_abort(args):
    run = SweepRun(args, "steer-abort", 'hold|tool:shell_execute#{"description":"hold the turn open","workspace_root":"/tmp","command":"sleep 5"}|text:steer-consumed-done')
    try:
        run.session.wait_for(WELCOME_MARKER, args.startup_timeout, "welcome banner")
        run.settle()
        run.frame("welcome")

        run.session.type_text("hold this thought")
        run.session.send(KEY_ENTER, "Enter (submit)")
        run.session.wait_for(b"streaming", 10.0, "streaming status after submit")
        run.frame("streaming")

        run.session.type_text("steer this turn")
        echo_from = len(run.session.plain)
        run.session.send(KEY_ENTER, "Enter (steer)")
        run.session.wait_for(b"queue", 6.0, "queued steer indicator")
        run.settle()
        run.frame("steer-queued")
        if findUserEntryEcho(run.session.plain, "steer this turn", echo_from) < 0:
            raise ScenarioError("steer-abort: steered text did not echo into the transcript as a user entry at steer time")
        run.note("Enter while streaming queues the steer and echoes the steered text into the transcript immediately as a 'You' entry, alongside the 'queued 1' composer footer")

        run.session.type_text("/abort")
        abort_from = len(run.session.plain)
        run.session.send(KEY_ENTER, "Enter (/abort)")
        run.session.wait_for(b"Turn aborted.", 6.0, "abort confirmation")
        run.frame("aborted")
        run.settle(1.0)
        aborted_at = run.session.plain.find(plain_text(b"Turn aborted."), abort_from)
        you_at = run.session.plain.rfind(plain_text(b"You"), abort_from, aborted_at)
        echo_at = run.session.plain.find(plain_text(b"steer this turn"), you_at)
        if aborted_at < 0 or you_at < 0 or echo_at < 0 or echo_at - you_at > 160 or echo_at >= aborted_at or aborted_at - you_at > 600:
            raise ScenarioError("steer-abort: steer echo did not flush into transcript history adjacent to the abort row")
        run.note("/abort during a held stream cancels the turn, clears the streaming status, and the flushed history renders the steered text as a permanent 'You' entry directly above the abort row")

        run.session.type_text("run the slow tool")
        run.session.send(KEY_ENTER, "Enter (submit tool turn)")
        run.session.wait_for(b"streaming", 10.0, "streaming status after tool submit")
        run.frame("tool-turn-streaming")

        run.session.type_text("steer this turn too")
        tool_echo_from = len(run.session.plain)
        run.session.send(KEY_ENTER, "Enter (steer)")
        run.session.wait_for(b"queue", 6.0, "queued steer indicator during tool run")
        run.settle()
        run.frame("tool-steer-queued")
        if findUserEntryEcho(run.session.plain, "steer this turn too", tool_echo_from) < 0:
            raise ScenarioError("steer-abort: steered text did not echo during the tool run")

        run.session.wait_for(b"steer-consumed-done", 15.0, "turn completion after steer consumption")
        run.settle(1.0)
        run.frame("tool-turn-done")
        done_at = run.session.plain.rfind(plain_text(b"steer-consumed-done"))
        if run.session.plain.find(plain_text(b"queued"), done_at) >= 0:
            raise ScenarioError("steer-abort: queued indicator survived steer consumption")
        if findUserEntryEcho(run.session.plain, "steer this turn too", tool_echo_from) < 0:
            raise ScenarioError("steer-abort: steered text echo vanished after consumption")
        run.note("a steer queued during a tool run is consumed when the tool finishes: the queue indicator clears, the turn completes, and the echoed steered text stays rendered exactly as echoed (runtime-declared consumption reconciles pending steers even when consumption events never reach the app)")

        run.quit()
    except ScenarioError as err:
        run.error = str(err)
    finally:
        run.close()
    return run


WORKSPACE_INFO_ARGS = '{"workspace_root":"/tmp"}'


def scenario_approval_deny(args):
    tool_step = 'tool:shell_execute#{"command":"true --pty-probe"}'
    run = SweepRun(args, "approval-deny", tool_step + "|" + tool_step + "|" + tool_step + "|text:deny-persist-complete")
    try:
        run.session.wait_for(WELCOME_MARKER, args.startup_timeout, "welcome banner")
        run.settle()
        run.command("/permissions ask", "permission mode set to ask")

        run.session.type_text("use the tool twice")
        run.session.send(KEY_ENTER, "Enter (submit)")
        run.session.wait_for(b"Approval required", 10.0, "approval view")
        run.session.wait_for(b"Tool: shell_execute", 5.0, "approval tool name")
        run.frame("approval-pending")

        deny_from = len(run.session.plain)
        run.key_wait(b"n", "deny approval", "Approval required")
        run.frame("denied")
        if b"Tool execution rejected by user" not in run.session.plain[deny_from:]:
            raise ScenarioError("approval-deny: the readable rejection text did not render after 'n'")
        run.note("'n' denies the first approval, the readable rejection text renders, and the agent retries the same tool")

        always_from = len(run.session.plain)
        run.key_wait(b"a", "approve always", "deny-persist-complete")
        run.frame("approved-always")
        final_at = run.session.plain.find(b"deny-persist-complete", always_from)
        if b"Approval required" in run.session.plain[always_from:final_at]:
            raise ScenarioError("approval-deny: the third matching tool call prompted again although 'a' approved always")
        run.note("'a' approves always for a persistable shell call: the third shell_execute runs with no new approval prompt and the turn completes")
    except ScenarioError as err:
        run.error = str(err)
    finally:
        run.close()
    return run


def scenario_approval_allow(args):
    run = SweepRun(args, "approval-allow", 'tool:workspace_info#' + WORKSPACE_INFO_ARGS + "|text:allow-path-complete")
    try:
        run.session.wait_for(WELCOME_MARKER, args.startup_timeout, "welcome banner")
        run.settle()
        run.command("/permissions ask", "permission mode set to ask")

        turn_from = len(run.session.plain)
        run.session.type_text("run workspace info")
        run.session.send(KEY_ENTER, "Enter (submit)")
        run.session.wait_for(b"Approval required", 10.0, "approval view")
        run.session.wait_for(b"Tool: workspace_info", 5.0, "approval tool name")
        run.frame("approval-pending")
        run.key_wait(b"y", "approve once", "allow-path-complete")
        run.settle(0.5)
        run.frame("approved-once")
        turn_plain = run.session.plain[turn_from:]
        summary_lines = turn_plain.count(b"Workspace Info ok")
        if summary_lines != 1:
            raise ScenarioError(f"approval-allow: expected exactly one finalized tool summary line, saw {summary_lines}")
        if b'   {"workspace_root"' in turn_plain:
            raise ScenarioError("approval-allow: raw tool-args JSON echoed as a transcript row")
        if b"Workspace Info failed" in turn_plain:
            raise ScenarioError("approval-allow: the approved workspace_info call rendered as failed")
        if b"project_root" not in turn_plain:
            raise ScenarioError("approval-allow: workspace_info result text missing from the transcript")
        run.note("'y' approves once: workspace_info executes as one summary line plus its result block, and the turn completes")
    except ScenarioError as err:
        run.error = str(err)
    finally:
        run.close()
    return run


def scenario_tool_loss_reconcile(args):
    home = tempfile.mkdtemp(prefix="makai-pty-home-tool-loss-")
    try:
        sessions_dir = os.path.join(home, ".makai", "sessions")
        os.makedirs(sessions_dir, exist_ok=True)
        meta = {
            "session_id": "tool-loss-reconcile",
            "model": "claude-sonnet-4-5",
            "provider": "anthropic",
            "last_active": int(time.time() * 1000),
        }
        tool_calls_json = json.dumps([
            {"type": "tool_call", "id": "call-loss-1", "name": "shell_command", "arguments_json": "{\"command\":\"ls\"}"},
            {"type": "tool_call", "id": "call-loss-2", "name": "shell_command", "arguments_json": "{\"command\":\"pwd\"}"},
        ])
        events = [
            {"type": "message_start", "role": "user"},
            {"type": "message_end", "role": "user", "text": "run both tools"},
            {"type": "message_start", "role": "assistant"},
            {"type": "message_end", "role": "assistant", "tool_calls_json": tool_calls_json},
            {"type": "tool_execution_start", "tool_call_id": "call-loss-1", "tool_name": "shell_command", "args_json": "{\"command\":\"ls\"}"},
            {"type": "turn_end", "stop_reason": "stop"},
            {"type": "message_start", "role": "tool_result"},
            {"type": "message_end", "role": "tool_result", "tool_call_id": "call-loss-1", "tool_name": "shell_command", "text": "recovered output", "details_json": "{\"ok\":true}", "is_error": False},
            {"type": "message_start", "role": "tool_result"},
            {"type": "message_end", "role": "tool_result", "tool_call_id": "call-loss-2", "tool_name": "shell_command", "text": "Tool execution failed: Boom", "details_json": "{\"ok\":false,\"err\":\"Boom\"}", "is_error": True},
            {"type": "tool_execution_end", "tool_call_id": "call-loss-2", "tool_name": "shell_command", "result_json": "{\"ok\":false,\"err\":\"Boom\"}", "is_error": True},
            {"type": "turn_end", "stop_reason": "stop"},
            {"type": "agent_end", "reason": "completed"},
        ]
        with open(os.path.join(sessions_dir, "tool-loss-reconcile.jsonl"), "w") as handle:
            for event in events:
                handle.write(json.dumps({"metadata": meta, "event": event}) + "\n")

        run = SweepRun(args, "tool-loss-reconcile", "loss-probe", home=home)
        try:
            run.session.wait_for(WELCOME_MARKER, args.startup_timeout, "welcome banner")
            run.settle()
            run.command("/resume", SESSION_PICKER_MARKER.decode())
            run.session.send(KEY_ENTER, "Enter (resume tool-loss session)")
            run.session.wait_for(b"Boom", 10.0, "reversed failing tool error card")
            run.settle(0.5)
            run.frame("resumed-reconciled")
            if plain_text(b"interrupted") in run.session.plain:
                raise ScenarioError("tool-loss-reconcile: scrollback still shows the interrupted placeholder after reconciliation")
            scrollback = run.session.plain
            reconciled_ok = plain_text(b" ok ") in scrollback or plain_text(b"[ok") in scrollback
            if not reconciled_ok:
                raise ScenarioError("tool-loss-reconcile: reconciled tool never rendered its ok summary row")
            failed_row = plain_text(b" failed ") in scrollback or plain_text(b"[failed") in scrollback
            if not failed_row:
                raise ScenarioError("tool-loss-reconcile: reversed failing tool never rendered its failed summary row")
            card_count = scrollback.count(plain_text(b"failed:"))
            if card_count < 1:
                raise ScenarioError("tool-loss-reconcile: the reconciled error card never rendered")
            if plain_text(b"Boom") not in scrollback:
                raise ScenarioError("tool-loss-reconcile: error detail Boom missing from the error card")
            run.note("withheld end reconciled from retained result; reversed failing result merged with a single error card")
            run.quit()
        except ScenarioError as err:
            run.error = str(err)
        finally:
            run.close()
            run.dump(os.path.join(args.output_dir, "tool-loss-reconcile"))
        return run
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_session_roundtrip(args):
    home = tempfile.mkdtemp(prefix="makai-pty-home-roundtrip-")
    save_dir = os.path.join(args.output_dir, "session-roundtrip", "save")
    resume_dir = os.path.join(args.output_dir, "session-roundtrip", "resume")
    shutil.rmtree(os.path.join(args.output_dir, "session-roundtrip"), ignore_errors=True)
    try:
        first = SweepRun(args, "session-roundtrip-save", "roundtrip-reply-alpha", home=home)
        first.dump_dir = save_dir
        try:
            first.session.wait_for(WELCOME_MARKER, args.startup_timeout, "welcome banner (run 1)")
            first.settle()
            first.submit("remember the alpha", "roundtrip-reply-alpha")
            first.frame("saved-turn")
            first.quit()
        except ScenarioError as err:
            first.error = str(err)
        finally:
            first.close()
            first.dump(save_dir)
        if first.error is not None:
            return first

        second = SweepRun(args, "session-roundtrip-resume", "roundtrip-reply-beta", home=home)
        second.dump_dir = resume_dir
        try:
            second.session.wait_for(WELCOME_MARKER, args.startup_timeout, "welcome banner (run 2)")
            second.settle()
            picker_from = len(second.session.plain)
            second.command("/resume", "Sessions")
            picker_row = f"claude-sonnet-4-5 anthropic {time.gmtime().tm_year}"
            if not second.seen(picker_row, picker_from):
                raise ScenarioError("session-roundtrip: picker row does not show the saved model and provider")
            second.frame("session-picker")

            second.session.send(KEY_ENTER, "Enter (resume session)")
            second.session.wait_for(b"roundtrip-reply-alpha", 10.0, "restored transcript reply")
            second.frame("resumed")
            second.note("saved session round-trips: /resume lists it and Enter replays the saved assistant reply")
            second.quit()
        except ScenarioError as err:
            second.error = str(err)
        finally:
            second.close()
    finally:
        shutil.rmtree(home, ignore_errors=True)
    return second


SCENARIOS = {
    "core-loop": None,
    "commands": scenario_commands,
    "keys": scenario_keys,
    "steer-abort": scenario_steer_abort,
    "approval-deny": scenario_approval_deny,
    "approval-allow": scenario_approval_allow,
    "session-roundtrip": scenario_session_roundtrip,
    "tool-loss-reconcile": scenario_tool_loss_reconcile,
}


def validate_core_loop_args(parser, args):
    if not args.fixture_text:
        parser.error("--fixture-text must be non-empty: an empty MAKAI_TUI_FIXTURE disables fixture mode in the TUI and would let a submit reach real providers")
    if args.fixture_text.startswith(("text:", "tool:", "error:")) or args.fixture_text == "hold":
        parser.error("--fixture-text must be a plain reply, not the scenario step encoding (text:/tool:/hold/error:): core-loop asserts the literal value, which a parsed step never emits verbatim")
    if any(ord(char) < 32 or 0x7F <= ord(char) <= 0x9F for char in args.prompt):
        parser.error("--prompt must be printable single-line text: control characters would be sent to the TUI as terminal input")
    if args.fixture_text in args.prompt or args.prompt in args.fixture_text:
        parser.error("--prompt and --fixture-text must not contain each other: the submitted prompt is echoed to the transcript before the assistant reply streams, so overlapping values cannot distinguish the reply render")
    if any(ord(char) < 32 or 0x7F <= ord(char) <= 0x9F for char in args.fixture_text):
        parser.error("--fixture-text must be printable single-line text: the transcript renderer strips C0/C1 controls and wraps multiline replies, so markers containing them can never match")
    if not args.fixture_text.strip():
        parser.error("--fixture-text must contain non-whitespace text: layout padding makes whitespace-only markers match before any reply renders")
    if args.fixture_text != args.fixture_text.strip():
        parser.error("--fixture-text must not have leading or trailing whitespace: trimmed rendering breaks marker contiguity")
    if args.fixture_text.startswith(("```", "~~~")):
        parser.error("--fixture-text must not open a code fence: the transcript renderer hides fence lines, so the marker can never appear")
    if not args.prompt.strip():
        parser.error("--prompt must contain non-whitespace text: whitespace-only input submits nothing")
    if args.prompt.lstrip().startswith("/"):
        parser.error("--prompt must not start with '/': the TUI dispatches slash-prefixed input as a command, so no provider turn is submitted")
    body_cell_cap = min(args.width, 106) - 8
    if terminal_cell_width(args.fixture_text) > body_cell_cap or terminal_cell_width(args.prompt) > body_cell_cap:
        parser.error(f"--fixture-text and --prompt must each fit one rendered transcript row (at most {body_cell_cap} terminal cells at --width {args.width}; the transcript caps and wraps rows near 106 columns regardless of terminal width): wrapping inserts layout between fragments the marker cannot match")


def dump_core_loop(output_dir, session):
    os.makedirs(output_dir, exist_ok=True)
    with open(os.path.join(output_dir, "transcript.bin"), "wb") as handle:
        for _, chunk in session.chunks:
            handle.write(chunk)
    with open(os.path.join(output_dir, "batches.jsonl"), "w") as handle:
        for timestamp, chunk in session.chunks:
            handle.write(json.dumps({"t_ms": round((timestamp - session.spawned_at) * 1000.0, 3), "bytes": len(chunk)}) + "\n")


def run_core_loop(args, repo_root):
    session = None
    metrics = None
    error = None
    try:
        session, metrics, error = run_scenario(args, repo_root)
    except ScenarioError as err:
        error = err

    if session is not None:
        dump_core_loop(args.output_dir, session)

    if error is not None:
        if session is not None:
            failure = {
                "schema": 1,
                "harness": "scripts/tui-pty-driver.py",
                "git_revision": git_revision(repo_root),
                "error": str(error),
                "exit_code": session.proc.returncode,
            }
            with open(os.path.join(args.output_dir, "metrics.json"), "w") as handle:
                json.dump(failure, handle, indent=2)
                handle.write("\n")
        return error

    with open(os.path.join(args.output_dir, "metrics.json"), "w") as handle:
        json.dump(metrics, handle, indent=2)
        handle.write("\n")

    print(json.dumps(metrics, indent=2))
    print(
        f"tui-pty-driver: OK startup={metrics['startup']['first_frame_ms']}ms "
        f"keypress-median={metrics['keypress']['median_ms']}ms "
        f"keypress-p95={metrics['keypress']['p95_ms']}ms",
        file=sys.stderr,
    )
    return None


def run_sweep_scenario(args, repo_root, name):
    runner = SCENARIOS[name]
    try:
        run = runner(args)
        output_dir = run.dump_dir or os.path.join(args.output_dir, name)
        run.dump(output_dir)
        if run.error is not None:
            return {"scenario": name, "result": "fail", "error": run.error, "frames": len(run.frames), "notes": run.notes, "output_dir": output_dir}
        return {
            "scenario": name,
            "result": "pass",
            "frames": len(run.frames),
            "notes": run.notes,
            "output_dir": output_dir,
        }
    except (ScenarioError, OSError) as err:
        return {"scenario": name, "result": "fail", "error": str(err), "notes": []}


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description="Drive the Makai TUI through a pseudo-terminal and measure it.")
    parser.add_argument("--binary", default=os.path.join(repo_root, "zig-out", "bin", "makai"))
    parser.add_argument("--output-dir", default="tui-pty-out")
    parser.add_argument("--width", type=int, default=100)
    parser.add_argument("--height", type=int, default=30)
    parser.add_argument("--prompt", default="the quick brown fox")
    parser.add_argument("--fixture-text", default="pty-fixture-reply")
    parser.add_argument("--scenario", default="core-loop", choices=list(SCENARIOS) + ["all"])
    parser.add_argument("--startup-timeout", type=float, default=15.0)
    parser.add_argument("--stream-timeout", type=float, default=15.0)
    args = parser.parse_args()
    if sys.platform == "darwin":
        parser.error(
            "macOS is rejected: makai reads the login keychain (com.makai.auth / Codex Auth) "
            "regardless of HOME, so this driver cannot isolate a credential-free run there "
            "(issue #263 tracks a file-only auth mode); run on Linux/CI"
        )
    try:
        check_binary(args.binary)
        check_output_dir(args.output_dir)
    except (ScenarioError, OSError) as err:
        print(f"tui-pty-driver: FAIL: {err}", file=sys.stderr)
        return 1

    if args.scenario == "core-loop":
        validate_core_loop_args(parser, args)
        error = run_core_loop(args, repo_root)
        if error is not None:
            print(f"tui-pty-driver: FAIL: {error}", file=sys.stderr)
            return 1
        return 0

    names = [name for name in SCENARIOS if name != "core-loop"] if args.scenario == "all" else [args.scenario]
    if args.scenario == "all":
        validate_core_loop_args(parser, args)
        core_error = run_core_loop(args, repo_root)
        if core_error is not None:
            print(f"tui-pty-driver: FAIL: core-loop: {core_error}", file=sys.stderr)
            return 1

    results = []
    for name in names:
        result = run_sweep_scenario(args, repo_root, name)
        results.append(result)
        status = "OK" if result["result"] == "pass" else f"FAIL: {result.get('error', '')}"
        print(f"tui-pty-driver: {name}: {status}", file=sys.stderr)

    summary = {
        "schema": 1,
        "harness": "scripts/tui-pty-driver.py",
        "scenario": args.scenario,
        "git_revision": git_revision(repo_root),
        "results": results,
    }
    with open(os.path.join(args.output_dir, "summary.json"), "w") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")

    failures = [r for r in results if r["result"] == "fail"]
    if failures:
        return 1
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main())
