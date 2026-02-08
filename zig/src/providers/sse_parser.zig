const std = @import("std");

pub const SSEEvent = struct {
    event_type: ?[]const u8 = null,
    data: []const u8,

    pub fn deinit(self: *SSEEvent, allocator: std.mem.Allocator) void {
        if (self.event_type) |et| allocator.free(et);
        allocator.free(self.data);
    }
};

pub const SSEParser = struct {
    line_buffer: std.ArrayList(u8),
    current_event_type: ?[]const u8,
    current_data: std.ArrayList(u8),
    pending_events: std.ArrayList(SSEEvent),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SSEParser {
        return .{
            .line_buffer = std.ArrayList(u8){},
            .current_event_type = null,
            .current_data = std.ArrayList(u8){},
            .pending_events = std.ArrayList(SSEEvent){},
            .allocator = allocator,
        };
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
                // Accumulate line (skip \r)
                try self.line_buffer.append(self.allocator, byte);
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
        if (std.mem.indexOfScalar(u8, line, ':')) |colon_pos| {
            const field = line[0..colon_pos];
            var value = line[colon_pos + 1..];

            // Skip leading space in value
            if (value.len > 0 and value[0] == ' ') {
                value = value[1..];
            }

            if (std.mem.eql(u8, field, "event")) {
                // Set event type
                if (self.current_event_type) |et| {
                    self.allocator.free(et);
                }
                self.current_event_type = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, field, "data")) {
                // Append data (with newline if not first)
                if (self.current_data.items.len > 0) {
                    try self.current_data.append(self.allocator, '\n');
                }
                try self.current_data.appendSlice(self.allocator, value);
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
};

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
