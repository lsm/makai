# API Quick Reference

## Core Types (types.zig)

### ContentBlock
```zig
pub const ContentBlock = union(enum) {
    text: TextBlock,
    tool_use: ToolUseBlock,
    thinking: ThinkingBlock,
};

// Usage
const block = ContentBlock{ .text = TextBlock{ .text = "hello" } };
switch (block) {
    .text => |t| std.debug.print("{s}", .{t.text}),
    .tool_use => |t| std.debug.print("{s}", .{t.name}),
    .thinking => |t| std.debug.print("{s}", .{t.thinking}),
}
```

### Usage
```zig
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,

    pub fn add(self: *Usage, other: Usage) void;
    pub fn total(self: Usage) u64;
};

// Usage
var usage = Usage{ .input_tokens = 100, .output_tokens = 50 };
const total = usage.total(); // 150
usage.add(another_usage);
```

### Message
```zig
pub const Message = struct {
    role: Role,
    content: []const ContentBlock,
    timestamp: i64,
};

pub const Role = enum { user, assistant, tool_result };
```

### AssistantMessage
```zig
pub const AssistantMessage = struct {
    content: []const ContentBlock,
    usage: Usage,
    stop_reason: StopReason,
    model: []const u8,
    timestamp: i64,
};

pub const StopReason = enum { stop, length, tool_use, @"error", aborted };
```

### MessageEvent
```zig
pub const MessageEvent = union(enum) {
    start: StartEvent,
    text_start: ContentIndexEvent,
    text_delta: DeltaEvent,
    text_end: ContentEndEvent,
    thinking_start: ContentIndexEvent,
    thinking_delta: DeltaEvent,
    thinking_end: ContentEndEvent,
    toolcall_start: ToolCallStartEvent,
    toolcall_delta: DeltaEvent,
    toolcall_end: ToolCallEndEvent,
    done: DoneEvent,
    @"error": ErrorEvent,
    ping: void,
};

// Event structs
pub const StartEvent = struct { model: []const u8 };
pub const ContentIndexEvent = struct { index: usize };
pub const DeltaEvent = struct { index: usize, delta: []const u8 };
pub const ContentEndEvent = struct { index: usize };
pub const ToolCallStartEvent = struct { index: usize, id: []const u8, name: []const u8 };
pub const ToolCallEndEvent = struct { index: usize, input_json: []const u8 };
pub const DoneEvent = struct { usage: Usage, stop_reason: StopReason };
pub const ErrorEvent = struct { message: []const u8 };
```

## EventStream (event_stream.zig)

### Generic EventStream
```zig
pub fn EventStream(comptime T: type, comptime R: type) type;

// Type alias for assistant messages
pub const AssistantMessageStream = EventStream(MessageEvent, AssistantMessage);
```

### Methods
```zig
// Initialize
var stream = AssistantMessageStream.init(allocator);
defer stream.deinit();

// Push events (thread-safe)
try stream.push(event);

// Poll (non-blocking)
if (stream.poll()) |event| {
    // Process event
}

// Wait (blocking with condition variable)
while (stream.wait()) |event| {
    // Process event
}

// Complete with result
stream.complete(result);

// Complete with error
stream.completeWithError("error message");

// Check status
if (stream.isDone()) {
    if (stream.getResult()) |result| {
        // Process final result
    }
    if (stream.getError()) |error_msg| {
        // Handle error
    }
}
```

## Provider (provider.zig)

### StreamFn Type
```zig
pub const StreamFn = *const fn (
    messages: []const Message,
    allocator: std.mem.Allocator,
) anyerror!*AssistantMessageStream;
```

### Provider
```zig
pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    stream_fn: StreamFn,
};
```

### Registry
```zig
// Initialize
var registry = Registry.init(allocator);
defer registry.deinit();

// Register provider
const provider = Provider{
    .id = "my-provider",
    .name = "My Provider",
    .stream_fn = myStreamFn,
};
try registry.register(provider);

// Get provider
if (registry.get("my-provider")) |provider| {
    const stream = try provider.stream_fn(messages, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }
}

// Unregister
_ = registry.unregister("my-provider");
```

## Mock Provider (mock_provider.zig)

### MockConfig
```zig
pub const MockConfig = struct {
    events: []const MessageEvent,
    final_result: AssistantMessage,
    delay_ns: u64 = 0,  // Optional delay between events
};
```

### Creating Mock Provider
```zig
const config = MockConfig{
    .events = &events,
    .final_result = final_result,
    .delay_ns = 10_000_000, // 10ms
};

const provider = try createMockProvider(config, allocator);
```

### Creating Mock Stream
```zig
const events = [_]MessageEvent{
    .{ .start = StartEvent{ .model = "mock" } },
    .{ .text_delta = DeltaEvent{ .index = 0, .delta = "Hello" } },
    .{ .done = DoneEvent{ .usage = Usage{}, .stop_reason = .stop } },
};

const config = MockConfig{
    .events = &events,
    .final_result = AssistantMessage{ /* ... */ },
};

var stream = try createMockStream(config, allocator);
defer {
    stream.deinit();
    allocator.destroy(stream);
}

while (stream.wait()) |event| {
    // Process event
}
```

## Benchmarking (bench.zig)

### BenchResult
```zig
pub const BenchResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,

    pub fn print(self: BenchResult) void;
};
```

### Running Benchmarks
```zig
// Simple function benchmark
fn myBenchFunc() void {
    // Code to benchmark
}

const result = try runBenchmark("My Benchmark", 10000, myBenchFunc);
result.print();

// Benchmark with allocator
fn myAllocBenchFunc(allocator: std.mem.Allocator) !void {
    // Code to benchmark
}

const result = try runBenchmarkAlloc("My Alloc Benchmark", 1000, allocator, myAllocBenchFunc);
result.print();
```

## Complete Example

```zig
const std = @import("std");
const types = @import("types.zig");
const event_stream = @import("event_stream.zig");
const provider = @import("provider.zig");
const mock_provider = @import("mock_provider.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create message
    const message = types.Message{
        .role = .user,
        .content = &[_]types.ContentBlock{
            .{ .text = types.TextBlock{ .text = "Hello!" } },
        },
        .timestamp = std.time.timestamp(),
    };

    // Setup mock events
    const events = [_]types.MessageEvent{
        .{ .start = types.StartEvent{ .model = "test" } },
        .{ .text_delta = types.DeltaEvent{ .index = 0, .delta = "Hi" } },
        .{ .done = types.DoneEvent{
            .usage = types.Usage{ .output_tokens = 10 },
            .stop_reason = .stop,
        } },
    };

    const config = mock_provider.MockConfig{
        .events = &events,
        .final_result = types.AssistantMessage{
            .content = &[_]types.ContentBlock{
                .{ .text = types.TextBlock{ .text = "Hi" } },
            },
            .usage = types.Usage{ .output_tokens = 10 },
            .stop_reason = .stop,
            .model = "test",
            .timestamp = std.time.timestamp(),
        },
    };

    // Create and consume stream
    var stream = try mock_provider.createMockStream(config, allocator);
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    while (stream.wait()) |event| {
        switch (event) {
            .start => |e| std.debug.print("Model: {s}\n", .{e.model}),
            .text_delta => |e| std.debug.print("Delta: {s}\n", .{e.delta}),
            .done => |e| std.debug.print("Tokens: {d}\n", .{e.usage.output_tokens}),
            else => {},
        }
    }

    if (stream.getResult()) |result| {
        std.debug.print("Done! Model: {s}\n", .{result.model});
    }
}
```
