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

pub const BuiltInProvider = struct {
    id: []const u8,
    api: []const u8,
    endpoint: []const u8,
    allows_anonymous: bool,
    model_id: []const u8,
    display_name: []const u8,
    context_window: u32,
    max_output_tokens: u32,
};

pub const BUILT_IN_PROVIDERS = [_]BuiltInProvider{
    .{
        .id = "anthropic",
        .api = "anthropic-messages",
        .endpoint = "https://api.anthropic.com",
        .allows_anonymous = false,
        .model_id = "claude-sonnet-4-5",
        .display_name = "Claude Sonnet 4.5",
        .context_window = 200_000,
        .max_output_tokens = 8_192,
    },
    .{
        .id = "openai",
        .api = "openai-responses",
        .endpoint = "https://api.openai.com",
        .allows_anonymous = false,
        .model_id = "gpt-4o",
        .display_name = "GPT-4o",
        .context_window = 128_000,
        .max_output_tokens = 16_384,
    },
    .{
        .id = "ollama",
        .api = "ollama",
        .endpoint = "http://127.0.0.1:11434",
        .allows_anonymous = true,
        .model_id = "llama3",
        .display_name = "Llama 3",
        .context_window = 128_000,
        .max_output_tokens = 8_192,
    },
};

pub fn buildModelRef(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    wire: types.Wire,
    model_id: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}@{s}", .{ provider_id, wire.toString(), model_id });
}

test "a built in provider yields a model ref that names its own wire" {
    const allocator = std.testing.allocator;
    const mapping = mapApiToWire("ollama").?;
    const model_ref = try buildModelRef(allocator, "ollama", mapping.wire, "llama3");
    defer allocator.free(model_ref);
    try std.testing.expectEqualStrings("ollama/other@llama3", model_ref);
}

test "every built in provider maps to a describable wire" {
    for (BUILT_IN_PROVIDERS) |provider| {
        try std.testing.expect(isExpressible(provider.api));
    }
}
