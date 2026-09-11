
const std = @import("std");

pub fn preprocess(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    return preprocessWithOptions(allocator, source, true);
}

fn preprocessWithOptions(allocator: std.mem.Allocator, source: []const u8, protect_math: bool) anyerror![]u8 {
    if (source.len == 0) return allocator.dupe(u8, source);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    var line_style = LineStyle{
        .line_start = 0,
        .line_end = 0,
        .in_style = false,
        .star2_starts = undefined,
        .star2_count = 0,
        .star1_starts = undefined,
        .star1_count = 0,
        .overflow = false,
    };

    var i: usize = 0;
    var list_ctx = ListContext{};
    while (i < source.len) {
        if (isAtLineStart(source, i)) {
            line_style = computeLineStyle(source, i);
            updateListContext(source, i, &list_ctx);
            if (try consumeFenceBlock(allocator, writer, source, &i)) continue;
            if (try consumeTildeFenceBlock(allocator, writer, source, &i)) continue;
            if (try consumeBlockquoteFenceBlock(writer, source, &i)) continue;
            if (try consumeIndentedCodeBlock(writer, source, &i, list_ctx)) continue;
        }

        if (source[i] == '[') {
            if (try consumeMarkdownLink(allocator, writer, source, &i)) continue;
        }
        if (isBareUrlPrefix(source, i)) {
            if (try consumeBareUrl(writer, source, &i)) continue;
        }
        if (source[i] == '/') {
            if (try consumeRelativePath(writer, source, &i)) continue;
        }

        if (source[i] == '`') {
            if (try consumeInlineCode(writer, source, &i)) continue;
        }

        if (i + 1 < source.len and source[i] == '$' and source[i + 1] == '$') {
            if (try consumeBlockMath(allocator, writer, source, &i)) continue;
        }

        if (source[i] == '$') {
            if (try consumeInlineMath(allocator, writer, source, &i, protect_math, line_style)) continue;
        }

        try writer.writeByte(source[i]);
        i += 1;
    }

    return out.toOwnedSlice();
}

fn isAtLineStart(source: []const u8, i: usize) bool {
    if (i == 0) return true;
    return source[i - 1] == '\n';
}

fn consumeInlineCode(writer: *std.Io.Writer, source: []const u8, i: *usize) anyerror!bool {
    const start = i.*;
    var tick_count: usize = 0;
    while (start + tick_count < source.len and source[start + tick_count] == '`') tick_count += 1;

    if (tick_count >= 3 and isAtLineStart(source, start)) return false;

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
    const line_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    try writer.writeAll(source[start..line_end]);
    i.* = line_end;
    return true;
}

fn consumeBlockquoteFenceBlock(writer: *std.Io.Writer, source: []const u8, i: *usize) anyerror!bool {
    const start = i.*;
    const opener = parseBlockquoteFenceLine(source, start) orelse return false;
    var end = if (opener.line_end < source.len) opener.line_end + 1 else source.len;
    while (end < source.len) {
        if (parseBlockquoteFenceLine(source, end)) |candidate| {
            if (candidate.fence_char == opener.fence_char and candidate.fence_len >= opener.fence_len and candidate.is_closer) {
                end = if (candidate.line_end < source.len) candidate.line_end + 1 else source.len;
                break;
            }
        }
        const line_end = std.mem.indexOfScalarPos(u8, source, end, '\n') orelse source.len;
        end = if (line_end < source.len) line_end + 1 else source.len;
    }
    try writer.writeAll(source[start..end]);
    i.* = end;
    return true;
}

const BlockquoteFence = struct {
    fence_char: u8,
    fence_len: usize,
    line_end: usize,
    is_closer: bool,
};

fn parseBlockquoteFenceLine(source: []const u8, line_start: usize) ?BlockquoteFence {
    const prefix = skipBlockquoteMarkers(source, line_start);
    if (!prefix.has_marker) return null;
    var pos = prefix.content_start;
    while (pos < source.len and source[pos] == ' ') pos += 1;
    if (pos >= source.len or (source[pos] != '`' and source[pos] != '~')) return null;
    const fence_char = source[pos];
    const fence_len = countLeadingChar(source[pos..], fence_char);
    if (fence_len < 3) return null;
    const after_fence = pos + fence_len;
    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    const rest = std.mem.trim(u8, source[after_fence..line_end], " \t\r");
    return .{
        .fence_char = fence_char,
        .fence_len = fence_len,
        .line_end = line_end,
        .is_closer = rest.len == 0,
    };
}

fn consumeIndentedCodeBlock(writer: *std.Io.Writer, source: []const u8, i: *usize, list_ctx: ListContext) anyerror!bool {
    const start = i.*;
    const bq = skipBlockquoteMarkers(source, start);
    if (!isIndentedCodeLine(source, bq.content_start)) return false;

    if (list_ctx.active and !bq.has_marker) {
        const indent = lineIndent(source, start);
        if (indent < list_ctx.content_indent + 4) return false;
    }

    var end = start;
    while (end < source.len) {
        if (!isAtLineStart(source, end)) break;
        const line_bq = skipBlockquoteMarkers(source, end);
        if (line_bq.has_marker != bq.has_marker) break;
        if (!isIndentedCodeLine(source, line_bq.content_start)) break;
        if (list_ctx.active and !line_bq.has_marker) {
            const indent = lineIndent(source, end);
            if (indent < list_ctx.content_indent + 4) break;
        }
        const line_end = std.mem.indexOfScalarPos(u8, source, end, '\n') orelse source.len;
        end = if (line_end < source.len) line_end + 1 else source.len;
    }

    try writer.writeAll(source[start..end]);
    i.* = end;
    return true;
}

const BlockquotePrefix = struct {
    has_marker: bool,
    content_start: usize,
};

fn skipBlockquoteMarkers(source: []const u8, line_start: usize) BlockquotePrefix {
    var pos = line_start;
    var saw_marker = false;
    while (true) {
        var spaces: usize = 0;
        while (pos + spaces < source.len and source[pos + spaces] == ' ' and spaces < 3) spaces += 1;
        const after_spaces = pos + spaces;
        if (after_spaces >= source.len or source[after_spaces] != '>') break;
        saw_marker = true;
        pos = after_spaces + 1;
        if (pos < source.len and source[pos] == ' ') pos += 1;
    }
    return .{ .has_marker = saw_marker, .content_start = pos };
}

fn isIndentedCodeLine(source: []const u8, line_start: usize) bool {
    if (line_start >= source.len) return false;
    if (source[line_start] == '\t') return true;
    return line_start + 4 <= source.len and std.mem.eql(u8, source[line_start .. line_start + 4], "    ");
}

const ListContext = struct {
    active: bool = false,
    content_indent: usize = 0,
};

fn updateListContext(source: []const u8, line_start: usize, ctx: *ListContext) void {
    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    const line = source[line_start..line_end];
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0) return;
    const indent = line.len - trimmed.len;

    if (isListMarkerLine(trimmed)) {
        ctx.active = true;
        if (trimmed[0] == '-' or trimmed[0] == '*') {
            ctx.content_indent = indent + 2;
        } else {
            var marker_width: usize = 0;
            while (marker_width < trimmed.len and std.ascii.isDigit(trimmed[marker_width])) marker_width += 1;
            if (marker_width < trimmed.len and trimmed[marker_width] == '.') marker_width += 1;
            if (marker_width < trimmed.len and trimmed[marker_width] == ' ') marker_width += 1;
            ctx.content_indent = indent + marker_width;
        }
        return;
    }
    if (indent == 0) ctx.active = false;
}

fn lineIndent(source: []const u8, line_start: usize) usize {
    var width: usize = 0;
    var i = line_start;
    while (i < source.len) {
        switch (source[i]) {
            ' ' => width += 1,
            '\t' => width += 4,
            else => break,
        }
        i += 1;
    }
    return width;
}

fn isListMarkerLine(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) return true;
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) i += 1;
    return i > 0 and i + 1 < trimmed.len and trimmed[i] == '.' and trimmed[i + 1] == ' ';
}

const MAX_STAR_RUNS = 32;

const LineStyle = struct {
    line_start: usize,
    line_end: usize,
    in_style: bool,
    star2_starts: [MAX_STAR_RUNS]usize,
    star2_count: usize,
    star1_starts: [MAX_STAR_RUNS]usize,
    star1_count: usize,
    overflow: bool,
};

fn computeLineStyle(source: []const u8, line_start: usize) LineStyle {
    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    const line = source[line_start..line_end];
    const trimmed_start = std.mem.indexOfNonePos(u8, line, 0, " ") orelse line.len;
    const trimmed = line[trimmed_start..];

    var star2_starts: [MAX_STAR_RUNS]usize = undefined;
    var star2_count: usize = 0;
    var star1_starts: [MAX_STAR_RUNS]usize = undefined;
    var star1_count: usize = 0;
    var overflow = false;

    var pos: usize = 0;
    while (pos < line.len) {
        if (line[pos] != '*') {
            pos += 1;
            continue;
        }
        const run_start = pos;
        while (pos < line.len and line[pos] == '*') pos += 1;
        const abs_start = line_start + run_start;
        const run_len = pos - run_start;
        if (run_len >= 2) {
            if (star2_count < MAX_STAR_RUNS) {
                star2_starts[star2_count] = abs_start;
                star2_count += 1;
            } else overflow = true;
        } else {
            if (star1_count < MAX_STAR_RUNS) {
                star1_starts[star1_count] = abs_start;
                star1_count += 1;
            } else overflow = true;
        }
    }

    return .{
        .line_start = line_start,
        .line_end = line_end,
        .in_style = std.mem.startsWith(u8, trimmed, "# ") or
            std.mem.startsWith(u8, trimmed, "## ") or
            std.mem.startsWith(u8, trimmed, "### ") or
            std.mem.startsWith(u8, trimmed, "> "),
        .star2_starts = star2_starts,
        .star2_count = star2_count,
        .star1_starts = star1_starts,
        .star1_count = star1_count,
        .overflow = overflow,
    };
}

fn runsBefore(starts: []const usize, len: usize, pos: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (starts[i] < pos) n += 1;
    }
    return n;
}

fn runAtOrAfter(starts: []const usize, len: usize, pos: usize) bool {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (starts[i] >= pos) return true;
    }
    return false;
}

fn isInsideNonRecursiveMarkdownStyle(open: usize, close: usize, style: LineStyle) bool {
    if (style.in_style) return true;
    if (style.overflow) return false;
    if (runsBefore(style.star2_starts[0..], style.star2_count, open) % 2 == 1 and
        runAtOrAfter(style.star2_starts[0..], style.star2_count, close)) return true;
    if (runsBefore(style.star1_starts[0..], style.star1_count, open) % 2 == 1 and
        runAtOrAfter(style.star1_starts[0..], style.star1_count, close)) return true;
    return false;
}

fn consumeMarkdownLink(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, i: *usize) anyerror!bool {
    const start = i.*;
    if (start >= source.len or source[start] != '[') return false;

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

    const url_start = text_end + 1;
    if (url_start >= source.len or source[url_start] != '(') return false;

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

    const label_text = source[start + 1 .. text_end];
    const processed_label = try preprocessWithOptions(allocator, label_text, false);
    defer allocator.free(processed_label);

    const raw_close_count = std.mem.count(u8, label_text, "]");
    const processed_close_count = std.mem.count(u8, processed_label, "]");
    const effective_label = if (processed_close_count > raw_close_count)
        label_text
    else
        processed_label;

    try writer.writeByte('[');
    try writer.writeAll(effective_label);
    try writer.writeAll("](");
    try writer.writeAll(source[url_start + 1 .. url_end]);
    try writer.writeByte(')');
    i.* = url_end + 1;
    return true;
}

fn findMarkdownLinkEnd(source: []const u8, start: usize) ?usize {
    if (start >= source.len or source[start] != '[') return null;

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
    if (bracket_depth != 0 or text_end >= source.len) return null;

    const dest_start = text_end + 1;
    if (dest_start >= source.len) return null;

    if (source[dest_start] == '(') {
        var url_end = dest_start + 1;
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
        if (paren_depth != 0 or url_end >= source.len) return null;
        return url_end + 1;
    }

    if (source[dest_start] == '[') {
        var ref_end = dest_start + 1;
        while (ref_end < source.len) {
            const c = source[ref_end];
            if (c == '\\' and ref_end + 1 < source.len) {
                ref_end += 2;
                continue;
            }
            if (c == ']') return ref_end + 1;
            if (c == '\n' or c == '\r') return null;
            ref_end += 1;
        }
    }

    return null;
}

fn isBareUrlPrefix(source: []const u8, i: usize) bool {
    if (i + 7 <= source.len and std.ascii.eqlIgnoreCase(source[i .. i + 7], "http://")) return true;
    if (i + 8 <= source.len and std.ascii.eqlIgnoreCase(source[i .. i + 8], "https://")) return true;
    return false;
}

fn consumeBareUrl(writer: *std.Io.Writer, source: []const u8, i: *usize) !bool {
    if (!isBareUrlPrefix(source, i.*)) return false;
    const start = i.*;
    var end = start;
    while (end < source.len) {
        const c = source[end];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '<' or c == '>') break;
        end += 1;
    }
    try writer.writeAll(source[start..end]);
    i.* = end;
    return true;
}

fn consumeRelativePath(writer: *std.Io.Writer, source: []const u8, i: *usize) anyerror!bool {
    if (source[i.*] != '/') return false;
    const start = i.*;
    var requires_dollar_placeholder = false;
    if (start > 0) {
        const prev = source[start - 1];
        const is_whitespace_boundary = std.ascii.isWhitespace(prev);
        const is_opener_boundary = prev == '(' or prev == '[' or prev == '{' or
            prev == '"' or prev == '\'' or prev == '<';
        if (!is_whitespace_boundary and !is_opener_boundary) return false;
        requires_dollar_placeholder = is_opener_boundary;
    }
    var end = start;
    var slash_count: usize = 0;
    var has_dollar = false;
    while (end < source.len) {
        const c = source[end];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '<' or c == '>') break;
        if (c == '/') slash_count += 1;
        if (c == '$') has_dollar = true;
        end += 1;
    }
    if (slash_count < 2 and !has_dollar) return false;
    if (requires_dollar_placeholder and !has_dollar) return false;
    try writer.writeAll(source[start..end]);
    i.* = end;
    return true;
}

const mermaid_lang = "mermaid";

fn consumeFenceBlock(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, i: *usize) !bool {
    return try consumeFenceGeneric(allocator, writer, source, i, '`', true);
}

fn consumeTildeFenceBlock(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, i: *usize) anyerror!bool {
    return try consumeFenceGeneric(allocator, writer, source, i, '~', true);
}

fn consumeFenceGeneric(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    source: []const u8,
    i: *usize,
    fence_char: u8,
    may_be_mermaid: bool,
) !bool {
    const start = i.*;
    var indent_end = start;
    while (indent_end < source.len and source[indent_end] == ' ') indent_end += 1;
    if (indent_end >= source.len or source[indent_end] != fence_char) return false;

    var fence_len: usize = 0;
    while (indent_end + fence_len < source.len and source[indent_end + fence_len] == fence_char) fence_len += 1;
    if (fence_len < 3) return false;

    const fence_end = indent_end + fence_len;
    const line_end = std.mem.indexOfScalarPos(u8, source, fence_end, '\n') orelse source.len;
    const tag = if (may_be_mermaid)
        std.mem.trim(u8, source[fence_end..line_end], " \t\r")
    else
        "";

    const body_start = if (line_end < source.len) line_end + 1 else source.len;
    const close_line_start = findFenceCloseLine(source, body_start, fence_len, fence_char);
    const body_end = if (close_line_start) |cls| cls else source.len;
    const body = source[body_start..body_end];

    if (may_be_mermaid and std.mem.eql(u8, tag, mermaid_lang)) {
        const diagram_type = detectMermaidType(body);
        if (diagram_type.len > 0) {
            try writer.print("**Mermaid diagram: {s}**\n\n", .{diagram_type});
        } else {
            try writer.writeAll("**Mermaid diagram**\n\n");
        }
        try writeQuotedLines(writer, body);
        try writer.writeByte('\n');
    } else {
        try writer.writeAll(source[start..body_end]);
        if (close_line_start) |cls| {
            const close_line_end = std.mem.indexOfScalarPos(u8, source, cls, '\n') orelse source.len;
            const emit_end = if (close_line_end < source.len) close_line_end + 1 else source.len;
            try writer.writeAll(source[cls..emit_end]);
            i.* = emit_end;
        } else {
            i.* = body_end;
            if (body_end < source.len and source[body_end] == '\n') {
                try writer.writeByte('\n');
                i.* = body_end + 1;
            }
        }
        _ = allocator;
        return true;
    }

    if (close_line_start) |cls| {
        const close_line_end = std.mem.indexOfScalarPos(u8, source, cls, '\n') orelse source.len;
        i.* = if (close_line_end < source.len) close_line_end + 1 else source.len;
    } else {
        i.* = source.len;
    }
    return true;
}

fn findFenceCloseLine(source: []const u8, body_start: usize, fence_len: usize, fence_char: u8) ?usize {
    var j = body_start;
    while (j < source.len) {
        const line_start = j;
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = source[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (countLeadingChar(trimmed, fence_char) >= fence_len) {
            if (std.mem.allEqual(u8, trimmed, fence_char)) return line_start;
        }
        j = if (line_end < source.len) line_end + 1 else source.len;
    }
    return null;
}

fn countLeadingChar(s: []const u8, c: u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == c) n += 1;
    return n;
}

fn detectMermaidType(body: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "%%")) continue;
        var tok_end: usize = 0;
        while (tok_end < line.len and !std.ascii.isWhitespace(line[tok_end])) tok_end += 1;
        const tok = line[0..tok_end];
        if (tok.len == 0) continue;

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
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        if (std.mem.allEqual(u8, line, ' ') or line.len == 0) continue;
        if (wrote_any) try writer.writeByte('\n');
        try writer.writeAll("> ");
        try writer.writeAll(line);
        wrote_any = true;
    }
    if (!wrote_any) {
        try writer.writeAll("> (empty)");
    }
}

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

fn findUnescapedDollar(source: []const u8, start: usize) ?usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        if (source[i] == '$' and !isEscaped(source, i)) return i;
    }
    return null;
}

fn findInlineMathClose(source: []const u8, start: usize) ?usize {
    var i = start;
    while (i < source.len) {
        if (source[i] == '`') {
            const tick_count = countLeadingChar(source[i..], '`');
            var scan = i + tick_count;
            var found_close = false;
            while (scan < source.len) {
                if (source[scan] == '`') {
                    const close_count = countLeadingChar(source[scan..], '`');
                    if (close_count == tick_count) {
                        i = scan + close_count;
                        found_close = true;
                        break;
                    }
                    scan += close_count;
                    continue;
                }
                scan += 1;
            }
            if (!found_close) return null;
            continue;
        }
        if (isBareUrlPrefix(source, i)) {
            var url_end = i;
            while (url_end < source.len) {
                const c = source[url_end];
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
                    c == '<' or c == '>')
                {
                    break;
                }
                url_end += 1;
            }
            i = url_end;
            continue;
        }
        if (source[i] == '[') {
            if (findMarkdownLinkEnd(source, i)) |link_end| {
                i = link_end;
                continue;
            }
        }
        if (source[i] == '$' and !isEscaped(source, i)) return i;
        i += 1;
    }
    return null;
}

fn findUnescapedDoubleDollar(source: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < source.len) : (i += 1) {
        if (source[i] == '$' and source[i + 1] == '$' and !isEscaped(source, i)) return i;
    }
    return null;
}

fn writeProtectedMathSpan(writer: *std.Io.Writer, source: []const u8, open: usize, text: []const u8, line_start: usize) anyerror!void {
    if (!needsMathProtection(source, open, text, line_start)) {
        try writer.writeAll(text);
        return;
    }
    if (std.mem.indexOfScalar(u8, text, '`') != null) {
        try writer.writeAll(text);
        return;
    }
    try writer.writeByte('`');
    try writer.writeAll(text);
    try writer.writeByte('`');
}

fn consumeBlockMath(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, i: *usize) !bool {
    const open = i.*;
    if (open > 0 and isEscaped(source, open)) {
        try writer.writeAll("$$");
        i.* = open + 2;
        return true;
    }
    if (open + 2 < source.len and source[open + 2] == '$') {
        try writer.writeAll("$$");
        i.* = open + 2;
        return true;
    }
    const body_start = open + 2;
    const close = findUnescapedDoubleDollar(source, body_start) orelse {
        try writer.writeAll("$$");
        i.* = body_start;
        return true;
    };

    const body = source[body_start..close];
    if (isCurrencyLikeMathBody(body)) return false;
    if (open > 0 and source[open - 1] != '\n') try writer.writeByte('\n');
    try writeBlockMath(allocator, writer, body);
    const after_close = close + 2;
    if (after_close < source.len and source[after_close] != '\n') {
        try writer.writeByte('\n');
        i.* = if (source[after_close] == ' ') after_close + 1 else after_close;
    } else {
        i.* = after_close;
    }
    return true;
}

fn writeBlockMath(allocator: std.mem.Allocator, writer: *std.Io.Writer, body: []const u8) !void {
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try renderMathBody(&rendered.writer, body);

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

fn consumeInlineMath(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, i: *usize, protect_math: bool, line_style: LineStyle) anyerror!bool {
    const open = i.*;

    if (open > 0 and std.ascii.isDigit(source[open - 1])) return false;
    if (open > 0 and isEscaped(source, open)) return false;
    if (open + 1 >= source.len) return false;
    {
        const next = source[open + 1];
        if (next == '$' or next == '{') return false;
    }

    const body_start = open + 1;
    const close = findInlineMathClose(source, body_start) orelse return false;

    const body = source[body_start..close];
    const has_leading_ws = body.len > 0 and (body[0] == ' ' or body[0] == '\t');
    const has_trailing_ws = body.len > 0 and (body[body.len - 1] == ' ' or body[body.len - 1] == '\t');
    if (has_trailing_ws and !has_leading_ws) return false;
    const math_body = std.mem.trim(u8, body, " \t\r");
    if (math_body.len == 0) return false;

    if (std.mem.indexOf(u8, math_body, "://") != null) return false;
    if (isCurrencyLikeMathBody(math_body) and !startsBlockMarkdownAtSourcePosition(source, open, math_body, line_style.line_start)) return false;

    if (math_body.len > 0 and isShellVarSeparator(math_body[math_body.len - 1])) {
        if (close + 1 < source.len and isIdentifierChar(source[close + 1]) and isShellNameLike(math_body[0 .. math_body.len - 1])) return false;
    }
    if (close + 1 < source.len) {
        const after = source[close + 1];
        if (after == '$' or after == '{' or std.ascii.isDigit(after)) return false;
        if ((after == '/' or after == '-') and isShellNameLike(math_body)) {
            var scan = close + 2;
            while (scan < source.len and (std.ascii.isAlphanumeric(source[scan]) or source[scan] == '_')) scan += 1;
            if (scan < source.len and source[scan] == '$') return false;
        }
        if (isUppercaseShellName(math_body) and isIdentifierChar(after)) return false;
        if (std.ascii.isAlphabetic(after) and std.ascii.isUpper(after)) {
            return false;
        }
    }

    if (std.mem.indexOfScalar(u8, math_body, '\n') != null) return false;

    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    try renderMathBody(&rendered.writer, math_body);
    if (protect_math and !isInsideNonRecursiveMarkdownStyle(open, close, line_style)) {
        try writeProtectedMathSpan(writer, source, open, rendered.written(), line_style.line_start);
    } else {
        try writer.writeAll(rendered.written());
    }
    i.* = close + 1;
    return true;
}

fn renderMathBody(writer: *std.Io.Writer, body: []const u8) anyerror!void {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];

        if (c == '\\') {
            var j = i + 1;
            while (j < body.len and std.ascii.isAlphabetic(body[j])) j += 1;
            if (j == i + 1 and j < body.len) {
                const next = body[j];
                if (next == ',') {
                    try writer.writeAll(" ");
                    i = j + 1;
                    continue;
                }
                if (next == ';' or next == ':') {
                    try writer.writeAll(" ");
                    i = j + 1;
                    continue;
                }
                if (next == '!') {
                    i = j + 1;
                    continue;
                }
                if (next == '\\') {
                    try writer.writeByte('\n');
                    i = j + 1;
                    continue;
                }
                if (next == '$' or next == '%' or next == '&' or next == '#' or next == '_' or next == '{' or next == '}') {
                    try writer.writeByte(next);
                    i = j + 1;
                    continue;
                }
                try writer.writeByte('\\');
                try writer.writeByte(next);
                i = j + 1;
                continue;
            }

            const name = body[i + 1 .. j];

            if (std.mem.eql(u8, name, "frac")) {
                i = try writeFrac(writer, body, j);
                continue;
            }
            if (std.mem.eql(u8, name, "sqrt")) {
                i = try writeSqrt(writer, body, j);
                continue;
            }

            if (isTextModeCommand(name) and j < body.len and body[j] == '{') {
                if (readGroup(body, j)) |grp| {
                    try writer.writeAll(body[j + 1 .. grp.end - 1]);
                    i = grp.end;
                    continue;
                }
            }

            if (lookupCommand(name)) |sym| {
                try writer.writeAll(sym);
                i = j;
                continue;
            }

            try writer.writeByte('\\');
            try writer.writeAll(name);
            var after = j;
            while (after < body.len and body[after] == '{') {
                const grp = readGroup(body, after) orelse {
                    try writer.writeAll(body[after..]);
                    return;
                };
                try writer.writeAll(body[after..grp.end]);
                after = grp.end;
            }
            i = after;
            continue;
        }

        if (c == '^' or c == '_') {
            try writeScript(writer, body, &i);
            continue;
        }

        if (c == '{' or c == '}') {
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
        if (readGroup(body, i.*)) |grp| {
            had_braces = true;
            token_start = i.* + 1;
            token_end = grp.end - 1;
            i.* = grp.end;
        } else {
            try writer.writeByte(marker);
            try writer.writeAll(body[i.*..]);
            i.* = body.len;
            return;
        }
    } else {
        const c = body[i.*];
        if (isScriptTokenChar(c)) {
            token_start = i.*;
            token_end = i.* + 1;
            i.* += 1;
        } else {
            try writer.writeByte(marker);
            return;
        }
    }

    const token = body[token_start..token_end];
    if (marker == '^') {
        if (writeSuperscript(writer, token)) return;
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

fn isUppercaseShellName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isUpper(c) or c == '_')) return false;
    }
    return true;
}

fn isShellNameLike(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn isShellVarSeparator(c: u8) bool {
    return c == '/' or c == '-' or c == ':' or c == '@' or c == '.';
}

fn isCurrencyLikeMathBody(body: []const u8) bool {
    if (body.len == 0 or !std.ascii.isDigit(body[0])) return false;
    var saw_space = false;
    var saw_alpha = false;
    var i: usize = 1;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == ';') return true;
        if (c == '\\') {
            var j = i + 1;
            while (j < body.len and std.ascii.isAlphabetic(body[j])) j += 1;
            i = j - 1;
            continue;
        }
        if (c == '^' or c == '_' or c == '+' or c == '-' or
            c == '*' or c == '/' or c == '=' or c == '<' or c == '>')
        {
            continue;
        }
        if (std.ascii.isAlphabetic(c)) saw_alpha = true;
        if (std.ascii.isWhitespace(c)) saw_space = true;
    }
    return saw_alpha and saw_space;
}

fn needsMathProtection(source: []const u8, open: usize, text: []const u8, line_start: usize) bool {
    for (text) |c| {
        if (c == '*' or c == '_' or c == '`' or c == '[' or c == ']' or
            c == '<' or c == '>')
        {
            return true;
        }
    }
    return startsBlockMarkdownAtSourcePosition(source, open, text, line_start);
}

fn startsBlockMarkdownAtSourcePosition(source: []const u8, open: usize, text: []const u8, line_start: usize) bool {
    const before = source[line_start..open];
    if (std.mem.indexOfNone(u8, before, " \t") != null) return false;

    if (std.mem.startsWith(u8, text, "# ")) return true;
    if (std.mem.startsWith(u8, text, "- ") or std.mem.startsWith(u8, text, "* ")) return true;
    if (text.len >= 3 and isAllMarkdownRuleChar(text, '-')) return true;
    if (text.len >= 3 and isAllMarkdownRuleChar(text, '*')) return true;

    var i: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    return i > 0 and i + 1 < text.len and text[i] == '.' and text[i + 1] == ' ';
}

fn isAllMarkdownRuleChar(text: []const u8, c: u8) bool {
    for (text) |ch| {
        if (ch != c and ch != ' ') return false;
    }
    return true;
}

fn isTextModeCommand(name: []const u8) bool {
    const text_cmds = [_][]const u8{
        "text",   "textbf",    "textit", "textrm",     "texttt", "textsf",
        "emph",   "underline", "mathrm", "mathit",     "mathbf", "mathsf",
        "mathtt", "mathcal",   "mathbb", "boldsymbol", "pmb",    "operatorname",
    };
    for (text_cmds) |cmd| {
        if (std.mem.eql(u8, name, cmd)) return true;
    }
    return false;
}

const FracOperand = struct {
    raw: []const u8,
    end: usize,
};

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
    return .{ .raw = body[j .. j + 1], .end = j + 1 };
}

fn isBraceGroup(raw: []const u8) bool {
    return raw.len >= 2 and raw[0] == '{' and raw[raw.len - 1] == '}';
}

fn writeFrac(writer: *std.Io.Writer, body: []const u8, start: usize) anyerror!usize {
    const a = readFracOperand(body, start);
    const b = if (a) |op| readFracOperand(body, op.end) else null;
    if (a != null and b != null and isBraceGroup(a.?.raw) and isBraceGroup(b.?.raw)) {
        try writer.writeByte('(');
        try renderMathBody(writer, a.?.raw[1 .. a.?.raw.len - 1]);
        try writer.writeAll(")/(");
        try renderMathBody(writer, b.?.raw[1 .. b.?.raw.len - 1]);
        try writer.writeByte(')');
        return b.?.end;
    }
    try writer.writeAll("\\frac");
    if (a) |op| {
        const end = if (b) |op2| op2.end else op.end;
        try writer.writeAll(body[start..end]);
        return end;
    }
    return start;
}

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

fn readGroup(body: []const u8, i: usize) ?BraceGroup {
    if (i >= body.len or body[i] != '{') return null;
    var depth: usize = 1;
    var j = i + 1;
    while (j < body.len) : (j += 1) {
        if (body[j] == '\\' and j + 1 < body.len) {
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

fn lookupCommand(name: []const u8) ?[]const u8 {
    const map = struct {
        const entries = [_]struct { name: []const u8, sym: []const u8 }{
            .{ .name = "alpha", .sym = "α" },
            .{ .name = "beta", .sym = "β" },
            .{ .name = "gamma", .sym = "γ" },
            .{ .name = "delta", .sym = "δ" },
            .{ .name = "epsilon", .sym = "ϵ" },
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
            .{ .name = "simeq", .sym = "≃" },
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
            .{ .name = "lbrack", .sym = "[" },
            .{ .name = "rbrack", .sym = "]" },
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

    for (map.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            if (entry.sym.len == 0) return "";
            return entry.sym;
        }
    }
    return null;
}

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
    try std.testing.expect(std.mem.indexOf(u8, out, "ⁿ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_{i=1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "xᵢ") != null);
}

test "inline math ignores dollar signs used as currency" {
    const src = "costs $5 and $10 each";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "currency price range preserves both dollar signs" {
    const src = "price $5-$10 today";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
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

test "triple-backtick inline code span is not parsed as math" {
    const src = "Use ```echo $x$``` then $\\alpha$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "```echo $x$```") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "echo x") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "α") != null);
}

test "unterminated block math passes through verbatim per doc" {
    const src = "text $$\\alpha no closer";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
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
    const src = "set $\\boxed{\\{1,2}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\boxed{\\{1,2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\boxed\\{1,2") == null);
}

test "mermaid block replaced with labeled summary" {
    const src = "intro\n\n```mermaid\nflowchart TD\n  A --> B\n```\n\noutro";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "**Mermaid diagram: flowchart**") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "> flowchart TD") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ">   A --> B") != null);
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
    const src = "```text\nsome\nraw\nlines";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "math inside non-mermaid fenced code block is not transformed" {
    const src = "```sh\necho $$ $HOME\nx=5\n```\nthen $\\alpha$ math";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "echo $$ $HOME") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "α") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$\\alpha$") == null);
}

test "mermaid quoted source preserves indentation" {
    const src = "```mermaid\nmindmap\n  root\n    child\n      grandchild\n```";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ">   root") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ">     child") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ">       grandchild") != null);
}

test "mermaid source with dollar labels is not mutated by math pass" {
    const src = "```mermaid\nflowchart TD\n  A[$x$] --> B[$5-$10]\n```";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "A[$x$]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "B[$5-$10]") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "\\frac{10}2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\frac102") == null);
}
test "fraction with space separated single token operands preserves braces" {
    const src = "ratio $\\frac a{b}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
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
    const src = "```mermaid\nflowchart TD\n  A --> B\n```\noutro";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Boutro") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, ">   A --> B\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\noutro") != null);
}

test "four-backtick fenced code block is recognized and closed" {
    const src = "````text\n$\\alpha$\n````\nthen $\\beta$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "$\\alpha$") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "α") == null);
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
    const src = "deep $x^{\\frac{1}{2}}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "^{\\frac{1}{2}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\frac{1}2") == null);
}

test "inline math protects markdown metacharacters with inline code" {
    const src = "product $a*b*c$ and sum $x[y](z)$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "`a*b*c`") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`x[y](z)`") != null);
}

test "block math forces line boundaries around prose" {
    const src = "before$$x$$after";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "before\n> x\nafter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "before > x after") == null);
}

test "block math with spaces around delimiters separates from prose" {
    const src = "before $$x$$ after";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "> x") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "before > x after") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nafter") != null);
}

test "link label math is rendered while url stays verbatim" {
    const src = "[loss $L_2$](https://example.com/$id)";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[loss L₂](https://example.com/$id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$L_2$") == null);
}

test "incomplete unknown command group is preserved verbatim" {
    const src = "set $\\boxed{\\{1,2$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\boxed{\\{1,2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\boxed\\{1,2") == null);
}

test "relative path with dollar placeholders stays verbatim" {
    const src = "GET /users/$user_id$/orders";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "inline math allows lowercase prose suffixes" {
    const src = "the $n$th term";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "the nth term") != null);
}

test "division before inline math is not treated as a route" {
    const src = "the rate is 1/$n$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "1/n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1/$n$") == null);
}

test "tilde fenced code block is preserved verbatim" {
    const src = "~~~sh\necho $x$\n~~~\n";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "mermaid type detection skips directive lines" {
    const src = "```mermaid\n%%{init: {'theme': 'dark'}}%%\nflowchart TD\n  A --> B\n```";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "**Mermaid diagram: flowchart**") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Mermaid diagram: %%{init") == null);
}

test "simeq maps to the correct relation" {
    const src = "$a \\simeq b$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "≃") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "≅") == null);
}

test "positive latex spacing commands produce a space" {
    const src = "$a\\;b$ and $x\\:y$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "a b") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x y") != null);
}

test "negative latex spacing command is dropped" {
    const src = "$a\\!b$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ab") != null);
}

test "uppercase math with slash or minus renders" {
    const src = "$A/B$ and $X - Y$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "A/B") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "X - Y") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$A/B$") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$X - Y$") == null);
}

test "route after opening delimiter is protected when it has dollar placeholders" {
    const src = "call (/api/v1/$id$) now";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "/api/v1/$id$") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`/api/v1/`)") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`id`") == null);
}

test "parenthesized math is not swallowed as a route" {
    const src = "value ($A/B$)";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(A/B)") != null);
}

test "uppercase shell variable suffix stays raw" {
    const src = "path is $HOME$var today";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "$HOME$var") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`HOME`var") == null);
}

test "lowercase prose suffix after math renders" {
    const src = "file $x$_tmp";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "file x_tmp") != null);
}

test "math wrapper omitted inside styled markdown contexts" {
    const src = "**Energy: $E=mc^2$**";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "**Energy: E=mc²**") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`E=mc²`") == null);
}

test "math wrapper still applied when metacharacters present" {
    const src = "formula $a*b*c$ here";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "`a*b*c`") != null);
}

test "lowercase shell variables with path separators stay raw" {
    const src = "vars $foo/$bar and $prefix-$suffix";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "$foo/$bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$prefix-$suffix") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`foo`") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`prefix`") == null);
}

test "inline math closer skips bare url placeholders" {
    const src = "Pay $5; details: https://example.com/$id$ here";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://example.com/$id$") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`5; details:") == null);
}

test "text command preserves literal operand" {
    const src = "label $\\text{user_id}$ end";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "user_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "userᵢd") == null);
}

test "styled text commands preserve literal operand" {
    const src = "vars $\\textbf{x_id}$ and $\\mathrm{a^b}$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "x_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a^b") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "xᵢ") == null);
}

test "epsilon and varepsilon render distinctly" {
    const src = "vars $\\epsilon$ vs $\\varepsilon$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ϵ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ε") != null);
}

test "link label with bracketed math falls back to raw" {
    const src = "[range $\\lbrack 0, 1 \\rbrack$](https://example.com)";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\rbrack$](https://example.com)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[range [0, 1]]") == null);
}

test "unterminated inline code preserves rest of line" {
    const src = "Run `echo $HOME$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "unterminated inline code with newline preserves next line" {
    const src = "Run `echo $HOME$\nthen $x$ math";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "`echo $HOME$") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "then x math") != null);
}

test "unterminated block math preserves opening dollars" {
    const src = "$$x$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "unterminated block math in prose preserves dollars" {
    const src = "intro $$x$ trailing";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "$$x$") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`x`") == null);
}

test "inline closer skips triple-backtick code spans" {
    const src = "Pay $5; run ```echo $x$``` now";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "protection wrapper omitted in non-recursive markdown styles" {
    const bold_src = "**Index $x_j$**";
    const bold = try preprocess(std.testing.allocator, bold_src);
    defer std.testing.allocator.free(bold);
    try std.testing.expect(std.mem.indexOf(u8, bold, "**Index x_j**") != null);
    try std.testing.expect(std.mem.indexOf(u8, bold, "`x_j`") == null);

    const heading_src = "# $x_j$";
    const heading = try preprocess(std.testing.allocator, heading_src);
    defer std.testing.allocator.free(heading);
    try std.testing.expect(std.mem.indexOf(u8, heading, "# x_j") != null);
    try std.testing.expect(std.mem.indexOf(u8, heading, "`x_j`") == null);

    const quote_src = "> $x_j$";
    const quote = try preprocess(std.testing.allocator, quote_src);
    defer std.testing.allocator.free(quote);
    try std.testing.expect(std.mem.indexOf(u8, quote, "> x_j") != null);
    try std.testing.expect(std.mem.indexOf(u8, quote, "`x_j`") == null);
}

test "indented code block is preserved verbatim" {
    const src = "intro\n\n    const formula = \"$x^2$\";\n\noutro $y$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "    const formula = \"$x^2$\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "outro y") != null);
}

test "inline closer skips complete markdown links" {
    const src = "Pay $5; see [$x$](https://example.com) now";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Pay $5; see [x](https://example.com) now") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`5; see [") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x$](https://example.com)") == null);
}

test "inline closer skips reference markdown links" {
    const src = "Pay $5; see [$x$][ref] now";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Pay $5; see [x][ref] now") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "`5; see [") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x$][ref]") == null);
}

test "rejected double dollar openers are consumed atomically" {
    const escaped = "\\$$x$$";
    const escaped_out = try preprocess(std.testing.allocator, escaped);
    defer std.testing.allocator.free(escaped_out);
    try std.testing.expectEqualStrings(escaped, escaped_out);

    const triple = "$$$x$$";
    const triple_out = try preprocess(std.testing.allocator, triple);
    defer std.testing.allocator.free(triple_out);
    try std.testing.expectEqualStrings(triple, triple_out);
}

test "lowercase shell variables separated by punctuation stay raw" {
    const src = "connect $host:$port as $user@$host via $name.$domain";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "$host:$port") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$user@$host") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$name.$domain") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "host:port") == null);
}

test "currency dollar with operator does not steal formula opener" {
    const src = "Costs $5+tax; x=$x$.";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Costs $5+tax; x=x.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Costs 5+tax; x=x$.") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$x$") == null);
}

test "pure digit-prefixed arithmetic still renders after currency widening" {
    const a = try preprocess(std.testing.allocator, "$5+3$");
    defer std.testing.allocator.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, "5+3") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "$5+3$") == null);

    const b = try preprocess(std.testing.allocator, "$2^n$");
    defer std.testing.allocator.free(b);
    try std.testing.expect(std.mem.indexOf(u8, b, "2ⁿ") != null);

    const c = try preprocess(std.testing.allocator, "$$10 \\times 4$$");
    defer std.testing.allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "> 10 × 4") != null);
}

test "whitespace-padded inline math renders" {
    const src = "Sum $ x + y $ done";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Sum x + y done") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$ x + y $") == null);

    const tab_src = "Sum $\tx + y\t$ done";
    const tab_out = try preprocess(std.testing.allocator, tab_src);
    defer std.testing.allocator.free(tab_out);
    try std.testing.expect(std.mem.indexOf(u8, tab_out, "Sum x + y done") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab_out, "$\tx + y\t$") == null);
}

test "empty padded dollars are not a formula" {
    const src = "cost $ $ today";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "line-start inline math that renders block marker is protected" {
    const heading_src = "$\\# S$";
    const heading = try preprocess(std.testing.allocator, heading_src);
    defer std.testing.allocator.free(heading);
    try std.testing.expect(std.mem.indexOf(u8, heading, "`# S`") != null);

    const rule_src = "$---$";
    const rule = try preprocess(std.testing.allocator, rule_src);
    defer std.testing.allocator.free(rule);
    try std.testing.expect(std.mem.indexOf(u8, rule, "`---`") != null);

    const list_src = "$- item$";
    const list = try preprocess(std.testing.allocator, list_src);
    defer std.testing.allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "`- item`") != null);

    const ordered_src = "$1. item$";
    const ordered = try preprocess(std.testing.allocator, ordered_src);
    defer std.testing.allocator.free(ordered);
    try std.testing.expect(std.mem.indexOf(u8, ordered, "`1. item`") != null);
}

test "indented code nested inside unordered list item is preserved verbatim" {
    const src = "- Example:\n\n        const formula = \"$x^2$\";";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "        const formula = \"$x^2$\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x²") == null);
}

test "indented code nested inside ordered list item is preserved verbatim" {
    const src = "1. Example:\n\n        const formula = \"$x^2$\";";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "        const formula = \"$x^2$\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x²") == null);
}

test "indented list continuation math is rendered" {
    const src = "- Formula:\n    $x^2$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "    x²") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    $x^2$") == null);
}

test "digit-prefixed double dollars stay prose" {
    const src = "cost $$5 total$$ today";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "unfinished blockquoted code fence preserves quoted lines" {
    const src = "> ```sh\n> echo $HOME$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "blockquoted code fence preserves quoted shell variables through close" {
    const src = "> ```sh\n> echo $HOME$\n> ```\nthen $x$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "> echo $HOME$") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "then x") != null);
}

test "currency dollar does not pair with following formula opener" {
    const src = "Costs $5; x=$x$.";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Costs $5; x=x.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Costs 5; x=x$.") == null);
}

test "long list continuations avoid quadratic backscan and render math" {
    const src = "- Item:\n    $a$\n    $b$\n    $c$\n    $d$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "    a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    d") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$d$") == null);
}

test "digit-prefixed formulas with math separators render" {
    const src = "$2 + 3$ and $$10 \\times 4$$ and $2,000$ and $1:2$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "2 + 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "> 10 × 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "2,000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1:2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$2 + 3$") == null);
}

test "list context survives ordinary continuation lines" {
    const src = "- Formula:\n  explanation\n    $x^2$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "    x²") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    $x^2$") == null);
}

test "nested blockquote code fence preserves quoted lines" {
    const src = "> > ```sh\n> > echo $HOME$";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "blockquote-indented code is preserved verbatim" {
    const src = ">     const formula = \"$x^2$\";";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "tilde-fenced mermaid block renders like backtick mermaid" {
    const src = "~~~mermaid\nflowchart TD\n  A --> B\n~~~";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "**Mermaid diagram: flowchart**") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "> flowchart TD") != null);
}

test "tilde-fenced non-mermaid block stays verbatim" {
    const src = "~~~sh\necho $x$\n~~~";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "hyphenated prose after math renders" {
    const src = "the $x$-axis";
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "the x-axis") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$x$") == null);
}

test "digit-prefixed algebraic coefficients render" {
    const inline_src = "scale by $2x$";
    const inline_out = try preprocess(std.testing.allocator, inline_src);
    defer std.testing.allocator.free(inline_out);
    try std.testing.expect(std.mem.indexOf(u8, inline_out, "scale by 2x") != null);
    try std.testing.expect(std.mem.indexOf(u8, inline_out, "$2x$") == null);

    const display_src = "$$10xy$$";
    const display_out = try preprocess(std.testing.allocator, display_src);
    defer std.testing.allocator.free(display_out);
    try std.testing.expect(std.mem.indexOf(u8, display_out, "> 10xy") != null);
    try std.testing.expect(std.mem.indexOf(u8, display_out, "$$10xy$$") == null);
}

test "emphasis-delimited math is protected only when truly enclosed" {
    const flanking = "**left** $a*b$ **right**";
    const flanking_out = try preprocess(std.testing.allocator, flanking);
    defer std.testing.allocator.free(flanking_out);
    try std.testing.expect(std.mem.indexOf(u8, flanking_out, "`a*b`") != null);
    try std.testing.expect(std.mem.indexOf(u8, flanking_out, "$a*b$") == null);

    const enclosed = "**Energy: $E=mc^2$**";
    const enclosed_out = try preprocess(std.testing.allocator, enclosed);
    defer std.testing.allocator.free(enclosed_out);
    try std.testing.expect(std.mem.indexOf(u8, enclosed_out, "**Energy: E=mc²**") != null);
    try std.testing.expect(std.mem.indexOf(u8, enclosed_out, "`E=mc²`") == null);

    const italic_flanking = "*left* $a*b$ *right*";
    const italic_out = try preprocess(std.testing.allocator, italic_flanking);
    defer std.testing.allocator.free(italic_out);
    try std.testing.expect(std.mem.indexOf(u8, italic_out, "`a*b`") != null);
}

test "many inline formulas on one line do not rescans quadratically" {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    const part = "$a_i$ ";
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        std.mem.copyForwards(u8, buf[len..], part);
        len += part.len;
    }
    const src = buf[0..len];
    const out = try preprocess(std.testing.allocator, src);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "$a_i$") == null);
    try std.testing.expect(std.mem.count(u8, out, "aᵢ") == 200);
}

