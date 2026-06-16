const std = @import("std");
const compat = @import("compat");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    const api_key = compat.getEnvVarOwned(allocator, "KIMI_API_KEY") catch |err| {
        std.debug.print("Failed to get KIMI_API_KEY: {}\n", .{err});
        return err;
    };
    defer allocator.free(api_key);
    
    const endpoint = "https://api.kimi.com/coding/v1/chat/completions";
    
    std.debug.print("\n=== Testing: {s} ===\n", .{endpoint});
    
    var client = std.http.Client{
        .allocator = allocator,
    };
    defer client.deinit();
    
    const body = 
    \\{
    \\  "model": "kimi-k2.7-code",
    \\  "messages": [{"role": "user", "content": "hello"}],
    \\  "stream": true
    \\}
    ;
    
    var header_buffer: [1024]u8 = undefined;
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(bearer);
    
    var req = try client.open(.POST, try std.Uri.parse(endpoint), .{
        .server_header_buffer = &header_buffer,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = bearer },
            .{ .name = "Content-Type", .value = "application/json" },
        },
    });
    defer req.deinit();
    
    try req.send(.{ .body = body });
    try req.wait();
    
    std.debug.print("Status: {d}\n", .{req.response.status});
    std.debug.print("Headers:\n", .{});
    for (req.response.headers.list) |header| {
        std.debug.print("  {s}: {s}\n", .{header.name, header.value});
    }
    
    std.debug.print("\nStreaming body (first 5KB):\n", .{});
    const reader = req.reader();
    var buffer: [5120]u8 = undefined;
    const n = try reader.readAll(&buffer);
    std.debug.print("{s}\n", .{buffer[0..n]});
}
