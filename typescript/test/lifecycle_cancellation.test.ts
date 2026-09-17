import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  MakaiAuthError,
  MakaiProtocolError,
  MakaiStdioClient,
  MakaiStreamError,
  createMakaiAuthClient,
  createMakaiClient,
  createMakaiStdioClient,
} from "../src";

const sourceFixturesDir = path.resolve(__dirname, "../../typescript/test/fixtures");
const pidReportingServer = path.join(sourceFixturesDir, "pid-reporting-server.js");
const streamCancelObserverServer = path.join(sourceFixturesDir, "stream-cancel-observer-server.js");

const providerRequest = {
  model_ref: "anthropic/anthropic-messages@claude-sonnet-4-5",
  messages: [{ role: "user" as const, content: "hi" }],
};

async function tempFile(prefix: string): Promise<string> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), prefix));
  return path.join(dir, "data");
}

async function readLines(filePath: string): Promise<string[]> {
  try {
    const raw = await fs.readFile(filePath, "utf8");
    return raw.split("\n").filter((line) => line.length > 0);
  } catch {
    return [];
  }
}

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error: unknown) {
    if (error && typeof error === "object" && "code" in error && error.code === "EPERM") return true;
    return false;
  }
}

async function waitForPidFile(pidFile: string, timeoutMs = 4000): Promise<number> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const raw = await fs.readFile(pidFile, "utf8").catch(() => "");
    const pid = Number(raw.trim());
    if (Number.isInteger(pid) && pid > 0) return pid;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`fixture never reported a pid via ${pidFile}`);
}

async function waitForExit(pid: number, timeoutMs = 4000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!processIsAlive(pid)) return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return false;
}

async function waitForLine(filePath: string, predicate: (lines: string[]) => boolean, timeoutMs = 2000): Promise<string[]> {
  const deadline = Date.now() + timeoutMs;
  let lines = await readLines(filePath);
  while (Date.now() < deadline && !predicate(lines)) {
    await new Promise((resolve) => setTimeout(resolve, 20));
    lines = await readLines(filePath);
  }
  return lines;
}

test("handshake timeout terminates the spawned runtime process", async () => {
  const pidFile = await tempFile("makai-pid-timeout-");
  const client = await createMakaiStdioClient({
    command: process.execPath,
    args: [pidReportingServer],
    env: { ...process.env, MAKAI_TEST_PID_FILE: pidFile, MAKAI_TEST_HANDSHAKE: "silent" },
    handshakeTimeoutMs: 150,
  });

  await assert.rejects(() => client.connect(), /handshake timed out/);
  const pid = await waitForPidFile(pidFile);
  assert.equal(await waitForExit(pid), true, `pid ${pid} survived a failed handshake`);
  await client.close();
});

test("createMakaiClient leaves no orphan runtime when the handshake times out", async () => {
  const pidFile = await tempFile("makai-pid-factory-");
  await assert.rejects(
    () =>
      createMakaiClient({
        command: process.execPath,
        args: [pidReportingServer],
        env: { ...process.env, MAKAI_TEST_PID_FILE: pidFile, MAKAI_TEST_HANDSHAKE: "silent" },
        handshakeTimeoutMs: 150,
      }),
    /handshake timed out/,
  );

  const pid = await waitForPidFile(pidFile);
  assert.equal(await waitForExit(pid), true, `createMakaiClient orphaned pid ${pid}`);
});

test("createMakaiAuthClient leaves no orphan runtime when the handshake times out", async () => {
  const pidFile = await tempFile("makai-pid-auth-factory-");
  await assert.rejects(
    () =>
      createMakaiAuthClient({
        command: process.execPath,
        args: [pidReportingServer],
        env: { ...process.env, MAKAI_TEST_PID_FILE: pidFile, MAKAI_TEST_HANDSHAKE: "silent" },
        handshakeTimeoutMs: 150,
      }),
    /handshake timed out/,
  );

  const pid = await waitForPidFile(pidFile);
  assert.equal(await waitForExit(pid), true, `createMakaiAuthClient orphaned pid ${pid}`);
});

test("protocol version mismatch terminates the spawned runtime process", async () => {
  const pidFile = await tempFile("makai-pid-skew-");
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [pidReportingServer],
    env: { ...process.env, MAKAI_TEST_PID_FILE: pidFile, MAKAI_TEST_HANDSHAKE: "version_mismatch" },
    handshakeTimeoutMs: 3000,
  });

  await assert.rejects(() => client.connect(), /protocol version mismatch/);
  const pid = await waitForPidFile(pidFile);
  assert.equal(await waitForExit(pid), true, `pid ${pid} survived a version-skew handshake`);
  await client.close();
});

test("handshake error frame terminates the spawned runtime process", async () => {
  const pidFile = await tempFile("makai-pid-errorframe-");
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [pidReportingServer],
    env: { ...process.env, MAKAI_TEST_PID_FILE: pidFile, MAKAI_TEST_HANDSHAKE: "error_frame" },
    handshakeTimeoutMs: 3000,
  });

  await assert.rejects(() => client.connect(), /unsupported protocol/);
  const pid = await waitForPidFile(pidFile);
  assert.equal(await waitForExit(pid), true, `pid ${pid} survived a rejected handshake`);
  await client.close();
});

test("breaking out of provider.stream cancels the runtime stream", async () => {
  const frameLog = await tempFile("makai-frames-break-");
  const client = await createMakaiClient({
    command: process.execPath,
    args: [streamCancelObserverServer],
    env: { ...process.env, MAKAI_TEST_FRAME_LOG: frameLog },
    handshakeTimeoutMs: 3000,
    responseTimeoutMs: 5000,
  });

  try {
    let received = 0;
    for await (const event of client.provider.stream(providerRequest)) {
      if (event.type === "text_delta") received += 1;
      if (received >= 2) break;
    }
    assert.equal(received, 2);

    const frames = await waitForLine(frameLog, (lines) => lines.includes("abort_request"));
    assert.ok(frames.includes("abort_request"), `expected abort_request, runtime saw ${JSON.stringify(frames)}`);
  } finally {
    await client.close();
  }
});

test("provider.stream that runs to completion does not cancel the runtime stream", async () => {
  const frameLog = await tempFile("makai-frames-complete-");
  const client = await createMakaiClient({
    command: process.execPath,
    args: [streamCancelObserverServer],
    env: { ...process.env, MAKAI_TEST_FRAME_LOG: frameLog, MAKAI_TEST_DELTA_COUNT: "2", MAKAI_TEST_DELTA_INTERVAL_MS: "5" },
    handshakeTimeoutMs: 3000,
    responseTimeoutMs: 5000,
  });

  try {
    const types: string[] = [];
    for await (const event of client.provider.stream(providerRequest)) types.push(event.type);
    assert.equal(types.at(-1), "message_end");

    await new Promise((resolve) => setTimeout(resolve, 150));
    const frames = await readLines(frameLog);
    assert.ok(!frames.includes("abort_request"), `unexpected abort_request after clean completion: ${JSON.stringify(frames)}`);
  } finally {
    await client.close();
  }
});

test("aborting provider.stream cancels the runtime stream exactly once", async () => {
  const frameLog = await tempFile("makai-frames-abort-");
  const client = await createMakaiClient({
    command: process.execPath,
    args: [streamCancelObserverServer],
    env: { ...process.env, MAKAI_TEST_FRAME_LOG: frameLog },
    handshakeTimeoutMs: 3000,
    responseTimeoutMs: 5000,
  });

  try {
    const controller = new AbortController();
    await assert.rejects(async () => {
      let received = 0;
      for await (const event of client.provider.stream({ ...providerRequest, options: { signal: controller.signal } })) {
        if (event.type === "text_delta") received += 1;
        if (received >= 2) controller.abort();
      }
    }, (error: unknown) => error instanceof Error && error.name === "AbortError");

    const frames = await waitForLine(frameLog, (lines) => lines.includes("abort_request"));
    assert.equal(frames.filter((frame) => frame === "abort_request").length, 1, `frames: ${JSON.stringify(frames)}`);
  } finally {
    await client.close();
  }
});

test("provider and agent calls on a closed transport reject with MakaiStreamError", async () => {
  const client = await createMakaiClient({
    command: process.execPath,
    args: [streamCancelObserverServer],
    handshakeTimeoutMs: 3000,
    responseTimeoutMs: 1000,
  });
  await client.close();

  const isTransportStreamError = (error: unknown): boolean =>
    error instanceof MakaiStreamError && error.kind === "transport_error";

  await assert.rejects(() => client.provider.complete(providerRequest), isTransportStreamError);
  await assert.rejects(async () => {
    for await (const _event of client.provider.stream(providerRequest)) break;
  }, isTransportStreamError);
  await assert.rejects(() => client.agent.run(providerRequest), isTransportStreamError);
  await assert.rejects(async () => {
    for await (const _event of client.agent.stream(providerRequest)) break;
  }, isTransportStreamError);
});

test("aborting a provider call rejects with a plain AbortError, not MakaiStreamError", async () => {
  const client = await createMakaiClient({
    command: process.execPath,
    args: [streamCancelObserverServer],
    handshakeTimeoutMs: 3000,
    responseTimeoutMs: 5000,
  });

  try {
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(
      () => client.provider.complete({ ...providerRequest, options: { signal: controller.signal } }),
      (error: unknown) =>
        error instanceof Error &&
        error.name === "AbortError" &&
        !(error instanceof MakaiStreamError),
    );
  } finally {
    await client.close();
  }
});

test("models.list on a closed transport rejects with a plain Error, not MakaiProtocolError", async () => {
  const client = await createMakaiClient({
    command: process.execPath,
    args: [streamCancelObserverServer],
    handshakeTimeoutMs: 3000,
    responseTimeoutMs: 1000,
  });
  await client.close();

  await assert.rejects(
    () => client.models.list(),
    (error: unknown) =>
      error instanceof Error &&
      !(error instanceof MakaiProtocolError) &&
      error.message === "client is not connected",
  );
});

test("responseTimeoutMs does not govern the auth namespace", async () => {
  const client = await createMakaiClient({
    command: process.execPath,
    args: [streamCancelObserverServer],
    handshakeTimeoutMs: 3000,
    responseTimeoutMs: 120,
  });

  try {
    const settled = { done: false };
    const pending = client.auth
      .listProviders()
      .then(() => {
        settled.done = true;
      })
      .catch((error: unknown) => {
        settled.done = true;
        assert.ok(error instanceof MakaiAuthError);
      });

    await new Promise((resolve) => setTimeout(resolve, 600));
    assert.equal(settled.done, false, "auth.listProviders honoured responseTimeoutMs; update the README if this changed");
    void pending;
  } finally {
    await client.close();
  }
});
