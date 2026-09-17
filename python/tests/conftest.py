"""Shared fixtures: fake-server transports and clients.

The ``fake`` fixture spawns ``fixtures/fake_server.py`` with a JSON config, so
transport, framing, routing, sequencing, error mapping, and cancellation are
all exercised without a runtime binary or any credentials.

``real_binary`` points at a locally built ``makai`` and skips when
``MAKAI_BINARY_PATH`` is unset, so the suite is green without one but never
silently claims real-runtime coverage.
"""

from __future__ import annotations

import itertools
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, AsyncIterator, Dict, List, Optional

import pytest

from makai.client import AuthOptions, MakaiClient
from makai.transport import StdioTransport

FIXTURE_SERVER = str(Path(__file__).parent / "fixtures" / "fake_server.py")

_counter = itertools.count()


def read_log(log_path: str) -> List[Dict[str, Any]]:
    """Return every frame the fake server received, in order."""
    path = Path(log_path)
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


class FakeServerFactory:
    """Builds transports and clients backed by the fake protocol server."""

    def __init__(self, directory: Path) -> None:
        self._directory = directory
        self._transports: List[StdioTransport] = []
        self._clients: List[MakaiClient] = []

    def log_path(self) -> str:
        """Return a fresh path for a request log."""
        return str(self._directory / f"requests-{next(_counter)}.jsonl")

    def write_config(self, config: Dict[str, Any]) -> str:
        path = self._directory / f"config-{next(_counter)}.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        return str(path)

    async def transport(
        self, config: Optional[Dict[str, Any]] = None, **kwargs: Any
    ) -> StdioTransport:
        env = dict(os.environ)
        env["MAKAI_FAKE_CONFIG"] = self.write_config(config or {})
        env.pop("MAKAI_BINARY_PATH", None)
        transport = StdioTransport(
            command=sys.executable,
            args=[FIXTURE_SERVER],
            env=env,
            **kwargs,
        )
        self._transports.append(transport)
        await transport.connect()
        return transport

    async def client(
        self,
        config: Optional[Dict[str, Any]] = None,
        *,
        auth: Optional[AuthOptions] = None,
        response_timeout: Optional[float] = None,
        frame_timeout: Optional[float] = None,
        **kwargs: Any,
    ) -> MakaiClient:
        transport = await self.transport(config, **kwargs)
        client = MakaiClient(
            transport,
            auth=auth,
            response_timeout=response_timeout,
            frame_timeout=frame_timeout,
        )
        self._clients.append(client)
        return client

    async def aclose(self) -> None:
        for client in self._clients:
            await client.close()
        for transport in self._transports:
            await transport.close()


@pytest.fixture
async def fake() -> AsyncIterator[FakeServerFactory]:
    with tempfile.TemporaryDirectory(prefix="makai-py-tests-") as directory:
        factory = FakeServerFactory(Path(directory))
        try:
            yield factory
        finally:
            await factory.aclose()


@pytest.fixture(scope="session")
def real_binary() -> str:
    """Path to a locally built ``makai``, or skip the test."""
    path = os.environ.get("MAKAI_BINARY_PATH")
    if not path:
        pytest.skip("MAKAI_BINARY_PATH is not set; build with `zig build install --prefix ...`")
    if not Path(path).exists():
        pytest.skip(f"MAKAI_BINARY_PATH points at a missing file: {path}")
    return path


def process_alive(pid: Optional[int]) -> bool:
    """Return ``True`` when ``pid`` still names a live (non-zombie) process."""
    if pid is None or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        state = subprocess.run(
            ["ps", "-o", "state=", "-p", str(pid)],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
    except OSError:  # pragma: no cover - ps missing
        return True
    if not state:
        return False
    return not state.startswith("Z")
