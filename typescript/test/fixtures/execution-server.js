const fs = require("node:fs");
const readline = require("node:readline");

function emit(frame) {
  process.stdout.write(JSON.stringify(frame) + "\n");
}

function loadJson(path, fallback) {
  if (!path) return fallback;
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

function appendLog(path, line) {
  if (!path) return;
  fs.appendFileSync(path, line + "\n");
}

function ack(env) {
  const id = env.stream_id || env.session_id;
  return {
    type: "ack",
    ...(env.stream_id ? { stream_id: env.stream_id } : { session_id: env.session_id }),
    message_id: `${id}-ack`,
    sequence: 2,
    timestamp: Date.now(),
    version: 1,
    in_reply_to: env.message_id,
    payload: { acknowledged_id: env.message_id },
  };
}

function frame(env, type, payload, sequence) {
  const id = env.stream_id || env.session_id;
  return {
    type,
    ...(env.stream_id ? { stream_id: env.stream_id } : { session_id: env.session_id }),
    message_id: `${id}-${sequence}`,
    sequence,
    timestamp: Date.now(),
    version: 1,
    in_reply_to: env.message_id,
    payload,
  };
}

const defaultProviderResult = {
  role: "assistant",
  content: [{ type: "text", text: "hello" }],
  usage: { input: 3, output: 5, cache_read: 1, cache_write: 0 },
  provider_id: "anthropic",
  api: "anthropic-messages",
  model_id: "claude-sonnet-4-5",
  stop_reason: "end_turn",
};

function defaultProviderEventsFor(env) {
  const modelRef = env.payload?.model_ref || "";
  if (modelRef === "test-fixture/test-fixture@fixture-echo-v1") {
    const message = env.payload?.context?.messages?.[0]?.content || "";
    return [
      { type: "message_start", provider_id: "test-fixture", api: "test-fixture", model_id: "fixture-echo-v1" },
      { type: "text_delta", delta: `[fixture-echo-v1] ${String(message).split("").reverse().join("")}` },
      { type: "message_end", usage: { input: 1, output: 1 }, stop_reason: "end_turn" },
    ];
  }
  return [
    { type: "message_start", provider_id: "anthropic", api: "anthropic-messages", model_id: "claude-sonnet-4-5" },
    { type: "text_delta", delta: "hel" },
    { type: "reasoning", delta: "thinking" },
    { type: "text_delta", delta: "lo" },
    { type: "message_end", usage: { input: 3, output: 5 }, stop_reason: "end_turn" },
  ];
}

const configuredProviderEvents = process.env.MAKAI_TEST_PROVIDER_EVENTS_PATH
  ? loadJson(process.env.MAKAI_TEST_PROVIDER_EVENTS_PATH, null)
  : null;

const defaultAgentEvents = [
  { type: "agent_start", session_id: "testNanoIdSess1234567" },
  { type: "turn_start" },
  { type: "message_start", provider_id: "anthropic", api: "anthropic-messages", model_id: "claude-sonnet-4-5" },
  { type: "text_delta", delta: "agent" },
  { type: "tool_execution_start", tool_call_id: "tool-1", tool_name: "lookup" },
  { type: "tool_execution_end", tool_call_id: "tool-1", is_error: false },
  { type: "turn_end", stop_reason: "end_turn" },
  { type: "agent_end", usage: { input: 7, output: 9 }, stop_reason: "end_turn" },
];

emit({ type: "ready", protocol_version: "1" });

const requestLog = process.env.MAKAI_TEST_REQUEST_LOG || "";
const authStatePath = process.env.MAKAI_TEST_AUTH_STATE_PATH || "";
const providerResult = loadJson(process.env.MAKAI_TEST_PROVIDER_RESULT_PATH, defaultProviderResult);
const agentEvents = loadJson(process.env.MAKAI_TEST_AGENT_EVENTS_PATH, defaultAgentEvents);
const agentResult = loadJson(process.env.MAKAI_TEST_AGENT_RESULT_PATH, null);
const agentError = loadJson(process.env.MAKAI_TEST_AGENT_ERROR_PATH, null);
const defaultModelsResponse = {
  models: [{
    model_ref: "anthropic/anthropic-messages@claude-sonnet-4-5",
    model_id: "claude-sonnet-4-5",
    display_name: "Claude Sonnet 4.5",
    provider_id: "anthropic",
    api: "anthropic-messages",
    auth_status: "authenticated",
    lifecycle: "stable",
    capabilities: ["chat", "streaming", "tools", "reasoning"],
    source: "dynamic",
    base_url: "https://api.anthropic.com",
    context_window: 200000,
    max_output_tokens: 8192,
    reasoning_default: "medium",
  }],
  fetched_at_ms: 1,
  cache_max_age_ms: 300000,
};
const modelsResponse = loadJson(process.env.MAKAI_TEST_MODELS_RESPONSE_PATH, defaultModelsResponse);

const requestCounts = new Map();
const authenticatedProviders = new Set();
const authFlows = new Map();

function loadAuthState() {
  if (!authStatePath || !fs.existsSync(authStatePath)) return;
  try {
    const state = JSON.parse(fs.readFileSync(authStatePath, "utf8"));
    for (const providerId of state.authenticatedProviders || []) {
      authenticatedProviders.add(providerId);
    }
  } catch {
    // Ignore corrupt fixture state and behave as logged out.
  }
}

function saveAuthState() {
  if (!authStatePath) return;
  fs.writeFileSync(authStatePath, JSON.stringify({ authenticatedProviders: [...authenticatedProviders] }));
}

loadAuthState();

function shouldAuthReject(envType) {
  if (process.env.MAKAI_TEST_AUTH_REQUIRED_ALWAYS) return true;
  if (!process.env.MAKAI_TEST_AUTH_REQUIRED_ONCE) return false;
  const count = requestCounts.get(envType) || 0;
  requestCounts.set(envType, count + 1);
  return count === 0;
}

function authRequiredPayload() {
  const payload = { error_code: "auth_required", reason: "login required" };
  if (!process.env.MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID) {
    payload.provider_id = "anthropic";
  }
  return payload;
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

rl.on("line", (line) => {
  let env;
  try {
    env = JSON.parse(line);
  } catch {
    return;
  }
  appendLog(requestLog, JSON.stringify(env));
  emit(ack(env));

  if (env.type === "complete_request") {
    if (shouldAuthReject("complete_request")) {
      emit(frame(env, "nack", authRequiredPayload(), 3));
      return;
    }
    if (process.env.MAKAI_TEST_SUPPRESS_COMPLETE_RESPONSE) return;
    emit(frame(env, "result", providerResult, 3));
  } else if (env.type === "stream_request") {
    if (shouldAuthReject("stream_request")) {
      emit(frame(env, "nack", authRequiredPayload(), 3));
      return;
    }
    const providerEvents = configuredProviderEvents ?? defaultProviderEventsFor(env);
    for (let i = 0; i < providerEvents.length; i += 1) {
      const event = providerEvents[i];
      emit(frame(env, event.type, event, i + 3));
    }
  } else if (env.type === "agent_start") {
    if (shouldAuthReject("agent_start")) {
      emit(frame(env, "nack", authRequiredPayload(), 3));
      return;
    }
    emit(frame(env, "agent_started", { session_id: env.session_id }, 3));
  } else if (env.type === "agent_message") {
    if (process.env.MAKAI_TEST_SUPPRESS_AGENT_MESSAGE_RESPONSE) return;
    if (process.env.MAKAI_TEST_AGENT_MALFORMED_RESULT_JSON) {
      emit(frame(env, "agent_result", { result_json: "not-json" }, 3));
    } else if (process.env.MAKAI_TEST_AGENT_MALFORMED_EVENT_JSON) {
      emit(frame(env, "agent_started", { session_id: env.session_id }, 3));
      emit(frame(env, "agent_event", { event_json: "not-json" }, 4));
    } else if (agentError) {
      emit(frame(env, "agent_error", agentError, 3));
    } else if (agentResult) {
      emit(frame(env, "agent_result", { result_json: JSON.stringify(agentResult) }, 3));
    } else {
      for (let i = 0; i < agentEvents.length; i += 1) {
        emit(frame(env, "agent_event", { event_json: JSON.stringify(agentEvents[i]) }, i + 3));
      }
    }
  } else if (env.type === "auth_providers_request") {
    const providers = process.env.MAKAI_TEST_AUTH_REQUIRES_PROMPT ? [
      {
        id: "test-fixture",
        name: "Test Fixture (CI)",
        auth_status: authenticatedProviders.has("test-fixture") ? "authenticated" : "login_required",
      },
      { id: "github-copilot", name: "GitHub Copilot", auth_status: "unknown" },
      { id: "anthropic", name: "Anthropic", auth_status: "unknown" },
    ] : [];
    emit(frame(env, "auth_providers_response", { providers }, 3));
  } else if (env.type === "auth_login_start") {
    const providerId = env.payload?.provider_id || "";
    const flowId = env.stream_id || env.payload?.flow_id || "";
    authFlows.set(flowId, providerId);
    if (process.env.MAKAI_TEST_AUTH_REQUIRES_PROMPT) {
      emit(frame(env, "auth_event", { prompt: { flow_id: flowId, prompt_id: "test-prompt", provider_id: providerId, message: "Enter code", allow_empty: false } }, 3));
    } else {
      authenticatedProviders.add(providerId);
      saveAuthState();
      emit(frame(env, "auth_event", { success: { flow_id: flowId, provider_id: providerId } }, 3));
      emit(frame(env, "auth_login_result", { status: "success", flow_id: flowId, provider_id: providerId }, 4));
    }
  } else if (env.type === "auth_prompt_response") {
    const flowId = env.stream_id || env.payload?.flow_id || "";
    const providerId = authFlows.get(flowId) || env.payload?.provider_id || "test-fixture";
    if (env.payload?.answer === "ok" || env.payload?.answer === "letmein") {
      authenticatedProviders.add(providerId);
      saveAuthState();
      emit(frame(env, "auth_event", { success: { flow_id: flowId, provider_id: providerId } }, 3));
      emit(frame(env, "auth_login_result", { status: "success", flow_id: flowId, provider_id: providerId }, 4));
    } else {
      emit(frame(env, "auth_event", { error: { flow_id: flowId, provider_id: providerId, code: "invalid_code", message: "fixture rejected code" } }, 3));
      emit(frame(env, "auth_login_result", { status: "failed", flow_id: flowId, provider_id: providerId }, 4));
    }
  } else if (env.type === "auth_cancel") {
    const flowId = env.stream_id || env.payload?.flow_id || "";
    const providerId = authFlows.get(flowId) || env.payload?.provider_id || "test-fixture";
    emit(frame(env, "auth_login_result", { status: "cancelled", flow_id: flowId, provider_id: providerId }, 3));
  } else if (env.type === "models_request") {
    emit(frame(env, "models_response", modelsResponse, 3));
  }
});

rl.on("close", () => process.exit(0));
