const std = @import("std");

pub const SSEEvent = struct {
    event_type: ?[]const u8 = null,
    data: []const u8,

    pub fn deinit(self: *SSEEvent, allocator: std.mem.Allocator) void {
        if (self.event_type) |et| allocator.free(et);
        allocator.free(self.data);

        // Poison freed memory to catch use-after-free in debug builds
        self.* = undefined;
    }
};

pub const Limits = struct {
    /// Largest accepted physical SSE line, excluding its line ending.
    line_bytes: usize = 1024 * 1024,
    /// Largest returned event, including type, data, and inserted data newlines.
    event_bytes: usize = 4 * 1024 * 1024,
};

pub const SSEParser = struct {
    line_buffer: std.ArrayList(u8),
    current_event_type: ?[]const u8,
    current_data: std.ArrayList(u8),
    pending_events: std.ArrayList(SSEEvent),
    allocator: std.mem.Allocator,
    limits: Limits,

    pub fn init(allocator: std.mem.Allocator) SSEParser {
        return .{
            .line_buffer = std.ArrayList(u8).empty,
            .current_event_type = null,
            .current_data = std.ArrayList(u8).empty,
            .pending_events = std.ArrayList(SSEEvent).empty,
            .allocator = allocator,
            .limits = .{},
        };
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) SSEParser {
        var parser = init(allocator);
        parser.limits = limits;
        return parser;
    }

    pub fn deinit(self: *SSEParser) void {
        self.line_buffer.deinit(self.allocator);
        if (self.current_event_type) |et| {
            self.allocator.free(et);
        }
        self.current_data.deinit(self.allocator);
        for (self.pending_events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.pending_events.deinit(self.allocator);

        // Poison freed memory to catch use-after-free in debug builds
        self.* = undefined;
    }

    /// Feed a chunk of data, returns completed events
    /// Caller must copy event data if needed beyond next feed() call
    pub fn feed(self: *SSEParser, chunk: []const u8) ![]SSEEvent {
        // Clear previous pending events
        for (self.pending_events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.pending_events.clearRetainingCapacity();

        var i: usize = 0;
        while (i < chunk.len) {
            const byte = chunk[i];
            i += 1;

            if (byte == '\n') {
                const line = self.line_buffer.items;

                // Empty line marks end of event
                if (line.len == 0) {
                    try self.finalizeEvent();
                } else {
                    try self.processLine(line);
                    self.line_buffer.clearRetainingCapacity();
                }
            } else if (byte != '\r') {
                try self.appendLineByte(byte);
            }
        }

        return self.pending_events.items;
    }

    /// Reset parser state
    pub fn reset(self: *SSEParser) void {
        self.line_buffer.clearRetainingCapacity();
        if (self.current_event_type) |et| {
            self.allocator.free(et);
            self.current_event_type = null;
        }
        self.current_data.clearRetainingCapacity();
        for (self.pending_events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.pending_events.clearRetainingCapacity();
    }

    fn processLine(self: *SSEParser, line: []const u8) !void {
        if (line.len == 0) return;

        // Comments start with ":"
        if (line[0] == ':') return;

        // Find the colon separator
        if (std.mem.findScalar(u8, line, ':')) |colon_pos| {
            const field = line[0..colon_pos];
            var value = line[colon_pos + 1 ..];

            // Skip leading space in value
            if (value.len > 0 and value[0] == ' ') {
                value = value[1..];
            }

            if (std.mem.eql(u8, field, "event")) {
                try self.setEventType(value);
            } else if (std.mem.eql(u8, field, "data")) {
                try self.appendEventData(value);
            }
            // Other fields are ignored
        }
    }

    fn finalizeEvent(self: *SSEParser) !void {
        // Only create event if we have data
        if (self.current_data.items.len == 0) return;

        const event = SSEEvent{
            .event_type = self.current_event_type,
            .data = try self.allocator.dupe(u8, self.current_data.items),
        };

        try self.pending_events.append(self.allocator, event);

        // Reset current state
        self.current_event_type = null;
        self.current_data.clearRetainingCapacity();
    }

    fn appendLineByte(self: *SSEParser, byte: u8) !void {
        if (self.line_buffer.items.len >= self.limits.line_bytes) return error.LineTooLarge;
        try self.line_buffer.append(self.allocator, byte);
    }

    fn setEventType(self: *SSEParser, event_type: []const u8) !void {
        const data_len = self.current_data.items.len;
        if (event_type.len > self.limits.event_bytes -| data_len) return error.EventTooLarge;

        const copy = try self.allocator.dupe(u8, event_type);
        if (self.current_event_type) |old| self.allocator.free(old);
        self.current_event_type = copy;
    }

    fn appendEventData(self: *SSEParser, value: []const u8) !void {
        const type_len = if (self.current_event_type) |event_type| event_type.len else 0;
        const separator_len: usize = if (self.current_data.items.len > 0) 1 else 0;
        const data_len = self.current_data.items.len;
        const remaining_after_type = self.limits.event_bytes -| type_len;
        const remaining_after_data = remaining_after_type -| data_len;
        if (separator_len > remaining_after_data or value.len > remaining_after_data - separator_len) {
            return error.EventTooLarge;
        }

        if (separator_len != 0) try self.current_data.append(self.allocator, '\n');
        try self.current_data.appendSlice(self.allocator, value);
    }
};

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.LineTooLarge => "sse line too large",
        error.EventTooLarge => "sse event too large",
        else => "sse parse error",
    };
}

// Tests
test "SSEParser - basic single event" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const chunk = "data: hello world\n\n";
    const events = try parser.feed(chunk);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("hello world", events[0].data);
    try std.testing.expectEqual(@as(?[]const u8, null), events[0].event_type);
}

test "SSEParser - event with type" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const chunk = "event: message\ndata: test data\n\n";
    const events = try parser.feed(chunk);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("test data", events[0].data);
    try std.testing.expect(events[0].event_type != null);
    try std.testing.expectEqualStrings("message", events[0].event_type.?);
}

test "SSEParser - multiple data lines" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const chunk = "data: first line\ndata: second line\ndata: third line\n\n";
    const events = try parser.feed(chunk);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("first line\nsecond line\nthird line", events[0].data);
}

test "SSEParser - partial chunks" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    // Feed data in parts
    var events = try parser.feed("data: hel");
    try std.testing.expectEqual(@as(usize, 0), events.len);

    events = try parser.feed("lo wor");
    try std.testing.expectEqual(@as(usize, 0), events.len);

    events = try parser.feed("ld\n\n");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("hello world", events[0].data);
}

test "SSEParser - multiple events in one chunk" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const chunk = "data: first\n\ndata: second\n\ndata: third\n\n";
    const events = try parser.feed(chunk);

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("first", events[0].data);
    try std.testing.expectEqualStrings("second", events[1].data);
    try std.testing.expectEqualStrings("third", events[2].data);
}

test "SSEParser - comments ignored" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const chunk = ": this is a comment\ndata: actual data\n: another comment\n\n";
    const events = try parser.feed(chunk);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("actual data", events[0].data);
}

test "SSEParser - event type and data" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const chunk = "event: update\ndata: {\"key\":\"value\"}\n\n";
    const events = try parser.feed(chunk);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0].event_type != null);
    try std.testing.expectEqualStrings("update", events[0].event_type.?);
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", events[0].data);
}

test "SSEParser - partial event across multiple feeds" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    var events = try parser.feed("event: test\n");
    try std.testing.expectEqual(@as(usize, 0), events.len);

    events = try parser.feed("data: line 1\n");
    try std.testing.expectEqual(@as(usize, 0), events.len);

    events = try parser.feed("data: line 2\n");
    try std.testing.expectEqual(@as(usize, 0), events.len);

    events = try parser.feed("\n");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("test", events[0].event_type.?);
    try std.testing.expectEqualStrings("line 1\nline 2", events[0].data);
}

test "SSEParser - empty lines between events" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const chunk = "data: first\n\n\n\ndata: second\n\n";
    const events = try parser.feed(chunk);

    // Extra empty lines should not create empty events
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("first", events[0].data);
    try std.testing.expectEqualStrings("second", events[1].data);
}

test "SSEParser - carriage return handling" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const chunk = "data: test\r\n\r\n";
    const events = try parser.feed(chunk);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("test", events[0].data);
}

test "SSEParser - reset clears state" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    _ = try parser.feed("event: test\ndata: partial");
    parser.reset();

    const events = try parser.feed("data: complete\n\n");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("complete", events[0].data);
    try std.testing.expectEqual(@as(?[]const u8, null), events[0].event_type);
}

test "SSEParser - data with colon" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const chunk = "data: key:value:more\n\n";
    const events = try parser.feed(chunk);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("key:value:more", events[0].data);
}

test "SSEParser - field without space after colon" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const chunk = "data:no space\n\n";
    const events = try parser.feed(chunk);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("no space", events[0].data);
}

test "SSEParser - rejects an overlong line before growth" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.initWithLimits(allocator, .{ .line_bytes = 4, .event_bytes = 32 });
    defer parser.deinit();

    try std.testing.expectError(error.LineTooLarge, parser.feed("abcde"));
    try std.testing.expectEqual(@as(usize, 4), parser.line_buffer.items.len);
}

test "SSEParser - complete event limit includes type and data" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.initWithLimits(allocator, .{ .line_bytes = 32, .event_bytes = 8 });
    defer parser.deinit();

    _ = try parser.feed("event: type\n");
    try std.testing.expectError(error.EventTooLarge, parser.feed("data: value\n"));
}

test "SSEParser - error messages preserve limit names" {
    try std.testing.expectEqualStrings("sse line too large", errorMessage(error.LineTooLarge));
    try std.testing.expectEqualStrings("sse event too large", errorMessage(error.EventTooLarge));
}

test "sse_parser_one_byte_incremental_reads_preserve_events" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const input = "event: message\ndata: {\"delta\":\"a\"}\n\ndata: [DONE]\n\n";
    var completed: usize = 0;
    var first_seen = false;
    var done_seen = false;

    for (input) |byte| {
        const events = try parser.feed((&byte)[0..1]);
        for (events) |event| {
            completed += 1;
            if (completed == 1) {
                first_seen = true;
                try std.testing.expectEqualStrings("message", event.event_type.?);
                try std.testing.expectEqualStrings("{\"delta\":\"a\"}", event.data);
            } else if (completed == 2) {
                done_seen = true;
                try std.testing.expect(event.event_type == null);
                try std.testing.expectEqualStrings("[DONE]", event.data);
            }
        }
    }

    try std.testing.expect(first_seen);
    try std.testing.expect(done_seen);
    try std.testing.expectEqual(@as(usize, 2), completed);
}

test "sse_parser_provider_error_body_path_surfaces_error_event" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.init(allocator);
    defer parser.deinit();

    const body = "event: error\ndata: {\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad input\"}}\n\n";
    const events = try parser.feed(body);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("error", events[0].event_type.?);
    try std.testing.expect(std.mem.find(u8, events[0].data, "invalid_request_error") != null);
    try std.testing.expect(std.mem.find(u8, events[0].data, "bad input") != null);
}
