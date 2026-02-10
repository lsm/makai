const std = @import("std");

/// AWS SigV4 signing utilities for Bedrock API authentication
/// Reference: https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html

pub const SignedRequest = struct {
    authorization: []const u8,
    x_amz_date: []const u8,
    x_amz_security_token: ?[]const u8,
};

/// Sign a request using AWS Signature Version 4
pub fn signRequest(
    method: []const u8,
    uri: []const u8,
    query_string: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    region: []const u8,
    service: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    session_token: ?[]const u8,
    allocator: std.mem.Allocator,
) !SignedRequest {
    const timestamp = std.time.timestamp();
    const amz_date = try formatAmzDate(timestamp, allocator);
    errdefer allocator.free(amz_date);

    const date_stamp = try formatDateStamp(timestamp, allocator);
    defer allocator.free(date_stamp);

    // Build canonical request
    const canonical_request = try buildCanonicalRequest(
        method,
        uri,
        query_string,
        headers,
        body,
        allocator,
    );
    defer allocator.free(canonical_request);

    // Build string to sign
    const credential_scope = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}/aws4_request",
        .{ date_stamp, region, service },
    );
    defer allocator.free(credential_scope);

    const canonical_hash = try sha256Hex(canonical_request, allocator);
    defer allocator.free(canonical_hash);

    const string_to_sign = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}",
        .{ amz_date, credential_scope, canonical_hash },
    );
    defer allocator.free(string_to_sign);

    // Calculate signature
    const signing_key = try deriveSigningKey(secret_key, date_stamp, region, service, allocator);
    defer allocator.free(signing_key);

    const signature = try hmacSha256Hex(string_to_sign, signing_key, allocator);
    defer allocator.free(signature);

    // Build authorization header
    const signed_headers = try getSignedHeaders(headers, allocator);
    defer allocator.free(signed_headers);

    const authorization = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ access_key, credential_scope, signed_headers, signature },
    );

    return SignedRequest{
        .authorization = authorization,
        .x_amz_date = amz_date,
        .x_amz_security_token = if (session_token) |token| try allocator.dupe(u8, token) else null,
    };
}

/// Build canonical request string
fn buildCanonicalRequest(
    method: []const u8,
    uri: []const u8,
    query_string: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const body_hash = try sha256Hex(body, allocator);
    defer allocator.free(body_hash);

    const canonical_headers = try buildCanonicalHeaders(headers, allocator);
    defer allocator.free(canonical_headers);

    const signed_headers = try getSignedHeaders(headers, allocator);
    defer allocator.free(signed_headers);

    return std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{s}\n{s}\n{s}\n{s}",
        .{ method, uri, query_string, canonical_headers, signed_headers, body_hash },
    );
}

/// Build canonical headers string (sorted, lowercase, trimmed)
fn buildCanonicalHeaders(headers: std.StringHashMap([]const u8), allocator: std.mem.Allocator) ![]u8 {
    var header_list: std.ArrayList(struct { key: []const u8, value: []const u8 }) = .{};
    defer header_list.deinit(allocator);

    var it = headers.iterator();
    while (it.next()) |entry| {
        const lower_key = try std.ascii.allocLowerString(allocator, entry.key_ptr.*);
        try header_list.append(allocator, .{ .key = lower_key, .value = entry.value_ptr.* });
    }

    // Sort by key
    std.mem.sort(
        @TypeOf(header_list.items[0]),
        header_list.items,
        {},
        struct {
            fn lessThan(_: void, a: @TypeOf(header_list.items[0]), b: @TypeOf(header_list.items[0])) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lessThan,
    );

    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    for (header_list.items) |header| {
        defer allocator.free(header.key);
        const trimmed_value = std.mem.trim(u8, header.value, " \t");
        try result.writer(allocator).print("{s}:{s}\n", .{ header.key, trimmed_value });
    }

    return result.toOwnedSlice(allocator);
}

/// Get signed headers string (sorted, lowercase, semicolon-separated)
fn getSignedHeaders(headers: std.StringHashMap([]const u8), allocator: std.mem.Allocator) ![]u8 {
    var header_names: std.ArrayList([]const u8) = .{};
    defer header_names.deinit(allocator);

    var it = headers.keyIterator();
    while (it.next()) |key| {
        const lower_key = try std.ascii.allocLowerString(allocator, key.*);
        try header_names.append(allocator, lower_key);
    }

    // Sort
    std.mem.sort([]const u8, header_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    for (header_names.items, 0..) |name, i| {
        defer allocator.free(name);
        if (i > 0) try result.append(allocator, ';');
        try result.appendSlice(allocator, name);
    }

    return result.toOwnedSlice(allocator);
}

/// Derive AWS SigV4 signing key
fn deriveSigningKey(
    secret_key: []const u8,
    date_stamp: []const u8,
    region: []const u8,
    service: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const k_secret = try std.fmt.allocPrint(allocator, "AWS4{s}", .{secret_key});
    defer allocator.free(k_secret);

    const k_date = try hmacSha256(date_stamp, k_secret);
    const k_region = try hmacSha256(region, &k_date);
    const k_service = try hmacSha256(service, &k_region);
    const k_signing = try hmacSha256("aws4_request", &k_service);

    return try allocator.dupe(u8, &k_signing);
}

/// Compute HMAC-SHA256
fn hmacSha256(data: []const u8, key: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, data, key);
    return out;
}

/// Compute HMAC-SHA256 and return hex string
fn hmacSha256Hex(data: []const u8, key: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const hash = try hmacSha256(data, key);
    return hexEncode(&hash, allocator);
}

/// Compute SHA256 hash and return hex string
fn sha256Hex(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hexEncode(&hash, allocator);
}

/// Convert bytes to hex string (lowercase)
fn hexEncode(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const result = try allocator.alloc(u8, bytes.len * 2);
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return result;
}

/// Format timestamp as ISO8601 date-time (YYYYMMDDTHHMMSSZ)
fn formatAmzDate(timestamp: i64, allocator: std.mem.Allocator) ![]u8 {
    const epoch_seconds = std.math.cast(u64, timestamp) orelse return error.InvalidTimestamp;
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(@divFloor(epoch_seconds, std.time.s_per_day)) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_seconds = @as(u64, @intCast(@mod(epoch_seconds, std.time.s_per_day)));
    const hours = @divFloor(day_seconds, std.time.s_per_hour);
    const minutes = @divFloor(@mod(day_seconds, std.time.s_per_hour), std.time.s_per_min);
    const seconds = @mod(day_seconds, std.time.s_per_min);

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
        .{ year_day.year, @intFromEnum(month_day.month), month_day.day_index + 1, hours, minutes, seconds },
    );
}

/// Format timestamp as date stamp (YYYYMMDD)
fn formatDateStamp(timestamp: i64, allocator: std.mem.Allocator) ![]u8 {
    const epoch_seconds = std.math.cast(u64, timestamp) orelse return error.InvalidTimestamp;
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(@divFloor(epoch_seconds, std.time.s_per_day)) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}",
        .{ year_day.year, @intFromEnum(month_day.month), month_day.day_index + 1 },
    );
}

// Tests

test "sha256Hex" {
    const allocator = std.testing.allocator;
    const hash = try sha256Hex("hello", allocator);
    defer allocator.free(hash);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hash);
}

test "hmacSha256Hex" {
    const allocator = std.testing.allocator;
    const key = "key";
    const data = "The quick brown fox jumps over the lazy dog";
    const result = try hmacSha256Hex(data, key, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8", result);
}

test "hexEncode" {
    const allocator = std.testing.allocator;
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const hex = try hexEncode(&bytes, allocator);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings("deadbeef", hex);
}

test "formatAmzDate" {
    const allocator = std.testing.allocator;
    const timestamp: i64 = 1609459200; // 2021-01-01 00:00:00 UTC
    const date = try formatAmzDate(timestamp, allocator);
    defer allocator.free(date);
    try std.testing.expectEqualStrings("20210101T000000Z", date);
}

test "formatDateStamp" {
    const allocator = std.testing.allocator;
    const timestamp: i64 = 1609459200; // 2021-01-01 00:00:00 UTC
    const date = try formatDateStamp(timestamp, allocator);
    defer allocator.free(date);
    try std.testing.expectEqualStrings("20210101", date);
}

test "buildCanonicalHeaders" {
    const allocator = std.testing.allocator;
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("Host", "example.com");
    try headers.put("Content-Type", "application/json");
    try headers.put("X-Amz-Date", "20210101T000000Z");

    const canonical = try buildCanonicalHeaders(headers, allocator);
    defer allocator.free(canonical);

    try std.testing.expect(std.mem.indexOf(u8, canonical, "content-type:application/json\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "host:example.com\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "x-amz-date:20210101T000000Z\n") != null);
}

test "getSignedHeaders" {
    const allocator = std.testing.allocator;
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("Host", "example.com");
    try headers.put("Content-Type", "application/json");

    const signed = try getSignedHeaders(headers, allocator);
    defer allocator.free(signed);

    try std.testing.expectEqualStrings("content-type;host", signed);
}

test "deriveSigningKey" {
    const allocator = std.testing.allocator;
    const key = try deriveSigningKey("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", "iam", allocator);
    defer allocator.free(key);
    try std.testing.expect(key.len == 32);
}

test "buildCanonicalRequest" {
    const allocator = std.testing.allocator;
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("host", "example.amazonaws.com");
    try headers.put("x-amz-date", "20150830T123600Z");

    const canonical = try buildCanonicalRequest(
        "GET",
        "/",
        "",
        headers,
        "",
        allocator,
    );
    defer allocator.free(canonical);

    try std.testing.expect(std.mem.indexOf(u8, canonical, "GET\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "/\n") != null);
}

test "signRequest complete flow" {
    const allocator = std.testing.allocator;
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("host", "bedrock-runtime.us-east-1.amazonaws.com");
    try headers.put("content-type", "application/json");

    const signed = try signRequest(
        "POST",
        "/model/test-model/converse-stream",
        "",
        headers,
        "{}",
        "us-east-1",
        "bedrock",
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        null,
        allocator,
    );
    defer allocator.free(signed.authorization);
    defer allocator.free(signed.x_amz_date);

    try std.testing.expect(std.mem.startsWith(u8, signed.authorization, "AWS4-HMAC-SHA256 Credential="));
    try std.testing.expect(signed.x_amz_security_token == null);
}
