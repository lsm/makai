"""The ``provider`` namespace: request payloads, event normalisation, errors."""

from __future__ import annotations

import asyncio
import json
from contextlib import aclosing
from typing import Any, Dict, List

import pytest

from makai._wire import number_or
from conftest import FakeServerFactory, read_log
from makai.errors import TIMEOUT_CODE, MakaiAuthRequiredError, MakaiProtocolError, MakaiStreamError
from makai.types import (
    MessageEnd,
    MessageStart,
    ProviderStreamEvent,
    RunOptions,
    StreamError,
    TextDelta,
    ThinkingDelta,
    ToolCall,
    ToolDefinition,
)

MODEL_REF = "anthropic/anthropic-messages@claude-sonnet-4-5"

RESULT_PAYLOAD = {
    "role": "assistant",
    "content": [{"type": "text", "text": "hello"}],
    "usage": {"input": 3, "output": 5, "cache_read": 1, "cache_write": 0},
    "provider_id": "anthropic",
    "api": "anthropic-messages",
    "model_id": "claude-sonnet-4-5",
    "stop_reason": "end_turn",
}


def stream_config(events: List[Dict[str, Any]], **extra: Any) -> Dict[str, Any]:
    return {
        "handlers": {
            "stream_request": [
                {"type": event["type"], "payload": event} for event in events
            ]
        },
        **extra,
    }


async def test_complete_parses_result(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {"handlers": {"complete_request": [{"type": "result", "payload": RESULT_PAYLOAD}]}}
    )
    response = await client.provider.complete(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    )
    assert response.provider_id == "anthropic"
    assert response.api == "anthropic-messages"
    assert response.model_id == "claude-sonnet-4-5"
    assert response.stop_reason == "end_turn"
    assert response.text == "hello"
    assert response.usage is not None
    assert (response.usage.input, response.usage.output) == (3, 5)
    assert response.usage.cache_read == 1


async def test_complete_builds_the_wire_payload(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {"complete_request": [{"type": "result", "payload": RESULT_PAYLOAD}]},
        }
    )
    await client.provider.complete(
        model_ref=MODEL_REF,
        messages=[
            {"role": "system", "content": "be terse"},
            {"role": "developer", "content": "and precise"},
            {"role": "user", "content": "hi"},
        ],
        tools=[
            ToolDefinition(name="t", description="d", parameters_schema_json='{"type":"object"}')
        ],
        options=RunOptions(max_tokens=64, temperature=0.2, metadata={"trace": "abc"}),
    )

    request = read_log(log)[0]
    assert request["type"] == "complete_request"
    assert request["sequence"] == 1
    payload = request["payload"]
    assert payload["model_ref"] == MODEL_REF
    assert payload["model"] == {
        "id": "claude-sonnet-4-5",
        "name": "claude-sonnet-4-5",
        "api": "anthropic-messages",
        "provider": "anthropic",
        "base_url": "",
    }
    # system/developer turns are folded into one system_prompt.
    assert payload["context"]["system_prompt"] == "be terse\n\nand precise"
    assert payload["context"]["messages"] == [{"role": "user", "content": "hi"}]
    assert payload["context"]["tools"] == [
        {"name": "t", "description": "d", "parameters_schema_json": '{"type":"object"}'}
    ]
    assert payload["options"] == {
        "temperature": 0.2,
        "max_tokens": 64,
        "metadata": {"trace": "abc"},
    }
    assert "include_partial" not in payload


async def test_stream_suppresses_partials(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        stream_config([{"type": "message_end", "stop_reason": "end_turn"}], log=log)
    )
    async for _ in client.provider.stream(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    ):
        pass
    assert read_log(log)[0]["payload"]["include_partial"] is False


async def test_stream_normalises_events(fake: FakeServerFactory) -> None:
    client = await fake.client(
        stream_config(
            [
                {
                    "type": "message_start",
                    "provider_id": "anthropic",
                    "api": "anthropic-messages",
                    "model_id": "claude-sonnet-4-5",
                },
                {"type": "text_delta", "delta": "hel"},
                # Provider-native "reasoning" normalises to thinking_delta.
                {"type": "reasoning", "delta": "hmm"},
                {"type": "text_delta", "delta": "lo"},
                {
                    "type": "message_end",
                    "usage": {"input": 3, "output": 5},
                    "stop_reason": "end_turn",
                },
            ]
        )
    )
    events: List[ProviderStreamEvent] = [
        event
        async for event in client.provider.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    ]

    assert isinstance(events[0], MessageStart)
    assert events[0].provider_id == "anthropic"
    assert isinstance(events[1], TextDelta) and events[1].delta == "hel"
    assert isinstance(events[2], ThinkingDelta) and events[2].delta == "hmm"
    assert isinstance(events[3], TextDelta) and events[3].delta == "lo"
    assert isinstance(events[4], MessageEnd)
    assert events[4].stop_reason == "end_turn"
    assert events[4].usage is not None and events[4].usage.output == 5
    assert len(events) == 5


async def test_stream_buffers_tool_call_deltas(fake: FakeServerFactory) -> None:
    client = await fake.client(
        stream_config(
            [
                {"type": "toolcall_start", "content_index": 0, "id": "call-1", "name": "lookup"},
                {"type": "toolcall_delta", "content_index": 0, "delta": '{"city":'},
                {"type": "toolcall_delta", "content_index": 0, "delta": '"SF"}'},
                {"type": "toolcall_end", "content_index": 0},
                {"type": "message_end", "stop_reason": "tool_use"},
            ]
        )
    )
    events = [
        event
        async for event in client.provider.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    ]
    tool_calls = [event for event in events if isinstance(event, ToolCall)]
    assert len(tool_calls) == 1
    assert tool_calls[0].tool_call_id == "call-1"
    assert tool_calls[0].name == "lookup"
    assert json.loads(tool_calls[0].arguments_json) == {"city": "SF"}


async def test_stream_ends_on_terminal_error(fake: FakeServerFactory) -> None:
    client = await fake.client(
        stream_config(
            [
                {"type": "text_delta", "delta": "partial"},
                {"type": "error", "message": "provider exploded", "code": "upstream_error"},
                {"type": "text_delta", "delta": "never delivered"},
            ]
        )
    )
    events = [
        event
        async for event in client.provider.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    ]
    assert len(events) == 2
    assert isinstance(events[1], StreamError)
    assert events[1].code == "upstream_error"


async def test_auth_required_nack_raises_typed_error(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "complete_request": [
                    {
                        "type": "nack",
                        "payload": {
                            "error_code": "auth_required",
                            "reason": "login required",
                            "provider_id": "anthropic",
                        },
                    }
                ]
            }
        }
    )
    with pytest.raises(MakaiAuthRequiredError) as excinfo:
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    assert excinfo.value.provider_id == "anthropic"
    assert excinfo.value.code == "auth_required"
    assert excinfo.value.kind == "provider_error"


async def test_auth_required_without_provider_id_uses_model_ref(
    fake: FakeServerFactory,
) -> None:
    client = await fake.client(
        {
            "handlers": {
                "complete_request": [
                    {
                        "type": "nack",
                        "payload": {"error_code": "auth_required", "reason": "login required"},
                    }
                ]
            }
        }
    )
    with pytest.raises(MakaiAuthRequiredError) as excinfo:
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    assert excinfo.value.provider_id == "anthropic"


async def test_auth_failure_in_result_is_re_raised(fake: FakeServerFactory) -> None:
    """A failed auth turn settles as a normal result; it must not look successful."""
    client = await fake.client(
        {
            "handlers": {
                "complete_request": [
                    {
                        "type": "result",
                        "payload": {
                            "role": "assistant",
                            "content": "",
                            "provider_id": "anthropic",
                            "api": "anthropic-messages",
                            "stop_reason": "error",
                            "error_message": "auth_required",
                        },
                    }
                ]
            }
        }
    )
    with pytest.raises(MakaiAuthRequiredError):
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )


async def test_non_auth_nack_keeps_its_code(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "complete_request": [
                    {
                        "type": "nack",
                        "payload": {"error_code": "invalid_request", "reason": "bad model"},
                    }
                ]
            }
        }
    )
    with pytest.raises(MakaiStreamError) as excinfo:
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    assert not isinstance(excinfo.value, MakaiAuthRequiredError)
    assert excinfo.value.code == "invalid_request"


async def test_stream_error_frame_maps_to_error(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "complete_request": [
                    {"type": "stream_error", "payload": {"message": "boom", "code": "bad"}}
                ]
            }
        }
    )
    with pytest.raises(MakaiStreamError) as excinfo:
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    assert excinfo.value.code == "bad"


async def test_unexpected_frame_type_is_rejected(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {"handlers": {"complete_request": [{"type": "agent_started", "payload": {}}]}}
    )
    with pytest.raises(MakaiStreamError, match="unexpected frame type"):
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )


async def test_timeout_carries_diagnostics(fake: FakeServerFactory) -> None:
    client = await fake.client({"ack": False}, response_timeout=0.3)
    with pytest.raises(MakaiStreamError) as excinfo:
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    assert excinfo.value.kind == "transport_error"
    assert excinfo.value.code == TIMEOUT_CODE
    assert excinfo.value.diagnostics is not None
    assert excinfo.value.diagnostics["model_ref"] == MODEL_REF
    assert excinfo.value.diagnostics["provider_id"] == "anthropic"


async def test_cancelling_complete_sends_abort_request(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client({"log": log, "ack": False}, response_timeout=10.0)
    task = asyncio.create_task(
        client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    )
    await asyncio.sleep(0.2)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    await asyncio.sleep(0.2)

    frames = read_log(log)
    abort = [frame for frame in frames if frame["type"] == "abort_request"]
    assert len(abort) == 1
    assert abort[0]["stream_id"] == frames[0]["stream_id"]
    assert abort[0]["payload"]["target_stream_id"] == frames[0]["stream_id"]


async def test_breaking_out_of_stream_sends_abort_request(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        stream_config(
            [
                {"type": "text_delta", "delta": "a"},
                {"type": "text_delta", "delta": "b", "delay_ms": 50},
                {"type": "message_end", "stop_reason": "end_turn", "delay_ms": 50},
            ],
            log=log,
        )
    )
    stream = client.provider.stream(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    )
    async for event in stream:
        if isinstance(event, TextDelta):
            break
    await stream.aclose()
    await asyncio.sleep(0.2)
    assert any(frame["type"] == "abort_request" for frame in read_log(log))


async def test_documented_aclosing_pattern_sends_abort(fake: FakeServerFactory) -> None:
    """The README's ``async with aclosing(...)`` recipe must actually work."""
    log = fake.log_path()
    client = await fake.client(
        stream_config(
            [
                {"type": "text_delta", "delta": "a"},
                {"type": "text_delta", "delta": "b", "delay_ms": 50},
                {"type": "message_end", "stop_reason": "end_turn", "delay_ms": 50},
            ],
            log=log,
        )
    )
    async with aclosing(
        client.provider.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    ) as stream:
        async for event in stream:
            if isinstance(event, TextDelta):
                break
    await asyncio.sleep(0.2)
    assert any(frame["type"] == "abort_request" for frame in read_log(log))


async def test_concurrent_streams_are_independent(fake: FakeServerFactory) -> None:
    client = await fake.client(
        stream_config(
            [
                {"type": "text_delta", "delta": "x", "delay_ms": 10},
                {"type": "message_end", "stop_reason": "end_turn"},
            ]
        )
    )

    async def collect() -> int:
        return len(
            [
                event
                async for event in client.provider.stream(
                    model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
                )
            ]
        )

    assert await asyncio.gather(*(collect() for _ in range(5))) == [2] * 5


async def test_invalid_model_ref_is_rejected_before_send(fake: FakeServerFactory) -> None:
    client = await fake.client({})
    with pytest.raises(TypeError):
        await client.provider.complete(model_ref="", messages=[])
    with pytest.raises(MakaiProtocolError, match="exceeds maximum length"):
        await client.provider.complete(model_ref="x" * 5000, messages=[])


async def test_opaque_model_ref_is_passed_through(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {"complete_request": [{"type": "result", "payload": RESULT_PAYLOAD}]},
        }
    )
    await client.provider.complete(
        model_ref="opaque-handle", messages=[{"role": "user", "content": "hi"}]
    )
    payload = read_log(log)[0]["payload"]
    assert payload["model_ref"] == "opaque-handle"
    assert payload["model"]["id"] == "opaque-handle"
    assert payload["model"]["provider"] == ""


def test_non_finite_content_index_falls_back() -> None:
    """number_or feeds int() too; NaN/Infinity must take the fallback."""
    for value in (float("nan"), float("inf"), float("-inf")):
        assert number_or(value, 7) == 7
    assert number_or(3, 7) == 3
    assert number_or(3.9, 7) == 3
    assert number_or(True, 7) == 7
    assert number_or("3", 7) == 7
