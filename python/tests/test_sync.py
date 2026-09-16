"""The blocking wrapper delegates to the async client without changing it."""

from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterator, List

import pytest

from conftest import FIXTURE_SERVER, process_alive
from makai.errors import MakaiProtocolError
from makai.sync import SyncMakaiClient, connect_sync
from makai.types import MessageEnd, TextDelta

MODEL_REF = "anthropic/anthropic-messages@claude-sonnet-4-5"

MODEL = {
    "model_ref": MODEL_REF,
    "model_id": "claude-sonnet-4-5",
    "display_name": "Claude Sonnet 4.5",
    "provider_id": "anthropic",
    "api": "anthropic-messages",
    "auth_status": "authenticated",
    "lifecycle": "stable",
    "capabilities": ["chat"],
    "source": "dynamic",
}

CONFIG: Dict[str, Any] = {
    "handlers": {
        "models_request": [
            {
                "type": "models_response",
                "payload": {"models": [MODEL], "fetched_at_ms": 1, "cache_max_age_ms": 2},
            }
        ],
        "stream_request": [
            {"type": "text_delta", "payload": {"type": "text_delta", "delta": "sync "}},
            {"type": "text_delta", "payload": {"type": "text_delta", "delta": "works"}},
            {
                "type": "message_end",
                "payload": {"type": "message_end", "stop_reason": "end_turn"},
            },
        ],
        "complete_request": [
            {
                "type": "result",
                "payload": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "blocking"}],
                    "provider_id": "anthropic",
                    "api": "anthropic-messages",
                    "model_id": "claude-sonnet-4-5",
                    "stop_reason": "end_turn",
                },
            }
        ],
        "auth_providers_request": [
            {
                "type": "auth_providers_response",
                "payload": {
                    "providers": [
                        {"id": "anthropic", "name": "Anthropic", "auth_status": "authenticated"}
                    ]
                },
            }
        ],
    }
}


@pytest.fixture
def sync_client() -> Iterator[SyncMakaiClient]:
    with tempfile.TemporaryDirectory(prefix="makai-sync-tests-") as directory:
        config_path = Path(directory) / "config.json"
        config_path.write_text(json.dumps(CONFIG), encoding="utf-8")
        env = dict(os.environ)
        env["MAKAI_FAKE_CONFIG"] = str(config_path)
        env.pop("MAKAI_BINARY_PATH", None)
        client = connect_sync(command=sys.executable, args=[FIXTURE_SERVER], env=env)
        try:
            yield client
        finally:
            client.close()


def test_models_list(sync_client: SyncMakaiClient) -> None:
    result = sync_client.models.list()
    assert [model.model_ref for model in result.models] == [MODEL_REF]


def test_models_resolve(sync_client: SyncMakaiClient) -> None:
    model = sync_client.models.resolve(
        provider_id="anthropic", model_id="claude-sonnet-4-5"
    )
    assert model.display_name == "Claude Sonnet 4.5"


def test_provider_complete(sync_client: SyncMakaiClient) -> None:
    response = sync_client.provider.complete(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    )
    assert response.text == "blocking"


def test_provider_stream_is_a_plain_iterator(sync_client: SyncMakaiClient) -> None:
    events = list(
        sync_client.provider.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
    )
    text = "".join(event.delta for event in events if isinstance(event, TextDelta))
    assert text == "sync works"
    assert isinstance(events[-1], MessageEnd)


def test_breaking_out_of_a_sync_stream_closes_it(sync_client: SyncMakaiClient) -> None:
    collected: List[str] = []
    for event in sync_client.provider.stream(
        model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
    ):
        if isinstance(event, TextDelta):
            collected.append(event.delta)
            break
    assert collected == ["sync "]


def test_auth_list_providers(sync_client: SyncMakaiClient) -> None:
    providers = sync_client.auth.list_providers()
    assert providers[0].id == "anthropic"


def test_errors_propagate_unchanged(sync_client: SyncMakaiClient) -> None:
    with pytest.raises(MakaiProtocolError, match="resolve requires provider_id"):
        sync_client.models.resolve(provider_id="", model_id="m")


def test_agent_models_alias(sync_client: SyncMakaiClient) -> None:
    assert sync_client.agent.models.list().models[0].model_ref == MODEL_REF


def test_close_terminates_the_child() -> None:
    with tempfile.TemporaryDirectory(prefix="makai-sync-tests-") as directory:
        config_path = Path(directory) / "config.json"
        config_path.write_text(json.dumps(CONFIG), encoding="utf-8")
        env = dict(os.environ)
        env["MAKAI_FAKE_CONFIG"] = str(config_path)
        env.pop("MAKAI_BINARY_PATH", None)
        client = connect_sync(command=sys.executable, args=[FIXTURE_SERVER], env=env)
        pid = client.transport.pid
        client.close()
        assert pid is not None
        assert not process_alive(pid)


def test_context_manager_closes() -> None:
    with tempfile.TemporaryDirectory(prefix="makai-sync-tests-") as directory:
        config_path = Path(directory) / "config.json"
        config_path.write_text(json.dumps(CONFIG), encoding="utf-8")
        env = dict(os.environ)
        env["MAKAI_FAKE_CONFIG"] = str(config_path)
        env.pop("MAKAI_BINARY_PATH", None)
        with connect_sync(command=sys.executable, args=[FIXTURE_SERVER], env=env) as client:
            pid = client.transport.pid
            assert client.models.list().models
        assert pid is not None
        assert not process_alive(pid)


def test_close_is_idempotent() -> None:
    """Closing inside a ``with`` block and letting ``__exit__`` close again."""
    with tempfile.TemporaryDirectory(prefix="makai-sync-tests-") as directory:
        config_path = Path(directory) / "config.json"
        config_path.write_text(json.dumps(CONFIG), encoding="utf-8")
        env = dict(os.environ)
        env["MAKAI_FAKE_CONFIG"] = str(config_path)
        env.pop("MAKAI_BINARY_PATH", None)
        with connect_sync(command=sys.executable, args=[FIXTURE_SERVER], env=env) as client:
            pid = client.transport.pid
            client.close()
            client.close()
        assert pid is not None
        assert not process_alive(pid)


def test_an_abandoned_stream_does_not_raise_after_the_client_is_closed() -> None:
    """The generator's finalizer must not run teardown on a dead loop."""
    with tempfile.TemporaryDirectory(prefix="makai-sync-tests-") as directory:
        config_path = Path(directory) / "config.json"
        config_path.write_text(json.dumps(CONFIG), encoding="utf-8")
        env = dict(os.environ)
        env["MAKAI_FAKE_CONFIG"] = str(config_path)
        env.pop("MAKAI_BINARY_PATH", None)
        client = connect_sync(command=sys.executable, args=[FIXTURE_SERVER], env=env)
        stream = client.provider.stream(
            model_ref=MODEL_REF, messages=[{"role": "user", "content": "hi"}]
        )
        assert next(iter(stream)) is not None
        client.close()
        closer = getattr(stream, "close", None)
        assert closer is not None
        closer()


async def test_connect_sync_refuses_inside_a_running_loop() -> None:
    assert asyncio.get_running_loop() is not None
    with pytest.raises(RuntimeError, match="running event loop"):
        connect_sync()
