//! Provider authentication: listing auth state and running interactive logins.
//!
//! Token material stays inside the runtime. This SDK never reads
//! `~/.makai/auth.json`, never shells out to `makai auth ...`, and never hands a
//! credential back to the caller (spec §3.7).

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::error::{AuthErrorKind, Error, Result};
use crate::ids::new_ulid;
use crate::models::AuthStatus;
use crate::transport::Transport;
use crate::wire::{Envelope, Frame};

/// One provider's auth state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderAuthInfo {
    /// The provider id to pass to [`AuthApi::login`].
    pub id: String,
    /// A human-readable name.
    pub name: String,
    /// Whether its credentials are usable.
    #[serde(default = "unknown_status")]
    pub auth_status: AuthStatus,
    /// The last failure, when there was one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
}

fn unknown_status() -> AuthStatus {
    AuthStatus::Unknown
}

/// A question the login flow needs answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthPrompt {
    /// The flow this prompt belongs to.
    pub flow_id: String,
    /// Identifies the prompt within the flow; echoed back in the response.
    pub prompt_id: String,
    /// The provider being authenticated.
    pub provider_id: String,
    /// What to ask the user.
    pub message: String,
    /// Whether an empty answer is acceptable.
    pub allow_empty: bool,
}

/// Something that happened during a login flow.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum AuthEvent {
    /// A URL the user must open.
    AuthUrl {
        /// The flow this belongs to.
        flow_id: String,
        /// The provider being authenticated.
        provider_id: String,
        /// The URL to open.
        url: String,
        /// What to do once it is open.
        instructions: Option<String>,
    },
    /// The flow needs an answer. Routed to the prompt handler as well.
    Prompt(AuthPrompt),
    /// Progress detail worth showing.
    Progress {
        /// The flow this belongs to.
        flow_id: String,
        /// The provider being authenticated.
        provider_id: String,
        /// The message.
        message: String,
    },
    /// The flow succeeded.
    Success {
        /// The flow this belongs to.
        flow_id: String,
        /// The provider that was authenticated.
        provider_id: String,
    },
    /// The flow reported a failure. A terminal `auth_login_result` still follows.
    Error {
        /// The flow this belongs to.
        flow_id: String,
        /// The provider being authenticated.
        provider_id: String,
        /// The protocol error code, when supplied.
        code: Option<String>,
        /// Human-readable detail.
        message: String,
    },
}

type PromptFuture = Pin<Box<dyn Future<Output = std::result::Result<String, String>> + Send>>;
type EventCallback = Arc<dyn Fn(AuthEvent) + Send + Sync>;
type PromptCallback = Arc<dyn Fn(AuthPrompt) -> PromptFuture + Send + Sync>;

/// Callbacks that drive an interactive login.
///
/// A flow that reaches a prompt with no [`AuthHandlers::on_prompt`] is cancelled
/// rather than left hanging (spec §3.7).
#[derive(Clone, Default)]
pub struct AuthHandlers {
    on_event: Option<EventCallback>,
    on_prompt: Option<PromptCallback>,
}

impl std::fmt::Debug for AuthHandlers {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuthHandlers")
            .field("on_event", &self.on_event.is_some())
            .field("on_prompt", &self.on_prompt.is_some())
            .finish()
    }
}

impl AuthHandlers {
    /// No handlers. A flow that needs a prompt will be cancelled.
    pub fn new() -> Self {
        Self::default()
    }

    /// Observes every event in the flow.
    pub fn on_event(mut self, handler: impl Fn(AuthEvent) + Send + Sync + 'static) -> Self {
        self.on_event = Some(Arc::new(handler));
        self
    }

    /// Answers prompts. Returning `Err` aborts the flow.
    pub fn on_prompt<F, Fut>(mut self, handler: F) -> Self
    where
        F: Fn(AuthPrompt) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = std::result::Result<String, String>> + Send + 'static,
    {
        self.on_prompt = Some(Arc::new(move |prompt| Box::pin(handler(prompt))));
        self
    }

    fn has_prompt_handler(&self) -> bool {
        self.on_prompt.is_some()
    }
}

/// The auth namespace.
///
/// Cheap to clone; every clone shares one transport.
#[derive(Clone)]
pub struct AuthApi {
    transport: Arc<Transport>,
    handlers: AuthHandlers,
    frame_timeout: Duration,
}

impl std::fmt::Debug for AuthApi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuthApi")
            .field("handlers", &self.handlers)
            .field("frame_timeout", &self.frame_timeout)
            .finish()
    }
}

impl AuthApi {
    pub(crate) fn new(
        transport: Arc<Transport>,
        handlers: AuthHandlers,
        frame_timeout: Duration,
    ) -> Self {
        Self {
            transport,
            handlers,
            frame_timeout,
        }
    }

    /// Lists every provider the runtime knows about, with its auth state.
    pub async fn list_providers(&self) -> Result<Vec<ProviderAuthInfo>> {
        let stream_id = new_ulid();
        let mut subscription = self.transport.subscribe_stream(&stream_id);
        self.transport
            .send(&Envelope::for_stream(
                "auth_providers_request",
                &stream_id,
                json!({}),
            ))
            .map_err(to_auth_error)?;

        loop {
            let frame = subscription
                .next_within(self.frame_timeout, "auth_providers_response")
                .await
                .map_err(to_auth_error)?;
            match frame.kind.as_str() {
                "ack" => continue,
                "nack" => return Err(nack_to_auth_error(&frame)),
                "auth_providers_response" => return parse_providers(&frame),
                other => {
                    let detail = format!(
                        "unexpected envelope type while awaiting auth_providers_response: {other}"
                    );
                    return Err(Error::auth(AuthErrorKind::TransportError, detail, None));
                }
            }
        }
    }

    /// Runs an interactive login for `provider_id`.
    ///
    /// `handlers` overrides the client-level handlers for this call; passing
    /// `None` uses the client's (spec §3.7's normative handler resolution order).
    ///
    /// Returns once the runtime sends a terminal `auth_login_result`. Dropping
    /// the returned future cancels the flow: the SDK sends `auth_cancel` so the
    /// runtime does not leave an OAuth listener running.
    pub async fn login(&self, provider_id: &str, handlers: Option<&AuthHandlers>) -> Result<()> {
        let handlers = handlers.unwrap_or(&self.handlers).clone();
        let flow_id = new_ulid();
        let mut subscription = self.transport.subscribe_stream(&flow_id);
        let mut sequence = 1u64;

        let mut guard = LoginGuard {
            transport: Arc::clone(&self.transport),
            flow_id: flow_id.clone(),
            sequence,
            settled: false,
        };

        self.transport
            .send(&Envelope::for_flow(
                "auth_login_start",
                &flow_id,
                next(&mut sequence),
                json!({ "provider_id": provider_id }),
            ))
            .map_err(|err| {
                guard.settled = true;
                to_auth_error(err)
            })?;
        guard.sequence = sequence;

        let mut last_error: Option<(Option<String>, String)> = None;
        let mut cancelled_for_missing_handler = false;

        loop {
            let frame = match subscription
                .next_within(self.frame_timeout, "auth_login_result/auth_event")
                .await
            {
                Ok(frame) => frame,
                Err(err) => return Err(to_auth_error(err)),
            };

            match frame.kind.as_str() {
                "ack" => continue,
                "nack" => {
                    guard.settled = true;
                    return Err(nack_to_auth_error(&frame));
                }
                "auth_event" => {
                    let event = parse_auth_event(&frame)?;
                    if let Some(callback) = &handlers.on_event {
                        callback(event.clone());
                    }
                    match event {
                        AuthEvent::Error { code, message, .. } => {
                            last_error = Some((code, message));
                        }
                        AuthEvent::Prompt(prompt) => {
                            if !handlers.has_prompt_handler() {
                                // Spec §3.7: fail fast rather than stall on a
                                // question nobody can answer. The cancel is
                                // sent and the flow's tail drained, but the
                                // outcome is decided here: a provider whose
                                // flow re-prompts in a loop must not be able to
                                // keep this call alive.
                                cancelled_for_missing_handler = true;
                                self.cancel(&flow_id, next(&mut sequence));
                                guard.settled = true;
                                self.drain_login_result(&mut subscription).await;
                                return finish_login(
                                    Some("cancelled"),
                                    last_error,
                                    cancelled_for_missing_handler,
                                );
                            }
                            let answer = match &handlers.on_prompt {
                                Some(handler) => handler(prompt.clone()).await,
                                None => Err("no prompt handler".to_owned()),
                            };
                            match answer {
                                Ok(answer) => {
                                    self.transport
                                        .send(&Envelope::for_flow(
                                            "auth_prompt_response",
                                            &flow_id,
                                            next(&mut sequence),
                                            json!({
                                                "flow_id": flow_id,
                                                "prompt_id": prompt.prompt_id,
                                                "answer": answer,
                                            }),
                                        ))
                                        .map_err(|err| {
                                            guard.settled = true;
                                            to_auth_error(err)
                                        })?;
                                    guard.sequence = sequence;
                                }
                                Err(reason) => {
                                    self.cancel(&flow_id, next(&mut sequence));
                                    guard.settled = true;
                                    self.drain_login_result(&mut subscription).await;
                                    return Err(Error::auth(AuthErrorKind::Unknown, reason, None));
                                }
                            }
                        }
                        _ => {}
                    }
                }
                "auth_login_result" => {
                    guard.settled = true;
                    return finish_login(
                        frame.payload_str("status"),
                        last_error,
                        cancelled_for_missing_handler,
                    );
                }
                other => {
                    guard.settled = true;
                    return Err(Error::auth(
                        AuthErrorKind::TransportError,
                        format!("unexpected envelope type during login flow: {other}"),
                        None,
                    ));
                }
            }
        }
    }

    fn cancel(&self, flow_id: &str, sequence: u64) {
        self.transport.send_best_effort(&Envelope::for_flow(
            "auth_cancel",
            flow_id,
            sequence,
            json!({ "flow_id": flow_id }),
        ));
    }

    /// Consumes frames until the terminal result, so the flow's tail does not
    /// outlive the call that abandoned it. Bounded: a runtime that keeps talking
    /// must not keep this call alive indefinitely.
    async fn drain_login_result(&self, subscription: &mut crate::transport::Subscription) {
        let deadline = tokio::time::Instant::now() + Duration::from_millis(500);
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return;
            }
            match subscription
                .next_within(remaining, "auth_login_result")
                .await
            {
                Ok(frame) if frame.kind == "auth_login_result" => return,
                Ok(_) => continue,
                Err(_) => return,
            }
        }
    }
}

/// Cancels an abandoned login flow when the future driving it is dropped.
///
/// `sequence` tracks the flow's next outbound value and is advanced after
/// every send. A stale value would be rejected as a duplicate sequence, and
/// the runtime would leave the flow and its OAuth listener running.
struct LoginGuard {
    transport: Arc<Transport>,
    flow_id: String,
    sequence: u64,
    settled: bool,
}

impl Drop for LoginGuard {
    fn drop(&mut self) {
        if self.settled {
            return;
        }
        self.transport.send_best_effort(&Envelope::for_flow(
            "auth_cancel",
            &self.flow_id,
            self.sequence,
            json!({ "flow_id": self.flow_id }),
        ));
    }
}

fn next(sequence: &mut u64) -> u64 {
    let value = *sequence;
    *sequence += 1;
    value
}

fn finish_login(
    status: Option<&str>,
    last_error: Option<(Option<String>, String)>,
    cancelled_for_missing_handler: bool,
) -> Result<()> {
    match status {
        Some("success") => Ok(()),
        Some("cancelled") => {
            let (code, message) = last_error.unzip_or_else(|| {
                if cancelled_for_missing_handler {
                    "auth login cancelled (no prompt handler configured)".to_owned()
                } else {
                    "auth login cancelled".to_owned()
                }
            });
            Err(Error::auth(AuthErrorKind::Cancelled, message, code))
        }
        Some("failed") => {
            let (code, message) = last_error.unzip_or_else(|| "auth login failed".to_owned());
            Err(Error::auth(AuthErrorKind::ProviderError, message, code))
        }
        other => Err(Error::auth(
            AuthErrorKind::Unknown,
            format!(
                "unexpected auth_login_result status: {}",
                other.unwrap_or("<missing>")
            ),
            None,
        )),
    }
}

/// Small helper so the two terminal branches read the same way.
trait UnzipOrElse {
    fn unzip_or_else(self, fallback: impl FnOnce() -> String) -> (Option<String>, String);
}

impl UnzipOrElse for Option<(Option<String>, String)> {
    fn unzip_or_else(self, fallback: impl FnOnce() -> String) -> (Option<String>, String) {
        match self {
            Some((code, message)) => (code, message),
            None => (None, fallback()),
        }
    }
}

fn to_auth_error(error: Error) -> Error {
    match error {
        Error::Auth { .. } => error,
        other => Error::auth(
            AuthErrorKind::TransportError,
            other.message().to_owned(),
            other.code().map(str::to_owned),
        ),
    }
}

fn nack_to_auth_error(frame: &Frame) -> Error {
    Error::auth(
        AuthErrorKind::TransportError,
        frame
            .payload_non_empty("reason")
            .unwrap_or_else(|| "transport nack".to_owned()),
        frame.payload_non_empty("error_code"),
    )
}

fn parse_providers(frame: &Frame) -> Result<Vec<ProviderAuthInfo>> {
    #[derive(Deserialize)]
    struct Payload {
        providers: Vec<serde_json::Value>,
    }
    let payload: Payload = serde_json::from_value(frame.payload().clone()).map_err(|_| {
        Error::auth(
            AuthErrorKind::TransportError,
            "auth_providers_response payload missing providers array",
            None,
        )
    })?;

    payload
        .providers
        .iter()
        .enumerate()
        .map(|(index, raw)| {
            // An unknown `auth_status` degrades to `unknown` rather than failing
            // the whole listing: V1 evolution is additive-only and a new status
            // must not make the call unusable.
            let mut raw = raw.clone();
            let unknown_status = raw.get("auth_status").is_some_and(|status| {
                serde_json::from_value::<AuthStatus>(status.clone()).is_err()
            });
            if unknown_status {
                if let Some(object) = raw.as_object_mut() {
                    object.insert("auth_status".to_owned(), json!("unknown"));
                }
            }
            serde_json::from_value::<ProviderAuthInfo>(raw).map_err(|err| {
                Error::auth(
                    AuthErrorKind::TransportError,
                    format!("provider entry at index {index} is malformed: {err}"),
                    None,
                )
            })
        })
        .collect()
}

/// Flattens the `{ "<variant>": { ... } }` payload the auth protocol uses.
pub(crate) fn parse_auth_event(frame: &Frame) -> Result<AuthEvent> {
    let payload = frame.payload();
    for variant in ["auth_url", "prompt", "progress", "success", "error"] {
        let Some(data) = payload.get(variant).filter(|value| value.is_object()) else {
            continue;
        };
        let flow_id = required_string(data, "flow_id")?;
        let provider_id = required_string(data, "provider_id")?;
        return Ok(match variant {
            "auth_url" => AuthEvent::AuthUrl {
                flow_id,
                provider_id,
                url: required_string(data, "url")?,
                instructions: crate::wire::opt_string(data, "instructions"),
            },
            "prompt" => AuthEvent::Prompt(AuthPrompt {
                flow_id,
                prompt_id: required_string(data, "prompt_id")?,
                provider_id,
                message: required_string(data, "message")?,
                allow_empty: data
                    .get("allow_empty")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
            }),
            "progress" => AuthEvent::Progress {
                flow_id,
                provider_id,
                message: required_string(data, "message")?,
            },
            "success" => AuthEvent::Success {
                flow_id,
                provider_id,
            },
            _ => AuthEvent::Error {
                flow_id,
                provider_id,
                code: crate::wire::opt_string(data, "code"),
                message: required_string(data, "message")?,
            },
        });
    }
    Err(Error::auth(
        AuthErrorKind::Unknown,
        format!("unknown auth_event variant: {payload}"),
        None,
    ))
}

fn required_string(data: &serde_json::Value, key: &str) -> Result<String> {
    data.get(key)
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| {
            Error::auth(
                AuthErrorKind::TransportError,
                format!("auth_event field \"{key}\" missing or not a string"),
                None,
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn frame(value: Value) -> Frame {
        Frame::parse(&value.to_string()).expect("frame parses")
    }

    #[test]
    fn provider_listings_parse() {
        let providers = parse_providers(&frame(json!({
            "type": "auth_providers_response",
            "payload": { "providers": [
                { "id": "anthropic", "name": "Anthropic", "auth_status": "login_required" },
                { "id": "openai-codex", "name": "OpenAI Codex", "auth_status": "authenticated" },
            ]}
        })))
        .expect("parses");
        assert_eq!(providers.len(), 2);
        assert_eq!(providers[0].auth_status, AuthStatus::LoginRequired);
        assert_eq!(providers[1].auth_status, AuthStatus::Authenticated);
        assert_eq!(providers[0].last_error, None);
    }

    #[test]
    fn unknown_auth_statuses_degrade_rather_than_fail() {
        let providers = parse_providers(&frame(json!({
            "type": "auth_providers_response",
            "payload": { "providers": [{ "id": "x", "name": "X", "auth_status": "brand_new" }] }
        })))
        .expect("parses");
        assert_eq!(providers[0].auth_status, AuthStatus::Unknown);
    }

    #[test]
    fn provider_entries_missing_required_fields_are_rejected() {
        let result = parse_providers(&frame(json!({
            "type": "auth_providers_response",
            "payload": { "providers": [{ "name": "no id" }] }
        })));
        assert!(result.is_err());

        let result = parse_providers(&frame(json!({
            "type": "auth_providers_response",
            "payload": { "nope": [] }
        })));
        assert!(result.is_err());
    }

    #[test]
    fn auth_events_flatten_from_their_variant_key() {
        let event = parse_auth_event(&frame(json!({
            "type": "auth_event",
            "payload": { "prompt": {
                "flow_id": "F", "prompt_id": "prompt-1", "provider_id": "test-fixture",
                "message": "Enter fixture code:", "allow_empty": false
            }}
        })))
        .expect("parses");
        assert_eq!(
            event,
            AuthEvent::Prompt(AuthPrompt {
                flow_id: "F".to_owned(),
                prompt_id: "prompt-1".to_owned(),
                provider_id: "test-fixture".to_owned(),
                message: "Enter fixture code:".to_owned(),
                allow_empty: false,
            })
        );
    }

    #[test]
    fn auth_url_events_carry_optional_instructions() {
        let event = parse_auth_event(&frame(json!({
            "type": "auth_event",
            "payload": { "auth_url": {
                "flow_id": "F", "provider_id": "p", "url": "https://example.invalid/login"
            }}
        })))
        .expect("parses");
        match event {
            AuthEvent::AuthUrl { instructions, .. } => assert_eq!(instructions, None),
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn unknown_auth_event_variants_are_errors() {
        let result = parse_auth_event(&frame(json!({
            "type": "auth_event",
            "payload": { "teleport": { "flow_id": "F" } }
        })));
        assert!(result.is_err());
    }

    #[test]
    fn auth_events_missing_required_fields_are_errors() {
        let result = parse_auth_event(&frame(json!({
            "type": "auth_event",
            "payload": { "progress": { "flow_id": "F", "provider_id": "p" } }
        })));
        assert!(result.is_err());
    }

    #[test]
    fn terminal_statuses_map_to_the_right_error_kinds() {
        assert!(finish_login(Some("success"), None, false).is_ok());

        let err = finish_login(Some("cancelled"), None, true).unwrap_err();
        assert!(err.is_cancelled());
        assert!(err.message().contains("no prompt handler"), "{err}");

        let err = finish_login(
            Some("failed"),
            Some((Some("auth_expired".into()), "token expired".into())),
            false,
        )
        .unwrap_err();
        assert_eq!(err.code(), Some("auth_expired"));
        assert_eq!(err.message(), "token expired");

        let err = finish_login(Some("teleported"), None, false).unwrap_err();
        assert!(
            err.message().contains("unexpected auth_login_result"),
            "{err}"
        );

        let err = finish_login(None, None, false).unwrap_err();
        assert!(err.message().contains("<missing>"), "{err}");
    }

    #[test]
    fn the_terminal_error_event_wins_over_the_generic_message() {
        // Spec §8: capture the terminal `auth_event.error` and propagate it.
        let err = finish_login(
            Some("cancelled"),
            Some((Some("user_declined".into()), "user declined".into())),
            false,
        )
        .unwrap_err();
        assert_eq!(err.message(), "user declined");
        assert_eq!(err.code(), Some("user_declined"));
    }

    #[test]
    fn nacks_become_transport_auth_errors() {
        let err = nack_to_auth_error(&frame(json!({
            "type": "nack",
            "payload": { "reason": "bad flow", "error_code": "invalid_request" }
        })));
        assert_eq!(err.code(), Some("invalid_request"));
        assert_eq!(err.message(), "bad flow");
    }
}
