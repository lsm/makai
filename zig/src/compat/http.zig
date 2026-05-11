const std = @import("std");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub const Method = std.http.Method;
pub const Headers = std.http.Client.Request.Headers;
pub const Request = std.http.Client.Request;
pub const Response = std.http.Client.Response;
pub const RequestOptions = struct {
    extra_headers: []const std.http.Header = &.{},
    keep_alive: bool = true,
};

/// Thin HTTP client wrapper for the Zig 0.16 I/O migration seam.
///
/// Zig 0.16 mapping: construct `std.http.Client` with the Makai-owned default
/// I/O context (`std.Io.Threaded`/dispatch as required internally) while keeping
/// `std.Io` out of public signatures. Provider/OAuth rollout will add streaming
/// response helpers on this boundary without changing provider behavior here.
pub const HttpClient = struct {
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{ .client = .{ .allocator = allocator, .io = defaultIo() } };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn openRequest(self: *HttpClient, method: Method, uri: std.Uri, options: RequestOptions) !Request {
        return self.client.request(method, uri, .{
            .extra_headers = options.extra_headers,
            .keep_alive = options.keep_alive,
        });
    }
};

/// Send a request body and complete the outbound request.
pub fn sendRequest(request: *Request, body: []const u8) !void {
    request.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try request.sendBody(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
}

/// Receive the response headers/body metadata for a request.
pub fn receiveResponse(request: *Request, redirect_buffer: []u8) !Response {
    return request.receiveHead(redirect_buffer);
}

/// Reader wrapper for streaming response bodies without exposing raw `std.Io`.
pub const ResponseReader = opaque {};

/// Read bytes from a response body reader.
pub fn readResponse(reader: *ResponseReader, buffer: []u8) !usize {
    const inner: *std.Io.Reader = @ptrCast(@alignCast(reader));
    return inner.readSliceShort(buffer);
}

/// Read exactly `buffer.len` bytes from a response body reader.
pub fn readAllResponse(reader: *ResponseReader, buffer: []u8) !void {
    const inner: *std.Io.Reader = @ptrCast(@alignCast(reader));
    try inner.readSliceAll(buffer);
}

/// Return a streaming reader for a response body.
pub fn responseReader(response: *Response, transfer_buf: []u8) *ResponseReader {
    return @ptrCast(@alignCast(response.reader(transfer_buf)));
}

test "compat http client initializes and deinitializes" {
    var client = HttpClient.init(std.testing.allocator);
    client.deinit();
}

test "compat http request options default to no extra headers" {
    const options = RequestOptions{};
    try std.testing.expectEqual(@as(usize, 0), options.extra_headers.len);
    try std.testing.expect(options.keep_alive);
}
