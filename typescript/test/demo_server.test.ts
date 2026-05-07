import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import fsSync from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { startDemoServer } from "../demo/server";
import { createMakaiClient, MakaiAuthError } from "../src";

const binaryPath = process.env.MAKAI_BINARY_PATH;
const sourceFixturesDir = path.resolve(__dirname, "../../typescript/test/fixtures");
const executionFixture = path.join(sourceFixturesDir, "execution-server.js");

function fixtureServerOptions(tempHome: string, requestLog?: string) {
  return {
    command: process.execPath,
    args: [executionFixture],
    env: {
      MAKAI_TEST_AUTH_REQUIRES_PROMPT: "1",
      MAKAI_TEST_AUTH_STATE_PATH: path.join(tempHome, "auth-state.json"),
      ...(requestLog ? { MAKAI_TEST_REQUEST_LOG: requestLog } : {}),
    },
    homeDir: tempHome,
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForAuthStatus(
  baseUrl: string,
  sessionId: string,
  expected: "waiting_for_input" | "success" | "error",
  timeoutMs = 12_000,
): Promise<{ status: string; pendingPrompt?: { message?: string } }> {
  const deadline = Date.now() + timeoutMs;
  let last: { status: string; pendingPrompt?: { message?: string } } | undefined;
  while (Date.now() < deadline) {
    const response = await fetch(`${baseUrl}/api/auth/sessions/${sessionId}`);
    assert.equal(response.status, 200);
    last = (await response.json()) as { status: string; pendingPrompt?: { message?: string } };
    if (last.status === expected) return last;
    await sleep(150);
  }
  throw new Error(`timed out waiting for ${expected}, last status=${last?.status ?? "unknown"}`);
}

test("demo: serves UI and metadata", async () => {
  const tempHome = await fs.mkdtemp(path.join(os.tmpdir(), "makai-demo-home-"));
  const running = await startDemoServer({
    port: 0,
    ...fixtureServerOptions(tempHome),
  });
  try {
    const indexRes = await fetch(`${running.url}/`);
    assert.equal(indexRes.status, 200);
    const html = await indexRes.text();
    assert.equal(html.includes("Makai TS SDK Demo"), true);

    const metaRes = await fetch(`${running.url}/api/meta`);
    assert.equal(metaRes.status, 200);
    const meta = (await metaRes.json()) as {
      oauthProviders: Array<{ id: string }>;
      chatProviders: Array<{ id: string; authenticated: boolean }>;
    };
    assert.equal(meta.oauthProviders.some((provider) => provider.id === "test-fixture"), true);
    assert.equal(meta.chatProviders.some((provider) => provider.id === "test-fixture"), true);
  } finally {
    await running.close();
    await fs.rm(tempHome, { recursive: true, force: true });
  }
});

test("demo: chat endpoint supports fixture provider", async () => {
  const tempHome = await fs.mkdtemp(path.join(os.tmpdir(), "makai-demo-home-"));
  const logPath = path.join(tempHome, "request.log");
  const running = await startDemoServer({
    port: 0,
    ...fixtureServerOptions(tempHome, logPath),
  });
  try {
    const response = await fetch(`${running.url}/api/chat`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        provider: "test-fixture",
        model: "fixture-echo-v1",
        message: "hello world",
      }),
    });
    assert.equal(response.status, 200);
    const payload = (await response.json()) as { reply: string };
    assert.equal(payload.reply, "[fixture-echo-v1] dlrow olleh");

    const requests = fsSync.readFileSync(logPath, "utf8")
      .trim()
      .split(/\r?\n/)
      .filter(Boolean)
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    const streamRequest = requests.find((request) => request.type === "stream_request");
    assert.ok(streamRequest);
    assert.equal((streamRequest.payload as { model_ref?: string }).model_ref, "test-fixture/test-fixture@fixture-echo-v1");
  } finally {
    await running.close();
    await fs.rm(tempHome, { recursive: true, force: true });
  }
});

test("demo: fixture chat works without configured Makai runtime", async () => {
  const tempHome = await fs.mkdtemp(path.join(os.tmpdir(), "makai-demo-home-"));
  const running = await startDemoServer({
    port: 0,
    homeDir: tempHome,
    binaryPath: "",
    env: { MAKAI_BINARY_PATH: undefined },
  });
  try {
    const response = await fetch(`${running.url}/api/chat`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        provider: "test-fixture",
        model: "fixture-echo-v1",
        message: "binary free",
      }),
    });
    assert.equal(response.status, 200);
    const payload = (await response.json()) as { reply: string };
    assert.equal(payload.reply, "[fixture-echo-v1] eerf yranib");
  } finally {
    await running.close();
    await fs.rm(tempHome, { recursive: true, force: true });
  }
});

test("demo: auth-required chat response is client error", async () => {
  const tempHome = await fs.mkdtemp(path.join(os.tmpdir(), "makai-demo-home-"));
  const running = await startDemoServer({
    port: 0,
    command: process.execPath,
    args: [executionFixture],
    env: { MAKAI_TEST_AUTH_REQUIRED_ALWAYS: "1" },
    homeDir: tempHome,
  });
  try {
    const response = await fetch(`${running.url}/api/chat`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        provider: "anthropic",
        model: "claude-sonnet-4-5",
        message: "hello world",
      }),
    });
    assert.equal(response.status, 400);
    const payload = (await response.json()) as { error: string };
    assert.match(payload.error, /login required|auth/i);
  } finally {
    await running.close();
    await fs.rm(tempHome, { recursive: true, force: true });
  }
});

test("demo: auth fixture flow reaches cancelled terminal state", async () => {
  const tempHome = await fs.mkdtemp(path.join(os.tmpdir(), "makai-demo-home-"));
  const client = await createMakaiClient({
    command: process.execPath,
    args: [executionFixture],
    env: { ...process.env, HOME: tempHome, MAKAI_TEST_AUTH_REQUIRES_PROMPT: "1" },
    frameTimeoutMs: 5000,
  });
  try {
    await assert.rejects(
      () => client.auth.login("test-fixture"),
      (error: unknown) => error instanceof MakaiAuthError && error.kind === "cancelled",
    );
  } finally {
    await client.close();
    await fs.rm(tempHome, { recursive: true, force: true });
  }
});

test("demo: oauth fixture flow persists auth credentials", async () => {
  const tempHome = await fs.mkdtemp(path.join(os.tmpdir(), "makai-demo-home-"));
  const logPath = path.join(tempHome, "request.log");
  const running = await startDemoServer(binaryPath ? {
    port: 0,
    homeDir: tempHome,
    binaryPath,
    env: { MAKAI_TEST_REQUEST_LOG: logPath },
  } : {
    port: 0,
    ...fixtureServerOptions(tempHome, logPath),
  });
  try {
    const createRes = await fetch(`${running.url}/api/auth/sessions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ provider: "test-fixture" }),
    });
    assert.equal(createRes.status, 200);
    const created = (await createRes.json()) as { sessionId: string };
    assert.equal(typeof created.sessionId, "string");

    const waiting = await waitForAuthStatus(running.url, created.sessionId, "waiting_for_input");
    assert.equal(typeof waiting.pendingPrompt?.message, "string");

    const respondRes = await fetch(`${running.url}/api/auth/sessions/${created.sessionId}/respond`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ answer: "ok" }),
    });
    assert.equal(respondRes.status, 200);

    await waitForAuthStatus(running.url, created.sessionId, "success");

    if (binaryPath) {
      const authRaw = await fs.readFile(path.join(tempHome, ".makai", "auth.json"), "utf8");
      const auth = JSON.parse(authRaw) as Record<string, { access?: string; refresh?: string }>;
      assert.equal(typeof auth["test-fixture"]?.access, "string");
      assert.equal(typeof auth["test-fixture"]?.refresh, "string");
    }

    if (!binaryPath) {
      const metaRes = await fetch(`${running.url}/api/meta`);
      assert.equal(metaRes.status, 200);
      const meta = (await metaRes.json()) as { chatProviders: Array<{ id: string; authenticated: boolean }> };
      assert.equal(meta.chatProviders.find((provider) => provider.id === "test-fixture")?.authenticated, true);

      const requests = fsSync.readFileSync(logPath, "utf8")
        .trim()
        .split(/\r?\n/)
        .filter(Boolean)
        .map((line) => JSON.parse(line) as Record<string, unknown>);
      assert.equal(requests.some((request) => request.type === "auth_login_start"), true);
      assert.equal(requests.some((request) => request.type === "auth_prompt_response"), true);
    }
  } finally {
    await running.close();
    await fs.rm(tempHome, { recursive: true, force: true });
  }
});
