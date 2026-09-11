const std = @import("std");

pub const StreamingJsonAccumulator = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StreamingJsonAccumulator {
        return .{
            .buffer = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StreamingJsonAccumulator) void {
        self.buffer.deinit(self.allocator);

        self.* = undefined;
    }

    pub fn append(self: *StreamingJsonAccumulator, delta: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, delta);
    }

    pub fn getBuffer(self: StreamingJsonAccumulator) []const u8 {
        return self.buffer.items;
    }

    pub fn clearRetainingCapacity(self: *StreamingJsonAccumulator) void {
        self.buffer.clearRetainingCapacity();
    }
};

pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: @This()) void {
            self.arena.deinit();
        }
    };
}

pub fn parse(comptime T: type, allocator: std.mem.Allocator, buffer: []const u8) ?Parsed(T) {
    if (buffer.len == 0) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const parsed = std.json.parseFromSliceLeaky(T, arena.allocator(), buffer, .{
        .ignore_unknown_fields = true,
        .max_value_len = null,
    }) catch {
        return null;
    };

    return .{
        .value = parsed,
        .arena = arena,
    };
}

pub fn parseValue(allocator: std.mem.Allocator, buffer: []const u8) ?std.json.Parsed(std.json.Value) {
    if (buffer.len == 0) return null;

    return std.json.parseFromSlice(std.json.Value, allocator, buffer, .{
        .ignore_unknown_fields = true,
        .max_value_len = null,
    }) catch null;
}

test "StreamingJsonAccumulator - append multiple deltas" {
    const allocator = std.testing.allocator;

    var acc = StreamingJsonAccumulator.init(allocator);
    defer acc.deinit();

    try acc.append("{\"name\"");
    try acc.append(": \"test\"");
    try acc.append("}");

    try std.testing.expectEqualStrings("{\"name\": \"test\"}", acc.getBuffer());
}

test "StreamingJsonAccumulator - clear and reuse" {
    const allocator = std.testing.allocator;

    var acc = StreamingJsonAccumulator.init(allocator);
    defer acc.deinit();

    try acc.append("first");
    try std.testing.expectEqualStrings("first", acc.getBuffer());

    acc.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), acc.getBuffer().len);

    try acc.append("second");
    try std.testing.expectEqualStrings("second", acc.getBuffer());
}

test "parse - complete JSON succeeds" {
    const allocator = std.testing.allocator;

    const TestStruct = struct {
        name: []const u8,
        value: i32,
    };

    const json = "{\"name\": \"test\", \"value\": 42}";

    const result = parse(TestStruct, allocator, json);
    try std.testing.expect(result != null);

    if (result) |r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("test", r.value.name);
        try std.testing.expectEqual(@as(i32, 42), r.value.value);
    }
}

test "parse - incomplete JSON returns null" {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const TestStruct = struct {
        name: []const u8,
        value: i32,
    };

    const incomplete = "{\"name\": \"test\", \"value\":";
    const result = parse(TestStruct, fba.allocator(), incomplete);
    try std.testing.expect(result == null);
}

test "parse - empty buffer returns null" {
    const allocator = std.testing.allocator;

    const TestStruct = struct {
        name: []const u8,
    };

    const result = parse(TestStruct, allocator, "");
    try std.testing.expect(result == null);
}

test "parse - invalid JSON returns null" {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const TestStruct = struct {
        name: []const u8,
    };

    const invalid = "{name: test}";
    const result = parse(TestStruct, fba.allocator(), invalid);
    try std.testing.expect(result == null);
}

test "parseValue - complete JSON succeeds" {
    const allocator = std.testing.allocator;

    const json = "{\"key\": \"value\", \"number\": 123}";

    const result = parseValue(allocator, json);
    try std.testing.expect(result != null);

    if (result) |r| {
        defer r.deinit();
        try std.testing.expect(r.value == .object);
        const obj = r.value.object;
        try std.testing.expect(obj.contains("key"));
        try std.testing.expect(obj.contains("number"));
    }
}

test "parseValue - incomplete JSON returns null" {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const incomplete = "{\"key\":";
    const result = parseValue(fba.allocator(), incomplete);
    try std.testing.expect(result == null);
}

test "parseValue - nested object" {
    const allocator = std.testing.allocator;

    const json = "{\"outer\": {\"inner\": \"value\"}}";

    const result = parseValue(allocator, json);
    try std.testing.expect(result != null);

    if (result) |r| {
        defer r.deinit();
        const outer = r.value.object.get("outer").?;
        try std.testing.expect(outer == .object);
        const inner = outer.object.get("inner").?;
        try std.testing.expectEqualStrings("value", inner.string);
    }
}

test "StreamingJsonAccumulator - simulate tool call streaming" {
    const allocator = std.testing.allocator;

    var acc = StreamingJsonAccumulator.init(allocator);
    defer acc.deinit();

    const deltas = [_][]const u8{
        "{\"comman",
        "d\": \"ls\", \"arg",
        "uments\": [\"-la\"",
        "]}",
    };

    for (deltas) |delta| {
        try acc.append(delta);
    }

    const ToolInput = struct {
        command: []const u8,
        arguments: []const []const u8,
    };

    const result = parse(ToolInput, allocator, acc.getBuffer());
    try std.testing.expect(result != null);

    if (result) |r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("ls", r.value.command);
        try std.testing.expectEqual(@as(usize, 1), r.value.arguments.len);
        try std.testing.expectEqualStrings("-la", r.value.arguments[0]);
    }
}
