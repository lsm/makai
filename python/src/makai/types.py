"""Public data types for requests, responses, and stream events.

Requests use ``TypedDict`` so callers can write plain dictionaries
(``{"role": "user", "content": "hi"}``), matching the protocol's JSON shapes.
Stream events are frozen dataclasses with a ``type`` discriminator, so both
``isinstance(event, TextDelta)`` and ``event.type == "text_delta"`` work.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import (
    Any,
    Awaitable,
    Callable,
    Dict,
    List,
    Literal,
    Mapping,
    NotRequired,
    Optional,
    Sequence,
    TypedDict,
    Union,
    cast,
)

__all__ = [
    "AuthRetryPolicy",
    "ReasoningEffort",
    "Role",
    "TextContentPart",
    "ThinkingContentPart",
    "ImageContentPart",
    "ToolCallContentPart",
    "ToolResultContentPart",
    "ContentPart",
    "Content",
    "ChatMessage",
    "ToolContext",
    "ToolResult",
    "ToolExecutor",
    "ToolDefinition",
    "RunOptions",
    "Usage",
    "AssistantMessage",
    "CompletionResponse",
    "MessageStart",
    "TextDelta",
    "ThinkingDelta",
    "ToolCall",
    "MessageEnd",
    "StreamError",
    "ProviderStreamEvent",
    "AgentStart",
    "AgentEnd",
    "TurnStart",
    "TurnEnd",
    "ToolExecutionStart",
    "ToolExecutionEnd",
    "AgentStreamEvent",
    "AuthStatus",
    "ModelLifecycle",
    "ModelCapability",
    "ModelSource",
    "ProviderAuthInfo",
    "ModelDescriptor",
    "ListModelsResponse",
    "AuthUrlEvent",
    "AuthPromptEvent",
    "AuthProgressEvent",
    "AuthSuccessEvent",
    "AuthErrorEvent",
    "AuthEvent",
    "AuthEventHandler",
    "AuthPromptHandler",
    "AuthFlowHandlers",
]

AuthRetryPolicy = Literal["manual", "auto_once"]
ReasoningEffort = Literal["off", "minimal", "low", "medium", "high", "xhigh"]
Role = Literal["system", "developer", "user", "assistant", "tool"]

AuthStatus = Literal[
    "authenticated",
    "login_required",
    "expired",
    "refreshing",
    "login_in_progress",
    "failed",
    "unknown",
]
ModelLifecycle = Literal["stable", "preview", "deprecated"]
ModelCapability = Literal[
    "chat",
    "streaming",
    "tools",
    "vision",
    "reasoning",
    "prompt_cache",
    "audio_input",
    "audio_output",
]
ModelSource = Literal["dynamic", "static_fallback"]


class TextContentPart(TypedDict):
    type: Literal["text"]
    text: str
    text_signature: NotRequired[str]


class ThinkingContentPart(TypedDict):
    type: Literal["thinking"]
    thinking: str
    thinking_signature: NotRequired[str]


class ImageContentPart(TypedDict):
    type: Literal["image"]
    data: str
    mime_type: str


class ToolCallContentPart(TypedDict):
    type: Literal["tool_call"]
    tool_call_id: str
    name: str
    arguments_json: str


class ToolResultContentPart(TypedDict):
    type: Literal["tool_result"]
    tool_call_id: str
    tool_name: str
    content: Union[str, List[TextContentPart]]
    is_error: NotRequired[bool]
    details_json: NotRequired[str]


ContentPart = Union[
    TextContentPart,
    ThinkingContentPart,
    ImageContentPart,
    ToolCallContentPart,
    ToolResultContentPart,
]
Content = Union[str, List[ContentPart]]


class ChatMessage(TypedDict):
    """One conversation turn.

    ``system`` and ``developer`` messages are folded into the request's system
    prompt by the SDK; every other role is sent as a message.
    """

    role: Role
    content: Content
    name: NotRequired[str]
    tool_call_id: NotRequired[str]


@dataclass(frozen=True)
class ToolContext:
    """Identifiers passed to a tool's ``execute`` callback."""

    tool_call_id: str
    tool_name: str
    args_json: str


ToolResult = Union[str, List[TextContentPart]]
ToolExecutor = Callable[
    [Dict[str, Any], ToolContext],
    Union[ToolResult, Awaitable[ToolResult]],
]


@dataclass(frozen=True)
class ToolDefinition:
    """A tool the model may call.

    ``parameters_schema_json`` is a JSON Schema **string**, matching the wire
    format. ``execute`` is optional: supply it for ``agent`` calls so the SDK
    can run the tool in your process when the runtime asks. It may be a plain
    function or a coroutine function. Tools without ``execute`` are advertised
    to the model but reported back as not executable if called.
    """

    name: str
    description: str
    parameters_schema_json: str
    execute: Optional[ToolExecutor] = None


@dataclass(frozen=True)
class RunOptions:
    """Per-request knobs.

    ``session_id`` is a **correlation key only**, not a resume handle: sessions
    are not resumable (spec §13.1). Supplying one lets you correlate SDK calls
    with runtime logs; on interruption you must resend the full context. Under
    ``auth_retry_policy="auto_once"`` the SDK regenerates the id for the
    retried attempt, so it is not stable across a retry.
    """

    temperature: Optional[float] = None
    max_tokens: Optional[int] = None
    reasoning_effort: Optional[ReasoningEffort] = None
    auth_retry_policy: Optional[AuthRetryPolicy] = None
    session_id: Optional[str] = None
    metadata: Optional[Mapping[str, str]] = None


@dataclass(frozen=True)
class Usage:
    """Token accounting for one provider turn or one aggregate agent run."""

    input: int
    output: int
    cache_read: Optional[int] = None
    cache_write: Optional[int] = None


@dataclass(frozen=True)
class AssistantMessage:
    role: Literal["assistant"]
    content: Content


@dataclass(frozen=True)
class CompletionResponse:
    """The terminal result of ``provider.complete`` or ``agent.run``."""

    message: AssistantMessage
    provider_id: str
    api: str
    model_id: str
    usage: Optional[Usage] = None
    stop_reason: Optional[str] = None
    error_message: Optional[str] = None

    @property
    def text(self) -> str:
        """Concatenate every text part of the assistant message."""
        content = self.message.content
        if isinstance(content, str):
            return content
        chunks: List[str] = []
        for part in content:
            if part.get("type") == "text":
                text = cast(TextContentPart, part).get("text", "")
                if isinstance(text, str):
                    chunks.append(text)
        return "".join(chunks)


@dataclass(frozen=True)
class MessageStart:
    provider_id: Optional[str] = None
    api: Optional[str] = None
    model_id: Optional[str] = None
    type: Literal["message_start"] = "message_start"


@dataclass(frozen=True)
class TextDelta:
    delta: str
    type: Literal["text_delta"] = "text_delta"


@dataclass(frozen=True)
class ThinkingDelta:
    delta: str
    type: Literal["thinking_delta"] = "thinking_delta"


@dataclass(frozen=True)
class ToolCall:
    tool_call_id: str
    name: str
    arguments_json: str
    type: Literal["tool_call"] = "tool_call"


@dataclass(frozen=True)
class MessageEnd:
    usage: Optional[Usage] = None
    stop_reason: Optional[str] = None
    error_message: Optional[str] = None
    type: Literal["message_end"] = "message_end"


@dataclass(frozen=True)
class StreamError:
    message: str
    code: Optional[str] = None
    provider_id: Optional[str] = None
    type: Literal["error"] = "error"


ProviderStreamEvent = Union[
    MessageStart, TextDelta, ThinkingDelta, ToolCall, MessageEnd, StreamError
]


@dataclass(frozen=True)
class AgentStart:
    session_id: Optional[str] = None
    type: Literal["agent_start"] = "agent_start"


@dataclass(frozen=True)
class AgentEnd:
    usage: Optional[Usage] = None
    stop_reason: Optional[str] = None
    error_message: Optional[str] = None
    provider_id: Optional[str] = None
    api: Optional[str] = None
    type: Literal["agent_end"] = "agent_end"


@dataclass(frozen=True)
class TurnStart:
    type: Literal["turn_start"] = "turn_start"


@dataclass(frozen=True)
class TurnEnd:
    stop_reason: Optional[str] = None
    error_message: Optional[str] = None
    type: Literal["turn_end"] = "turn_end"


@dataclass(frozen=True)
class ToolExecutionStart:
    tool_call_id: str
    tool_name: str
    type: Literal["tool_execution_start"] = "tool_execution_start"


@dataclass(frozen=True)
class ToolExecutionEnd:
    tool_call_id: str
    is_error: Optional[bool] = None
    type: Literal["tool_execution_end"] = "tool_execution_end"


AgentStreamEvent = Union[
    ProviderStreamEvent,
    AgentStart,
    AgentEnd,
    TurnStart,
    TurnEnd,
    ToolExecutionStart,
    ToolExecutionEnd,
]


@dataclass(frozen=True)
class ProviderAuthInfo:
    """One row of ``auth.list_providers()``."""

    id: str
    name: str
    auth_status: AuthStatus
    last_error: Optional[str] = None


@dataclass(frozen=True)
class ModelDescriptor:
    """Discovery-plane metadata for one model.

    ``model_ref`` is opaque. Pass it to ``provider``/``agent`` calls unchanged;
    do not parse or construct one.
    """

    model_ref: str
    model_id: str
    display_name: str
    provider_id: str
    api: str
    auth_status: AuthStatus
    lifecycle: ModelLifecycle
    capabilities: Sequence[ModelCapability]
    source: ModelSource
    base_url: Optional[str] = None
    context_window: Optional[int] = None
    max_output_tokens: Optional[int] = None
    reasoning_default: Optional[ReasoningEffort] = None
    metadata: Optional[Mapping[str, str]] = None


@dataclass(frozen=True)
class ListModelsResponse:
    models: List[ModelDescriptor] = field(default_factory=list)
    fetched_at_ms: int = 0
    cache_max_age_ms: int = 0


@dataclass(frozen=True)
class AuthUrlEvent:
    flow_id: str
    provider_id: str
    url: str
    instructions: Optional[str] = None
    type: Literal["auth_url"] = "auth_url"


@dataclass(frozen=True)
class AuthPromptEvent:
    flow_id: str
    prompt_id: str
    provider_id: str
    message: str
    allow_empty: bool = False
    type: Literal["prompt"] = "prompt"


@dataclass(frozen=True)
class AuthProgressEvent:
    flow_id: str
    provider_id: str
    message: str
    type: Literal["progress"] = "progress"


@dataclass(frozen=True)
class AuthSuccessEvent:
    flow_id: str
    provider_id: str
    type: Literal["success"] = "success"


@dataclass(frozen=True)
class AuthErrorEvent:
    flow_id: str
    provider_id: str
    message: str
    code: Optional[str] = None
    type: Literal["error"] = "error"


AuthEvent = Union[
    AuthUrlEvent, AuthPromptEvent, AuthProgressEvent, AuthSuccessEvent, AuthErrorEvent
]

AuthEventHandler = Callable[[AuthEvent], Union[None, Awaitable[None]]]
AuthPromptHandler = Callable[[AuthPromptEvent], Union[str, Awaitable[str]]]


@dataclass(frozen=True)
class AuthFlowHandlers:
    """Callbacks driving an interactive login.

    ``on_event`` receives every auth event; ``on_prompt`` must return the
    user's answer for a ``prompt`` event. Either may be a coroutine function.
    A login that hits a prompt with no ``on_prompt`` handler is cancelled.
    """

    on_event: Optional[AuthEventHandler] = None
    on_prompt: Optional[AuthPromptHandler] = None
