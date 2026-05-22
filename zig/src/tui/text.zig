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

pub fn truncateToWidth(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");
    if (visibleWidth(text) <= max_width) return allocator.dupe(u8, text);
    if (max_width <= 1) return allocator.dupe(u8, ellipsis);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    const target = max_width - 1;
    var width: usize = 0;
    var i: usize = 0;
    var open_sgr = false;

    while (i < text.len and width < target) {
        if (text[i] == 0x1b) {
            const start = i;
            try copyAnsiSequence(writer, text, &i);
            if (i > start and isSgrSequence(text[start..i])) open_sgr = true;
            continue;
        }
        if (text[i] == '\n') break;

        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch text[i];
        const cw = zz.measure.charWidth(@intCast(codepoint));
        if (width + cw > target) break;
        try writer.writeAll(text[i .. i + len]);
        width += cw;
        i += len;
    }

    try writer.writeAll(ellipsis);
    if (open_sgr) try writer.writeAll(zz.ansi.reset);
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
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) return;
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

test "visibleWidth ignores ANSI" {
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("\x1b[31mhello\x1b[0m"));
}

test "truncateToWidth preserves ANSI and width" {
    const text = try truncateToWidth(std.testing.allocator, "\x1b[31mhello world\x1b[0m", 6);
    defer std.testing.allocator.free(text);
    try std.testing.expect(visibleWidth(text) <= 6);
    try std.testing.expect(std.mem.indexOf(u8, text, ellipsis) != null);
}

test "wrapTextWithAnsi wraps words" {
    const text = try wrapTextWithAnsi(std.testing.allocator, "alpha beta gamma", 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("alpha beta\ngamma", text);
}
