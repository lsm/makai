#!/usr/bin/env python3
# Black-box conformance driver for `makai --stdio` (the protocol host).
#
# The host reads newline-delimited JSON envelopes on stdin and writes them on
# stdout, routing by envelope shape into the auth, provider, and agent protocol
# servers (see runStdioMode in zig/src/tools/makai.zig). This driver spawns the
# real binary and checks its observable behavior against the normative rules in
# DESIGN.md sections 4-5 and docs/v1-sdk-agent-provider-spec.md section 13.
#
# No API keys or network access are needed: every check here is answered by
# envelope validation, sequencing, session lifecycle, or framing, all of which
# happen before any provider call. Checks that would require a live provider
# are deliberately absent.
#
# Usage:
#   zig build install --prefix /tmp/makai-stdio-test
#   python3 scripts/stdio-conformance.py --binary /tmp/makai-stdio-test/bin/makai
#   python3 scripts/stdio-conformance.py --group envelope --verbose
#   python3 scripts/stdio-conformance.py --json > report.json
#
# Exit status is 0 when every check passes and 1 when any check fails, so the
# driver doubles as a regression gate. Checks tagged `info` record a behavior
# the spec does not pin down; they never affect exit status.
#
# Each check runs in its own `makai --stdio` process because several of the
# behaviors under test are process-fatal.
#
# macOS note: an unsigned build reads the login Keychain through an ACL prompt
# that never renders for a non-interactive process, so any frame that reaches
# credential storage (a valid auth_providers_request, an admitted agent run)
# blocks on the host's pump thread. Checks that can reach that path report
# `info` instead of failing.

import argparse
import json
import os
import queue
import random
import string
import subprocess
import sys
import threading
import time

CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
NANOID_ALPHABET = string.ascii_letters + string.digits

# ULID timestamps are 48 bits, so the leading Crockford digit never exceeds 7.
ULID_LEAD = "01234567"

DEFAULT_BINARY_CANDIDATES = (
    os.environ.get("MAKAI_BINARY_PATH", ""),
    "zig-out/bin/makai",
    "zig/zig-out/bin/makai",
    "/tmp/makai-stdio-test/bin/makai",
)

MODEL_REF = "anthropic/anthropic-messages@claude-sonnet-4-5"


def ulid():
    return random.choice(ULID_LEAD) + "".join(random.choice(CROCKFORD) for _ in range(25))


def nanoid():
    return "".join(random.choice(NANOID_ALPHABET) for _ in range(21))


def agent_frame(kind, session_id, sequence, payload, message_id=None, **extra):
    frame = {
        "type": kind,
        "session_id": session_id,
        "message_id": message_id or ulid(),
        "sequence": sequence,
        "timestamp": int(time.time() * 1000),
        "version": 1,
        "payload": payload,
    }
    frame.update(extra)
    return frame


def provider_frame(kind, stream_id, sequence, payload, message_id=None, **extra):
    frame = {
        "type": kind,
        "stream_id": stream_id,
        "message_id": message_id or ulid(),
        "sequence": sequence,
        "timestamp": int(time.time() * 1000),
        "version": 1,
        "payload": payload,
    }
    frame.update(extra)
    return frame


def auth_frame(kind, stream_id, sequence, payload, message_id=None, **extra):
    return provider_frame(kind, stream_id, sequence, payload, message_id, **extra)


def start_payload(session_id, model_ref=MODEL_REF):
    return {
        "session_id": session_id,
        "resume_session_id": session_id,
        "config_json": json.dumps({"model_ref": model_ref, "tools": []}),
    }


def message_payload(session_id, text="hello", model_ref=MODEL_REF):
    return {
        "session_id": session_id,
        "message_json": json.dumps({
            "model_ref": model_ref,
            "messages": [{"role": "user", "content": text}],
            "tools": [],
        }),
    }


class Host:
    """One `makai --stdio` process with a background stdout reader."""

    def __init__(self, binary, env=None):
        child_env = dict(os.environ)
        if env:
            child_env.update(env)
        self.proc = subprocess.Popen(
            [binary, "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=child_env,
            bufsize=0,
        )
        self.lines = []
        self.stderr_lines = []
        self._queue = queue.Queue()
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        fd = self.proc.stdout.fileno()
        buffered = b""
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                self._queue.put(None)
                return
            buffered += chunk
            while b"\n" in buffered:
                raw, buffered = buffered.split(b"\n", 1)
                text = raw.decode("utf-8", "replace").strip()
                if text:
                    self.lines.append(text)
                    self._queue.put(text)

    def _read_stderr(self):
        for raw in self.proc.stderr:
            self.stderr_lines.append(raw.decode("utf-8", "replace").rstrip())

    def write_bytes(self, data):
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def send(self, frame):
        self.write_bytes((json.dumps(frame) + "\n").encode())

    def next_frame(self, timeout=3.0):
        """Next stdout frame, None on timeout, the string EOF when stdout closes."""
        try:
            line = self._queue.get(timeout=timeout)
        except queue.Empty:
            return None
        if line is None:
            return "EOF"
        try:
            return json.loads(line)
        except ValueError:
            return {"__unparsed__": line}

    def exchange(self, frame, timeout=3.0, quiet=0.7):
        """Send one frame and gather every reply until the host goes quiet."""
        self.send(frame)
        return self.drain(timeout=timeout, quiet=quiet)

    def drain(self, timeout=3.0, quiet=0.7):
        collected = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            frame = self.next_frame(timeout=min(quiet, max(0.05, deadline - time.time())))
            if frame is None:
                if collected:
                    break
                continue
            if frame == "EOF":
                collected.append("EOF")
                break
            collected.append(frame)
        return collected

    def collect(self, window=20.0, quiet=2.0, expect=None):
        """Read until `quiet` seconds without a new frame, or `window` elapses."""
        started = time.time()
        last_change = time.time()
        seen = len(self.lines)
        while time.time() - started < window:
            time.sleep(0.05)
            if len(self.lines) != seen:
                seen = len(self.lines)
                last_change = time.time()
                if expect is not None and seen >= expect:
                    break
            elif time.time() - last_change > quiet:
                break
        return list(self.lines)

    def alive(self):
        return self.proc.poll() is None

    def close_stdin(self):
        try:
            self.proc.stdin.close()
        except (OSError, ValueError):
            pass

    def wait(self, timeout=8.0):
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return None

    def shutdown(self, timeout=8.0):
        """Close stdin and reap. Returns the exit status, or the string HANG."""
        self.close_stdin()
        code = self.wait(timeout)
        if code is None:
            self.proc.kill()
            try:
                self.proc.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                pass
            return "HANG"
        return code


class Result:
    def __init__(self, name, group, status, spec, expected, observed, detail=None):
        self.name = name
        self.group = group
        self.status = status
        self.spec = spec
        self.expected = expected
        self.observed = observed
        self.detail = detail or {}

    def to_dict(self):
        return {
            "name": self.name,
            "group": self.group,
            "status": self.status,
            "spec": self.spec,
            "expected": self.expected,
            "observed": self.observed,
            "detail": self.detail,
        }


def frame_kind(frame):
    """Compact label for a reply frame: type, or type:code for error payloads."""
    if isinstance(frame, str):
        return frame
    kind = frame.get("type")
    payload = frame.get("payload") or {}
    if kind == "agent_error" and "code" in payload:
        return "agent_error:%s" % payload["code"]
    if kind == "nack" and "error_code" in payload:
        return "nack:%s" % payload["error_code"]
    if kind == "error":
        return "error:%s" % frame.get("code")
    return kind


def kinds(frames):
    return [frame_kind(f) for f in frames]


# --- group: envelope --------------------------------------------------------
# A malformed or hostile envelope must be answered, not fatal. The stdio host
# already documents the contract for an unroutable frame: emit the runtime
# `unknown_envelope` error and keep processing (see the unit test "stdio mode
# emits unknown_envelope error and continues processing" in makai.zig).

def survives(ctx, name, frame_or_bytes, spec, answered=True):
    """Send one frame and require the host process to survive it.

    A frame that is rejected before it reaches real work answers the follow-up
    ping. A frame that is accepted may instead block in something slow (on an
    unsigned macOS build, reading the login Keychain pops an invisible ACL
    prompt), so an alive-but-silent host is reported rather than failed; only a
    host that actually died fails the check.

    Surviving is necessary but not sufficient: the frame must also have been
    *answered*, with an error frame if it was rejected or a normal reply if it
    was accepted. A host that silently drops a frame stays alive and answers
    the follow-up ping, which would otherwise pass this check while regressing
    the contract it exists to protect. A frame carrying no usable message_id
    cannot be correlated to any reply, so pass ``answered=False`` for those.
    """
    host = ctx.host()
    host.next_frame(timeout=3.0)
    if isinstance(frame_or_bytes, (bytes, bytearray)):
        host.write_bytes(frame_or_bytes)
    else:
        host.send(frame_or_bytes)
    replies = host.drain(timeout=2.5, quiet=0.7)

    died_early = not host.alive()
    still_answering = False
    if not died_early:
        try:
            host.send(agent_frame("ping", nanoid(), 1, {}))
            probe = host.next_frame(timeout=3.0)
            still_answering = isinstance(probe, dict) and probe.get("type") == "pong"
        except (BrokenPipeError, OSError):
            still_answering = False

    code = host.shutdown()
    if died_early or (isinstance(code, int) and code != 0):
        return Result(
            name, "envelope", "fail", spec,
            "host answers with an error frame and keeps serving",
            "host died (exit=%s), replies=%s" % (code, kinds(replies)),
            {"stderr": host.stderr_lines[:4], "replies": replies},
        )
    if not still_answering:
        return Result(
            name, "envelope", "info", spec,
            "host answers and keeps serving",
            "host stayed alive but did not answer the follow-up ping "
            "(exit=%s); on macOS an unsigned build blocks on the Keychain ACL prompt" % code)
    if answered and not replies:
        return Result(
            name, "envelope", "fail", spec,
            "host answers the frame and keeps serving",
            "host survived but answered nothing: replies=[], exit=%s" % code,
            {"stderr": host.stderr_lines[:4]},
        )
    return Result(name, "envelope", "pass", spec,
                  "host answers and keeps serving",
                  "alive, replies=%s, exit=%s" % (kinds(replies), code))


def group_envelope(ctx):
    session = nanoid()
    message = ulid()
    stream = ulid()
    spec_agent = "spec 13.1 / DESIGN 4.1 (ids and sequence are validated fields)"
    spec_host = "makai.zig runStdioMode: unroutable frame emits unknown_envelope and continues"

    def agent(**over):
        base = agent_frame("ping", session, 1, {})
        base.update(over)
        return base

    def prov(**over):
        base = provider_frame("ping", stream, 1, {})
        base.update(over)
        return base

    def auth(**over):
        base = auth_frame("auth_providers_request", stream, 1, {})
        base.update(over)
        return base

    def without(frame, key):
        return {k: v for k, v in frame.items() if k != key}

    cases = [
        ("agent: sequence is negative", agent(sequence=-1), spec_agent),
        ("agent: sequence is i64 min", agent(sequence=-9223372036854775808), spec_agent),
        ("agent: version is negative", agent(version=-1), spec_agent),
        ("agent: version exceeds u8", agent(version=256), spec_agent),
        ("agent: in_reply_to is a number", agent(in_reply_to=123), spec_agent),
        ("agent: in_reply_to is null", agent(in_reply_to=None), spec_agent),
        ("agent: agent_start payload session_id is a number",
         agent(type="agent_start", payload={"config_json": "{}", "session_id": 5}), spec_agent),
        ("agent: models_request provider_id is a number",
         agent(type="models_request", payload={"provider_id": 5}), spec_agent),

        ("provider: sequence is negative", prov(sequence=-1), spec_agent),
        ("provider: sequence is a string", prov(sequence="1"), spec_agent),
        ("provider: sequence is absent", without(prov(), "sequence"), spec_agent),
        ("provider: version is negative", prov(version=-1), spec_agent),
        ("provider: version exceeds u8", prov(version=300), spec_agent),
        ("provider: type is absent", without(prov(), "type"), spec_host),
        ("provider: type is a number", prov(type=123), spec_host),
        ("provider: payload is absent", without(prov(), "payload"), spec_host),
        ("provider: payload is an array", prov(payload=[]), spec_host),
        ("provider: message_id is absent", without(prov(), "message_id"), spec_agent, False),
        ("provider: message_id is a number", prov(message_id=5), spec_agent, False),
        ("provider: result payload is empty", prov(type="result", payload={}), spec_host),
        ("provider: result stop_reason is a number",
         prov(type="result", payload={"stop_reason": 5}), spec_host),
        ("provider: result is missing model/api/provider",
         prov(type="result", payload={"stop_reason": "end_turn"}), spec_host),
        ("provider: result timestamp is a string",
         prov(type="result", payload={"stop_reason": "end_turn", "model": "m", "api": "a",
                                      "provider": "p", "timestamp": "soon"}), spec_host),
        ("provider: result content element is not an object",
         prov(type="result", payload={"content": [1], "stop_reason": "end_turn", "model": "m",
                                      "api": "a", "provider": "p", "timestamp": 1}), spec_host),
        ("provider: result usage input is a string",
         prov(type="result", payload={"usage": {"input": "lots"}, "stop_reason": "end_turn",
                                      "model": "m", "api": "a", "provider": "p",
                                      "timestamp": 1}), spec_host),
        ("provider: text_delta payload is empty", prov(type="text_delta", payload={}), spec_host),
        ("provider: text_delta content_index is a string",
         prov(type="text_delta", payload={"content_index": "first", "delta": "hi"}), spec_host),
        ("provider: text_delta content_index is negative",
         prov(type="text_delta", payload={"content_index": -1, "delta": "hi"}), spec_host),
        ("provider: start payload has no model", prov(type="start", payload={}), spec_host),
        ("provider: done payload has no message", prov(type="done", payload={}), spec_host),
        ("provider: timestamp is absent", without(prov(), "timestamp"), spec_agent),
        ("provider: timestamp is a string", prov(timestamp="x"), spec_agent),
        ("provider: in_reply_to is a number", prov(in_reply_to=123), spec_agent),
        ("provider: models_request provider_id is a number",
         prov(type="models_request", payload={"provider_id": 5}), spec_agent),
        ("provider: stream_request user message without content",
         prov(type="stream_request", payload={
             "model": MODEL_REF,
             "context": {"messages": [{"role": "user", "timestamp": 1}]},
         }), spec_agent),
        ("provider: models_response without cache_max_age_ms",
         prov(type="models_response", payload={"fetched_at_ms": 1, "models": []}), spec_agent),
        ("provider: toolcall_end thought_signature is a number",
         prov(type="toolcall_end", payload={"content_index": 0, "thought_signature": 5}), spec_host),
        ("provider: error event error_message is a number",
         prov(type="error", payload={"reason": "error", "error_message": 5}), spec_host),
        ("provider: text_delta partial current_text is a number",
         prov(type="text_delta", payload={"content_index": 0, "delta": "hi",
                                          "partial": {"current_text": 5}}), spec_host),
        ("provider: thinking_delta partial current_thinking is a number",
         prov(type="thinking_delta", payload={"content_index": 0, "delta": "hi",
                                              "partial": {"current_thinking": 5}}), spec_host),
        ("provider: toolcall_delta partial current_arguments_json is a number",
         prov(type="toolcall_delta", payload={"content_index": 0, "delta": "{",
                                              "partial": {"current_arguments_json": 5}}), spec_host),
        ("provider: result text content text_signature is a number",
         prov(type="result", payload={"content": [{"type": "text", "text": "hi",
                                                   "text_signature": 5}],
                                      "stop_reason": "end_turn", "model": "m", "api": "a",
                                      "provider": "p", "timestamp": 1}), spec_host),
        ("provider: result thinking content thinking_signature is a number",
         prov(type="result", payload={"content": [{"type": "thinking", "thinking": "hm",
                                                   "thinking_signature": 5}],
                                      "stop_reason": "end_turn", "model": "m", "api": "a",
                                      "provider": "p", "timestamp": 1}), spec_host),
        ("provider: result tool_call content thought_signature is a number",
         prov(type="result", payload={"content": [{"type": "tool_call", "id": "c1", "name": "t",
                                                   "arguments_json": "{}",
                                                   "thought_signature": 5}],
                                      "stop_reason": "end_turn", "model": "m", "api": "a",
                                      "provider": "p", "timestamp": 1}), spec_host),

        ("auth: sequence is negative", auth(sequence=-1), spec_agent),
        ("auth: version is negative", auth(version=-1), spec_agent),
        ("auth: version is absent", without(auth(), "version"), spec_agent),
        ("auth: payload is absent", without(auth(), "payload"), spec_host),
        ("auth: payload is an array", auth(payload=[]), spec_host),
        ("auth: timestamp is absent", without(auth(), "timestamp"), spec_agent),
        ("auth: auth_login_start without provider_id",
         auth(type="auth_login_start", payload={}), spec_host),
        ("auth: auth_login_start provider_id is a number",
         auth(type="auth_login_start", payload={"provider_id": 5}), spec_host),
        ("auth: auth_cancel without flow_id", auth(type="auth_cancel", payload={}), spec_host),
        ("auth: auth_prompt_response without flow_id",
         auth(type="auth_prompt_response", payload={}), spec_host),
    ]

    raw_cases = [
        ("raw: not JSON", b"{not json\n"),
        ("raw: bare scalar", b"5\n"),
        ("raw: top-level array", b"[1,2,3]\n"),
        ("raw: JSON null", b"null\n"),
        ("raw: empty object", b"{}\n"),
        ("raw: duplicate keys",
         ('{"type":"ping","session_id":"%s","session_id":"%s","message_id":"%s",'
          '"sequence":1,"timestamp":1,"version":1,"payload":{}}\n'
          % (session, nanoid(), message)).encode()),
        ("raw: deeply nested payload",
         b'{"type":"ping","session_id":"' + session.encode() + b'","message_id":"'
         + message.encode() + b'","sequence":1,"timestamp":1,"version":1,"payload":'
         + b"[" * 4000 + b"]" * 4000 + b"}\n"),
    ]

    results = []
    for case in cases:
        name, frame, spec = case[0], case[1], case[2]
        answered = case[3] if len(case) > 3 else True
        results.append(survives(ctx, name, frame, spec, answered))
    for name, blob in raw_cases:
        results.append(survives(ctx, name, blob, spec_host))

    # An undecodable provider frame that still carries a routable stream_id and
    # message_id must come back as a correlated nack: a client that gets nothing
    # cannot tell a rejected request from a slow one.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    answered = {}
    for label, frame in (
        ("missing timestamp", without(prov(), "timestamp")),
        ("missing payload", without(prov(), "payload")),
        ("complete_request without model",
         provider_frame("complete_request", stream, 1, {})),
        ("complete_request with a string model",
         provider_frame("complete_request", stream, 1, {"model": "gpt"})),
    ):
        replies = host.exchange(frame)
        nacks = [f for f in replies if isinstance(f, dict) and f.get("type") == "nack"]
        answered[label] = {
            "kinds": kinds(replies),
            "correlated": bool(nacks) and nacks[0].get("in_reply_to") == frame.get("message_id"),
        }
    code = host.shutdown()
    unanswered = [k for k, v in answered.items() if not v["correlated"]]
    results.append(Result(
        "undecodable provider frame answers with a correlated nack", "envelope",
        "pass" if not unanswered else "fail",
        "spec 8 (malformed requests use the nack envelope with invalid_request)",
        "each malformed frame answers nack with in_reply_to naming the request",
        "unanswered=%s exit=%s" % (unanswered, code), {"replies": answered}))

    # Ambiguous routing: a frame carrying both scoping ids is rejected by
    # detectDispatchTarget rather than guessed at. The spec does not cover it.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    replies = host.exchange({
        "type": "ping", "stream_id": stream, "session_id": session,
        "message_id": message, "sequence": 1, "timestamp": 1, "version": 1, "payload": {},
    })
    code = host.shutdown()
    results.append(Result(
        "raw: both stream_id and session_id", "envelope", "info",
        "spec is silent on a frame carrying two scoping ids",
        "documented behavior", "replies=%s exit=%s" % (kinds(replies), code)))
    return results


# --- group: framing ---------------------------------------------------------
# The stdin reader is a bounded queue in front of a 1 MiB line framer
# (zig/src/transports/stdio.zig). Both bounds are reachable from a conforming
# client, so both must be reported rather than silently ending the connection.
# DESIGN.md section 8.4 makes backpressure_failures = 0 a hard gate, and spec
# 13.2.7 defines process exit only for stdin close with no active work.

def group_framing(ctx):
    results = []

    # A burst that fits the inbound queue must be answered in full.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    session = nanoid()
    fits = 1023
    for _ in range(fits):
        host.send(agent_frame("ping", session, 1, {}))
    lines = host.collect(window=30.0, quiet=3.0, expect=fits + 1)
    pongs = sum(1 for line in lines if '"pong"' in line)
    code = host.shutdown()
    results.append(Result(
        "inbound burst within queue capacity is answered in full", "framing", "pass" if pongs == fits else "fail",
        "DESIGN 8.4 (backpressure_failures = 0)",
        "%d pongs for %d pings" % (fits, fits),
        "%d pongs, exit=%s" % (pongs, code)))

    # A burst that overruns the queue must not silently end the connection.
    # How many frames that takes depends on how fast the pump drains, so the
    # target is well past the queue depth: a Debug build trips near 1.4k and a
    # ReleaseSafe build near 3.5k.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    session = nanoid()
    target = 20000
    sent = 0
    broken_at = None
    try:
        for _ in range(target):
            host.send(agent_frame("ping", session, 1, {}))
            sent += 1
    except (BrokenPipeError, OSError):
        broken_at = sent
    lines = host.collect(window=30.0, quiet=3.0, expect=sent + 1)
    pongs = sum(1 for line in lines if '"pong"' in line)
    errors = [line for line in lines if '"type":"error"' in line]
    code = host.shutdown()
    lost = sent - pongs
    ok = lost == 0 or len(errors) > 0
    results.append(Result(
        "inbound burst beyond queue capacity is reported, not silently dropped",
        "framing", "pass" if ok else "fail",
        "DESIGN 8.4 (backpressure_failures = 0); spec 13.2.7 (exit only on stdin close)",
        "every accepted frame answered, or an error frame explaining the loss",
        "sent=%d answered=%d lost=%d error_frames=%d broken_pipe_at=%s exit=%s"
        % (sent, pongs, lost, len(errors), broken_at, code),
        {"stderr": host.stderr_lines[:4]}))

    # A frame past the 1 MiB line limit must be reported, not silently fatal.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    session = nanoid()
    host.send(agent_frame("agent_start", session, 1, start_payload(session)))
    started = host.drain(timeout=3.0, quiet=0.7)
    oversized = agent_frame("agent_message", session, 2, message_payload(session, "x" * (1200 * 1024)))
    try:
        host.send(oversized)
        wrote = True
    except (BrokenPipeError, OSError):
        wrote = False
    lines = host.collect(window=12.0, quiet=3.0)
    after = lines[len(started) + 1:]
    code = host.shutdown()
    results.append(Result(
        "frame over the 1 MiB line limit is reported, not silently fatal",
        "framing", "pass" if after else "fail",
        "DESIGN 8.4; spec 13.2.7 (exit only on stdin close with no active work)",
        "an error frame naming the limit; the host keeps serving",
        "wrote=%s frames_after_oversized=%d exit=%s" % (wrote, len(after), code),
        {"stderr": host.stderr_lines[:4], "limit": "stdio.zig default_line_bytes = 1 MiB"}))

    # A trailing frame with no newline must still be framed at EOF.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    session = nanoid()
    host.write_bytes(json.dumps(agent_frame("ping", session, 1, {})).encode())
    before = host.drain(timeout=1.5, quiet=1.0)
    host.close_stdin()
    after = host.drain(timeout=3.0, quiet=1.0)
    code = host.wait(8.0)
    saw_pong = any(isinstance(f, dict) and f.get("type") == "pong" for f in before + after)
    results.append(Result(
        "final frame without a trailing newline is processed at EOF", "framing",
        "pass" if saw_pong else "fail",
        "spec is silent; NDJSON convention tolerates a missing final newline",
        "the frame is processed once EOF closes the line",
        "pong_seen=%s exit=%s" % (saw_pong, code)))

    # A frame split across writes must be reassembled.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    session = nanoid()
    blob = (json.dumps(agent_frame("ping", session, 1, {})) + "\n").encode()
    host.write_bytes(blob[:40])
    time.sleep(0.3)
    host.write_bytes(blob[40:])
    replies = host.drain(timeout=3.0, quiet=0.8)
    code = host.shutdown()
    results.append(Result(
        "frame split across writes is reassembled", "framing",
        "pass" if kinds(replies) == ["pong"] else "fail",
        "spec is silent; NDJSON framing is byte-stream oriented",
        "one pong", "%s exit=%s" % (kinds(replies), code)))

    # Blank and whitespace-only lines must be skipped, not treated as frames.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    session = nanoid()
    host.write_bytes(b"\n\n\n   \n\t\n")
    replies = host.exchange(agent_frame("ping", session, 1, {}))
    code = host.shutdown()
    results.append(Result(
        "blank lines are skipped", "framing",
        "pass" if kinds(replies) == ["pong"] else "fail",
        "spec is silent", "blank lines produce no frames",
        "%s exit=%s" % (kinds(replies), code)))
    return results


# --- group: sequencing ------------------------------------------------------

def group_sequencing(ctx):
    results = []
    host = ctx.host()
    host.next_frame(timeout=3.0)

    for bad in (0, 2):
        session = nanoid()
        replies = host.exchange(agent_frame("agent_start", session, bad, start_payload(session)))
        got = kinds(replies)
        results.append(Result(
            "agent_start with sequence %d is rejected" % bad, "sequencing",
            "pass" if got == ["agent_error:invalid_request"] else "fail",
            "spec 13.1 (agent_start MUST carry sequence 1)",
            "agent_error:invalid_request", str(got)))

    # Request-validation errors carry sequence 0, outside the ordering domain.
    session = nanoid()
    replies = host.exchange(agent_frame("agent_start", session, 5, start_payload(session)))
    seq = replies[0].get("sequence") if replies and isinstance(replies[0], dict) else None
    results.append(Result(
        "request-validation agent_error carries sequence 0", "sequencing",
        "pass" if seq == 0 else "fail",
        "spec 13.1 (validation agent_error envelopes carry sequence 0)",
        "sequence == 0", "sequence == %s" % seq))

    # A live session: gaps and duplicates are rejected and never advance.
    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    for bad, label in ((5, "gap"), (1, "duplicate of agent_start")):
        replies = host.exchange(agent_frame("agent_message", session, bad, message_payload(session)))
        got = kinds(replies)
        results.append(Result(
            "agent_message sequence %s is rejected" % label, "sequencing",
            "pass" if got == ["agent_error:invalid_request"] else "fail",
            "DESIGN 4.2 (monotonic +1, no gaps or duplicates)",
            "agent_error:invalid_request", str(got)))
    replies = host.exchange(agent_frame("agent_stop", session, 2, {"session_id": session, "reason": "done"}))
    got = kinds(replies)
    results.append(Result(
        "rejected requests do not advance the inbound counter", "sequencing",
        "pass" if got == ["agent_stopped"] else "fail",
        "spec 13.1 (rejected requests never advance the counter)",
        "agent_stopped at sequence 2", str(got)))

    # Out-of-order stop is rejected and leaves the session registered.
    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    bad_stop = kinds(host.exchange(agent_frame("agent_stop", session, 7, {"session_id": session, "reason": "x"})))
    still = kinds(host.exchange(agent_frame("agent_status", session, 3, {"session_id": session})))
    good_stop = kinds(host.exchange(agent_frame("agent_stop", session, 2, {"session_id": session, "reason": "x"})))
    ok = bad_stop == ["agent_error:invalid_request"] and still == ["session_info"] and good_stop == ["agent_stopped"]
    results.append(Result(
        "out-of-order agent_stop is rejected and leaves the session registered",
        "sequencing", "pass" if ok else "fail",
        "spec 6.1 (out-of-order stops are rejected and leave the session registered)",
        "invalid_request, then session_info, then agent_stopped",
        "%s / %s / %s" % (bad_stop, still, good_stop)))

    # Non-sequencing request types must not consume the inbound counter.
    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    observed = {}
    for kind, payload in (
        ("agent_status", {"session_id": session}),
        ("ping", {}),
        ("tool_list", {}),
        ("models_request", {"provider_id": "anthropic"}),
        ("goodbye", {}),
    ):
        observed[kind] = kinds(host.exchange(agent_frame(kind, session, 77, payload)))
    after = kinds(host.exchange(agent_frame("agent_stop", session, 2, {"session_id": session, "reason": "x"})))
    results.append(Result(
        "agent_status/ping/tool_list/models_request/goodbye consume no inbound sequence",
        "sequencing", "pass" if after == ["agent_stopped"] else "fail",
        "spec 13.1 (these types never consume inbound sequence)",
        "agent_stop at sequence 2 still accepted",
        "replies=%s then stop=%s" % (observed, after)))

    # goodbye is accepted silently and leaves the session usable.
    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    bye = kinds(host.exchange(agent_frame("goodbye", session, 9, {}), timeout=1.5))
    after_bye = kinds(host.exchange(agent_frame("agent_status", session, 2, {"session_id": session})))
    results.append(Result(
        "goodbye produces no reply and leaves the session usable", "sequencing",
        "pass" if bye == [] and after_bye == ["session_info"] else "fail",
        "spec 13.1 (goodbye is accepted silently; the session remains usable)",
        "no reply, then session_info", "%s / %s" % (bye, after_bye)))

    # Concurrent sessions keep independent counters.
    left, right = nanoid(), nanoid()
    host.send(agent_frame("agent_start", left, 1, start_payload(left)))
    host.send(agent_frame("agent_start", right, 1, start_payload(right)))
    starts = kinds(host.drain(timeout=4.0, quiet=0.8))
    host.send(agent_frame("agent_stop", left, 2, {"session_id": left, "reason": "x"}))
    host.send(agent_frame("agent_stop", right, 2, {"session_id": right, "reason": "x"}))
    stops = kinds(host.drain(timeout=4.0, quiet=0.8))
    ok = starts == ["agent_started"] * 2 and stops == ["agent_stopped"] * 2
    results.append(Result(
        "concurrent sessions keep independent inbound counters", "sequencing",
        "pass" if ok else "fail",
        "DESIGN 4.2/4.3 (per-session counters; a global counter is non-conformant)",
        "both starts at 1 and both stops at 2 accepted",
        "%s / %s" % (starts, stops)))

    host.shutdown()

    # Provider streams validate their own sequence scope.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    stream = ulid()
    first = kinds(host.exchange(provider_frame("models_request", stream, 1, {"provider_id": "anthropic"}), timeout=4.0))
    dup = kinds(host.exchange(provider_frame("models_request", stream, 1, {"provider_id": "anthropic"}), timeout=4.0))
    gap = kinds(host.exchange(provider_frame("models_request", stream, 99, {"provider_id": "anthropic"}), timeout=4.0))
    fresh = kinds(host.exchange(provider_frame("models_request", ulid(), 5, {"provider_id": "anthropic"}), timeout=4.0))
    host.shutdown()
    ok = (first == ["ack", "models_response"] and dup == ["nack:duplicate_sequence"]
          and gap == ["nack:sequence_gap"] and fresh == ["nack:sequence_gap"])
    results.append(Result(
        "provider stream sequence scope rejects duplicates and gaps", "sequencing",
        "pass" if ok else "fail",
        "DESIGN 4.1/4.2 (provider sequence scope is stream_id, first request is 1)",
        "ack+models_response, duplicate_sequence, sequence_gap, sequence_gap",
        "%s / %s / %s / %s" % (first, dup, gap, fresh)))
    return results


# --- group: lifecycle -------------------------------------------------------

def group_lifecycle(ctx):
    results = []
    host = ctx.host()
    host.next_frame(timeout=3.0)

    session = nanoid()
    before = kinds(host.exchange(agent_frame("agent_message", session, 1, message_payload(session))))
    results.append(Result(
        "agent_message before agent_start is agent_not_found", "lifecycle",
        "pass" if before == ["agent_error:agent_not_found"] else "fail",
        "spec 13.4.1 (a message for an unknown session is rejected agent_not_found)",
        "agent_error:agent_not_found", str(before)))

    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    dup = kinds(host.exchange(agent_frame("agent_start", session, 1, start_payload(session))))
    results.append(Result(
        "duplicate agent_start on a registered id is agent_busy", "lifecycle",
        "pass" if dup == ["agent_error:agent_busy"] else "fail",
        "spec 13.2.1 / 13.3.3 (a start naming a registered id is rejected agent_busy)",
        "agent_error:agent_busy", str(dup)))

    stop_once = kinds(host.exchange(agent_frame("agent_stop", session, 2, {"session_id": session, "reason": "x"})))
    stop_twice = kinds(host.exchange(agent_frame("agent_stop", session, 2, {"session_id": session, "reason": "x"})))
    results.append(Result(
        "second agent_stop on a stopped id is agent_not_found", "lifecycle",
        "pass" if stop_once == ["agent_stopped"] and stop_twice == ["agent_error:agent_not_found"] else "fail",
        "spec 13.2.6 (a stopped id answers agent_not_found)",
        "agent_stopped then agent_error:agent_not_found",
        "%s / %s" % (stop_once, stop_twice)))

    unknown = nanoid()
    probes = {
        "agent_status": kinds(host.exchange(agent_frame("agent_status", unknown, 1, {"session_id": unknown}))),
        "agent_stop": kinds(host.exchange(agent_frame("agent_stop", unknown, 1, {"session_id": unknown, "reason": "x"}))),
        "agent_message": kinds(host.exchange(agent_frame("agent_message", unknown, 2, message_payload(unknown)))),
    }
    ok = all(v == ["agent_error:agent_not_found"] for v in probes.values())
    results.append(Result(
        "unknown session id answers agent_not_found on every session-scoped request",
        "lifecycle", "pass" if ok else "fail",
        "spec 13.2.6 (eviction MUST NOT be distinguishable from stop by error code)",
        "agent_error:agent_not_found for status, stop and message", str(probes)))

    # A stopped id may be re-registered, and its outbound counter restarts.
    session = nanoid()
    rounds = []
    for _ in range(2):
        seen = []
        for frame in host.exchange(agent_frame("agent_start", session, 1, start_payload(session))):
            if isinstance(frame, dict):
                seen.append((frame.get("type"), frame.get("sequence")))
        for frame in host.exchange(agent_frame("agent_stop", session, 2, {"session_id": session, "reason": "x"})):
            if isinstance(frame, dict):
                seen.append((frame.get("type"), frame.get("sequence")))
        rounds.append(seen)
    ok = rounds[0] == rounds[1] == [("agent_started", 1), ("agent_stopped", 2)]
    results.append(Result(
        "a re-registered session id restarts the outbound counter", "lifecycle",
        "pass" if ok else "fail",
        "spec 13.1 (the outbound counter is scoped to the registration, not the id string)",
        "both registrations emit agent_started(1) and agent_stopped(2)", str(rounds)))

    # Envelope and payload session ids must agree before any mutation.
    session, other = nanoid(), nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    mismatch = kinds(host.exchange(agent_frame("agent_stop", session, 2, {"session_id": other, "reason": "x"})))
    survived = kinds(host.exchange(agent_frame("agent_status", session, 3, {"session_id": session})))
    ok = mismatch == ["agent_error:invalid_request"] and survived == ["session_info"]
    results.append(Result(
        "envelope/payload session_id mismatch is rejected before any mutation",
        "lifecycle", "pass" if ok else "fail",
        "spec 13.1 (compare the two ids FIRST; reject a mismatch before lookup or removal)",
        "invalid_request, and the session survives", "%s / %s" % (mismatch, survived)))

    # An unsolicited tool_result is discarded and consumes no sequence.
    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    stray = kinds(host.exchange(agent_frame(
        "tool_result", session, 2, {"tool_call_id": "call_1", "result_json": "{}"}, in_reply_to=ulid())))
    after = kinds(host.exchange(agent_frame("agent_stop", session, 2, {"session_id": session, "reason": "x"})))
    ok = stray == ["error:unknown_envelope"] and after == ["agent_stopped"]
    results.append(Result(
        "unsolicited tool_result is discarded and consumes no sequence", "lifecycle",
        "pass" if ok else "fail",
        "spec 13.1 / 13.3.4 (uncorrelated tool_result is discarded; it never consumes sequence)",
        "unknown_envelope, then agent_stop at sequence 2 still accepted",
        "%s / %s" % (stray, after)))

    # An id-omitting agent_start makes the server allocate the container id.
    envelope_id = nanoid()
    generated = None
    for frame in host.exchange(agent_frame(
            "agent_start", envelope_id, 1, {"config_json": json.dumps({"model_ref": MODEL_REF})})):
        if isinstance(frame, dict) and frame.get("type") == "agent_started":
            generated = frame.get("session_id")
    results.append(Result(
        "agent_start omitting the payload id gets a server-generated id", "lifecycle",
        "pass" if generated is not None and generated != envelope_id else "fail",
        "spec 13.1 (when agent_start omits the payload id the envelope id is ignored)",
        "agent_started carries a generated id different from the request envelope id",
        "request=%s generated=%s" % (envelope_id, generated)))

    host.shutdown()
    return results


# --- group: eviction --------------------------------------------------------

def group_eviction(ctx):
    results = []

    # A tiny TTL evicts an idle session, and the id is reusable afterwards.
    host = ctx.host(env={"MAKAI_AGENT_SESSION_IDLE_TTL_MS": "1"})
    host.next_frame(timeout=3.0)
    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    time.sleep(1.2)
    evicted = kinds(host.exchange(agent_frame("agent_status", session, 2, {"session_id": session})))
    restart = kinds(host.exchange(agent_frame("agent_start", session, 1, start_payload(session))))
    host.shutdown()
    ok = evicted == ["agent_error:agent_not_found"] and restart == ["agent_started"]
    results.append(Result(
        "idle TTL evicts, and an evicted id is indistinguishable from a stopped one",
        "eviction", "pass" if ok else "fail",
        "spec 13.2.6 (evicted sessions answer agent_not_found; agent_start creates a fresh container)",
        "agent_not_found, then agent_started on the same id",
        "%s / %s" % (evicted, restart)))

    # TTL 0 disables eviction.
    host = ctx.host(env={"MAKAI_AGENT_SESSION_IDLE_TTL_MS": "0"})
    host.next_frame(timeout=3.0)
    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    time.sleep(2.0)
    alive = kinds(host.exchange(agent_frame("agent_status", session, 2, {"session_id": session})))
    host.shutdown()
    results.append(Result(
        "MAKAI_AGENT_SESSION_IDLE_TTL_MS=0 disables eviction", "eviction",
        "pass" if alive == ["session_info"] else "fail",
        "spec 13.2.6 (0 disables the idle TTL)", "session_info", str(alive)))

    # An agent_status poll refreshes the idle clock.
    host = ctx.host(env={"MAKAI_AGENT_SESSION_IDLE_TTL_MS": "2500"})
    host.next_frame(timeout=3.0)
    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    polls = []
    for index in range(6):
        time.sleep(0.8)
        host.send(agent_frame("agent_status", session, 2 + index, {"session_id": session}))
        polls.append(frame_kind(host.next_frame(timeout=3.0)))
    host.shutdown()
    ok = all(p == "session_info" for p in polls)
    results.append(Result(
        "agent_status polls refresh the idle clock", "eviction",
        "pass" if ok else "fail",
        "spec 13.2.6 (idleness is measured from last activity, including an agent_status poll)",
        "six polls at 0.8s under a 2.5s TTL all answer session_info", str(polls)))
    return results


# --- group: ids -------------------------------------------------------------

def group_ids(ctx):
    results = []
    host = ctx.host()
    host.next_frame(timeout=3.0)

    # session_id must be a 21-character alphanumeric NanoID.
    rejected = {}
    for label, bad in (
        ("20 characters", nanoid()[:20]),
        ("22 characters", nanoid() + "x"),
        ("contains a dash", "abc-defghijklmnopqrst"),
        ("ULID-shaped", ulid()),
    ):
        rejected[label] = kinds(host.exchange(agent_frame("agent_start", bad, 1, start_payload(bad))))
    ok = all(v == ["error:unknown_envelope"] for v in rejected.values())
    results.append(Result(
        "malformed session_id is refused", "ids", "pass" if ok else "fail",
        "DESIGN 4.1 / spec 3.1 (session_id is [A-Za-z0-9]{21})",
        "every malformed id is refused", str(rejected)))

    # message_id must be a 26-character Crockford ULID.
    lengths = {}
    for label, bad in (("25 characters", ulid()[:25]), ("27 characters", ulid() + "Z"),
                       ("NanoID-shaped", nanoid()),
                       ("leading digit 8 overflows the 48-bit timestamp", "8" + ulid()[1:])):
        session = nanoid()
        lengths[label] = kinds(host.exchange(
            agent_frame("agent_start", session, 1, start_payload(session), message_id=bad)))
    ok = all(v == ["error:unknown_envelope"] for v in lengths.values())
    results.append(Result(
        "malformed message_id is refused", "ids", "pass" if ok else "fail",
        "DESIGN 4.1 / spec 3.1 (message_id is [0-9A-HJKMNP-TV-Z]{26})",
        "every malformed id is refused", str(lengths)))

    # A ULID the host accepts must be echoed verbatim in in_reply_to, or the
    # string-equality correlation in spec 13.3.1 cannot find its waiter.
    canonical = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    echoes = {}
    for label, variant in (
        ("canonical", canonical),
        ("lowercase", canonical.lower()),
        ("mixed case", "01arZ3nDEktsv4RRffq69G5FAV"),
        ("Crockford alias I for 1", "0IARZ3NDEKTSV4RRFFQ69G5FAV"),
        ("Crockford alias L for 1", "0LARZ3NDEKTSV4RRFFQ69G5FAV"),
        ("Crockford alias O for 0", "O1ARZ3NDEKTSV4RRFFQ69G5FAV"),
    ):
        session = nanoid()
        replies = host.exchange(agent_frame("agent_start", session, 1, start_payload(session), message_id=variant))
        accepted = [f for f in replies if isinstance(f, dict) and f.get("type") == "agent_started"]
        if accepted:
            echoes[label] = {"sent": variant, "in_reply_to": accepted[0].get("in_reply_to"),
                             "verbatim": accepted[0].get("in_reply_to") == variant}
        else:
            echoes[label] = {"sent": variant, "refused": kinds(replies)}
    broken = {k: v for k, v in echoes.items() if v.get("verbatim") is False}
    results.append(Result(
        "an accepted message_id is echoed verbatim in in_reply_to", "ids",
        "pass" if not broken else "fail",
        "spec 13.3.1 (a reply MUST reach the waiter whose request message_id equals in_reply_to)",
        "in_reply_to is byte-identical to the accepted message_id, or the id is refused",
        "normalized for %d accepted variants: %s" % (len(broken), list(broken)),
        {"variants": echoes}))

    host.shutdown()

    # The envelope version is not a validated field today.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    versions = {}
    for version in (0, 2, 255):
        session = nanoid()
        versions[version] = kinds(host.exchange(
            agent_frame("agent_start", session, 1, start_payload(session), version=version)))
    host.shutdown()
    results.append(Result(
        "envelope version handling", "ids", "info",
        "spec 9 keeps the envelope version at 1 but does not say how to answer another value",
        "documented behavior", str(versions)))
    return results


# --- group: routing ---------------------------------------------------------

def group_routing(ctx):
    results = []
    host = ctx.host()
    host.next_frame(timeout=3.0)

    # Many sessions interleaved: frames must stay on their own session route
    # and each reply must correlate to the request that produced it.
    count = 100
    sessions = [nanoid() for _ in range(count)]
    starts = {}
    for session in sessions:
        message_id = ulid()
        starts[message_id] = session
        host.send(agent_frame("agent_start", session, 1, start_payload(session), message_id=message_id))
    for round_index in range(2):
        for session in sessions:
            host.send(agent_frame("agent_status", session, 2 + round_index, {"session_id": session}))
    for session in sessions:
        host.send(agent_frame("agent_stop", session, 2, {"session_id": session, "reason": "done"}))

    lines = host.collect(window=30.0, quiet=3.0, expect=1 + count * 4)
    frames = []
    for line in lines:
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
        if parsed.get("type") != "ready":
            frames.append(parsed)

    by_session = {}
    for frame in frames:
        by_session.setdefault(frame.get("session_id"), []).append(frame)

    expected_order = ["agent_started", "session_info", "session_info", "agent_stopped"]
    wrong_order = [s for s in sessions if [f.get("type") for f in by_session.get(s, [])] != expected_order]
    crossed = []
    for frame in frames:
        if frame.get("type") == "agent_started":
            owner = starts.get(frame.get("in_reply_to"))
            if owner != frame.get("session_id"):
                crossed.append(frame.get("session_id"))
    code = host.shutdown()

    results.append(Result(
        "%d interleaved sessions preserve per-session ordering" % count, "routing",
        "pass" if not wrong_order and len(by_session) == count else "fail",
        "DESIGN 5 (ordering is guaranteed within a session, multiplexed across them)",
        "each session sees agent_started, session_info x2, agent_stopped in order",
        "sessions=%d out_of_order=%d exit=%s" % (len(by_session), len(wrong_order), code)))
    results.append(Result(
        "in_reply_to never crosses sessions under interleaving", "routing",
        "pass" if not crossed else "fail",
        "spec 13.1 / 13.3.1 (in_reply_to references the request envelope message_id only)",
        "every agent_started correlates to its own start",
        "crossed=%d" % len(crossed)))

    # Echo replies copy the request's inbound sequence verbatim.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    echo = {}
    for kind, payload, sequence in (("agent_status", {"session_id": session}, 41),
                                    ("ping", {}, 42),
                                    ("tool_list", {}, 43)):
        replies = host.exchange(agent_frame(kind, session, sequence, payload))
        echo[kind] = [(f.get("type"), f.get("sequence")) for f in replies if isinstance(f, dict)]
    host.shutdown()
    ok = (echo.get("agent_status") == [("session_info", 41)]
          and echo.get("ping") == [("pong", 42)]
          and echo.get("tool_list") == [("tool_list_response", 43)])
    results.append(Result(
        "session_info, pong and tool_list_response echo the request sequence", "routing",
        "pass" if ok else "fail",
        "spec 13.1 (echo replies copy the request's inbound sequence verbatim)",
        "session_info(41), pong(42), tool_list_response(43)", str(echo)))
    return results


# --- group: shutdown --------------------------------------------------------

def group_shutdown(ctx):
    results = []

    # Immediate EOF: the host prints ready and exits cleanly.
    started = time.time()
    try:
        completed = subprocess.run([ctx.binary, "--stdio"], stdin=subprocess.DEVNULL,
                                   capture_output=True, timeout=20)
        exited_clean = completed.returncode == 0
        outcome = "exit=%d" % completed.returncode
    except subprocess.TimeoutExpired:
        exited_clean = False
        outcome = "HANG (no exit within 20s)"
    elapsed = time.time() - started
    results.append(Result(
        "immediate stdin EOF exits 0", "shutdown",
        "pass" if exited_clean else "fail",
        "spec 13.2.7 (the process exits when stdin closes and no work remains)",
        "exit 0", "%s in %.2fs" % (outcome, elapsed)))

    # Half-close with an idle session registered.
    host = ctx.host()
    host.next_frame(timeout=3.0)
    session = nanoid()
    host.exchange(agent_frame("agent_start", session, 1, start_payload(session)))
    started = time.time()
    code = host.shutdown(timeout=10.0)
    results.append(Result(
        "stdin half-close with an idle session exits 0 promptly", "shutdown",
        "pass" if code == 0 else "fail",
        "spec 13.2.7 (sessions die with the process; the connection bounds their lifetime)",
        "exit 0", "exit=%s in %.2fs" % (code, time.time() - started)))

    # The client closes its read side: the host should shut down gracefully
    # rather than propagating a raw write error out of main.
    proc = subprocess.Popen([ctx.binary, "--stdio"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    time.sleep(0.4)
    proc.stdout.close()
    session = nanoid()
    wrote = 0
    try:
        for _ in range(50):
            proc.stdin.write((json.dumps(agent_frame("ping", session, 1, {})) + "\n").encode())
            proc.stdin.flush()
            wrote += 1
            time.sleep(0.02)
    except (BrokenPipeError, OSError):
        pass
    try:
        proc.stdin.close()
    except (OSError, ValueError):
        pass
    try:
        code = proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        code = "HANG"
    stderr = proc.stderr.read().decode("utf-8", "replace")
    results.append(Result(
        "closing the client read side shuts down without a raw error trace", "shutdown",
        "pass" if code == 0 and not stderr.strip() else "fail",
        "spec 13.2.7 (settlement frames are lost only when the read side is gone)",
        "exit 0 with no stack trace on stderr",
        "exit=%s wrote=%d stderr=%r" % (code, wrote, stderr[:160])))
    return results


# --- group: resources -------------------------------------------------------

def group_resources(ctx):
    # Reported rather than gated: idle growth shows up in the default Debug
    # build (`zig build`) and not in the ReleaseSafe build that releases ship,
    # so a failure here would say more about the build mode than the protocol.
    results = []
    host = ctx.host()
    host.next_frame(timeout=3.0)
    time.sleep(1.0)

    def rss_kb():
        try:
            out = subprocess.run(["ps", "-o", "rss=", "-p", str(host.proc.pid)],
                                 capture_output=True, text=True, timeout=5).stdout.strip()
        except subprocess.TimeoutExpired:
            return -1
        return int(out) if out.isdigit() else -1

    window = ctx.resource_window
    first = rss_kb()
    time.sleep(window)
    last = rss_kb()
    host.shutdown()
    if first < 0 or last < 0:
        return [Result("idle host does not grow without bound", "resources", "info",
                       "DESIGN 8.4 (leak_count = 0)", "flat RSS while idle",
                       "could not sample RSS on this platform")]
    rate = (last - first) / float(window)
    results.append(Result(
        "idle host RSS growth", "resources", "info",
        "DESIGN 8.4 (leak_count = 0)",
        "flat RSS with no sessions and no traffic",
        "%d KB -> %d KB over %.0fs = %.1f KB/s (%.1f MB/hour)"
        % (first, last, window, rate, rate * 3600 / 1024)))
    return results


GROUPS = {
    "envelope": group_envelope,
    "framing": group_framing,
    "sequencing": group_sequencing,
    "lifecycle": group_lifecycle,
    "eviction": group_eviction,
    "ids": group_ids,
    "routing": group_routing,
    "shutdown": group_shutdown,
    "resources": group_resources,
}


class Context:
    def __init__(self, binary, resource_window):
        self.binary = binary
        self.resource_window = resource_window
        self._hosts = []

    def host(self, env=None):
        host = Host(self.binary, env)
        self._hosts.append(host)
        return host

    def cleanup(self):
        for host in self._hosts:
            if host.alive():
                host.proc.kill()
        self._hosts = []


def resolve_binary(explicit):
    if explicit:
        return explicit
    for candidate in DEFAULT_BINARY_CANDIDATES:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def main():
    parser = argparse.ArgumentParser(description="Conformance driver for makai --stdio")
    parser.add_argument("--binary", help="path to the makai binary")
    parser.add_argument("--group", action="append", choices=sorted(GROUPS),
                        help="run only these groups (repeatable)")
    parser.add_argument("--list", action="store_true", help="list groups and exit")
    parser.add_argument("--json", action="store_true", help="emit the report as JSON")
    parser.add_argument("--verbose", action="store_true", help="print every check, not just failures")
    parser.add_argument("--resource-window", type=float, default=10.0,
                        help="seconds to sample RSS in the resources group")
    parser.add_argument("--seed", type=int, help="seed the id generator for reproducible runs")
    args = parser.parse_args()

    if args.list:
        for name in sorted(GROUPS):
            print(name)
        return 0

    if args.seed is not None:
        random.seed(args.seed)

    binary = resolve_binary(args.binary)
    if not binary:
        sys.stderr.write(
            "no makai binary found; pass --binary or set MAKAI_BINARY_PATH\n"
            "build one with: zig build install --prefix /tmp/makai-stdio-test\n")
        return 2

    selected = args.group or sorted(GROUPS)
    ctx = Context(binary, args.resource_window)
    results = []
    try:
        for name in selected:
            if not args.json:
                sys.stderr.write("running group %s...\n" % name)
            results.extend(GROUPS[name](ctx))
    finally:
        ctx.cleanup()

    failures = [r for r in results if r.status == "fail"]
    if args.json:
        print(json.dumps({
            "binary": binary,
            "total": len(results),
            "failed": len(failures),
            "results": [r.to_dict() for r in results],
        }, indent=2))
    else:
        for result in results:
            if result.status == "pass" and not args.verbose:
                continue
            print("[%s] %s" % (result.status.upper(), result.name))
            print("    spec     : %s" % result.spec)
            print("    expected : %s" % result.expected)
            print("    observed : %s" % result.observed)
            if result.detail and result.status == "fail":
                print("    detail   : %s" % json.dumps(result.detail)[:600])
        passed = sum(1 for r in results if r.status == "pass")
        info = sum(1 for r in results if r.status == "info")
        print("\n%d checks: %d passed, %d failed, %d informational"
              % (len(results), passed, len(failures), info))

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
