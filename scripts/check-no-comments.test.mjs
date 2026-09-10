// Self-tests for check-no-comments.mjs (#228): Zig lexer literal fixtures,
// exemption patterns for both languages, the ported TypeScript scanner's
// regex/template regression corpus, and ratchet behavior. Run with
// `node --test scripts/check-no-comments.test.mjs`.

import { execSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";

import { checkFiles, findComments, loadAllowlist, stripComments } from "./check-no-comments.mjs";

const SCRIPT = fileURLToPath(new URL("check-no-comments.mjs", import.meta.url));

const zigCount = (src) => findComments(src, "x.zig").length;
const tsCount = (src) => findComments(src, "x.ts").length;

test("zig: // inside a string literal is not a comment", () => {
  const src = 'const u = "http://x";\nconst y = 1;\n';
  assert.equal(zigCount(src), 0);
  assert.equal(stripComments(src, "x.zig"), src);
});

test("zig: escaped quote inside a string does not hide a trailing comment", () => {
  const src = 'const s = "a\\""; // gone\nconst y = 1;\n';
  const out = stripComments(src, "x.zig");
  assert.equal(zigCount(src), 1);
  assert.ok(out.includes('const s = "a\\"";'));
  assert.ok(!out.includes("// gone"));
  assert.ok(out.includes("const y = 1;"));
});

test("zig: // inside a multiline string literal is not a comment", () => {
  const src = String.raw`const s =
    \\ see http://example.com
    \\ and \"quotes\"
    ;
// gone
const y = 1;
`;
  assert.equal(zigCount(src), 1);
  const out = stripComments(src, "x.zig");
  assert.ok(out.includes(String.raw`\\ see http://example.com`));
  assert.ok(!out.includes("// gone"));
  assert.ok(out.includes("const y = 1;"));
});

test("zig: multiline string continues across indented continuation lines", () => {
  const src = String.raw`const s =
\\one
    \\two // not a comment
        \\three
;
// gone
`;
  assert.equal(zigCount(src), 1);
  assert.ok(stripComments(src, "x.zig").includes("// not a comment"));
});

test("zig: a non-continuation line ends the multiline string", () => {
  const src = String.raw`const s =
\\one
// gone
;
`;
  assert.equal(zigCount(src), 1);
  assert.ok(!stripComments(src, "x.zig").includes("// gone"));
});

test("zig: // inside char literals is not a comment", () => {
  const src = "const a = '/';\nconst b = '\\n';\nconst c = '\\u{1F}';\nconst d = '\\'';\nconst e = '\"';\n// gone\nconst y = 1;\n";
  assert.equal(zigCount(src), 1);
  const out = stripComments(src, "x.zig");
  assert.ok(out.includes("const e = '\"';"));
  assert.ok(out.includes("const y = 1;"));
});

test("zig: char literal followed by an inline comment on the same line", () => {
  const src = "const c = 'a'; // gone\n";
  const out = stripComments(src, "x.zig");
  assert.ok(out.includes("const c = 'a';"));
  assert.ok(!out.includes("// gone"));
});

test("zig: quotes and apostrophes inside comments do not leak literal state", () => {
  const src = '// it is "fine"\nconst x = 1;\nconst s = "keep";\n';
  assert.equal(zigCount(src), 1);
  const out = stripComments(src, "x.zig");
  assert.ok(out.includes("const x = 1;"));
  assert.ok(out.includes('const s = "keep";'));
});

test("zig: /// doc and //! module comments are comments", () => {
  const src = "//! module doc\n/// doc comment\nconst x = 1;\n";
  assert.equal(zigCount(src), 2);
  assert.equal(stripComments(src, "x.zig"), "const x = 1;\n");
});

test("zig: only exact `// zig fmt: off|on` directives are exempt", () => {
  const src = "// zig fmt: off\nconst x = [1, 2,]; // gone\n// zig fmt: on\n";
  assert.equal(zigCount(src), 1);
  const out = stripComments(src, "x.zig");
  assert.ok(out.startsWith("// zig fmt: off\n"));
  assert.ok(out.includes("// zig fmt: on"));
  assert.ok(!out.includes("// gone"));
  assert.ok(out.includes("const x = [1, 2,];"));

  const notExact = "// zig fmt: off (disabled here)\nconst y = 1;\n";
  assert.equal(zigCount(notExact), 1);
  const docForm = "/// zig fmt: off\nconst z = 1;\n";
  assert.equal(zigCount(docForm), 1);
});

test("ts: // inside a string literal is not a comment", () => {
  const src = 'const u = "http://x"; // gone\nconst y = 1;\n';
  const out = stripComments(src, "x.ts");
  assert.ok(out.includes('const u = "http://x";'));
  assert.ok(!out.includes("// gone"));
});

test("ts: regex literals containing // are not comments", () => {
  const src = "const r = /[//]/.test(url) // gone\nkeep(r)\n";
  const out = stripComments(src, "x.ts");
  assert.ok(out.includes("/[//]/.test(url)"));
  assert.ok(!out.includes("// gone"));
  assert.ok(out.includes("keep(r)"));
});

test("ts: export default regex with // in a character class", () => {
  const src = "export default /[//]/\nkeep()\n";
  assert.equal(stripComments(src, "x.ts"), src);
});

test("ts: division after identifiers, parens, braces, and increments", () => {
  assert.ok(!stripComments("const n = total / count // gone\n", "x.ts").includes("// gone"));
  assert.ok(!stripComments("const q = (a + b) / 2 // gone\n", "x.ts").includes("// gone"));
  assert.ok(!stripComments("const x = {a:1} / 2 // gone\n", "x.ts").includes("// gone"));
  assert.ok(!stripComments("const x = i++ / 2 // gone\n", "x.ts").includes("// gone"));
  assert.ok(stripComments("const x = i++ / 2 // gone\n", "x.ts").includes("i++ / 2"));
});

test("ts: unterminated regex is left intact, later comments still stripped", () => {
  const src = "const q = - /oops\n// gone\nkeep()\n";
  const out = stripComments(src, "x.ts");
  assert.ok(out.includes("- /oops"));
  assert.ok(!out.includes("// gone"));
  assert.ok(out.includes("keep()"));
});

test("ts: template text and template-literal types are preserved verbatim", () => {
  const src = "const t = `a${1}b // not a comment`\n";
  assert.equal(stripComments(src, "x.ts"), src);
  const type = "type T = `//${string}`\nconst keep = 1\n";
  assert.equal(stripComments(type, "x.ts"), type);
});

test("ts: comments inside template placeholders are stripped", () => {
  assert.equal(stripComments("const t = `a${ /*c*/ 1 }b`\n", "x.ts"), "const t = `a${ 1 }b`\n");
});

test("ts: comment trailing a block before a closing brace is stripped", () => {
  assert.equal(
    stripComments("function f(){\n  a()\n  // trailing\n}\n", "x.ts"),
    "function f(){\n  a()\n}\n",
  );
});

test("ts: removing a block comment between tokens keeps them separated", () => {
  assert.equal(stripComments("return/* note */value\n", "x.ts"), "return value\n");
  assert.equal(stripComments("const/*c*/x = 1\n", "x.ts"), "const x = 1\n");
  assert.equal(stripComments("a+/*c*/+b\n", "x.ts"), "a+ +b\n");
  assert.equal(stripComments("let x/*c*/=1\n", "x.ts"), "let x =1\n");
  assert.equal(stripComments("const a = 1 /* c */ + 2\n", "x.ts"), "const a = 1 + 2\n");
});

test("ts: a block comment spanning lines preserves a line terminator (ASI)", () => {
  // A MultiLineComment containing a line terminator counts as one for
  // automatic semicolon insertion, so the newline must survive stripping.
  assert.equal(stripComments("return/* multi\nline */value\n", "x.ts"), "return\nvalue\n");
  assert.equal(stripComments("return /*\n*/value\n", "x.ts"), "return\nvalue\n");
  assert.equal(stripComments("foo(/*\n*/x)\n", "x.ts"), "foo(\nx)\n");
});

test("ts: unclosed block comment refuses to lex", () => {
  assert.throws(() => stripComments("const a = 1 /* oops\nkeep()\n", "x.ts"), /never closed/);
});

test("ts: functional directives are exempt, lookalikes are not", () => {
  const kept = [
    "#!/usr/bin/env node\nconst a = 1\n",
    '/// <reference types="node" />\nconst a = 1\n',
    "// @ts-expect-error malformed input\nconst a = 1\n",
    "/* @ts-ignore */\nconst a = 1\n",
    "// biome-ignore lint/suspicious/noExplicitAny: fixture\nconst a = 1\n",
    "// eslint-disable-next-line no-console\nconst a = 1\n",
    "// oxlint-disable-next-line\nconst a = 1\n",
    "// @public\nconst a = 1\n",
    "// knip-ignore\nconst a = 1\n",
    "/* v8 ignore next */\nconst a = 1\n",
    "// istanbul ignore next\nconst a = 1\n",
    "// c8 ignore next\nconst a = 1\n",
  ];
  for (const src of kept) {
    assert.equal(tsCount(src), 0, `expected exempt: ${src.split("\n")[0]}`);
    assert.equal(stripComments(src, "x.ts"), src);
  }
  assert.equal(tsCount("// ts is a language\nconst a = 1\n"), 1);
  assert.equal(tsCount("// @ts-team notes\nconst a = 1\n"), 1);
  assert.equal(tsCount("// eslint is used by downstream consumers\nconst a = 1\n"), 1);
  assert.equal(tsCount("/* eslint enables linting */\nconst a = 1\n"), 1);
  assert.equal(tsCount("// do not add @ts-ignore here\nconst a = 1\n"), 1);
  assert.equal(tsCount("// consider biome-ignore later\nconst a = 1\n"), 1);
  assert.equal(tsCount("// coverage uses v8 ignore below\nconst a = 1\n"), 1);
  assert.equal(tsCount("// we removed knip-ignore usage\nconst a = 1\n"), 1);
});

let workDir;
test.beforeEach(() => {
  workDir = mkdtempSync(join(tmpdir(), "no-comments-"));
});
test.afterEach(() => {
  rmSync(workDir, { recursive: true, force: true });
});

function fixtures() {
  const dirtyZig = join(workDir, "dirty.zig");
  const cleanZig = join(workDir, "clean.zig");
  const dirtyTs = join(workDir, "dirty.ts");
  writeFileSync(dirtyZig, "// carve\nconst x = 1;\n");
  writeFileSync(cleanZig, 'const s = "http://x";\nconst y = 1;\n');
  writeFileSync(dirtyTs, "// sdk\nconst a = 1;\n");
  return { dirtyZig, cleanZig, dirtyTs };
}

test("ratchet: allowlisted dirty file passes, unallowlisted dirty file fails", () => {
  const { dirtyZig, cleanZig, dirtyTs } = fixtures();
  const allowlist = loadAllowlistFrom([dirtyZig]);
  const result = checkFiles([dirtyZig, cleanZig, dirtyTs], allowlist);
  assert.deepEqual(result.offending, [dirtyTs]);
  assert.deepEqual(result.ratcheted, [dirtyZig]);
  assert.deepEqual(result.stale, []);
});

test("ratchet: removing a dirty file's entry makes it fail", () => {
  const { dirtyZig } = fixtures();
  const result = checkFiles([dirtyZig], new Set());
  assert.deepEqual(result.offending, [dirtyZig]);
});

test("ratchet: allowlisted file that is clean or untracked is stale", () => {
  const { dirtyZig, cleanZig } = fixtures();
  const staleEntry = join(workDir, "deleted.zig");
  const result = checkFiles([dirtyZig, cleanZig], new Set([dirtyZig, cleanZig, staleEntry]));
  assert.deepEqual(result.offending, []);
  assert.deepEqual(result.stale.sort(), [cleanZig, staleEntry].sort());
});

function gitRepo(name) {
  const repo = join(workDir, name);
  mkdirSync(repo);
  execSync("git init -q", { cwd: repo });
  return repo;
}

function gitCommit(repo) {
  execSync("git -c user.name=test -c user.email=test@test add -A", { cwd: repo });
  execSync("git -c user.name=test -c user.email=test@test commit -qm ratchet", { cwd: repo });
}

test("ratchet: an allowlist new in this change seeds freely (base revision lacks it)", () => {
  const repo = gitRepo("seed-repo");
  writeFileSync(join(repo, "dirty.zig"), "// carve\nconst x = 1;\n");
  writeFileSync(join(repo, "dirty.ts"), "// sdk\nconst a = 1;\n");
  gitCommit(repo);
  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\ndirty.ts\n");
  gitCommit(repo);
  const run = spawnSync(
    process.execPath,
    [SCRIPT, "--check", "--allowlist", "allowlist.txt", "--files", "dirty.zig", "dirty.ts"],
    { cwd: repo },
  );
  assert.equal(run.status, 0, run.stdout);
  assert.ok(run.stdout.includes("(2 ratcheted)"));
});

test("ratchet: allowlist entries absent from the base revision are rejected additions", () => {
  const repo = gitRepo("additions-repo");
  writeFileSync(join(repo, "dirty.zig"), "// carve\nconst x = 1;\n");
  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\n");
  gitCommit(repo);
  writeFileSync(join(repo, "dirty.ts"), "// sdk\nconst a = 1;\n");
  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\ndirty.ts\n");
  gitCommit(repo);
  const run = spawnSync(
    process.execPath,
    [SCRIPT, "--check", "--allowlist", "allowlist.txt", "--files", "dirty.zig", "dirty.ts"],
    { cwd: repo },
  );
  assert.equal(run.status, 1, run.stdout);
  assert.ok(run.stdout.includes("allowlist addition not permitted"));
  assert.ok(run.stdout.includes("dirty.ts"));
  assert.ok(run.stdout.includes("added entries: 1"));
});

test("ratchet: --base catches additions hidden earlier in a multi-commit range", () => {
  const repo = gitRepo("range-repo");
  writeFileSync(join(repo, "dirty.zig"), "// carve\nconst x = 1;\n");
  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\n");
  gitCommit(repo);
  const rootSha = execSync("git rev-parse HEAD", { cwd: repo, encoding: "utf8" }).trim();
  writeFileSync(join(repo, "sneaky.ts"), "// mid-range\nconst a = 1;\n");
  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\nsneaky.ts\n");
  gitCommit(repo);
  writeFileSync(join(repo, "dirty.zig"), "// carve\nconst x = 2;\n");
  gitCommit(repo);
  const args = [
    SCRIPT,
    "--check",
    "--allowlist",
    "allowlist.txt",
    "--files",
    "dirty.zig",
    "sneaky.ts",
  ];
  const viaParent = spawnSync(process.execPath, args, { cwd: repo });
  assert.equal(viaParent.status, 0, viaParent.stdout);
  const viaBase = spawnSync(process.execPath, [...args.slice(0, 2), "--base", rootSha, ...args.slice(2)], {
    cwd: repo,
  });
  assert.equal(viaBase.status, 1, viaBase.stdout);
  assert.ok(viaBase.stdout.includes("allowlist addition not permitted"));
  assert.ok(viaBase.stdout.includes("sneaky.ts"));
});

function loadAllowlistFrom(paths) {
  const file = join(workDir, "allowlist.txt");
  writeFileSync(file, "# seeded\n" + paths.map((p) => p.replace(/\\/g, "/")).join("\n") + "\n");
  return loadAllowlist(file);
}

test("cli: --check exits 0 when every dirty file is ratcheted", () => {
  const { dirtyZig, cleanZig } = fixtures();
  const allowlist = join(workDir, "allowlist.txt");
  writeFileSync(allowlist, `${dirtyZig.replace(/\\/g, "/")}\n`);
  const run = spawnSync(process.execPath, [
    SCRIPT,
    "--check",
    "--allowlist",
    allowlist,
    "--files",
    dirtyZig,
    cleanZig,
  ]);
  assert.equal(run.status, 0, run.stdout);
  assert.ok(run.stdout.includes("(1 ratcheted)"));
});

test("cli: --check exits 1 on an offending file and on a stale entry", () => {
  const { dirtyZig, dirtyTs, cleanZig } = fixtures();
  const allowlist = join(workDir, "allowlist.txt");
  writeFileSync(allowlist, `${dirtyZig.replace(/\\/g, "/")}\n${cleanZig.replace(/\\/g, "/")}\n`);
  const run = spawnSync(process.execPath, [
    SCRIPT,
    "--check",
    "--allowlist",
    allowlist,
    "--files",
    dirtyZig,
    dirtyTs,
    cleanZig,
  ]);
  assert.equal(run.status, 1, run.stdout);
  assert.ok(run.stdout.includes(`comments remain: ${dirtyTs}`));
  assert.ok(run.stdout.includes(`stale allowlist entry`));
});

test("cli: --stats reports per-file counts without writing", () => {
  const { dirtyZig } = fixtures();
  const before = readFileSync(dirtyZig, "utf8");
  const run = spawnSync(process.execPath, [SCRIPT, "--stats", "--files", dirtyZig]);
  assert.equal(run.status, 0, run.stdout);
  assert.ok(run.stdout.includes(`${dirtyZig}: 1`));
  assert.equal(readFileSync(dirtyZig, "utf8"), before);
});
