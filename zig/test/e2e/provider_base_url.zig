//! Provider Protocol E2E: default base URL resolution on the stdio path (#183).
//!
//! Streams through the same line-delimited JSON framing the stdio transport
//! uses (ProtocolClient -> SerializedPipe -> ProtocolServer -> mock provider),
//! no API keys required. Asserts the server defaults empty client-supplied
//! base URLs — the TS SDK sends `base_url: ""` in every model descriptor —
//! and that `*_BASE_URL` env overrides are respected end-to-end. The build
//! step pins `OPENAI_BASE_URL` for this binary so the override assertion is
//! deterministic on every machine.

const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");
const protocol_server = @import("protocol_server");
const protocol_client = @import("protocol_client");
const envelope = @import("envelope");
const protocol_runtime = @import("protocol_runtime");
const provider_base_url = @import("provider_base_url");
const in_process = @import("transports/in_process");

const testing = std.testing;
const ProtocolServer = protocol_server.ProtocolServer;
const ProtocolClient = protocol_client.ProtocolClient;
const ProviderProtocolRuntime = protocol_runtime.ProviderProtocolRuntime;

// Access protocol_types through envelope module (which re-exports types)
const protocol_types = envelope.protocol_types;

/// Forced by the build step for this test binary, so the env-override
/// assertion below is deterministic regardless of the host environment.
const FORCED_OPENAI_BASE_URL = "https://env-override.makai.test/openai";

/// Base URL the last mock provider stream received. The capture happens
/// synchronously while the runtime pumps the client message, before the test
/// inspects it. The static buffer outlives the request (wire base URLs are
/// capped at MAX_MODEL_FIELD_LENGTH = 512 bytes).
const MockCapture = struct {
    var buffer: [512]u8 = undefined;
    var base_url: ?[]const u8 = null;

    fn reset() void {
        base_url = null;
    }

    fn capture(url: []const u8) void {
        const len = @min(url.len, buffer.len);
        @memcpy(buffer[0..len], url[0..len]);
        base_url = buffer[0..len];
    }
};

/// Mock provider stream: captures the model's base URL and completes
/// immediately with a result (no network, no background thread).
fn capturingStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = context;
    _ = options;

    MockCapture.capture(model.base_url);

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

/// Model shaped like the TS SDK's descriptors: known provider/API routing
/// but an empty base URL.
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
        .max_tokens = 4096,
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

    // The TS SDK sends base_url: "" for every model descriptor (#183).
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

    // The stream reached the provider through the full protocol path.
    try testing.expectEqual(@as(usize, 1), server.activeStreamCount());

    const captured = MockCapture.base_url orelse return error.TestUnexpectedResult;
    try expectValidHttpsUrl(captured);

    // Canonical default (or the machine's env override, matched exactly so
    // the assertion holds wherever *_BASE_URL vars are set).
    const expected = try provider_base_url.defaultBaseUrlForRef(allocator, "anthropic", "anthropic-messages");
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, captured);
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

    // The build step pins OPENAI_BASE_URL for this binary, so the provider
    // must have seen exactly that endpoint — the env override survived the
    // whole client -> wire -> server -> provider path.
    try testing.expectEqualStrings(FORCED_OPENAI_BASE_URL, captured);
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

    // complete_request has no client-side helper; frame it exactly like the
    // wire protocol does.
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
    const expected = try provider_base_url.defaultBaseUrlForRef(allocator, "anthropic", "anthropic-messages");
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, captured);

    // The server answered with a result envelope on the client-facing pipe.
    var receiver = pipe.clientReceiver();
    const line = try receiver.readLine(allocator) orelse return error.TestUnexpectedResult;
    defer allocator.free(line);
    var resp = try envelope.deserializeEnvelope(line, allocator);
    defer resp.deinit(allocator);
    try testing.expect(resp.payload == .result);
}
