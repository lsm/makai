const std = @import("std");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const api_registry_mod = @import("api_registry");

pub fn stream(
    registry: *api_registry_mod.ApiRegistry,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    const provider = registry.getApiProvider(model.api) orelse return error.NoApiProvider;
    return provider.stream(model, context, options, allocator);
}

pub fn streamSimple(
    registry: *api_registry_mod.ApiRegistry,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    const provider = registry.getApiProvider(model.api) orelse return error.NoApiProvider;
    return provider.stream_simple(model, context, options, allocator);
}

pub fn complete(
    registry: *api_registry_mod.ApiRegistry,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !ai_types.AssistantMessage {
    const s = try stream(registry, model, context, options, allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    while (!s.isDone()) {
        std.Thread.Futex.wait(&s.futex, s.futex.load(.acquire));
    }

    const result = s.getResult() orelse return error.NoResult;
    return ai_types.cloneAssistantMessage(allocator, result);
}

pub fn completeSimple(
    registry: *api_registry_mod.ApiRegistry,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !ai_types.AssistantMessage {
    const s = try streamSimple(registry, model, context, options, allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    while (!s.isDone()) {
        std.Thread.Futex.wait(&s.futex, s.futex.load(.acquire));
    }

    const result = s.getResult() orelse return error.NoResult;
    return ai_types.cloneAssistantMessage(allocator, result);
}

fn mockStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);

    var result_content = try allocator.alloc(ai_types.AssistantContent, 1);
    result_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "ok") } };

    const result = ai_types.AssistantMessage{
        .content = result_content,
        .api = "openai-completions", // Borrowed reference
        .provider = "openai", // Borrowed reference
        .model = "gpt-4o", // Borrowed reference
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 1,
    };

    s.complete(result);
    return s;
}

fn mockStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = options;
    return mockStream(model, context, null, allocator);
}

test "complete resolves via api registry provider" {
    var registry = api_registry_mod.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerApiProvider(.{
        .api = "openai-completions",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    }, null);

    const msgs = [_]ai_types.Message{};
    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 16_384,
    };

    const ctx = ai_types.Context{ .messages = &msgs };

    var result = try complete(&registry, model, ctx, null, std.testing.allocator);
    defer ai_types.deinitAssistantMessageOwned(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("ok", result.content[0].text.text);
    try std.testing.expectEqualStrings("openai", result.provider);
}

test "stream delegates to registered provider stream function" {
    var registry = api_registry_mod.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerApiProvider(.{
        .api = "openai-completions",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    }, null);

    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 16_384,
    };
    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{} };

    const s = try stream(&registry, model, ctx, null, std.testing.allocator);
    defer {
        s.deinit();
        std.testing.allocator.destroy(s);
    }

    try std.testing.expect(s.isDone());
    try std.testing.expect(s.getResult() != null);
}

test "streamSimple delegates to registered provider stream_simple function" {
    var registry = api_registry_mod.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerApiProvider(.{
        .api = "openai-completions",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    }, null);

    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 16_384,
    };
    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{} };

    const s = try streamSimple(&registry, model, ctx, null, std.testing.allocator);
    defer {
        s.deinit();
        std.testing.allocator.destroy(s);
    }

    try std.testing.expect(s.isDone());
    try std.testing.expect(s.getResult() != null);
}

test "completeSimple resolves via api registry provider" {
    var registry = api_registry_mod.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerApiProvider(.{
        .api = "openai-completions",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    }, null);

    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 16_384,
    };
    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{} };

    var result = try completeSimple(&registry, model, ctx, null, std.testing.allocator);
    defer ai_types.deinitAssistantMessageOwned(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("ok", result.content[0].text.text);
}

test "stream returns NoApiProvider when provider is missing" {
    var registry = api_registry_mod.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "missing-api",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 16_384,
    };
    const ctx = ai_types.Context{ .messages = &[_]ai_types.Message{} };

    try std.testing.expectError(error.NoApiProvider, stream(&registry, model, ctx, null, std.testing.allocator));
    try std.testing.expectError(error.NoApiProvider, streamSimple(&registry, model, ctx, null, std.testing.allocator));
}
