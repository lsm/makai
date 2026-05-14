/**
 * Tests for AbortSignal support in models and auth APIs.
 */

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createMakaiAuthClient,
  createMakaiClient,
  createMakaiModelsApi,
  MakaiAuthError,
  MakaiStdioClient,
  type ListModelsResponse,
  type ModelDescriptor,
} from "../src";

const sourceFixturesDir = path.resolve(__dirname, "../../typescript/test/fixtures");

function makeDescriptor(overrides: Partial<ModelDescriptor> = {}): ModelDescriptor {
  return {
    model_ref: "anthropic/anthropic-messages@claude-sonnet-4-5",
    model_id: "claude-sonnet-4-5",
    display_name: "Claude Sonnet 4.5",
    provider_id: "anthropic",
    api: "anthropic-messages",
    auth_status: "authenticated",
    lifecycle: "stable",
    capabilities: ["chat", "streaming"],
    source: "dynamic",
    ...overrides,
  };
}

function makeResponse(models: ModelDescriptor[]): ListModelsResponse {
  return {
    models,
    fetched_at_ms: 1_760_000_000_198,
    cache_max_age_ms: 300_000,
  };
}

type ModelsHarness = {
  client: MakaiStdioClient;
  responsePath: string;
  logPath: string;
  cleanup: () => Promise<void>;
};

async function setupModelsHarness(): Promise<ModelsHarness> {
  const fixtureScript = path.join(sourceFixturesDir, "models-server.js");
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-abort-models-test-"));
  const responsePath = path.join(tmpDir, "response.json");
  const logPath = path.join(tmpDir, "request.log");
  fs.writeFileSync(responsePath, JSON.stringify(makeResponse([makeDescriptor()])));

  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath, MAKAI_TEST_RESPONSE_PATH: responsePath },
    handshakeTimeoutMs: 5000,
  });
  await client.connect();
  return {
    client,
    responsePath,
    logPath,
    cleanup: async () => {
      await client.close();
      fs.rmSync(tmpDir, { recursive: true, force: true });
    },
  };
}

// ---------------------------------------------------------------------------
// models.list abort tests
// ---------------------------------------------------------------------------

test("models.list rejects immediately with AbortSignal.abort()", async () => {
  const harness = await setupModelsHarness();
  try {
    const api = createMakaiModelsApi(harness.client);
    await assert.rejects(
      () => api.list({ signal: AbortSignal.abort() }),
      (error: unknown) =>
        error instanceof Error && error.name === "AbortError",
    );
  } finally {
    await harness.cleanup();
  }
});

test("models.list rejects when signal is aborted during response wait", async () => {
  const fixtureScript = path.join(sourceFixturesDir, "models-server.js");
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-abort-models-wait-test-"));
  const responsePath = path.join(tmpDir, "response.json");
  const logPath = path.join(tmpDir, "request.log");
  fs.writeFileSync(responsePath, JSON.stringify(makeResponse([makeDescriptor()])));

  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [fixtureScript],
    env: {
      ...process.env,
      MAKAI_TEST_REQUEST_LOG: logPath,
      MAKAI_TEST_RESPONSE_PATH: responsePath,
      MAKAI_TEST_RESPONSE_DELAY_MS: "5000", // Slow response so abort fires during wait
    },
    handshakeTimeoutMs: 5000,
  });
  await client.connect();
  try {
    const api = createMakaiModelsApi(client, { responseTimeoutMs: 10000 });
    const controller = new AbortController();
    const listPromise = api.list({ provider_id: "anthropic", signal: controller.signal });

    // Abort after a short delay
    await new Promise((resolve) => setTimeout(resolve, 10));
    controller.abort();

    await assert.rejects(
      () => listPromise,
      (error: unknown) =>
        error instanceof Error && error.name === "AbortError",
    );
  } finally {
    await client.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("models.resolve rejects immediately with AbortSignal.abort()", async () => {
  const harness = await setupModelsHarness();
  try {
    const api = createMakaiModelsApi(harness.client);
    await assert.rejects(
      () => api.resolve({ provider_id: "anthropic", model_id: "test", signal: AbortSignal.abort() }),
      (error: unknown) =>
        error instanceof Error && error.name === "AbortError",
    );
  } finally {
    await harness.cleanup();
  }
});

test("models.list succeeds when signal is not aborted", async () => {
  const harness = await setupModelsHarness();
  try {
    const api = createMakaiModelsApi(harness.client);
    const controller = new AbortController();
    const result = await api.list({ signal: controller.signal });
    assert.equal(result.models.length, 1);
    assert.equal(controller.signal.aborted, false);
  } finally {
    await harness.cleanup();
  }
});

// ---------------------------------------------------------------------------
// auth.login abort tests
// ---------------------------------------------------------------------------

test("auth.login rejects immediately with AbortSignal.abort()", async () => {
  const fixture = path.join(sourceFixturesDir, "auth-protocol-login-success-server.js");
  const client = await createMakaiAuthClient({
    command: process.execPath,
    args: [fixture],
    handshakeTimeoutMs: 5000,
    frameTimeoutMs: 5000,
  });
  try {
    await assert.rejects(
      () => client.auth.login("test-fixture", undefined, { signal: AbortSignal.abort() }),
      (error: unknown) =>
        error instanceof MakaiAuthError && error.kind === "cancelled",
    );
  } finally {
    await client.close();
  }
});

test("auth.login succeeds when signal is not aborted", async () => {
  const fixture = path.join(sourceFixturesDir, "auth-protocol-login-success-server.js");
  const client = await createMakaiAuthClient({
    command: process.execPath,
    args: [fixture],
    handshakeTimeoutMs: 5000,
    frameTimeoutMs: 5000,
  });
  try {
    const controller = new AbortController();
    const result = await client.auth.login("test-fixture", { onPrompt: () => "letmein" }, { signal: controller.signal });
    assert.deepEqual(result, { status: "success" });
    assert.equal(controller.signal.aborted, false);
  } finally {
    await client.close();
  }
});

// ---------------------------------------------------------------------------
// createMakaiClient integration abort test
// ---------------------------------------------------------------------------

test("createMakaiClient provider.complete rejects with AbortSignal.abort()", async () => {
  const fixtureScript = path.join(sourceFixturesDir, "execution-server.js");
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-abort-client-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
  });
  try {
    await assert.rejects(
      () => handle.provider.complete({
        model_ref: "anthropic/anthropic-messages@model",
        messages: [{ role: "user", content: "hello" }],
        options: { signal: AbortSignal.abort() },
      }),
      (error: unknown) =>
        error instanceof Error && error.name === "AbortError",
    );
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("createMakaiClient agent.stream rejects with AbortSignal.abort()", async () => {
  const fixtureScript = path.join(sourceFixturesDir, "execution-server.js");
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-abort-agent-stream-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const handle = await createMakaiClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath },
    handshakeTimeoutMs: 5000,
    responseTimeoutMs: 5000,
  });
  try {
    const events: unknown[] = [];
    await assert.rejects(
      async () => {
        for await (const event of handle.agent.stream({
          model_ref: "anthropic/anthropic-messages@model",
          messages: [{ role: "user", content: "hello" }],
          options: { signal: AbortSignal.abort() },
        })) {
          events.push(event);
        }
      },
      (error: unknown) =>
        error instanceof Error && error.name === "AbortError",
    );
    assert.equal(events.length, 0);
  } finally {
    await handle.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
