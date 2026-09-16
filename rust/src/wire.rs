//! Envelope construction and frame parsing.
//!
//! Every line on the transport is one JSON envelope. Outbound envelopes are
//! built through [`Envelope`]; inbound lines are parsed into [`Frame`], which
//! keeps the routing fields typed and leaves the per-type payload as JSON for
//! the namespace that owns it to deserialize into a pinned shape.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::error::{Error, Result};
use crate::ids::{new_ulid, now_millis};

/// Protocol envelope version. V1 keeps this pinned at 1.
pub(crate) const ENVELOPE_VERSION: u32 = 1;

/// An outbound envelope.
#[derive(Debug, Clone, Serialize)]
pub(crate) struct Envelope {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub message_id: String,
    pub sequence: u64,
    pub timestamp: i64,
    pub version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub in_reply_to: Option<String>,
    pub payload: Value,
}

impl Envelope {
    /// Builds a stream-routed envelope whose `message_id` equals its `stream_id`,
    /// the shape both SDKs use for single-request provider and models exchanges.
    pub(crate) fn for_stream(kind: &str, stream_id: &str, payload: Value) -> Self {
        Self {
            kind: kind.to_owned(),
            stream_id: Some(stream_id.to_owned()),
            session_id: None,
            message_id: stream_id.to_owned(),
            sequence: 1,
            timestamp: now_millis(),
            version: ENVELOPE_VERSION,
            in_reply_to: None,
            payload,
        }
    }

    /// Builds a stream-routed envelope with an independent `message_id`, used by
    /// the auth flow where several envelopes share one `flow_id`.
    pub(crate) fn for_flow(kind: &str, flow_id: &str, sequence: u64, payload: Value) -> Self {
        Self {
            kind: kind.to_owned(),
            stream_id: Some(flow_id.to_owned()),
            session_id: None,
            message_id: new_ulid(),
            sequence,
            timestamp: now_millis(),
            version: ENVELOPE_VERSION,
            in_reply_to: None,
            payload,
        }
    }

    /// Builds a session-routed envelope.
    pub(crate) fn for_session(kind: &str, session_id: &str, sequence: u64, payload: Value) -> Self {
        Self {
            kind: kind.to_owned(),
            stream_id: None,
            session_id: Some(session_id.to_owned()),
            message_id: new_ulid(),
            sequence,
            timestamp: now_millis(),
            version: ENVELOPE_VERSION,
            in_reply_to: None,
            payload,
        }
    }

    /// Builds a reply to `request`, carrying `in_reply_to` and the request's
    /// sequence plus one. Used for `tool_result`.
    pub(crate) fn reply_to(kind: &str, request: &Frame, payload: Value) -> Self {
        Self {
            kind: kind.to_owned(),
            stream_id: None,
            session_id: request.session_id.clone(),
            message_id: new_ulid(),
            sequence: request.sequence.unwrap_or(0).saturating_add(1),
            timestamp: now_millis(),
            version: ENVELOPE_VERSION,
            in_reply_to: request.message_id.clone(),
            payload,
        }
    }

    /// Serializes to a single NDJSON line, without the trailing newline.
    pub(crate) fn to_line(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| {
            // `Envelope` is a plain struct over `Value`; the only way this can
            // fail is a payload holding a non-finite float, which cannot reach
            // here because every payload is built from owned Rust data.
            json!({ "type": self.kind, "version": ENVELOPE_VERSION }).to_string()
        })
    }
}

/// An inbound frame.
#[derive(Debug, Clone)]
pub struct Frame {
    /// The envelope `type`.
    pub kind: String,
    /// The provider/auth route key, when present.
    pub stream_id: Option<String>,
    /// The agent route key, when present.
    pub session_id: Option<String>,
    /// This envelope's own identity.
    pub message_id: Option<String>,
    /// The `message_id` of the request this frame replies to, when it is a reply.
    pub in_reply_to: Option<String>,
    /// The per-direction, per-route allocation counter.
    pub sequence: Option<u64>,
    /// The whole frame as received.
    pub raw: Value,
}

#[derive(Deserialize)]
struct RawFrame {
    #[serde(rename = "type")]
    kind: Option<String>,
    stream_id: Option<String>,
    session_id: Option<String>,
    message_id: Option<String>,
    in_reply_to: Option<String>,
    sequence: Option<u64>,
}

impl Frame {
    /// Parses one NDJSON line.
    pub(crate) fn parse(line: &str) -> Result<Self> {
        let raw: Value = serde_json::from_str(line)
            .map_err(|err| Error::transport(format!("invalid JSON frame: {err}")))?;
        if !raw.is_object() {
            return Err(Error::transport("frame is not a JSON object"));
        }
        let fields: RawFrame = serde_json::from_value(raw.clone())
            .map_err(|err| Error::transport(format!("malformed envelope fields: {err}")))?;
        let Some(kind) = fields.kind else {
            return Err(Error::transport("frame is missing 'type'"));
        };
        Ok(Self {
            kind,
            stream_id: fields.stream_id,
            session_id: fields.session_id,
            message_id: fields.message_id,
            in_reply_to: fields.in_reply_to,
            sequence: fields.sequence,
            raw,
        })
    }

    /// The `payload` object, falling back to the frame itself when the envelope
    /// carries its fields at the top level. Mirrors the TypeScript SDK's
    /// `readPayloadOrFrame`, which keeps both SDKs tolerant of the flatter
    /// shapes older fixtures and the `ready` handshake use.
    pub fn payload(&self) -> &Value {
        match self.raw.get("payload") {
            Some(payload) if payload.is_object() => payload,
            _ => &self.raw,
        }
    }

    /// The `payload` object for a frame whose payload must be one.
    ///
    /// Keeps `payload`'s fallback to the envelope for the flatter shapes that
    /// omit `payload` altogether, but rejects a `payload` that is present and
    /// is not an object: falling back there parses the envelope instead and
    /// turns a malformed response into a valid-looking empty value.
    pub(crate) fn payload_object(&self) -> Result<&Value> {
        match self.raw.get("payload") {
            Some(payload) if payload.is_object() => Ok(payload),
            None | Some(Value::Null) => Ok(&self.raw),
            Some(_) => Err(Error::protocol(
                format!("{} carried a payload that is not an object", self.kind),
                Some("malformed_response"),
            )),
        }
    }

    /// Deserializes the payload into a pinned shape.
    pub(crate) fn payload_as<T: serde::de::DeserializeOwned>(&self) -> Result<T> {
        serde_json::from_value(self.payload().clone()).map_err(|err| {
            Error::protocol(
                format!("{} payload did not match its schema: {err}", self.kind),
                Some("malformed_response"),
            )
        })
    }

    /// Reads a payload field that holds a JSON document as a string
    /// (`event_json`, `result_json`, `config_json`, ...) and parses it.
    pub(crate) fn payload_json_string(&self, key: &str) -> Result<Value> {
        let payload = self.payload();
        let raw = payload
            .get(key)
            .and_then(Value::as_str)
            .or_else(|| payload.get("event_json").and_then(Value::as_str))
            .or_else(|| payload.get("result_json").and_then(Value::as_str));
        match raw {
            Some(text) => serde_json::from_str(text)
                .map_err(|_| Error::transport_stream(format!("malformed JSON in {key}"))),
            None => Ok(payload.clone()),
        }
    }

    /// Reads a string field from the payload.
    pub(crate) fn payload_str(&self, key: &str) -> Option<&str> {
        self.payload().get(key).and_then(Value::as_str)
    }

    /// Reads a string field from the payload, ignoring empty strings.
    pub(crate) fn payload_non_empty(&self, key: &str) -> Option<String> {
        self.payload_str(key)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    }
}

/// Reads a string field, ignoring non-strings and empty strings.
pub(crate) fn opt_string(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

/// Reads the first present string field from `keys`.
pub(crate) fn opt_string_any(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| opt_string(value, key))
}

/// Reads a string field, defaulting to the empty string.
pub(crate) fn str_or_empty(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// Reads an object field, or an empty map.
pub(crate) fn object_or_empty(value: &Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

#[cfg(test)]
mod tests {

    use super::*;

    #[test]
    fn parses_routing_fields() {
        let frame = Frame::parse(
            r#"{"type":"ack","stream_id":"S","message_id":"M","sequence":3,"in_reply_to":"R","payload":{"acknowledged_id":"R"}}"#,
        )
        .expect("frame parses");
        assert_eq!(frame.kind, "ack");
        assert_eq!(frame.stream_id.as_deref(), Some("S"));
        assert_eq!(frame.message_id.as_deref(), Some("M"));
        assert_eq!(frame.in_reply_to.as_deref(), Some("R"));
        assert_eq!(frame.sequence, Some(3));
        assert_eq!(frame.payload_str("acknowledged_id"), Some("R"));
    }

    #[test]
    fn payload_falls_back_to_the_frame_when_absent() {
        let frame = Frame::parse(r#"{"type":"ready","protocol_version":"1"}"#).expect("parses");
        assert_eq!(frame.payload_str("protocol_version"), Some("1"));
    }

    #[test]
    fn payload_falls_back_when_payload_is_not_an_object() {
        let frame = Frame::parse(r#"{"type":"x","payload":42,"delta":"hi"}"#).expect("parses");
        assert_eq!(frame.payload_str("delta"), Some("hi"));
    }

    #[test]
    fn payload_object_falls_back_only_when_payload_is_absent() {
        let flat = Frame::parse(r#"{"type":"result","stop_reason":"end_turn"}"#).expect("parses");
        assert_eq!(
            flat.payload_object().expect("flat shape is accepted")["stop_reason"],
            Value::String("end_turn".to_owned())
        );

        let nested = Frame::parse(r#"{"type":"result","payload":{"stop_reason":"max_tokens"}}"#)
            .expect("parses");
        assert_eq!(
            nested.payload_object().expect("nested shape is accepted")["stop_reason"],
            Value::String("max_tokens".to_owned())
        );

        let null = Frame::parse(r#"{"type":"result","payload":null,"stop_reason":"end_turn"}"#)
            .expect("parses");
        assert!(null.payload_object().is_ok());
    }

    #[test]
    fn payload_object_rejects_a_payload_that_is_not_an_object() {
        for line in [
            r#"{"type":"result","payload":"a string"}"#,
            r#"{"type":"result","payload":42}"#,
            r#"{"type":"result","payload":[{"stop_reason":"end_turn"}]}"#,
        ] {
            let frame = Frame::parse(line).expect("parses");
            let err = frame
                .payload_object()
                .expect_err("a non-object payload must not fall back to the envelope");
            assert!(err.to_string().contains("not an object"), "{err}");
        }
    }

    #[test]
    fn rejects_non_json_and_shapeless_lines() {
        assert!(Frame::parse("not json").is_err());
        assert!(Frame::parse("[1,2,3]").is_err());
        assert!(Frame::parse(r#"{"stream_id":"S"}"#).is_err());
    }

    #[test]
    fn rejects_wrongly_typed_routing_fields() {
        assert!(Frame::parse(r#"{"type":"ack","sequence":"three"}"#).is_err());
        assert!(Frame::parse(r#"{"type":"ack","stream_id":7}"#).is_err());
    }

    #[test]
    fn json_string_payloads_are_parsed() {
        let frame = Frame::parse(
            r#"{"type":"agent_event","payload":{"event_json":"{\"type\":\"turn_start\"}"}}"#,
        )
        .expect("parses");
        let event = frame.payload_json_string("event_json").expect("parses");
        assert_eq!(
            event.get("type").and_then(Value::as_str),
            Some("turn_start")
        );
    }

    #[test]
    fn malformed_json_string_payloads_are_transport_errors() {
        let frame = Frame::parse(r#"{"type":"agent_event","payload":{"event_json":"{nope"}}"#)
            .expect("parses");
        let err = frame.payload_json_string("event_json").unwrap_err();
        assert!(err.message().contains("malformed JSON in event_json"));
    }

    #[test]
    fn envelopes_serialize_without_absent_routes() {
        let envelope = Envelope::for_stream("models_request", "STREAM", json!({}));
        let line = envelope.to_line();
        assert!(line.contains(r#""type":"models_request""#));
        assert!(line.contains(r#""stream_id":"STREAM""#));
        assert!(line.contains(r#""message_id":"STREAM""#));
        assert!(line.contains(r#""version":1"#));
        assert!(!line.contains("session_id"));
        assert!(!line.contains("in_reply_to"));
        assert!(!line.contains('\n'));
    }

    #[test]
    fn session_envelopes_carry_the_session_route_only() {
        let envelope = Envelope::for_session("agent_start", "SESSION", 1, json!({"a": 1}));
        let line = envelope.to_line();
        assert!(line.contains(r#""session_id":"SESSION""#));
        assert!(!line.contains("stream_id"));
        assert_eq!(envelope.sequence, 1);
    }

    #[test]
    fn replies_advance_the_request_sequence_and_correlate() {
        let request = Frame::parse(
            r#"{"type":"tool_execute","session_id":"S","message_id":"M","sequence":9,"payload":{}}"#,
        )
        .expect("parses");
        let reply = Envelope::reply_to("tool_result", &request, json!({}));
        assert_eq!(reply.sequence, 10);
        assert_eq!(reply.in_reply_to.as_deref(), Some("M"));
        assert_eq!(reply.session_id.as_deref(), Some("S"));
    }
}
