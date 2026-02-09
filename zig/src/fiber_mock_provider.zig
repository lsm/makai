const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const provider = @import("provider");
const zio = @import("zio");

pub const FiberMockConfig = struct {
    events: []const types.MessageEvent,
    final_result: types.AssistantMessage,
    delay_ns: u64 = 0,
};

const FiberContext = struct {
    stream: *event_stream.AssistantMessageStream,
    events: []const types.MessageEvent,
    final_result: types.AssistantMessage,
    delay_ns: u64,
    allocator: std.mem.Allocator,
};

fn fiberTask(context: *FiberContext) void {
    for (context.events) |event| {
        context.stream.push(event) catch |err| {
            const err_msg = std.fmt.allocPrint(
                context.allocator,
                "Failed to push event: {any}",
                .{err},
            ) catch "Unknown error";
            const stream = context.stream;
            context.allocator.destroy(context);
            stream.completeWithError(err_msg);
            return;
        };

        if (context.delay_ns > 0) {
            std.Thread.sleep(context.delay_ns);
        }
    }

    // Free context before signaling completion, since the consumer
    // may exit immediately after complete() and trigger leak detection.
    const stream = context.stream;
    const final_result = context.final_result;
    context.allocator.destroy(context);
    stream.complete(final_result);
}

fn mockStreamFn(
    ctx: *anyopaque,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    _ = ctx;
    _ = messages;

    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);

    const result = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .usage = types.Usage{},
        .stop_reason = .stop,
        .model = "fiber-mock-model",
        .timestamp = std.time.timestamp(),
    };

    stream.complete(result);
    return stream;
}

fn fiberMockDeinitFn(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const config: *FiberMockConfig = @ptrCast(@alignCast(ctx));
    allocator.destroy(config);
}

pub fn createFiberMockProvider(config: FiberMockConfig, allocator: std.mem.Allocator) !provider.Provider {
    const config_ptr = try allocator.create(FiberMockConfig);
    config_ptr.* = config;

    return provider.Provider{
        .id = "fiber-mock",
        .name = "Fiber Mock Provider (ZIO-based)",
        .context = config_ptr,
        .stream_fn = mockStreamFn,
        .deinit_fn = fiberMockDeinitFn,
    };
}

pub fn createFiberMockStream(
    config: FiberMockConfig,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);

    if (config.events.len == 0 and config.delay_ns == 0) {
        stream.complete(config.final_result);
        return stream;
    }

    // Use a thread for now - for a full ZIO implementation, you'd run this within
    // a ZIO runtime event loop. This demonstrates the API without the async complexity.
    const context = try allocator.create(FiberContext);
    context.* = FiberContext{
        .stream = stream,
        .events = config.events,
        .final_result = config.final_result,
        .delay_ns = config.delay_ns,
        .allocator = allocator,
    };

    const thread = try std.Thread.spawn(.{}, fiberTask, .{context});
    thread.detach();

    return stream;
}

// Tests
test "Fiber mock provider creation" {
    const config = FiberMockConfig{
        .events = &[_]types.MessageEvent{},
        .final_result = types.AssistantMessage{
            .content = &[_]types.ContentBlock{},
            .usage = types.Usage{},
            .stop_reason = .stop,
            .model = "fiber-mock-model",
            .timestamp = 0,
        },
    };

    var mock = try createFiberMockProvider(config, std.testing.allocator);
    defer mock.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("fiber-mock", mock.id);
}

test "Fiber mock stream immediate completion" {
    const config = FiberMockConfig{
        .events = &[_]types.MessageEvent{},
        .final_result = types.AssistantMessage{
            .content = &[_]types.ContentBlock{},
            .usage = types.Usage{},
            .stop_reason = .stop,
            .model = "fiber-mock-model",
            .timestamp = 0,
        },
    };

    var stream = try createFiberMockStream(config, std.testing.allocator);
    defer {
        stream.deinit();
        std.testing.allocator.destroy(stream);
    }

    try std.testing.expect(stream.isDone());
    const result = stream.getResult();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("fiber-mock-model", result.?.model);
}

test "Fiber mock stream with events" {
    const events = [_]types.MessageEvent{
        .{ .start = types.StartEvent{ .model = "fiber-mock-model" } },
        .{ .text_delta = types.DeltaEvent{ .index = 0, .delta = "Hello" } },
        .{ .done = types.DoneEvent{ .usage = types.Usage{}, .stop_reason = .stop } },
    };

    const config = FiberMockConfig{
        .events = &events,
        .final_result = types.AssistantMessage{
            .content = &[_]types.ContentBlock{},
            .usage = types.Usage{},
            .stop_reason = .stop,
            .model = "fiber-mock-model",
            .timestamp = 0,
        },
        .delay_ns = 1_000_000, // 1ms
    };

    var stream = try createFiberMockStream(config, std.testing.allocator);
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
