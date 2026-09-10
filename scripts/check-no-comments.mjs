#!/usr/bin/env node
// Zero-comments policy checker for makai (#228), ported from
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
// seeded there pass while the gap-7 series lands; entries whose file is
// clean or untracked are stale and fail, and entries absent from the
// base revision (--base's merge-base, else HEAD^1 — the seed itself
// excepted) are additions and fail, so the list only shrinks.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import ts from "typescript";

// All git invocations pass an argument array to execFileSync: a shell
// never sees the pathspecs, so quoting works identically on posix and
// Windows (cmd.exe would otherwise keep the single quotes).
function git(args, cwd) {
  return execFileSync("git", args, { encoding: "utf8", cwd, stdio: ["ignore", "pipe", "pipe"] });
}

const TS_KEEP_PATTERNS = [
  /^#!/,
  /^\/\/\/\s*</,
  /^(?:\/\/|\/\*+)[\s*]*@ts-(ignore|expect-error|nocheck|check)\b/,
  /^(?:\/\/|\/\*+)[\s*]*biome-ignore\b/,
  /^(?:\/\/|\/\*+)\s*eslint-/,
  /^(?:\/\/|\/\*+)[\s*]*oxlint-(disable|enable)\b/,
  /^(?:\/\/|\/\*+)[\s*]*@public\b/,
  /^(?:\/\/|\/\*+)[\s*]*(?:v8|istanbul|c8) ignore\b/,
  /^(?:\/\/|\/\*+)[\s*]*knip-ignore\b/,
];

const ZIG_KEEP_PATTERNS = [/^\/\/ zig fmt: (off|on)[ \t\r]*$/];

const DEFAULT_ALLOWLIST = fileURLToPath(new URL("no-comments-allowlist.txt", import.meta.url));

// ---------------------------------------------------------------------------
// TypeScript: literal spans from the parser, then any `//` or `/*` outside
// them is unambiguously a comment.
// ---------------------------------------------------------------------------

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
  while (i < n) {
    const span = spans[spanIdx];
    if (span && i >= span.end) {
      spanIdx++;
      continue;
    }
    if (span && i >= span.start) {
      i = span.end;
      continue;
    }
    if (text[i] === "/" && text[i + 1] === "/") {
      let j = i + 2;
      while (j < n && text[j] !== "\n") j++;
      if (!TS_KEEP_PATTERNS.some((p) => p.test(text.slice(i, j)))) ranges.push({ start: i, end: j });
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

function expandRange(text, { start, end }) {
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
    return { start: lineStart, end: Math.min(nlAfter + 1, text.length), alone: true };
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

export function stripComments(text, fileName = "x.ts") {
  const comments = findComments(text, fileName);
  if (comments.length === 0) return text;
  const removals = mergeRanges(comments.map((r) => expandRange(text, r)));
  let out = "";
  let cursor = 0;
  for (const { start, end, alone } of removals) {
    out += text.slice(cursor, start);
    // A removal must not change token separation. Comment-only lines are
    // fully removed (`alone`) — surrounding newlines already separate the
    // neighbors. Otherwise, when the removal would join two directly
    // abutting non-whitespace characters (`return/*c*/value`,
    // `a+/*c*/+b`), leave a space. A block comment spanning lines carries
    // a line terminator for ASI purposes, so removing one inline leaves a
    // newline (`return/*\n*/value` keeps `return\nvalue`).
    if (!alone) {
      if (text.slice(start, end).includes("\n")) out += "\n";
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

// Entries of the allowlist as committed in the base revision, or null when
// no comparison point is determinable — the seed case, where the allowlist
// is new in this change and every entry is taken as given. The comparison
// commit is the merge-base of HEAD and the --base revision (the PR base sha
// or a push's pre-update sha, so additions anywhere in a multi-commit range
// are caught), or HEAD^1 when --base is not given.
export function baseAllowlistEntries(allowlistPath, cwd, baseRev = null) {
  let root;
  let base;
  let rel;
  try {
    root = git(["rev-parse", "--show-toplevel"], cwd).trim();
    base = baseRev
      ? git(["merge-base", "HEAD", baseRev], cwd).trim()
      : git(["rev-parse", "--verify", "HEAD^1"], cwd).trim();
    rel = relative(root, resolve(cwd, allowlistPath));
  } catch {
    return null;
  }
  if (rel.startsWith("..")) return null;
  try {
    return parseAllowlist(git(["show", `${base}:${rel}`], cwd));
  } catch {
    return null;
  }
}

export function checkFiles(files, allowlist, baseEntries = null) {
  const offending = [];
  const ratcheted = [];
  const stats = [];
  const dirty = new Set();
  for (const file of files) {
    const text = readFileSync(file, "utf8");
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
  return git(["ls-files", "*.zig", "*.ts"])
    .split("\n")
    .map((f) => f.trim())
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
    const result = checkFiles(files, allowlist, baseAllowlistEntries(allowlistPath, process.cwd(), baseRev));
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
    const text = readFileSync(file, "utf8");
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
