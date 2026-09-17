const std = @import("std");

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

pub fn describe(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;

    if (root.get("error")) |err_value| {
        switch (err_value) {
            .object => |err_obj| {
                if (stringField(err_obj, "message")) |message| {
                    if (stringField(err_obj, "type")) |kind| {
                        return try std.fmt.allocPrint(allocator, " ({s}: {s})", .{ kind, message });
                    }
                    return try std.fmt.allocPrint(allocator, " ({s})", .{message});
                }
                if (stringField(err_obj, "type")) |kind| {
                    return try std.fmt.allocPrint(allocator, " ({s})", .{kind});
                }
                return null;
            },
            .string => |text| {
                if (text.len == 0) return null;
                return try std.fmt.allocPrint(allocator, " ({s})", .{text});
            },
            else => return null,
        }
    }

    if (stringField(root, "detail")) |text| return try std.fmt.allocPrint(allocator, " ({s})", .{text});
    if (stringField(root, "message")) |text| return try std.fmt.allocPrint(allocator, " ({s})", .{text});
    return null;
}

const testing = std.testing;

fn expectDescribe(body: []const u8, want: ?[]const u8) !void {
    const got = try describe(testing.allocator, body);
    defer if (got) |text| testing.allocator.free(text);
    if (want) |expected| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(expected, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "describe extracts the openai error envelope with its type" {
    try expectDescribe(
        \\{"error":{"message":"You've reached your 5-hour usage limit","type":"access_terminated_error"}}
    , " (access_terminated_error: You've reached your 5-hour usage limit)");
}

test "describe extracts a codex usage limit and ignores extra fields" {
    try expectDescribe(
        \\{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"pro","resets_at":1789805636}}
    , " (usage_limit_reached: The usage limit has been reached)");
}

test "describe falls back to a top level detail" {
    try expectDescribe(
        \\{"detail":"The 'gpt-5.4-mini' model is not supported when using Codex with a ChatGPT account."}
    , " (The 'gpt-5.4-mini' model is not supported when using Codex with a ChatGPT account.)");
}

test "describe handles a message without a type and a bare string error" {
    try expectDescribe(
        \\{"error":{"message":"Invalid Authentication"}}
    , " (Invalid Authentication)");
    try expectDescribe(
        \\{"error":"upstream exploded"}
    , " (upstream exploded)");
}

test "describe returns null for bodies it cannot read" {
    try expectDescribe("not json", null);
    try expectDescribe("[1,2,3]", null);
    try expectDescribe("{}", null);
    try expectDescribe(
        \\{"error":{"message":""}}
    , null);
    try expectDescribe(
        \\{"error":123}
    , null);
}

test "describe keeps the anthropic shape byte identical to the previous formatter" {
    try expectDescribe(
        \\{"error":{"type":"invalid_request_error","message":"max_tokens is too large"}}
    , " (invalid_request_error: max_tokens is too large)");
}
