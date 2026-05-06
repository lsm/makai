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
    model_ref: "opaque-model-ref-with:colon",
    messages: [{ role: "user" as const, content: "hello" }],
    options: { temperature: 0.2, session_id: "11111111-1111-4111-8111-111111111111" },
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
      api: "",
      provider: "",
      base_url: "",
    });
    assert.deepEqual((payload.context as Record<string, unknown>).messages, request().messages);
  } finally {
    await harness.cleanup();
  }
});

test("client.provider.complete maps system prompts and tool messages into provider context", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    await provider.complete({
      model_ref: "opaque-model-ref-with:colon",
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

test("client.agent.run rejects non-UUID session IDs before transport I/O", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      () => agent.run({ ...request(), options: { ...request().options, session_id: "session-1" } }),
      (err: unknown) => err instanceof TypeError && err.message === "request.options.session_id must be a UUID for agent transport",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.stream rejects non-UUID session IDs before transport I/O", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      async () => collect(agent.stream({ ...request(), options: { ...request().options, session_id: "session-1" } })),
      (err: unknown) => err instanceof TypeError && err.message === "request.options.session_id must be a UUID for agent transport",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
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
    assert.deepEqual(events[0], { type: "agent_start", session_id: "11111111-1111-4111-8111-111111111111" } satisfies AgentStreamEvent);
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
    { type: "event", event_type: "toolcall_start", content_index: 0, id: "call-1", name: "lookup" },
    { type: "event", event_type: "toolcall_delta", content_index: 0, delta: "{\"q\":" },
    { type: "event", event_type: "toolcall_delta", content_index: 0, delta: "\"makai\"}" },
    { type: "event", event_type: "toolcall_end", content_index: 0 },
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
    assert.equal((payload.model as Record<string, unknown>).id, "opaque-model-ref-with:colon");
    assert.deepEqual((payload.context as Record<string, unknown>).messages, request().messages);
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("stream error paths throw MakaiStreamError", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-exec-error-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([{ type: "message_start" }, { type: "error", message: "boom", code: "provider_error" }]));
  const harness = await setupHarness({ MAKAI_TEST_PROVIDER_EVENTS_PATH: eventsPath });
  try {
    const provider = createMakaiProviderApi(harness.client);
    await assert.rejects(
      async () => collect(provider.stream(request())),
      (err: unknown) => err instanceof MakaiStreamError && err.message === "boom" && err.code === "provider_error",
    );
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

test("agent stream error paths throw MakaiStreamError", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-error-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([{ type: "agent_start" }, { type: "error", message: "agent boom", code: "provider_error" }]));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_EVENTS_PATH: eventsPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      async () => collect(agent.stream(request())),
      (err: unknown) => err instanceof MakaiStreamError && err.message === "agent boom" && err.code === "provider_error",
    );
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
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
    assert.deepEqual((await handle.models.list()).models, []);
    await collect(handle.provider.stream(request()));
    const streamRequest = readLoggedRequests(logPath).find((entry) => entry.type === "stream_request");
    assert.equal(((streamRequest?.payload as Record<string, unknown>).options as Record<string, unknown>).auth_retry_policy, "auto_once");
    assert.equal(((streamRequest?.payload as Record<string, unknown>).model as Record<string, unknown>).id, "opaque-model-ref-with:colon");
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
