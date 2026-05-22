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
