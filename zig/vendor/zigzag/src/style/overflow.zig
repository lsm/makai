
const std = @import("std");
const Writer = std.Io.Writer;
const measure = @import("../layout/measure.zig");

pub const Overflow = enum {
    visible,
    hidden,
    ellipsis,
    word_wrap,
    char_wrap,
};

pub fn applyOverflow(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: u16,
    policy: Overflow,
) ![]const u8 {
    if (policy == .visible or max_width == 0) return text;

    var result: std.array_list.Managed(u8) = .init(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) try result.append('\n');
        first_line = false;

        switch (policy) {
            .hidden => try applyClip(&result, line, max_width),
            .ellipsis => try applyEllipsis(&result, line, max_width),
            .word_wrap => try applyWordWrap(&result, line, max_width),
            .char_wrap => try applyCharWrap(&result, line, max_width),
            .visible => unreachable,
        }
    }

    return result.toOwnedSlice();
}

fn applyClip(result: *std.array_list.Managed(u8), line: []const u8, max_width: u16) !void {
    var visible_width: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            const seq_start = i;
            i += 2;
            while (i < line.len and line[i] != 'm' and line[i] != 'H' and line[i] != 'J' and line[i] != 'K' and line[i] != 'A' and line[i] != 'B' and line[i] != 'C' and line[i] != 'D') : (i += 1) {}
            if (i < line.len) i += 1;
            try result.appendSlice(line[seq_start..i]);
            continue;
        }

        const char_width = charDisplayWidth(line, i);
        if (visible_width + char_width > max_width) break;

        const byte_len = charByteLen(line[i]);
        try result.appendSlice(line[i .. i + byte_len]);
        visible_width += char_width;
        i += byte_len;
    }
}

fn applyEllipsis(result: *std.array_list.Managed(u8), line: []const u8, max_width: u16) !void {
    const line_width = measure.width(line);
    if (line_width <= max_width) {
        try result.appendSlice(line);
        return;
    }

    if (max_width <= 1) {
        if (max_width == 1) try result.appendSlice("\xe2\x80\xa6");
        return;
    }

    var visible_width: usize = 0;
    var i: usize = 0;
    const target_width = max_width - 1;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            const seq_start = i;
            i += 2;
            while (i < line.len and line[i] != 'm' and line[i] != 'H' and line[i] != 'J' and line[i] != 'K' and line[i] != 'A' and line[i] != 'B' and line[i] != 'C' and line[i] != 'D') : (i += 1) {}
            if (i < line.len) i += 1;
            try result.appendSlice(line[seq_start..i]);
            continue;
        }

        const char_width = charDisplayWidth(line, i);
        if (visible_width + char_width > target_width) break;

        const byte_len = charByteLen(line[i]);
        try result.appendSlice(line[i .. i + byte_len]);
        visible_width += char_width;
        i += byte_len;
    }

    try result.appendSlice("\xe2\x80\xa6");
}

fn applyWordWrap(result: *std.array_list.Managed(u8), line: []const u8, max_width: u16) !void {
    if (measure.width(line) <= max_width) {
        try result.appendSlice(line);
        return;
    }

    var visible_width: usize = 0;
    var i: usize = 0;
    var line_start = true;

    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            const seq_start = i;
            i += 2;
            while (i < line.len and line[i] != 'm' and line[i] != 'H' and line[i] != 'J' and line[i] != 'K' and line[i] != 'A' and line[i] != 'B' and line[i] != 'C' and line[i] != 'D') : (i += 1) {}
            if (i < line.len) i += 1;
            try result.appendSlice(line[seq_start..i]);
            continue;
        }

        if (line[i] == ' ') {
            if (visible_width + 1 > max_width) {
                try result.append('\n');
                visible_width = 0;
                line_start = true;
                i += 1;
                while (i < line.len and line[i] == ' ') : (i += 1) {}
                continue;
            }
            if (!line_start) {
                try result.append(' ');
                visible_width += 1;
            }
            i += 1;
            continue;
        }

        const word_start = i;
        var word_width: usize = 0;
        while (i < line.len and line[i] != ' ') {
            if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
                i += 2;
                while (i < line.len and line[i] != 'm' and line[i] != 'H' and line[i] != 'J' and line[i] != 'K' and line[i] != 'A' and line[i] != 'B' and line[i] != 'C' and line[i] != 'D') : (i += 1) {}
                if (i < line.len) i += 1;
                continue;
            }
            word_width += charDisplayWidth(line, i);
            i += charByteLen(line[i]);
        }
        const word = line[word_start..i];

        if (!line_start and visible_width + word_width > max_width) {
            try result.append('\n');
            visible_width = 0;
            line_start = true;
        }

        try result.appendSlice(word);
        visible_width += word_width;
        line_start = false;
    }
}

fn applyCharWrap(result: *std.array_list.Managed(u8), line: []const u8, max_width: u16) !void {
    if (measure.width(line) <= max_width) {
        try result.appendSlice(line);
        return;
    }

    var visible_width: usize = 0;
    var i: usize = 0;
    var first_on_line = true;

    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            const seq_start = i;
            i += 2;
            while (i < line.len and line[i] != 'm' and line[i] != 'H' and line[i] != 'J' and line[i] != 'K' and line[i] != 'A' and line[i] != 'B' and line[i] != 'C' and line[i] != 'D') : (i += 1) {}
            if (i < line.len) i += 1;
            try result.appendSlice(line[seq_start..i]);
            continue;
        }

        const char_width = charDisplayWidth(line, i);
        if (visible_width + char_width > max_width and !first_on_line) {
            try result.append('\n');
            visible_width = 0;
            first_on_line = true;
        }

        const byte_len = charByteLen(line[i]);
        try result.appendSlice(line[i .. i + byte_len]);
        visible_width += char_width;
        first_on_line = false;
        i += byte_len;
    }
}

fn charDisplayWidth(text: []const u8, pos: usize) usize {
    const byte = text[pos];
    if (byte < 0x80) return 1;
    const byte_len = charByteLen(byte);
    if (byte_len >= 3 and pos + byte_len <= text.len) {
        const cp = std.unicode.utf8Decode(text[pos..][0..byte_len]) catch return 1;
        if (isWideCodepoint(cp)) return 2;
    }
    return 1;
}

fn isWideCodepoint(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0x303E) or
        (cp >= 0x3041 and cp <= 0x33BF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF01 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x20000 and cp <= 0x2FFFD) or
        (cp >= 0x30000 and cp <= 0x3FFFD);
}

fn charByteLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte & 0xE0 == 0xC0) return 2;
    if (first_byte & 0xF0 == 0xE0) return 3;
    if (first_byte & 0xF8 == 0xF0) return 4;
    return 1;
}

test "clip truncates at max width" {
    const allocator = std.testing.allocator;
    const result = try applyOverflow(allocator, "Hello, World!", 5, .hidden);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "ellipsis adds character" {
    const allocator = std.testing.allocator;
    const result = try applyOverflow(allocator, "Hello, World!", 6, .ellipsis);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello\xe2\x80\xa6", result);
}

test "visible returns original" {
    const allocator = std.testing.allocator;
    const result = try applyOverflow(allocator, "Hello", 3, .visible);
    try std.testing.expectEqualStrings("Hello", result);
}

test "short text unchanged with ellipsis" {
    const allocator = std.testing.allocator;
    const result = try applyOverflow(allocator, "Hi", 10, .ellipsis);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hi", result);
}
