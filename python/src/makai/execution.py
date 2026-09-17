"""The ``provider`` and ``agent`` namespaces.

``provider`` is the direct path: one ``stream_id``-scoped request
(``complete_request`` / ``stream_request``) and its events.

``agent`` runs the runtime's agent loop over a ``session_id``-scoped session:
``agent_start`` (sequence 1) -> ``agent_started`` -> ``agent_message``
(sequence 2) -> run output -> ``agent_stop`` (sequence 3). When the loop wants
a tool, the runtime publishes ``tool_execute`` and the SDK runs the matching
:class:`~makai.types.ToolDefinition.execute` callback **in your process**,
replying with a correlated ``tool_result``.

Sequencing is per session and starts at 1 (spec §13.1). ``session_id`` is a
correlation key only: sessions are not resumable and this module implements no
resume path.
"""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import json
import logging
from typing import Any, AsyncGenerator, Dict, List, Mapping, Optional, Sequence, Tuple

from ._diagnostics import TimeoutContext, build_diagnostics, format_timeout_message
from ._ids import is_nano_id, new_nano_id, new_ulid
from ._model_ref import ModelRefParseError, parse_model_ref
from ._normalize import (
    ToolBuffers,
    add_usage,
    build_response_from_events,
    error_frame_to_stream_error,
    is_auth_failure_message,
    is_known_agent_frame_type,
    nack_to_stream_error,
    normalize_agent_frame,
    normalize_provider_frame,
    parse_agent_run_response,
    parse_completion_response,
)
from ._wire import build_reply_envelope, build_session_envelope, build_stream_envelope, json_payload_field, payload_of
from .auth import AuthApi
from .errors import (
    MakaiAuthError,
    MakaiAuthRequiredError,
    MakaiProtocolError,
    MakaiStreamError,
    TIMEOUT_CODE,
    is_timeout_error,
)
from .models import ModelsApi
from .transport import FrameRoute, StdioTransport
from .types import (
    AgentEnd,
    AgentStart,
    AgentStreamEvent,
    ChatMessage,
    CompletionResponse,
    Content,
    ContentPart,
    MessageEnd,
    ProviderStreamEvent,
    RunOptions,
    StreamError,
    ToolContext,
    ToolDefinition,
    ToolExecutionEnd,
    ToolExecutionStart,
    Usage,
)

__all__ = ["ProviderApi", "AgentApi"]

logger = logging.getLogger("makai.execution")

DEFAULT_RESPONSE_TIMEOUT_S = 30.0
MAX_MODEL_REF_LENGTH = 4096
MAX_IDENTIFIER_LENGTH = 256
MAX_MODEL_FIELD_LENGTH = 512

_AGENT_START_SEQUENCE = 1
_AGENT_MESSAGE_SEQUENCE = 2
_AGENT_STOP_SEQUENCE = 3


class _ExecutionBase:
    def __init__(
        self,
        transport: StdioTransport,
        *,
        response_timeout: float = DEFAULT_RESPONSE_TIMEOUT_S,
        auth_retry_policy: Optional[str] = None,
        auth: Optional[AuthApi] = None,
    ) -> None:
        self._transport = transport
        self._response_timeout = response_timeout
        self._auth_retry_policy = auth_retry_policy
        self._auth = auth

    def _policy(self, options: Optional[RunOptions]) -> Optional[str]:
        if options is not None and options.auth_retry_policy is not None:
            return options.auth_retry_policy
        return self._auth_retry_policy

    async def _relogin(self, provider_id: str, original: MakaiStreamError) -> None:
        """Run one login for ``provider_id``; raise the typed auth error on failure."""
        assert self._auth is not None
        logger.info("auto_once: retrying after auth_required provider_id=%s", provider_id)
        try:
            await self._auth.login(provider_id)
        except MakaiAuthError as exc:
            raise MakaiAuthRequiredError(provider_id, original.message) from exc


class ProviderApi(_ExecutionBase):
    """Direct provider completions and streaming."""

    async def complete(
        self,
        *,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]] = None,
        options: Optional[RunOptions] = None,
    ) -> CompletionResponse:
        """Run one non-streaming completion.

        Raises:
            MakaiAuthRequiredError: the provider needs a login and the retry
                policy did not resolve it.
            MakaiStreamError: any other provider, protocol, or transport
                failure.
        """
        policy = self._policy(options)
        fallback_provider_id = _provider_id_from_ref(model_ref)
        try:
            return await self._complete_once(model_ref, messages, tools, options, policy)
        except MakaiStreamError as exc:
            provider_id = _retryable_auth_provider(exc, fallback_provider_id)
            if provider_id is None:
                raise
            if policy != "auto_once" or self._auth is None:
                raise MakaiAuthRequiredError(provider_id, exc.message) from exc
            await self._relogin(provider_id, exc)
            try:
                return await self._complete_once(model_ref, messages, tools, options, policy)
            except MakaiStreamError as retry_exc:
                retry_provider = _retryable_auth_provider(retry_exc, fallback_provider_id)
                if retry_provider is not None:
                    raise MakaiAuthRequiredError(retry_provider, retry_exc.message) from retry_exc
                raise

    async def _complete_once(
        self,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]],
        options: Optional[RunOptions],
        policy: Optional[str],
    ) -> CompletionResponse:
        stream_id = new_ulid()
        payload = _build_execution_payload(model_ref, messages, tools, options, policy)
        context = _stream_timeout_context(
            "provider complete_response", self._response_timeout, stream_id, model_ref
        )
        fallback_provider_id = _provider_id_from_ref(model_ref)

        async with self._transport.route(stream_id=stream_id) as route:
            # The send is inside the handler: it can suspend in drain() with
            # the request bytes already queued, and cancelling there would
            # otherwise close the route without an abort and leave a billable
            # completion running in the child.
            try:
                await self._transport.send(
                    build_stream_envelope("complete_request", stream_id, payload)
                )
                while True:
                    frame = await _next(route, self._response_timeout, context)
                    frame_type = frame.get("type")
                    if frame_type == "ack":
                        continue
                    if frame_type == "nack":
                        raise nack_to_stream_error(frame, fallback_provider_id)
                    if frame_type == "stream_error":
                        raise error_frame_to_stream_error(frame)
                    if frame_type in ("result", "complete_response"):
                        return _response_or_auth_error(
                            parse_completion_response(payload_of(frame)),
                            fallback_provider_id,
                            allow_retry=True,
                        )
                    raise MakaiStreamError(
                        f"unexpected frame type while awaiting provider result: {frame_type}",
                        kind="transport_error",
                    )
            except asyncio.CancelledError:
                await _abort_stream(self._transport, stream_id)
                await route.drain()
                raise

    async def stream(
        self,
        *,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]] = None,
        options: Optional[RunOptions] = None,
    ) -> AsyncGenerator[ProviderStreamEvent, None]:
        """Stream one completion.

        Yields :class:`~makai.types.ProviderStreamEvent` values and ends after
        exactly one terminal event (``message_end`` or ``error``, spec §3.5).
        Breaking out of the loop or cancelling the task sends an
        ``abort_request`` for the stream.
        """
        policy = self._policy(options)
        fallback_provider_id = _provider_id_from_ref(model_ref)
        attempt = 0
        while True:
            yielded = False
            try:
                inner = self._stream_once(model_ref, messages, tools, options, policy)
                async with contextlib.aclosing(inner):
                    async for event in inner:
                        yielded = True
                        yield event
                return
            except MakaiStreamError as exc:
                provider_id = _retryable_auth_provider(exc, fallback_provider_id)
                if provider_id is None:
                    raise
                if yielded or attempt > 0 or policy != "auto_once" or self._auth is None:
                    raise MakaiAuthRequiredError(provider_id, exc.message) from exc
                await self._relogin(provider_id, exc)
                attempt += 1

    async def _stream_once(
        self,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]],
        options: Optional[RunOptions],
        policy: Optional[str],
    ) -> AsyncGenerator[ProviderStreamEvent, None]:
        stream_id = new_ulid()
        payload = _build_execution_payload(
            model_ref, messages, tools, options, policy, suppress_partial=True
        )
        context = _stream_timeout_context(
            "provider stream event", self._response_timeout, stream_id, model_ref
        )
        fallback_provider_id = _provider_id_from_ref(model_ref)
        buffers: ToolBuffers = {}
        terminal = False

        async with self._transport.route(stream_id=stream_id) as route:
            try:
                await self._transport.send(
                    build_stream_envelope("stream_request", stream_id, payload)
                )
                while not terminal:
                    frame = await _next(route, self._response_timeout, context)
                    frame_type = frame.get("type")
                    if frame_type == "ack":
                        continue
                    if frame_type == "nack":
                        raise nack_to_stream_error(frame, fallback_provider_id)
                    event = normalize_provider_frame(frame, buffers)
                    if event is None:
                        continue
                    if isinstance(event, StreamError):
                        terminal = True
                        if event.code == "auth_required":
                            raise MakaiStreamError(
                                event.message,
                                kind="provider_error",
                                code=event.code,
                                provider_id=event.provider_id,
                            )
                        yield event
                        continue
                    if isinstance(event, MessageEnd):
                        terminal = True
                    yield event
            except (asyncio.CancelledError, GeneratorExit):
                await _abort_stream(self._transport, stream_id)
                raise


class AgentApi(_ExecutionBase):
    """The runtime's agent loop, with tools executed in client code."""

    def __init__(
        self,
        transport: StdioTransport,
        *,
        response_timeout: float = DEFAULT_RESPONSE_TIMEOUT_S,
        auth_retry_policy: Optional[str] = None,
        auth: Optional[AuthApi] = None,
        models: ModelsApi,
    ) -> None:
        super().__init__(
            transport,
            response_timeout=response_timeout,
            auth_retry_policy=auth_retry_policy,
            auth=auth,
        )
        self.models = models
        """A models namespace sharing this transport.

        Convenience for chaining discovery with an agent call. It is a
        separate instance from ``client.models``, not the same object.
        """

    async def run(
        self,
        *,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]] = None,
        options: Optional[RunOptions] = None,
    ) -> CompletionResponse:
        """Run the agent loop to completion and return the final message."""
        policy = self._policy(options)
        fallback_provider_id = _provider_id_from_ref(model_ref)
        progress: Dict[str, bool] = {"tools_executed": False}
        try:
            return await self._run_once(model_ref, messages, tools, options, policy, progress)
        except MakaiStreamError as exc:
            provider_id = _retryable_auth_provider(exc, fallback_provider_id)
            if provider_id is None:
                raise
            if policy != "auto_once" or self._auth is None or progress["tools_executed"]:
                raise MakaiAuthRequiredError(provider_id, exc.message) from exc
            await self._relogin(provider_id, exc)
            retry_options = _with_fresh_session_id(options)
            try:
                return await self._run_once(
                    model_ref, messages, tools, retry_options, policy, progress
                )
            except MakaiStreamError as retry_exc:
                retry_provider = _retryable_auth_provider(retry_exc, fallback_provider_id)
                if retry_provider is not None:
                    raise MakaiAuthRequiredError(retry_provider, retry_exc.message) from retry_exc
                raise

    async def _run_once(
        self,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]],
        options: Optional[RunOptions],
        policy: Optional[str],
        progress: Optional[Dict[str, bool]] = None,
    ) -> CompletionResponse:
        events: List[AgentStreamEvent] = []
        response: Optional[CompletionResponse] = None
        tools_executed = False

        def mark_tools_executed() -> None:
            nonlocal tools_executed
            tools_executed = True
            if progress is not None:
                progress["tools_executed"] = True

        session = self._session(model_ref, messages, tools, options, policy)
        async with contextlib.aclosing(session):
            async for kind, value in session:
                if kind == "tool_executed":
                    mark_tools_executed()
                    continue
                if kind == "response":
                    response = value
                    break
                if isinstance(value, (ToolExecutionStart, ToolExecutionEnd)):
                    mark_tools_executed()
                events.append(value)
                if isinstance(value, AgentEnd):
                    response = build_response_from_events(events)
                    break
                if isinstance(value, StreamError):
                    raise MakaiStreamError(
                        value.message,
                        kind="provider_error",
                        code=value.code,
                        provider_id=value.provider_id,
                    )

        if response is None:
            raise MakaiStreamError(
                "agent run ended without a terminal result", kind="transport_error"
            )
        return _response_or_auth_error(
            response, _provider_id_from_ref(model_ref), allow_retry=not tools_executed
        )

    async def stream(
        self,
        *,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]] = None,
        options: Optional[RunOptions] = None,
    ) -> AsyncGenerator[AgentStreamEvent, None]:
        """Stream the agent loop's lifecycle and provider events.

        The stream ends after ``agent_end`` or a terminal ``error`` event.
        ``agent_end`` carries aggregate usage summed over the run's provider
        turns.
        """
        policy = self._policy(options)
        fallback_provider_id = _provider_id_from_ref(model_ref)
        attempt = 0
        effective_options = options
        while True:
            yielded_content = False
            progress: Dict[str, bool] = {"tools_executed": False}
            try:
                inner = self._stream_once(
                    model_ref, messages, tools, effective_options, policy, progress
                )
                async with contextlib.aclosing(inner):
                    async for event in inner:
                        if not _is_replayable(event):
                            yielded_content = True
                        yield event
                return
            except MakaiStreamError as exc:
                provider_id = _retryable_auth_provider(exc, fallback_provider_id)
                if provider_id is None:
                    raise
                if (
                    yielded_content
                    or progress["tools_executed"]
                    or attempt > 0
                    or policy != "auto_once"
                    or self._auth is None
                ):
                    raise MakaiAuthRequiredError(provider_id, exc.message) from exc
                await self._relogin(provider_id, exc)
                effective_options = _with_fresh_session_id(effective_options)
                attempt += 1

    async def _stream_once(
        self,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]],
        options: Optional[RunOptions],
        policy: Optional[str],
        progress: Optional[Dict[str, bool]] = None,
    ) -> AsyncGenerator[AgentStreamEvent, None]:
        started = False
        aggregate: Optional[Usage] = None
        session_id = _agent_session_id(options)
        fallback_provider_id = _provider_id_from_ref(model_ref)

        session = self._session(
            model_ref, messages, tools, options, policy, session_id=session_id
        )
        async with contextlib.aclosing(session):
            async for kind, value in session:
                if kind == "tool_executed":
                    if progress is not None:
                        progress["tools_executed"] = True
                    continue
                if kind == "response":
                    # agent.run's non-streaming settlement shape; project it as
                    # a terminal agent_end so streaming consumers still see one.
                    response: CompletionResponse = value
                    if not started:
                        started = True
                        yield AgentStart(session_id=session_id)
                    settled = AgentEnd(
                        usage=aggregate or response.usage,
                        stop_reason=response.stop_reason,
                        error_message=response.error_message,
                        provider_id=response.provider_id or None,
                        api=response.api or None,
                    )
                    # The host settles a provider auth failure through
                    # agent_result too, so this path needs the same check the
                    # agent_end branch applies; without it the stream yields a
                    # normal-looking terminal and auto_once never retries.
                    if settled.stop_reason == "error" and is_auth_failure_message(
                        settled.error_message, api=settled.api
                    ):
                        raise MakaiStreamError(
                            settled.error_message or "auth_required",
                            kind="provider_error",
                            code="auth_required",
                            provider_id=settled.provider_id or fallback_provider_id,
                        )
                    yield settled
                    return

                event: AgentStreamEvent = value
                if not started:
                    started = True
                    if not isinstance(event, AgentStart):
                        yield AgentStart(session_id=session_id)
                if isinstance(event, MessageEnd) and event.usage is not None:
                    aggregate = add_usage(aggregate, event.usage) if aggregate else event.usage
                if isinstance(event, AgentEnd):
                    final = AgentEnd(
                        usage=aggregate or event.usage,
                        stop_reason=event.stop_reason,
                        error_message=event.error_message,
                        provider_id=event.provider_id,
                        api=event.api,
                    )
                    if final.stop_reason == "error" and is_auth_failure_message(
                        final.error_message, api=final.api
                    ):
                        raise MakaiStreamError(
                            final.error_message or "auth_required",
                            kind="provider_error",
                            code="auth_required",
                            provider_id=final.provider_id or fallback_provider_id,
                        )
                    yield final
                    return
                if isinstance(event, StreamError):
                    if event.code == "auth_required":
                        raise MakaiStreamError(
                            event.message,
                            kind="provider_error",
                            code=event.code,
                            provider_id=event.provider_id or fallback_provider_id,
                        )
                    yield event
                    return
                yield event

    async def _session(
        self,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]],
        options: Optional[RunOptions],
        policy: Optional[str],
        *,
        session_id: Optional[str] = None,
    ) -> AsyncGenerator[Tuple[str, Any], None]:
        """Drive one agent session, yielding ``("event", e)`` / ``("response", r)``.

        Handles the ``agent_start`` -> ``agent_started`` -> ``agent_message``
        handshake, dispatches ``tool_execute`` to client tools, and always
        sends ``agent_stop`` on the way out.
        """
        _validate_execution_request(model_ref, messages)
        session_id = session_id or _agent_session_id(options)
        fallback_provider_id = _provider_id_from_ref(model_ref)
        context = _session_timeout_context(
            "agent result", self._response_timeout, session_id, model_ref
        )
        buffers: ToolBuffers = {}
        tool_map = {tool.name: tool for tool in (tools or [])}
        start_accepted = False
        message_sent = False
        message_message_id: Optional[str] = None
        message_accepted = False
        stop_sent = False
        start_rejected = False
        # An id the SDK minted is exclusively ours, so a lost or delayed start
        # reply still leaves it safe to tear down. A caller-supplied id may
        # belong to someone else's live run (spec 6.1).
        exclusive_session = options is None or options.session_id is None

        async with self._transport.route(session_id=session_id) as route:
            start_envelope = build_session_envelope(
                "agent_start",
                session_id,
                _AGENT_START_SEQUENCE,
                _build_agent_start_payload(model_ref, tools, session_id),
            )
            start_message_id = start_envelope["message_id"]

            # The send is inside the handler for the same reason
            # _complete_once does it: it can suspend on the write lock or in
            # drain() with the start frame already queued to the child, and a
            # cancellation there would otherwise skip the finally and leave a
            # session the host holds until idle-TTL eviction. The
            # exclusive-session guard below keeps the stop ownership-safe when
            # the send never reached the child at all.
            try:
                await self._transport.send(start_envelope)
                while True:
                    frame = await _next(route, self._response_timeout, context)
                    frame_type = frame.get("type")
                    in_reply_to = frame.get("in_reply_to")

                    if frame_type in ("ack", "agent_stopped"):
                        if frame_type == "ack" and in_reply_to == message_message_id:
                            message_accepted = True
                        continue

                    if frame_type == "nack":
                        if not start_accepted and in_reply_to not in (None, start_message_id):
                            continue
                        start_rejected = not start_accepted
                        raise nack_to_stream_error(frame, fallback_provider_id)

                    if frame_type == "agent_error":
                        if not start_accepted and in_reply_to not in (None, start_message_id):
                            continue
                        start_rejected = not start_accepted
                        raise error_frame_to_stream_error(frame)

                    if frame_type == "agent_started":
                        if in_reply_to not in (None, start_message_id):
                            continue
                        start_accepted = True
                        if not message_sent:
                            message_envelope = build_session_envelope(
                                "agent_message",
                                session_id,
                                _AGENT_MESSAGE_SEQUENCE,
                                _build_agent_message_payload(
                                    model_ref, messages, tools, options, policy, session_id
                                ),
                            )
                            message_message_id = message_envelope["message_id"]
                            await self._transport.send(message_envelope)
                            message_sent = True
                        continue

                    if not start_accepted:
                        # Nothing but a reply to agent_start is meaningful yet.
                        continue

                    # Any run output means the host processed agent_message and
                    # advanced its inbound counter past it.
                    if message_sent:
                        message_accepted = True

                    if frame_type == "tool_execute":
                        await self._transport.send(
                            await _execute_tool_frame(frame, tool_map)
                        )
                        # Reported separately from the lifecycle events,
                        # because a runtime may execute a tool without
                        # delivering tool_execution_start/end -- and an
                        # auth retry after a side effect would repeat it.
                        yield ("tool_executed", None)
                        continue

                    if frame_type == "agent_result":
                        yield ("response", parse_agent_run_response(
                            json_payload_field(frame, "result_json")
                        ))
                        return
                    if frame_type in ("result", "complete_response"):
                        yield ("response", parse_completion_response(payload_of(frame)))
                        return

                    if not is_known_agent_frame_type(frame_type):
                        raise MakaiStreamError(
                            "unexpected frame type while awaiting agent result: "
                            f"{frame_type}",
                            kind="transport_error",
                        )
                    # An understood frame may still carry nothing to emit
                    # (buffered tool-call deltas, deferred V1 events).
                    events = normalize_agent_frame(frame, buffers)
                    for event in events:
                        yield ("event", event)
                        if isinstance(event, (AgentEnd, StreamError)):
                            return
            finally:
                # A rejected agent_start means this session was never ours --
                # `agent_busy` in particular says someone else holds the id.
                # Neither is a caller-supplied id whose start reply never
                # arrived: the run behind it may be someone else's, and a stop
                # that happens to carry their next expected sequence would
                # tear it down.
                if not stop_sent and not start_rejected and (start_accepted or exclusive_session):
                    stop_sent = True
                    # The host validates agent_stop against the session's next
                    # expected inbound sequence, and only advances it for a
                    # frame it accepted. A stop that never sent agent_message,
                    # or whose agent_message was rejected, must reuse 2.
                    stop_sequence = (
                        _AGENT_STOP_SEQUENCE
                        if message_accepted
                        else _AGENT_MESSAGE_SEQUENCE
                    )
                    with contextlib.suppress(Exception):
                        await _stop_agent_with_sequence_probe(
                            self._transport, route, session_id, stop_sequence
                        )


_STOP_PROBE_IDLE_S = 0.05
_STOP_PROBE_BUDGET_S = 0.25


def _correlated_rejection_code(frame: Mapping[str, Any]) -> Optional[str]:
    if frame.get("type") not in ("agent_error", "nack"):
        return None
    payload = payload_of(frame)
    code = payload.get("code") or payload.get("error_code")
    if not isinstance(code, str):
        return None
    return "invalid_request" if code == "invalid_sequence" else code


async def _stop_agent_with_sequence_probe(
    transport: StdioTransport,
    route: FrameRoute,
    session_id: str,
    preferred: int,
) -> None:
    """Send ``agent_stop``, retrying once with the other plausible sequence.

    The host validates the stop against the session's next expected inbound
    value and rejects a mismatch, leaving the session registered until the
    idle sweep. Acceptance of ``agent_message`` is inferred, not guaranteed --
    the message can be lost in flight -- so a rejection is answered by trying
    the other candidate, as the TypeScript SDK does (spec 13.4.1).
    """
    alternate = (
        _AGENT_MESSAGE_SEQUENCE if preferred == _AGENT_STOP_SEQUENCE else _AGENT_STOP_SEQUENCE
    )
    try:
        await _probe_stop_sequences(transport, route, session_id, (preferred, alternate))
    finally:
        await route.drain()


async def _probe_stop_sequences(
    transport: StdioTransport,
    route: FrameRoute,
    session_id: str,
    candidates: Tuple[int, int],
) -> None:
    for attempt, sequence in enumerate(candidates):
        envelope = build_session_envelope(
            "agent_stop", session_id, sequence, {"session_id": session_id, "reason": "completed"}
        )
        await transport.send_best_effort(envelope)

        loop = asyncio.get_running_loop()
        deadline = loop.time() + _STOP_PROBE_BUDGET_S
        rejected = False
        while loop.time() < deadline:
            remaining = min(_STOP_PROBE_IDLE_S, deadline - loop.time())
            if remaining <= 0:
                break
            try:
                frame = await route.next_frame(remaining)
            except MakaiStreamError as exc:
                if not is_timeout_error(exc):
                    # The route is failed, and next_frame re-arms that failure,
                    # so retrying would busy-spin until the budget expires
                    # without ever suspending. Nothing can answer the probe.
                    return
                # A quiet slice, not a failure: the deadline ends the wait.
                continue
            except Exception:
                break
            if frame.get("in_reply_to") != envelope["message_id"]:
                continue
            if frame.get("type") == "agent_stopped":
                return
            if _correlated_rejection_code(frame) == "invalid_request":
                rejected = True
            break
        if not rejected or attempt == 1:
            return


async def _next(route: FrameRoute, timeout: float, context: TimeoutContext) -> Dict[str, Any]:
    try:
        return await route.next_frame(timeout)
    except MakaiStreamError as exc:
        if is_timeout_error(exc):
            raise MakaiStreamError(
                format_timeout_message(context),
                kind="transport_error",
                code=TIMEOUT_CODE,
                diagnostics=build_diagnostics(context),
            ) from exc
        raise


async def _abort_stream(transport: StdioTransport, stream_id: str) -> None:
    await transport.send_best_effort(
        build_stream_envelope(
            "abort_request",
            stream_id,
            {"target_stream_id": stream_id, "reason": "client aborted"},
            message_id=new_ulid(),
            sequence=2,
        )
    )


async def _execute_tool_frame(
    frame: Mapping[str, Any], tools: Mapping[str, ToolDefinition]
) -> Dict[str, Any]:
    """Run a client-side tool for a ``tool_execute`` frame and build the reply."""
    payload = payload_of(frame)
    tool_call_id = payload.get("tool_call_id")
    tool_call_id = tool_call_id if isinstance(tool_call_id, str) else ""
    tool_name = payload.get("tool_name")
    tool_name = tool_name if isinstance(tool_name, str) else ""
    args_json = payload.get("args_json")
    args_json = args_json if isinstance(args_json, str) else ""

    tool = tools.get(tool_name)
    if tool is None or tool.execute is None:
        return _tool_result_envelope(
            frame, tool_call_id, f"Tool '{tool_name}' is not executable by this client", True
        )

    try:
        args = _parse_tool_arguments(args_json)
        result = tool.execute(args, ToolContext(tool_call_id, tool_name, args_json))
        if inspect.isawaitable(result):
            result = await result
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        logger.debug("tool %s raised: %r", tool_name, exc)
        return _tool_result_envelope(frame, tool_call_id, str(exc), True)
    return _tool_result_envelope(frame, tool_call_id, result, False)


def _parse_tool_arguments(args_json: str) -> Dict[str, Any]:
    parsed = json.loads(args_json) if args_json else {}
    if not isinstance(parsed, dict):
        raise ValueError("tool arguments must be a JSON object")
    return parsed


def _tool_result_envelope(
    frame: Mapping[str, Any], tool_call_id: str, result: Any, is_error: bool
) -> Dict[str, Any]:
    return build_reply_envelope(
        "tool_result",
        frame,
        {
            "tool_call_id": tool_call_id,
            "result_json": _serialize_tool_result(result),
            "is_error": is_error,
        },
    )


def _serialize_tool_result(result: Any) -> str:
    if isinstance(result, str):
        return json.dumps([{"type": "text", "text": result}], separators=(",", ":"))
    if isinstance(result, list):
        return json.dumps(result, separators=(",", ":"))
    return json.dumps([{"type": "text", "text": str(result)}], separators=(",", ":"))


def _validate_execution_request(model_ref: str, messages: Sequence[ChatMessage]) -> None:
    if not isinstance(model_ref, str) or not model_ref:
        raise TypeError("request requires opaque model_ref")
    if len(model_ref) > MAX_MODEL_REF_LENGTH:
        raise MakaiProtocolError(
            f"model_ref exceeds maximum length of {MAX_MODEL_REF_LENGTH} characters",
            "invalid_request",
        )
    _validate_model_ref_segments(model_ref)
    if isinstance(messages, (str, bytes)) or not isinstance(messages, Sequence):
        raise TypeError("request requires a sequence of messages")


def _validate_model_ref_segments(model_ref: str) -> None:
    parsed = _split_model_ref(model_ref)
    if parsed is not None:
        provider_id, api, model_id = parsed
        _validate_model_segments(provider_id, api, model_id)
        return
    if len(model_ref) > MAX_MODEL_FIELD_LENGTH:
        raise MakaiProtocolError(
            f"model_ref exceeds maximum length of {MAX_MODEL_FIELD_LENGTH} characters "
            "for opaque refs",
            "invalid_request",
        )


def _validate_model_segments(provider_id: str, api: str, model_id: str) -> None:
    if len(provider_id) > MAX_IDENTIFIER_LENGTH:
        raise MakaiProtocolError(
            f"model_ref provider segment exceeds maximum length of {MAX_IDENTIFIER_LENGTH} "
            "characters",
            "invalid_request",
        )
    if len(api) > MAX_IDENTIFIER_LENGTH:
        raise MakaiProtocolError(
            f"model_ref api segment exceeds maximum length of {MAX_IDENTIFIER_LENGTH} characters",
            "invalid_request",
        )
    if len(model_id) > MAX_MODEL_FIELD_LENGTH:
        raise MakaiProtocolError(
            f"model_ref model_id segment exceeds maximum length of {MAX_MODEL_FIELD_LENGTH} "
            "characters",
            "invalid_request",
        )


def _split_model_ref(model_ref: str) -> Optional[Tuple[str, str, str]]:
    """Return ``(provider_id, api, model_id)``, or ``None`` for an opaque ref.

    Canonical parsing first, then the loose ``a/b@c`` split the TypeScript SDK
    falls back to, so a ref the server emits in a slightly different shape
    still produces a usable ``model`` payload.
    """
    try:
        parsed = parse_model_ref(model_ref)
        return (parsed.provider_id, parsed.api, parsed.model_id)
    except ModelRefParseError:
        pass
    slash_index = model_ref.find("/")
    at_index = model_ref.find("@")
    if slash_index != -1 and at_index != -1 and slash_index < at_index:
        provider_id = model_ref[:slash_index]
        api = model_ref[slash_index + 1 : at_index]
        model_id = model_ref[at_index + 1 :]
        if provider_id and api:
            return (provider_id, api, model_id)
    return None


def _model_from_ref(model_ref: str) -> Dict[str, Any]:
    """Build the provider protocol's ``model`` object from a ``model_ref``.

    The provider protocol carries a resolved ``ai_types.Model``, not a ref, so
    the SDK has to reconstruct one. See :mod:`makai._model_ref`: application
    code must still treat ``model_ref`` as opaque.
    """
    parsed = _split_model_ref(model_ref)
    if parsed is None:
        return {"id": model_ref, "name": model_ref, "api": "", "provider": "", "base_url": ""}
    provider_id, api, model_id = parsed
    _validate_model_segments(provider_id, api, model_id)
    return {
        "id": model_id,
        "name": model_id,
        "api": api,
        "provider": provider_id,
        "base_url": "",
    }


def _provider_id_from_ref(model_ref: str) -> Optional[str]:
    parsed = _split_model_ref(model_ref)
    return parsed[0] if parsed is not None else None


def _serialize_options(options: Optional[RunOptions], policy: Optional[str]) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    if policy is not None:
        out["auth_retry_policy"] = policy
    if options is None:
        return out
    for key in (
        "temperature",
        "max_tokens",
        "reasoning_effort",
        "auth_retry_policy",
        "session_id",
        "metadata",
    ):
        value = getattr(options, key)
        if value is not None:
            out[key] = dict(value) if key == "metadata" else value
    return out


def _build_execution_payload(
    model_ref: str,
    messages: Sequence[ChatMessage],
    tools: Optional[Sequence[ToolDefinition]],
    options: Optional[RunOptions],
    policy: Optional[str],
    *,
    suppress_partial: bool = False,
) -> Dict[str, Any]:
    _validate_execution_request(model_ref, messages)
    payload: Dict[str, Any] = {
        "model": _model_from_ref(model_ref),
        "context": _execution_context(messages, tools),
        "model_ref": model_ref,
    }
    serialized = _serialize_options(options, policy)
    if serialized:
        payload["options"] = serialized
    if suppress_partial:
        payload["include_partial"] = False
    return payload


def _build_agent_start_payload(
    model_ref: str, tools: Optional[Sequence[ToolDefinition]], session_id: str
) -> Dict[str, Any]:
    config = {"model_ref": model_ref, "tools": [_serialize_tool(t) for t in (tools or [])]}
    return {
        "session_id": session_id,
        # Permanent legacy alias carrying the same value (spec §13.1): a
        # pre-#198 server only understands this key, and would otherwise mint
        # its own id and reject every later frame in the session.
        "resume_session_id": session_id,
        "config_json": json.dumps(config, separators=(",", ":")),
    }


def _build_agent_message_payload(
    model_ref: str,
    messages: Sequence[ChatMessage],
    tools: Optional[Sequence[ToolDefinition]],
    options: Optional[RunOptions],
    policy: Optional[str],
    session_id: str,
) -> Dict[str, Any]:
    message = {
        "model_ref": model_ref,
        "messages": [_serialize_message(m) for m in messages],
        "tools": [_serialize_tool(t) for t in (tools or [])],
    }
    payload: Dict[str, Any] = {
        "session_id": session_id,
        "message_json": json.dumps(message, separators=(",", ":")),
    }
    serialized = _serialize_options(options, policy)
    if serialized:
        payload["options_json"] = json.dumps(serialized, separators=(",", ":"))
    return payload


def _execution_context(
    messages: Sequence[ChatMessage], tools: Optional[Sequence[ToolDefinition]]
) -> Dict[str, Any]:
    wire_messages: List[Dict[str, Any]] = []
    system_prompts: List[str] = []
    for message in messages:
        if message.get("role") in ("system", "developer"):
            system_prompts.append(_content_as_prompt_text(message.get("content", "")))
        else:
            wire_messages.append(_serialize_message(message))
    context: Dict[str, Any] = {"messages": wire_messages}
    if system_prompts:
        context["system_prompt"] = "\n\n".join(system_prompts)
    if tools is not None:
        context["tools"] = [_serialize_tool(tool) for tool in tools]
    return context


def _serialize_message(message: ChatMessage) -> Dict[str, Any]:
    role = message.get("role")
    content: Any = message.get("content", "")
    if role == "tool":
        content = _content_as_parts(content)
    out: Dict[str, Any] = {"role": role, "content": content}
    name = message.get("name")
    if name:
        out["name"] = name
    if role == "tool":
        out["tool_name"] = name or ""
    tool_call_id = message.get("tool_call_id")
    if tool_call_id:
        out["tool_call_id"] = tool_call_id
    return out


def _serialize_tool(tool: ToolDefinition) -> Dict[str, Any]:
    return {
        "name": tool.name,
        "description": tool.description,
        "parameters_schema_json": tool.parameters_schema_json,
    }


def _content_as_prompt_text(content: Content) -> str:
    if isinstance(content, str):
        return content
    lines = [_content_part_text(part) for part in content]
    return "\n".join(line for line in lines if line)


def _content_part_text(part: ContentPart) -> str:
    kind = part.get("type")
    if kind == "text":
        return str(part.get("text", ""))
    if kind == "thinking":
        return str(part.get("thinking", ""))
    if kind == "tool_result":
        inner = part.get("content", "")
        return inner if isinstance(inner, str) else _content_as_prompt_text(inner)  # type: ignore[arg-type]
    return ""


def _content_as_parts(content: Content) -> List[ContentPart]:
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return list(content)


def _agent_session_id(options: Optional[RunOptions]) -> str:
    session_id = options.session_id if options is not None else None
    if session_id is None:
        return new_nano_id()
    if not is_nano_id(session_id):
        raise TypeError(
            "options.session_id must be a 21-character alphanumeric NanoID for agent transport"
        )
    return session_id


def _with_fresh_session_id(options: Optional[RunOptions]) -> RunOptions:
    """Return ``options`` with a regenerated ``session_id`` for a retry.

    A retried attempt is a new session: the previous session id was consumed by
    the attempt that hit ``auth_required`` and sessions are not resumable.
    """
    if options is None:
        return RunOptions(session_id=new_nano_id())
    return RunOptions(
        temperature=options.temperature,
        max_tokens=options.max_tokens,
        reasoning_effort=options.reasoning_effort,
        auth_retry_policy=options.auth_retry_policy,
        session_id=new_nano_id(),
        metadata=options.metadata,
    )


def _stream_timeout_context(
    operation: str, timeout: float, stream_id: str, model_ref: str
) -> TimeoutContext:
    parsed = _split_model_ref(model_ref)
    return TimeoutContext(
        operation,
        timeout,
        stream_id=stream_id,
        message_id=stream_id,
        provider_id=parsed[0] if parsed else None,
        api=parsed[1] if parsed else None,
        model_ref=model_ref,
        model_id=parsed[2] if parsed else None,
    )


def _session_timeout_context(
    operation: str, timeout: float, session_id: str, model_ref: str
) -> TimeoutContext:
    parsed = _split_model_ref(model_ref)
    return TimeoutContext(
        operation,
        timeout,
        session_id=session_id,
        provider_id=parsed[0] if parsed else None,
        api=parsed[1] if parsed else None,
        model_ref=model_ref,
        model_id=parsed[2] if parsed else None,
    )


def _retryable_auth_provider(
    error: MakaiStreamError, fallback_provider_id: Optional[str]
) -> Optional[str]:
    """Return the provider to log in to, or ``None`` when this is not an auth failure."""
    if isinstance(error, MakaiAuthRequiredError):
        return None
    if error.code != "auth_required":
        return None
    return error.provider_id or fallback_provider_id


def _response_or_auth_error(
    response: CompletionResponse, provider_id: Optional[str], *, allow_retry: bool
) -> CompletionResponse:
    """Re-raise a provider auth failure that arrived as a normal result.

    A failed auth turn still settles through the result path with
    ``stop_reason: "error"`` (spec §3.5); returning it as a successful
    response would hide the login requirement.
    """
    if response.stop_reason != "error" or not is_auth_failure_message(
        response.error_message, api=response.api
    ):
        return response
    resolved = response.provider_id or provider_id
    message = response.error_message or "auth_required"
    if allow_retry:
        raise MakaiStreamError(
            message, kind="provider_error", code="auth_required", provider_id=resolved
        )
    if resolved:
        raise MakaiAuthRequiredError(resolved, message)
    raise MakaiStreamError(message, kind="provider_error", code="auth_required")


def _is_replayable(event: AgentStreamEvent) -> bool:
    """Lifecycle events that a retried attempt would re-emit harmlessly."""
    from .types import MessageStart, TurnEnd, TurnStart

    return isinstance(event, (AgentStart, TurnStart, TurnEnd, MessageStart, MessageEnd))
