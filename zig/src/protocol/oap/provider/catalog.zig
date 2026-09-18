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
    return null;
}

pub fn isExpressible(api: []const u8) bool {
    return mapApiToWire(api) != null;
}

pub fn unmappableApis(buffer: [][]const u8) [][]const u8 {
    var count: usize = 0;
    for (MAKAI_API_NAMES) |api| {
        if (isExpressible(api)) continue;
        buffer[count] = api;
        count += 1;
    }
    return buffer[0..count];
}

test "the closed wire set names five of makai's eight registered apis" {
    var expressible: usize = 0;
    for (MAKAI_API_NAMES) |api| {
        if (isExpressible(api)) expressible += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), expressible);
}

test "three registered apis have no value in the closed wire set" {
    var buffer: [MAKAI_API_NAMES.len][]const u8 = undefined;
    const unmappable = unmappableApis(&buffer);

    try std.testing.expectEqual(@as(usize, 3), unmappable.len);
    try std.testing.expectEqualStrings("google-generative-ai", unmappable[0]);
    try std.testing.expectEqualStrings("google-gemini-cli", unmappable[1]);
    try std.testing.expectEqualStrings("ollama", unmappable[2]);
}

test "two endpoints share the responses wire and are told apart by provider" {
    const azure = mapApiToWire("azure-openai-responses").?;
    const codex = mapApiToWire("openai-codex-responses").?;
    const native = mapApiToWire("openai-responses").?;

    try std.testing.expectEqual(types.Wire.@"openai-responses", azure.wire);
    try std.testing.expectEqual(types.Wire.@"openai-responses", codex.wire);
    try std.testing.expectEqual(types.Wire.@"openai-responses", native.wire);
}

test "ollama is the only attestation for ndjson framing and has no wire to carry it" {
    try std.testing.expect(!isExpressible("ollama"));

    var ndjson_sources: usize = 0;
    for (MAKAI_API_NAMES) |api| {
        const mapping = mapApiToWire(api) orelse continue;
        if (mapping.framing == .ndjson) ndjson_sources += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), ndjson_sources);
}
