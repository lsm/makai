"""Transport: handshake, framing, routing, lifetime, and child death."""

from __future__ import annotations

import asyncio
import os
import sys
from typing import Any, List

import pytest

from conftest import FIXTURE_SERVER, FakeServerFactory, process_alive
from makai._wire import build_stream_envelope
from makai.errors import TIMEOUT_CODE, MakaiStreamError, is_timeout_error
from makai.transport import StdioTransport


async def test_handshake_succeeds(fake: FakeServerFactory) -> None:
    transport = await fake.transport({})
    assert transport.connected
    assert transport.pid is not None


async def test_handshake_rejects_version_mismatch(fake: FakeServerFactory) -> None:
    with pytest.raises(MakaiStreamError) as excinfo:
        await fake.transport({"handshake": "bad_version"})
    assert excinfo.value.code == "version_mismatch"
    assert "expected 1, got 99" in excinfo.value.message


async def test_handshake_maps_error_frame(fake: FakeServerFactory) -> None:
    with pytest.raises(MakaiStreamError) as excinfo:
        await fake.transport({"handshake": "error"})
    assert excinfo.value.code == "version_mismatch"
    assert "unsupported protocol" in excinfo.value.message


async def test_handshake_rejects_garbage_line(fake: FakeServerFactory) -> None:
    with pytest.raises(MakaiStreamError, match="invalid JSON frame"):
        await fake.transport({"handshake": "garbage"})


async def test_handshake_times_out_on_silent_server(fake: FakeServerFactory) -> None:
    with pytest.raises(MakaiStreamError, match="handshake timed out"):
        await fake.transport({"handshake": "silent"}, handshake_timeout=0.3)


async def test_handshake_timeout_kills_the_child(fake: FakeServerFactory) -> None:
    transport = StdioTransport(
        command=sys.executable,
        args=[FIXTURE_SERVER],
        env={"MAKAI_FAKE_CONFIG": fake.write_config({"handshake": "silent"}), "PATH": "/usr/bin"},
        handshake_timeout=0.3,
    )
    with pytest.raises(MakaiStreamError):
        await transport.connect()
    assert transport.pid is None


async def test_spawn_failure_is_typed(fake: FakeServerFactory) -> None:
    transport = StdioTransport(command="/definitely/not/a/binary", args=[])
    with pytest.raises(MakaiStreamError, match="failed to spawn"):
        await transport.connect()


async def test_frames_route_by_stream_id(fake: FakeServerFactory) -> None:
    transport = await fake.transport(
        {"handlers": {"probe": [{"type": "pong", "payload": {"hello": "stream"}}]}}
    )
    async with transport.route(stream_id="STREAM-A") as route:
        await transport.send(build_stream_envelope("probe", "STREAM-A", {}))
        first = await route.next_frame(2.0)
        assert first["type"] == "ack"
        second = await route.next_frame(2.0)
        assert second["type"] == "pong"
        assert second["payload"] == {"hello": "stream"}


async def test_frames_route_by_session_id(fake: FakeServerFactory) -> None:
    transport = await fake.transport(
        {"ack": False, "handlers": {"probe": [{"type": "pong", "payload": {"hi": "session"}}]}}
    )
    async with transport.route(session_id="sess") as route:
        await transport.send(
            {
                "type": "probe",
                "session_id": "sess",
                "message_id": "M1",
                "sequence": 1,
                "version": 1,
                "payload": {},
            }
        )
        frame = await route.next_frame(2.0)
        assert frame["type"] == "pong"
        assert frame["session_id"] == "sess"


async def test_concurrent_routes_do_not_cross_talk(fake: FakeServerFactory) -> None:
    transport = await fake.transport(
        {
            "ack": False,
            "handlers": {
                "probe": [
                    {"type": "reply", "payload": {"echo": "$stream_id"}, "delay_ms": 20},
                ]
            },
        }
    )

    async def probe(stream_id: str) -> str:
        async with transport.route(stream_id=stream_id) as route:
            await transport.send(build_stream_envelope("probe", stream_id, {}))
            frame = await route.next_frame(2.0)
            echoed: str = frame["payload"]["echo"]
            return echoed

    results = await asyncio.gather(*(probe(f"S{index}") for index in range(8)))
    assert results == [f"S{index}" for index in range(8)]


async def test_unroutable_frames_are_dropped_and_counted(fake: FakeServerFactory) -> None:
    transport = await fake.transport(
        {"ack": False, "handlers": {"probe": [{"type": "reply", "payload": {}}]}}
    )
    # No route is open, so the reply has nowhere to go.
    await transport.send(build_stream_envelope("probe", "ORPHAN", {}))
    for _ in range(40):
        if transport.dropped_frames:
            break
        await asyncio.sleep(0.02)
    assert transport.dropped_frames >= 1


async def test_duplicate_route_is_rejected(fake: FakeServerFactory) -> None:
    transport = await fake.transport({})
    async with transport.route(stream_id="DUP"):
        with pytest.raises(MakaiStreamError, match="already open"):
            async with transport.route(stream_id="DUP"):
                pass


async def test_route_requires_exactly_one_key(fake: FakeServerFactory) -> None:
    transport = await fake.transport({})
    with pytest.raises(ValueError):
        transport.route()
    with pytest.raises(ValueError):
        transport.route(stream_id="a", session_id="b")


async def test_next_frame_times_out(fake: FakeServerFactory) -> None:
    transport = await fake.transport({"ack": False})
    async with transport.route(stream_id="QUIET") as route:
        with pytest.raises(MakaiStreamError, match="timed out waiting for frame"):
            await route.next_frame(0.2)


async def test_child_death_fails_open_routes(fake: FakeServerFactory) -> None:
    transport = await fake.transport({"exit_after": 1, "ack": False})
    async with transport.route(stream_id="DOOMED") as route:
        await transport.send(build_stream_envelope("probe", "DOOMED", {}))
        with pytest.raises(MakaiStreamError, match="exited"):
            await route.next_frame(3.0)


async def test_child_death_fails_every_open_route(fake: FakeServerFactory) -> None:
    transport = await fake.transport({"exit_after": 1, "ack": False})

    async def wait(stream_id: str) -> BaseException:
        async with transport.route(stream_id=stream_id) as route:
            try:
                await route.next_frame(3.0)
            except BaseException as exc:
                return exc
            raise AssertionError("expected a failure")

    waiters = [asyncio.create_task(wait(f"R{index}")) for index in range(3)]
    await asyncio.sleep(0.1)
    await transport.send(build_stream_envelope("probe", "TRIGGER", {}))
    errors = await asyncio.gather(*waiters)
    assert all(isinstance(error, MakaiStreamError) for error in errors)


async def test_close_terminates_the_child(fake: FakeServerFactory) -> None:
    transport = await fake.transport({})
    pid = transport.pid
    assert pid is not None
    await transport.close()
    for _ in range(50):
        if not process_alive(pid):
            break
        await asyncio.sleep(0.05)
    assert not process_alive(pid)
    assert not transport.connected


async def test_close_is_idempotent(fake: FakeServerFactory) -> None:
    transport = await fake.transport({})
    await transport.close()
    await transport.close()


async def test_send_after_close_is_typed(fake: FakeServerFactory) -> None:
    transport = await fake.transport({})
    await transport.close()
    with pytest.raises(MakaiStreamError, match="not connected"):
        await transport.send({"type": "probe"})


async def test_connect_twice_is_rejected(fake: FakeServerFactory) -> None:
    transport = await fake.transport({})
    with pytest.raises(RuntimeError, match="already connected"):
        await transport.connect()


async def test_invalid_json_after_handshake_is_skipped(fake: FakeServerFactory) -> None:
    """A malformed line must not poison later frames on live routes."""
    transport = await fake.transport(
        {
            "ack": False,
            "handlers": {
                "probe": [
                    {"raw": "{not json at all"},
                    {"raw": "[1, 2, 3]"},
                    {"type": "reply", "payload": {"ok": True}},
                ]
            },
        }
    )
    async with transport.route(stream_id="AFTER") as route:
        await transport.send(build_stream_envelope("probe", "AFTER", {}))
        frame = await route.next_frame(2.0)
        assert frame["type"] == "reply"
        assert frame["payload"] == {"ok": True}


async def test_async_context_manager_closes(fake: FakeServerFactory) -> None:
    env = {"MAKAI_FAKE_CONFIG": fake.write_config({}), "PATH": "/usr/bin"}
    async with StdioTransport(command=sys.executable, args=[FIXTURE_SERVER], env=env) as transport:
        pid = transport.pid
        assert pid is not None
    for _ in range(50):
        if not process_alive(pid):
            break
        await asyncio.sleep(0.05)
    assert not process_alive(pid)


async def test_concurrent_connects_do_not_spawn_two_children(
    fake: FakeServerFactory,
) -> None:
    """The connected check used to sit before the first suspension point."""
    import os

    env = dict(os.environ)
    env["MAKAI_FAKE_CONFIG"] = fake.write_config({})
    env.pop("MAKAI_BINARY_PATH", None)
    transport = StdioTransport(command=sys.executable, args=[FIXTURE_SERVER], env=env)

    results = await asyncio.gather(
        transport.connect(), transport.connect(), return_exceptions=True
    )
    # One call wins; the other is refused rather than spawning a second child.
    assert sum(1 for result in results if result is None) == 1
    refusals = [result for result in results if isinstance(result, RuntimeError)]
    assert len(refusals) == 1
    assert "already connected" in str(refusals[0])

    pid = transport.pid
    assert pid is not None
    await transport.close()
    await asyncio.sleep(0.1)
    assert not process_alive(pid)


async def test_an_oversized_frame_tears_the_transport_down(
    fake: FakeServerFactory, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A line past the limit must close the transport and reap the child.

    The reader stops consuming stdout on this path, so leaving the transport
    open reports ``connected`` while every later route waits for frames that
    can no longer arrive, with the child still running behind it.
    """
    monkeypatch.setattr("makai.transport._MAX_LINE_BYTES", 4096)
    transport = await fake.transport(
        {"ack": False, "handlers": {"probe": [{"raw": "x" * 16384}]}}
    )
    pid = transport.pid
    assert pid is not None
    async with transport.route(stream_id="HUGE") as route:
        await transport.send(build_stream_envelope("probe", "HUGE", {}))
        with pytest.raises(MakaiStreamError, match="oversized frame"):
            await route.next_frame(3.0)

    assert not transport.connected
    with pytest.raises(MakaiStreamError, match="not connected"):
        await transport.send(build_stream_envelope("probe", "LATER", {}))
    for _ in range(50):
        if not process_alive(pid):
            break
        await asyncio.sleep(0.05)
    assert not process_alive(pid)
    await transport.close()
    await transport.close()


async def test_a_child_that_exits_marks_the_transport_disconnected(
    fake: FakeServerFactory,
) -> None:
    """After the child exits, connected and pid must stop claiming a live host.

    The clean-EOF path used to fail the open routes and stop there, leaving
    _closed False and _process set, so only the next request's typed error
    revealed that the host was gone.
    """
    transport = await fake.transport({"exit_after": 1, "ack": False})
    async with transport.route(stream_id="GONE") as route:
        await transport.send(build_stream_envelope("probe", "GONE", {}))
        with pytest.raises(MakaiStreamError, match="exited"):
            await route.next_frame(3.0)

    assert not transport.connected
    assert transport.pid is None
    with pytest.raises(MakaiStreamError, match="not connected"):
        await transport.send(build_stream_envelope("probe", "AFTER", {}))


async def test_close_during_connect_does_not_orphan_the_child(
    fake: FakeServerFactory, monkeypatch: pytest.MonkeyPatch
) -> None:
    """close() landing mid-spawn must not leave a live child behind.

    close() finds no process to reap and returns; connect() then installed the
    one it had just spawned, so the handshake succeeded and every later send
    raised 'not connected' with the child still running.
    """
    env = dict(os.environ)
    env["MAKAI_FAKE_CONFIG"] = fake.write_config({})
    env.pop("MAKAI_BINARY_PATH", None)
    transport = StdioTransport(command=sys.executable, args=[FIXTURE_SERVER], env=env)

    spawned: List[Any] = []
    real_exec = asyncio.create_subprocess_exec

    async def exec_then_close(*args: Any, **kwargs: Any) -> Any:
        process = await real_exec(*args, **kwargs)
        spawned.append(process)
        await transport.close()
        return process

    monkeypatch.setattr(asyncio, "create_subprocess_exec", exec_then_close)
    with pytest.raises(MakaiStreamError, match="closed while connecting"):
        await transport.connect()
    monkeypatch.undo()

    assert len(spawned) == 1
    assert not transport.connected
    assert transport.pid is None
    pid = spawned[0].pid
    for _ in range(50):
        if not process_alive(pid):
            break
        await asyncio.sleep(0.05)
    assert not process_alive(pid)


async def test_a_frame_timeout_is_identified_by_code_not_message(
    fake: FakeServerFactory,
) -> None:
    """Timeout classification must survive a reworded message.

    Three call sites branch on 'is this a timeout?'; matching the wording of
    the message transport.py happens to emit couples them all to that string.
    """
    transport = await fake.transport({"ack": False})
    async with transport.route(stream_id="QUIET") as route:
        with pytest.raises(MakaiStreamError) as excinfo:
            await route.next_frame(0.2)

    assert excinfo.value.code == TIMEOUT_CODE
    assert is_timeout_error(excinfo.value)
    assert not is_timeout_error(
        MakaiStreamError("timed out waiting for frame for x", kind="transport_error")
    )
    assert not is_timeout_error(
        MakaiStreamError("transport closed", kind="transport_error")
    )
