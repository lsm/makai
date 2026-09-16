//! Error types.
//!
//! The variants mirror the TypeScript SDK's error classes so that the two SDKs
//! report the same failure with the same `kind` / `code` pair:
//!
//! | TypeScript | Rust |
//! | --- | --- |
//! | `MakaiStreamError` | [`Error::Stream`] |
//! | `MakaiAuthRequiredError` | [`Error::AuthRequired`] |
//! | `MakaiProtocolError` | [`Error::Protocol`] |
//! | `MakaiAuthError` | [`Error::Auth`] |
//!
//! [`Error::Transport`] and [`Error::InvalidRequest`] have no TypeScript
//! counterpart: TypeScript folds connect-time and argument-validation failures
//! into plain `Error`/`TypeError`, which would be untyped here.

use thiserror::Error;

/// Result alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;

/// Classification of a [`Error::Stream`] failure. Mirrors `MakaiStreamErrorKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum StreamErrorKind {
    /// The provider or the agent loop reported the failure.
    ProviderError,
    /// The transport failed: timeout, malformed frame, or a dead child process.
    TransportError,
    /// The caller cancelled the operation.
    Aborted,
    /// Anything else.
    Unknown,
}

impl StreamErrorKind {
    /// The wire-facing spelling, matching the TypeScript `kind` strings.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ProviderError => "provider_error",
            Self::TransportError => "transport_error",
            Self::Aborted => "aborted",
            Self::Unknown => "unknown",
        }
    }
}

impl std::fmt::Display for StreamErrorKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Classification of an [`Error::Auth`] failure. Mirrors `MakaiAuthErrorKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum AuthErrorKind {
    /// The provider's auth flow failed.
    ProviderError,
    /// The flow was cancelled, either by the user or by the runtime.
    Cancelled,
    /// The transport failed while the flow was in progress.
    TransportError,
    /// Anything else.
    Unknown,
}

impl AuthErrorKind {
    /// The wire-facing spelling, matching the TypeScript `kind` strings.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ProviderError => "provider_error",
            Self::Cancelled => "cancelled",
            Self::TransportError => "transport_error",
            Self::Unknown => "unknown",
        }
    }
}

impl std::fmt::Display for AuthErrorKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Every failure this crate can produce.
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum Error {
    /// A `provider` or `agent` call failed. Mirrors `MakaiStreamError`.
    #[error("{message}")]
    Stream {
        /// What kind of failure this was.
        kind: StreamErrorKind,
        /// The protocol `error_code`, when the runtime supplied one.
        code: Option<String>,
        /// The provider the failure is attributed to, when known.
        provider_id: Option<String>,
        /// Human-readable detail.
        message: String,
    },

    /// A call needs interactive login first. Mirrors `MakaiAuthRequiredError`.
    ///
    /// This is the terminal form: it is raised after `auth_retry_policy` has
    /// been exhausted, so receiving it means the caller must run
    /// [`crate::AuthApi::login`] itself.
    #[error("{message}")]
    AuthRequired {
        /// The provider that needs credentials.
        provider_id: String,
        /// Human-readable detail.
        message: String,
    },

    /// A `models` call failed, or a frame did not match the shape the spec pins.
    /// Mirrors `MakaiProtocolError`.
    #[error("{message}")]
    Protocol {
        /// The protocol `error_code`, when the runtime supplied one.
        code: Option<String>,
        /// Human-readable detail.
        message: String,
    },

    /// An `auth` call failed. Mirrors `MakaiAuthError`.
    #[error("{message}")]
    Auth {
        /// What kind of failure this was.
        kind: AuthErrorKind,
        /// The protocol `error_code`, when the runtime supplied one.
        code: Option<String>,
        /// Human-readable detail.
        message: String,
    },

    /// The runtime process could not be found, started, or kept alive.
    #[error("{message}")]
    Transport {
        /// Human-readable detail.
        message: String,
    },

    /// The request was rejected locally, before anything reached the wire.
    #[error("{message}")]
    InvalidRequest {
        /// Human-readable detail.
        message: String,
    },
}

impl Error {
    pub(crate) fn stream(kind: StreamErrorKind, message: impl Into<String>) -> Self {
        Self::Stream {
            kind,
            code: None,
            provider_id: None,
            message: message.into(),
        }
    }

    pub(crate) fn transport_stream(message: impl Into<String>) -> Self {
        Self::stream(StreamErrorKind::TransportError, message)
    }

    pub(crate) fn provider_stream(
        message: impl Into<String>,
        code: Option<String>,
        provider_id: Option<String>,
    ) -> Self {
        Self::Stream {
            kind: StreamErrorKind::ProviderError,
            code,
            provider_id,
            message: message.into(),
        }
    }

    pub(crate) fn auth_required(
        provider_id: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self::AuthRequired {
            provider_id: provider_id.into(),
            message: message.into(),
        }
    }

    pub(crate) fn protocol(message: impl Into<String>, code: Option<&str>) -> Self {
        Self::Protocol {
            code: code.map(str::to_owned),
            message: message.into(),
        }
    }

    pub(crate) fn auth(
        kind: AuthErrorKind,
        message: impl Into<String>,
        code: Option<String>,
    ) -> Self {
        Self::Auth {
            kind,
            code,
            message: message.into(),
        }
    }

    pub(crate) fn transport(message: impl Into<String>) -> Self {
        Self::Transport {
            message: message.into(),
        }
    }

    pub(crate) fn invalid_request(message: impl Into<String>) -> Self {
        Self::InvalidRequest {
            message: message.into(),
        }
    }

    /// The protocol `error_code` carried by this error, when there is one.
    pub fn code(&self) -> Option<&str> {
        match self {
            Self::Stream { code, .. } | Self::Protocol { code, .. } | Self::Auth { code, .. } => {
                code.as_deref()
            }
            Self::AuthRequired { .. } => Some("auth_required"),
            Self::Transport { .. } | Self::InvalidRequest { .. } => None,
        }
    }

    /// The provider this failure is attributed to, when known.
    pub fn provider_id(&self) -> Option<&str> {
        match self {
            Self::Stream { provider_id, .. } => provider_id.as_deref(),
            Self::AuthRequired { provider_id, .. } => Some(provider_id),
            _ => None,
        }
    }

    /// Whether the runtime reported that the provider needs credentials.
    ///
    /// True both for the terminal [`Error::AuthRequired`] and for the
    /// still-retryable [`Error::Stream`] form carrying `code = "auth_required"`.
    pub fn is_auth_required(&self) -> bool {
        matches!(self, Self::AuthRequired { .. }) || self.code() == Some("auth_required")
    }

    /// Whether this failure came from the caller cancelling the operation.
    pub fn is_cancelled(&self) -> bool {
        matches!(
            self,
            Self::Stream {
                kind: StreamErrorKind::Aborted,
                ..
            } | Self::Auth {
                kind: AuthErrorKind::Cancelled,
                ..
            }
        )
    }

    /// Whether this failure is an `auth_required` that has not yet been through
    /// the `auto_once` retry, i.e. one a login attempt could still clear.
    pub(crate) fn is_retryable_auth(&self) -> bool {
        matches!(self, Self::Stream { code, .. } if code.as_deref() == Some("auth_required"))
    }

    pub(crate) fn message(&self) -> &str {
        match self {
            Self::Stream { message, .. }
            | Self::AuthRequired { message, .. }
            | Self::Protocol { message, .. }
            | Self::Auth { message, .. }
            | Self::Transport { message }
            | Self::InvalidRequest { message } => message,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_required_reports_its_code_and_provider() {
        let err = Error::auth_required("anthropic", "login first");
        assert_eq!(err.code(), Some("auth_required"));
        assert_eq!(err.provider_id(), Some("anthropic"));
        assert!(err.is_auth_required());
        assert!(!err.is_retryable_auth());
    }

    #[test]
    fn retryable_auth_is_the_stream_shaped_one() {
        let err = Error::provider_stream(
            "auth_required",
            Some("auth_required".into()),
            Some("anthropic".into()),
        );
        assert!(err.is_retryable_auth());
        assert!(err.is_auth_required());
    }

    #[test]
    fn transport_errors_carry_no_code() {
        let err = Error::transport_stream("child exited");
        assert_eq!(err.code(), None);
        assert!(!err.is_auth_required());
    }

    #[test]
    fn cancellation_is_reported_for_both_domains() {
        assert!(Error::stream(StreamErrorKind::Aborted, "cancelled").is_cancelled());
        assert!(Error::auth(AuthErrorKind::Cancelled, "cancelled", None).is_cancelled());
        assert!(!Error::transport("boom").is_cancelled());
    }

    #[test]
    fn display_is_the_message() {
        let err = Error::protocol("model not found", Some("invalid_request"));
        assert_eq!(err.to_string(), "model not found");
        assert_eq!(err.code(), Some("invalid_request"));
    }
}
