"""Frame -> event and frame -> response normalisation.

The runtime publishes the same logical event under several wire shapes: as a
top-level frame type, nested under ``payload.event``, or JSON-encoded in
``agent_event.event_json``. Provider-native naming also differs (``reasoning``
vs ``thinking``). Everything is funnelled through here so the ``provider`` and
``agent`` namespaces only ever see the typed events from :mod:`makai.types`.
"""

from __future__ import annotations

from typing import Any, Dict, List, Mapping, Optional, Sequence, Union

from ._wire import json_payload_field, number_or, optional_str, payload_of, str_or
from .errors import MakaiStreamError
from .types import (
    AgentEnd,
    AgentStart,
    AgentStreamEvent,
    AssistantMessage,
    CompletionResponse,
    Content,
    ContentPart,
    MessageEnd,
    MessageStart,
    ProviderStreamEvent,
    StreamError,
    TextDelta,
    ThinkingDelta,
    ToolCall,
    ToolExecutionEnd,
    ToolExecutionStart,
    TurnEnd,
    TurnStart,
    Usage,
)

__all__ = [
    "ToolBuffers",
    "is_known_agent_frame_type",
    "normalize_provider_frame",
    "normalize_agent_frame",
    "parse_completion_response",
    "parse_agent_run_response",
    "build_response_from_events",
    "parse_usage",
    "add_usage",
    "nack_to_stream_error",
    "error_frame_to_stream_error",
    "is_auth_failure_message",
]

ToolBuffers = Dict[int, Dict[str, Any]]

_AGENT_EVENT_TYPES = frozenset(
    {
        "agent_start",
        "agent_end",
        "turn_start",
        "turn_end",
        "tool_execution_start",
        "tool_execution_end",
        "tool_execution_update",
    }
)

_PROVIDER_EVENT_TYPES = frozenset(
    {
        "text_delta",
        "thinking_delta",
        "reasoning_delta",
        "reasoning",
        "toolcall_start",
        "toolcall_delta",
        "toolcall_end",
        "tool_call",
    }
)


_KNOWN_FRAME_TYPES = frozenset(
    {
        "agent_result",
        "agent_error",
        "agent_event",
        "event",
        "stream_error",
        "start",
        "message_start",
        "text_delta",
        "thinking_delta",
        "reasoning_delta",
        "reasoning",
        "tool_call",
        "toolcall_start",
        "toolcall_delta",
        "toolcall_end",
        "message_end",
        "done",
        "result",
        "error",
    }
)


def is_known_agent_frame_type(frame_type: Any) -> bool:
    """Return ``True`` for a frame the normalisers understand.

    An understood frame can still produce zero events -- ``toolcall_start`` is
    buffered, ``tool_execution_update`` is deferred in V1 -- so callers must
    not read an empty result as "unrecognised frame".
    """
    return frame_type in _KNOWN_FRAME_TYPES


def normalize_provider_frame(
    frame: Mapping[str, Any], buffers: ToolBuffers
) -> Optional[ProviderStreamEvent]:
    """Convert one provider-protocol frame into an event, or ``None`` to skip."""
    frame_type = frame.get("type")
    payload = payload_of(frame)

    if frame_type == "event":
        inner = payload.get("event")
        return _normalize_provider_payload(inner if isinstance(inner, dict) else payload, buffers)
    if frame_type == "stream_error":
        return _parse_error(payload)
    if frame_type in ("start", "message_start"):
        return _message_start(payload)
    if frame_type == "text_delta":
        return TextDelta(delta=str_or(payload.get("delta")))
    if frame_type in ("thinking_delta", "reasoning_delta", "reasoning"):
        return ThinkingDelta(delta=str_or(payload.get("delta", payload.get("reasoning"))))
    if frame_type == "tool_call":
        return _tool_call(payload)
    if frame_type in ("toolcall_start", "toolcall_delta", "toolcall_end"):
        return _normalize_provider_payload(payload, buffers)
    if frame_type in ("message_end", "done", "result"):
        return _message_end(payload)
    if frame_type == "error":
        return _parse_error(payload)
    return None


def _normalize_provider_payload(
    payload: Mapping[str, Any], buffers: ToolBuffers
) -> Optional[ProviderStreamEvent]:
    kind = _event_kind(payload)
    if kind == "start":
        message = payload.get("message")
        return _message_start(message if isinstance(message, dict) else payload)
    if kind == "text_delta":
        return TextDelta(delta=str_or(payload.get("delta")))
    if kind in ("thinking_delta", "reasoning_delta", "reasoning"):
        return ThinkingDelta(delta=str_or(payload.get("delta", payload.get("reasoning"))))
    if kind == "toolcall_start":
        index = number_or(payload.get("content_index"), len(buffers))
        buffers[index] = {
            "id": optional_str(payload.get("id")),
            "name": optional_str(payload.get("name")),
            "args": "",
        }
        return None
    if kind == "toolcall_delta":
        index = number_or(payload.get("content_index"), 0)
        buffered = buffers.setdefault(index, {"id": None, "name": None, "args": ""})
        buffered["args"] = str(buffered.get("args", "")) + str_or(payload.get("delta"))
        return None
    if kind == "toolcall_end":
        return _buffered_tool_call(payload, buffers)
    if kind == "tool_call":
        return _tool_call(payload)
    if kind in ("done", "message_end"):
        return _message_end(payload)
    if kind in ("stream_error", "error"):
        return _parse_error(payload)
    return None


def normalize_agent_frame(frame: Mapping[str, Any], buffers: ToolBuffers) -> List[AgentStreamEvent]:
    """Convert one agent-protocol frame into zero or more events."""
    frame_type = frame.get("type")
    if frame_type == "agent_result":
        return [_agent_end(json_payload_field(frame, "result_json"))]
    if frame_type == "agent_error":
        return [_parse_error(payload_of(frame))]
    if frame_type == "agent_event":
        return _normalize_agent_event(json_payload_field(frame, "event_json"), buffers)
    if frame_type == "event":
        payload = payload_of(frame)
        merged: Dict[str, Any] = dict(frame)
        if payload is not frame:
            merged.update(payload)
        inner_raw = merged.get("event")
        inner = inner_raw if isinstance(inner_raw, dict) else merged
        kind = _event_kind(inner)
        if kind in _AGENT_EVENT_TYPES:
            promoted = dict(inner)
            promoted["type"] = kind
            return _normalize_agent_event(promoted, buffers)
    provider_event = normalize_provider_frame(frame, buffers)
    return [provider_event] if provider_event is not None else []


def _normalize_agent_event(
    event: Mapping[str, Any], buffers: ToolBuffers
) -> List[AgentStreamEvent]:
    kind = _event_kind(event)
    if event.get("type") or event.get("event_type"):
        data: Mapping[str, Any] = event
    else:
        nested = event.get(kind)
        data = nested if isinstance(nested, dict) else event

    if kind == "agent_start":
        return [AgentStart(session_id=optional_str(data.get("session_id")))]
    if kind == "turn_start":
        return [TurnStart()]
    if kind == "turn_end":
        return [
            TurnEnd(
                stop_reason=optional_str(data.get("stop_reason")),
                error_message=optional_str(data.get("error_message")),
            )
        ]
    if kind == "tool_execution_start":
        return [
            ToolExecutionStart(
                tool_call_id=str_or(data.get("tool_call_id")),
                tool_name=str_or(data.get("tool_name")),
            )
        ]
    if kind == "tool_execution_end":
        is_error = data.get("is_error")
        return [
            ToolExecutionEnd(
                tool_call_id=str_or(data.get("tool_call_id")),
                is_error=is_error if isinstance(is_error, bool) else None,
            )
        ]
    if kind == "tool_execution_update":
        return []
    if kind == "agent_end":
        return [_agent_end(data)]
    if kind == "message_start":
        message = data.get("message")
        return [_message_start(message if isinstance(message, dict) else data)]
    if kind == "message_update":
        inner = data.get("event")
        provider_event = _normalize_provider_payload(
            inner if isinstance(inner, dict) else data, buffers
        )
        return [provider_event] if provider_event is not None else []
    if kind in _PROVIDER_EVENT_TYPES:
        provider_event = _normalize_provider_payload(event, buffers)
        return [provider_event] if provider_event is not None else []
    if kind == "message_end":
        message = data.get("message")
        return [_message_end(message if isinstance(message, dict) else data)]
    if kind == "error":
        return [_parse_error(data)]
    return []


def _event_kind(event: Mapping[str, Any]) -> str:
    explicit = optional_str(event.get("type"))
    event_type = optional_str(event.get("event_type"))
    if explicit == "event" and event_type:
        return event_type
    if explicit:
        return explicit
    if event_type:
        return event_type
    for key in event:
        return str(key)
    return ""


def _message_start(data: Mapping[str, Any]) -> MessageStart:
    return MessageStart(
        provider_id=optional_str(data.get("provider_id", data.get("provider"))),
        api=optional_str(data.get("api")),
        model_id=optional_str(data.get("model_id", data.get("model"))),
    )


def _message_end(data: Mapping[str, Any]) -> MessageEnd:
    raw_message = data.get("message")
    message = raw_message if isinstance(raw_message, dict) else data
    return MessageEnd(
        usage=parse_usage(message.get("usage", data.get("usage", message))),
        stop_reason=optional_str(
            data.get("stop_reason", data.get("reason", message.get("stop_reason")))
        ),
        error_message=optional_str(
            data.get("error_message", message.get("error_message"))
        ),
    )


def _agent_end(data: Mapping[str, Any]) -> AgentEnd:
    return AgentEnd(
        usage=parse_usage(data.get("usage", data)),
        stop_reason=optional_str(data.get("stop_reason", data.get("reason"))),
        error_message=optional_str(data.get("error_message")),
        provider_id=optional_str(data.get("provider_id", data.get("provider"))),
        api=optional_str(data.get("api")),
    )


def _tool_call(data: Mapping[str, Any]) -> ToolCall:
    return ToolCall(
        tool_call_id=str_or(data.get("tool_call_id", data.get("id"))),
        name=str_or(data.get("name")),
        arguments_json=str_or(data.get("arguments_json")),
    )


def _buffered_tool_call(data: Mapping[str, Any], buffers: ToolBuffers) -> ToolCall:
    index = number_or(data.get("content_index"), 0)
    buffered = buffers.pop(index, {})
    return ToolCall(
        tool_call_id=str_or(data.get("tool_call_id", data.get("id", buffered.get("id")))),
        name=str_or(data.get("name", buffered.get("name"))),
        arguments_json=str_or(data.get("arguments_json", buffered.get("args"))),
    )


def _parse_error(data: Mapping[str, Any]) -> StreamError:
    return StreamError(
        message=str_or(
            data.get("message", data.get("error_message", data.get("reason"))), "stream error"
        ),
        code=optional_str(data.get("code", data.get("error_code"))),
        provider_id=optional_str(data.get("provider_id")),
    )


def parse_usage(raw: Any) -> Optional[Usage]:
    """Parse a usage object, accepting both ``input`` and ``input_tokens``."""
    if not isinstance(raw, dict):
        return None
    inp = raw.get("input", raw.get("input_tokens"))
    out = raw.get("output", raw.get("output_tokens"))
    if not isinstance(inp, int) or not isinstance(out, int):
        return None
    if isinstance(inp, bool) or isinstance(out, bool):
        return None
    cache_read = raw.get("cache_read")
    cache_write = raw.get("cache_write")
    return Usage(
        input=inp,
        output=out,
        cache_read=cache_read if isinstance(cache_read, int) and not isinstance(cache_read, bool) else None,
        cache_write=cache_write if isinstance(cache_write, int) and not isinstance(cache_write, bool) else None,
    )


def add_usage(left: Usage, right: Usage) -> Usage:
    """Sum two usage records, keeping cache fields present when either has one."""
    cache_read = None
    if left.cache_read is not None or right.cache_read is not None:
        cache_read = (left.cache_read or 0) + (right.cache_read or 0)
    cache_write = None
    if left.cache_write is not None or right.cache_write is not None:
        cache_write = (left.cache_write or 0) + (right.cache_write or 0)
    return Usage(
        input=left.input + right.input,
        output=left.output + right.output,
        cache_read=cache_read,
        cache_write=cache_write,
    )


def parse_completion_response(raw: Any) -> CompletionResponse:
    """Parse a provider ``result`` / ``complete_response`` payload."""
    data: Mapping[str, Any] = raw if isinstance(raw, dict) else {}
    raw_message = data.get("message")
    message: Mapping[str, Any] = raw_message if isinstance(raw_message, dict) else data
    return CompletionResponse(
        message=AssistantMessage(role="assistant", content=parse_content(message.get("content"))),
        usage=parse_usage(message.get("usage", data.get("usage", data))),
        provider_id=str_or(
            message.get(
                "provider_id",
                message.get("provider", data.get("provider_id", data.get("provider"))),
            )
        ),
        api=str_or(message.get("api", data.get("api"))),
        model_id=str_or(
            message.get("model_id", message.get("model", data.get("model_id", data.get("model"))))
        ),
        stop_reason=optional_str(
            message.get("stop_reason", data.get("stop_reason", data.get("reason")))
        ),
        error_message=optional_str(message.get("error_message", data.get("error_message"))),
    )


def parse_agent_run_response(raw: Any) -> CompletionResponse:
    """Parse an ``agent_result`` payload into a completion response."""
    data: Mapping[str, Any] = raw if isinstance(raw, dict) else {}
    if isinstance(data.get("message"), dict):
        return parse_completion_response(data)

    raw_messages = data.get("messages")
    messages = [item for item in raw_messages if isinstance(item, dict)] if isinstance(raw_messages, list) else []
    assistant: Mapping[str, Any] = data
    for message in reversed(messages):
        if message.get("role") == "assistant":
            assistant = message
            break
    raw_terminal = data.get("result")
    terminal: Mapping[str, Any] = raw_terminal if isinstance(raw_terminal, dict) else data
    return CompletionResponse(
        message=AssistantMessage(role="assistant", content=parse_content(assistant.get("content"))),
        usage=parse_usage(assistant.get("usage", terminal.get("usage", terminal))),
        provider_id=str_or(
            assistant.get(
                "provider_id",
                assistant.get(
                    "provider", terminal.get("provider_id", terminal.get("provider"))
                ),
            )
        ),
        api=str_or(assistant.get("api", terminal.get("api"))),
        model_id=str_or(
            assistant.get(
                "model_id",
                assistant.get("model", terminal.get("model_id", terminal.get("model"))),
            )
        ),
        stop_reason=optional_str(
            assistant.get(
                "stop_reason", terminal.get("stop_reason", terminal.get("reason"))
            )
        ),
        error_message=optional_str(
            assistant.get("error_message", terminal.get("error_message"))
        ),
    )


def build_response_from_events(events: Sequence[AgentStreamEvent]) -> CompletionResponse:
    """Fold a completed agent event stream into a completion response."""
    terminal: Optional[Union[MessageEnd, AgentEnd]] = None
    message_end: Optional[MessageEnd] = None
    for event in reversed(events):
        if terminal is None and isinstance(event, (MessageEnd, AgentEnd)):
            terminal = event
        if message_end is None and isinstance(event, MessageEnd):
            message_end = event
        if terminal is not None and message_end is not None:
            break

    final_events = _final_assistant_message_events(events)
    start = next((event for event in final_events if isinstance(event, MessageStart)), None)

    usage = terminal.usage if terminal is not None else None
    if usage is None and message_end is not None:
        usage = message_end.usage

    terminal_provider_id = getattr(terminal, "provider_id", None) if terminal else None
    terminal_api = getattr(terminal, "api", None) if terminal else None

    return CompletionResponse(
        message=AssistantMessage(role="assistant", content=_content_from_events(final_events)),
        usage=usage,
        provider_id=(start.provider_id if start else None) or terminal_provider_id or "",
        api=(start.api if start else None) or terminal_api or "",
        model_id=(start.model_id if start else None) or "",
        stop_reason=terminal.stop_reason if terminal is not None else None,
        error_message=terminal.error_message if terminal is not None else None,
    )


def _final_assistant_message_events(
    events: Sequence[AgentStreamEvent],
) -> Sequence[AgentStreamEvent]:
    start_index = -1
    for index, event in enumerate(events):
        if isinstance(event, MessageStart):
            start_index = index
    if start_index < 0:
        return events
    for index in range(start_index + 1, len(events)):
        if isinstance(events[index], MessageEnd):
            return events[start_index : index + 1]
    return events[start_index:]


def _content_from_events(events: Sequence[AgentStreamEvent]) -> Content:
    parts: List[ContentPart] = []
    text = ""
    for event in events:
        if isinstance(event, TextDelta):
            text += event.delta
        elif isinstance(event, ThinkingDelta):
            if text:
                parts.append({"type": "text", "text": text})
                text = ""
            parts.append({"type": "thinking", "thinking": event.delta})
        elif isinstance(event, ToolCall):
            if text:
                parts.append({"type": "text", "text": text})
                text = ""
            parts.append(
                {
                    "type": "tool_call",
                    "tool_call_id": event.tool_call_id,
                    "name": event.name,
                    "arguments_json": event.arguments_json,
                }
            )
    if not parts:
        return text
    if text:
        parts.append({"type": "text", "text": text})
    return parts


def parse_content(raw: Any) -> Content:
    """Normalise a response's ``content`` field into a string or part list."""
    if isinstance(raw, str):
        return raw
    if not isinstance(raw, list):
        return ""
    parts: List[ContentPart] = []
    for part in raw:
        if not isinstance(part, dict):
            parts.append({"type": "text", "text": str(part)})
            continue
        if part.get("type") == "tool_call":
            parts.append(
                {
                    "type": "tool_call",
                    "tool_call_id": str_or(part.get("tool_call_id", part.get("id"))),
                    "name": str_or(part.get("name")),
                    "arguments_json": str_or(part.get("arguments_json")),
                }
            )
            continue
        parts.append(part)  # type: ignore[arg-type]
    return parts


def nack_to_stream_error(
    frame: Mapping[str, Any], fallback_provider_id: Optional[str] = None
) -> MakaiStreamError:
    """Map a ``nack`` frame to a typed stream error."""
    payload = payload_of(frame)
    code = optional_str(payload.get("error_code"))
    provider_id = optional_str(payload.get("provider_id"))
    if provider_id is None and code == "auth_required":
        provider_id = fallback_provider_id
    return MakaiStreamError(
        str_or(payload.get("reason"), "request rejected"),
        kind="provider_error",
        code=code,
        provider_id=provider_id,
    )


def error_frame_to_stream_error(frame: Mapping[str, Any]) -> MakaiStreamError:
    """Map a ``stream_error`` / ``agent_error`` frame to a typed stream error."""
    payload = payload_of(frame)
    return MakaiStreamError(
        str_or(payload.get("message", payload.get("reason")), "stream error"),
        kind="provider_error",
        code=optional_str(payload.get("code", payload.get("error_code"))),
        provider_id=optional_str(payload.get("provider_id")),
    )


_AUTH_FAILURE_MARKERS = (
    "authentication required",
    "401",
    "403",
    "unauthorized",
    "forbidden",
)
_AUTH_FAILURE_EXACT = ("auth_required", "auth_expired", "auth_refresh_failed")
_ANTHROPIC_AUTH_MARKERS = ("authentication_error", "permission_error", "invalid api key")


def is_auth_failure_message(message: Optional[str], *, api: Optional[str] = None) -> bool:
    """Mirror the runtime's auth-failure detector (spec §3.5).

    A provider turn that failed on auth still settles as a normal terminal
    event carrying ``stop_reason: "error"``; this is how the SDK recognises it
    and re-raises it on the typed auth path instead of returning a "successful"
    empty response.
    """
    if not message:
        return False
    normalized = message.lower()
    if normalized in _AUTH_FAILURE_EXACT:
        return True
    if any(marker in normalized for marker in _AUTH_FAILURE_MARKERS):
        return True
    if api == "anthropic-messages":
        return any(marker in normalized for marker in _ANTHROPIC_AUTH_MARKERS)
    return False
