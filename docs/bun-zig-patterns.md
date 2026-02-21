# Bun Zig Patterns Research

> Exploration of the Bun codebase (https://github.com/oven-sh/bun) to learn Zig best practices for the Makai project.
>
> **Date**: 2026-02-21
> **Source**: tmp/bun (cloned repository, 1165 Zig files)

---

## Table of Contents

1. [Memory Allocator Patterns](#1-memory-allocator-patterns)
2. [Error Handling Patterns](#2-error-handling-patterns)
3. [String Ownership Conventions](#3-string-ownership-conventions)
4. [Async/Event Loop Patterns](#4-asyncevent-loop-patterns)
5. [Struct Initialization Patterns](#5-struct-initialization-patterns)
6. [Testing Patterns](#6-testing-patterns)
7. [HTTP/Networking Patterns](#7-httpnetworking-patterns)
8. [Generic Programming Patterns](#8-generic-programming-patterns)
9. [Recommendations for Makai](#9-recommendations-for-makai)
10. [External vs Built-In Dependencies](#10-external-vs-built-in-dependencies)

---

## 10. External vs Built-In Dependencies

Bun uses a **hybrid approach** - they integrate external C/C++ libraries (via Zig bindings) but build most high-level patterns themselves.

### 10.1 External Libraries (C/C++ with Zig Bindings)

These are battle-tested C/C++ libraries that Bun wraps with Zig bindings:

| Library | Purpose | How Used |
|---------|---------|----------|
| **mimalloc** | High-performance memory allocator | Direct C library, wrapped in Zig |
| **BoringSSL** | TLS/SSL (Google's fork of OpenSSL) | Translated to Zig via `src/deps/boringssl.translated.zig` |
| **libuv** | Cross-platform async I/O (Windows) | Bindings in `src/deps/libuv.zig` |
| **uSockets/uWS** | High-performance HTTP/WebSocket server | Zig wrappers in `src/deps/uws/` |
| **c-ares** | Async DNS resolution | Bindings in `src/deps/c_ares.zig` |
| **zlib/zstd** | Compression | Multiple platform-specific bindings |
| **brotli** | Compression | `src/deps/brotli_c.zig` |
| **lol-html** | HTML parsing | `src/deps/lol-html.zig` |
| **picohttp** | HTTP parsing | `src/deps/picohttp.zig` |
| **libdeflate** | Fast deflate | `src/deps/libdeflate.zig` |

### 10.2 Patterns Built by Bun Team (Pure Zig)

These are **Bun's own implementations**, not external libraries:

| Pattern | File | Description |
|---------|------|-------------|
| **MimallocArena** | `src/allocators/MimallocArena.zig` | Thread-local heap wrapper (their design) |
| **AllocationScope** | `src/allocators/allocation_scope.zig` | Leak detection wrapper |
| **MaybeOwned** | `src/allocators/maybe_owned.zig` | Owned/borrowed wrapper |
| **CowSlice** | `src/ptr/CowSlice.zig` | Copy-on-write slice |
| **RefCount** | `src/ptr/ref_count.zig` | Reference counting mixin |
| **HiveArray** | `src/collections/hive_array.zig` | Fixed-size allocation pool |
| **ThreadPool** | `src/threading/ThreadPool.zig` | Derived from kprotty/zap (MIT license) |
| **Event Loop** | `src/async/posix_event_loop.zig` | Their own epoll/kqueue wrapper |
| **StringBuilder** | `src/string/StringBuilder.zig` | Two-phase string builder |
| **SmolStr** | `src/string/SmolStr.zig` | Small-string optimization |
| **TaggedPointerUnion** | `src/ptr/tagged_pointer.zig` | Type-safe tagged pointer |

### 10.3 ThreadPool Attribution Example

Bun properly attributes external code:

```zig
// From src/threading/ThreadPool.zig
// Thank you @kprotty.
//
// This file contains code derived from the following source:
//   https://github.com/kprotty/zap/blob/blog/src/thread_pool.zig
//
// That code is covered by the MIT License
// Copyright (c) 2021 kprotty
```

### 10.4 Key Takeaway

**Bun's approach:**
1. Use **battle-tested C/C++ libraries** for low-level performance-critical stuff (mimalloc, TLS, HTTP parsing)
2. Write **their own high-level patterns** in Zig for ownership, async, and ergonomics
3. **Translate** some C libraries to Zig (BoringSSL) for easier integration

**For Makai**, we don't need the C/C++ dependencies, but we can adopt their **pure Zig patterns**:
- `MaybeOwned` for ownership tracking
- `CowSlice` for copy-on-write
- `StringBuilder` for efficient string building
- The `Owned`/`Borrowed` type pattern

---

## 1. Memory Allocator Patterns

### 1.1 Core Allocator Types

| Allocator | Purpose | File |
|-----------|---------|------|
| `bun.default_allocator` | High-performance mimalloc-backed allocator | `src/allocators.zig` |
| `MimallocArena` | Thread-local heap with owned/borrowed semantics | `src/allocators/MimallocArena.zig` |
| `AllocationScope` | Leak detection wrapper with tracking | `src/allocators/allocation_scope.zig` |
| `MaybeOwned` | Wrapper for either owned or borrowed memory | `src/allocators/maybe_owned.zig` |
| `NullableAllocator` | Optional allocator pattern | `src/allocators/NullableAllocator.zig` |
| `BufferFallbackAllocator` | Stack buffer with heap fallback | `src/allocators/BufferFallbackAllocator.zig` |

### 1.2 Generic Allocator Interface

```zig
// A generic allocator must implement:
const GenericAllocator = struct {
    // Required.
    pub fn allocator(self: Self) std.mem.Allocator;

    // Optional, to allow default-initialization.
    pub fn init() Self;

    // Optional, if this allocator owns auxiliary resources.
    pub fn deinit(self: *Self) void;

    // Optional. Defining a borrowed type makes ownership clear.
    pub const Borrowed: type;
    pub fn borrow(self: Self) Borrowed;
};
```

### 1.3 Owned vs Borrowed Semantics

```zig
// From src/allocators/MimallocArena.zig
/// Borrowed version of `MimallocArena`, returned by `MimallocArena.borrow`.
/// Using this type makes it clear who actually owns the `MimallocArena`, and prevents
/// `deinit` from being called twice.
pub const Borrowed = struct {
    #heap: BorrowedHeap,
    // ...
};
```

### 1.4 dupe/clone Conventions

| Function Name | Meaning |
|--------------|---------|
| `dupe` / `dupeRef` | Shallow copy, increment ref count, or allocate copy of pointer |
| `clone` | Deep copy with new memory allocation, typically takes `allocator` parameter |
| `cloneLatin1` / `cloneUTF8` / `cloneUTF16` | Encoding-specific clones for strings |

```zig
// From src/bun.zig
pub fn clone(item: anytype, allocator: std.mem.Allocator) !@TypeOf(item) {
    const T = @TypeOf(item);

    if (std.meta.hasFn(T, "clone")) {
        return try item.clone(allocator);
    }

    const Child = std.meta.Child(T);
    if (comptime trait.isContainer(Child)) {
        if (std.meta.hasFn(Child, "clone")) {
            const slice = try allocator.alloc(Child, item.len);
            for (slice, 0..) |*val, i| {
                val.* = try item[i].clone(allocator);
            }
            return slice;
        }
        @compileError("Expected clone() to exist for slice child: " ++ @typeName(Child));
    }

    return try allocator.dupe(Child, item);
}
```

### 1.5 Memory Utilities

```zig
// From src/memory.zig

/// Allocates memory for a value of type `T` and initializes it with `value`.
pub fn create(comptime T: type, allocator: std.mem.Allocator, value: T) bun.OOM!*T {
    const ptr = try allocator.create(T);
    ptr.* = value;
    return ptr;
}

/// Frees memory previously allocated by `create`.
pub fn destroy(allocator: std.mem.Allocator, ptr: anytype) void {
    allocator.destroy(ptr);
}

/// Recursive deinit for nested types
pub fn deinit(ptr_or_slice: anytype) void {
    // handles slices, optionals, error unions, arrays, structs, tagged unions
}
```

### 1.6 StringBuilder Pattern (Two-Phase Building)

```zig
// Phase 1: Count the needed capacity
var builder = StringBuilder{};
builder.count(string1);
builder.count(string2);
builder.countZ(string3);  // with null terminator

// Phase 2: Allocate and fill
try builder.allocate(allocator);
const result1 = builder.append(string1);
const result2 = builder.append(string2);
const result3 = builder.appendZ(string3);

// Cleanup
builder.deinit(allocator);
```

---

## 2. Error Handling Patterns

### 2.1 Error Set Definitions

```zig
// Simple error sets
pub const ShellError = error{ Init, Process, GlobalThisThrown, Spawn };

// Combined error sets using ||
const ParserError = bun.OOM || error{ UnexpectedToken };

// Domain-specific error sets
pub const AnyPostgresError = error{
    ConnectionClosed,
    ExpectedRequest,
    InvalidBackendKeyData,
    // ... many more
};
```

### 2.2 Custom Rich Error Types (Maybe Pattern)

```zig
// From src/sys/Error.zig - Rich error with context
const Error = @This();

errno: Int = todo_errno,
fd: bun.FileDescriptor = bun.invalid_fd,
path: []const u8 = "",
syscall: sys.Tag = sys.Tag.TODO,
dest: []const u8 = "",

pub fn withPath(this: Error, path: anytype) Error {
    return Error{
        .errno = this.errno,
        .syscall = this.syscall,
        .path = bun.span(path),
    };
}
```

### 2.3 The Maybe(T) Pattern

```zig
// From src/bun.js/node.zig
pub fn Maybe(comptime ReturnTypeT: type, comptime ErrorTypeT: type) type {
    return union(Tag) {
        err: ErrorType,
        result: ReturnType,

        pub const Tag = enum { err, result };

        pub fn unwrap(this: @This()) !ReturnType {
            return switch (this) {
                .result => |r| r,
                .err => |e| bun.errnoToZigErr(e.errno),
            };
        }
    };
}

// Usage
pub fn openat(dir: bun.FileDescriptor, path: [:0]const u8, ...) Maybe(File) {
    return switch (sys.openat(dir, path, ...)) {
        .result => |fd| .{ .result = .{ .handle = fd } },
        .err => |err| .{ .err = err },
    };
}
```

### 2.4 bun.handleOom Pattern

```zig
// From src/handle_oom.zig
/// Prefer this method over `catch bun.outOfMemory()`, since that could
/// mistakenly catch non-OOM-related errors.
pub fn handleOom(error_union_or_set: anytype) return_type {
    const err = switch (comptime @typeInfo(ArgType)) {
        .error_union => if (error_union_or_set) |success| return success else |err| err,
        .error_set => error_union_or_set,
        else => unreachable,
    };
    return if (comptime isOomOnlyError(ArgType))
        bun.outOfMemory()
    else switch (err) {
        error.OutOfMemory => bun.outOfMemory(),
        else => |other_error| other_error,
    };
}

// Usage
const ptr = bun.handleOom(allocator.create(T));
```

### 2.5 errdefer Usage

```zig
// Simple errdefer
var envp = try .initCapacity(num_vars + 1);
errdefer envp.deinit();

// Multiple errdefers
errdefer new_credentials.deinit();
errdefer bun.default_allocator.free(host);

// errdefer with allocator.destroy
const define = try allocator.create(Define);
errdefer allocator.destroy(define);
```

---

## 3. String Ownership Conventions

### 3.1 Primary String Types

| Type | File | Description |
|------|------|-------------|
| `[]const u8` | stdlib | Standard Zig slice - **borrowed by default** |
| `bun.String` | `src/string.zig` | Tagged union with ref counting |
| `ZigString` | `src/bun.js/bindings/ZigString.zig` | Extern struct with pointer tagging |
| `SmolStr` | `src/string/SmolStr.zig` | Small-string optimized (inline <=15 bytes) |
| `CowSlice(T)` | `src/ptr/CowSlice.zig` | Copy-on-write with owned/borrowed tracking |

### 3.2 String Tag

```zig
pub const Tag = enum(u8) {
    Dead = 0,           // Invalid string
    WTFStringImpl = 1,  // JSC-owned, reference counted
    ZigString = 2,      // Unknown owner, must clone for JS
    StaticZigString = 3,// Static memory, never freed
    Empty = 4,          // Empty string ""
};
```

### 3.3 Borrowed vs Owned Strings

```zig
// Borrowed (no allocation)
pub fn borrowUTF8(value: []const u8) String {
    return String.init(ZigString.initUTF8(value));
}

// Owned (allocates)
pub fn cloneUTF8(bytes: []const u8) String {
    return jsc.WebCore.encoding.toBunStringComptime(bytes, .utf8);
}

// Reference counting
pub fn dupeRef(this: String) String {
    this.ref();
    return this;  // Returns same pointer with incremented refcount
}
```

### 3.4 Pointer Tagging in ZigString

```zig
// Bit 63: is UTF-16
pub inline fn is16Bit(this: *const ZigString) bool {
    return (@intFromPtr(this._unsafe_ptr_do_not_use) & (1 << 63)) != 0;
}

// Bit 62: is globally allocated (mimalloc)
pub inline fn isGloballyAllocated(this: ZigString) bool {
    return (@intFromPtr(this._unsafe_ptr_do_not_use) & (1 << 62)) != 0;
}

// Bit 61: is UTF-8
pub fn isUTF8(this: ZigString) bool {
    return (@intFromPtr(this._unsafe_ptr_do_not_use) & (1 << 61)) != 0;
}
```

### 3.5 CowSlice - Explicit Ownership Tracking

```zig
// From src/ptr/CowSlice.zig
pub fn CowSliceZ(T: type, comptime sentinel: ?T) type {
    return struct {
        ptr: [*]T,
        flags: packed struct(usize) {
            len: u63,
            is_owned: bool,  // THE KEY BIT
        },

        /// Create a Cow that owns its allocation.
        pub fn initOwned(data: []T, allocator: Allocator) Self { ... }

        /// Create a Cow that wraps a static string.
        /// Calling `.deinit()` is safe but will have no effect.
        pub fn initStatic(comptime data: Slice) Self { ... }
    };
}
```

### 3.6 Ownership Indicators Summary

| Indicator | Meaning | Example |
|-----------|---------|---------|
| `borrow`, `borrowUTF8` | No ownership transfer | `String.borrowUTF8(slice)` |
| `clone`, `cloneUTF8` | Allocates copy, caller owns | `String.cloneUTF8(bytes)` |
| `dupeRef` | Increments refcount, shared ownership | `str.dupeRef()` |
| `initOwned` | Takes ownership of passed memory | `CowSlice.initOwned(alloced, alloc)` |
| `initStatic` | Points to static memory, never freed | `CowSlice.initStatic("literal")` |
| `toOwnedSlice` | Allocates and returns owned slice | `str.toOwnedSlice(allocator)` |
| `deinit` | Conditionally frees based on ownership | `slice.deinit()` |
| `deref` | Decrements refcount | `wtf_string.deref()` |

---

## 4. Async/Event Loop Patterns

### 4.1 Platform Abstraction

```zig
// The Loop is an alias to uws.Loop (uSockets loop)
pub const Loop = uws.Loop;

// FilePoll wraps a file descriptor and its owner for I/O events
pub const FilePoll = struct {
    fd: bun.FileDescriptor = invalid_fd,
    flags: Flags.Set = Flags.Set{},
    owner: Owner = Owner.Null,  // Tagged pointer to handler
    generation_number: KQueueGenerationNumber = 0,

    pub fn register(this: *FilePoll, loop: *Loop, flag: Flags, one_shot: bool) bun.sys.Maybe(void) {
        // On Linux: uses epoll_ctl
        // On macOS: uses kevent64
    }
};
```

### 4.2 KeepAlive Pattern

```zig
pub const KeepAlive = struct {
    status: Status = .inactive,

    const Status = enum { active, inactive, done };

    pub fn activate(this: *KeepAlive, loop: *Loop) void {
        if (this.status != .inactive) return;
        this.status = .active;
        loop.addActive(1);
    }

    pub fn deactivate(this: *KeepAlive, loop: *Loop) void {
        if (this.status != .active) return;
        this.status = .inactive;
        loop.subActive(1);
    }
};
```

### 4.3 Task System with Tagged Pointer Unions

```zig
pub const Task = TaggedPointerUnion(.{
    Access,
    AnyTask,
    AppendFile,
    ReadFile,
    WriteFile,
    // ... many more task types
});

pub fn tickQueueWithCount(this: *EventLoop, ...) void {
    while (this.tasks.readItem()) |task| {
        switch (task.tag()) {
            @field(Task.Tag, @typeName(ReadFile)) => {
                var any: *ReadFile = task.get(ReadFile).?;
                try any.runFromJSThread();
            },
            // ... all other task types
        }
    }
}
```

### 4.4 ConcurrentPromiseTask Pattern

```zig
pub fn ConcurrentPromiseTask(comptime Context: type) type {
    return struct {
        ctx: *Context,
        task: WorkPoolTask = .{ .callback = &runFromThreadPool },
        event_loop: *jsc.EventLoop,
        promise: jsc.JSPromise.Strong = .{},
        ref: Async.KeepAlive = .{},

        // Runs on thread pool
        pub fn runFromThreadPool(task: *WorkPoolTask) void {
            var this: *This = @fieldParentPtr("task", task);
            Context.run(this.ctx);  // Do the work
            this.onFinish();
        }

        // Schedule result back to JS thread
        pub fn onFinish(this: *This) void {
            this.event_loop.enqueueTaskConcurrent(this.concurrent_task.from(this));
        }

        // Runs on JS thread to resolve promise
        pub fn runFromJS(this: *This) bun.JSTerminated!void {
            const promise = this.promise.swap();
            return this.ctx.then(promise);  // Context implements then()
        }
    };
}
```

### 4.5 Key Patterns Summary

| Pattern | Use Case |
|---------|----------|
| `FilePoll` | Watch FDs for I/O events |
| `KeepAlive` | Keep process alive during async ops |
| `Tagged Task Union` | Type-safe task dispatch without vtables |
| `ConcurrentTask` | Cross-thread task scheduling |
| `ConcurrentPromiseTask` | Thread pool work + Promise resolution |
| `WorkPool/ThreadPool` | CPU-intensive or blocking work |
| `Waker` | Cross-thread wake-up mechanism |
| `Futex` | Low-level thread blocking/waking |

---

## 5. Struct Initialization Patterns

### 5.1 Standard init/deinit Pattern

```zig
const MutableString = @This();

allocator: Allocator,
list: std.ArrayListUnmanaged(u8),

pub fn init(allocator: Allocator, capacity: usize) Allocator.Error!MutableString {
    return MutableString{
        .allocator = allocator,
        .list = if (capacity > 0)
            try std.ArrayListUnmanaged(u8).initCapacity(allocator, capacity)
        else
            std.ArrayListUnmanaged(u8){},
    };
}

pub fn deinit(str: *MutableString) void {
    if (str.list.capacity > 0) {
        str.list.expandToCapacity();
        str.list.clearAndFree(str.allocator);
    }
}
```

### 5.2 Multiple init Variants

```zig
pub fn initEmpty(allocator: Allocator) MutableString {
    return MutableString{ .allocator = allocator, .list = .{} };
}

pub fn initCopy(allocator: Allocator, str: anytype) Allocator.Error!MutableString {
    var mutable = try MutableString.init(allocator, str.len);
    try mutable.copy(str);
    return mutable;
}

pub fn initCapacity(allocator: Allocator, cap: usize) Allocator.Error!StringBuilder {
    return StringBuilder{
        .cap = cap,
        .len = 0,
        .ptr = (try allocator.alloc(u8, cap)).ptr,
    };
}
```

### 5.3 Options Structs Pattern

```zig
pub const Options = struct {
    log_level: LogLevel = .default,
    global: bool = false,
    dry_run: bool = false,
    max_threads: u32 = 4,
    // ... many more fields with defaults
};

pub fn init(config: Config) ThreadPool {
    return .{
        .stack_size = @max(1, config.stack_size),
        .max_threads = @max(1, config.max_threads),
    };
}
```

### 5.4 Comptime Dispatch for Different Buffer Types

```zig
pub fn LinearFifo(comptime T: type, comptime buffer_type: LinearFifoBufferType) type {
    return struct {
        allocator: if (buffer_type == .Dynamic) Allocator else void,
        buf: BufferType,

        // Dispatch different init functions based on buffer type
        pub const init = switch (buffer_type) {
            .Static => initStatic,
            .Slice => initSlice,
            .Dynamic => initDynamic,
        };
    };
}
```

### 5.5 Key Conventions

1. **Named field initialization**: Always use `.field = value` syntax
2. **Default values**: Specify directly in struct field definitions
3. **Invalidation**: Set `self.* = undefined` at end of `deinit()` to catch use-after-free
4. **Private fields**: Use `#field_name` syntax for internal state (Zig 0.13+)
5. **Borrowed types**: Separate `Borrowed` variant for non-owning references

---

## 6. Testing Patterns

### 6.1 Test Block Organization

Tests are **inline** in source files at the **bottom**:

```zig
// Implementation code...

test "basic string usage" {
    var s = bun.String.cloneUTF8("hi");
    defer s.deref();
    try t.expect(s.tag != .Dead and s.tag != .Empty);
}

// Imports at the very bottom
const std = @import("std");
const t = std.testing;
```

### 6.2 Test Naming Conventions

```zig
// Descriptive names
test "LinearFifo(u8, .Dynamic) discard(0) from empty buffer should not error on overflow"
test "Creating an inlined SmolStr does not allocate"

// Type-named tests (decltest pattern)
test SmolStr {
    // All tests for the SmolStr type
}
```

### 6.3 Assertions

```zig
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// Boolean assertions
try testing.expect(condition);

// Equality assertions
try testing.expectEqual(@as(usize, 5), fifo.readableLength());

// String assertions
try testing.expectEqualStrings("hello", str.slice());

// Error assertions
try testing.expectError(error.StringTooLong, SmolStr.Inlined.init("..."));
```

### 6.4 Allocator Patterns in Tests

```zig
test "StaticHashMap: put, get, delete, grow" {
    const keys = try testing.allocator.alloc(usize, 512);
    defer testing.allocator.free(keys);

    var map = try AutoHashMap(usize, usize, 50).initCapacity(testing.allocator, 16);
    defer map.deinit(testing.allocator);
}
```

### 6.5 Mocking Patterns

```zig
const MockRequestContextType = struct {
    handle_request_called: bool = false,
    redirect_called: bool = false,
    matched_route: ?Match = null,

    pub fn handleRequest(this: *MockRequestContextType) !void {
        this.handle_request_called = true;
    }
};
```

---

## 7. HTTP/Networking Patterns

### 7.1 HTTP Client Architecture

```zig
const HTTPClient = @This();

pub var default_allocator: std.mem.Allocator = undefined;
pub var default_arena: Arena = undefined;
pub var http_thread: HTTPThread = undefined;

// Shared buffers to avoid repeated allocation
var shared_request_headers_buf: [256]picohttp.Header = undefined;
var shared_response_headers_buf: [256]picohttp.Header = undefined;
```

### 7.2 Connection Pooling

```zig
pub fn NewHTTPContext(comptime ssl: bool) type {
    return struct {
        const pool_size = 64;  // Fixed pool size

        const PooledSocket = struct {
            http_socket: HTTPSocket,
            hostname_buf: [128]u8 = undefined,
            hostname_len: u8 = 0,
            port: u16 = 0,
        };

        pending_sockets: PooledSocketHiveAllocator,  // HiveArray<PooledSocket, 64>

        pub fn releaseSocket(this: *@This(), socket: HTTPSocket, ...) void {
            // Reuse socket for HTTP Keep-Alive
            if (socket.isEstablished()) {
                if (this.pending_sockets.get()) |pending| {
                    pending.http_socket = socket;
                    socket.setTimeoutMinutes(5);  // Keep-alive timeout
                    return;
                }
            }
            closeSocket(socket);
        }
    };
}
```

### 7.3 HiveArray (Fixed-Size Allocation Pool)

```zig
pub fn HiveArray(comptime T: type, comptime capacity: u16) type {
    return struct {
        buffer: [capacity]T,
        used: bun.bit_set.IntegerBitSet(capacity),

        pub fn get(self: *Self) ?*T {
            const index = self.used.findFirstUnset() orelse return null;
            self.used.set(index);
            return &self.buffer[index];
        }

        pub fn put(self: *Self, value: *T) bool {
            const index = self.indexOf(value) orelse return false;
            value.* = undefined;
            self.used.unset(index);
            return true;
        }
    };
}
```

### 7.4 Stack Fallback for Request Bodies

```zig
const request_body_send_stack_buffer_size = 32 * 1024;  // 32KB stack

pub const RequestBodyBuffer = union(enum) {
    heap: *HeapRequestBodyBuffer,  // 512KB
    stack: std.heap.StackFallbackAllocator(32 * 1024),

    pub fn allocator(this: *@This()) std.mem.Allocator {
        return switch (this.*) {
            .heap => |heap| heap.fixed_buffer_allocator.allocator(),
            .stack => |*stack| stack.get(),
        };
    }
};
```

---

## 8. Generic Programming Patterns

### 8.1 Comptime Generics

```zig
pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        err: E,
    };
}

pub fn AutoHashMap(comptime K: type, comptime V: type, comptime max_load: comptime_int) type {
    return HashMap(K, V, std.hash_map.AutoContext(K), max_load);
}
```

### 8.2 Type Functions

```zig
// Extract child type from pointer/slice
pub fn Item(comptime T: type) type {
    switch (@typeInfo(T)) {
        .pointer => |ptr| return ptr.child,
        else => return std.meta.Child(T),
    }
}

// Create tagged union type
pub fn Tagged(comptime U: type, comptime T: type) type {
    var info: std.builtin.Type.Union = @typeInfo(U).@"union";
    info.tag_type = T;
    return @Type(.{ .@"union" = info });
}
```

### 8.3 Tagged Unions

```zig
pub const OutputSrc = union(enum) {
    arrlist: std.ArrayListUnmanaged(u8),
    owned_buf: []const u8,
    borrowed_buf: []const u8,

    pub fn slice(this: *OutputSrc) []const u8 {
        return switch (this.*) {
            .arrlist => |*a| a.items,
            .owned_buf => |b| b,
            .borrowed_buf => |b| b,
        };
    }

    pub fn deinit(this: *OutputSrc) void {
        switch (this.*) {
            .arrlist => |*a| a.deinit(allocator),
            .owned_buf => |b| allocator.free(b),
            .borrow_buf => {},
        }
    }
};
```

### 8.4 Type Traits

```zig
pub inline fn isZigString(comptime T: type) bool {
    return comptime blk: {
        const info = @typeInfo(T);
        if (info != .pointer) break :blk false;
        const ptr = &info.pointer;
        if (ptr.size == .slice) break :blk ptr.child == u8;
        break :blk false;
    };
}

pub inline fn isSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice;
}

pub inline fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"opaque", .@"union" => true,
        else => false,
    };
}
```

---

## 9. Recommendations for Makai

Based on Bun's patterns, here are specific improvements for Makai's agent module:

### 9.1 Use Borrowed Types for Ownership Clarity

```zig
// Instead of ambiguous ownership
pub const AgentContext = struct {
    messages: []Message,  // Who owns this?
};

// Use explicit ownership
pub const AgentContext = struct {
    messages: []Message,
    owns_messages: bool = false,  // Or use CowSlice

    pub const Borrowed = struct {
        messages: []const Message,  // Never frees
    };

    pub fn borrow(self: *const AgentContext) Borrowed {
        return .{ .messages = self.messages };
    }
};
```

### 9.2 Add cloneIfBorrowed Pattern

```zig
pub fn cloneIfBorrowed(self: Slice, allocator: std.mem.Allocator) bun.OOM!Slice {
    if (self.isAllocated()) {
        return self;  // Already owned
    }
    const duped = try allocator.dupe(u8, self.ptr[0..self.len]);
    return Slice{ .allocator = NullableAllocator.init(allocator), .ptr = duped.ptr };
}
```

### 9.3 Implement Maybe(T) for Rich Error Context

```zig
pub fn Maybe(comptime T: type) type {
    return union(enum) {
        result: T,
        err: Error,

        pub const Error = struct {
            code: u16,
            message: []const u8,
            syscall: ?[]const u8 = null,
        };
    };
}
```

### 9.4 Use errdefer Consistently

```zig
pub fn init(allocator: std.mem.Allocator, config: Config) OOM!*Agent {
    const agent = try allocator.create(Agent);
    errdefer allocator.destroy(agent);

    agent.messages = try allocator.alloc(Message, config.max_messages);
    errdefer allocator.free(agent.messages);

    agent.stream = try EventStream.init();
    errdefer agent.stream.deinit();

    return agent;
}
```

### 9.5 Add bun.handleOom for Safer OOM Handling

```zig
// Instead of:
const ptr = allocator.create(T) catch bun.outOfMemory();

// Use:
const ptr = bun.handleOom(allocator.create(T));
// This only catches OOM, not other errors
```

### 9.6 Consider StringBuilder for Event Construction

```zig
// Two-phase building for efficient string construction
var builder = StringBuilder{};
builder.count(event.type);
builder.count(event.data);
builder.countZ(event.timestamp);

try builder.allocate(allocator);
_ = builder.append(event.type);
_ = builder.append(event.data);
_ = builder.appendZ(event.timestamp);
```

---

## Key Files for Reference

| Category | Key Files |
|----------|-----------|
| Allocators | `src/allocators.zig`, `src/allocators/MimallocArena.zig` |
| Strings | `src/string.zig`, `src/string/StringBuilder.zig`, `src/string/SmolStr.zig` |
| Errors | `src/sys/Error.zig`, `src/handle_oom.zig` |
| Async | `src/async/posix_event_loop.zig`, `src/bun.js/event_loop.zig` |
| Tasks | `src/bun.js/event_loop/Task.zig`, `src/bun.js/event_loop/ConcurrentTask.zig` |
| Testing | `src/main_test.zig`, `src/unit_test.zig` |
| Generics | `src/meta.zig`, `src/trait.zig`, `src/collections/` |
