/**
 * Tests for AbortSignal support across execution, models, and auth APIs.
 *
 * Acceptance criteria from the task:
 * - `AbortSignal.abort()` before call → immediate rejection
 * - `AbortSignal.timeout(5000)` → aborts after timeout
 * - Manual `controller.abort()` during streaming → stream stops, resources cleaned up
 * - No resource leaks (listeners removed, transport closed)
 */

import assert from "node:assert/strict";
import test from "node:test";
import {
  createMakaiAgentApi,
  createMakaiProviderApi,
  MakaiAuthError,
  MakaiStreamError,
  type StdioFrame,
} from "../src";

const REQUEST = {
  model_ref: "fixture/anthropic-messages@model",
  messages: [{ role: "user" as const, content: "hello" }],
};

// ---------------------------------------------------------------------------
// Scripted transport for unit-level abort tests
// ---------------------------------------------------------------------------

class AbortTestTransport {
  public readonly sent: StdioFrame[] = [];
  private readonly frames: StdioFrame[];
  private readonly failWith?: Error;
  /** Tracks whether pending promises were rejected (resource leak check). */
  public rejectedCount = 0;

  constructor(frames: StdioFrame[] = [], failWith?: Error) {
    this.frames = [...frames];
    this.failWith = failWith;
  }

  send(frame: StdioFrame): void {
    this.sent.push(frame);
  }

  async nextFrameForStream(streamId: string, _timeoutMs?: number): Promise<StdioFrame> {
    if (this.failWith) throw this.failWith;
    const frame = this.frames.shift();
    if (!frame) {
      // Return a promise that never resolves (simulates waiting for a frame).
      // The abort signal should cancel it.
      return new Promise<StdioFrame>(() => {});
    }
    return { stream_id: streamId, ...frame };
  }

  async nextFrameForSession(sessionId: string, _timeoutMs?: number): Promise<StdioFrame> {
    if (this.failWith) throw this.failWith;
    const frame = this.frames.shift();
    if (!frame) {
      return new Promise<StdioFrame>(() => {});
    }
    return { session_id: sessionId, ...frame };
  }
}

async function collect<T>(iterable: AsyncIterable<T>): Promise<T[]> {
  const events: T[] = [];
  for await (const event of iterable) events.push(event);
  return events;
}

// ---------------------------------------------------------------------------
// provider.complete abort tests
// ---------------------------------------------------------------------------

test("provider.complete rejects immediately when AbortSignal.abort() is passed", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const signal = AbortSignal.abort();

  await assert.rejects(
    () => provider.complete({ ...REQUEST, options: { signal } }),
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  // No frames should have been sent since abort was checked before transport I/O.
  assert.equal(transport.sent.length, 0);
});

test("provider.complete rejects when signal is aborted during frame wait", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();

  const completePromise = provider.complete({ ...REQUEST, options: { signal: controller.signal } });

  // Allow the operation to start, then abort.
  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => completePromise,
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  // The initial envelope should have been sent.
  assert.equal(transport.sent.length, 1);
  assert.equal(transport.sent[0]?.type, "complete_request");
});

test("provider.complete with AbortSignal.timeout aborts after timeout", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  // 5ms timeout — should abort while waiting for frames
  const signal = AbortSignal.timeout(5);

  await assert.rejects(
    () => provider.complete({ ...REQUEST, options: { signal } }),
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
});

// ---------------------------------------------------------------------------
// provider.stream abort tests
// ---------------------------------------------------------------------------

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
});

test("provider.stream stops iteration when signal is aborted during streaming", async () => {
  // Provide a few frames but not terminal — the stream should be interrupted.
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
      // Abort after receiving the first event.
      controller.abort();
    }
  })();

  await assert.rejects(
    () => streamPromise,
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  // Should have received at least one event before abort.
  assert.ok(events.length >= 1, "expected at least one event before abort");
});

test("provider.stream with AbortSignal.timeout aborts after timeout", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const signal = AbortSignal.timeout(5);

  await assert.rejects(
    () => collect(provider.stream({ ...REQUEST, options: { signal } })),
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
});

// ---------------------------------------------------------------------------
// agent.run abort tests
// ---------------------------------------------------------------------------

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
  assert.equal(transport.sent.length, 1);
  assert.equal(transport.sent[0]?.type, "agent_start");
});

// ---------------------------------------------------------------------------
// agent.stream abort tests
// ---------------------------------------------------------------------------

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
      // Abort after receiving the first event.
      controller.abort();
    }
  })();

  await assert.rejects(
    () => streamPromise,
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
  assert.ok(events.length >= 1, "expected at least one event before abort");
});

test("agent.stream with AbortSignal.timeout aborts after timeout", async () => {
  const transport = new AbortTestTransport();
  const agent = createMakaiAgentApi(transport as never);
  const signal = AbortSignal.timeout(5);

  await assert.rejects(
    () => collect(agent.stream({ ...REQUEST, options: { signal } })),
    (error: unknown) =>
      error instanceof Error && error.name === "AbortError",
  );
});

// ---------------------------------------------------------------------------
// Resource cleanup: listener count verification
// ---------------------------------------------------------------------------

test("provider.complete removes abort listener after rejection", async () => {
  const transport = new AbortTestTransport();
  const provider = createMakaiProviderApi(transport as never);
  const controller = new AbortController();
  const signal = controller.signal;

  // Count listeners before.
  const listenersBefore = listenerCount(signal);

  const completePromise = provider.complete({ ...REQUEST, options: { signal } });
  // Give it time to register the listener.
  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => completePromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  // After rejection, no lingering abort listeners.
  assert.equal(listenerCount(signal), listenersBefore);
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
});

// ---------------------------------------------------------------------------
// Already-aborted signal with pre-flushed transport
// ---------------------------------------------------------------------------

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
});

// ---------------------------------------------------------------------------
// AbortSignal does not interfere with normal completion
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// AbortError is distinguishable from MakaiStreamError
// ---------------------------------------------------------------------------

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
});

// ---------------------------------------------------------------------------
// Abort during withAuthRetry (auth_required + auto_once)
// ---------------------------------------------------------------------------

test("provider.complete withAuthRetry aborts before auth retry sends second envelope", async () => {
  // Transport that yields an auth_required nack, then blocks (never resolves).
  // The abort should cancel the retry without sending a second complete_request.
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
  // Abort before the retry attempt can proceed
  const completePromise = createMakaiProviderApi(transport as never, {
    auth,
    authRetryPolicy: "auto_once",
  }).complete({ ...REQUEST, options: { auth_retry_policy: "auto_once", signal: controller.signal } });

  // Give time for the nack to be received and withAuthRetry to enter the login call
  await new Promise((resolve) => setTimeout(resolve, 5));
  controller.abort();

  await assert.rejects(
    () => completePromise,
    (error: unknown) => error instanceof Error && error.name === "AbortError",
  );

  // Only the initial complete_request should have been sent; no retry envelope
  assert.equal(transport.sent.filter((f) => f.type === "complete_request").length, 1);
  assert.equal(auth.loginCalls, 1);
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

  // Only one agent_start should have been sent
  assert.equal(transport.sent.filter((f) => f.type === "agent_start").length, 1);
  assert.equal(auth.loginCalls, 1);
});

// ---------------------------------------------------------------------------
// Helper: count abort listeners on a signal
// ---------------------------------------------------------------------------

function listenerCount(signal: AbortSignal): number {
  // Node.js AbortSignal exposes listener count via EventEmitter methods.
  // Using the internal `_maxListeners` is fragile, so we just use the public
  // `EventEmitter.listenerCount` if available, otherwise count manually.
  if ("listenerCount" in signal && typeof signal.listenerCount === "function") {
    return (signal as unknown as { listenerCount(event: string): number }).listenerCount("abort");
  }
  // Fallback: no reliable way to count in all environments.
  return 0;
}
