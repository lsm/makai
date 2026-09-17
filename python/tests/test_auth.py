"""The ``auth`` namespace: provider listing and interactive login flows."""

from __future__ import annotations

import asyncio
from typing import Any, Dict, List

import pytest

from conftest import FakeServerFactory, read_log
from makai.auth import flatten_auth_event
from makai.errors import TIMEOUT_CODE, MakaiAuthError
from makai.types import (
    AuthErrorEvent,
    AuthEvent,
    AuthFlowHandlers,
    AuthProgressEvent,
    AuthPromptEvent,
    AuthSuccessEvent,
    AuthUrlEvent,
)

PROVIDERS = [
    {"id": "anthropic", "name": "Anthropic", "auth_status": "login_required"},
    {"id": "openai", "name": "OpenAI", "auth_status": "authenticated"},
    {"id": "weird", "name": "Weird", "auth_status": "not-a-real-status"},
    {"id": "broken", "name": "Broken", "auth_status": "failed", "last_error": "boom"},
]


async def test_list_providers(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "auth_providers_request": [
                    {"type": "auth_providers_response", "payload": {"providers": PROVIDERS}}
                ]
            }
        }
    )
    providers = await client.auth.list_providers()
    assert [p.id for p in providers] == ["anthropic", "openai", "weird", "broken"]
    assert providers[0].auth_status == "login_required"
    # An unrecognised status degrades to "unknown" rather than failing the call.
    assert providers[2].auth_status == "unknown"
    assert providers[3].last_error == "boom"


async def test_list_providers_maps_nack(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "auth_providers_request": [
                    {"type": "nack", "payload": {"reason": "nope", "error_code": "invalid_request"}}
                ]
            }
        }
    )
    with pytest.raises(MakaiAuthError) as excinfo:
        await client.auth.list_providers()
    assert excinfo.value.kind == "transport_error"
    assert excinfo.value.code == "invalid_request"


async def test_list_providers_rejects_missing_payload(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "auth_providers_request": [
                    {"type": "auth_providers_response", "payload": {"nope": []}}
                ]
            }
        }
    )
    with pytest.raises(MakaiAuthError, match="missing providers array"):
        await client.auth.list_providers()


async def test_list_providers_rejects_bad_entry(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "auth_providers_request": [
                    {"type": "auth_providers_response", "payload": {"providers": [{"id": 7}]}}
                ]
            }
        }
    )
    with pytest.raises(MakaiAuthError, match="missing id/name"):
        await client.auth.list_providers()


def login_config(replies: List[Dict[str, Any]], **extra: Any) -> Dict[str, Any]:
    return {"handlers": {"auth_login_start": replies}, **extra}


async def test_login_success_publishes_events(fake: FakeServerFactory) -> None:
    client = await fake.client(
        login_config(
            [
                {
                    "type": "auth_event",
                    "payload": {
                        "auth_url": {
                            "flow_id": "$stream_id",
                            "provider_id": "anthropic",
                            "url": "https://example.test/authorize",
                            "instructions": "paste the code",
                        }
                    },
                },
                {
                    "type": "auth_event",
                    "payload": {
                        "progress": {
                            "flow_id": "$stream_id",
                            "provider_id": "anthropic",
                            "message": "waiting",
                        }
                    },
                },
                {
                    "type": "auth_event",
                    "payload": {"success": {"flow_id": "$stream_id", "provider_id": "anthropic"}},
                },
                {"type": "auth_login_result", "payload": {"status": "success"}},
            ]
        )
    )

    seen: List[AuthEvent] = []
    await client.auth.login("anthropic", AuthFlowHandlers(on_event=seen.append))

    assert [type(event) for event in seen] == [
        AuthUrlEvent,
        AuthProgressEvent,
        AuthSuccessEvent,
    ]
    assert isinstance(seen[0], AuthUrlEvent)
    assert seen[0].url == "https://example.test/authorize"
    assert seen[0].instructions == "paste the code"


async def test_login_answers_prompts(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {
                "auth_login_start": [
                    {
                        "type": "auth_event",
                        "payload": {
                            "prompt": {
                                "flow_id": "$stream_id",
                                "prompt_id": "P1",
                                "provider_id": "anthropic",
                                "message": "Enter code",
                                "allow_empty": False,
                            }
                        },
                    }
                ],
                "auth_prompt_response": [
                    {"type": "auth_login_result", "payload": {"status": "success"}}
                ],
            },
        }
    )

    prompts: List[AuthPromptEvent] = []

    async def on_prompt(prompt: AuthPromptEvent) -> str:
        prompts.append(prompt)
        return "letmein"

    await client.auth.login("anthropic", AuthFlowHandlers(on_prompt=on_prompt))

    assert len(prompts) == 1
    assert prompts[0].message == "Enter code"
    assert prompts[0].allow_empty is False

    frames = read_log(log)
    start = next(f for f in frames if f["type"] == "auth_login_start")
    answer = next(f for f in frames if f["type"] == "auth_prompt_response")
    assert start["payload"] == {"provider_id": "anthropic"}
    assert start["sequence"] == 1
    assert answer["payload"]["prompt_id"] == "P1"
    assert answer["payload"]["answer"] == "letmein"
    assert answer["stream_id"] == start["stream_id"]
    assert answer["sequence"] > start["sequence"]


async def test_login_without_prompt_handler_cancels(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {
                "auth_login_start": [
                    {
                        "type": "auth_event",
                        "payload": {
                            "prompt": {
                                "flow_id": "$stream_id",
                                "prompt_id": "P1",
                                "provider_id": "anthropic",
                                "message": "Enter code",
                            }
                        },
                    }
                ],
                "auth_cancel": [
                    {"type": "auth_login_result", "payload": {"status": "cancelled"}}
                ],
            },
        }
    )

    with pytest.raises(MakaiAuthError) as excinfo:
        await client.auth.login("anthropic")
    assert excinfo.value.kind == "cancelled"
    assert "no on_prompt handler" in str(excinfo.value)
    assert any(frame["type"] == "auth_cancel" for frame in read_log(log))


async def test_login_failed_uses_last_error(fake: FakeServerFactory) -> None:
    client = await fake.client(
        login_config(
            [
                {
                    "type": "auth_event",
                    "payload": {
                        "error": {
                            "flow_id": "$stream_id",
                            "provider_id": "anthropic",
                            "code": "invalid_code",
                            "message": "fixture rejected code",
                        }
                    },
                },
                {"type": "auth_login_result", "payload": {"status": "failed"}},
            ]
        )
    )
    with pytest.raises(MakaiAuthError) as excinfo:
        await client.auth.login("anthropic")
    assert excinfo.value.kind == "provider_error"
    assert excinfo.value.code == "invalid_code"
    assert str(excinfo.value) == "fixture rejected code"


async def test_login_cancelled_status(fake: FakeServerFactory) -> None:
    client = await fake.client(
        login_config([{"type": "auth_login_result", "payload": {"status": "cancelled"}}])
    )
    with pytest.raises(MakaiAuthError) as excinfo:
        await client.auth.login("anthropic")
    assert excinfo.value.kind == "cancelled"
    assert str(excinfo.value) == "auth login cancelled"


async def test_login_unknown_status(fake: FakeServerFactory) -> None:
    client = await fake.client(
        login_config([{"type": "auth_login_result", "payload": {"status": "weird"}}])
    )
    with pytest.raises(MakaiAuthError, match="unexpected auth_login_result status"):
        await client.auth.login("anthropic")


async def test_login_maps_nack(fake: FakeServerFactory) -> None:
    client = await fake.client(
        login_config(
            [{"type": "nack", "payload": {"reason": "rejected", "error_code": "invalid_request"}}]
        )
    )
    with pytest.raises(MakaiAuthError) as excinfo:
        await client.auth.login("anthropic")
    assert excinfo.value.kind == "transport_error"
    assert excinfo.value.code == "invalid_request"


async def test_handler_exception_becomes_auth_error(fake: FakeServerFactory) -> None:
    client = await fake.client(
        login_config(
            [
                {
                    "type": "auth_event",
                    "payload": {
                        "progress": {
                            "flow_id": "$stream_id",
                            "provider_id": "anthropic",
                            "message": "hi",
                        }
                    },
                }
            ]
        )
    )

    def boom(event: AuthEvent) -> None:
        raise RuntimeError("handler exploded")

    with pytest.raises(MakaiAuthError) as excinfo:
        await client.auth.login("anthropic", AuthFlowHandlers(on_event=boom))
    assert excinfo.value.kind == "unknown"
    assert "handler exploded" in str(excinfo.value)


async def test_prompt_handler_exception_cancels(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    client = await fake.client(
        {
            "log": log,
            "handlers": {
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
                ]
            },
        }
    )

    def boom(prompt: AuthPromptEvent) -> str:
        raise RuntimeError("prompt exploded")

    with pytest.raises(MakaiAuthError, match="prompt exploded"):
        await client.auth.login("anthropic", AuthFlowHandlers(on_prompt=boom))
    assert any(frame["type"] == "auth_cancel" for frame in read_log(log))


async def test_per_call_handlers_win_over_client_defaults(fake: FakeServerFactory) -> None:
    from makai.client import AuthOptions

    default: List[AuthEvent] = []
    per_call: List[AuthEvent] = []
    client = await fake.client(
        login_config(
            [
                {
                    "type": "auth_event",
                    "payload": {
                        "progress": {
                            "flow_id": "$stream_id",
                            "provider_id": "anthropic",
                            "message": "hi",
                        }
                    },
                },
                {"type": "auth_login_result", "payload": {"status": "success"}},
            ]
        ),
        auth=AuthOptions(handlers=AuthFlowHandlers(on_event=default.append)),
    )

    await client.auth.login("anthropic", AuthFlowHandlers(on_event=per_call.append))
    assert len(per_call) == 1
    assert default == []


async def test_client_default_handlers_used_when_no_per_call(fake: FakeServerFactory) -> None:
    from makai.client import AuthOptions

    default: List[AuthEvent] = []
    client = await fake.client(
        login_config(
            [
                {
                    "type": "auth_event",
                    "payload": {
                        "progress": {
                            "flow_id": "$stream_id",
                            "provider_id": "anthropic",
                            "message": "hi",
                        }
                    },
                },
                {"type": "auth_login_result", "payload": {"status": "success"}},
            ]
        ),
        auth=AuthOptions(handlers=AuthFlowHandlers(on_event=default.append)),
    )
    await client.auth.login("anthropic")
    assert len(default) == 1


async def test_login_timeout_carries_diagnostics(fake: FakeServerFactory) -> None:
    client = await fake.client({"ack": False}, frame_timeout=0.3)
    with pytest.raises(MakaiAuthError) as excinfo:
        await client.auth.login("anthropic")
    assert excinfo.value.kind == "transport_error"
    assert excinfo.value.code == TIMEOUT_CODE
    assert excinfo.value.diagnostics is not None
    assert excinfo.value.diagnostics["provider_id"] == "anthropic"


async def test_cancelling_login_sends_auth_cancel(fake: FakeServerFactory) -> None:
    """Cancellation stays cancellation, and still cancels the flow on the wire."""
    log = fake.log_path()
    client = await fake.client({"log": log, "ack": False}, frame_timeout=5.0)
    task = asyncio.create_task(client.auth.login("anthropic"))
    await asyncio.sleep(0.2)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert task.cancelled()
    await asyncio.sleep(0.1)
    assert any(frame["type"] == "auth_cancel" for frame in read_log(log))


def test_flatten_rejects_unknown_variant() -> None:
    with pytest.raises(MakaiAuthError, match="unknown auth_event variant"):
        flatten_auth_event({"mystery": {}})


def test_flatten_rejects_missing_field() -> None:
    with pytest.raises(MakaiAuthError, match='field "flow_id" missing'):
        flatten_auth_event({"progress": {"provider_id": "p", "message": "m"}})


def test_flatten_builds_each_variant() -> None:
    flow = {"flow_id": "F", "provider_id": "p"}
    assert isinstance(flatten_auth_event({"auth_url": {**flow, "url": "u"}}), AuthUrlEvent)
    assert isinstance(
        flatten_auth_event({"prompt": {**flow, "prompt_id": "P", "message": "m"}}),
        AuthPromptEvent,
    )
    assert isinstance(flatten_auth_event({"progress": {**flow, "message": "m"}}), AuthProgressEvent)
    assert isinstance(flatten_auth_event({"success": flow}), AuthSuccessEvent)
    assert isinstance(flatten_auth_event({"error": {**flow, "message": "m"}}), AuthErrorEvent)
