const std = @import("std");
const compat = @import("compat");
const net = compat.net;

/// Local HTTP callback server for OAuth
pub const CallbackServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    listener: net.Server,
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,

    /// Start callback server on 127.0.0.1
    pub fn start(allocator: std.mem.Allocator, port: u16) !CallbackServer {
        const address = try net.resolveAddress(allocator, "127.0.0.1", port);
        const listener = try net.tcpListen(address, .{
            .reuse_address = true,
        });

        return .{
            .allocator = allocator,
            .port = port,
            .listener = listener,
        };
    }

    /// Wait for OAuth callback with timeout
    pub fn waitForCode(self: *CallbackServer, timeout_ms: u64) !?[]const u8 {
        const deadline = compat.time.nowMillis() + @as(i64, @intCast(timeout_ms));

        while (compat.time.nowMillis() < deadline) {
            // Accept connection with timeout
            var connection = net.accept(&self.listener) catch |err| {
                if (err == error.WouldBlock) {
                    compat.time.sleepMs(100);
                    continue;
                }
                return err;
            };
            defer connection.stream.close();

            // Read HTTP request
            var buffer: [4096]u8 = undefined;
            const bytes_read = try connection.stream.read(&buffer);
            if (bytes_read == 0) continue;

            const request = buffer[0..bytes_read];

            // Parse query string from GET request
            if (std.mem.startsWith(u8, request, "GET ")) {
                const query_start = std.mem.find(u8, request, "?") orelse {
                    try self.sendResponse(&connection.stream, false, "No query parameters");
                    continue;
                };

                const query_end = std.mem.find(u8, request[query_start..], " ") orelse request.len - query_start;
                const query = request[query_start + 1 .. query_start + query_end];

                // Parse code and state
                var code: ?[]const u8 = null;
                var state: ?[]const u8 = null;
                var error_param: ?[]const u8 = null;

                var iter = std.mem.splitScalar(u8, query, '&');
                while (iter.next()) |param| {
                    if (std.mem.startsWith(u8, param, "code=")) {
                        code = try self.allocator.dupe(u8, param[5..]);
                    } else if (std.mem.startsWith(u8, param, "state=")) {
                        state = try self.allocator.dupe(u8, param[6..]);
                    } else if (std.mem.startsWith(u8, param, "error=")) {
                        error_param = try self.allocator.dupe(u8, param[6..]);
                    }
                }

                if (error_param) |err_msg| {
                    self.error_msg = err_msg;
                    try self.sendResponse(&connection.stream, false, err_msg);
                    return error.OAuthError;
                }

                if (code) |c| {
                    self.code = c;
                    self.state = state;
                    try self.sendResponse(&connection.stream, true, null);
                    return c;
                }

                try self.sendResponse(&connection.stream, false, "No code parameter");
            }
        }

        return null; // Timeout
    }

    /// Send HTML response to browser
    fn sendResponse(self: *CallbackServer, stream: *net.Stream, success: bool, error_msg: ?[]const u8) !void {
        const html = if (success)
            \\HTTP/1.1 200 OK
            \\Content-Type: text/html; charset=utf-8
            \\Connection: close
            \\
            \\<!DOCTYPE html>
            \\<html><head><title>Success</title></head>
            \\<body><h1>Authentication successful!</h1>
            \\<p>You can close this window and return to your application.</p>
            \\</body></html>
        else blk: {
            const msg = error_msg orelse "Unknown error";
            break :blk try std.fmt.allocPrint(self.allocator,
                \\HTTP/1.1 400 Bad Request
                \\Content-Type: text/html; charset=utf-8
                \\Connection: close
                \\
                \\<!DOCTYPE html>
                \\<html><head><title>Error</title></head>
                \\<body><h1>Authentication failed</h1>
                \\<p>Error: {s}</p>
                \\</body></html>
            , .{msg});
        };

        defer if (!success) self.allocator.free(html);
        try stream.writeAll(html);
    }

    /// Stop callback server and free resources
    pub fn stop(self: *CallbackServer) void {
        net.closeServer(&self.listener);
        if (self.code) |code| {
            self.allocator.free(code);
        }
        if (self.state) |state| {
            self.allocator.free(state);
        }
        if (self.error_msg) |msg| {
            self.allocator.free(msg);
        }
    }
};

test "CallbackServer - start and stop" {
    var server = try CallbackServer.start(std.testing.allocator, 8888);
    defer server.stop();

    try std.testing.expectEqual(@as(u16, 8888), server.port);
}
