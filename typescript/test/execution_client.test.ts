import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createMakaiAgentApi,
  createMakaiClient,
  createMakaiProviderApi,
  MakaiStdioClient,
  MakaiAuthRequiredError,
  MakaiStreamError,
  type AgentStreamEvent,
  type ProviderStreamEvent,
} from "../src";

const sourceFixturesDir = path.resolve(__dirname, "../../typescript/test/fixtures");
const fixtureScript = path.join(sourceFixturesDir, "execution-server.js");

type Harness = {
  client: MakaiStdioClient;
  tmpDir: string;
  logPath: string;
  cleanup(): Promise<void>;
};

async function setupHarness(envOverrides: NodeJS.ProcessEnv = {}): Promise<Harness> {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-exec-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, ...envOverrides },
    handshakeTimeoutMs: 5000,
  });
  await client.connect();
  return {
    client,
    tmpDir,
    logPath,
    cleanup: async () => {
      await client.close();
      fs.rmSync(tmpDir, { recursive: true, force: true });
    },
  };
}

function request() {
  return {
    model_ref: "anthropic/anthropic-messages@opaque-model-ref-with%3Acolon",
    messages: [{ role: "user" as const, content: "hello" }],
    options: { temperature: 0.2, session_id: "testNanoIdSess1234567" },
  };
}

function readLoggedRequests(logPath: string): Array<Record<string, unknown>> {
  if (!fs.existsSync(logPath)) return [];
  return fs.readFileSync(logPath, "utf8").trim().split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
}

async function collect<T>(iterable: AsyncIterable<T>): Promise<T[]> {
  const out: T[] = [];
  for await (const item of iterable) out.push(item);
  return out;
}

test("client.provider.complete resolves with correct CompletionResponse shape", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    const result = await provider.complete(request());

    assert.equal(result.message.role, "assistant");
    assert.deepEqual(result.message.content, [{ type: "text", text: "hello" }]);
    assert.deepEqual(result.usage, { input: 3, output: 5, cache_read: 1, cache_write: 0 });
    assert.equal(result.provider_id, "anthropic");
    assert.equal(result.api, "anthropic-messages");
    assert.equal(result.model_id, "claude-sonnet-4-5");
    assert.equal(result.stop_reason, "end_turn");

    const logged = readLoggedRequests(harness.logPath);
    assert.equal(logged[0]?.type, "complete_request");
    const payload = logged[0]?.payload as Record<string, unknown>;
    assert.deepEqual(payload.model, {
      id: "opaque-model-ref-with:colon",
      name: "opaque-model-ref-with:colon",
      api: "anthropic-messages",
      provider: "anthropic",
      base_url: "",
    });
    assert.equal(payload.model_ref, request().model_ref);
    assert.deepEqual((payload.context as Record<string, unknown>).messages, request().messages);
  } finally {
    await harness.cleanup();
  }
});

test("client.provider.complete keeps routing fields for non-canonical model_ref", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    await provider.complete({ ...request(), model_ref: "anthropic/anthropic-messages@opaque-model-ref-with:colon" });

    const payload = readLoggedRequests(harness.logPath)[0]?.payload as Record<string, unknown>;
    assert.deepEqual(payload.model, {
      id: "opaque-model-ref-with:colon",
      name: "opaque-model-ref-with:colon",
      api: "anthropic-messages",
      provider: "anthropic",
      base_url: "",
    });
    assert.equal(payload.model_ref, "anthropic/anthropic-messages@opaque-model-ref-with:colon");
  } finally {
    await harness.cleanup();
  }
});

test("client.provider.complete maps system prompts and tool messages into provider context", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    await provider.complete({
      model_ref: "anthropic/anthropic-messages@opaque-model-ref-with%3Acolon",
      messages: [
        { role: "system", content: "You are helpful." },
        { role: "developer", content: [{ type: "text", text: "Prefer concise answers." }] },
        { role: "user", content: "hello" },
        { role: "tool", tool_call_id: "call-1", name: "lookup", content: "tool result" },
      ],
    });

    const payload = readLoggedRequests(harness.logPath)[0]?.payload as Record<string, unknown>;
    const context = payload.context as Record<string, unknown>;
    assert.equal(context.system_prompt, "You are helpful.\n\nPrefer concise answers.");
    assert.deepEqual(context.messages, [
      { role: "user", content: "hello" },
      {
        role: "tool",
        content: [{ type: "text", text: "tool result" }],
        name: "lookup",
        tool_name: "lookup",
        tool_call_id: "call-1",
      },
    ]);
  } finally {
    await harness.cleanup();
  }
});

test("provider.complete timeout includes actionable diagnostics", async () => {
  const harness = await setupHarness({ MAKAI_TEST_SUPPRESS_COMPLETE_RESPONSE: "1" });
  try {
    const provider = createMakaiProviderApi(harness.client, { responseTimeoutMs: 20 });
    await assert.rejects(
      () => provider.complete(request()),
      (err: unknown) =>
        err instanceof MakaiStreamError &&
        err.kind === "transport_error" &&
        err.message.includes("Timed out waiting for provider complete_response after 20ms for provider 'anthropic'") &&
        err.message.includes("model_ref='anthropic/anthropic-messages@opaque-model-ref-with%3Acolon'") &&
        err.message.includes("stream_id=") &&
        err.message.includes("message_id=") &&
        err.message.includes("Check network connectivity") &&
        err.diagnostics?.operation === "provider complete_response" &&
        err.diagnostics.timeout_ms === 20 &&
        err.diagnostics.provider_id === "anthropic" &&
        err.diagnostics.api === "anthropic-messages" &&
        err.diagnostics.model_id === "opaque-model-ref-with:colon" &&
        typeof err.diagnostics.stream_id === "string" &&
        err.diagnostics.message_id === err.diagnostics.stream_id,
    );
  } finally {
    await harness.cleanup();
  }
});

test("client.provider.stream yields ProviderStreamEvent sequence including message_end", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    const events = await collect(provider.stream(request()));
    assert.deepEqual(events, [
      { type: "message_start", provider_id: "anthropic", api: "anthropic-messages", model_id: "claude-sonnet-4-5" },
      { type: "text_delta", delta: "hel" },
      { type: "thinking_delta", delta: "thinking" },
      { type: "text_delta", delta: "lo" },
      { type: "message_end", usage: { input: 3, output: 5 }, stop_reason: "end_turn" },
    ] satisfies ProviderStreamEvent[]);
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run resolves with correct AgentRunResponse", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-result-test-"));
  const resultPath = path.join(tmpDir, "agent-result.json");
  fs.writeFileSync(resultPath, JSON.stringify({
    messages: [{
      role: "assistant",
      content: [
        { type: "text", text: "Use this tool" },
        { type: "tool_call", id: "call-1", name: "lookup", arguments_json: "{\"q\":\"makai\"}" },
      ],
      usage: { input: 7, output: 9 },
      provider: "anthropic",
      api: "anthropic-messages",
      model: "claude-sonnet-4-5",
      stop_reason: "tool_use",
    }],
  }));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_RESULT_PATH: resultPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const result = await agent.run(request());
    assert.deepEqual(result.message.content, [
      { type: "text", text: "Use this tool" },
      { type: "tool_call", tool_call_id: "call-1", name: "lookup", arguments_json: "{\"q\":\"makai\"}" },
    ]);
    assert.deepEqual(result.usage, { input: 7, output: 9 });
    assert.equal(result.provider_id, "anthropic");
    assert.equal(result.api, "anthropic-messages");
    assert.equal(result.model_id, "claude-sonnet-4-5");
    assert.equal(result.stop_reason, "tool_use");
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("agent.run timeout includes actionable diagnostics", async () => {
  const harness = await setupHarness({ MAKAI_TEST_SUPPRESS_AGENT_MESSAGE_RESPONSE: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client, { responseTimeoutMs: 20 });
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) =>
        err instanceof MakaiStreamError &&
        err.kind === "transport_error" &&
        err.message.includes("Timed out waiting for agent result after 20ms for provider 'anthropic'") &&
        err.message.includes("session_id=testNanoIdSess1234567") &&
        err.message.includes("Verify the makai binary") &&
        err.diagnostics?.operation === "agent result" &&
        err.diagnostics.timeout_ms === 20 &&
        err.diagnostics.provider_id === "anthropic" &&
        err.diagnostics.api === "anthropic-messages" &&
        err.diagnostics.model_id === "opaque-model-ref-with:colon" &&
        err.diagnostics.session_id === "testNanoIdSess1234567",
    );
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run rejects non-NanoID session IDs before transport I/O", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      () => agent.run({ ...request(), options: { ...request().options, session_id: "session-1" } }),
      (err: unknown) => err instanceof TypeError && err.message === "request.options.session_id must be a 21-character alphanumeric NanoID for agent transport",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.stream rejects non-NanoID session IDs before transport I/O", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      async () => collect(agent.stream({ ...request(), options: { ...request().options, session_id: "session-1" } })),
      (err: unknown) => err instanceof TypeError && err.message === "request.options.session_id must be a 21-character alphanumeric NanoID for agent transport",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run rejects UUID session IDs", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      () => agent.run({ ...request(), options: { ...request().options, session_id: "01890f3e-7b62-7cc4-8f68-7a6f6a1b1234" } }),
      (err: unknown) => err instanceof TypeError && err.message === "request.options.session_id must be a 21-character alphanumeric NanoID for agent transport",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run accepts valid NanoID session IDs", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-nanoid-session-test-"));
  const resultPath = path.join(tmpDir, "agent-result.json");
  fs.writeFileSync(resultPath, JSON.stringify({
    messages: [{
      role: "assistant",
      content: "ok",
      usage: { input: 1, output: 1 },
      provider: "anthropic",
      api: "anthropic-messages",
      model: "claude-sonnet-4-5",
      stop_reason: "end_turn",
    }],
  }));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_RESULT_PATH: resultPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const nanoId = "abcABC123xyzXYZ789mno";
    await agent.run({ ...request(), options: { ...request().options, session_id: nanoId } });
    assert.equal(readLoggedRequests(harness.logPath)[0]?.session_id, nanoId);
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.stream yields agent lifecycle events in order", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    const events = await collect(agent.stream(request()));
    assert.deepEqual(events.map((event) => event.type), [
      "agent_start",
      "turn_start",
      "message_start",
      "text_delta",
      "tool_execution_start",
      "tool_execution_end",
      "turn_end",
      "agent_end",
    ]);
    assert.deepEqual(events[0], { type: "agent_start", session_id: "testNanoIdSess1234567" } satisfies AgentStreamEvent);
    assert.deepEqual(events.at(-1), { type: "agent_end", usage: { input: 7, output: 9 }, stop_reason: "end_turn" } satisfies AgentStreamEvent);

    const logged = readLoggedRequests(harness.logPath);
    assert.equal(logged[0]?.type, "agent_start");
    assert.equal(typeof logged[0]?.session_id, "string");
    assert.equal(logged[0]?.stream_id, undefined);
    assert.equal(logged[1]?.type, "agent_message");
    assert.equal(logged[1]?.session_id, logged[0]?.session_id);
    assert.equal(logged[1]?.stream_id, undefined);
    assert.deepEqual(JSON.parse(((logged[1]?.payload as Record<string, unknown>).message_json as string)).messages, request().messages);
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run event fallback returns only final assistant turn content", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-final-turn-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([
    { type: "agent_start", session_id: "session-1" },
    { type: "turn_start" },
    { type: "message_start", provider_id: "anthropic", api: "anthropic-messages", model_id: "claude-sonnet-4-5" },
    { type: "text_delta", delta: "lookup first" },
    { type: "tool_call", tool_call_id: "call-1", name: "lookup", arguments_json: "{\"q\":\"makai\"}" },
    { type: "message_end", usage: { input: 5, output: 6 }, stop_reason: "tool_use" },
    { type: "turn_end", stop_reason: "tool_use" },
    { type: "turn_start" },
    { type: "message_start", provider_id: "anthropic", api: "anthropic-messages", model_id: "claude-sonnet-4-5" },
    { type: "text_delta", delta: "final answer" },
    { type: "message_end", usage: { input: 7, output: 9 }, stop_reason: "end_turn" },
    { type: "turn_end", stop_reason: "end_turn" },
    { type: "agent_end", usage: { input: 7, output: 9 }, stop_reason: "end_turn" },
  ]));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_EVENTS_PATH: eventsPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const result = await agent.run(request());
    assert.equal(result.message.content, "final answer");
    assert.deepEqual(result.usage, { input: 7, output: 9 });
    assert.equal(result.provider_id, "anthropic");
    assert.equal(result.api, "anthropic-messages");
    assert.equal(result.model_id, "claude-sonnet-4-5");
    assert.equal(result.stop_reason, "end_turn");
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.provider.stream buffers incremental tool calls into one tool_call event", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-tool-buffer-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([
    { type: "message_start", provider_id: "anthropic", api: "anthropic-messages", model_id: "claude-sonnet-4-5" },
    { type: "toolcall_start", content_index: 0, id: "call-1", name: "lookup" },
    { type: "toolcall_delta", content_index: 0, delta: "{\"q\":" },
    { type: "toolcall_delta", content_index: 0, delta: "\"makai\"}" },
    { type: "toolcall_end", content_index: 0 },
    { type: "message_end", usage: { input: 3, output: 5 }, stop_reason: "tool_use" },
  ]));
  const harness = await setupHarness({ MAKAI_TEST_PROVIDER_EVENTS_PATH: eventsPath });
  try {
    const provider = createMakaiProviderApi(harness.client);
    const events = await collect(provider.stream(request()));
    assert.deepEqual(events.map((event) => event.type), ["message_start", "tool_call", "message_end"]);
    assert.deepEqual(events[1], {
      type: "tool_call",
      tool_call_id: "call-1",
      name: "lookup",
      arguments_json: "{\"q\":\"makai\"}",
    });

    const payload = readLoggedRequests(harness.logPath)[0]?.payload as Record<string, unknown>;
    assert.equal(payload.include_partial, false);
    assert.deepEqual(payload.model, {
      id: "opaque-model-ref-with:colon",
      name: "opaque-model-ref-with:colon",
      api: "anthropic-messages",
      provider: "anthropic",
      base_url: "",
    });
    assert.deepEqual((payload.context as Record<string, unknown>).messages, request().messages);
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("stream error paths emit one terminal error event", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-exec-error-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([{ type: "message_start" }, { type: "error", message: "boom", code: "provider_error" }]));
  const harness = await setupHarness({ MAKAI_TEST_PROVIDER_EVENTS_PATH: eventsPath });
  try {
    const provider = createMakaiProviderApi(harness.client);
    const events = await collect(provider.stream(request()));
    assert.equal(events.filter((event) => event.type === "error").length, 1);
    assert.deepEqual(events.at(-1), { type: "error", message: "boom", code: "provider_error" });
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("provider stream_error frames preserve MakaiStreamError code", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-stream-error-code-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([{ type: "stream_error", message: "login required", code: "auth_required" }]));
  const harness = await setupHarness({ MAKAI_TEST_PROVIDER_EVENTS_PATH: eventsPath });
  try {
    const provider = createMakaiProviderApi(harness.client);
    await assert.rejects(
      async () => collect(provider.stream(request())),
      (err: unknown) => err instanceof MakaiStreamError && err.message === "login required" && err.code === "auth_required",
    );
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("agent stream error paths emit one terminal error event", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-error-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([{ type: "agent_start" }, { type: "error", message: "agent boom", code: "provider_error" }]));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_EVENTS_PATH: eventsPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const events = await collect(agent.stream(request()));
    assert.equal(events.filter((event) => event.type === "error").length, 1);
    assert.equal(events.some((event) => event.type === "agent_end"), false);
    assert.deepEqual(events.at(-1), { type: "error", message: "agent boom", code: "provider_error" });
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run throws MakaiStreamError on malformed result_json", async () => {
  const harness = await setupHarness({ MAKAI_TEST_AGENT_MALFORMED_RESULT_JSON: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.message === "malformed JSON in result_json" && err.kind === "transport_error",
    );
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.stream throws MakaiStreamError on malformed event_json", async () => {
  const harness = await setupHarness({ MAKAI_TEST_AGENT_MALFORMED_EVENT_JSON: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      async () => collect(agent.stream(request())),
      (err: unknown) => err instanceof MakaiStreamError && err.message === "malformed JSON in event_json" && err.kind === "transport_error",
    );
  } finally {
    await harness.cleanup();
  }
});

test("createMakaiClient wires all namespaces correctly", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-client-wiring-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    assert.equal(typeof handle.auth.listProviders, "function");
    assert.equal(typeof handle.models.list, "function");
    assert.equal(typeof handle.provider.complete, "function");
    assert.equal(typeof handle.provider.stream, "function");
    assert.equal(typeof handle.agent.run, "function");
    assert.equal(typeof handle.agent.stream, "function");
    assert.deepEqual(await handle.auth.listProviders(), []);
    assert.equal(Array.isArray((await handle.models.list()).models), true);
    await collect(handle.provider.stream(request()));
    const streamRequest = readLoggedRequests(logPath).find((entry) => entry.type === "stream_request");
    assert.equal(((streamRequest?.payload as Record<string, unknown>).options as Record<string, unknown>).auth_retry_policy, "auto_once");
    assert.equal(((streamRequest?.payload as Record<string, unknown>).model as Record<string, unknown>).api, "anthropic-messages");
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.provider.stream normalizes top-level start frame to message_start", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-start-frame-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([
    { type: "start", provider_id: "anthropic", api: "anthropic-messages", model_id: "claude-sonnet-4-5" },
    { type: "text_delta", delta: "hello" },
    { type: "done", usage: { input: 3, output: 5 }, stop_reason: "end_turn" },
  ]));
  const harness = await setupHarness({ MAKAI_TEST_PROVIDER_EVENTS_PATH: eventsPath });
  try {
    const provider = createMakaiProviderApi(harness.client);
    const events = await collect(provider.stream(request()));
    assert.deepEqual(events, [
      { type: "message_start", provider_id: "anthropic", api: "anthropic-messages", model_id: "claude-sonnet-4-5" },
      { type: "text_delta", delta: "hello" },
      { type: "message_end", usage: { input: 3, output: 5 }, stop_reason: "end_turn" },
    ] satisfies ProviderStreamEvent[]);
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.provider.complete auto_once retries on auth_required nack and succeeds", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-complete-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const result = await handle.provider.complete(request());
    assert.deepEqual(result.message.content, [{ type: "text", text: "hello" }]);
    const logged = readLoggedRequests(logPath);
    const completeRequests = logged.filter((entry) => entry.type === "complete_request");
    assert.equal(completeRequests.length, 2);
    assert.equal(completeRequests[0]?.type, "complete_request");
    assert.equal(completeRequests[1]?.type, "complete_request");
    const loginStarts = logged.filter((entry) => entry.type === "auth_login_start");
    assert.equal(loginStarts.length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.provider.stream auto_once retries on auth_required nack and yields events", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-stream-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const events = await collect(handle.provider.stream(request()));
    assert.equal(events[0]?.type, "message_start");
    const logged = readLoggedRequests(logPath);
    const streamRequests = logged.filter((entry) => entry.type === "stream_request");
    assert.equal(streamRequests.length, 2);
    const loginStarts = logged.filter((entry) => entry.type === "auth_login_start");
    assert.equal(loginStarts.length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.provider.complete auto_once retries at most once when auth_required persists", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-complete-limit-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ALWAYS: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    await assert.rejects(
      () => handle.provider.complete(request()),
      (err: unknown) => err instanceof MakaiAuthRequiredError && err.provider_id === "anthropic",
    );
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "complete_request").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.provider.stream auto_once retries at most once when auth_required persists", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-stream-limit-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ALWAYS: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    await assert.rejects(
      async () => collect(handle.provider.stream(request())),
      (err: unknown) => err instanceof MakaiStreamError && err.code === "auth_required",
    );
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "stream_request").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run auto_once retries on auth_required nack and succeeds", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-agent-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const resultPath = path.join(tmpDir, "agent-result.json");
  fs.writeFileSync(resultPath, JSON.stringify({
    messages: [{
      role: "assistant",
      content: "ok",
      usage: { input: 1, output: 1 },
      provider: "anthropic",
      api: "anthropic-messages",
      model: "claude-sonnet-4-5",
      stop_reason: "end_turn",
    }],
  }));
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AGENT_RESULT_PATH: resultPath },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const result = await handle.agent.run(request());
    assert.equal(result.message.content, "ok");
    const logged = readLoggedRequests(logPath);
    const agentStarts = logged.filter((entry) => entry.type === "agent_start");
    assert.equal(agentStarts.length, 2);
    const loginStarts = logged.filter((entry) => entry.type === "auth_login_start");
    assert.equal(loginStarts.length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run auto_once retries at most once when auth_required persists", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-agent-limit-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ALWAYS: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    await assert.rejects(
      () => handle.agent.run(request()),
      (err: unknown) => err instanceof MakaiAuthRequiredError && err.provider_id === "anthropic",
    );
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "agent_start").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run auto_once uses fresh session_id on retry", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-agent-session-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const resultPath = path.join(tmpDir, "agent-result.json");
  fs.writeFileSync(resultPath, JSON.stringify({
    messages: [{
      role: "assistant",
      content: "ok",
      usage: { input: 1, output: 1 },
      provider: "anthropic",
      api: "anthropic-messages",
      model: "claude-sonnet-4-5",
      stop_reason: "end_turn",
    }],
  }));
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AGENT_RESULT_PATH: resultPath },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    await handle.agent.run(request());
    const logged = readLoggedRequests(logPath);
    const agentStarts = logged.filter((entry) => entry.type === "agent_start");
    assert.equal(agentStarts.length, 2);
    const firstSessionId = agentStarts[0]?.session_id;
    const secondSessionId = agentStarts[1]?.session_id;
    assert.equal(firstSessionId, "testNanoIdSess1234567");
    assert.notEqual(secondSessionId, firstSessionId);
    assert.match(secondSessionId as string, /^[0-9A-Za-z]{21}$/);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("manual auth_retry_policy does not retry on auth_required", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-manual-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "manual" },
  });
  try {
    await assert.rejects(
      () => handle.provider.complete(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.code === "auth_required" && err.provider_id === "anthropic",
    );
    const logged = readLoggedRequests(logPath);
    const completeRequests = logged.filter((entry) => entry.type === "complete_request");
    assert.equal(completeRequests.length, 1);
    const loginStarts = logged.filter((entry) => entry.type === "auth_login_start");
    assert.equal(loginStarts.length, 0);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("auto_once normalizes login failure to auth_required with partial handlers", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-fail-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRES_PROMPT: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once", handlers: { onEvent: () => undefined } },
  });
  try {
    await assert.rejects(
      () => handle.provider.complete(request()),
      (err: unknown) => err instanceof MakaiAuthRequiredError && err.provider_id === "anthropic",
    );
    const logged = readLoggedRequests(logPath);
    const completeRequests = logged.filter((entry) => entry.type === "complete_request");
    assert.equal(completeRequests.length, 1);
    const loginStarts = logged.filter((entry) => entry.type === "auth_login_start");
    assert.equal(loginStarts.length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("manual policy backfills provider_id on auth_required nack missing provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-manual-backfill-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "manual" },
  });
  try {
    await assert.rejects(
      () => handle.provider.complete(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.code === "auth_required" && err.provider_id === "anthropic",
    );
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "complete_request").length, 1);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 0);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("manual policy backfills provider_id on auth_required stream nack missing provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-manual-backfill-stream-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "manual" },
  });
  try {
    await assert.rejects(
      async () => {
        for await (const _event of handle.provider.stream(request())) {
          // no-op
        }
      },
      (err: unknown) => err instanceof MakaiStreamError && err.code === "auth_required" && err.provider_id === "anthropic",
    );
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "stream_request").length, 1);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 0);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("manual policy backfills provider_id on agent run auth_required nack missing provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-manual-backfill-agent-run-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "manual" },
  });
  try {
    await assert.rejects(
      () => handle.agent.run(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.code === "auth_required" && err.provider_id === "anthropic",
    );
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "agent_start").length, 1);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 0);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("manual policy backfills provider_id on agent stream auth_required nack missing provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-manual-backfill-agent-stream-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "manual" },
  });
  try {
    await assert.rejects(
      async () => {
        for await (const _event of handle.agent.stream(request())) {
          // no-op
        }
      },
      (err: unknown) => err instanceof MakaiStreamError && err.code === "auth_required" && err.provider_id === "anthropic",
    );
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "agent_start").length, 1);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 0);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("manual policy backfills provider_id for non-canonical model_ref on auth_required nack", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-manual-backfill-noncanon-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "manual" },
  });
  try {
    await assert.rejects(
      () => handle.provider.complete({
        model_ref: "anthropic/anthropic-messages@opaque-model-ref-with:colon",
        messages: [{ role: "user" as const, content: "hello" }],
      }),
      (err: unknown) => err instanceof MakaiStreamError && err.code === "auth_required" && err.provider_id === "anthropic",
    );
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "complete_request").length, 1);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 0);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.stream auto_once retries on auth_required nack and yields events", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-agent-stream-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const events = await collect(handle.agent.stream(request()));
    assert.equal(events[0]?.type, "agent_start");
    const logged = readLoggedRequests(logPath);
    const agentStarts = logged.filter((entry) => entry.type === "agent_start");
    assert.equal(agentStarts.length, 2);
    const loginStarts = logged.filter((entry) => entry.type === "auth_login_start");
    assert.equal(loginStarts.length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.stream auto_once uses fresh session_id on retry", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-agent-stream-session-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    await collect(handle.agent.stream(request()));
    const logged = readLoggedRequests(logPath);
    const agentStarts = logged.filter((entry) => entry.type === "agent_start");
    assert.equal(agentStarts.length, 2);
    const firstSessionId = agentStarts[0]?.session_id;
    const secondSessionId = agentStarts[1]?.session_id;
    assert.equal(firstSessionId, "testNanoIdSess1234567");
    assert.notEqual(secondSessionId, firstSessionId);
    assert.match(secondSessionId as string, /^[0-9A-Za-z]{21}$/);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.stream auto_once retries at most once when auth_required persists", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-agent-stream-limit-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ALWAYS: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    await assert.rejects(
      async () => collect(handle.agent.stream(request())),
      (err: unknown) => err instanceof MakaiStreamError && err.code === "auth_required",
    );
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "agent_start").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("per-request manual auth_retry_policy overrides client auto_once", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-override-manual-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    await assert.rejects(
      () => handle.provider.complete({ ...request(), options: { auth_retry_policy: "manual" } }),
      (err: unknown) => err instanceof MakaiStreamError && err.code === "auth_required",
    );
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "complete_request").length, 1);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 0);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("per-request auto_once auth_retry_policy overrides client manual", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-override-auto-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "manual" },
  });
  try {
    const result = await handle.provider.complete({ ...request(), options: { auth_retry_policy: "auto_once" } });
    assert.deepEqual(result.message.content, [{ type: "text", text: "hello" }]);
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "complete_request").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.provider.complete auto_once retries when error lacks provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-no-pid-complete-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const result = await handle.provider.complete(request());
    assert.deepEqual(result.message.content, [{ type: "text", text: "hello" }]);
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "complete_request").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.provider.stream auto_once retries when error lacks provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-no-pid-stream-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const events = await collect(handle.provider.stream(request()));
    assert.equal(events[0]?.type, "message_start");
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "stream_request").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run auto_once retries when error lacks provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-no-pid-agent-run-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const resultPath = path.join(tmpDir, "agent-result.json");
  fs.writeFileSync(resultPath, JSON.stringify({
    messages: [{
      role: "assistant",
      content: "ok",
      usage: { input: 1, output: 1 },
      provider: "anthropic",
      api: "anthropic-messages",
      model: "claude-sonnet-4-5",
      stop_reason: "end_turn",
    }],
  }));
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1", MAKAI_TEST_AGENT_RESULT_PATH: resultPath },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const result = await handle.agent.run(request());
    assert.equal(result.message.content, "ok");
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "agent_start").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.stream auto_once retries when error lacks provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-no-pid-agent-stream-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const events = await collect(handle.agent.stream(request()));
    assert.equal(events[0]?.type, "agent_start");
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "agent_start").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.provider.complete auto_once retries for non-canonical model_ref when error lacks provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-noncanon-complete-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const result = await handle.provider.complete({
      model_ref: "anthropic/anthropic-messages@opaque-model-ref-with:colon",
      messages: [{ role: "user" as const, content: "hello" }],
    });
    assert.deepEqual(result.message.content, [{ type: "text", text: "hello" }]);
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "complete_request").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
    const login = logged.find((entry) => entry.type === "auth_login_start");
    assert.equal((login?.payload as Record<string, unknown>)?.provider_id, "anthropic");
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.provider.stream auto_once retries for non-canonical model_ref when error lacks provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-noncanon-stream-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const events = await collect(handle.provider.stream({
      model_ref: "anthropic/anthropic-messages@opaque-model-ref-with:colon",
      messages: [{ role: "user" as const, content: "hello" }],
    }));
    assert.equal(events[0]?.type, "message_start");
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "stream_request").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
    const login = logged.find((entry) => entry.type === "auth_login_start");
    assert.equal((login?.payload as Record<string, unknown>)?.provider_id, "anthropic");
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run auto_once retries for non-canonical model_ref when error lacks provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-noncanon-agent-run-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const resultPath = path.join(tmpDir, "agent-result.json");
  fs.writeFileSync(resultPath, JSON.stringify({
    messages: [{
      role: "assistant",
      content: "ok",
      usage: { input: 1, output: 1 },
      provider: "anthropic",
      api: "anthropic-messages",
      model: "claude-sonnet-4-5",
      stop_reason: "end_turn",
    }],
  }));
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1", MAKAI_TEST_AGENT_RESULT_PATH: resultPath },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const result = await handle.agent.run({
      model_ref: "anthropic/anthropic-messages@opaque-model-ref-with:colon",
      messages: [{ role: "user" as const, content: "hello" }],
    });
    assert.equal(result.message.content, "ok");
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "agent_start").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
    const login = logged.find((entry) => entry.type === "auth_login_start");
    assert.equal((login?.payload as Record<string, unknown>)?.provider_id, "anthropic");
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.stream auto_once retries for non-canonical model_ref when error lacks provider_id", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-retry-noncanon-agent-stream-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AUTH_REQUIRED_NO_PROVIDER_ID: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const events = await collect(handle.agent.stream({
      model_ref: "anthropic/anthropic-messages@opaque-model-ref-with:colon",
      messages: [{ role: "user" as const, content: "hello" }],
    }));
    assert.equal(events[0]?.type, "agent_start");
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "agent_start").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
    const login = logged.find((entry) => entry.type === "auth_login_start");
    assert.equal((login?.payload as Record<string, unknown>)?.provider_id, "anthropic");
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("agent_start payload includes resume_session_id", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    await collect(agent.stream(request()));
    const logged = readLoggedRequests(harness.logPath);
    const start = logged.find((entry) => entry.type === "agent_start");
    assert.ok(start);
    const payload = start?.payload as Record<string, unknown>;
    assert.equal(payload.resume_session_id, "testNanoIdSess1234567");
  } finally {
    await harness.cleanup();
  }
});

test("acceptance: OAuth, model discovery, and provider execution share provider-agnostic client path", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-acceptance-provider-path-"));
  const logPath = path.join(tmpDir, "request.log");
  const authStatePath = path.join(tmpDir, "auth-state.json");
  const model = {
    model_ref: "anthropic/anthropic-messages@claude-sonnet-4-5",
    model_id: "claude-sonnet-4-5",
    display_name: "Claude Sonnet 4.5",
    provider_id: "anthropic",
    api: "anthropic-messages",
    auth_status: "authenticated" as const,
    lifecycle: "stable" as const,
    capabilities: ["chat", "streaming", "tools", "reasoning"] as const,
    source: "dynamic" as const,
  };
  const modelsPath = path.join(tmpDir, "models.json");
  fs.writeFileSync(modelsPath, JSON.stringify({ models: [model], fetched_at_ms: 1, cache_max_age_ms: 300000 }));

  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: {
      ...process.env,
      MAKAI_TEST_REQUEST_LOG: logPath,
      MAKAI_TEST_AUTH_STATE_PATH: authStatePath,
      MAKAI_TEST_AUTH_REQUIRES_PROMPT: "1",
      MAKAI_TEST_MODELS_RESPONSE_PATH: modelsPath,
    },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "manual" },
  });
  try {
    await handle.auth.login("test-fixture", { onPrompt: () => "ok" });
    const listed = await handle.models.list({ provider_id: "anthropic" });
    assert.deepEqual(listed.models[0], model);

    const selectedModelRef = listed.models[0]!.model_ref;
    const result = await handle.provider.complete({
      model_ref: selectedModelRef,
      messages: [{ role: "user", content: "hello" }],
    });
    assert.deepEqual(result.message.content, [{ type: "text", text: "hello" }]);

    const logged = readLoggedRequests(logPath);
    assert.equal(logged.some((entry) => entry.type === "auth_login_start"), true);
    assert.equal(logged.some((entry) => entry.type === "models_request"), true);
    const completePayload = logged.find((entry) => entry.type === "complete_request")?.payload as Record<string, unknown>;
    assert.equal(completePayload.model_ref, selectedModelRef);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("acceptance: provider and agent model lists have identical output shape", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-acceptance-model-shape-"));
  const logPath = path.join(tmpDir, "request.log");
  const model = {
    model_ref: "anthropic/anthropic-messages@claude-sonnet-4-5",
    model_id: "claude-sonnet-4-5",
    display_name: "Claude Sonnet 4.5",
    provider_id: "anthropic",
    api: "anthropic-messages",
    auth_status: "authenticated" as const,
    lifecycle: "stable" as const,
    capabilities: ["chat", "streaming"] as const,
    source: "dynamic" as const,
  };
  const modelsPath = path.join(tmpDir, "models.json");
  fs.writeFileSync(modelsPath, JSON.stringify({ models: [model], fetched_at_ms: 7, cache_max_age_ms: 300000 }));
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_MODELS_RESPONSE_PATH: modelsPath },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
  });
  try {
    assert.deepEqual(await handle.models.list(), await handle.agent.models.list());
    assert.equal(readLoggedRequests(logPath).filter((entry) => entry.type === "models_request").length, 2);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("acceptance: provider and agent execution accept the same model_ref", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-acceptance-shared-model-ref-"));
  const logPath = path.join(tmpDir, "request.log");
  const resultPath = path.join(tmpDir, "agent-result.json");
  fs.writeFileSync(resultPath, JSON.stringify({
    messages: [{
      role: "assistant",
      content: "ok",
      usage: { input: 1, output: 1 },
      provider: "anthropic",
      api: "anthropic-messages",
      model: "claude-sonnet-4-5",
      stop_reason: "end_turn",
    }],
  }));
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AGENT_RESULT_PATH: resultPath },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
  });
  try {
    const shared = request();
    await handle.provider.complete(shared);
    await handle.agent.run(shared);
    const logged = readLoggedRequests(logPath);
    const completePayload = logged.find((entry) => entry.type === "complete_request")?.payload as Record<string, unknown>;
    const agentMessagePayload = logged.find((entry) => entry.type === "agent_message")?.payload as Record<string, unknown>;
    assert.equal(completePayload.model_ref, shared.model_ref);
    assert.equal(JSON.parse(agentMessagePayload.message_json as string).model_ref, shared.model_ref);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
