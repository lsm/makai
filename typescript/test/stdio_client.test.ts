import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { createMakaiStdioClient, MakaiStdioClient, StdioProtocolError } from "../src";

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
    args: [path.join(sourceFixturesDir, "route-server.js")],
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

test("nextFrameForSession preserves foreign session frames for their owner", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "route-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  try {
    client.send({ type: "agent_message", session_id: "a1" });
    client.send({ type: "agent_message", session_id: "a2" });

    const secondFrame = await client.nextFrameForSession("a2", 5000);
    assert.equal(secondFrame.type, "agent_event");
    assert.equal(secondFrame.session_id, "a2");

    const firstFrame = await client.nextFrameForSession("a1", 5000);
    assert.equal(firstFrame.type, "agent_event");
    assert.equal(firstFrame.session_id, "a1");
  } finally {
    await client.close();
  }
});

test("targeted frame reads preserve frames across stream and session owners", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "route-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  try {
    client.send({ type: "stream_request", stream_id: "s1" });
    client.send({ type: "agent_message", session_id: "a1" });

    const agentFrame = await client.nextFrameForSession("a1", 5000);
    assert.equal(agentFrame.type, "agent_event");
    assert.equal(agentFrame.session_id, "a1");

    const streamFrame = await client.nextFrameForStream("s1", 5000);
    assert.equal(streamFrame.type, "event");
    assert.equal(streamFrame.stream_id, "s1");
  } finally {
    await client.close();
  }
});

test("nextFrameForStream evicts late orphaned frames from the shared buffer", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "one-stream-server.js")],
    handshakeTimeoutMs: 5000,
    streamFrameQueueTtlMs: 20,
  });

  await client.connect();
  try {
    const orphanedWaiter = client.nextFrameForStream("s2", 30);
    await assert.rejects(orphanedWaiter, /timed out waiting for frame for stream s2 after 30ms/);

    const blocked = client.nextFrameForStream("s1", 80);
    client.send({ type: "stream_request", stream_id: "s2" });
    await assert.rejects(blocked, /timed out waiting for frame for stream s1 after 80ms/);

    await assert.rejects(
      () => client.nextFrameForStream("s2", 20),
      /timed out waiting for frame for stream s2 after 20ms/,
    );
  } finally {
    await client.close();
  }
});

test("createMakaiStdioClient forwards streamFrameQueueTtlMs", async () => {
  const client = await createMakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "one-stream-server.js")],
    handshakeTimeoutMs: 5000,
    streamFrameQueueTtlMs: 20,
  });

  await client.connect();
  try {
    const orphanedWaiter = client.nextFrameForStream("s2", 30);
    await assert.rejects(orphanedWaiter, /timed out waiting for frame for stream s2 after 30ms/);

    const blocked = client.nextFrameForStream("s1", 80);
    client.send({ type: "stream_request", stream_id: "s2" });
    await assert.rejects(blocked, /timed out waiting for frame for stream s1 after 80ms/);

    await assert.rejects(
      () => client.nextFrameForStream("s2", 20),
      /timed out waiting for frame for stream s2 after 20ms/,
    );
  } finally {
    await client.close();
  }
});

test("nextFrameForStream timeout includes time waiting for read lock", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "one-stream-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  try {
    const blocked = client.nextFrameForStream("s1", 160);
    const delayed = new Promise((resolve) => setTimeout(resolve, 40))
      .then(() => client.nextFrameForStream("s2", 80));

    setTimeout(() => {
      client.send({ type: "stream_request", stream_id: "s2" });
    }, 110);

    const [delayedResult, blockedResult] = await Promise.allSettled([delayed, blocked]);
    assert.equal(delayedResult.status, "rejected");
    assert.match(
      delayedResult.reason instanceof Error ? delayedResult.reason.message : String(delayedResult.reason),
      /timed out waiting for frame for stream s2 after 80ms/,
    );
    assert.equal(blockedResult.status, "rejected");
    assert.match(
      blockedResult.reason instanceof Error ? blockedResult.reason.message : String(blockedResult.reason),
      /timed out waiting for frame for stream s1 after 160ms/,
    );
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
