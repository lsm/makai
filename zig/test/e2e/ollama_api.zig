const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const register_builtins = @import("register_builtins");
const stream_mod = @import("stream");

const testing = std.testing;

fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

test "ollama e2e: basic text generation (new api)" {
    // Ollama can run in two modes:
    // 1. Cloud API (ollama.com) - requires OLLAMA_API_KEY
    // 2. Local server (localhost:11434) - no auth required
    const api_key = getEnvOwned(testing.allocator, "OLLAMA_API_KEY");
    defer if (api_key) |k| testing.allocator.free(k);

    // Skip if no API key and local server isn't running
    if (api_key == null) {
        var client = std.http.Client{ .allocator = testing.allocator };
        defer client.deinit();

        const uri = std.Uri.parse("http://127.0.0.1:11434/api/tags") catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: no OLLAMA_API_KEY and localhost:11434 not available\n", .{});
            return error.SkipZigTest;
        };

        var req = client.request(.GET, uri, .{}) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: no OLLAMA_API_KEY and localhost:11434 not responding\n", .{});
            return error.SkipZigTest;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = 0 };
        req.sendBodyComplete(&.{}) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: ollama local server not responding\n", .{});
            return error.SkipZigTest;
        };

        var head_buf: [1024]u8 = undefined;
        const response = req.receiveHead(&head_buf) catch {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: ollama local server not available\n", .{});
            return error.SkipZigTest;
        };

        if (response.head.status != .ok) {
            std.debug.print("\n\x1b[90mSKIPPED\x1b[0m: ollama local server not healthy\n", .{});
            return error.SkipZigTest;
        }
    }

    // Use ministral-3:3b as default - it's the smallest Ollama cloud model (~4.67GB)
    const model_id = getEnvOwned(testing.allocator, "OLLAMA_MODEL") orelse try testing.allocator.dupe(u8, "ministral-3:3b");
    defer testing.allocator.free(model_id);

    const base_url = getEnvOwned(testing.allocator, "OLLAMA_BASE_URL") orelse try testing.allocator.dupe(u8, "");
    defer testing.allocator.free(base_url);

    var registry = api_registry.ApiRegistry.init(testing.allocator);
    defer registry.deinit();
    try register_builtins.registerBuiltInApiProviders(&registry);

    const model = ai_types.Model{
        .id = model_id,
        .name = model_id,
        .api = "ollama",
        .provider = "ollama",
        .base_url = base_url,
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 131_072,
        .max_tokens = 48,
    };

    const user_msg = ai_types.Message{ .user = .{
        .content = .{ .text = "Reply with exactly: tiny ollama ok" },
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{user_msg} };

    const stream = try stream_mod.stream(&registry, model, ctx, .{
        .api_key = api_key,
        .max_tokens = 48,
        .temperature = 0.0,
    }, testing.allocator);
    defer {
        stream.deinit();
        testing.allocator.destroy(stream);
    }

    while (!stream.isDone()) {
        _ = stream.poll();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Allow detached provider thread to complete deferred cleanup
    std.Thread.sleep(50 * std.time.ns_per_ms);

    if (stream.getError()) |err| {
        std.debug.print("\nTest FAILED: ollama e2e stream error: {s}\n", .{err});
        return error.TestFailed;
    }

    const result = stream.getResult() orelse return error.NoResult;
    try testing.expect(result.content.len > 0);

    switch (result.content[0]) {
        .text => |t| try testing.expect(t.text.len > 0),
        else => return error.ExpectedText,
    }
}
