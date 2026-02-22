import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { resolveMakaiBinary } from "../src";

const ENV_BINARY_PATH = "MAKAI_BINARY_PATH";
const ENV_BINARY_URL = "MAKAI_BINARY_URL";
const ENV_BINARY_SHA256 = "MAKAI_BINARY_SHA256";

test("resolveMakaiBinary prefers MAKAI_BINARY_PATH override", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "makai-bin-path-"));
  const binaryPath = path.join(tempDir, process.platform === "win32" ? "makai.exe" : "makai");
  await fs.writeFile(binaryPath, "fixture");

  const prev = process.env[ENV_BINARY_PATH];
  process.env[ENV_BINARY_PATH] = binaryPath;
  try {
    const resolved = await resolveMakaiBinary();
    assert.equal(resolved, binaryPath);
  } finally {
    if (prev === undefined) delete process.env[ENV_BINARY_PATH];
    else process.env[ENV_BINARY_PATH] = prev;
    await fs.rm(tempDir, { recursive: true, force: true });
  }
});

test("resolveMakaiBinary downloads URL override to cache with checksum", async () => {
  const payload = Buffer.from("makai-binary-content");
  const checksum = createHash("sha256").update(payload).digest("hex");
  const cacheDir = await fs.mkdtemp(path.join(os.tmpdir(), "makai-cache-"));

  const server = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "application/octet-stream" });
    res.end(payload);
  });
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const address = server.address();
  if (!address || typeof address === "string") {
    server.close();
    throw new Error("test server did not expose a TCP address");
  }

  const prevUrl = process.env[ENV_BINARY_URL];
  const prevChecksum = process.env[ENV_BINARY_SHA256];
  const prevPath = process.env[ENV_BINARY_PATH];
  process.env[ENV_BINARY_URL] = `http://127.0.0.1:${address.port}/makai-test.bin`;
  process.env[ENV_BINARY_SHA256] = checksum;
  delete process.env[ENV_BINARY_PATH];
  try {
    const resolved = await resolveMakaiBinary({ cacheDir });
    const downloaded = await fs.readFile(resolved);
    assert.equal(downloaded.toString("utf8"), payload.toString("utf8"));
  } finally {
    if (prevUrl === undefined) delete process.env[ENV_BINARY_URL];
    else process.env[ENV_BINARY_URL] = prevUrl;
    if (prevChecksum === undefined) delete process.env[ENV_BINARY_SHA256];
    else process.env[ENV_BINARY_SHA256] = prevChecksum;
    if (prevPath === undefined) delete process.env[ENV_BINARY_PATH];
    else process.env[ENV_BINARY_PATH] = prevPath;
    await fs.rm(cacheDir, { recursive: true, force: true });
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
