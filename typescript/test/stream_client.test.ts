import assert from "node:assert/strict";
import test from "node:test";
import {
  createMakaiAgentApi,
  createMakaiProviderApi,
  MakaiStreamError,
  type ProviderCompleteRequest,
  type StdioFrame,
} from "../src";

const REQUEST: ProviderCompleteRequest = {
  model_ref: "fixture/anthropic-messages@model",
  messages: [{ role: "user", content: "hello" }],
};

class ScriptedTransport {
  public readonly sent: StdioFrame[] = [];
  private readonly frames: StdioFrame[];
  private readonly failWith?: Error;

  constructor(frames: StdioFrame[], failWith?: Error) {
    this.frames = [...frames];
    this.failWith = failWith;
  }

  send(frame: StdioFrame): void {
    this.sent.push(frame);
  }

  async nextFrameForStream(streamId: string): Promise<StdioFrame> {
    if (this.failWith) throw this.failWith;
    const frame = this.frames.shift();
    if (!frame) throw new Error(`no scripted frame for ${streamId}`);
    return { stream_id: streamId, ...frame };
  }

  async nextFrameForSession(sessionId: string): Promise<StdioFrame> {
    if (this.failWith) throw this.failWith;
    const frame = this.frames.shift();
    if (!frame) throw new Error(`no scripted frame for ${sessionId}`);
    return { session_id: sessionId, ...frame };
  }
}

async function collect<T>(iterable: AsyncIterable<T>): Promise<T[]> {
  const events: T[] = [];
  for await (const event of iterable) events.push(event);
  return events;
}

test("provider stream emits exactly one terminal event", async () => {
  const transport = new ScriptedTransport([
    { type: "event", payload: { type: "message_start" } },
    { type: "event", payload: { type: "text_delta", delta: "hi" } },
    { type: "event", payload: { type: "message_end", usage: { input: 1, output: 2 }, stop_reason: "end_turn" } },
    { type: "event", payload: { type: "error", message: "late" } },
  ]);
  const events = await collect(createMakaiProviderApi(transport as never).stream(REQUEST));

  const terminals = events.filter((event) => event.type === "message_end" || event.type === "error");
  assert.equal(terminals.length, 1);
  assert.equal(terminals[0]?.type, "message_end");
  assert.equal(events.at(-1)?.type, "message_end");
});

test("provider stream does not emit error after message_end and normalizes reasoning", async () => {
  const transport = new ScriptedTransport([
    { type: "event", payload: { type: "start", provider: "anthropic", api: "anthropic-messages", model: "claude" } },
    { type: "event", payload: { type: "reasoning", delta: "thinking" } },
    { type: "event", payload: { type: "toolcall_start", content_index: 0, id: "tc1", name: "lookup" } },
    { type: "event", payload: { type: "toolcall_delta", content_index: 0, delta: "{\"q\":" } },
    { type: "event", payload: { type: "toolcall_delta", content_index: 0, delta: "\"x\"}" } },
    { type: "event", payload: { type: "toolcall_end", content_index: 0 } },
    { type: "event", payload: { type: "done", reason: "tool_use", message: { usage: { input: 4, output: 5 } } } },
    { type: "stream_error", payload: { message: "late provider error" } },
  ]);
  const events = await collect(createMakaiProviderApi(transport as never).stream(REQUEST));

  assert.deepEqual(events[0], {
    type: "message_start",
    provider_id: "anthropic",
    api: "anthropic-messages",
    model_id: "claude",
  });
  assert.deepEqual(events[1], { type: "thinking_delta", delta: "thinking" });
  assert.deepEqual(events[2], {
    type: "tool_call",
    tool_call_id: "tc1",
    name: "lookup",
    arguments_json: "{\"q\":\"x\"}",
  });
  assert.equal(events.at(-1)?.type, "message_end");
  assert.equal(events.some((event) => event.type === "error"), false);
});

test("agent stream emits agent_start first and agent_end last", async () => {
  const transport = new ScriptedTransport([
    { type: "agent_started", payload: {} },
    { type: "event", payload: { type: "turn_start" } },
    { type: "event", payload: { type: "message_end", usage: { input: 1, output: 1 }, stop_reason: "end_turn" } },
    { type: "event", payload: { type: "turn_end", stop_reason: "end_turn" } },
    { type: "agent_event", payload: { type: "agent_end", stop_reason: "end_turn" } },
    { type: "event", payload: { type: "error", message: "late" } },
  ]);
  const events = await collect(createMakaiAgentApi(transport as never).stream(REQUEST));

  assert.equal(events[0]?.type, "agent_start");
  assert.equal(events.at(-1)?.type, "agent_end");
});

test("agent stream aggregates usage across multiple turns", async () => {
  const transport = new ScriptedTransport([
    { type: "agent_started", payload: {} },
    { type: "agent_event", payload: { type: "agent_start", session_id: "abc" } },
    { type: "event", payload: { type: "turn_start" } },
    { type: "event", payload: { type: "message_end", usage: { input: 2, output: 3, cache_read: 5, cache_write: 7 } } },
    { type: "event", payload: { type: "turn_end", stop_reason: "tool_use" } },
    { type: "event", payload: { type: "turn_start" } },
    { type: "event", payload: { type: "message_end", usage: { input: 11, output: 13, cache_read: 17, cache_write: 19 } } },
    { type: "event", payload: { type: "turn_end", stop_reason: "end_turn" } },
    { type: "agent_event", payload: { type: "agent_end", stop_reason: "max_turns" } },
  ]);
  const events = await collect(createMakaiAgentApi(transport as never).stream(REQUEST));
  const agentEnd = events.at(-1);

  assert.equal(agentEnd?.type, "agent_end");
  assert.deepEqual(agentEnd?.usage, { input: 13, output: 16, cache_read: 22, cache_write: 26 });
  assert.equal(agentEnd?.stop_reason, "max_turns");
  assert.equal(events.filter((event) => event.type === "turn_end").length, 2);
});

test("agent stream single failure emits one error and no agent_end", async () => {
  const transport = new ScriptedTransport([
    { type: "agent_started", payload: {} },
    { type: "agent_event", payload: { type: "agent_start" } },
    { type: "event", payload: { type: "error", message: "boom", code: "provider_error" } },
    { type: "agent_event", payload: { type: "agent_end", stop_reason: "end_turn" } },
    { type: "stream_error", payload: { message: "duplicate" } },
  ]);
  const events = await collect(createMakaiAgentApi(transport as never).stream(REQUEST));

  assert.equal(events.filter((event) => event.type === "error").length, 1);
  assert.deepEqual(events.at(-1), { type: "error", message: "boom", code: "provider_error" });
  assert.equal(events.some((event) => event.type === "agent_end"), false);
});

test("MakaiStreamError is thrown on provider async iterator failure", async () => {
  const transport = new ScriptedTransport([], new Error("transport failed"));
  const iterable = createMakaiProviderApi(transport as never).stream(REQUEST);

  await assert.rejects(
    async () => collect(iterable),
    (error: unknown) =>
      error instanceof MakaiStreamError &&
      error.kind === "transport_error" &&
      error.message === "transport failed",
  );
});

test("MakaiStreamError is thrown on agent async iterator failure", async () => {
  const transport = new ScriptedTransport([], new Error("agent transport failed"));
  const iterable = createMakaiAgentApi(transport as never).stream(REQUEST);

  await assert.rejects(
    async () => collect(iterable),
    (error: unknown) =>
      error instanceof MakaiStreamError &&
      error.kind === "transport_error" &&
      error.message === "agent transport failed",
  );
});

test("envelope nacks surface as one MakaiStreamError failure", async () => {
  const transport = new ScriptedTransport([
    { type: "nack", payload: { reason: "invalid model", error_code: "invalid_request" } },
    { type: "stream_error", payload: { message: "duplicate" } },
  ]);

  await assert.rejects(
    async () => collect(createMakaiProviderApi(transport as never).stream(REQUEST)),
    (error: unknown) =>
      error instanceof MakaiStreamError &&
      error.kind === "provider_error" &&
      error.code === "invalid_request" &&
      error.message === "invalid model",
  );
});
