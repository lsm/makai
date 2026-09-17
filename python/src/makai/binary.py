"""Locating the ``makai`` runtime binary.

Resolution order mirrors ``typescript/src/binary_resolver.ts``:

1. ``BinaryResolverOptions.binary_path``, or the ``MAKAI_BINARY_PATH``
   environment variable (the environment wins, as in the TypeScript SDK).
2. ``binary_url`` / ``MAKAI_BINARY_URL``, which **requires** a SHA-256 checksum
   (``checksum_sha256`` / ``MAKAI_BINARY_SHA256``). The download is cached and
   re-verified on every resolve.
3. ``./zig-out/bin/makai`` relative to the current working directory.
4. ``./zig/zig-out/bin/makai``.
5. ``makai`` on ``PATH``.

The TypeScript SDK has one extra step between 2 and 3: an optional
``@makai/cli-<platform>-<arch>`` npm package. **That step is deliberately
omitted here.** npm's optional-dependency mechanism installs a per-platform
package automatically; Python's closest equivalent would be publishing
platform-specific wheels, and no such distribution exists for makai today.
Inventing a ``makai-cli-<platform>`` import probe would be dead code that also
silently outranks a local ``zig build`` -- the exact footgun CLAUDE.md warns
about for the TypeScript resolver. If platform wheels are published later, this
is the place to add the step; until then, set ``MAKAI_BINARY_PATH`` when you
need to pin a specific binary.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import stat
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

__all__ = ["BinaryResolverOptions", "resolve_makai_binary"]

ENV_BINARY_PATH = "MAKAI_BINARY_PATH"
ENV_BINARY_URL = "MAKAI_BINARY_URL"
ENV_BINARY_SHA256 = "MAKAI_BINARY_SHA256"

_DOWNLOAD_TIMEOUT_S = 120.0


@dataclass(frozen=True)
class BinaryResolverOptions:
    """Options controlling how the ``makai`` binary is located.

    Attributes:
        binary_path: Explicit path to a ``makai`` executable.
        binary_url: URL to download the binary from. Requires
            ``checksum_sha256``.
        checksum_sha256: Hex-encoded SHA-256 of the downloaded binary.
        cache_dir: Where downloads are cached. Defaults to
            ``~/.cache/makai/bin``.
    """

    binary_path: Optional[str] = None
    binary_url: Optional[str] = None
    checksum_sha256: Optional[str] = None
    cache_dir: Optional[str] = None


def _binary_name() -> str:
    return "makai.exe" if os.name == "nt" else "makai"


def _sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def resolve_makai_binary(options: Optional[BinaryResolverOptions] = None) -> str:
    """Return the path (or bare command name) of the ``makai`` binary.

    Raises:
        FileNotFoundError: An explicit path was given but does not exist.
        ValueError: A URL was given without a checksum, or the checksum did
            not match the downloaded bytes.
    """
    options = options or BinaryResolverOptions()

    explicit = os.environ.get(ENV_BINARY_PATH) or options.binary_path
    if explicit:
        resolved = Path(explicit).expanduser().resolve()
        if not resolved.exists():
            raise FileNotFoundError(f"makai binary not found at {resolved}")
        return str(resolved)

    binary_url = os.environ.get(ENV_BINARY_URL) or options.binary_url
    checksum = os.environ.get(ENV_BINARY_SHA256) or options.checksum_sha256
    if binary_url:
        return _resolve_from_url(binary_url, checksum, options.cache_dir)

    name = _binary_name()
    for candidate in (
        Path.cwd() / "zig-out" / "bin" / name,
        Path.cwd() / "zig" / "zig-out" / "bin" / name,
    ):
        if candidate.exists():
            return str(candidate)

    from_path = shutil.which(name)
    if from_path:
        return from_path
    return name


def _resolve_from_url(binary_url: str, checksum: Optional[str], cache_dir: Optional[str]) -> str:
    if not checksum:
        raise ValueError(
            f"SHA256 checksum is required when downloading makai binary from URL: {binary_url}"
        )
    expected = checksum.lower()

    directory = Path(cache_dir) if cache_dir else Path.home() / ".cache" / "makai" / "bin"
    file_name = Path(urllib.parse.urlparse(binary_url).path).name or _binary_name()
    cache_path = directory / file_name

    if cache_path.exists():
        actual = _sha256(cache_path.read_bytes())
        if actual == expected:
            return str(cache_path)
        cache_path.unlink()

    content = _download(binary_url)
    actual = _sha256(content)
    if actual != expected:
        raise ValueError(f"binary checksum mismatch: expected {expected}, got {actual}")

    directory.mkdir(parents=True, exist_ok=True)
    temp_path = cache_path.with_suffix(cache_path.suffix + ".tmp")
    temp_path.write_bytes(content)
    if os.name != "nt":
        temp_path.chmod(temp_path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    temp_path.replace(cache_path)
    return str(cache_path)


def _download(binary_url: str) -> bytes:
    parsed = urllib.parse.urlparse(binary_url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"unsupported binary_url scheme: {parsed.scheme!r}")
    with urllib.request.urlopen(binary_url, timeout=_DOWNLOAD_TIMEOUT_S) as response:  # noqa: S310
        status = getattr(response, "status", 200)
        if status != 200:
            raise ValueError(f"failed to download binary: {status}")
        data: bytes = response.read()
    return data
