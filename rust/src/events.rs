//! Streaming events and the normalization that produces them.
//!
//! The runtime spells the same logical event several ways depending on which
//! layer emitted it: a provider `event` envelope, an `agent_event` carrying a
//! JSON document in a string, or a bare typed frame. Everything funnels through
//! [`normalize_provider_frame`] and [`normalize_agent_frame`] so that consumers
//! see one shape.
//!
//! Tool calls are buffered, not streamed: spec §3.5 defers incremental tool-call
//! deltas, so `toolcall_start` / `toolcall_delta` / `toolcall_end` accumulate
//! into a single [`ProviderEvent::ToolCall`].

use std::collections::HashMap;

use serde_json::Value;

use crate::error::Result;
use crate::types::Usage;
use crate::wire::{opt_string, opt_string_any, str_or_empty, Frame};

/// An event from a provider-level stream.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum ProviderEvent {
    /// Generation started. Carries the resolved identity when the runtime knows it.
    MessageStart {
        /// The provider serving the request.
        provider_id: Option<String>,
        /// The API it is reached through.
        api: Option<String>,
        /// The resolved model id.
        model_id: Option<String>,
    },
    /// Newly generated text.
    TextDelta {
        /// The new text. Deltas concatenate; they are not cumulative.
        delta: String,
    },
    /// Newly generated reasoning output.
    ThinkingDelta {
        /// The new reasoning text.
        delta: String,
    },
    /// A fully buffered tool call.
    ToolCall {
        /// Correlates this call with its result.
        tool_call_id: String,
        /// The tool's name.
        name: String,
        /// The arguments, as a JSON document in a string.
        arguments_json: String,
    },
    /// Generation finished. One of the two terminal events (spec §3.5).
    MessageEnd {
        /// Token accounting, when the provider reported any.
        usage: Option<Usage>,
        /// Why generation stopped.
        stop_reason: Option<String>,
        /// Failure detail, when the turn failed but still produced a terminal event.
        error_message: Option<String>,
    },
    /// The stream failed. The other terminal event.
    Error {
        /// Human-readable detail.
        message: String,
        /// The protocol error code, when the runtime supplied one.
        code: Option<String>,
        /// The provider the failure is attributed to.
        provider_id: Option<String>,
    },
}

impl ProviderEvent {
    /// Whether this event ends the stream.
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::MessageEnd { .. } | Self::Error { .. })
    }

    /// The text this event contributes, if any.
    pub fn text(&self) -> Option<&str> {
        match self {
            Self::TextDelta { delta } => Some(delta),
            _ => None,
        }
    }
}

/// An event from an agent run. Wraps [`ProviderEvent`] with the loop's own
/// lifecycle events.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum AgentEvent {
    /// The run started.
    AgentStart {
        /// The run's session id, a correlation key only.
        session_id: Option<String>,
    },
    /// A provider turn started.
    TurnStart,
    /// A provider turn finished.
    TurnEnd {
        /// Why the turn stopped. Turn-scoped, not the run's outcome.
        stop_reason: Option<String>,
        /// Failure detail for a turn that failed at the provider.
        error_message: Option<String>,
    },
    /// The loop is about to run a tool.
    ToolExecutionStart {
        /// The call being executed.
        tool_call_id: String,
        /// The tool's name.
        tool_name: String,
    },
    /// A tool finished.
    ToolExecutionEnd {
        /// The call that finished.
        tool_call_id: String,
        /// Whether it failed.
        is_error: Option<bool>,
    },
    /// The run finished. The terminal event on the success path.
    AgentEnd {
        /// Aggregate token accounting across every turn.
        usage: Option<Usage>,
        /// Why the run stopped; may be agent-level, such as `max_turns`.
        stop_reason: Option<String>,
        /// Failure detail, when a turn failed at the provider.
        error_message: Option<String>,
        /// The provider that served the run.
        provider_id: Option<String>,
        /// The API it was reached through.
        api: Option<String>,
    },
    /// A provider-level event from the turn currently running.
    Provider(ProviderEvent),
}

impl AgentEvent {
    /// Whether this event ends the run.
    pub fn is_terminal(&self) -> bool {
        match self {
            Self::AgentEnd { .. } => true,
            Self::Provider(event) => matches!(event, ProviderEvent::Error { .. }),
            _ => false,
        }
    }

    /// The text this event contributes, if any.
    pub fn text(&self) -> Option<&str> {
        match self {
            Self::Provider(event) => event.text(),
            _ => None,
        }
    }

    /// Whether the runtime would replay this event on a retried attempt, so it
    /// does not count as content already delivered to the caller.
    pub(crate) fn is_replayable(&self) -> bool {
        matches!(
            self,
            Self::AgentStart { .. }
                | Self::TurnStart
                | Self::TurnEnd { .. }
                | Self::Provider(ProviderEvent::MessageStart { .. })
                | Self::Provider(ProviderEvent::MessageEnd { .. })
        )
    }
}

/// Accumulates streamed tool-call fragments until `toolcall_end`.
#[derive(Debug, Default)]
pub(crate) struct ToolCallBuffers {
    entries: HashMap<u64, ToolCallBuffer>,
}

#[derive(Debug, Default)]
struct ToolCallBuffer {
    id: Option<String>,
    name: Option<String>,
    args: String,
}

impl ToolCallBuffers {
    fn start(&mut self, index: u64, id: Option<String>, name: Option<String>) {
        self.entries.insert(
            index,
            ToolCallBuffer {
                id,
                name,
                args: String::new(),
            },
        );
    }

    fn push(&mut self, index: u64, delta: &str) {
        self.entries.entry(index).or_default().args.push_str(delta);
    }

    fn finish(&mut self, index: u64) -> ToolCallBuffer {
        self.entries.remove(&index).unwrap_or_default()
    }

    fn len(&self) -> u64 {
        self.entries.len() as u64
    }
}

fn index_of(value: &Value, fallback: u64) -> u64 {
    value
        .get("content_index")
        .and_then(Value::as_u64)
        .unwrap_or(fallback)
}

/// Normalizes a provider-level frame. Returns `None` for frames that carry no
/// consumer-visible event, such as a buffered tool-call fragment.
pub(crate) fn normalize_provider_frame(
    frame: &Frame,
    buffers: &mut ToolCallBuffers,
) -> Option<ProviderEvent> {
    let payload = frame.payload();
    match frame.kind.as_str() {
        "event" => {
            let inner = payload
                .get("event")
                .filter(|value| value.is_object())
                .unwrap_or(payload);
            normalize_provider_event(inner, buffers)
        }
        "stream_error" | "error" => Some(parse_error(payload)),
        "start" | "message_start" => Some(message_start(payload)),
        "text_delta" => Some(ProviderEvent::TextDelta {
            delta: str_or_empty(payload, "delta"),
        }),
        "thinking_delta" | "reasoning_delta" | "reasoning" => Some(ProviderEvent::ThinkingDelta {
            delta: opt_string_any(payload, &["delta", "reasoning"]).unwrap_or_default(),
        }),
        "tool_call" => Some(parse_tool_call(payload)),
        "toolcall_start" | "toolcall_delta" | "toolcall_end" => {
            normalize_provider_event(payload, buffers)
        }
        "message_end" | "done" | "result" => Some(message_end(payload)),
        _ => None,
    }
}

fn event_kind(value: &Value) -> String {
    let explicit = opt_string(value, "type");
    let event_type = opt_string(value, "event_type");
    match (explicit.as_deref(), event_type) {
        (Some("event"), Some(inner)) => inner,
        (Some(kind), _) => kind.to_owned(),
        (None, Some(inner)) => inner,
        (None, None) => value
            .as_object()
            .and_then(|object| object.keys().next().cloned())
            .unwrap_or_default(),
    }
}

fn normalize_provider_event(
    payload: &Value,
    buffers: &mut ToolCallBuffers,
) -> Option<ProviderEvent> {
    match event_kind(payload).as_str() {
        "start" => {
            let source = payload
                .get("message")
                .filter(|value| value.is_object())
                .unwrap_or(payload);
            Some(message_start(source))
        }
        "text_delta" => Some(ProviderEvent::TextDelta {
            delta: str_or_empty(payload, "delta"),
        }),
        "thinking_delta" | "reasoning_delta" | "reasoning" => Some(ProviderEvent::ThinkingDelta {
            delta: opt_string_any(payload, &["delta", "reasoning"]).unwrap_or_default(),
        }),
        "toolcall_start" => {
            let index = index_of(payload, buffers.len());
            buffers.start(
                index,
                opt_string(payload, "id"),
                opt_string(payload, "name"),
            );
            None
        }
        "toolcall_delta" => {
            let index = index_of(payload, 0);
            buffers.push(index, &str_or_empty(payload, "delta"));
            None
        }
        "toolcall_end" => {
            let index = index_of(payload, 0);
            let buffered = buffers.finish(index);
            Some(ProviderEvent::ToolCall {
                tool_call_id: opt_string_any(payload, &["tool_call_id", "id"])
                    .or(buffered.id)
                    .unwrap_or_default(),
                name: opt_string(payload, "name")
                    .or(buffered.name)
                    .unwrap_or_default(),
                arguments_json: opt_string(payload, "arguments_json").unwrap_or(buffered.args),
            })
        }
        "tool_call" => Some(parse_tool_call(payload)),
        "done" | "message_end" => Some(message_end(payload)),
        "stream_error" | "error" => Some(parse_error(payload)),
        _ => None,
    }
}

/// Normalizes an agent-level frame into zero or more events.
pub(crate) fn normalize_agent_frame(
    frame: &Frame,
    buffers: &mut ToolCallBuffers,
) -> Result<Vec<AgentEvent>> {
    match frame.kind.as_str() {
        "agent_result" => {
            let result = frame.payload_json_string("result_json")?;
            Ok(vec![agent_end(&result)])
        }
        "agent_error" => Ok(vec![AgentEvent::Provider(parse_error(frame.payload()))]),
        "agent_event" => {
            let event = frame.payload_json_string("event_json")?;
            Ok(normalize_agent_event(&event, buffers))
        }
        "event" => {
            let payload = frame.payload();
            let inner = payload
                .get("event")
                .filter(|value| value.is_object())
                .unwrap_or(payload);
            if is_agent_event_kind(&event_kind(inner)) {
                Ok(normalize_agent_event(inner, buffers))
            } else {
                Ok(normalize_provider_frame(frame, buffers)
                    .map(AgentEvent::Provider)
                    .into_iter()
                    .collect())
            }
        }
        _ => Ok(normalize_provider_frame(frame, buffers)
            .map(AgentEvent::Provider)
            .into_iter()
            .collect()),
    }
}

fn is_agent_event_kind(kind: &str) -> bool {
    matches!(
        kind,
        "agent_start"
            | "agent_end"
            | "turn_start"
            | "turn_end"
            | "tool_execution_start"
            | "tool_execution_end"
            | "tool_execution_update"
    )
}

fn normalize_agent_event(event: &Value, buffers: &mut ToolCallBuffers) -> Vec<AgentEvent> {
    let kind = event_kind(event);
    // A `{ "turn_start": { ... } }` shape nests the data under the variant key;
    // a `{ "type": "turn_start", ... }` shape carries it inline.
    let data = if event.get("type").is_some() || event.get("event_type").is_some() {
        event
    } else {
        event
            .get(&kind)
            .filter(|value| value.is_object())
            .unwrap_or(event)
    };

    match kind.as_str() {
        "agent_start" => vec![AgentEvent::AgentStart {
            session_id: opt_string(data, "session_id"),
        }],
        "turn_start" => vec![AgentEvent::TurnStart],
        "turn_end" => vec![AgentEvent::TurnEnd {
            stop_reason: opt_string(data, "stop_reason"),
            error_message: opt_string(data, "error_message"),
        }],
        "tool_execution_start" => vec![AgentEvent::ToolExecutionStart {
            tool_call_id: str_or_empty(data, "tool_call_id"),
            tool_name: str_or_empty(data, "tool_name"),
        }],
        "tool_execution_end" => vec![AgentEvent::ToolExecutionEnd {
            tool_call_id: str_or_empty(data, "tool_call_id"),
            is_error: data.get("is_error").and_then(Value::as_bool),
        }],
        // Deferred to a future revision (spec §3.5); not surfaced in V1.
        "tool_execution_update" => Vec::new(),
        "agent_end" => vec![agent_end(data)],
        "message_start" => {
            let source = data
                .get("message")
                .filter(|value| value.is_object())
                .unwrap_or(data);
            vec![AgentEvent::Provider(message_start(source))]
        }
        "message_end" => {
            let source = data
                .get("message")
                .filter(|value| value.is_object())
                .unwrap_or(data);
            vec![AgentEvent::Provider(message_end(source))]
        }
        "message_update" => {
            let inner = data
                .get("event")
                .filter(|value| value.is_object())
                .unwrap_or(data);
            normalize_provider_event(inner, buffers)
                .map(AgentEvent::Provider)
                .into_iter()
                .collect()
        }
        "text_delta" | "thinking_delta" | "reasoning_delta" | "reasoning" | "toolcall_start"
        | "toolcall_delta" | "toolcall_end" | "tool_call" => {
            normalize_provider_event(event, buffers)
                .map(AgentEvent::Provider)
                .into_iter()
                .collect()
        }
        "error" => vec![AgentEvent::Provider(parse_error(data))],
        _ => Vec::new(),
    }
}

fn message_start(data: &Value) -> ProviderEvent {
    ProviderEvent::MessageStart {
        provider_id: opt_string_any(data, &["provider_id", "provider"]),
        api: opt_string(data, "api"),
        model_id: opt_string_any(data, &["model_id", "model"]),
    }
}

fn message_end(data: &Value) -> ProviderEvent {
    let message = data
        .get("message")
        .filter(|value| value.is_object())
        .unwrap_or(data);
    ProviderEvent::MessageEnd {
        usage: message
            .get("usage")
            .and_then(Usage::parse)
            .or_else(|| data.get("usage").and_then(Usage::parse))
            .or_else(|| Usage::parse(message)),
        stop_reason: opt_string_any(data, &["stop_reason", "reason"])
            .or_else(|| opt_string(message, "stop_reason")),
        error_message: opt_string(data, "error_message")
            .or_else(|| opt_string(message, "error_message")),
    }
}

fn agent_end(data: &Value) -> AgentEvent {
    AgentEvent::AgentEnd {
        usage: data
            .get("usage")
            .and_then(Usage::parse)
            .or_else(|| Usage::parse(data)),
        stop_reason: opt_string_any(data, &["stop_reason", "reason"]),
        error_message: opt_string(data, "error_message"),
        provider_id: opt_string_any(data, &["provider_id", "provider"]),
        api: opt_string(data, "api"),
    }
}

fn parse_tool_call(data: &Value) -> ProviderEvent {
    ProviderEvent::ToolCall {
        tool_call_id: opt_string_any(data, &["tool_call_id", "id"]).unwrap_or_default(),
        name: str_or_empty(data, "name"),
        arguments_json: str_or_empty(data, "arguments_json"),
    }
}

pub(crate) fn parse_error(data: &Value) -> ProviderEvent {
    ProviderEvent::Error {
        message: opt_string_any(data, &["message", "error_message", "reason"])
            .unwrap_or_else(|| "stream error".to_owned()),
        code: opt_string_any(data, &["code", "error_code"]),
        provider_id: opt_string(data, "provider_id"),
    }
}

/// Reconstructs the assistant message from a run's event history, for the
/// non-streaming `run` call when the runtime settles through `agent_end` rather
/// than an `agent_result` frame.
pub(crate) fn response_from_events(events: &[AgentEvent]) -> crate::types::CompletionResponse {
    use crate::types::{Content, ContentPart};

    let final_message = final_assistant_message_events(events);

    let mut parts: Vec<ContentPart> = Vec::new();
    let mut text = String::new();
    let flush = |text: &mut String, parts: &mut Vec<ContentPart>| {
        if !text.is_empty() {
            parts.push(ContentPart::text(std::mem::take(text)));
        }
    };
    for event in final_message {
        match event {
            AgentEvent::Provider(ProviderEvent::TextDelta { delta }) => text.push_str(delta),
            AgentEvent::Provider(ProviderEvent::ThinkingDelta { delta }) => {
                flush(&mut text, &mut parts);
                parts.push(ContentPart::Thinking {
                    thinking: delta.clone(),
                    thinking_signature: None,
                });
            }
            AgentEvent::Provider(ProviderEvent::ToolCall {
                tool_call_id,
                name,
                arguments_json,
            }) => {
                flush(&mut text, &mut parts);
                parts.push(ContentPart::ToolCall {
                    tool_call_id: tool_call_id.clone(),
                    name: name.clone(),
                    arguments_json: arguments_json.clone(),
                });
            }
            _ => {}
        }
    }

    let content = if parts.is_empty() {
        Content::Text(text)
    } else {
        flush(&mut text, &mut parts);
        Content::Parts(parts)
    };

    let start = events.iter().rev().find_map(|event| match event {
        AgentEvent::Provider(ProviderEvent::MessageStart {
            provider_id,
            api,
            model_id,
        }) => Some((provider_id.clone(), api.clone(), model_id.clone())),
        _ => None,
    });
    let last_message_end_usage = events.iter().rev().find_map(|event| match event {
        AgentEvent::Provider(ProviderEvent::MessageEnd { usage, .. }) => *usage,
        _ => None,
    });
    let terminal = events.iter().rev().find(|event| {
        matches!(
            event,
            AgentEvent::AgentEnd { .. } | AgentEvent::Provider(ProviderEvent::MessageEnd { .. })
        )
    });

    let (mut usage, stop_reason, error_message, terminal_provider, terminal_api) = match terminal {
        Some(AgentEvent::AgentEnd {
            usage,
            stop_reason,
            error_message,
            provider_id,
            api,
        }) => (
            *usage,
            stop_reason.clone(),
            error_message.clone(),
            provider_id.clone(),
            api.clone(),
        ),
        Some(AgentEvent::Provider(ProviderEvent::MessageEnd {
            usage,
            stop_reason,
            error_message,
        })) => (
            *usage,
            stop_reason.clone(),
            error_message.clone(),
            None,
            None,
        ),
        _ => (None, None, None, None, None),
    };
    if usage.is_none() {
        usage = last_message_end_usage;
    }

    let (start_provider, start_api, start_model) = start.unwrap_or((None, None, None));
    crate::types::CompletionResponse {
        content,
        usage,
        provider_id: start_provider.or(terminal_provider).unwrap_or_default(),
        api: start_api.or(terminal_api).unwrap_or_default(),
        model_id: start_model.unwrap_or_default(),
        stop_reason,
        error_message,
    }
}

/// The slice of events belonging to the run's last assistant message.
fn final_assistant_message_events(events: &[AgentEvent]) -> &[AgentEvent] {
    let Some(start) = events.iter().rposition(|event| {
        matches!(
            event,
            AgentEvent::Provider(ProviderEvent::MessageStart { .. })
        )
    }) else {
        return events;
    };
    let tail = events.get(start + 1..).unwrap_or(&[]);
    let end = tail
        .iter()
        .position(|event| {
            matches!(
                event,
                AgentEvent::Provider(ProviderEvent::MessageEnd { .. })
            )
        })
        .map(|offset| start + 1 + offset + 1)
        .unwrap_or(events.len());
    events.get(start..end).unwrap_or(events)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn frame(value: Value) -> Frame {
        Frame::parse(&value.to_string()).expect("frame parses")
    }

    #[test]
    fn provider_event_envelopes_normalize() {
        let mut buffers = ToolCallBuffers::default();
        let event = normalize_provider_frame(
            &frame(json!({
                "type": "event",
                "stream_id": "S",
                "payload": { "event": { "type": "text_delta", "delta": "hi" } }
            })),
            &mut buffers,
        );
        assert_eq!(
            event,
            Some(ProviderEvent::TextDelta {
                delta: "hi".to_owned()
            })
        );
    }

    #[test]
    fn reasoning_is_normalized_to_thinking() {
        let mut buffers = ToolCallBuffers::default();
        for payload in [
            json!({ "type": "reasoning", "delta": "why" }),
            json!({ "type": "reasoning_delta", "delta": "why" }),
            json!({ "type": "thinking_delta", "delta": "why" }),
            json!({ "type": "reasoning", "reasoning": "why" }),
        ] {
            let event = normalize_provider_event(&payload, &mut buffers);
            assert_eq!(
                event,
                Some(ProviderEvent::ThinkingDelta {
                    delta: "why".to_owned()
                }),
                "{payload}"
            );
        }
    }

    #[test]
    fn tool_call_fragments_buffer_into_one_event() {
        let mut buffers = ToolCallBuffers::default();
        assert_eq!(
            normalize_provider_event(
                &json!({ "type": "toolcall_start", "content_index": 0, "id": "c1", "name": "lookup" }),
                &mut buffers
            ),
            None
        );
        assert_eq!(
            normalize_provider_event(
                &json!({ "type": "toolcall_delta", "content_index": 0, "delta": "{\"city\":" }),
                &mut buffers
            ),
            None
        );
        assert_eq!(
            normalize_provider_event(
                &json!({ "type": "toolcall_delta", "content_index": 0, "delta": "\"SF\"}" }),
                &mut buffers
            ),
            None
        );
        assert_eq!(
            normalize_provider_event(
                &json!({ "type": "toolcall_end", "content_index": 0 }),
                &mut buffers
            ),
            Some(ProviderEvent::ToolCall {
                tool_call_id: "c1".to_owned(),
                name: "lookup".to_owned(),
                arguments_json: r#"{"city":"SF"}"#.to_owned(),
            })
        );
    }

    #[test]
    fn interleaved_tool_calls_keep_their_own_buffers() {
        let mut buffers = ToolCallBuffers::default();
        normalize_provider_event(
            &json!({ "type": "toolcall_start", "content_index": 0, "id": "a", "name": "one" }),
            &mut buffers,
        );
        normalize_provider_event(
            &json!({ "type": "toolcall_start", "content_index": 1, "id": "b", "name": "two" }),
            &mut buffers,
        );
        normalize_provider_event(
            &json!({ "type": "toolcall_delta", "content_index": 1, "delta": "B" }),
            &mut buffers,
        );
        normalize_provider_event(
            &json!({ "type": "toolcall_delta", "content_index": 0, "delta": "A" }),
            &mut buffers,
        );
        assert_eq!(
            normalize_provider_event(
                &json!({ "type": "toolcall_end", "content_index": 1 }),
                &mut buffers
            ),
            Some(ProviderEvent::ToolCall {
                tool_call_id: "b".to_owned(),
                name: "two".to_owned(),
                arguments_json: "B".to_owned(),
            })
        );
        assert_eq!(
            normalize_provider_event(
                &json!({ "type": "toolcall_end", "content_index": 0 }),
                &mut buffers
            ),
            Some(ProviderEvent::ToolCall {
                tool_call_id: "a".to_owned(),
                name: "one".to_owned(),
                arguments_json: "A".to_owned(),
            })
        );
    }

    #[test]
    fn nacks_and_errors_carry_their_codes() {
        let event = parse_error(
            &json!({ "error_code": "auth_required", "reason": "auth_required", "provider_id": "anthropic" }),
        );
        assert_eq!(
            event,
            ProviderEvent::Error {
                message: "auth_required".to_owned(),
                code: Some("auth_required".to_owned()),
                provider_id: Some("anthropic".to_owned()),
            }
        );
    }

    #[test]
    fn agent_events_arrive_as_json_strings() {
        let mut buffers = ToolCallBuffers::default();
        let events = normalize_agent_frame(
            &frame(json!({
                "type": "agent_event",
                "session_id": "S",
                "payload": { "event_json": "{\"type\":\"turn_end\",\"stop_reason\":\"end_turn\"}" }
            })),
            &mut buffers,
        )
        .expect("normalizes");
        assert_eq!(
            events,
            vec![AgentEvent::TurnEnd {
                stop_reason: Some("end_turn".to_owned()),
                error_message: None,
            }]
        );
    }

    #[test]
    fn unknown_agent_events_are_ignored() {
        let mut buffers = ToolCallBuffers::default();
        // The runtime emits `prompt_segment_usage` and `context_usage`; V1 does
        // not surface them.
        let events = normalize_agent_frame(
            &frame(json!({
                "type": "agent_event",
                "session_id": "S",
                "payload": { "event_json": "{\"type\":\"context_usage\",\"total_bytes\":2}" }
            })),
            &mut buffers,
        )
        .expect("normalizes");
        assert!(events.is_empty());
    }

    #[test]
    fn tool_execution_update_is_deferred() {
        let mut buffers = ToolCallBuffers::default();
        assert!(normalize_agent_event(
            &json!({ "type": "tool_execution_update", "tool_call_id": "c" }),
            &mut buffers
        )
        .is_empty());
    }

    #[test]
    fn agent_end_reads_the_runtime_shape() {
        let mut buffers = ToolCallBuffers::default();
        let events = normalize_agent_frame(
            &frame(json!({
                "type": "agent_event",
                "session_id": "S",
                "payload": { "event_json": "{\"type\":\"agent_end\",\"stop_reason\":\"error\",\"provider_id\":\"anthropic\",\"api\":\"anthropic-messages\",\"error_message\":\"auth_required\"}" }
            })),
            &mut buffers,
        )
        .expect("normalizes");
        assert_eq!(
            events,
            vec![AgentEvent::AgentEnd {
                usage: None,
                stop_reason: Some("error".to_owned()),
                error_message: Some("auth_required".to_owned()),
                provider_id: Some("anthropic".to_owned()),
                api: Some("anthropic-messages".to_owned()),
            }]
        );
    }

    #[test]
    fn agent_result_frames_become_agent_end() {
        let mut buffers = ToolCallBuffers::default();
        let events = normalize_agent_frame(
            &frame(json!({
                "type": "agent_result",
                "session_id": "S",
                "payload": { "result_json": "{\"stop_reason\":\"end_turn\",\"input\":3,\"output\":5}" }
            })),
            &mut buffers,
        )
        .expect("normalizes");
        match &events[0] {
            AgentEvent::AgentEnd {
                usage, stop_reason, ..
            } => {
                assert_eq!(stop_reason.as_deref(), Some("end_turn"));
                assert_eq!(usage.map(|u| u.output), Some(5));
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn malformed_event_json_is_an_error_not_a_silent_drop() {
        let mut buffers = ToolCallBuffers::default();
        let result = normalize_agent_frame(
            &frame(json!({
                "type": "agent_event",
                "session_id": "S",
                "payload": { "event_json": "{oops" }
            })),
            &mut buffers,
        );
        assert!(result.is_err());
    }

    #[test]
    fn responses_rebuild_from_the_last_message_only() {
        let events = vec![
            AgentEvent::AgentStart { session_id: None },
            AgentEvent::Provider(ProviderEvent::MessageStart {
                provider_id: Some("anthropic".into()),
                api: Some("anthropic-messages".into()),
                model_id: Some("claude".into()),
            }),
            AgentEvent::Provider(ProviderEvent::TextDelta {
                delta: "first".into(),
            }),
            AgentEvent::Provider(ProviderEvent::MessageEnd {
                usage: None,
                stop_reason: Some("tool_use".into()),
                error_message: None,
            }),
            AgentEvent::Provider(ProviderEvent::MessageStart {
                provider_id: Some("anthropic".into()),
                api: Some("anthropic-messages".into()),
                model_id: Some("claude".into()),
            }),
            AgentEvent::Provider(ProviderEvent::TextDelta {
                delta: "sec".into(),
            }),
            AgentEvent::Provider(ProviderEvent::TextDelta {
                delta: "ond".into(),
            }),
            AgentEvent::Provider(ProviderEvent::MessageEnd {
                usage: Some(Usage {
                    input: 1,
                    output: 2,
                    cache_read: None,
                    cache_write: None,
                }),
                stop_reason: Some("end_turn".into()),
                error_message: None,
            }),
            AgentEvent::AgentEnd {
                usage: Some(Usage {
                    input: 4,
                    output: 6,
                    cache_read: None,
                    cache_write: None,
                }),
                stop_reason: Some("end_turn".into()),
                error_message: None,
                provider_id: None,
                api: None,
            },
        ];
        let response = response_from_events(&events);
        assert_eq!(response.text(), "second");
        assert_eq!(response.model_id, "claude");
        assert_eq!(response.usage.map(|u| u.output), Some(6));
        assert_eq!(response.stop_reason.as_deref(), Some("end_turn"));
    }

    #[test]
    fn replayable_events_do_not_count_as_delivered_content() {
        assert!(AgentEvent::TurnStart.is_replayable());
        assert!(AgentEvent::AgentStart { session_id: None }.is_replayable());
        assert!(
            !AgentEvent::Provider(ProviderEvent::TextDelta { delta: "x".into() }).is_replayable()
        );
        assert!(!AgentEvent::ToolExecutionStart {
            tool_call_id: "c".into(),
            tool_name: "t".into()
        }
        .is_replayable());
    }
}
