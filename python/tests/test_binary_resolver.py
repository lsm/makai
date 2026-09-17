"""Binary resolution order and checksum enforcement."""

from __future__ import annotations

import hashlib
import http.server
import os
import threading
from pathlib import Path
from typing import Iterator

import pytest

from makai.binary import BinaryResolverOptions, resolve_makai_binary


@pytest.fixture(autouse=True)
def clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in ("MAKAI_BINARY_PATH", "MAKAI_BINARY_URL", "MAKAI_BINARY_SHA256"):
        monkeypatch.delenv(name, raising=False)


def make_binary(directory: Path, name: str = "makai") -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_bytes(b"#!/bin/sh\nexit 0\n")
    path.chmod(0o755)
    return path


def test_explicit_path_wins(tmp_path: Path) -> None:
    binary = make_binary(tmp_path / "explicit")
    resolved = resolve_makai_binary(BinaryResolverOptions(binary_path=str(binary)))
    assert resolved == str(binary.resolve())


def test_env_path_overrides_option(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from_env = make_binary(tmp_path / "env")
    from_option = make_binary(tmp_path / "option")
    monkeypatch.setenv("MAKAI_BINARY_PATH", str(from_env))
    resolved = resolve_makai_binary(BinaryResolverOptions(binary_path=str(from_option)))
    assert resolved == str(from_env.resolve())


def test_missing_explicit_path_raises(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        resolve_makai_binary(BinaryResolverOptions(binary_path=str(tmp_path / "nope")))


def test_url_requires_checksum() -> None:
    with pytest.raises(ValueError, match="SHA256 checksum is required"):
        resolve_makai_binary(BinaryResolverOptions(binary_url="https://example.invalid/makai"))


def test_zig_out_before_zig_zig_out(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    make_binary(tmp_path / "zig-out" / "bin")
    make_binary(tmp_path / "zig" / "zig-out" / "bin")
    monkeypatch.chdir(tmp_path)
    assert resolve_makai_binary() == str(tmp_path / "zig-out" / "bin" / "makai")


def test_nested_zig_out_used_when_top_level_absent(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    make_binary(tmp_path / "zig" / "zig-out" / "bin")
    monkeypatch.chdir(tmp_path)
    assert resolve_makai_binary() == str(tmp_path / "zig" / "zig-out" / "bin" / "makai")


def test_path_lookup_when_no_local_build(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    on_path = make_binary(tmp_path / "bin")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PATH", str(tmp_path / "bin"))
    assert resolve_makai_binary() == str(on_path)


def test_falls_back_to_bare_name(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    empty = tmp_path / "empty"
    empty.mkdir()
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PATH", str(empty))
    assert resolve_makai_binary() == "makai"


class _Server(http.server.BaseHTTPRequestHandler):
    payload = b""

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        self.send_response(200)
        self.send_header("Content-Length", str(len(self.payload)))
        self.end_headers()
        self.wfile.write(self.payload)

    def log_message(self, *args: object) -> None:
        return


class _FastHTTPServer(http.server.HTTPServer):
    """``HTTPServer`` without the reverse-DNS lookup in ``server_bind``.

    ``socket.getfqdn()`` can block for tens of seconds on macOS.
    """

    def server_bind(self) -> None:
        import socketserver

        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = int(port)


@pytest.fixture
def http_server() -> Iterator[str]:
    _Server.payload = b"fake-makai-binary"
    server = _FastHTTPServer(("127.0.0.1", 0), _Server)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/makai"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_url_download_verifies_checksum(tmp_path: Path, http_server: str) -> None:
    digest = hashlib.sha256(b"fake-makai-binary").hexdigest()
    cache = tmp_path / "cache"
    resolved = resolve_makai_binary(
        BinaryResolverOptions(
            binary_url=http_server, checksum_sha256=digest, cache_dir=str(cache)
        )
    )
    assert Path(resolved).read_bytes() == b"fake-makai-binary"
    assert os.access(resolved, os.X_OK)

    # A second resolve is served from cache without re-downloading.
    again = resolve_makai_binary(
        BinaryResolverOptions(
            binary_url=http_server, checksum_sha256=digest, cache_dir=str(cache)
        )
    )
    assert again == resolved


def test_url_download_rejects_checksum_mismatch(tmp_path: Path, http_server: str) -> None:
    with pytest.raises(ValueError, match="checksum mismatch"):
        resolve_makai_binary(
            BinaryResolverOptions(
                binary_url=http_server,
                checksum_sha256="0" * 64,
                cache_dir=str(tmp_path / "cache"),
            )
        )


def test_poisoned_cache_entry_is_replaced(tmp_path: Path, http_server: str) -> None:
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / "makai").write_bytes(b"tampered")
    digest = hashlib.sha256(b"fake-makai-binary").hexdigest()
    resolved = resolve_makai_binary(
        BinaryResolverOptions(
            binary_url=http_server, checksum_sha256=digest, cache_dir=str(cache)
        )
    )
    assert Path(resolved).read_bytes() == b"fake-makai-binary"


def test_rejects_non_http_url(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="unsupported binary_url scheme"):
        resolve_makai_binary(
            BinaryResolverOptions(
                binary_url="file:///etc/passwd",
                checksum_sha256="0" * 64,
                cache_dir=str(tmp_path),
            )
        )
