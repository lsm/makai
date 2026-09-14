#!/usr/bin/env python3
# PTY driver for the Makai TUI (#259): launches `makai --tui` inside a
# pseudo-terminal, replays the core-loop scenario (launch -> type prompt ->
# submit -> stream -> /model picker -> /resume picker -> /quit), captures
# every rendered byte stream with timestamps, and reports a performance
# baseline. Determinism comes from MAKAI_TUI_FIXTURE (see
# zig/src/tui/fixture_provider.zig): the env value is the canned assistant
# reply, so no API keys or network access are involved.
#
# Usage:
#   zig build install -Doptimize=ReleaseFast --prefix /tmp/makai-pty
#   python3 scripts/tui-pty-driver.py --binary /tmp/makai-pty/bin/makai \
#       --output-dir tui-pty-out
#
# Output: one JSON object on stdout (also written to <output-dir>/metrics.json),
# the raw terminal transcript in <output-dir>/transcript.bin, and one
# {"t_ms", "bytes"} line per read batch in <output-dir>/batches.jsonl.
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

ANSI_RE = re.compile(
    rb"\x1b\[[0-9;?<=>! \-/]*[@-~]"
    rb"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
    rb"|\x1b[PX^_][^\x1b]*\x1b\\"
    rb"|\x1b[@-Z\\-_]"
)
CONTROL_RE = re.compile(rb"[\x00-\x1f\x7f]")


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


class PtySession:
    def __init__(self, args):
        self.binary = args.binary
        self.width = args.width
        self.height = args.height
        self.fixture_text = args.fixture_text
        self.home = tempfile.mkdtemp(prefix="makai-pty-home-")
        self.chunks = []
        self.plain = b""
        self.first_output_ms = None
        self.last_read_at = time.monotonic()
        self.probe_carry = b""
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", self.height, self.width, 0, 0))
        env = dict(os.environ)
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
        os.close(slave)

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        try:
            os.close(self.master)
        except OSError:
            pass
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
            if probe in self.probe_carry:
                try:
                    os.write(self.master, reply)
                except OSError as err:
                    raise ScenarioError(f"failed to answer terminal probe {probe!r}: {err}")

    def wait_for(self, marker, timeout, what):
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

    def wait_next_batch(self, timeout, what):
        deadline = time.monotonic() + timeout
        start = time.monotonic()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ScenarioError(f"timed out after {timeout}s waiting for render after {what}")
            if self._read_once(min(0.05, remaining)) is not None:
                return (time.monotonic() - start) * 1000.0

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
            self.send(char.encode(), f"key {char!r}")
            elapsed = self.wait_next_batch(2.0, f"key {char!r}")
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
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def run_scenario(args, repo_root):
    if not os.path.isfile(args.binary):
        raise ScenarioError(f"binary not found: {args.binary} (build with: zig build install -Doptimize=ReleaseFast)")

    session = PtySession(args)
    error = None
    try:
        session.wait_for(WELCOME_MARKER, args.startup_timeout, "first frame (welcome banner)")
        first_frame_ms = (session.last_read_at - session.spawned_at) * 1000.0
        session.quiesce(0.4)

        keypress_ms = session.type_text(args.prompt, measure=True)
        if args.prompt.encode() not in session.plain:
            raise ScenarioError("typed prompt did not appear in the composer render")

        session.send(b"\r", "Enter (submit)")
        submit_sent_at = time.monotonic()
        session.wait_for(args.fixture_text.encode(), args.stream_timeout, "fixture reply after submit")
        submit_to_reply_ms = (session.last_read_at - submit_sent_at) * 1000.0
        session.quiesce(1.0)

        session.type_text("/model")
        session.send(b"\r", "Enter (/model)")
        model_sent_at = time.monotonic()
        session.wait_for(MODEL_PICKER_MARKER, 5.0, "model picker")
        model_picker_ms = (session.last_read_at - model_sent_at) * 1000.0
        session.send(b"\x1b", "Escape (close model picker)")
        session.quiesce(0.4)

        session.type_text("/resume")
        session.send(b"\r", "Enter (/resume)")
        resume_sent_at = time.monotonic()
        session.wait_for(SESSION_PICKER_MARKER, 5.0, "session picker")
        session_picker_ms = (session.last_read_at - resume_sent_at) * 1000.0
        session.send(b"\x1b", "Escape (close session picker)")
        session.quiesce(0.4)

        session.type_text("/quit")
        session.send(b"\r", "Enter (/quit)")
        quit_started = time.monotonic()
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
                "median_ms": round(percentile(sorted_latencies, 0.5), 3) if sorted_latencies else None,
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


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description="Drive the Makai TUI through a pseudo-terminal and measure it.")
    parser.add_argument("--binary", default=os.path.join(repo_root, "zig-out", "bin", "makai"))
    parser.add_argument("--output-dir", default="tui-pty-out")
    parser.add_argument("--width", type=int, default=100)
    parser.add_argument("--height", type=int, default=30)
    parser.add_argument("--prompt", default="the quick brown fox")
    parser.add_argument("--fixture-text", default="pty-fixture-reply")
    parser.add_argument("--startup-timeout", type=float, default=15.0)
    parser.add_argument("--stream-timeout", type=float, default=15.0)
    args = parser.parse_args()

    session = None
    metrics = None
    error = None
    try:
        session, metrics, error = run_scenario(args, repo_root)
    except ScenarioError as err:
        error = err

    if session is not None:
        os.makedirs(args.output_dir, exist_ok=True)
        with open(os.path.join(args.output_dir, "transcript.bin"), "wb") as handle:
            for _, chunk in session.chunks:
                handle.write(chunk)
        with open(os.path.join(args.output_dir, "batches.jsonl"), "w") as handle:
            for timestamp, chunk in session.chunks:
                handle.write(json.dumps({"t_ms": round((timestamp - session.spawned_at) * 1000.0, 3), "bytes": len(chunk)}) + "\n")

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
        print(f"tui-pty-driver: FAIL: {error}", file=sys.stderr)
        return 1

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
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main())
