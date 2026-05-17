/**
 * Assembles npm packages from compiled binaries.
 * Takes binaries from dist/bin/ and creates publishable packages in dist/npm/.
 *
 * Usage: node scripts/package-npm.ts [--version 0.1.0]
 */

import { mkdirSync, copyFileSync, writeFileSync, chmodSync, readFileSync } from "node:fs";
import { join } from "node:path";

const ROOT = process.cwd();
const BIN_DIR = join(ROOT, "dist", "bin");
const NPM_DIR = join(ROOT, "dist", "npm");

const versionIdx = process.argv.indexOf("--version");
const VERSION =
  versionIdx !== -1
    ? process.argv[versionIdx + 1]
    : JSON.parse(readFileSync(join(ROOT, "package.json"), "utf-8")).version;

const PLATFORMS = [
  { target: "darwin-arm64", os: "darwin", cpu: "arm64", binary: "makai-darwin-arm64" },
  { target: "darwin-x64", os: "darwin", cpu: "x64", binary: "makai-darwin-x64" },
  { target: "linux-arm64", os: "linux", cpu: "arm64", binary: "makai-linux-arm64" },
  { target: "linux-x64", os: "linux", cpu: "x64", binary: "makai-linux-x64" },
  { target: "win32-x64", os: "win32", cpu: "x64", binary: "makai.exe" },
];

console.log(`Packaging npm packages (version ${VERSION})...\n`);

for (const { target, os, cpu, binary } of PLATFORMS) {
  const pkgName = `@makai/cli-${target}`;
  const pkgDir = join(NPM_DIR, `cli-${target}`);
  const binDir = join(pkgDir, "bin");

  mkdirSync(binDir, { recursive: true });

  const srcBinary = join(BIN_DIR, binary);
  const destBinary = join(binDir, os === "win32" ? "makai.exe" : "makai");

  try {
    copyFileSync(srcBinary, destBinary);
    if (os !== "win32") {
      chmodSync(destBinary, 0o755);
    }
  } catch {
    console.warn(`  Warning: Binary not found: ${srcBinary} (skipping ${pkgName})`);
    continue;
  }

  writeFileSync(
    join(pkgDir, "package.json"),
    JSON.stringify(
      {
        name: pkgName,
        version: VERSION,
        description: `Makai binary for ${os} ${cpu}`,
        os: [os],
        cpu: [cpu],
        bin: { makai: os === "win32" ? "bin/makai.exe" : "bin/makai" },
        files: ["bin/"],
        license: "ISC",
        repository: {
          type: "git",
          url: "https://github.com/lsm/makai",
        },
      },
      null,
      2
    )
  );

  console.log(`  Created ${pkgName}`);
}

// Create main makai package
const mainDir = join(NPM_DIR, "makai");
mkdirSync(mainDir, { recursive: true });

// Copy launcher script
copyFileSync(join(ROOT, "bin", "makai.js"), join(mainDir, "makai.js"));
chmodSync(join(mainDir, "makai.js"), 0o755);

// Copy SDK files
const srcDir = join(ROOT, "dist", "src");
const destSrcDir = join(mainDir, "dist", "src");
mkdirSync(destSrcDir, { recursive: true });

// Read existing package.json and update for packaging
const mainPkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf-8"));
mainPkg.bin = { makai: "makai.js" };
mainPkg.files = ["dist/src/", "makai.js", "README.md"];

writeFileSync(
  join(mainDir, "package.json"),
  JSON.stringify(mainPkg, null, 2)
);

// Copy dist/src contents
function copyDir(src: string, dest: string) {
  mkdirSync(dest, { recursive: true });
  for (const entry of require("fs").readdirSync(src, { withFileTypes: true })) {
    const srcPath = join(src, entry.name);
    const destPath = join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      copyFileSync(srcPath, destPath);
    }
  }
}
copyDir(srcDir, destSrcDir);

// Copy README
copyFileSync(join(ROOT, "README.md"), join(mainDir, "README.md"));

console.log(`  Created makai (main package)`);

console.log(`\nAll packages created in ${NPM_DIR}`);
console.log(`\nTo publish, run:`);
for (const { target } of PLATFORMS) {
  console.log(`  cd dist/npm/cli-${target} && npm publish --access public`);
}
console.log(`  cd dist/npm/makai && npm publish --access public`);
