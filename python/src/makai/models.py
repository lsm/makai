"""The ``models`` namespace: discovery and deterministic resolution.

``models.list`` and ``models.resolve`` both map to a ``models_request``
envelope (spec §3.6 -- there is no separate resolve envelope); ``resolve``
adds an exact ``model_id`` filter and asserts the response contains exactly
one matching model.
"""

from __future__ import annotations

import logging
import math
from typing import Any, Dict, List, Mapping, Optional, Set

from ._diagnostics import TimeoutContext, build_diagnostics, format_timeout_message
from ._ids import new_ulid
from ._wire import build_stream_envelope, payload_of
from .errors import TIMEOUT_CODE, MakaiProtocolError, MakaiStreamError, is_timeout_error
from .transport import StdioTransport
from .types import ListModelsResponse, ModelCapability, ModelDescriptor, ReasoningEffort

__all__ = ["ModelsApi"]

logger = logging.getLogger("makai.models")

DEFAULT_RESPONSE_TIMEOUT_S = 5.0
DEFAULT_CACHE_MAX_AGE_MS = 300_000
MAX_PROVIDER_ID_LENGTH = 256
MAX_MODEL_ID_LENGTH = 256
MALFORMED_RESPONSE_CODE = "malformed_response"

_KNOWN_AUTH_STATUSES: Set[str] = {
    "authenticated",
    "login_required",
    "expired",
    "refreshing",
    "login_in_progress",
    "failed",
    "unknown",
}
_KNOWN_LIFECYCLES: Set[str] = {"stable", "preview", "deprecated"}
_KNOWN_CAPABILITIES: Set[str] = {
    "chat",
    "streaming",
    "tools",
    "vision",
    "reasoning",
    "prompt_cache",
    "audio_input",
    "audio_output",
}
_KNOWN_SOURCES: Set[str] = {"dynamic", "static_fallback"}
_KNOWN_REASONING_LEVELS: Set[str] = {"off", "minimal", "low", "medium", "high", "xhigh"}


class ModelsApi:
    """Model discovery over the provider protocol."""

    def __init__(
        self,
        transport: StdioTransport,
        *,
        response_timeout: float = DEFAULT_RESPONSE_TIMEOUT_S,
    ) -> None:
        self._transport = transport
        self._response_timeout = response_timeout

    async def list(
        self,
        *,
        provider_id: Optional[str] = None,
        api: Optional[str] = None,
        model_id: Optional[str] = None,
        include_deprecated: Optional[bool] = None,
        include_login_required: Optional[bool] = None,
    ) -> ListModelsResponse:
        """List known models, optionally filtered.

        Raises:
            MakaiProtocolError: the request was rejected or the response was
                malformed.
        """
        if provider_id is not None and len(provider_id) > MAX_PROVIDER_ID_LENGTH:
            raise MakaiProtocolError(
                f"provider_id exceeds maximum length of {MAX_PROVIDER_ID_LENGTH} characters",
                "invalid_request",
            )
        if model_id is not None and len(model_id) > MAX_MODEL_ID_LENGTH:
            raise MakaiProtocolError(
                f"model_id exceeds maximum length of {MAX_MODEL_ID_LENGTH} characters",
                "invalid_request",
            )
        return await self._dispatch(
            {
                "provider_id": provider_id,
                "api": api,
                "model_id": model_id,
                "include_deprecated": include_deprecated,
                "include_login_required": include_login_required,
            }
        )

    async def resolve(
        self,
        *,
        provider_id: str,
        model_id: str,
        api: Optional[str] = None,
    ) -> ModelDescriptor:
        """Resolve exactly one model and return its descriptor.

        Unlike the TypeScript SDK, which returns ``{model}``, this returns the
        :class:`~makai.types.ModelDescriptor` directly -- the wrapper carries
        no extra information in Python.

        Raises:
            MakaiProtocolError: no match, more than one match, or a mismatch
                between the request filters and the returned descriptor.
        """
        if not provider_id:
            raise MakaiProtocolError("resolve requires provider_id", "invalid_request")
        if len(provider_id) > MAX_PROVIDER_ID_LENGTH:
            raise MakaiProtocolError(
                f"provider_id exceeds maximum length of {MAX_PROVIDER_ID_LENGTH} characters",
                "invalid_request",
            )
        if not model_id:
            raise MakaiProtocolError("resolve requires model_id", "invalid_request")
        if len(model_id) > MAX_MODEL_ID_LENGTH:
            raise MakaiProtocolError(
                f"model_id exceeds maximum length of {MAX_MODEL_ID_LENGTH} characters",
                "invalid_request",
            )

        response = await self._dispatch(
            {"provider_id": provider_id, "api": api, "model_id": model_id}
        )
        if not response.models:
            raise MakaiProtocolError("model not found", "invalid_request")
        if len(response.models) > 1:
            raise MakaiProtocolError(
                f"resolve returned {len(response.models)} matches; expected exactly 1",
                "invalid_request",
            )
        model = response.models[0]
        if model.provider_id != provider_id:
            raise MakaiProtocolError("resolved model provider_id mismatch", "invalid_request")
        if model.model_id != model_id:
            raise MakaiProtocolError("resolved model_id mismatch", "invalid_request")
        if api is not None and model.api != api:
            raise MakaiProtocolError("resolved model api mismatch", "invalid_request")
        return model

    async def _dispatch(self, filters: Mapping[str, Any]) -> ListModelsResponse:
        stream_id = new_ulid()
        context = TimeoutContext(
            "models_response",
            self._response_timeout,
            stream_id=stream_id,
            message_id=stream_id,
            provider_id=filters.get("provider_id"),
            api=filters.get("api"),
            model_id=filters.get("model_id"),
        )
        envelope = build_stream_envelope("models_request", stream_id, _build_payload(filters))
        logger.debug("models_request stream_id=%s filters=%s", stream_id, dict(filters))

        async with self._transport.route(stream_id=stream_id) as route:
            await self._send(envelope)
            while True:
                try:
                    frame = await route.next_frame(self._response_timeout)
                except MakaiStreamError as exc:
                    raise _timeout_aware(exc, context) from exc
                frame_type = frame.get("type")
                if frame_type == "ack":
                    continue
                if frame_type == "nack":
                    raise _nack_to_error(frame)
                if frame_type == "models_response":
                    response = _parse_models_response(frame)
                    logger.debug("models_response count=%d", len(response.models))
                    return response
                raise MakaiProtocolError(
                    f"unexpected frame type while awaiting models_response: {frame_type}",
                    MALFORMED_RESPONSE_CODE,
                )

    async def _send(self, envelope: Mapping[str, Any]) -> None:
        try:
            await self._transport.send(dict(envelope))
        except MakaiStreamError as exc:
            raise MakaiProtocolError(str(exc), exc.code) from exc


def _build_payload(filters: Mapping[str, Any]) -> Dict[str, Any]:
    payload: Dict[str, Any] = {}
    for key in ("provider_id", "api", "model_id"):
        value = filters.get(key)
        if isinstance(value, str) and value:
            payload[key] = value
    for key in ("include_deprecated", "include_login_required"):
        value = filters.get(key)
        if isinstance(value, bool):
            payload[key] = value
    return payload


def _timeout_aware(error: MakaiStreamError, context: TimeoutContext) -> MakaiProtocolError:
    if is_timeout_error(error):
        return MakaiProtocolError(
            format_timeout_message(context),
            TIMEOUT_CODE,
            diagnostics=build_diagnostics(context),
        )
    return MakaiProtocolError(error.message, error.code)


def _nack_to_error(frame: Mapping[str, Any]) -> MakaiProtocolError:
    payload = payload_of(frame)
    reason = payload.get("reason")
    code = payload.get("error_code")
    return MakaiProtocolError(
        reason if isinstance(reason, str) and reason else "models request rejected",
        code if isinstance(code, str) else None,
    )


def _malformed(message: str) -> MakaiProtocolError:
    return MakaiProtocolError(message, MALFORMED_RESPONSE_CODE)


def _finite_int(value: Any) -> Optional[int]:
    """Convert a JSON number to ``int``, or ``None`` when it is not one.

    Python's JSON decoder accepts ``NaN``, ``Infinity`` and ``-Infinity``, all
    of which are floats, so an isinstance check alone lets them through to an
    ``int()`` that raises ``ValueError`` or ``OverflowError`` instead of this
    module's typed error.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value):
        return None
    return int(value)


def _parse_models_response(frame: Mapping[str, Any]) -> ListModelsResponse:
    raw_payload = frame.get("payload")
    if not isinstance(raw_payload, dict):
        raise _malformed("models_response missing payload object")

    raw_models = raw_payload.get("models")
    if not isinstance(raw_models, list):
        raise _malformed("models_response missing 'models' array")

    fetched_at_ms = _finite_int(raw_payload.get("fetched_at_ms"))
    if fetched_at_ms is None:
        raise _malformed("models_response missing numeric 'fetched_at_ms'")

    cache_max_age_ms = _finite_int(raw_payload.get("cache_max_age_ms"))
    if cache_max_age_ms is None:
        cache_max_age_ms = DEFAULT_CACHE_MAX_AGE_MS

    models = [_parse_descriptor(item, index) for index, item in enumerate(raw_models)]
    return ListModelsResponse(
        models=models,
        fetched_at_ms=fetched_at_ms,
        cache_max_age_ms=cache_max_age_ms,
    )


def _parse_descriptor(raw: Any, index: int) -> ModelDescriptor:
    if not isinstance(raw, dict):
        raise _malformed(f"models[{index}] is not an object")

    capabilities_raw = raw.get("capabilities")
    if not isinstance(capabilities_raw, list):
        raise _malformed(f"models[{index}].capabilities must be an array")
    capabilities: List[ModelCapability] = []
    for cap_index, capability in enumerate(capabilities_raw):
        if not isinstance(capability, str):
            raise _malformed(f"models[{index}].capabilities[{cap_index}] must be a string")
        if capability not in _KNOWN_CAPABILITIES:
            raise _malformed(
                f"models[{index}].capabilities[{cap_index}] has unknown value: {capability}"
            )
        capabilities.append(capability)  # type: ignore[arg-type]

    metadata: Optional[Dict[str, str]] = None
    raw_metadata = raw.get("metadata")
    if isinstance(raw_metadata, dict):
        metadata = {}
        for key, value in raw_metadata.items():
            if not isinstance(value, str):
                raise _malformed(f"models[{index}].metadata.{key} must be a string")
            metadata[key] = value

    reasoning_default: Optional[ReasoningEffort] = None
    if raw.get("reasoning_default") is not None:
        reasoning_default = _require_known(  # type: ignore[assignment]
            raw.get("reasoning_default"),
            f"models[{index}].reasoning_default",
            _KNOWN_REASONING_LEVELS,
        )

    return ModelDescriptor(
        model_ref=_require_str(raw.get("model_ref"), f"models[{index}].model_ref"),
        model_id=_require_str(raw.get("model_id"), f"models[{index}].model_id"),
        display_name=_require_str(raw.get("display_name"), f"models[{index}].display_name"),
        provider_id=_require_str(raw.get("provider_id"), f"models[{index}].provider_id"),
        api=_require_str(raw.get("api"), f"models[{index}].api"),
        auth_status=_require_known(  # type: ignore[arg-type]
            raw.get("auth_status"), f"models[{index}].auth_status", _KNOWN_AUTH_STATUSES
        ),
        lifecycle=_require_known(  # type: ignore[arg-type]
            raw.get("lifecycle"), f"models[{index}].lifecycle", _KNOWN_LIFECYCLES
        ),
        capabilities=capabilities,
        source=_require_known(  # type: ignore[arg-type]
            raw.get("source"), f"models[{index}].source", _KNOWN_SOURCES
        ),
        base_url=_optional_nonempty_str(raw.get("base_url")),
        context_window=_finite_int(raw.get("context_window")),
        max_output_tokens=_finite_int(raw.get("max_output_tokens")),
        reasoning_default=reasoning_default,
        metadata=metadata,
    )


def _require_str(value: Any, field_name: str) -> str:
    if not isinstance(value, str):
        raise _malformed(f"{field_name} must be a string")
    return value


def _require_known(value: Any, field_name: str, known: Set[str]) -> str:
    text = _require_str(value, field_name)
    if text not in known:
        raise _malformed(f"{field_name} has unknown value: {text}")
    return text


def _optional_nonempty_str(value: Any) -> Optional[str]:
    return value if isinstance(value, str) and value else None

