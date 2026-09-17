"""The ``models`` namespace: wire payloads, parsing, and error mapping."""

from __future__ import annotations

from typing import Any, Dict, List

import pytest

from conftest import FakeServerFactory, read_log
from makai.errors import TIMEOUT_CODE, MakaiProtocolError
from makai.models import DEFAULT_CACHE_MAX_AGE_MS, _parse_models_response

MODEL = {
    "model_ref": "anthropic/anthropic-messages@claude-sonnet-4-5",
    "model_id": "claude-sonnet-4-5",
    "display_name": "Claude Sonnet 4.5",
    "provider_id": "anthropic",
    "api": "anthropic-messages",
    "auth_status": "authenticated",
    "lifecycle": "stable",
    "capabilities": ["chat", "streaming", "tools", "reasoning"],
    "source": "dynamic",
    "base_url": "https://api.anthropic.com",
    "context_window": 200000,
    "max_output_tokens": 8192,
    "reasoning_default": "medium",
    "metadata": {"tier": "flagship"},
}


def models_config(models: List[Dict[str, Any]], **payload: Any) -> Dict[str, Any]:
    body = {"models": models, "fetched_at_ms": 1700, "cache_max_age_ms": 300000, **payload}
    return {"handlers": {"models_request": [{"type": "models_response", "payload": body}]}}


async def test_list_parses_descriptors(fake: FakeServerFactory) -> None:
    client = await fake.client(models_config([MODEL]))
    result = await client.models.list()
    assert result.fetched_at_ms == 1700
    assert result.cache_max_age_ms == 300000
    assert len(result.models) == 1
    model = result.models[0]
    assert model.model_ref == MODEL["model_ref"]
    assert model.capabilities == ["chat", "streaming", "tools", "reasoning"]
    assert model.context_window == 200000
    assert model.reasoning_default == "medium"
    assert model.metadata == {"tier": "flagship"}


async def test_list_sends_only_populated_filters(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    config = models_config([MODEL])
    config["log"] = log
    client = await fake.client(config)
    await client.models.list(provider_id="anthropic", include_deprecated=False)

    frames = read_log(log)
    assert len(frames) == 1
    request = frames[0]
    assert request["type"] == "models_request"
    assert request["sequence"] == 1
    assert request["version"] == 1
    assert request["payload"] == {"provider_id": "anthropic", "include_deprecated": False}
    assert request["stream_id"] == request["message_id"]


async def test_list_skips_ack_frames(fake: FakeServerFactory) -> None:
    config = models_config([MODEL])
    config["ack"] = True
    client = await fake.client(config)
    result = await client.models.list()
    assert len(result.models) == 1


async def test_resolve_returns_the_descriptor(fake: FakeServerFactory) -> None:
    log = fake.log_path()
    config = models_config([MODEL])
    config["log"] = log
    client = await fake.client(config)

    model = await client.models.resolve(
        provider_id="anthropic", api="anthropic-messages", model_id="claude-sonnet-4-5"
    )
    assert model.model_ref == MODEL["model_ref"]

    request = read_log(log)[0]
    assert request["payload"] == {
        "provider_id": "anthropic",
        "api": "anthropic-messages",
        "model_id": "claude-sonnet-4-5",
    }


async def test_resolve_rejects_empty_result(fake: FakeServerFactory) -> None:
    client = await fake.client(models_config([]))
    with pytest.raises(MakaiProtocolError) as excinfo:
        await client.models.resolve(provider_id="anthropic", model_id="claude-sonnet-4-5")
    assert excinfo.value.code == "invalid_request"
    assert "model not found" in str(excinfo.value)


async def test_resolve_rejects_multiple_matches(fake: FakeServerFactory) -> None:
    second = dict(MODEL, api="openai-completions")
    client = await fake.client(models_config([MODEL, second]))
    with pytest.raises(MakaiProtocolError, match="expected exactly 1"):
        await client.models.resolve(provider_id="anthropic", model_id="claude-sonnet-4-5")


async def test_resolve_rejects_mismatched_api(fake: FakeServerFactory) -> None:
    client = await fake.client(models_config([MODEL]))
    with pytest.raises(MakaiProtocolError, match="api mismatch"):
        await client.models.resolve(
            provider_id="anthropic", api="openai-completions", model_id="claude-sonnet-4-5"
        )


async def test_resolve_rejects_mismatched_model_id(fake: FakeServerFactory) -> None:
    client = await fake.client(models_config([dict(MODEL, model_id="other")]))
    with pytest.raises(MakaiProtocolError, match="model_id mismatch"):
        await client.models.resolve(provider_id="anthropic", model_id="claude-sonnet-4-5")


@pytest.mark.parametrize(
    ("provider_id", "model_id", "message"),
    [
        ("", "m", "resolve requires provider_id"),
        ("p", "", "resolve requires model_id"),
        ("p" * 257, "m", "provider_id exceeds maximum length"),
        ("p", "m" * 257, "model_id exceeds maximum length"),
    ],
)
async def test_resolve_validates_arguments_locally(
    fake: FakeServerFactory, provider_id: str, model_id: str, message: str
) -> None:
    client = await fake.client(models_config([MODEL]))
    with pytest.raises(MakaiProtocolError, match=message):
        await client.models.resolve(provider_id=provider_id, model_id=model_id)


async def test_nack_maps_to_protocol_error(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {
            "handlers": {
                "models_request": [
                    {
                        "type": "nack",
                        "payload": {"reason": "model not found", "error_code": "invalid_request"},
                    }
                ]
            }
        }
    )
    with pytest.raises(MakaiProtocolError) as excinfo:
        await client.models.list()
    assert excinfo.value.code == "invalid_request"
    assert str(excinfo.value) == "model not found"


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        ({"fetched_at_ms": 1}, "missing 'models' array"),
        ({"models": []}, "missing numeric 'fetched_at_ms'"),
        ({"models": ["nope"], "fetched_at_ms": 1}, "models[0] is not an object"),
    ],
)
async def test_malformed_responses_are_rejected(
    fake: FakeServerFactory, payload: Dict[str, Any], message: str
) -> None:
    client = await fake.client(
        {"handlers": {"models_request": [{"type": "models_response", "payload": payload}]}}
    )
    with pytest.raises(MakaiProtocolError) as excinfo:
        await client.models.list()
    assert excinfo.value.code == "malformed_response"
    assert message in str(excinfo.value)


@pytest.mark.parametrize(
    ("override", "message"),
    [
        ({"model_ref": 7}, "models[0].model_ref must be a string"),
        ({"auth_status": "bogus"}, "models[0].auth_status has unknown value"),
        ({"lifecycle": "bogus"}, "models[0].lifecycle has unknown value"),
        ({"source": "bogus"}, "models[0].source has unknown value"),
        ({"capabilities": "chat"}, "models[0].capabilities must be an array"),
        ({"capabilities": ["telepathy"]}, "unknown value: telepathy"),
        ({"metadata": {"k": 1}}, "models[0].metadata.k must be a string"),
    ],
)
async def test_malformed_descriptors_are_rejected(
    fake: FakeServerFactory, override: Dict[str, Any], message: str
) -> None:
    client = await fake.client(models_config([dict(MODEL, **override)]))
    with pytest.raises(MakaiProtocolError) as excinfo:
        await client.models.list()
    assert message in str(excinfo.value)


async def test_unexpected_frame_type_is_rejected(fake: FakeServerFactory) -> None:
    client = await fake.client(
        {"handlers": {"models_request": [{"type": "agent_started", "payload": {}}]}}
    )
    with pytest.raises(MakaiProtocolError, match="unexpected frame type"):
        await client.models.list()


async def test_timeout_carries_diagnostics(fake: FakeServerFactory) -> None:
    client = await fake.client({"ack": False}, response_timeout=0.3)
    with pytest.raises(MakaiProtocolError) as excinfo:
        await client.models.list(provider_id="anthropic")
    error = excinfo.value
    assert "Timed out waiting for models_response" in str(error)
    assert error.code == TIMEOUT_CODE
    assert error.diagnostics is not None
    assert error.diagnostics["operation"] == "models_response"
    assert error.diagnostics["provider_id"] == "anthropic"
    assert error.diagnostics["stream_id"]
    assert error.diagnostics["suggestions"]


async def test_concurrent_lists_do_not_interleave(fake: FakeServerFactory) -> None:
    import asyncio

    config = models_config([MODEL])
    config["handlers"]["models_request"][0]["delay_ms"] = 15
    client = await fake.client(config)
    results = await asyncio.gather(*(client.models.list() for _ in range(6)))
    assert all(len(result.models) == 1 for result in results)


async def test_agent_models_is_a_separate_instance(fake: FakeServerFactory) -> None:
    client = await fake.client(models_config([MODEL]))
    assert client.agent.models is not client.models
    assert (await client.agent.models.list()).models[0].model_ref == MODEL["model_ref"]


def test_non_finite_timestamps_are_typed_protocol_errors() -> None:
    """Python's JSON decoder accepts NaN and Infinity, and both are floats.

    Without a finiteness check they reach ``int()``, which raises a raw
    ``ValueError`` or ``OverflowError`` instead of this module's typed error.
    """
    for value in (float("nan"), float("inf"), float("-inf")):
        frame = {"payload": {"models": [], "fetched_at_ms": value}}
        with pytest.raises(MakaiProtocolError) as excinfo:
            _parse_models_response(frame)
        assert excinfo.value.code == "malformed_response"


def test_a_non_finite_cache_age_falls_back_to_the_default() -> None:
    response = _parse_models_response(
        {"payload": {"models": [], "fetched_at_ms": 1, "cache_max_age_ms": float("inf")}}
    )
    assert response.cache_max_age_ms == DEFAULT_CACHE_MAX_AGE_MS


def test_non_finite_descriptor_limits_are_dropped_not_crashes() -> None:
    """context_window / max_output_tokens reach int() the same way."""
    for value in (float("nan"), float("inf"), float("-inf")):
        response = _parse_models_response(
            {
                "payload": {
                    "fetched_at_ms": 1,
                    "models": [
                        {
                            "model_ref": "anthropic/anthropic-messages@m",
                            "model_id": "m",
                            "display_name": "M",
                            "provider_id": "anthropic",
                            "api": "anthropic-messages",
                            "auth_status": "authenticated",
                            "lifecycle": "stable",
                            "capabilities": ["chat"],
                            "source": "dynamic",
                            "context_window": value,
                            "max_output_tokens": value,
                        }
                    ],
                }
            }
        )
        assert response.models[0].context_window is None
        assert response.models[0].max_output_tokens is None
