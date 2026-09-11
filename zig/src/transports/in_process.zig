
const std = @import("std");
const compat = @import("compat");
const transport_mod = @import("transport");
const event_stream = @import("event_stream");
const ai_types = @import("ai_types");
const oom = @import("oom");

pub const Mode = enum {
    direct,
    serialized,
};

pub const InProcessTransport = struct {
    stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
    owns_stream: bool,
    mode: Mode,

    const Self = @This();

    pub fn initWithStream(stream: *event_stream.AssistantMessageStream, allocator: std.mem.Allocator) Self {
        return .{
            .stream = stream,
            .allocator = allocator,
            .owns_stream = false,
            .mode = .direct,
        };
    }

    pub fn init(allocator: std.mem.Allocator) !*Self {
        return initWithMode(allocator, .direct);
    }

    pub fn initWithMode(allocator: std.mem.Allocator, mode: Mode) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const stream = try allocator.create(event_stream.AssistantMessageStream);
        errdefer allocator.destroy(stream);

        stream.* = event_stream.AssistantMessageStream.init(allocator);
        stream.owns_events = true;

        self.* = .{
            .stream = stream,
            .allocator = allocator,
            .owns_stream = true,
            .mode = mode,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.owns_stream) {
            self.stream.deinit();
            self.allocator.destroy(self.stream);
            self.allocator.destroy(self);
        }
    }

    pub fn getStream(self: *Self) *event_stream.AssistantMessageStream {
        return self.stream;
    }

    pub fn asyncSender(self: *Self) transport_mod.AsyncSender {
        return .{
            .context = @ptrCast(self),
            .write_fn = writeFn,
            .flush_fn = flushFn,
            .close_fn = closeFn,
        };
    }

    pub fn asyncReceiver(self: *Self) transport_mod.AsyncReceiver {
        return .{
            .context = @ptrCast(self),
            .receive_stream_fn = receiveStreamFn,
            .read_fn = null,
            .close_fn = closeReceiverFn,
        };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const msg = try transport_mod.deserialize(data, self.allocator);
        switch (msg) {
            .event => |ev| {
                var mutable_ev = ev;
                self.stream.push(mutable_ev) catch |err| {
                    ai_types.deinitAssistantMessageEvent(self.allocator, &mutable_ev);
                    return err;
                };
            },
            .result => |r| {
                self.stream.complete(r);
            },
            .stream_error => |e| {
                self.stream.completeWithError(e.slice());
                var mutable_e = e;
                mutable_e.deinit(self.allocator);
            },
            .control => |ctrl| {
                handleControlMessage(ctrl, self.allocator);
            },
        }
    }

    fn flushFn(ctx: *anyopaque) !void {
        _ = ctx;
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.owns_stream) {
            self.stream.completeWithError("Transport closed");
        }
    }

    const ProducerContext = struct {
        stream: *event_stream.AssistantMessageStream,
        byte_stream: *transport_mod.ByteStream,
        allocator: std.mem.Allocator,
    };

    fn receiveStreamFn(ctx: *anyopaque, allocator: std.mem.Allocator) !*transport_mod.ByteStream {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const byte_stream = try allocator.create(transport_mod.ByteStream);
        byte_stream.* = transport_mod.ByteStream.init(allocator);

        const thread_ctx = try allocator.create(ProducerContext);
        thread_ctx.* = .{
            .stream = self.stream,
            .byte_stream = byte_stream,
            .allocator = allocator,
        };

        const thread = try std.Thread.spawn(.{}, producerThread, .{thread_ctx});
        thread.detach();

        return byte_stream;
    }

    fn closeReceiverFn(ctx: *anyopaque) void {
        _ = ctx;
    }

    fn producerThread(ctx: *ProducerContext) void {
        defer {
            ctx.byte_stream.markThreadDone();
            ctx.allocator.destroy(ctx);
        }

        while (ctx.stream.wait()) |ev| {
            const json_bytes = transport_mod.serializeEvent(ev, ctx.allocator) catch {
                ctx.byte_stream.completeWithError("Serialization error");
                return;
            };

            var mutable_ev = ev;
            ai_types.deinitAssistantMessageEvent(ctx.allocator, &mutable_ev);

            const chunk = transport_mod.ByteChunk{
                .data = json_bytes,
                .owned = true,
            };

            ctx.byte_stream.push(chunk) catch {
                ctx.allocator.free(json_bytes);
                ctx.byte_stream.completeWithError("Stream queue full");
                return;
            };
        }

        if (ctx.stream.getError()) |err| {
            ctx.byte_stream.completeWithError(err);
        } else {
            ctx.byte_stream.complete({});
        }
    }

    fn handleControlMessage(ctrl: transport_mod.ControlMessage, allocator: std.mem.Allocator) void {
        transport_mod.freeControlStrings(ctrl, allocator);
    }
};

pub fn createPair(allocator: std.mem.Allocator) !struct { client: *InProcessTransport, server: *InProcessTransport } {
    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);
    stream.owns_events = true;

    const client = try allocator.create(InProcessTransport);
    client.* = InProcessTransport.initWithStream(stream, allocator);

    const server = try allocator.create(InProcessTransport);
    server.* = InProcessTransport.initWithStream(stream, allocator);

    return .{ .client = client, .server = server };
}

pub fn destroyPair(allocator: std.mem.Allocator, client: *InProcessTransport, server: *InProcessTransport) void {
    client.stream.deinit();
    allocator.destroy(client.stream);
    allocator.destroy(client);
    allocator.destroy(server);
}

pub fn createSerializedPipe(allocator: std.mem.Allocator) SerializedPipe {
    return SerializedPipe.init(allocator);
}

pub const SerializedPipe = struct {
    to_client: std.ArrayList(u8),
    to_server: std.ArrayList(u8),
    to_client_read_pos: usize,
    to_server_read_pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SerializedPipe {
        return .{
            .to_client = oom.unreachableOnOom(std.ArrayList(u8).initCapacity(allocator, 4096)),
            .to_server = oom.unreachableOnOom(std.ArrayList(u8).initCapacity(allocator, 4096)),
            .to_client_read_pos = 0,
            .to_server_read_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SerializedPipe) void {
        self.to_client.deinit(self.allocator);
        self.to_server.deinit(self.allocator);

        self.* = undefined;
    }

    pub fn compact(self: *SerializedPipe) void {
        compactBuffer(&self.to_client, &self.to_client_read_pos);
        compactBuffer(&self.to_server, &self.to_server_read_pos);
    }

    fn compactBuffer(buffer: *std.ArrayList(u8), read_pos: *usize) void {
        if (read_pos.* == 0) return;
        if (read_pos.* >= buffer.items.len) {
            buffer.clearRetainingCapacity();
            read_pos.* = 0;
            return;
        }
        const remaining = buffer.items[read_pos.*..];
        std.mem.copyForwards(u8, buffer.items[0..remaining.len], remaining);
        buffer.shrinkRetainingCapacity(remaining.len);
        read_pos.* = 0;
    }

    fn appendFramed(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
        try buffer.ensureUnusedCapacity(allocator, data.len + 1);
        buffer.appendSliceAssumeCapacity(data);
        buffer.appendAssumeCapacity('\n');
    }

    pub fn serverSender(self: *SerializedPipe) transport_mod.AsyncSender {
        return .{
            .context = self,
            .write_fn = struct {
                fn write(ctx: *anyopaque, data: []const u8) !void {
                    const s: *SerializedPipe = @ptrCast(@alignCast(ctx));
                    try appendFramed(&s.to_client, s.allocator, data);
                }
            }.write,
            .flush_fn = struct {
                fn flush(_: *anyopaque) !void {}
            }.flush,
        };
    }

    pub fn clientReceiver(self: *SerializedPipe) Receiver {
        return .{
            .pipe = self,
            .buffer = &self.to_client,
            .read_pos_ptr = &self.to_client_read_pos,
        };
    }

    pub fn clientSender(self: *SerializedPipe) transport_mod.AsyncSender {
        return .{
            .context = self,
            .write_fn = struct {
                fn write(ctx: *anyopaque, data: []const u8) !void {
                    const s: *SerializedPipe = @ptrCast(@alignCast(ctx));
                    try appendFramed(&s.to_server, s.allocator, data);
                }
            }.write,
            .flush_fn = struct {
                fn flush(_: *anyopaque) !void {}
            }.flush,
        };
    }

    pub fn serverReceiver(self: *SerializedPipe) Receiver {
        return .{
            .pipe = self,
            .buffer = &self.to_server,
            .read_pos_ptr = &self.to_server_read_pos,
        };
    }

    pub const Receiver = struct {
        pipe: *SerializedPipe,
        buffer: *std.ArrayList(u8),
        read_pos_ptr: *usize,

        pub fn readLine(self: *@This(), allocator: std.mem.Allocator) !?[]const u8 {
            const read_pos = self.read_pos_ptr.*;

            if (read_pos >= self.buffer.items.len) return null;

            const remaining = self.buffer.items[read_pos..];
            if (std.mem.findScalar(u8, remaining, '\n')) |nl_pos| {
                const line_end = read_pos + nl_pos;
                const line = self.buffer.items[read_pos..line_end];
                const result = try allocator.dupe(u8, line);
                self.read_pos_ptr.* = line_end + 1;
                return result;
            }
            return null;
        }
    };
};

pub const EventBridge = struct {
    source: *event_stream.AssistantMessageStream,
    dest: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
    cancel_token: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        source: *event_stream.AssistantMessageStream,
        dest: *event_stream.AssistantMessageStream,
        allocator: std.mem.Allocator,
    ) Self {
        return .{
            .source = source,
            .dest = dest,
            .allocator = allocator,
            .cancel_token = std.atomic.Value(bool).init(false),
        };
    }

    pub fn cancel(self: *Self) void {
        self.cancel_token.store(true, .release);
    }

    pub fn run(self: *Self) void {
        while (!self.cancel_token.load(.acquire)) {
            if (self.source.poll()) |ev| {
                const cloned = ai_types.cloneAssistantMessageEvent(self.allocator, ev) catch {
                    self.dest.completeWithError("Failed to clone event");
                    return;
                };

                var mutable_ev = ev;
                ai_types.deinitAssistantMessageEvent(self.allocator, &mutable_ev);

                self.dest.push(cloned) catch {
                    var mutable_cloned = cloned;
                    ai_types.deinitAssistantMessageEvent(self.allocator, &mutable_cloned);
                    self.dest.completeWithError("Destination queue full");
                    return;
                };
            } else {
                if (self.source.isDone()) {
                    if (self.source.getError()) |err| {
                        self.dest.completeWithError(err);
                    } else if (self.source.getResult()) |result| {
                        self.dest.complete(result);
                    } else {
                        self.dest.complete(.{
                            .content = &.{},
                            .usage = .{},
                            .stop_reason = .stop,
                            .model = "",
                            .api = "",
                            .provider = "",
                            .timestamp = 0,
                        });
                    }
                    return;
                }

                compat.time.sleepNs(1_000_000);
            }
        }

        self.dest.completeWithError("Bridge cancelled");
    }

    pub fn runAsync(self: *Self) !std.Thread {
        return std.Thread.spawn(.{}, run, .{self});
    }
};

pub const ZeroCopyForwarder = struct {
    dest: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(dest: *event_stream.AssistantMessageStream, allocator: std.mem.Allocator) Self {
        return .{
            .dest = dest,
            .allocator = allocator,
        };
    }

    pub fn forward(self: *Self, ev: ai_types.AssistantMessageEvent) !void {
        var cleanup = ev;
        errdefer ai_types.deinitAssistantMessageEvent(self.allocator, &cleanup);
        try self.dest.push(ev);
    }

    pub fn forwardCompletion(self: *Self, result: ai_types.AssistantMessage) void {
        self.dest.complete(result);
    }

    pub fn forwardError(self: *Self, msg: []const u8) void {
        self.dest.completeWithError(msg);
    }

    pub fn getDestStream(self: *Self) *event_stream.AssistantMessageStream {
        return self.dest;
    }
};

test "InProcessTransport basic send and receive" {
    const allocator = std.testing.allocator;

    var ip_transport = try InProcessTransport.init(allocator);
    defer ip_transport.deinit();

    var sender = ip_transport.asyncSender();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event_json = try transport_mod.serializeEvent(.{ .start = .{ .partial = partial } }, allocator);
    defer allocator.free(event_json);

    try sender.write(event_json);

    const received = ip_transport.stream.poll();
    try std.testing.expect(received != null);
    try std.testing.expect(received.? == .start);

    var mutable_ev = received.?;
    ai_types.deinitAssistantMessageEvent(allocator, &mutable_ev);
}

test "InProcessTransport pair communication" {
    const allocator = std.testing.allocator;

    const pair = try createPair(allocator);
    const client = pair.client;
    const server = pair.server;
    defer destroyPair(allocator, client, server);

    var sender = client.asyncSender();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event_json = try transport_mod.serializeEvent(.{ .start = .{ .partial = partial } }, allocator);
    defer allocator.free(event_json);

    try sender.write(event_json);

    const received = server.stream.poll();
    try std.testing.expect(received != null);
    try std.testing.expect(received.? == .start);

    var mutable_ev = received.?;
    ai_types.deinitAssistantMessageEvent(allocator, &mutable_ev);
}

test "EventBridge forwards events" {
    const allocator = std.testing.allocator;

    var source_stream = event_stream.AssistantMessageStream.init(allocator);
    defer source_stream.deinit();

    var dest_stream = event_stream.AssistantMessageStream.init(allocator);
    defer dest_stream.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event = ai_types.AssistantMessageEvent{ .start = .{ .partial = partial } };
    const cloned = try ai_types.cloneAssistantMessageEvent(allocator, event);
    try source_stream.push(cloned);

    source_stream.complete(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "",
        .api = "",
        .provider = "",
        .timestamp = 0,
    });

    var bridge = EventBridge.init(&source_stream, &dest_stream, allocator);
    bridge.run();

    const received = dest_stream.poll();
    try std.testing.expect(received != null);
    try std.testing.expect(received.? == .start);

    var mutable_ev = received.?;
    ai_types.deinitAssistantMessageEvent(allocator, &mutable_ev);
}

test "ZeroCopyForwarder forwards events" {
    const allocator = std.testing.allocator;

    var dest_stream = event_stream.AssistantMessageStream.init(allocator);
    defer dest_stream.deinit();

    var forwarder = ZeroCopyForwarder.init(&dest_stream, allocator);

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event = try ai_types.cloneAssistantMessageEvent(
        allocator,
        .{ .start = .{ .partial = partial } },
    );

    try forwarder.forward(event);

    const received = dest_stream.poll();
    try std.testing.expect(received != null);
    try std.testing.expect(received.? == .start);

    var mutable_ev = received.?;
    ai_types.deinitAssistantMessageEvent(allocator, &mutable_ev);
}

test "InProcessTransport async receiver" {
    const allocator = std.testing.allocator;

    var transport_ptr = try InProcessTransport.init(allocator);
    defer transport_ptr.deinit();

    var receiver = transport_ptr.asyncReceiver();

    const byte_stream = try receiver.receiveStream(allocator);

    var sender = transport_ptr.asyncSender();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event_json = try transport_mod.serializeEvent(.{ .start = .{ .partial = partial } }, allocator);
    defer allocator.free(event_json);

    try sender.write(event_json);

    transport_ptr.stream.complete(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "",
        .api = "",
        .provider = "",
        .timestamp = 0,
    });

    while (byte_stream.wait()) |chunk| {
        var mutable_chunk = chunk;
        mutable_chunk.deinit(allocator);
    }

    _ = byte_stream.waitForThread(5000);
    byte_stream.deinit();
    allocator.destroy(byte_stream);
}

test "SerializedPipe bidirectional communication" {
    const allocator = std.testing.allocator;

    var pipe = createSerializedPipe(allocator);
    defer pipe.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event_json = try transport_mod.serializeEvent(.{ .start = .{ .partial = partial } }, allocator);
    defer allocator.free(event_json);

    var sender = pipe.serverSender();
    try sender.write(event_json);
    try sender.flush();

    var receiver = pipe.clientReceiver();
    const line = try receiver.readLine(allocator) orelse return error.NoDataReceived;
    defer allocator.free(line);

    try std.testing.expectEqualStrings(event_json, line);
}

test "SerializedPipe full round trip" {
    const allocator = std.testing.allocator;

    var pipe = createSerializedPipe(allocator);
    defer pipe.deinit();

    const request = "{\"type\":\"ping\"}";
    var client_sender = pipe.clientSender();
    try client_sender.write(request);

    var server_receiver = pipe.serverReceiver();
    const received_req = try server_receiver.readLine(allocator) orelse return error.NoDataReceived;
    defer allocator.free(received_req);
    try std.testing.expectEqualStrings(request, received_req);

    const response = "{\"type\":\"pong\"}";
    var server_sender = pipe.serverSender();
    try server_sender.write(response);

    var client_receiver = pipe.clientReceiver();
    const received_resp = try client_receiver.readLine(allocator) orelse return error.NoDataReceived;
    defer allocator.free(received_resp);
    try std.testing.expectEqualStrings(response, received_resp);
}

test "SerializedPipe write is all-or-nothing under allocation failure" {
    const allocator = std.testing.allocator;
    const payload = try allocator.alloc(u8, 8192);
    defer allocator.free(payload);
    @memset(payload, 'x');
    payload[0] = '{';
    payload[payload.len - 1] = '}';

    var fail_index: usize = 0;
    while (fail_index <= 4) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var pipe = SerializedPipe.init(failing.allocator());
        defer pipe.deinit();

        failing.fail_index = fail_index;
        var sender = pipe.serverSender();
        if (sender.write(payload)) |_| {
            var receiver = pipe.clientReceiver();
            const line = try receiver.readLine(allocator) orelse return error.NoDataReceived;
            defer allocator.free(line);
            try std.testing.expectEqualStrings(payload, line);
            try std.testing.expectEqual(@as(?[]const u8, null), try receiver.readLine(allocator));
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            var receiver = pipe.clientReceiver();
            try std.testing.expectEqual(@as(?[]const u8, null), try receiver.readLine(allocator));
        }
    }
}

test "InProcessTransport applies queue backpressure under burst writes" {
    const allocator = std.testing.allocator;

    var ip_transport = try InProcessTransport.init(allocator);
    defer ip_transport.deinit();

    var sender = ip_transport.asyncSender();
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    for (0..event_stream.AssistantMessageStream.usable_capacity) |_| {
        const event_json = try transport_mod.serializeEvent(
            .{ .start = .{ .partial = partial } },
            allocator,
        );
        try sender.write(event_json);
        allocator.free(event_json);
    }

    const overflow_json = try transport_mod.serializeEvent(
        .{ .start = .{ .partial = partial } },
        allocator,
    );
    defer allocator.free(overflow_json);
    try std.testing.expectError(error.QueueFull, sender.write(overflow_json));

    const ev = ip_transport.stream.poll().?;
    var mut_ev = ev;
    ai_types.deinitAssistantMessageEvent(allocator, &mut_ev);

    const retry_json = try transport_mod.serializeEvent(
        .{ .start = .{ .partial = partial } },
        allocator,
    );
    defer allocator.free(retry_json);
    try sender.write(retry_json);

    while (ip_transport.stream.poll()) |leftover| {
        var mut_leftover = leftover;
        ai_types.deinitAssistantMessageEvent(allocator, &mut_leftover);
    }
}

test "InProcessTransport sender close propagates terminal error" {
    const allocator = std.testing.allocator;

    var ip_transport = try InProcessTransport.init(allocator);
    defer ip_transport.deinit();

    var sender = ip_transport.asyncSender();
    sender.close();

    try std.testing.expect(ip_transport.stream.isDone());
    try std.testing.expect(ip_transport.stream.getError() != null);
    try std.testing.expectEqualStrings("Transport closed", ip_transport.stream.getError().?);
}

const ConcurrentWriteCtx = struct {
    transport: *InProcessTransport,
    allocator: std.mem.Allocator,
    count: usize,
    failed: *std.atomic.Value(bool),
};

fn writeBurstThread(ctx: *ConcurrentWriteCtx) void {
    var sender = ctx.transport.asyncSender();
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    for (0..ctx.count) |_| {
        const event_json = transport_mod.serializeEvent(
            .{ .start = .{ .partial = partial } },
            ctx.allocator,
        ) catch {
            ctx.failed.store(true, .release);
            return;
        };
        sender.write(event_json) catch {
            ctx.allocator.free(event_json);
            ctx.failed.store(true, .release);
            return;
        };
        ctx.allocator.free(event_json);
    }

    ctx.transport.stream.complete(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "",
        .api = "",
        .provider = "",
        .timestamp = 0,
    });
}

test "InProcessTransport concurrent write/read drains all events" {
    const allocator = std.testing.allocator;

    var ip_transport = try InProcessTransport.init(allocator);
    defer ip_transport.deinit();

    var failed = std.atomic.Value(bool).init(false);
    var ctx = ConcurrentWriteCtx{
        .transport = ip_transport,
        .allocator = allocator,
        .count = 64,
        .failed = &failed,
    };

    const th = try std.Thread.spawn(.{}, writeBurstThread, .{&ctx});
    defer th.join();

    var received: usize = 0;
    while (ip_transport.stream.wait()) |ev| {
        if (ev == .start) {
            received += 1;
        }
        var mut_ev = ev;
        ai_types.deinitAssistantMessageEvent(allocator, &mut_ev);
    }

    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(ctx.count, received);
}
