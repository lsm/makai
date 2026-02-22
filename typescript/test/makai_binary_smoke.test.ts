import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createMakaiStdioClient, loginWithMakaiAuth, StdioProtocolError } from "../src";

const binaryPath = process.env.MAKAI_BINARY_PATH;

test("e2e: connect to makai binary over stdio", async (t) => {
  if (!binaryPath) {
    t.skip("MAKAI_BINARY_PATH is not set");
    return;
  }

  const client = await createMakaiStdioClient({
    resolver: { binaryPath },
    handshakeTimeoutMs: 1000,
  });
  await client.connect();
  await client.close();
});

test("e2e: send frame and timeout waiting for response", async (t) => {
  if (!binaryPath) {
    t.skip("MAKAI_BINARY_PATH is not set");
    return;
  }

  const client = await createMakaiStdioClient({
    resolver: { binaryPath },
    handshakeTimeoutMs: 1000,
  });
  await client.connect();
  client.send({ type: "stream_request", stream_id: "e2e-smoke" });
  await assert.rejects(() => client.nextFrame(150), /timed out waiting for frame/);
  await client.close();
});

test("e2e: version skew fails fast", async (t) => {
  if (!binaryPath) {
    t.skip("MAKAI_BINARY_PATH is not set");
    return;
  }

  const client = await createMakaiStdioClient({
    resolver: { binaryPath },
    expectedProtocolVersion: "2",
    handshakeTimeoutMs: 1000,
  });
  await assert.rejects(
    () => client.connect(),
    (error: unknown) =>
      error instanceof StdioProtocolError &&
      error.code === "version_mismatch" &&
      error.message.includes("protocol version mismatch"),
  );
  await client.close();
});

test("e2e: auth login persists credentials", async (t) => {
  if (!binaryPath) {
    t.skip("MAKAI_BINARY_PATH is not set");
    return;
  }

  const tempHome = await fs.mkdtemp(path.join(os.tmpdir(), "makai-auth-home-"));
  try {
    await loginWithMakaiAuth({
      resolver: { binaryPath },
      provider: "test-fixture",
      env: { ...process.env, HOME: tempHome },
      onPrompt: async () => "ok",
    });
    const authPath = path.join(tempHome, ".makai", "auth.json");
    const raw = await fs.readFile(authPath, "utf8");
    const parsed = JSON.parse(raw) as Record<string, { refresh?: string; access?: string }>;
    assert.equal(typeof parsed["test-fixture"]?.refresh, "string");
    assert.equal(typeof parsed["test-fixture"]?.access, "string");
  } finally {
    await fs.rm(tempHome, { recursive: true, force: true });
  }
});
