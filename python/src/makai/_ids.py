"""Protocol identifier generation.

The Makai protocols use two wire formats for identifiers (spec §3.1):

* ``session_id`` -- a 21-character alphanumeric NanoID.
* ``message_id`` / ``stream_id`` / ``flow_id`` -- a 26-character uppercase
  Crockford Base32 ULID.

Both are generated here so the SDK has no third-party runtime dependencies.
Identifiers are opaque to callers; nothing outside this module parses them.
"""

from __future__ import annotations

import os
import secrets
import time

__all__ = ["new_nano_id", "new_ulid", "is_nano_id", "is_ulid"]

_NANO_ID_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
_NANO_ID_LENGTH = 21

_CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
_ULID_LENGTH = 26


def new_nano_id() -> str:
    """Return a fresh 21-character alphanumeric NanoID."""
    return "".join(secrets.choice(_NANO_ID_ALPHABET) for _ in range(_NANO_ID_LENGTH))


def new_ulid() -> str:
    """Return a fresh 26-character uppercase Crockford Base32 ULID.

    The leading 48 bits encode milliseconds since the Unix epoch, so ULIDs
    minted in the same process sort roughly by creation time. The trailing 80
    bits come from the OS CSPRNG.
    """
    timestamp_ms = int(time.time() * 1000) & ((1 << 48) - 1)
    randomness = int.from_bytes(os.urandom(10), "big")
    value = (timestamp_ms << 80) | randomness

    out = [""] * _ULID_LENGTH
    for index in range(_ULID_LENGTH - 1, -1, -1):
        out[index] = _CROCKFORD[value & 0x1F]
        value >>= 5
    return "".join(out)


def is_nano_id(value: str) -> bool:
    """Return ``True`` when ``value`` has the ``session_id`` wire shape."""
    if len(value) != _NANO_ID_LENGTH:
        return False
    return all(char.isascii() and char.isalnum() for char in value)


def is_ulid(value: str) -> bool:
    """Return ``True`` when ``value`` has the ULID wire shape."""
    if len(value) != _ULID_LENGTH:
        return False
    return all(char in _CROCKFORD for char in value)
