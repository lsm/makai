//! The direct provider path: one request, one provider turn, no tool loop.

use std::sync::Arc;
use std::time::Duration;

use async_stream::try_stream;
use futures_core::Stream;
use serde_json::json;

use crate::auth::AuthApi;
use crate::error::{Error, Result};
use crate::events::{normalize_provider_frame, ProviderEvent, ToolCallBuffers};
use crate::execution::{provider_id_from_ref, provider_payload, ExecutionRequest};
use crate::ids::new_ulid;
use crate::transport::Transport;
use crate::types::{AuthRetryPolicy, CompletionResponse};
use crate::wire::{Envelope, Frame};

/// The provider namespace.
///
/// Cheap to clone; every clone shares one transport.
#[derive(Clone)]
pub struct ProviderApi {
    pub(crate) transport: Arc<Transport>,
    pub(crate) auth: AuthApi,
    pub(crate) auth_retry_policy: Option<AuthRetryPolicy>,
    pub(crate) response_timeout: Duration,
}

impl std::fmt::Debug for ProviderApi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderApi")
            .field("auth_retry_policy", &self.auth_retry_policy)
            .field("response_timeout", &self.response_timeout)
            .finish()
    }
}

impl ProviderApi {
    /// Runs one provider turn and waits for the whole message.
    pub async fn complete(&self, request: ExecutionRequest) -> Result<CompletionResponse> {
        request.validate()?;
        let policy = request
            .options
            .auth_retry_policy
            .or(self.auth_retry_policy)
            .unwrap_or_default();
        let fallback_provider = provider_id_from_ref(&request.model_ref);

        match self.complete_once(&request).await {
            Ok(response) => Ok(response),
            Err(error) if error.is_retryable_auth() => {
                let provider_id = error
                    .provider_id()
                    .map(str::to_owned)
                    .or_else(|| fallback_provider.clone());
                let Some(provider_id) = provider_id else {
                    return Err(error);
                };
                if policy != AuthRetryPolicy::AutoOnce {
                    return Err(Error::auth_required(
                        provider_id,
                        error.message().to_owned(),
                    ));
                }
                self.auth
                    .login(&provider_id, None)
                    .await
                    .map_err(|_| Error::auth_required(&provider_id, error.message().to_owned()))?;
                self.complete_once(&request).await.map_err(|retry_error| {
                    promote_auth_error(retry_error, Some(provider_id.clone()))
                })
            }
            Err(error) => Err(error),
        }
    }

    async fn complete_once(&self, request: &ExecutionRequest) -> Result<CompletionResponse> {
        let fallback_provider = provider_id_from_ref(&request.model_ref);
        let stream_id = new_ulid();
        let mut subscription = self.transport.subscribe_stream(&stream_id);
        let mut guard = StreamCancelGuard::new(Arc::clone(&self.transport), stream_id.clone());

        self.transport.send(&Envelope::for_stream(
            "complete_request",
            &stream_id,
            provider_payload(request, true, self.auth_retry_policy),
        ))?;

        loop {
            let frame = subscription
                .next_within(self.response_timeout, "provider complete_response")
                .await?;
            match frame.kind.as_str() {
                "ack" => continue,
                "nack" => {
                    guard.settle();
                    return Err(nack_to_error(&frame, fallback_provider.as_deref()));
                }
                "stream_error" => {
                    guard.settle();
                    return Err(frame_to_error(&frame));
                }
                "result" | "complete_response" => {
                    guard.settle();
                    return Ok(CompletionResponse::parse(frame.payload_object()?));
                }
                other => {
                    guard.settle();
                    return Err(Error::transport_stream(format!(
                        "unexpected frame type while awaiting provider result: {other}"
                    )));
                }
            }
        }
    }

    /// Runs one provider turn, yielding events as they arrive.
    ///
    /// Exactly one terminal event ends the stream:
    /// [`ProviderEvent::MessageEnd`] or [`ProviderEvent::Error`] (spec §3.5).
    /// Failures that never reach the event plane — a rejected request, a dead
    /// transport, a timeout — arrive as an `Err` item instead.
    ///
    /// Dropping the stream cancels it: the SDK sends `abort_request` for the
    /// stream, so the runtime stops the provider turn instead of finishing it
    /// into a queue nobody is reading.
    pub fn stream(
        &self,
        request: ExecutionRequest,
    ) -> impl Stream<Item = Result<ProviderEvent>> + Send + 'static {
        let this = self.clone();
        try_stream! {
            request.validate()?;
            let policy = request
                .options
                .auth_retry_policy
                .or(this.auth_retry_policy)
                .unwrap_or_default();
            let fallback_provider = provider_id_from_ref(&request.model_ref);

            let mut yielded = false;
            let mut retried = false;

            'attempt: loop {
                let stream_id = new_ulid();
                let mut subscription = this.transport.subscribe_stream(&stream_id);
                let mut guard =
                    StreamCancelGuard::new(Arc::clone(&this.transport), stream_id.clone());
                let mut buffers = ToolCallBuffers::default();

                this.transport.send(&Envelope::for_stream(
                    "stream_request",
                    &stream_id,
                    provider_payload(&request, false, this.auth_retry_policy),
                ))?;

                loop {
                    let frame = subscription
                        .next_within(this.response_timeout, "provider stream event")
                        .await?;

                    if frame.kind == "ack" {
                        continue;
                    }
                    if frame.kind == "nack" {
                        guard.settle();
                        let error = nack_to_error(&frame, fallback_provider.as_deref());
                        if !yielded && !retried && policy == AuthRetryPolicy::AutoOnce
                            && error.is_retryable_auth()
                        {
                            if let Some(provider_id) = error
                                .provider_id()
                                .map(str::to_owned)
                                .or_else(|| fallback_provider.clone())
                            {
                                this.auth.login(&provider_id, None).await.map_err(|_| {
                                    Error::auth_required(&provider_id, error.message().to_owned())
                                })?;
                                retried = true;
                                continue 'attempt;
                            }
                        }
                        Err(promote_auth_error(error, fallback_provider.clone()))?;
                        return;
                    }

                    let Some(event) = normalize_provider_frame(&frame, &mut buffers) else {
                        continue;
                    };

                    if let ProviderEvent::Error {
                        message,
                        code,
                        provider_id,
                    } = &event
                    {
                        guard.settle();
                        // An `auth_required` error event is a failure, not an
                        // event a consumer should have to inspect: it becomes
                        // the typed auth path like every other auth rejection.
                        if code.as_deref() == Some("auth_required") {
                            let error = Error::provider_stream(
                                message.clone(),
                                code.clone(),
                                provider_id.clone().or_else(|| fallback_provider.clone()),
                            );
                            if !yielded && !retried && policy == AuthRetryPolicy::AutoOnce {
                                if let Some(provider) = error.provider_id().map(str::to_owned) {
                                    this.auth.login(&provider, None).await.map_err(|_| {
                                        Error::auth_required(&provider, error.message().to_owned())
                                    })?;
                                    retried = true;
                                    continue 'attempt;
                                }
                            }
                            Err(promote_auth_error(error, fallback_provider.clone()))?;
                            return;
                        }
                        yield event;
                        return;
                    }

                    if event.is_terminal() {
                        guard.settle();
                        yield event;
                        return;
                    }

                    yielded = true;
                    yield event;
                }
            }
        }
    }
}

/// Sends `abort_request` if the stream is dropped before it settles.
pub(crate) struct StreamCancelGuard {
    transport: Arc<Transport>,
    stream_id: String,
    settled: bool,
}

impl StreamCancelGuard {
    pub(crate) fn new(transport: Arc<Transport>, stream_id: String) -> Self {
        Self {
            transport,
            stream_id,
            settled: false,
        }
    }

    pub(crate) fn settle(&mut self) {
        self.settled = true;
    }
}

impl Drop for StreamCancelGuard {
    fn drop(&mut self) {
        if self.settled {
            return;
        }
        // The abort carries sequence 2 because the request it cancels carried 1.
        // It is advisory: a request the server already rejected never advanced
        // its counter, so the abort may itself be rejected as a sequence gap —
        // which is harmless, since in that case there is nothing left to abort.
        self.transport.send_best_effort(&Envelope {
            kind: "abort_request".to_owned(),
            stream_id: Some(self.stream_id.clone()),
            session_id: None,
            message_id: new_ulid(),
            sequence: 2,
            timestamp: crate::ids::now_millis(),
            version: crate::wire::ENVELOPE_VERSION,
            in_reply_to: None,
            payload: json!({
                "target_stream_id": self.stream_id,
                "reason": "client aborted",
            }),
        });
    }
}

pub(crate) fn nack_to_error(frame: &Frame, fallback_provider: Option<&str>) -> Error {
    let code = frame.payload_non_empty("error_code");
    let mut provider_id = frame.payload_non_empty("provider_id");
    if provider_id.is_none() && code.as_deref() == Some("auth_required") {
        provider_id = fallback_provider.map(str::to_owned);
    }
    Error::provider_stream(
        frame
            .payload_non_empty("reason")
            .unwrap_or_else(|| "request rejected".to_owned()),
        code,
        provider_id,
    )
}

pub(crate) fn frame_to_error(frame: &Frame) -> Error {
    Error::provider_stream(
        frame
            .payload_non_empty("message")
            .or_else(|| frame.payload_non_empty("reason"))
            .unwrap_or_else(|| "stream error".to_owned()),
        frame
            .payload_non_empty("code")
            .or_else(|| frame.payload_non_empty("error_code")),
        frame.payload_non_empty("provider_id"),
    )
}

/// Turns a still-retryable `auth_required` into the terminal typed form once
/// the retry budget is gone.
pub(crate) fn promote_auth_error(error: Error, fallback_provider: Option<String>) -> Error {
    if !error.is_retryable_auth() {
        return error;
    }
    match error.provider_id().map(str::to_owned).or(fallback_provider) {
        Some(provider_id) => Error::auth_required(provider_id, error.message().to_owned()),
        None => error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn frame(value: Value) -> Frame {
        Frame::parse(&value.to_string()).expect("frame parses")
    }

    #[test]
    fn nacks_attribute_auth_failures_to_the_requests_provider() {
        // The shape the runtime answers an unauthenticated stream_request with.
        let error = nack_to_error(
            &frame(json!({
                "type": "nack",
                "payload": { "reason": "auth_required", "error_code": "auth_required" }
            })),
            Some("anthropic"),
        );
        assert_eq!(error.code(), Some("auth_required"));
        assert_eq!(error.provider_id(), Some("anthropic"));
        assert!(error.is_retryable_auth());
    }

    #[test]
    fn non_auth_nacks_do_not_borrow_the_fallback_provider() {
        let error = nack_to_error(
            &frame(json!({
                "type": "nack",
                "payload": { "reason": "bad filter", "error_code": "invalid_request" }
            })),
            Some("anthropic"),
        );
        assert_eq!(error.provider_id(), None);
        assert!(!error.is_retryable_auth());
    }

    #[test]
    fn nacks_without_a_reason_still_carry_a_message() {
        let error = nack_to_error(&frame(json!({ "type": "nack", "payload": {} })), None);
        assert_eq!(error.message(), "request rejected");
    }

    #[test]
    fn stream_error_frames_read_both_code_spellings() {
        let error = frame_to_error(&frame(json!({
            "type": "stream_error",
            "payload": { "message": "upstream exploded", "error_code": "provider_error", "provider_id": "openai" }
        })));
        assert_eq!(error.code(), Some("provider_error"));
        assert_eq!(error.provider_id(), Some("openai"));
        assert_eq!(error.message(), "upstream exploded");
    }

    #[test]
    fn promotion_only_touches_retryable_auth_errors() {
        let promoted = promote_auth_error(
            Error::provider_stream("auth_required", Some("auth_required".into()), None),
            Some("anthropic".to_owned()),
        );
        assert!(matches!(promoted, Error::AuthRequired { .. }));
        assert_eq!(promoted.provider_id(), Some("anthropic"));

        let untouched = promote_auth_error(
            Error::transport_stream("child exited"),
            Some("anthropic".to_owned()),
        );
        assert!(matches!(untouched, Error::Stream { .. }));

        // With no provider to attribute it to, the retryable form is kept as-is
        // rather than inventing one.
        let kept = promote_auth_error(
            Error::provider_stream("auth_required", Some("auth_required".into()), None),
            None,
        );
        assert!(matches!(kept, Error::Stream { .. }));
    }
}
