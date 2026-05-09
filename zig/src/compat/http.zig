const std = @import("std");
const sse_parser = @import("sse_parser");

pub const CompatHttpMethod = std.http.Method;
pub const CompatHttpHeader = std.http.Header;
pub const CompatHttpStatus = std.http.Status;

const default_header_buffer_size = 16 * 1024;

/// Request options for the compatibility HTTP seam.
///
/// Zig 0.16 mapping: these options remain Makai-owned request metadata. The
/// implementation will translate them to the future `std.http.Client` request
/// flow after client construction moves to `std.http.Client{ .io = ... }`.
pub const CompatHttpRequestOptions = struct {
    keep_alive: bool = true,
    header_buffer_size: usize = default_header_buffer_size,
    /// Defaults to `identity` so SSE streams are not buffered behind gzip. Future
    /// non-SSE consumers can opt into another value without bypassing this seam.
    accept_encoding: []const u8 = "identity",
};

/// Type-erased streaming response body reader.
///
/// Public APIs intentionally expose only `read`/`readSliceShort` over byte
/// slices. The Zig 0.15.2 implementation adapts `std.http.Client.Response`'s
/// reader internally; a later Zig 0.16 implementation can adapt the new I/O
/// reader shape without leaking `std.Io` into provider or OAuth signatures.
pub const CompatHttpBodyReader = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque, buffer: []u8) anyerror!usize,

    pub fn read(self: CompatHttpBodyReader, buffer: []u8) !usize {
        return self.read_fn(self.context, buffer);
    }

    pub fn readSliceShort(self: CompatHttpBodyReader, buffer: []u8) !usize {
        return self.read(buffer);
    }
};

fn stdReaderRead(context: *anyopaque, buffer: []u8) !usize {
    const reader: *std.Io.Reader = @ptrCast(@alignCast(context));
    return reader.readSliceShort(buffer);
}

fn bodyReaderFromStd(reader: *std.Io.Reader) CompatHttpBodyReader {
    return .{ .context = reader, .read_fn = stdReaderRead };
}

/// HTTP response wrapper that owns the in-flight request and header storage.
///
/// The request must stay alive while callers stream the response body. Keeping it
/// inside this wrapper preserves the current Zig 0.15.2 lifetime requirements and
/// gives the Zig 0.16 migration a single place to absorb request/send/receive
/// state-machine changes.
pub const CompatHttpResponse = struct {
    allocator: std.mem.Allocator,
    request_handle: std.http.Client.Request,
    response: std.http.Client.Response,
    header_buffer: []u8,

    pub fn deinit(self: *CompatHttpResponse) void {
        self.request_handle.deinit();
        self.allocator.free(self.header_buffer);
        self.* = undefined;
    }

    pub fn status(self: *const CompatHttpResponse) CompatHttpStatus {
        return self.response.head.status;
    }

    pub fn headerBytes(self: *const CompatHttpResponse) []const u8 {
        return self.response.head.bytes;
    }

    pub fn headers(self: *const CompatHttpResponse) std.http.HeaderIterator {
        return self.response.head.iterateHeaders();
    }

    pub fn reader(self: *CompatHttpResponse, transfer_buffer: []u8) CompatHttpBodyReader {
        return bodyReaderFromStd(self.response.reader(transfer_buffer));
    }
};

/// Thin HTTP client wrapper for provider/OAuth request creation.
///
/// Zig 0.15.2: wraps `std.http.Client{ .allocator = allocator }` and the
/// `request -> send body -> receive head -> stream body` sequence used by current
/// providers.
///
/// Zig 0.16 mapping: construct `std.http.Client` with the Makai-owned default
/// I/O context internally (for example `std.http.Client{ .io = ... }`) and
/// translate this same method to the new request/send/receive flow. Raw `std.Io`
/// handles must remain private to this module.
pub const CompatHttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) CompatHttpClient {
        return .{ .allocator = allocator, .client = .{ .allocator = allocator } };
    }

    pub fn deinit(self: *CompatHttpClient) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn request(
        self: *CompatHttpClient,
        method: CompatHttpMethod,
        url: []const u8,
        headers: []const CompatHttpHeader,
        body: []const u8,
    ) !CompatHttpResponse {
        return self.requestWithOptions(method, url, headers, body, .{});
    }

    pub fn requestWithOptions(
        self: *CompatHttpClient,
        method: CompatHttpMethod,
        url: []const u8,
        headers: []const CompatHttpHeader,
        body: []const u8,
        options: CompatHttpRequestOptions,
    ) !CompatHttpResponse {
        const uri = try std.Uri.parse(url);
        const header_buffer = try self.allocator.alloc(u8, options.header_buffer_size);
        errdefer self.allocator.free(header_buffer);

        // SSE streams must not be gzip-compressed: compression can buffer event
        // delivery and break incremental parsing. Default to `identity`, while
        // allowing non-SSE consumers to opt into another accept-encoding value.
        var request_handle = try self.client.request(method, uri, .{
            .extra_headers = headers,
            .keep_alive = options.keep_alive,
            .headers = .{ .accept_encoding = .{ .override = options.accept_encoding } },
        });
        errdefer request_handle.deinit();

        request_handle.transfer_encoding = .{ .content_length = body.len };
        try request_handle.sendBodyComplete(body);

        const response = try request_handle.receiveHead(header_buffer);
        return .{
            .allocator = self.allocator,
            .request_handle = request_handle,
            .response = response,
            .header_buffer = header_buffer,
        };
    }
};

/// Backwards-compatible aliases from the initial compatibility skeleton.
pub const Method = CompatHttpMethod;
pub const Headers = std.http.Client.Request.Headers;
pub const Request = std.http.Client.Request;
pub const Response = std.http.Client.Response;
pub const RequestOptions = CompatHttpRequestOptions;
pub const HttpClient = CompatHttpClient;
pub const ResponseReader = CompatHttpBodyReader;

/// Open a low-level request for call sites that still need to manage the
/// request state machine directly before they migrate to `CompatHttpClient.request`.
pub fn openRequest(client: *CompatHttpClient, method: CompatHttpMethod, uri: std.Uri, options: CompatHttpRequestOptions, headers: []const CompatHttpHeader) !Request {
    return client.client.request(method, uri, .{
        .extra_headers = headers,
        .keep_alive = options.keep_alive,
    });
}

/// Send a request body and complete the outbound request.
pub fn sendRequest(request_handle: *Request, body: []const u8) !void {
    request_handle.transfer_encoding = .{ .content_length = body.len };
    try request_handle.sendBodyComplete(body);
}

/// Receive the response headers/body metadata for a request.
pub fn receiveResponse(request_handle: *Request, header_buffer: []u8) !Response {
    return request_handle.receiveHead(header_buffer);
}

/// Return a streaming reader for a response body.
pub fn responseReader(response: *Response, transfer_buffer: []u8) CompatHttpBodyReader {
    return bodyReaderFromStd(response.reader(transfer_buffer));
}

/// Mock response for tests and preparatory consumers that need to validate the
/// abstraction without opening a socket.
pub const CompatHttpMockResponse = struct {
    status_code: CompatHttpStatus,
    header_list: []const CompatHttpHeader,
    raw_header_bytes: []const u8 = "",
    body: []const u8,
    offset: usize = 0,
    max_chunk_size: usize = std.math.maxInt(usize),

    pub fn init(status_code: CompatHttpStatus, header_list: []const CompatHttpHeader, body: []const u8) CompatHttpMockResponse {
        return .{ .status_code = status_code, .header_list = header_list, .body = body };
    }

    pub fn initWithHeaderBytes(
        status_code: CompatHttpStatus,
        header_list: []const CompatHttpHeader,
        raw_header_bytes: []const u8,
        body: []const u8,
    ) CompatHttpMockResponse {
        return .{
            .status_code = status_code,
            .header_list = header_list,
            .raw_header_bytes = raw_header_bytes,
            .body = body,
        };
    }

    pub fn status(self: *const CompatHttpMockResponse) CompatHttpStatus {
        return self.status_code;
    }

    pub fn headerBytes(self: *const CompatHttpMockResponse) []const u8 {
        return self.raw_header_bytes;
    }

    pub fn headers(self: *const CompatHttpMockResponse) []const CompatHttpHeader {
        return self.header_list;
    }

    pub fn reader(self: *CompatHttpMockResponse) CompatHttpBodyReader {
        return .{ .context = self, .read_fn = mockRead };
    }

    fn mockRead(context: *anyopaque, buffer: []u8) !usize {
        const self: *CompatHttpMockResponse = @ptrCast(@alignCast(context));
        if (self.offset >= self.body.len) return 0;

        const remaining = self.body.len - self.offset;
        const n = @min(buffer.len, @min(self.max_chunk_size, remaining));
        @memcpy(buffer[0..n], self.body[self.offset .. self.offset + n]);
        self.offset += n;
        return n;
    }
};

test "compat http client initializes and deinitializes" {
    var client = CompatHttpClient.init(std.testing.allocator);
    client.deinit();
}

test "compat http request options default to streaming safe behavior" {
    const options = CompatHttpRequestOptions{};
    try std.testing.expect(options.keep_alive);
    try std.testing.expectEqual(@as(usize, default_header_buffer_size), options.header_buffer_size);
    try std.testing.expectEqualStrings("identity", options.accept_encoding);

    const gzip_options = CompatHttpRequestOptions{ .accept_encoding = "gzip" };
    try std.testing.expectEqualStrings("gzip", gzip_options.accept_encoding);
}

test "compat http mock response exposes status headers and incremental reader" {
    const headers = [_]CompatHttpHeader{
        .{ .name = "content-type", .value = "text/event-stream" },
    };
    var response = CompatHttpMockResponse.init(.ok, &headers, "abcdef");
    response.max_chunk_size = 2;

    try std.testing.expectEqual(CompatHttpStatus.ok, response.status());
    try std.testing.expectEqualStrings("content-type", response.headers()[0].name);
    try std.testing.expectEqualStrings("", response.headerBytes());

    const raw_response = CompatHttpMockResponse.initWithHeaderBytes(.ok, &headers, "HTTP/1.1 200 OK\r\n", "");
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", raw_response.headerBytes());

    var reader = response.reader();
    var buffer: [4]u8 = undefined;

    const first = try reader.readSliceShort(&buffer);
    try std.testing.expectEqual(@as(usize, 2), first);
    try std.testing.expectEqualStrings("ab", buffer[0..first]);

    const second = try reader.readSliceShort(&buffer);
    try std.testing.expectEqual(@as(usize, 2), second);
    try std.testing.expectEqualStrings("cd", buffer[0..second]);

    const third = try reader.readSliceShort(&buffer);
    try std.testing.expectEqual(@as(usize, 2), third);
    try std.testing.expectEqualStrings("ef", buffer[0..third]);

    const done = try reader.readSliceShort(&buffer);
    try std.testing.expectEqual(@as(usize, 0), done);
}

test "compat http body reader preserves SSE incremental parsing" {
    const body = "data: first\n\ndata: second\n\n";
    var response = CompatHttpMockResponse.init(.ok, &.{}, body);
    response.max_chunk_size = 1;
    var reader = response.reader();

    var parser = sse_parser.SSEParser.init(std.testing.allocator);
    defer parser.deinit();

    var read_buffer: [8]u8 = undefined;
    var event_count: usize = 0;
    var saw_first = false;
    var saw_second = false;

    while (true) {
        const n = try reader.readSliceShort(&read_buffer);
        if (n == 0) break;

        const events = try parser.feed(read_buffer[0..n]);
        for (events) |event| {
            event_count += 1;
            if (std.mem.eql(u8, event.data, "first")) saw_first = true;
            if (std.mem.eql(u8, event.data, "second")) saw_second = true;
        }
    }

    try std.testing.expectEqual(@as(usize, 2), event_count);
    try std.testing.expect(saw_first);
    try std.testing.expect(saw_second);
}
