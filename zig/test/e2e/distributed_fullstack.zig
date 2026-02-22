//! Distributed Fullstack E2E (mock-based)
//!
//! Verifies agent loop end-to-end behavior when:
//!   - provider calls flow through provider protocol bridge
//!   - tool calls execute through tool protocol runtime
//! without requiring external provider credentials.

const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");
const agent_types = @import("agent_types");
const agent_loop = @import("agent_loop");
const agent_bridge = @import("agent_bridge");
const tool_types = @import("tool_types");
const tool_envelope = @import("tool_envelope");
const tool_runtime = @import("tool_runtime");
const in_process = @import("transports/in_process");

const InProcessProviderProtocolBridge = agent_bridge.InProcessProviderProtocolBridge;
const ToolProtocolRuntime = tool_runtime.ToolProtocolRuntime;

fn contextHasToolResult(context: ai_types.Context) bool {
    for (context.messages) |message| {
        if (message == .tool_result) return true;
    }
    return false;
}

fn makeToolUseMessage(allocator: std.mem.Allocator) !ai_types.AssistantMessage {
    const content = try allocator.alloc(ai_types.AssistantContent, 1);
    content[0] = .{ .tool_call = .{
        .id = try allocator.dupe(u8, "call_remote_sum"),
        .name = try allocator.dupe(u8, "remote_sum"),
        .arguments_json = try allocator.dupe(u8, "{\"a\":2,\"b\":3}"),
    } };

    return .{
        .content = content,
        .api = "mock-api",
        .provider = "mock",
        .model = "mock-model",
        .usage = .{},
        .stop_reason = .tool_use,
        .timestamp = std.time.milliTimestamp(),
        .is_owned = false,
    };
}

fn makeFinalMessage(allocator: std.mem.Allocator) !ai_types.AssistantMessage {
    const content = try allocator.alloc(ai_types.AssistantContent, 1);
    content[0] = .{ .text = .{
        .text = try allocator.dupe(u8, "final answer: sum=5"),
    } };

    return .{
        .content = content,
        .api = "mock-api",
        .provider = "mock",
        .model = "mock-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = std.time.milliTimestamp(),
        .is_owned = false,
    };
}

fn distributedMockProviderStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = options;

    const stream = try allocator.create(event_stream.AssistantMessageEventStream);
    stream.* = event_stream.AssistantMessageEventStream.init(allocator);

    const response = if (contextHasToolResult(context))
        try makeFinalMessage(allocator)
    else
        try makeToolUseMessage(allocator);

    try stream.push(.{
        .done = .{
            .reason = response.stop_reason,
            .message = response,
        },
    });
    stream.complete(response);
    stream.markThreadDone();
    return stream;
}

fn distributedMockProviderStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = options;
    return distributedMockProviderStream(model, context, null, allocator);
}

fn remoteSumToolExecute(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent_types.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent_types.AgentToolResult {
    _ = on_update_ctx;
    _ = on_update;

    if (cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }

    const Args = struct { a: i64, b: i64 };
    var parsed = try std.json.parseFromSlice(Args, allocator, args_json, .{});
    defer parsed.deinit();
    const sum = parsed.value.a + parsed.value.b;

    const ServerCtx = struct {};
    const ClientCtx = struct {
        received_result: bool = false,
        received_error: bool = false,
    };

    const callbacks = struct {
        fn handleClientEnvelope(
            ctx: ?*anyopaque,
            env: tool_types.Envelope,
            test_allocator: std.mem.Allocator,
        ) !?tool_types.Envelope {
            _ = ctx;
            if (env.payload != .tool_execute) return null;

            const req = env.payload.tool_execute;
            const ParsedArgs = struct { a: i64, b: i64 };
            var parsed_args = try std.json.parseFromSlice(ParsedArgs, test_allocator, req.args_json, .{});
            defer parsed_args.deinit();
            const computed = parsed_args.value.a + parsed_args.value.b;

            const result_json = try std.fmt.allocPrint(test_allocator, "[{{\"type\":\"text\",\"text\":\"sum={d}\"}}]", .{computed});

            return .{
                .server_id = env.server_id,
                .message_id = tool_types.generateUuid(),
                .sequence = env.sequence + 1,
                .in_reply_to = env.message_id,
                .timestamp = std.time.milliTimestamp(),
                .payload = .{ .tool_result = .{
                    .execution_id = req.execution_id,
                    .tool_call_id = try test_allocator.dupe(u8, req.tool_call_id),
                    .result_json = result_json,
                    .duration_ms = 1,
                } },
            };
        }

        fn processServerEnvelope(
            ctx: ?*anyopaque,
            env: tool_types.Envelope,
            test_allocator: std.mem.Allocator,
        ) !void {
            _ = test_allocator;
            const client: *ClientCtx = @ptrCast(@alignCast(ctx.?));
            switch (env.payload) {
                .tool_result => client.received_result = true,
                .tool_error => client.received_error = true,
                else => {},
            }
        }
    };

    var pipe = in_process.SerializedPipe.init(allocator);
    defer pipe.deinit();

    var server_ctx = ServerCtx{};
    var client_ctx = ClientCtx{};
    var runtime = ToolProtocolRuntime{
        .pipe = &pipe,
        .allocator = allocator,
        .server_ctx = &server_ctx,
        .client_ctx = &client_ctx,
        .handle_client_envelope_fn = callbacks.handleClientEnvelope,
        .process_server_envelope_fn = callbacks.processServerEnvelope,
    };

    var req_env = tool_types.Envelope{
        .server_id = tool_types.generateUuid(),
        .message_id = tool_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .tool_execute = .{
            .execution_id = tool_types.generateUuid(),
            .tool_call_id = try allocator.dupe(u8, tool_call_id),
            .tool_name = try allocator.dupe(u8, "remote_sum"),
            .args_json = try allocator.dupe(u8, args_json),
        } },
    };
    defer req_env.deinit(allocator);

    const req_json = try tool_envelope.serializeEnvelope(req_env, allocator);
    defer allocator.free(req_json);

    var sender = pipe.clientSender();
    try sender.write(req_json);
    try sender.flush();

    _ = try runtime.pumpOnce();

    if (client_ctx.received_error or !client_ctx.received_result) {
        return error.ToolProtocolExecutionFailed;
    }

    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{
        .text = try std.fmt.allocPrint(allocator, "sum={d}", .{sum}),
    } };
    const details_json = try std.fmt.allocPrint(allocator, "{{\"sum\":{d},\"remote\":true}}", .{sum});

    return .{
        .content = agent_types.OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = agent_types.OwnedSlice(u8).initOwned(details_json),
    };
}

fn filterContextForProtocol(
    ctx: ?*anyopaque,
    messages: []const ai_types.Message,
    allocator: std.mem.Allocator,
) anyerror![]const ai_types.Message {
    _ = ctx;
    var filtered = std.ArrayList(ai_types.Message){};
    defer filtered.deinit(allocator);

    for (messages) |message| {
        if (message == .assistant) continue;
        try filtered.append(allocator, message);
    }
    return try filtered.toOwnedSlice(allocator);
}

test "distributed fullstack: agent loop via provider protocol and tool protocol" {
    const allocator = std.testing.allocator;

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerApiProvider(.{
        .api = "mock-api",
        .stream = distributedMockProviderStream,
        .stream_simple = distributedMockProviderStreamSimple,
    }, null);

    var bridge = InProcessProviderProtocolBridge.init(&registry);
    var context = agent_types.AgentContext.init(allocator);
    defer context.deinit();

    const model = ai_types.Model{
        .id = "mock-model",
        .name = "Mock",
        .api = "mock-api",
        .provider = "mock",
        .base_url = "",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 8192,
        .max_tokens = 256,
    };

    const prompt_text = try allocator.dupe(u8, "What is 2 + 3?");
    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = prompt_text },
        .timestamp = std.time.milliTimestamp(),
    } };

    const tools = [_]agent_types.AgentTool{
        .{
            .label = "Remote Sum",
            .name = "remote_sum",
            .description = "Add two numbers remotely",
            .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]}",
            .execute = remoteSumToolExecute,
        },
    };

    const stream = try agent_loop.agentLoop(allocator, &.{prompt}, &context, .{
        .model = model,
        .protocol = bridge.protocolClient(),
        .tools = &tools,
        .max_iterations = 4,
        .transform_context_fn = filterContextForProtocol,
    });
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    var saw_tool_execution_start = false;
    var saw_tool_execution_end = false;

    while (stream.wait()) |event| {
        switch (event) {
            .tool_execution_start => saw_tool_execution_start = true,
            .tool_execution_end => saw_tool_execution_end = true,
            else => {},
        }
    }

    const result = stream.getResult().?;
    try std.testing.expectEqual(@as(u32, 2), result.iterations);
    try std.testing.expect(saw_tool_execution_start);
    try std.testing.expect(saw_tool_execution_end);
    try std.testing.expectEqual(ai_types.StopReason.stop, result.final_message.stop_reason);
    try std.testing.expect(result.final_message.content.len == 1);
    try std.testing.expect(result.final_message.content[0] == .text);
    try std.testing.expectEqualStrings("final answer: sum=5", result.final_message.content[0].text.text);

    var found_tool_result = false;
    for (result.messages.slice()) |message| {
        if (message != .tool_result) continue;
        found_tool_result = true;
        try std.testing.expectEqualStrings("remote_sum", message.tool_result.tool_name);
        try std.testing.expectEqual(@as(usize, 1), message.tool_result.content.len);
        try std.testing.expect(message.tool_result.content[0] == .text);
        try std.testing.expectEqualStrings("sum=5", message.tool_result.content[0].text.text);
    }
    try std.testing.expect(found_tool_result);
}
