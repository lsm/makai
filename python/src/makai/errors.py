"""Exception hierarchy for the Makai SDK.

The hierarchy mirrors the TypeScript SDK's error classes:

``MakaiError``
    Base class. Everything the SDK raises on purpose derives from it, so
    ``except MakaiError`` is a valid catch-all.

``MakaiStreamError``
    Provider, stream, transport, abort, or unknown failures raised while
    running ``provider`` or ``agent`` calls.

``MakaiAuthRequiredError``
    A ``MakaiStreamError`` specialisation for ``auth_required``. Carries the
    ``provider_id`` that needs a login.

``MakaiProtocolError``
    Models-API protocol failures: ``invalid_request``, malformed responses, or
    a request ``nack``.

``MakaiAuthError``
    Auth provider listing and interactive login failures.
"""

from __future__ import annotations

from typing import Any, Literal, Mapping, Optional

__all__ = [
    "MakaiError",
    "MakaiStreamError",
    "MakaiStreamErrorKind",
    "MakaiAuthRequiredError",
    "MakaiProtocolError",
    "MakaiAuthError",
    "MakaiAuthErrorKind",
    "TimeoutDiagnostics",
]

MakaiStreamErrorKind = Literal["provider_error", "transport_error", "aborted", "unknown"]
MakaiAuthErrorKind = Literal["provider_error", "cancelled", "transport_error", "unknown"]

TimeoutDiagnostics = Mapping[str, Any]
"""Structured context attached to timeout failures.

Keys mirror the TypeScript ``TimeoutDiagnostics`` shape: ``operation``,
``timeout_ms``, ``stream_id``, ``message_id``, ``session_id``, ``provider_id``,
``api``, ``model_ref``, ``model_id``, and ``suggestions``.
"""


class MakaiError(Exception):
    """Base class for every error the Makai SDK raises deliberately."""

    def __init__(
        self,
        message: str,
        *,
        code: Optional[str] = None,
        diagnostics: Optional[TimeoutDiagnostics] = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.diagnostics = diagnostics

    def __str__(self) -> str:
        return self.message


class MakaiStreamError(MakaiError):
    """A provider or agent call failed.

    ``kind`` narrows the failure surface and ``code`` carries the protocol
    error code when the runtime supplied one (for example ``auth_required``,
    ``agent_busy``, ``invalid_request``).
    """

    def __init__(
        self,
        message: str,
        *,
        kind: MakaiStreamErrorKind = "unknown",
        code: Optional[str] = None,
        provider_id: Optional[str] = None,
        diagnostics: Optional[TimeoutDiagnostics] = None,
    ) -> None:
        super().__init__(message, code=code, diagnostics=diagnostics)
        self.kind: MakaiStreamErrorKind = kind
        self.provider_id = provider_id


TIMEOUT_CODE = "timeout"
"""``MakaiStreamError.code`` marking a wait that ran out of time.

Callers branch on this rather than on the message text, so rewording the
message cannot silently turn a timeout into an unrecognised transport error.
"""


def is_timeout_error(error: MakaiError) -> bool:
    """Return ``True`` when ``error`` is a wait that expired."""
    return error.code == TIMEOUT_CODE


class MakaiAuthRequiredError(MakaiStreamError):
    """The provider rejected the call because it needs an interactive login."""

    def __init__(self, provider_id: str, message: Optional[str] = None) -> None:
        super().__init__(
            message or f"authentication required for provider {provider_id}",
            kind="provider_error",
            code="auth_required",
            provider_id=provider_id,
        )
        self.provider_id: str = provider_id


class MakaiProtocolError(MakaiError):
    """A models-API request was rejected or the response was malformed."""

    def __init__(
        self,
        message: str,
        code: Optional[str] = None,
        *,
        diagnostics: Optional[TimeoutDiagnostics] = None,
    ) -> None:
        super().__init__(message, code=code, diagnostics=diagnostics)


class MakaiAuthError(MakaiError):
    """Listing auth providers or running an interactive login failed."""

    def __init__(
        self,
        message: str,
        *,
        kind: MakaiAuthErrorKind = "unknown",
        code: Optional[str] = None,
        diagnostics: Optional[TimeoutDiagnostics] = None,
    ) -> None:
        super().__init__(message, code=code, diagnostics=diagnostics)
        self.kind: MakaiAuthErrorKind = kind
