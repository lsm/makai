import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { createMakaiStdioClient, MakaiStdioClient, StdioFrame, StdioProtocolError } from "../src";

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

test("correlated session waits on one session each receive their own reply", async () => {
  // §13.3.1: two waits sharing one session route, each correlated with its
  // own outstanding request — each must receive the reply to ITS request,
  // regardless of arrival order on the shared route (#201).
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "correlate-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  try {
    const first = client.nextFrameForSession("a1", 5000, { correlate: "req-first" });
    const second = client.nextFrameForSession("a1", 5000, { correlate: "req-second" });
    // The second request's reply arrives FIRST on the wire: whichever wait
    // holds the read lock must park it for its owner, not consume it.
    client.send({ type: "agent_message", session_id: "a1", message_id: "req-second" });
    client.send({ type: "agent_message", session_id: "a1", message_id: "req-first" });

    const [firstFrame, secondFrame] = await Promise.all([first, second]);
    assert.equal(firstFrame.in_reply_to, "req-first");
    assert.equal(secondFrame.in_reply_to, "req-second");
  } finally {
    await client.close();
  }
});

test("correlated reply is not consumed by an uncorrelated waiter on the same session", async () => {
  // The duplicate-start misdelivery mode (#201): the established run's
  // output wait (no correlate) must not swallow a duplicate's correlated
  // agent_busy rejection while it holds the read lock.
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "correlate-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  try {
    const established = client.nextFrameForSession("a1", 5000);
    const duplicate = client.nextFrameForSession("a1", 5000, { correlate: "req-duplicate" });
    client.send({ type: "agent_message", session_id: "a1", message_id: "req-duplicate" });

    const duplicateFrame = await duplicate;
    assert.equal(duplicateFrame.in_reply_to, "req-duplicate");

    // The established wait stays pending (it did not steal the rejection)
    // while the event loop keeps serving macrotasks — no busy-spin from
    // re-dequeueing re-routed frames.
    let timersFired = 0;
    setTimeout(() => { timersFired += 1; }, 25);
    setTimeout(() => { timersFired += 1; }, 75);
    const stolen = await Promise.race([
      established.then((frame) => ({ stole: true, in_reply_to: frame.in_reply_to })),
      new Promise<{ stole: false }>((resolve) => setTimeout(() => resolve({ stole: false }), 150)),
    ]);
    assert.deepEqual(stolen, { stole: false });
    assert.equal(timersFired, 2);

    // Session-routed output (no in_reply_to) still reaches the established
    // waiter on the shared route.
    client.send({ type: "agent_message", session_id: "a1", message_id: "req-output", payload: { omit_in_reply_to: true } });
    const establishedFrame = await established;
    assert.equal(establishedFrame.session_id, "a1");
    assert.equal(establishedFrame.in_reply_to, undefined);
  } finally {
    await client.close();
  }
});

test("correlated stream waits on one stream each receive their own reply", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "correlate-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  try {
    const first = client.nextFrameForStream("s1", 5000, { correlate: "req-first" });
    const second = client.nextFrameForStream("s1", 5000, { correlate: "req-second" });
    client.send({ type: "stream_request", stream_id: "s1", message_id: "req-first" });
    client.send({ type: "stream_request", stream_id: "s1", message_id: "req-second" });

    const [firstFrame, secondFrame] = await Promise.all([first, second]);
    assert.equal(firstFrame.in_reply_to, "req-first");
    assert.equal(secondFrame.in_reply_to, "req-second");
    assert.equal(firstFrame.stream_id, "s1");
    assert.equal(secondFrame.stream_id, "s1");
  } finally {
    await client.close();
  }
});

test("frames with unmatched or absent in_reply_to keep session-routed behavior", async () => {
  // A reply whose in_reply_to matches no registered correlate — and frames
  // without in_reply_to at all — stay deliverable on the session route.
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "correlate-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  try {
    const unmatched = client.nextFrameForSession("a1", 5000);
    client.send({ type: "agent_message", session_id: "a1", message_id: "req-nobody-waiting-for" });
    const unmatchedFrame = await unmatched;
    assert.equal(unmatchedFrame.in_reply_to, "req-nobody-waiting-for");
    assert.equal(unmatchedFrame.session_id, "a1");

    const uncorrelated = client.nextFrameForSession("a1", 5000, { correlate: "req-registered" });
    client.send({ type: "agent_message", session_id: "a1", message_id: "req-no-reply-to", payload: { omit_in_reply_to: true } });
    const uncorrelatedFrame = await uncorrelated;
    assert.equal(uncorrelatedFrame.in_reply_to, undefined);
    assert.equal(uncorrelatedFrame.session_id, "a1");
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

test("nextFrameForStream does not consume timeout budget while waiting for read lock", async () => {
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
    // The s2 frame is sent at t=110 while blocked holds the lock. blocked
    // enqueues it as a foreign frame and continues waiting for s1. At t=160
    // blocked times out, releasing the lock. delayed then acquires the lock,
    // checks the queue, and finds the s2 frame already enqueued — so it
    // succeeds even though it started waiting for the lock at t=40.
    assert.equal(delayedResult.status, "fulfilled");
    assert.equal((delayedResult as PromiseFulfilledResult<StdioFrame>).value.type, "event");
    assert.equal((delayedResult as PromiseFulfilledResult<StdioFrame>).value.stream_id, "s2");
    assert.equal(blockedResult.status, "rejected");
    assert.match(
      blockedResult.reason instanceof Error ? blockedResult.reason.message : String(blockedResult.reason),
      /timed out waiting for frame for stream s1 after 160ms/,
    );
  } finally {
    await client.close();
  }
});

test("nextFrameForSession does not consume timeout budget while waiting for read lock", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "route-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  try {
    const blocked = client.nextFrameForSession("a1", 160);
    const delayed = new Promise((resolve) => setTimeout(resolve, 40))
      .then(() => client.nextFrameForSession("a2", 80));

    setTimeout(() => {
      client.send({ type: "agent_message", session_id: "a2" });
    }, 110);

    const [delayedResult, blockedResult] = await Promise.allSettled([delayed, blocked]);
    assert.equal(delayedResult.status, "fulfilled");
    assert.equal((delayedResult as PromiseFulfilledResult<StdioFrame>).value.type, "agent_event");
    assert.equal((delayedResult as PromiseFulfilledResult<StdioFrame>).value.session_id, "a2");
    assert.equal(blockedResult.status, "rejected");
    assert.match(
      blockedResult.reason instanceof Error ? blockedResult.reason.message : String(blockedResult.reason),
      /timed out waiting for frame for session a1 after 160ms/,
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
