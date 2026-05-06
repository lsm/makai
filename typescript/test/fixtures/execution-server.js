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
  return {
    type: "ack",
    stream_id: env.stream_id,
    message_id: `${env.stream_id}-ack`,
    sequence: 2,
    timestamp: Date.now(),
    version: 1,
    in_reply_to: env.message_id,
    payload: { acknowledged_id: env.message_id },
  };
}

function frame(env, type, payload, sequence) {
  return {
    type,
    stream_id: env.stream_id,
    message_id: `${env.stream_id}-${sequence}`,
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

const defaultProviderEvents = [
  { type: "message_start", provider_id: "anthropic", api: "anthropic-messages", model_id: "claude-sonnet-4-5" },
  { type: "text_delta", delta: "hel" },
  { type: "reasoning", delta: "thinking" },
  { type: "text_delta", delta: "lo" },
  { type: "message_end", usage: { input: 3, output: 5 }, stop_reason: "end_turn" },
];

const defaultAgentEvents = [
  { type: "agent_start", session_id: "session-1" },
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
const providerResult = loadJson(process.env.MAKAI_TEST_PROVIDER_RESULT_PATH, defaultProviderResult);
const providerEvents = loadJson(process.env.MAKAI_TEST_PROVIDER_EVENTS_PATH, defaultProviderEvents);
const agentEvents = loadJson(process.env.MAKAI_TEST_AGENT_EVENTS_PATH, defaultAgentEvents);
const modelsResponse = loadJson(process.env.MAKAI_TEST_MODELS_RESPONSE_PATH, {
  models: [],
  fetched_at_ms: 1,
  cache_max_age_ms: 300000,
});

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
    emit(frame(env, "result", providerResult, 3));
  } else if (env.type === "stream_request") {
    for (let i = 0; i < providerEvents.length; i += 1) {
      const event = providerEvents[i];
      emit(frame(env, event.type, event, i + 3));
    }
  } else if (env.type === "agent_run_request") {
    for (let i = 0; i < agentEvents.length; i += 1) {
      emit(frame(env, "agent_event", { event_json: JSON.stringify(agentEvents[i]) }, i + 3));
    }
  } else if (env.type === "auth_providers_request") {
    emit(frame(env, "auth_providers_response", { providers: [] }, 3));
  } else if (env.type === "models_request") {
    emit(frame(env, "models_response", modelsResponse, 3));
  }
});

rl.on("close", () => process.exit(0));
