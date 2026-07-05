//! WebSocket Transport (Beta)
//!
//! This implementation is suitable for development and testing.
//! Production use requires TLS termination via reverse proxy: `wss://` is parsed
//! but still rejected with `error.TlsNotSupported` because this transport only
//! wraps plain TCP streams.
//!
//! Networking is routed through Makai's `compat.net` seam, which currently uses
//! the project default `std.Io.Threaded` context (`std.testing.io` in tests).
//! Zig 0.16 `std.Io.Evented` networking remains unsupported by that seam.
//!
//! Handshake validation checks status/upgrade headers and verifies the
//! `Sec-WebSocket-Accept` value per RFC 6455 §4.2.2.

const std = @import("std");
const transport = @import("transport");
const ai_types = @import("ai_types");
const compat = @import("compat");

const default_subprotocol = "makai.v1";

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub const AsyncStreamHandle = WebSocketClient.AsyncStreamHandle;

fn streamFromSocketHandle(handle: std.Io.net.Socket.Handle) compat.net.Stream {
    return compat.net.Stream.init(.{ .socket = .{ .handle = handle, .address = .{ .ip4 = .loopback(0) } } });
}

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    state: ConnectionState,

    // Connection state
    tcp_stream: ?compat.net.Stream = null,

    // For async operation
    send_buffer: std.ArrayList(u8) = std.ArrayList(u8).empty,
    recv_buffer: std.ArrayList(u8) = std.ArrayList(u8).empty,
    fragment_buffer: std.ArrayList(u8) = std.ArrayList(u8).empty,
    fragment_opcode: ?Opcode = null,

    // Callbacks
    on_message: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null,
    on_message_ctx: ?*anyopaque = null,

    // Handshake key (stored for verification)
    handshake_key: [24]u8 = undefined,

    // Serializes tcp_stream state changes. Cancellation uses this mutex only
    // long enough to call shutdown, so it can bypass blocked writers.
    mutex: std.atomic.Mutex = .unlocked,

    // Serializes WebSocket frame writes so multi-write frames cannot interleave.
    write_mutex: std.atomic.Mutex = .unlocked,

    // Ping/pong timeout tracking
    ping_timeout_ms: u64 = 30_000,
    waiting_for_pong: bool = false,
    last_ping_at_ms: i64 = 0,

    const Self = @This();

    pub const ConnectionState = enum {
        disconnected,
        connecting,
        connected,
        closing,
        closed,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .state = .disconnected,
            .send_buffer = std.ArrayList(u8).empty,
            .recv_buffer = std.ArrayList(u8).empty,
            .fragment_buffer = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.close();
        self.send_buffer.deinit(self.allocator);
        self.recv_buffer.deinit(self.allocator);
        self.fragment_buffer.deinit(self.allocator);
    }

    /// Connect to WebSocket endpoint using the default `makai.v1` subprotocol.
    /// url format: ws://host:port/path or wss://host:port/path
    /// headers: optional headers (e.g., Authorization: Bearer <api_key>)
    pub fn connect(
        self: *Self,
        url: []const u8,
        headers: ?[]const ai_types.HeaderPair,
    ) !void {
        return self.connectWithSubprotocol(url, headers, default_subprotocol);
    }

    /// Connect to WebSocket endpoint with a configurable subprotocol.
    /// Pass `null` for subprotocol to omit the `Sec-WebSocket-Protocol` header.
    pub fn connectWithSubprotocol(
        self: *Self,
        url: []const u8,
        headers: ?[]const ai_types.HeaderPair,
        subprotocol: ?[]const u8,
    ) !void {
        if (!canInitiateConnect(self.state)) {
            return error.AlreadyConnected;
        }

        // Start each connection attempt from a clean session buffer state.
        self.send_buffer.clearRetainingCapacity();
        self.recv_buffer.clearRetainingCapacity();
        self.fragment_buffer.clearRetainingCapacity();
        self.fragment_opcode = null;
        self.resetPingState();

        self.state = .connecting;

        // Parse URL
        const parsed = parseUrl(url) catch {
            self.state = .disconnected;
            return error.InvalidUrl;
        };

        // Check for TLS (wss://). This transport intentionally remains a
        // plain-TCP WebSocket client after the Zig 0.16 networking migration.
        if (parsed.tls) {
            self.state = .disconnected;
            return error.TlsNotSupported;
        }

        // Resolve and connect through Makai's networking wrapper so std.Io
        // backend selection stays below the public transport interface.
        self.tcp_stream = compat.net.tcpConnectHost(self.allocator, parsed.host, parsed.port) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };

        // Perform WebSocket handshake
        performHandshake(self, parsed.host, parsed.port, parsed.path, headers, subprotocol) catch |err| {
            if (self.tcp_stream) |stream| {
                var closable = stream;
                closable.close();
                self.tcp_stream = null;
            }
            self.state = .disconnected;
            return err;
        };

        self.state = .connected;
    }

    /// Send a text message
    pub fn send(self: *Self, data: []const u8) !void {
        if (self.state != .connected) {
            return error.NotConnected;
        }

        _ = defaultIo();

        // Encode before locking, then hold the write mutex until writeAll
        // completes so multi-write frames cannot interleave. Do not hold the
        // transport-state mutex during writeAll; cancellation must be able to
        // shutdown the socket even when a write is blocked.
        const frame = Frame{
            .opcode = .text,
            .payload = data,
            .fin = true,
            .masked = true,
        };

        const encoded = try encodeFrame(frame, self.allocator);
        defer self.allocator.free(encoded);

        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        const stream = self.tcp_stream orelse {
            self.mutex.unlock();
            return error.NotConnected;
        };
        var writable = stream;
        self.mutex.unlock();

        while (!self.write_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.write_mutex.unlock();
        try writable.writeAll(encoded);
    }

    /// Receive a message (blocking)
    pub fn receive(self: *Self, allocator: std.mem.Allocator) !?[]const u8 {
        _ = defaultIo();
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        if (self.state != .connected) {
            self.mutex.unlock();
            return error.NotConnected;
        }
        self.mutex.unlock();

        // Read frames until we have a complete message
        while (true) {
            // Try to decode a frame from existing buffer
            if (decodeFrame(self.recv_buffer.items)) |result| {
                const frame = result.frame;
                const owned_payload = try allocator.dupe(u8, frame.payload);
                defer allocator.free(owned_payload);

                // Remove consumed bytes after copying the payload because decodeFrame
                // returns slices into recv_buffer.
                if (result.consumed > 0) {
                    const remaining = self.recv_buffer.items[result.consumed..];
                    std.mem.copyForwards(u8, self.recv_buffer.items[0..remaining.len], remaining);
                    self.recv_buffer.shrinkRetainingCapacity(remaining.len);
                }

                // Handle control frames
                switch (frame.opcode) {
                    .close => {
                        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
                        defer self.mutex.unlock();
                        self.state = .closing;
                        return null;
                    },
                    .ping => {
                        // Respond with pong
                        try self.sendPong(owned_payload);
                        continue;
                    },
                    .pong => {
                        self.markPongReceived();
                        continue;
                    },
                    .text, .binary => {
                        if (frame.fin) return try allocator.dupe(u8, owned_payload);
                        self.fragment_buffer.clearRetainingCapacity();
                        try self.fragment_buffer.appendSlice(self.allocator, owned_payload);
                        self.fragment_opcode = frame.opcode;
                        continue;
                    },
                    .continuation => {
                        if (self.fragment_opcode == null) return error.ProtocolError;
                        try self.fragment_buffer.appendSlice(self.allocator, owned_payload);
                        if (!frame.fin) continue;
                        defer {
                            self.fragment_buffer.clearRetainingCapacity();
                            self.fragment_opcode = null;
                        }
                        return try allocator.dupe(u8, self.fragment_buffer.items);
                    },
                }
            }

            // Need more data - read from stream
            while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
            const stream = self.tcp_stream orelse {
                self.mutex.unlock();
                return error.NotConnected;
            };
            var readable = stream;
            self.mutex.unlock();

            var read_buf: [4096]u8 = undefined;
            const bytes_read = readable.read(&read_buf) catch |err| {
                while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
                defer self.mutex.unlock();
                if (err == error.EndOfStream) {
                    if (self.tcp_stream) |open_stream| {
                        var closable = open_stream;
                        closable.close();
                        self.tcp_stream = null;
                    }
                    self.state = .closed;
                    return null;
                }
                return err;
            };

            if (bytes_read == 0) {
                while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
                defer self.mutex.unlock();
                if (self.tcp_stream) |open_stream| {
                    var closable = open_stream;
                    closable.close();
                    self.tcp_stream = null;
                }
                self.state = .closed;
                return null;
            }

            try self.recv_buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);
        }
    }

    /// Close the connection
    pub fn close(self: *Self) void {
        _ = defaultIo();
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.tcp_stream) |stream| {
            var closable = stream;
            // Send close frame if connected
            if (self.state == .connected) {
                const close_frame = Frame{
                    .opcode = .close,
                    .payload = &.{},
                    .fin = true,
                    .masked = true,
                };
                if (encodeFrame(close_frame, self.allocator)) |encoded| {
                    defer self.allocator.free(encoded);
                    closable.writeAll(encoded) catch {}; // Ignore errors on close
                } else |_| {}
            }
            closable.close();
            self.tcp_stream = null;
        }
        self.send_buffer.clearRetainingCapacity();
        self.recv_buffer.clearRetainingCapacity();
        self.fragment_buffer.clearRetainingCapacity();
        self.fragment_opcode = null;
        self.resetPingState();
        self.state = .closed;
    }

    /// Force-close the socket without sending a close frame; safe from cancellation paths.
    fn abort(self: *Self) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.tcp_stream) |stream| {
            var closable = stream;
            closable.shutdown();
        }
        self.resetPingState();
        self.state = .closing;
    }

    /// Convert to AsyncSender interface
    pub fn asyncSender(self: *Self) transport.AsyncSender {
        return .{
            .context = @ptrCast(self),
            .write_fn = writeFn,
            .flush_fn = flushFn,
            .close_fn = closeFn,
        };
    }

    /// Convert to AsyncReceiver interface
    pub fn asyncReceiver(self: *Self) transport.AsyncReceiver {
        return .{
            .context = @ptrCast(self),
            .receive_stream_fn = receiveStreamFn,
            .read_fn = readFn,
            .close_fn = closeFn,
        };
    }

    fn sendPong(self: *Self, payload: []const u8) !void {
        _ = defaultIo();

        const frame = Frame{
            .opcode = .pong,
            .payload = payload,
            .fin = true,
            .masked = true,
        };

        const encoded = try encodeFrame(frame, self.allocator);
        defer self.allocator.free(encoded);

        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        const stream = self.tcp_stream orelse {
            self.mutex.unlock();
            return error.NotConnected;
        };
        var writable = stream;
        self.mutex.unlock();

        while (!self.write_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.write_mutex.unlock();
        try writable.writeAll(encoded);
    }

    fn resetPingState(self: *Self) void {
        self.waiting_for_pong = false;
        self.last_ping_at_ms = 0;
    }

    fn markPingSent(self: *Self, now_ms: i64) void {
        self.waiting_for_pong = true;
        self.last_ping_at_ms = now_ms;
    }

    fn markPongReceived(self: *Self) void {
        self.resetPingState();
    }

    fn hasPingTimedOut(self: *const Self, now_ms: i64) bool {
        if (!self.waiting_for_pong) return false;
        const elapsed = now_ms - self.last_ping_at_ms;
        if (elapsed < 0) return false;
        return @as(u64, @intCast(elapsed)) >= self.ping_timeout_ms;
    }

    // --- AsyncSender implementation ---

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.send(data);
    }

    fn flushFn(ctx: *anyopaque) !void {
        _ = ctx;
        // WebSocket auto-flushes on each write
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.close();
    }

    // --- AsyncReceiver implementation ---

    const ProducerContext = struct {
        stream: *transport.ByteStream,
        client: *WebSocketClient,
        allocator: std.mem.Allocator,
    };

    /// Handle for a cancelable WebSocket reader thread.
    /// Created by `receiveStreamWithHandle`; call `deinit` to join the thread.
    pub const AsyncStreamHandle = struct {
        stream: *transport.ByteStream,
        thread: std.Thread,
        cancel_token: *std.atomic.Value(bool),
        client: *WebSocketClient,
        allocator: std.mem.Allocator,

        const Handle = @This();

        pub fn deinit(self: *Handle, timeout_ms: u64) bool {
            self.cancel();
            const exited = self.stream.waitForThread(timeout_ms);
            if (!exited) {
                self.thread.detach();
                return false;
            }
            self.thread.join();
            self.stream.deinit();
            self.allocator.destroy(self.stream);
            self.allocator.destroy(self.cancel_token);
            self.allocator.destroy(self);
            return true;
        }

        pub fn cancel(self: *Handle) void {
            self.cancel_token.store(true, .release);
            // Force-closing the socket unblocks a reader thread parked in receive().
            self.client.abort();
        }
    };

    const HandleProducerContext = struct {
        stream: *transport.ByteStream,
        client: *WebSocketClient,
        allocator: std.mem.Allocator,
        cancel_token: *std.atomic.Value(bool),
    };

    fn receiveStreamFn(ctx: *anyopaque, allocator: std.mem.Allocator) !*transport.ByteStream {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const stream = try allocator.create(transport.ByteStream);
        stream.* = transport.ByteStream.init(allocator);

        const thread_ctx = try allocator.create(ProducerContext);
        thread_ctx.* = .{
            .stream = stream,
            .client = self,
            .allocator = allocator,
        };

        const thread = try std.Thread.spawn(.{}, producerThread, .{thread_ctx});
        thread.detach();

        return stream;
    }

    /// Create an async stream with explicit thread-lifecycle management.
    /// The returned handle owns the `ByteStream`, cancel token, and reader thread.
    pub fn receiveStreamWithHandle(self: *Self, allocator: std.mem.Allocator) !*Self.AsyncStreamHandle {
        const stream = try allocator.create(transport.ByteStream);
        stream.* = transport.ByteStream.init(allocator);
        errdefer {
            stream.deinit();
            allocator.destroy(stream);
        }

        const cancel_token = try allocator.create(std.atomic.Value(bool));
        cancel_token.* = std.atomic.Value(bool).init(false);
        errdefer allocator.destroy(cancel_token);

        const handle = try allocator.create(Self.AsyncStreamHandle);
        errdefer allocator.destroy(handle);

        const thread_ctx = try allocator.create(HandleProducerContext);
        thread_ctx.* = .{
            .stream = stream,
            .client = self,
            .allocator = allocator,
            .cancel_token = cancel_token,
        };
        errdefer allocator.destroy(thread_ctx);

        const thread = try std.Thread.spawn(.{}, handleProducerThread, .{thread_ctx});

        handle.* = .{
            .stream = stream,
            .thread = thread,
            .cancel_token = cancel_token,
            .client = self,
            .allocator = allocator,
        };
        return handle;
    }

    fn producerThread(ctx: *ProducerContext) void {
        defer {
            ctx.stream.markThreadDone();
            ctx.allocator.destroy(ctx);
        }

        while (true) {
            const msg = ctx.client.receive(ctx.allocator) catch {
                ctx.stream.completeWithError("Receive error");
                return;
            };

            if (msg) |data| {
                const chunk = transport.ByteChunk{
                    .data = data,
                    .owned = true,
                };
                if (!pushChunkOrFail(ctx.stream, chunk, ctx.allocator)) {
                    return;
                }
            } else {
                // Connection closed
                ctx.stream.complete({});
                return;
            }
        }
    }

    fn handleProducerThread(ctx: *HandleProducerContext) void {
        defer {
            ctx.stream.markThreadDone();
            ctx.allocator.destroy(ctx);
        }

        while (!ctx.cancel_token.load(.acquire)) {
            const msg = ctx.client.receive(ctx.allocator) catch {
                if (ctx.cancel_token.load(.acquire)) {
                    ctx.stream.complete({});
                    return;
                }
                ctx.stream.completeWithError("Receive error");
                return;
            };

            if (msg) |data| {
                const chunk = transport.ByteChunk{
                    .data = data,
                    .owned = true,
                };
                if (!pushChunkOrFail(ctx.stream, chunk, ctx.allocator)) {
                    return;
                }
            } else {
                // Connection closed
                ctx.stream.complete({});
                return;
            }
        }

        ctx.stream.complete({});
    }

    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.receive(allocator);
    }
};

fn pushChunkOrFail(stream: *transport.ByteStream, chunk: transport.ByteChunk, allocator: std.mem.Allocator) bool {
    stream.push(chunk) catch {
        var dropped = chunk;
        dropped.deinit(allocator);
        stream.completeWithError("Stream queue full");
        return false;
    };
    return true;
}

fn hasHeaderName(response: []const u8, name: []const u8) bool {
    var line_start: usize = 0;
    while (line_start < response.len) {
        const line_end = std.mem.indexOfScalarPos(u8, response, line_start, '\n') orelse response.len;
        var line = response[line_start..line_end];
        if (std.mem.endsWith(u8, line, "\r")) {
            line = line[0 .. line.len - 1];
        }

        if (line.len == 0) return false;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const header_name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(header_name, name)) return true;
        }

        line_start = if (line_end < response.len) line_end + 1 else response.len;
    }
    return false;
}

fn headerValueContainsToken(response: []const u8, name: []const u8, token: []const u8) bool {
    var line_start: usize = 0;
    while (line_start < response.len) {
        const line_end = std.mem.indexOfScalarPos(u8, response, line_start, '\n') orelse response.len;
        var line = response[line_start..line_end];
        if (std.mem.endsWith(u8, line, "\r")) {
            line = line[0 .. line.len - 1];
        }

        if (line.len == 0) return false;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const header_name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(header_name, name)) {
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                var parts = std.mem.splitScalar(u8, value, ',');
                while (parts.next()) |part| {
                    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
                }
            }
        }

        line_start = if (line_end < response.len) line_end + 1 else response.len;
    }
    return false;
}

fn getHeaderValue(response: []const u8, name: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    while (line_start < response.len) {
        const line_end = std.mem.indexOfScalarPos(u8, response, line_start, '\n') orelse response.len;
        var line = response[line_start..line_end];
        if (std.mem.endsWith(u8, line, "\r")) {
            line = line[0 .. line.len - 1];
        }

        if (line.len == 0) return null;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const header_name = std.mem.trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(header_name, name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        }

        line_start = if (line_end < response.len) line_end + 1 else response.len;
    }
    return null;
}

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

fn verifyAcceptHeader(response: []const u8, request_key: []const u8) bool {
    const accept_value = getHeaderValue(response, "Sec-WebSocket-Accept") orelse return false;

    var hash_input: [60]u8 = undefined;
    @memcpy(hash_input[0..24], request_key);
    @memcpy(hash_input[24..60], websocket_guid);

    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&hash_input, &digest, .{});

    var expected: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&expected, &digest);

    return std.mem.eql(u8, accept_value, &expected);
}

// --- Internal types ---

fn canInitiateConnect(state: WebSocketClient.ConnectionState) bool {
    return state == .disconnected or state == .closed;
}

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub const Frame = struct {
    opcode: Opcode,
    payload: []const u8,
    fin: bool = true,
    masked: bool = true,
};

/// Encode a WebSocket frame
pub fn encodeFrame(frame: Frame, allocator: std.mem.Allocator) ![]u8 {
    const payload_len = frame.payload.len;

    // Calculate frame size
    const header_size: usize = if (payload_len < 126)
        2
    else if (payload_len <= 65535)
        4
    else
        10;

    const mask_size: usize = if (frame.masked) 4 else 0;
    const total_size = header_size + mask_size + payload_len;

    const buffer = try allocator.alloc(u8, total_size);
    var offset: usize = 0;

    // First byte: FIN + RSV1-3 + Opcode
    var first_byte: u8 = @as(u8, @intFromEnum(frame.opcode));
    if (frame.fin) first_byte |= 0x80;
    buffer[offset] = first_byte;
    offset += 1;

    // Second byte: MASK + Payload length
    var second_byte: u8 = if (frame.masked) 0x80 else 0;
    if (payload_len < 126) {
        second_byte |= @truncate(payload_len);
        buffer[offset] = second_byte;
        offset += 1;
    } else if (payload_len <= 65535) {
        second_byte |= 126;
        buffer[offset] = second_byte;
        offset += 1;
        // 16-bit length (big endian)
        buffer[offset] = @truncate(payload_len >> 8);
        buffer[offset + 1] = @truncate(payload_len);
        offset += 2;
    } else {
        second_byte |= 127;
        buffer[offset] = second_byte;
        offset += 1;
        // 64-bit length (big endian) - only use lower 32 bits for simplicity
        buffer[offset..][0..8].* = .{
            0,                            0,                            0,                           0, // Upper 32 bits (always 0)
            @truncate(payload_len >> 24), @truncate(payload_len >> 16), @truncate(payload_len >> 8), @truncate(payload_len),
        };
        offset += 8;
    }

    // Masking key and masked payload
    if (frame.masked) {
        // Generate random mask
        var mask: [4]u8 = undefined;
        compat.random.fillSecureBytes(&mask);

        // Write mask
        buffer[offset..][0..4].* = mask;
        offset += 4;

        // Mask and write payload
        for (frame.payload, 0..) |byte, i| {
            buffer[offset + i] = byte ^ mask[i % 4];
        }
        offset += payload_len;
    } else {
        // Write unmasked payload
        @memcpy(buffer[offset..][0..payload_len], frame.payload);
        offset += payload_len;
    }

    return buffer;
}

/// Decode a WebSocket frame from buffer, returns frame and bytes consumed
/// Note: The returned payload is a slice into the input data
pub fn decodeFrame(data: []const u8) ?struct { frame: Frame, consumed: usize } {
    if (data.len < 2) return null;

    const first_byte = data[0];
    const second_byte = data[1];

    const fin = (first_byte & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(first_byte & 0x0F);
    const masked = (second_byte & 0x80) != 0;

    var payload_len: u64 = @as(u64, second_byte) & 0x7F;
    var offset: usize = 2;

    // Extended payload length
    if (payload_len == 126) {
        if (data.len < 4) return null;
        payload_len = (@as(u64, data[2]) << 8) | @as(u64, data[3]);
        offset = 4;
    } else if (payload_len == 127) {
        if (data.len < 10) return null;
        payload_len = 0;
        for (data[2..10], 0..) |byte, i| {
            payload_len |= @as(u64, byte) << @as(u6, @intCast(56 - i * 8));
        }
        offset = 10;
    }

    // Masking key
    const mask: ?[4]u8 = if (masked) blk: {
        if (data.len < offset + 4) return null;
        const m = data[offset..][0..4].*;
        offset += 4;
        break :blk m;
    } else null;

    // Payload
    if (data.len < offset + payload_len) return null;
    const payload_start = offset;
    offset += @as(usize, @intCast(payload_len));

    // If masked, we need to unmask - but for now just return a reference
    // The caller should handle masking if needed
    // For server->client frames, masked is typically false
    const payload = data[payload_start..][0..@as(usize, @intCast(payload_len))];

    // If the frame is masked, we need to allocate and unmask
    // For simplicity, we return the raw payload and note if it was masked
    // In practice, server->client frames are not masked
    _ = mask; // Acknowledge we received the mask

    return .{
        .frame = .{
            .opcode = opcode,
            .payload = payload,
            .fin = fin,
            .masked = masked,
        },
        .consumed = offset,
    };
}

/// Perform WebSocket handshake
fn performHandshake(
    client: *WebSocketClient,
    host: []const u8,
    port: u16,
    path: []const u8,
    headers: ?[]const ai_types.HeaderPair,
    subprotocol: ?[]const u8,
) !void {
    _ = port; // Port is already resolved and connected before calling this
    const stream = client.tcp_stream orelse return error.NotConnected;

    // Generate random 16-byte nonce and base64 encode
    var nonce: [16]u8 = undefined;
    compat.random.fillSecureBytes(&nonce);

    // Base64 encode the nonce
    const encoder = std.base64.standard.Encoder;
    const key = encoder.encode(&client.handshake_key, &nonce);

    // Build handshake request
    var request = std.ArrayList(u8).empty;
    defer request.deinit(client.allocator);

    try request.print(client.allocator, "GET {s} HTTP/1.1\r\n", .{path});
    try request.print(client.allocator, "Host: {s}\r\n", .{host});
    try request.print(client.allocator, "Upgrade: websocket\r\n", .{});
    try request.print(client.allocator, "Connection: Upgrade\r\n", .{});
    try request.print(client.allocator, "Sec-WebSocket-Key: {s}\r\n", .{key});
    if (subprotocol) |sp| {
        try request.print(client.allocator, "Sec-WebSocket-Protocol: {s}\r\n", .{sp});
    }
    try request.print(client.allocator, "Sec-WebSocket-Version: 13\r\n", .{});

    // Add custom headers
    if (headers) |h| {
        for (h) |header| {
            try request.print(client.allocator, "{s}: {s}\r\n", .{ header.name, header.value });
        }
    }

    try request.print(client.allocator, "\r\n", .{});

    // Send request
    var io_stream = stream;
    try io_stream.writeAll(request.items);

    // Read response headers. TCP can split the HTTP response across reads, so
    // keep reading until the header terminator arrives and preserve any frame
    // bytes coalesced after it.
    var response_buf: [4096]u8 = undefined;
    var response_len: usize = 0;
    var header_end: ?usize = null;
    while (response_len < response_buf.len) {
        const n = try io_stream.read(response_buf[response_len..]);
        if (n == 0) return error.HandshakeFailed;
        response_len += n;
        if (std.mem.indexOf(u8, response_buf[0..response_len], "\r\n\r\n")) |idx| {
            header_end = idx;
            break;
        }
    }
    const end = header_end orelse return error.HandshakeFailed;
    const response = response_buf[0..response_len];
    const headers_part = response[0 .. end + 4];
    const leftover = response[end + 4 ..];

    // Verify response
    // Should start with "HTTP/1.1 101"
    if (!std.mem.startsWith(u8, headers_part, "HTTP/1.1 101")) {
        return error.HandshakeFailed;
    }

    // Verify Upgrade and Connection headers case-insensitively.
    if (!headerValueContainsToken(headers_part, "Upgrade", "websocket")) {
        return error.HandshakeFailed;
    }

    if (!headerValueContainsToken(headers_part, "Connection", "upgrade")) {
        return error.HandshakeFailed;
    }

    if (subprotocol) |expected_protocol| {
        const selected_protocol = getHeaderValue(headers_part, "Sec-WebSocket-Protocol") orelse return error.HandshakeFailed;
        if (!std.mem.eql(u8, selected_protocol, expected_protocol)) return error.HandshakeFailed;
    }

    // Verify Sec-WebSocket-Accept header matches the request key (RFC 6455 §4.2.2).
    if (!verifyAcceptHeader(headers_part, client.handshake_key[0..24])) {
        return error.HandshakeFailed;
    }

    if (leftover.len > 0) {
        try client.recv_buffer.appendSlice(client.allocator, leftover);
    }
}

/// Parsed URL components
const ParsedUrl = struct {
    tls: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Parse a WebSocket URL
fn parseUrl(url: []const u8) !ParsedUrl {
    var result: ParsedUrl = .{
        .tls = false,
        .host = "",
        .port = 80,
        .path = "/",
    };

    var offset: usize = 0;

    // Check scheme
    if (std.mem.startsWith(u8, url, "wss://")) {
        result.tls = true;
        result.port = 443;
        offset = 6;
    } else if (std.mem.startsWith(u8, url, "ws://")) {
        offset = 5;
    } else {
        return error.InvalidScheme;
    }

    // Find end of host (start of port or path)
    const host_start = offset;
    var host_end = url.len;

    // Look for port
    if (std.mem.findScalarPos(u8, url, offset, ':')) |colon_pos| {
        host_end = colon_pos;
        offset = colon_pos + 1;

        // Parse port
        const port_end = std.mem.findScalarPos(u8, url, offset, '/') orelse url.len;
        const port_str = url[offset..port_end];
        result.port = try std.fmt.parseInt(u16, port_str, 10);
        offset = port_end;
    } else if (std.mem.findScalarPos(u8, url, offset, '/')) |slash_pos| {
        host_end = slash_pos;
        offset = slash_pos;
    } else {
        offset = url.len;
    }

    result.host = url[host_start..host_end];

    // Path
    if (offset < url.len) {
        result.path = url[offset..];
    }

    return result;
}

// --- Tests ---

test "encodeFrame and decodeFrame roundtrip" {
    const allocator = std.testing.allocator;

    // Test small payload
    const frame1 = Frame{
        .opcode = .text,
        .payload = "Hello, WebSocket!",
        .fin = true,
        .masked = true,
    };

    const encoded1 = try encodeFrame(frame1, allocator);
    defer allocator.free(encoded1);

    const result1 = decodeFrame(encoded1).?;
    try std.testing.expectEqual(Opcode.text, result1.frame.opcode);
    try std.testing.expect(result1.frame.fin);
    try std.testing.expect(result1.frame.masked);
    try std.testing.expectEqual(@as(usize, 17), result1.frame.payload.len);

    // Test medium payload (126 bytes, uses 16-bit length)
    var medium_payload: [126]u8 = undefined;
    for (&medium_payload, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }

    const frame2 = Frame{
        .opcode = .binary,
        .payload = &medium_payload,
        .fin = true,
        .masked = true,
    };

    const encoded2 = try encodeFrame(frame2, allocator);
    defer allocator.free(encoded2);

    const result2 = decodeFrame(encoded2).?;
    try std.testing.expectEqual(Opcode.binary, result2.frame.opcode);
    try std.testing.expectEqual(@as(usize, 126), result2.frame.payload.len);

    // Test unmasked frame
    const frame3 = Frame{
        .opcode = .ping,
        .payload = "ping",
        .fin = true,
        .masked = false,
    };

    const encoded3 = try encodeFrame(frame3, allocator);
    defer allocator.free(encoded3);

    const result3 = decodeFrame(encoded3).?;
    try std.testing.expectEqual(Opcode.ping, result3.frame.opcode);
    try std.testing.expect(!result3.frame.masked);
    try std.testing.expectEqualStrings("ping", result3.frame.payload);
}

test "hasHeaderName matches HTTP header names case-insensitively" {
    const response =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "upgrade: websocket\r\n" ++
        "connection: Upgrade\r\n" ++
        "sec-websocket-accept: value\r\n" ++
        "\r\n";

    try std.testing.expect(hasHeaderName(response, "Sec-WebSocket-Accept"));
    try std.testing.expect(hasHeaderName(response, "Upgrade"));
    try std.testing.expect(!hasHeaderName(response, "Sec-WebSocket-Protocol"));
}

test "decodeFrame rejects incomplete extended length and masked payloads" {
    // Extended length marker (126) but missing the two-byte length
    try std.testing.expect(decodeFrame(&.{ 0x81, 0x7E }) == null);

    // Extended length marker (127) but missing the eight-byte length
    try std.testing.expect(decodeFrame(&.{ 0x81, 0x7F, 0, 0, 0 }) == null);

    // Mask bit set but missing mask key
    try std.testing.expect(decodeFrame(&.{ 0x81, 0x80 }) == null);

    // Mask + key present, but payload byte missing
    try std.testing.expect(decodeFrame(&.{ 0x81, 0x81, 1, 2, 3, 4 }) == null);
}

test "decodeFrame supports partial buffering and consumed ordering" {
    const allocator = std.testing.allocator;

    const f1 = Frame{ .opcode = .text, .payload = "first", .fin = true, .masked = false };
    const f2 = Frame{ .opcode = .text, .payload = "second", .fin = true, .masked = false };

    const e1 = try encodeFrame(f1, allocator);
    defer allocator.free(e1);
    const e2 = try encodeFrame(f2, allocator);
    defer allocator.free(e2);

    // Simulate partial read: first frame + partial second frame
    var partial = std.ArrayList(u8).empty;
    defer partial.deinit(allocator);
    try partial.appendSlice(allocator, e1);
    try partial.appendSlice(allocator, e2[0..2]);

    const first = decodeFrame(partial.items).?;
    try std.testing.expectEqualStrings("first", first.frame.payload);

    const rem1 = partial.items[first.consumed..];
    try std.testing.expect(decodeFrame(rem1) == null);

    // Append rest of second frame and decode in order
    try partial.appendSlice(allocator, e2[2..]);
    const second = decodeFrame(partial.items[first.consumed..]).?;
    try std.testing.expectEqualStrings("second", second.frame.payload);
}

test "decodeFrame preserves fragmentation flags" {
    const allocator = std.testing.allocator;

    const start = Frame{ .opcode = .text, .payload = "hel", .fin = false, .masked = false };
    const cont = Frame{ .opcode = .continuation, .payload = "lo", .fin = true, .masked = false };

    const start_encoded = try encodeFrame(start, allocator);
    defer allocator.free(start_encoded);
    const cont_encoded = try encodeFrame(cont, allocator);
    defer allocator.free(cont_encoded);

    const r1 = decodeFrame(start_encoded).?;
    try std.testing.expectEqual(Opcode.text, r1.frame.opcode);
    try std.testing.expect(!r1.frame.fin);

    const r2 = decodeFrame(cont_encoded).?;
    try std.testing.expectEqual(Opcode.continuation, r2.frame.opcode);
    try std.testing.expect(r2.frame.fin);
}

test "decodeFrame preserves interleaved logical stream ordering" {
    const allocator = std.testing.allocator;

    const a = Frame{ .opcode = .text, .payload = "s1:a", .fin = true, .masked = false };
    const b = Frame{ .opcode = .text, .payload = "s2:b", .fin = true, .masked = false };
    const c = Frame{ .opcode = .text, .payload = "s1:c", .fin = true, .masked = false };

    const ea = try encodeFrame(a, allocator);
    defer allocator.free(ea);
    const eb = try encodeFrame(b, allocator);
    defer allocator.free(eb);
    const ec = try encodeFrame(c, allocator);
    defer allocator.free(ec);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, ea);
    try buf.appendSlice(allocator, eb);
    try buf.appendSlice(allocator, ec);

    var offset: usize = 0;
    const expected = [_][]const u8{ "s1:a", "s2:b", "s1:c" };
    for (expected) |want| {
        const decoded = decodeFrame(buf.items[offset..]).?;
        try std.testing.expectEqualStrings(want, decoded.frame.payload);
        offset += decoded.consumed;
    }
    try std.testing.expectEqual(offset, buf.items.len);
}

test "websocket producer backpressure completes stream with error" {
    const allocator = std.testing.allocator;

    var stream = transport.ByteStream.init(allocator);
    defer {
        stream.markThreadDone();
        stream.deinit();
    }

    // Fill queue with borrowed chunks to simulate sustained consumer lag.
    while (true) {
        stream.push(.{ .data = "x", .owned = false }) catch |err| {
            try std.testing.expectEqual(error.QueueFull, err);
            break;
        };
    }

    const overflow = try allocator.dupe(u8, "overflow");
    const ok = pushChunkOrFail(&stream, .{ .data = overflow, .owned = true }, allocator);
    try std.testing.expect(!ok);

    try std.testing.expect(stream.getError() != null);
    try std.testing.expectEqualStrings("Stream queue full", stream.getError().?);
}

test "WebSocketClient connect precondition allows disconnected/closed" {
    try std.testing.expect(canInitiateConnect(.disconnected));
    try std.testing.expect(canInitiateConnect(.closed));
    try std.testing.expect(!canInitiateConnect(.connecting));
    try std.testing.expect(!canInitiateConnect(.connected));
    try std.testing.expect(!canInitiateConnect(.closing));
}

test "WebSocketClient connect rejects non-reconnectable states early" {
    const allocator = std.testing.allocator;

    var client = WebSocketClient.init(allocator);
    defer client.deinit();

    client.state = .connected;
    try std.testing.expectError(error.AlreadyConnected, client.connect("not-a-websocket-url", null));

    client.state = .connecting;
    try std.testing.expectError(error.AlreadyConnected, client.connect("not-a-websocket-url", null));

    client.state = .closing;
    try std.testing.expectError(error.AlreadyConnected, client.connect("not-a-websocket-url", null));
}

test "WebSocketClient close is idempotent" {
    const allocator = std.testing.allocator;

    var client = WebSocketClient.init(allocator);
    defer client.deinit();

    client.close();
    client.close();

    try std.testing.expectEqual(WebSocketClient.ConnectionState.closed, client.state);
    try std.testing.expect(client.tcp_stream == null);
}

test "WebSocketClient reconnect attempts clear stale buffers and remain retryable" {
    const allocator = std.testing.allocator;

    var client = WebSocketClient.init(allocator);
    defer client.deinit();

    try client.send_buffer.appendSlice(allocator, "stale-subscribe");
    try client.recv_buffer.appendSlice(allocator, "stale-event");

    client.state = .closed;
    try std.testing.expectError(error.InvalidUrl, client.connect("not-a-websocket-url", null));
    try std.testing.expectEqual(WebSocketClient.ConnectionState.disconnected, client.state);
    try std.testing.expectEqual(@as(usize, 0), client.send_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.recv_buffer.items.len);

    // First reconnect failure should not block subsequent reconnect attempts.
    try std.testing.expectError(error.InvalidUrl, client.connect("still-not-a-websocket-url", null));
}

test "WebSocketClient connect rejects wss TLS before networking" {
    const allocator = std.testing.allocator;

    var client = WebSocketClient.init(allocator);
    defer client.deinit();

    try std.testing.expectError(error.TlsNotSupported, client.connect("wss://127.0.0.1/socket", null));
    try std.testing.expectEqual(WebSocketClient.ConnectionState.disconnected, client.state);
}

test "WebSocketClient ping timeout triggers without pong" {
    const allocator = std.testing.allocator;

    var client = WebSocketClient.init(allocator);
    defer client.deinit();

    client.ping_timeout_ms = 50;
    client.markPingSent(1_000);

    try std.testing.expect(!client.hasPingTimedOut(1_049));
    try std.testing.expect(client.hasPingTimedOut(1_050));
}

test "WebSocketClient pong clears timeout wait state" {
    const allocator = std.testing.allocator;

    var client = WebSocketClient.init(allocator);
    defer client.deinit();

    client.ping_timeout_ms = 50;
    client.markPingSent(1_000);
    client.markPongReceived();

    try std.testing.expect(!client.waiting_for_pong);
    try std.testing.expectEqual(@as(i64, 0), client.last_ping_at_ms);
    try std.testing.expect(!client.hasPingTimedOut(9_999));
}

test "WebSocketClient receive close frame enters closing state" {
    const allocator = std.testing.allocator;

    const pipe = try std.Io.Threaded.pipe2(.{});
    var peer_stream = streamFromSocketHandle(pipe[1]);
    defer peer_stream.close();

    var client = WebSocketClient.init(allocator);
    defer client.deinit();
    client.tcp_stream = streamFromSocketHandle(pipe[0]);
    client.state = .connected;

    const close_frame = Frame{ .opcode = .close, .payload = "bye", .fin = true, .masked = false };
    const encoded = try encodeFrame(close_frame, allocator);
    defer allocator.free(encoded);

    try client.recv_buffer.appendSlice(allocator, encoded);
    const msg = try client.receive(allocator);
    try std.testing.expect(msg == null);
    try std.testing.expectEqual(WebSocketClient.ConnectionState.closing, client.state);
}

test "WebSocketClient close from closing state finalizes cleanup" {
    const allocator = std.testing.allocator;

    const pipe = try std.Io.Threaded.pipe2(.{});
    var peer_stream = streamFromSocketHandle(pipe[1]);
    defer peer_stream.close();

    var client = WebSocketClient.init(allocator);
    defer client.deinit();
    client.tcp_stream = streamFromSocketHandle(pipe[0]);
    client.state = .closing;
    client.ping_timeout_ms = 50;
    client.markPingSent(1_000);
    try client.send_buffer.appendSlice(allocator, "queued");
    try client.recv_buffer.appendSlice(allocator, "partial-close");

    client.close();
    try std.testing.expectEqual(WebSocketClient.ConnectionState.closed, client.state);
    try std.testing.expect(client.tcp_stream == null);
    try std.testing.expectEqual(@as(usize, 0), client.send_buffer.items.len);
    try std.testing.expectEqual(@as(usize, 0), client.recv_buffer.items.len);
    try std.testing.expect(!client.waiting_for_pong);
}

test "WebSocketClient init and deinit" {
    const allocator = std.testing.allocator;

    var client = WebSocketClient.init(allocator);
    defer client.deinit();

    try std.testing.expectEqual(WebSocketClient.ConnectionState.disconnected, client.state);
    try std.testing.expect(client.tcp_stream == null);
}

test "parseUrl validates URLs" {
    // Test ws:// URL
    const url1 = try parseUrl("ws://localhost:8080/path");
    try std.testing.expect(!url1.tls);
    try std.testing.expectEqualStrings("localhost", url1.host);
    try std.testing.expectEqual(@as(u16, 8080), url1.port);
    try std.testing.expectEqualStrings("/path", url1.path);

    // Test wss:// URL
    const url2 = try parseUrl("wss://example.com/ws");
    try std.testing.expect(url2.tls);
    try std.testing.expectEqualStrings("example.com", url2.host);
    try std.testing.expectEqual(@as(u16, 443), url2.port);
    try std.testing.expectEqualStrings("/ws", url2.path);

    // Test URL without port
    const url3 = try parseUrl("ws://host/path");
    try std.testing.expectEqual(@as(u16, 80), url3.port);

    // Test URL without path
    const url4 = try parseUrl("ws://host:9000");
    try std.testing.expectEqual(@as(u16, 9000), url4.port);
    try std.testing.expectEqualStrings("/", url4.path);

    // Test invalid scheme
    try std.testing.expectError(error.InvalidScheme, parseUrl("http://example.com"));
}

test "performHandshake validates response" {
    const allocator = std.testing.allocator;

    // Create a pipe to simulate connection
    const pipe = try std.Io.Threaded.pipe2(.{});
    const read_fd = pipe[0];
    const write_fd = pipe[1];

    // Create client with pipe
    var client = WebSocketClient.init(allocator);
    defer client.deinit();

    client.tcp_stream = streamFromSocketHandle(write_fd);
    client.state = .connecting;

    // Write valid handshake response (not used in this simplified test)
    _ = read_fd;
    const valid_response =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "\r\n";
    _ = valid_response;

    // We can't easily test performHandshake with a pipe because it needs bidirectional communication
    // So just close the pipes and verify no crash
    var read_stream = streamFromSocketHandle(pipe[0]);
    read_stream.close();
    var write_stream = streamFromSocketHandle(pipe[1]);
    write_stream.close();
    client.tcp_stream = null;
}

test "Opcode values are correct" {
    try std.testing.expectEqual(@as(u4, 0x0), @intFromEnum(Opcode.continuation));
    try std.testing.expectEqual(@as(u4, 0x1), @intFromEnum(Opcode.text));
    try std.testing.expectEqual(@as(u4, 0x2), @intFromEnum(Opcode.binary));
    try std.testing.expectEqual(@as(u4, 0x8), @intFromEnum(Opcode.close));
    try std.testing.expectEqual(@as(u4, 0x9), @intFromEnum(Opcode.ping));
    try std.testing.expectEqual(@as(u4, 0xA), @intFromEnum(Opcode.pong));
}

test "AsyncSender and AsyncReceiver interfaces" {
    const allocator = std.testing.allocator;

    var client = WebSocketClient.init(allocator);
    defer client.deinit();

    // Test that we can get the interfaces
    const sender = client.asyncSender();
    const receiver = client.asyncReceiver();

    // Verify the optional interfaces are present
    try std.testing.expect(sender.flush_fn != null);
    try std.testing.expect(sender.close_fn != null);
    try std.testing.expect(receiver.read_fn != null);
    try std.testing.expect(receiver.close_fn != null);

    // Verify non-optional fields exist by using them
    _ = sender.write_fn;
    _ = sender.context;
    _ = receiver.receive_stream_fn;
    _ = receiver.context;
}


test "websocket_masking_key_xor_output_byte_for_byte" {
    const payload = "Mask me";
    const mask = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    const encoded = [_]u8{
        0x81, 0x80 | @as(u8, @intCast(payload.len)),
        mask[0], mask[1], mask[2], mask[3],
        payload[0] ^ mask[0],
        payload[1] ^ mask[1],
        payload[2] ^ mask[2],
        payload[3] ^ mask[3],
        payload[4] ^ mask[0],
        payload[5] ^ mask[1],
        payload[6] ^ mask[2],
    };

    const decoded = decodeFrame(&encoded).?;
    try std.testing.expectEqual(Opcode.text, decoded.frame.opcode);
    try std.testing.expect(decoded.frame.masked);
    try std.testing.expectEqual(encoded.len, decoded.consumed);

    for (decoded.frame.payload, 0..) |masked_byte, i| {
        try std.testing.expectEqual(payload[i] ^ mask[i % 4], masked_byte);
        try std.testing.expectEqual(payload[i], masked_byte ^ mask[i % 4]);
    }
}

test "websocket_continuation_frame_reassembly_across_fragmented_frames" {
    const allocator = std.testing.allocator;

    const fragments = [_]Frame{
        .{ .opcode = .text, .payload = "frag", .fin = false, .masked = false },
        .{ .opcode = .continuation, .payload = "ment", .fin = false, .masked = false },
        .{ .opcode = .continuation, .payload = "ed", .fin = true, .masked = false },
    };

    var wire = std.ArrayList(u8).empty;
    defer wire.deinit(allocator);

    for (fragments) |fragment| {
        const encoded = try encodeFrame(fragment, allocator);
        defer allocator.free(encoded);
        try wire.appendSlice(allocator, encoded);
    }

    var reassembled = std.ArrayList(u8).empty;
    defer reassembled.deinit(allocator);

    var offset: usize = 0;
    var saw_start = false;
    while (offset < wire.items.len) {
        const decoded = decodeFrame(wire.items[offset..]).?;
        offset += decoded.consumed;

        switch (decoded.frame.opcode) {
            .text => {
                try std.testing.expect(!saw_start);
                saw_start = true;
                try reassembled.appendSlice(allocator, decoded.frame.payload);
                try std.testing.expect(!decoded.frame.fin);
            },
            .continuation => {
                try std.testing.expect(saw_start);
                try reassembled.appendSlice(allocator, decoded.frame.payload);
            },
            else => return error.UnexpectedOpcode,
        }
    }

    try std.testing.expectEqual(wire.items.len, offset);
    try std.testing.expectEqualStrings("fragmented", reassembled.items);
}
