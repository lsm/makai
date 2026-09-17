const std = @import("std");

pub const FieldError = error{
    MissingField,
    InvalidFieldType,
    FieldOutOfRange,
};

pub fn asObject(value: std.json.Value) FieldError!std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => error.InvalidFieldType,
    };
}

pub fn asArray(value: std.json.Value) FieldError!std.json.Array {
    return switch (value) {
        .array => |a| a,
        else => error.InvalidFieldType,
    };
}

pub fn asString(value: std.json.Value) FieldError![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidFieldType,
    };
}

pub fn asInteger(value: std.json.Value) FieldError!i64 {
    return switch (value) {
        .integer => |i| i,
        else => error.InvalidFieldType,
    };
}

pub fn asBool(value: std.json.Value) FieldError!bool {
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidFieldType,
    };
}

pub fn asFloat(value: std.json.Value) FieldError!f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.InvalidFieldType,
    };
}

pub fn asInt(comptime T: type, value: std.json.Value) FieldError!T {
    return toInt(T, try asInteger(value));
}

pub fn toInt(comptime T: type, value: i64) FieldError!T {
    return std.math.cast(T, value) orelse error.FieldOutOfRange;
}

pub fn required(obj: std.json.ObjectMap, field: []const u8) FieldError!std.json.Value {
    return obj.get(field) orelse error.MissingField;
}

pub fn requiredObject(obj: std.json.ObjectMap, field: []const u8) FieldError!std.json.ObjectMap {
    return asObject(try required(obj, field));
}

pub fn requiredArray(obj: std.json.ObjectMap, field: []const u8) FieldError!std.json.Array {
    return asArray(try required(obj, field));
}

pub fn requiredString(obj: std.json.ObjectMap, field: []const u8) FieldError![]const u8 {
    return asString(try required(obj, field));
}

pub fn requiredInteger(obj: std.json.ObjectMap, field: []const u8) FieldError!i64 {
    return asInteger(try required(obj, field));
}

pub fn requiredInt(comptime T: type, obj: std.json.ObjectMap, field: []const u8) FieldError!T {
    return toInt(T, try requiredInteger(obj, field));
}

pub fn requiredBool(obj: std.json.ObjectMap, field: []const u8) FieldError!bool {
    return asBool(try required(obj, field));
}

pub fn optionalObject(obj: std.json.ObjectMap, field: []const u8) FieldError!?std.json.ObjectMap {
    const value = obj.get(field) orelse return null;
    if (value == .null) return null;
    return try asObject(value);
}

pub fn optionalArray(obj: std.json.ObjectMap, field: []const u8) FieldError!?std.json.Array {
    const value = obj.get(field) orelse return null;
    if (value == .null) return null;
    return try asArray(value);
}

pub fn optionalString(obj: std.json.ObjectMap, field: []const u8) FieldError!?[]const u8 {
    const value = obj.get(field) orelse return null;
    if (value == .null) return null;
    return try asString(value);
}

pub fn optionalInteger(obj: std.json.ObjectMap, field: []const u8) FieldError!?i64 {
    const value = obj.get(field) orelse return null;
    if (value == .null) return null;
    return try asInteger(value);
}

pub fn optionalInt(comptime T: type, obj: std.json.ObjectMap, field: []const u8, default: T) FieldError!T {
    const value = try optionalInteger(obj, field) orelse return default;
    return toInt(T, value);
}

pub fn optionalIntValue(comptime T: type, value: ?std.json.Value) FieldError!?T {
    const present = value orelse return null;
    if (present == .null) return null;
    return try asInt(T, present);
}

pub fn optionalBool(obj: std.json.ObjectMap, field: []const u8, default: bool) FieldError!bool {
    const value = obj.get(field) orelse return default;
    if (value == .null) return default;
    return try asBool(value);
}

pub fn optionalFloat(obj: std.json.ObjectMap, field: []const u8, default: f64) FieldError!f64 {
    const value = obj.get(field) orelse return default;
    if (value == .null) return default;
    return try asFloat(value);
}

pub fn rootObject(parsed: std.json.Value) FieldError!std.json.ObjectMap {
    return asObject(parsed);
}

pub fn isFieldError(err: anyerror) bool {
    return switch (err) {
        error.MissingField, error.InvalidFieldType, error.FieldOutOfRange => true,
        else => false,
    };
}

pub fn shouldAnswerDecodeError(err: anyerror) bool {
    return switch (err) {
        error.UnknownPayloadType, error.InvalidPayloadType => false,
        else => true,
    };
}

pub fn rejectionReason(err: anyerror) []const u8 {
    return switch (err) {
        error.InputTooLong => "input field exceeds maximum allowed length",
        error.MissingField => "envelope is missing a required field",
        error.InvalidFieldType => "envelope field has the wrong JSON type",
        error.FieldOutOfRange => "envelope field is outside the allowed numeric range",
        error.InvalidUlid => "envelope id is not a valid ULID",
        error.InvalidSessionId => "envelope session_id is not a valid session id",
        error.UnknownPayloadType, error.InvalidPayloadType => "envelope payload type is not recognized",
        error.SyntaxError, error.UnexpectedEndOfInput, error.UnexpectedToken => "envelope is not valid JSON",
        else => "envelope could not be decoded",
    };
}

fn parseForTest(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

test "required reports MissingField for absent keys" {
    const allocator = std.testing.allocator;
    var parsed = try parseForTest(allocator, "{\"a\":1}");
    defer parsed.deinit();
    const obj = try rootObject(parsed.value);

    try std.testing.expectError(error.MissingField, required(obj, "b"));
    try std.testing.expectError(error.MissingField, requiredString(obj, "b"));
    try std.testing.expectError(error.MissingField, requiredObject(obj, "b"));
    try std.testing.expectError(error.MissingField, requiredArray(obj, "b"));
    try std.testing.expectError(error.MissingField, requiredInteger(obj, "b"));
    try std.testing.expectError(error.MissingField, requiredBool(obj, "b"));
}

test "accessors reject mismatched json types" {
    const allocator = std.testing.allocator;
    var parsed = try parseForTest(
        allocator,
        "{\"s\":\"x\",\"i\":1,\"o\":{},\"a\":[],\"b\":true,\"n\":null}",
    );
    defer parsed.deinit();
    const obj = try rootObject(parsed.value);

    try std.testing.expectError(error.InvalidFieldType, requiredString(obj, "i"));
    try std.testing.expectError(error.InvalidFieldType, requiredInteger(obj, "s"));
    try std.testing.expectError(error.InvalidFieldType, requiredObject(obj, "a"));
    try std.testing.expectError(error.InvalidFieldType, requiredArray(obj, "o"));
    try std.testing.expectError(error.InvalidFieldType, requiredBool(obj, "s"));
    try std.testing.expectError(error.InvalidFieldType, requiredObject(obj, "n"));

    try std.testing.expectEqualStrings("x", try requiredString(obj, "s"));
    try std.testing.expectEqual(@as(i64, 1), try requiredInteger(obj, "i"));
    try std.testing.expectEqual(true, try requiredBool(obj, "b"));
}

test "integer casts report FieldOutOfRange instead of trapping" {
    const allocator = std.testing.allocator;
    var parsed = try parseForTest(allocator, "{\"neg\":-1,\"big\":99999}");
    defer parsed.deinit();
    const obj = try rootObject(parsed.value);

    try std.testing.expectError(error.FieldOutOfRange, requiredInt(u64, obj, "neg"));
    try std.testing.expectError(error.FieldOutOfRange, requiredInt(u8, obj, "big"));
    try std.testing.expectEqual(@as(i64, -1), try requiredInteger(obj, "neg"));
    try std.testing.expectEqual(@as(u32, 99999), try requiredInt(u32, obj, "big"));
}

test "optional accessors treat null and absence alike" {
    const allocator = std.testing.allocator;
    var parsed = try parseForTest(allocator, "{\"n\":null,\"s\":\"x\",\"i\":5,\"b\":false}");
    defer parsed.deinit();
    const obj = try rootObject(parsed.value);

    try std.testing.expectEqual(@as(?[]const u8, null), try optionalString(obj, "n"));
    try std.testing.expectEqual(@as(?[]const u8, null), try optionalString(obj, "absent"));
    try std.testing.expectEqualStrings("x", (try optionalString(obj, "s")).?);
    try std.testing.expectEqual(@as(u32, 5), try optionalInt(u32, obj, "i", 0));
    try std.testing.expectEqual(@as(u32, 7), try optionalInt(u32, obj, "absent", 7));
    try std.testing.expectEqual(false, try optionalBool(obj, "b", true));
    try std.testing.expectEqual(true, try optionalBool(obj, "n", true));
    try std.testing.expectEqual(@as(?std.json.ObjectMap, null), try optionalObject(obj, "n"));
}

test "optionalIntValue tolerates absent and null values" {
    const allocator = std.testing.allocator;
    var parsed = try parseForTest(allocator, "{\"n\":null,\"i\":3,\"neg\":-4}");
    defer parsed.deinit();
    const obj = try rootObject(parsed.value);

    try std.testing.expectEqual(@as(?u64, null), try optionalIntValue(u64, obj.get("absent")));
    try std.testing.expectEqual(@as(?u64, null), try optionalIntValue(u64, obj.get("n")));
    try std.testing.expectEqual(@as(?u64, 3), try optionalIntValue(u64, obj.get("i")));
    try std.testing.expectError(error.FieldOutOfRange, optionalIntValue(u64, obj.get("neg")));
}

test "rootObject rejects non-object documents" {
    const allocator = std.testing.allocator;
    var parsed = try parseForTest(allocator, "[1,2,3]");
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidFieldType, rootObject(parsed.value));
}

test "shouldAnswerDecodeError stays silent only for unrecognized payload types" {
    try std.testing.expect(!shouldAnswerDecodeError(error.UnknownPayloadType));
    try std.testing.expect(!shouldAnswerDecodeError(error.InvalidPayloadType));
    try std.testing.expect(shouldAnswerDecodeError(error.MissingField));
    try std.testing.expect(shouldAnswerDecodeError(error.InvalidFieldType));
    try std.testing.expect(shouldAnswerDecodeError(error.FieldOutOfRange));
    try std.testing.expect(shouldAnswerDecodeError(error.InvalidUlid));
    try std.testing.expect(shouldAnswerDecodeError(error.InvalidSessionId));
    try std.testing.expect(shouldAnswerDecodeError(error.SyntaxError));
}

test "rejectionReason maps decode failures to stable text" {
    try std.testing.expectEqualStrings("envelope is missing a required field", rejectionReason(error.MissingField));
    try std.testing.expectEqualStrings("envelope field has the wrong JSON type", rejectionReason(error.InvalidFieldType));
    try std.testing.expectEqualStrings("envelope field is outside the allowed numeric range", rejectionReason(error.FieldOutOfRange));
    try std.testing.expectEqualStrings("envelope id is not a valid ULID", rejectionReason(error.InvalidUlid));
    try std.testing.expectEqualStrings("envelope is not valid JSON", rejectionReason(error.SyntaxError));
    try std.testing.expectEqualStrings("envelope could not be decoded", rejectionReason(error.OutOfMemory));
}

test "isFieldError classifies only field errors" {
    try std.testing.expect(isFieldError(error.MissingField));
    try std.testing.expect(isFieldError(error.InvalidFieldType));
    try std.testing.expect(isFieldError(error.FieldOutOfRange));
    try std.testing.expect(!isFieldError(error.OutOfMemory));
}
