//! Preprocessor that adapts LaTeX math spans (`$...$`, `$$...$$`) and
//! Mermaid fenced code blocks for terminal rendering by ZigZag's markdown
//! renderer.
//!
//! The downstream renderer has no math or diagram support, so we rewrite the
//! raw assistant text before it runs:
//!
//! - Block math (`$$...$$`) is replaced with a short Unicode rendering of the
//!   math, wrapped as a Markdown blockquote so it gets visually offset.
//! - Inline math (`$...$`) is replaced with the Unicode rendering inline.
//! - Mermaid fenced blocks (```mermaid ... ```) are replaced with a labeled
//!   summary line plus the raw diagram source as a blockquote.
//!
//! Unknown LaTeX commands fall back to their raw form (with the leading
//! backslash preserved) so nothing is silently dropped. The conversion is
//! intentionally lightweight — no external math engine, no unicode table
//! beyond a curated symbol map.

const std = @import("std");

/// Public entry point. Returns an allocator-owned copy of `source` with
/// math spans and Mermaid blocks rewritten. The caller owns the returned
/// slice.
pub fn preprocess(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len == 0) return allocator.dupe(u8, source);

    // Pass 1: replace ```mermaid ... ``` blocks. Doing this first avoids any
    // accidental `$`/math interaction with diagram source.
    const after_mermaid = try replaceMermaidBlocks(allocator, source);
    defer allocator.free(after_mermaid);

    // Pass 2: replace $$...$$ block math. Done before inline math so the `$$`
    // sentinel doesn't get mis-parsed as two adjacent `$...$` spans.
    const after_block = try replaceBlockMath(allocator, after_mermaid);
    defer allocator.free(after_block);

    // Pass 3: replace $...$ inline math.
    return replaceInlineMath(allocator, after_block);
}

// ---------------------------------------------------------------------------
// Mermaid
// ---------------------------------------------------------------------------

const mermaid_fence = "```";
const mermaid_lang = "mermaid";

/// Replace each ```mermaid ... ``` block with a labeled summary plus the raw
/// source as a Markdown blockquote. If the closing fence is missing we emit
/// the label only and pass the remainder through verbatim.
fn replaceMermaidBlocks(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    var cursor: usize = 0;
    while (cursor < source.len) {
        const fence_pos = std.mem.indexOfPos(u8, source, cursor, mermaid_fence) orelse {
            try writer.writeAll(source[cursor..]);
            break;
        };

        // Scan the language tag immediately after the fence.
        const tag_start = fence_pos + mermaid_fence.len;
        const line_end = std.mem.indexOfScalarPos(u8, source, tag_start, '\n') orelse source.len;
        const tag = std.mem.trim(u8, source[tag_start..line_end], " \t\r");

        if (!std.mem.eql(u8, tag, mermaid_lang)) {
            // Not a mermaid block — copy through the fence line and keep
            // scanning from after it so nested non-mermaid blocks are
            // unaffected. Use min to stay in bounds when the fence runs to
            // end-of-input without a trailing newline.
            const advance = @min(line_end + 1, source.len);
            try writer.writeAll(source[cursor..advance]);
            cursor = advance;
            continue;
        }

        // Find the closing fence.
        const body_start = if (line_end < source.len) line_end + 1 else source.len;
        const close_pos = findMermaidClose(source, body_start);

        // Emit any plain text leading up to the fence verbatim.
        try writer.writeAll(source[cursor..fence_pos]);

        const body_end = close_pos orelse source.len;
        const body = source[body_start..body_end];
        const diagram_type = detectMermaidType(body);

        // Header line: bold "Mermaid diagram: <type>" — bold survives the
        // downstream markdown pass and clearly delineates the diagram region.
        if (diagram_type.len > 0) {
            try writer.print("**Mermaid diagram: {s}**\n\n", .{diagram_type});
        } else {
            try writer.writeAll("**Mermaid diagram**\n\n");
        }

        // Raw source as a blockquote so the markdown renderer offsets it from
        // surrounding prose. Skip blank trailing lines to avoid empty quote
        // lines.
        try writeQuotedLines(writer, body);

        if (close_pos) |cp| {
            // Skip past the closing fence line.
            const after_close = std.mem.indexOfScalarPos(u8, source, cp, '\n');
            cursor = if (after_close) |ac| ac + 1 else source.len;
        } else {
            cursor = source.len;
        }
    }

    return out.toOwnedSlice();
}

/// Locate the closing ``` for a mermaid block starting at `body_start`.
/// Returns the absolute index of the closing fence or null if none is found.
fn findMermaidClose(source: []const u8, body_start: usize) ?usize {
    var i: usize = body_start;
    while (i < source.len) {
        if (source[i] == '`') {
            // Only treat lines whose first non-space content is ``` as the
            // closing fence — indented triple backticks inside a diagram are
            // part of the diagram source.
            const line_start = lineStartBefore(source, i);
            const prefix = source[line_start..i];
            const all_space = std.mem.allEqual(u8, prefix, ' ') or prefix.len == 0;
            if (all_space and i + 3 <= source.len and std.mem.eql(u8, source[i .. i + 3], mermaid_fence)) {
                return i;
            }
        }
        i += 1;
    }
    return null;
}

fn lineStartBefore(source: []const u8, pos: usize) usize {
    var i: usize = pos;
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

/// Inspect the first non-blank line of a Mermaid block to classify the
/// diagram type (flowchart, sequenceDiagram, etc.). Returns an empty string
/// when no recognized type is found.
fn detectMermaidType(body: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        // Take the first whitespace-separated token. Mermaid's grammar uses
        // a fixed keyword (flowchart, graph, sequenceDiagram, ...) here.
        var tok_end: usize = 0;
        while (tok_end < line.len and !std.ascii.isWhitespace(line[tok_end])) tok_end += 1;
        const tok = line[0..tok_end];
        if (tok.len == 0) continue;

        // Normalize graph vs flowchart — both render flowcharts; preserve
        // the user's wording otherwise.
        if (std.ascii.eqlIgnoreCase(tok, "graph") or std.ascii.eqlIgnoreCase(tok, "flowchart") or std.ascii.eqlIgnoreCase(tok, "flowChart")) return "flowchart";
        if (std.ascii.eqlIgnoreCase(tok, "sequenceDiagram")) return "sequence";
        if (std.ascii.eqlIgnoreCase(tok, "classDiagram")) return "class";
        if (std.ascii.eqlIgnoreCase(tok, "stateDiagram") or std.ascii.eqlIgnoreCase(tok, "stateDiagram-v2")) return "state";
        if (std.ascii.eqlIgnoreCase(tok, "erDiagram")) return "er";
        if (std.ascii.eqlIgnoreCase(tok, "gantt")) return "gantt";
        if (std.ascii.eqlIgnoreCase(tok, "pie")) return "pie";
        if (std.ascii.eqlIgnoreCase(tok, "journey")) return "journey";
        if (std.ascii.eqlIgnoreCase(tok, "gitGraph")) return "git";
        return tok;
    }
    return "";
}

fn writeQuotedLines(writer: *std.Io.Writer, body: []const u8) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    var wrote_any = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        // Skip blank lines so the quote stays tight.
        if (line.len == 0) continue;
        if (wrote_any) try writer.writeByte('\n');
        try writer.writeAll("> ");
        try writer.writeAll(line);
        wrote_any = true;
    }
    if (!wrote_any) {
        // Empty body — emit a single placeholder line so the section still
        // reads as a diagram block.
        try writer.writeAll("> (empty)");
    }
}

// ---------------------------------------------------------------------------
// Math
// ---------------------------------------------------------------------------

/// Replace `$$...$$` blocks. The closing `$$` may appear on the same line
/// or on a later line; both forms are supported. An unterminated `$$` is
/// passed through verbatim.
fn replaceBlockMath(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    var cursor: usize = 0;
    while (cursor < source.len) {
        const open = std.mem.indexOfPos(u8, source, cursor, "$$") orelse {
            try writer.writeAll(source[cursor..]);
            break;
        };
        // `$$$` is ambiguous — treat as not-a-block so we don't swallow the
        // third `$` from inline math like `$$$x$$`. Require the char after
        // the opening pair to not be another `$`.
        if (open + 2 < source.len and source[open + 2] == '$') {
            try writer.writeAll(source[cursor .. open + 1]);
            cursor = open + 1;
            continue;
        }

        const body_start = open + 2;
        const close = std.mem.indexOfPos(u8, source, body_start, "$$");

        try writer.writeAll(source[cursor..open]);

        if (close) |cp| {
            const body = source[body_start..cp];
            try writeBlockMath(allocator, writer, body);
            cursor = cp + 2;
        } else {
            // Unterminated — render what's left as a block and stop.
            const body = source[body_start..];
            try writeBlockMath(allocator, writer, body);
            cursor = source.len;
        }
    }

    return out.toOwnedSlice();
}

fn writeBlockMath(allocator: std.mem.Allocator, writer: *std.Io.Writer, body: []const u8) !void {
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try renderMathBody(&rendered.writer, body);

    // Emit as a Markdown blockquote — one quote line per source line, with
    // blank lines collapsed. This visually sets math apart from prose and
    // survives the downstream markdown pass cleanly.
    var lines = std.mem.splitScalar(u8, rendered.written(), '\n');
    var wrote_any = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (wrote_any) try writer.writeByte('\n');
        try writer.writeAll("> ");
        try writer.writeAll(line);
        wrote_any = true;
    }
    if (!wrote_any) try writer.writeAll("> ");
}

/// Replace inline `$...$` spans. Refuses to match if the opening `$` is
/// preceded by a non-space char or if the body contains a newline — both
/// are common false-positive sources (currency, "5$ for x" etc.).
fn replaceInlineMath(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    var cursor: usize = 0;
    while (cursor < source.len) {
        if (source[cursor] != '$') {
            try writer.writeByte(source[cursor]);
            cursor += 1;
            continue;
        }
        // Reject opening preceded by a non-space, non-start byte (e.g. "5$").
        if (cursor > 0) {
            const prev = source[cursor - 1];
            if (prev != ' ' and prev != '\t' and prev != '\n' and prev != '(' and prev != '[') {
                try writer.writeByte(source[cursor]);
                cursor += 1;
                continue;
            }
        }
        // Reject opening with no body or body starting with space.
        if (cursor + 1 >= source.len or source[cursor + 1] == ' ' or source[cursor + 1] == '$') {
            try writer.writeByte(source[cursor]);
            cursor += 1;
            continue;
        }

        const body_start = cursor + 1;
        const close = std.mem.indexOfScalarPos(u8, source, body_start, '$');
        if (close == null) {
            try writer.writeByte(source[cursor]);
            cursor += 1;
            continue;
        }
        const cp = close.?;
        // Closing `$` must not be preceded by whitespace and must not be
        // followed by another `$` (which would be a different block math
        // boundary handled elsewhere).
        if (source[cp - 1] == ' ' or (cp + 1 < source.len and source[cp + 1] == '$')) {
            try writer.writeByte(source[cursor]);
            cursor += 1;
            continue;
        }
        const body = source[body_start..cp];
        // Reject newlines — inline math is a single line.
        if (std.mem.indexOfScalar(u8, body, '\n') != null) {
            try writer.writeByte(source[cursor]);
            cursor += 1;
            continue;
        }

        try renderMathBody(writer, body);
        cursor = cp + 1;
    }

    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// LaTeX → Unicode
// ---------------------------------------------------------------------------

/// Render a math body to `writer`. Walks the source, substituting recognized
/// LaTeX commands and a small set of superscript/subscript forms. Anything
/// unknown is emitted verbatim (with the backslash preserved) so the
/// rendered output remains useful as a fallback.
fn renderMathBody(writer: *std.Io.Writer, body: []const u8) anyerror!void {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];

        if (c == '\\') {
            // Read command name: letters, optionally followed by a single
            // non-letter for one-char commands like `\,` `\;` etc.
            var j = i + 1;
            while (j < body.len and std.ascii.isAlphabetic(body[j])) j += 1;
            if (j == i + 1 and j < body.len) {
                // Single non-letter command — handle the common spacing ones.
                const next = body[j];
                if (next == ',') {
                    try writer.writeAll(" ");
                    i = j + 1;
                    continue;
                }
                if (next == ';' or next == ':' or next == '!') {
                    i = j + 1;
                    continue;
                }
                if (next == '\\') {
                    try writer.writeByte('\n');
                    i = j + 1;
                    continue;
                }
                // Unknown single-char command: emit backslash and the char.
                try writer.writeByte('\\');
                try writer.writeByte(next);
                i = j + 1;
                continue;
            }

            const name = body[i + 1 .. j];

            // Multi-argument commands need special handling so their operands
            // land in the right order.
            if (std.mem.eql(u8, name, "frac")) {
                i = try writeFrac(writer, body, j);
                continue;
            }
            if (std.mem.eql(u8, name, "sqrt")) {
                i = try writeSqrt(writer, body, j);
                continue;
            }

            if (lookupCommand(name)) |sym| {
                try writer.writeAll(sym);
            } else {
                // Unknown command — emit raw so it stays visible as a fallback.
                try writer.writeByte('\\');
                try writer.writeAll(name);
            }
            i = j;
            continue;
        }

        if (c == '^' or c == '_') {
            // Superscript / subscript. If the next char is `{`, read until
            // `}`; otherwise consume a single char. Render with Unicode
            // superscripts when possible; otherwise emit `^x` / `_x` as
            // plain-text fallback (still readable, no semantic loss).
            try writeScript(writer, body, &i);
            continue;
        }

        if (c == '{' or c == '}') {
            // Grouping braces have no visible meaning in plain Unicode math.
            i += 1;
            continue;
        }

        if (c == '\n') {
            try writer.writeByte('\n');
            i += 1;
            continue;
        }

        try writer.writeByte(c);
        i += 1;
    }
}

fn writeScript(writer: *std.Io.Writer, body: []const u8, i: *usize) !void {
    const marker = body[i.*];
    i.* += 1;
    if (i.* >= body.len) {
        try writer.writeByte(marker);
        return;
    }

    var token_start = i.*;
    var token_end: usize = undefined;
    if (body[i.*] == '{') {
        token_start = i.* + 1;
        const close = std.mem.indexOfScalarPos(u8, body, token_start, '}') orelse {
            // No closing brace — emit marker + rest verbatim.
            try writer.writeByte(marker);
            try writer.writeAll(body[i.*..]);
            i.* = body.len;
            return;
        };
        token_end = close;
        i.* = close + 1;
    } else {
        // Only consume a single ASCII alphanumeric or operator punctuation as
        // the script token. Anything else (notably `\`, which starts a LaTeX
        // command) is left in place for normal processing so `^\infty`
        // becomes `^` + `∞` rather than swallowing the backslash.
        const c = body[i.*];
        if (isScriptTokenChar(c)) {
            token_start = i.*;
            token_end = i.* + 1;
            i.* += 1;
        } else {
            // Bare marker with no consumable token — emit and let the
            // following char process normally.
            try writer.writeByte(marker);
            return;
        }
    }

    const token = body[token_start..token_end];
    if (marker == '^') {
        if (writeSuperscript(writer, token)) return;
        try writer.print("^{s}", .{token});
    } else {
        if (writeSubscript(writer, token)) return;
        try writer.print("_{s}", .{token});
    }
}

fn isScriptTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '=' or c == '(' or c == ')';
}

/// Render `\frac{A}{B}` as `(A)/(B)`. Returns the new cursor position past
/// both groups. If the next non-whitespace tokens aren't brace groups, emit
/// the operands inline as a graceful fallback.
fn writeFrac(writer: *std.Io.Writer, body: []const u8, start: usize) anyerror!usize {
    var i = skipSpace(body, start);
    const a_group = readGroup(body, i);
    if (a_group) |g| i = g.end;
    i = skipSpace(body, i);
    const b_group = readGroup(body, i);
    if (b_group) |g| i = g.end;

    if (a_group != null and b_group != null) {
        try writer.writeByte('(');
        try renderMathBody(writer, a_group.?.inner);
        try writer.writeAll(")/(");
        try renderMathBody(writer, b_group.?.inner);
        try writer.writeByte(')');
        return i;
    }
    // Fallback: emit literal so the user sees the source structure.
    try writer.writeAll("\\frac");
    return start;
}

/// Render `\sqrt{X}` as `√X` (with braces stripped). If there's no brace
/// group, emit `√` alone and let single-char scripts apply normally
/// (e.g. `\sqrt2` → `√2` via the regular code path).
fn writeSqrt(writer: *std.Io.Writer, body: []const u8, start: usize) anyerror!usize {
    const i = skipSpace(body, start);
    const g = readGroup(body, i);
    if (g) |grp| {
        try writer.writeAll("√");
        try renderMathBody(writer, grp.inner);
        return grp.end;
    }
    try writer.writeAll("√");
    return start;
}

fn skipSpace(body: []const u8, i: usize) usize {
    var j = i;
    while (j < body.len and (body[j] == ' ' or body[j] == '\t')) j += 1;
    return j;
}

const BraceGroup = struct {
    inner: []const u8,
    end: usize,
};

/// Read a `{...}` group starting at `i` (after skipping leading spaces).
/// Returns null if `i` doesn't point at a `{`. Does not handle nested
/// braces — math operands rarely nest, and raw fallback preserves the
/// source when they do.
fn readGroup(body: []const u8, i: usize) ?BraceGroup {
    if (i >= body.len or body[i] != '{') return null;
    var depth: usize = 1;
    var j = i + 1;
    while (j < body.len) : (j += 1) {
        if (body[j] == '{') depth += 1;
        if (body[j] == '}') {
            depth -= 1;
            if (depth == 0) return .{ .inner = body[i + 1 .. j], .end = j + 1 };
        }
    }
    return null;
}

/// Emit a Unicode superscript for single-character tokens that have a
/// dedicated superscript codepoint. Returns true if handled.
fn writeSuperscript(writer: *std.Io.Writer, token: []const u8) bool {
    const out: []const u8 = blk: {
        if (token.len == 1) {
            break :blk superscriptFor(token[0]) orelse "";
        }
        if (eqlCaseInsensitive(token, "th")) break :blk "ᵗʰ";
        if (eqlCaseInsensitive(token, "nd")) break :blk "ⁿᵈ";
        if (eqlCaseInsensitive(token, "rd")) break :blk "ʳᵈ";
        if (eqlCaseInsensitive(token, "st")) break :blk "ˢᵗ";
        break :blk "";
    };
    if (out.len == 0) return false;
    writer.writeAll(out) catch return false;
    return true;
}

fn writeSubscript(writer: *std.Io.Writer, token: []const u8) bool {
    const out: []const u8 = blk: {
        if (token.len == 1) {
            break :blk subscriptFor(token[0]) orelse "";
        }
        break :blk "";
    };
    if (out.len == 0) return false;
    writer.writeAll(out) catch return false;
    return true;
}

fn superscriptFor(c: u8) ?[]const u8 {
    return switch (c) {
        '0' => "⁰",
        '1' => "¹",
        '2' => "²",
        '3' => "³",
        '4' => "⁴",
        '5' => "⁵",
        '6' => "⁶",
        '7' => "⁷",
        '8' => "⁸",
        '9' => "⁹",
        '+' => "⁺",
        '-' => "⁻",
        '=' => "⁼",
        '(' => "⁽",
        ')' => "⁾",
        'n' => "ⁿ",
        'i' => "ⁱ",
        else => null,
    };
}

fn subscriptFor(c: u8) ?[]const u8 {
    return switch (c) {
        '0' => "₀",
        '1' => "₁",
        '2' => "₂",
        '3' => "₃",
        '4' => "₄",
        '5' => "₅",
        '6' => "₆",
        '7' => "₇",
        '8' => "₈",
        '9' => "₉",
        '+' => "₊",
        '-' => "₋",
        '=' => "₌",
        '(' => "₍",
        ')' => "₎",
        'a' => "ₐ",
        'e' => "ₑ",
        'i' => "ᵢ",
        'o' => "ₒ",
        'x' => "ₓ",
        'h' => "ₕ",
        'k' => "ₖ",
        'l' => "ₗ",
        'm' => "ₘ",
        'n' => "ₙ",
        'p' => "ₚ",
        's' => "ₛ",
        't' => "ₜ",
        else => null,
    };
}

fn eqlCaseInsensitive(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Curated LaTeX → Unicode symbol table. Covers common Greek letters and
/// operators. Returns null for unknown commands so callers can fall back.
fn lookupCommand(name: []const u8) ?[]const u8 {
    const map = struct {
        const entries = [_]struct { name: []const u8, sym: []const u8 }{
            // Greek lowercase
            .{ .name = "alpha", .sym = "α" },
            .{ .name = "beta", .sym = "β" },
            .{ .name = "gamma", .sym = "γ" },
            .{ .name = "delta", .sym = "δ" },
            .{ .name = "epsilon", .sym = "ε" },
            .{ .name = "varepsilon", .sym = "ε" },
            .{ .name = "zeta", .sym = "ζ" },
            .{ .name = "eta", .sym = "η" },
            .{ .name = "theta", .sym = "θ" },
            .{ .name = "vartheta", .sym = "ϑ" },
            .{ .name = "iota", .sym = "ι" },
            .{ .name = "kappa", .sym = "κ" },
            .{ .name = "lambda", .sym = "λ" },
            .{ .name = "mu", .sym = "μ" },
            .{ .name = "nu", .sym = "ν" },
            .{ .name = "xi", .sym = "ξ" },
            .{ .name = "omicron", .sym = "ο" },
            .{ .name = "pi", .sym = "π" },
            .{ .name = "varpi", .sym = "ϖ" },
            .{ .name = "rho", .sym = "ρ" },
            .{ .name = "varrho", .sym = "ϱ" },
            .{ .name = "sigma", .sym = "σ" },
            .{ .name = "varsigma", .sym = "ς" },
            .{ .name = "tau", .sym = "τ" },
            .{ .name = "upsilon", .sym = "υ" },
            .{ .name = "phi", .sym = "φ" },
            .{ .name = "varphi", .sym = "ϕ" },
            .{ .name = "chi", .sym = "χ" },
            .{ .name = "psi", .sym = "ψ" },
            .{ .name = "omega", .sym = "ω" },
            // Greek uppercase
            .{ .name = "Alpha", .sym = "Α" },
            .{ .name = "Beta", .sym = "Β" },
            .{ .name = "Gamma", .sym = "Γ" },
            .{ .name = "Delta", .sym = "Δ" },
            .{ .name = "Epsilon", .sym = "Ε" },
            .{ .name = "Zeta", .sym = "Ζ" },
            .{ .name = "Eta", .sym = "Η" },
            .{ .name = "Theta", .sym = "Θ" },
            .{ .name = "Iota", .sym = "Ι" },
            .{ .name = "Kappa", .sym = "Κ" },
            .{ .name = "Lambda", .sym = "Λ" },
            .{ .name = "Mu", .sym = "Μ" },
            .{ .name = "Nu", .sym = "Ν" },
            .{ .name = "Xi", .sym = "Ξ" },
            .{ .name = "Omicron", .sym = "Ο" },
            .{ .name = "Pi", .sym = "Π" },
            .{ .name = "Rho", .sym = "Ρ" },
            .{ .name = "Sigma", .sym = "Σ" },
            .{ .name = "Tau", .sym = "Τ" },
            .{ .name = "Upsilon", .sym = "Υ" },
            .{ .name = "Phi", .sym = "Φ" },
            .{ .name = "Chi", .sym = "Χ" },
            .{ .name = "Psi", .sym = "Ψ" },
            .{ .name = "Omega", .sym = "Ω" },
            // Operators / relations
            .{ .name = "sum", .sym = "∑" },
            .{ .name = "prod", .sym = "∏" },
            .{ .name = "coprod", .sym = "∐" },
            .{ .name = "int", .sym = "∫" },
            .{ .name = "oint", .sym = "∮" },
            .{ .name = "iint", .sym = "∬" },
            .{ .name = "iiint", .sym = "∭" },
            .{ .name = "cbrt", .sym = "∛" },
            .{ .name = "cdot", .sym = "·" },
            .{ .name = "cdots", .sym = "⋯" },
            .{ .name = "ldots", .sym = "…" },
            .{ .name = "vdots", .sym = "⋮" },
            .{ .name = "ddots", .sym = "⋱" },
            .{ .name = "times", .sym = "×" },
            .{ .name = "div", .sym = "÷" },
            .{ .name = "pm", .sym = "±" },
            .{ .name = "mp", .sym = "∓" },
            .{ .name = "ast", .sym = "∗" },
            .{ .name = "star", .sym = "⋆" },
            .{ .name = "circ", .sym = "∘" },
            .{ .name = "bullet", .sym = "•" },
            .{ .name = "leq", .sym = "≤" },
            .{ .name = "le", .sym = "≤" },
            .{ .name = "geq", .sym = "≥" },
            .{ .name = "ge", .sym = "≥" },
            .{ .name = "neq", .sym = "≠" },
            .{ .name = "ne", .sym = "≠" },
            .{ .name = "approx", .sym = "≈" },
            .{ .name = "equiv", .sym = "≡" },
            .{ .name = "sim", .sym = "∼" },
            .{ .name = "simeq", .sym = "≅" },
            .{ .name = "cong", .sym = "≅" },
            .{ .name = "propto", .sym = "∝" },
            .{ .name = "in", .sym = "∈" },
            .{ .name = "notin", .sym = "∉" },
            .{ .name = "ni", .sym = "∋" },
            .{ .name = "subset", .sym = "⊂" },
            .{ .name = "supset", .sym = "⊃" },
            .{ .name = "subseteq", .sym = "⊆" },
            .{ .name = "supseteq", .sym = "⊇" },
            .{ .name = "cup", .sym = "∪" },
            .{ .name = "cap", .sym = "∩" },
            .{ .name = "emptyset", .sym = "∅" },
            .{ .name = "varnothing", .sym = "∅" },
            .{ .name = "forall", .sym = "∀" },
            .{ .name = "exists", .sym = "∃" },
            .{ .name = "nexists", .sym = "∄" },
            .{ .name = "neg", .sym = "¬" },
            .{ .name = "lnot", .sym = "¬" },
            .{ .name = "land", .sym = "∧" },
            .{ .name = "lor", .sym = "∨" },
            .{ .name = "Rightarrow", .sym = "⇒" },
            .{ .name = "Leftarrow", .sym = "⇐" },
            .{ .name = "Leftrightarrow", .sym = "⇔" },
            .{ .name = "rightarrow", .sym = "→" },
            .{ .name = "to", .sym = "→" },
            .{ .name = "gets", .sym = "←" },
            .{ .name = "leftarrow", .sym = "←" },
            .{ .name = "leftrightarrow", .sym = "↔" },
            .{ .name = "mapsto", .sym = "↦" },
            .{ .name = "uparrow", .sym = "↑" },
            .{ .name = "downarrow", .sym = "↓" },
            .{ .name = "updownarrow", .sym = "↕" },
            .{ .name = "infty", .sym = "∞" },
            .{ .name = "partial", .sym = "∂" },
            .{ .name = "nabla", .sym = "∇" },
            .{ .name = "hbar", .sym = "ℏ" },
            .{ .name = "ell", .sym = "ℓ" },
            .{ .name = "Re", .sym = "ℜ" },
            .{ .name = "Im", .sym = "ℑ" },
            .{ .name = "aleph", .sym = "ℵ" },
            .{ .name = "angle", .sym = "∠" },
            .{ .name = "perp", .sym = "⊥" },
            .{ .name = "parallel", .sym = "∥" },
            .{ .name = "triangle", .sym = "△" },
            .{ .name = "square", .sym = "□" },
            .{ .name = "diamond", .sym = "◇" },
            .{ .name = "oplus", .sym = "⊕" },
            .{ .name = "ominus", .sym = "⊖" },
            .{ .name = "otimes", .sym = "⊗" },
            .{ .name = "oslash", .sym = "⊘" },
            .{ .name = "odot", .sym = "⊙" },
            .{ .name = "wr", .sym = "≀" },
            .{ .name = "dagger", .sym = "†" },
            .{ .name = "ddagger", .sym = "‡" },
            .{ .name = "degree", .sym = "°" },
            .{ .name = "prime", .sym = "′" },
            .{ .name = "dprime", .sym = "″" },
            // Style modifiers — silently dropped (no semantic loss in plain text).
            .{ .name = "mathrm", .sym = "" },
            .{ .name = "mathit", .sym = "" },
            .{ .name = "mathbf", .sym = "" },
            .{ .name = "mathsf", .sym = "" },
            .{ .name = "mathtt", .sym = "" },
            .{ .name = "mathcal", .sym = "" },
            .{ .name = "mathbb", .sym = "" },
            .{ .name = "displaystyle", .sym = "" },
            .{ .name = "textstyle", .sym = "" },
            .{ .name = "scriptstyle", .sym = "" },
            .{ .name = "text", .sym = "" },
            .{ .name = "operatorname", .sym = "" },
            .{ .name = "left", .sym = "" },
            .{ .name = "right", .sym = "" },
            .{ .name = "big", .sym = "" },
            .{ .name = "Big", .sym = "" },
            .{ .name = "bigg", .sym = "" },
            .{ .name = "Bigg", .sym = "" },
            .{ .name = "bigl", .sym = "" },
            .{ .name = "bigr", .sym = "" },
            .{ .name = "Bigl", .sym = "" },
            .{ .name = "Bigr", .sym = "" },
        };
    };

    // Linear scan is fine: the table is small and lookup happens once per
    // command occurrence in a chat message.
    for (map.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            if (entry.sym.len == 0) return "";
            return entry.sym;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "preprocess returns input unchanged when no math or mermaid present" {
    const src = "hello world\n# Heading";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "preprocess handles empty input" {
    const out = try preprocess(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "inline math substitutes Greek letters" {
    const src = "angle $\\alpha + \\beta$ equals gamma";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "α + β") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\alpha") == null);
    // Surrounding prose survives.
    try std.testing.expect(std.mem.indexOf(u8, out, "angle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "equals gamma") != null);
}

test "inline math renders superscripts with Unicode" {
    const src = "energy $E = mc^2$ is famous";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "E = mc²") != null);
}

test "inline math falls back to caret form for unsupported superscript" {
    const src = "value $x^q$ here";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "x^q") != null);
}

test "block math on same line renders as blockquote" {
    const src = "intro\n\n$$\\int_0^\\infty f(x)\\,dx$$\n\nafter";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "> ∫") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "₀") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "∞") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$$") == null);
}

test "multi-line block math collapses to quoted lines" {
    const src = "$$\n\\sum_{i=1}^n x_i\n$$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "> ∑") != null);
    // `^n` becomes Unicode superscript n; `_{i=1}` has no single-char form
    // so it stays as the literal `_{i=1}` fallback.
    try std.testing.expect(std.mem.indexOf(u8, out, "ⁿ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "xᵢ") != null);
}

test "inline math ignores dollar signs used as currency" {
    const src = "costs $5 and $10 each";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // No transform should occur — currency stays as-is.
    try std.testing.expectEqualStrings(src, out);
}

test "unterminated block math falls back gracefully" {
    const src = "text $$\\alpha no closer";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "α") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$$") == null);
}

test "unknown LaTeX command falls back to raw with backslash" {
    const src = "weird $\\zzzx$ here";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\zzzx") != null);
}

test "mermaid block replaced with labeled summary" {
    const src = "intro\n\n```mermaid\nflowchart TD\n  A --> B\n```\n\noutro";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "**Mermaid diagram: flowchart**") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "> flowchart TD") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "> A --> B") != null);
    // Raw fence must be gone — copy behavior relies on raw text being inside
    // the quoted section, but the fence delimiters themselves are stripped.
    try std.testing.expect(std.mem.indexOf(u8, out, "```mermaid") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "intro") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "outro") != null);
}

test "mermaid sequenceDiagram type classified correctly" {
    const src = "```mermaid\nsequenceDiagram\n  Alice->>Bob: Hi\n```";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "**Mermaid diagram: sequence**") != null);
}

test "mermaid block without closing fence still labels" {
    const src = "```mermaid\nflowchart TD\n  A --> B";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "**Mermaid diagram: flowchart**") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "> flowchart TD") != null);
}

test "non-mermaid fenced code block is left untouched" {
    const src = "```zig\nconst x = 1;\n```";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "fraction command keeps operands visible" {
    const src = "ratio $\\frac{a}{b}$ shows";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // \frac{a}{b} renders as (a)/(b) so both operands and the slash survive.
    try std.testing.expect(std.mem.indexOf(u8, out, "(a)/(b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\frac") == null);
}

test "style modifiers are silently dropped" {
    const src = "math $\\mathrm{sin} + x$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "sin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\mathrm") == null);
}

test "sqrt emits radical sign" {
    const src = "root $\\sqrt{x+1}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "√x+1") != null);
}
