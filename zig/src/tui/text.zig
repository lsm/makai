const std = @import("std");
const zz = @import("zigzag");

const ellipsis = "…";

pub fn visibleWidth(text: []const u8) usize {
    return zz.width(text);
}

pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

pub fn compactNumber(allocator: std.mem.Allocator, value: u64) ![]u8 {
    if (value >= 1_000_000) return std.fmt.allocPrint(allocator, "{d}M", .{value / 1_000_000});
    if (value >= 1_000) return std.fmt.allocPrint(allocator, "{d}k", .{value / 1_000});
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

pub fn truncateToWidth(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    return truncateLineToWidth(allocator, text, max_width);
}

pub fn truncateLineToWidth(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");
    if (visibleWidth(text) <= max_width and std.mem.indexOfScalar(u8, text, '\n') == null) return allocator.dupe(u8, text);
    if (max_width <= 1) return allocator.dupe(u8, ellipsis);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    const target = max_width - 1;
    var width: usize = 0;
    var i: usize = 0;
    var open_sgr = false;
    var truncated = false;

    while (i < text.len and width < target) {
        if (text[i] == 0x1b) {
            const start = i;
            try copyAnsiSequence(writer, text, &i);
            if (i > start and isSgrSequence(text[start..i])) open_sgr = true;
            continue;
        }
        if (text[i] == '\n') {
            truncated = true;
            break;
        }

        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch text[i];
        const cw = zz.measure.charWidth(@intCast(codepoint));
        if (width + cw > target) {
            truncated = true;
            break;
        }
        try writer.writeAll(text[i .. i + len]);
        width += cw;
        i += len;
    }

    if (i < text.len or truncated) try writer.writeAll(ellipsis);
    if (open_sgr) try writer.writeAll(zz.ansi.reset);
    return out.toOwnedSlice();
}

pub fn flattenNewlines(allocator: std.mem.Allocator, text: []const u8, separator: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeAll(separator);
        first = false;
        try writer.writeAll(line);
    }
    return out.toOwnedSlice();
}

pub fn truncateMultilineToBudget(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");
    if (visibleWidth(text) <= max_width) return allocator.dupe(u8, text);
    if (max_width <= 1) return allocator.dupe(u8, ellipsis);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var remaining = max_width;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    var source_has_more = false;
    while (lines.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        if (remaining <= 1) {
            source_has_more = true;
            break;
        }
        const line_width = visibleWidth(line);
        const budget = @min(remaining, line_width + 1);
        const clipped = try truncateLineToWidth(allocator, line, budget);
        defer allocator.free(clipped);
        try writer.writeAll(clipped);
        const consumed = @min(remaining, visibleWidth(clipped));
        remaining -|= consumed;
        if (line_width > budget or remaining == 0) {
            source_has_more = true;
            break;
        }
    }
    if (source_has_more and remaining > 0) try writer.writeAll(ellipsis);
    return out.toOwnedSlice();
}

pub fn truncateLinesToWidth(allocator: std.mem.Allocator, text: []const u8, line_width: usize, max_lines: usize) ![]u8 {
    if (line_width == 0 or max_lines == 0) return allocator.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var row: usize = 0;
    while (row < max_lines) : (row += 1) {
        const line = lines.next() orelse break;
        if (row > 0) try writer.writeByte('\n');
        const has_more_lines = row + 1 == max_lines and lines.peek() != null;
        const width = if (has_more_lines) line_width -| 1 else line_width;
        const clipped = try truncateLineToWidth(allocator, line, width);
        defer allocator.free(clipped);
        try writer.writeAll(clipped);
        if (has_more_lines) try writer.writeAll(ellipsis);
    }
    return out.toOwnedSlice();
}

pub fn wrapTextWithAnsi(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (max_width == 0 or text.len == 0) return allocator.dupe(u8, text);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var line_width: usize = 0;
    var word = std.ArrayList(u8).empty;
    defer word.deinit(allocator);
    var word_width: usize = 0;
    var pending_space = false;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const start = i;
            var sink: std.Io.Writer.Allocating = .init(allocator);
            defer sink.deinit();
            try copyAnsiSequence(&sink.writer, text, &i);
            try word.appendSlice(allocator, sink.written());
            _ = start;
            continue;
        }

        const c = text[i];
        if (c == '\n') {
            try flushWord(writer, &word, word_width, &line_width, max_width, pending_space);
            word_width = 0;
            pending_space = false;
            try writer.writeByte('\n');
            line_width = 0;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            try flushWord(writer, &word, word_width, &line_width, max_width, pending_space);
            word_width = 0;
            pending_space = line_width > 0;
            i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch c;
        const cw = zz.measure.charWidth(@intCast(codepoint));
        try word.appendSlice(allocator, text[i .. i + len]);
        word_width += cw;
        i += len;
    }

    try flushWord(writer, &word, word_width, &line_width, max_width, pending_space);
    return out.toOwnedSlice();
}

fn flushWord(writer: *std.Io.Writer, word: *std.ArrayList(u8), word_width: usize, line_width: *usize, max_width: usize, pending_space: bool) !void {
    if (word.items.len == 0) return;
    const sep: usize = if (pending_space and line_width.* > 0) 1 else 0;
    if (line_width.* > 0 and line_width.* + sep + word_width > max_width) {
        try writer.writeByte('\n');
        line_width.* = 0;
    } else if (sep == 1) {
        try writer.writeByte(' ');
        line_width.* += 1;
    }
    try writer.writeAll(word.items);
    line_width.* += word_width;
    word.clearRetainingCapacity();
}

/// Word-wrap `text` to `max_width` while preserving line-oriented block prefixes
/// produced by ZigZag's markdown renderer (list bullets, code-block bars, ordered
/// list numbers, and plain leading spaces). ANSI sequences are treated as zero-width
/// and are never split; words that exceed the available width are hard-split.
pub fn wrapTextPreservingPrefix(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (max_width == 0 or text.len == 0) return allocator.dupe(u8, text);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        const prefix = linePrefix(line);
        try wrapLineWithPrefix(writer, allocator, line, prefix, max_width);
    }

    return out.toOwnedSlice();
}

const LinePrefix = struct {
    first_bytes: []const u8,
    width: usize,
    content_start: usize,
    continuation_is_bar: bool,
};

fn linePrefix(line: []const u8) LinePrefix {
    var i: usize = 0;
    var leading_spaces: usize = 0;
    while (i < line.len) {
        if (line[i] == ' ') {
            leading_spaces += 1;
            i += 1;
            continue;
        }
        if (line[i] == 0x1b) {
            skipAnsiSequence(line, &i);
            continue;
        }
        break;
    }

    if (i < line.len) {
        const char_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const cp = if (i + char_len <= line.len)
            std.unicode.utf8Decode(line[i .. i + char_len]) catch line[i]
        else
            line[i];

        if (cp == '•' or cp == '│') {
            const after = i + char_len;
            const include_space = after < line.len and line[after] == ' ';
            const end = if (include_space) after + 1 else after;
            return .{
                .first_bytes = line[0..end],
                .width = leading_spaces + 1 + @as(usize, if (include_space) 1 else 0),
                .content_start = end,
                .continuation_is_bar = cp == '│',
            };
        }

        if (cp >= '0' and cp <= '9') {
            var j = i;
            while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
            if (j + 1 < line.len and line[j] == '.' and line[j + 1] == ' ') {
                const num_width = j - i;
                const end = j + 2;
                return .{
                    .first_bytes = line[0..end],
                    .width = leading_spaces + num_width + 2,
                    .content_start = end,
                    .continuation_is_bar = false,
                };
            }
        }
    }

    return .{ .first_bytes = "", .width = 0, .content_start = 0, .continuation_is_bar = false };
}

fn wrapLineWithPrefix(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    line: []const u8,
    prefix: LinePrefix,
    max_width: usize,
) !void {
    const prefix_fits = prefix.width < max_width;

    if (prefix_fits) {
        try writer.writeAll(prefix.first_bytes);
    } else if (prefix.content_start < line.len) {
        // The prefix alone is too wide for the viewport. Show as much of it as
        // fits, then continue the content on the next line without a prefix.
        const truncated = try truncateLineToWidth(allocator, prefix.first_bytes, max_width);
        defer allocator.free(truncated);
        try writer.writeAll(truncated);
        try writer.writeByte('\n');
    } else {
        // The line is only a prefix; truncate it to the viewport.
        const truncated = try truncateLineToWidth(allocator, prefix.first_bytes, max_width);
        defer allocator.free(truncated);
        try writer.writeAll(truncated);
        return;
    }

    const avail = if (prefix_fits) max_width - prefix.width else max_width;

    var cont_prefix_buf: ?[]u8 = null;
    defer if (cont_prefix_buf) |buf| allocator.free(buf);
    const cont_prefix: []const u8 = if (!prefix_fits)
        ""
    else if (prefix.continuation_is_bar)
        prefix.first_bytes
    else blk: {
        const buf = try allocator.alloc(u8, prefix.width);
        cont_prefix_buf = buf;
        @memset(buf, ' ');
        break :blk buf;
    };

    var word = std.ArrayList(u8).empty;
    defer word.deinit(allocator);
    var word_width: usize = 0;
    var word_has_visible = false;
    var col: usize = 0;
    var pending_space = false;

    var i = prefix.content_start;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            var sink: std.Io.Writer.Allocating = .init(allocator);
            defer sink.deinit();
            try copyAnsiSequence(&sink.writer, line, &i);
            try word.appendSlice(allocator, sink.written());
            continue;
        }

        const c = line[i];
        if (c == ' ' or c == '\t') {
            if (!word_has_visible) {
                // Preserve spaces that belong to a style-only prefix or indentation.
                try word.appendSlice(allocator, " ");
                word_width += 1;
            } else {
                try flushWordWithPrefix(writer, cont_prefix, &word, word_width, &col, &pending_space, avail);
                word_width = 0;
                word_has_visible = false;
                pending_space = true;
            }
            i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + len > line.len) break;
        const codepoint = std.unicode.utf8Decode(line[i .. i + len]) catch c;
        const cw = zz.measure.charWidth(@intCast(codepoint));

        if (word_width + cw > avail and word_width > 0) {
            try flushWordWithPrefix(writer, cont_prefix, &word, word_width, &col, &pending_space, avail);
            word_width = 0;
            word_has_visible = false;
            pending_space = false;
        }

        try word.appendSlice(allocator, line[i .. i + len]);
        word_width += cw;
        word_has_visible = true;
        i += len;
    }

    try flushWordWithPrefix(writer, cont_prefix, &word, word_width, &col, &pending_space, avail);
}

fn flushWordWithPrefix(
    writer: *std.Io.Writer,
    prefix: []const u8,
    word: *std.ArrayList(u8),
    word_width: usize,
    col: *usize,
    pending_space: *bool,
    avail: usize,
) !void {
    if (word.items.len == 0) return;
    const sep: usize = if (pending_space.* and col.* > 0) 1 else 0;
    if (col.* + sep + word_width > avail) {
        try writer.writeByte('\n');
        try writer.writeAll(prefix);
        col.* = 0;
        pending_space.* = false;
    } else if (sep == 1) {
        try writer.writeByte(' ');
        col.* += 1;
    }
    try writer.writeAll(word.items);
    col.* += word_width;
    word.clearRetainingCapacity();
}

fn skipAnsiSequence(text: []const u8, index: *usize) void {
    if (index.* >= text.len or text[index.*] != 0x1b) return;
    index.* += 1;
    if (index.* >= text.len) return;
    const second = text[index.*];
    index.* += 1;

    if (second == '[') {
        while (index.* < text.len) {
            const c = text[index.*];
            index.* += 1;
            if (c >= 0x40 and c <= 0x7e) return;
        }
        return;
    }
    if (second == ']') {
        while (index.* < text.len) {
            const c = text[index.*];
            index.* += 1;
            if (c == 0x07) return;
            if (c == 0x1b and index.* < text.len and text[index.*] == '\\') {
                index.* += 1;
                return;
            }
        }
        return;
    }
    if (second >= '(' and second <= '+') {
        if (index.* < text.len) index.* += 1;
        return;
    }
    if (second == 'P') {
        while (index.* < text.len) {
            const c = text[index.*];
            index.* += 1;
            if (c == 0x07) return;
            if (c == 0x1b and index.* < text.len and text[index.*] == '\\') {
                index.* += 1;
                return;
            }
        }
        return;
    }
}

fn copyAnsiSequence(writer: *std.Io.Writer, text: []const u8, index: *usize) !void {
    const start = index.*;
    try writer.writeByte(text[index.*]);
    index.* += 1;
    if (index.* >= text.len) return;
    try writer.writeByte(text[index.*]);
    const second = text[index.*];
    index.* += 1;

    if (second == '[') {
        while (index.* < text.len) {
            const c = text[index.*];
            try writer.writeByte(c);
            index.* += 1;
            if (c >= 0x40 and c <= 0x7e) return;
        }
        return;
    }
    if (second == ']') {
        while (index.* < text.len) {
            const c = text[index.*];
            try writer.writeByte(c);
            index.* += 1;
            if (c == 0x07) return;
            if (c == 0x1b and index.* < text.len and text[index.*] == '\\') {
                try writer.writeByte(text[index.*]);
                index.* += 1;
                return;
            }
        }
        return;
    }
    // SCS: ESC ( ) * + — followed by one more byte
    if (second >= '(' and second <= '+') {
        if (index.* < text.len) {
            try writer.writeByte(text[index.*]);
            index.* += 1;
        }
        return;
    }
    // DCS: ESC P — followed by string until ST (ESC \) or BEL
    if (second == 'P') {
        while (index.* < text.len) {
            const c = text[index.*];
            try writer.writeByte(c);
            index.* += 1;
            if (c == 0x07) return;
            if (c == 0x1b and index.* < text.len and text[index.*] == '\\') {
                try writer.writeByte(text[index.*]);
                index.* += 1;
                return;
            }
        }
        return;
    }
    _ = start;
}

fn isSgrSequence(seq: []const u8) bool {
    return seq.len >= 3 and seq[0] == 0x1b and seq[1] == '[' and seq[seq.len - 1] == 'm';
}

test "compactNumber formats suffixes" {
    const small = try compactNumber(std.testing.allocator, 42);
    defer std.testing.allocator.free(small);
    try std.testing.expectEqualStrings("42", small);
    const thousands = try compactNumber(std.testing.allocator, 12_345);
    defer std.testing.allocator.free(thousands);
    try std.testing.expectEqualStrings("12k", thousands);
    const millions = try compactNumber(std.testing.allocator, 2_000_000);
    defer std.testing.allocator.free(millions);
    try std.testing.expectEqualStrings("2M", millions);
}

test "visibleWidth ignores ANSI" {
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("\x1b[31mhello\x1b[0m"));
}

test "truncateToWidth preserves ANSI and width" {
    const text = try truncateToWidth(std.testing.allocator, "\x1b[31mhello world\x1b[0m", 6);
    defer std.testing.allocator.free(text);
    try std.testing.expect(visibleWidth(text) <= 6);
    try std.testing.expect(std.mem.indexOf(u8, text, ellipsis) != null);
}

test "flattenNewlines joins rows for single-line transcript entries" {
    const text = try flattenNewlines(std.testing.allocator, "alpha\nbeta", " / ");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("alpha / beta", text);
}

test "truncateMultilineToBudget preserves newline before clipping" {
    const text = try truncateMultilineToBudget(std.testing.allocator, "alpha\nbeta gamma", 10);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') != null);
}

test "truncateLinesToWidth caps output to max lines" {
    const text = try truncateLinesToWidth(std.testing.allocator, "one\ntwo\nthree\nfour", 10, 3);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 3), lineCount(text));
    try std.testing.expect(std.mem.indexOf(u8, text, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ellipsis) != null);
}

test "truncateToWidth accepts CSI tilde terminator" {
    const text = try truncateToWidth(std.testing.allocator, "\x1b[1~hello", 5);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
}

test "wrapTextWithAnsi accepts CSI tilde terminator" {
    const text = try wrapTextWithAnsi(std.testing.allocator, "\x1b[1~alpha beta", 20);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "beta") != null);
}

test "wrapTextWithAnsi wraps words" {
    const text = try wrapTextWithAnsi(std.testing.allocator, "alpha beta gamma", 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("alpha beta\ngamma", text);
}

test "wrapTextPreservingPrefix preserves list bullet on continuation" {
    const text = try wrapTextPreservingPrefix(std.testing.allocator, "• alpha beta gamma", 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("• alpha\n  beta\n  gamma", text);
}

test "wrapTextPreservingPrefix preserves ordered list prefix" {
    const text = try wrapTextPreservingPrefix(std.testing.allocator, "12. alpha beta gamma", 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("12. alpha\n    beta\n    gamma", text);
}

test "wrapTextPreservingPrefix is ANSI aware" {
    const text = try wrapTextPreservingPrefix(std.testing.allocator, "\x1b[31m• alpha beta\x1b[0m gamma", 10);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[31m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gamma") != null);
    try std.testing.expect(visibleWidth(text) <= 10);
}

test "wrapTextPreservingPrefix hard-splits long words" {
    const text = try wrapTextPreservingPrefix(std.testing.allocator, "• abcdefghijklmnopqrstuvwxyz", 10);
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(visibleWidth(line) <= 10);
    }
}

test "wrapTextPreservingPrefix truncates a prefix wider than the viewport" {
    const text = try wrapTextPreservingPrefix(std.testing.allocator, "12345678. item here", 8);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "item") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "here") != null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(visibleWidth(line) <= 8);
    }
}

test "wrapTextPreservingPrefix preserves code block bar" {
    const text = try wrapTextPreservingPrefix(std.testing.allocator, "│ alpha beta gamma", 10);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "│ "));
    try std.testing.expectEqualStrings("│ alpha\n│ beta\n│ gamma", text);
}
