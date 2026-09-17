"""``auth_retry_policy`` behaviour for provider and agent calls (spec §3.7)."""

from __future__ import annotations

from typing import Any, Dict, List

import pytest

from conftest import FakeServerFactory, read_log
from makai.client import AuthOptions
from makai.errors import MakaiAuthRequiredError
from makai.types import AuthFlowHandlers, RunOptions, TextDelta

MODEL_REF = "anthropic/anthropic-messages@claude-sonnet-4-5"

AUTH_NACK = {
    "type": "nack",
    "payload": {
        "error_code": "auth_required",
        "reason": "login required",
        "provider_id": "anthropic",
    },
}

RESULT = {
    "type": "result",
    "payload": {
        "role": "assistant",
        "content": [{"type": "text", "text": "ok"}],
        "provider_id": "anthropic",
        "api": "anthropic-messages",
        "model_id": "claude-sonnet-4-5",
        "stop_reason": "end_turn",
    },
}

LOGIN_SUCCESS = [{"type": "auth_login_result", "payload": {"status": "success"}}]


def auth_once_config(request_type: str, success: List[Dict[str, Any]], **extra: Any) -> Dict[str, Any]:
    """Reject the first request of ``request_type``, then behave normally."""
    return {
        "once": {request_type: [AUTH_NACK]},
        "handlers": {request_type: success, "auth_login_start": LOGIN_SUCCESS},
        **extra,
    }


async def test_manual_policy_raises_auth_required(fake: FakeServerFactory) -> None:
    client = await fake.client(auth_once_config("complete_request", [RESULT]))
    with pytest.raises(MakaiAuthRequiredError) as excinfo:
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    assert excinfo.value.provider_id == "anthropic"


async def test_auto_once_logs_in_and_retries_complete(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        auth_once_config("complete_request", [RESULT], log=log),
        auth=AuthOptions(auth_retry_policy="auto_once"),
    )
    response = await client.provider.complete(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    )
    assert response.text == "ok"

    kinds = [frame["type"] for frame in read_log(log)]
    assert kinds == ["complete_request", "auth_login_start", "complete_request"]


async def test_auto_once_only_retries_once(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {
                "complete_request": [AUTH_NACK],
                "auth_login_start": LOGIN_SUCCESS,
            },
        },
        auth=AuthOptions(auth_retry_policy="auto_once"),
    )
    with pytest.raises(MakaiAuthRequiredError):
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    kinds = [frame["type"] for frame in read_log(log)]
    assert kinds.count("complete_request") == 2
    assert kinds.count("auth_login_start") == 1


async def test_per_request_policy_overrides_the_client_default(
    fake: FakeServerFactory,
) -> None:
    log = fake.log_path()
    client = await fake.client(
        auth_once_config("complete_request", [RESULT], log=log),
        auth=AuthOptions(auth_retry_policy="manual"),
    )
    response = await client.provider.complete(
        model_ref=MODEL_REF,
        messages=[{"role": "user", "content": "hi"}],
        options=RunOptions(auth_retry_policy="auto_once"),
    )
    assert response.text == "ok"
    assert any(frame["type"] == "auth_login_start" for frame in read_log(log))


async def test_policy_is_forwarded_on_the_wire(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        {"log": log, "handlers": {"complete_request": [RESULT]}},
        auth=AuthOptions(auth_retry_policy="auto_once"),
    )
    await client.provider.complete(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    )
    assert read_log(log)[0]["payload"]["options"]["auth_retry_policy"] == "auto_once"


async def test_auto_once_failure_surfaces_typed_auth_error(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "complete_request": [AUTH_NACK],
                "auth_login_start": [
                    {"type": "auth_login_result", "payload": {"status": "failed"}}
                ],
            }
        },
        auth=AuthOptions(auth_retry_policy="auto_once"),
    )
    with pytest.raises(MakaiAuthRequiredError) as excinfo:
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    assert excinfo.value.provider_id == "anthropic"


async def test_auto_once_retries_a_stream_before_any_content(
    fake: FakeServerFactory,
) -> None:
    log = fake.log_path()
    client = await fake.client(
        auth_once_config(
            "stream_request",
            [
                {"type": "text_delta", "payload": {"type": "text_delta", "delta": "hi"}},
                {
                    "type": "message_end",
                    "payload": {"type": "message_end", "stop_reason": "end_turn"},
                },
            ],
            log=log,
        ),
        auth=AuthOptions(auth_retry_policy="auto_once"),
    )
    events = [
        event
        async for event in client.provider.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    ]
    assert any(isinstance(event, TextDelta) for event in events)
    kinds = [frame["type"] for frame in read_log(log)]
    assert kinds.count("stream_request") == 2


async def test_auto_once_retries_an_agent_run_with_a_new_session(
    fake: FakeServerFactory,
) -> None:
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "once": {"agent_start": [AUTH_NACK]},
            "handlers": {
                "agent_start": [
                    {"type": "agent_started", "payload": {"session_id": "$session_id"}}
                ],
                "agent_message": [
                    {
                        "type": "agent_event",
                        "payload": {},
                        "correlate": False,
                        "event_json": {"type": "text_delta", "delta": "retried"},
                    },
                    {
                        "type": "agent_event",
                        "payload": {},
                        "correlate": False,
                        "event_json": {"type": "agent_end", "stop_reason": "end_turn"},
                    },
                ],
                "auth_login_start": LOGIN_SUCCESS,
            },
        },
        auth=AuthOptions(auth_retry_policy="auto_once"),
    )
    response = await client.agent.run(
        model_ref=MODEL_REF,
        messages=[{"role": "user", "content": "hi"}],
        options=RunOptions(session_id="Abcdefghijklmnopqrstu"),
    )
    assert response.text == "retried"

    starts = [frame for frame in read_log(log) if frame["type"] == "agent_start"]
    assert len(starts) == 2
    # Sessions are not resumable: the retry runs under a fresh id.
    assert starts[0]["session_id"] == "Abcdefghijklmnopqrstu"
    assert starts[1]["session_id"] != starts[0]["session_id"]
    assert starts[1]["sequence"] == 1


async def test_auto_once_without_auth_handlers_still_fails_fast(
    fake: FakeServerFactory,
) -> None:
    """An interactive provider with no handlers must fail, never hang."""
    client = await fake.client(
        {
            "handlers": {
                "complete_request": [AUTH_NACK],
                "auth_login_start": [
                    {
                        "type": "auth_event",
                        "payload": {
                            "prompt": {
                                "flow_id": "$stream_id",
                                "prompt_id": "P1",
                                "provider_id": "anthropic",
                                "message": "code?",
                            }
                        },
                    }
                ],
                "auth_cancel": [
                    {"type": "auth_login_result", "payload": {"status": "cancelled"}}
                ],
            }
        },
        auth=AuthOptions(auth_retry_policy="auto_once"),
        response_timeout=3.0,
        frame_timeout=3.0,
    )
    with pytest.raises(MakaiAuthRequiredError):
        await client.provider.complete(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )


async def test_auto_once_uses_client_level_handlers(fake: FakeServerFactory) -> None:
    answered: List[str] = []

    def on_prompt(prompt: Any) -> str:
        answered.append(prompt.prompt_id)
        return "letmein"

    client = await fake.client(
        {
            "once": {"complete_request": [AUTH_NACK]},
            "handlers": {
                "complete_request": [RESULT],
                "auth_login_start": [
                    {
                        "type": "auth_event",
                        "payload": {
                            "prompt": {
                                "flow_id": "$stream_id",
                                "prompt_id": "P1",
                                "provider_id": "anthropic",
                                "message": "code?",
                            }
                        },
                    }
                ],
                "auth_prompt_response": LOGIN_SUCCESS,
            },
        },
        auth=AuthOptions(
            auth_retry_policy="auto_once",
            handlers=AuthFlowHandlers(on_prompt=on_prompt),
        ),
    )
    response = await client.provider.complete(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    )
    assert response.text == "ok"
    assert answered == ["P1"]


async def test_auto_once_does_not_replay_a_run_whose_tools_already_ran(
    fake: FakeServerFactory,
) -> None:
    """A tool round is a side effect; an auth failure after one must not retry.

    The result path already refuses with ``allow_retry=not tools_executed``,
    but a terminal ``error`` event leaves ``_run_once`` as a stream error
    before that gate, so ``run()`` has to be told what the attempt did.
    """
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
                            "tool_call_id": "c1",
                            "tool_name": "charge_card",
                        },
                    },
                    {
                        "type": "agent_event",
                        "payload": {},
                        "correlate": False,
                        "event_json": {
                            "type": "tool_execution_end",
                            "tool_call_id": "c1",
                            "is_error": False,
                        },
                    },
                    {
                        "type": "agent_event",
                        "payload": {},
                        "correlate": False,
                        "event_json": {
                            "type": "error",
                            "message": "auth_required",
                            "code": "auth_required",
                            "provider_id": "anthropic",
                        },
                    },
                ],
                "auth_login_start": LOGIN_SUCCESS,
            },
        },
        auth=AuthOptions(auth_retry_policy="auto_once"),
    )
    with pytest.raises(MakaiAuthRequiredError) as excinfo:
        await client.agent.run(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    assert excinfo.value.provider_id == "anthropic"
    frames = read_log(log)
    assert [frame["type"] for frame in frames].count("agent_start") == 1
    assert not any(frame["type"] == "auth_login_start" for frame in frames)
