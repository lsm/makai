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
//! backslash preserved and any `{...}` argument left intact) so nothing is
//! silently dropped. The conversion is intentionally lightweight — no
//! external math engine, no unicode table beyond a curated symbol map.
//!
//! All three transformations run in a single source pass so that:
//! - the interior of any non-mermaid fenced code block is left untouched
//!   (including any literal ```` ```mermaid ```` lines it may contain, and
//!   any `$` shell variables / currency prose inside); and
//! - the blockquote emitted for a Mermaid block is not subsequently
//!   re-processed by the math pass (which would otherwise eat `$` labels in
//!   the diagram source).

const std = @import("std");

/// Public entry point. Returns an allocator-owned copy of `source` with
/// math spans and Mermaid blocks rewritten. The caller owns the returned
/// slice.
pub fn preprocess(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len == 0) return allocator.dupe(u8, source);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    var i: usize = 0;
    while (i < source.len) {
        // 1. Fenced code block opener at line start. Consumed whole: mermaid
        //    blocks are transformed in place, every other language is copied
        //    verbatim (including any literal ```mermaid lines or `$` chars
        //    inside). Emits directly to the writer so the math steps below
        //    never re-process the interior.
        if (isAtLineStart(source, i)) {
            if (try consumeFenceBlock(allocator, writer, source, &i)) continue;
        }

        // 2. Markdown inline links and bare URLs must stay raw. Protect their
        //    destinations before math checks so URLs like
        //    `/users/$user_id$` survive.
        if (source[i] == '[') {
            if (try consumeMarkdownLink(writer, source, &i)) continue;
        }
        if (isBareUrlPrefix(source, i)) {
            if (try consumeBareUrl(writer, source, &i)) continue;
        }

        // 3. Inline code spans must stay raw. Protect them before math checks
        //    so snippets like `echo $x$` remain copyable.
        if (source[i] == '`') {
            if (try consumeInlineCode(writer, source, &i)) continue;
        }

        // 4. Block math `$$...$$`. Checked before inline `$` so the leading
        //    `$$` isn't mis-parsed as two adjacent single-dollar spans.
        if (i + 1 < source.len and source[i] == '$' and source[i + 1] == '$') {
            if (try consumeBlockMath(allocator, writer, source, &i)) continue;
        }

        // 5. Inline math `$...$`.
        if (source[i] == '$') {
            if (try consumeInlineMath(writer, source, &i)) continue;
        }

        // 5. Plain byte.
        try writer.writeByte(source[i]);
        i += 1;
    }

    return out.toOwnedSlice();
}

fn isAtLineStart(source: []const u8, i: usize) bool {
    if (i == 0) return true;
    return source[i - 1] == '\n';
}

/// Consume an inline code span verbatim. Returns false for fenced code block
/// runs (handled by consumeFenceBlock) and unterminated spans so the default
/// byte path preserves source.
fn consumeInlineCode(writer: *std.Io.Writer, source: []const u8, i: *usize) !bool {
    const start = i.*;
    var tick_count: usize = 0;
    while (start + tick_count < source.len and source[start + tick_count] == '`') tick_count += 1;
    if (tick_count >= 3) return false;

    var scan = start + tick_count;
    while (scan < source.len) : (scan += 1) {
        if (source[scan] != '`') continue;
        var close_count: usize = 0;
        while (scan + close_count < source.len and source[scan + close_count] == '`') close_count += 1;
        if (close_count == tick_count) {
            try writer.writeAll(source[start .. scan + close_count]);
            i.* = scan + close_count;
            return true;
        }
        scan += close_count - 1;
    }
    return false;
}

/// Consume a Markdown inline link `[text](url)` verbatim. Returns false when
/// the bytes at `*i` don't form a complete link so the default byte path
/// preserves the source. Link destinations may contain `$` chars that must not
/// be interpreted as inline math, so the whole link is copied unchanged.
fn consumeMarkdownLink(writer: *std.Io.Writer, source: []const u8, i: *usize) !bool {
    const start = i.*;
    if (start >= source.len or source[start] != '[') return false;

    // Find the matching `]` for link text, respecting nested brackets and
    // escaped brackets (e.g. `\]`).
    var text_end = start + 1;
    var bracket_depth: usize = 1;
    while (text_end < source.len) {
        const c = source[text_end];
        if (c == '\\' and text_end + 1 < source.len) {
            text_end += 2;
            continue;
        }
        if (c == '[') bracket_depth += 1;
        if (c == ']') {
            bracket_depth -= 1;
            if (bracket_depth == 0) break;
        }
        text_end += 1;
    }
    if (bracket_depth != 0 or text_end >= source.len) return false;

    // Inline links are followed by `(`; reference-style `[text][ref]` is left
    // for the default path (it has no URL destination to protect).
    const url_start = text_end + 1;
    if (url_start >= source.len or source[url_start] != '(') return false;

    // Find the matching `)` for the URL, respecting balanced nested parens and
    // escaped parens.
    var url_end = url_start + 1;
    var paren_depth: usize = 1;
    while (url_end < source.len) {
        const c = source[url_end];
        if (c == '\\' and url_end + 1 < source.len) {
            url_end += 2;
            continue;
        }
        if (c == '(') paren_depth += 1;
        if (c == ')') {
            paren_depth -= 1;
            if (paren_depth == 0) break;
        }
        url_end += 1;
    }
    if (paren_depth != 0 or url_end >= source.len) return false;

    try writer.writeAll(source[start .. url_end + 1]);
    i.* = url_end + 1;
    return true;
}

/// Returns true when `source[i..]` begins with a common bare URL scheme
/// (`http://` or `https://`).
fn isBareUrlPrefix(source: []const u8, i: usize) bool {
    if (i + 7 <= source.len and std.ascii.eqlIgnoreCase(source[i .. i + 7], "http://")) return true;
    if (i + 8 <= source.len and std.ascii.eqlIgnoreCase(source[i .. i + 8], "https://")) return true;
    return false;
}

/// Consume a bare URL (`http://...` or `https://...`) verbatim. Returns false
/// when `*i` is not at a URL prefix so the default path preserves the source.
fn consumeBareUrl(writer: *std.Io.Writer, source: []const u8, i: *usize) !bool {
    if (!isBareUrlPrefix(source, i.*)) return false;
    const start = i.*;
    var end = start;
    while (end < source.len) {
        const c = source[end];
        // Stop at whitespace or common delimiters that terminate URLs in prose.
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '<' or c == '>') break;
        end += 1;
    }
    try writer.writeAll(source[start..end]);
    i.* = end;
    return true;
}

// ---------------------------------------------------------------------------
// Fence + mermaid
// ---------------------------------------------------------------------------

const mermaid_lang = "mermaid";

/// If `source[i..]` opens a fenced code block at line start (optionally
/// indented), consume the whole block in place:
///
/// - mermaid blocks become the labeled summary + quoted source;
/// - any other language is copied verbatim, including any literal
///   ```` ```mermaid ```` lines or `$` chars inside.
///
/// Updates `*i` past the consumed block and returns true. Returns false
/// (without modifying `*i`) if `i` is not at a fence opener.
///
/// Supports CommonMark-style long fences (4+ backticks) so a block opened
/// with ```` ```` ```` is only closed by a line whose leading backtick run
/// is at least as long — this lets users embed ``` ```` ``` fences inside
/// without breaking the outer block.
fn consumeFenceBlock(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, i: *usize) !bool {
    const start = i.*;
    // Allow leading space indentation (a line of spaces followed by ```).
    var indent_end = start;
    while (indent_end < source.len and source[indent_end] == ' ') indent_end += 1;
    if (indent_end >= source.len or source[indent_end] != '`') return false;

    // Count the opening backtick run. CommonMark requires >=3 to open a
    // fence; we accept any length and require a closer with at least as
    // many backticks so users can use ```` to wrap content containing ```.
    var fence_len: usize = 0;
    while (indent_end + fence_len < source.len and source[indent_end + fence_len] == '`') fence_len += 1;
    if (fence_len < 3) return false;

    // Lang tag occupies the rest of the opener line.
    const fence_end = indent_end + fence_len;
    const line_end = std.mem.indexOfScalarPos(u8, source, fence_end, '\n') orelse source.len;
    const tag = std.mem.trim(u8, source[fence_end..line_end], " \t\r");

    // Body starts on the line after the opener.
    const body_start = if (line_end < source.len) line_end + 1 else source.len;
    const close_line_start = findCodeBlockCloseLine(source, body_start, fence_len);
    const body_end = if (close_line_start) |cls| cls else source.len;
    const body = source[body_start..body_end];

    if (std.mem.eql(u8, tag, mermaid_lang)) {
        // Mermaid block — emit the label + quoted source directly to the
        // writer. The caller never sees these bytes again so a later math
        // step can't mutate the quoted diagram source.
        const diagram_type = detectMermaidType(body);
        if (diagram_type.len > 0) {
            try writer.print("**Mermaid diagram: {s}**\n\n", .{diagram_type});
        } else {
            try writer.writeAll("**Mermaid diagram**\n\n");
        }
        try writeQuotedLines(writer, body);
        // Trailing newline separates the mermaid region from whatever
        // follows; without it the next paragraph would concatenate onto
        // the last `> ...` line.
        try writer.writeByte('\n');
    } else {
        // Non-mermaid fenced code block — copy opener, body, and closer
        // verbatim so any literal ```mermaid lines or `$` shell vars inside
        // survive unchanged.
        try writer.writeAll(source[start..body_end]);
        if (close_line_start) |cls| {
            // Include the closer line together with its trailing newline so
            // the verbatim copy stays byte-identical with the source.
            const close_line_end = std.mem.indexOfScalarPos(u8, source, cls, '\n') orelse source.len;
            const emit_end = if (close_line_end < source.len) close_line_end + 1 else source.len;
            try writer.writeAll(source[cls..emit_end]);
            i.* = emit_end;
        } else {
            // Unterminated fence — copy through the trailing newline if any.
            i.* = body_end;
            if (body_end < source.len and source[body_end] == '\n') {
                try writer.writeByte('\n');
                i.* = body_end + 1;
            }
        }
        _ = allocator;
        return true;
    }

    // Mermaid path: advance past the closing fence line (or end of source
    // when unterminated).
    if (close_line_start) |cls| {
        const close_line_end = std.mem.indexOfScalarPos(u8, source, cls, '\n') orelse source.len;
        i.* = if (close_line_end < source.len) close_line_end + 1 else source.len;
    } else {
        i.* = source.len;
    }
    return true;
}

/// Locate the first line at or after `body_start` that closes a fenced
/// code block opened with `fence_len` backticks. A closing line is one
/// whose leading backtick run (after optional whitespace) is at least
/// `fence_len` ticks long and contains nothing else but whitespace.
///
/// Returns the absolute index of that closer line's first byte, or null if
/// none is found.
fn findCodeBlockCloseLine(source: []const u8, body_start: usize, fence_len: usize) ?usize {
    var i = body_start;
    while (i < source.len) {
        const line_start = i;
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = source[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (countLeadingBackticks(trimmed) >= fence_len) {
            // Reject lines that have non-tick content after the run, e.g.
            // an opener ```text. A valid closer is all backticks (possibly
            // followed by trailing whitespace, already trimmed off).
            if (std.mem.allEqual(u8, trimmed, '`')) return line_start;
        }
        i = if (line_end < source.len) line_end + 1 else source.len;
    }
    return null;
}

fn countLeadingBackticks(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == '`') n += 1;
    return n;
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

/// Quote each line of `body` for the markdown renderer. Trailing whitespace
/// and fully-blank lines are dropped, but **leading indentation is
/// preserved** — mindmap, state diagrams, and several other Mermaid types
/// rely on indentation as structural syntax, and the raw source must remain
/// copyable from the transcript.
fn writeQuotedLines(writer: *std.Io.Writer, body: []const u8) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    var wrote_any = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        // Skip lines that are entirely whitespace so the quote stays tight.
        if (std.mem.allEqual(u8, line, ' ') or line.len == 0) continue;
        if (wrote_any) try writer.writeByte('\n');
        try writer.writeAll("> ");
        // Preserve any leading indentation (e.g. mindmap nesting).
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

/// Returns true if `source[i]` is preceded by an odd number of consecutive
/// backslashes, i.e. it is LaTeX-escaped.
fn isEscaped(source: []const u8, i: usize) bool {
    if (i == 0) return false;
    var backslashes: usize = 0;
    var j = i;
    while (j > 0 and source[j - 1] == '\\') {
        backslashes += 1;
        j -= 1;
    }
    return backslashes % 2 == 1;
}

/// Find the next unescaped `$` at or after `start`.
fn findUnescapedDollar(source: []const u8, start: usize) ?usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        if (source[i] == '$' and !isEscaped(source, i)) return i;
    }
    return null;
}

/// Find the next unescaped `$$` at or after `start`.
fn findUnescapedDoubleDollar(source: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < source.len) : (i += 1) {
        if (source[i] == '$' and source[i + 1] == '$' and !isEscaped(source, i)) return i;
    }
    return null;
}

/// Try to consume a `$$...$$` block math span at `*i`. Returns true and
/// advances `*i` past the closing `$$` on success. Returns false (without
/// modifying `*i`) when the bytes at `*i` aren't a real block-math opener —
/// either because there's no closing `$$`, or because the opening looks like
/// currency (`$$$` or `$$<digit>`). In the false cases the caller emits the
/// `$` byte by byte via the default path so prose like "cost $$5 total"
/// survives unchanged.
fn consumeBlockMath(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, i: *usize) !bool {
    const open = i.*;
    // Reject an escaped opener (`\$$...`) so the backslash survives verbatim.
    if (open > 0 and isEscaped(source, open)) return false;
    // Reject `$$$` — ambiguous with inline math like `$$$x$$`.
    if (open + 2 < source.len and source[open + 2] == '$') return false;
    const body_start = open + 2;
    const close = findUnescapedDoubleDollar(source, body_start) orelse {
        // Unterminated — let the caller emit `$$` verbatim via the default
        // byte-by-byte path. We must NOT swallow the remainder.
        return false;
    };

    const body = source[body_start..close];
    try writeBlockMath(allocator, writer, body);
    i.* = close + 2;
    return true;
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

/// Try to consume an inline `$...$` math span at `*i`. Returns true and
/// advances `*i` past the closing `$` on success. Returns false (leaving
/// `*i` unmodified) when the bytes don't form a real inline-math span.
///
/// Common non-math dollar patterns are explicitly rejected by the
/// open/close guards so they pass through verbatim:
/// - `5$` — opening `$` preceded by a digit.
/// - `$5-$10`, `$5/$10` — the closer is followed by a digit.
/// - `$HOME/$PATH` — the closer is followed by an identifier char.
/// - `${HOME}/${XDG_CONFIG_HOME}` — the opener or closer is followed by `{`
///   (braced shell/config variables), so both dollar signs survive.
/// - `\$FOO\$` — the opener/closer is escaped by a backslash.
/// Digit-led formulas such as `$2^n$` still render because the closer is not
/// identifier/digit-adjacent.
fn consumeInlineMath(writer: *std.Io.Writer, source: []const u8, i: *usize) !bool {
    const open = i.*;

    // Opening `$` immediately after a digit is a price suffix, not math
    // (`5$`). A `$` followed by `{` is a braced shell/config variable, not
    // math. A `$` preceded by an unescaped backslash is an escaped literal
    // dollar, not math. Other punctuation/operators like `=` or `:` are
    // allowed so common forms such as `f(x)=$x^2$` and `value:$v$` render.
    if (open > 0 and std.ascii.isDigit(source[open - 1])) return false;
    if (open > 0 and isEscaped(source, open)) return false;
    // Body must start with a non-space and non-`$` char.
    if (open + 1 >= source.len) return false;
    {
        const next = source[open + 1];
        if (next == ' ' or next == '$' or next == '{') return false;
    }

    const body_start = open + 1;
    const close = findUnescapedDollar(source, body_start) orelse return false;

    // Closing `$` must not be preceded by whitespace, followed by another
    // `$`, followed by a digit (currency ranges), followed by an identifier
    // char (adjacent shell vars like `$HOME/$PATH`), or followed by `{`
    // (braced shell variables like `${HOME}`).
    if (source[close - 1] == ' ') return false;
    if (close + 1 < source.len) {
        const after = source[close + 1];
        if (after == '$' or after == '{' or std.ascii.isDigit(after) or isIdentifierChar(after)) return false;
    }

    const body = source[body_start..close];
    // Reject newlines — inline math is a single line.
    if (std.mem.indexOfScalar(u8, body, '\n') != null) return false;

    try renderMathBody(writer, body);
    i.* = close + 1;
    return true;
}

// ---------------------------------------------------------------------------
// LaTeX → Unicode
// ---------------------------------------------------------------------------

/// Render a math body to `writer`. Walks the source, substituting recognized
/// LaTeX commands and a small set of superscript/subscript forms. Anything
/// unknown is emitted verbatim (with the backslash preserved and any
/// immediate `{...}` argument left intact) so the rendered output remains a
/// useful fallback.
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
                // Escaped literal characters render as themselves.
                if (next == '$' or next == '%' or next == '&' or next == '#' or next == '_' or next == '{' or next == '}') {
                    try writer.writeByte(next);
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
                i = j;
                continue;
            }

            // Unknown command — emit raw so it stays visible as a fallback.
            // Preserve any immediate `{...}` argument verbatim so users can
            // still read / copy unsupported LaTeX like `\boxed{x+1}` instead
            // of having the brace-stripping pass run the operand into the
            // command name (e.g. `\boxedx+1`).
            try writer.writeByte('\\');
            try writer.writeAll(name);
            var after = j;
            while (after < body.len and body[after] == '{') {
                const grp = readGroup(body, after) orelse break;
                try writer.writeAll(body[after..grp.end]);
                after = grp.end;
            }
            i = after;
            continue;
        }

        if (c == '^' or c == '_') {
            // Superscript / subscript. If the next char is `{`, read until
            // `}`; otherwise consume a single char. Render with Unicode
            // superscripts when possible; otherwise emit `^x` / `^{x}` as
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
    var had_braces = false;
    if (body[i.*] == '{') {
        // Use readGroup so nested braces like `^{\frac{1}{2}}` parse
        // correctly — a scalar search for `}` would stop at the first
        // inner closer and corrupt the rest.
        if (readGroup(body, i.*)) |grp| {
            had_braces = true;
            token_start = i.* + 1;
            token_end = grp.end - 1;
            i.* = grp.end;
        } else {
            // Unterminated brace group — emit marker + rest verbatim.
            try writer.writeByte(marker);
            try writer.writeAll(body[i.*..]);
            i.* = body.len;
            return;
        }
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
        // Preserve the source brace grouping in the fallback so multi-char
        // scripts like `^{abc}` render as `^{abc}` (not `^abc`); single-char
        // fallbacks stay in the bare `^x` form for readability.
        if (had_braces) try writer.print("^{{{s}}}", .{token}) else try writer.print("^{s}", .{token});
    } else {
        if (writeSubscript(writer, token)) return;
        if (had_braces) try writer.print("_{{{s}}}", .{token}) else try writer.print("_{s}", .{token});
    }
}

fn isScriptTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '=' or c == '(' or c == ')';
}

fn isIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const FracOperand = struct {
    raw: []const u8,
    end: usize,
};

/// Read one fraction operand starting at `i`: either a `{...}` brace group,
/// a command token (`\alpha`), or a single non-whitespace character. Returns
/// the raw source span (including braces) and the cursor past the operand.
fn readFracOperand(body: []const u8, i: usize) ?FracOperand {
    const j = skipSpace(body, i);
    if (j >= body.len) return null;
    if (body[j] == '{') {
        const g = readGroup(body, j) orelse return null;
        return .{ .raw = body[j..g.end], .end = g.end };
    }
    if (body[j] == '\\' and j + 1 < body.len) {
        var k = j + 2;
        if (std.ascii.isAlphabetic(body[j + 1])) {
            while (k < body.len and std.ascii.isAlphabetic(body[k])) k += 1;
        }
        return .{ .raw = body[j..k], .end = k };
    }
    return .{ .raw = body[j..j + 1], .end = j + 1 };
}

fn isBraceGroup(raw: []const u8) bool {
    return raw.len >= 2 and raw[0] == '{' and raw[raw.len - 1] == '}';
}

/// Render `\frac{A}{B}` as `(A)/(B)`. Returns the new cursor position past
/// both groups. If the operands aren't both brace groups, preserve the raw
/// operand text as a graceful fallback so formulas stay copyable.
fn writeFrac(writer: *std.Io.Writer, body: []const u8, start: usize) anyerror!usize {
    const a = readFracOperand(body, start);
    const b = if (a) |op| readFracOperand(body, op.end) else null;
    if (a != null and b != null and isBraceGroup(a.?.raw) and isBraceGroup(b.?.raw)) {
        try writer.writeByte('(');
        try renderMathBody(writer, a.?.raw[1..a.?.raw.len - 1]);
        try writer.writeAll(")/(");
        try renderMathBody(writer, b.?.raw[1..b.?.raw.len - 1]);
        try writer.writeByte(')');
        return b.?.end;
    }
    // Fallback: preserve the raw operand text so formulas like \frac{10}2 stay
    // copyable instead of collapsing to \frac102. Include any leading
    // whitespace so space-separated operands such as \frac a{b} survive.
    try writer.writeAll("\\frac");
    if (a) |op| {
        const end = if (b) |op2| op2.end else op.end;
        try writer.writeAll(body[start..end]);
        return end;
    }
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
    while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n' or body[j] == '\r')) j += 1;
    return j;
}

const BraceGroup = struct {
    inner: []const u8,
    end: usize,
};

/// Read a `{...}` group starting at `i`. Returns null if `i` doesn't point
/// at a `{`. Handles nested braces via a depth counter so
/// `\frac{\frac{a}{b}}{c}` renders as `((a)/(b))/(c)`. Skipped over escape
/// pairs (`\{`, `\}`, etc.) so escaped LaTeX braces don't affect depth —
/// otherwise unbalanced escapes like `\boxed{\{1,2}` corrupt grouping and
/// drop content.
fn readGroup(body: []const u8, i: usize) ?BraceGroup {
    if (i >= body.len or body[i] != '{') return null;
    var depth: usize = 1;
    var j = i + 1;
    while (j < body.len) : (j += 1) {
        if (body[j] == '\\' and j + 1 < body.len) {
            // Skip the escaped char so it can't affect brace depth.
            j += 1;
            continue;
        }
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
            .{ .name = "textbf", .sym = "" },
            .{ .name = "textit", .sym = "" },
            .{ .name = "textrm", .sym = "" },
            .{ .name = "texttt", .sym = "" },
            .{ .name = "textsf", .sym = "" },
            .{ .name = "emph", .sym = "" },
            .{ .name = "underline", .sym = "" },
            .{ .name = "boldsymbol", .sym = "" },
            .{ .name = "pmb", .sym = "" },
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

test "numeric display math renders as blockquote" {
    const src = "$$2^n$$\n$$100\\%$$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "> 2ⁿ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "> 100%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$$") == null);
}

test "multi-line block math collapses to quoted lines" {
    const src = "$$\n\\sum_{i=1}^n x_i\n$$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "> ∑") != null);
    // `^n` becomes Unicode superscript n; `_{i=1}` has no single-char form
    // so the brace-preserving fallback emits `_{i=1}`.
    try std.testing.expect(std.mem.indexOf(u8, out, "ⁿ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_{i=1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "xᵢ") != null);
}

test "inline math ignores dollar signs used as currency" {
    const src = "costs $5 and $10 each";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // No transform should occur — currency stays as-is.
    try std.testing.expectEqualStrings(src, out);
}

test "currency price range preserves both dollar signs" {
    const src = "price $5-$10 today";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // The second `$` in `$5-$10` is adjacent to digits on both sides and
    // must NOT be treated as a math closer.
    try std.testing.expectEqualStrings(src, out);
}

test "currency slash range preserves both dollar signs" {
    const src = "split $5/$10 ratio";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "inline math after operators renders" {
    const src = "f(x)=$x^2$ and value:$v$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "f(x)=x²") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "value:v") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$x^2$") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$v$") == null);
}

test "inline math starting with digits renders" {
    const src = "count $2^n$ and percent $100\\%$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "2ⁿ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "100%") != null);
}

test "escaped dollar inside inline math is not treated as closer" {
    const src = "price $x = \\$5$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // The escaped \$ should render as a literal $ and the real closing $ should
    // terminate the math span, so the whole formula renders as "x = $5".
    try std.testing.expect(std.mem.indexOf(u8, out, "price x = $5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "price $x = \\5") == null);
}

test "escaped dollar inside block math is not treated as closer" {
    const src = "$$x = \\$5$$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "x = $5") != null);
}

test "escaped double dollar opener stays verbatim" {
    const src = "\\$$x$$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // The leading \\$ must survive and the unescaped $$x$$ should not be eaten.
    try std.testing.expect(std.mem.indexOf(u8, out, "\\$$x$$") != null);
}

test "adjacent shell variables are not parsed as math" {
    const src = "use $HOME/$PATH and $FOO-$BAR";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "braced shell variables are not parsed as math" {
    const src = "use ${HOME}/${XDG_CONFIG_HOME} here";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "markdown link destination with dollar variables stays verbatim" {
    const src = "[API](https://api.example.com/users/$user_id$)";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "markdown link with nested parens in destination stays verbatim" {
    const src = "[link](https://example.com/a(b)c)";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "plain brackets still allow inline math" {
    const src = "value is [x] = $x$ ok";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[x] = x ok") != null);
}

test "bare url with dollar variables stays verbatim" {
    const src = "see https://api.example.com/users/$user_id$ here";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "uppercase bare url scheme is protected from math parsing" {
    const src = "see HTTPS://example.com/$x$ here";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "escaped dollar delimiters in prose stay verbatim" {
    const src = "Use \\$FOO\\$ in docs and write \\$x\\$ to show the delimiter";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "inline code span is not parsed as math" {
    const src = "Use `echo $x$` then $\\alpha$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "`echo $x$`") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "α") != null);
}

test "multi-backtick inline code span is not parsed as math" {
    const src = "Use ``echo $x$`` then $\\alpha$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "``echo $x$``") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "echo x") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "α") != null);
}

test "unterminated block math passes through verbatim per doc" {
    const src = "text $$\\alpha no closer";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // Doc contract: unterminated `$$` is not a math block. Source must
    // survive unchanged so prose like "cost $$5 total" doesn't lose data.
    try std.testing.expectEqualStrings(src, out);
}

test "unterminated block math preserves currency-style double dollar" {
    const src = "cost $$5 total";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "unknown LaTeX command falls back to raw with backslash" {
    const src = "weird $\\zzzx$ here";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\zzzx") != null);
}

test "unknown LaTeX command with brace argument preserves group" {
    const src = "boxed $\\boxed{x+1}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // Unknown `\boxed` must survive together with its `{x+1}` argument so
    // the raw fallback stays copyable (NOT `\boxedx+1`).
    try std.testing.expect(std.mem.indexOf(u8, out, "\\boxed{x+1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\boxedx") == null);
}

test "unknown LaTeX command with multiple brace arguments preserves groups" {
    const src = "choose $\\binom{n}{k}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\binom{n}{k}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\binom{n}k") == null);
}

test "escaped braces inside group do not corrupt depth" {
    // `\{` and `\}` are literal brace chars in LaTeX math, not grouping
    // braces. readGroup must skip the escaped pair so unbalanced escaped
    // braces don't drop content. Repro from review: `\boxed{\{1,2}` should
    // preserve the `\boxed{` opener.
    const src = "set $\\boxed{\\{1,2}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // The `\boxed{` opener must survive — without the escape-skip fix the
    // depth counter matched `\}` against the inner `\boxed{` and lost it.
    try std.testing.expect(std.mem.indexOf(u8, out, "\\boxed{\\{1,2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\boxed\\{1,2") == null);
}

test "mermaid block replaced with labeled summary" {
    const src = "intro\n\n```mermaid\nflowchart TD\n  A --> B\n```\n\noutro";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "**Mermaid diagram: flowchart**") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "> flowchart TD") != null);
    // Indentation from the source is preserved ("> " + "  A --> B").
    try std.testing.expect(std.mem.indexOf(u8, out, ">   A --> B") != null);
    // Raw fence delimiters stripped.
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

test "mermaid fence inside a non-mermaid code block is not transformed" {
    // A code block that documents mermaid syntax must survive verbatim —
    // we cannot eat its closing fence or rewrite its contents.
    const src = "```text\n```mermaid\nflowchart TD\n  A --> B\n```\n```";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "mermaid fence inside a zig code block is not transformed" {
    const src = "```zig\nconst s = \"```mermaid\\nflowchart\\n```\";\n```";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "unterminated non-mermaid code block passes through verbatim" {
    // No closing fence at all — everything after the opener survives.
    const src = "```text\nsome\nraw\nlines";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "math inside non-mermaid fenced code block is not transformed" {
    // Shell-style `$$` (PID var) and `$x$` inside a bash block must survive
    // unchanged — the math pass only runs outside fenced code.
    const src = "```sh\necho $$ $HOME\nx=5\n```\nthen $\\alpha$ math";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // Code block interior unchanged.
    try std.testing.expect(std.mem.indexOf(u8, out, "echo $$ $HOME") != null);
    // Outside-fence math still rendered.
    try std.testing.expect(std.mem.indexOf(u8, out, "α") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$\\alpha$") == null);
}

test "mermaid quoted source preserves indentation" {
    // Indentation-sensitive diagram (mindmap shape) — leading spaces must
    // survive so the raw spec stays copyable from the transcript.
    const src = "```mermaid\nmindmap\n  root\n    child\n      grandchild\n```";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // `> ` prefix + original indentation, so "  root" becomes ">   root".
    try std.testing.expect(std.mem.indexOf(u8, out, ">   root") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ">     child") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ">       grandchild") != null);
}

test "mermaid source with dollar labels is not mutated by math pass" {
    // Mermaid label `$x$` and `$5-$10` must reach the output unchanged —
    // the quoted body is emitted directly by the fence consumer and never
    // re-processed by the inline math step.
    const src = "```mermaid\nflowchart TD\n  A[$x$] --> B[$5-$10]\n```";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "A[$x$]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "B[$5-$10]") != null);
    // Math pass did not eat the labels.
    try std.testing.expect(std.mem.indexOf(u8, out, "A[x]") == null);
}

test "text style commands drop their wrapper" {
    const src = "math $\\textbf{X} + \\textit{Y} + \\textrm{Z} + \\texttt{W}$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "X + Y + Z + W") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\textbf") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\textit") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\textrm") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\texttt") == null);
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

test "nested fraction renders fully" {
    const src = "deep $\\frac{\\frac{a}{b}}{c}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "((a)/(b))/(c)") != null);
}

test "fraction with non-braced operand preserves raw fallback" {
    const src = "ratio $\\frac{10}2$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // When \frac doesn't have two brace groups, the raw operands must survive
    // so the fallback stays copyable (NOT \frac102).
    try std.testing.expect(std.mem.indexOf(u8, out, "\\frac{10}2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\frac102") == null);
}
test "fraction with space separated single token operands preserves braces" {
    const src = "ratio $\\frac a{b}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // The brace around the second operand must survive the fallback.
    try std.testing.expect(std.mem.indexOf(u8, out, "\\frac a{b}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\frac ab") == null);
}

test "fraction with space separated token operands preserves source" {
    const src = "ratio $\\frac a b$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\frac a b") != null);
}

test "fraction with newline separated brace operands renders" {
    const src = "$$\\frac\n{a}\n{b}$$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // Newlines between \\frac and its brace groups should be treated as
    // whitespace and the fraction should still render as (a)/(b).
    try std.testing.expect(std.mem.indexOf(u8, out, "(a)/(b)") != null);
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

test "mermaid block separates from following paragraph with newline" {
    // Without a trailing newline after the quoted source, the next paragraph
    // would concatenate onto the last `> ...` line.
    const src = "```mermaid\nflowchart TD\n  A --> B\n```\noutro";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // "outro" must land on its own line, not glued to the last quoted line.
    try std.testing.expect(std.mem.indexOf(u8, out, "Boutro") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, ">   A --> B\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\noutro") != null);
}

test "four-backtick fenced code block is recognized and closed" {
    // CommonMark allows longer fences so users can wrap content containing
    // triple backticks. A 4-tick fence must be matched by a 4+ tick closer
    // and must protect its interior from math preprocessing.
    const src = "````text\n$\\alpha$\n````\nthen $\\beta$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // Interior of the 4-tick block is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "$\\alpha$") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "α") == null);
    // Math after the block still renders.
    try std.testing.expect(std.mem.indexOf(u8, out, "β") != null);
}

test "four-backtick mermaid block is detected and labeled" {
    const src = "````mermaid\nflowchart TD\n  A --> B\n````";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "**Mermaid diagram: flowchart**") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ">   A --> B") != null);
}

test "nested script braces preserve inner group" {
    // Grouped superscript with nested braces — the scalar `}` search used to
    // truncate at the first inner closer. readGroup handles the nesting.
    const src = "deep $x^{\\frac{1}{2}}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    // The full `\frac{1}{2}` survives inside the script fallback rather than
    // being truncated to `\frac{1}2`.
    try std.testing.expect(std.mem.indexOf(u8, out, "^{\\frac{1}{2}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\frac{1}2") == null);
}
