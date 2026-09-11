#!/usr/bin/env node
// Zero-comments policy checker for makai (#233), ported from
// lsm/superpipe scripts/strip-comments.mjs (itself a port of
// lsm/HyperNeo scripts/strip-comments.ts). One mechanism, two lexers:
// TypeScript comments are found by scanning for `//` and `/*` outside
// string/template/regex literal spans identified by the TypeScript
// parser; Zig comments by a state-machine lexer that tracks `"…"`
// strings, `\\`-prefixed multiline strings, and 'c' char literals, so a
// `//` inside any literal is never a comment. `//`, `///`, and `//!`
// outside literals are comments; only `// zig fmt: off|on` is exempt
// (formatter control). Modes: `--check` (exit 1 on any comment in a
// non-allowlisted file — CI), `--stats` (per-file counts), and write
// mode (default, or `--write`: strip + tidy orphaned blank lines).
// `--check` is ratcheted by scripts/no-comments-allowlist.txt: files
// seeded there pass while the gap-7 series lands, and the list may only
// shrink — entries whose file is clean or untracked are stale, entries
// absent from the comparison revision (--base's commit, else HEAD^1, the
// seed itself excepted) are additions, and both fail. Removing the list
// requires leaving <allowlist>.retired behind, which closes seeding for
// good.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import ts from "typescript";

// All git invocations pass an argument array to execFileSync: a shell
// never sees the pathspecs, so quoting works identically on posix and
// Windows (cmd.exe would otherwise keep the single quotes).
function git(args, cwd) {
  return execFileSync("git", args, { encoding: "utf8", cwd, stdio: ["ignore", "pipe", "pipe"] });
}

// Every pattern matches the COMPLETE directive name followed by a valid
// continuation (end of comment, whitespace, or the char that opens the
// directive's argument) — a `\b` alone would accept hyphenated lookalikes
// (`eslint-disable-policy` is not a directive ESLint processes).
const TS_KEEP_PATTERNS = [
  /^#!/,
  /^(?:\/\/|\/\*+)[\s*]*@ts-(?:ignore|expect-error)(?=[\s:]|$)/,
  /^(?:\/\/|\/\*+)[\s*]*biome-ignore(?=[\s:]|$)/,
  /^(?:\/\/|\/\*+)[\s*]*eslint-disable(?:-(?:next-)?line)?(?=[\s,]|$)/,
  /^(?:\/\/|\/\*+)[\s*]*eslint-enable(?=[\s,]|$)/,
  /^\/\*+[\s*]*eslint-env(?=[\s,]|$)/,
  /^(?:\/\/|\/\*+)[\s*]*oxlint-disable(?:-(?:next-)?line)?(?=[\s,]|$)/,
  /^(?:\/\/|\/\*+)[\s*]*oxlint-enable(?=[\s,]|$)/,
  /^(?:\/\/|\/\*+)[\s*]*@public(?=[\s:]|$)/,
  // JSDoc `@deprecated` is machine-read: tsc copies it into the emitted
  // .d.ts, so stripping it would silently un-deprecate a public alias for
  // consumers and editors. Unlike the line-scoped directives above, a JSDoc
  // tag may follow a description in the same block, so match the tag
  // anywhere in the comment rather than only at its start.
  /^(?:\/\/|\/\*)[\s\S]*?@deprecated(?=[\s:]|$)/,
  /^(?:\/\/|\/\*+)[\s*]*(?:v8|istanbul|c8) ignore(?=[\s]|$)/,
  /^(?:\/\/|\/\*+)[\s*]*knip-ignore(?=[\s:]|$)/,
];

const ZIG_KEEP_PATTERNS = [/^\/\/ zig fmt: (off|on)[ \t\r]*$/];

const DEFAULT_ALLOWLIST = fileURLToPath(new URL("no-comments-allowlist.txt", import.meta.url));

// ---------------------------------------------------------------------------
// TypeScript: literal spans from the parser, then any `//` or `/*` outside
// them is unambiguously a comment. Line comments end at any ECMAScript
// line terminator (LF, CR, LS, PS) — a lone CR or LS terminates a comment
// just like a newline, or write mode would eat the next line's code.
// ---------------------------------------------------------------------------

const TS_LINE_TERMINATOR = /[\n\r\u2028\u2029]/;

// @ts-check/@ts-nocheck and /// <reference>-style directives are file-scoped
// TypeScript trivia: the compiler processes them only as single-line comments
// in the file's leading trivia — a shebang and other comments may precede
// them, executable code may not. Outside that window every placement (block
// pragmas, mid-file, post-code) is an ordinary comment and counts.
// @ts-ignore/@ts-expect-error stay on the always-exempt list above because
// they are line-scoped suppressions, not file-wide pragmas. The window is
// tracked by the scanner itself as it walks left to right (leadingTrivia in
// collectTsCommentRanges), never by stripping delimiter-shaped text out of
// the raw prefix — a block delimiter inside a line comment would fool that.
const TS_LEADING_PATTERNS = [
  /^\/\/\s*@ts-(?:nocheck|check)(?=[\s:]|$)/,
  /^\/\/\/\s*<(?:reference|amd-dependency|amd-module)(?=[\s]|$)/,
];

function parse(text, fileName) {
  return ts.createSourceFile(fileName, text, ts.ScriptTarget.Latest, false, ts.ScriptKind.TS);
}

function collectTsLiteralSpans(text, fileName) {
  const sf = parse(text, fileName);
  const spans = [];
  const visit = (node) => {
    if (
      ts.isStringLiteral(node) ||
      ts.isNoSubstitutionTemplateLiteral(node) ||
      ts.isTemplateHead(node) ||
      ts.isTemplateMiddle(node) ||
      ts.isTemplateTail(node) ||
      ts.isRegularExpressionLiteral(node)
    ) {
      spans.push({ start: node.getStart(sf), end: node.end });
    }
    ts.forEachChild(node, visit);
  };
  visit(sf);
  return spans;
}

function collectTsCommentRanges(text, fileName) {
  const spans = mergeRanges(collectTsLiteralSpans(text, fileName));
  const ranges = [];
  let spanIdx = 0;
  let i = 0;
  const n = text.length;
  // True while everything consumed so far is shebang/comments/whitespace:
  // the file's leading trivia. Literal spans and any other code close it,
  // comments never do, and the shebang skip below leaves it open.
  let leadingTrivia = true;
  // The shebang line is a protected span: a `//` inside it (e.g. a Deno
  // `--allow-net=https://…` flag) is not a comment, and keep-patterns can
  // never see it anyway because matching starts at the `//`.
  if (text.startsWith("#!")) {
    while (i < n && !TS_LINE_TERMINATOR.test(text[i])) i++;
  }
  while (i < n) {
    const span = spans[spanIdx];
    if (span && i >= span.end) {
      spanIdx++;
      continue;
    }
    if (span && i >= span.start) {
      i = span.end;
      leadingTrivia = false;
      continue;
    }
    if (text[i] === "/" && text[i + 1] === "/") {
      let j = i + 2;
      while (j < n && !TS_LINE_TERMINATOR.test(text[j])) j++;
      const slice = text.slice(i, j);
      const kept =
        TS_KEEP_PATTERNS.some((p) => p.test(slice)) ||
        (leadingTrivia && TS_LEADING_PATTERNS.some((p) => p.test(slice)));
      if (!kept) ranges.push({ start: i, end: j });
      i = j;
      continue;
    }
    if (text[i] === "/" && text[i + 1] === "*") {
      const close = text.indexOf("*/", i + 2);
      if (close === -1) {
        const line = text.slice(0, i).split("\n").length;
        throw new Error(
          `line ${line}: block comment is never closed — ambiguous lex, refusing to strip`,
        );
      }
      const end = close + 2;
      if (!TS_KEEP_PATTERNS.some((p) => p.test(text.slice(i, end)))) ranges.push({ start: i, end });
      i = end;
      continue;
    }
    if (!/\s/.test(text[i])) leadingTrivia = false;
    i++;
  }
  return ranges;
}

// ---------------------------------------------------------------------------
// Zig: single-pass state machine. Outside literals, `//` starts a comment
// that runs to end of line (`///` and `//!` are comment forms too); `\\`
// starts a multiline string literal line whose continuation lines are the
// following lines whose first non-blank characters are also `\\`.
// ---------------------------------------------------------------------------

function scanZig(text) {
  const comments = [];
  const literals = [];
  const n = text.length;
  let i = 0;
  while (i < n) {
    const c = text[i];
    if (c === '"' || c === "'") {
      const start = i;
      i++;
      while (i < n && text[i] !== c) {
        if (text[i] === "\\") i++;
        i++;
      }
      i = Math.min(i + 1, n);
      literals.push({ start, end: i });
      continue;
    }
    if (c === "\\" && text[i + 1] === "\\") {
      const start = i;
      for (;;) {
        while (i < n && text[i] !== "\n") i++;
        let j = i + 1;
        while (j < n && (text[j] === " " || text[j] === "\t")) j++;
        if (j + 1 < n && text[j] === "\\" && text[j + 1] === "\\") {
          i = j;
        } else {
          break;
        }
      }
      literals.push({ start, end: i });
      continue;
    }
    if (c === "/" && text[i + 1] === "/") {
      let j = i + 2;
      while (j < n && text[j] !== "\n") j++;
      if (!ZIG_KEEP_PATTERNS.some((p) => p.test(text.slice(i, j)))) comments.push({ start: i, end: j });
      i = j;
      continue;
    }
    i++;
  }
  return { comments, literals };
}

// ---------------------------------------------------------------------------
// Shared range machinery: whole-line removal for alone-on-a-line comments,
// then trailing-space and blank-run tidy outside literals only.
// ---------------------------------------------------------------------------

function expandRange(text, { start, end }, preserveLine = false) {
  let lineStart = 0;
  if (start > 0) {
    const nl = text.lastIndexOf("\n", start - 1);
    lineStart = nl === -1 ? 0 : nl + 1;
  }
  let nlAfter = text.indexOf("\n", end);
  if (nlAfter === -1) nlAfter = text.length;
  const prefix = text.slice(lineStart, start);
  const suffix = text.slice(end, nlAfter);
  if (/^\s*$/.test(prefix) && /^\s*$/.test(suffix)) {
    // Whole-line removal — but when a kept next-line directive sits on the
    // previous line, keep the newline so the directive still targets a line
    // of its own instead of sliding onto different code.
    return { start: lineStart, end: preserveLine ? nlAfter : Math.min(nlAfter + 1, text.length), alone: true };
  }
  let e = end;
  while (e < text.length && (text[e] === " " || text[e] === "\t")) e++;
  return { start, end: e, alone: false };
}

function mergeRanges(ranges) {
  const sorted = [...ranges].sort((a, b) => a.start - b.start);
  const merged = [];
  for (const r of sorted) {
    const last = merged[merged.length - 1];
    if (last && r.start <= last.end) {
      last.end = Math.max(last.end, r.end);
      last.alone = last.alone && r.alone;
    } else {
      merged.push({ ...r });
    }
  }
  return merged;
}

const tidy = (segment) => segment.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n");

function literalSpans(text, fileName) {
  return fileName.endsWith(".zig")
    ? mergeRanges(scanZig(text).literals)
    : mergeRanges(collectTsLiteralSpans(text, fileName));
}

function normalizeOutsideLiterals(text, fileName) {
  const spans = literalSpans(text, fileName);
  let out = "";
  let cursor = 0;
  for (const { start, end } of spans) {
    out += tidy(text.slice(cursor, start));
    out += text.slice(start, end);
    cursor = end;
  }
  return out + tidy(text.slice(cursor));
}

export function findComments(text, fileName) {
  return fileName.endsWith(".zig") ? scanZig(text).comments : collectTsCommentRanges(text, fileName);
}

// Does a kept directive comment occupy the line immediately before this
// comment's line? Removing a comment-only line directly under a next-line
// directive would otherwise re-attach the directive to different code.
function directivePrecedes(text, { start }, keepPatterns) {
  const lineStart = start > 0 ? text.lastIndexOf("\n", start - 1) + 1 : 0;
  if (lineStart === 0) return false;
  const prevEnd = lineStart - 1;
  const prevStart = text.lastIndexOf("\n", prevEnd - 1) + 1;
  const t = text.slice(prevStart, prevEnd).trimStart();
  return (t.startsWith("//") || t.startsWith("/*")) && keepPatterns.some((p) => p.test(t));
}

export function stripComments(text, fileName = "x.ts") {
  const lineTerminator = fileName.endsWith(".zig") ? /[\n]/ : TS_LINE_TERMINATOR;
  const keepPatterns = fileName.endsWith(".zig") ? ZIG_KEEP_PATTERNS : TS_KEEP_PATTERNS;
  const comments = findComments(text, fileName);
  if (comments.length === 0) return text;
  const removals = mergeRanges(
    comments.map((r) => expandRange(text, r, directivePrecedes(text, r, keepPatterns))),
  );
  let out = "";
  let cursor = 0;
  for (const { start, end, alone } of removals) {
    out += text.slice(cursor, start);
    // A removal must not change token separation. Comment-only lines are
    // fully removed (`alone`) — surrounding newlines already separate the
    // neighbors. Otherwise, when the removal would join two directly
    // abutting non-whitespace characters (`return/*c*/value`,
    // `a+/*c*/+b`), leave a space. A block comment containing a line
    // terminator carries one for ASI purposes, so removing it inline
    // leaves a newline (`return/*\r*/value` keeps `return\nvalue`; every
    // ECMAScript terminator for TypeScript, LF for Zig, which has no
    // block comments anyway).
    if (!alone) {
      const removed = text.slice(start, end);
      if (lineTerminator.test(removed)) out += "\n";
      else if (/\S$/.test(out) && end < text.length && /\S/.test(text[end])) out += " ";
    }
    cursor = end;
  }
  out += text.slice(cursor);
  return normalizeOutsideLiterals(out, fileName);
}

// ---------------------------------------------------------------------------
// Ratchet + CLI
// ---------------------------------------------------------------------------

function parseAllowlist(text) {
  const entries = new Set();
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    entries.add(t);
  }
  return entries;
}

export function loadAllowlist(path) {
  if (!existsSync(path)) return new Set();
  return parseAllowlist(readFileSync(path, "utf8"));
}

// The comparison commit for ratchet diffs: the requested --base revision
// itself (a pull request's base sha, or a push's pre-update sha — the start
// of the submitted range). Deliberately not its merge-base with HEAD: under
// a force push to divergent history the merge-base is some older common
// ancestor, and ratchet state recorded between that ancestor and the old tip
// (a retirement marker, a removed allowlist entry) would never be inspected,
// so the force push could undo the latch unnoticed. An explicit --base that
// does not resolve to a commit — force-pushed away, all-zero, shallow clone
// — is an error: narrowing to HEAD^1 instead would hide an addition made and
// stripped earlier in the same range. With no --base, HEAD^1 is the
// comparison commit; null when there is none (root commit), where the
// allowlist is necessarily new and seeds.
export function resolveBaseCommit(cwd, baseRev = null) {
  if (baseRev) {
    try {
      return git(["rev-parse", "--verify", `${baseRev}^{commit}`], cwd).trim();
    } catch {
      throw new Error(
        `--base ${baseRev} does not resolve to a commit — refusing to narrow the ratchet to HEAD^1`,
      );
    }
  }
  try {
    return git(["rev-parse", "--verify", "HEAD^1"], cwd).trim();
  } catch {
    return null;
  }
}

// Entries of the allowlist as committed at the comparison commit, or null
// when there is no comparison commit or the file is not there — the seed
// case, where the allowlist is new in this change and every entry is taken
// as given. ratchetViolation is what keeps seeding closed after retirement.
export function baseAllowlistEntries(allowlistPath, cwd, baseCommit) {
  if (!baseCommit) return null;
  let root;
  try {
    root = git(["rev-parse", "--show-toplevel"], cwd).trim();
  } catch {
    return null;
  }
  const rel = relative(root, resolve(cwd, allowlistPath));
  if (rel.startsWith("..")) return null;
  try {
    return parseAllowlist(git(["show", `${baseCommit}:${rel}`], cwd));
  } catch {
    return null;
  }
}

// The ratchet is a one-way latch. The planned one-time strip removes the
// allowlist and leaves a `<allowlist>.retired` marker in its place; from
// then on seeding is closed — the marker cannot be removed and the
// allowlist cannot be recreated — so a fresh seed of arbitrary dirty paths
// can never reopen the bypass. Returns a violation message or null.
export function ratchetViolation(allowlistPath, cwd, baseCommit = null) {
  const marker = `${allowlistPath}.retired`;
  const allowlistExists = existsSync(allowlistPath);
  const markerExists = existsSync(marker);
  if (markerExists && allowlistExists) {
    return "ratchet is retired but an allowlist is present — seeding is closed; remove the allowlist";
  }
  if (markerExists) return null;
  let root;
  try {
    root = git(["rev-parse", "--show-toplevel"], cwd).trim();
  } catch {
    return null;
  }
  const markerRel = relative(root, resolve(cwd, marker));
  const allowlistRel = relative(root, resolve(cwd, allowlistPath));
  if (markerRel.startsWith("..")) return null;
  const revs = baseCommit ? ["HEAD", baseCommit] : ["HEAD"];
  // A marker that existed in HEAD (working-tree removal) or at the
  // comparison commit (committed removal) but is absent now undoes the
  // retirement.
  for (const rev of revs) {
    try {
      git(["cat-file", "-e", `${rev}:${markerRel}`], cwd);
      return "ratchet retirement cannot be undone — the retired marker was removed";
    } catch {
      // marker not present at this revision
    }
  }
  // Removing the allowlist requires the marker: without it a later change
  // could recreate the file and seed freely, since no base allowlist and no
  // marker would exist.
  if (!allowlistExists) {
    for (const rev of revs) {
      try {
        git(["cat-file", "-e", `${rev}:${allowlistRel}`], cwd);
        return `allowlist removed without the retirement marker — create ${marker} so seeding stays closed`;
      } catch {
        // allowlist not present at this revision
      }
    }
  }
  return null;
}

// A tracked file deleted from the working tree before staging (git
// ls-files still lists it) is not dirty — skipping it lets the stale-entry
// logic report its allowlist entry instead of crashing on ENOENT.
function readIfExists(file) {
  try {
    return readFileSync(file, "utf8");
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
}

export function checkFiles(files, allowlist, baseEntries = null) {
  const offending = [];
  const ratcheted = [];
  const stats = [];
  const dirty = new Set();
  for (const file of files) {
    const text = readIfExists(file);
    if (text === null) continue;
    const count = findComments(text, file).length;
    if (count === 0) continue;
    dirty.add(file);
    stats.push({ file, count, allowlisted: allowlist.has(file) });
    if (allowlist.has(file)) {
      ratcheted.push(file);
    } else {
      offending.push(file);
    }
  }
  const stale = [...allowlist].filter((p) => !dirty.has(p)).sort();
  const additions = baseEntries === null ? [] : [...allowlist].filter((p) => !baseEntries.has(p)).sort();
  return { offending, ratcheted, stale, additions, stats, dirtyCount: dirty.size, commentTotal: stats.reduce((a, s) => a + s.count, 0) };
}

function listFiles(args) {
  const filesIdx = args.indexOf("--files");
  if (filesIdx !== -1) {
    const rest = args.slice(filesIdx + 1);
    const end = rest.findIndex((a) => a.startsWith("--"));
    return rest.slice(0, end === -1 ? rest.length : end).filter(Boolean);
  }
  // -z emits NUL-delimited names without C-quoting non-ASCII paths or
  // touching embedded whitespace, so every tracked filename reads exactly.
  return git(["ls-files", "-z", "*.zig", "*.ts"])
    .split("\0")
    .filter(Boolean);
}

function main() {
  const args = process.argv.slice(2);
  const check = args.includes("--check");
  const stats = args.includes("--stats");
  const allowlistIdx = args.indexOf("--allowlist");
  const allowlistPath = allowlistIdx !== -1 ? args[allowlistIdx + 1] : DEFAULT_ALLOWLIST;
  const baseIdx = args.indexOf("--base");
  const baseRev = baseIdx !== -1 ? args[baseIdx + 1] : null;
  const files = listFiles(args);
  const allowlist = loadAllowlist(allowlistPath);

  if (check) {
    let baseCommit;
    try {
      baseCommit = resolveBaseCommit(process.cwd(), baseRev);
    } catch (err) {
      process.stdout.write(`${err.message}\n`);
      process.exit(1);
    }
    const violation = ratchetViolation(allowlistPath, process.cwd(), baseCommit);
    if (violation) {
      process.stdout.write(`${violation}\n`);
      process.exit(1);
    }
    const result = checkFiles(files, allowlist, baseAllowlistEntries(allowlistPath, process.cwd(), baseCommit));
    for (const file of result.offending) process.stdout.write(`comments remain: ${file}\n`);
    for (const path of result.stale) {
      process.stdout.write(`stale allowlist entry (clean or untracked): ${path}\n`);
    }
    for (const path of result.additions) {
      process.stdout.write(`allowlist addition not permitted (the ratchet may only shrink): ${path}\n`);
    }
    process.stdout.write(
      `files with comments: ${result.dirtyCount} (${result.ratcheted.length} ratcheted), ` +
        `offending: ${result.offending.length}, stale entries: ${result.stale.length}` +
        `, added entries: ${result.additions.length}\n`,
    );
    if (result.offending.length > 0 || result.stale.length > 0 || result.additions.length > 0) {
      process.exit(1);
    }
    return;
  }

  let stripped = 0;
  let removed = 0;
  let failed = false;
  for (const file of files) {
    const text = readIfExists(file);
    if (text === null) continue;
    let out;
    try {
      out = stripComments(text, file);
    } catch (err) {
      process.stdout.write(`cannot lex ${file}: ${err.message}\n`);
      failed = true;
      break;
    }
    if (out === text) continue;
    const count = findComments(text, file).length;
    stripped++;
    removed += count;
    if (stats) process.stdout.write(`${file}: ${count}\n`);
    if (!stats) writeFileSync(file, out);
  }
  process.stdout.write(
    `${stats ? "files with comments" : "files stripped"}: ${stripped}, comments: ${removed}\n`,
  );
  if (failed) process.exit(2);
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main();
}
