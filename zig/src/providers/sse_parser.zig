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
    has_data_field: bool,
    pending_events: std.ArrayList(SSEEvent),
    allocator: std.mem.Allocator,
    limits: Limits,
    pending_cr: bool,

    pub fn init(allocator: std.mem.Allocator) SSEParser {
        return .{
            .line_buffer = std.ArrayList(u8).empty,
            .current_event_type = null,
            .current_data = std.ArrayList(u8).empty,
            .has_data_field = false,
            .pending_events = std.ArrayList(SSEEvent).empty,
            .allocator = allocator,
            .limits = .{},
            .pending_cr = false,
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

            if (self.pending_cr) {
                self.pending_cr = false;
                if (byte == '\n') continue;
            }

            if (byte == '\n') {
                try self.finishLine();
            } else if (byte == '\r') {
                try self.finishLine();
                self.pending_cr = true;
            } else try self.appendLineByte(byte);
        }

        return self.pending_events.items;
    }

    /// Reset parser state
    pub fn reset(self: *SSEParser) void {
        self.line_buffer.clearRetainingCapacity();
        self.pending_cr = false;
        if (self.current_event_type) |et| {
            self.allocator.free(et);
            self.current_event_type = null;
        }
        self.current_data.clearRetainingCapacity();
        self.has_data_field = false;
        for (self.pending_events.items) |*event| {
            event.deinit(self.allocator);
        }
        self.pending_events.clearRetainingCapacity();
    }

    fn processLine(self: *SSEParser, line: []const u8) !void {
        if (line.len == 0) return;

        // Comments start with ":"
        if (line[0] == ':') return;

        const colon_pos = std.mem.findScalar(u8, line, ':');
        const field = if (colon_pos) |pos| line[0..pos] else line;
        var value: []const u8 = if (colon_pos) |pos| line[pos + 1 ..] else "";

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

    fn finishLine(self: *SSEParser) !void {
        if (self.line_buffer.items.len == 0) {
            try self.finalizeEvent();
        } else {
            try self.processLine(self.line_buffer.items);
            self.line_buffer.clearRetainingCapacity();
        }
    }

    fn finalizeEvent(self: *SSEParser) !void {
        // Only create event if we have data
        if (!self.has_data_field) return;

        const event = SSEEvent{
            .event_type = self.current_event_type,
            .data = try self.allocator.dupe(u8, self.current_data.items),
        };

        try self.pending_events.append(self.allocator, event);

        // Reset current state
        self.current_event_type = null;
        self.current_data.clearRetainingCapacity();
        self.has_data_field = false;
    }

    fn appendLineByte(self: *SSEParser, byte: u8) !void {
        if (self.line_buffer.items.len >= self.limits.line_bytes) return error.LineTooLarge;
        const new_len = std.math.add(usize, self.line_buffer.items.len, 1) catch return error.LineTooLarge;
        try self.ensureBoundedCapacity(&self.line_buffer, new_len, self.limits.line_bytes);
        self.line_buffer.appendAssumeCapacity(byte);
    }

    fn setEventType(self: *SSEParser, event_type: []const u8) !void {
        const data_len = self.current_data.items.len;
        if (event_type.len > self.limits.event_bytes -| data_len) return error.EventTooLarge;

        const copy = try self.allocator.dupe(u8, event_type);
        errdefer self.allocator.free(copy);
        try self.reboundDataCapacity(self.limits.event_bytes - event_type.len);
        if (self.current_event_type) |old| self.allocator.free(old);
        self.current_event_type = copy;
    }

    fn reboundDataCapacity(self: *SSEParser, limit: usize) !void {
        if (self.current_data.capacity <= limit) return;

        var rebound = std.ArrayList(u8).empty;
        errdefer rebound.deinit(self.allocator);
        try rebound.ensureTotalCapacityPrecise(self.allocator, self.current_data.items.len);
        rebound.appendSliceAssumeCapacity(self.current_data.items);
        self.current_data.deinit(self.allocator);
        self.current_data = rebound;
    }

    fn appendEventData(self: *SSEParser, value: []const u8) !void {
        const type_len = if (self.current_event_type) |event_type| event_type.len else 0;
        const separator_len: usize = if (self.has_data_field) 1 else 0;
        const data_len = self.current_data.items.len;
        const remaining_after_type = self.limits.event_bytes -| type_len;
        const remaining_after_data = remaining_after_type -| data_len;
        if (separator_len > remaining_after_data or value.len > remaining_after_data - separator_len) {
            return error.EventTooLarge;
        }

        const with_separator = std.math.add(usize, data_len, separator_len) catch return error.EventTooLarge;
        const new_len = std.math.add(usize, with_separator, value.len) catch return error.EventTooLarge;
        try self.ensureBoundedCapacity(&self.current_data, new_len, remaining_after_type);
        if (separator_len != 0) self.current_data.appendAssumeCapacity('\n');
        self.current_data.appendSliceAssumeCapacity(value);
        self.has_data_field = true;
    }

    fn ensureBoundedCapacity(
        self: *SSEParser,
        buffer: *std.ArrayList(u8),
        needed: usize,
        limit: usize,
    ) !void {
        if (needed <= buffer.capacity) return;

        const doubled = std.math.mul(usize, buffer.capacity, 2) catch limit;
        const geometric = @max(@as(usize, 8), doubled);
        const target = @min(limit, @max(needed, geometric));
        try buffer.ensureTotalCapacityPrecise(self.allocator, target);
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

test "SSEParser - buffer growth is amortized and bounded" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.initWithLimits(allocator, .{ .line_bytes = 64, .event_bytes = 64 });
    defer parser.deinit();

    _ = try parser.feed("data: a\ndata: b\ndata: c\n");
    try std.testing.expect(parser.current_data.capacity > parser.current_data.items.len);
    try std.testing.expect(parser.current_data.capacity <= parser.limits.event_bytes);
    try std.testing.expect(parser.line_buffer.capacity <= parser.limits.line_bytes);
}

test "SSEParser - late event type rebinds data capacity to aggregate limit" {
    const allocator = std.testing.allocator;
    var parser = SSEParser.initWithLimits(allocator, .{ .line_bytes = 64, .event_bytes = 64 });
    defer parser.deinit();

    _ = try parser.feed("data: 1234567\ndata: 1234567\ndata: 1234567\ndata: 1234567\ndata: 1234567\n");
    try std.testing.expect(parser.current_data.capacity > parser.current_data.items.len);

    _ = try parser.feed("event: 1234567890123456789012345\n");
    try std.testing.expect(parser.current_data.capacity <= parser.limits.event_bytes - parser.current_event_type.?.len);
    try std.testing.expectEqualStrings("1234567\n1234567\n1234567\n1234567\n1234567", parser.current_data.items);
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

fn expect_fixture_events(events: []const SSEEvent, seen: *usize) !void {
    for (events) |event| {
        seen.* += 1;
        try std.testing.expectEqual(@as(usize, 1), seen.*);
        try std.testing.expectEqualStrings("update", event.event_type.?);
        try std.testing.expectEqualStrings("first\n\nthird", event.data);
    }
}

fn expect_fixture_with_step(input: []const u8, step: usize) !void {
    var parser = SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    var seen: usize = 0;
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(input.len, offset + step);
        try expect_fixture_events(try parser.feed(input[offset..end]), &seen);
        offset = end;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

fn expect_fixture_at_split(input: []const u8, split: usize) !void {
    var parser = SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    var seen: usize = 0;
    try expect_fixture_events(try parser.feed(input[0..split]), &seen);
    try expect_fixture_events(try parser.feed(input[split..]), &seen);
    try std.testing.expectEqual(@as(usize, 1), seen);
}

fn expect_fixture_with_random_chunks(input: []const u8, seed: u64) !void {
    var parser = SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var seen: usize = 0;
    var offset: usize = 0;
    while (offset < input.len) {
        const max_chunk = @min(@as(usize, 11), input.len - offset);
        const chunk_len = random.intRangeAtMost(usize, 1, max_chunk);
        try expect_fixture_events(try parser.feed(input[offset..][0..chunk_len]), &seen);
        offset += chunk_len;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "SSEParser - valid fixture is independent of LF chunk boundaries" {
    const fixture = "event: update\ndata: first\ndata\ndata: third\nunknown\n\n";

    try expect_fixture_with_step(fixture, fixture.len);
    try expect_fixture_with_step(fixture, 1);
    for (0..fixture.len + 1) |split| try expect_fixture_at_split(fixture, split);

    const seed: u64 = 0x5eed_fa11;
    expect_fixture_with_random_chunks(fixture, seed) catch |err| {
        std.debug.print("SSE randomized framing failure; replay seed={d}\n", .{seed});
        return err;
    };
}

test "SSEParser - CRLF and bare CR framing match LF framing" {
    const crlf_fixture = "event: update\r\ndata: first\r\ndata\r\ndata: third\r\nunknown\r\n\r\n";
    const cr_fixture = "event: update\rdata: first\rdata\rdata: third\runknown\r\r";

    try expect_fixture_with_step(crlf_fixture, 1);
    try expect_fixture_with_step(cr_fixture, 1);
}

test "SSEParser - CRLF boundary split across feeds is one delimiter" {
    var parser = SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    try std.testing.expectEqual(@as(usize, 0), (try parser.feed("event: update\r")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parser.feed("\ndata: first\r")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parser.feed("\ndata\r")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parser.feed("\ndata: third\r")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parser.feed("\nunknown\r")).len);
    const events = try parser.feed("\n\r");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("first\n\nthird", events[0].data);
    try std.testing.expectEqual(@as(usize, 0), (try parser.feed("\n")).len);
}

test "SSEParser - recognized colonless event field has an empty value" {
    var parser = SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    const events = try parser.feed("event: stale\nevent\ndata: value\n\n");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("", events[0].event_type.?);
    try std.testing.expectEqualStrings("value", events[0].data);
}

test "SSEParser - leading and sole empty data fields are preserved" {
    var parser = SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    var events = try parser.feed("data\ndata: value\n\n");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("\nvalue", events[0].data);

    events = try parser.feed("data:\ndata: value\n\n");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("\nvalue", events[0].data);

    events = try parser.feed("data\n\n");
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("", events[0].data);
}

test "SSEParser - exact limits succeed and one byte over recovers after reset" {
    var parser = SSEParser.initWithLimits(std.testing.allocator, .{ .line_bytes = 9, .event_bytes = 3 });
    defer parser.deinit();

    const exact = try parser.feed("data: xxx\n\n");
    try std.testing.expectEqual(@as(usize, 1), exact.len);
    try std.testing.expectEqualStrings("xxx", exact[0].data);

    try std.testing.expectError(error.LineTooLarge, parser.feed("1234567890"));
    parser.reset();
    try std.testing.expectError(error.EventTooLarge, parser.feed("data: xx\ndata: x\n"));
    parser.reset();

    const recovered = try parser.feed("data: ok\n\n");
    try std.testing.expectEqual(@as(usize, 1), recovered.len);
    try std.testing.expectEqualStrings("ok", recovered[0].data);
}
