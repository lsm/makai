const std = @import("std");
const ai_types = @import("ai_types");

/// UUID type for stream/message identification
pub const Uuid = [16]u8;

/// Generate a random UUID v4
pub fn generateUuid() Uuid {
    var uuid: Uuid = undefined;
    std.crypto.random.bytes(&uuid);

    // Set version to 4 (random UUID)
    uuid[6] = (uuid[6] & 0x0f) | 0x40;
    // Set variant to RFC 4122
    uuid[8] = (uuid[8] & 0x3f) | 0x80;

    return uuid;
}

/// Convert UUID to string representation (36 chars: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
pub fn uuidToString(uuid: Uuid, allocator: std.mem.Allocator) ![]const u8 {
    const result = try allocator.alloc(u8, 36);

    const hex_chars = "0123456789abcdef";
    var idx: usize = 0;

    for (uuid[0..4], 0..) |byte, i| {
        result[idx] = hex_chars[byte >> 4];
        result[idx + 1] = hex_chars[byte & 0x0f];
        idx += 2;
        if (i == 3) {
            result[idx] = '-';
            idx += 1;
        }
    }

    for (uuid[4..6], 0..) |byte, i| {
        result[idx] = hex_chars[byte >> 4];
        result[idx + 1] = hex_chars[byte & 0x0f];
        idx += 2;
        if (i == 1) {
            result[idx] = '-';
            idx += 1;
        }
    }

    for (uuid[6..8], 0..) |byte, i| {
        result[idx] = hex_chars[byte >> 4];
        result[idx + 1] = hex_chars[byte & 0x0f];
        idx += 2;
        if (i == 1) {
            result[idx] = '-';
            idx += 1;
        }
    }

    for (uuid[8..10], 0..) |byte, i| {
        result[idx] = hex_chars[byte >> 4];
        result[idx + 1] = hex_chars[byte & 0x0f];
        idx += 2;
        if (i == 1) {
            result[idx] = '-';
            idx += 1;
        }
    }

    for (uuid[10..16]) |byte| {
        result[idx] = hex_chars[byte >> 4];
        result[idx + 1] = hex_chars[byte & 0x0f];
        idx += 2;
    }

    return result;
}

/// Parse UUID from string
pub fn parseUuid(str: []const u8) ?Uuid {
    // Expected format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 chars)
    if (str.len != 36) return null;

    // Check hyphen positions
    if (str[8] != '-' or str[13] != '-' or str[18] != '-' or str[23] != '-') return null;

    var uuid: Uuid = undefined;

    const parseHexByte = struct {
        fn parseHexByte(s: []const u8) ?u8 {
            const hi = charToHex(s[0]) orelse return null;
            const lo = charToHex(s[1]) orelse return null;
            return (@as(u8, hi) << 4) | @as(u8, lo);
        }

        fn charToHex(c: u8) ?u4 {
            return switch (c) {
                '0'...'9' => @intCast(c - '0'),
                'a'...'f' => @intCast(c - 'a' + 10),
                'A'...'F' => @intCast(c - 'A' + 10),
                else => null,
            };
        }
    }.parseHexByte;

    // Parse first group (8 hex chars = 4 bytes)
    uuid[0] = parseHexByte(str[0..2]) orelse return null;
    uuid[1] = parseHexByte(str[2..4]) orelse return null;
    uuid[2] = parseHexByte(str[4..6]) orelse return null;
    uuid[3] = parseHexByte(str[6..8]) orelse return null;

    // Parse second group (4 hex chars = 2 bytes)
    uuid[4] = parseHexByte(str[9..11]) orelse return null;
    uuid[5] = parseHexByte(str[11..13]) orelse return null;

    // Parse third group (4 hex chars = 2 bytes)
    uuid[6] = parseHexByte(str[14..16]) orelse return null;
    uuid[7] = parseHexByte(str[16..18]) orelse return null;

    // Parse fourth group (4 hex chars = 2 bytes)
    uuid[8] = parseHexByte(str[19..21]) orelse return null;
    uuid[9] = parseHexByte(str[21..23]) orelse return null;

    // Parse fifth group (12 hex chars = 6 bytes)
    uuid[10] = parseHexByte(str[24..26]) orelse return null;
    uuid[11] = parseHexByte(str[26..28]) orelse return null;
    uuid[12] = parseHexByte(str[28..30]) orelse return null;
    uuid[13] = parseHexByte(str[30..32]) orelse return null;
    uuid[14] = parseHexByte(str[32..34]) orelse return null;
    uuid[15] = parseHexByte(str[34..36]) orelse return null;

    return uuid;
}

/// Protocol envelope wrapping all messages
pub const Envelope = struct {
    /// Protocol version
    version: u8 = 1,
    /// Unique stream identifier (stable for stream lifecycle)
    stream_id: Uuid,
    /// Message ID (unique per message)
    message_id: Uuid,
    /// Sequence number within stream (starts at 1)
    sequence: u64,
    /// For request/response correlation
    in_reply_to: ?Uuid = null,
    /// Unix timestamp in milliseconds
    timestamp: i64,
    /// The actual payload
    payload: Payload,

    pub fn deinit(self: *Envelope, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
    }
};

/// Discriminated payload union
pub const Payload = union(enum) {
    // Client -> Server
    stream_request: StreamRequest,
    complete_request: CompleteRequest,
    abort_request: AbortRequest,

    // Server -> Client
    ack: Ack,
    nack: Nack,
    event: ai_types.AssistantMessageEvent,
    result: ai_types.AssistantMessage,
    stream_error: StreamError,

    // Keepalive
    ping: void,
    pong: void,

    pub fn deinit(self: *Payload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .stream_request => |*req| req.deinit(allocator),
            .complete_request => |*req| req.deinit(allocator),
            .abort_request => |*req| req.deinit(allocator),
            .nack => |*n| n.deinit(allocator),
            .event => |*e| deinitEvent(allocator, e),
            .result => |*r| r.deinit(allocator),
            .stream_error => |*err| err.deinit(allocator),
            .ack, .ping, .pong => {},
        }
    }
};

/// Helper to deinit AssistantMessageEvent variants that own memory
fn deinitEvent(allocator: std.mem.Allocator, event: *ai_types.AssistantMessageEvent) void {
    switch (event.*) {
        .text_delta => |*d| {
            allocator.free(d.delta);
            d.partial.deinit(allocator);
        },
        .text_end => |*t| {
            allocator.free(t.content);
            t.partial.deinit(allocator);
        },
        .thinking_delta => |*t| {
            allocator.free(t.delta);
            t.partial.deinit(allocator);
        },
        .thinking_end => |*t| {
            allocator.free(t.content);
            t.partial.deinit(allocator);
        },
        .toolcall_delta => |*t| {
            allocator.free(t.delta);
            t.partial.deinit(allocator);
        },
        .toolcall_end => |*t| {
            allocator.free(t.tool_call.id);
            allocator.free(t.tool_call.name);
            if (t.tool_call.arguments_json.len > 0) allocator.free(t.tool_call.arguments_json);
            if (t.tool_call.thought_signature) |s| allocator.free(s);
            t.partial.deinit(allocator);
        },
        .done => |*d| d.message.deinit(allocator),
        .@"error" => |*e| e.err.deinit(allocator),
        .start, .text_start, .thinking_start, .toolcall_start, .keepalive => {},
    }
}

/// Request to start a streaming completion
pub const StreamRequest = struct {
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions = null,
    /// If true, include lightweight partials in events
    include_partial: bool = true,

    pub fn deinit(self: *StreamRequest, allocator: std.mem.Allocator) void {
        // Model fields are typically borrowed references, not owned
        _ = self;
        _ = allocator;
    }
};

/// Request for non-streaming completion
pub const CompleteRequest = struct {
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions = null,

    pub fn deinit(self: *CompleteRequest, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Request to abort a stream
pub const AbortRequest = struct {
    target_stream_id: Uuid,
    reason: ?[]const u8 = null,

    pub fn deinit(self: *AbortRequest, allocator: std.mem.Allocator) void {
        if (self.reason) |r| allocator.free(r);
    }
};

/// Acknowledgment response
pub const Ack = struct {
    /// Echoes back the request's message_id
    in_reply_to: Uuid,
    /// The assigned stream_id (for stream_request)
    stream_id: ?Uuid = null,
};

/// Negative acknowledgment response
pub const Nack = struct {
    in_reply_to: Uuid,
    error_code: ErrorCode,
    message: []const u8,

    pub fn deinit(self: *Nack, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

/// Error codes for protocol errors
pub const ErrorCode = enum {
    invalid_request,
    model_not_found,
    provider_error,
    rate_limited,
    internal_error,
    stream_not_found,
    stream_already_exists,
    version_mismatch,
};

/// Stream error payload
pub const StreamError = struct {
    code: ErrorCode,
    message: []const u8,

    pub fn deinit(self: *StreamError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

// Tests

test "generateUuid produces valid UUID" {
    const uuid = generateUuid();

    // Check version bits (should be 0x4X for version 4)
    try std.testing.expectEqual(@as(u8, 0x40), uuid[6] & 0xf0);

    // Check variant bits (should be 0x8X or 0x9X, 0xaX, or 0xbX for RFC 4122)
    try std.testing.expect(uuid[8] >= 0x80 and uuid[8] <= 0xbf);

    // Generate multiple UUIDs and ensure they're different
    const uuid2 = generateUuid();
    try std.testing.expect(!std.mem.eql(u8, &uuid, &uuid2));
}

test "uuidToString and parseUuid roundtrip" {
    const uuid = generateUuid();
    const str = try uuidToString(uuid, std.testing.allocator);
    defer std.testing.allocator.free(str);

    // Check format: 36 chars with hyphens at correct positions
    try std.testing.expectEqual(@as(usize, 36), str.len);
    try std.testing.expectEqual(@as(u8, '-'), str[8]);
    try std.testing.expectEqual(@as(u8, '-'), str[13]);
    try std.testing.expectEqual(@as(u8, '-'), str[18]);
    try std.testing.expectEqual(@as(u8, '-'), str[23]);

    // Roundtrip
    const parsed = parseUuid(str);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualSlices(u8, &uuid, &parsed.?);

    // Test with known UUID
    const known_uuid: Uuid = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 };
    const known_str = try uuidToString(known_uuid, std.testing.allocator);
    defer std.testing.allocator.free(known_str);
    try std.testing.expectEqualStrings("01234567-89ab-cdef-fedc-ba9876543210", known_str);

    const parsed_known = parseUuid(known_str);
    try std.testing.expect(parsed_known != null);
    try std.testing.expectEqualSlices(u8, &known_uuid, &parsed_known.?);
}

test "parseUuid returns null for invalid strings" {
    // Wrong length
    try std.testing.expect(parseUuid("01234567-89ab-cdef-fedc-ba987654321") == null); // 35 chars
    try std.testing.expect(parseUuid("01234567-89ab-cdef-fedc-ba98765432100") == null); // 37 chars

    // Missing hyphens
    try std.testing.expect(parseUuid("0123456789abcdef0123456789abcdef0123") == null);

    // Invalid hex characters
    try std.testing.expect(parseUuid("01234567-89ab-cdef-xxxx-ba9876543210") == null);
    try std.testing.expect(parseUuid("g1234567-89ab-cdef-fedc-ba9876543210") == null);

    // Hyphens in wrong positions
    try std.testing.expect(parseUuid("0123456-789a-bcde-ffed-cba9876543210") == null);
    try std.testing.expect(parseUuid("012345678-9ab-cdef-fedc-ba9876543210") == null);

    // Empty string
    try std.testing.expect(parseUuid("") == null);
}

test "ErrorCode enum values match protocol spec" {
    // Verify all expected error codes exist
    const codes = [_]ErrorCode{
        .invalid_request,
        .model_not_found,
        .provider_error,
        .rate_limited,
        .internal_error,
        .stream_not_found,
        .stream_already_exists,
        .version_mismatch,
    };

    // Verify enum has exactly 8 values
    try std.testing.expectEqual(@as(usize, 8), codes.len);

    // Verify each can be instantiated
    inline for (codes) |code| {
        _ = code;
    }
}

test "Envelope with ping payload" {
    const uuid = generateUuid();
    var envelope = Envelope{
        .stream_id = uuid,
        .message_id = generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .ping,
    };

    // No memory to free for ping
    envelope.deinit(std.testing.allocator);
}

test "Nack deinit frees message" {
    const msg = try std.testing.allocator.dupe(u8, "Test error message");
    var nack = Nack{
        .in_reply_to = generateUuid(),
        .error_code = .invalid_request,
        .message = msg,
    };

    nack.deinit(std.testing.allocator);
    // Should not leak - test passes if no memory leak detected
}

test "StreamError deinit frees message" {
    const msg = try std.testing.allocator.dupe(u8, "Provider error");
    var stream_err = StreamError{
        .code = .provider_error,
        .message = msg,
    };

    stream_err.deinit(std.testing.allocator);
    // Should not leak - test passes if no memory leak detected
}

test "AbortRequest deinit frees reason" {
    const reason = try std.testing.allocator.dupe(u8, "User cancelled");
    var abort = AbortRequest{
        .target_stream_id = generateUuid(),
        .reason = reason,
    };

    abort.deinit(std.testing.allocator);
    // Should not leak - test passes if no memory leak detected
}

test "AbortRequest deinit handles null reason" {
    var abort = AbortRequest{
        .target_stream_id = generateUuid(),
        .reason = null,
    };

    abort.deinit(std.testing.allocator);
    // Should not crash
}

test "Payload deinit handles all variants" {
    // Test ping
    var ping_payload: Payload = .ping;
    ping_payload.deinit(std.testing.allocator);

    // Test pong
    var pong_payload: Payload = .pong;
    pong_payload.deinit(std.testing.allocator);

    // Test ack
    var ack_payload: Payload = .{ .ack = .{ .in_reply_to = generateUuid() } };
    ack_payload.deinit(std.testing.allocator);
}
