const std = @import("std");
const types = @import("oap_provider_types");

pub const MAKAI_API_NAMES = [_][]const u8{
    "anthropic-messages",
    "openai-completions",
    "openai-responses",
    "azure-openai-responses",
    "openai-codex-responses",
    "google-generative-ai",
    "google-gemini-cli",
    "ollama",
};

pub const WireMapping = struct {
    wire: types.Wire,
    framing: types.Framing,
};

pub fn mapApiToWire(api: []const u8) ?WireMapping {
    if (std.mem.eql(u8, api, "anthropic-messages")) {
        return .{ .wire = .@"anthropic-messages", .framing = .sse };
    }
    if (std.mem.eql(u8, api, "openai-completions")) {
        return .{ .wire = .@"openai-chat-completions", .framing = .sse };
    }
    if (std.mem.eql(u8, api, "openai-responses")) {
        return .{ .wire = .@"openai-responses", .framing = .sse };
    }
    if (std.mem.eql(u8, api, "azure-openai-responses")) {
        return .{ .wire = .@"openai-responses", .framing = .sse };
    }
    if (std.mem.eql(u8, api, "openai-codex-responses")) {
        return .{ .wire = .@"openai-responses", .framing = .sse };
    }
    if (std.mem.eql(u8, api, "google-generative-ai")) {
        return .{ .wire = .other, .framing = .sse };
    }
    if (std.mem.eql(u8, api, "google-gemini-cli")) {
        return .{ .wire = .other, .framing = .sse };
    }
    if (std.mem.eql(u8, api, "ollama")) {
        return .{ .wire = .other, .framing = .ndjson };
    }
    return null;
}

pub fn isExpressible(api: []const u8) bool {
    return mapApiToWire(api) != null;
}

pub fn hasNamedWire(api: []const u8) bool {
    const mapping = mapApiToWire(api) orelse return false;
    return mapping.wire.isNamed();
}

pub fn unnamedWireApis(buffer: [][]const u8) [][]const u8 {
    var count: usize = 0;
    for (MAKAI_API_NAMES) |api| {
        if (hasNamedWire(api)) continue;
        buffer[count] = api;
        count += 1;
    }
    return buffer[0..count];
}

test "every registered api is describable and five earn a named wire" {
    var named: usize = 0;
    for (MAKAI_API_NAMES) |api| {
        try std.testing.expect(isExpressible(api));
        if (hasNamedWire(api)) named += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), named);
}

test "the three that name no wire are the ones no second implementer speaks" {
    var buffer: [MAKAI_API_NAMES.len][]const u8 = undefined;
    const unnamed = unnamedWireApis(&buffer);

    try std.testing.expectEqual(@as(usize, 3), unnamed.len);
    try std.testing.expectEqualStrings("google-generative-ai", unnamed[0]);
    try std.testing.expectEqualStrings("google-gemini-cli", unnamed[1]);
    try std.testing.expectEqualStrings("ollama", unnamed[2]);
}

test "two endpoints share the responses wire and are told apart by provider" {
    const azure = mapApiToWire("azure-openai-responses").?;
    const codex = mapApiToWire("openai-codex-responses").?;
    const native = mapApiToWire("openai-responses").?;

    try std.testing.expectEqual(types.Wire.@"openai-responses", azure.wire);
    try std.testing.expectEqual(types.Wire.@"openai-responses", codex.wire);
    try std.testing.expectEqual(types.Wire.@"openai-responses", native.wire);
}

test "ndjson is reachable now that an unnamed wire can carry it" {
    var ndjson_sources: usize = 0;
    for (MAKAI_API_NAMES) |api| {
        const mapping = mapApiToWire(api) orelse continue;
        if (mapping.framing == .ndjson) ndjson_sources += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ndjson_sources);

    const ollama = mapApiToWire("ollama").?;
    try std.testing.expectEqual(types.Framing.ndjson, ollama.framing);
    try std.testing.expect(!ollama.wire.isNamed());
}

test "a named wire is never invented for a shape only its originator speaks" {
    try std.testing.expect(!hasNamedWire("ollama"));
    try std.testing.expect(!hasNamedWire("google-generative-ai"));
    try std.testing.expect(hasNamedWire("anthropic-messages"));
}
