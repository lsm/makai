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
STREAMING_MARKERS = (b"streaming", b"waiting for", b"running")
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


CSI_RE = re.compile(rb"\x1b\[([\x30-\x3f]*)([\x20-\x2f]*)([\x40-\x7e])")


def cell_width(char):
    if not char or unicodedata.combining(char) or unicodedata.category(char) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1


class VtScreen:
    """Minimal VT100/xterm screen model: enough to know which rows the TUI left on screen."""

    def __init__(self, cols, rows):
        self.cols = cols
        self.rows = rows
        self.lines = [self._blank() for _ in range(rows)]
        self.scrollback = []
        self.row = 0
        self.col = 0
        self.top = 0
        self.bottom = rows - 1
        self.pending_wrap = False
        self.saved = (0, 0)
        self.buf = b""

    def _blank(self):
        return [" "] * self.cols

    def feed(self, data):
        self.buf += data
        b = self.buf
        i = 0
        n = len(b)
        while i < n:
            c = b[i]
            if c == 0x1B:
                if i + 1 >= n:
                    break
                nxt = b[i + 1]
                if nxt == 0x5B:
                    m = CSI_RE.match(b, i)
                    if not m:
                        if n - i > 64:
                            i += 2
                            continue
                        break
                    self._csi(m.group(1).decode("latin1"), chr(m.group(3)[0]))
                    i = m.end()
                    continue
                if nxt in (0x5D, 0x50, 0x5F, 0x5E, 0x58):
                    end = -1
                    j = i + 2
                    while j < n:
                        if b[j] == 0x07:
                            end = j + 1
                            break
                        if b[j] == 0x1B and j + 1 < n and b[j + 1] == 0x5C:
                            end = j + 2
                            break
                        j += 1
                    if end < 0:
                        if n - i > 8192:
                            i += 2
                            continue
                        break
                    i = end
                    continue
                if nxt in (0x28, 0x29, 0x2A, 0x2B):
                    i += 3
                    continue
                if nxt == 0x37:
                    self.saved = (self.row, self.col)
                elif nxt == 0x38:
                    self.row, self.col = self.saved
                elif nxt == 0x4D:
                    if self.row == self.top:
                        self._scroll_down(1)
                    elif self.row > 0:
                        self.row -= 1
                elif nxt == 0x44:
                    self._linefeed()
                elif nxt == 0x45:
                    self.col = 0
                    self._linefeed()
                i += 2
                continue
            if c == 0x0D:
                self.col = 0
                self.pending_wrap = False
            elif c in (0x0A, 0x0B, 0x0C):
                self._linefeed()
            elif c == 0x08:
                self.col = max(0, self.col - 1)
                self.pending_wrap = False
            elif c == 0x09:
                self.col = min(self.cols - 1, (self.col // 8 + 1) * 8)
            elif c < 0x20 or c == 0x7F:
                pass
            else:
                length = 1 if c < 0x80 else 2 if c < 0xE0 else 3 if c < 0xF0 else 4
                if i + length > n:
                    break
                self._put(b[i:i + length].decode("utf-8", "replace"))
                i += length
                continue
            i += 1
        self.buf = b[i:]

    def _put(self, char):
        width = cell_width(char)
        if width == 0:
            if self.col > 0:
                self.lines[self.row][self.col - 1] += char
            return
        if self.pending_wrap or self.col + width > self.cols:
            self.col = 0
            self._linefeed()
            self.pending_wrap = False
        line = self.lines[self.row]
        line[self.col] = char
        if width == 2 and self.col + 1 < self.cols:
            line[self.col + 1] = ""
        self.col += width
        if self.col >= self.cols:
            self.col = self.cols - 1
            self.pending_wrap = True

    def _linefeed(self):
        if self.row == self.bottom:
            self._scroll_up(1)
        elif self.row < self.rows - 1:
            self.row += 1
        self.pending_wrap = False

    def _scroll_up(self, count):
        for _ in range(count):
            removed = self.lines.pop(self.top)
            if self.top == 0:
                self.scrollback.append(removed)
            self.lines.insert(self.bottom, self._blank())

    def _scroll_down(self, count):
        for _ in range(count):
            self.lines.pop(self.bottom)
            self.lines.insert(self.top, self._blank())

    def _erase(self, row, start, end):
        line = self.lines[row]
        for index in range(max(0, start), min(self.cols, end)):
            line[index] = " "

    def _csi(self, params, final):
        prefix = ""
        while params and params[0] in "?<>=!":
            prefix += params[0]
            params = params[1:]
        if prefix:
            return
        nums = [int(part) if part.isdigit() else 0 for part in params.split(";")] if params else []

        def arg(index, default=1):
            if index < len(nums) and nums[index] != 0:
                return nums[index]
            return default

        cursor_col = self.col + (1 if self.pending_wrap else 0)
        if final == "A":
            self.row = max(self.top if self.row >= self.top else 0, self.row - arg(0))
            self.pending_wrap = False
        elif final == "B":
            self.row = min(self.bottom if self.row <= self.bottom else self.rows - 1, self.row + arg(0))
            self.pending_wrap = False
        elif final == "C":
            self.col = min(self.cols - 1, self.col + arg(0))
            self.pending_wrap = False
        elif final == "D":
            self.col = max(0, self.col - arg(0))
            self.pending_wrap = False
        elif final == "G":
            self.col = min(self.cols - 1, arg(0) - 1)
            self.pending_wrap = False
        elif final == "d":
            self.row = min(self.rows - 1, arg(0) - 1)
            self.pending_wrap = False
        elif final in ("H", "f"):
            self.row = min(self.rows - 1, arg(0) - 1)
            self.col = min(self.cols - 1, arg(1) - 1)
            self.pending_wrap = False
        elif final == "J":
            mode = nums[0] if nums else 0
            if mode == 0:
                self._erase(self.row, cursor_col, self.cols)
                for row in range(self.row + 1, self.rows):
                    self.lines[row] = self._blank()
            elif mode == 1:
                for row in range(0, self.row):
                    self.lines[row] = self._blank()
                self._erase(self.row, 0, self.col + 1)
            else:
                self.lines = [self._blank() for _ in range(self.rows)]
                if mode == 3:
                    self.scrollback = []
        elif final == "K":
            mode = nums[0] if nums else 0
            if mode == 0:
                self._erase(self.row, cursor_col, self.cols)
            elif mode == 1:
                self._erase(self.row, 0, self.col + 1)
            else:
                self.lines[self.row] = self._blank()
        elif final == "X":
            self._erase(self.row, self.col, self.col + arg(0))
        elif final == "r":
            top = arg(0, 1) - 1
            bottom = arg(1, self.rows) - 1
            if 0 <= top < bottom < self.rows:
                self.top, self.bottom = top, bottom
            else:
                self.top, self.bottom = 0, self.rows - 1
            self.row, self.col = 0, 0
            self.pending_wrap = False
        elif final == "S":
            self._scroll_up(arg(0))
        elif final == "T":
            self._scroll_down(arg(0))
        elif final == "L":
            if self.top <= self.row <= self.bottom:
                for _ in range(arg(0)):
                    self.lines.pop(self.bottom)
                    self.lines.insert(self.row, self._blank())
        elif final == "M":
            if self.top <= self.row <= self.bottom:
                for _ in range(arg(0)):
                    self.lines.pop(self.row)
                    self.lines.insert(self.bottom, self._blank())
        elif final == "s":
            self.saved = (self.row, self.col)
        elif final == "u":
            self.row, self.col = self.saved

    def visible_rows(self):
        return ["".join(line).rstrip() for line in self.lines]

    def all_rows(self):
        return ["".join(line).rstrip() for line in self.scrollback] + self.visible_rows()


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
        self.screen = VtScreen(self.width, self.height)
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
        self.screen.feed(chunk)
        self.answerTerminalProbes(chunk)
        return now

    def screen_rows(self):
        return [row.encode("utf-8") for row in self.screen.all_rows()]

    def screen_text(self):
        return b"\n".join(self.screen_rows())

    def visible_text(self):
        return b"\n".join(row.encode("utf-8") for row in self.screen.visible_rows())

    def wait_visible(self, marker, timeout, what):
        marker = plain_text(marker)
        deadline = time.monotonic() + timeout
        while True:
            if marker in self.visible_text():
                return self.last_read_at
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                tail = self.visible_text()[-400:].decode("utf-8", "replace")
                raise ScenarioError(
                    f"timed out after {timeout}s waiting for {what} ({marker!r}) to be on screen; "
                    f"process alive={self.proc.poll() is None}; screen tail: {tail!r}"
                )
            self._read_once(min(0.05, remaining))

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

    def wait_for(self, marker, timeout, what, since=None):
        marker = plain_text(marker)
        if not marker:
            raise ScenarioError(f"empty marker for {what}")
        search_from = len(self.plain) if since is None else since
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

    def wait_for_any(self, markers, timeout, what):
        candidates = [plain_text(marker) for marker in markers]
        if not candidates or not all(candidates):
            raise ScenarioError(f"empty marker for {what}")
        search_from = len(self.plain)
        deadline = time.monotonic() + timeout
        while True:
            window = self.plain[search_from:]
            for marker in candidates:
                if marker in window:
                    return self.last_read_at
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                tail = self.plain[-400:].decode("ascii", "replace")
                names = ", ".join(repr(marker) for marker in candidates)
                raise ScenarioError(
                    f"timed out after {timeout}s waiting for {what} (any of {names}); "
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

TOOL_OK_GLYPH = "\u2713".encode()
TOOL_FAILED_GLYPH = "\u2717".encode()
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
    if STATUS_BAR_CUT_MARKER in run.session.plain:
        run.note(f"status bar truncated on a whole-segment boundary behind the cut marker ({what})")


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
            "screen": self.session.screen.visible_rows(),
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
        echo_chunks = len(run.session.chunks)
        run.session.send(KEY_ENTER, "Enter (submit two-line draft)")
        run.session.wait_for(b"keys-fixture-reply", 10.0, "reply after two-line submit")
        run.settle()
        echo_raw = b"".join(chunk for _, chunk in run.session.chunks[echo_chunks:])
        first_at = echo_raw.find(b"first line")
        second_at = echo_raw.find(b"second line", first_at + len(b"first line")) if first_at >= 0 else -1
        if first_at < 0 or second_at < 0 or echo_raw.find(b"\r\n", first_at, second_at) < 0:
            raise ScenarioError(
                f"keys: Shift+Enter (kitty CSI 13;2u) did not produce a two-line draft: the submitted "
                f"echo must render 'first line' and 'second line' on separate transcript rows "
                f"(first_at={first_at}, second_at={second_at}, no row break between them)"
            )
        run.note("Shift+Enter (kitty CSI 13;2u) inserts a composer newline: the submitted draft echoes as two transcript rows")

        run.key_wait(KEY_UP, "Up history (latest)", "second line")
        run.key_wait(KEY_UP, "Up history (previous)", "alpha turn three")
        run.key_wait(KEY_DOWN, "Down history (latest)", "second line")
        run.frame("history-recall")

        run.key(KEY_PGUP, "PageUp scroll")
        run.session.wait_visible(b"SCROLL", 5.0, "scroll indicator after PageUp")
        run.frame("paged-up")
        run.key(KEY_PGDN, "PageDown scroll")
        run.settle()
        if b"SCROLL" in run.session.screen_text():
            raise ScenarioError("keys: the scroll indicator stayed on screen after PageDown returned to the tail")
        run.note("PageUp scrolls the inline window over the transcript with a SCROLL indicator; PageDown returns to the tail and clears it")
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

        clear_from = len(run.session.plain)
        run.key(KEY_CTRL_C, "Ctrl+C clears the composer draft")
        if run.session.proc.poll() is not None:
            raise ScenarioError("keys: first Ctrl+C with a draft in the composer must clear it, not exit")
        run.session.type_text("y")
        if plain_text(b"y") not in run.session.plain[clear_from:]:
            raise ScenarioError("keys: composer stopped echoing after Ctrl+C cleared the draft")
        run.session.send(b"\x7f", "Backspace clears the probe")
        run.settle()
        run.session.send(KEY_CTRL_C, "Ctrl+C quit")
        exit_code = run.session.wait_exit(5.0)
        if exit_code != 0:
            raise ScenarioError(f"keys: Ctrl+C exited with code {exit_code}, expected 0")
        run.note("Ctrl+C clears a pending draft first; Ctrl+C on an empty idle composer exits cleanly with code 0")
    except ScenarioError as err:
        run.error = str(err)
    finally:
        run.close()
    return run


# Asserted against the rendered screen rather than the raw byte stream: a
# bottom-anchored frame repaints rows above an insertion too, so "the next
# thing written after a You header" is no longer the entry's own text.
def findUserEntryEcho(session, text):
    needle = plain_text(text.encode())
    rows = session.screen_rows()
    for index, row in enumerate(rows):
        if plain_text(b"You") not in row:
            continue
        for follower in rows[index + 1 : index + 3]:
            if needle in follower:
                return index
    return -1


def scenario_steer_abort(args):
    run = SweepRun(args, "steer-abort", 'hold|tool:shell_execute#{"description":"hold the turn open","workspace_root":"/tmp","command":"sleep 5"}|text:steer-consumed-done')
    try:
        run.session.wait_for(WELCOME_MARKER, args.startup_timeout, "welcome banner")
        run.settle()
        run.frame("welcome")

        run.session.type_text("hold this thought")
        run.session.send(KEY_ENTER, "Enter (submit)")
        run.session.wait_for_any(STREAMING_MARKERS, 10.0, "streaming status after submit")
        run.frame("streaming")

        run.session.type_text("steer this turn")
        run.session.send(KEY_ENTER, "Enter (steer)")
        run.session.wait_for(b"queue", 6.0, "queued steer indicator")
        run.settle()
        run.frame("steer-queued")
        if findUserEntryEcho(run.session, "steer this turn") < 0:
            raise ScenarioError("steer-abort: steered text did not echo into the transcript as a user entry at steer time")
        run.note("Enter while streaming queues the steer and echoes the steered text into the transcript immediately as a 'You' entry, alongside the 'queued 1' composer footer")

        run.session.type_text("/abort")
        abort_from = len(run.session.plain)
        run.session.send(KEY_ENTER, "Enter (/abort)")
        run.session.wait_for(b"Turn aborted.", 6.0, "abort confirmation")
        run.frame("aborted")
        run.settle(1.0)
        rows = run.session.screen_rows()
        aborted_rows = [index for index, row in enumerate(rows) if b"Turn aborted." in row]
        you_rows = [index for index, row in enumerate(rows[:aborted_rows[-1]]) if b"You" in row] if aborted_rows else []
        echo_row = you_rows[-1] + 1 if you_rows else -1
        if not aborted_rows or not you_rows or b"steer this turn" not in rows[echo_row] or aborted_rows[-1] - you_rows[-1] > 8:
            raise ScenarioError("steer-abort: steer echo is not in the transcript directly above the abort row")
        run.note("/abort during a held stream cancels the turn, clears the streaming status, and the flushed history renders the steered text as a permanent 'You' entry directly above the abort row")

        run.session.type_text("run the slow tool")
        run.session.send(KEY_ENTER, "Enter (submit tool turn)")
        run.session.wait_for_any(STREAMING_MARKERS, 10.0, "streaming status after tool submit")
        run.frame("tool-turn-streaming")

        run.session.type_text("steer this turn too")
        run.session.send(KEY_ENTER, "Enter (steer)")
        run.session.wait_for(b"queue", 6.0, "queued steer indicator during tool run")
        run.settle()
        run.frame("tool-steer-queued")
        if findUserEntryEcho(run.session, "steer this turn too") < 0:
            raise ScenarioError("steer-abort: steered text did not echo during the tool run")

        run.session.wait_for(b"steer-consumed-done", 15.0, "turn completion after steer consumption")
        run.settle(1.0)
        run.frame("tool-turn-done")
        done_at = run.session.plain.rfind(plain_text(b"steer-consumed-done"))
        if run.session.plain.find(plain_text(b"queued"), done_at) >= 0:
            raise ScenarioError("steer-abort: queued indicator survived steer consumption")
        if findUserEntryEcho(run.session, "steer this turn too") < 0:
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

        submit_from = len(run.session.plain)
        run.session.type_text("use the tool twice")
        run.session.send(KEY_ENTER, "Enter (submit)")
        run.session.wait_for(b"Approval required", 10.0, "approval view", since=submit_from)
        run.session.wait_for(b"Tool: shell_execute", 5.0, "approval tool name", since=submit_from)
        run.frame("approval-pending")

        deny_from = len(run.session.plain)
        run.session.send(b"n", "deny approval")
        run.session.wait_for(b"Tool execution rejected by user", 6.0, "readable rejection text")
        run.session.wait_for(b"Approval required", 6.0, "second approval view", since=deny_from + 1)
        run.settle()
        run.frame("denied")
        if b"Tool execution rejected by user" not in run.session.screen_text():
            raise ScenarioError("approval-deny: the readable rejection text did not render after 'n'")
        run.note("'n' denies the first approval, the readable rejection text renders, and the agent retries the same tool")

        always_from = len(run.session.plain)
        run.key_wait(b"a", "approve always", "deny-persist-complete")
        run.frame("approved-always")
        final_at = run.session.plain.find(b"deny-persist-complete", always_from)
        if b"Approval required" in run.session.plain[always_from:final_at] or b"Approval required" in run.session.visible_text():
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
        run.session.wait_for(b"Approval required", 10.0, "approval view", since=turn_from)
        run.session.wait_for(b"Tool: workspace_info", 5.0, "approval tool name", since=turn_from)
        run.frame("approval-pending")
        run.key_wait(b"y", "approve once", "allow-path-complete")
        run.settle(0.5)
        run.frame("approved-once")
        shown = run.session.screen_text()
        if b"Workspace Info" not in shown:
            raise ScenarioError("approval-allow: the workspace_info summary row never rendered")
        summary_lines = shown.count(TOOL_OK_GLYPH)
        if summary_lines != 1:
            raise ScenarioError(f"approval-allow: expected exactly one finalized tool summary line on screen, saw {summary_lines}")
        if b'   {"workspace_root"' in shown:
            raise ScenarioError("approval-allow: raw tool-args JSON echoed as a transcript row")
        if TOOL_FAILED_GLYPH in shown:
            raise ScenarioError("approval-allow: the approved workspace_info call rendered as failed")
        if b"project_root" not in shown:
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
            shown = run.session.screen_text()
            rows = shown.split(b"\n")
            reconciled_rows = [row for row in rows if TOOL_OK_GLYPH in row and b"shell_command" in row and b"ls" in row]
            if len(reconciled_rows) != 1:
                raise ScenarioError(f"tool-loss-reconcile: expected exactly one ok summary row for the reconciled tool, saw {len(reconciled_rows)}")
            failed_rows = [row for row in rows if TOOL_FAILED_GLYPH in row and b"failed" in row and b"pwd" in row]
            if len(failed_rows) != 1:
                raise ScenarioError(f"tool-loss-reconcile: expected exactly one failed summary row for the reversed tool, saw {len(failed_rows)}")
            if b"recovered output" not in shown:
                raise ScenarioError("tool-loss-reconcile: the retained result text never rendered under the reconciled row")
            card_count = shown.count(b"failed:")
            if card_count != 1:
                raise ScenarioError(f"tool-loss-reconcile: expected exactly one error card, saw {card_count}")
            if b"Boom" not in shown:
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


def scenario_tool_loss_flush_release(args):
    home = tempfile.mkdtemp(prefix="makai-pty-home-flush-release-")
    try:
        sessions_dir = os.path.join(home, ".makai", "sessions")
        os.makedirs(sessions_dir, exist_ok=True)
        meta = {
            "session_id": "tool-loss-flush-release",
            "model": "claude-sonnet-4-5",
            "provider": "anthropic",
            "last_active": int(time.time() * 1000),
        }
        tool_calls_json = json.dumps([
            {"type": "tool_call", "id": "call-flush-1", "name": "shell_command", "arguments_json": "{\"command\":\"ls\"}"},
        ])
        events = [
            {"type": "message_start", "role": "user"},
            {"type": "message_end", "role": "user", "text": "run the tool then report"},
            {"type": "message_start", "role": "assistant"},
            {"type": "message_end", "role": "assistant", "tool_calls_json": tool_calls_json},
            {"type": "tool_execution_start", "tool_call_id": "call-flush-1", "tool_name": "shell_command", "args_json": "{\"command\":\"ls\"}"},
            {"type": "tool_execution_end", "tool_call_id": "call-flush-1", "tool_name": "shell_command", "result_json": "{\"ok\":true}", "is_error": False},
        ]
        for i in range(30):
            events.append({"type": "message_start", "role": "assistant"})
            events.append({"type": "message_end", "role": "assistant", "text": f"release-row-{i:03d}"})
        events.append({"type": "turn_end", "stop_reason": "stop"})
        events.append({"type": "agent_end", "reason": "completed"})
        with open(os.path.join(sessions_dir, "tool-loss-flush-release.jsonl"), "w") as handle:
            for event in events:
                handle.write(json.dumps({"metadata": meta, "event": event}) + "\n")

        run = SweepRun(args, "tool-loss-flush-release", "loss-probe", home=home)
        try:
            run.session.wait_for(WELCOME_MARKER, args.startup_timeout, "welcome banner")
            run.settle()
            run.command("/resume", SESSION_PICKER_MARKER.decode())
            run.session.send(KEY_ENTER, "Enter (resume flush-release session)")
            run.session.wait_for(b"release-row-029", 10.0, "final replay row")
            run.settle(0.5)
            run.frame("resumed-released")
            shown = run.session.screen_text()
            if b"release-row-000" not in shown:
                raise ScenarioError("tool-loss-flush-release: the end-of-session release never flushed the early rows into scrollback")
            if b"release-row-015" not in shown:
                raise ScenarioError("tool-loss-flush-release: mid-session rows missing from scrollback after the release")
            ok_rows = [row for row in shown.split(b"\n") if TOOL_OK_GLYPH in row and b"shell_command" in row and b"ls" in row]
            if len(ok_rows) != 1:
                raise ScenarioError(f"tool-loss-flush-release: expected exactly one ok summary row for the dropped-result tool, saw {len(ok_rows)}")
            run.note("agent_end retires the execution-only occurrence and the flush releases the held prefix into scrollback")
            run.quit()
        except ScenarioError as err:
            run.error = str(err)
        finally:
            run.close()
            run.dump(os.path.join(args.output_dir, "tool-loss-flush-release"))
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
    "tool-loss-flush-release": scenario_tool_loss_flush_release,
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
            "macOS is rejected: makai reads the login keychain (ai.hyperneo.oap / Codex Auth) "
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
