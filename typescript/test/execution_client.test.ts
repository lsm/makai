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
    options: { temperature: 0.2, session_id: "session-1" },
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
    assert.equal((logged[0]?.payload as Record<string, unknown>).model_ref, "opaque-model-ref-with:colon");
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
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client);
    const result = await agent.run(request());
    assert.equal(result.message.content, "agent");
    assert.deepEqual(result.usage, { input: 7, output: 9 });
    assert.equal(result.provider_id, "anthropic");
    assert.equal(result.api, "anthropic-messages");
    assert.equal(result.model_id, "claude-sonnet-4-5");
    assert.equal(result.stop_reason, "end_turn");
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
    assert.deepEqual(events[0], { type: "agent_start", session_id: "session-1" } satisfies AgentStreamEvent);
    assert.deepEqual(events.at(-1), { type: "agent_end", usage: { input: 7, output: 9 }, stop_reason: "end_turn" } satisfies AgentStreamEvent);
  } finally {
    await harness.cleanup();
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

test("createMakaiClient wires all namespaces correctly", async () => {
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
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
  } finally {
    await handle.close();
  }
});
