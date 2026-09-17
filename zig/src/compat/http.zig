const std = @import("std");

fn workerEnviron() std.process.Environ {
    const builtin = @import("builtin");
    if (builtin.is_test) return std.testing.environ;

    const Block = std.process.Environ.Block;
    if (@hasField(Block, "use_global")) return .{ .block = .global };
    if (!builtin.link_libc) return .empty;

    const c_environ = std.c.environ;
    var env_count: usize = 0;
    while (c_environ[env_count] != null) : (env_count += 1) {}
    return .{ .block = .{ .slice = @ptrCast(c_environ[0..env_count :null]) } };
}

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
                .accept_encoding = acceptEncoding(options.accept_encoding),
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

pub fn headerPresent(headers: []const std.http.Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
    }
    return false;
}

test "compat http header presence ignores case and reports absence" {
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = "Bearer x" },
        .{ .name = "content-type", .value = "application/json" },
    };
    try std.testing.expect(headerPresent(&headers, "authorization"));
    try std.testing.expect(headerPresent(&headers, "CONTENT-TYPE"));
    try std.testing.expect(!headerPresent(&headers, "x-tenant"));
    try std.testing.expect(!headerPresent(&.{}, "authorization"));
}

pub fn acceptEncoding(override: ?[]const u8) Headers.Value {
    return .{ .override = override orelse "identity" };
}

test "compat http requests identity encoding unless a caller overrides it" {
    switch (acceptEncoding(null)) {
        .override => |value| try std.testing.expectEqualStrings("identity", value),
        else => return error.TestUnexpectedResult,
    }
    switch (acceptEncoding("gzip")) {
        .override => |value| try std.testing.expectEqualStrings("gzip", value),
        else => return error.TestUnexpectedResult,
    }
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

pub const default_fetch_timeout_ms: u64 = 30_000;

pub const FetchError = error{
    Timeout,
    RequestFailed,
    OutOfMemory,
};

pub const FetchOptions = struct {
    method: Method = .GET,
    extra_headers: []const std.http.Header = &.{},
    body: ?[]const u8 = null,
    accept_encoding: ?[]const u8 = null,
    max_response_bytes: usize = 8 * 1024 * 1024,
    timeout_ms: u64 = default_fetch_timeout_ms,
};

pub const Fetched = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Fetched, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

const FetchJob = struct {
    refs: std.atomic.Value(u32),
    event: std.Io.Event,
    succeeded: bool,
    status: u16,
    body: []u8,

    url: []u8,
    method: Method,
    headers: []std.http.Header,
    request_body: ?[]u8,
    accept_encoding: ?[]u8,
    max_response_bytes: usize,

    const arena = std.heap.page_allocator;

    fn create(url: []const u8, options: FetchOptions) error{OutOfMemory}!*FetchJob {
        const job = try arena.create(FetchJob);
        errdefer arena.destroy(job);

        const url_copy = try arena.dupe(u8, url);
        errdefer arena.free(url_copy);

        const headers = try arena.alloc(std.http.Header, options.extra_headers.len);
        var filled: usize = 0;
        errdefer {
            for (headers[0..filled]) |header| {
                arena.free(header.name);
                arena.free(header.value);
            }
            arena.free(headers);
        }
        for (options.extra_headers, 0..) |header, i| {
            const name = try arena.dupe(u8, header.name);
            errdefer arena.free(name);
            const value = try arena.dupe(u8, header.value);
            headers[i] = .{ .name = name, .value = value };
            filled = i + 1;
        }

        const request_body = if (options.body) |value| try arena.dupe(u8, value) else null;
        errdefer if (request_body) |value| arena.free(value);

        const accept_encoding = if (options.accept_encoding) |value| try arena.dupe(u8, value) else null;

        job.* = .{
            .refs = std.atomic.Value(u32).init(2),
            .event = .unset,
            .succeeded = false,
            .status = 0,
            .body = &.{},
            .url = url_copy,
            .method = options.method,
            .headers = headers,
            .request_body = request_body,
            .accept_encoding = accept_encoding,
            .max_response_bytes = options.max_response_bytes,
        };
        return job;
    }

    fn release(job: *FetchJob) void {
        if (job.refs.fetchSub(1, .acq_rel) != 1) return;
        if (job.body.len > 0) arena.free(job.body);
        arena.free(job.url);
        for (job.headers) |header| {
            arena.free(header.name);
            arena.free(header.value);
        }
        arena.free(job.headers);
        if (job.request_body) |value| arena.free(value);
        if (job.accept_encoding) |value| arena.free(value);
        arena.destroy(job);
    }

    fn run(job: *FetchJob) void {
        defer job.release();

        var status: u16 = 0;
        var body: []u8 = &.{};
        const ok = job.perform(&status, &body);

        job.succeeded = ok;
        job.status = status;
        job.body = body;
        job.event.set(defaultIo());
    }

    fn perform(job: *FetchJob, status_out: *u16, body_out: *[]u8) bool {
        const uri = std.Uri.parse(job.url) catch return false;

        var client = HttpClient.init(arena);
        defer client.deinit();

        var environ_map = std.process.Environ.createMap(workerEnviron(), arena) catch null;
        defer if (environ_map) |*map| map.deinit();
        if (environ_map) |*map| client.initDefaultProxies(arena, map) catch {};

        var request = client.openRequest(job.method, uri, .{
            .extra_headers = job.headers,
            .keep_alive = false,
            .accept_encoding = job.accept_encoding,
        }) catch return false;
        defer request.deinit();

        if (job.request_body) |value| {
            sendRequest(&request, value) catch return false;
        } else {
            sendBodilessRequest(&request) catch return false;
        }

        var redirect_buf: [8192]u8 = undefined;
        var response = receiveResponse(&request, &redirect_buf) catch return false;
        status_out.* = @intFromEnum(response.head.status);

        var transfer_buf: [8192]u8 = undefined;
        const reader = responseReader(&response, &transfer_buf);
        body_out.* = allocRemainingResponse(arena, reader, job.max_response_bytes) catch return false;
        return true;
    }
};

pub fn fetch(allocator: std.mem.Allocator, url: []const u8, options: FetchOptions) FetchError!Fetched {
    const job = try FetchJob.create(url, options);

    const thread = std.Thread.spawn(.{}, FetchJob.run, .{job}) catch {
        job.release();
        job.release();
        return error.RequestFailed;
    };
    thread.detach();

    const io = defaultIo();
    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .{ .nanoseconds = @as(i96, @intCast(options.timeout_ms)) * 1_000_000 },
        .clock = .awake,
    } };

    job.event.waitTimeout(io, timeout) catch {
        job.release();
        return error.Timeout;
    };

    defer job.release();
    if (!job.succeeded) return error.RequestFailed;
    const body = allocator.dupe(u8, job.body) catch return error.OutOfMemory;
    return .{ .status = job.status, .body = body };
}

test "fetch reports a url it cannot parse as a failed request" {
    try std.testing.expectError(
        error.RequestFailed,
        fetch(std.testing.allocator, "not a url at all", .{ .timeout_ms = 2_000 }),
    );
}

test "fetch reports a refused connection rather than hanging" {
    try std.testing.expectError(
        error.RequestFailed,
        fetch(std.testing.allocator, "http://127.0.0.1:1/nothing", .{ .timeout_ms = 5_000 }),
    );
}

test "fetch options default to a bounded timeout" {
    const options = FetchOptions{};
    try std.testing.expectEqual(default_fetch_timeout_ms, options.timeout_ms);
    try std.testing.expect(options.timeout_ms > 0);
}
