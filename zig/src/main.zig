const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const provider = @import("provider");
const mock_provider = @import("mock_provider");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Pi-AI Core Abstractions - Zig Implementation\n", .{});
    std.debug.print("===========================================\n\n", .{});

    // Test 1: Basic types
    std.debug.print("Test 1: Basic Types\n", .{});
    const usage = types.Usage{
        .input_tokens = 100,
        .output_tokens = 50,
        .cache_read_tokens = 20,
        .cache_write_tokens = 10,
    };
    std.debug.print("  Usage total: {d} tokens\n", .{usage.total()});

    const text_block = types.ContentBlock{ .text = types.TextBlock{ .text = "Hello, World!" } };
    std.debug.print("  Content block type: {s}\n", .{@tagName(std.meta.activeTag(text_block))});

    // Test 2: Event Stream
    std.debug.print("\nTest 2: Event Stream\n", .{});
    var stream = event_stream.AssistantMessageStream.init(allocator);
    defer stream.deinit();

    const start_event = types.MessageEvent{ .start = types.StartEvent{ .model = "claude-3-opus" } };
    try stream.push(start_event);
    std.debug.print("  Pushed start event\n", .{});

    const text_delta = types.MessageEvent{ .text_delta = types.DeltaEvent{ .index = 0, .delta = "Hello" } };
    try stream.push(text_delta);
    std.debug.print("  Pushed text delta event\n", .{});

    const result = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .usage = usage,
        .stop_reason = .stop,
        .model = "claude-3-opus",
        .timestamp = std.time.timestamp(),
    };
    stream.complete(result);
    std.debug.print("  Stream completed\n", .{});

    var event_count: usize = 0;
    while (stream.poll()) |_| {
        event_count += 1;
    }
    std.debug.print("  Received {d} events\n", .{event_count});

    // Test 3: Provider Registry
    std.debug.print("\nTest 3: Provider Registry\n", .{});
    var registry = provider.Registry.init(allocator);
    defer registry.deinit();

    const mock_config = mock_provider.MockConfig{
        .events = &[_]types.MessageEvent{},
        .final_result = types.AssistantMessage{
            .content = &[_]types.ContentBlock{},
            .usage = types.Usage{},
            .stop_reason = .stop,
            .model = "mock-model",
            .timestamp = std.time.timestamp(),
        },
    };

    const mock = try mock_provider.createMockProvider(mock_config, allocator);
    try registry.register(mock);
    std.debug.print("  Registered mock provider: {s}\n", .{mock.name});

    const retrieved = registry.get("mock");
    if (retrieved) |p| {
        std.debug.print("  Retrieved provider: {s}\n", .{p.name});
    }

    // Test 4: Mock Stream
    std.debug.print("\nTest 4: Mock Stream with Events\n", .{});
    const events = [_]types.MessageEvent{
        .{ .start = types.StartEvent{ .model = "mock-model" } },
        .{ .text_start = types.ContentIndexEvent{ .index = 0 } },
        .{ .text_delta = types.DeltaEvent{ .index = 0, .delta = "Hello" } },
        .{ .text_delta = types.DeltaEvent{ .index = 0, .delta = " World" } },
        .{ .text_end = types.ContentEndEvent{ .index = 0 } },
        .{ .done = types.DoneEvent{
            .usage = types.Usage{ .output_tokens = 10 },
            .stop_reason = .stop,
        } },
    };

    const stream_config = mock_provider.MockConfig{
        .events = &events,
        .final_result = types.AssistantMessage{
            .content = &[_]types.ContentBlock{
                .{ .text = types.TextBlock{ .text = "Hello World" } },
            },
            .usage = types.Usage{ .output_tokens = 10 },
            .stop_reason = .stop,
            .model = "mock-model",
            .timestamp = std.time.timestamp(),
        },
        .delay_ns = 10_000_000, // 10ms between events
    };

    var mock_stream = try mock_provider.createMockStream(stream_config, allocator);
    defer {
        mock_stream.deinit();
        allocator.destroy(mock_stream);
    }

    std.debug.print("  Consuming mock stream events:\n", .{});
    var mock_event_count: usize = 0;
    while (mock_stream.wait()) |event| {
        mock_event_count += 1;
        std.debug.print("    Event {d}: {s}\n", .{ mock_event_count, @tagName(std.meta.activeTag(event)) });
    }

    if (mock_stream.getResult()) |final_result| {
        std.debug.print("  Final result: {d} output tokens, stop reason: {s}\n", .{
            final_result.usage.output_tokens,
            @tagName(final_result.stop_reason),
        });
    }

    std.debug.print("\nAll tests completed successfully!\n", .{});
}
