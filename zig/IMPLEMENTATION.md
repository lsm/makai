# Zig Implementation Details

## Overview

This implementation provides the pi-ai core abstractions in Zig, focusing on:
- Type safety through tagged unions
- Thread-safe event streaming
- Zero-cost abstractions via comptime generics
- Explicit memory management

## Key Design Decisions

### 1. Tagged Unions for Variants

Zig's tagged unions provide compile-time type safety and efficient pattern matching:

```zig
pub const ContentBlock = union(enum) {
    text: TextBlock,
    tool_use: ToolUseBlock,
    thinking: ThinkingBlock,
};
```

This is similar to Rust's enums and TypeScript's discriminated unions, but with Zig's zero-cost abstraction guarantees.

### 2. Generic EventStream

The EventStream uses comptime generics to be reusable for any event and result type:

```zig
pub fn EventStream(comptime T: type, comptime R: type) type {
    return struct {
        queue: std.ArrayList(T),
        result: ?R,
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        // ...
    };
}
```

This approach:
- Generates specialized code at compile time
- Zero runtime overhead
- Type-safe event handling

### 3. Thread Safety

Thread safety is achieved through:
- `std.Thread.Mutex` for mutual exclusion
- `std.Thread.Condition` for efficient waiting
- Careful lock management with defer

```zig
pub fn push(self: *Self, event: T) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try self.queue.append(event);
    self.condition.signal();
}
```

### 4. Memory Management

Zig requires explicit allocator passing:
- No hidden allocations
- Full control over memory
- Easy to track and optimize allocations

```zig
pub fn init(allocator: std.mem.Allocator) Self {
    return Self{
        .queue = std.ArrayList(T).init(allocator),
        .allocator = allocator,
    };
}
```

### 5. Error Handling

Zig's error unions provide compile-time error handling:

```zig
pub fn push(self: *Self, event: T) !void {
    // ! means "may return an error"
}
```

Errors must be explicitly handled or propagated with `try`.

## File Organization

### types.zig (157 lines)
- Core type definitions
- 3 content block types
- Usage tracking struct
- Message types
- 13-variant MessageEvent union
- Unit tests

### event_stream.zig (143 lines)
- Generic EventStream implementation
- Thread-safe queue operations
- Blocking and non-blocking retrieval
- AssistantMessageStream type alias
- Unit tests

### provider.zig (109 lines)
- Provider struct definition
- Registry with HashMap
- Registration/lookup/removal
- Unit tests

### mock_provider.zig (138 lines)
- MockConfig struct
- Thread-based event streaming
- Configurable delays
- Mock provider factory
- Unit tests

### main.zig (119 lines)
- Demo application
- 4 test scenarios
- Example usage patterns

### bench.zig (250 lines)
- Benchmark harness
- Statistical analysis (min, max, mean, p50, p95, p99)
- 4 core benchmarks
- Pretty-printed results

### build.zig (60 lines)
- Library target
- Executable targets (demo and bench)
- Test runner
- Standard build configuration

## Performance Characteristics

### Memory
- ContentBlock: ~32 bytes (union size = largest variant)
- Usage: 32 bytes (4 × u64)
- MessageEvent: ~40 bytes (depends on largest variant)
- EventStream overhead: ArrayList + Mutex + Condition ≈ 96 bytes

### Thread Safety
- Lock-free reads: No (uses mutex)
- Blocking wait: Yes (condition variable)
- Lock contention: Minimal (fine-grained locking)

### Allocation Strategy
- EventStream queue grows dynamically
- No pre-allocation (can be optimized with capacity hints)
- Explicit cleanup with deinit()

## Testing Strategy

Each module includes unit tests using Zig's built-in test framework:

```zig
test "Usage add and total" {
    var usage1 = Usage{ .input_tokens = 100, ... };
    const usage2 = Usage{ .input_tokens = 50, ... };

    usage1.add(usage2);

    try std.testing.expectEqual(@as(u64, 150), usage1.input_tokens);
    try std.testing.expectEqual(@as(u64, 275), usage1.total());
}
```

Tests cover:
- Type operations
- Event streaming
- Thread safety
- Provider registry
- Mock streams

## Comparison with Other Languages

| Feature | Zig | Rust | Go | TypeScript |
|---------|-----|------|-----|------------|
| Type Safety | Tagged unions | Enums | Interfaces | Discriminated unions |
| Memory | Manual | RAII | GC | GC |
| Concurrency | Mutex + Condition | Mutex + Condvar | Channels | Promises |
| Generics | Comptime | Monomorphization | Runtime | Runtime |
| Error Handling | Error unions | Result types | Multiple returns | Exceptions/Result |

## Build Times

Expected build times (Release mode):
- Incremental: <1s
- Full rebuild: 2-5s
- Tests: 2-4s
- Benchmarks: 3-6s

## Future Optimizations

1. **Lock-Free Queue**: Use atomic operations for single-producer scenarios
2. **Arena Allocation**: Use arena allocator for short-lived event streams
3. **SIMD Usage**: Optimize bulk operations on Usage arrays
4. **Inline Hints**: Add @inline hints for hot paths
5. **Comptime Validation**: Add more compile-time checks for correctness

## Platform Support

Tested on:
- Linux x86_64
- macOS ARM64 (expected to work)
- Windows x86_64 (expected to work)

Cross-compilation supported via Zig's built-in cross-compiler.
