"""Internal ``model_ref`` parser.

``model_ref`` is an opaque, server-issued handle (spec §3.2). **Application
code must never parse or construct one** -- take it from ``models.list`` or
``models.resolve`` and pass it through unchanged.

The SDK itself has to look inside for exactly one reason: the provider
protocol's ``complete_request`` / ``stream_request`` payloads carry a resolved
``model`` object (``ai_types.Model``), not a ``model_ref``. This module
reconstructs that object, and is also used for timeout diagnostics. It mirrors
``typescript/src/diagnostics/model_ref.ts``, which is documented the same way.

A ref that does not parse is passed through opaquely rather than rejected, so a
future server-side format change cannot break request submission.
"""

from __future__ import annotations

from typing import NamedTuple
from urllib.parse import unquote

__all__ = ["ParsedModelRef", "ModelRefParseError", "parse_model_ref"]

_UNRESERVED_EXTRA = frozenset("-._~")
_HEX_DIGITS = frozenset("0123456789abcdefABCDEF")


class ParsedModelRef(NamedTuple):
    provider_id: str
    api: str
    model_id: str


class ModelRefParseError(ValueError):
    """``model_ref`` did not match the canonical server format."""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


def parse_model_ref(model_ref: str) -> ParsedModelRef:
    """Parse ``provider_id/api@percent-encoded-model-id``.

    Raises :class:`ModelRefParseError` when ``model_ref`` is not in the
    canonical form.
    """
    slash_index = model_ref.find("/")
    if slash_index == -1:
        raise ModelRefParseError("model_ref is missing '/' and '@' separators", "missing_separators")
    if slash_index == 0:
        raise ModelRefParseError("model_ref is missing provider_id segment", "missing_provider_id")

    first_at = model_ref.find("@")
    if first_at != -1 and first_at < slash_index:
        raise ModelRefParseError("model_ref contains ambiguous separators in provider_id", "ambiguous_separators")

    at_offset = model_ref.find("@", slash_index + 1)
    if at_offset == -1:
        raise ModelRefParseError("model_ref is missing '@' separator", "missing_separators")

    provider_id = model_ref[:slash_index]
    api = model_ref[slash_index + 1 : at_offset]
    encoded_model_id = model_ref[at_offset + 1 :]

    if "/" in api:
        raise ModelRefParseError("model_ref contains ambiguous '/' separators", "ambiguous_separators")
    if "@" in encoded_model_id or "/" in encoded_model_id:
        raise ModelRefParseError("model_ref contains ambiguous separators", "ambiguous_separators")

    _validate_segment(provider_id, "provider_id")
    _validate_segment(api, "api")

    if not encoded_model_id:
        raise ModelRefParseError("model_ref is missing model_id segment", "missing_model_id")
    _validate_encoded_model_id(encoded_model_id)

    try:
        model_id = unquote(encoded_model_id, errors="strict")
    except UnicodeDecodeError as exc:
        raise ModelRefParseError(
            "model_ref model_id is not valid UTF-8 percent encoding", "invalid_utf8_model_id"
        ) from exc
    return ParsedModelRef(provider_id=provider_id, api=api, model_id=model_id)


def _validate_segment(value: str, name: str) -> None:
    if not value:
        raise ModelRefParseError(f"model_ref is missing {name} segment", f"missing_{name}")
    if any(char in value for char in ("/", "@", "%")):
        raise ModelRefParseError(f"{name} contains forbidden characters", f"invalid_{name}")


def _validate_encoded_model_id(encoded: str) -> None:
    index = 0
    length = len(encoded)
    while index < length:
        char = encoded[index]
        if char == "%":
            if index + 2 >= length or encoded[index + 1] not in _HEX_DIGITS or encoded[index + 2] not in _HEX_DIGITS:
                raise ModelRefParseError("model_id has invalid percent escape", "invalid_percent_escape")
            index += 3
            continue
        if not (char.isascii() and (char.isalnum() or char in _UNRESERVED_EXTRA)):
            raise ModelRefParseError(
                "model_id has non-canonical unescaped characters", "invalid_model_id_encoding"
            )
        index += 1
