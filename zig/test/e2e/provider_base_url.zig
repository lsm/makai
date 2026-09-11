
const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");
const protocol_server = @import("protocol_server");
const protocol_client = @import("protocol_client");
const envelope = @import("envelope");
const protocol_runtime = @import("protocol_runtime");
const in_process = @import("transports/in_process");

const testing = std.testing;
const ProtocolServer = protocol_server.ProtocolServer;
const ProtocolClient = protocol_client.ProtocolClient;
const ProviderProtocolRuntime = protocol_runtime.ProviderProtocolRuntime;

const protocol_types = envelope.protocol_types;

const FORCED_OPENAI_BASE_URL = "https://env-override.makai.test/openai";

const EXPECTED_CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex";
const EXPECTED_KIMI_BASE_URL = "https://api.kimi.com/coding";

const EXPECTED_DEFAULT_MAX_TOKENS: u32 = 4_096;

const EXPECTED_ANTHROPIC_CATALOG_MAX_TOKENS: u32 = 8_192;
const EXPECTED_KIMI_CATALOG_MAX_TOKENS: u32 = 16_384;

const MockCapture = struct {
    var buffer: [512]u8 = undefined;
    var base_url: ?[]const u8 = null;
    var max_tokens: u32 = 0;
    var compat_options: ?ai_types.OpenAICompatOptions = null;
    var reasoning: bool = false;

    fn reset() void {
        base_url = null;
        max_tokens = 0;
        compat_options = null;
        reasoning = false;
    }

    fn capture(model: ai_types.Model) void {
        const len = @min(model.base_url.len, buffer.len);
        @memcpy(buffer[0..len], model.base_url[0..len]);
        base_url = buffer[0..len];
        max_tokens = model.max_tokens;
        compat_options = model.compat;
        reasoning = model.reasoning;
    }
};

fn capturingStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = context;
    _ = options;

    MockCapture.capture(model);

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
    s.complete(.{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
    });
    s.markThreadDone();
    return s;
}

fn capturingStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = options;
    return capturingStream(model, context, null, allocator);
}

fn emptyBaseUrlModel(provider_id: []const u8, api: []const u8, model_id: []const u8) ai_types.Model {
    return .{
        .id = model_id,
        .name = model_id,
        .api = api,
        .provider = provider_id,
        .base_url = "",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 0,
    };
}

fn registerCapturingProvider(registry: *api_registry.ApiRegistry, api: []const u8) !void {
    try registry.registerApiProvider(.{
        .api = api,
        .stream = capturingStream,
        .stream_simple = capturingStreamSimple,
    }, null);
}

fn expectValidHttpsUrl(url: []const u8) !void {
    try testing.expect(url.len > 0);
    const uri = std.Uri.parse(url) catch |err| {
        std.debug.print("resolved base URL is not a valid URI: '{s}' ({t})\n", .{ url, err });
        return err;
    };
    try testing.expectEqualStrings("https", uri.scheme);
    try testing.expect(uri.host != null);
}

test "stdio protocol stream defaults empty base URL for anthropic" {
    MockCapture.reset();
    defer MockCapture.reset();

    const allocator = testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try registerCapturingProvider(&registry, "anthropic-messages");

    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();
    client.setSender(pipe.clientSender());

    var runtime = ProviderProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    const model = emptyBaseUrlModel("anthropic", "anthropic-messages", "claude-sonnet-4-5");
    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Reply with exactly: hello world" },
        .timestamp = compat.time.nowSeconds(),
    } };
    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };
    const options = ai_types.StreamOptions{
        .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key"),
    };

    _ = try client.sendStreamRequest(model, ctx, options);
    try runtime.pumpClientMessages();

    try testing.expectEqual(@as(usize, 1), server.activeStreamCount());

    const captured = MockCapture.base_url orelse return error.TestUnexpectedResult;
    try expectValidHttpsUrl(captured);
    try testing.expectEqualStrings("https://api.anthropic.com", captured);
    try testing.expect(MockCapture.compat_options == null);
    try testing.expectEqual(EXPECTED_ANTHROPIC_CATALOG_MAX_TOKENS, MockCapture.max_tokens);
}

test "stdio protocol stream respects OPENAI_BASE_URL env override end-to-end" {
    MockCapture.reset();
    defer MockCapture.reset();

    const allocator = testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try registerCapturingProvider(&registry, "openai-completions");

    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    var client = ProtocolClient.init(allocator, .{});
    defer client.deinit();
    client.setSender(pipe.clientSender());

    var runtime = ProviderProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    const model = emptyBaseUrlModel("openai", "openai-completions", "gpt-5-mini");
    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Reply with exactly: hello world" },
        .timestamp = compat.time.nowSeconds(),
    } };
    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };
    const options = ai_types.StreamOptions{
        .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key"),
    };

    _ = try client.sendStreamRequest(model, ctx, options);
    try runtime.pumpClientMessages();

    const captured = MockCapture.base_url orelse return error.TestUnexpectedResult;

    try testing.expectEqualStrings(FORCED_OPENAI_BASE_URL, captured);
    try testing.expectEqual(EXPECTED_DEFAULT_MAX_TOKENS, MockCapture.max_tokens);
    try testing.expect(MockCapture.reasoning);

    const compat_options = MockCapture.compat_options orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?bool, true), compat_options.supports_store);
    try testing.expectEqual(@as(?bool, true), compat_options.supports_developer_role);
    try testing.expectEqual(@as(@TypeOf(compat_options.max_tokens_field), .max_completion_tokens), compat_options.max_tokens_field);
}

test "stdio protocol stream defaults catalog-issued codex and kimi refs" {
    {
        MockCapture.reset();
        defer MockCapture.reset();

        const allocator = testing.allocator;

        var registry = api_registry.ApiRegistry.init(allocator);
        defer registry.deinit();
        try registerCapturingProvider(&registry, "openai-codex-responses");

        var server = ProtocolServer.init(allocator, &registry, .{});
        defer server.deinit();

        var pipe = in_process.createSerializedPipe(allocator);
        defer pipe.deinit();

        var client = ProtocolClient.init(allocator, .{});
        defer client.deinit();
        client.setSender(pipe.clientSender());

        var runtime = ProviderProtocolRuntime{
            .server = &server,
            .pipe = &pipe,
            .allocator = allocator,
        };

        const model = emptyBaseUrlModel("openai-codex", "openai-codex-responses", "gpt-5-codex");
        const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{} };
        const options = ai_types.StreamOptions{
            .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key"),
        };

        _ = try client.sendStreamRequest(model, ctx, options);
        try runtime.pumpClientMessages();

        const captured = MockCapture.base_url orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(EXPECTED_CODEX_BASE_URL, captured);
    }

    {
        MockCapture.reset();
        defer MockCapture.reset();

        const allocator = testing.allocator;

        var registry = api_registry.ApiRegistry.init(allocator);
        defer registry.deinit();
        try registerCapturingProvider(&registry, "openai-completions");

        var server = ProtocolServer.init(allocator, &registry, .{});
        defer server.deinit();

        var pipe = in_process.createSerializedPipe(allocator);
        defer pipe.deinit();

        var client = ProtocolClient.init(allocator, .{});
        defer client.deinit();
        client.setSender(pipe.clientSender());

        var runtime = ProviderProtocolRuntime{
            .server = &server,
            .pipe = &pipe,
            .allocator = allocator,
        };

        const model = emptyBaseUrlModel("kimi", "openai-completions", "kimi-k2.7-code");
        const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{} };
        const options = ai_types.StreamOptions{
            .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key"),
        };

        _ = try client.sendStreamRequest(model, ctx, options);
        try runtime.pumpClientMessages();

        const captured = MockCapture.base_url orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(EXPECTED_KIMI_BASE_URL, captured);
        try testing.expectEqual(EXPECTED_KIMI_CATALOG_MAX_TOKENS, MockCapture.max_tokens);
    }
}

test "stdio protocol complete_request defaults empty base URL" {
    MockCapture.reset();
    defer MockCapture.reset();

    const allocator = testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try registerCapturingProvider(&registry, "anthropic-messages");

    var server = ProtocolServer.init(allocator, &registry, .{});
    defer server.deinit();

    var pipe = in_process.createSerializedPipe(allocator);
    defer pipe.deinit();

    var runtime = ProviderProtocolRuntime{
        .server = &server,
        .pipe = &pipe,
        .allocator = allocator,
    };

    var env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .complete_request = .{
            .model = emptyBaseUrlModel("anthropic", "anthropic-messages", "claude-sonnet-4-5"),
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    defer env.deinit(allocator);
    const json = try envelope.serializeEnvelope(env, allocator);
    defer allocator.free(json);

    var sender = pipe.clientSender();
    try sender.write(json);
    try sender.flush();

    try runtime.pumpClientMessages();

    const captured = MockCapture.base_url orelse return error.TestUnexpectedResult;
    try expectValidHttpsUrl(captured);
    try testing.expectEqualStrings("https://api.anthropic.com", captured);
    try testing.expectEqual(EXPECTED_ANTHROPIC_CATALOG_MAX_TOKENS, MockCapture.max_tokens);

    var receiver = pipe.clientReceiver();
    const line = try receiver.readLine(allocator) orelse return error.TestUnexpectedResult;
    defer allocator.free(line);
    var resp = try envelope.deserializeEnvelope(line, allocator);
    defer resp.deinit(allocator);
    try testing.expect(resp.payload == .result);
}
