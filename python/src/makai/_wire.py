"""Envelope construction and frame-payload readers.

Every protocol frame is an envelope:

``{type, stream_id|session_id, message_id, sequence, timestamp, version, payload}``

with ``in_reply_to`` on replies. Sequencing is per stream/session and starts at
1 (spec §13.1); provider and models requests are single-frame streams that
always carry sequence 1, while an agent session counts ``agent_start`` = 1,
``agent_message`` = 2, ``agent_stop`` = 3.
"""

from __future__ import annotations

import math
import time
from typing import Any, Dict, Mapping, Optional

from ._ids import new_ulid
from .errors import MakaiStreamError

__all__ = [
    "ENVELOPE_VERSION",
    "build_stream_envelope",
    "build_session_envelope",
    "build_reply_envelope",
    "payload_of",
    "json_payload_field",
    "str_or",
    "optional_str",
    "number_or",
    "is_mapping",
]

ENVELOPE_VERSION = 1


def _now_ms() -> int:
    return int(time.time() * 1000)


def build_stream_envelope(
    frame_type: str,
    stream_id: str,
    payload: Mapping[str, Any],
    *,
    message_id: Optional[str] = None,
    sequence: int = 1,
) -> Dict[str, Any]:
    """Build a ``stream_id``-routed envelope."""
    return {
        "type": frame_type,
        "stream_id": stream_id,
        "message_id": message_id or stream_id,
        "sequence": sequence,
        "timestamp": _now_ms(),
        "version": ENVELOPE_VERSION,
        "payload": dict(payload),
    }


def build_session_envelope(
    frame_type: str,
    session_id: str,
    sequence: int,
    payload: Mapping[str, Any],
) -> Dict[str, Any]:
    """Build a ``session_id``-routed envelope with a fresh ``message_id``."""
    return {
        "type": frame_type,
        "session_id": session_id,
        "message_id": new_ulid(),
        "sequence": sequence,
        "timestamp": _now_ms(),
        "version": ENVELOPE_VERSION,
        "payload": dict(payload),
    }


def build_reply_envelope(
    frame_type: str,
    request: Mapping[str, Any],
    payload: Mapping[str, Any],
) -> Dict[str, Any]:
    """Build a reply to ``request``, correlated by ``in_reply_to``.

    ``in_reply_to`` names the request envelope's ``message_id`` and nothing
    else (spec §13.1).
    """
    return {
        "type": frame_type,
        "session_id": request.get("session_id"),
        "message_id": new_ulid(),
        "sequence": number_or(request.get("sequence"), 0) + 1,
        "timestamp": _now_ms(),
        "version": ENVELOPE_VERSION,
        "in_reply_to": request.get("message_id"),
        "payload": dict(payload),
    }


def is_mapping(value: Any) -> bool:
    return isinstance(value, dict)


def payload_of(frame: Mapping[str, Any]) -> Dict[str, Any]:
    """Return a frame's ``payload`` object, or the frame itself when absent.

    Some runtime frames inline their fields on the envelope instead of nesting
    them under ``payload``; both shapes are accepted.
    """
    payload = frame.get("payload")
    if isinstance(payload, dict):
        return payload
    return dict(frame)


def json_payload_field(frame: Mapping[str, Any], key: str) -> Dict[str, Any]:
    """Parse a JSON-string payload field such as ``event_json``/``result_json``."""
    import json

    payload = payload_of(frame)
    raw = payload.get(key)
    if raw is None:
        raw = payload.get("event_json", payload.get("result_json"))
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise MakaiStreamError(f"malformed JSON in {key}", kind="transport_error") from exc
        return parsed if isinstance(parsed, dict) else {}
    return payload


def str_or(value: Any, fallback: str = "") -> str:
    return value if isinstance(value, str) else fallback


def optional_str(value: Any) -> Optional[str]:
    return value if isinstance(value, str) and value else None


def number_or(value: Any, fallback: int) -> int:
    """Read a JSON number, falling back when it is not a usable one.

    ``NaN`` and ``Infinity`` are floats that Python's JSON decoder accepts, so
    an isinstance check alone lets them reach an ``int()`` that raises.
    """
    if isinstance(value, bool):
        return fallback
    if isinstance(value, int):
        return value
    if isinstance(value, float) and math.isfinite(value):
        return int(value)
    return fallback
