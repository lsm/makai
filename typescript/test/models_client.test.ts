import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createMakaiModelsApi,
  MakaiProtocolError,
  MakaiStdioClient,
  type ListModelsResponse,
  type ModelDescriptor,
} from "../src";

const sourceFixturesDir = path.resolve(__dirname, "../../typescript/test/fixtures");
const fixtureScript = path.join(sourceFixturesDir, "models-server.js");

function makeDescriptor(overrides: Partial<ModelDescriptor> = {}): ModelDescriptor {
  return {
    model_ref: "anthropic/anthropic-messages@claude-sonnet-4-5",
    model_id: "claude-sonnet-4-5",
    display_name: "Claude Sonnet 4.5",
    provider_id: "anthropic",
    api: "anthropic-messages",
    auth_status: "authenticated",
    lifecycle: "stable",
    capabilities: ["chat", "streaming", "tools", "reasoning"],
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

type Harness = {
  client: MakaiStdioClient;
  responsePath: string;
  nackPath: string;
  logPath: string;
  cleanup: () => Promise<void>;
};

async function setupHarness(opts: {
  response?: ListModelsResponse;
  nack?: { reason: string; error_code?: string };
}): Promise<Harness> {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-models-test-"));
  const responsePath = path.join(tmpDir, "response.json");
  const nackPath = path.join(tmpDir, "nack.json");
  const logPath = path.join(tmpDir, "request.log");

  const env: NodeJS.ProcessEnv = {
    ...process.env,
    MAKAI_TEST_REQUEST_LOG: logPath,
  };

  if (opts.nack) {
    fs.writeFileSync(nackPath, JSON.stringify(opts.nack));
    env.MAKAI_TEST_NACK_PATH = nackPath;
  } else {
    fs.writeFileSync(
      responsePath,
      JSON.stringify(opts.response ?? makeResponse([makeDescriptor()])),
    );
    env.MAKAI_TEST_RESPONSE_PATH = responsePath;
  }

  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [fixtureScript],
    env,
    // Bump from default to absorb subprocess-spawn jitter under parallel
    // test-file execution (multiple node:test workers can spawn dozens of
    // node fixture children at once on first cold start).
    handshakeTimeoutMs: 5000,
  });
  await client.connect();

  return {
    client,
    responsePath,
    nackPath,
    logPath,
    cleanup: async () => {
      await client.close();
      fs.rmSync(tmpDir, { recursive: true, force: true });
    },
  };
}

function readLoggedRequests(logPath: string): Array<Record<string, unknown>> {
  if (!fs.existsSync(logPath)) return [];
  return fs
    .readFileSync(logPath, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

test("models.list parses and returns full ListModelsResponse shape", async () => {
  const expected = makeResponse([
    makeDescriptor({
      base_url: "https://api.anthropic.com",
      context_window: 200_000,
      max_output_tokens: 8_192,
      reasoning_default: "medium",
      metadata: { tier: "standard" },
    }),
    makeDescriptor({
      model_ref: "anthropic/anthropic-messages@claude-haiku-4-5",
      model_id: "claude-haiku-4-5",
      display_name: "Claude Haiku 4.5",
      lifecycle: "preview",
      source: "static_fallback",
      capabilities: ["chat"],
    }),
  ]);
  const harness = await setupHarness({ response: expected });
  try {
    const api = createMakaiModelsApi(harness.client);
    const result = await api.list();

    assert.equal(result.models.length, 2);
    assert.equal(result.fetched_at_ms, expected.fetched_at_ms);
    assert.equal(result.cache_max_age_ms, expected.cache_max_age_ms);

    const first = result.models[0]!;
    assert.equal(first.model_ref, "anthropic/anthropic-messages@claude-sonnet-4-5");
    assert.equal(first.base_url, "https://api.anthropic.com");
    assert.equal(first.context_window, 200_000);
    assert.equal(first.max_output_tokens, 8_192);
    assert.equal(first.reasoning_default, "medium");
    assert.deepEqual(first.metadata, { tier: "standard" });
    assert.deepEqual(first.capabilities, ["chat", "streaming", "tools", "reasoning"]);
    assert.equal(first.source, "dynamic");

    const second = result.models[1]!;
    assert.equal(second.lifecycle, "preview");
    assert.equal(second.source, "static_fallback");
    assert.equal(second.base_url, undefined);
    assert.equal(second.metadata, undefined);
  } finally {
    await harness.cleanup();
  }
});

test("models.list defaults missing cache_max_age_ms to 5 minutes", async () => {
  // Spec §2.3: clients should default to 300_000 when server omits it.
  const responseWithoutCache = {
    models: [makeDescriptor()],
    fetched_at_ms: 1_760_000_000_500,
  } as ListModelsResponse;
  const harness = await setupHarness({ response: responseWithoutCache });
  try {
    const api = createMakaiModelsApi(harness.client);
    const result = await api.list();
    assert.equal(result.cache_max_age_ms, 300_000);
  } finally {
    await harness.cleanup();
  }
});

test("models.list passes filter fields through on the wire", async () => {
  const harness = await setupHarness({
    response: makeResponse([makeDescriptor()]),
  });
  try {
    const api = createMakaiModelsApi(harness.client);
    await api.list({
      provider_id: "anthropic",
      api: "anthropic-messages",
      include_deprecated: true,
      include_login_required: false,
    });

    const logged = readLoggedRequests(harness.logPath);
    assert.equal(logged.length, 1);
    const env = logged[0]!;
    assert.equal(env.type, "models_request");
    assert.equal(env.version, 1);
    assert.equal(typeof env.stream_id, "string");
    assert.equal(env.message_id, env.stream_id);

    const payload = env.payload as Record<string, unknown>;
    assert.equal(payload.provider_id, "anthropic");
    assert.equal(payload.api, "anthropic-messages");
    assert.equal(payload.include_deprecated, true);
    assert.equal(payload.include_login_required, false);
    // Resolve-only fields must not leak into a regular list.
    assert.equal(payload.model_id, undefined);
  } finally {
    await harness.cleanup();
  }
});

test("models.resolve issues models_request with exact model_id filter", async () => {
  const target = makeDescriptor();
  const harness = await setupHarness({ response: makeResponse([target]) });
  try {
    const api = createMakaiModelsApi(harness.client);
    const result = await api.resolve({
      provider_id: "anthropic",
      api: "anthropic-messages",
      model_id: "claude-sonnet-4-5",
    });

    assert.equal(result.model.model_ref, target.model_ref);
    assert.equal(result.model.model_id, "claude-sonnet-4-5");

    const logged = readLoggedRequests(harness.logPath);
    assert.equal(logged.length, 1);
    const payload = (logged[0] as { payload: Record<string, unknown> }).payload;
    assert.equal(payload.provider_id, "anthropic");
    assert.equal(payload.api, "anthropic-messages");
    assert.equal(payload.model_id, "claude-sonnet-4-5");
  } finally {
    await harness.cleanup();
  }
});

test("models.resolve throws invalid_request when runtime returns multiple matches", async () => {
  const harness = await setupHarness({
    response: makeResponse([
      makeDescriptor({ api: "anthropic-messages" }),
      makeDescriptor({
        api: "openai-completions",
        model_ref: "anthropic/openai-completions@claude-sonnet-4-5",
      }),
    ]),
  });
  try {
    const api = createMakaiModelsApi(harness.client);
    await assert.rejects(
      () =>
        api.resolve({
          provider_id: "anthropic",
          model_id: "claude-sonnet-4-5",
        }),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        /2 matches/.test(err.message),
    );
  } finally {
    await harness.cleanup();
  }
});

test("models.resolve throws invalid_request 'model not found' when no match", async () => {
  const harness = await setupHarness({ response: makeResponse([]) });
  try {
    const api = createMakaiModelsApi(harness.client);
    await assert.rejects(
      () =>
        api.resolve({
          provider_id: "anthropic",
          model_id: "non-existent-model",
        }),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model not found",
    );
  } finally {
    await harness.cleanup();
  }
});

test("models.list propagates nack error_code as MakaiProtocolError", async () => {
  const harness = await setupHarness({
    nack: { reason: "model not found", error_code: "invalid_request" },
  });
  try {
    const api = createMakaiModelsApi(harness.client);
    await assert.rejects(
      () => api.list({ provider_id: "anthropic", model_id: "nope" }),
      (err: unknown) =>
        err instanceof MakaiProtocolError &&
        err.code === "invalid_request" &&
        err.message === "model not found",
    );
  } finally {
    await harness.cleanup();
  }
});

test("models.resolve rejects locally when provider_id or model_id is missing", async () => {
  const harness = await setupHarness({ response: makeResponse([makeDescriptor()]) });
  try {
    const api = createMakaiModelsApi(harness.client);
    await assert.rejects(
      // @ts-expect-error testing runtime guard
      () => api.resolve({ model_id: "claude-sonnet-4-5" }),
      (err: unknown) =>
        err instanceof MakaiProtocolError && err.code === "invalid_request",
    );
    await assert.rejects(
      // @ts-expect-error testing runtime guard
      () => api.resolve({ provider_id: "anthropic" }),
      (err: unknown) =>
        err instanceof MakaiProtocolError && err.code === "invalid_request",
    );
  } finally {
    await harness.cleanup();
  }
});
