//! A scriptable stand-in for `makai --stdio`.
//!
//! It speaks the same NDJSON protocol but answers from a fixed script instead of
//! a provider, so the SDK's transport, framing, sequencing, error mapping, and
//! cancellation can be tested without credentials or a network. The integration
//! tests drive it; downstream crates can too, by pointing
//! `ClientBuilder::command` at it.
//!
//! Scenarios are selected with `MAKAI_FAKE_SCENARIO`; see [`Scenario`]. Frames it
//! receives are appended to `MAKAI_FAKE_REQUEST_LOG` when that is set, one JSON
//! document per line, so tests can assert on what the SDK actually sent.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::io::{BufRead, BufWriter, Write};

use serde_json::{json, Value};

/// How the fake answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Scenario {
    /// Normal, happy-path answers for every namespace.
    Ok,
    /// No `ready` frame at all; the handshake must time out.
    NoHandshake,
    /// A `ready` frame advertising the wrong protocol version.
    BadVersion,
    /// An `error` frame in place of the handshake.
    HandshakeError,
    /// A line of garbage before `ready`.
    GarbageThenReady,
    /// Exit as soon as the first request arrives.
    DieOnRequest,
    /// Ignore the `ready` handshake's followers: never answer a request.
    Silent,
    /// Reject everything with `auth_required`.
    AuthRequired,
    /// An agent run that asks for a tool, then settles.
    AgentTools,
    /// An agent run whose start is rejected with `agent_busy`.
    AgentBusy,
    /// An agent run that streams for a long time, for cancellation tests.
    AgentSlow,
    /// An agent run that accepts the message and then says nothing, so the
    /// client times out with the message still unresolved.
    AgentSilentAfterMessage,
    /// A provider stream that never terminates, for cancellation tests.
    ProviderSlow,
    /// An interactive login that prompts, then succeeds.
    LoginSuccess,
    /// An interactive login the runtime cancels.
    LoginCancelled,
    /// An interactive login that fails with a detail event.
    LoginFailed,
    /// Structurally invalid answers, for the parser's rejection paths.
    Malformed,
}

impl Scenario {
    fn from_env() -> Self {
        match std::env::var("MAKAI_FAKE_SCENARIO")
            .unwrap_or_default()
            .as_str()
        {
            "no_handshake" => Self::NoHandshake,
            "bad_version" => Self::BadVersion,
            "handshake_error" => Self::HandshakeError,
            "garbage_then_ready" => Self::GarbageThenReady,
            "die_on_request" => Self::DieOnRequest,
            "silent" => Self::Silent,
            "auth_required" => Self::AuthRequired,
            "agent_tools" => Self::AgentTools,
            "agent_busy" => Self::AgentBusy,
            "agent_slow" => Self::AgentSlow,
            "agent_silent_after_message" => Self::AgentSilentAfterMessage,
            "provider_slow" => Self::ProviderSlow,
            "login_success" => Self::LoginSuccess,
            "login_cancelled" => Self::LoginCancelled,
            "login_failed" => Self::LoginFailed,
            "malformed" => Self::Malformed,
            _ => Self::Ok,
        }
    }
}

struct Fake {
    out: BufWriter<std::io::Stdout>,
    scenario: Scenario,
    log: Option<std::fs::File>,
    outbound_sequence: u64,
    cancelled_flows: Vec<String>,
}

impl Fake {
    fn emit(&mut self, frame: Value) {
        let _ = writeln!(self.out, "{frame}");
        let _ = self.out.flush();
    }

    fn next_sequence(&mut self) -> u64 {
        self.outbound_sequence += 1;
        self.outbound_sequence
    }

    fn record(&mut self, line: &str) {
        if let Some(log) = self.log.as_mut() {
            let _ = writeln!(log, "{line}");
            let _ = log.flush();
        }
    }

    fn route(&self, request: &Value) -> Value {
        match (request.get("stream_id"), request.get("session_id")) {
            (Some(stream_id), _) => json!({ "stream_id": stream_id }),
            (_, Some(session_id)) => json!({ "session_id": session_id }),
            _ => json!({}),
        }
    }

    fn frame(&mut self, request: &Value, kind: &str, payload: Value, correlated: bool) -> Value {
        let mut frame = json!({
            "type": kind,
            "message_id": format!("01FAKE{:020}", self.next_sequence()),
            "sequence": self.outbound_sequence,
            "timestamp": 1_760_000_000_000i64,
            "version": 1,
            "payload": payload,
        });
        if let Some(object) = self.route(request).as_object() {
            for (key, value) in object {
                frame[key] = value.clone();
            }
        }
        if correlated {
            if let Some(message_id) = request.get("message_id") {
                frame["in_reply_to"] = message_id.clone();
            }
        }
        frame
    }

    fn reply(&mut self, request: &Value, kind: &str, payload: Value) {
        let frame = self.frame(request, kind, payload, true);
        self.emit(frame);
    }

    /// Asynchronous run output carries no `in_reply_to` (spec §13.3.2).
    fn publish(&mut self, request: &Value, kind: &str, payload: Value) {
        let frame = self.frame(request, kind, payload, false);
        self.emit(frame);
    }

    fn ack(&mut self, request: &Value) {
        let acknowledged = request.get("message_id").cloned().unwrap_or(Value::Null);
        self.reply(request, "ack", json!({ "acknowledged_id": acknowledged }));
    }

    fn nack(&mut self, request: &Value, reason: &str, code: &str) {
        let rejected = request.get("message_id").cloned().unwrap_or(Value::Null);
        self.reply(
            request,
            "nack",
            json!({ "rejected_id": rejected, "reason": reason, "error_code": code }),
        );
    }
}

fn model_descriptor() -> Value {
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
        "context_window": 200_000,
        "max_output_tokens": 8_192,
        "reasoning_default": "medium"
    })
}

fn second_model_descriptor() -> Value {
    let mut model = model_descriptor();
    model["model_ref"] = json!("anthropic/anthropic-messages-v2@claude-sonnet-4-5");
    model["api"] = json!("anthropic-messages-v2");
    model
}

fn main() {
    let scenario = Scenario::from_env();
    let log = std::env::var("MAKAI_FAKE_REQUEST_LOG")
        .ok()
        .and_then(|path| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .ok()
        });

    // Lets a test watch this exact process rather than counting every fake the
    // suite has running in parallel.
    if let Ok(path) = std::env::var("MAKAI_FAKE_PID_FILE") {
        let _ = std::fs::write(path, std::process::id().to_string());
    }

    let mut fake = Fake {
        out: BufWriter::new(std::io::stdout()),
        scenario,
        log,
        outbound_sequence: 0,
        cancelled_flows: Vec::new(),
    };

    match scenario {
        Scenario::NoHandshake => {}
        Scenario::BadVersion => fake.emit(json!({ "type": "ready", "protocol_version": "99" })),
        Scenario::HandshakeError => fake.emit(json!({
            "type": "error",
            "code": "startup_failed",
            "message": "runtime could not start"
        })),
        Scenario::GarbageThenReady => {
            let _ = writeln!(fake.out, "this is not json");
            let _ = fake.out.flush();
            fake.emit(json!({ "type": "ready", "protocol_version": "1" }));
        }
        _ => fake.emit(json!({ "type": "ready", "protocol_version": "1" })),
    }

    if scenario == Scenario::NoHandshake {
        // Stay alive so the client's handshake timeout, not an EOF, is what fails.
        std::thread::sleep(std::time::Duration::from_secs(30));
        return;
    }

    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        fake.record(trimmed);

        let Ok(request) = serde_json::from_str::<Value>(trimmed) else {
            fake.emit(json!({
                "type": "error",
                "code": "dispatch_error",
                "message": "unparseable line"
            }));
            continue;
        };

        if fake.scenario == Scenario::DieOnRequest {
            std::process::exit(7);
        }
        if fake.scenario == Scenario::Silent {
            continue;
        }

        handle(&mut fake, &request);
    }
}

fn handle(fake: &mut Fake, request: &Value) {
    let kind = request.get("type").and_then(Value::as_str).unwrap_or("");
    match kind {
        "models_request" => handle_models(fake, request),
        "auth_providers_request" => handle_auth_providers(fake, request),
        "auth_login_start" => handle_login_start(fake, request),
        "auth_prompt_response" => handle_prompt_response(fake, request),
        "auth_cancel" => handle_auth_cancel(fake, request),
        "complete_request" => handle_complete(fake, request),
        "stream_request" => handle_stream(fake, request),
        "abort_request" => {
            fake.ack(request);
        }
        "agent_start" => handle_agent_start(fake, request),
        "agent_message" => handle_agent_message(fake, request),
        "agent_stop" => handle_agent_stop(fake, request),
        "tool_result" => handle_tool_result(fake, request),
        other => {
            fake.nack(
                request,
                &format!("unknown envelope {other}"),
                "invalid_request",
            );
        }
    }
}

fn handle_models(fake: &mut Fake, request: &Value) {
    if fake.scenario == Scenario::Malformed {
        fake.ack(request);
        fake.reply(
            request,
            "models_response",
            json!({ "models": "not an array" }),
        );
        return;
    }
    if fake.scenario == Scenario::AuthRequired {
        fake.nack(request, "auth_required", "auth_required");
        return;
    }

    let payload = request.get("payload").cloned().unwrap_or(json!({}));
    let model_id = payload.get("model_id").and_then(Value::as_str);
    let api = payload.get("api").and_then(Value::as_str);

    let mut models = vec![model_descriptor(), second_model_descriptor()];
    if let Some(model_id) = model_id {
        models.retain(|model| model["model_id"] == json!(model_id));
        if model_id == "missing" {
            models.clear();
        }
    }
    if let Some(api) = api {
        models.retain(|model| model["api"] == json!(api));
    }
    if payload.get("model_id").is_none() {
        models.truncate(1);
    }

    fake.ack(request);
    fake.reply(
        request,
        "models_response",
        json!({
            "models": models,
            "fetched_at_ms": 1_760_000_000_198i64,
            "cache_max_age_ms": 300_000
        }),
    );
}

fn handle_auth_providers(fake: &mut Fake, request: &Value) {
    if fake.scenario == Scenario::Malformed {
        fake.ack(request);
        fake.reply(request, "auth_providers_response", json!({ "nope": true }));
        return;
    }
    fake.ack(request);
    fake.reply(
        request,
        "auth_providers_response",
        json!({ "providers": [
            { "id": "anthropic", "name": "Anthropic", "auth_status": "login_required" },
            { "id": "openai", "name": "OpenAI", "auth_status": "authenticated" },
            { "id": "future", "name": "Future", "auth_status": "teleported" }
        ]}),
    );
}

fn auth_event(fake: &mut Fake, request: &Value, variant: &str, body: Value) {
    let flow_id = request
        .get("stream_id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let mut event = body;
    event["flow_id"] = json!(flow_id);
    fake.publish(request, "auth_event", json!({ variant: event }));
}

fn handle_login_start(fake: &mut Fake, request: &Value) {
    let provider_id = request
        .get("payload")
        .and_then(|payload| payload.get("provider_id"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    fake.ack(request);

    match fake.scenario {
        Scenario::LoginFailed => {
            auth_event(
                fake,
                request,
                "error",
                json!({ "provider_id": provider_id, "code": "auth_refresh_failed", "message": "refresh token rejected" }),
            );
            fake.publish(
                request,
                "auth_login_result",
                json!({ "provider_id": provider_id, "status": "failed" }),
            );
        }
        Scenario::LoginCancelled => {
            fake.publish(
                request,
                "auth_login_result",
                json!({ "provider_id": provider_id, "status": "cancelled" }),
            );
        }
        _ => {
            auth_event(
                fake,
                request,
                "progress",
                json!({ "provider_id": provider_id, "message": "Auth flow started." }),
            );
            auth_event(
                fake,
                request,
                "auth_url",
                json!({
                    "provider_id": provider_id,
                    "url": "https://example.invalid/login",
                    "instructions": "Enter the code shown in the browser."
                }),
            );
            auth_event(
                fake,
                request,
                "prompt",
                json!({
                    "provider_id": provider_id,
                    "prompt_id": "prompt-1",
                    "message": "Enter code:",
                    "allow_empty": false
                }),
            );
        }
    }
}

fn handle_prompt_response(fake: &mut Fake, request: &Value) {
    let payload = request.get("payload").cloned().unwrap_or(json!({}));
    let answer = payload.get("answer").and_then(Value::as_str).unwrap_or("");
    fake.ack(request);
    if answer == "ok" {
        auth_event(
            fake,
            request,
            "success",
            json!({ "provider_id": "anthropic" }),
        );
        fake.publish(
            request,
            "auth_login_result",
            json!({ "provider_id": "anthropic", "status": "success" }),
        );
    } else {
        auth_event(
            fake,
            request,
            "error",
            json!({ "provider_id": "anthropic", "code": "invalid_code", "message": "wrong code" }),
        );
        fake.publish(
            request,
            "auth_login_result",
            json!({ "provider_id": "anthropic", "status": "failed" }),
        );
    }
}

fn handle_auth_cancel(fake: &mut Fake, request: &Value) {
    let flow_id = request
        .get("stream_id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    if fake.cancelled_flows.contains(&flow_id) {
        return;
    }
    fake.cancelled_flows.push(flow_id);
    fake.publish(
        request,
        "auth_login_result",
        json!({ "provider_id": "anthropic", "status": "cancelled" }),
    );
}

fn handle_complete(fake: &mut Fake, request: &Value) {
    if fake.scenario == Scenario::AuthRequired {
        fake.nack(request, "auth_required", "auth_required");
        return;
    }
    fake.ack(request);
    fake.reply(
        request,
        "result",
        json!({
            "message": {
                "role": "assistant",
                "content": [{ "type": "text", "text": "hello" }],
                "usage": { "input": 3, "output": 5, "cache_read": 1 },
                "provider_id": "anthropic",
                "api": "anthropic-messages",
                "model_id": "claude-sonnet-4-5",
                "stop_reason": "end_turn"
            }
        }),
    );
}

fn handle_stream(fake: &mut Fake, request: &Value) {
    if fake.scenario == Scenario::AuthRequired {
        fake.nack(request, "auth_required", "auth_required");
        return;
    }
    fake.ack(request);
    fake.publish(
        request,
        "event",
        json!({ "event": { "type": "start", "provider_id": "anthropic", "api": "anthropic-messages", "model_id": "claude-sonnet-4-5" }}),
    );
    fake.publish(
        request,
        "event",
        json!({ "event": { "type": "text_delta", "delta": "hel" }}),
    );
    fake.publish(
        request,
        "event",
        json!({ "event": { "type": "reasoning", "delta": "thinking" }}),
    );
    fake.publish(
        request,
        "event",
        json!({ "event": { "type": "toolcall_start", "content_index": 0, "id": "call-1", "name": "lookup" }}),
    );
    fake.publish(
        request,
        "event",
        json!({ "event": { "type": "toolcall_delta", "content_index": 0, "delta": "{\"city\":\"SF\"}" }}),
    );
    fake.publish(
        request,
        "event",
        json!({ "event": { "type": "toolcall_end", "content_index": 0 }}),
    );
    fake.publish(
        request,
        "event",
        json!({ "event": { "type": "text_delta", "delta": "lo" }}),
    );

    if fake.scenario == Scenario::ProviderSlow {
        // Never terminate: the client must be the one to give up or cancel.
        return;
    }

    fake.publish(
        request,
        "event",
        json!({ "event": { "type": "done", "usage": { "input": 3, "output": 5 }, "stop_reason": "end_turn" }}),
    );
}

fn agent_event(fake: &mut Fake, request: &Value, event: Value) {
    fake.publish(
        request,
        "agent_event",
        json!({ "event_json": event.to_string() }),
    );
}

fn handle_agent_start(fake: &mut Fake, request: &Value) {
    if fake.scenario == Scenario::AgentBusy {
        fake.reply(
            request,
            "agent_error",
            json!({ "code": "agent_busy", "message": "session already exists" }),
        );
        return;
    }
    if request.get("sequence").and_then(Value::as_u64) != Some(1) {
        fake.reply(
            request,
            "agent_error",
            json!({ "code": "invalid_request", "message": "agent_start sequence must be 1" }),
        );
        return;
    }
    let session_id = request.get("session_id").cloned().unwrap_or(Value::Null);
    fake.reply(
        request,
        "agent_started",
        json!({ "session_id": session_id }),
    );
}

fn handle_agent_message(fake: &mut Fake, request: &Value) {
    if request.get("sequence").and_then(Value::as_u64) != Some(2) {
        fake.reply(
            request,
            "agent_error",
            json!({ "code": "invalid_request", "message": "agent_message sequence must be 2" }),
        );
        return;
    }
    if fake.scenario == Scenario::AgentSilentAfterMessage {
        // Accepted — so the server's counter has advanced past 2 — but the
        // client is told nothing, which is exactly what the stop probe is for.
        return;
    }
    if fake.scenario == Scenario::AuthRequired {
        agent_event(fake, request, json!({ "type": "agent_start" }));
        agent_event(fake, request, json!({ "type": "turn_start" }));
        agent_event(
            fake,
            request,
            json!({ "type": "turn_end", "stop_reason": "error", "error_message": "auth_required" }),
        );
        fake.publish(
            request,
            "agent_result",
            json!({ "result_json": json!({
                "type": "result",
                "stop_reason": "error",
                "model": "claude-sonnet-4-5",
                "api": "anthropic-messages",
                "provider": "anthropic",
                "input": 0,
                "output": 0,
                "content": [{ "type": "text", "text": "" }],
                "error_message": "auth_required"
            }).to_string() }),
        );
        return;
    }

    agent_event(fake, request, json!({ "type": "agent_start" }));
    agent_event(fake, request, json!({ "type": "turn_start" }));
    agent_event(
        fake,
        request,
        json!({ "type": "message_start", "provider_id": "anthropic", "api": "anthropic-messages", "model_id": "claude-sonnet-4-5" }),
    );

    if fake.scenario == Scenario::AgentTools {
        agent_event(
            fake,
            request,
            json!({ "type": "tool_execution_start", "tool_call_id": "call-1", "tool_name": "lookup" }),
        );
        fake.publish(
            request,
            "tool_execute",
            json!({ "tool_call_id": "call-1", "tool_name": "lookup", "args_json": "{\"city\":\"SF\"}" }),
        );
        return;
    }

    if fake.scenario == Scenario::AgentSlow {
        agent_event(
            fake,
            request,
            json!({ "type": "text_delta", "delta": "slow" }),
        );
        return;
    }

    finish_agent_run(fake, request, None);
}

fn handle_tool_result(fake: &mut Fake, request: &Value) {
    let payload = request.get("payload").cloned().unwrap_or(json!({}));
    let is_error = payload
        .get("is_error")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let result = payload
        .get("result_json")
        .and_then(Value::as_str)
        .unwrap_or("[]")
        .to_owned();
    agent_event(
        fake,
        request,
        json!({ "type": "tool_execution_end", "tool_call_id": "call-1", "is_error": is_error }),
    );
    finish_agent_run(fake, request, Some(result));
}

fn finish_agent_run(fake: &mut Fake, request: &Value, tool_result: Option<String>) {
    let text = match tool_result {
        Some(result) => {
            let parsed: Value = serde_json::from_str(&result).unwrap_or(json!([]));
            let observed = parsed
                .get(0)
                .and_then(|part| part.get("text"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            format!("tool said: {observed}")
        }
        None => "agent done".to_owned(),
    };

    agent_event(
        fake,
        request,
        json!({ "type": "text_delta", "delta": text.clone() }),
    );
    agent_event(
        fake,
        request,
        json!({ "type": "message_end", "usage": { "input": 3, "output": 5 }, "stop_reason": "end_turn" }),
    );
    agent_event(
        fake,
        request,
        json!({ "type": "turn_end", "stop_reason": "end_turn" }),
    );
    fake.publish(
        request,
        "agent_result",
        json!({ "result_json": json!({
            "type": "result",
            "stop_reason": "end_turn",
            "model": "claude-sonnet-4-5",
            "api": "anthropic-messages",
            "provider": "anthropic",
            "input": 3,
            "output": 5,
            "content": [{ "type": "text", "text": text }]
        }).to_string() }),
    );
    // The real runtime queues a terminal `agent_end` behind `agent_result`;
    // a client that does not drain would hand it to the next run on this id.
    agent_event(
        fake,
        request,
        json!({ "type": "agent_end", "stop_reason": "end_turn", "usage": { "input": 3, "output": 5 } }),
    );
}

fn handle_agent_stop(fake: &mut Fake, request: &Value) {
    let sequence = request.get("sequence").and_then(Value::as_u64).unwrap_or(0);
    let expected: u64 = std::env::var("MAKAI_FAKE_EXPECTED_STOP_SEQUENCE")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(sequence);
    if sequence != expected {
        fake.reply(
            request,
            "agent_error",
            json!({ "code": "invalid_request", "message": "out-of-order agent_stop" }),
        );
        return;
    }
    fake.reply(
        request,
        "agent_stopped",
        json!({ "session_id": request.get("session_id") }),
    );
}
