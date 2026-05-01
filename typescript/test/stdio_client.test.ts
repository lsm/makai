import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { MakaiStdioClient, StdioProtocolError } from "../src";

const sourceFixturesDir = path.resolve(__dirname, "../../typescript/test/fixtures");

test("connect succeeds with ready handshake and receives event frame", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "ready-server.js")],
    // Generous timeout so cold-start jitter from concurrent test-file workers
    // (each spawning their own node fixture) does not flake this test.
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  try {
    client.send({ type: "stream_request", stream_id: "s1" });
    const frame = await client.nextFrame(5000);
    assert.equal(frame.type, "event");
    assert.equal(frame.stream_id, "s1");
  } finally {
    await client.close();
  }
});

test("nextFrameForStream preserves foreign frames for their owner", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "ready-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  try {
    client.send({ type: "stream_request", stream_id: "s1" });
    client.send({ type: "stream_request", stream_id: "s2" });

    const secondFrame = await client.nextFrameForStream("s2", 5000);
    assert.equal(secondFrame.type, "event");
    assert.equal(secondFrame.stream_id, "s2");

    const firstFrame = await client.nextFrameForStream("s1", 5000);
    assert.equal(firstFrame.type, "event");
    assert.equal(firstFrame.stream_id, "s1");
  } finally {
    await client.close();
  }
});

test("connect surfaces protocol error frame", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "error-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await assert.rejects(
    () => client.connect(),
    (error: unknown) =>
      error instanceof StdioProtocolError &&
      error.code === "version_mismatch" &&
      error.message.includes("unsupported protocol"),
  );
  await client.close();
});

test("connect times out when no handshake frame arrives", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "silent-server.js")],
    handshakeTimeoutMs: 100,
  });

  await assert.rejects(() => client.connect(), /handshake timed out/);
  await client.close();
});
