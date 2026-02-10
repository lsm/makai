const std = @import("std");

/// Local HTTP callback server for OAuth
pub const CallbackServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    listener: std.net.Server,
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,
    error_msg: ?[]const u8 = null,

    /// Start callback server on 127.0.0.1
    pub fn start(allocator: std.mem.Allocator, port: u16) !CallbackServer {
        const address = try std.net.Address.parseIp4("127.0.0.1", port);
        const listener = try address.listen(.{
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
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

        while (std.time.milliTimestamp() < deadline) {
            // Accept connection with timeout
            var connection = self.listener.accept() catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
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
                const query_start = std.mem.indexOf(u8, request, "?") orelse {
                    try self.sendResponse(connection.stream, false, "No query parameters");
                    continue;
                };

                const query_end = std.mem.indexOf(u8, request[query_start..], " ") orelse request.len - query_start;
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
                    try self.sendResponse(connection.stream, false, err_msg);
                    return error.OAuthError;
                }

                if (code) |c| {
                    self.code = c;
                    self.state = state;
                    try self.sendResponse(connection.stream, true, null);
                    return c;
                }

                try self.sendResponse(connection.stream, false, "No code parameter");
            }
        }

        return null; // Timeout
    }

    /// Send HTML response to browser
    fn sendResponse(self: *CallbackServer, stream: std.net.Stream, success: bool, error_msg: ?[]const u8) !void {
        _ = self;
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
            break :blk try std.fmt.allocPrint(std.testing.allocator,
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

        defer if (!success) std.testing.allocator.free(html);
        _ = try stream.write(html);
    }

    /// Stop callback server and free resources
    pub fn stop(self: *CallbackServer) void {
        self.listener.deinit();
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
