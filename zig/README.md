# Pi-AI Core Abstractions - Zig Implementation

This is a Zig implementation of the pi-ai core abstractions for benchmarking purposes.

## Requirements

- Zig 0.13.0 or later

## Installation

Download and install Zig from: https://ziglang.org/download/

## Building

```bash
# Build all targets
zig build

# Run the demo
zig build run

# Run benchmarks
zig build bench

# Run tests
zig build test
```

## Project Structure

```
zig/
├── build.zig              # Build configuration
├── src/
│   ├── types.zig          # Core type definitions (ContentBlock, Usage, Message, etc.)
│   ├── event_stream.zig   # Generic EventStream with mutex + queue
│   ├── provider.zig       # Provider registry
│   ├── mock_provider.zig  # Mock provider for testing/benchmarking
│   ├── main.zig           # Demo/smoke test
│   └── bench.zig          # Benchmark harness
└── README.md
```

## Core Types

### ContentBlock
Tagged union with variants:
- `text`: Text content
- `tool_use`: Tool call with id, name, and JSON input
- `thinking`: Extended thinking content

### Usage
Token usage tracking with methods:
- `add()`: Accumulate usage from another Usage struct
- `total()`: Get total token count

### MessageEvent
13-variant tagged union for streaming:
- `start`, `text_start`, `text_delta`, `text_end`
- `thinking_start`, `thinking_delta`, `thinking_end`
- `toolcall_start`, `toolcall_delta`, `toolcall_end`
- `done`, `error`, `ping`

### EventStream(T, R)
Generic thread-safe event stream using:
- `std.ArrayList` for queue
- `std.Thread.Mutex` for thread safety
- `std.Thread.Condition` for blocking waits

Methods:
- `push(event)`: Thread-safe event push
- `poll()`: Non-blocking event retrieval
- `wait()`: Blocking event retrieval with condition variable
- `complete(result)`: Mark stream complete with result
- `completeWithError(msg)`: Mark stream failed
- `isDone()`: Check completion status
- `getResult()`: Get final result

## Architecture

The implementation follows the same architectural patterns as the Rust, Go, and TypeScript versions:

1. **Type Safety**: Uses Zig's tagged unions for variant types
2. **Thread Safety**: Mutex-protected event queues with condition variables
3. **Zero-cost Abstractions**: Comptime generics for EventStream
4. **Memory Safety**: Explicit allocator management
5. **Testability**: Mock providers with configurable event streams

## Example Usage

```zig
const std = @import("std");
const types = @import("types.zig");
const event_stream = @import("event_stream.zig");
const mock_provider = @import("mock_provider.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create mock configuration
    const events = [_]types.MessageEvent{
        .{ .start = types.StartEvent{ .model = "mock" } },
        .{ .text_delta = types.DeltaEvent{ .index = 0, .delta = "Hello" } },
        .{ .done = types.DoneEvent{ .usage = types.Usage{}, .stop_reason = .stop } },
    };

    const config = mock_provider.MockConfig{
        .events = &events,
        .final_result = types.AssistantMessage{
            .content = &[_]types.ContentBlock{},
            .usage = types.Usage{},
            .stop_reason = .stop,
            .model = "mock",
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
        // Process event
        std.debug.print("Event: {s}\n", .{@tagName(std.meta.activeTag(event))});
    }

    if (stream.getResult()) |result| {
        std.debug.print("Final result: {s}\n", .{result.model});
    }
}
```

## Benchmarks

The benchmark suite includes:

1. **Usage Operations**: Testing add() performance
2. **EventStream Push/Poll**: Testing queue operations (100 events)
3. **ContentBlock Switching**: Testing tagged union performance
4. **Mock Stream**: End-to-end stream consumption with events

Run with: `zig build bench`

## Testing

Unit tests are included in each module using Zig's built-in test framework.

Run with: `zig build test`

## License

MIT
