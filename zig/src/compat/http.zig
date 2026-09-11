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
    accept_encoding: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
};

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
            .headers = .{
                .accept_encoding = if (options.accept_encoding) |value| .{ .override = value } else .default,
                .user_agent = if (options.user_agent) |value| .{ .override = value } else .default,
            },
        });
    }

    pub fn initDefaultProxies(self: *HttpClient, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !void {
        try self.client.initDefaultProxies(allocator, environ_map);
    }
};

pub fn sendRequest(request: *Request, body: []const u8) !void {
    request.transfer_encoding = .{ .content_length = body.len };
    try request.sendBodyComplete(@constCast(body));
}

pub fn sendBodilessRequest(request: *Request) !void {
    try request.sendBodiless();
}

pub fn receiveResponse(request: *Request, redirect_buffer: []u8) !Response {
    return request.receiveHead(redirect_buffer);
}

pub const ResponseReader = opaque {};

pub fn readResponse(reader: *ResponseReader, buffer: []u8) !usize {
    const inner: *std.Io.Reader = @ptrCast(@alignCast(reader));
    return inner.readSliceShort(buffer);
}

pub fn readAllResponse(reader: *ResponseReader, buffer: []u8) !void {
    const inner: *std.Io.Reader = @ptrCast(@alignCast(reader));
    try inner.readSliceAll(buffer);
}

pub fn allocRemainingResponse(allocator: std.mem.Allocator, reader: *ResponseReader, max_bytes: usize) ![]u8 {
    const inner: *std.Io.Reader = @ptrCast(@alignCast(reader));
    return inner.allocRemaining(allocator, std.Io.Limit.limited(max_bytes));
}

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
    try std.testing.expect(options.accept_encoding == null);
}

test "compat http request options can override accept encoding" {
    const options = RequestOptions{ .accept_encoding = "identity" };
    try std.testing.expectEqualStrings("identity", options.accept_encoding.?);
}
