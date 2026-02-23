const std = @import("std");

pub const ModelRefError = error{
    MissingProviderId,
    MissingApi,
    MissingModelId,
    MissingSeparators,
    AmbiguousSeparators,
    InvalidProviderId,
    InvalidApi,
    InvalidPercentEscape,
    InvalidModelIdEncoding,
    InvalidUtf8ModelId,
};

pub const ParsedModelRef = struct {
    provider_id: []u8,
    api: []u8,
    model_id: []u8,

    pub fn deinit(self: *ParsedModelRef, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.api);
        allocator.free(self.model_id);
        self.* = undefined;
    }
};

pub fn formatModelRef(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    api: []const u8,
    model_id: []const u8,
) (std.mem.Allocator.Error || ModelRefError)![]u8 {
    try validateProviderId(provider_id);
    try validateApi(api);

    const encoded_model_id = try encodeModelId(allocator, model_id);
    defer allocator.free(encoded_model_id);

    return std.fmt.allocPrint(allocator, "{s}/{s}@{s}", .{ provider_id, api, encoded_model_id });
}

pub fn parseModelRef(
    allocator: std.mem.Allocator,
    model_ref: []const u8,
) (std.mem.Allocator.Error || ModelRefError)!ParsedModelRef {
    const slash_index = std.mem.indexOfScalar(u8, model_ref, '/') orelse return error.MissingSeparators;
    if (slash_index == 0) return error.MissingProviderId;

    const first_at_index = std.mem.indexOfScalar(u8, model_ref, '@');
    if (first_at_index) |idx| {
        if (idx < slash_index) return error.AmbiguousSeparators;
    }

    const api_and_model = model_ref[slash_index + 1 ..];
    const at_offset = std.mem.indexOfScalar(u8, api_and_model, '@') orelse return error.MissingSeparators;
    const at_index = slash_index + 1 + at_offset;

    if (std.mem.indexOfScalar(u8, model_ref[slash_index + 1 .. at_index], '/')) |_| {
        return error.AmbiguousSeparators;
    }
    if (std.mem.indexOfScalar(u8, model_ref[at_index + 1 ..], '@')) |_| {
        return error.AmbiguousSeparators;
    }
    if (std.mem.indexOfScalar(u8, model_ref[at_index + 1 ..], '/')) |_| {
        return error.AmbiguousSeparators;
    }

    const provider_id = model_ref[0..slash_index];
    const api = model_ref[slash_index + 1 .. at_index];
    const encoded_model_id = model_ref[at_index + 1 ..];

    try validateProviderId(provider_id);
    try validateApi(api);

    if (encoded_model_id.len == 0) return error.MissingModelId;

    const decoded_model_id = try decodeModelId(allocator, encoded_model_id);
    errdefer allocator.free(decoded_model_id);

    const owned_provider_id = try allocator.dupe(u8, provider_id);
    errdefer allocator.free(owned_provider_id);

    const owned_api = try allocator.dupe(u8, api);
    errdefer allocator.free(owned_api);

    return .{
        .provider_id = owned_provider_id,
        .api = owned_api,
        .model_id = decoded_model_id,
    };
}

fn validateProviderId(provider_id: []const u8) ModelRefError!void {
    if (provider_id.len == 0) return error.MissingProviderId;
    if (hasForbiddenSegmentChar(provider_id)) return error.InvalidProviderId;
}

fn validateApi(api: []const u8) ModelRefError!void {
    if (api.len == 0) return error.MissingApi;
    if (hasForbiddenSegmentChar(api)) return error.InvalidApi;
}

fn hasForbiddenSegmentChar(segment: []const u8) bool {
    for (segment) |byte| {
        switch (byte) {
            '/', '@', '%' => return true,
            else => {},
        }
    }
    return false;
}

fn encodeModelId(allocator: std.mem.Allocator, model_id: []const u8) (std.mem.Allocator.Error || ModelRefError)![]u8 {
    if (model_id.len == 0) return error.MissingModelId;
    if (!std.unicode.utf8ValidateSlice(model_id)) return error.InvalidUtf8ModelId;

    var encoded = std.ArrayList(u8){};
    defer encoded.deinit(allocator);

    for (model_id) |byte| {
        if (isUnreserved(byte)) {
            try encoded.append(allocator, byte);
            continue;
        }
        try appendPercentEncodedByte(&encoded, allocator, byte);
    }

    return encoded.toOwnedSlice(allocator);
}

fn decodeModelId(allocator: std.mem.Allocator, encoded_model_id: []const u8) (std.mem.Allocator.Error || ModelRefError)![]u8 {
    var decoded = std.ArrayList(u8){};
    defer decoded.deinit(allocator);

    var idx: usize = 0;
    while (idx < encoded_model_id.len) {
        const byte = encoded_model_id[idx];
        if (byte == '%') {
            if (idx + 2 >= encoded_model_id.len) return error.InvalidPercentEscape;
            const hi = fromHexDigit(encoded_model_id[idx + 1]) orelse return error.InvalidPercentEscape;
            const lo = fromHexDigit(encoded_model_id[idx + 2]) orelse return error.InvalidPercentEscape;
            try decoded.append(allocator, (hi << 4) | lo);
            idx += 3;
            continue;
        }

        if (byte == '/' or byte == '@') return error.AmbiguousSeparators;
        if (!isUnreserved(byte)) return error.InvalidModelIdEncoding;

        try decoded.append(allocator, byte);
        idx += 1;
    }

    const owned = try decoded.toOwnedSlice(allocator);
    errdefer allocator.free(owned);

    if (!std.unicode.utf8ValidateSlice(owned)) return error.InvalidUtf8ModelId;
    return owned;
}

fn appendPercentEncodedByte(out: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) !void {
    const hex_chars = "0123456789ABCDEF";
    try out.append(allocator, '%');
    try out.append(allocator, hex_chars[(byte >> 4) & 0x0F]);
    try out.append(allocator, hex_chars[byte & 0x0F]);
}

fn fromHexDigit(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

fn isUnreserved(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or
        byte == '-' or
        byte == '.' or
        byte == '_' or
        byte == '~';
}

test "model_ref format and parse roundtrip canonical refs" {
    const allocator = std.testing.allocator;

    const formatted = try formatModelRef(allocator, "anthropic", "anthropic-messages", "claude-sonnet-4.5");
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("anthropic/anthropic-messages@claude-sonnet-4.5", formatted);

    var parsed = try parseModelRef(allocator, formatted);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("anthropic", parsed.provider_id);
    try std.testing.expectEqualStrings("anthropic-messages", parsed.api);
    try std.testing.expectEqualStrings("claude-sonnet-4.5", parsed.model_id);

    const reformatted = try formatModelRef(allocator, parsed.provider_id, parsed.api, parsed.model_id);
    defer allocator.free(reformatted);
    try std.testing.expectEqualStrings(formatted, reformatted);
}

test "model_ref supports colons and reserved chars via percent encoding" {
    const allocator = std.testing.allocator;
    const original_model_id = "claude:sonnet/4@latest?x=1&y=2";

    const formatted = try formatModelRef(allocator, "anthropic", "anthropic-messages", original_model_id);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings(
        "anthropic/anthropic-messages@claude%3Asonnet%2F4%40latest%3Fx%3D1%26y%3D2",
        formatted,
    );

    var parsed = try parseModelRef(allocator, formatted);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings(original_model_id, parsed.model_id);
}

test "model_ref supports UTF-8 model ids via percent encoding" {
    const allocator = std.testing.allocator;
    const original_model_id = "模型:ß🚀";

    const formatted = try formatModelRef(allocator, "openai", "openai-responses", original_model_id);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings(
        "openai/openai-responses@%E6%A8%A1%E5%9E%8B%3A%C3%9F%F0%9F%9A%80",
        formatted,
    );

    var parsed = try parseModelRef(allocator, formatted);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("openai", parsed.provider_id);
    try std.testing.expectEqualStrings("openai-responses", parsed.api);
    try std.testing.expectEqualStrings(original_model_id, parsed.model_id);
}

test "model_ref parse rejects malformed refs" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingProviderId, parseModelRef(allocator, "/api@model"));
    try std.testing.expectError(error.MissingApi, parseModelRef(allocator, "provider/@model"));
    try std.testing.expectError(error.MissingModelId, parseModelRef(allocator, "provider/api@"));
    try std.testing.expectError(error.MissingSeparators, parseModelRef(allocator, "provider-api-model"));
    try std.testing.expectError(error.InvalidPercentEscape, parseModelRef(allocator, "provider/api@bad%2"));
    try std.testing.expectError(error.InvalidPercentEscape, parseModelRef(allocator, "provider/api@bad%GG"));
    try std.testing.expectError(error.AmbiguousSeparators, parseModelRef(allocator, "provider/api/v1@model"));
    try std.testing.expectError(error.AmbiguousSeparators, parseModelRef(allocator, "provider/api@bad/model"));
    try std.testing.expectError(error.AmbiguousSeparators, parseModelRef(allocator, "provider/api@bad@model"));
}
