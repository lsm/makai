import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createMakaiAuthClient,
  flattenAuthEvent,
  MakaiAuthError,
  type CreateMakaiAuthClientOptions,
  type MakaiAuthEvent,
} from "../src";

const sourceFixturesDir = path.resolve(__dirname, "../../typescript/test/fixtures");
const ULID_RE = /^[0-7][0-9A-HJKMNP-TV-Z]{25}$/;

function fixtureClientOptions(
  fixture: string,
  extra: Partial<CreateMakaiAuthClientOptions> = {},
): CreateMakaiAuthClientOptions {
  return {
    command: process.execPath,
    args: [path.join(sourceFixturesDir, fixture)],
    handshakeTimeoutMs: 5000,
    frameTimeoutMs: 5000,
    ...extra,
  };
}

test("flattenAuthEvent normalizes every Zig union wire variant", () => {
  assert.deepEqual(flattenAuthEvent({
    auth_url: {
      flow_id: "00000000000000000000000000",
      provider_id: "fixture",
      url: "https://example.test/auth",
      instructions: "open browser",
    },
  }), {
    type: "auth_url",
    flow_id: "00000000000000000000000000",
    provider_id: "fixture",
    url: "https://example.test/auth",
    instructions: "open browser",
  });

  assert.deepEqual(flattenAuthEvent({
    prompt: {
      flow_id: "00000000000000000000000001",
      prompt_id: "device_code",
      provider_id: "fixture",
      message: "enter code",
      allow_empty: false,
    },
  }), {
    type: "prompt",
    flow_id: "00000000000000000000000001",
    prompt_id: "device_code",
    provider_id: "fixture",
    message: "enter code",
    allow_empty: false,
  });

  assert.deepEqual(flattenAuthEvent({
    progress: {
      flow_id: "00000000000000000000000002",
      provider_id: "fixture",
      message: "waiting",
    },
  }), {
    type: "progress",
    flow_id: "00000000000000000000000002",
    provider_id: "fixture",
    message: "waiting",
  });

  assert.deepEqual(flattenAuthEvent({
    success: {
      flow_id: "00000000000000000000000003",
      provider_id: "fixture",
    },
  }), {
    type: "success",
    flow_id: "00000000000000000000000003",
    provider_id: "fixture",
  });

  assert.deepEqual(flattenAuthEvent({
    error: {
      flow_id: "00000000000000000000000004",
      provider_id: "fixture",
      code: "auth_failed",
      message: "boom",
    },
  }), {
    type: "error",
    flow_id: "00000000000000000000000004",
    provider_id: "fixture",
    code: "auth_failed",
    message: "boom",
  });
});

test("client.auth.listProviders parses providers payload", async () => {
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-providers-server.js"),
  );
  try {
    const providers = await client.auth.listProviders();
    assert.equal(providers.length, 3);
    assert.deepEqual(providers[0], {
      id: "anthropic",
      name: "Anthropic",
      auth_status: "login_required",
    });
    assert.equal(providers[1]?.id, "github-copilot");
    assert.equal(providers[1]?.auth_status, "authenticated");
    assert.equal(providers[2]?.auth_status, "failed");
    assert.equal(providers[2]?.last_error, "previous attempt rejected");
  } finally {
    await client.close();
  }
});

test("client.auth.listProviders preserves frames for concurrent auth streams", async () => {
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-concurrent-server.js"),
  );
  try {
    const [first, second] = await Promise.all([
      client.auth.listProviders(),
      client.auth.listProviders(),
    ]);
    assert.equal(first[0]?.id, "anthropic");
    assert.equal(second[0]?.id, "anthropic");
  } finally {
    await client.close();
  }
});

test("client.auth.listProviders emits ULID stream and message IDs on stdio", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-wire-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const frameLogPath = path.join(tmpDir, "frames.log");
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-providers-server.js", {
      env: {
        ...process.env,
        MAKAI_TEST_REQUEST_LOG: logPath,
        MAKAI_TEST_FRAME_LOG: frameLogPath,
      },
    }),
  );
  try {
    await client.auth.listProviders();
    const request = JSON.parse(fs.readFileSync(logPath, "utf8").trim()) as Record<string, unknown>;
    assert.equal(request.type, "auth_providers_request");
    assert.equal(typeof request.stream_id, "string");
    assert.equal(typeof request.message_id, "string");
    assert.match(request.stream_id as string, ULID_RE);
    assert.match(request.message_id as string, ULID_RE);

    const frames = fs.readFileSync(frameLogPath, "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    assert.equal(frames.length, 2);
    for (const frame of frames) {
      assert.equal(frame.stream_id, request.stream_id);
      assert.equal(frame.in_reply_to, request.message_id);
      assert.equal(typeof frame.message_id, "string");
      assert.match(frame.message_id as string, ULID_RE);
    }
  } finally {
    await client.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.auth.login emits ULID flow IDs on stdio", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-auth-login-wire-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-login-success-server.js", {
      env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath },
    }),
  );
  try {
    await client.auth.login("test-fixture", { onPrompt: () => "letmein" });
    const request = JSON.parse(fs.readFileSync(logPath, "utf8").trim()) as Record<string, unknown>;
    assert.equal(request.type, "auth_login_start");
    assert.equal(typeof request.stream_id, "string");
    assert.equal(typeof request.message_id, "string");
    assert.match(request.stream_id as string, ULID_RE);
    assert.match(request.message_id as string, ULID_RE);
  } finally {
    await client.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test("client.auth.login resolves on success after prompt loop", async () => {
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-login-success-server.js"),
  );
  try {
    const events: MakaiAuthEvent[] = [];
    const result = await client.auth.login("test-fixture", {
      onEvent: (event) => events.push(event),
      onPrompt: async (prompt) => {
        assert.equal(prompt.type, "prompt");
        assert.equal(prompt.allow_empty, false);
        assert.equal(prompt.prompt_id, "device_code");
        return "letmein";
      },
    });
    assert.deepEqual(result, { status: "success" });
    assert.equal(events.some((e) => e.type === "auth_url"), true);
    assert.equal(events.some((e) => e.type === "prompt"), true);
    assert.equal(events.some((e) => e.type === "success"), true);
  } finally {
    await client.close();
  }
});

test("client.auth.login drains cancellation after prompt handler throws", async () => {
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-prompt-throw-cleanup-server.js"),
  );
  try {
    await assert.rejects(
      () =>
        client.auth.login("test-fixture", {
          onPrompt: () => {
            throw new Error("prompt handler failed");
          },
        }),
      /prompt handler failed/,
    );

    const result = await client.auth.login("test-fixture", {
      onPrompt: () => "letmein",
    });
    assert.deepEqual(result, { status: "success" });
  } finally {
    await client.close();
  }
});

test("client.auth.login rejects with cancelled error on cancelled login result", async () => {
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-login-cancelled-server.js"),
  );
  try {
    await assert.rejects(
      () => client.auth.login("test-fixture"),
      (error: unknown) =>
        error instanceof MakaiAuthError && error.kind === "cancelled",
    );
  } finally {
    await client.close();
  }
});

test("client.auth.listProviders timeout includes actionable diagnostics", async () => {
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-providers-server.js", {
      frameTimeoutMs: 20,
      env: { ...process.env, MAKAI_TEST_RESPONSE_DELAY_MS: "100" },
    }),
  );
  try {
    await assert.rejects(
      () => client.auth.listProviders(),
      (error: unknown) =>
        error instanceof MakaiAuthError &&
        error.kind === "transport_error" &&
        error.message.includes("Timed out waiting for auth_providers_response after 20ms") &&
        error.message.includes("stream_id=") &&
        error.message.includes("message_id=") &&
        error.message.includes("Verify the makai binary") &&
        error.diagnostics?.operation === "auth_providers_response" &&
        error.diagnostics.timeout_ms === 20 &&
        typeof error.diagnostics.stream_id === "string" &&
        typeof error.diagnostics.message_id === "string",
    );
  } finally {
    await client.close();
  }
});

test("client.auth.login rejects with provider_error and propagates code/message on failure", async () => {
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-login-failed-server.js"),
  );
  try {
    await assert.rejects(
      () => client.auth.login("test-fixture"),
      (error: unknown) =>
        error instanceof MakaiAuthError &&
        error.kind === "provider_error" &&
        error.code === "auth_failed" &&
        error.message.includes("fixture auth failed"),
    );
  } finally {
    await client.close();
  }
});

test("client.auth.login per-call handlers override client-level defaults", async () => {
  const calls: string[] = [];
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-login-success-server.js", {
      handlers: {
        onPrompt: () => {
          calls.push("client-default");
          return "wrong-answer";
        },
        onEvent: () => {
          calls.push("client-default-event");
        },
      },
    }),
  );
  try {
    const result = await client.auth.login("test-fixture", {
      onPrompt: () => {
        calls.push("per-call");
        return "letmein";
      },
    });
    assert.deepEqual(result, { status: "success" });
    // Per-call handlers entirely replace client-level defaults; the default
    // onPrompt/onEvent must not have been invoked.
    assert.equal(calls.includes("client-default"), false);
    assert.equal(calls.includes("client-default-event"), false);
    assert.equal(calls.includes("per-call"), true);
  } finally {
    await client.close();
  }
});

test("client.auth.login falls back to client-level handlers when no per-call handlers given", async () => {
  const calls: string[] = [];
  const client = await createMakaiAuthClient(
    fixtureClientOptions("auth-protocol-login-success-server.js", {
      handlers: {
        onPrompt: () => {
          calls.push("client-default");
          return "letmein";
        },
      },
    }),
  );
  try {
    const result = await client.auth.login("test-fixture");
    assert.deepEqual(result, { status: "success" });
    assert.deepEqual(calls, ["client-default"]);
  } finally {
    await client.close();
  }
});
