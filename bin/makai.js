#!/usr/bin/env node

/**
 * Makai CLI launcher.
 * Detects the current platform and spawns the correct compiled binary
 * from the matching @makai/cli-{platform} optional dependency.
 */

const { spawnSync } = require("child_process");

const PLATFORM_MAP = {
  "darwin-arm64": "@makai/cli-darwin-arm64",
  "darwin-x64": "@makai/cli-darwin-x64",
  "linux-arm64": "@makai/cli-linux-arm64",
  "linux-x64": "@makai/cli-linux-x64",
  "win32-x64": "@makai/cli-win32-x64",
};

const platformKey = `${process.platform}-${process.arch}`;
const packageName = PLATFORM_MAP[platformKey];

if (!packageName) {
  console.error(
    `Error: Makai does not support ${process.platform} ${process.arch}.\n` +
      `Supported platforms: ${Object.keys(PLATFORM_MAP).join(", ")}`
  );
  process.exit(1);
}

let binaryPath;
try {
  const binaryName = process.platform === "win32" ? "makai.exe" : "makai";
  binaryPath = require.resolve(`${packageName}/bin/${binaryName}`);
} catch {
  console.error(
    `Error: Could not find Makai binary for ${platformKey}.\n` +
      `The package ${packageName} may not be installed.\n` +
      `Try reinstalling: npm install -g makai`
  );
  process.exit(1);
}

const result = spawnSync(binaryPath, process.argv.slice(2), {
  stdio: "inherit",
  env: process.env,
});

if (result.error) {
  console.error(`Error: Failed to execute Makai binary: ${result.error.message}`);
  process.exit(1);
}

process.exit(result.status ?? 1);
