"""A blocking convenience wrapper around :class:`~makai.client.MakaiClient`.

The async client is the real API. This module runs it on a private event loop
in a background thread so scripts and REPLs can use Makai without an
``async def main()``::

    with makai.connect_sync() as client:
        model = client.models.resolve(provider_id="anthropic", model_id="...")
        for event in client.provider.stream(model_ref=model.model_ref, messages=[...]):
            ...

Everything here delegates; no protocol logic lives in this module. Do not use
it from inside a running event loop -- use the async client there instead.
"""

from __future__ import annotations

import asyncio
import threading
from concurrent.futures import Future
from types import TracebackType
from typing import (
    Any,
    AsyncIterator,
    Awaitable,
    Callable,
    Iterator,
    List,
    Mapping,
    Optional,
    Sequence,
    Type,
    TypeVar,
)

from .binary import BinaryResolverOptions
from .client import AuthOptions, MakaiClient, connect
from .transport import DEFAULT_HANDSHAKE_TIMEOUT_S, StdioTransport
from .types import (
    AgentStreamEvent,
    AuthFlowHandlers,
    ChatMessage,
    CompletionResponse,
    ListModelsResponse,
    ModelDescriptor,
    ProviderAuthInfo,
    ProviderStreamEvent,
    RunOptions,
    ToolDefinition,
)

__all__ = [
    "SyncMakaiClient",
    "SyncAuthApi",
    "SyncModelsApi",
    "SyncProviderApi",
    "SyncAgentApi",
    "connect_sync",
]

T = TypeVar("T")

_STREAM_SENTINEL = object()


class _LoopThread:
    """A dedicated event loop running on its own thread."""

    def __init__(self) -> None:
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(
            target=self._run, name="makai-sync-loop", daemon=True
        )
        self._thread.start()

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def run(self, coro: Awaitable[T]) -> T:
        future: Future[T] = asyncio.run_coroutine_threadsafe(coro, self._loop)  # type: ignore[arg-type]
        return future.result()

    def is_closed(self) -> bool:
        return self._loop.is_closed()

    def close(self) -> None:
        if self._loop.is_closed():
            return
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(timeout=5.0)
        self._loop.close()


def _iterate(
    loop: _LoopThread, factory: Callable[[], AsyncIterator[Any]]
) -> Iterator[Any]:
    """Drive an async iterator from the calling (synchronous) thread."""
    holder: List[AsyncIterator[Any]] = []

    async def start() -> None:
        holder.append(factory().__aiter__())

    async def step() -> Any:
        try:
            return await holder[0].__anext__()
        except StopAsyncIteration:
            return _STREAM_SENTINEL

    async def stop() -> None:
        closer = getattr(holder[0], "aclose", None)
        if closer is not None:
            await closer()

    loop.run(start())
    try:
        while True:
            item = loop.run(step())
            if item is _STREAM_SENTINEL:
                return
            yield item
    finally:
        # The caller may have closed the client before abandoning this
        # iterator, in which case the loop is gone and there is nowhere left
        # to run the teardown; the runtime process is already terminated.
        if not loop.is_closed():
            loop.run(stop())


class SyncAuthApi:
    """Blocking view of :class:`~makai.auth.AuthApi`."""

    def __init__(self, loop: _LoopThread, client: MakaiClient) -> None:
        self._loop = loop
        self._client = client

    def list_providers(self) -> List[ProviderAuthInfo]:
        return self._loop.run(self._client.auth.list_providers())

    def login(self, provider_id: str, handlers: Optional[AuthFlowHandlers] = None) -> None:
        self._loop.run(self._client.auth.login(provider_id, handlers))


class SyncModelsApi:
    """Blocking view of :class:`~makai.models.ModelsApi`."""

    def __init__(self, loop: _LoopThread, client: MakaiClient) -> None:
        self._loop = loop
        self._client = client

    def list(self, **kwargs: Any) -> ListModelsResponse:
        return self._loop.run(self._client.models.list(**kwargs))

    def resolve(self, **kwargs: Any) -> ModelDescriptor:
        return self._loop.run(self._client.models.resolve(**kwargs))


class SyncProviderApi:
    """Blocking view of :class:`~makai.execution.ProviderApi`."""

    def __init__(self, loop: _LoopThread, client: MakaiClient) -> None:
        self._loop = loop
        self._client = client

    def complete(
        self,
        *,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]] = None,
        options: Optional[RunOptions] = None,
    ) -> CompletionResponse:
        return self._loop.run(
            self._client.provider.complete(
                model_ref=model_ref, messages=messages, tools=tools, options=options
            )
        )

    def stream(
        self,
        *,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]] = None,
        options: Optional[RunOptions] = None,
    ) -> Iterator[ProviderStreamEvent]:
        return _iterate(
            self._loop,
            lambda: self._client.provider.stream(
                model_ref=model_ref, messages=messages, tools=tools, options=options
            ),
        )


class SyncAgentApi:
    """Blocking view of :class:`~makai.execution.AgentApi`."""

    def __init__(self, loop: _LoopThread, client: MakaiClient) -> None:
        self._loop = loop
        self._client = client
        self.models = SyncModelsApi(loop, client)

    def run(
        self,
        *,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]] = None,
        options: Optional[RunOptions] = None,
    ) -> CompletionResponse:
        return self._loop.run(
            self._client.agent.run(
                model_ref=model_ref, messages=messages, tools=tools, options=options
            )
        )

    def stream(
        self,
        *,
        model_ref: str,
        messages: Sequence[ChatMessage],
        tools: Optional[Sequence[ToolDefinition]] = None,
        options: Optional[RunOptions] = None,
    ) -> Iterator[AgentStreamEvent]:
        return _iterate(
            self._loop,
            lambda: self._client.agent.stream(
                model_ref=model_ref, messages=messages, tools=tools, options=options
            ),
        )


class SyncMakaiClient:
    """Blocking client. Create one with :func:`connect_sync`."""

    def __init__(self, loop: _LoopThread, client: MakaiClient) -> None:
        self._loop = loop
        self._client = client
        self.auth = SyncAuthApi(loop, client)
        self.models = SyncModelsApi(loop, client)
        self.provider = SyncProviderApi(loop, client)
        self.agent = SyncAgentApi(loop, client)
        self._closed = False

    @property
    def transport(self) -> "StdioTransport":
        """The underlying stdio transport. Useful for diagnostics."""
        return self._client.transport

    def close(self) -> None:
        """Terminate the runtime process and stop the background loop.

        Idempotent: closing inside a ``with connect_sync()`` block and letting
        ``__exit__`` close again is the common pattern, and the second call
        must not build a coroutine for a loop that is already gone.
        """
        if self._closed:
            return
        self._closed = True
        try:
            self._loop.run(self._client.close())
        finally:
            self._loop.close()

    def __enter__(self) -> "SyncMakaiClient":
        return self

    def __exit__(
        self,
        exc_type: Optional[Type[BaseException]],
        exc: Optional[BaseException],
        tb: Optional[TracebackType],
    ) -> None:
        self.close()


def connect_sync(
    *,
    command: Optional[str] = None,
    args: Optional[Sequence[str]] = None,
    cwd: Optional[str] = None,
    env: Optional[Mapping[str, str]] = None,
    resolver: Optional[BinaryResolverOptions] = None,
    auth: Optional[AuthOptions] = None,
    response_timeout: Optional[float] = None,
    frame_timeout: Optional[float] = None,
    handshake_timeout: float = DEFAULT_HANDSHAKE_TIMEOUT_S,
) -> SyncMakaiClient:
    """Start a runtime and return a blocking client.

    Accepts the same arguments as :func:`makai.connect`. Raises
    :class:`RuntimeError` when called from inside a running event loop.
    """
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        pass
    else:
        raise RuntimeError(
            "connect_sync() cannot be called from a running event loop; use makai.connect()"
        )

    loop = _LoopThread()
    try:
        client = loop.run(
            connect(
                command=command,
                args=args,
                cwd=cwd,
                env=env,
                resolver=resolver,
                auth=auth,
                response_timeout=response_timeout,
                frame_timeout=frame_timeout,
                handshake_timeout=handshake_timeout,
            )._open()
        )
    except BaseException:
        loop.close()
        raise
    return SyncMakaiClient(loop, client)
