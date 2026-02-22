import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { listMakaiAuthProviders, loginWithMakaiAuth, MakaiAuthError, type MakaiAuthEvent } from "../src";

const sourceFixturesDir = path.resolve(__dirname, "../../typescript/test/fixtures");

test("loginWithMakaiAuth handles prompt and success", async () => {
  const seenEvents: MakaiAuthEvent[] = [];
  await loginWithMakaiAuth({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "auth-login-server.js")],
    onEvent: (event) => seenEvents.push(event),
    onPrompt: async () => "letmein",
  });

  assert.equal(seenEvents.some((event) => event.type === "auth_url"), true);
  assert.equal(seenEvents.some((event) => event.type === "success"), true);
});

test("loginWithMakaiAuth rejects on auth error event", async () => {
  await assert.rejects(
    () =>
      loginWithMakaiAuth({
        command: process.execPath,
        args: [path.join(sourceFixturesDir, "auth-error-server.js")],
      }),
    (error: unknown) =>
      error instanceof MakaiAuthError &&
      error.code === "auth_failed" &&
      error.message.includes("fixture auth failed"),
  );
});

test("loginWithMakaiAuth rejects when prompt handler missing", async () => {
  await assert.rejects(
    () =>
      loginWithMakaiAuth({
        command: process.execPath,
        args: [path.join(sourceFixturesDir, "auth-login-server.js")],
      }),
    /prompt requested but no onPrompt handler/,
  );
});

test("listMakaiAuthProviders parses providers payload", async () => {
  const providers = await listMakaiAuthProviders({
    command: process.execPath,
    args: [path.join(sourceFixturesDir, "auth-providers-server.js")],
  });
  assert.equal(providers.length, 2);
  assert.equal(providers[0]?.id, "anthropic");
  assert.equal(providers[1]?.id, "github-copilot");
});
