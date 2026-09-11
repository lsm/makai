
const std = @import("std");
const Writer = std.Io.Writer;
const keys = @import("../input/keys.zig");
const style = @import("../style/style.zig");
const Color = @import("../style/color.zig").Color;

pub const TextInput = struct {
    allocator: std.mem.Allocator,

    value: std.array_list.Managed(u8),
    cursor: usize,

    placeholder: []const u8,
    prompt: []const u8,
    width: ?u16,
    char_limit: ?usize,
    echo_mode: EchoMode,

    text_style: style.Style,
    placeholder_style: style.Style,
    cursor_style: style.Style,
    prompt_style: style.Style,

    focused: bool,

    validate_fn: ?*const fn ([]const u8) bool,

    suggestions: []const []const u8,
    current_suggestion_idx: usize,
    show_suggestions: bool,
    suggestion_style: style.Style,

    pub const EchoMode = enum {
        normal,
        password,
        none,
    };

    pub fn init(allocator: std.mem.Allocator) TextInput {
        return .{
            .allocator = allocator,
            .value = std.array_list.Managed(u8).init(allocator),
            .cursor = 0,
            .placeholder = "",
            .prompt = "",
            .width = null,
            .char_limit = null,
            .echo_mode = .normal,
            .text_style = blk: {
                var s = style.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
            .placeholder_style = blk: {
                var s = style.Style{};
                s = s.fg(.gray(12));
                s = s.inline_style(true);
                break :blk s;
            },
            .cursor_style = blk: {
                var s = style.Style{};
                s = s.reverse(true);
                s = s.inline_style(true);
                break :blk s;
            },
            .prompt_style = blk: {
                var s = style.Style{};
                s = s.inline_style(true);
                break :blk s;
            },
            .focused = true,
            .validate_fn = null,
            .suggestions = &.{},
            .current_suggestion_idx = 0,
            .show_suggestions = true,
            .suggestion_style = blk2: {
                var s2 = style.Style{};
                s2 = s2.dim(true);
                s2 = s2.inline_style(true);
                break :blk2 s2;
            },
        };
    }

    pub fn deinit(self: *TextInput) void {
        self.value.deinit();
    }

    pub fn setValue(self: *TextInput, text: []const u8) !void {
        self.value.clearRetainingCapacity();
        try self.value.appendSlice(text);
        self.cursor = @min(self.cursor, self.value.items.len);
    }

    pub fn getValue(self: *const TextInput) []const u8 {
        return self.value.items;
    }

    pub fn setPlaceholder(self: *TextInput, text: []const u8) void {
        self.placeholder = text;
    }

    pub fn setPrompt(self: *TextInput, text: []const u8) void {
        self.prompt = text;
    }

    pub fn setWidth(self: *TextInput, w: u16) void {
        self.width = w;
    }

    pub fn setCharLimit(self: *TextInput, limit: usize) void {
        self.char_limit = limit;
    }

    pub fn setEchoMode(self: *TextInput, mode: EchoMode) void {
        self.echo_mode = mode;
    }

    pub fn setValidation(self: *TextInput, validate: *const fn ([]const u8) bool) void {
        self.validate_fn = validate;
    }

    pub fn focus(self: *TextInput) void {
        self.focused = true;
    }

    pub fn blur(self: *TextInput) void {
        self.focused = false;
    }

    pub fn isValid(self: *const TextInput) bool {
        if (self.validate_fn) |validate| {
            return validate(self.value.items);
        }
        return true;
    }

    pub fn setSuggestions(self: *TextInput, list: []const []const u8) void {
        self.suggestions = list;
        self.current_suggestion_idx = 0;
    }

    pub fn currentSuggestion(self: *const TextInput) ?[]const u8 {
        if (self.suggestions.len == 0 or self.value.items.len == 0) return null;
        const val = self.value.items;
        var match_count: usize = 0;
        for (self.suggestions) |s| {
            if (s.len > val.len and std.mem.startsWith(u8, s, val)) {
                if (match_count == self.current_suggestion_idx) {
                    return s;
                }
                match_count += 1;
            }
        }
        return null;
    }

    pub fn handleKey(self: *TextInput, key: keys.KeyEvent) void {
        if (!self.focused) return;

        if (key.modifiers.alt) {
            switch (key.key) {
                .left => {
                    self.moveCursorWordLeft();
                    return;
                },
                .right => {
                    self.moveCursorWordRight();
                    return;
                },
                else => {},
            }
        }

        if (key.modifiers.ctrl) {
            switch (key.key) {
                .char => |c| switch (c) {
                    'a' => self.cursor = 0,
                    'e' => self.cursor = self.value.items.len,
                    'k' => self.value.shrinkRetainingCapacity(self.cursor),
                    'u' => {
                        std.mem.copyForwards(u8, self.value.items[0..], self.value.items[self.cursor..]);
                        self.value.shrinkRetainingCapacity(self.value.items.len - self.cursor);
                        self.cursor = 0;
                    },
                    'w' => self.deleteWordBackward(),
                    else => {},
                },
                else => {},
            }
            return;
        }

        switch (key.key) {
            .char => |c| self.insertChar(c),
            .paste => |text| self.insertText(text),
            .backspace => self.deleteBackward(),
            .delete => self.deleteForward(),
            .left => self.moveCursorLeft(),
            .right => self.moveCursorRight(),
            .home => self.cursor = 0,
            .end => self.cursor = self.value.items.len,
            .tab => {
                if (self.currentSuggestion()) |suggestion| {
                    self.value.clearRetainingCapacity();
                    self.value.appendSlice(suggestion) catch {};
                    self.cursor = self.value.items.len;
                }
            },
            else => {},
        }
    }

    fn insertChar(self: *TextInput, c: u21) void {
        if (self.char_limit) |limit| {
            if (self.charCount() >= limit) return;
        }

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(c, &buf) catch return;

        self.value.insertSlice(self.cursor, buf[0..len]) catch return;
        self.cursor += len;
    }

    fn insertText(self: *TextInput, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\r' or text[i] == '\n') {
                i += 1;
                continue;
            }

            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                self.insertChar(text[i]);
                i += 1;
                continue;
            };
            if (i + len > text.len) {
                self.insertChar(text[i]);
                i += 1;
                continue;
            }

            const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch {
                self.insertChar(text[i]);
                i += 1;
                continue;
            };
            self.insertChar(codepoint);
            i += len;
        }
    }

    fn deleteBackward(self: *TextInput) void {
        if (self.cursor == 0) return;

        var start = self.cursor - 1;
        while (start > 0 and (self.value.items[start] & 0xC0) == 0x80) {
            start -= 1;
        }

        const len = self.cursor - start;
        _ = self.value.orderedRemove(start);
        for (1..len) |_| {
            if (start < self.value.items.len) {
                _ = self.value.orderedRemove(start);
            }
        }
        self.cursor = start;
    }

    fn deleteForward(self: *TextInput) void {
        if (self.cursor >= self.value.items.len) return;

        const byte_len = std.unicode.utf8ByteSequenceLength(self.value.items[self.cursor]) catch 1;

        for (0..byte_len) |_| {
            if (self.cursor < self.value.items.len) {
                _ = self.value.orderedRemove(self.cursor);
            }
        }
    }

    fn deleteWordBackward(self: *TextInput) void {
        if (self.cursor == 0) return;

        while (self.cursor > 0 and self.value.items[self.cursor - 1] == ' ') {
            self.deleteBackward();
        }

        while (self.cursor > 0 and self.value.items[self.cursor - 1] != ' ') {
            self.deleteBackward();
        }
    }

    fn moveCursorLeft(self: *TextInput) void {
        if (self.cursor == 0) return;

        self.cursor -= 1;
        while (self.cursor > 0 and (self.value.items[self.cursor] & 0xC0) == 0x80) {
            self.cursor -= 1;
        }
    }

    fn moveCursorRight(self: *TextInput) void {
        if (self.cursor >= self.value.items.len) return;

        const byte_len = std.unicode.utf8ByteSequenceLength(self.value.items[self.cursor]) catch 1;
        self.cursor = @min(self.cursor + byte_len, self.value.items.len);
    }

    fn moveCursorWordLeft(self: *TextInput) void {
        if (self.cursor == 0) return;
        while (self.cursor > 0 and self.value.items[self.cursor - 1] == ' ') {
            self.cursor -= 1;
        }
        while (self.cursor > 0 and self.value.items[self.cursor - 1] != ' ') {
            self.cursor -= 1;
        }
    }

    fn moveCursorWordRight(self: *TextInput) void {
        if (self.cursor >= self.value.items.len) return;
        while (self.cursor < self.value.items.len and self.value.items[self.cursor] != ' ') {
            self.cursor += 1;
        }
        while (self.cursor < self.value.items.len and self.value.items[self.cursor] == ' ') {
            self.cursor += 1;
        }
    }

    fn charCount(self: *const TextInput) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.value.items.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(self.value.items[i]) catch 1;
            i += byte_len;
            count += 1;
        }
        return count;
    }

    pub fn view(self: *const TextInput, allocator: std.mem.Allocator) ![]const u8 {
        var result: Writer.Allocating = .init(allocator);
        const writer = &result.writer;

        if (self.prompt.len > 0) {
            const rendered_prompt = try self.prompt_style.render(allocator, self.prompt);
            try writer.writeAll(rendered_prompt);
        }

        if (self.value.items.len == 0) {
            if (self.placeholder.len > 0) {
                const rendered = try self.placeholder_style.render(allocator, self.placeholder);
                try writer.writeAll(rendered);
            }
        } else {
            switch (self.echo_mode) {
                .normal => {
                    if (self.focused) {
                        try self.renderWithCursor(writer, allocator);
                    } else {
                        const rendered = try self.text_style.render(allocator, self.value.items);
                        try writer.writeAll(rendered);
                    }
                },
                .password => {
                    const char_count = self.charCount();
                    const masked = try allocator.alloc(u8, char_count);
                    @memset(masked, '*');
                    const rendered = try self.text_style.render(allocator, masked);
                    try writer.writeAll(rendered);
                },
                .none => {
                },
            }
        }

        return result.toOwnedSlice();
    }

    fn renderWithCursor(self: *const TextInput, writer: *Writer, allocator: std.mem.Allocator) !void {
        if (self.cursor > 0) {
            const before = try self.text_style.render(allocator, self.value.items[0..self.cursor]);
            try writer.writeAll(before);
        }

        if (self.cursor < self.value.items.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(self.value.items[self.cursor]) catch 1;
            const cursor_char = self.value.items[self.cursor..][0..byte_len];
            const cursor_rendered = try self.cursor_style.render(allocator, cursor_char);
            try writer.writeAll(cursor_rendered);

            if (self.cursor + byte_len < self.value.items.len) {
                const after = try self.text_style.render(allocator, self.value.items[self.cursor + byte_len ..]);
                try writer.writeAll(after);
            }
        } else {
            const cursor_rendered = try self.cursor_style.render(allocator, " ");
            try writer.writeAll(cursor_rendered);
        }

        if (self.show_suggestions) {
            if (self.currentSuggestion()) |suggestion| {
                if (suggestion.len > self.value.items.len) {
                    const ghost = suggestion[self.value.items.len..];
                    const ghost_rendered = try self.suggestion_style.render(allocator, ghost);
                    try writer.writeAll(ghost_rendered);
                }
            }
        }
    }
};
