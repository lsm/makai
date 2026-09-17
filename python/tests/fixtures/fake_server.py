"""A configurable fake ``makai --stdio`` host.

Plays the role of ``typescript/test/fixtures/*.js``: one script driven by a
JSON config so the matrix of scenarios does not need a file each.

The config path comes from ``MAKAI_FAKE_CONFIG``. Recognised keys:

``handshake``
    ``"ready"`` (default), ``"error"``, ``"bad_version"``, ``"silent"``, or
    ``"garbage"`` (a non-JSON line).
``log``
    Path to append every received frame to, one JSON object per line.
``handlers``
    ``{frame_type: [reply, ...]}``. Replies are emitted in order.
``once``
    Same shape as ``handlers``, but each frame type fires only on its first
    request; afterwards ``handlers`` takes over.
``ack``
    ``true`` (default) to emit a correlated ``ack`` before the handlers.
``exit_after``
    Exit the process after this many received frames, simulating a crash.
``track_agent_sessions``
    Validate the agent session lifecycle the way the real server does:
    duplicate ``agent_start`` is rejected ``agent_busy``, ``agent_message`` and
    ``agent_stop`` must carry the expected sequence, and ``agent_stop`` removes
    the session.

A reply is a dict with:

``type``
    Frame type to emit.
``payload``
    Payload object. ``"$session_id"`` / ``"$stream_id"`` / ``"$tool_call_id"``
    anywhere inside it is substituted from the request.
``correlate``
    ``true`` (default) to set ``in_reply_to`` to the request's ``message_id``.
    Real async run output carries no ``in_reply_to``; set ``false`` for it.
``delay_ms``
    Sleep before emitting.
``event_json`` / ``result_json``
    Convenience: the value is JSON-encoded into the payload under that key.
``raw``
    Write this string verbatim instead of building a frame, for malformed-line
    coverage.
"""

from __future__ import annotations

import json
import os
import sys
import time
from typing import Any, Dict, List, Optional

_received = 0
_agent_sessions: Dict[str, int] = {}
_once_fired: set[str] = set()


def emit(frame: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(frame) + "\n")
    sys.stdout.flush()


def load_config() -> Dict[str, Any]:
    path = os.environ.get("MAKAI_FAKE_CONFIG")
    if not path:
        return {}
    with open(path, encoding="utf-8") as handle:
        data: Dict[str, Any] = json.load(handle)
    return data


def append_log(path: Optional[str], frame: Dict[str, Any]) -> None:
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(frame) + "\n")


def substitute(value: Any, request: Dict[str, Any]) -> Any:
    if isinstance(value, str):
        if value == "$session_id":
            return request.get("session_id")
        if value == "$stream_id":
            return request.get("stream_id")
        if value == "$message_id":
            return request.get("message_id")
        if value == "$tool_call_id":
            payload = request.get("payload") or {}
            return payload.get("tool_call_id")
        return value
    if isinstance(value, dict):
        return {key: substitute(item, request) for key, item in value.items()}
    if isinstance(value, list):
        return [substitute(item, request) for item in value]
    return value


def route_fields(request: Dict[str, Any]) -> Dict[str, Any]:
    if request.get("stream_id"):
        return {"stream_id": request["stream_id"]}
    return {"session_id": request.get("session_id")}


def build_frame(
    request: Dict[str, Any], spec: Dict[str, Any], sequence: int
) -> Dict[str, Any]:
    payload = substitute(spec.get("payload", {}), request)
    if "event_json" in spec:
        payload = dict(payload)
        payload["event_json"] = json.dumps(substitute(spec["event_json"], request))
    if "result_json" in spec:
        payload = dict(payload)
        payload["result_json"] = (
            spec["result_json"]
            if isinstance(spec["result_json"], str)
            else json.dumps(substitute(spec["result_json"], request))
        )
    frame: Dict[str, Any] = {
        "type": spec["type"],
        **route_fields(request),
        "message_id": f"{request.get('message_id', 'x')}-{sequence}",
        "sequence": spec.get("sequence", sequence),
        "timestamp": int(time.time() * 1000),
        "version": 1,
        "payload": payload,
    }
    if spec.get("correlate", True):
        frame["in_reply_to"] = request.get("message_id")
    return frame


def emit_replies(request: Dict[str, Any], specs: List[Dict[str, Any]]) -> None:
    for index, spec in enumerate(specs):
        delay_ms = spec.get("delay_ms", 0)
        if delay_ms:
            time.sleep(delay_ms / 1000.0)
        if "raw" in spec:
            sys.stdout.write(spec["raw"] + "\n")
            sys.stdout.flush()
            continue
        emit(build_frame(request, spec, index + 3))


def handle_agent_tracking(request: Dict[str, Any], config: Dict[str, Any]) -> bool:
    """Return ``True`` when the frame was fully handled by session tracking."""
    if not config.get("track_agent_sessions"):
        return False
    frame_type = request.get("type")
    session_id = request.get("session_id")
    if not isinstance(session_id, str):
        return False

    if frame_type == "agent_start":
        if session_id in _agent_sessions:
            emit(
                build_frame(
                    request,
                    {
                        "type": "nack",
                        "payload": {"error_code": "agent_busy", "reason": "session already exists"},
                    },
                    3,
                )
            )
            return True
        if request.get("sequence") != 1:
            emit(
                build_frame(
                    request,
                    {
                        "type": "agent_error",
                        "sequence": 0,
                        "payload": {"code": "invalid_request", "message": "invalid sequence"},
                    },
                    3,
                )
            )
            return True
        _agent_sessions[session_id] = 2
        return False

    if frame_type == "agent_message":
        expected = _agent_sessions.get(session_id, 1)
        if request.get("sequence") != expected:
            emit(
                build_frame(
                    request,
                    {
                        "type": "agent_error",
                        "sequence": 0,
                        "payload": {"code": "invalid_request", "message": "invalid sequence"},
                    },
                    3,
                )
            )
            return True
        _agent_sessions[session_id] = expected + 1
        return False

    if frame_type == "agent_stop":
        expected = _agent_sessions.get(session_id, 1)
        if request.get("sequence") != expected:
            emit(
                build_frame(
                    request,
                    {
                        "type": "agent_error",
                        "sequence": 0,
                        "payload": {"code": "invalid_request", "message": "invalid sequence"},
                    },
                    3,
                )
            )
            return True
        del _agent_sessions[session_id]
        emit(
            build_frame(
                request,
                {"type": "agent_stopped", "payload": {"session_id": session_id}},
                3,
            )
        )
        return True

    return False


def main() -> None:
    global _received
    config = load_config()
    log_path = config.get("log")

    handshake = config.get("handshake", "ready")
    if handshake == "ready":
        emit({"type": "ready", "protocol_version": "1"})
    elif handshake == "bad_version":
        emit({"type": "ready", "protocol_version": "99"})
    elif handshake == "error":
        emit({"type": "error", "code": "version_mismatch", "message": "unsupported protocol"})
    elif handshake == "garbage":
        sys.stdout.write("{not json\n")
        sys.stdout.flush()
    elif handshake == "silent":
        pass

    handlers: Dict[str, List[Dict[str, Any]]] = config.get("handlers", {})
    once: Dict[str, List[Dict[str, Any]]] = config.get("once", {})
    exit_after = config.get("exit_after")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(request, dict):
            continue

        _received += 1
        append_log(log_path, request)

        if exit_after is not None and _received >= exit_after:
            sys.stdout.flush()
            os._exit(1)

        frame_type = request.get("type")
        if config.get("ack", True):
            emit(
                build_frame(
                    request,
                    {"type": "ack", "payload": {"acknowledged_id": request.get("message_id")}},
                    1,
                )
            )

        if handle_agent_tracking(request, config):
            continue

        if frame_type in once and frame_type not in _once_fired:
            _once_fired.add(str(frame_type))
            emit_replies(request, once[frame_type])
            continue
        if frame_type in handlers:
            emit_replies(request, handlers[frame_type])


if __name__ == "__main__":
    main()
