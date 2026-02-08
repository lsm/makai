const std = @import("std");
const xev = @import("xev");

pub const HttpError = error{
    ConnectionFailed,
    InvalidResponse,
    RequestFailed,
    Timeout,
    OutOfMemory,
    InvalidUrl,
    InvalidStatusCode,
    HeaderParseFailed,
    SocketError,
};

/// Callback for when data is received
pub const OnDataFn = *const fn (userdata: ?*anyopaque, data: []const u8) void;

/// Callback for when request completes or errors
pub const OnCompleteFn = *const fn (userdata: ?*anyopaque, err: ?HttpError) void;

/// HTTP request configuration
pub const HttpRequest = struct {
    method: Method,
    host: []const u8,
    port: u16,
    path: []const u8,
    headers: []const Header,
    body: ?[]const u8,

    pub const Method = enum {
        GET,
        POST,

        pub fn toString(self: Method) []const u8 {
            return switch (self) {
                .GET => "GET",
                .POST => "POST",
            };
        }
    };

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };
};

/// HTTP client using libxev
pub const HttpClient = struct {
    loop: *xev.Loop,
    allocator: std.mem.Allocator,

    pub fn init(loop: *xev.Loop, allocator: std.mem.Allocator) HttpClient {
        return .{
            .loop = loop,
            .allocator = allocator,
        };
    }

    /// Execute a streaming HTTP request
    /// Calls on_data for each chunk of response body
    /// Calls on_complete when finished (or on error)
    pub fn executeStreaming(
        self: *HttpClient,
        request: HttpRequest,
        userdata: ?*anyopaque,
        on_data: OnDataFn,
        on_complete: OnCompleteFn,
    ) !void {
        // Create request context to manage the async operation
        const ctx = try self.allocator.create(RequestContext);
        errdefer self.allocator.destroy(ctx);

        ctx.* = .{
            .client = self,
            .request = request,
            .userdata = userdata,
            .on_data = on_data,
            .on_complete = on_complete,
            .socket = try xev.TCP.init(request.host),
            .buffer = try self.allocator.alloc(u8, 16384), // 16KB buffer
            .state = .connecting,
            .headers_parsed = false,
            .body_start = 0,
        };

        // Resolve address
        const addr = try std.net.Address.parseIp4(request.host, request.port);

        // Start async connection
        var completion: xev.Completion = undefined;
        ctx.socket.connect(
            self.loop,
            &completion,
            addr,
            RequestContext,
            ctx,
            onConnect,
        );
    }

    const State = enum {
        connecting,
        sending,
        receiving_headers,
        receiving_body,
        done,
    };

    const RequestContext = struct {
        client: *HttpClient,
        request: HttpRequest,
        userdata: ?*anyopaque,
        on_data: OnDataFn,
        on_complete: OnCompleteFn,
        socket: xev.TCP,
        buffer: []u8,
        state: State,
        headers_parsed: bool,
        body_start: usize,
        response_data: std.ArrayList(u8) = undefined,

        fn deinit(self: *RequestContext) void {
            self.client.allocator.free(self.buffer);
            if (self.state != .connecting) {
                if (@hasField(@TypeOf(self.response_data), "deinit")) {
                    self.response_data.deinit(self.client.allocator);
                }
            }
            self.socket.close(self.client.loop, &self.socket, void, null, onSocketClosed);
        }

        fn onSocketClosed(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.TCP.CloseError!void) xev.CallbackAction {
            return .disarm;
        }
    };

    fn onConnect(
        ctx_ptr: ?*RequestContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        socket: xev.TCP,
        result: xev.TCP.ConnectError!void,
    ) xev.CallbackAction {
        const ctx = ctx_ptr orelse return .disarm;
        _ = socket;

        result catch {
            ctx.on_complete(ctx.userdata, HttpError.ConnectionFailed);
            ctx.deinit();
            ctx.client.allocator.destroy(ctx);
            return .disarm;
        };

        // Build HTTP request
        const request_str = buildHttpRequest(ctx.request, ctx.client.allocator) catch {
            ctx.on_complete(ctx.userdata, HttpError.RequestFailed);
            ctx.deinit();
            ctx.client.allocator.destroy(ctx);
            return .disarm;
        };
        defer ctx.client.allocator.free(request_str);

        ctx.state = .sending;

        // Send HTTP request
        ctx.socket.write(
            loop,
            completion,
            .{ .slice = request_str },
            RequestContext,
            ctx,
            onWrite,
        );

        return .disarm;
    }

    fn onWrite(
        ctx_ptr: ?*RequestContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        socket: xev.TCP,
        buffer: xev.WriteBuffer,
        result: xev.TCP.WriteError!usize,
    ) xev.CallbackAction {
        const ctx = ctx_ptr orelse return .disarm;
        _ = socket;
        _ = buffer;

        _ = result catch {
            ctx.on_complete(ctx.userdata, HttpError.RequestFailed);
            ctx.deinit();
            ctx.client.allocator.destroy(ctx);
            return .disarm;
        };

        ctx.state = .receiving_headers;
        ctx.response_data = std.ArrayList(u8){};

        // Start reading response
        ctx.socket.read(
            loop,
            completion,
            .{ .slice = ctx.buffer },
            RequestContext,
            ctx,
            onRead,
        );

        return .disarm;
    }

    fn onRead(
        ctx_ptr: ?*RequestContext,
        loop: *xev.Loop,
        completion: *xev.Completion,
        socket: xev.TCP,
        buffer: xev.ReadBuffer,
        result: xev.TCP.ReadError!usize,
    ) xev.CallbackAction {
        const ctx = ctx_ptr orelse return .disarm;
        _ = socket;

        const bytes_read = result catch |err| {
            if (err == error.EOF) {
                // Connection closed, complete the request
                ctx.on_complete(ctx.userdata, null);
                ctx.deinit();
                ctx.client.allocator.destroy(ctx);
                return .disarm;
            }
            ctx.on_complete(ctx.userdata, HttpError.RequestFailed);
            ctx.deinit();
            ctx.client.allocator.destroy(ctx);
            return .disarm;
        };

        if (bytes_read == 0) {
            // EOF
            ctx.on_complete(ctx.userdata, null);
            ctx.deinit();
            ctx.client.allocator.destroy(ctx);
            return .disarm;
        }

        const data = buffer.slice[0..bytes_read];

        // Append to response data
        ctx.response_data.appendSlice(ctx.client.allocator, data) catch {
            ctx.on_complete(ctx.userdata, HttpError.OutOfMemory);
            ctx.deinit();
            ctx.client.allocator.destroy(ctx);
            return .disarm;
        };

        // Parse headers if not done yet
        if (!ctx.headers_parsed) {
            if (parseResponseHeaders(ctx.response_data.items)) |info| {
                ctx.headers_parsed = true;
                ctx.body_start = info.body_start;
                ctx.state = .receiving_body;

                // Check status code
                if (info.status < 200 or info.status >= 300) {
                    ctx.on_complete(ctx.userdata, HttpError.InvalidStatusCode);
                    ctx.deinit();
                    ctx.client.allocator.destroy(ctx);
                    return .disarm;
                }

                // Call on_data with body portion
                if (ctx.response_data.items.len > ctx.body_start) {
                    const body_data = ctx.response_data.items[ctx.body_start..];
                    ctx.on_data(ctx.userdata, body_data);
                }
            } else |_| {
                // Headers not complete yet, continue reading
            }
        } else {
            // Already parsing body, call on_data with new data
            ctx.on_data(ctx.userdata, data);
        }

        // Continue reading
        ctx.socket.read(
            loop,
            completion,
            .{ .slice = ctx.buffer },
            RequestContext,
            ctx,
            onRead,
        );

        return .disarm;
    }
};

/// Build an HTTP/1.1 request string
pub fn buildHttpRequest(
    request: HttpRequest,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);

    // Request line: METHOD PATH HTTP/1.1
    try writer.print("{s} {s} HTTP/1.1\r\n", .{ request.method.toString(), request.path });

    // Host header
    try writer.print("Host: {s}\r\n", .{request.host});

    // Additional headers
    for (request.headers) |header| {
        try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    // Content-Length for POST requests
    if (request.body) |body| {
        try writer.print("Content-Length: {d}\r\n", .{body.len});
    }

    // End of headers
    try writer.writeAll("\r\n");

    // Body
    if (request.body) |body| {
        try writer.writeAll(body);
    }

    return buf.toOwnedSlice(allocator);
}

/// Parse HTTP response headers, return body start offset
pub fn parseResponseHeaders(
    data: []const u8,
) !struct { status: u16, body_start: usize } {
    // Find end of headers (double CRLF)
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse
        return error.HeaderParseFailed;

    // Parse status line
    const first_line_end = std.mem.indexOf(u8, data, "\r\n") orelse
        return error.HeaderParseFailed;

    const status_line = data[0..first_line_end];

    // Status line format: HTTP/1.1 200 OK
    var parts = std.mem.splitSequence(u8, status_line, " ");
    _ = parts.next() orelse return error.HeaderParseFailed; // HTTP/1.1
    const status_str = parts.next() orelse return error.HeaderParseFailed;

    const status = std.fmt.parseInt(u16, status_str, 10) catch
        return error.InvalidStatusCode;

    return .{
        .status = status,
        .body_start = header_end + 4, // Skip \r\n\r\n
    };
}

test "buildHttpRequest GET" {
    const allocator = std.testing.allocator;

    const request = HttpRequest{
        .method = .GET,
        .host = "localhost",
        .port = 8080,
        .path = "/api/chat",
        .headers = &[_]HttpRequest.Header{
            .{ .name = "Accept", .value = "application/json" },
        },
        .body = null,
    };

    const result = try buildHttpRequest(request, allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "GET /api/chat HTTP/1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Host: localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Accept: application/json") != null);
}

test "buildHttpRequest POST" {
    const allocator = std.testing.allocator;

    const body = "{\"test\":\"data\"}";
    const request = HttpRequest{
        .method = .POST,
        .host = "localhost",
        .port = 11434,
        .path = "/api/generate",
        .headers = &[_]HttpRequest.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = body,
    };

    const result = try buildHttpRequest(request, allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "POST /api/generate HTTP/1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Content-Type: application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Content-Length: 15") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, body) != null);
}

test "parseResponseHeaders success" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nHello World";

    const result = try parseResponseHeaders(response);

    try std.testing.expectEqual(@as(u16, 200), result.status);
    try std.testing.expectEqual(@as(usize, 45), result.body_start);
    try std.testing.expectEqualStrings("Hello World", response[result.body_start..]);
}

test "parseResponseHeaders 404" {
    const response = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot found";

    const result = try parseResponseHeaders(response);

    try std.testing.expectEqual(@as(u16, 404), result.status);
}

test "parseResponseHeaders incomplete" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain";

    const result = parseResponseHeaders(response);

    try std.testing.expectError(error.HeaderParseFailed, result);
}
