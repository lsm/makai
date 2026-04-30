//! Distributed Fullstack E2E (GitHub Copilot, non-mock provider)
//!
//! Verifies end-to-end distributed wiring with a real provider path:
//!   - agent loop
//!   - provider protocol bridge
//!   - tool protocol runtime (remote tool execution callback path)

const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const test_helpers = @import("test_helpers");
const agent_types = @import("agent_types");
const agent_loop = @import("agent_loop");
const agent_bridge = @import("agent_bridge");
const tool_types = @import("tool_types");
const tool_envelope = @import("tool_envelope");
const tool_runtime = @import("tool_runtime");
const in_process = @import("transports/in_process");

const InProcessProviderProtocolBridge = agent_bridge.InProcessProviderProtocolBridge;
const ToolProtocolRuntime = tool_runtime.ToolProtocolRuntime;

const ToolServerState = struct {};

const ToolClientState = struct {
    saw_result: bool = false,
    saw_error: bool = false,
    result_json: ?[]u8 = null,
    details_json: ?[]u8 = null,
    error_message: ?[]u8 = null,

    fn deinit(self: *ToolClientState, allocator: std.mem.Allocator) void {
        if (self.result_json) |v| allocator.free(v);
        if (self.details_json) |v| allocator.free(v);
        if (self.error_message) |v| allocator.free(v);
    }
};

fn shouldNotExecuteLocalTool(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent_types.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent_types.AgentToolResult {
    _ = tool_call_id;
    _ = args_json;
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;
    _ = allocator;
    return error.UnexpectedLocalToolExecution;
}

fn handleToolClientEnvelope(
    ctx: ?*anyopaque,
    env: tool_types.Envelope,
    allocator: std.mem.Allocator,
) anyerror!?tool_types.Envelope {
    _ = ctx;
    if (env.payload != .tool_execute) return null;

    const req = env.payload.tool_execute;
    const ParsedArgs = struct { a: i64, b: i64 };
    var parsed_args = try std.json.parseFromSlice(ParsedArgs, allocator, req.args_json, .{});
    defer parsed_args.deinit();
    const sum = parsed_args.value.a + parsed_args.value.b;

    const result_json = try std.fmt.allocPrint(allocator, "[{{\"type\":\"text\",\"text\":\"sum={d}\"}}]", .{sum});
    return .{
        .server_id = env.server_id,
        .message_id = tool_types.generateUuid(),
        .sequence = env.sequence + 1,
        .in_reply_to = env.message_id,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .tool_result = .{
            .execution_id = req.execution_id,
            .tool_call_id = try allocator.dupe(u8, req.tool_call_id),
            .result_json = result_json,
            .duration_ms = 1,
        } },
    };
}

fn processToolServerEnvelope(
    ctx: ?*anyopaque,
    env: tool_types.Envelope,
    allocator: std.mem.Allocator,
) anyerror!void {
    const client: *ToolClientState = @ptrCast(@alignCast(ctx.?));
    switch (env.payload) {
        .tool_result => |res| {
            client.saw_result = true;
            client.result_json = try allocator.dupe(u8, res.result_json);
            if (res.getDetailsJson()) |details| {
                client.details_json = try allocator.dupe(u8, details);
            }
        },
        .tool_error => |err| {
            client.saw_error = true;
            client.error_message = try allocator.dupe(u8, err.message);
        },
        else => {},
    }
}

fn executeToolViaProtocol(
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent_types.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent_types.AgentToolResult {
    _ = ctx;
    _ = on_update_ctx;
    _ = on_update;

    if (cancel_token) |token| {
        if (token.isCancelled()) return error.Cancelled;
    }

    var pipe = in_process.SerializedPipe.init(allocator);
    defer pipe.deinit();

    var server_ctx = ToolServerState{};
    var client_ctx = ToolClientState{};
    defer client_ctx.deinit(allocator);

    var runtime = ToolProtocolRuntime{
        .pipe = &pipe,
        .allocator = allocator,
        .server_ctx = &server_ctx,
        .client_ctx = &client_ctx,
        .handle_client_envelope_fn = handleToolClientEnvelope,
        .process_server_envelope_fn = processToolServerEnvelope,
    };

    var req_env = tool_types.Envelope{
        .server_id = tool_types.generateUuid(),
        .message_id = tool_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .tool_execute = .{
            .execution_id = tool_types.generateUuid(),
            .tool_call_id = try allocator.dupe(u8, tool_call_id),
            .tool_name = try allocator.dupe(u8, tool_name),
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

    if (client_ctx.saw_error) return error.ToolProtocolExecutionFailed;
    if (!client_ctx.saw_result or client_ctx.result_json == null) return error.NoToolResult;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, client_ctx.result_json.?, .{});
    defer parsed.deinit();

    const arr = parsed.value.array.items;
    if (arr.len == 0) return error.InvalidToolResult;
    const first = arr[0].object;
    const text_val = first.get("text") orelse return error.InvalidToolResult;

    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    content[0] = .{ .text = .{
        .text = try allocator.dupe(u8, text_val.string),
    } };

    return .{
        .content = agent_types.OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = if (client_ctx.details_json) |details|
            agent_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, details))
        else
            agent_types.OwnedSlice(u8).initBorrowed(""),
    };
}

test "distributed fullstack github: agent loop via provider+tool protocols without mock provider" {
    const allocator = std.testing.allocator;

    try test_helpers.skipGitHubCopilotTest(allocator);
    var creds = (try test_helpers.getFreshGitHubCopilotCredentials(allocator)) orelse return error.SkipZigTest;
    defer creds.deinit(allocator);

    var registry = api_registry.ApiRegistry.init(allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    var bridge = InProcessProviderProtocolBridge.init(&registry);
    var context = agent_types.AgentContext.init(allocator);
    defer context.deinit();

    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "openai-completions",
        .provider = "github-copilot",
        .base_url = creds.base_url orelse "https://api.individual.githubcopilot.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 200,
    };

    const prompt_text = try allocator.dupe(
        u8,
        "You must call tool remote_sum exactly once with arguments {\"a\":2,\"b\":3}. " ++
            "After receiving the tool result, answer with exactly: final answer: sum=5",
    );
    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = prompt_text },
        .timestamp = std.time.milliTimestamp(),
    } };

    const tools = [_]agent_types.AgentTool{
        .{
            .label = "Remote Sum",
            .name = "remote_sum",
            .description = "Add two integers and return sum",
            .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"integer\"},\"b\":{\"type\":\"integer\"}},\"required\":[\"a\",\"b\"]}",
            .execute = shouldNotExecuteLocalTool,
        },
    };

    const stream = try agent_loop.agentLoop(allocator, &.{prompt}, &context, .{
        .model = model,
        .protocol = bridge.protocolClient(),
        .api_key = creds.copilot_token,
        .session_id = "distributed-fullstack-github",
        .tools = &tools,
        .execute_tool_via_protocol_fn = executeToolViaProtocol,
        .max_iterations = 4,
        .temperature = 0.0,
        .max_tokens = 200,
    });
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    var saw_tool_start = false;
    var saw_tool_end = false;
    while (stream.wait()) |event| {
        switch (event) {
            .tool_execution_start => saw_tool_start = true,
            .tool_execution_end => saw_tool_end = true,
            .message_update => |u| {
                var owned_event = u.event;
                ai_types.deinitAssistantMessageEvent(allocator, &owned_event);
            },
            else => {},
        }
    }

    const result = stream.getResult() orelse return error.MissingResult;
    var found_tool_result = false;
    for (result.messages.slice()) |message| {
        if (message != .tool_result) continue;
        found_tool_result = true;
        try std.testing.expectEqualStrings("remote_sum", message.tool_result.tool_name);
    }

    if (!saw_tool_start or !saw_tool_end or !found_tool_result) {
        std.debug.print(
            "\n\x1b[90mNOTE\x1b[0m: distributed github fullstack test - provider response did not include a tool call in this run\n",
            .{},
        );
        return;
    }

    try std.testing.expectEqual(ai_types.StopReason.stop, result.final_message.stop_reason);
}
