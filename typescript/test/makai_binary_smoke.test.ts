import assert from "node:assert/strict";
import test from "node:test";
import { createMakaiStdioClient, StdioProtocolError } from "../src";

const binaryPath = process.env.MAKAI_BINARY_PATH;

test("smoke: connect to makai binary over stdio", async (t) => {
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

test("smoke: version skew fails fast", async (t) => {
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
