import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { startDemoServer } from "../demo/server";

const binaryPath = process.env.MAKAI_BINARY_PATH;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForAuthStatus(
  baseUrl: string,
  sessionId: string,
  expected: "waiting_for_input" | "success",
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
  const running = await startDemoServer({ port: 0, homeDir: tempHome });
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
  const running = await startDemoServer({ port: 0, homeDir: tempHome });
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
  } finally {
    await running.close();
    await fs.rm(tempHome, { recursive: true, force: true });
  }
});

test("demo: oauth fixture flow persists auth credentials", async (t) => {
  if (!binaryPath) {
    t.skip("MAKAI_BINARY_PATH is not set");
    return;
  }

  const tempHome = await fs.mkdtemp(path.join(os.tmpdir(), "makai-demo-home-"));
  const running = await startDemoServer({ port: 0, homeDir: tempHome, binaryPath });
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
    const authRaw = await fs.readFile(path.join(tempHome, ".makai", "auth.json"), "utf8");
    const auth = JSON.parse(authRaw) as Record<string, { access?: string; refresh?: string }>;
    assert.equal(typeof auth["test-fixture"]?.access, "string");
    assert.equal(typeof auth["test-fixture"]?.refresh, "string");
  } finally {
    await running.close();
    await fs.rm(tempHome, { recursive: true, force: true });
  }
});
