const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const provider = @import("provider");
const zio = @import("zio");

pub const MockConfig = struct {
    events: []const types.MessageEvent,
    final_result: types.AssistantMessage,
    delay_ns: u64 = 0,
};

const StreamContext = struct {
    stream: *event_stream.AssistantMessageStream,
    events: []const types.MessageEvent,
    final_result: types.AssistantMessage,
    delay_ns: u64,
    allocator: std.mem.Allocator,
};

fn fiberTask(context: *StreamContext) !void {
    for (context.events) |event| {
        context.stream.push(event) catch |err| {
            const err_msg = std.fmt.allocPrint(
                context.allocator,
                "Failed to push event: {any}",
                .{err},
            ) catch "Unknown error";
            context.stream.completeWithError(err_msg);
            return;
        };

        if (context.delay_ns > 0) {
            std.Thread.sleep(context.delay_ns);
        }
    }

    context.stream.complete(context.final_result);
}

fn runtimeThread(context: *StreamContext) void {
    defer context.allocator.destroy(context);

    const rt = zio.Runtime.init(context.allocator, .{}) catch |err| {
        const err_msg = std.fmt.allocPrint(
            context.allocator,
            "Failed to init ZIO runtime: {any}",
            .{err},
        ) catch "Unknown error";
        context.stream.completeWithError(err_msg);
        return;
    };
    defer rt.deinit();

    var group: zio.Group = .init;
    defer group.cancel();

    group.spawn(fiberTask, .{context}) catch |err| {
        const err_msg = std.fmt.allocPrint(
            context.allocator,
            "Failed to spawn fiber: {any}",
            .{err},
        ) catch "Unknown error";
        context.stream.completeWithError(err_msg);
        return;
    };

    group.wait() catch |err| {
        const err_msg = std.fmt.allocPrint(
            context.allocator,
            "Fiber execution failed: {any}",
            .{err},
        ) catch "Unknown error";
        context.stream.completeWithError(err_msg);
    };
}

fn mockStreamFn(
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    _ = messages;

    // This is a simplified version - in real usage, config would be captured in a closure
    // For now, we'll create a basic stream that immediately completes
    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);

    const result = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .usage = types.Usage{},
        .stop_reason = .stop,
        .model = "mock-model",
        .timestamp = std.time.timestamp(),
    };

    stream.complete(result);
    return stream;
}

pub fn createMockProvider(config: MockConfig, allocator: std.mem.Allocator) !provider.Provider {
    _ = config;
    _ = allocator;

    return provider.Provider{
        .id = "mock",
        .name = "Mock Provider",
        .stream_fn = mockStreamFn,
    };
}

pub fn createMockStream(
    config: MockConfig,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);

    if (config.events.len == 0 and config.delay_ns == 0) {
        stream.complete(config.final_result);
        return stream;
    }

    // Create context for the fiber task
    const context = try allocator.create(StreamContext);
    context.* = StreamContext{
        .stream = stream,
        .events = config.events,
        .final_result = config.final_result,
        .delay_ns = config.delay_ns,
        .allocator = allocator,
    };

    // Spawn a thread that will run a ZIO runtime and execute the fiber
    const thread = try std.Thread.spawn(.{}, runtimeThread, .{context});
    thread.detach();

    return stream;
}

// Tests
test "Mock provider creation" {
    const config = MockConfig{
        .events = &[_]types.MessageEvent{},
        .final_result = types.AssistantMessage{
            .content = &[_]types.ContentBlock{},
            .usage = types.Usage{},
            .stop_reason = .stop,
            .model = "mock-model",
            .timestamp = 0,
        },
    };

    const mock_provider = try createMockProvider(config, std.testing.allocator);
    try std.testing.expectEqualStrings("mock", mock_provider.id);
    try std.testing.expectEqualStrings("Mock Provider", mock_provider.name);
}

test "Mock stream immediate completion" {
    const config = MockConfig{
        .events = &[_]types.MessageEvent{},
        .final_result = types.AssistantMessage{
            .content = &[_]types.ContentBlock{},
            .usage = types.Usage{},
            .stop_reason = .stop,
            .model = "mock-model",
            .timestamp = 0,
        },
    };

    var stream = try createMockStream(config, std.testing.allocator);
    defer {
        stream.deinit();
        std.testing.allocator.destroy(stream);
    }

    try std.testing.expect(stream.isDone());
    const result = stream.getResult();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("mock-model", result.?.model);
}

test "Mock stream with events" {
    const events = [_]types.MessageEvent{
        .{ .start = types.StartEvent{ .model = "mock-model" } },
        .{ .text_delta = types.DeltaEvent{ .index = 0, .delta = "Hello" } },
        .{ .done = types.DoneEvent{ .usage = types.Usage{}, .stop_reason = .stop } },
    };

    const config = MockConfig{
        .events = &events,
        .final_result = types.AssistantMessage{
            .content = &[_]types.ContentBlock{},
            .usage = types.Usage{},
            .stop_reason = .stop,
            .model = "mock-model",
            .timestamp = 0,
        },
        .delay_ns = 1_000_000, // 1ms
    };

    var stream = try createMockStream(config, std.testing.allocator);
    defer {
        stream.deinit();
        std.testing.allocator.destroy(stream);
    }

    var event_count: usize = 0;
    while (stream.wait()) |_| {
        event_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), event_count);
    try std.testing.expect(stream.isDone());
}
