//! Model discovery: `models.list` and `models.resolve`.
//!
//! `model_ref` is an opaque, server-issued handle (spec §3.2). This crate never
//! parses or constructs one: it is read off a [`ModelDescriptor`] and passed
//! straight back into a provider or agent request.

use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::error::{Error, Result};
use crate::ids::new_ulid;
use crate::transport::Transport;
use crate::wire::Envelope;

const MAX_PROVIDER_ID_LEN: usize = 256;
const MAX_MODEL_ID_LEN: usize = 256;
const DEFAULT_CACHE_MAX_AGE_MS: u64 = 300_000;

/// Whether a provider's credentials are usable right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthStatus {
    /// Credentials are present and valid.
    Authenticated,
    /// No credentials; an interactive login is needed.
    LoginRequired,
    /// Credentials exist but have expired.
    Expired,
    /// A refresh is in flight.
    Refreshing,
    /// An interactive login is in flight.
    LoginInProgress,
    /// The last attempt failed.
    Failed,
    /// The runtime could not tell.
    Unknown,
}

/// Where a model sits in its provider's lifecycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelLifecycle {
    /// Generally available.
    Stable,
    /// Available but subject to change.
    Preview,
    /// Scheduled for removal.
    Deprecated,
}

/// Something a model can do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelCapability {
    /// Multi-turn chat.
    Chat,
    /// Incremental output.
    Streaming,
    /// Tool calling.
    Tools,
    /// Image input.
    Vision,
    /// Reasoning output.
    Reasoning,
    /// Prompt caching.
    PromptCache,
    /// Audio input.
    AudioInput,
    /// Audio output.
    AudioOutput,
}

/// Whether the descriptor came from the provider or from the built-in catalog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelSource {
    /// Fetched from the provider.
    Dynamic,
    /// Served from the runtime's static catalog.
    StaticFallback,
}

/// The default reasoning budget for a model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReasoningLevel {
    /// Reasoning disabled.
    Off,
    /// The smallest budget.
    Minimal,
    /// A small budget.
    Low,
    /// The provider's default.
    Medium,
    /// A large budget.
    High,
    /// The largest budget.
    Xhigh,
}

/// One model the runtime can reach.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelDescriptor {
    /// The opaque handle to pass back in requests. Do not parse or construct it.
    pub model_ref: String,
    /// The provider's own model id, preserved verbatim.
    pub model_id: String,
    /// A human-readable name.
    pub display_name: String,
    /// The provider serving the model.
    pub provider_id: String,
    /// The API the provider is reached through.
    pub api: String,
    /// The endpoint the runtime will use, when it is not the provider default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// Whether this provider's credentials are usable.
    pub auth_status: AuthStatus,
    /// Where the model sits in its lifecycle.
    pub lifecycle: ModelLifecycle,
    /// What the model can do.
    pub capabilities: Vec<ModelCapability>,
    /// Where this descriptor came from.
    pub source: ModelSource,
    /// The context window, in tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u32>,
    /// The output ceiling, in tokens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u32>,
    /// The model's default reasoning budget.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_default: Option<ReasoningLevel>,
    /// Provider-specific extras.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<std::collections::BTreeMap<String, String>>,
}

/// Filters for [`ModelsApi::list`].
#[derive(Debug, Clone, Default)]
pub struct ListModelsRequest {
    /// Restrict to one provider.
    pub provider_id: Option<String>,
    /// Restrict to one API.
    pub api: Option<String>,
    /// Restrict to one exact model id.
    pub model_id: Option<String>,
    /// Include models marked deprecated.
    pub include_deprecated: Option<bool>,
    /// Include providers that still need a login.
    pub include_login_required: Option<bool>,
}

/// What [`ModelsApi::list`] returns.
#[derive(Debug, Clone, PartialEq)]
pub struct ListModelsResponse {
    /// The matching models.
    pub models: Vec<ModelDescriptor>,
    /// When the runtime built this list, in milliseconds since the epoch.
    pub fetched_at_ms: i64,
    /// How long the list may be cached, in milliseconds.
    pub cache_max_age_ms: u64,
}

#[derive(Deserialize)]
struct ModelsResponsePayload {
    models: Vec<Value>,
    fetched_at_ms: i64,
    #[serde(default)]
    cache_max_age_ms: Option<u64>,
}

/// Model discovery over the active transport.
///
/// Cheap to clone; every clone shares one transport.
#[derive(Clone)]
pub struct ModelsApi {
    transport: Arc<Transport>,
    response_timeout: Duration,
}

impl std::fmt::Debug for ModelsApi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ModelsApi")
            .field("response_timeout", &self.response_timeout)
            .finish()
    }
}

impl ModelsApi {
    pub(crate) fn new(transport: Arc<Transport>, response_timeout: Duration) -> Self {
        Self {
            transport,
            response_timeout,
        }
    }

    /// Lists the models the runtime can reach.
    pub async fn list(&self, request: ListModelsRequest) -> Result<ListModelsResponse> {
        if let Some(provider_id) = &request.provider_id {
            if provider_id.len() > MAX_PROVIDER_ID_LEN {
                return Err(Error::protocol(
                    format!(
                        "provider_id exceeds maximum length of {MAX_PROVIDER_ID_LEN} characters"
                    ),
                    Some("invalid_request"),
                ));
            }
        }
        if let Some(model_id) = &request.model_id {
            if model_id.len() > MAX_MODEL_ID_LEN {
                return Err(Error::protocol(
                    format!("model_id exceeds maximum length of {MAX_MODEL_ID_LEN} characters"),
                    Some("invalid_request"),
                ));
            }
        }
        self.dispatch(&request).await
    }

    /// Looks up exactly one model.
    ///
    /// Maps to a `models_request` with an exact `model_id` filter (spec §3.6);
    /// there is no separate resolve envelope. Zero or multiple matches are an
    /// `invalid_request` failure.
    pub async fn resolve(
        &self,
        provider_id: impl Into<String>,
        api: Option<&str>,
        model_id: impl Into<String>,
    ) -> Result<ModelDescriptor> {
        let provider_id = provider_id.into();
        let model_id = model_id.into();
        if provider_id.is_empty() {
            return Err(Error::protocol(
                "resolve requires provider_id",
                Some("invalid_request"),
            ));
        }
        if model_id.is_empty() {
            return Err(Error::protocol(
                "resolve requires model_id",
                Some("invalid_request"),
            ));
        }

        let response = self
            .list(ListModelsRequest {
                provider_id: Some(provider_id.clone()),
                api: api.map(str::to_owned),
                model_id: Some(model_id.clone()),
                ..Default::default()
            })
            .await?;

        match response.models.len() {
            0 => {
                return Err(Error::protocol("model not found", Some("invalid_request")));
            }
            1 => {}
            count => {
                return Err(Error::protocol(
                    format!("resolve returned {count} matches; expected exactly 1"),
                    Some("invalid_request"),
                ));
            }
        }

        let model = response
            .models
            .into_iter()
            .next()
            .ok_or_else(|| Error::protocol("model not found", Some("invalid_request")))?;
        if model.provider_id != provider_id {
            return Err(Error::protocol(
                "resolved model provider_id mismatch",
                Some("invalid_request"),
            ));
        }
        if model.model_id != model_id {
            return Err(Error::protocol(
                "resolved model_id mismatch",
                Some("invalid_request"),
            ));
        }
        if let Some(api) = api {
            if model.api != api {
                return Err(Error::protocol(
                    "resolved model api mismatch",
                    Some("invalid_request"),
                ));
            }
        }
        Ok(model)
    }

    async fn dispatch(&self, request: &ListModelsRequest) -> Result<ListModelsResponse> {
        let stream_id = new_ulid();
        let mut subscription = self.transport.subscribe_stream(&stream_id);
        self.transport
            .send(&Envelope::for_stream(
                "models_request",
                &stream_id,
                build_payload(request),
            ))
            .map_err(to_protocol_error)?;

        let deadline = tokio::time::Instant::now() + self.response_timeout;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                return Err(Error::protocol(
                    format!(
                        "timed out waiting for models_response after {}ms (stream_id={stream_id})",
                        self.response_timeout.as_millis()
                    ),
                    None,
                ));
            }
            let frame = subscription
                .next_within(remaining, "models_response")
                .await
                .map_err(to_protocol_error)?;

            match frame.kind.as_str() {
                "ack" => continue,
                "nack" => {
                    return Err(Error::protocol(
                        frame
                            .payload_non_empty("reason")
                            .unwrap_or_else(|| "models request rejected".to_owned()),
                        frame.payload_str("error_code"),
                    ))
                }
                "models_response" => return parse_models_response(&frame),
                other => {
                    return Err(Error::protocol(
                        format!("unexpected frame type while awaiting models_response: {other}"),
                        Some("malformed_response"),
                    ))
                }
            }
        }
    }
}

fn to_protocol_error(error: Error) -> Error {
    match error {
        Error::Protocol { .. } => error,
        other => Error::protocol(other.message().to_owned(), other.code()),
    }
}

fn build_payload(request: &ListModelsRequest) -> Value {
    let mut payload = Map::new();
    let mut insert_non_empty = |key: &str, value: &Option<String>| {
        if let Some(value) = value.as_deref().filter(|text| !text.is_empty()) {
            payload.insert(key.to_owned(), json!(value));
        }
    };
    insert_non_empty("provider_id", &request.provider_id);
    insert_non_empty("api", &request.api);
    insert_non_empty("model_id", &request.model_id);
    if let Some(value) = request.include_deprecated {
        payload.insert("include_deprecated".to_owned(), json!(value));
    }
    if let Some(value) = request.include_login_required {
        payload.insert("include_login_required".to_owned(), json!(value));
    }
    Value::Object(payload)
}

fn parse_models_response(frame: &crate::wire::Frame) -> Result<ListModelsResponse> {
    if !frame.raw.get("payload").is_some_and(Value::is_object) {
        return Err(Error::protocol(
            "models_response missing payload object",
            Some("malformed_response"),
        ));
    }
    let payload: ModelsResponsePayload = frame.payload_as()?;
    let models = payload
        .models
        .iter()
        .enumerate()
        .map(|(index, raw)| {
            serde_json::from_value::<ModelDescriptor>(raw.clone()).map_err(|err| {
                Error::protocol(
                    format!("models[{index}] did not match ModelDescriptor: {err}"),
                    Some("malformed_response"),
                )
            })
        })
        .collect::<Result<Vec<_>>>()?;

    Ok(ListModelsResponse {
        models,
        fetched_at_ms: payload.fetched_at_ms,
        cache_max_age_ms: payload.cache_max_age_ms.unwrap_or(DEFAULT_CACHE_MAX_AGE_MS),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::Frame;

    fn frame(value: Value) -> Frame {
        Frame::parse(&value.to_string()).expect("frame parses")
    }

    fn descriptor_json() -> Value {
        json!({
            "model_ref": "anthropic/anthropic-messages@claude-sonnet-4-5",
            "model_id": "claude-sonnet-4-5",
            "display_name": "Claude Sonnet 4.5",
            "provider_id": "anthropic",
            "api": "anthropic-messages",
            "auth_status": "authenticated",
            "lifecycle": "stable",
            "capabilities": ["chat", "streaming", "tools", "reasoning"],
            "source": "static_fallback",
            "base_url": "https://api.anthropic.com",
            "context_window": 200000,
            "max_output_tokens": 8192,
            "reasoning_default": "medium"
        })
    }

    #[test]
    fn list_payloads_omit_absent_filters() {
        let payload = build_payload(&ListModelsRequest::default());
        assert_eq!(payload, json!({}));

        let payload = build_payload(&ListModelsRequest {
            provider_id: Some("anthropic".into()),
            api: Some(String::new()),
            model_id: Some("claude-sonnet-4-5".into()),
            include_login_required: Some(true),
            include_deprecated: None,
        });
        assert_eq!(
            payload,
            json!({
                "provider_id": "anthropic",
                "model_id": "claude-sonnet-4-5",
                "include_login_required": true
            })
        );
    }

    #[test]
    fn responses_parse_into_typed_descriptors() {
        let response = parse_models_response(&frame(json!({
            "type": "models_response",
            "stream_id": "S",
            "payload": {
                "models": [descriptor_json()],
                "fetched_at_ms": 1_760_000_000_198i64,
                "cache_max_age_ms": 300_000
            }
        })))
        .expect("parses");
        assert_eq!(response.models.len(), 1);
        assert_eq!(response.models[0].auth_status, AuthStatus::Authenticated);
        assert_eq!(response.models[0].source, ModelSource::StaticFallback);
        assert_eq!(
            response.models[0].capabilities,
            vec![
                ModelCapability::Chat,
                ModelCapability::Streaming,
                ModelCapability::Tools,
                ModelCapability::Reasoning
            ]
        );
        assert_eq!(response.fetched_at_ms, 1_760_000_000_198);
        assert_eq!(response.cache_max_age_ms, 300_000);
    }

    #[test]
    fn cache_max_age_defaults_when_the_runtime_omits_it() {
        let response = parse_models_response(&frame(json!({
            "type": "models_response",
            "payload": { "models": [], "fetched_at_ms": 1 }
        })))
        .expect("parses");
        assert_eq!(response.cache_max_age_ms, DEFAULT_CACHE_MAX_AGE_MS);
    }

    #[test]
    fn malformed_responses_are_rejected_not_coerced() {
        for payload in [
            json!({ "type": "models_response" }),
            json!({ "type": "models_response", "payload": { "fetched_at_ms": 1 } }),
            json!({ "type": "models_response", "payload": { "models": [] } }),
            json!({ "type": "models_response", "payload": { "models": [], "fetched_at_ms": "soon" } }),
        ] {
            let result = parse_models_response(&frame(payload.clone()));
            assert!(result.is_err(), "{payload} should not parse");
        }
    }

    #[test]
    fn unknown_enum_values_are_rejected() {
        let mut descriptor = descriptor_json();
        descriptor["auth_status"] = json!("teleported");
        let result = parse_models_response(&frame(json!({
            "type": "models_response",
            "payload": { "models": [descriptor], "fetched_at_ms": 1 }
        })));
        let err = result.unwrap_err();
        assert_eq!(err.code(), Some("malformed_response"));
        assert!(err.message().contains("models[0]"), "{err}");
    }

    #[test]
    fn descriptors_keep_unknown_extra_fields_out_of_the_way() {
        let mut descriptor = descriptor_json();
        descriptor["something_new"] = json!(true);
        let response = parse_models_response(&frame(json!({
            "type": "models_response",
            "payload": { "models": [descriptor], "fetched_at_ms": 1 }
        })))
        .expect("unknown fields are ignored per the V1 additive-only rule");
        assert_eq!(response.models.len(), 1);
    }
}
