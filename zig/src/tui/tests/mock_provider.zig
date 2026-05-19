const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const agent = @import("agent");

pub const test_model = ai_types.Model{
    .id = "tui-fixture-model",
    .name = "TUI Fixture Model",
    .api = "tui-fixture-api",
    .provider = "tui-fixture-provider",
    .base_url = "https://example.invalid",
    .reasoning = false,
    .input = &.{"text"},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 8192,
    .max_tokens = 1024,
};

pub const alternate_model = ai_types.Model{
    .id = "tui-fixture-model-alt",
    .name = "TUI Fixture Model Alt",
    .api = "tui-fixture-api",
    .provider = "tui-fixture-provider",
    .base_url = "https://example.invalid",
    .reasoning = false,
    .input = &.{"text"},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 8192,
    .max_tokens = 1024,
};

pub const ToolCallSpec = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const ResponseStep = union(enum) {
    text: []const u8,
    tool_calls: []const ToolCallSpec,
    provider_error: []const u8,
    wait_for_cancel: void,
};

pub const Scenario = struct {
    steps: []const ResponseStep,
};

pub const MockProvider = struct {
    scenario: Scenario,
    call_count: usize = 0,
    last_model_id: []const u8 = "",
    last_message_count: usize = 0,

    pub fn init(scenario: Scenario) MockProvider {
        return .{ .scenario = scenario };
    }

    pub fn protocolClient(self: *MockProvider) agent.ProtocolClient {
        return .{ .stream_fn = stream, .ctx = self };
    }

    fn stream(
        ctx: ?*anyopaque,
        model: ai_types.Model,
        context: ai_types.Context,
        options: agent.ProtocolOptions,
        allocator: std.mem.Allocator,
    ) anyerror!*event_stream.AssistantMessageEventStream {
        const self: *MockProvider = @ptrCast(@alignCast(ctx.?));
        self.last_model_id = model.id;
        self.last_message_count = context.messages.len;

        const stream_ptr = try allocator.create(event_stream.AssistantMessageEventStream);
        stream_ptr.* = event_stream.AssistantMessageEventStream.init(allocator);

        const step = if (self.call_count < self.scenario.steps.len)
            self.scenario.steps[self.call_count]
        else
            ResponseStep{ .text = "done" };
        self.call_count += 1;

        switch (step) {
            .text => |text| try pushTextResponse(stream_ptr, allocator, model, text),
            .tool_calls => |calls| try pushToolCalls(stream_ptr, allocator, model, calls),
            .provider_error => |message| stream_ptr.completeWithError(message),
            .wait_for_cancel => {
                if (options.cancel_token) |token| {
                    var waits: usize = 0;
                    while (!token.isCancelled() and waits < 1_000) : (waits += 1) {
                        compat.time.sleepMs(1);
                    }
                }
                try pushDoneAndComplete(stream_ptr, allocator, model, &.{}, .aborted);
            },
        }

        return stream_ptr;
    }
};

fn emptyAssistantMessage(model: ai_types.Model, stop_reason: ai_types.StopReason) ai_types.AssistantMessage {
    return .{
        .content = &.{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = stop_reason,
        .timestamp = compat.time.nowMillis(),
        .is_owned = false,
    };
}

fn makeAssistantMessage(allocator: std.mem.Allocator, model: ai_types.Model, content: []const ai_types.AssistantContent, stop_reason: ai_types.StopReason) !ai_types.AssistantMessage {
    const blocks = try allocator.alloc(ai_types.AssistantContent, content.len);
    var initialized: usize = 0;
    errdefer ai_types.deinitAssistantContent(allocator, blocks[0..initialized]);

    for (content, 0..) |block, i| {
        blocks[i] = switch (block) {
            .text => |t| .{ .text = .{
                .text = try allocator.dupe(u8, t.text),
                .text_signature = if (t.text_signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .thinking => |t| .{ .thinking = .{
                .thinking = try allocator.dupe(u8, t.thinking),
                .thinking_signature = if (t.thinking_signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .tool_call => |tc| .{ .tool_call = .{
                .id = try allocator.dupe(u8, tc.id),
                .name = try allocator.dupe(u8, tc.name),
                .arguments_json = try allocator.dupe(u8, tc.arguments_json),
                .thought_signature = if (tc.thought_signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .image => |img| .{ .image = .{
                .data = try allocator.dupe(u8, img.data),
                .mime_type = try allocator.dupe(u8, img.mime_type),
            } },
        };
        initialized += 1;
    }

    return .{
        .content = blocks,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = stop_reason,
        .timestamp = compat.time.nowMillis(),
    };
}

fn pushDoneAndComplete(stream: *event_stream.AssistantMessageEventStream, allocator: std.mem.Allocator, model: ai_types.Model, content: []const ai_types.AssistantContent, reason: ai_types.StopReason) !void {
    const event_message = try makeAssistantMessage(allocator, model, content, reason);
    errdefer {
        var msg = event_message;
        msg.deinit(allocator);
    }
    const result_message = try makeAssistantMessage(allocator, model, content, reason);
    errdefer {
        var msg = result_message;
        msg.deinit(allocator);
    }
    if (reason == .@"error") {
        try stream.push(.{ .@"error" = .{ .reason = reason, .err = event_message } });
    } else {
        try stream.push(.{ .done = .{ .reason = reason, .message = event_message } });
    }
    stream.complete(result_message);
}

fn pushTextResponse(stream: *event_stream.AssistantMessageEventStream, allocator: std.mem.Allocator, model: ai_types.Model, text: []const u8) !void {
    const partial = emptyAssistantMessage(model, .stop);
    try stream.push(.{ .start = .{ .partial = partial } });
    try stream.push(.{ .text_delta = .{ .content_index = 0, .delta = text, .partial = partial } });

    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = text } }};
    try pushDoneAndComplete(stream, allocator, model, &content, .stop);
}

fn pushToolCalls(stream: *event_stream.AssistantMessageEventStream, allocator: std.mem.Allocator, model: ai_types.Model, calls: []const ToolCallSpec) !void {
    const partial = emptyAssistantMessage(model, .tool_use);
    try stream.push(.{ .start = .{ .partial = partial } });

    const content = try allocator.alloc(ai_types.AssistantContent, calls.len);
    defer allocator.free(content);
    for (calls, 0..) |call, i| {
        content[i] = .{ .tool_call = .{ .id = call.id, .name = call.name, .arguments_json = call.arguments_json } };
        try stream.push(.{ .toolcall_delta = .{ .content_index = i, .delta = call.arguments_json, .partial = partial } });
    }

    try pushDoneAndComplete(stream, allocator, model, content, .tool_use);
}

test "mock provider streams canned text" {
    const steps = [_]ResponseStep{.{ .text = "hello" }};
    var provider = MockProvider.init(.{ .steps = &steps });
    const client = provider.protocolClient();
    const stream_ptr = try client.stream(test_model, .{ .messages = &.{}, .is_owned = false }, .{}, std.testing.allocator);
    defer {
        stream_ptr.deinit();
        std.testing.allocator.destroy(stream_ptr);
    }

    var saw_delta = false;
    while (stream_ptr.wait()) |event| {
        if (event == .text_delta) saw_delta = std.mem.eql(u8, event.text_delta.delta, "hello");
    }
    try std.testing.expect(saw_delta);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
}
