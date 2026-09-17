"""The ``auth`` namespace: provider listing and interactive login.

The runtime owns credential storage and every OAuth flow. This SDK never reads
``~/.makai/auth.json``, never spawns ``makai auth ...``, and never sees token
material -- it drives the auth protocol over the same transport as everything
else (spec §3.7).

A login is a single ``flow_id``-scoped exchange: the SDK sends
``auth_login_start``, forwards each ``auth_event`` to ``on_event``, answers
``prompt`` events through ``on_prompt`` with an ``auth_prompt_response``, and
finishes on ``auth_login_result``.
"""

from __future__ import annotations

import asyncio
import inspect
import logging
from typing import Any, Dict, List, Mapping, Optional, cast

from ._diagnostics import TimeoutContext, build_diagnostics, format_timeout_message
from ._ids import new_ulid
from ._wire import build_stream_envelope, payload_of
from .errors import TIMEOUT_CODE, MakaiAuthError, MakaiStreamError, is_timeout_error
from .transport import StdioTransport
from .types import (
    AuthErrorEvent,
    AuthEvent,
    AuthFlowHandlers,
    AuthProgressEvent,
    AuthPromptEvent,
    AuthStatus,
    AuthSuccessEvent,
    AuthUrlEvent,
    ProviderAuthInfo,
)

__all__ = ["AuthApi", "flatten_auth_event"]

logger = logging.getLogger("makai.auth")

DEFAULT_FRAME_TIMEOUT_S = 30.0

_VALID_AUTH_STATUSES = {
    "authenticated",
    "login_required",
    "expired",
    "refreshing",
    "login_in_progress",
    "failed",
    "unknown",
}

_EVENT_VARIANTS = ("auth_url", "prompt", "progress", "success", "error")


class AuthApi:
    """Auth protocol client."""

    def __init__(
        self,
        transport: StdioTransport,
        *,
        handlers: Optional[AuthFlowHandlers] = None,
        frame_timeout: float = DEFAULT_FRAME_TIMEOUT_S,
    ) -> None:
        self._transport = transport
        self._default_handlers = handlers
        self._frame_timeout = frame_timeout

    async def list_providers(self) -> List[ProviderAuthInfo]:
        """Return every auth provider the runtime knows about, with status.

        Raises:
            MakaiAuthError: the request was rejected, timed out, or the
                response was malformed.
        """
        stream_id = new_ulid()
        envelope = build_stream_envelope("auth_providers_request", stream_id, {})
        context = TimeoutContext(
            "auth_providers_response",
            self._frame_timeout,
            stream_id=stream_id,
            message_id=stream_id,
        )
        logger.debug("auth_providers_request stream_id=%s", stream_id)

        async with self._transport.route(stream_id=stream_id) as route:
            await self._send(envelope)
            while True:
                frame = await self._next_frame(route, context)
                frame_type = frame.get("type")
                if frame_type == "ack":
                    continue
                if frame_type == "nack":
                    raise _nack_to_auth_error(frame)
                if frame_type == "auth_providers_response":
                    return _parse_providers(frame)
                raise MakaiAuthError(
                    "unexpected envelope type while awaiting auth_providers_response: "
                    f"{frame_type}",
                    kind="transport_error",
                )

    async def login(
        self,
        provider_id: str,
        handlers: Optional[AuthFlowHandlers] = None,
    ) -> None:
        """Run one interactive login flow for ``provider_id``.

        Handler resolution is per-call handlers first, then the client-level
        handlers, then none (spec §3.7). A ``prompt`` event with no
        ``on_prompt`` handler cancels the flow rather than hanging.

        Returns ``None`` on success -- the TypeScript SDK's ``{status:
        "success"}`` carries no additional information.

        Raises:
            asyncio.CancelledError: when the caller cancels the awaiting task.
                This propagates rather than being converted, so a cancelled
                login is indistinguishable from any other cancelled await; the
                SDK still sends ``auth_cancel`` before re-raising.
            MakaiAuthError: ``kind="cancelled"`` when the runtime reports the
                flow as cancelled, or when the SDK cancels it because a prompt
                arrived with no ``on_prompt`` handler;
                ``kind="provider_error"`` when the provider rejected the
                login; ``kind="transport_error"`` on timeouts.
        """
        effective = handlers or self._default_handlers
        flow_id = new_ulid()
        sequence = 1
        last_error: Optional[Dict[str, Optional[str]]] = None
        cancelled_locally = False
        settled = False

        logger.info("auth login provider_id=%s flow_id=%s", provider_id, flow_id)
        context = TimeoutContext(
            "auth_login_result/auth_event",
            self._frame_timeout,
            stream_id=flow_id,
            provider_id=provider_id,
        )

        async with self._transport.route(stream_id=flow_id) as route:
            await self._send(
                build_stream_envelope(
                    "auth_login_start",
                    flow_id,
                    {"provider_id": provider_id},
                    message_id=new_ulid(),
                    sequence=sequence,
                )
            )
            sequence += 1

            try:
                while True:
                    frame = await self._next_frame(route, context)
                    frame_type = frame.get("type")
                    if frame_type == "ack":
                        continue
                    if frame_type == "nack":
                        raise _nack_to_auth_error(frame)

                    if frame_type == "auth_event":
                        event = flatten_auth_event(_require_payload(frame))
                        await self._emit(effective, event)

                        if isinstance(event, AuthErrorEvent):
                            last_error = {"code": event.code, "message": event.message}
                            continue
                        if isinstance(event, AuthPromptEvent):
                            if effective is None or effective.on_prompt is None:
                                cancelled_locally = True
                                await self._cancel(flow_id, sequence)
                                sequence += 1
                                continue
                            answer = await self._ask(effective, event)
                            await self._send(
                                build_stream_envelope(
                                    "auth_prompt_response",
                                    flow_id,
                                    {
                                        "flow_id": flow_id,
                                        "prompt_id": event.prompt_id,
                                        "answer": answer,
                                    },
                                    message_id=new_ulid(),
                                    sequence=sequence,
                                )
                            )
                            sequence += 1
                        continue

                    if frame_type == "auth_login_result":
                        settled = True
                        status = _require_payload(frame).get("status")
                        if status == "success":
                            logger.info("auth login succeeded provider_id=%s", provider_id)
                            return
                        if status == "cancelled":
                            message = (last_error or {}).get("message")
                            if message is None:
                                message = (
                                    "auth login cancelled (no on_prompt handler configured)"
                                    if cancelled_locally
                                    else "auth login cancelled"
                                )
                            raise MakaiAuthError(
                                message, kind="cancelled", code=(last_error or {}).get("code")
                            )
                        if status == "failed":
                            raise MakaiAuthError(
                                (last_error or {}).get("message") or "auth login failed",
                                kind="provider_error",
                                code=(last_error or {}).get("code"),
                            )
                        raise MakaiAuthError(
                            f"unexpected auth_login_result status: {status}", kind="unknown"
                        )

                    raise MakaiAuthError(
                        f"unexpected envelope type during login flow: {frame_type}",
                        kind="transport_error",
                    )
            except BaseException:
                # Also covers asyncio.CancelledError, which is re-raised
                # unchanged: converting it to a normal exception would hide
                # the cancellation from wait_for, task groups, and
                # Task.cancelled(). The flow is still cancelled on the wire.
                if not settled:
                    await self._cancel(flow_id, sequence)
                raise

    async def _ask(self, handlers: AuthFlowHandlers, event: AuthPromptEvent) -> str:
        assert handlers.on_prompt is not None
        try:
            result = handlers.on_prompt(event)
            if inspect.isawaitable(result):
                result = await result
        except (MakaiAuthError, asyncio.CancelledError):
            raise
        except Exception as exc:
            raise MakaiAuthError(str(exc), kind="unknown") from exc
        return result if isinstance(result, str) else ""

    async def _emit(self, handlers: Optional[AuthFlowHandlers], event: AuthEvent) -> None:
        if handlers is None or handlers.on_event is None:
            return
        try:
            result = handlers.on_event(event)
            if inspect.isawaitable(result):
                await result
        except MakaiAuthError:
            raise
        except Exception as exc:
            raise MakaiAuthError(str(exc), kind="unknown") from exc

    async def _cancel(self, flow_id: str, sequence: int) -> None:
        await self._transport.send_best_effort(
            build_stream_envelope(
                "auth_cancel",
                flow_id,
                {"flow_id": flow_id},
                message_id=new_ulid(),
                sequence=sequence,
            )
        )

    async def _send(self, envelope: Mapping[str, Any]) -> None:
        try:
            await self._transport.send(dict(envelope))
        except MakaiStreamError as exc:
            raise MakaiAuthError(str(exc), kind="transport_error") from exc

    async def _next_frame(self, route: Any, context: TimeoutContext) -> Dict[str, Any]:
        try:
            frame: Dict[str, Any] = await route.next_frame(self._frame_timeout)
        except MakaiStreamError as exc:
            if is_timeout_error(exc):
                raise MakaiAuthError(
                    format_timeout_message(context),
                    kind="transport_error",
                    code=TIMEOUT_CODE,
                    diagnostics=build_diagnostics(context),
                ) from exc
            raise MakaiAuthError(exc.message, kind="transport_error", code=exc.code) from exc
        return frame


def flatten_auth_event(payload: Mapping[str, Any]) -> AuthEvent:
    """Convert an ``auth_event`` payload into a typed event.

    The wire shape nests the event under its variant key, for example
    ``{"prompt": {...}}``.
    """
    for variant in _EVENT_VARIANTS:
        value = payload.get(variant)
        if isinstance(value, dict):
            return _normalize(variant, value)
    raise MakaiAuthError(f"unknown auth_event variant: {dict(payload)!r}", kind="unknown")


def _normalize(variant: str, data: Mapping[str, Any]) -> AuthEvent:
    flow_id = _string_field(data, "flow_id")
    provider_id = _string_field(data, "provider_id")
    if variant == "auth_url":
        return AuthUrlEvent(
            flow_id=flow_id,
            provider_id=provider_id,
            url=_string_field(data, "url"),
            instructions=_optional_string_field(data, "instructions"),
        )
    if variant == "prompt":
        allow_empty = data.get("allow_empty")
        return AuthPromptEvent(
            flow_id=flow_id,
            prompt_id=_string_field(data, "prompt_id"),
            provider_id=provider_id,
            message=_string_field(data, "message"),
            allow_empty=allow_empty if isinstance(allow_empty, bool) else False,
        )
    if variant == "progress":
        return AuthProgressEvent(
            flow_id=flow_id, provider_id=provider_id, message=_string_field(data, "message")
        )
    if variant == "success":
        return AuthSuccessEvent(flow_id=flow_id, provider_id=provider_id)
    return AuthErrorEvent(
        flow_id=flow_id,
        provider_id=provider_id,
        message=_string_field(data, "message"),
        code=_optional_string_field(data, "code"),
    )


def _string_field(data: Mapping[str, Any], key: str) -> str:
    value = data.get(key)
    if not isinstance(value, str):
        raise MakaiAuthError(
            f'auth_event field "{key}" missing or not a string', kind="transport_error"
        )
    return value


def _optional_string_field(data: Mapping[str, Any], key: str) -> Optional[str]:
    value = data.get(key)
    if isinstance(value, str) and value:
        return value
    return None


def _require_payload(frame: Mapping[str, Any]) -> Dict[str, Any]:
    payload = frame.get("payload")
    if not isinstance(payload, dict):
        raise MakaiAuthError(
            f"envelope {frame.get('type')} missing payload object", kind="transport_error"
        )
    return payload


def _parse_providers(frame: Mapping[str, Any]) -> List[ProviderAuthInfo]:
    payload = _require_payload(frame)
    providers = payload.get("providers")
    if not isinstance(providers, list):
        raise MakaiAuthError(
            "auth_providers_response payload missing providers array", kind="transport_error"
        )
    return [_parse_provider(entry, index) for index, entry in enumerate(providers)]


def _parse_provider(entry: Any, index: int) -> ProviderAuthInfo:
    if not isinstance(entry, dict):
        raise MakaiAuthError(
            f"provider entry at index {index} is not an object", kind="transport_error"
        )
    identifier = entry.get("id")
    name = entry.get("name")
    if not isinstance(identifier, str) or not isinstance(name, str):
        raise MakaiAuthError(
            f"provider entry at index {index} missing id/name", kind="transport_error"
        )
    status = entry.get("auth_status")
    auth_status: AuthStatus = (
        cast(AuthStatus, status)
        if isinstance(status, str) and status in _VALID_AUTH_STATUSES
        else "unknown"
    )
    last_error = entry.get("last_error")
    return ProviderAuthInfo(
        id=identifier,
        name=name,
        auth_status=auth_status,
        last_error=last_error if isinstance(last_error, str) and last_error else None,
    )


def _nack_to_auth_error(frame: Mapping[str, Any]) -> MakaiAuthError:
    payload = payload_of(frame)
    reason = payload.get("reason")
    code = payload.get("error_code")
    return MakaiAuthError(
        reason if isinstance(reason, str) else "transport nack",
        kind="transport_error",
        code=code if isinstance(code, str) else None,
    )
