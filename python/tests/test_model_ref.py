"""``model_ref`` parsing.

Application code treats ``model_ref`` as opaque; the SDK parses it only to
rebuild the provider protocol's ``model`` payload. These tests pin that the
parser agrees with the server's canonical format (spec §3.2).
"""

from __future__ import annotations

import pytest

from makai._model_ref import ModelRefParseError, parse_model_ref
from makai.execution import _model_from_ref, _provider_id_from_ref, _split_model_ref


def test_parses_canonical_ref() -> None:
    parsed = parse_model_ref("anthropic/anthropic-messages@claude-sonnet-4-5")
    assert parsed.provider_id == "anthropic"
    assert parsed.api == "anthropic-messages"
    assert parsed.model_id == "claude-sonnet-4-5"


def test_decodes_percent_encoded_model_id() -> None:
    # Ollama model ids contain ':' and travel percent-encoded.
    parsed = parse_model_ref("ollama/ollama@gemma4%3A31b")
    assert parsed.model_id == "gemma4:31b"


def test_rejects_raw_colon_in_model_id() -> None:
    with pytest.raises(ModelRefParseError) as excinfo:
        parse_model_ref("ollama/ollama@gemma4:31b")
    assert excinfo.value.code == "invalid_model_id_encoding"


@pytest.mark.parametrize(
    ("model_ref", "code"),
    [
        ("no-separators", "missing_separators"),
        ("/anthropic-messages@model", "missing_provider_id"),
        ("anthropic/anthropic-messages", "missing_separators"),
        ("anthro@pic/api@model", "ambiguous_separators"),
        ("provider/a/b@model", "ambiguous_separators"),
        ("provider/api@model@extra", "ambiguous_separators"),
        ("provider/api@", "missing_model_id"),
        ("provider/api@bad%zz", "invalid_percent_escape"),
        ("provider/@model", "missing_api"),
    ],
)
def test_rejects_malformed_refs(model_ref: str, code: str) -> None:
    with pytest.raises(ModelRefParseError) as excinfo:
        parse_model_ref(model_ref)
    assert excinfo.value.code == code


def test_split_falls_back_to_loose_form() -> None:
    # Not canonical (raw colon), but still usable for the `model` payload.
    assert _split_model_ref("ollama/ollama@gemma4:31b") == ("ollama", "ollama", "gemma4:31b")


def test_split_returns_none_for_opaque_ref() -> None:
    assert _split_model_ref("totally-opaque-handle") is None


def test_model_payload_from_canonical_ref() -> None:
    assert _model_from_ref("anthropic/anthropic-messages@claude-sonnet-4-5") == {
        "id": "claude-sonnet-4-5",
        "name": "claude-sonnet-4-5",
        "api": "anthropic-messages",
        "provider": "anthropic",
        "base_url": "",
    }


def test_model_payload_from_opaque_ref_is_passed_through() -> None:
    assert _model_from_ref("opaque-handle") == {
        "id": "opaque-handle",
        "name": "opaque-handle",
        "api": "",
        "provider": "",
        "base_url": "",
    }


def test_provider_id_extraction() -> None:
    assert _provider_id_from_ref("anthropic/anthropic-messages@m") == "anthropic"
    assert _provider_id_from_ref("opaque") is None
