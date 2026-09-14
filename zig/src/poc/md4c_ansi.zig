const std = @import("std");
const c = @cImport({
    @cInclude("md4c.h");
});

const reset = "\x1b[0m";

const SpanKind = enum { bold, italic, code, del, link };

const tab_width: usize = 8;

fn spanSgr(kind: SpanKind) []const u8 {
    return switch (kind) {
        .bold => "1",
        .italic => "3",
        .code => "33",
        .del => "2;9",
        .link => "36;4",
    };
}

fn headingSgr(level: usize) []const u8 {
    return switch (level) {
        1 => "1;4;95",
        2 => "1;96",
        3 => "1;92",
        else => "1;94",
    };
}

const AnsiRenderer = struct {
    allocator: std.mem.Allocator,
    width: usize,
    out: std.Io.Writer.Allocating,
    row: std.ArrayList(u8),
    row_w: usize,
    span_stack: std.ArrayList(SpanKind),
    heading_level: usize,
    list_depth: usize,
    li_ordered: bool,
    ol_number: usize,
    indent_bytes: std.ArrayList(u8),
    indent_width: usize,
    quote_lens: std.ArrayList(usize),
    bullet_bytes: std.ArrayList(u8),
    bullet_width: usize,
    bullet_used: bool,
    link_href: []const u8,
    in_code: bool,
    need_blank: bool,
    row_open: bool,
    pending_sep: bool,
    style_dirty: bool,
    row_styled: bool,
    code_newlines: usize,

    fn init(allocator: std.mem.Allocator, width: usize) AnsiRenderer {
        return .{
            .allocator = allocator,
            .width = width,
            .out = .init(allocator),
            .row = .empty,
            .row_w = 0,
            .span_stack = .empty,
            .heading_level = 0,
            .list_depth = 0,
            .li_ordered = false,
            .ol_number = 1,
            .indent_bytes = .empty,
            .indent_width = 0,
            .quote_lens = .empty,
            .bullet_bytes = .empty,
            .bullet_width = 0,
            .bullet_used = false,
            .link_href = "",
            .in_code = false,
            .need_blank = false,
            .row_open = false,
            .pending_sep = false,
            .style_dirty = false,
            .row_styled = false,
            .code_newlines = 0,
        };
    }

    fn deinit(self: *AnsiRenderer) void {
        self.out.deinit();
        self.row.deinit(self.allocator);
        self.span_stack.deinit(self.allocator);
        self.indent_bytes.deinit(self.allocator);
        self.quote_lens.deinit(self.allocator);
        self.bullet_bytes.deinit(self.allocator);
    }

    fn openSgr(self: *AnsiRenderer, allocator: std.mem.Allocator) ![]const u8 {
        if (self.span_stack.items.len == 0 and self.heading_level == 0) return "";
        var buf: std.Io.Writer.Allocating = .init(allocator);
        try buf.writer.writeAll("\x1b[");
        var first = true;
        if (self.heading_level > 0) {
            try buf.writer.writeAll(headingSgr(self.heading_level));
            first = false;
        }
        for (self.span_stack.items) |kind| {
            if (!first) try buf.writer.writeByte(';');
            try buf.writer.writeAll(spanSgr(kind));
            first = false;
        }
        try buf.writer.writeByte('m');
        return buf.toOwnedSlice();
    }

    fn prefixWidth(self: *const AnsiRenderer) usize {
        return self.indent_width + (if (self.bullet_used) 0 else self.bullet_width);
    }

    fn emitStyle(self: *AnsiRenderer) !void {
        const sgr = try self.openSgr(self.allocator);
        defer self.allocator.free(sgr);
        if (sgr.len > 0 and !self.row_styled) {
            try self.row.appendSlice(self.allocator, sgr);
            self.row_styled = true;
        } else if (sgr.len == 0 and self.row_styled) {
            try self.row.appendSlice(self.allocator, reset);
            self.row_styled = false;
        }
        self.style_dirty = false;
    }

    fn flushRow(self: *AnsiRenderer) !void {
        if (!self.row_open or self.row.items.len == 0) {
            self.pending_sep = false;
            return;
        }
        if (self.need_blank) try self.out.writer.writeByte('\n');
        self.need_blank = false;
        try self.out.writer.writeAll(self.row.items);
        try self.out.writer.writeAll(reset);
        try self.out.writer.writeByte('\n');
        self.row.clearRetainingCapacity();
        self.row_w = 0;
        self.row_open = false;
        self.pending_sep = false;
        self.style_dirty = true;
        self.row_styled = false;
    }

    fn startRowIfNeeded(self: *AnsiRenderer) !void {
        if (self.row_open) return;
        self.row_open = true;
        try self.row.appendSlice(self.allocator, self.indent_bytes.items);
        self.row_w += self.indent_width;
        if (!self.bullet_used and self.bullet_bytes.items.len > 0) {
            try self.row.appendSlice(self.allocator, self.bullet_bytes.items);
            self.row_w += self.bullet_width;
            self.bullet_used = true;
        }
        self.style_dirty = true;
        self.row_styled = false;
    }

    fn appendWord(self: *AnsiRenderer, word: []const u8, word_w: usize) !void {
        if (word.len == 0) return;
        try self.startRowIfNeeded();
        var sep: usize = if (self.pending_sep and self.row_w > self.prefixWidth()) 1 else 0;
        if (self.row_w + sep + word_w > self.width and self.row_w > self.prefixWidth()) {
            try self.flushRow();
            try self.startRowIfNeeded();
            sep = 0;
        }
        if (self.style_dirty and self.span_stack.items.len == 0 and self.heading_level == 0) {
            try self.emitStyle();
        }
        if (sep == 1) {
            try self.row.append(self.allocator, ' ');
            self.row_w += 1;
        }
        self.pending_sep = false;
        if (self.style_dirty) try self.emitStyle();
        if (word_w > self.width) {
            var i: usize = 0;
            while (i < word.len) {
                if (self.row_w >= self.width) {
                    try self.flushRow();
                    try self.startRowIfNeeded();
                    if (self.style_dirty) try self.emitStyle();
                }
                const len = std.unicode.utf8ByteSequenceLength(word[i]) catch 1;
                const take = @min(len, word.len - i);
                try self.row.appendSlice(self.allocator, word[i .. i + take]);
                self.row_w += 1;
                i += take;
            }
            return;
        }
        try self.row.appendSlice(self.allocator, word);
        self.row_w += word_w;
    }

    fn appendProse(self: *AnsiRenderer, text: []const u8) !void {
        var i: usize = 0;
        var word_start: ?usize = null;
        while (i <= text.len) : (i += 1) {
            const is_sep = i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n');
            if (is_sep) {
                if (word_start) |ws| {
                    try self.appendWord(text[ws..i], visibleWidth(text[ws..i]));
                    word_start = null;
                }
                if (self.row_open) self.pending_sep = true;
                continue;
            }
            if (i == text.len) {
                if (word_start) |ws| try self.appendWord(text[ws..i], visibleWidth(text[ws..i]));
                break;
            }
            if (word_start == null) word_start = i;
        }
    }

    fn ensureCodeRow(self: *AnsiRenderer) !void {
        while (self.code_newlines > 0) {
            try self.row.appendSlice(self.allocator, "\n  \x1b[2m");
            self.row_w = 2;
            self.code_newlines -= 1;
        }
    }

    fn appendCodeText(self: *AnsiRenderer, raw: []const u8) !void {
        const max_w = self.width -| 2;
        var i: usize = 0;
        while (i < raw.len) {
            const ch = raw[i];
            if (ch == '\n') {
                self.code_newlines += 1;
                i += 1;
                continue;
            }
            if (ch == 0x1b) {
                skipAnsi(raw, &i);
                continue;
            }
            if (ch == '\t') {
                try self.ensureCodeRow();
                const pad = tab_width - (self.row_w % tab_width);
                var remaining = pad;
                while (remaining > 0) {
                    var budget = max_w -| self.row_w;
                    if (budget == 0) {
                        self.code_newlines += 1;
                        try self.ensureCodeRow();
                        budget = max_w -| self.row_w;
                    }
                    const take = @min(budget, remaining);
                    for (0..take) |_| try self.row.append(self.allocator, ' ');
                    self.row_w += take;
                    remaining -= take;
                }
                i += 1;
                continue;
            }
            if (ch < 0x20 or ch == 0x7f) {
                i += 1;
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(ch) catch {
                i += 1;
                continue;
            };
            if (i + len > raw.len) break;
            const codepoint = std.unicode.utf8Decode(raw[i .. i + len]) catch {
                i += 1;
                continue;
            };
            if (codepoint >= 0x80 and codepoint <= 0x9f) {
                i += len;
                continue;
            }
            if (self.row_w >= max_w) {
                self.code_newlines += 1;
            }
            try self.ensureCodeRow();
            if (self.row_w < max_w) {
                try self.row.appendSlice(self.allocator, raw[i .. i + len]);
                self.row_w += 1;
            }
            i += len;
        }
    }

    fn finish(self: *AnsiRenderer) ![]const u8 {
        try self.flushRow();
        return self.out.toOwnedSlice();
    }
};

fn visibleWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            skipAnsi(text, &i);
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @min(len, text.len - i);
        w += 1;
    }
    return w;
}

fn skipAnsi(text: []const u8, index: *usize) void {
    if (index.* >= text.len or text[index.*] != 0x1b) return;
    index.* += 1;
    if (index.* >= text.len) return;
    const second = text[index.*];
    index.* += 1;
    if (second == '[') {
        while (index.* < text.len) {
            const ch = text[index.*];
            index.* += 1;
            if (ch >= 0x40 and ch <= 0x7e) return;
        }
        return;
    }
    if (second == ']' or second == 'P' or second == '_' or second == '^' or second == 'X') {
        while (index.* < text.len) {
            const ch = text[index.*];
            index.* += 1;
            if (ch == 0x07) return;
            if (ch == 0x1b and index.* < text.len and text[index.*] == '\\') {
                index.* += 1;
                return;
            }
        }
    }
}

fn sanitize(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == 0x1b) {
            skipAnsi(text, &i);
            continue;
        }
        if (ch == '\t') {
            try writer.writeByte(ch);
            i += 1;
            continue;
        }
        if (ch < 0x20 or ch == 0x7f) {
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(ch) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        if (codepoint >= 0x80 and codepoint <= 0x9f) {
            i += len;
            continue;
        }
        try writer.writeAll(text[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice();
}

fn expandTabs(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, line, '\t') == null) return allocator.dupe(u8, line);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\t') {
            const pad = tab_width - (col % tab_width);
            for (0..pad) |_| try out.writer.writeByte(' ');
            col += pad;
            i += 1;
            continue;
        }
        try out.writer.writeByte(line[i]);
        col += 1;
        i += 1;
    }
    return out.toOwnedSlice();
}

fn enterBlockCb(blocktype: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const self: *AnsiRenderer = @ptrCast(@alignCast(userdata.?));
    blk: {
        switch (blocktype) {
            c.MD_BLOCK_QUOTE => {
                self.flushRow() catch break :blk;
                self.quote_lens.append(self.allocator, self.indent_bytes.items.len) catch break :blk;
                self.indent_bytes.appendSlice(self.allocator, "│ ") catch break :blk;
                self.indent_width += 2;
            },
            c.MD_BLOCK_UL => {
                self.list_depth += 1;
                self.li_ordered = false;
            },
            c.MD_BLOCK_OL => {
                self.list_depth += 1;
                self.li_ordered = true;
                const ol: *const c.MD_BLOCK_OL_DETAIL = @ptrCast(@alignCast(detail.?));
                self.ol_number = ol.start;
            },
            c.MD_BLOCK_LI => {
                self.flushRow() catch break :blk;
                self.bullet_bytes.clearRetainingCapacity();
                const spaces = (self.list_depth - 1) * 2;
                self.bullet_bytes.appendNTimes(self.allocator, ' ', spaces) catch break :blk;
                if (self.li_ordered) {
                    const marker = std.fmt.allocPrint(self.allocator, "{d}. ", .{self.ol_number}) catch break :blk;
                    defer self.allocator.free(marker);
                    self.bullet_bytes.appendSlice(self.allocator, marker) catch break :blk;
                    self.ol_number += 1;
                } else {
                    self.bullet_bytes.appendSlice(self.allocator, "• ") catch break :blk;
                }
                self.bullet_width = visibleWidth(self.bullet_bytes.items);
                self.bullet_used = false;
            },
            c.MD_BLOCK_HR => {
                self.flushRow() catch break :blk;
                if (self.need_blank) self.out.writer.writeByte('\n') catch break :blk;
                self.need_blank = false;
                self.out.writer.writeAll("\x1b[90m") catch break :blk;
                const bar_len = @min(self.width, 60);
                for (0..bar_len) |_| self.out.writer.writeAll("─") catch break :blk;
                self.out.writer.writeAll(reset ++ "\n") catch break :blk;
                self.need_blank = true;
            },
            c.MD_BLOCK_H => {
                const h: *const c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail.?));
                self.flushRow() catch break :blk;
                self.heading_level = h.level;
            },
            c.MD_BLOCK_CODE => {
                self.flushRow() catch break :blk;
                if (self.need_blank) self.out.writer.writeByte('\n') catch break :blk;
                self.need_blank = false;
                self.in_code = true;
                self.row.appendSlice(self.allocator, "  \x1b[2m") catch break :blk;
                self.row_w = 2;
                self.row_open = true;
            },
            else => {},
        }
    }
    return 0;
}

fn leaveBlockCb(blocktype: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const self: *AnsiRenderer = @ptrCast(@alignCast(userdata.?));
    _ = detail;
    blk: {
        switch (blocktype) {
            c.MD_BLOCK_QUOTE => {
                self.flushRow() catch break :blk;
                if (self.quote_lens.items.len > 0) {
                    const restore = self.quote_lens.pop().?;
                    self.indent_bytes.shrinkRetainingCapacity(restore);
                    self.indent_width = visibleWidth(self.indent_bytes.items);
                }
                self.need_blank = true;
            },
            c.MD_BLOCK_UL, c.MD_BLOCK_OL => {
                self.list_depth -= 1;
                if (self.list_depth == 0) self.need_blank = true;
            },
            c.MD_BLOCK_LI => {
                self.flushRow() catch break :blk;
                self.bullet_bytes.clearRetainingCapacity();
                self.bullet_width = 0;
                self.bullet_used = false;
            },
            c.MD_BLOCK_H => {
                self.heading_level = 0;
                self.flushRow() catch break :blk;
                self.need_blank = true;
            },
            c.MD_BLOCK_CODE => {
                self.in_code = false;
                self.code_newlines = 0;
                self.flushRow() catch break :blk;
                self.need_blank = true;
            },
            c.MD_BLOCK_P => {
                self.flushRow() catch break :blk;
                self.need_blank = true;
            },
            else => {},
        }
    }
    return 0;
}

fn enterSpanCb(spantype: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const self: *AnsiRenderer = @ptrCast(@alignCast(userdata.?));
    blk: {
        switch (spantype) {
            c.MD_SPAN_STRONG => self.span_stack.append(self.allocator, .bold) catch break :blk,
            c.MD_SPAN_EM => self.span_stack.append(self.allocator, .italic) catch break :blk,
            c.MD_SPAN_CODE => self.span_stack.append(self.allocator, .code) catch break :blk,
            c.MD_SPAN_DEL => self.span_stack.append(self.allocator, .del) catch break :blk,
            c.MD_SPAN_A => {
                const a: *const c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail.?));
                const href_text: [*]const u8 = @ptrCast(a.href.text);
                self.link_href = href_text[0..a.href.size];
                self.span_stack.append(self.allocator, .link) catch break :blk;
            },
            else => {},
        }
        self.style_dirty = true;
    }
    return 0;
}

fn leaveSpanCb(spantype: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const self: *AnsiRenderer = @ptrCast(@alignCast(userdata.?));
    _ = detail;
    blk: {
        switch (spantype) {
            c.MD_SPAN_A => {
                if (self.span_stack.items.len > 0) _ = self.span_stack.pop();
                const href = self.link_href;
                const href_clean = sanitize(self.allocator, href) catch break :blk;
                defer self.allocator.free(href_clean);
                const shown = std.fmt.allocPrint(self.allocator, " ({s})", .{href_clean}) catch break :blk;
                defer self.allocator.free(shown);
                self.style_dirty = true;
                self.appendWord(shown, visibleWidth(shown)) catch break :blk;
            },
            c.MD_SPAN_STRONG, c.MD_SPAN_EM, c.MD_SPAN_CODE, c.MD_SPAN_DEL => {
                if (self.span_stack.items.len > 0) _ = self.span_stack.pop();
                self.style_dirty = true;
            },
            else => {},
        }
    }
    return 0;
}

fn textCb(texttype: c.MD_TEXTTYPE, text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
    const self: *AnsiRenderer = @ptrCast(@alignCast(userdata.?));
    const raw: []const u8 = @as([*]const u8, @ptrCast(text))[0..size];
    blk: {
        switch (texttype) {
            c.MD_TEXT_NORMAL, c.MD_TEXT_ENTITY => {
                const clean = sanitize(self.allocator, raw) catch break :blk;
                defer self.allocator.free(clean);
                self.appendProse(clean) catch break :blk;
            },
            c.MD_TEXT_BR, c.MD_TEXT_SOFTBR => {
                self.flushRow() catch break :blk;
            },
            c.MD_TEXT_CODE, c.MD_TEXT_HTML, c.MD_TEXT_LATEXMATH => {
                if (self.in_code) {
                    self.appendCodeText(raw) catch break :blk;
                } else {
                    const clean = sanitize(self.allocator, raw) catch break :blk;
                    defer self.allocator.free(clean);
                    self.appendProse(clean) catch break :blk;
                }
            },
            c.MD_TEXT_NULLCHAR => {},
            else => {},
        }
    }
    return 0;
}

pub fn renderMarkdownAnsi(allocator: std.mem.Allocator, source: []const u8, width: usize) ![]const u8 {
    var renderer = AnsiRenderer.init(allocator, width);
    defer renderer.deinit();
    const parser: c.MD_PARSER = .{
        .abi_version = 0,
        .flags = c.MD_DIALECT_COMMONMARK | c.MD_FLAG_NOHTML,
        .enter_block = enterBlockCb,
        .leave_block = leaveBlockCb,
        .enter_span = enterSpanCb,
        .leave_span = leaveSpanCb,
        .text = textCb,
        .debug_log = null,
        .syntax = null,
    };
    const text_ptr: [*c]const c.MD_CHAR = @ptrCast(source.ptr);
    const rc = c.md_parse(text_ptr, @intCast(source.len), &parser, &renderer);
    if (rc != 0) return error.MarkdownParseAborted;
    return renderer.finish();
}

test "headings spans and links render with ansi" {
    const src = "# Title\n\nSome **bold** and *italic* text with `code`.\n\nSee [docs](https://example.com) now\n";
    const out = try renderMarkdownAnsi(std.testing.allocator, src, 60);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;4;95mTitle\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1mbold\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3mitalic\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[33mcode\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[36;4mdocs\x1b[0m (https://example.com)") != null);
}

test "paragraph wraps at width and reasserts span across break" {
    const src = "alpha **bravo charlie delta echo foxtrot** golf hotel\n";
    const out = try renderMarkdownAnsi(std.testing.allocator, src, 20);
    defer std.testing.allocator.free(out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    var rows: [8][]const u8 = undefined;
    var n: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(n < 8);
        rows[n] = line;
        n += 1;
    }
    try std.testing.expect(n >= 2);
    for (rows[0..n]) |row| {
        try std.testing.expect(visibleWidth(row) <= 20);
        try std.testing.expect(std.mem.endsWith(u8, row, "\x1b[0m"));
    }
    var bold_rows: usize = 0;
    for (rows[0..n]) |row| {
        if (std.mem.indexOf(u8, row, "\x1b[1m") != null) bold_rows += 1;
    }
    try std.testing.expect(bold_rows >= 2);
}

test "model output control bytes are stripped" {
    const src = "safe \x1b[31mred\x1b[0m text \x07bell \xc2\x9fC1 \xff\xfe malformed\n";
    const out = try renderMarkdownAnsi(std.testing.allocator, src, 60);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[31m") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{9f}") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\xff") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\xfe") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "safe") != null);
}

test "code block indents dim truncates expands tabs and keeps lines separate" {
    const src = "```zig\nconst x = 1;\n\ttabbed_line_here\nconst y = 2;\n```\n";
    const out = try renderMarkdownAnsi(std.testing.allocator, src, 24);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "  \x1b[2mconst x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const x = 1;\n  \x1b[2m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const y = 2;\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\t") == null);
    var longest: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| longest = @max(longest, visibleWidth(line));
    try std.testing.expect(longest <= 24);
}

test "list and quote nesting prefixes" {
    const src = "- one\n- two\n  - nested\n\n> quoted **deep**\n";
    const out = try renderMarkdownAnsi(std.testing.allocator, src, 40);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "• one\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "• two\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  • nested\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│ quoted \x1b[1mdeep\x1b[0m") != null);
}

test "ordered list numbering" {
    const src = "3. third\n4. fourth\n";
    const out = try renderMarkdownAnsi(std.testing.allocator, src, 40);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "3. third\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "4. fourth\x1b[0m") != null);
}

test "link destination metadata is sanitized" {
    const src = "[docs](https://example.com/\x1b]0;pwned\x07x)";
    const out = try renderMarkdownAnsi(std.testing.allocator, src, 60);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]0;") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x07") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://example.com/x") != null);
}

test "apc pm sos payloads are consumed to string terminator" {
    const src = "safe \x1b_hidden\x1b\\ end \x1b^pm\x1b\\ tail \x1bXsos\x1b\\ done\n";
    const out = try renderMarkdownAnsi(std.testing.allocator, src, 60);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b^") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1bX") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pm") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sos") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "done") != null);
}
