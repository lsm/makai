"""End-to-end coverage against a real ``makai --stdio`` host.

Every test here needs ``MAKAI_BINARY_PATH`` and skips without it, so a green
``pytest`` with the variable unset means **zero** real-runtime coverage. Build
one first::

    zig build install --prefix /tmp/makai-py
    MAKAI_BINARY_PATH=/tmp/makai-py/bin/makai pytest

No provider credentials are needed: the model catalogue, envelope validation,
frame routing, and process lifetime are all reachable without them.

The ``auth`` protocol is **not** exercised here by default. On macOS the login
Keychain is the primary credential store, and an unsigned local build blocks on
a Keychain access prompt that never surfaces from a non-interactive shell, so
``auth_providers_request`` never answers and the request hangs. Set
``MAKAI_TEST_REAL_AUTH=1`` to opt in where the runtime can reach its store
without prompting (Linux CI, or a signed build with a granted ACL).
"""

from __future__ import annotations

import asyncio
import os

import pytest

from conftest import process_alive
from makai._wire import build_stream_envelope
from makai.client import MakaiClient
from makai.errors import MakaiProtocolError, MakaiStreamError
from makai.transport import StdioTransport

pytestmark = pytest.mark.real_binary


async def open_transport(binary: str, **kwargs: object) -> StdioTransport:
    transport = StdioTransport(command=binary, args=["--stdio"], **kwargs)  # type: ignore[arg-type]
    await transport.connect()
    return transport


async def test_handshake_against_the_real_host(real_binary: str) -> None:
    transport = await open_transport(real_binary)
    try:
        assert transport.connected
        assert transport.pid is not None
    finally:
        await transport.close()


async def test_models_list_returns_the_static_catalogue(real_binary: str) -> None:
    transport = await open_transport(real_binary)
    client = MakaiClient(transport, response_timeout=10.0)
    try:
        result = await client.models.list()
        assert result.models, "the runtime always serves at least the static fallback catalogue"
        assert result.fetched_at_ms > 0
        assert result.cache_max_age_ms > 0
        for model in result.models:
            assert model.model_ref
            assert model.provider_id
            assert model.api
    finally:
        await client.close()


async def test_model_refs_round_trip_opaquely(real_binary: str) -> None:
    """A ref taken from list must resolve without the caller touching it."""
    transport = await open_transport(real_binary)
    client = MakaiClient(transport, response_timeout=10.0)
    try:
        listed = (await client.models.list()).models[0]
        resolved = await client.models.resolve(
            provider_id=listed.provider_id, api=listed.api, model_id=listed.model_id
        )
        assert resolved.model_ref == listed.model_ref
    finally:
        await client.close()


async def test_resolve_unknown_model_is_a_protocol_error(real_binary: str) -> None:
    transport = await open_transport(real_binary)
    client = MakaiClient(transport, response_timeout=10.0)
    try:
        with pytest.raises(MakaiProtocolError) as excinfo:
            await client.models.resolve(
                provider_id="definitely-not-a-provider", model_id="definitely-not-a-model"
            )
        assert excinfo.value.code == "invalid_request"
    finally:
        await client.close()


async def test_filtered_list_narrows_the_catalogue(real_binary: str) -> None:
    transport = await open_transport(real_binary)
    client = MakaiClient(transport, response_timeout=10.0)
    try:
        everything = await client.models.list()
        provider_id = everything.models[0].provider_id
        filtered = await client.models.list(provider_id=provider_id)
        assert filtered.models
        assert {model.provider_id for model in filtered.models} == {provider_id}
        assert len(filtered.models) <= len(everything.models)
    finally:
        await client.close()


async def test_concurrent_requests_do_not_cross_talk(real_binary: str) -> None:
    transport = await open_transport(real_binary)
    client = MakaiClient(transport, response_timeout=15.0)
    try:
        results = await asyncio.gather(*(client.models.list() for _ in range(8)))
        counts = {len(result.models) for result in results}
        assert len(counts) == 1, "every concurrent list must see the same catalogue"
    finally:
        await client.close()


async def test_unknown_envelope_type_is_silently_ignored(real_binary: str) -> None:
    """A well-formed envelope with an unrecognised ``type`` gets no reply.

    Verified against the runtime: only a *malformed* or ambiguous frame draws
    the host-level ``unknown_envelope`` error (see the next test). A caller
    that invents a frame type therefore just times out, which is why every
    request path here has a bounded timeout.
    """
    transport = await open_transport(real_binary)
    try:
        async with transport.route(stream_id="01ARZ3NDEKTSV4RRFFQ69G5FAV") as route:
            await transport.send(
                build_stream_envelope(
                    "definitely_not_a_real_envelope", "01ARZ3NDEKTSV4RRFFQ69G5FAV", {}
                )
            )
            with pytest.raises(MakaiStreamError, match="timed out"):
                await route.next_frame(2.0)
        assert transport.dropped_frames == 0
    finally:
        await transport.close()


@pytest.mark.parametrize("line", [b"{ this is not json\n", b"{}\n", b"[1,2,3]\n"])
async def test_malformed_frames_draw_an_unknown_envelope_error(
    real_binary: str, line: bytes, caplog: pytest.LogCaptureFixture
) -> None:
    """The host answers malformed input with an unroutable ``error`` frame.

    It carries no ``stream_id``/``session_id``, so no caller can await it; the
    transport counts it as dropped and logs it at warning level. The host must
    stay usable afterwards.
    """
    transport = await open_transport(real_binary)
    client = MakaiClient(transport, response_timeout=10.0)
    try:
        process = transport._process
        assert process is not None and process.stdin is not None
        with caplog.at_level("WARNING", logger="makai.transport"):
            process.stdin.write(line)
            await process.stdin.drain()
            await asyncio.sleep(0.3)

        assert transport.dropped_frames >= 1
        assert any("unknown_envelope" in record.getMessage() for record in caplog.records)

        # The host must still answer a well-formed request afterwards.
        assert (await client.models.list()).models
    finally:
        await client.close()


async def test_close_terminates_the_real_process(real_binary: str) -> None:
    transport = await open_transport(real_binary)
    pid = transport.pid
    assert pid is not None
    await transport.close()
    for _ in range(60):
        if not process_alive(pid):
            break
        await asyncio.sleep(0.05)
    assert not process_alive(pid), "closing the client must not leak the runtime process"


async def test_context_manager_closes_the_real_process(real_binary: str) -> None:
    async with StdioTransport(command=real_binary, args=["--stdio"]) as transport:
        client = MakaiClient(transport, response_timeout=10.0)
        assert (await client.models.list()).models
        pid = transport.pid
    assert pid is not None
    for _ in range(60):
        if not process_alive(pid):
            break
        await asyncio.sleep(0.05)
    assert not process_alive(pid)


async def test_requests_after_close_fail_cleanly(real_binary: str) -> None:
    transport = await open_transport(real_binary)
    client = MakaiClient(transport, response_timeout=5.0)
    await client.close()
    with pytest.raises((MakaiProtocolError, MakaiStreamError)):
        await client.models.list()


async def test_handshake_timeout_is_respected(real_binary: str) -> None:
    """An absurdly short handshake budget fails fast instead of hanging."""
    transport = StdioTransport(
        command=real_binary, args=["--stdio"], handshake_timeout=0.000_001
    )
    with pytest.raises(MakaiStreamError, match="handshake timed out"):
        await transport.connect()
    assert transport.pid is None


async def test_resolver_finds_the_binary_from_the_environment(real_binary: str) -> None:
    from makai.binary import resolve_makai_binary

    assert os.path.samefile(resolve_makai_binary(), real_binary)


@pytest.mark.skipif(
    not os.environ.get("MAKAI_TEST_REAL_AUTH"),
    reason="set MAKAI_TEST_REAL_AUTH=1; on macOS an unsigned build blocks on a Keychain prompt",
)
async def test_auth_list_providers_against_the_real_host(real_binary: str) -> None:
    transport = await open_transport(real_binary)
    client = MakaiClient(transport, frame_timeout=15.0)
    try:
        providers = await client.auth.list_providers()
        for provider in providers:
            assert provider.id
            assert provider.name
            assert provider.auth_status in {
                "authenticated",
                "login_required",
                "expired",
                "refreshing",
                "login_in_progress",
                "failed",
                "unknown",
            }
    finally:
        await client.close()
