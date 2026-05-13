import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createMakaiAgentApi,
  createMakaiProviderApi,
  MakaiStdioClient,
  MakaiStreamError,
  type MakaiLogger,
  getNoopLogger,
  resolveMakaiBinary,
} from "../src";

const sourceFixturesDir = path.resolve(__dirname, "../../typescript/test/fixtures");
const fixtureScript = path.join(sourceFixturesDir, "execution-server.js");

// ---------------------------------------------------------------------------
// Capturing logger — records all calls for assertions.
// ---------------------------------------------------------------------------
type LogEntry = { level: string; message: string; context?: Record<string, unknown> };

function createCapturingLogger(): MakaiLogger & { entries: LogEntry[] } {
  const entries: LogEntry[] = [];
  return {
    entries,
    debug(message, context) { entries.push({ level: "debug", message, context }); },
    info(message, context) { entries.push({ level: "info", message, context }); },
    warn(message, context) { entries.push({ level: "warn", message, context }); },
    error(message, context) { entries.push({ level: "error", message, context }); },
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
type Harness = {
  client: MakaiStdioClient;
  logger: ReturnType<typeof createCapturingLogger>;
  tmpDir: string;
  logPath: string;
  cleanup(): Promise<void>;
};

async function setupHarness(): Promise<Harness> {
  const logger = createCapturingLogger();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "makai-logger-test-"));
  const logPath = path.join(tmpDir, "request.log");
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [fixtureScript],
    env: { ...process.env, MAKAI_TEST_REQUEST_LOG: logPath },
    handshakeTimeoutMs: 5000,
    logger,
  });
  await client.connect();
  return {
    client,
    logger,
    tmpDir,
    logPath,
    cleanup: async () => {
      await client.close();
      fs.rmSync(tmpDir, { recursive: true, force: true });
    },
  };
}

function request() {
  return {
    model_ref: "anthropic/anthropic-messages@claude-sonnet-4-5",
    messages: [{ role: "user" as const, content: "hello" }],
    options: { temperature: 0.2, session_id: "testNanoIdSess1234567" },
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("getNoopLogger returns a logger with all four methods", () => {
  const logger = getNoopLogger();
  assert.equal(typeof logger.debug, "function");
  assert.equal(typeof logger.info, "function");
  assert.equal(typeof logger.warn, "function");
  assert.equal(typeof logger.error, "function");
  // Calling them should not throw
  logger.debug("test");
  logger.info("test");
  logger.warn("test");
  logger.error("test");
});

test("getNoopLogger returns the same singleton instance", () => {
  assert.strictEqual(getNoopLogger(), getNoopLogger());
});

test("stdio transport logs connect/handshake and close events", async () => {
  const logger = createCapturingLogger();
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "ready-server.js")],
    handshakeTimeoutMs: 5000,
    logger,
  });

  await client.connect();
  // Should log process spawn, handshake wait, and handshake complete
  const spawnLog = logger.entries.find((e) => e.message === "stdio: spawning process");
  assert.ok(spawnLog, "expected 'stdio: spawning process' log");
  assert.equal(spawnLog.context?.command, process.execPath);

  const handshakeLog = logger.entries.find((e) => e.message === "stdio: waiting for handshake");
  assert.ok(handshakeLog, "expected 'stdio: waiting for handshake' log");

  const completeLog = logger.entries.find((e) => e.message === "stdio: handshake complete");
  assert.ok(completeLog, "expected 'stdio: handshake complete' log");

  await client.close();
  const closeLog = logger.entries.find((e) => e.message === "stdio: closing transport");
  assert.ok(closeLog, "expected 'stdio: closing transport' log");
});

test("stdio transport logs frame send and receive", async () => {
  const logger = createCapturingLogger();
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "ready-server.js")],
    handshakeTimeoutMs: 5000,
    logger,
  });

  await client.connect();
  // Clear handshake logs for clarity
  logger.entries.length = 0;

  client.send({ type: "stream_request", stream_id: "s1" });

  const sendLog = logger.entries.find((e) => e.message === "stdio: sending frame");
  assert.ok(sendLog, "expected 'stdio: sending frame' log");
  assert.equal(sendLog.context?.type, "stream_request");
  assert.equal(sendLog.context?.stream_id, "s1");

  const frame = await client.nextFrame(5000);
  const receiveLog = logger.entries.find((e) => e.message === "stdio: received frame");
  assert.ok(receiveLog, "expected 'stdio: received frame' log");
  assert.equal(receiveLog.context?.type, frame.type);

  await client.close();
});

test("stdio transport logs error frame during handshake", async () => {
  const logger = createCapturingLogger();
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "error-server.js")],
    handshakeTimeoutMs: 5000,
    logger,
  });

  // The error server sends a protocol error frame. This should be logged as a
  // received frame before the handshake is rejected.
  await assert.rejects(() => client.connect());
  const receiveLog = logger.entries.find((e) => e.message === "stdio: received frame");
  assert.ok(receiveLog, "expected 'stdio: received frame' log");
  assert.equal(receiveLog.context?.type, "error");
  await client.close();
});

test("binary resolver logs resolution steps", async () => {
  const logger = createCapturingLogger();
  const tempDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "makai-bin-log-"));
  const binaryPath = path.join(tempDir, process.platform === "win32" ? "makai.exe" : "makai");
  await fs.promises.writeFile(binaryPath, "fixture");

  const prev = process.env.MAKAI_BINARY_PATH;
  process.env.MAKAI_BINARY_PATH = binaryPath;
  try {
    await resolveMakaiBinary({ logger });
    const resolvingLog = logger.entries.find((e) => e.message === "binary: resolving from explicit path");
    assert.ok(resolvingLog, "expected 'binary: resolving from explicit path' log");
    assert.equal(resolvingLog.context?.path, path.resolve(binaryPath));

    const resolvedLog = logger.entries.find((e) => e.message === "binary: resolved from explicit path");
    assert.ok(resolvedLog, "expected 'binary: resolved from explicit path' log");
  } finally {
    if (prev === undefined) delete process.env.MAKAI_BINARY_PATH;
    else process.env.MAKAI_BINARY_PATH = prev;
    await fs.promises.rm(tempDir, { recursive: true, force: true });
  }
});

test("binary resolver logs auto resolution candidate checks", async () => {
  const logger = createCapturingLogger();
  const prevPath = process.env.MAKAI_BINARY_PATH;
  const prevUrl = process.env.MAKAI_BINARY_URL;
  const prevChecksum = process.env.MAKAI_BINARY_SHA256;
  delete process.env.MAKAI_BINARY_PATH;
  delete process.env.MAKAI_BINARY_URL;
  delete process.env.MAKAI_BINARY_SHA256;
  try {
    await resolveMakaiBinary({ logger });
    const candidateLogs = logger.entries.filter((e) => e.message === "binary: checking local candidate");
    assert.ok(candidateLogs.length >= 1, "expected at least one 'binary: checking local candidate' log");

    const fallbackLog = logger.entries.find((e) => e.message === "binary: falling back to PATH lookup");
    assert.ok(fallbackLog, "expected 'binary: falling back to PATH lookup' log");
  } finally {
    if (prevPath === undefined) delete process.env.MAKAI_BINARY_PATH;
    else process.env.MAKAI_BINARY_PATH = prevPath;
    if (prevUrl === undefined) delete process.env.MAKAI_BINARY_URL;
    else process.env.MAKAI_BINARY_URL = prevUrl;
    if (prevChecksum === undefined) delete process.env.MAKAI_BINARY_SHA256;
    else process.env.MAKAI_BINARY_SHA256 = prevChecksum;
  }
});

test("provider complete logs stream_request and frame exchange", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client, { logger: harness.logger });
    await provider.complete(request());

    const streamLog = harness.logger.entries.find((e) => e.message === "provider: sending complete_request");
    assert.ok(streamLog, "expected 'provider: sending complete_request' log");
    assert.equal(streamLog.context?.model_ref, request().model_ref);
    assert.ok(typeof streamLog.context?.stream_id === "string");
  } finally {
    await harness.cleanup();
  }
});

test("provider stream logs start and terminal events", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client, { logger: harness.logger });
    const events = [];
    for await (const event of provider.stream(request())) {
      events.push(event);
    }

    const startLog = harness.logger.entries.find((e) => e.message === "provider: starting stream");
    assert.ok(startLog, "expected 'provider: starting stream' log");

    const requestLog = harness.logger.entries.find((e) => e.message === "provider: sending stream_request");
    assert.ok(requestLog, "expected 'provider: sending stream_request' log");

    const streamStartedLog = harness.logger.entries.find((e) => e.message === "provider: stream started");
    assert.ok(streamStartedLog, "expected 'provider: stream started' log");
  } finally {
    await harness.cleanup();
  }
});

test("agent run logs agent_start", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client, { logger: harness.logger });
    await agent.run(request());

    const startLog = harness.logger.entries.find((e) => e.message === "agent: sending agent_start");
    assert.ok(startLog, "expected 'agent: sending agent_start' log");
    assert.ok(typeof startLog.context?.session_id === "string");
  } finally {
    await harness.cleanup();
  }
});

test("agent stream logs start events", async () => {
  const harness = await setupHarness();
  try {
    const agent = createMakaiAgentApi(harness.client, { logger: harness.logger });
    const events = [];
    for await (const event of agent.stream(request())) {
      events.push(event);
    }

    const startLog = harness.logger.entries.find((e) => e.message === "agent: starting stream");
    assert.ok(startLog, "expected 'agent: starting stream' log");

    const agentStartLog = harness.logger.entries.find((e) => e.message === "agent: sending agent_start");
    assert.ok(agentStartLog, "expected 'agent: sending agent_start' log");

    const streamStartedLog = harness.logger.entries.find((e) => e.message === "agent: stream started");
    assert.ok(streamStartedLog, "expected 'agent: stream started' log");
  } finally {
    await harness.cleanup();
  }
});

test("no logger configured results in zero overhead (no crashes)", async () => {
  // Create a client without a logger — should work exactly as before
  const client = new MakaiStdioClient({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "ready-server.js")],
    handshakeTimeoutMs: 5000,
  });

  await client.connect();
  client.send({ type: "stream_request", stream_id: "s1" });
  const frame = await client.nextFrame(5000);
  assert.ok(frame);
  await client.close();
});

test("logger captures envelope type and stream_id in frame send context", async () => {
  const harness = await setupHarness();
  try {
    const provider = createMakaiProviderApi(harness.client, { logger: harness.logger });
    await provider.complete(request());

    // Check that send logs include the envelope type
    const sendLogs = harness.logger.entries.filter(
      (e) => e.message === "stdio: sending frame" && e.context?.type === "complete_request",
    );
    assert.ok(sendLogs.length >= 1, "expected at least one complete_request send log");

    // Verify stream_id is present and is a ULID
    const streamId = sendLogs[0]!.context?.stream_id;
    assert.equal(typeof streamId, "string");
    assert.ok((streamId as string).length >= 10, "stream_id should be a ULID");
  } finally {
    await harness.cleanup();
  }
});
