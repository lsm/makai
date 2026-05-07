import assert from "node:assert/strict";
import test from "node:test";
import {
  MakaiAuthError,
  MakaiAuthRequiredError,
  createMakaiProviderApi,
  type AuthFlowHandlers,
  type MakaiAuthApi,
} from "../src";
import type { RunOptions } from "../src/execution_types";
import type { MakaiStdioClient, StdioFrame } from "../src/stdio_client";

const REQUEST = {
  model_ref: "fixture/openai-responses@gpt-test",
  messages: [{ role: "user" as const, content: "hello" }],
};

class FakeTransport {
  public sent: StdioFrame[] = [];
  private streams: StdioFrame[][];

  constructor(streams: StdioFrame[][]) {
    this.streams = streams;
  }

  send(frame: StdioFrame): void {
    this.sent.push(frame);
  }

  async nextFrameForStream(streamId: string, _timeoutMs?: number): Promise<StdioFrame> {
    const stream = this.streams[0];
    if (!stream) throw new Error("no frames configured");
    const frame = stream.shift();
    if (!frame) throw new Error("stream exhausted");
    if (stream.length === 0) this.streams.shift();
    return { stream_id: streamId, ...frame };
  }
}

class FakeAuth implements MakaiAuthApi {
  public loginCalls: Array<{ providerId: string; handlers?: AuthFlowHandlers }> = [];
  constructor(private readonly outcomes: Array<"success" | "interactive_required"> = []) {}

  async listProviders() { return []; }

  async login(providerId: string, handlers?: AuthFlowHandlers): Promise<{ status: "success" }> {
    this.loginCalls.push({ providerId, handlers });
    const outcome = this.outcomes.shift() ?? "success";
    if (outcome === "interactive_required") {
      throw new MakaiAuthError("auth login cancelled (no onPrompt handler configured)", { kind: "cancelled" });
    }
    return { status: "success" };
  }
}

const authRequired = (provider_id = "fixture"): StdioFrame[] => [
  { type: "nack", payload: { error_code: "auth_required", reason: "login required", provider_id } },
];

const success = (text = "ok"): StdioFrame[] => [
  { type: "ack" },
  {
    type: "result",
    payload: {
      message: { role: "assistant", content: text },
      provider_id: "fixture",
      api: "openai-responses",
      model_id: "gpt-test",
    },
  },
];

test("manual policy throws typed auth_required error with provider_id", async () => {
  const auth = new FakeAuth();
  const provider = createMakaiProviderApi(
    new FakeTransport([authRequired("fixture")]) as unknown as MakaiStdioClient,
    { auth },
  );

  await assert.rejects(
    () => provider.complete(REQUEST),
    (error: unknown) => error instanceof MakaiAuthRequiredError && error.provider_id === "fixture",
  );
  assert.equal(auth.loginCalls.length, 0);
});

test("auto_once policy logs in then retries original request once", async () => {
  const auth = new FakeAuth(["success"]);
  const transport = new FakeTransport([authRequired("fixture"), success("retried")]);
  const provider = createMakaiProviderApi(transport as unknown as MakaiStdioClient, {
    auth,
    authRetryPolicy: "auto_once",
    authHandlers: { onPrompt: () => "code" },
  });

  const response = await provider.complete(REQUEST);
  assert.equal(response.message.content, "retried");
  assert.deepEqual(auth.loginCalls.map((call) => call.providerId), ["fixture"]);
  assert.equal(transport.sent.length, 2);
});

test("auto_once with no handlers and required interaction fails fast as auth_required", async () => {
  const auth = new FakeAuth(["interactive_required"]);
  const provider = createMakaiProviderApi(
    new FakeTransport([authRequired("fixture")]) as unknown as MakaiStdioClient,
    { auth, authRetryPolicy: "auto_once" },
  );

  await assert.rejects(
    () => provider.complete(REQUEST),
    (error: unknown) => error instanceof MakaiAuthRequiredError && error.provider_id === "fixture",
  );
  assert.equal(auth.loginCalls.length, 1);
});

test("auto_once with non-interactive auth succeeds without handlers", async () => {
  const auth = new FakeAuth(["success"]);
  const provider = createMakaiProviderApi(
    new FakeTransport([authRequired("fixture"), success("non-interactive")]) as unknown as MakaiStdioClient,
    { auth, authRetryPolicy: "auto_once" },
  );

  const response = await provider.complete(REQUEST);
  assert.equal(response.message.content, "non-interactive");
  assert.equal(auth.loginCalls.length, 1);
});

test("per-call policy overrides client-level default", async () => {
  const auth = new FakeAuth(["success"]);
  const provider = createMakaiProviderApi(
    new FakeTransport([authRequired("fixture"), success("per-call")]) as unknown as MakaiStdioClient,
    { auth, authRetryPolicy: "manual", authHandlers: { onPrompt: () => "client" } },
  );

  const response = await provider.complete({
    ...REQUEST,
    options: { auth_retry_policy: "auto_once" },
  });
  assert.equal(response.message.content, "per-call");
  assert.equal(auth.loginCalls.length, 1);
});

test("client-level auto_once is overridden by per-call manual", async () => {
  const auth = new FakeAuth(["success"]);
  const provider = createMakaiProviderApi(
    new FakeTransport([authRequired("fixture")]) as unknown as MakaiStdioClient,
    { auth, authRetryPolicy: "auto_once", authHandlers: { onPrompt: () => "client" } },
  );

  await assert.rejects(
    () => provider.complete({ ...REQUEST, options: { auth_retry_policy: "manual" } }),
    MakaiAuthRequiredError,
  );
  assert.equal(auth.loginCalls.length, 0);
});

test("auto_once uses client-level default handlers, not per-call request policy", async () => {
  const auth = new FakeAuth(["success"]);
  const handler = () => "client";
  const provider = createMakaiProviderApi(
    new FakeTransport([authRequired("fixture"), success("handler-default")]) as unknown as MakaiStdioClient,
    { auth, authRetryPolicy: "auto_once", authHandlers: { onPrompt: handler } },
  );

  await provider.complete(REQUEST);
  assert.equal(auth.loginCalls[0]?.handlers?.onPrompt, handler);
});
