"""Identifier generation matches the wire formats in spec §3.1."""

from __future__ import annotations

import re

from makai._ids import is_nano_id, is_ulid, new_nano_id, new_ulid

NANO_ID_RE = re.compile(r"^[0-9A-Za-z]{21}$")
ULID_RE = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")


def test_nano_id_shape() -> None:
    for _ in range(200):
        value = new_nano_id()
        assert NANO_ID_RE.match(value), value
        assert is_nano_id(value)


def test_ulid_shape() -> None:
    for _ in range(200):
        value = new_ulid()
        assert ULID_RE.match(value), value
        assert is_ulid(value)


def test_ids_are_unique() -> None:
    assert len({new_nano_id() for _ in range(500)}) == 500
    assert len({new_ulid() for _ in range(500)}) == 500


def test_ulids_sort_by_creation_time() -> None:
    # Only the 10-character timestamp prefix is ordered; the 16-character
    # suffix is random, so values minted within one millisecond are unordered
    # among themselves and the whole list is sorted only by accident.
    prefixes = [new_ulid()[:10] for _ in range(50)]
    assert prefixes == sorted(prefixes)


def test_validators_reject_wrong_shapes() -> None:
    assert not is_nano_id("short")
    assert not is_nano_id("x" * 22)
    assert not is_nano_id("!" * 21)
    assert not is_ulid("short")
    # 'I', 'L', 'O', and 'U' are excluded from Crockford Base32.
    assert not is_ulid("I" * 26)
    assert not is_ulid("U" * 26)
