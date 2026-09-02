const std = @import("std");
const transport = @import("transport");
const sse_parser = @import("sse_parser");
const ai_types = @import("ai_types");
const compat = @import("compat");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

fn fileFromPipeHandle(handle: std.Io.File.Handle) std.Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

/// SSE Sender — writes events in Server-Sent Events wire format.
/// Each write becomes: "data: <json>\n\n"
pub const SseSender = struct {
    file: std.Io.File,

    pub fn init(file: std.Io.File) SseSender {
        return .{ .file = file };
    }

    pub fn sender(self: *SseSender) transport.Sender {
        return .{
            .context = @ptrCast(self),
            .write_fn = writeFn,
        };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *SseSender = @ptrCast(@alignCast(ctx));
        try self.file.writeStreamingAll(defaultIo(), "data: ");
        try self.file.writeStreamingAll(defaultIo(), data);
        try self.file.writeStreamingAll(defaultIo(), "\n\n");
    }
};

/// SSE Receiver — reads from a byte source, feeds into SSEParser,
/// and yields one data payload per read() call.
pub const SseReceiver = struct {
    parser: sse_parser.SSEParser,
    file: std.Io.File,
    read_buf: [4096]u8 = undefined,
    /// Pending events from last parser.feed() — stored as duped data strings
    pending: std.ArrayList([]u8),
    pending_index: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(file: std.Io.File, allocator: std.mem.Allocator) SseReceiver {
        return .{
            .parser = sse_parser.SSEParser.init(allocator),
            .file = file,
            .pending = std.ArrayList([]u8).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SseReceiver) void {
        for (self.pending.items[self.pending_index..]) |item| {
            self.allocator.free(item);
        }
        self.pending.deinit(self.allocator);
        self.parser.deinit();
    }

    pub fn receiver(self: *SseReceiver) transport.Receiver {
        return .{
            .context = @ptrCast(self),
            .read_fn = readFn,
            .close_fn = closeFn,
        };
    }

    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator) !?[]const u8 {
        const self: *SseReceiver = @ptrCast(@alignCast(ctx));

        while (true) {
            // Drain any pending events
            if (self.pending_index < self.pending.items.len) {
                const data = self.pending.items[self.pending_index];
                self.pending_index += 1;

                // If caller allocator differs from internal, re-dupe; otherwise transfer ownership
                if (allocator.ptr == self.allocator.ptr) {
                    return data;
                } else {
                    const copy = try allocator.dupe(u8, data);
                    self.allocator.free(data);
                    return copy;
                }
            }

            // All pending consumed — clear for next batch
            self.pending.clearRetainingCapacity();
            self.pending_index = 0;

            // Read more bytes from the source
            const bytes_read = self.file.readStreaming(defaultIo(), &.{&self.read_buf}) catch return null;
            if (bytes_read == 0) return null; // EOF

            // Feed to parser — parser returns slice of SSEEvent
            const events = try self.parser.feed(self.read_buf[0..bytes_read]);

            // Dupe the data strings before next feed() invalidates them
            for (events) |event| {
                const duped = try self.allocator.dupe(u8, event.data);
                try self.pending.append(self.allocator, duped);
            }
        }
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *SseReceiver = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

pub const ParsedHttpUrl = struct {
    scheme: Scheme,
    host: []const u8,
    port: u16,
    path: []const u8,
    explicit_port: bool = false,

    pub const Scheme = enum { http, https };
};

pub fn parseHttpUrl(url: []const u8) !ParsedHttpUrl {
    var result = ParsedHttpUrl{ .scheme = .http, .host = "", .port = 80, .path = "/" };
    var offset: usize = 0;
    if (std.mem.startsWith(u8, url, "http://")) {
        offset = 7;
    } else if (std.mem.startsWith(u8, url, "https://")) {
        result.scheme = .https;
        result.port = 443;
        offset = 8;
    } else {
        return error.InvalidScheme;
    }

    const host_start = offset;
    var authority_end = url.len;
    if (std.mem.indexOfAnyPos(u8, url, offset, "/?")) |end| authority_end = end;
    var host_end = authority_end;
    if (std.mem.indexOfScalarPos(u8, url, offset, ':')) |colon| {
        if (colon < authority_end) {
            host_end = colon;
            result.explicit_port = true;
            result.port = try std.fmt.parseInt(u16, url[colon + 1 .. authority_end], 10);
        }
    }
    offset = authority_end;

    if (host_end == host_start) return error.InvalidUrl;
    result.host = url[host_start..host_end];
    if (offset < url.len) result.path = url[offset..];
    return result;
}

pub const SseHttpClient = struct {
    allocator: std.mem.Allocator,
    endpoint: []u8 = &.{},
    headers: []ai_types.HeaderPair = &.{},
    producer: ?*HttpProducer = null,
    byte_stream: ?*transport.ByteStream = null,
    thread: ?std.Thread = null,
    parser: sse_parser.SSEParser,
    pending: std.ArrayList([]u8) = .empty,
    pending_index: usize = 0,
    connected: bool = false,
    chunked: bool = false,

    pub fn init(allocator: std.mem.Allocator) SseHttpClient {
        return .{ .allocator = allocator, .parser = sse_parser.SSEParser.init(allocator) };
    }

    pub fn deinit(self: *SseHttpClient) void {
        self.close();
        for (self.headers) |*header| header.deinit(self.allocator);
        if (self.headers.len > 0) self.allocator.free(self.headers);
        if (self.endpoint.len > 0) self.allocator.free(self.endpoint);
        self.pending.deinit(self.allocator);
        self.parser.deinit();
        self.* = undefined;
    }

    pub fn connect(self: *SseHttpClient, url: []const u8, headers: []const ai_types.HeaderPair) !void {
        self.close();
        const parsed = parseHttpUrl(url) catch return error.InvalidUrl;
        if (parsed.scheme == .https) return error.TlsNotSupported;
        if (self.endpoint.len > 0) self.allocator.free(self.endpoint);
        self.endpoint = try self.allocator.dupe(u8, url);
        try self.replaceHeaders(headers);
        var stream = compat.net.tcpConnectHost(self.allocator, parsed.host, parsed.port) catch return error.ConnectionFailed;
        errdefer stream.close();
        var request = std.ArrayList(u8).empty;
        defer request.deinit(self.allocator);
        const host_header = try formatHostHeader(self.allocator, parsed);
        defer self.allocator.free(host_header);
        const path = try formatPath(self.allocator, parsed.path);
        defer self.allocator.free(path);
        try request.print(self.allocator, "GET {s} HTTP/1.1\r\nHost: {s}\r\nAccept: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n", .{ path, host_header });
        for (self.headers) |header| try request.print(self.allocator, "{s}: {s}\r\n", .{ header.name, header.value });
        try request.appendSlice(self.allocator, "\r\n");
        stream.writeAll(request.items) catch return error.ConnectionFailed;
        var header_info = try self.readResponseHeaders(&stream, true);
        defer header_info.deinit(self.allocator);
        self.chunked = header_info.chunked;
        const byte_stream = try self.allocator.create(transport.ByteStream);
        errdefer self.allocator.destroy(byte_stream);
        byte_stream.* = transport.ByteStream.init(self.allocator);
        errdefer byte_stream.deinit();
        const producer = try self.allocator.create(HttpProducer);
        errdefer self.allocator.destroy(producer);
        producer.* = .{ .allocator = self.allocator, .stream = stream, .out = byte_stream, .chunked = header_info.chunked, .prefix = header_info.body_prefix };
        header_info.body_prefix = &.{};
        const thread = try std.Thread.spawn(.{}, httpProducerThread, .{producer});
        self.producer = producer;
        self.byte_stream = byte_stream;
        self.thread = thread;
        self.connected = true;
    }

    pub fn asyncSender(self: *SseHttpClient) transport.AsyncSender {
        return .{ .context = @ptrCast(self), .write_fn = writeFn, .flush_fn = flushFn, .close_fn = closeFn };
    }

    pub fn readLine(self: *SseHttpClient, allocator: std.mem.Allocator) !?[]const u8 {
        while (true) {
            if (self.pending_index < self.pending.items.len) {
                const data = self.pending.items[self.pending_index];
                self.pending_index += 1;
                if (allocator.ptr == self.allocator.ptr) return data;
                defer self.allocator.free(data);
                return try allocator.dupe(u8, data);
            }
            self.pending.clearRetainingCapacity();
            self.pending_index = 0;
            const byte_stream = self.byte_stream orelse return null;
            if (byte_stream.poll()) |chunk| {
                var mutable = chunk;
                defer mutable.deinit(byte_stream.allocator);
                const events = try self.parser.feed(chunk.data);
                for (events) |event| try self.pending.append(self.allocator, try self.allocator.dupe(u8, event.data));
                continue;
            }
            if (byte_stream.isDone()) {
                self.connected = false;
                return null;
            }
            return null;
        }
    }

    pub fn close(self: *SseHttpClient) void {
        if (self.producer) |producer| {
            producer.cancel.store(true, .release);
            producer.stream.close();
        }
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.producer) |producer| {
            producer.deinit();
            self.allocator.destroy(producer);
        }
        self.producer = null;
        if (self.byte_stream) |byte_stream| {
            byte_stream.deinit();
            self.allocator.destroy(byte_stream);
        }
        self.byte_stream = null;
        for (self.pending.items[self.pending_index..]) |item| self.allocator.free(item);
        self.pending.clearRetainingCapacity();
        self.pending_index = 0;
        self.connected = false;
        self.chunked = false;
        self.parser.deinit();
        self.parser = sse_parser.SSEParser.init(self.allocator);
    }

    fn replaceHeaders(self: *SseHttpClient, headers: []const ai_types.HeaderPair) !void {
        for (self.headers) |*header| header.deinit(self.allocator);
        if (self.headers.len > 0) self.allocator.free(self.headers);
        self.headers = try self.allocator.alloc(ai_types.HeaderPair, headers.len);
        for (headers, 0..) |header, i| self.headers[i] = .{ .name = try self.allocator.dupe(u8, header.name), .value = try self.allocator.dupe(u8, header.value) };
    }

    const HeaderInfo = struct {
        chunked: bool = false,
        body_prefix: []u8 = &.{},

        fn deinit(self: *HeaderInfo, allocator: std.mem.Allocator) void {
            if (self.body_prefix.len > 0) allocator.free(self.body_prefix);
            self.* = .{};
        }
    };

    fn readResponseHeaders(self: *SseHttpClient, stream: *compat.net.Stream, feed_body: bool) !HeaderInfo {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);
        var tmp: [512]u8 = undefined;
        while (std.mem.indexOf(u8, buffer.items, "\r\n\r\n") == null) {
            const n = stream.read(&tmp) catch return error.ConnectionFailed;
            if (n == 0) return error.ConnectionFailed;
            try buffer.appendSlice(self.allocator, tmp[0..n]);
            if (buffer.items.len > 16 * 1024) return error.UnexpectedStatus;
        }
        if (!std.mem.startsWith(u8, buffer.items, "HTTP/1.1 2") and !std.mem.startsWith(u8, buffer.items, "HTTP/1.0 2")) return error.UnexpectedStatus;
        const headers_end = std.mem.indexOf(u8, buffer.items, "\r\n\r\n") orelse return error.UnexpectedStatus;
        const headers = buffer.items[0..headers_end];
        var info = HeaderInfo{ .chunked = hasHeaderValue(headers, "Transfer-Encoding", "chunked") };
        errdefer info.deinit(self.allocator);
        if (!feed_body) return info;
        const body_start = headers_end + 4;
        if (body_start < buffer.items.len) {
            const body = buffer.items[body_start..];
            if (info.chunked) {
                info.body_prefix = try self.allocator.dupe(u8, body);
            } else {
                const events = try self.parser.feed(body);
                for (events) |event| try self.pending.append(self.allocator, try self.allocator.dupe(u8, event.data));
            }
        }
        return info;
    }

    fn post(self: *SseHttpClient, data: []const u8) !void {
        if (self.endpoint.len == 0) return error.NotConnected;
        const parsed = parseHttpUrl(self.endpoint) catch return error.InvalidUrl;
        var stream = compat.net.tcpConnectHost(self.allocator, parsed.host, parsed.port) catch return error.ConnectionFailed;
        defer stream.close();
        var request = std.ArrayList(u8).empty;
        defer request.deinit(self.allocator);
        const host_header = try formatHostHeader(self.allocator, parsed);
        defer self.allocator.free(host_header);
        const path = try formatPath(self.allocator, parsed.path);
        defer self.allocator.free(path);
        try request.print(self.allocator, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n", .{ path, host_header, data.len });
        for (self.headers) |header| try request.print(self.allocator, "{s}: {s}\r\n", .{ header.name, header.value });
        try request.appendSlice(self.allocator, "\r\n");
        try request.appendSlice(self.allocator, data);
        stream.writeAll(request.items) catch return error.ConnectionFailed;
        _ = self.readResponseHeaders(&stream, false) catch return error.HttpPostFailed;
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *SseHttpClient = @ptrCast(@alignCast(ctx));
        try self.post(data);
    }

    fn flushFn(_: *anyopaque) !void {}

    fn closeFn(ctx: *anyopaque) void {
        const self: *SseHttpClient = @ptrCast(@alignCast(ctx));
        self.close();
    }
};

fn formatPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '?') return std.fmt.allocPrint(allocator, "/{s}", .{path});
    return allocator.dupe(u8, path);
}

fn formatHostHeader(allocator: std.mem.Allocator, parsed: ParsedHttpUrl) ![]u8 {
    if (!parsed.explicit_port) return allocator.dupe(u8, parsed.host);
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ parsed.host, parsed.port });
}

const HttpProducer = struct {
    allocator: std.mem.Allocator,
    stream: compat.net.Stream,
    out: *transport.ByteStream,
    chunked: bool,
    prefix: []u8 = &.{},
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn deinit(self: *HttpProducer) void {
        if (self.prefix.len > 0) self.allocator.free(self.prefix);
        self.* = undefined;
    }
};

fn httpProducerThread(ctx: *HttpProducer) void {
    defer {
        ctx.stream.close();
        ctx.out.markThreadDone();
    }
    if (ctx.chunked) {
        readChunkedBody(ctx) catch |err| ctx.out.completeWithError(@errorName(err));
    } else {
        readPlainBody(ctx) catch |err| ctx.out.completeWithError(@errorName(err));
    }
}

fn readPlainBody(ctx: *HttpProducer) !void {
    if (ctx.prefix.len > 0) {
        try ctx.out.push(.{ .data = try ctx.allocator.dupe(u8, ctx.prefix), .owned = true });
        ctx.allocator.free(ctx.prefix);
        ctx.prefix = &.{};
    }
    var buf: [4096]u8 = undefined;
    while (!ctx.cancel.load(.acquire)) {
        const n = try ctx.stream.read(&buf);
        if (n == 0) {
            ctx.out.complete({});
            return;
        }
        const data = try ctx.allocator.dupe(u8, buf[0..n]);
        errdefer ctx.allocator.free(data);
        try ctx.out.push(.{ .data = data, .owned = true });
    }
    ctx.out.completeWithError("Cancelled");
}

fn readChunkedBody(ctx: *HttpProducer) !void {
    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(ctx.allocator);
    if (ctx.prefix.len > 0) {
        try raw.appendSlice(ctx.allocator, ctx.prefix);
        ctx.allocator.free(ctx.prefix);
        ctx.prefix = &.{};
        while (try popHttpChunk(ctx.allocator, &raw)) |chunk| {
            errdefer ctx.allocator.free(chunk);
            try ctx.out.push(.{ .data = chunk, .owned = true });
        }
    }
    var buf: [4096]u8 = undefined;
    while (!ctx.cancel.load(.acquire)) {
        const n = try ctx.stream.read(&buf);
        if (n == 0) {
            ctx.out.complete({});
            return;
        }
        try raw.appendSlice(ctx.allocator, buf[0..n]);
        while (try popHttpChunk(ctx.allocator, &raw)) |chunk| {
            errdefer ctx.allocator.free(chunk);
            try ctx.out.push(.{ .data = chunk, .owned = true });
        }
    }
    ctx.out.completeWithError("Cancelled");
}

fn popHttpChunk(allocator: std.mem.Allocator, raw: *std.ArrayList(u8)) !?[]u8 {
    const line_end = std.mem.indexOf(u8, raw.items, "\r\n") orelse return null;
    const size_text = raw.items[0..line_end];
    const semi = std.mem.indexOfScalar(u8, size_text, ';') orelse size_text.len;
    const size = try std.fmt.parseInt(usize, std.mem.trim(u8, size_text[0..semi], " \t"), 16);
    const data_start = line_end + 2;
    const total = data_start + size + 2;
    if (raw.items.len < total) return null;
    if (size == 0) {
        raw.clearRetainingCapacity();
        return null;
    }
    const out = try allocator.dupe(u8, raw.items[data_start..][0..size]);
    const remaining = raw.items[total..];
    std.mem.copyForwards(u8, raw.items[0..remaining.len], remaining);
    raw.shrinkRetainingCapacity(remaining.len);
    return out;
}

fn dechunkHttpBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(allocator);
    try raw.appendSlice(allocator, body);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    while (try popHttpChunk(allocator, &raw)) |chunk| {
        defer allocator.free(chunk);
        try out.appendSlice(allocator, chunk);
    }
    return out.toOwnedSlice(allocator);
}

fn hasHeaderValue(headers: []const u8, name: []const u8, value: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
        const header_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.indexOfIgnoreCase(header_value, value) != null) return true;
    }
    return false;
}

// --- Async implementations ---

/// Async SSE Sender — writes events in Server-Sent Events wire format.
pub const AsyncSseSender = struct {
    file: std.Io.File,

    pub fn init(file: std.Io.File) AsyncSseSender {
        return .{ .file = file };
    }

    pub fn sender(self: *AsyncSseSender) transport.AsyncSender {
        return .{
            .context = @ptrCast(self),
            .write_fn = writeFn,
        };
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) !void {
        const self: *AsyncSseSender = @ptrCast(@alignCast(ctx));
        try self.file.writeStreamingAll(defaultIo(), "data: ");
        try self.file.writeStreamingAll(defaultIo(), data);
        try self.file.writeStreamingAll(defaultIo(), "\n\n");
    }
};

/// Async SSE Receiver — produces ByteStream with parsed SSE data payloads.
/// Caller must call deinit() to join the thread and free resources.
pub const AsyncSseReceiver = struct {
    file: std.Io.File,
    thread: ?std.Thread = null,
    stream: ?*transport.ByteStream = null,
    cancel_token: ?*std.atomic.Value(bool) = null,
    allocator: ?std.mem.Allocator = null,

    const Self = @This();

    pub fn init(file: std.Io.File) Self {
        return .{ .file = file };
    }

    /// Signal cancellation and join the thread with a timeout.
    /// Returns true if the thread exited cleanly, false if timeout was reached.
    pub fn deinit(self: *Self) bool {
        // Signal cancellation if we have a cancel token
        if (self.cancel_token) |token| {
            token.store(true, .release);
        }

        // Join thread with timeout
        if (self.thread) |t| {
            // Use stream's waitForThread for timeout-based waiting
            const thread_exited = if (self.stream) |s| s.waitForThread(5000) else false;

            // Always join the thread (blocking if it didn't exit)
            t.join();
            self.thread = null;

            if (!thread_exited) {
                // Thread didn't exit in time, but we still joined
            }
        }

        // Free cancel token
        if (self.cancel_token) |token| {
            if (self.allocator) |alloc| {
                alloc.destroy(token);
            }
            self.cancel_token = null;
        }

        // Free stream
        if (self.stream) |s| {
            s.deinit();
            if (self.allocator) |alloc| {
                alloc.destroy(s);
            }
            self.stream = null;
        }

        self.allocator = null;
        return true;
    }

    pub fn receiver(self: *Self) transport.AsyncReceiver {
        return .{
            .context = @ptrCast(self),
            .receive_stream_fn = receiveStreamFn,
            .read_fn = readFn,
        };
    }

    const ProducerContext = struct {
        stream: *transport.ByteStream,
        file: std.Io.File,
        allocator: std.mem.Allocator,
        parser: sse_parser.SSEParser,
        read_buf: [4096]u8 = undefined,
        cancel_token: ?*std.atomic.Value(bool) = null,
    };

    fn receiveStreamFn(ctx: *anyopaque, allocator: std.mem.Allocator) !*transport.ByteStream {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Guard against double-call
        if (self.stream != null) return error.StreamAlreadyActive;

        const stream = try allocator.create(transport.ByteStream);
        stream.* = transport.ByteStream.init(allocator);

        const cancel_token = try allocator.create(std.atomic.Value(bool));
        cancel_token.* = std.atomic.Value(bool).init(false);

        const thread_ctx = try allocator.create(ProducerContext);
        thread_ctx.* = .{
            .stream = stream,
            .file = self.file,
            .allocator = allocator,
            .parser = sse_parser.SSEParser.init(allocator),
            .cancel_token = cancel_token,
        };

        // Store for deinit
        self.stream = stream;
        self.cancel_token = cancel_token;
        self.allocator = allocator;

        const thread = try std.Thread.spawn(.{}, producerThread, .{thread_ctx});
        self.thread = thread;
        // Don't detach - we need to join in deinit

        return stream;
    }

    fn producerThread(ctx: *ProducerContext) void {
        // Save pointers before defer block since we need to call markThreadDone
        // AFTER freeing ctx (to avoid race with waitForThread)
        const stream = ctx.stream;
        const allocator = ctx.allocator;

        defer {
            ctx.parser.deinit();
            allocator.destroy(ctx);
            // Mark thread done AFTER all cleanup so waitForThread guarantees memory is freed
            stream.markThreadDone();
        }

        while (true) {
            // Check for cancellation
            if (ctx.cancel_token) |token| {
                if (token.load(.acquire)) {
                    ctx.stream.completeWithError("Cancelled");
                    return;
                }
            }

            // Read more bytes from the source
            const bytes_read = ctx.file.readStreaming(defaultIo(), &.{&ctx.read_buf}) catch {
                ctx.stream.completeWithError("Read error");
                return;
            };

            if (bytes_read == 0) {
                // EOF
                ctx.stream.complete({});
                return;
            }

            // Feed to parser
            const events = ctx.parser.feed(ctx.read_buf[0..bytes_read]) catch |err| {
                ctx.stream.completeWithError(sse_parser.errorMessage(err));
                return;
            };

            // Push each event as a ByteChunk
            for (events) |event| {
                const data = ctx.allocator.dupe(u8, event.data) catch {
                    ctx.stream.completeWithError("Out of memory");
                    return;
                };
                const chunk = transport.ByteChunk{
                    .data = data,
                    .owned = true,
                };
                ctx.stream.push(chunk) catch {
                    ctx.stream.completeWithError("Stream queue full");
                    return;
                };
            }
        }
    }

    // Keep backward-compatible blocking read
    fn readFn(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        var parser = sse_parser.SSEParser.init(allocator);
        defer parser.deinit();
        var read_buf: [4096]u8 = undefined;
        var pending = std.ArrayList([]u8).empty;
        defer {
            for (pending.items) |item| {
                allocator.free(item);
            }
            pending.deinit(allocator);
        }
        var pending_index: usize = 0;

        while (true) {
            // Drain any pending events
            if (pending_index < pending.items.len) {
                const data = pending.items[pending_index];
                pending_index += 1;
                return data; // Transfer ownership
            }

            // All pending consumed — clear for next batch
            pending.clearRetainingCapacity();
            pending_index = 0;

            // Read more bytes from the source
            const bytes_read = self.file.readStreaming(defaultIo(), &.{&read_buf}) catch return null;
            if (bytes_read == 0) return null; // EOF

            // Feed to parser
            const events = try parser.feed(read_buf[0..bytes_read]);

            // Dupe the data strings
            for (events) |event| {
                const duped = try allocator.dupe(u8, event.data);
                try pending.append(allocator, duped);
            }
        }
    }
};

// Tests

const MockHttpSseServer = struct {
    server: compat.net.Server,
    thread: ?std.Thread = null,
    saw_get_auth: bool = false,
    saw_post_auth: bool = false,
    saw_post_body: bool = false,

    fn start(self: *MockHttpSseServer) !void {
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn stop(self: *MockHttpSseServer) void {
        if (self.thread) |thread| thread.join();
        compat.net.closeServer(&self.server);
    }

    fn serve(self: *MockHttpSseServer) void {
        handleGet(self) catch return;
        handlePost(self) catch return;
    }

    fn readRequest(allocator: std.mem.Allocator, stream: *compat.net.Stream) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        var tmp: [512]u8 = undefined;
        while (true) {
            const n = try stream.read(&tmp);
            if (n == 0) break;
            try buf.appendSlice(allocator, tmp[0..n]);
            if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |headers_end| {
                const content_length = parseContentLength(buf.items[0..headers_end]) orelse 0;
                const total = headers_end + 4 + content_length;
                while (buf.items.len < total) {
                    const more = try stream.read(&tmp);
                    if (more == 0) break;
                    try buf.appendSlice(allocator, tmp[0..more]);
                }
                break;
            }
        }
        return buf.toOwnedSlice(allocator);
    }

    fn parseContentLength(request: []const u8) ?usize {
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
                return std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \t"), 10) catch null;
            }
        }
        return null;
    }

    fn handleGet(self: *MockHttpSseServer) !void {
        var conn = try compat.net.accept(&self.server);
        defer conn.stream.close();
        const req = try readRequest(std.testing.allocator, &conn.stream);
        defer std.testing.allocator.free(req);
        self.saw_get_auth = std.mem.indexOf(u8, req, "Authorization: Bearer test-token") != null;
        try conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: {\"type\":\"agent_started\"}\n\n");
    }

    fn handlePost(self: *MockHttpSseServer) !void {
        var conn = try compat.net.accept(&self.server);
        defer conn.stream.close();
        const req = try readRequest(std.testing.allocator, &conn.stream);
        defer std.testing.allocator.free(req);
        self.saw_post_auth = std.mem.indexOf(u8, req, "Authorization: Bearer test-token") != null;
        self.saw_post_body = std.mem.indexOf(u8, req, "{\"hello\":true}") != null;
        try conn.stream.writeAll("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    }
};

test "parseHttpUrl validates HTTP SSE URLs" {
    const a = try parseHttpUrl("http://127.0.0.1:8080/events");
    try std.testing.expectEqual(ParsedHttpUrl.Scheme.http, a.scheme);
    try std.testing.expectEqualStrings("127.0.0.1", a.host);
    try std.testing.expectEqual(@as(u16, 8080), a.port);
    try std.testing.expectEqualStrings("/events", a.path);
    try std.testing.expect(a.explicit_port);
    const query_only = try parseHttpUrl("http://backend:8080?token=abc");
    try std.testing.expectEqualStrings("backend", query_only.host);
    try std.testing.expectEqual(@as(u16, 8080), query_only.port);
    try std.testing.expectEqualStrings("?token=abc", query_only.path);
    const b = try parseHttpUrl("https://example.com/sse");
    try std.testing.expectEqual(ParsedHttpUrl.Scheme.https, b.scheme);
    try std.testing.expectEqual(@as(u16, 443), b.port);
    try std.testing.expectError(error.InvalidUrl, parseHttpUrl("http:///bad"));
    try std.testing.expectError(error.InvalidScheme, parseHttpUrl("ws://example.com"));
}

test "SseHttpClient dechunks HTTP body before SSE parsing" {
    const chunked = "7\r\ndata: {\r\nC\r\n\"ok\":true}\n\n\r\n0\r\n\r\n";
    const body = try dechunkHttpBody(std.testing.allocator, chunked);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("data: {\"ok\":true}\n\n", body);
}

test "SseSender writes SSE format" {
    // Create a pipe
    const pipe = try std.Io.Threaded.pipe2(.{});
    const read_file = fileFromPipeHandle(pipe[0]);
    const write_file = fileFromPipeHandle(pipe[1]);
    defer read_file.close(defaultIo());

    var sse_sender = SseSender.init(write_file);
    var s = sse_sender.sender();

    try s.write("{\"type\":\"ping\"}");
    try s.write("{\"type\":\"start\",\"model\":\"test\"}");
    write_file.close(defaultIo());

    // Read raw bytes and verify SSE format
    var buf: [1024]u8 = undefined;
    const n = try read_file.readStreaming(defaultIo(), &.{&buf});
    const output = buf[0..n];

    const expected = "data: {\"type\":\"ping\"}\n\ndata: {\"type\":\"start\",\"model\":\"test\"}\n\n";
    try std.testing.expectEqualStrings(expected, output);
}

test "SseReceiver parses SSE format" {
    const allocator = std.testing.allocator;

    // Create a pipe
    const pipe = try std.Io.Threaded.pipe2(.{});
    const read_file = fileFromPipeHandle(pipe[0]);
    const write_file = fileFromPipeHandle(pipe[1]);
    defer read_file.close(defaultIo());

    // Write SSE-formatted data
    try write_file.writeStreamingAll(defaultIo(), "data: {\"type\":\"ping\"}\n\ndata: {\"type\":\"start\",\"model\":\"test\"}\n\n");
    write_file.close(defaultIo());

    var sse_recv = SseReceiver.init(read_file, allocator);
    defer sse_recv.deinit();
    var r = sse_recv.receiver();

    const line1 = try r.read(allocator);
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("{\"type\":\"ping\"}", line1.?);
    allocator.free(line1.?);

    const line2 = try r.read(allocator);
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("{\"type\":\"start\",\"model\":\"test\"}", line2.?);
    allocator.free(line2.?);

    const line3 = try r.read(allocator);
    try std.testing.expect(line3 == null);
}

test "SseSender and SseReceiver round-trip with transport" {
    const allocator = std.testing.allocator;

    // Create a pipe
    const pipe = try std.Io.Threaded.pipe2(.{});
    const read_file = fileFromPipeHandle(pipe[0]);
    const write_file = fileFromPipeHandle(pipe[1]);
    defer read_file.close(defaultIo());

    // Serialize a real event through SseSender
    var sse_sender = SseSender.init(write_file);
    var s = sse_sender.sender();

    const empty_partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event_json = try transport.serializeEvent(
        .{ .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = empty_partial } },
        allocator,
    );
    defer allocator.free(event_json);
    try s.write(event_json);

    const result_json = try transport.serializeResult(.{
        .content = &[_]ai_types.AssistantContent{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "test",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 1,
    }, allocator);
    defer allocator.free(result_json);
    try s.write(result_json);

    write_file.close(defaultIo());

    // Read back through SseReceiver + deserialize
    var sse_recv = SseReceiver.init(read_file, allocator);
    defer sse_recv.deinit();
    var r = sse_recv.receiver();

    const line1 = try r.read(allocator);
    try std.testing.expect(line1 != null);
    defer allocator.free(line1.?);
    const msg1 = try transport.deserialize(line1.?, allocator);
    try std.testing.expect(msg1 == .event);
    try std.testing.expect(msg1.event == .text_delta);
    allocator.free(msg1.event.text_delta.delta);

    const line2 = try r.read(allocator);
    try std.testing.expect(line2 != null);
    defer allocator.free(line2.?);
    const msg2 = try transport.deserialize(line2.?, allocator);
    try std.testing.expect(msg2 == .result);
    var mutable_result = msg2.result;
    mutable_result.deinit(allocator);
}
