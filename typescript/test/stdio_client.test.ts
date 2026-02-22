import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { MakaiStdioClient, StdioProtocolError } from "../src";

const sourceFixturesDir = path.resolve(__dirname, "../../typescript/test/fixtures");

test("connect succeeds with ready handshake and receives event frame", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "ready-server.js")],
    handshakeTimeoutMs: 1000,
  });

  await client.connect();
  client.send({ type: "stream_request", stream_id: "s1" });
  const frame = await client.nextFrame(1000);
  assert.equal(frame.type, "event");
  assert.equal(frame.stream_id, "s1");
  await client.close();
});

test("connect surfaces protocol error frame", async () => {
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "error-server.js")],
    handshakeTimeoutMs: 1000,
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
