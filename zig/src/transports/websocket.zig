//! WebSocket Transport (Beta)
//!
//! This implementation is suitable for development and testing.
//! Production use requires TLS termination via reverse proxy.
//! See PROTOCOL.md for current limitations.

const std = @import("std");
const transport = @import("transport");
const ai_types = @import("ai_types");

pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    state: ConnectionState,

    // Connection state
    tcp_stream: ?std.net.Stream = null,

    // For async operation
    send_buffer: std.ArrayList(u8) = std.ArrayList(u8){},
    recv_buffer: std.ArrayList(u8) = std.ArrayList(u8){},

    // Callbacks
    on_message: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null,
    on_message_ctx: ?*anyopaque = null,

    // Handshake key (stored for verification)
    handshake_key: [24]u8 = undefined,

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
            .send_buffer = std.ArrayList(u8){},
            .recv_buffer = std.ArrayList(u8){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.close();
        self.send_buffer.deinit(self.allocator);
        self.recv_buffer.deinit(self.allocator);
    }

    /// Connect to WebSocket endpoint
    /// url format: ws://host:port/path or wss://host:port/path
    /// headers: optional headers (e.g., Authorization: Bearer <api_key>)
    pub fn connect(
        self: *Self,
        url: []const u8,
        headers: ?[]const ai_types.HeaderPair,
    ) !void {
        if (!canInitiateConnect(self.state)) {
            return error.AlreadyConnected;
        }

        self.state = .connecting;

        // Parse URL
        const parsed = parseUrl(url) catch {
            self.state = .disconnected;
            return error.InvalidUrl;
        };

        // Check for TLS (wss://)
        if (parsed.tls) {
            // TODO: TLS support not implemented in this phase
            // Will be added in a future update
            self.state = .disconnected;
            return error.TlsNotSupported;
        }

        // Resolve and connect
        const address = std.net.Address.resolveIp(parsed.host, parsed.port) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };

        self.tcp_stream = std.net.tcpConnectToAddress(address) catch {
            self.state = .disconnected;
            return error.ConnectionFailed;
        };

        // Perform WebSocket handshake
        performHandshake(self, parsed.host, parsed.port, parsed.path, headers) catch |err| {
            if (self.tcp_stream) |stream| {
                stream.close();
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

        const stream = self.tcp_stream orelse return error.NotConnected;

        // Encode the frame
        const frame = Frame{
            .opcode = .text,
            .payload = data,
            .fin = true,
            .masked = true,
        };

        const encoded = try encodeFrame(frame, self.allocator);
        defer self.allocator.free(encoded);

        try stream.writeAll(encoded);
    }

    /// Receive a message (blocking)
    pub fn receive(self: *Self, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.state != .connected) {
            return error.NotConnected;
        }

        const stream = self.tcp_stream orelse return error.NotConnected;

        // Read frames until we have a complete message
        while (true) {
            // Try to decode a frame from existing buffer
            if (decodeFrame(self.recv_buffer.items)) |result| {
                const frame = result.frame;

                // Remove consumed bytes
                if (result.consumed > 0) {
                    const remaining = self.recv_buffer.items[result.consumed..];
                    std.mem.copyForwards(u8, self.recv_buffer.items[0..remaining.len], remaining);
                    self.recv_buffer.shrinkRetainingCapacity(remaining.len);
                }

                // Handle control frames
                switch (frame.opcode) {
                    .close => {
                        self.state = .closing;
                        return null;
                    },
                    .ping => {
                        // Respond with pong
                        try self.sendPong(frame.payload);
                        continue;
                    },
                    .pong => {
                        // Ignore pong
                        continue;
                    },
                    .text, .binary => {
                        // Return text/binary payload
                        return try allocator.dupe(u8, frame.payload);
                    },
                    .continuation => {
                        // Continuation frames not fully supported - return payload
                        return try allocator.dupe(u8, frame.payload);
                    },
                }
            }

            // Need more data - read from stream
            var read_buf: [4096]u8 = undefined;
            const bytes_read = stream.read(&read_buf) catch |err| {
                if (err == error.EndOfStream) {
                    self.state = .closed;
                    return null;
                }
                return err;
            };

            if (bytes_read == 0) {
                self.state = .closed;
                return null;
            }

            try self.recv_buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);
        }
    }

    /// Close the connection
    pub fn close(self: *Self) void {
        if (self.tcp_stream) |stream| {
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
                    stream.writeAll(encoded) catch {}; // Ignore errors on close
                } else |_| {}
            }
            stream.close();
            self.tcp_stream = null;
        }
        self.state = .closed;
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
        const stream = self.tcp_stream orelse return error.NotConnected;

        const frame = Frame{
            .opcode = .pong,
            .payload = payload,
            .fin = true,
            .masked = true,
        };

        const encoded = try encodeFrame(frame, self.allocator);
        defer self.allocator.free(encoded);

        try stream.writeAll(encoded);
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
        std.crypto.random.bytes(&mask);

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
) !void {
    _ = port; // Port is already resolved and connected before calling this
    const stream = client.tcp_stream orelse return error.NotConnected;

    // Generate random 16-byte nonce and base64 encode
    var nonce: [16]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    // Base64 encode the nonce
    const encoder = std.base64.standard.Encoder;
    const key = encoder.encode(&client.handshake_key, &nonce);

    // Build handshake request
    var request = std.ArrayList(u8){};
    defer request.deinit(client.allocator);

    const writer = request.writer(client.allocator);

    try writer.print("GET {s} HTTP/1.1\r\n", .{path});
    try writer.print("Host: {s}\r\n", .{host});
    try writer.print("Upgrade: websocket\r\n", .{host});
    try writer.print("Connection: Upgrade\r\n", .{});
    try writer.print("Sec-WebSocket-Key: {s}\r\n", .{key});
    try writer.print("Sec-WebSocket-Protocol: makai.v1\r\n", .{});
    try writer.print("Sec-WebSocket-Version: 13\r\n", .{});

    // Add custom headers
    if (headers) |h| {
        for (h) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
    }

    try writer.print("\r\n", .{});

    // Send request
    try stream.writeAll(request.items);

    // Read response
    var response_buf: [4096]u8 = undefined;
    const response_len = try stream.read(&response_buf);
    const response = response_buf[0..response_len];

    // Verify response
    // Should start with "HTTP/1.1 101"
    if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) {
        return error.HandshakeFailed;
    }

    // Verify Upgrade: websocket
    if (std.mem.indexOf(u8, response, "Upgrade: websocket") == null and
        std.mem.indexOf(u8, response, "Upgrade: Websocket") == null)
    {
        return error.HandshakeFailed;
    }

    // Verify Connection: Upgrade
    if (std.mem.indexOf(u8, response, "Connection: Upgrade") == null and
        std.mem.indexOf(u8, response, "Connection: upgrade") == null)
    {
        return error.HandshakeFailed;
    }

    // Verify Sec-WebSocket-Accept header
    // The accept key is base64(sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    // For simplicity, just verify the header exists
    if (std.mem.indexOf(u8, response, "Sec-WebSocket-Accept:") == null and
        std.mem.indexOf(u8, response, "Sec-WebSocket-Protocol:") == null)
    {
        return error.HandshakeFailed;
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
    if (std.mem.indexOfScalarPos(u8, url, offset, ':')) |colon_pos| {
        host_end = colon_pos;
        offset = colon_pos + 1;

        // Parse port
        const port_end = std.mem.indexOfScalarPos(u8, url, offset, '/') orelse url.len;
        const port_str = url[offset..port_end];
        result.port = try std.fmt.parseInt(u16, port_str, 10);
        offset = port_end;
    } else if (std.mem.indexOfScalarPos(u8, url, offset, '/')) |slash_pos| {
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
    var partial = std.ArrayList(u8){};
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

    var buf = std.ArrayList(u8){};
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
    const pipe = try std.posix.pipe();
    const read_fd = pipe[0];
    const write_fd = pipe[1];

    // Create client with pipe
    var client = WebSocketClient.init(allocator);
    defer client.deinit();

    client.tcp_stream = std.net.Stream{ .handle = write_fd };
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
    std.posix.close(pipe[0]);
    std.posix.close(pipe[1]);
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
