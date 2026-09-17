//! The agent path: a multi-turn loop with client-side tool execution.
//!
//! # Session lifecycle
//!
//! One call owns one session. The exchange is `agent_start` (inbound sequence 1)
//! → `agent_started` → `agent_message` (sequence 2) → run output → settlement,
//! then `agent_stop` carrying the next expected sequence. Sequences are per
//! session and per direction and start at 1 (spec §13.1); tool-result replies do
//! not consume one.
//!
//! `session_id` is a correlation key, not a resume handle: sessions are not
//! resumable and this SDK exposes no way to rejoin one (spec §13.5).
//!
//! # Teardown ownership
//!
//! Spec §6.1 makes teardown client-owned but bounds it by ownership: a client
//! must not stop a session its own `agent_start` did not establish. This SDK
//! follows the `[current — #205]` rule:
//!
//! * a client-generated `session_id` is always safe to stop — no other caller
//!   could have supplied it;
//! * a caller-supplied id is stopped only once a reply correlated to *this*
//!   attempt's `agent_start` has been seen;
//! * a start rejected with `agent_busy` is never stopped: the id belongs to
//!   another live run.
//!
//! # Tool execution
//!
//! Tools run in this process. The runtime publishes `tool_execute` on the
//! session route and waits for the correlated `tool_result`; a [`crate::Tool`]
//! with no handler answers with an error result rather than stalling the loop.

use std::sync::Arc;
use std::time::Duration;

use async_stream::try_stream;
use futures_core::Stream;
use serde_json::json;

use crate::auth::AuthApi;
use crate::error::{Error, Result};
use crate::events::{
    normalize_agent_frame, response_from_events, AgentEvent, ProviderEvent, ToolCallBuffers,
};
use crate::execution::{
    agent_message_payload, agent_start_payload, is_auth_failure_message, provider_id_from_ref,
    ExecutionRequest,
};
use crate::ids::new_session_id;
use crate::models::ModelsApi;
use crate::provider::{frame_to_error, nack_to_error, promote_auth_error};
use crate::transport::{Subscription, Transport};
use crate::types::{AuthRetryPolicy, CompletionResponse, ToolInvocation, Usage};
use crate::wire::{Envelope, Frame};

/// How long the SDK waits for the tail of a settled session before giving up.
const DRAIN_BUDGET: Duration = Duration::from_millis(250);

/// The agent namespace.
///
/// Cheap to clone; every clone shares one transport.
#[derive(Clone)]
pub struct AgentApi {
    pub(crate) transport: Arc<Transport>,
    pub(crate) auth: AuthApi,
    pub(crate) auth_retry_policy: Option<AuthRetryPolicy>,
    pub(crate) response_timeout: Duration,
    pub(crate) models: ModelsApi,
}

impl std::fmt::Debug for AgentApi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AgentApi")
            .field("auth_retry_policy", &self.auth_retry_policy)
            .field("response_timeout", &self.response_timeout)
            .finish()
    }
}

/// Tracks what this attempt is allowed to tear down, and with which sequence.
struct SessionGuard {
    transport: Arc<Transport>,
    session_id: String,
    /// The session's next expected inbound sequence.
    next_sequence: u64,
    /// True when the caller did not supply the id, making it exclusively ours.
    id_client_generated: bool,
    /// True once a reply correlated to our own `agent_start` has arrived.
    start_reply_observed: bool,
    /// True once the session has been stopped, or must never be stopped.
    settled: bool,
    /// The sequence to stop with while the `agent_message` is still unresolved:
    /// a message the server has not admitted has not advanced its counter.
    /// Cleared once admission is known either way.
    unresolved_sequence: Option<u64>,
}

impl SessionGuard {
    fn new(transport: Arc<Transport>, session_id: String, id_client_generated: bool) -> Self {
        Self {
            transport,
            session_id,
            next_sequence: 2,
            id_client_generated,
            start_reply_observed: false,
            settled: true,
            unresolved_sequence: None,
        }
    }

    /// Arms the guard. Called once `agent_start` is on the wire.
    fn arm(&mut self) {
        self.settled = false;
    }

    /// Marks the session as one we must never stop: either it is already gone,
    /// or it was never ours (`agent_busy`).
    fn abandon(&mut self) {
        self.settled = true;
    }

    fn may_stop(&self) -> bool {
        !self.settled && (self.id_client_generated || self.start_reply_observed)
    }

    fn stop_envelope(&self, reason: &str) -> Envelope {
        Envelope::for_session(
            "agent_stop",
            &self.session_id,
            self.next_sequence,
            json!({ "session_id": self.session_id, "reason": reason }),
        )
    }

    /// Stops the session and returns the `agent_stop` envelope's `message_id`,
    /// so the caller can drain until the correlated `agent_stopped`.
    fn stop(&mut self, reason: &str) -> Option<String> {
        if !self.may_stop() {
            self.settled = true;
            return None;
        }
        self.settled = true;
        let envelope = self.stop_envelope(reason);
        let message_id = envelope.message_id.clone();
        self.transport.send_best_effort(&envelope);
        Some(message_id)
    }
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        // A `Drop` cannot await, so it cannot read the reply that tells the
        // terminal path which sequence was right. Where admission is still
        // unresolved it sends both candidates rather than guessing one: the
        // server answers the wrong one with `invalid_request` and leaves the
        // session untouched, so the pair costs one ignored error frame and
        // stops the session whichever way admission actually went.
        let post_send = self.next_sequence;
        match self.unresolved_sequence.take() {
            Some(pre_send) if pre_send != post_send => {
                self.next_sequence = pre_send;
                if self.stop("client aborted").is_some() {
                    self.settled = false;
                    self.next_sequence = post_send;
                    self.stop("client aborted");
                }
            }
            _ => {
                self.stop("client aborted");
            }
        }
    }
}

impl AgentApi {
    /// Model discovery over the same transport, for chaining with a run.
    ///
    /// The same API as [`crate::Client::models`], reached through this
    /// namespace; the two return identical results.
    pub fn models(&self) -> ModelsApi {
        self.models.clone()
    }

    /// Runs the agent loop to completion and returns the final assistant message.
    pub async fn run(&self, request: ExecutionRequest) -> Result<CompletionResponse> {
        request.validate()?;
        let policy = request
            .options
            .auth_retry_policy
            .or(self.auth_retry_policy)
            .unwrap_or_default();
        let fallback_provider = provider_id_from_ref(&request.model_ref);

        let caller_session_id = request.options.session_id.clone();
        match self.run_once(&request, caller_session_id.clone()).await {
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
                // The first attempt's session was stopped on the way out, and a
                // stopped id is rejected on reuse, so the retry runs under a
                // fresh one. Callers who pinned a `session_id` do not keep it
                // across the retry; it is a correlation key, not an identity.
                self.run_once(&request, None)
                    .await
                    .map_err(|retry_error| promote_auth_error(retry_error, Some(provider_id)))
            }
            Err(error) => Err(error),
        }
    }

    async fn run_once(
        &self,
        request: &ExecutionRequest,
        caller_session_id: Option<String>,
    ) -> Result<CompletionResponse> {
        let fallback_provider = provider_id_from_ref(&request.model_ref);
        let id_client_generated = caller_session_id.is_none();
        let session_id = caller_session_id.unwrap_or_else(new_session_id);

        let mut session = AgentSession::start(
            Arc::clone(&self.transport),
            session_id,
            id_client_generated,
            request,
            self.auth_retry_policy,
        )?;

        let mut events: Vec<AgentEvent> = Vec::new();
        let mut buffers = ToolCallBuffers::default();
        let mut tools_executed = false;

        loop {
            let frame = match session
                .subscription
                .next_within(self.response_timeout, "agent result")
                .await
            {
                Ok(frame) => frame,
                Err(error) => {
                    // A run that never settled leaves the `agent_message`
                    // unresolved, which is exactly the case the stop probe
                    // exists for: the server may still be expecting sequence 2.
                    session.teardown("completed").await;
                    return Err(error);
                }
            };

            match session.classify(&frame) {
                FrameAction::Ignore => continue,
                FrameAction::Rejected(error) => {
                    session.finish_without_stop();
                    return Err(retryable_or_auth_error(
                        error,
                        fallback_provider.clone(),
                        !tools_executed,
                    ));
                }
                FrameAction::Failed(error) => {
                    session.teardown("completed").await;
                    return Err(retryable_or_auth_error(
                        error,
                        fallback_provider.clone(),
                        !tools_executed,
                    ));
                }
                FrameAction::Started => {
                    session.send_message(request, self.auth_retry_policy)?;
                    continue;
                }
                FrameAction::ToolExecute => {
                    session.mark_message_settled();
                    let reply = execute_tool(&frame, request).await;
                    self.transport.send(&reply)?;
                    tools_executed = true;
                    continue;
                }
                FrameAction::Result => {
                    session.mark_message_settled();
                    let result = frame.payload_json_string("result_json")?;
                    let response = CompletionResponse::parse_agent_result(&result);
                    session.teardown("completed").await;
                    return response_or_auth_error(
                        response,
                        fallback_provider.clone(),
                        !tools_executed,
                    );
                }
                FrameAction::ProviderResult => {
                    session.mark_message_settled();
                    let response = CompletionResponse::parse(frame.payload_object()?);
                    session.teardown("completed").await;
                    return response_or_auth_error(
                        response,
                        fallback_provider.clone(),
                        !tools_executed,
                    );
                }
                FrameAction::Normalize => {
                    let normalized = match normalize_agent_frame(&frame, &mut buffers) {
                        Ok(normalized) => normalized,
                        Err(error) => {
                            session.teardown("completed").await;
                            return Err(error);
                        }
                    };
                    if normalized.is_empty() {
                        continue;
                    }
                    session.mark_message_settled();
                    for event in normalized {
                        if let AgentEvent::Provider(ProviderEvent::Error {
                            message,
                            code,
                            provider_id,
                        }) = &event
                        {
                            session.teardown("completed").await;
                            return Err(retryable_or_auth_error(
                                Error::provider_stream(
                                    message.clone(),
                                    code.clone(),
                                    provider_id.clone(),
                                ),
                                fallback_provider.clone(),
                                !tools_executed,
                            ));
                        }
                        if matches!(
                            event,
                            AgentEvent::ToolExecutionStart { .. }
                                | AgentEvent::ToolExecutionEnd { .. }
                        ) {
                            tools_executed = true;
                        }
                        let terminal = matches!(event, AgentEvent::AgentEnd { .. });
                        events.push(event);
                        if terminal {
                            let response = response_from_events(&events);
                            session.teardown("completed").await;
                            return response_or_auth_error(
                                response,
                                fallback_provider.clone(),
                                !tools_executed,
                            );
                        }
                    }
                }
            }
        }
    }

    /// Runs the agent loop, yielding events as they arrive.
    ///
    /// The run ends with exactly one terminal event: [`AgentEvent::AgentEnd`],
    /// or a [`ProviderEvent::Error`] wrapped in [`AgentEvent::Provider`]
    /// (spec §3.5). Failures outside the event plane arrive as an `Err` item.
    ///
    /// Dropping the stream cancels the run: the SDK sends `agent_stop`, so the
    /// runtime stops the loop rather than running it out against a queue nobody
    /// is reading.
    pub fn stream(
        &self,
        request: ExecutionRequest,
    ) -> impl Stream<Item = Result<AgentEvent>> + Send + 'static {
        let this = self.clone();
        try_stream! {
            request.validate()?;
            let policy = request
                .options
                .auth_retry_policy
                .or(this.auth_retry_policy)
                .unwrap_or_default();
            let fallback_provider = provider_id_from_ref(&request.model_ref);

            let mut caller_session_id = request.options.session_id.clone();
            let mut yielded_content = false;
            let mut retried = false;

            'attempt: loop {
                let id_client_generated = caller_session_id.is_none();
                let session_id = caller_session_id
                    .clone()
                    .unwrap_or_else(new_session_id);
                let mut session = AgentSession::start(
                    Arc::clone(&this.transport),
                    session_id.clone(),
                    id_client_generated,
                    &request,
                    this.auth_retry_policy,
                )?;

                let mut buffers = ToolCallBuffers::default();
                let mut emitted_agent_start = false;
                let mut aggregate_usage: Option<Usage> = None;

                loop {
                    let frame = session
                        .subscription
                        .next_within(this.response_timeout, "agent stream event")
                        .await?;

                    let action = session.classify(&frame);
                    let failure = match action {
                        FrameAction::Ignore => continue,
                        FrameAction::Started => {
                            session.send_message(&request, this.auth_retry_policy)?;
                            continue;
                        }
                        FrameAction::ToolExecute => {
                            session.mark_message_settled();
                            let reply = execute_tool(&frame, &request).await;
                            this.transport.send(&reply)?;
                            continue;
                        }
                        FrameAction::Rejected(error) => {
                            session.finish_without_stop();
                            Some(error)
                        }
                        FrameAction::Failed(error) => {
                            session.finish_without_stop();
                            Some(error)
                        }
                        FrameAction::Result | FrameAction::ProviderResult | FrameAction::Normalize => None,
                    };

                    if let Some(error) = failure {
                        if !yielded_content
                            && !retried
                            && policy == AuthRetryPolicy::AutoOnce
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
                                caller_session_id = None;
                                continue 'attempt;
                            }
                        }
                        Err(promote_auth_error(error, fallback_provider.clone()))?;
                        return;
                    }

                    session.mark_message_settled();
                    let normalized = normalize_agent_frame(&frame, &mut buffers)?;
                    for mut event in normalized {
                        if let AgentEvent::Provider(ProviderEvent::Error { code, message, provider_id }) = &event {
                            if code.as_deref() == Some("auth_required") {
                                let error = Error::provider_stream(
                                    message.clone(),
                                    code.clone(),
                                    provider_id.clone().or_else(|| fallback_provider.clone()),
                                );
                                session.finish_without_stop();
                                if !yielded_content && !retried && policy == AuthRetryPolicy::AutoOnce {
                                    if let Some(provider) = error.provider_id().map(str::to_owned) {
                                        this.auth.login(&provider, None).await.map_err(|_| {
                                            Error::auth_required(&provider, error.message().to_owned())
                                        })?;
                                        retried = true;
                                        caller_session_id = None;
                                        continue 'attempt;
                                    }
                                }
                                Err(promote_auth_error(error, fallback_provider.clone()))?;
                                return;
                            }
                        }

                        if !emitted_agent_start {
                            emitted_agent_start = true;
                            if !matches!(event, AgentEvent::AgentStart { .. }) {
                                yield AgentEvent::AgentStart {
                                    session_id: Some(session_id.clone()),
                                };
                            }
                        }

                        if let AgentEvent::Provider(ProviderEvent::MessageEnd {
                            usage: Some(usage),
                            ..
                        }) = &event
                        {
                            aggregate_usage = Some(match aggregate_usage {
                                Some(total) => total.saturating_add(*usage),
                                None => *usage,
                            });
                        }

                        if let AgentEvent::AgentEnd {
                            usage,
                            stop_reason,
                            error_message,
                            api,
                            provider_id,
                        } = &mut event
                        {
                            // Spec §3.5: aggregate usage sums the turns. The
                            // terminal payload commonly carries the final
                            // turn's usage, so the accumulated total wins
                            // whenever there is one; the payload's value is
                            // only used for a run that produced no message_end.
                            if aggregate_usage.is_some() {
                                *usage = aggregate_usage;
                            }
                            if stop_reason.as_deref() == Some("error")
                                && is_auth_failure_message(error_message.as_deref(), api.as_deref())
                            {
                                let resolved = provider_id.clone().or_else(|| fallback_provider.clone());
                                let error = Error::provider_stream(
                                    error_message.clone().unwrap_or_else(|| "auth_required".to_owned()),
                                    Some("auth_required".to_owned()),
                                    resolved,
                                );
                                session.teardown("completed").await;
                                if !yielded_content && !retried && policy == AuthRetryPolicy::AutoOnce {
                                    if let Some(provider) = error.provider_id().map(str::to_owned) {
                                        this.auth.login(&provider, None).await.map_err(|_| {
                                            Error::auth_required(&provider, error.message().to_owned())
                                        })?;
                                        retried = true;
                                        caller_session_id = None;
                                        continue 'attempt;
                                    }
                                }
                                Err(promote_auth_error(error, fallback_provider.clone()))?;
                                return;
                            }
                        }

                        if !event.is_replayable() {
                            yielded_content = true;
                        }
                        if event.is_terminal() {
                            // Teardown has to happen before the yield: a
                            // consumer that breaks on the terminal event drops
                            // the generator at this suspension point, and the
                            // drop guard only sends a fire-and-forget
                            // agent_stop with reason "client aborted" and
                            // never drains the tail. A promptly reused session
                            // id would then pick up the trailing frame as its
                            // own first event.
                            session.teardown("completed").await;
                            yield event;
                            return;
                        }
                        yield event;
                    }
                }
            }
        }
    }
}

/// What to do with an inbound frame.
enum FrameAction {
    /// Not ours, or carries nothing.
    Ignore,
    /// The runtime accepted `agent_start`.
    Started,
    /// The request was rejected; the session was never established.
    Rejected(Error),
    /// The run failed after admission.
    Failed(Error),
    /// The loop wants a tool run.
    ToolExecute,
    /// `agent_result`: the run settled.
    Result,
    /// A provider-shaped settlement on the agent route.
    ProviderResult,
    /// An ordinary event frame.
    Normalize,
}

/// One agent session, from `agent_start` to teardown.
struct AgentSession {
    transport: Arc<Transport>,
    subscription: Subscription,
    guard: SessionGuard,
    session_id: String,
    start_message_id: String,
    message_message_id: Option<String>,
    start_accepted: bool,
}

impl AgentSession {
    fn start(
        transport: Arc<Transport>,
        session_id: String,
        id_client_generated: bool,
        request: &ExecutionRequest,
        _policy: Option<AuthRetryPolicy>,
    ) -> Result<Self> {
        let mut subscription = transport.subscribe_session(&session_id);
        let start = Envelope::for_session(
            "agent_start",
            &session_id,
            1,
            agent_start_payload(request, &session_id),
        );
        let start_message_id = start.message_id.clone();
        subscription.correlate(&start_message_id);

        // Losing the session route means another live run already holds this
        // caller-supplied id. That run's `agent_start` established it, not ours,
        // so this attempt must never stop it (spec §6.1) — it will receive its
        // own correlated `agent_busy` and nothing else.
        let owns_session = subscription.owns_session();
        let mut guard = SessionGuard::new(
            Arc::clone(&transport),
            session_id.clone(),
            id_client_generated && owns_session,
        );
        transport.send(&start)?;
        if owns_session {
            guard.arm();
        }

        Ok(Self {
            transport,
            subscription,
            guard,
            session_id,
            start_message_id,
            message_message_id: None,
            start_accepted: false,
        })
    }

    fn classify(&mut self, frame: &Frame) -> FrameAction {
        if frame.kind == "ack" || frame.kind == "agent_stopped" {
            return FrameAction::Ignore;
        }

        if !self.start_accepted {
            // Until the start is accepted, only a reply to *our* `agent_start`
            // belongs to this attempt. A reply naming another request is
            // somebody else's; an uncorrelated session-scoped frame is stale
            // output from a previous run on this id, because our own run output
            // cannot begin before `agent_message` is even sent.
            if frame.in_reply_to.as_deref() != Some(&self.start_message_id) {
                return FrameAction::Ignore;
            }
            self.guard.start_reply_observed = true;
        }

        match frame.kind.as_str() {
            "agent_started" => {
                self.start_accepted = true;
                FrameAction::Started
            }
            "nack" | "agent_error" => {
                let error = if frame.kind == "nack" {
                    nack_to_error(frame, None)
                } else {
                    frame_to_error(frame)
                };
                if self.message_message_id.is_some() && frame.in_reply_to == self.message_message_id
                {
                    // A rejected message never advanced the server's counter.
                    self.rollback_message_sequence();
                }
                if error.code() == Some("agent_busy") {
                    // The id belongs to another live run; stopping it would
                    // destroy that run (spec §6.1).
                    self.guard.abandon();
                }
                if self.start_accepted {
                    FrameAction::Failed(error)
                } else {
                    FrameAction::Rejected(error)
                }
            }
            "tool_execute" => FrameAction::ToolExecute,
            "agent_result" => FrameAction::Result,
            "result" | "complete_response" => FrameAction::ProviderResult,
            _ => FrameAction::Normalize,
        }
    }

    fn send_message(
        &mut self,
        request: &ExecutionRequest,
        policy: Option<AuthRetryPolicy>,
    ) -> Result<()> {
        if self.message_message_id.is_some() {
            return Ok(());
        }
        let message = Envelope::for_session(
            "agent_message",
            &self.session_id,
            2,
            agent_message_payload(request, &self.session_id, policy),
        );
        let message_id = message.message_id.clone();
        self.subscription.uncorrelate(&self.start_message_id);
        self.subscription.correlate(&message_id);
        self.transport.send(&message)?;
        self.message_message_id = Some(message_id);
        self.guard.next_sequence = 3;
        self.guard.unresolved_sequence = Some(2);
        Ok(())
    }

    /// Any run output proves the message was admitted, so the server's counter
    /// has advanced and a stop must carry the post-send value.
    fn mark_message_settled(&mut self) {
        self.guard.unresolved_sequence = None;
    }

    fn rollback_message_sequence(&mut self) {
        if let Some(sequence) = self.guard.unresolved_sequence.take() {
            self.guard.next_sequence = sequence;
        }
    }

    /// The run was rejected before admission, or the session is not ours.
    fn finish_without_stop(&mut self) {
        if self.guard.may_stop() {
            self.guard.stop("completed");
        } else {
            self.guard.abandon();
        }
    }

    /// Stops the session and drains its tail.
    ///
    /// Per spec §6.1 the server queues a terminal `agent_end` after
    /// `agent_result`; draining keeps that frame from becoming the first frame a
    /// later run on the same id sees. The stop is probed: a message that was
    /// never admitted leaves the counter where it was, so a stop rejected as
    /// out-of-order is retried once with the post-send value.
    async fn teardown(&mut self, reason: &str) {
        let probe_sequence = self.guard.unresolved_sequence.take();
        if let Some(pre_send) = probe_sequence {
            let post_send = self.guard.next_sequence;
            self.guard.next_sequence = pre_send;
            if let Some(message_id) = self.guard.stop(reason) {
                if self.probe_stop(&message_id).await == StopOutcome::WrongSequence {
                    self.guard.settled = false;
                    self.guard.next_sequence = post_send;
                    if let Some(message_id) = self.guard.stop(reason) {
                        self.probe_stop(&message_id).await;
                    }
                }
            }
        } else if let Some(message_id) = self.guard.stop(reason) {
            self.probe_stop(&message_id).await;
        }
        self.drain().await;
    }

    async fn probe_stop(&mut self, stop_message_id: &str) -> StopOutcome {
        self.subscription.correlate(stop_message_id);
        let deadline = tokio::time::Instant::now() + DRAIN_BUDGET;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return StopOutcome::Unknown;
            }
            let Ok(frame) = self
                .subscription
                .next_within(remaining, "agent_stopped")
                .await
            else {
                return StopOutcome::Unknown;
            };
            if frame.in_reply_to.as_deref() != Some(stop_message_id) {
                continue;
            }
            if frame.kind == "agent_stopped" {
                return StopOutcome::Stopped;
            }
            let code = frame
                .payload_non_empty("code")
                .or_else(|| frame.payload_non_empty("error_code"));
            return match code.as_deref() {
                Some("invalid_request") | Some("invalid_sequence") => StopOutcome::WrongSequence,
                _ => StopOutcome::Unknown,
            };
        }
    }

    async fn drain(&mut self) {
        self.subscription.drain_ready();
        // One short wait catches the `agent_end` the server queues behind
        // `agent_result`; anything still outstanding after that is not ours.
        let _ = self
            .subscription
            .next_within(Duration::from_millis(50), "session tail")
            .await;
        self.subscription.drain_ready();
    }
}

#[derive(Debug, PartialEq, Eq)]
enum StopOutcome {
    Stopped,
    WrongSequence,
    Unknown,
}

async fn execute_tool(frame: &Frame, request: &ExecutionRequest) -> Envelope {
    let tool_call_id = frame
        .payload_str("tool_call_id")
        .unwrap_or_default()
        .to_owned();
    let tool_name = frame
        .payload_str("tool_name")
        .unwrap_or_default()
        .to_owned();
    let args_json = frame
        .payload_str("args_json")
        .unwrap_or_default()
        .to_owned();

    let invocation = ToolInvocation {
        tool_call_id: tool_call_id.clone(),
        tool_name: tool_name.clone(),
        args_json,
    };

    let outcome = match request.tool(&tool_name) {
        Some(tool) => tool.call(invocation).await,
        None => None,
    };

    let (text, is_error) = match outcome {
        Some(Ok(text)) => (text, false),
        Some(Err(message)) => (message, true),
        None => (
            format!("Tool '{tool_name}' is not executable by this client"),
            true,
        ),
    };

    Envelope::reply_to(
        "tool_result",
        frame,
        json!({
            "tool_call_id": tool_call_id,
            "result_json": json!([{ "type": "text", "text": text }]).to_string(),
            "is_error": is_error,
        }),
    )
}

/// Spec §3.5: a provider auth failure can settle as a *successful* run whose
/// `stop_reason` is `error`. Those must reach the typed auth path rather than
/// being handed back as a completed response.
/// Keeps an `auth_required` frame failure in its retryable `Stream` form while
/// `run` can still act on it, and promotes it to the terminal `AuthRequired`
/// only once a replay would re-run tools that already had side effects.
///
/// `run`'s `auto_once` gate matches `is_retryable_auth`, which is true only for
/// a `Stream` error coded `auth_required`; promoting inside `run_once` closed
/// that gate before `run` ever saw it. `run` promotes on every path it takes
/// after deciding, so returning the raw error here loses nothing -- it derives
/// the same `fallback_provider` from the same `request.model_ref`.
fn retryable_or_auth_error(
    error: Error,
    fallback_provider: Option<String>,
    allow_retry: bool,
) -> Error {
    if allow_retry {
        return error;
    }
    promote_auth_error(error, fallback_provider)
}

fn response_or_auth_error(
    response: CompletionResponse,
    fallback_provider: Option<String>,
    allow_retry: bool,
) -> Result<CompletionResponse> {
    if response.stop_reason.as_deref() != Some("error")
        || !is_auth_failure_message(response.error_message.as_deref(), Some(&response.api))
    {
        return Ok(response);
    }
    let message = response
        .error_message
        .clone()
        .unwrap_or_else(|| "auth_required".to_owned());
    let provider_id = Some(response.provider_id.clone())
        .filter(|id| !id.is_empty())
        .or(fallback_provider);

    if allow_retry {
        // Still retryable: `run` may log in and try once more. A run that
        // already executed tools is not replayed, so it goes straight to the
        // terminal form.
        return Err(Error::provider_stream(
            message,
            Some("auth_required".to_owned()),
            provider_id,
        ));
    }
    Err(match provider_id {
        Some(provider_id) => Error::auth_required(provider_id, message),
        None => Error::provider_stream(message, Some("auth_required".to_owned()), None),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Tool;
    use serde_json::Value;

    fn frame(value: Value) -> Frame {
        Frame::parse(&value.to_string()).expect("frame parses")
    }

    fn tool_execute_frame(tool_name: &str, args: &str) -> Frame {
        frame(json!({
            "type": "tool_execute",
            "session_id": "S",
            "message_id": "TE1",
            "sequence": 4,
            "payload": { "tool_call_id": "call-1", "tool_name": tool_name, "args_json": args }
        }))
    }

    #[tokio::test]
    async fn tool_results_reply_to_the_request_that_asked() {
        let request = ExecutionRequest::prompt("p/a@m", "hi").with_tool(
            Tool::new("lookup", "look it up", "{}")
                .on_call(|invocation| async move { Ok(format!("ran {}", invocation.tool_name)) }),
        );
        let reply = execute_tool(&tool_execute_frame("lookup", "{}"), &request).await;
        assert_eq!(reply.kind, "tool_result");
        assert_eq!(reply.in_reply_to.as_deref(), Some("TE1"));
        assert_eq!(reply.session_id.as_deref(), Some("S"));
        assert_eq!(reply.sequence, 5);
        assert_eq!(reply.payload["is_error"], json!(false));
        // `serde_json` serializes object keys in sorted order.
        assert_eq!(
            reply.payload["result_json"],
            json!(r#"[{"text":"ran lookup","type":"text"}]"#)
        );
    }

    #[tokio::test]
    async fn a_failing_tool_answers_with_an_error_result() {
        let request = ExecutionRequest::prompt("p/a@m", "hi").with_tool(
            Tool::new("lookup", "look it up", "{}")
                .on_call(|_| async move { Err("upstream is down".to_owned()) }),
        );
        let reply = execute_tool(&tool_execute_frame("lookup", "{}"), &request).await;
        assert_eq!(reply.payload["is_error"], json!(true));
        assert!(reply.payload["result_json"]
            .as_str()
            .unwrap_or_default()
            .contains("upstream is down"));
    }

    #[tokio::test]
    async fn an_unknown_tool_answers_rather_than_stalling_the_loop() {
        let request = ExecutionRequest::prompt("p/a@m", "hi");
        let reply = execute_tool(&tool_execute_frame("missing", "{}"), &request).await;
        assert_eq!(reply.payload["is_error"], json!(true));
        assert!(reply.payload["result_json"]
            .as_str()
            .unwrap_or_default()
            .contains("not executable by this client"));
    }

    #[tokio::test]
    async fn a_declaration_only_tool_answers_rather_than_stalling_the_loop() {
        let request = ExecutionRequest::prompt("p/a@m", "hi").with_tool(Tool::new(
            "lookup",
            "look it up",
            "{}",
        ));
        let reply = execute_tool(&tool_execute_frame("lookup", "{}"), &request).await;
        assert_eq!(reply.payload["is_error"], json!(true));
    }

    #[test]
    fn errored_runs_with_auth_messages_take_the_auth_path() {
        let response = CompletionResponse::parse_agent_result(&json!({
            "stop_reason": "error",
            "provider": "anthropic",
            "api": "anthropic-messages",
            "content": [{ "type": "text", "text": "" }],
            "error_message": "auth_required"
        }));

        let retryable = response_or_auth_error(response.clone(), None, true).unwrap_err();
        assert!(retryable.is_retryable_auth());
        assert_eq!(retryable.provider_id(), Some("anthropic"));

        let terminal = response_or_auth_error(response, None, false).unwrap_err();
        assert!(matches!(terminal, Error::AuthRequired { .. }));
    }

    #[test]
    fn frame_failures_stay_retryable_until_tools_have_run() {
        let auth_failure = || {
            Error::provider_stream(
                "auth_required".to_owned(),
                Some("auth_required".to_owned()),
                Some("anthropic".to_owned()),
            )
        };

        let retryable = retryable_or_auth_error(auth_failure(), None, true);
        assert!(
            retryable.is_retryable_auth(),
            "auto_once gates on a retryable Stream error"
        );
        assert_eq!(retryable.provider_id(), Some("anthropic"));

        let terminal = retryable_or_auth_error(auth_failure(), None, false);
        assert!(matches!(terminal, Error::AuthRequired { .. }));
    }

    #[test]
    fn frame_failures_take_the_fallback_provider_when_promoted() {
        let anonymous = Error::provider_stream(
            "auth_required".to_owned(),
            Some("auth_required".to_owned()),
            None,
        );
        let terminal = retryable_or_auth_error(anonymous, Some("openai".to_owned()), false);
        assert_eq!(terminal.provider_id(), Some("openai"));
    }

    #[test]
    fn non_auth_frame_failures_are_never_promoted() {
        let rate_limited = || {
            Error::provider_stream(
                "rate limited".to_owned(),
                Some("rate_limited".to_owned()),
                Some("anthropic".to_owned()),
            )
        };
        assert!(!retryable_or_auth_error(rate_limited(), None, true).is_retryable_auth());
        assert!(matches!(
            retryable_or_auth_error(rate_limited(), None, false),
            Error::Stream { .. }
        ));
    }

    #[test]
    fn errored_runs_without_auth_messages_are_returned_as_responses() {
        let response = CompletionResponse::parse_agent_result(&json!({
            "stop_reason": "error",
            "provider": "anthropic",
            "api": "anthropic-messages",
            "error_message": "rate limited"
        }));
        let returned = response_or_auth_error(response, None, true).expect("not an auth failure");
        assert_eq!(returned.error_message.as_deref(), Some("rate limited"));
    }

    #[test]
    fn successful_runs_pass_straight_through() {
        let response = CompletionResponse::parse_agent_result(&json!({
            "stop_reason": "end_turn",
            "content": [{ "type": "text", "text": "hello" }]
        }));
        assert_eq!(
            response_or_auth_error(response, None, true)
                .expect("ok")
                .text(),
            "hello"
        );
    }
}
