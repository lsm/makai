#!/usr/bin/env node
/**
 * Verifies the `makai` npm tarball ships usable TypeScript declarations (#184).
 *
 * Rebuilds the SDK from a clean `dist/` (see the `check:declarations` npm
 * script), then:
 *
 *   1. `npm pack --dry-run` must list `*.d.ts` files under `dist/src`,
 *      including the `dist/src/index.d.ts` entrypoint declaration.
 *   2. A fresh-install consumer project that installs the packed tarball must
 *      type-check cleanly under strict TS with `skipLibCheck` disabled, and
 *      must be able to `require("makai")` at runtime.
 *
 * Exits non-zero on the first failed expectation.
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const IS_WINDOWS = process.platform === "win32";

function fail(message) {
  console.error(`check-npm-declarations: FAIL: ${message}`);
  process.exit(1);
}

function run(command, args, options = {}) {
  return execFileSync(command, args, { cwd: ROOT, encoding: "utf8", ...options });
}

// npm is a `.cmd` launcher on Windows, which execFile cannot spawn without a
// shell (https://nodejs.org/api/child_process.html#spawning-bat-and-cmd-files-on-windows).
// The shell parses the command line, so args containing spaces must be quoted.
function npmRun(args, options = {}) {
  if (!IS_WINDOWS) {
    return run("npm", args, options);
  }
  const quoted = args.map((arg) => (/\s/.test(arg) ? `"${arg}"` : arg));
  return execFileSync("npm", quoted, { cwd: ROOT, encoding: "utf8", shell: true, ...options });
}

// Build from a clean output directory: a stale `dist/` left by an earlier
// build (e.g. from before declaration emission was enabled) would otherwise
// satisfy the checks below and let declarations that no longer match the
// source ship silently — the exact failure mode reported in #184.
console.log("rebuilding SDK into clean dist/...");
rmSync(join(ROOT, "dist"), { recursive: true, force: true });
run(process.execPath, [join("node_modules", "typescript", "bin", "tsc"), "-p", "tsconfig.json"], {
  stdio: "inherit",
});

// ---------------------------------------------------------------------------
// 1. The tarball must contain declaration files under dist/src.
// ---------------------------------------------------------------------------

const packListing = JSON.parse(npmRun(["pack", "--dry-run", "--json"]));
const tarballFiles = packListing.flatMap((entry) => entry.files.map((file) => file.path));

const declarationFiles = tarballFiles.filter((file) => /^dist\/src\/.*\.d\.ts$/.test(file));
if (declarationFiles.length === 0) {
  fail(
    "npm pack ships no *.d.ts under dist/src — the SDK build must emit " +
      "declarations (tsconfig.json \"declaration\": true) before packaging"
  );
}
for (const required of ["dist/src/index.d.ts", "dist/src/index.js"]) {
  if (!tarballFiles.includes(required)) {
    fail(`npm pack output is missing required entrypoint file ${required}`);
  }
}

// Every shipped module must carry a matching declaration, so a partial
// emission gap cannot hide behind the entrypoint check above.
const jsFiles = tarballFiles.filter((file) => /^dist\/src\/.*\.js$/.test(file));
const jsWithoutDeclarations = jsFiles.filter(
  (file) => !tarballFiles.includes(file.replace(/\.js$/, ".d.ts"))
);
if (jsWithoutDeclarations.length > 0) {
  fail(`shipped JS files without matching .d.ts: ${jsWithoutDeclarations.join(", ")}`);
}
console.log(`tarball ships ${declarationFiles.length} declaration files under dist/src`);

// ---------------------------------------------------------------------------
// 2. A fresh-install consumer must type-check under strict TS and load at runtime.
// ---------------------------------------------------------------------------

const rootPackage = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
const workDir = mkdtempSync(join(tmpdir(), "makai-declaration-check-"));

try {
  const packResult = JSON.parse(
    npmRun(["pack", "--json", "--pack-destination", workDir])
  );
  const tarballPath = join(workDir, packResult[0].filename);

  writeFileSync(
    join(workDir, "package.json"),
    JSON.stringify({ name: "makai-declaration-smoke", version: "0.0.0", private: true }, null, 2)
  );

  console.log("installing packed tarball into fresh consumer project...");
  npmRun([
    "install",
    tarballPath,
    `typescript@${rootPackage.devDependencies.typescript}`,
    `@types/node@${rootPackage.devDependencies["@types/node"]}`,
  ], { cwd: workDir, stdio: "inherit" });

  // Strict TS with skipLibCheck disabled so the shipped .d.ts files themselves
  // are type-checked, not just the consumer code. The @ts-expect-error line
  // fails the build if `makai` ever resolves to `any` instead of real types.
  writeFileSync(
    join(workDir, "tsconfig.json"),
    JSON.stringify(
      {
        compilerOptions: {
          target: "ES2022",
          module: "Node16",
          moduleResolution: "Node16",
          strict: true,
          noEmit: true,
          skipLibCheck: false,
          esModuleInterop: true,
          types: ["node"],
        },
        include: ["consumer.ts"],
      },
      null,
      2
    )
  );

  writeFileSync(
    join(workDir, "consumer.ts"),
    `import {
  createMakaiClient,
  createMakaiStdioClient,
  createMakaiModelsApi,
  resolveMakaiBinary,
  isAbortError,
  getNoopLogger,
  MakaiProtocolError,
  type ChatMessage,
  type UsageSummary,
  type ProviderStreamEvent,
  type MakaiClient,
  type StdioFrame,
} from "makai";

const messages: ChatMessage[] = [{ role: "user", content: "hello" }];
const usage: UsageSummary = { input: 1, output: 2 };
const frame: StdioFrame = { type: "ping" };

function describeEvent(event: ProviderStreamEvent): string {
  return event.type;
}
describeEvent({ type: "error", message: "boom" });

const protocolError: MakaiProtocolError = new MakaiProtocolError("bad frame");
if (!(protocolError instanceof Error)) {
  throw new Error("MakaiProtocolError is not an Error");
}

async function main(): Promise<void> {
  const client: MakaiClient = await createMakaiClient({ logger: getNoopLogger() });
  const transport = await createMakaiStdioClient();
  const models = createMakaiModelsApi(transport, { logger: getNoopLogger() });
  void client;
  void models;
  void frame;
  void (await resolveMakaiBinary());

  const abortErr = new Error("cancelled");
  abortErr.name = "AbortError";
  if (typeof isAbortError(abortErr) !== "boolean") {
    throw new Error("isAbortError did not return boolean");
  }
}
void main;
void messages;
void usage;

// @ts-expect-error malformed messages must be rejected, proving the exports
// have real types rather than resolving to any
const _bad: ChatMessage = { role: "invalid-role", content: 42 };

export {};
`
  );

  console.log("type-checking consumer under strict TS (skipLibCheck disabled)...");
  run(process.execPath, [join("node_modules", "typescript", "bin", "tsc"), "-p", "."], {
    cwd: workDir,
    stdio: "inherit",
  });

  console.log("requiring installed package at runtime...");
  run(
    process.execPath,
    ["-e", "const makai = require('makai'); if (typeof makai.createMakaiClient !== 'function') { throw new Error('createMakaiClient is not a function'); }"],
    { cwd: workDir, stdio: "inherit" }
  );
} finally {
  rmSync(workDir, { recursive: true, force: true });
}

console.log("check-npm-declarations: OK");
