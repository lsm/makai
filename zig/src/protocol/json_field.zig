const std = @import("std");

pub const FieldError = error{
    MissingField,
    InvalidFieldType,
    FieldOutOfRange,
};

pub fn asObject(value: std.json.Value) FieldError!std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => error.InvalidFieldType,
    };
}

pub fn lookup(obj: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const value = obj.get(key) orelse return null;
    return if (value == .null) null else value;
}

pub fn optionalString(obj: std.json.ObjectMap, key: []const u8) FieldError!?[]const u8 {
    const value = lookup(obj, key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidFieldType,
    };
}

pub fn requireString(obj: std.json.ObjectMap, key: []const u8) FieldError![]const u8 {
    return (try optionalString(obj, key)) orelse error.MissingField;
}

pub fn optionalInteger(obj: std.json.ObjectMap, key: []const u8) FieldError!?i64 {
    const value = lookup(obj, key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => error.InvalidFieldType,
    };
}

pub fn requireInteger(obj: std.json.ObjectMap, key: []const u8) FieldError!i64 {
    return (try optionalInteger(obj, key)) orelse error.MissingField;
}

pub fn optionalUnsigned(comptime T: type, obj: std.json.ObjectMap, key: []const u8) FieldError!?T {
    const number = (try optionalInteger(obj, key)) orelse return null;
    if (number < 0) return error.FieldOutOfRange;
    if (number > std.math.maxInt(T)) return error.FieldOutOfRange;
    return @intCast(number);
}

pub fn requireUnsigned(comptime T: type, obj: std.json.ObjectMap, key: []const u8) FieldError!T {
    return (try optionalUnsigned(T, obj, key)) orelse error.MissingField;
}

pub fn unsignedOr(comptime T: type, obj: std.json.ObjectMap, key: []const u8, fallback: T) FieldError!T {
    return (try optionalUnsigned(T, obj, key)) orelse fallback;
}

pub fn optionalBool(obj: std.json.ObjectMap, key: []const u8) FieldError!?bool {
    const value = lookup(obj, key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidFieldType,
    };
}

pub fn boolOr(obj: std.json.ObjectMap, key: []const u8, fallback: bool) FieldError!bool {
    return (try optionalBool(obj, key)) orelse fallback;
}

pub fn optionalFloat(obj: std.json.ObjectMap, key: []const u8) FieldError!?f64 {
    const value = lookup(obj, key) orelse return null;
    return switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => error.InvalidFieldType,
    };
}

pub fn optionalObject(obj: std.json.ObjectMap, key: []const u8) FieldError!?std.json.ObjectMap {
    const value = lookup(obj, key) orelse return null;
    return switch (value) {
        .object => |nested| nested,
        else => error.InvalidFieldType,
    };
}

pub fn requireObject(obj: std.json.ObjectMap, key: []const u8) FieldError!std.json.ObjectMap {
    return (try optionalObject(obj, key)) orelse error.MissingField;
}

pub fn optionalArray(obj: std.json.ObjectMap, key: []const u8) FieldError!?std.json.Array {
    const value = lookup(obj, key) orelse return null;
    return switch (value) {
        .array => |items| items,
        else => error.InvalidFieldType,
    };
}

pub fn requireArray(obj: std.json.ObjectMap, key: []const u8) FieldError!std.json.Array {
    return (try optionalArray(obj, key)) orelse error.MissingField;
}

pub fn elementAsObject(value: std.json.Value) FieldError!std.json.ObjectMap {
    return asObject(value);
}

pub fn elementAsString(value: std.json.Value) FieldError![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidFieldType,
    };
}

test "requireString rejects absent, null and mistyped fields" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"present":"value","wrong":5,"empty":null}
    , .{});
    defer parsed.deinit();
    const obj = try asObject(parsed.value);

    try std.testing.expectEqualStrings("value", try requireString(obj, "present"));
    try std.testing.expectError(error.InvalidFieldType, requireString(obj, "wrong"));
    try std.testing.expectError(error.MissingField, requireString(obj, "empty"));
    try std.testing.expectError(error.MissingField, requireString(obj, "absent"));
    try std.testing.expectEqual(@as(?[]const u8, null), try optionalString(obj, "absent"));
    try std.testing.expectEqual(@as(?[]const u8, null), try optionalString(obj, "empty"));
}

test "requireUnsigned rejects negative and oversized integers" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"ok":7,"negative":-1,"big":300,"text":"7","huge":18446744073709551615}
    , .{});
    defer parsed.deinit();
    const obj = try asObject(parsed.value);

    try std.testing.expectEqual(@as(u64, 7), try requireUnsigned(u64, obj, "ok"));
    try std.testing.expectError(error.FieldOutOfRange, requireUnsigned(u64, obj, "negative"));
    try std.testing.expectError(error.FieldOutOfRange, requireUnsigned(u8, obj, "big"));
    try std.testing.expectError(error.InvalidFieldType, requireUnsigned(u64, obj, "text"));
    try std.testing.expectError(error.InvalidFieldType, requireUnsigned(u64, obj, "huge"));
    try std.testing.expectEqual(@as(u8, 1), try unsignedOr(u8, obj, "absent", 1));
    try std.testing.expectError(error.MissingField, requireUnsigned(u64, obj, "absent"));
}

test "object and array accessors reject mismatched containers" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"obj":{"a":1},"arr":[1,2],"scalar":3}
    , .{});
    defer parsed.deinit();
    const obj = try asObject(parsed.value);

    _ = try requireObject(obj, "obj");
    _ = try requireArray(obj, "arr");
    try std.testing.expectError(error.InvalidFieldType, requireObject(obj, "arr"));
    try std.testing.expectError(error.InvalidFieldType, requireArray(obj, "obj"));
    try std.testing.expectError(error.InvalidFieldType, requireObject(obj, "scalar"));
    try std.testing.expectError(error.MissingField, requireObject(obj, "absent"));
    try std.testing.expectError(error.InvalidFieldType, asObject(parsed.value.object.get("arr").?));
}

test "boolean and float accessors validate their types" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"flag":true,"num":1.5,"whole":2,"text":"no"}
    , .{});
    defer parsed.deinit();
    const obj = try asObject(parsed.value);

    try std.testing.expectEqual(true, try boolOr(obj, "flag", false));
    try std.testing.expectEqual(false, try boolOr(obj, "absent", false));
    try std.testing.expectError(error.InvalidFieldType, boolOr(obj, "text", false));
    try std.testing.expectEqual(@as(?f64, 1.5), try optionalFloat(obj, "num"));
    try std.testing.expectEqual(@as(?f64, 2.0), try optionalFloat(obj, "whole"));
    try std.testing.expectError(error.InvalidFieldType, optionalFloat(obj, "text"));
}
