"""The ``agent`` namespace: session lifecycle, tool execution, sequencing."""

from __future__ import annotations

import asyncio
import json
import re
import time
from typing import Any, Dict, List

import pytest

from conftest import FakeServerFactory, read_log
from makai._ids import new_nano_id
from makai.execution import _probe_stop_sequences, _stop_agent_with_sequence_probe
from makai.errors import TIMEOUT_CODE, MakaiAuthRequiredError, MakaiStreamError
from makai.types import (
    AgentEnd,
    AgentStart,
    AgentStreamEvent,
    MessageEnd,
    MessageStart,
    RunOptions,
    StreamError,
    TextDelta,
    ToolContext,
    ToolDefinition,
    ToolExecutionEnd,
    ToolExecutionStart,
    TurnEnd,
    TurnStart,
)

MODEL_REF = "anthropic/anthropic-messages@claude-sonnet-4-5"
NANO_ID = re.compile(r"^[0-9A-Za-z]{21}$")

DEFAULT_EVENTS: List[Dict[str, Any]] = [
    {"type": "agent_start", "session_id": "$session_id"},
    {"type": "turn_start"},
    {
        "type": "message_start",
        "provider_id": "anthropic",
        "api": "anthropic-messages",
        "model_id": "claude-sonnet-4-5",
    },
    {"type": "text_delta", "delta": "agent "},
    {"type": "text_delta", "delta": "says hi"},
    {"type": "message_end", "usage": {"input": 7, "output": 9}, "stop_reason": "end_turn"},
    {"type": "turn_end", "stop_reason": "end_turn"},
    {"type": "agent_end", "stop_reason": "end_turn"},
]


def agent_config(events: List[Dict[str, Any]], **extra: Any) -> Dict[str, Any]:
    handlers: Dict[str, Any] = {
        "agent_start": [{"type": "agent_started", "payload": {"session_id": "$session_id"}}],
        "agent_message": [
            {"type": "agent_event", "payload": {}, "event_json": event, "correlate": False}
            for event in events
        ],
    }
    config: Dict[str, Any] = {"handlers": handlers}
    config.update(extra)
    return config


async def test_run_folds_events_into_a_response(fake: FakeServerFactory) -> None:
    client = await fake.client(agent_config(DEFAULT_EVENTS))
    response = await client.agent.run(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    )
    assert response.text == "agent says hi"
    assert response.stop_reason == "end_turn"
    assert response.provider_id == "anthropic"
    assert response.model_id == "claude-sonnet-4-5"
    assert response.usage is not None and response.usage.output == 9


async def test_run_accepts_an_agent_result_frame(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "agent_start": [
                    {"type": "agent_started", "payload": {"session_id": "$session_id"}}
                ],
                "agent_message": [
                    {
                        "type": "agent_result",
                        "payload": {},
                        "result_json": {
                            "message": {
                                "role": "assistant",
                                "content": [{"type": "text", "text": "done"}],
                            },
                            "usage": {"input": 1, "output": 2},
                            "provider_id": "anthropic",
                            "api": "anthropic-messages",
                            "model_id": "claude-sonnet-4-5",
                            "stop_reason": "end_turn",
                        },
                    }
                ],
            }
        }
    )
    response = await client.agent.run(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    )
    assert response.text == "done"
    assert response.usage is not None and response.usage.input == 1


async def test_session_sequencing_and_teardown(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    config = agent_config(DEFAULT_EVENTS, log=log, track_agent_sessions=True)
    client = await fake.client(config)
    await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    await asyncio.sleep(0.2)

    frames = read_log(log)
    by_type = {frame["type"]: frame for frame in frames}
    assert [frame["type"] for frame in frames] == ["agent_start", "agent_message", "agent_stop"]

    # Sequencing is per session and starts at 1 (spec §13.1).
    assert by_type["agent_start"]["sequence"] == 1
    assert by_type["agent_message"]["sequence"] == 2
    assert by_type["agent_stop"]["sequence"] == 3

    session_ids = {frame["session_id"] for frame in frames}
    assert len(session_ids) == 1
    assert NANO_ID.match(session_ids.pop())


async def test_agent_start_carries_both_session_id_keys(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(agent_config(DEFAULT_EVENTS, log=log))
    await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])

    start = read_log(log)[0]
    payload = start["payload"]
    # The legacy alias carries the same value for pre-#198 servers (spec §13.1).
    assert payload["session_id"] == payload["resume_session_id"] == start["session_id"]
    config = json.loads(payload["config_json"])
    assert config["model_ref"] == MODEL_REF
    assert config["tools"] == []


async def test_agent_message_payload(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(agent_config(DEFAULT_EVENTS, log=log))
    await client.agent.run(
        model_ref=MODEL_REF,
        messages=[{"role": "user", "content": "hi"}],
        tools=[ToolDefinition(name="t", description="d", parameters_schema_json="{}")],
        options=RunOptions(max_tokens=32),
    )

    message = read_log(log)[1]
    body = json.loads(message["payload"]["message_json"])
    assert body["model_ref"] == MODEL_REF
    assert body["messages"] == [{"role": "user", "content": "hi"}]
    assert body["tools"] == [{"name": "t", "description": "d", "parameters_schema_json": "{}"}]
    assert json.loads(message["payload"]["options_json"]) == {"max_tokens": 32}


async def test_supplied_session_id_is_used(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(agent_config(DEFAULT_EVENTS, log=log))
    session_id = "Abcdefghijklmnopqrstu"
    await client.agent.run(
        model_ref=MODEL_REF,
        messages=[{"role": "user", "content": "hi"}],
        options=RunOptions(session_id=session_id),
    )
    assert all(frame["session_id"] == session_id for frame in read_log(log))


async def test_bad_session_id_is_rejected(fake: FakeServerFactory) -> None:
    client = await fake.client(agent_config(DEFAULT_EVENTS))
    with pytest.raises(TypeError, match="21-character alphanumeric NanoID"):
        await client.agent.run(
            model_ref=MODEL_REF,
            messages=[{"role": "user", "content": "hi"}],
            options=RunOptions(session_id="too-short"),
        )


async def test_stream_emits_lifecycle_events(fake: FakeServerFactory) -> None:
    client = await fake.client(agent_config(DEFAULT_EVENTS))
    events: List[AgentStreamEvent] = [
        event
        async for event in client.agent.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    ]
    assert [type(event) for event in events] == [
        AgentStart,
        TurnStart,
        MessageStart,
        TextDelta,
        TextDelta,
        MessageEnd,
        TurnEnd,
        AgentEnd,
    ]
    assert isinstance(events[-1], AgentEnd)
    assert events[-1].stop_reason == "end_turn"


async def test_stream_aggregates_usage_across_turns(fake: FakeServerFactory) -> None:
    events: List[Dict[str, Any]] = [
        {"type": "agent_start", "session_id": "$session_id"},
        {"type": "turn_start"},
        {"type": "message_end", "usage": {"input": 3, "output": 4, "cache_read": 1}},
        {"type": "turn_end"},
        {"type": "turn_start"},
        {"type": "message_end", "usage": {"input": 5, "output": 6}},
        {"type": "turn_end"},
        {"type": "agent_end", "stop_reason": "end_turn"},
    ]
    client = await fake.client(agent_config(events))
    collected = [
        event
        async for event in client.agent.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    ]
    end = collected[-1]
    assert isinstance(end, AgentEnd)
    assert end.usage is not None
    assert (end.usage.input, end.usage.output) == (8, 10)
    assert end.usage.cache_read == 1


async def test_stream_synthesises_agent_start(fake: FakeServerFactory) -> None:
    """The runtime may not emit agent_start; consumers still get one first."""
    events: List[Dict[str, Any]] = [
        {"type": "text_delta", "delta": "hi"},
        {"type": "agent_end", "stop_reason": "end_turn"},
    ]
    client = await fake.client(agent_config(events))
    collected = [
        event
        async for event in client.agent.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    ]
    assert isinstance(collected[0], AgentStart)
    assert collected[0].session_id is not None
    assert NANO_ID.match(collected[0].session_id)


async def test_client_tool_is_executed_and_answered(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {
                "agent_start": [
                    {"type": "agent_started", "payload": {"session_id": "$session_id"}}
                ],
                "agent_message": [
                    {
                        "type": "agent_event",
                        "payload": {},
                        "correlate": False,
                        "event_json": {
                            "type": "tool_execution_start",
                            "tool_call_id": "call-1",
                            "tool_name": "lookup",
                        },
                    },
                    {
                        "type": "tool_execute",
                        "correlate": False,
                        "payload": {
                            "tool_call_id": "call-1",
                            "tool_name": "lookup",
                            "args_json": '{"city":"SF"}',
                        },
                    },
                ],
                "tool_result": [
                    {
                        "type": "agent_event",
                        "payload": {},
                        "correlate": False,
                        "event_json": {
                            "type": "tool_execution_end",
                            "tool_call_id": "call-1",
                            "is_error": False,
                        },
                    },
                    {
                        "type": "agent_event",
                        "payload": {},
                        "correlate": False,
                        "event_json": {"type": "text_delta", "delta": "it is raining"},
                    },
                    {
                        "type": "agent_event",
                        "payload": {},
                        "correlate": False,
                        "event_json": {"type": "agent_end", "stop_reason": "end_turn"},
                    },
                ],
            },
        }
    )

    calls: List[tuple[Dict[str, Any], ToolContext]] = []

    def lookup(args: Dict[str, Any], context: ToolContext) -> str:
        calls.append((args, context))
        return f"weather for {args['city']}"

    response = await client.agent.run(
        model_ref=MODEL_REF,
        messages=[{"role": "user", "content": "weather?"}],
        tools=[
            ToolDefinition(
                name="lookup", description="d", parameters_schema_json="{}", execute=lookup
            )
        ],
    )

    assert response.text == "it is raining"
    assert len(calls) == 1
    args, context = calls[0]
    assert args == {"city": "SF"}
    assert context.tool_call_id == "call-1"
    assert context.tool_name == "lookup"

    tool_result = next(frame for frame in read_log(log) if frame["type"] == "tool_result")
    tool_execute_id = next(
        frame["message_id"] for frame in read_log(log) if frame["type"] == "agent_message"
    )
    assert tool_result["payload"]["tool_call_id"] == "call-1"
    assert tool_result["payload"]["is_error"] is False
    assert json.loads(tool_result["payload"]["result_json"]) == [
        {"type": "text", "text": "weather for SF"}
    ]
    # in_reply_to names the tool_execute envelope, never the agent_message.
    assert tool_result["in_reply_to"] != tool_execute_id


async def test_async_tool_callback_is_awaited(fake: FakeServerFactory) -> None:
    client = await fake.client(_tool_roundtrip_config())

    async def lookup(args: Dict[str, Any], context: ToolContext) -> str:
        await asyncio.sleep(0)
        return "async result"

    response = await client.agent.run(
        model_ref=MODEL_REF,
        messages=[{"role": "user", "content": "go"}],
        tools=[
            ToolDefinition(
                name="lookup", description="d", parameters_schema_json="{}", execute=lookup
            )
        ],
    )
    assert response.text == "done"


async def test_tool_exception_is_reported_not_raised(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    config = _tool_roundtrip_config()
    config["log"] = log
    client = await fake.client(config)

    def boom(args: Dict[str, Any], context: ToolContext) -> str:
        raise RuntimeError("tool exploded")

    response = await client.agent.run(
        model_ref=MODEL_REF,
        messages=[{"role": "user", "content": "go"}],
        tools=[
            ToolDefinition(
                name="lookup", description="d", parameters_schema_json="{}", execute=boom
            )
        ],
    )
    assert response.text == "done"

    tool_result = next(frame for frame in read_log(log) if frame["type"] == "tool_result")
    assert tool_result["payload"]["is_error"] is True
    assert json.loads(tool_result["payload"]["result_json"]) == [
        {"type": "text", "text": "tool exploded"}
    ]


async def test_unknown_tool_is_reported_as_not_executable(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    config = _tool_roundtrip_config()
    config["log"] = log
    client = await fake.client(config)

    await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "go"}])

    tool_result = next(frame for frame in read_log(log) if frame["type"] == "tool_result")
    assert tool_result["payload"]["is_error"] is True
    assert "not executable by this client" in tool_result["payload"]["result_json"]


async def test_tool_without_execute_is_reported(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    config = _tool_roundtrip_config()
    config["log"] = log
    client = await fake.client(config)

    await client.agent.run(
        model_ref=MODEL_REF,
        messages=[{"role": "user", "content": "go"}],
        tools=[ToolDefinition(name="lookup", description="d", parameters_schema_json="{}")],
    )
    tool_result = next(frame for frame in read_log(log) if frame["type"] == "tool_result")
    assert tool_result["payload"]["is_error"] is True


def _tool_roundtrip_config() -> Dict[str, Any]:
    return {
        "handlers": {
            "agent_start": [{"type": "agent_started", "payload": {"session_id": "$session_id"}}],
            "agent_message": [
                {
                    "type": "tool_execute",
                    "correlate": False,
                    "payload": {
                        "tool_call_id": "call-1",
                        "tool_name": "lookup",
                        "args_json": "{}",
                    },
                }
            ],
            "tool_result": [
                {
                    "type": "agent_event",
                    "payload": {},
                    "correlate": False,
                    "event_json": {"type": "text_delta", "delta": "done"},
                },
                {
                    "type": "agent_event",
                    "payload": {},
                    "correlate": False,
                    "event_json": {"type": "agent_end", "stop_reason": "end_turn"},
                },
            ],
        }
    }


async def test_agent_busy_nack_is_surfaced(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "agent_start": [
                    {
                        "type": "nack",
                        "payload": {"error_code": "agent_busy", "reason": "session already exists"},
                    }
                ]
            }
        }
    )
    with pytest.raises(MakaiStreamError) as excinfo:
        await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    assert excinfo.value.code == "agent_busy"


async def test_a_rejected_start_does_not_stop_the_session(fake: FakeServerFactory) -> None:
    """``agent_busy`` means someone else owns the id; do not stop their run.

    The stop sequence is fixed at 3, so a blind teardown could match a foreign
    session's counter and kill a run this client never started.
    """
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {
                "agent_start": [
                    {
                        "type": "nack",
                        "payload": {"error_code": "agent_busy", "reason": "session already exists"},
                    }
                ]
            },
        }
    )
    with pytest.raises(MakaiStreamError):
        await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    await asyncio.sleep(0.2)
    assert [frame["type"] for frame in read_log(log)] == ["agent_start"]


async def test_a_rejected_start_via_agent_error_does_not_stop_the_session(
    fake: FakeServerFactory,
) -> None:
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {
                "agent_start": [
                    {
                        "type": "agent_error",
                        "payload": {"code": "agent_busy", "message": "session already exists"},
                    }
                ]
            },
        }
    )
    with pytest.raises(MakaiStreamError):
        await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    await asyncio.sleep(0.2)
    assert [frame["type"] for frame in read_log(log)] == ["agent_start"]


async def test_reusing_a_session_id_concurrently_fails_locally(
    fake: FakeServerFactory,
) -> None:
    """Two live runs cannot share a session id: routing would be ambiguous.

    The transport refuses the second route before the frame is sent, so the
    caller gets a clear local error instead of the server's ``agent_busy``.
    """
    slow_events = [dict(event, delay_ms=30) for event in DEFAULT_EVENTS]
    client = await fake.client(agent_config(slow_events, track_agent_sessions=True))
    options = RunOptions(session_id="Abcdefghijklmnopqrstu")

    outcomes = await asyncio.gather(
        client.agent.run(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "1"}], options=options
        ),
        client.agent.run(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "2"}], options=options
        ),
        return_exceptions=True,
    )
    failures = [item for item in outcomes if isinstance(item, MakaiStreamError)]
    assert len(failures) == 1
    assert "already open" in str(failures[0])


async def test_a_session_id_can_be_reused_after_the_session_is_stopped(
    fake: FakeServerFactory,
) -> None:
    """Sequential reuse works because agent_stop removes the session server-side.

    This is not resumption: the second run is a brand-new session that happens
    to carry the same correlation key, and it resends the full context.
    """
    log = fake.log_path()
    client = await fake.client(agent_config(DEFAULT_EVENTS, log=log, track_agent_sessions=True))
    options = RunOptions(session_id="Abcdefghijklmnopqrstu")

    first = await client.agent.run(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "1"}], options=options
    )
    second = await client.agent.run(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "2"}], options=options
    )
    assert first.text == second.text == "agent says hi"

    await asyncio.sleep(0.2)
    kinds = [frame["type"] for frame in read_log(log)]
    assert kinds == [
        "agent_start",
        "agent_message",
        "agent_stop",
        "agent_start",
        "agent_message",
        "agent_stop",
    ]
    # Each run restarts the session counter at 1 (spec §13.1).
    sequences = [frame["sequence"] for frame in read_log(log)]
    assert sequences == [1, 2, 3, 1, 2, 3]


async def test_agent_error_settlement_is_surfaced(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "agent_start": [
                    {"type": "agent_started", "payload": {"session_id": "$session_id"}}
                ],
                "agent_message": [
                    {
                        "type": "agent_error",
                        "correlate": False,
                        "payload": {"code": "internal_error", "message": "loop failed"},
                    }
                ],
            }
        }
    )
    with pytest.raises(MakaiStreamError) as excinfo:
        await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    assert excinfo.value.code == "internal_error"
    assert str(excinfo.value) == "loop failed"


async def test_malformed_event_json_is_rejected(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "agent_start": [
                    {"type": "agent_started", "payload": {"session_id": "$session_id"}}
                ],
                "agent_message": [
                    {
                        "type": "agent_event",
                        "correlate": False,
                        "payload": {"event_json": "not-json"},
                    }
                ],
            }
        }
    )
    with pytest.raises(MakaiStreamError, match="malformed JSON"):
        await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])


async def test_auth_failure_in_agent_end_raises_typed_error(fake: FakeServerFactory) -> None:
    events: List[Dict[str, Any]] = [
        {"type": "turn_end", "stop_reason": "error", "error_message": "auth_required"},
        {
            "type": "agent_end",
            "stop_reason": "error",
            "error_message": "auth_required",
            "provider_id": "anthropic",
            "api": "anthropic-messages",
        },
    ]
    client = await fake.client(agent_config(events))
    with pytest.raises(MakaiAuthRequiredError) as excinfo:
        await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    assert excinfo.value.provider_id == "anthropic"


async def test_terminal_stream_error_ends_the_stream(fake: FakeServerFactory) -> None:
    events: List[Dict[str, Any]] = [
        {"type": "text_delta", "delta": "partial"},
        {"type": "error", "message": "loop failed", "code": "internal_error"},
        {"type": "text_delta", "delta": "never"},
    ]
    client = await fake.client(agent_config(events))
    collected = [
        event
        async for event in client.agent.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    ]
    assert isinstance(collected[-1], StreamError)
    assert collected[-1].code == "internal_error"
    assert not any(isinstance(event, TextDelta) and event.delta == "never" for event in collected)


async def test_run_raises_on_terminal_stream_error(fake: FakeServerFactory) -> None:
    events = [{"type": "error", "message": "loop failed", "code": "internal_error"}]
    client = await fake.client(agent_config(events))
    with pytest.raises(MakaiStreamError) as excinfo:
        await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    assert excinfo.value.code == "internal_error"


async def test_stop_is_sent_even_when_the_run_fails(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    events = [{"type": "error", "message": "loop failed", "code": "internal_error"}]
    client = await fake.client(agent_config(events, log=log))
    with pytest.raises(MakaiStreamError):
        await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    await asyncio.sleep(0.2)
    assert any(frame["type"] == "agent_stop" for frame in read_log(log))


async def test_breaking_out_of_agent_stream_stops_the_session(
    fake: FakeServerFactory,
) -> None:
    log = fake.log_path()
    slow_events = [dict(event, delay_ms=40) for event in DEFAULT_EVENTS]
    client = await fake.client(agent_config(slow_events, log=log))

    stream = client.agent.stream(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    )
    async for event in stream:
        if isinstance(event, TextDelta):
            break
    await stream.aclose()
    await asyncio.sleep(0.3)

    frames = read_log(log)
    stops = [frame for frame in frames if frame["type"] == "agent_stop"]
    assert len(stops) == 1
    assert stops[0]["sequence"] == 3
    assert stops[0]["payload"]["session_id"] == frames[0]["session_id"]


async def test_cancelling_a_run_stops_the_session(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {
                "agent_start": [
                    {"type": "agent_started", "payload": {"session_id": "$session_id"}}
                ]
            },
        },
        response_timeout=10.0,
    )
    task = asyncio.create_task(
        client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    )
    await asyncio.sleep(0.3)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    await asyncio.sleep(0.3)
    assert any(frame["type"] == "agent_stop" for frame in read_log(log))


async def test_timeout_carries_session_diagnostics(fake: FakeServerFactory) -> None:
    client = await fake.client({"ack": False}, response_timeout=0.3)
    with pytest.raises(MakaiStreamError) as excinfo:
        await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    assert excinfo.value.code == TIMEOUT_CODE
    assert excinfo.value.diagnostics is not None
    assert NANO_ID.match(str(excinfo.value.diagnostics["session_id"]))
    assert excinfo.value.diagnostics["model_ref"] == MODEL_REF


async def test_tool_execution_events_are_surfaced(fake: FakeServerFactory) -> None:
    events: List[Dict[str, Any]] = [
        {"type": "tool_execution_start", "tool_call_id": "c1", "tool_name": "lookup"},
        {"type": "tool_execution_update", "tool_call_id": "c1"},
        {"type": "tool_execution_end", "tool_call_id": "c1", "is_error": False},
        {"type": "agent_end", "stop_reason": "end_turn"},
    ]
    client = await fake.client(agent_config(events))
    collected = [
        event
        async for event in client.agent.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    ]
    kinds = [type(event) for event in collected]
    # tool_execution_update is deferred in V1 and is dropped.
    assert kinds == [AgentStart, ToolExecutionStart, ToolExecutionEnd, AgentEnd]
    start = collected[1]
    assert isinstance(start, ToolExecutionStart)
    assert start.tool_call_id == "c1"
    assert start.tool_name == "lookup"
    end = collected[2]
    assert isinstance(end, ToolExecutionEnd)
    assert end.is_error is False


async def test_concurrent_agent_runs_are_independent(fake: FakeServerFactory) -> None:
    slow_events = [dict(event, delay_ms=5) for event in DEFAULT_EVENTS]
    client = await fake.client(agent_config(slow_events, track_agent_sessions=True))
    responses = await asyncio.gather(
        *(
            client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
            for _ in range(4)
        )
    )
    assert all(response.text == "agent says hi" for response in responses)


async def test_a_caller_supplied_id_is_not_stopped_when_the_start_reply_is_lost(
    fake: FakeServerFactory,
) -> None:
    """Spec 6.1: teardown after an unknown start outcome needs an exclusive id.

    A caller-supplied id may name someone else's live run, and a stop that
    happens to carry their next expected sequence would cancel it.
    """
    log = fake.log_path()
    client = await fake.client(
        {"log": log, "handlers": {"agent_start": [{"type": "silent"}]}},
        response_timeout=0.3,
    )
    with pytest.raises(MakaiStreamError):
        await client.agent.run(
            model_ref=MODEL_REF,
            messages=[{"role": "user", "content": "hi"}],
            options=RunOptions(session_id=new_nano_id()),
        )
    await asyncio.sleep(0.2)
    assert [frame["type"] for frame in read_log(log)] == ["agent_start"]


async def test_a_generated_id_is_stopped_when_the_start_reply_is_lost(
    fake: FakeServerFactory,
) -> None:
    """A locally minted id cannot be anyone else's, so teardown is safe."""
    log = fake.log_path()
    client = await fake.client(
        {"log": log, "handlers": {"agent_start": [{"type": "silent"}]}},
        response_timeout=0.3,
    )
    with pytest.raises(MakaiStreamError):
        await client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    await asyncio.sleep(0.2)
    frames = read_log(log)
    assert [frame["type"] for frame in frames] == ["agent_start", "agent_stop"]
    # agent_message was never sent, so the host still expects sequence 2.
    assert frames[1]["sequence"] == 2


async def test_stream_raises_auth_required_from_an_agent_result(
    fake: FakeServerFactory,
) -> None:
    """The host settles provider auth failures through agent_result too."""
    client = await fake.client(
        {
            "handlers": {
                "agent_start": [
                    {"type": "agent_started", "payload": {"session_id": "$session_id"}}
                ],
                "agent_message": [
                    {
                        "type": "agent_result",
                        "payload": {},
                        "result_json": {
                            "message": {"role": "assistant", "content": []},
                            "provider_id": "anthropic",
                            "api": "anthropic-messages",
                            "stop_reason": "error",
                            "error_message": "auth_required",
                        },
                    }
                ],
            }
        }
    )

    with pytest.raises(MakaiAuthRequiredError) as excinfo:
        async for _ in client.agent.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        ):
            pass
    assert excinfo.value.provider_id == "anthropic"


async def test_a_rejected_stop_sequence_is_retried_with_the_other_candidate() -> None:
    """The host rejects a stop whose sequence does not match its counter."""
    sent: List[Dict[str, Any]] = []

    class StubTransport:
        async def send_best_effort(self, frame: Dict[str, Any]) -> None:
            sent.append(frame)

    class StubRoute:
        def __init__(self) -> None:
            self.drained = False

        async def next_frame(self, timeout: float) -> Dict[str, Any]:
            last = sent[-1]
            if last["sequence"] == 3:
                return {
                    "type": "agent_error",
                    "in_reply_to": last["message_id"],
                    "payload": {"code": "invalid_request", "message": "invalid sequence"},
                }
            return {"type": "agent_stopped", "in_reply_to": last["message_id"], "payload": {}}

        async def drain(self, idle: float = 0.05, budget: float = 0.25) -> None:
            self.drained = True

    route = StubRoute()
    await _stop_agent_with_sequence_probe(
        StubTransport(), route, "Abcdefghijklmnopqrstu", 3  # type: ignore[arg-type]
    )

    assert [frame["sequence"] for frame in sent] == [3, 2]
    assert route.drained


async def test_an_accepted_stop_sequence_is_not_retried() -> None:
    sent: List[Dict[str, Any]] = []

    class StubTransport:
        async def send_best_effort(self, frame: Dict[str, Any]) -> None:
            sent.append(frame)

    class StubRoute:
        async def next_frame(self, timeout: float) -> Dict[str, Any]:
            return {"type": "agent_stopped", "in_reply_to": sent[-1]["message_id"], "payload": {}}

        async def drain(self, idle: float = 0.05, budget: float = 0.25) -> None:
            return None

    await _stop_agent_with_sequence_probe(
        StubTransport(), StubRoute(), "Abcdefghijklmnopqrstu", 2  # type: ignore[arg-type]
    )

    assert [frame["sequence"] for frame in sent] == [2]


async def test_the_stop_probe_gives_up_when_the_route_is_already_dead(
    fake: FakeServerFactory,
) -> None:
    """A failed route must end the probe, not be retried until the budget runs out.

    next_frame re-arms the queued failure for the next waiter, so treating it
    as a quiet slice spins without ever suspending: both candidates burn their
    full budget while nothing can answer.
    """
    transport = await fake.transport({"ack": False})
    session_id = new_nano_id()
    async with transport.route(session_id=session_id) as route:
        await transport.close()
        started = time.perf_counter()
        await _probe_stop_sequences(transport, route, session_id, (2, 1))
        elapsed = time.perf_counter() - started

    assert elapsed < 0.1


async def test_cancelling_during_the_start_send_still_stops_the_session(
    fake: FakeServerFactory, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A cancel landing mid-send must not orphan the session.

    send() can suspend on the write lock or in drain() with the start frame
    already queued to the child. With the send outside the try, that
    cancellation skipped the finally and the host kept a session nobody
    stopped until idle-TTL eviction (30 minutes by default).
    """
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {
                "agent_start": [
                    {"type": "agent_started", "payload": {"session_id": "$session_id"}}
                ]
            },
        },
        response_timeout=10.0,
    )

    transport = client.transport
    real_send = transport.send
    suspended = asyncio.Event()
    held = asyncio.Event()

    async def send_holding_the_first_start(frame: Dict[str, Any]) -> None:
        if frame.get("type") == "agent_start" and not suspended.is_set():
            suspended.set()
            await held.wait()
        await real_send(frame)

    monkeypatch.setattr(transport, "send", send_holding_the_first_start)

    task = asyncio.create_task(
        client.agent.run(model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}])
    )
    await asyncio.wait_for(suspended.wait(), 3.0)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    await asyncio.sleep(0.3)

    assert any(frame["type"] == "agent_stop" for frame in read_log(log))
