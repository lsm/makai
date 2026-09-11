// Self-tests for check-no-comments.mjs (#233): Zig lexer literal fixtures,
// exemption patterns for both languages, the ported TypeScript scanner's
// regex/template regression corpus, and ratchet closure behavior (base
// cascade, additions vs the comparison commit, fail-closed base,
// retirement latch). Run with `node --test scripts/check-no-comments.test.mjs`.

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

test("ts: a removed comment under a next-line directive keeps the directive's own line", () => {
  // eslint-disable-next-line targets the immediately following line; if a
  // removed comment occupied that line, deleting it outright would slide
  // the suppression onto different code. The blank line preserves the
  // original attachment.
  assert.equal(
    stripComments("// eslint-disable-next-line no-undef\n// explanation\nfoo()\n", "x.ts"),
    "// eslint-disable-next-line no-undef\n\nfoo()\n",
  );
  assert.equal(
    stripComments("// @ts-expect-error malformed\n// because of X\nconst a = 1\n", "x.ts"),
    "// @ts-expect-error malformed\n\nconst a = 1\n",
  );
  assert.equal(
    stripComments("// biome-ignore lint/suspicious/noExplicitAny: reason\n// detail\nfoo(1 as any)\n", "x.ts"),
    "// biome-ignore lint/suspicious/noExplicitAny: reason\n\nfoo(1 as any)\n",
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

test("ts: every ECMAScript line terminator inside a block comment preserves ASI", () => {
  assert.equal(stripComments("return/*\r*/value\n", "x.ts"), "return\nvalue\n");
  assert.equal(stripComments("return/*\u2028*/value\n", "x.ts"), "return\nvalue\n");
});

test("ts: line comments end at every ECMAScript line terminator, not just LF", () => {
  const cr = "const a=1;//c\rconst b=2;\n";
  assert.equal(tsCount(cr), 1);
  const crOut = stripComments(cr, "x.ts");
  assert.ok(crOut.includes("const b=2;"), crOut);
  const ls = "const a=1;//c\u2028const b=2;\n";
  assert.equal(tsCount(ls), 1);
  const lsOut = stripComments(ls, "x.ts");
  assert.ok(lsOut.includes("const b=2;"), lsOut);
});

test("ts: unclosed block comment refuses to lex", () => {
  assert.throws(() => stripComments("const a = 1 /* oops\nkeep()\n", "x.ts"), /never closed/);
});

test("ts: functional directives are exempt, lookalikes are not", () => {
  const kept = [
    "#!/usr/bin/env node\nconst a = 1\n",
    "#!/usr/bin/env -S deno run --allow-net=https://example.com\nconst a = 1\n",
    '/// <reference types="node" />\nconst a = 1\n',
    "// @ts-expect-error malformed input\nconst a = 1\n",
    "/* @ts-ignore */\nconst a = 1\n",
    "// biome-ignore lint/suspicious/noExplicitAny: fixture\nconst a = 1\n",
    "// eslint-disable-next-line no-console\nconst a = 1\n",
    "// eslint-disable-line\nconst a = 1\n",
    "/* eslint-enable */\nconst a = 1\n",
    "// oxlint-disable-next-line\nconst a = 1\n",
    "/* eslint-disable no-console, no-alert */\nconst a = 1\n",
    "/* eslint-env browser, node */\nconst a = 1\n",
    "// oxlint-disable-next-line\nconst a = 1\n",
    "// @public\nconst a = 1\n",
    "/** @deprecated Use NewOptions. */\nconst a = 1\n",
    "/**\n * Legacy options.\n * @deprecated Use NewOptions.\n */\nconst a = 1\n",
    "// @deprecated Use NewOptions.\nconst a = 1\n",
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
  assert.equal(tsCount("// eslint-plugin-react is not needed here\nconst a = 1\n"), 1);
  assert.equal(tsCount("// eslint-disable-policy discussion\nconst a = 1\n"), 1);
  assert.equal(tsCount("// eslint-enable-line\nconst a = 1\n"), 1);
  assert.equal(tsCount("// eslint-enable-next-line no-console\nconst a = 1\n"), 1);
  assert.equal(tsCount("// oxlint-enable-next-line\nconst a = 1\n"), 1);
  assert.equal(tsCount("// @ts-ignore-policy notes\nconst a = 1\n"), 1);
  assert.equal(tsCount("// biome-ignore-policy draft\nconst a = 1\n"), 1);
  assert.equal(tsCount("// v8 ignore-all the things\nconst a = 1\n"), 1);
  assert.equal(tsCount("// do not add @ts-ignore here\nconst a = 1\n"), 1);
  assert.equal(tsCount("// consider biome-ignore later\nconst a = 1\n"), 1);
  assert.equal(tsCount("// coverage uses v8 ignore below\nconst a = 1\n"), 1);
  assert.equal(tsCount("// we removed knip-ignore usage\nconst a = 1\n"), 1);
  assert.equal(tsCount("// @deprecated-policy draft\nconst a = 1\n"), 1);
  assert.equal(tsCount("// this API is deprecated\nconst a = 1\n"), 1);
  assert.equal(tsCount("/// <summary>documentation</summary>\nconst a = 1\n"), 1);
});

test("ts: @ts-check/@ts-nocheck are exempt only as leading single-line pragmas", () => {
  const kept = [
    "// @ts-nocheck\nconst a = 1\n",
    "//@ts-check\nconst a = 1\n",
    "#!/usr/bin/env node\n// @ts-check\nconst a = 1\n",
    '/// <reference types="node" />\n// @ts-nocheck\nconst a = 1\n',
    "const a = 1\n// @ts-ignore\nconst b = 2\n",
    "const a = 1\n// @ts-expect-error\nconst b = 2\n",
  ];
  for (const src of kept) {
    assert.equal(tsCount(src), 0, `expected exempt: ${src.split("\n")[0]}`);
  }
  const afterHeader = "/* header */\n// @ts-nocheck\nconst a = 1\n";
  const found = findComments(afterHeader, "x.ts");
  assert.equal(found.length, 1);
  assert.ok(afterHeader.slice(found[0].start, found[0].end).startsWith("/* header"));
  assert.equal(tsCount("/* @ts-nocheck */\nconst a = 1\n"), 1);
  assert.equal(tsCount("const a = 1\n// @ts-nocheck\nconst b = 2\n"), 1);
  assert.equal(tsCount("const a = 1\n// @ts-check\nconst b = 2\n"), 1);
  assert.equal(tsCount('const a = "// @ts-check"\n// @ts-nocheck\nconst b = 2\n'), 1);
  assert.equal(tsCount("#!/usr/bin/env node\r// @ts-check\nconst a = 1\n"), 0);
  const interleaved = '// @ts-ignore /*\nconst x = 1; // @ts-ignore */\n// @ts-check\n';
  const foundInterleaved = findComments(interleaved, "x.ts");
  assert.equal(foundInterleaved.length, 1);
  assert.ok(interleaved.slice(foundInterleaved[0].start, foundInterleaved[0].end).startsWith("// @ts-check"));
});

test("ts: /// directives are exempt only in the file's leading trivia", () => {
  const kept = [
    '/// <reference types="node" />\nconst a = 1\n',
    '/// <amd-dependency path="./x.js" />\nconst a = 1\n',
    '/// <amd-module name="x" />\nconst a = 1\n',
    '/// <reference types="node" />\n/// <reference lib="dom" />\nconst a = 1\n',
    '#!/usr/bin/env node\n/// <reference types="node" />\nconst a = 1\n',
  ];
  for (const src of kept) {
    assert.equal(tsCount(src), 0, `expected exempt: ${src.split("\n")[0]}`);
  }
  const afterLineComment = '// harness config\n/// <reference types="node" />\nconst a = 1\n';
  const foundComment = findComments(afterLineComment, "x.ts");
  assert.equal(foundComment.length, 1);
  assert.ok(afterLineComment.slice(foundComment[0].start, foundComment[0].end).startsWith("// harness"));
  const afterHeader = '/* header */\n/// <reference types="node" />\nconst a = 1\n';
  const found = findComments(afterHeader, "x.ts");
  assert.equal(found.length, 1);
  assert.ok(afterHeader.slice(found[0].start, found[0].end).startsWith("/* header"));
  assert.equal(tsCount('const a = 1\n/// <reference types="node" />\n'), 1);
  assert.equal(tsCount('#!/usr/bin/env node\nconst a = 1\n/// <reference types="node" />\n'), 1);
  assert.equal(tsCount('const a = 1/// <reference types="node" />\n'), 1);
  assert.equal(tsCount('const a = 1\n/// <amd-module name="x" />\n'), 1);
  assert.equal(tsCount("#!/usr/bin/env node\u2028/// <reference types=\"node\" />\nconst a = 1\n"), 0);
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

test("ratchet: a tracked file deleted before staging is skipped, not crashed on", () => {
  const { dirtyZig } = fixtures();
  const deleted = join(workDir, "deleted-pending-stage.zig");
  writeFileSync(deleted, "// carve\nconst x = 1;\n");
  const result = checkFiles([dirtyZig, deleted], new Set([dirtyZig, deleted]));
  rmSync(deleted);
  const after = checkFiles([dirtyZig, deleted], new Set([dirtyZig, deleted]));
  assert.deepEqual(result.offending, []);
  assert.deepEqual(result.ratcheted.sort(), [deleted, dirtyZig].sort());
  assert.deepEqual(after.offending, []);
  assert.deepEqual(after.stale, [deleted]);
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

test("ratchet: an allowlist new in this change seeds freely (no comparison commit has it)", () => {
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
  assert.ok(run.stdout.includes("(2 ratcheted)"), run.stdout);
  assert.ok(run.stdout.includes("added entries: 0"), run.stdout);
});

test("ratchet: allowlist entries absent from the comparison commit are rejected additions", () => {
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
  assert.ok(run.stdout.includes("allowlist addition not permitted"), run.stdout);
  assert.ok(run.stdout.includes("dirty.ts"), run.stdout);
  assert.ok(run.stdout.includes("added entries: 1"), run.stdout);
});

function headSha(repo) {
  return execSync("git rev-parse HEAD", { cwd: repo, encoding: "utf8" }).trim();
}

// Three commits with sneaky.ts allowlisted in the middle one: comparing
// against HEAD^1 sees the entry as pre-existing, so only the true start of
// the range exposes it.
function rangeRepo(name) {
  const repo = gitRepo(name);
  writeFileSync(join(repo, "dirty.zig"), "// carve\nconst x = 1;\n");
  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\n");
  gitCommit(repo);
  const rootSha = headSha(repo);
  writeFileSync(join(repo, "sneaky.ts"), "// mid-range\nconst a = 1;\n");
  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\nsneaky.ts\n");
  gitCommit(repo);
  writeFileSync(join(repo, "dirty.zig"), "// carve\nconst x = 2;\n");
  gitCommit(repo);
  return { repo, rootSha };
}

const rangeArgs = [
  SCRIPT,
  "--check",
  "--allowlist",
  "allowlist.txt",
  "--files",
  "dirty.zig",
  "sneaky.ts",
];

test("ratchet: --base catches an addition hidden earlier in a multi-commit range", () => {
  const { repo, rootSha } = rangeRepo("range-repo");
  const viaParent = spawnSync(process.execPath, rangeArgs, { cwd: repo });
  assert.equal(viaParent.status, 0, viaParent.stdout);
  const viaBase = spawnSync(
    process.execPath,
    [SCRIPT, "--check", "--base", rootSha, ...rangeArgs.slice(2)],
    { cwd: repo },
  );
  assert.equal(viaBase.status, 1, viaBase.stdout);
  assert.ok(viaBase.stdout.includes("allowlist addition not permitted"), viaBase.stdout);
  assert.ok(viaBase.stdout.includes("sneaky.ts"), viaBase.stdout);
});

test("ratchet: an unresolvable --base fails closed instead of narrowing to HEAD^1", () => {
  // The same range HEAD^1 accepts above must not pass when the base it was
  // asked to compare against is gone: silence there would hide the addition.
  const { repo } = rangeRepo("dangling-base-repo");
  const run = spawnSync(
    process.execPath,
    [SCRIPT, "--check", "--base", "0".repeat(40), ...rangeArgs.slice(2)],
    { cwd: repo },
  );
  assert.equal(run.status, 1, run.stdout);
  assert.ok(run.stdout.includes("does not resolve to a commit"), run.stdout);
  assert.ok(run.stdout.includes("refusing to narrow the ratchet to HEAD^1"), run.stdout);
});

test("ratchet: --base is read as given, not reduced to its merge base", () => {
  // A force push replaces the old tip with divergent history: the start of
  // the pushed range is the old tip itself. Reducing it to the merge base
  // (a shared ancestor) skips everything committed between that ancestor
  // and the old tip, so a retirement recorded there goes unseen and the
  // force push re-enables seeding without failing.
  const repo = gitRepo("divergent-base-repo");
  writeFileSync(join(repo, "dirty.zig"), "// carve\nconst x = 1;\n");
  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\n");
  gitCommit(repo);
  const ancestor = headSha(repo);
  rmSync(join(repo, "allowlist.txt"));
  writeFileSync(join(repo, "allowlist.txt.retired"), "");
  gitCommit(repo);
  const prePush = headSha(repo);
  execSync(`git checkout -q -b rewritten ${ancestor}`, { cwd: repo });
  writeFileSync(join(repo, "dirty.zig"), "// carve\nconst x = 2;\n");
  gitCommit(repo);
  const run = spawnSync(
    process.execPath,
    [SCRIPT, "--check", "--base", prePush, "--allowlist", "allowlist.txt", "--files", "dirty.zig"],
    { cwd: repo },
  );
  assert.equal(run.status, 1, run.stdout);
  assert.ok(run.stdout.includes("cannot be undone"), run.stdout);
});

test("ratchet: retirement is a one-way latch that closes seeding", () => {
  const repo = gitRepo("retired-repo");
  writeFileSync(join(repo, "dirty.zig"), "// carve\nconst x = 1;\n");
  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\n");
  gitCommit(repo);
  writeFileSync(join(repo, "dirty.zig"), "const x = 1;\n");
  rmSync(join(repo, "allowlist.txt"));
  writeFileSync(join(repo, "allowlist.txt.retired"), "");
  gitCommit(repo);
  const run = () =>
    spawnSync(
      process.execPath,
      [SCRIPT, "--check", "--allowlist", "allowlist.txt", "--files", "dirty.zig"],
      { cwd: repo },
    );

  const retired = run();
  assert.equal(retired.status, 0, retired.stdout);

  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\n");
  const recreated = run();
  assert.equal(recreated.status, 1, recreated.stdout);
  assert.ok(recreated.stdout.includes("seeding is closed"), recreated.stdout);

  rmSync(join(repo, "allowlist.txt"));
  rmSync(join(repo, "allowlist.txt.retired"));
  const unretired = run();
  assert.equal(unretired.status, 1, unretired.stdout);
  assert.ok(unretired.stdout.includes("cannot be undone"), unretired.stdout);
});

test("ratchet: removing the allowlist without the retirement marker fails", () => {
  const repo = gitRepo("no-marker-repo");
  writeFileSync(join(repo, "dirty.zig"), "// carve\nconst x = 1;\n");
  writeFileSync(join(repo, "allowlist.txt"), "dirty.zig\n");
  gitCommit(repo);
  writeFileSync(join(repo, "dirty.zig"), "const x = 1;\n");
  rmSync(join(repo, "allowlist.txt"));
  const run = spawnSync(
    process.execPath,
    [SCRIPT, "--check", "--allowlist", "allowlist.txt", "--files", "dirty.zig"],
    { cwd: repo },
  );
  assert.equal(run.status, 1, run.stdout);
  assert.ok(run.stdout.includes("without the retirement marker"), run.stdout);
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

test("cli: non-ASCII tracked filenames are read exactly from git ls-files -z", () => {
  const repo = gitRepo("unicode-repo");
  writeFileSync(join(repo, "café.zig"), "// carve\nconst x = 1;\n");
  gitCommit(repo);
  const run = spawnSync(process.execPath, [SCRIPT, "--check", "--allowlist", "none.txt"], { cwd: repo });
  assert.equal(run.status, 1, run.stdout);
  assert.ok(run.stdout.includes("comments remain: café.zig"), run.stdout);
});
