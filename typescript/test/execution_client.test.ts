import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createMakaiAgentApi,
  createMakaiClient,
  createMakaiProviderApi,
  drainSessionFramesUntilQuiescent,
  MakaiStdioClient,
  MakaiAuthRequiredError,
  MakaiProtocolError,
  MakaiStreamError,
  type AgentStreamEvent,
  type ProviderStreamEvent,
  type StdioFrame,
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

/**
 * Waits until the fixture's request log satisfies `predicate`. Error-path
 * teardown sends agent_stop asynchronously (no awaited drain, so the error is
 * not delayed past caller abort/retry windows), so the log assertion must
 * tolerate the fixture processing the stop a beat after the rejection.
 */
async function waitForLoggedRequests(
  logPath: string,
  predicate: (entries: Array<Record<string, unknown>>) => boolean,
  timeoutMs = 2000,
): Promise<Array<Record<string, unknown>>> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const logged = readLoggedRequests(logPath);
    if (predicate(logged) || Date.now() >= deadline) return logged;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
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

test("client.agent.run executes tool_execute frames and continues awaiting result", async () => {
  const transport = {
    sent: [] as StdioFrame[],
    frames: [
      { type: "agent_started", payload: {} },
      {
        type: "tool_execute",
        session_id: "testNanoIdSess1234567",
        message_id: "tool-request-1",
        sequence: 3,
        payload: { tool_call_id: "call-1", tool_name: "sum", args_json: "{\"a\":2,\"b\":3}" },
      },
      {
        type: "agent_result",
        payload: {
          result_json: JSON.stringify({
            messages: [{
              role: "assistant",
              content: "done",
              usage: { input: 1, output: 1 },
              provider: "anthropic",
              api: "anthropic-messages",
              model: "claude-sonnet-4-5",
              stop_reason: "end_turn",
            }],
          }),
        },
      },
    ] as StdioFrame[],
    send(frame: StdioFrame) { this.sent.push(frame); },
    async nextFrameForSession(sessionId: string) {
      const frame = this.frames.shift();
      if (!frame) throw new Error("stream exhausted");
      return { session_id: sessionId, ...frame };
    },
  };
  const agent = createMakaiAgentApi(transport as unknown as MakaiStdioClient);
  const result = await agent.run({
    ...request(),
    tools: [{
      name: "sum",
      description: "sum numbers",
      parameters_schema_json: "{}",
      execute: (args) => `sum=${Number(args.a) + Number(args.b)}`,
    }],
  });

  const toolResult = transport.sent.find((frame) => frame.type === "tool_result");
  assert.equal(toolResult?.session_id, "testNanoIdSess1234567");
  assert.equal(toolResult?.in_reply_to, "tool-request-1");
  assert.deepEqual(toolResult?.payload, {
    tool_call_id: "call-1",
    result_json: JSON.stringify([{ type: "text", text: "sum=5" }]),
    is_error: false,
  });
  assert.equal(result.message.content, "done");
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

test("client.agent.stream surfaces provider error details on turn_end and agent_end", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-error-events-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([
    { type: "agent_start", session_id: "testNanoIdSess1234567" },
    { type: "turn_start" },
    { type: "turn_end", stop_reason: "error", error_message: "fixture stream failure" },
    { type: "agent_end", stop_reason: "error", error_message: "fixture stream failure" },
  ]));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_EVENTS_PATH: eventsPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const events = await collect(agent.stream(request()));
    const turnEnd = events.find((event) => event.type === "turn_end");
    assert.equal(turnEnd?.type, "turn_end");
    assert.equal(turnEnd.type === "turn_end" ? turnEnd.error_message : undefined, "fixture stream failure");
    assert.equal(turnEnd.type === "turn_end" ? turnEnd.stop_reason : undefined, "error");

    const agentEnd = events.at(-1);
    assert.equal(agentEnd?.type, "agent_end");
    assert.equal(agentEnd.type === "agent_end" ? agentEnd.error_message : undefined, "fixture stream failure");
    assert.equal(agentEnd.type === "agent_end" ? agentEnd.stop_reason : undefined, "error");
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run surfaces provider error details from event fallback", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-error-fallback-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([
    { type: "agent_start", session_id: "testNanoIdSess1234567" },
    { type: "turn_start" },
    { type: "turn_end", stop_reason: "error", error_message: "fixture stream failure" },
    { type: "agent_end", stop_reason: "error", error_message: "fixture stream failure" },
  ]));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_EVENTS_PATH: eventsPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const result = await agent.run(request());
    assert.equal(result.stop_reason, "error");
    assert.equal(result.error_message, "fixture stream failure");
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run surfaces provider error details from agent_result", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-error-result-test-"));
  const resultPath = path.join(tmpDir, "agent-result.json");
  fs.writeFileSync(resultPath, JSON.stringify({
    type: "result",
    stop_reason: "error",
    model: "fixture-model",
    api: "fixture-error-api",
    provider: "fixture",
    timestamp: 1,
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    content: [],
    error_message: "invalid anthropic URL",
  }));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_RESULT_PATH: resultPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const result = await agent.run(request());
    assert.equal(result.stop_reason, "error");
    assert.equal(result.error_message, "invalid anthropic URL");
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run translates auth_required provider failures into MakaiAuthRequiredError", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-auth-result-test-"));
  const resultPath = path.join(tmpDir, "agent-result.json");
  fs.writeFileSync(resultPath, JSON.stringify({
    type: "result",
    stop_reason: "error",
    model: "fixture-model",
    api: "fixture-error-api",
    provider: "fixture",
    timestamp: 1,
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    content: [],
    error_message: "auth_required",
  }));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_RESULT_PATH: resultPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) =>
        err instanceof MakaiAuthRequiredError &&
        err.code === "auth_required" &&
        err.provider_id === "fixture" &&
        err.message === "auth_required",
    );
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.stream yields turn_end detail then throws retryable auth error", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-auth-stream-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  fs.writeFileSync(eventsPath, JSON.stringify([
    { type: "agent_start", session_id: "testNanoIdSess1234567" },
    { type: "turn_start" },
    { type: "turn_end", stop_reason: "error", error_message: "auth_required" },
    { type: "agent_end", stop_reason: "error", error_message: "auth_required" },
  ]));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_EVENTS_PATH: eventsPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const events: AgentStreamEvent[] = [];
    await assert.rejects(
      async () => {
        for await (const event of agent.stream(request())) events.push(event);
      },
      (err: unknown) =>
        err instanceof MakaiAuthRequiredError &&
        err.code === "auth_required" &&
        err.provider_id === "anthropic" &&
        err.message === "auth_required",
    );
    // The failing turn's detail is still surfaced on the yielded turn_end
    // event before the typed auth error terminates the stream.
    assert.deepEqual(events.map((event) => event.type), ["agent_start", "turn_start", "turn_end"]);
    const turnEnd = events.at(-1);
    assert.equal(turnEnd?.type, "turn_end");
    assert.equal(turnEnd.type === "turn_end" ? turnEnd.error_message : undefined, "auth_required");
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run resolves auth retry provider from response provider_id for opaque model_ref", async () => {
  const transport = {
    sent: [] as StdioFrame[],
    frames: [
      { type: "agent_started", payload: {} },
      {
        type: "agent_result",
        payload: {
          result_json: JSON.stringify({
            type: "result",
            stop_reason: "error",
            model: "fixture-model",
            api: "fixture-error-api",
            provider: "fixture-provider",
            timestamp: 1,
            input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            content: [],
            error_message: "auth_required",
          }),
        },
      },
    ] as StdioFrame[],
    send(frame: StdioFrame) { this.sent.push(frame); },
    async nextFrameForSession(sessionId: string) {
      const frame = this.frames.shift();
      if (!frame) throw new Error("stream exhausted");
      return { session_id: sessionId, ...frame };
    },
  };
  const agent = createMakaiAgentApi(transport as unknown as MakaiStdioClient);
  await assert.rejects(
    () => agent.run({ model_ref: "opaque-model-ref-no-provider", messages: [{ role: "user", content: "hello" }] }),
    (err: unknown) => err instanceof MakaiAuthRequiredError && err.provider_id === "fixture-provider" && err.code === "auth_required",
  );
});

test("client.agent.stream auto_once retries after yielded auth lifecycle events", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-auth-retry-stream-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const eventsPath = path.join(tmpDir, "events.json");
  // Mirrors a real run: prompt echo message frames arrive before the failing
  // provider turn, so the retry gate must classify them as replayable.
  fs.writeFileSync(eventsPath, JSON.stringify([
    { type: "agent_start", session_id: "testNanoIdSess1234567" },
    { type: "message_start", provider_id: "anthropic", api: "anthropic-messages", model_id: "claude-sonnet-4-5" },
    { type: "message_end", stop_reason: "end_turn" },
    { type: "turn_start" },
    { type: "turn_end", stop_reason: "error", error_message: "auth_required" },
    { type: "agent_end", stop_reason: "error", error_message: "auth_required", provider_id: "anthropic" },
  ]));
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AGENT_EVENTS_PATH: eventsPath },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    const events: AgentStreamEvent[] = [];
    await assert.rejects(
      async () => {
        for await (const event of handle.agent.stream(request())) events.push(event);
      },
      (err: unknown) => err instanceof MakaiAuthRequiredError && err.code === "auth_required" && err.provider_id === "anthropic",
    );
    // Both attempts yielded only replayable markers: the prompt echo frames,
    // the failed attempt's turn_end detail, then the retried attempt's replay.
    assert.deepEqual(events.map((event) => event.type), [
      "agent_start", "message_start", "message_end", "turn_start", "turn_end",
      "agent_start", "message_start", "message_end", "turn_start", "turn_end",
    ]);
    const logged = readLoggedRequests(logPath);
    assert.equal(logged.filter((entry) => entry.type === "agent_message").length, 2);
    assert.equal(logged.filter((entry) => entry.type === "auth_login_start").length, 1);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run does not auth-retry after tools have executed", async () => {
  const transport = {
    sent: [] as StdioFrame[],
    frames: [
      { type: "agent_started", payload: {} },
      {
        type: "tool_execute",
        session_id: "testNanoIdSess1234567",
        message_id: "tool-request-1",
        sequence: 3,
        payload: { tool_call_id: "call-1", tool_name: "sum", args_json: "{\"a\":2,\"b\":3}" },
      },
      {
        type: "agent_result",
        payload: {
          result_json: JSON.stringify({
            type: "result",
            stop_reason: "error",
            model: "fixture-model",
            api: "fixture-error-api",
            provider: "fixture-provider",
            timestamp: 1,
            input: 1,
            output: 1,
            cache_read: 0,
            cache_write: 0,
            content: [],
            error_message: "auth_required",
          }),
        },
      },
    ] as StdioFrame[],
    send(frame: StdioFrame) { this.sent.push(frame); },
    async nextFrameForSession(sessionId: string) {
      const frame = this.frames.shift();
      if (!frame) throw new Error("stream exhausted");
      return { session_id: sessionId, ...frame };
    },
  };
  const agent = createMakaiAgentApi(transport as unknown as MakaiStdioClient);
  // The run already executed a tool; a retry would replay its side effects, so
  // the auth-shaped terminal failure surfaces as the typed terminal auth error
  // (never re-entering auto_once) rather than a retryable error.
  await assert.rejects(
    () => agent.run({
      ...request(),
      tools: [{
        name: "sum",
        description: "sum numbers",
        parameters_schema_json: "{}",
        execute: (args) => `sum=${Number(args.a) + Number(args.b)}`,
      }],
    }),
    (err: unknown) => err instanceof MakaiAuthRequiredError && err.code === "auth_required" && err.provider_id === "fixture-provider",
  );
  // Only one agent run was started: no retry attempt.
  assert.equal(transport.sent.filter((frame) => frame.type === "agent_start").length, 1);
});

test("client.agent.run scopes provider-specific auth patterns to the matching provider", async () => {
  const transportFor = (api: string, provider: string) => ({
    sent: [] as StdioFrame[],
    frames: [
      { type: "agent_started", payload: {} },
      {
        type: "agent_result",
        payload: {
          result_json: JSON.stringify({
            type: "result",
            stop_reason: "error",
            model: "fixture-model",
            api,
            provider,
            timestamp: 1,
            input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            content: [],
            error_message: "permission_error: scope denied",
          }),
        },
      },
    ] as StdioFrame[],
    send(frame: StdioFrame) { this.sent.push(frame); },
    async nextFrameForSession(sessionId: string) {
      const frame = this.frames.shift();
      if (!frame) throw new Error("stream exhausted");
      return { session_id: sessionId, ...frame };
    },
  });

  // Non-Anthropic provider: permission_error is not an auth failure per the
  // server's default detector, so the run resolves with the error completion.
  const generic = createMakaiAgentApi(transportFor("fixture-error-api", "fixture-provider") as unknown as MakaiStdioClient);
  const completion = await generic.run(request());
  assert.equal(completion.stop_reason, "error");
  assert.equal(completion.error_message, "permission_error: scope denied");

  // Remapped model: provider_id "anthropic" on a non-Anthropic API must not
  // borrow the anthropic-messages detector patterns.
  const remapped = createMakaiAgentApi(transportFor("openai-completions", "anthropic") as unknown as MakaiStdioClient);
  const remappedCompletion = await remapped.run(request());
  assert.equal(remappedCompletion.stop_reason, "error");
  assert.equal(remappedCompletion.error_message, "permission_error: scope denied");

  // Anthropic API: the registered detector treats permission_error as auth.
  const anthropic = createMakaiAgentApi(transportFor("anthropic-messages", "anthropic") as unknown as MakaiStdioClient);
  await assert.rejects(
    () => anthropic.run(request()),
    (err: unknown) => err instanceof MakaiAuthRequiredError && err.provider_id === "anthropic",
  );
});

test("client.agent.run matches human-readable auth failure messages", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-auth-readable-test-"));
  const resultPath = path.join(tmpDir, "agent-result.json");
  fs.writeFileSync(resultPath, JSON.stringify({
    type: "result",
    stop_reason: "error",
    model: "fixture-model",
    api: "fixture-error-api",
    provider: "fixture-provider",
    timestamp: 1,
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    content: [],
    error_message: "Authentication required for provider fixture",
  }));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_RESULT_PATH: resultPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) => err instanceof MakaiAuthRequiredError && err.provider_id === "fixture-provider",
    );
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.stream resolves auth retry provider from the streamed agent_end", async () => {
  const transport = {
    sent: [] as StdioFrame[],
    frames: [
      { type: "agent_started", payload: {} },
      {
        type: "agent_result",
        payload: {
          result_json: JSON.stringify({
            type: "result",
            stop_reason: "error",
            model: "fixture-model",
            api: "fixture-error-api",
            provider: "fixture-provider",
            timestamp: 1,
            input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            content: [],
            error_message: "auth_required",
          }),
        },
      },
    ] as StdioFrame[],
    send(frame: StdioFrame) { this.sent.push(frame); },
    async nextFrameForSession(sessionId: string) {
      const frame = this.frames.shift();
      if (!frame) throw new Error("stream exhausted");
      return { session_id: sessionId, ...frame };
    },
  };
  const agent = createMakaiAgentApi(transport as unknown as MakaiStdioClient);
  const events: AgentStreamEvent[] = [];
  await assert.rejects(
    async () => {
      for await (const event of agent.stream({ model_ref: "opaque-model-ref-no-provider", messages: [{ role: "user", content: "hello" }] })) {
        events.push(event);
      }
    },
    (err: unknown) => err instanceof MakaiAuthRequiredError && err.provider_id === "fixture-provider" && err.code === "auth_required",
  );
});

test("client.agent.run event fallback applies API-scoped auth via terminal agent_end api", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-fallback-api-test-"));
  const eventsPath = path.join(tmpDir, "events.json");
  // No assistant message_start (failed before provider output); the terminal
  // agent_end carries the resolved identity including api.
  fs.writeFileSync(eventsPath, JSON.stringify([
    { type: "agent_start", session_id: "testNanoIdSess1234567" },
    { type: "turn_start" },
    { type: "turn_end", stop_reason: "error", error_message: "permission_error: scope denied" },
    { type: "agent_end", stop_reason: "error", error_message: "permission_error: scope denied", provider_id: "anthropic", api: "anthropic-messages" },
  ]));
  const harness = await setupHarness({ MAKAI_TEST_AGENT_EVENTS_PATH: eventsPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) => err instanceof MakaiAuthRequiredError && err.provider_id === "anthropic" && err.code === "auth_required",
    );
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

test("agent_start payload includes session_id (#198)", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    await collect(agent.stream(request()));
    const logged = readLoggedRequests(harness.logPath);
    const start = logged.find((entry) => entry.type === "agent_start");
    assert.ok(start);
    const payload = start?.payload as Record<string, unknown>;
    assert.equal(payload.session_id, "testNanoIdSess1234567");
    // The legacy `resume_session_id` alias rides along with the SAME value so
    // pre-rename servers keep binding the caller's id; dual-key servers
    // prefer the canonical key (#198).
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

// --- model_ref input validation tests ---

test("provider.complete rejects model_ref exceeding 4096 characters before transport I/O", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    const longModelRef = "a".repeat(4097);
    await assert.rejects(
      () => provider.complete({ model_ref: longModelRef, messages: [{ role: "user", content: "hi" }] }),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model_ref exceeds maximum length of 4096 characters",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("provider.stream rejects model_ref exceeding 4096 characters before transport I/O", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    const longModelRef = "a".repeat(4097);
    await assert.rejects(
      async () => collect(provider.stream({ model_ref: longModelRef, messages: [{ role: "user", content: "hi" }] })),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model_ref exceeds maximum length of 4096 characters",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("agent.run rejects model_ref exceeding 4096 characters before transport I/O", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    const longModelRef = "a".repeat(4097);
    await assert.rejects(
      () => agent.run({ model_ref: longModelRef, messages: [{ role: "user", content: "hi" }] }),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model_ref exceeds maximum length of 4096 characters",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("agent.stream rejects model_ref exceeding 4096 characters before transport I/O", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    const longModelRef = "a".repeat(4097);
    await assert.rejects(
      async () => collect(agent.stream({ model_ref: longModelRef, messages: [{ role: "user", content: "hi" }] })),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model_ref exceeds maximum length of 4096 characters",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

// --- model_ref segment-level validation tests ---

test("provider.complete rejects canonical model_ref with provider segment exceeding 256 characters", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    const longProvider = "a".repeat(257);
    const modelRef = `${longProvider}/anthropic-messages@claude-sonnet-4-5`;
    await assert.rejects(
      () => provider.complete({ model_ref: modelRef, messages: [{ role: "user", content: "hi" }] }),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model_ref provider segment exceeds maximum length of 256 characters",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("provider.stream rejects canonical model_ref with api segment exceeding 256 characters", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    const longApi = "a".repeat(257);
    const modelRef = `anthropic/${longApi}@claude-sonnet-4-5`;
    await assert.rejects(
      async () => collect(provider.stream({ model_ref: modelRef, messages: [{ role: "user", content: "hi" }] })),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model_ref api segment exceeds maximum length of 256 characters",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("agent.run rejects canonical model_ref with api segment exceeding 256 characters", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    const longApi = "a".repeat(257);
    const modelRef = `anthropic/${longApi}@claude-sonnet-4-5`;
    await assert.rejects(
      () => agent.run({ model_ref: modelRef, messages: [{ role: "user", content: "hi" }] }),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model_ref api segment exceeds maximum length of 256 characters",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("provider.complete rejects fallback model_ref with provider segment exceeding 256 characters", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    const longProvider = "a".repeat(257);
    // Use colon in model_id to force parseModelRef failure, triggering fallback path
    const modelRef = `${longProvider}/anthropic-messages@model:id`;
    await assert.rejects(
      () => provider.complete({ model_ref: modelRef, messages: [{ role: "user", content: "hi" }] }),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model_ref provider segment exceeds maximum length of 256 characters",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("provider.complete rejects fallback model_ref with api segment exceeding 256 characters", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    const longApi = "a".repeat(257);
    // Use colon in model_id to force parseModelRef failure, triggering fallback path
    const modelRef = `anthropic/${longApi}@model:id`;
    await assert.rejects(
      () => provider.complete({ model_ref: modelRef, messages: [{ role: "user", content: "hi" }] }),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model_ref api segment exceeds maximum length of 256 characters",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

// --- opaque model_ref validation tests ---

test("provider.complete rejects opaque model_ref exceeding 512 characters before transport I/O", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    // No / or @ separators — fully opaque ref that becomes model.id/model.name
    const longModelRef = "x".repeat(513);
    await assert.rejects(
      () => provider.complete({ model_ref: longModelRef, messages: [{ role: "user", content: "hi" }] }),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model_ref exceeds maximum length of 512 characters for opaque refs",
    );
    assert.deepEqual(readLoggedRequests(harness.logPath), []);
  } finally {
    await harness.cleanup();
  }
});

test("provider.complete accepts opaque model_ref at exactly 512 characters", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    const modelRef = "x".repeat(512);
    assert.equal(modelRef.length, 512);
    await provider.complete({ model_ref: modelRef, messages: [{ role: "user", content: "hi" }] });
    const logged = readLoggedRequests(harness.logPath);
    assert.equal(logged.length, 1);
  } finally {
    await harness.cleanup();
  }
});

test("provider.complete accepts canonical model_ref with max valid segment sizes", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client);
    // Max valid canonical ref: 256-char provider, 256-char api, 512-char model_id = 1026 total
    const modelRef = `${"p".repeat(256)}/${"a".repeat(256)}@${"m".repeat(512)}`;
    assert.equal(modelRef.length, 256 + 1 + 256 + 1 + 512);
    // Passes both total cap (4096) and all segment caps
    await provider.complete({ model_ref: modelRef, messages: [{ role: "user", content: "hi" }] });
    const logged = readLoggedRequests(harness.logPath);
    assert.equal(logged.length, 1);
  } finally {
    await harness.cleanup();
  }
});

test("client.provider.complete surfaces error_message from error results", async () => {
  const errorResult = {
    role: "assistant",
    content: [{ type: "text", text: "" }],
    usage: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
    provider_id: "anthropic",
    api: "anthropic-messages",
    model_id: "claude-sonnet-4-5",
    stop_reason: "error",
    error_message: "QueueFull",
  };
  const resultPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "makai-err-result-")), "result.json");
  fs.writeFileSync(resultPath, JSON.stringify(errorResult));

  const harness = await setupHarness({ MAKAI_TEST_PROVIDER_RESULT_PATH: resultPath });
  try {
    const provider = createMakaiProviderApi(harness.client);
    const result = await provider.complete(request());
    assert.equal(result.stop_reason, "error");
    assert.equal(result.error_message, "QueueFull");
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run surfaces error_message from error agent results", async () => {
  const errorResult = {
    messages: [{
      role: "assistant",
      content: [{ type: "text", text: "" }],
      usage: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
      provider: "anthropic",
      api: "anthropic-messages",
      model: "claude-sonnet-4-5",
      stop_reason: "error",
      error_message: "QueueFull",
    }],
  };
  const resultPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-err-result-")), "result.json");
  fs.writeFileSync(resultPath, JSON.stringify(errorResult));

  const harness = await setupHarness({ MAKAI_TEST_AGENT_RESULT_PATH: resultPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const result = await agent.run(request());
    assert.equal(result.stop_reason, "error");
    assert.equal(result.error_message, "QueueFull");
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run tears down the session so the same session_id can be reused", async () => {
  // Tracking fixture mirrors the real server: agent_start on a live session
  // id fails with agent_busy until a sequence-valid agent_stop removes it.
  // Without teardown, the second run below rejects (issue #199).
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const first = await agent.run(request());
    assert.equal(first.stop_reason, "end_turn");
    const second = await agent.run(request());
    assert.equal(second.stop_reason, "end_turn");

    const logged = readLoggedRequests(harness.logPath);
    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 2);
    for (const stop of stops) {
      assert.equal(stop.session_id, "testNanoIdSess1234567");
      // start=1, message=2, so the server expects the stop at sequence 3 —
      // a default-sequence stop would be rejected and the session would leak.
      assert.equal(stop.sequence, 3);
      assert.equal((stop.payload as Record<string, unknown>).reason, "completed");
    }
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run sends agent_stop when the run fails and the id stays reusable", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-stop-error-"));
  const errorPath = path.join(tmpDir, "agent-error.json");
  fs.writeFileSync(errorPath, JSON.stringify({ code: "provider_error", message: "fixture agent failure" }));
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1", MAKAI_TEST_AGENT_ERROR_PATH: errorPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.message === "fixture agent failure",
    );

    const logged = await waitForLoggedRequests(harness.logPath, (entries) => entries.some((entry) => entry.type === "agent_stop"));
    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 1);
    assert.equal(stops[0]?.session_id, "testNanoIdSess1234567");
    assert.equal(stops[0]?.sequence, 3);
    assert.equal((stops[0]?.payload as Record<string, unknown>).reason, "completed");

    // The stop took effect server-side: an immediate retry with the same id
    // starts a fresh session (the fixture's agent_error replays for it — it
    // is NOT rejected with agent_busy, and the stale stop-reply frames are
    // skipped rather than consumed as the retry's own frames).
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.message === "fixture agent failure",
    );
    const stopsAfterRetry = (await waitForLoggedRequests(harness.logPath, (entries) => entries.filter((entry) => entry.type === "agent_stop").length >= 2))
      .filter((entry) => entry.type === "agent_stop");
    assert.equal(stopsAfterRetry.length, 2);
    assert.equal(stopsAfterRetry[1]?.sequence, 3);
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.stream tears down the session when the consumer closes the iterator early", async () => {
  // Breaking out of the for-await at the terminal event closes the generator
  // while suspended at its yield — loop-exit code never runs, so teardown
  // must live in the generator's finally (issue #199, review finding).
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const events: AgentStreamEvent[] = [];
    for await (const event of agent.stream(request())) {
      events.push(event);
      if (event.type === "agent_end") break;
    }
    assert.equal(events.at(-1)?.type, "agent_end");

    const result = await agent.run(request());
    assert.equal(result.stop_reason, "end_turn");

    const logged = readLoggedRequests(harness.logPath);
    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 2);
    for (const stop of stops) {
      assert.equal(stop.session_id, "testNanoIdSess1234567");
      assert.equal(stop.sequence, 3);
      assert.equal((stop.payload as Record<string, unknown>).reason, "completed");
    }
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run does not stop a session owned by another run after agent_busy", async () => {
  // A second run on an id owned by a live first run is rejected with
  // agent_busy; that rejection must NOT send an agent_stop — the tracked
  // sequence would validate against the other run's session and tear it down
  // (review finding on #199).
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1", MAKAI_TEST_SUPPRESS_AGENT_MESSAGE_RESPONSE: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client, { responseTimeoutMs: 500 });
    const first = agent.run(request());
    // Give the first run's start/message a beat to register the session.
    await new Promise((resolve) => setTimeout(resolve, 25));
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.code === "agent_busy" && err.message === "session already exists",
    );

    // The live session survives the busy attempt untouched; it is stopped
    // only by its own run's timeout teardown.
    await assert.rejects(
      () => first,
      (err: unknown) => err instanceof MakaiStreamError && err.kind === "transport_error",
    );
    const logged = await waitForLoggedRequests(harness.logPath, (entries) => entries.some((entry) => entry.type === "agent_stop"));
    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 1);
    assert.equal(stops[0]?.session_id, "testNanoIdSess1234567");
    assert.equal(stops[0]?.sequence, 3);
  } finally {
    await harness.cleanup();
  }
});

test("concurrent client.agent.run on one session id: duplicate is rejected promptly, established run completes", async () => {
  // §13.3.1 (#201): two overlapping runs on the same consumer-supplied
  // session id share one session route. With in_reply_to-aware waiter
  // routing each run receives its own start reply — the duplicate learns of
  // its agent_busy rejection immediately instead of surfacing the response
  // timeout after the established run finishes, and the established run is
  // unaffected (neither consuming the rejection nor losing its own reply).
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client, { responseTimeoutMs: 3000 });
    const startedAt = Date.now();
    const [established, duplicate] = await Promise.allSettled([agent.run(request()), agent.run(request())]);
    const elapsedMs = Date.now() - startedAt;

    // The duplicate's rejection is delivered by correlation, not by waiting
    // out the response timeout.
    assert.ok(elapsedMs < 1500, `duplicate rejection took ${elapsedMs}ms; expected correlated delivery, not a timeout`);
    assert.equal(established.status, "fulfilled");
    assert.equal((established as PromiseFulfilledResult<{ stop_reason?: string }>).value.stop_reason, "end_turn");
    assert.equal(duplicate.status, "rejected");
    const reason = (duplicate as PromiseRejectedResult).reason;
    assert.ok(reason instanceof MakaiStreamError && reason.code === "agent_busy" && reason.message === "session already exists", `unexpected duplicate rejection: ${String(reason)}`);

    // Exactly one teardown stop — the established run's. The duplicate owns
    // nothing on the session and must not stop it (its tracked sequence
    // would validate and tear the established run's session down).
    const logged = await waitForLoggedRequests(harness.logPath, (entries) => entries.some((entry) => entry.type === "agent_stop"));
    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 1);
    assert.equal(stops[0]?.sequence, 3);
  } finally {
    await harness.cleanup();
  }
});

test("concurrent client.agent.run duplicate receives the agent_error-shaped agent_busy rejection", async () => {
  // Same scenario with the real agent server's rejection flavor: the
  // duplicate start is refused with an agent_error frame (not a nack); the
  // correlated delivery must route it to the duplicate regardless of frame
  // type.
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1", MAKAI_TEST_AGENT_BUSY_AS_ERROR: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client, { responseTimeoutMs: 3000 });
    const startedAt = Date.now();
    const [established, duplicate] = await Promise.allSettled([agent.run(request()), agent.run(request())]);
    const elapsedMs = Date.now() - startedAt;

    assert.ok(elapsedMs < 1500, `duplicate rejection took ${elapsedMs}ms; expected correlated delivery, not a timeout`);
    assert.equal(established.status, "fulfilled");
    assert.equal((established as PromiseFulfilledResult<{ stop_reason?: string }>).value.stop_reason, "end_turn");
    assert.equal(duplicate.status, "rejected");
    const reason = (duplicate as PromiseRejectedResult).reason;
    assert.ok(reason instanceof MakaiStreamError && reason.code === "agent_busy" && reason.message === "session already exists", `unexpected duplicate rejection: ${String(reason)}`);

    const logged = await waitForLoggedRequests(harness.logPath, (entries) => entries.some((entry) => entry.type === "agent_stop"));
    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 1);
    assert.equal(stops[0]?.sequence, 3);
  } finally {
    await harness.cleanup();
  }
});

test("concurrent client.agent.stream on one session id: duplicate is rejected promptly, established stream completes", async () => {
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client, { responseTimeoutMs: 3000 });
    const startedAt = Date.now();
    const [established, duplicate] = await Promise.allSettled([collect(agent.stream(request())), collect(agent.stream(request()))]);
    const elapsedMs = Date.now() - startedAt;

    assert.ok(elapsedMs < 1500, `duplicate rejection took ${elapsedMs}ms; expected correlated delivery, not a timeout`);
    assert.equal(established.status, "fulfilled");
    const events = (established as PromiseFulfilledResult<AgentStreamEvent[]>).value;
    assert.equal(events.at(-1)?.type, "agent_end");
    assert.equal(duplicate.status, "rejected");
    const reason = (duplicate as PromiseRejectedResult).reason;
    assert.ok(reason instanceof MakaiStreamError && reason.code === "agent_busy" && reason.message === "session already exists", `unexpected duplicate rejection: ${String(reason)}`);

    const logged = await waitForLoggedRequests(harness.logPath, (entries) => entries.some((entry) => entry.type === "agent_stop"));
    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 1);
    assert.equal(stops[0]?.sequence, 3);
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run auth retry stops the abandoned session", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-stop-auth-retry-"));
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
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_AGENT_RESULT_PATH: resultPath, MAKAI_TEST_TRACK_AGENT_SESSIONS: "1" },
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
    assert.match(secondSessionId as string, /^[0-9A-Za-z]{21}$/);

    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 2);
    // The abandoned attempt stopped at the sequence it reached (start only).
    assert.equal(stops[0]?.session_id, firstSessionId);
    assert.equal(stops[0]?.sequence, 2);
    assert.equal((stops[0]?.payload as Record<string, unknown>).reason, "completed");
    // The retried attempt runs its full lifecycle and stops at sequence 3.
    assert.equal(stops[1]?.session_id, secondSessionId);
    assert.equal(stops[1]?.sequence, 3);
    assert.equal((stops[1]?.payload as Record<string, unknown>).reason, "completed");
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.stream tears down the session and drains the trailing terminal frame", async () => {
  // In agent_result mode the tracking fixture mirrors the real server's
  // double publish: agent_result first, then a trailing terminal agent_end.
  // The stream terminates on the agent_result-derived event, so the teardown
  // drain must consume the trailing frame or a follow-up run reusing the
  // session id would consume it as its first frame (issue #199).
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-stop-stream-"));
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
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1", MAKAI_TEST_AGENT_RESULT_PATH: resultPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    const events = await collect(agent.stream(request()));
    assert.equal(events.at(-1)?.type, "agent_end");

    const result = await agent.run(request());
    assert.equal(result.message.content, "ok");
    assert.equal(result.stop_reason, "end_turn");

    const logged = readLoggedRequests(harness.logPath);
    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 2);
    for (const stop of stops) {
      assert.equal(stop.session_id, "testNanoIdSess1234567");
      assert.equal(stop.sequence, 3);
      assert.equal((stop.payload as Record<string, unknown>).reason, "completed");
    }
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.agent.run does not stop a caller-supplied session when the start outcome is unknown (§6.1, #205)", async () => {
  // Timeout on a caller-supplied id with no reply to our own agent_start
  // observed: the id may have been registered by another caller whose start
  // won the race while our agent_busy reply was lost, and that owner's fresh
  // pre-message session also expects inbound sequence 2 — a sequence-2 stop
  // would be ACCEPTED and destroy it. The teardown must settle without
  // sending (spec §6.1: the leaked-if-ours session is strictly preferable).
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1", MAKAI_TEST_SUPPRESS_AGENT_START_RESPONSE: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client, { responseTimeoutMs: 300 });
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.kind === "transport_error",
    );

    // The stop decision is made synchronously in the error path, so by the
    // time the run rejects the log already reflects whatever was sent.
    const logged = readLoggedRequests(harness.logPath);
    const starts = logged.filter((entry) => entry.type === "agent_start");
    assert.equal(starts.length, 1);
    assert.equal(starts[0]?.session_id, "testNanoIdSess1234567");
    assert.equal(logged.filter((entry) => entry.type === "agent_stop").length, 0);

    // A same-id follow-up attempt is refused with a correlated agent_busy —
    // the un-stopped session stayed registered (the §6.1 leak, bounded only
    // by server eviction) — and the refusal must still not stop it: the
    // guard is per attempt, and the busy path settles without a send too.
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.code === "agent_busy" && err.message === "session already exists",
    );
    const loggedAfterRetry = readLoggedRequests(harness.logPath);
    assert.equal(loggedAfterRetry.filter((entry) => entry.type === "agent_start").length, 2);
    assert.equal(loggedAfterRetry.filter((entry) => entry.type === "agent_stop").length, 0);
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run still stops a client-generated session when the start outcome is unknown (#205)", async () => {
  // An exclusive client-generated id is the one sufficient ownership evidence
  // for stopping on an unknown start outcome (§6.1, until #204's generation
  // tokens): no other caller could hold the id, so the timeout teardown keeps
  // the always-stop behavior.
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1", MAKAI_TEST_SUPPRESS_AGENT_START_RESPONSE: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client, { responseTimeoutMs: 300 });
    await assert.rejects(
      () => agent.run({ ...request(), options: { temperature: 0.2 } }),
      (err: unknown) => err instanceof MakaiStreamError && err.kind === "transport_error",
    );

    const logged = await waitForLoggedRequests(harness.logPath, (entries) => entries.some((entry) => entry.type === "agent_stop"));
    const starts = logged.filter((entry) => entry.type === "agent_start");
    assert.equal(starts.length, 1);
    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 1);
    // Start sent (sequence 1), message never sent — the session expects the
    // stop at sequence 2.
    assert.equal(stops[0]?.session_id, starts[0]?.session_id);
    assert.equal(stops[0]?.sequence, 2);
    assert.equal((stops[0]?.payload as Record<string, unknown>).reason, "completed");
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.stream does not stop a caller-supplied session when the start outcome is unknown (#205)", async () => {
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1", MAKAI_TEST_SUPPRESS_AGENT_START_RESPONSE: "1" });
  try {
    const agent = createMakaiAgentApi(harness.client, { responseTimeoutMs: 300 });
    await assert.rejects(
      () => collect(agent.stream(request())),
      (err: unknown) => err instanceof MakaiStreamError && err.kind === "transport_error",
    );

    const logged = readLoggedRequests(harness.logPath);
    assert.equal(logged.filter((entry) => entry.type === "agent_start").length, 1);
    assert.equal(logged.filter((entry) => entry.type === "agent_stop").length, 0);
  } finally {
    await harness.cleanup();
  }
});

test("client.agent.run auth-retry attempt with a lost start reply still stops its SDK-generated session (#205)", async () => {
  // Codex review on PR #208: auto_once retries store their SDK-generated id
  // in options.session_id, so deriving the id's origin from the option's
  // presence misclassifies the retry's id as caller-supplied — a retry whose
  // start reply is lost (suppressed here) would then skip its teardown stop
  // and leak the admitted session. The origin must be tracked when the retry
  // request is constructed, not inferred from the request shape.
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-stop-retry-lost-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_AUTH_REQUIRED_ONCE: "1", MAKAI_TEST_SUPPRESS_AGENT_START_RESPONSE: "1", MAKAI_TEST_TRACK_AGENT_SESSIONS: "1" },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 300,
    auth: { auth_retry_policy: "auto_once" },
  });
  try {
    // Attempt 1 is auth-rejected (correlated nack — a resolved outcome, so
    // its abandoned session is stopped); the auto_once retry gets a fresh
    // SDK-generated id whose start reply is suppressed, so it times out with
    // an unknown outcome — and must STILL stop, because no other caller
    // could hold a client-generated id.
    await assert.rejects(
      () => handle.agent.run(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.kind === "transport_error",
    );

    const logged = await waitForLoggedRequests(logPath, (entries) => entries.filter((entry) => entry.type === "agent_stop").length >= 2);
    const starts = logged.filter((entry) => entry.type === "agent_start");
    assert.equal(starts.length, 2);
    assert.equal(starts[0]?.session_id, "testNanoIdSess1234567");
    const retryId = starts[1]?.session_id as string;
    assert.match(retryId, /^[0-9A-Za-z]{21}$/);
    const stops = logged.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 2);
    // Attempt 1's abandon stop (its correlated rejection resolved the start).
    assert.equal(stops[0]?.session_id, "testNanoIdSess1234567");
    assert.equal(stops[0]?.sequence, 2);
    // Attempt 2's unknown-outcome teardown: SDK-generated id keeps the stop.
    assert.equal(stops[1]?.session_id, retryId);
    assert.equal(stops[1]?.sequence, 2);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("session teardown drain consumes terminal-shaped frames before the current stop's reply (#205)", async () => {
  // Codex P1 on PR #208: the quiescent drain exited on ANY agent_error /
  // agent_stopped, so the failure pair's uncorrelated settlement ended the
  // drain before the CURRENT stop's agent_stopped reply was consumed. That
  // stale reply could then terminate a later same-id run's drain early,
  // leaving its trailing agent_end for a subsequent run to claim as its own
  // completion. The early exit must key on the reply's in_reply_to naming
  // the current stop only.
  const sessionId = "testNanoIdSess1234567";
  const frames: StdioFrame[] = [
    // The failure pair's settlement: terminal-shaped, but NOT a reply to the stop.
    { type: "agent_error", session_id: sessionId, message_id: "m-settlement", sequence: 4, timestamp: 1, version: 1, payload: { code: "internal_error", message: "fixture loop failure" } },
    // A stale agent_stopped replying to an EARLIER stop on the same id.
    { type: "agent_stopped", session_id: sessionId, message_id: "m-stale", sequence: 9, timestamp: 1, version: 1, in_reply_to: "earlier-stop-message-id", payload: {} },
    // The current stop's reply — the only frame that may end the drain early.
    { type: "agent_stopped", session_id: sessionId, message_id: "m-current", sequence: 9, timestamp: 1, version: 1, in_reply_to: "current-stop-message-id", payload: {} },
  ];
  const consumed: string[] = [];
  const transport = {
    nextFrameForSession: async (sid: string, timeoutMs?: number) => {
      const frame = frames.shift();
      if (!frame) throw new Error(`timed out waiting for frame for session ${sid} after ${timeoutMs ?? 1000}ms`);
      consumed.push(String(frame.type));
      return frame;
    },
  };
  // Positional timeouts in their original (pre-#205) slots with `opts`
  // appended — the exported signature stays source-compatible with callers
  // written against `(transport, sessionId, idleMs, maxMs)`.
  await drainSessionFramesUntilQuiescent(transport as never, sessionId, 20, 500, { stopReplyTo: "current-stop-message-id" });
  // All three frames were consumed: the settlement and the stale reply did
  // not end the drain (pre-fix it stopped at the settlement, leaving the
  // stale and current stop replies queued for later runs to trip over).
  assert.deepEqual(consumed, ["agent_error", "agent_stopped", "agent_stopped"]);
  assert.equal(frames.length, 0);
});

test("client.agent.run drains the failure pair's settlement before the error surfaces, so an immediate same-id run is not poisoned (#205)", async () => {
  // §13.4.2: a loop-internal failure settles via the pair agent_event(error)
  // + settlement agent_error — ONE settlement. The fixture emits BOTH frames
  // uncorrelated (faithful to the real server's async output), so a consumer
  // terminating on the first frame must drain the second before the id is
  // reused: the queued settlement agent_error would otherwise be claimed by
  // the follow-up run's first post-acceptance wait, treated as its own
  // rejection, and stop the newly registered session.
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-agent-failure-pair-"));
  const pairPath = path.join(tmpDir, "failure-pair.json");
  fs.writeFileSync(pairPath, JSON.stringify({ code: "internal_error", message: "fixture loop failure" }));
  const harness = await setupHarness({ MAKAI_TEST_TRACK_AGENT_SESSIONS: "1", MAKAI_TEST_AGENT_FAILURE_PAIR_PATH: pairPath });
  try {
    const agent = createMakaiAgentApi(harness.client);
    await assert.rejects(
      () => agent.run(request()),
      (err: unknown) => err instanceof MakaiStreamError && err.message === "fixture loop failure" && err.code === "internal_error",
    );

    // The failing run tore its session down at the throw site: the stop is
    // sent and the quiescent drain has consumed the settlement agent_error.
    // (The fixture logs the stop a beat after the rejection, so wait for it.)
    const logged = await waitForLoggedRequests(harness.logPath, (entries) => entries.some((entry) => entry.type === "agent_stop"));
    assert.equal(logged.filter((entry) => entry.type === "agent_stop").length, 1);
    assert.equal((logged.find((entry) => entry.type === "agent_stop")?.payload as Record<string, unknown>).reason, "completed");

    // The immediate same-id follow-up must NOT consume the stale settlement
    // (it runs the fixture's normal event flow — the pair fires once) and
    // must NOT send a session-destroying stop of its own before completing.
    const second = await agent.run(request());
    assert.equal(second.stop_reason, "end_turn");

    const loggedAfter = await waitForLoggedRequests(harness.logPath, (entries) => entries.filter((entry) => entry.type === "agent_stop").length >= 2);
    const stops = loggedAfter.filter((entry) => entry.type === "agent_stop");
    assert.equal(stops.length, 2);
    for (const stop of stops) {
      assert.equal(stop.session_id, "testNanoIdSess1234567");
      assert.equal(stop.sequence, 3);
      assert.equal((stop.payload as Record<string, unknown>).reason, "completed");
    }
  } finally {
    await harness.cleanup();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
