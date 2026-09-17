//! Shared request building for the `provider` and `agent` namespaces.

use serde_json::{json, Map, Value};

use crate::error::{Error, Result};
use crate::types::{AuthRetryPolicy, ChatMessage, Role, RunOptions, Tool};

const MAX_MODEL_REF_LEN: usize = 4096;
const MAX_IDENTIFIER_LEN: usize = 256;
const MAX_MODEL_FIELD_LEN: usize = 512;

/// A `provider.complete` / `provider.stream` / `agent.run` / `agent.stream` request.
#[derive(Debug, Clone, Default)]
pub struct ExecutionRequest {
    /// The opaque model handle from [`crate::ModelDescriptor::model_ref`].
    pub model_ref: String,
    /// The conversation. `system` and `developer` turns are hoisted into the
    /// request's system prompt rather than sent as messages.
    pub messages: Vec<ChatMessage>,
    /// Tools the model may call. On the agent path, tools with a handler execute
    /// in this process.
    pub tools: Vec<Tool>,
    /// Per-request knobs.
    pub options: RunOptions,
}

impl ExecutionRequest {
    /// A request for `model_ref` with `messages`.
    pub fn new(model_ref: impl Into<String>, messages: Vec<ChatMessage>) -> Self {
        Self {
            model_ref: model_ref.into(),
            messages,
            tools: Vec::new(),
            options: RunOptions::default(),
        }
    }

    /// A single-turn user request.
    pub fn prompt(model_ref: impl Into<String>, prompt: impl Into<String>) -> Self {
        Self::new(model_ref, vec![ChatMessage::user(prompt.into())])
    }

    /// Attaches tools.
    pub fn with_tools(mut self, tools: Vec<Tool>) -> Self {
        self.tools = tools;
        self
    }

    /// Attaches one tool.
    pub fn with_tool(mut self, tool: Tool) -> Self {
        self.tools.push(tool);
        self
    }

    /// Replaces the request options.
    pub fn with_options(mut self, options: RunOptions) -> Self {
        self.options = options;
        self
    }

    /// Sets the output token ceiling.
    pub fn with_max_tokens(mut self, max_tokens: u32) -> Self {
        self.options.max_tokens = Some(max_tokens);
        self
    }

    pub(crate) fn validate(&self) -> Result<()> {
        if self.model_ref.is_empty() {
            return Err(Error::invalid_request("request requires a model_ref"));
        }
        if self.model_ref.len() > MAX_MODEL_REF_LEN {
            return Err(Error::protocol(
                format!("model_ref exceeds maximum length of {MAX_MODEL_REF_LEN} characters"),
                Some("invalid_request"),
            ));
        }
        match split_model_ref(&self.model_ref) {
            Some((provider, api, model_id)) => validate_segments(provider, api, model_id)?,
            None if self.model_ref.len() > MAX_MODEL_FIELD_LEN => {
                return Err(Error::protocol(
                    format!(
                        "model_ref exceeds maximum length of {MAX_MODEL_FIELD_LEN} characters for opaque refs"
                    ),
                    Some("invalid_request"),
                ))
            }
            None => {}
        }
        self.options.validate()
    }

    pub(crate) fn tool(&self, name: &str) -> Option<&Tool> {
        self.tools.iter().find(|tool| tool.name() == name)
    }
}

fn validate_segments(provider: &str, api: &str, model_id: &str) -> Result<()> {
    if provider.len() > MAX_IDENTIFIER_LEN {
        return Err(Error::protocol(
            format!("model_ref provider segment exceeds maximum length of {MAX_IDENTIFIER_LEN} characters"),
            Some("invalid_request"),
        ));
    }
    if api.len() > MAX_IDENTIFIER_LEN {
        return Err(Error::protocol(
            format!(
                "model_ref api segment exceeds maximum length of {MAX_IDENTIFIER_LEN} characters"
            ),
            Some("invalid_request"),
        ));
    }
    if model_id.len() > MAX_MODEL_FIELD_LEN {
        return Err(Error::protocol(
            format!(
                "model_ref model_id segment exceeds maximum length of {MAX_MODEL_FIELD_LEN} characters"
            ),
            Some("invalid_request"),
        ));
    }
    Ok(())
}

/// Splits `provider/api@model_id`, without decoding the percent-encoded model id.
///
/// `model_ref` is opaque to *consumers* (spec §3.2), and nothing in this crate's
/// public API parses one. This is a wire-compatibility shim: V1 provider
/// envelopes carry an `ai_types.Model` object next to the ref, and the runtime
/// dereferences it without a null check — omitting `model` crashes the stdio
/// host rather than producing a `nack`. The TypeScript SDK derives the same
/// object the same way (`modelFromRef`). A ref that does not split is passed
/// through whole, which is what an opaque server-issued ref should do.
fn split_model_ref(model_ref: &str) -> Option<(&str, &str, &str)> {
    let slash = model_ref.find('/')?;
    if slash == 0 {
        return None;
    }
    let at = model_ref[slash + 1..].find('@')? + slash + 1;
    let provider = &model_ref[..slash];
    let api = &model_ref[slash + 1..at];
    let model_id = &model_ref[at + 1..];
    if provider.is_empty() || api.is_empty() {
        return None;
    }
    Some((provider, api, model_id))
}

/// The provider a failure without an explicit `provider_id` is attributed to.
pub(crate) fn provider_id_from_ref(model_ref: &str) -> Option<String> {
    split_model_ref(model_ref).map(|(provider, _, _)| provider.to_owned())
}

fn model_object(model_ref: &str) -> Value {
    match split_model_ref(model_ref) {
        Some((provider, api, model_id)) => {
            let decoded = percent_decode(model_id);
            json!({
                "id": decoded,
                "name": decoded,
                "api": api,
                "provider": provider,
                "base_url": "",
            })
        }
        None => json!({
            "id": model_ref,
            "name": model_ref,
            "api": "",
            "provider": "",
            "base_url": "",
        }),
    }
}

/// Undoes the ref's percent-encoding so the `model.id` field carries the
/// provider's own id (`gemma4%3A31b` travels encoded but names `gemma4:31b`).
fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        let decoded = if byte == b'%' {
            bytes
                .get(index + 1..index + 3)
                .and_then(|hex| std::str::from_utf8(hex).ok())
                .and_then(|hex| u8::from_str_radix(hex, 16).ok())
        } else {
            None
        };
        match decoded {
            Some(byte) => {
                out.push(byte);
                index += 3;
            }
            None => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8(out).unwrap_or_else(|_| value.to_owned())
}

fn execution_context(request: &ExecutionRequest) -> Value {
    let mut messages = Vec::new();
    let mut system_prompts = Vec::new();
    for message in &request.messages {
        if matches!(message.role, Role::System | Role::Developer) {
            system_prompts.push(message.content.as_prompt_text());
        } else {
            messages.push(message.serialize_for_wire());
        }
    }

    let mut context = Map::new();
    context.insert("messages".to_owned(), Value::Array(messages));
    if !system_prompts.is_empty() {
        context.insert(
            "system_prompt".to_owned(),
            json!(system_prompts.join("\n\n")),
        );
    }
    if !request.tools.is_empty() {
        context.insert(
            "tools".to_owned(),
            Value::Array(request.tools.iter().map(Tool::serialize_for_wire).collect()),
        );
    }
    Value::Object(context)
}

/// Builds the `stream_request` / `complete_request` payload.
pub(crate) fn provider_payload(
    request: &ExecutionRequest,
    include_partial: bool,
    fallback_policy: Option<AuthRetryPolicy>,
) -> Value {
    let mut payload = Map::new();
    payload.insert("model".to_owned(), model_object(&request.model_ref));
    payload.insert("context".to_owned(), execution_context(request));
    payload.insert("model_ref".to_owned(), json!(request.model_ref));
    let options = request
        .options
        .serialize_with_default_policy(fallback_policy);
    if !options.is_empty() {
        payload.insert("options".to_owned(), Value::Object(options));
    }
    if !include_partial {
        payload.insert("include_partial".to_owned(), json!(false));
    }
    Value::Object(payload)
}

/// Builds the `agent_start` payload.
///
/// Emits the canonical `session_id` and the permanent legacy alias
/// `resume_session_id` with the same value, per spec §9 / §13.1: a pre-rename
/// server reads only the alias, and without it would generate its own id and
/// reject every later session-scoped frame with `agent_not_found`.
pub(crate) fn agent_start_payload(request: &ExecutionRequest, session_id: &str) -> Value {
    let config = json!({
        "model_ref": request.model_ref,
        "tools": request.tools.iter().map(Tool::serialize_for_wire).collect::<Vec<_>>(),
    });
    json!({
        "session_id": session_id,
        "resume_session_id": session_id,
        "config_json": config.to_string(),
    })
}

/// Builds the `agent_message` payload.
pub(crate) fn agent_message_payload(
    request: &ExecutionRequest,
    session_id: &str,
    fallback_policy: Option<AuthRetryPolicy>,
) -> Value {
    let message = json!({
        "model_ref": request.model_ref,
        "messages": request.messages.iter().map(ChatMessage::serialize_for_wire).collect::<Vec<_>>(),
        "tools": request.tools.iter().map(Tool::serialize_for_wire).collect::<Vec<_>>(),
    });
    let mut payload = Map::new();
    payload.insert("session_id".to_owned(), json!(session_id));
    payload.insert("message_json".to_owned(), json!(message.to_string()));
    let options = request
        .options
        .serialize_with_default_policy(fallback_policy);
    if !options.is_empty() {
        payload.insert(
            "options_json".to_owned(),
            json!(Value::Object(options).to_string()),
        );
    }
    Value::Object(payload)
}

/// Whether a terminal `error_message` names an authentication failure.
///
/// Mirrors the server-side detector the spec pins in §3.5 so that a provider
/// auth failure that arrives as a *successful* `agent_end` with
/// `stop_reason: "error"` still reaches the typed auth path.
pub(crate) fn is_auth_failure_message(message: Option<&str>, api: Option<&str>) -> bool {
    let Some(message) = message else {
        return false;
    };
    let normalized = message.to_ascii_lowercase();
    if matches!(
        normalized.as_str(),
        "auth_required" | "auth_expired" | "auth_refresh_failed"
    ) || normalized.contains("authentication required")
        || normalized.contains("401")
        || normalized.contains("403")
        || normalized.contains("unauthorized")
        || normalized.contains("forbidden")
    {
        return true;
    }
    api == Some("anthropic-messages")
        && (normalized.contains("authentication_error")
            || normalized.contains("permission_error")
            || normalized.contains("invalid api key"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Content;

    #[test]
    fn refs_split_into_their_three_segments() {
        assert_eq!(
            split_model_ref("anthropic/anthropic-messages@claude-sonnet-4-5"),
            Some(("anthropic", "anthropic-messages", "claude-sonnet-4-5"))
        );
        assert_eq!(split_model_ref("opaque-handle"), None);
        assert_eq!(split_model_ref("/api@model"), None);
        assert_eq!(split_model_ref("provider/@model"), None);
        assert_eq!(split_model_ref("provider/api"), None);
    }

    #[test]
    fn percent_encoded_model_ids_decode_for_the_model_object() {
        // `formatModelRef` percent-encodes every byte outside the unreserved
        // set, so Ollama's `gemma4:31b` travels as `gemma4%3A31b`.
        let model = model_object("ollama/ollama@gemma4%3A31b");
        assert_eq!(model["id"], json!("gemma4:31b"));
        assert_eq!(model["provider"], json!("ollama"));
        assert_eq!(model["api"], json!("ollama"));
    }

    #[test]
    fn truncated_percent_escapes_pass_through_unchanged() {
        assert_eq!(percent_decode("abc%"), "abc%");
        assert_eq!(percent_decode("abc%3"), "abc%3");
        assert_eq!(percent_decode("abc%zz"), "abc%zz");
    }

    #[test]
    fn opaque_refs_become_an_identity_model_object() {
        let model = model_object("totally-opaque");
        assert_eq!(model["id"], json!("totally-opaque"));
        assert_eq!(model["provider"], json!(""));
        assert_eq!(model["api"], json!(""));
    }

    #[test]
    fn provider_payloads_carry_model_and_ref() {
        // The runtime dereferences `payload.model` without a null check, so it
        // must always be present.
        let request = ExecutionRequest::prompt("anthropic/anthropic-messages@x", "hi");
        let payload = provider_payload(&request, false, None);
        assert!(payload.get("model").is_some());
        assert_eq!(
            payload["model_ref"],
            json!("anthropic/anthropic-messages@x")
        );
        assert_eq!(payload["include_partial"], json!(false));
        assert_eq!(
            payload["context"]["messages"],
            json!([{ "role": "user", "content": "hi" }])
        );
        assert!(payload["context"].get("tools").is_none());
        assert!(payload.get("options").is_none());
    }

    #[test]
    fn complete_payloads_omit_include_partial() {
        let request = ExecutionRequest::prompt("p/a@m", "hi");
        let payload = provider_payload(&request, true, None);
        assert!(payload.get("include_partial").is_none());
    }

    #[test]
    fn system_turns_are_hoisted_into_the_system_prompt() {
        let request = ExecutionRequest::new(
            "p/a@m",
            vec![
                ChatMessage::system("be terse"),
                ChatMessage::new(Role::Developer, "and precise"),
                ChatMessage::user("hi"),
            ],
        );
        let payload = provider_payload(&request, false, None);
        assert_eq!(
            payload["context"]["system_prompt"],
            json!("be terse\n\nand precise")
        );
        assert_eq!(
            payload["context"]["messages"],
            json!([{ "role": "user", "content": "hi" }])
        );
    }

    #[test]
    fn tools_reach_both_the_context_and_the_agent_config() {
        let request = ExecutionRequest::prompt("p/a@m", "hi").with_tool(Tool::new(
            "lookup",
            "look it up",
            r#"{"type":"object"}"#,
        ));
        let payload = provider_payload(&request, false, None);
        assert_eq!(payload["context"]["tools"][0]["name"], json!("lookup"));

        let start = agent_start_payload(&request, "sessionsessionsessio");
        let config: Value =
            serde_json::from_str(start["config_json"].as_str().expect("string")).expect("json");
        assert_eq!(config["tools"][0]["name"], json!("lookup"));
        assert_eq!(config["model_ref"], json!("p/a@m"));
    }

    #[test]
    fn agent_start_emits_both_session_keys() {
        let request = ExecutionRequest::prompt("p/a@m", "hi");
        let payload = agent_start_payload(&request, "abcdefghijklmnopqrstu");
        assert_eq!(payload["session_id"], json!("abcdefghijklmnopqrstu"));
        assert_eq!(payload["resume_session_id"], json!("abcdefghijklmnopqrstu"));
    }

    #[test]
    fn agent_messages_carry_the_transcript_as_a_json_string() {
        let request = ExecutionRequest::new(
            "p/a@m",
            vec![ChatMessage::user("hi"), ChatMessage::assistant("hello")],
        );
        let payload = agent_message_payload(&request, "S", Some(AuthRetryPolicy::AutoOnce));
        let message: Value =
            serde_json::from_str(payload["message_json"].as_str().expect("string")).expect("json");
        assert_eq!(message["messages"].as_array().map(Vec::len), Some(2));
        let options: Value =
            serde_json::from_str(payload["options_json"].as_str().expect("string")).expect("json");
        assert_eq!(options["auth_retry_policy"], json!("auto_once"));
    }

    #[test]
    fn requests_are_validated_before_the_wire() {
        assert!(ExecutionRequest::new("", vec![]).validate().is_err());

        let long = "x".repeat(MAX_MODEL_REF_LEN + 1);
        let err = ExecutionRequest::new(long, vec![]).validate().unwrap_err();
        assert_eq!(err.code(), Some("invalid_request"));

        let long_model_id = format!("p/a@{}", "x".repeat(MAX_MODEL_FIELD_LEN + 1));
        let err = ExecutionRequest::new(long_model_id, vec![])
            .validate()
            .unwrap_err();
        assert!(err.message().contains("model_id segment"), "{err}");

        let long_opaque = "x".repeat(MAX_MODEL_FIELD_LEN + 1);
        let err = ExecutionRequest::new(long_opaque, vec![])
            .validate()
            .unwrap_err();
        assert!(err.message().contains("opaque refs"), "{err}");

        assert!(ExecutionRequest::prompt("p/a@m", "hi").validate().is_ok());
    }

    #[test]
    fn provider_attribution_falls_back_to_the_refs_first_segment() {
        assert_eq!(
            provider_id_from_ref("anthropic/anthropic-messages@m"),
            Some("anthropic".to_owned())
        );
        assert_eq!(provider_id_from_ref("opaque"), None);
    }

    #[test]
    fn auth_failure_detection_matches_the_server_side_rule() {
        assert!(is_auth_failure_message(Some("auth_required"), None));
        assert!(is_auth_failure_message(Some("AUTH_EXPIRED"), None));
        assert!(is_auth_failure_message(
            Some("HTTP 401 from upstream"),
            None
        ));
        assert!(is_auth_failure_message(Some("Unauthorized"), None));
        assert!(is_auth_failure_message(
            Some("authentication_error"),
            Some("anthropic-messages")
        ));
        assert!(!is_auth_failure_message(
            Some("authentication_error"),
            Some("ollama")
        ));
        assert!(!is_auth_failure_message(Some("rate limited"), None));
        assert!(!is_auth_failure_message(None, None));
    }

    #[test]
    fn tool_messages_keep_their_parts_on_the_wire() {
        let mut tool_message = ChatMessage::new(Role::Tool, "42");
        tool_message.name = Some("lookup".to_owned());
        let request = ExecutionRequest::new("p/a@m", vec![tool_message]);
        let payload = provider_payload(&request, false, None);
        assert_eq!(
            payload["context"]["messages"][0]["content"],
            json!([{ "type": "text", "text": "42" }])
        );
    }

    #[test]
    fn structured_content_survives_the_round_trip() {
        let request = ExecutionRequest::new(
            "p/a@m",
            vec![ChatMessage::user(Content::Parts(vec![
                crate::types::ContentPart::text("look at this"),
            ]))],
        );
        let payload = provider_payload(&request, false, None);
        assert_eq!(
            payload["context"]["messages"][0]["content"],
            json!([{ "type": "text", "text": "look at this" }])
        );
    }
}
