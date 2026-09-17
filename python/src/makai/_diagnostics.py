"""Timeout diagnostics shared by every namespace.

When a request times out, the SDK attaches the identifiers needed to correlate
the failure with runtime logs plus a short list of remediation suggestions.
This mirrors ``typescript/src/timeout_diagnostics.ts``.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

__all__ = [
    "TIMEOUT_SUGGESTIONS",
    "TimeoutContext",
    "build_diagnostics",
    "format_timeout_message",
]

TIMEOUT_SUGGESTIONS = (
    "Verify the makai binary is installed, executable, and still running.",
    "Check network connectivity and provider service health.",
    "Review server logs using the included stream_id/message_id for correlation.",
    "Increase the response_timeout option if the provider is expected to be slow.",
)


class TimeoutContext:
    """Identifiers describing the request that timed out."""

    __slots__ = (
        "operation",
        "timeout_s",
        "stream_id",
        "message_id",
        "session_id",
        "provider_id",
        "api",
        "model_ref",
        "model_id",
    )

    def __init__(
        self,
        operation: str,
        timeout_s: float,
        *,
        stream_id: Optional[str] = None,
        message_id: Optional[str] = None,
        session_id: Optional[str] = None,
        provider_id: Optional[str] = None,
        api: Optional[str] = None,
        model_ref: Optional[str] = None,
        model_id: Optional[str] = None,
    ) -> None:
        self.operation = operation
        self.timeout_s = timeout_s
        self.stream_id = stream_id
        self.message_id = message_id
        self.session_id = session_id
        self.provider_id = provider_id
        self.api = api
        self.model_ref = model_ref
        self.model_id = model_id


def build_diagnostics(context: TimeoutContext) -> Dict[str, Any]:
    """Return the structured diagnostics mapping for ``context``."""
    diagnostics: Dict[str, Any] = {
        "operation": context.operation,
        "timeout_ms": int(context.timeout_s * 1000),
        "suggestions": list(TIMEOUT_SUGGESTIONS),
    }
    for key in ("stream_id", "message_id", "session_id", "provider_id", "api", "model_ref", "model_id"):
        value = getattr(context, key)
        if value is not None:
            diagnostics[key] = value
    return diagnostics


def format_timeout_message(context: TimeoutContext) -> str:
    """Render the human-readable timeout message for ``context``."""
    ids = []
    if context.stream_id:
        ids.append(f"stream_id={context.stream_id}")
    if context.session_id:
        ids.append(f"session_id={context.session_id}")
    if context.message_id:
        ids.append(f"message_id={context.message_id}")
    id_suffix = f" ({', '.join(ids)})" if ids else ""
    provider = f" for provider '{context.provider_id}'" if context.provider_id else ""
    model = f" (model_ref='{context.model_ref}')" if context.model_ref else ""
    timeout_ms = int(context.timeout_s * 1000)
    return (
        f"Timed out waiting for {context.operation} after {timeout_ms}ms"
        f"{provider}{model}{id_suffix}. Suggestions: {' '.join(TIMEOUT_SUGGESTIONS)}"
    )
