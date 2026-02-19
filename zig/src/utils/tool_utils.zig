const std = @import("std");
const ai_types = @import("ai_types");

const Allocator = std.mem.Allocator;

/// Provider enum for tool call ID normalization
pub const Provider = enum {
    anthropic,
    openai,
    mistral,
    google,
    bedrock,
};

/// Check if a character is alphanumeric (a-z, A-Z, 0-9)
fn isAlphanumeric(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

/// Check if a string consists entirely of alphanumeric characters
fn isAlphanumericStr(s: []const u8) bool {
    for (s) |c| {
        if (!isAlphanumeric(c)) {
            return false;
        }
    }
    return true;
}

/// Normalize a tool call ID for a specific provider.
/// Mistral requires exactly 9 alphanumeric characters.
/// For other providers, returns a copy of the original ID.
/// Caller owns returned memory.
pub fn normalizeToolCallId(allocator: Allocator, id: []const u8, provider: Provider) ![]u8 {
    return switch (provider) {
        .mistral => try normalizeForMistral(allocator, id),
        .anthropic, .openai, .google, .bedrock => try allocator.dupe(u8, id),
    };
}

/// Normalize an ID for Mistral (exactly 9 alphanumeric characters).
/// - If ID is already 9 alphanumeric chars, return as-is.
/// - If ID is shorter, pad with hash-based alphanumeric chars.
/// - If ID is longer, hash to 9 alphanumeric chars.
/// - Uses consistent hashing so the same ID always maps to the same normalized ID.
fn normalizeForMistral(allocator: Allocator, id: []const u8) ![]u8 {
    const target_len = 9;

    // If ID is exactly 9 alphanumeric chars, return as-is
    if (id.len == target_len and isAlphanumericStr(id)) {
        return try allocator.dupe(u8, id);
    }

    // Allocate result buffer
    var result = try allocator.alloc(u8, target_len);
    errdefer allocator.free(result);

    // Use SHA-256 hash for consistent mapping
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &hash, .{});

    // Convert hash bytes to alphanumeric characters
    // We'll use the hash to generate alphanumeric chars: a-z (26) + A-Z (26) + 0-9 (10) = 62 chars
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    for (0..target_len) |i| {
        // Use modulo to map hash byte to alphabet index
        // Use multiple hash bytes for better distribution
        const hash_idx = i * 3 % hash.len;
        const combined = @as(u64, hash[hash_idx]) |
            (@as(u64, hash[(hash_idx + 1) % hash.len]) << 8) |
            (@as(u64, hash[(hash_idx + 2) % hash.len]) << 16);
        result[i] = alphabet[combined % alphabet.len];
    }

    return result;
}

/// Check if a tool call ID is valid for a provider.
pub fn isValidToolCallId(id: []const u8, provider: Provider) bool {
    return switch (provider) {
        .mistral => id.len == 9 and isAlphanumericStr(id),
        .anthropic, .openai, .google, .bedrock => id.len > 0,
    };
}

/// Generate a Mistral-compatible tool call ID (9 alphanumeric chars).
/// Uses random bytes for uniqueness.
pub fn generateMistralToolCallId(allocator: Allocator) ![]u8 {
    const target_len = 9;
    var result = try allocator.alloc(u8, target_len);
    errdefer allocator.free(result);

    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    for (0..target_len) |i| {
        result[i] = alphabet[random_bytes[i] % alphabet.len];
    }

    return result;
}

/// Create a mapping from original ID to normalized ID for round-trip conversion
pub const ToolIdMapping = struct {
    original: []const u8,
    normalized: []const u8,

    pub fn deinit(self: *ToolIdMapping, allocator: Allocator) void {
        allocator.free(self.original);
        allocator.free(self.normalized);
    }
};

/// Create tool ID mappings for a slice of assistant content.
/// Caller owns returned slice and all strings within.
pub fn createToolIdMappingsFromContent(
    allocator: Allocator,
    content: []const ai_types.AssistantContent,
    provider: Provider,
) ![]ToolIdMapping {
    var mappings = try std.ArrayList(ToolIdMapping).initCapacity(allocator, 0);
    errdefer {
        for (mappings.items) |*m| {
            m.deinit(allocator);
        }
        mappings.deinit(allocator);
    }

    // Track seen IDs to avoid duplicates
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (content) |c| {
        switch (c) {
            .tool_call => |tool_block| {
                // Skip if we've already seen this ID
                if (seen.contains(tool_block.id)) {
                    continue;
                }

                const original = try allocator.dupe(u8, tool_block.id);
                errdefer allocator.free(original);

                const normalized = try normalizeToolCallId(allocator, tool_block.id, provider);
                errdefer allocator.free(normalized);

                try mappings.append(allocator, .{
                    .original = original,
                    .normalized = normalized,
                });

                try seen.put(original, {});
            },
            else => {},
        }
    }

    return try mappings.toOwnedSlice(allocator);
}

/// Free a slice of ToolIdMapping
pub fn freeToolIdMappings(allocator: Allocator, mappings: []ToolIdMapping) void {
    for (mappings) |*m| {
        m.deinit(allocator);
    }
    allocator.free(mappings);
}

/// Look up the original ID from a normalized ID
pub fn findOriginalId(mappings: []const ToolIdMapping, normalized_id: []const u8) ?[]const u8 {
    for (mappings) |m| {
        if (std.mem.eql(u8, m.normalized, normalized_id)) {
            return m.original;
        }
    }
    return null;
}

/// Look up the normalized ID from an original ID
pub fn findNormalizedId(mappings: []const ToolIdMapping, original_id: []const u8) ?[]const u8 {
    for (mappings) |m| {
        if (std.mem.eql(u8, m.original, original_id)) {
            return m.normalized;
        }
    }
    return null;
}

// Tests

test "normalizeToolCallId returns copy for non-Mistral providers" {
    const id = "tool_abc123";

    const result_anthropic = try normalizeToolCallId(std.testing.allocator, id, .anthropic);
    defer std.testing.allocator.free(result_anthropic);
    try std.testing.expectEqualStrings(id, result_anthropic);

    const result_openai = try normalizeToolCallId(std.testing.allocator, id, .openai);
    defer std.testing.allocator.free(result_openai);
    try std.testing.expectEqualStrings(id, result_openai);

    const result_google = try normalizeToolCallId(std.testing.allocator, id, .google);
    defer std.testing.allocator.free(result_google);
    try std.testing.expectEqualStrings(id, result_google);

    const result_bedrock = try normalizeToolCallId(std.testing.allocator, id, .bedrock);
    defer std.testing.allocator.free(result_bedrock);
    try std.testing.expectEqualStrings(id, result_bedrock);
}

test "normalizeToolCallId for Mistral returns 9 alphanumeric chars" {
    // Short ID
    const short_id = "abc";
    const result_short = try normalizeToolCallId(std.testing.allocator, short_id, .mistral);
    defer std.testing.allocator.free(result_short);
    try std.testing.expectEqual(@as(usize, 9), result_short.len);
    try std.testing.expect(isAlphanumericStr(result_short));

    // Long ID
    const long_id = "this_is_a_very_long_tool_call_id_with_special_chars!@#$";
    const result_long = try normalizeToolCallId(std.testing.allocator, long_id, .mistral);
    defer std.testing.allocator.free(result_long);
    try std.testing.expectEqual(@as(usize, 9), result_long.len);
    try std.testing.expect(isAlphanumericStr(result_long));

    // ID with special characters
    const special_id = "tool-123_abc!@#";
    const result_special = try normalizeToolCallId(std.testing.allocator, special_id, .mistral);
    defer std.testing.allocator.free(result_special);
    try std.testing.expectEqual(@as(usize, 9), result_special.len);
    try std.testing.expect(isAlphanumericStr(result_special));
}

test "normalizeToolCallId for Mistral preserves valid 9-char alphanumeric IDs" {
    const valid_id = "AbCdEfGhI";
    const result = try normalizeToolCallId(std.testing.allocator, valid_id, .mistral);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(valid_id, result);

    const valid_id_2 = "123456789";
    const result_2 = try normalizeToolCallId(std.testing.allocator, valid_id_2, .mistral);
    defer std.testing.allocator.free(result_2);
    try std.testing.expectEqualStrings(valid_id_2, result_2);

    const valid_id_3 = "aB9xY2zQ7";
    const result_3 = try normalizeToolCallId(std.testing.allocator, valid_id_3, .mistral);
    defer std.testing.allocator.free(result_3);
    try std.testing.expectEqualStrings(valid_id_3, result_3);
}

test "normalizeToolCallId for Mistral hashes 9-char non-alphanumeric IDs" {
    // 9 chars but contains non-alphanumeric
    const non_alpha_id = "tool-123_";
    const result = try normalizeToolCallId(std.testing.allocator, non_alpha_id, .mistral);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 9), result.len);
    try std.testing.expect(isAlphanumericStr(result));
    // Should NOT equal original because it had non-alphanumeric chars
    try std.testing.expect(!std.mem.eql(u8, non_alpha_id, result));
}

test "normalizeToolCallId is consistent - same input produces same output" {
    const id = "my_tool_call_id";

    const result1 = try normalizeToolCallId(std.testing.allocator, id, .mistral);
    defer std.testing.allocator.free(result1);

    const result2 = try normalizeToolCallId(std.testing.allocator, id, .mistral);
    defer std.testing.allocator.free(result2);

    try std.testing.expectEqualStrings(result1, result2);
}

test "normalizeToolCallId produces different results for different inputs" {
    const id1 = "tool_call_1";
    const id2 = "tool_call_2";

    const result1 = try normalizeToolCallId(std.testing.allocator, id1, .mistral);
    defer std.testing.allocator.free(result1);

    const result2 = try normalizeToolCallId(std.testing.allocator, id2, .mistral);
    defer std.testing.allocator.free(result2);

    try std.testing.expect(!std.mem.eql(u8, result1, result2));
}

test "isValidToolCallId for Mistral" {
    // Valid IDs
    try std.testing.expect(isValidToolCallId("AbCdEfGhI", .mistral));
    try std.testing.expect(isValidToolCallId("123456789", .mistral));
    try std.testing.expect(isValidToolCallId("aB9xY2zQ7", .mistral));

    // Invalid - wrong length
    try std.testing.expect(!isValidToolCallId("short", .mistral));
    try std.testing.expect(!isValidToolCallId("tooLongId123", .mistral));

    // Invalid - non-alphanumeric
    try std.testing.expect(!isValidToolCallId("tool-123", .mistral));
    try std.testing.expect(!isValidToolCallId("tool_123", .mistral));
    try std.testing.expect(!isValidToolCallId("tool 123", .mistral));
}

test "isValidToolCallId for other providers" {
    // Any non-empty string is valid
    try std.testing.expect(isValidToolCallId("any_id", .anthropic));
    try std.testing.expect(isValidToolCallId("tool-123_abc!@#", .openai));
    try std.testing.expect(isValidToolCallId("x", .google));

    // Empty string is invalid
    try std.testing.expect(!isValidToolCallId("", .anthropic));
    try std.testing.expect(!isValidToolCallId("", .openai));
}

test "generateMistralToolCallId produces valid IDs" {
    const id1 = try generateMistralToolCallId(std.testing.allocator);
    defer std.testing.allocator.free(id1);

    try std.testing.expectEqual(@as(usize, 9), id1.len);
    try std.testing.expect(isAlphanumericStr(id1));
    try std.testing.expect(isValidToolCallId(id1, .mistral));

    const id2 = try generateMistralToolCallId(std.testing.allocator);
    defer std.testing.allocator.free(id2);

    try std.testing.expectEqual(@as(usize, 9), id2.len);
    try std.testing.expect(isAlphanumericStr(id2));
    try std.testing.expect(isValidToolCallId(id2, .mistral));

    // Should be different (extremely unlikely to be same)
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}

test "ToolIdMapping create and lookup from AssistantContent" {
    const content = [_]ai_types.AssistantContent{
        .{ .tool_call = .{ .id = "tool_1", .name = "search", .arguments_json = "{}" } },
        .{ .tool_call = .{ .id = "tool_2", .name = "read", .arguments_json = "{}" } },
        .{ .text = .{ .text = "some text" } },
        .{ .tool_call = .{ .id = "tool_1", .name = "search", .arguments_json = "{}" } }, // duplicate
    };

    const mappings = try createToolIdMappingsFromContent(std.testing.allocator, &content, .mistral);
    defer freeToolIdMappings(std.testing.allocator, mappings);

    // Should have 2 unique tool IDs
    try std.testing.expectEqual(@as(usize, 2), mappings.len);

    // All normalized IDs should be valid for Mistral
    for (mappings) |m| {
        try std.testing.expect(isValidToolCallId(m.normalized, .mistral));
    }

    // Test lookup
    const orig = findOriginalId(mappings, mappings[0].normalized);
    try std.testing.expect(orig != null);
    try std.testing.expectEqualStrings(mappings[0].original, orig.?);

    const norm = findNormalizedId(mappings, mappings[1].original);
    try std.testing.expect(norm != null);
    try std.testing.expectEqualStrings(mappings[1].normalized, norm.?);

    // Non-existent lookup
    try std.testing.expect(findOriginalId(mappings, "nonexistent") == null);
    try std.testing.expect(findNormalizedId(mappings, "nonexistent") == null);
}

test "ToolIdMapping for non-Mistral provider preserves IDs" {
    const content = [_]ai_types.AssistantContent{
        .{ .tool_call = .{ .id = "tool_abc123", .name = "search", .arguments_json = "{}" } },
    };

    const mappings = try createToolIdMappingsFromContent(std.testing.allocator, &content, .anthropic);
    defer freeToolIdMappings(std.testing.allocator, mappings);

    try std.testing.expectEqual(@as(usize, 1), mappings.len);
    try std.testing.expectEqualStrings("tool_abc123", mappings[0].original);
    try std.testing.expectEqualStrings("tool_abc123", mappings[0].normalized);
}

test "isAlphanumericStr" {
    try std.testing.expect(isAlphanumericStr("abc"));
    try std.testing.expect(isAlphanumericStr("ABC"));
    try std.testing.expect(isAlphanumericStr("123"));
    try std.testing.expect(isAlphanumericStr("aBc123"));
    try std.testing.expect(isAlphanumericStr(""));

    try std.testing.expect(!isAlphanumericStr("abc_123"));
    try std.testing.expect(!isAlphanumericStr("abc-123"));
    try std.testing.expect(!isAlphanumericStr("abc 123"));
    try std.testing.expect(!isAlphanumericStr("abc!123"));
}
