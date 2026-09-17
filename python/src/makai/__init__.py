"""Makai Python SDK.

Starts a ``makai --stdio`` runtime and exposes four namespaces over its
newline-delimited JSON protocol:

``client.auth``
    List auth providers and run interactive logins. Token material stays in
    the runtime and is never returned to callers.
``client.models``
    Discover models. ``model_ref`` values are opaque handles -- pass them
    through unchanged.
``client.provider``
    Direct provider completions (``complete``) and streaming (``stream``).
``client.agent``
    The runtime's agent loop (``run`` / ``stream``), with tools executed in
    your process through :class:`~makai.types.ToolDefinition` callbacks.

Quick start::

    import asyncio
    import makai

    async def main() -> None:
        async with makai.connect() as client:
            model = await client.models.resolve(
                provider_id="anthropic",
                api="anthropic-messages",
                model_id="claude-sonnet-4-5",
            )
            response = await client.provider.complete(
                model_ref=model.model_ref,
                messages=[{"role": "user", "content": "Write a haiku about streams."}],
                options=makai.RunOptions(max_tokens=128),
            )
            print(response.text)

    asyncio.run(main())
"""

from __future__ import annotations

from .auth import AuthApi
from .binary import BinaryResolverOptions, resolve_makai_binary
from .client import AuthOptions, MakaiClient, connect
from .errors import (
    MakaiAuthError,
    MakaiAuthErrorKind,
    MakaiAuthRequiredError,
    MakaiError,
    MakaiProtocolError,
    MakaiStreamError,
    MakaiStreamErrorKind,
)
from .execution import AgentApi, ProviderApi
from .models import ModelsApi
from .sync import SyncMakaiClient, connect_sync
from .transport import Frame, FrameRoute, StdioTransport
from .types import (
    AgentEnd,
    AgentStart,
    AgentStreamEvent,
    AssistantMessage,
    AuthErrorEvent,
    AuthEvent,
    AuthFlowHandlers,
    AuthProgressEvent,
    AuthPromptEvent,
    AuthRetryPolicy,
    AuthStatus,
    AuthSuccessEvent,
    AuthUrlEvent,
    ChatMessage,
    CompletionResponse,
    Content,
    ContentPart,
    ImageContentPart,
    ListModelsResponse,
    MessageEnd,
    MessageStart,
    ModelCapability,
    ModelDescriptor,
    ModelLifecycle,
    ModelSource,
    ProviderAuthInfo,
    ProviderStreamEvent,
    ReasoningEffort,
    RunOptions,
    StreamError,
    TextContentPart,
    TextDelta,
    ThinkingContentPart,
    ThinkingDelta,
    ToolCall,
    ToolCallContentPart,
    ToolContext,
    ToolDefinition,
    ToolExecutionEnd,
    ToolExecutionStart,
    ToolResult,
    ToolResultContentPart,
    TurnEnd,
    TurnStart,
    Usage,
)

__version__ = "0.1.0"

__all__ = [
    "__version__",
    # Entry points
    "connect",
    "connect_sync",
    "MakaiClient",
    "SyncMakaiClient",
    "AuthOptions",
    # Namespaces
    "AuthApi",
    "ModelsApi",
    "ProviderApi",
    "AgentApi",
    # Transport
    "StdioTransport",
    "FrameRoute",
    "Frame",
    "BinaryResolverOptions",
    "resolve_makai_binary",
    # Errors
    "MakaiError",
    "MakaiStreamError",
    "MakaiStreamErrorKind",
    "MakaiAuthRequiredError",
    "MakaiProtocolError",
    "MakaiAuthError",
    "MakaiAuthErrorKind",
    # Requests
    "ChatMessage",
    "Content",
    "ContentPart",
    "TextContentPart",
    "ThinkingContentPart",
    "ImageContentPart",
    "ToolCallContentPart",
    "ToolResultContentPart",
    "ToolDefinition",
    "ToolContext",
    "ToolResult",
    "RunOptions",
    "AuthRetryPolicy",
    "ReasoningEffort",
    # Responses
    "CompletionResponse",
    "AssistantMessage",
    "Usage",
    # Provider events
    "ProviderStreamEvent",
    "MessageStart",
    "TextDelta",
    "ThinkingDelta",
    "ToolCall",
    "MessageEnd",
    "StreamError",
    # Agent events
    "AgentStreamEvent",
    "AgentStart",
    "AgentEnd",
    "TurnStart",
    "TurnEnd",
    "ToolExecutionStart",
    "ToolExecutionEnd",
    # Models
    "ModelDescriptor",
    "ListModelsResponse",
    "ModelCapability",
    "ModelLifecycle",
    "ModelSource",
    "AuthStatus",
    # Auth
    "ProviderAuthInfo",
    "AuthFlowHandlers",
    "AuthEvent",
    "AuthUrlEvent",
    "AuthPromptEvent",
    "AuthProgressEvent",
    "AuthSuccessEvent",
    "AuthErrorEvent",
]
