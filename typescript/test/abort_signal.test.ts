
import assert from "node:assert/strict";
import test from "node:test";
import {
  createMakaiAgentApi,
  createMakaiModelsApi,
  createMakaiProviderApi,
  MakaiAuthError,
  MakaiStreamError,
  type StdioFrame,
} from "../src";

const REQUEST = {
  model_ref: "fixture/anthropic-messages@model",
  messages: [{ role: "user" as const, content: "hello" }],
};

class AbortTestTransport {
  public readonly sent: StdioFrame[] = [];
  private readonly frames: StdioFrame[];
  private readonly failWith?: Error;
  private readonly pendingEntries: Array<{ reject: (reason?: unknown) => void; timer: NodeJS.Timeout }> = [];

  constructor(frames: StdioFrame[] = [], failWith?: Error) {
    this.frames = [...frames];
    this.failWith = failWith;
  }

  send(frame: StdioFrame): void {
    this.sent.push(frame);
  }

  rejectAll(): void {
    for (const entry of this.pendingEntries.splice(0)) {
      clearTimeout(entry.timer);
      entry.reject(new Error("transport cleaned up"));
    }
  }

  async nextFrameForStream(streamId: string, timeoutMs?: number): Promise<StdioFrame> {
    if (this.failWith) throw this.failWith;
    const frame = this.frames.shift();
    if (!frame) {
      return new Promise<StdioFrame>((_resolve, reject) => {
        const timer = setTimeout(() => {
          const idx = this.pendingEntries.findIndex((e) => e.reject === reject);
          if (idx >= 0) this.pendingEntries.splice(idx, 1);
          reject(new Error(`timed out waiting for frame for stream ${streamId} after ${timeoutMs ?? 1000}ms`));
        }, timeoutMs ?? 1000);
        this.pendingEntries.push({ reject, timer });
      });
    }
    return { stream_id: streamId, ...frame };
  }

  async nextFrameForSession(sessionId: string, timeoutMs?: number): Promise<StdioFrame> {
    if (this.failWith) throw this.failWith;
    const frame = this.frames.shift();
    if (!frame) {
      return new Promise<StdioFrame>((_resolve, reject) => {
        const timer = setTimeout(() => {
          const idx = this.pendingEntries.findIndex((e) => e.reject === reject);
          if (idx >= 0) this.pendingEntries.splice(idx, 1);
          reject(new Error(`timed out waiting for frame for session ${sessionId} after ${timeoutMs ?? 1000}ms`));
        }, timeoutMs ?? 1000);
        this.pendingEntries.push({ reject, timer });
      });
    }
    return { session_id: sessionId, ...frame };
  }
}

async function collect<T>(iterable: AsyncIterable<T>): Promise<T[]> {
  const events: T[] = [];
  for await (const event of iterable) events.push(event);
  return events;
}

async function flushMicrotasks(): Promise<void> {
  await new Promise<void>((resolve) => queueMicrotask(resolve));
}

test("provider.complete rejects immediately when AbortSignal.abort() is passed", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const signal = AbortSignal.abort();

  await assert.rejects(
    () => provider.complete({ ...REQUEST, options: { signal } }),
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  assert.equal(transport.sent.length, 0);
  transport.rejectAll();
  await flushMicrotasks();
});

test("provider.complete rejects when signal is aborted during frame wait", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();

  const completePromise = provider.complete({ ...REQUEST, options: { signal: controller.signal } });

  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => completePromise,
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  assert.equal(transport.sent.length, 2);
  assert.equal(transport.sent[0]?.type, "complete_request");
  assert.equal(transport.sent[1]?.type, "abort_request");
  transport.rejectAll();
  await flushMicrotasks();
});

test("provider.complete with AbortSignal.timeout aborts after timeout", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5);
  try {
    await assert.rejects(
      () => provider.complete({ ...REQUEST, options: { signal: controller.signal } }),
      (error: unknown) =>
        error instanceof Error && error.name === "AbortError",
    );
  } finally {
    clearTimeout(timer);
    transport.rejectAll();
    await flushMicrotasks();
  }
});

test("provider.stream rejects immediately when AbortSignal.abort() is passed", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const signal = AbortSignal.abort();

  await assert.rejects(
    () => collect(provider.stream({ ...REQUEST, options: { signal } })),
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  assert.equal(transport.sent.length, 0);
  transport.rejectAll();
  await flushMicrotasks();
});

test("provider.stream stops iteration when signal is aborted during streaming", async () => {
  const transport = new AbortTestTransport([
    { type: "event", payload: { type: "message_start" } },
    { type: "event", payload: { type: "text_delta", delta: "hello" } },
  ]);
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();

  const events: unknown[] = [];
  const streamPromise = (async () => {
    for await (const event of provider.stream({ ...REQUEST, options: { signal: controller.signal } })) {
      events.push(event);
      controller.abort();
    }
  })();

  await assert.rejects(
    () => streamPromise,
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  assert.ok(events.length >= 1, "expected at least one event before abort");
  transport.rejectAll();
  await flushMicrotasks();
});

test("provider.stream with AbortSignal.timeout aborts after timeout", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5);
  try {
    await assert.rejects(
      () => collect(provider.stream({ ...REQUEST, options: { signal: controller.signal } })),
      (error: unknown) =>
        error instanceof Error && error.name === "AbortError",
    );
  } finally {
    clearTimeout(timer);
    transport.rejectAll();
    await flushMicrotasks();
  }
});

test("agent.run rejects immediately when AbortSignal.abort() is passed", async () => {
  const transport = new AbortTestTransport();
  const agent = createMakaiAgentApi(transport as never);
  const signal = AbortSignal.abort();

  await assert.rejects(
    () => agent.run({ ...REQUEST, options: { signal } }),
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  assert.equal(transport.sent.length, 0);
  transport.rejectAll();
  await flushMicrotasks();
});

test("agent.run rejects when signal is aborted during frame wait", async () => {
  const transport = new AbortTestTransport();
  const agent = createMakaiAgentApi(transport as never);
  const controller = new AbortController();

  const runPromise = agent.run({ ...REQUEST, options: { signal: controller.signal } });

  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => runPromise,
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  assert.equal(transport.sent.length, 2);
  assert.equal(transport.sent[0]?.type, "agent_start");
  assert.equal(transport.sent[0]?.sequence, 1);
  assert.equal(transport.sent[1]?.type, "agent_stop");
  assert.equal(transport.sent[1]?.sequence, 2);
  transport.rejectAll();
  await flushMicrotasks();
});

test("agent.run abort completes the sequence probe before the abort surfaces, so an immediate same-id retry is not agent_busy (#210 gap 7)", async () => {
  const queue: StdioFrame[] = [];
  const sent: StdioFrame[] = [];
  const transport = {
    send(frame: StdioFrame): void {
      sent.push(frame);
      if (frame.type === "agent_start") {
        queue.push({ type: "agent_started", session_id: frame.session_id, message_id: "m-started", sequence: 1, timestamp: 1, version: 1, in_reply_to: frame.message_id, payload: { session_id: frame.session_id } });
      }
      if (frame.type === "agent_stop") {
        if ((frame.sequence as number) < 3) {
          queue.push({ type: "agent_error", session_id: frame.session_id, message_id: "m-reject", sequence: 0, timestamp: 1, version: 1, in_reply_to: frame.message_id, payload: { code: "invalid_request", message: "invalid sequence" } });
        } else {
          queue.push({ type: "agent_stopped", session_id: frame.session_id, message_id: "m-stopped", sequence: 9, timestamp: 1, version: 1, in_reply_to: frame.message_id, payload: {} });
        }
      }
    },
    async nextFrameForSession(_sessionId: string, timeoutMs?: number, wait?: { correlate?: string }): Promise<StdioFrame> {
      const correlate = wait?.correlate;
      const index = correlate !== undefined
        ? queue.findIndex((entry) => entry.in_reply_to === correlate)
        : queue.findIndex((entry) => entry.in_reply_to === undefined);
      if (index >= 0) return queue.splice(index, 1)[0];
      await new Promise((resolve) => setTimeout(resolve, Math.min(timeoutMs ?? 50, 50)));
      throw new Error("timed out");
    },
  };
  const agent = createMakaiAgentApi(transport as never);
  const controller = new AbortController();

  const runPromise = agent.run({ ...REQUEST, options: { signal: controller.signal } });
  await new Promise((resolve) => setTimeout(resolve, 20));
  controller.abort();

  await assert.rejects(
    () => runPromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );
  assert.deepEqual(
    sent.map((frame) => `${frame.type}:${frame.sequence}`),
    ["agent_start:1", "agent_message:2", "agent_stop:2", "agent_stop:3"],
  );
  await new Promise((resolve) => setTimeout(resolve, 260));
});

test("agent.run abort cancels the abandoned session read instead of leaving it pending (#210 gap 7)", async () => {
  const queue: StdioFrame[] = [];
  let pendingReads = 0;
  const transport = {
    send(frame: StdioFrame): void {
      if (frame.type === "agent_start") {
        queue.push({ type: "agent_started", session_id: frame.session_id, message_id: "m-started", sequence: 1, timestamp: 1, version: 1, in_reply_to: frame.message_id, payload: { session_id: frame.session_id } });
      }
      if (frame.type === "agent_stop") {
        if ((frame.sequence as number) < 3) {
          queue.push({ type: "agent_error", session_id: frame.session_id, message_id: "m-reject", sequence: 0, timestamp: 1, version: 1, in_reply_to: frame.message_id, payload: { code: "invalid_request", message: "invalid sequence" } });
        } else {
          queue.push({ type: "agent_stopped", session_id: frame.session_id, message_id: "m-stopped", sequence: 9, timestamp: 1, version: 1, in_reply_to: frame.message_id, payload: {} });
        }
      }
    },
    nextFrameForSession(_sessionId: string, timeoutMs: number | undefined, wait?: { correlate?: string; signal?: AbortSignal }): Promise<StdioFrame> {
      const correlate = wait?.correlate;
      const index = correlate !== undefined ? queue.findIndex((entry) => entry.in_reply_to === correlate) : -1;
      if (index >= 0) return Promise.resolve(queue.splice(index, 1)[0]);
      pendingReads += 1;
      return new Promise<StdioFrame>((_resolve, reject) => {
        const settle = () => {
          pendingReads -= 1;
          reject(new Error("timed out"));
        };
        const timer = setTimeout(settle, timeoutMs ?? 1000);
        wait?.signal?.addEventListener("abort", () => {
          clearTimeout(timer);
          pendingReads -= 1;
          reject(new Error("aborted"));
        }, { once: true });
      });
    },
  };
  const agent = createMakaiAgentApi(transport as never, { responseTimeoutMs: 5000 });
  const controller = new AbortController();

  const runPromise = agent.run({ ...REQUEST, options: { signal: controller.signal } });
  await new Promise((resolve) => setTimeout(resolve, 20));
  controller.abort();

  await assert.rejects(
    () => runPromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(pendingReads, 0, "the abandoned session read must be aborted with the caller's signal");
});

test("agent.stream rejects immediately when AbortSignal.abort() is passed", async () => {
  const transport = new AbortTestTransport();
  const agent = createMakaiAgentApi(transport as never);
  const signal = AbortSignal.abort();

  await assert.rejects(
    () => collect(agent.stream({ ...REQUEST, options: { signal } })),
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  assert.equal(transport.sent.length, 0);
  transport.rejectAll();
  await flushMicrotasks();
});

test("agent.stream stops iteration when signal is aborted during streaming", async () => {
  const transport = new AbortTestTransport([
    { type: "agent_started", payload: {} },
    { type: "event", payload: { type: "turn_start" } },
  ]);
  const agent = createMakaiAgentApi(transport as never);
  const controller = new AbortController();

  const events: unknown[] = [];
  const streamPromise = (async () => {
    for await (const event of agent.stream({ ...REQUEST, options: { signal: controller.signal } })) {
      events.push(event);
      controller.abort();
    }
  })();

  await assert.rejects(
    () => streamPromise,
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  assert.ok(events.length >= 1, "expected at least one event before abort");
  assert.deepEqual(transport.sent.map((frame) => frame.type), ["agent_start", "agent_message", "agent_stop"]);
  assert.deepEqual(transport.sent.map((frame) => frame.sequence), [1, 2, 3]);
  transport.rejectAll();
  await flushMicrotasks();
});

test("agent.stream with AbortSignal.timeout aborts after timeout", async () => {
  const transport = new AbortTestTransport();
  const agent = createMakaiAgentApi(transport as never);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5);
  try {
    await assert.rejects(
      () => collect(agent.stream({ ...REQUEST, options: { signal: controller.signal } })),
      (error: unknown) =>
        error instanceof Error && error.name === "AbortError",
    );
  } finally {
    clearTimeout(timer);
    transport.rejectAll();
    await flushMicrotasks();
  }
});

test("provider.complete removes abort listener after rejection", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();
  const signal = controller.signal;

  const listenersBefore = listenerCount(signal);

  const completePromise = provider.complete({ ...REQUEST, options: { signal } });
  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => completePromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  assert.equal(listenerCount(signal), listenersBefore);
  transport.rejectAll();
  await flushMicrotasks();
});

test("agent.stream removes abort listener after rejection", async () => {
  const transport = new AbortTestTransport();
  const agent = createMakaiAgentApi(transport as never);
  const controller = new AbortController();
  const signal = controller.signal;

  const listenersBefore = listenerCount(signal);

  const streamPromise = collect(agent.stream({ ...REQUEST, options: { signal } }));
  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => streamPromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  assert.equal(listenerCount(signal), listenersBefore);
  transport.rejectAll();
  await flushMicrotasks();
});

test("provider.stream with pre-aborted signal does not send envelope", async () => {
  const transport = new AbortTestTransport([
    { type: "event", payload: { type: "message_start" } },
  ]);
  const provider = createMakaiProviderApi(transport as never);

  await assert.rejects(
    () => collect(provider.stream({ ...REQUEST, options: { signal: AbortSignal.abort() } })),
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );
  assert.equal(transport.sent.length, 0);
  transport.rejectAll();
  await flushMicrotasks();
});

test("agent.run with pre-aborted signal does not send envelope", async () => {
  const transport = new AbortTestTransport([
    { type: "agent_started", payload: {} },
  ]);
  const agent = createMakaiAgentApi(transport as never);

  await assert.rejects(
    () => agent.run({ ...REQUEST, options: { signal: AbortSignal.abort() } }),
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );
  assert.equal(transport.sent.length, 0);
  transport.rejectAll();
  await flushMicrotasks();
});

test("provider.complete succeeds when signal is not aborted", async () => {
  const transport = new AbortTestTransport([
    { type: "ack" },
    { type: "complete_response", payload: { message: { role: "assistant", content: "ok" }, usage: { input: 1, output: 1 } } },
  ]);
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();

  const result = await provider.complete({ ...REQUEST, options: { signal: controller.signal } });
  assert.equal(result.message.role, "assistant");
  assert.equal(controller.signal.aborted, false);
});

test("provider.stream completes normally when signal is not aborted", async () => {
  const transport = new AbortTestTransport([
    { type: "message_start", provider_id: "fixture", api: "anthropic-messages", model_id: "model" },
    { type: "text_delta", delta: "hi" },
    { type: "message_end", usage: { input: 1, output: 2 }, stop_reason: "end_turn" },
  ]);
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();

  const events = await collect(provider.stream({ ...REQUEST, options: { signal: controller.signal } }));
  assert.equal(events.length, 3);
  assert.equal(events.at(-1)?.type, "message_end");
  assert.equal(controller.signal.aborted, false);
});

test("abort rejection is a plain Error with name 'AbortError', not MakaiStreamError", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);

  try {
    await provider.complete({ ...REQUEST, options: { signal: AbortSignal.abort() } });
    assert.fail("expected rejection");
  } catch (error) {
    assert.ok(error instanceof Error);
    assert.equal(error.name, "AbortError");
    assert.equal(error instanceof MakaiStreamError, false);
  }
  transport.rejectAll();
  await flushMicrotasks();
});

test("provider.complete withAuthRetry aborts before auth retry sends second envelope", async () => {
  const transport = new AbortTestTransport();
  transport.nextFrameForStream = async (streamId: string, _timeoutMs?: number) => {
    return {
      stream_id: streamId,
      type: "nack",
      payload: { reason: "login required", error_code: "auth_required", provider_id: "fixture" },
    };
  };
  const auth = {
    loginCalls: 0,
    async listProviders() { return []; },
    async login(_providerId: string, _handlers?: unknown, options?: { signal?: AbortSignal }): Promise<{ status: "success" }> {
      this.loginCalls += 1;
      return new Promise<{ status: "success" }>((resolve, reject) => {
        const signal = options?.signal;
        if (signal?.aborted) {
          const error = new Error("login aborted");
          error.name = "AbortError";
          reject(error);
          return;
        }
        const onAbort = () => {
          const error = new Error("login aborted");
          error.name = "AbortError";
          reject(error);
        };
        signal?.addEventListener("abort", onAbort, { once: true });
      });
    },
  };
  const controller = new AbortController();
  const completePromise = createMakaiProviderApi(transport as never, {
    auth,
    authRetryPolicy: "auto_once",
  }).complete({ ...REQUEST, options: { auth_retry_policy: "auto_once", signal: controller.signal } });

  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => completePromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  assert.equal(transport.sent.filter((f) => f.type === "complete_request").length, 1);
  assert.equal(auth.loginCalls, 1);
  transport.rejectAll();
  await flushMicrotasks();
});

test("agent.run withAuthRetry aborts before retry sends second agent_start", async () => {
  const transport = new AbortTestTransport();
  transport.nextFrameForSession = async (sessionId: string, _timeoutMs?: number) => {
    return {
      session_id: sessionId,
      type: "nack",
      payload: { reason: "login required", error_code: "auth_required", provider_id: "fixture" },
    };
  };
  const auth = {
    loginCalls: 0,
    async listProviders() { return []; },
    async login(_providerId: string, _handlers?: unknown, options?: { signal?: AbortSignal }): Promise<{ status: "success" }> {
      this.loginCalls += 1;
      return new Promise<{ status: "success" }>((resolve, reject) => {
        const signal = options?.signal;
        if (signal?.aborted) {
          const error = new Error("login aborted");
          error.name = "AbortError";
          reject(error);
          return;
        }
        const onAbort = () => {
          const error = new Error("login aborted");
          error.name = "AbortError";
          reject(error);
        };
        signal?.addEventListener("abort", onAbort, { once: true });
      });
    },
  };
  const controller = new AbortController();
  const runPromise = createMakaiAgentApi(transport as never, {
    auth,
    authRetryPolicy: "auto_once",
  }).run({ ...REQUEST, options: { auth_retry_policy: "auto_once", signal: controller.signal } });

  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => runPromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  assert.equal(transport.sent.filter((f) => f.type === "agent_start").length, 1);
  assert.equal(auth.loginCalls, 1);
  transport.rejectAll();
  await flushMicrotasks();
});

function listenerCount(signal: AbortSignal): number {
  if ("listenerCount" in signal && typeof signal.listenerCount === "function") {
    return (signal as unknown as { listenerCount(event: string): number }).listenerCount("abort");
  }
  return 0;
}

test("provider.complete sends abort_request cancel envelope on abort", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();

  const completePromise = provider.complete({ ...REQUEST, options: { signal: controller.signal } });

  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => completePromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  const cancelFrame = transport.sent.find((f) => f.type === "abort_request");
  assert.ok(cancelFrame, "expected abort_request frame");
  const payload = cancelFrame!.payload as Record<string, unknown>;
  assert.equal(typeof payload.target_stream_id, "string");
  assert.equal(payload.reason, "client aborted");
  const requestFrame = transport.sent.find((f) => f.type === "complete_request");
  assert.equal(payload.target_stream_id, requestFrame?.stream_id);

  transport.rejectAll();
  await flushMicrotasks();
});

test("provider.stream sends abort_request cancel envelope on abort", async () => {
  const transport = new AbortTestTransport();
  let frameCount = 0;
  transport.nextFrameForStream = async (streamId: string, _timeoutMs?: number) => {
    frameCount++;
    if (frameCount === 1) {
      return { stream_id: streamId, type: "event", payload: { type: "message_start" } };
    }
    return { stream_id: streamId, type: "event", payload: { type: "text_delta", delta: "hi" } };
  };
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();

  const events: unknown[] = [];
  const streamPromise = (async () => {
    for await (const event of provider.stream({ ...REQUEST, options: { signal: controller.signal } })) {
      events.push(event);
      controller.abort();
    }
  })();

  await assert.rejects(
    () => streamPromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  const cancelFrames = transport.sent.filter((f) => f.type === "abort_request");
  assert.equal(cancelFrames.length, 1, "expected exactly one abort_request frame");
  const payload = cancelFrames[0]!.payload as Record<string, unknown>;
  assert.equal(payload.reason, "client aborted");
  const requestFrame = transport.sent.find((f) => f.type === "stream_request");
  assert.equal(payload.target_stream_id, requestFrame?.stream_id);

  transport.rejectAll();
  await flushMicrotasks();
});

test("agent.run sends agent_stop cancel envelope on abort", async () => {
  const transport = new AbortTestTransport();
  const agent = createMakaiAgentApi(transport as never);
  const controller = new AbortController();

  const runPromise = agent.run({ ...REQUEST, options: { signal: controller.signal } });

  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => runPromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  const cancelFrame = transport.sent.find((f) => f.type === "agent_stop");
  assert.ok(cancelFrame, "expected agent_stop frame");
  const payload = cancelFrame!.payload as Record<string, unknown>;
  assert.equal(payload.reason, "client aborted");
  const startFrame = transport.sent.find((f) => f.type === "agent_start");
  assert.equal(cancelFrame!.session_id, startFrame?.session_id);

  transport.rejectAll();
  await flushMicrotasks();
});

test("agent.stream sends agent_stop cancel envelope on abort", async () => {
  const transport = new AbortTestTransport();
  let frameCount = 0;
  transport.nextFrameForSession = async (sessionId: string, _timeoutMs?: number) => {
    frameCount++;
    if (frameCount === 1) {
      return { session_id: sessionId, type: "agent_started", payload: {} };
    }
    return {
      session_id: sessionId,
      type: "agent_event",
      payload: { event_json: JSON.stringify({ type: "turn_start" }) },
    };
  };
  const agent = createMakaiAgentApi(transport as never);
  const controller = new AbortController();

  const events: unknown[] = [];
  const streamPromise = (async () => {
    for await (const event of agent.stream({ ...REQUEST, options: { signal: controller.signal } })) {
      events.push(event);
      controller.abort();
    }
  })();

  await assert.rejects(
    () => streamPromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  const cancelFrames = transport.sent.filter((f) => f.type === "agent_stop");
  assert.equal(cancelFrames.length, 1, "expected exactly one agent_stop frame");
  const payload = cancelFrames[0]!.payload as Record<string, unknown>;
  assert.equal(payload.reason, "client aborted");

  transport.rejectAll();
  await flushMicrotasks();
});

test("cancel is not sent when abort occurs before transport I/O", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);

  await assert.rejects(
    () => provider.complete({ ...REQUEST, options: { signal: AbortSignal.abort() } }),
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  assert.equal(transport.sent.length, 0);
  transport.rejectAll();
  await flushMicrotasks();
});

test("provider.complete withAuthRetry sends cancel on abort during auth login", async () => {
  const transport = new AbortTestTransport();
  transport.nextFrameForStream = async (streamId: string, _timeoutMs?: number) => {
    return {
      stream_id: streamId,
      type: "nack",
      payload: { reason: "login required", error_code: "auth_required", provider_id: "fixture" },
    };
  };
  const auth = {
    async listProviders() { return []; },
    async login(_providerId: string, _handlers?: unknown, options?: { signal?: AbortSignal }): Promise<{ status: "success" }> {
      return new Promise<{ status: "success" }>((resolve, reject) => {
        const signal = options?.signal;
        if (signal?.aborted) {
          const error = new Error("login aborted");
          error.name = "AbortError";
          reject(error);
          return;
        }
        const onAbort = () => {
          const error = new Error("login aborted");
          error.name = "AbortError";
          reject(error);
        };
        signal?.addEventListener("abort", onAbort, { once: true });
      });
    },
  };
  const controller = new AbortController();
  const completePromise = createMakaiProviderApi(transport as never, {
    auth,
    authRetryPolicy: "auto_once",
  }).complete({ ...REQUEST, options: { auth_retry_policy: "auto_once", signal: controller.signal } });

  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => completePromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  const cancelFrame = transport.sent.find((f) => f.type === "abort_request");
  assert.ok(cancelFrame, "expected abort_request frame from withAuthRetry onAbort");
  const payload = cancelFrame!.payload as Record<string, unknown>;
  assert.equal(payload.reason, "client aborted");

  transport.rejectAll();
  await flushMicrotasks();
});

test("models.list sends abort_request cancel envelope on abort", async () => {
  const transport = new AbortTestTransport();
  const models = createMakaiModelsApi(transport as never);
  const controller = new AbortController();

  const listPromise = models.list({ provider_id: "anthropic", signal: controller.signal });

  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => listPromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  const cancelFrame = transport.sent.find((f) => f.type === "abort_request");
  assert.ok(cancelFrame, "expected abort_request frame");
  const payload = cancelFrame!.payload as Record<string, unknown>;
  assert.equal(typeof payload.target_stream_id, "string");
  assert.equal(payload.reason, "client aborted");
  const requestFrame = transport.sent.find((f) => f.type === "models_request");
  assert.equal(payload.target_stream_id, requestFrame?.stream_id);

  transport.rejectAll();
  await flushMicrotasks();
});
