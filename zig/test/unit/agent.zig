//! Unit tests for the agent module
//!
//! Tests basic agent functionality:
//! - Type definitions
//! - Context operations
//! - Agent loop behavior with a mock ProtocolClient implementation

const std = @import("std");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const agent_types = @import("agent_types");
const agent_loop = @import("agent_loop");

const testing = std.testing;

// Re-export types for convenience
const AgentEvent = agent_types.AgentEvent;
const AgentContext = agent_types.AgentContext;
const AgentLoopConfig = agent_types.AgentLoopConfig;
const ProtocolOptions = agent_types.ProtocolOptions;

// =============================================================================
// Context Tests
// =============================================================================

test "AgentContext: init and deinit" {
    var ctx = AgentContext.init(testing.allocator);
    defer ctx.deinit();

    try testing.expect(ctx.messages.items.len == 0);
    try testing.expect(ctx.getSystemPrompt() == null);
}

test "AgentContext: append and retrieve messages" {
    const allocator = testing.allocator;

    var ctx = AgentContext.init(allocator);
    defer ctx.deinit();

    // Use owned strings - don't free them ourselves, let AgentContext.deinit do it
    const text1 = try allocator.dupe(u8, "Hello");
    const text2 = try allocator.dupe(u8, "World");

    const msg1 = ai_types.Message{ .user = .{
        .content = .{ .text = text1 },
        .timestamp = 1,
    } };
    const msg2 = ai_types.Message{ .user = .{
        .content = .{ .text = text2 },
        .timestamp = 2,
    } };

    try ctx.appendMessage(msg1);
    try ctx.appendMessage(msg2);

    const messages = ctx.messagesSlice();
    try testing.expectEqual(@as(usize, 2), messages.len);
}

test "AgentContext: with system prompt" {
    const allocator = testing.allocator;

    var ctx = AgentContext.init(allocator);
    defer ctx.deinit();

    // Don't free system_prompt ourselves - let AgentContext.deinit do it
    ctx.system_prompt = agent_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "You are a helpful assistant."));

    try testing.expectEqualStrings("You are a helpful assistant.", ctx.getSystemPrompt().?);
}

// =============================================================================
// Event Type Tests
// =============================================================================

test "AgentEvent: tags are correct" {
    const event: AgentEvent = .agent_start;
    try testing.expect(std.meta.activeTag(event) == .agent_start);
}

// =============================================================================
// Protocol Options Tests
// =============================================================================

test "ProtocolOptions: default values" {
    const opts = ProtocolOptions{};
    try testing.expect(opts.api_key == null);
    try testing.expect(opts.session_id == null);
    try testing.expect(opts.cancel_token == null);
    try testing.expect(opts.temperature == null);
    try testing.expect(opts.max_tokens == null);
}

// =============================================================================
// Agent loop tests with mock ProtocolClient
// =============================================================================

const MockMode = enum { done, err };

const MockProtocolState = struct {
    mode: MockMode,
    text: []const u8 = "ok",
    stop_reason: ai_types.StopReason = .stop,
    call_count: usize = 0,
    last_options: ?ProtocolOptions = null,
};

fn createModel() ai_types.Model {
    return .{
        .id = "mock-model",
        .name = "Mock",
        .api = "mock-api",
        .provider = "mock-provider",
        .base_url = "",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 256,
    };
}

fn makeOwnedAssistantMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    stop_reason: ai_types.StopReason,
) !ai_types.AssistantMessage {
    const content = try allocator.alloc(ai_types.AssistantContent, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };

    return .{
        .content = content,
        .api = "mock-api",
        .provider = "mock-provider",
        .model = "mock-model",
        .usage = .{},
        .stop_reason = stop_reason,
        .timestamp = std.time.milliTimestamp(),
        .is_owned = false,
    };
}

fn mockProtocolStream(
    ctx: ?*anyopaque,
    model: ai_types.Model,
    context: ai_types.Context,
    options: agent_types.ProtocolOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;

    const state: *MockProtocolState = @ptrCast(@alignCast(ctx));
    state.call_count += 1;
    state.last_options = options;

    const stream = try allocator.create(event_stream.AssistantMessageEventStream);
    stream.* = event_stream.AssistantMessageEventStream.init(allocator);

    const msg = if (state.mode == .done)
        try makeOwnedAssistantMessage(allocator, state.text, state.stop_reason)
    else
        ai_types.AssistantMessage{
            .content = &[_]ai_types.AssistantContent{
                .{ .text = .{ .text = "" } },
            },
            .api = "mock-api",
            .provider = "mock-provider",
            .model = "mock-model",
            .usage = .{},
            .stop_reason = .@"error",
            .error_message = ai_types.OwnedSlice(u8).initBorrowed("mock provider error"),
            .timestamp = std.time.milliTimestamp(),
            .is_owned = false,
        };

    if (state.mode == .done) {
        try stream.push(.{ .done = .{
            .reason = .stop,
            .message = msg,
        } });
    } else {
        try stream.push(.{ .@"error" = .{
            .reason = .@"error",
            .err = msg,
        } });
    }

    // Mark stream completed without attaching result ownership to avoid
    // double-ownership in this test mock.
    stream.completeWithError("");
    stream.markThreadDone();
    return stream;
}

fn createMockProtocol(state: *MockProtocolState) agent_types.ProtocolClient {
    return .{
        .stream_fn = mockProtocolStream,
        .ctx = state,
    };
}

test "agentLoop: basic single turn with text response" {
    const allocator = testing.allocator;

    var state = MockProtocolState{ .mode = .done, .text = "hello from mock" };

    var ctx = AgentContext.init(allocator);
    defer ctx.deinit();

    const prompt_text = try allocator.dupe(u8, "Hello");
    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = prompt_text },
        .timestamp = std.time.milliTimestamp(),
    } };

    const config = AgentLoopConfig{
        .model = createModel(),
        .protocol = createMockProtocol(&state),
    };

    const stream = try agent_loop.agentLoop(allocator, &.{prompt}, &ctx, config);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    while (stream.wait()) |_| {}

    const result = stream.getResult().?;
    try testing.expectEqual(@as(usize, 2), result.messages.slice().len);
    try testing.expect(result.final_message.stop_reason == .stop);
    try testing.expectEqual(@as(usize, 1), state.call_count);
}

test "agentLoop: collects events in correct order" {
    const allocator = testing.allocator;

    var state = MockProtocolState{ .mode = .done, .text = "event order" };

    var ctx = AgentContext.init(allocator);
    defer ctx.deinit();

    const prompt_text = try allocator.dupe(u8, "Hi");
    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = prompt_text },
        .timestamp = std.time.milliTimestamp(),
    } };

    const config = AgentLoopConfig{
        .model = createModel(),
        .protocol = createMockProtocol(&state),
    };

    const stream = try agent_loop.agentLoop(allocator, &.{prompt}, &ctx, config);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    var saw_agent_start = false;
    var saw_turn_start = false;
    var saw_agent_end = false;

    while (stream.wait()) |event| {
        switch (event) {
            .agent_start => saw_agent_start = true,
            .turn_start => saw_turn_start = true,
            .agent_end => saw_agent_end = true,
            else => {},
        }
    }

    try testing.expect(saw_agent_start);
    try testing.expect(saw_turn_start);
    try testing.expect(saw_agent_end);
}

test "agentLoop: emits lifecycle events in strict sequence" {
    const allocator = testing.allocator;

    var state = MockProtocolState{ .mode = .done, .text = "ordered" };
    var ctx = AgentContext.init(allocator);
    defer ctx.deinit();

    const prompt_text = try allocator.dupe(u8, "Hi");
    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = prompt_text },
        .timestamp = std.time.milliTimestamp(),
    } };

    const config = AgentLoopConfig{
        .model = createModel(),
        .protocol = createMockProtocol(&state),
    };

    const stream = try agent_loop.agentLoop(allocator, &.{prompt}, &ctx, config);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    var step: u8 = 0;
    while (stream.wait()) |event| {
        switch (event) {
            .message_start => {
                if (step == 0) step = 1;
            },
            .message_end => {
                if (step == 1) step = 2;
            },
            .agent_start => {
                if (step == 2) step = 3;
            },
            .turn_start => {
                if (step == 3) step = 4;
            },
            .turn_end => {
                if (step == 4) step = 5;
            },
            .agent_end => {
                if (step == 5) step = 6;
            },
            else => {},
        }
    }

    try testing.expectEqual(@as(u8, 6), step);
}

test "agentLoop: handles provider error" {
    const allocator = testing.allocator;

    var state = MockProtocolState{ .mode = .err, .text = "" };

    var ctx = AgentContext.init(allocator);
    defer ctx.deinit();

    const prompt_text = try allocator.dupe(u8, "Fail please");
    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = prompt_text },
        .timestamp = std.time.milliTimestamp(),
    } };

    const config = AgentLoopConfig{
        .model = createModel(),
        .protocol = createMockProtocol(&state),
    };

    const stream = try agent_loop.agentLoop(allocator, &.{prompt}, &ctx, config);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    while (stream.wait()) |_| {}

    const result = stream.getResult().?;
    try testing.expect(result.final_message.stop_reason == .@"error");
    try testing.expect(result.final_message.getErrorMessage() != null);
}

test "ProtocolOptions: passed through to protocol client" {
    const allocator = testing.allocator;

    var state = MockProtocolState{ .mode = .done, .text = "options" };

    var ctx = AgentContext.init(allocator);
    defer ctx.deinit();

    const prompt_text = try allocator.dupe(u8, "options test");
    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = prompt_text },
        .timestamp = std.time.milliTimestamp(),
    } };

    const config = AgentLoopConfig{
        .model = createModel(),
        .protocol = createMockProtocol(&state),
        .temperature = 0.25,
        .max_tokens = 42,
        .api_key = "key-123",
        .session_id = "session-abc",
    };

    const stream = try agent_loop.agentLoop(allocator, &.{prompt}, &ctx, config);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    while (stream.wait()) |_| {}

    const seen = state.last_options.?;
    try testing.expectEqual(@as(?f32, 0.25), seen.temperature);
    try testing.expectEqual(@as(?u32, 42), seen.max_tokens);
    try testing.expectEqualStrings("key-123", seen.api_key.?);
    try testing.expectEqualStrings("session-abc", seen.session_id.?);
}

test "agentLoop: cancellation token stops before protocol stream call" {
    const allocator = testing.allocator;

    var state = MockProtocolState{ .mode = .done, .text = "unused" };
    var ctx = AgentContext.init(allocator);
    defer ctx.deinit();

    const prompt_text = try allocator.dupe(u8, "cancel");
    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = prompt_text },
        .timestamp = std.time.milliTimestamp(),
    } };

    var cancelled = std.atomic.Value(bool).init(true);
    const cancel_token = ai_types.CancelToken{ .cancelled = &cancelled };

    const config = AgentLoopConfig{
        .model = createModel(),
        .protocol = createMockProtocol(&state),
        .cancel_token = cancel_token,
    };

    const stream = try agent_loop.agentLoop(allocator, &.{prompt}, &ctx, config);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }
    while (stream.wait()) |_| {}

    const result = stream.getResult().?;
    try testing.expectEqual(@as(usize, 0), result.iterations);
    try testing.expectEqual(@as(usize, 0), state.call_count);
}

test "agentLoop: max_iterations caps repeated tool_use loop" {
    const allocator = testing.allocator;

    var state = MockProtocolState{
        .mode = .done,
        .text = "need tools",
        .stop_reason = .tool_use,
    };
    var ctx = AgentContext.init(allocator);
    defer ctx.deinit();

    const prompt_text = try allocator.dupe(u8, "loop");
    const prompt = ai_types.Message{ .user = .{
        .content = .{ .text = prompt_text },
        .timestamp = std.time.milliTimestamp(),
    } };

    const config = AgentLoopConfig{
        .model = createModel(),
        .protocol = createMockProtocol(&state),
        .max_iterations = 2,
    };

    const stream = try agent_loop.agentLoop(allocator, &.{prompt}, &ctx, config);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }
    while (stream.wait()) |_| {}

    const result = stream.getResult().?;
    try testing.expectEqual(@as(usize, 2), result.iterations);
    try testing.expectEqual(@as(usize, 2), state.call_count);
}
