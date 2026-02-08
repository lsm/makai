const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");

pub const StreamFn = *const fn (
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageStream;

pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    stream_fn: StreamFn,
};

pub const Registry = struct {
    providers: std.StringHashMap(Provider),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return Registry{
            .providers = std.StringHashMap(Provider).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.providers.deinit();
    }

    pub fn register(self: *Registry, provider: Provider) !void {
        try self.providers.put(provider.id, provider);
    }

    pub fn get(self: *Registry, id: []const u8) ?Provider {
        return self.providers.get(id);
    }

    pub fn unregister(self: *Registry, id: []const u8) bool {
        return self.providers.remove(id);
    }
};

/// Stream function that takes an opaque context pointer for configuration
pub const StreamFnWithContext = *const fn (
    ctx: *anyopaque,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageStream;

/// Cleanup function for provider context
pub const DeinitFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void;

/// Enhanced provider with context support for configuration
pub const ProviderV2 = struct {
    id: []const u8,
    name: []const u8,
    context: *anyopaque,
    stream_fn: StreamFnWithContext,
    deinit_fn: ?DeinitFn = null,

    pub fn stream(
        self: *const ProviderV2,
        messages: []const types.Message,
        allocator: std.mem.Allocator,
    ) !*event_stream.AssistantMessageStream {
        return self.stream_fn(self.context, messages, allocator);
    }

    pub fn deinit(self: *ProviderV2, allocator: std.mem.Allocator) void {
        if (self.deinit_fn) |f| {
            f(self.context, allocator);
        }
    }
};

pub const RegistryV2 = struct {
    providers: std.StringHashMap(ProviderV2),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RegistryV2 {
        return RegistryV2{
            .providers = std.StringHashMap(ProviderV2).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RegistryV2) void {
        var it = self.providers.valueIterator();
        while (it.next()) |provider| {
            provider.deinit(self.allocator);
        }
        self.providers.deinit();
    }

    pub fn register(self: *RegistryV2, provider: ProviderV2) !void {
        try self.providers.put(provider.id, provider);
    }

    pub fn get(self: *RegistryV2, id: []const u8) ?ProviderV2 {
        return self.providers.get(id);
    }

    pub fn unregister(self: *RegistryV2, id: []const u8) !void {
        if (self.providers.fetchRemove(id)) |kv| {
            var provider = kv.value;
            provider.deinit(self.allocator);
        }
    }
};

// Tests
fn testStreamFn(
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    _ = messages;
    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);
    return stream;
}

test "Registry register and get" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = Provider{
        .id = "test-provider",
        .name = "Test Provider",
        .stream_fn = testStreamFn,
    };

    try registry.register(provider);

    const retrieved = registry.get("test-provider");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("test-provider", retrieved.?.id);
    try std.testing.expectEqualStrings("Test Provider", retrieved.?.name);

    const not_found = registry.get("non-existent");
    try std.testing.expect(not_found == null);
}

test "Registry unregister" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = Provider{
        .id = "test-provider",
        .name = "Test Provider",
        .stream_fn = testStreamFn,
    };

    try registry.register(provider);
    try std.testing.expect(registry.get("test-provider") != null);

    const removed = registry.unregister("test-provider");
    try std.testing.expect(removed);
    try std.testing.expect(registry.get("test-provider") == null);

    const not_removed = registry.unregister("non-existent");
    try std.testing.expect(!not_removed);
}

test "Registry multiple providers" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const provider1 = Provider{
        .id = "provider-1",
        .name = "Provider 1",
        .stream_fn = testStreamFn,
    };

    const provider2 = Provider{
        .id = "provider-2",
        .name = "Provider 2",
        .stream_fn = testStreamFn,
    };

    try registry.register(provider1);
    try registry.register(provider2);

    const p1 = registry.get("provider-1");
    const p2 = registry.get("provider-2");

    try std.testing.expect(p1 != null);
    try std.testing.expect(p2 != null);
    try std.testing.expectEqualStrings("Provider 1", p1.?.name);
    try std.testing.expectEqualStrings("Provider 2", p2.?.name);
}

// ProviderV2 tests
const TestContext = struct {
    call_count: usize,
};

fn testStreamFnWithContext(
    ctx: *anyopaque,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    _ = messages;
    const test_ctx: *TestContext = @ptrCast(@alignCast(ctx));
    test_ctx.call_count += 1;
    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);
    return stream;
}

fn testDeinitFn(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const test_ctx: *TestContext = @ptrCast(@alignCast(ctx));
    allocator.destroy(test_ctx);
}

test "ProviderV2 stream method" {
    const test_ctx = try std.testing.allocator.create(TestContext);
    test_ctx.* = TestContext{ .call_count = 0 };
    defer std.testing.allocator.destroy(test_ctx);

    const provider = ProviderV2{
        .id = "test-provider-v2",
        .name = "Test Provider V2",
        .context = test_ctx,
        .stream_fn = testStreamFnWithContext,
        .deinit_fn = null,
    };

    const messages = [_]types.Message{};
    const stream = try provider.stream(&messages, std.testing.allocator);
    defer {
        stream.deinit();
        std.testing.allocator.destroy(stream);
    }

    try std.testing.expectEqual(@as(usize, 1), test_ctx.call_count);
}

test "ProviderV2 deinit with cleanup function" {
    const test_ctx = try std.testing.allocator.create(TestContext);
    test_ctx.* = TestContext{ .call_count = 0 };

    var provider = ProviderV2{
        .id = "test-provider-v2",
        .name = "Test Provider V2",
        .context = test_ctx,
        .stream_fn = testStreamFnWithContext,
        .deinit_fn = testDeinitFn,
    };

    provider.deinit(std.testing.allocator);
}

test "ProviderV2 deinit without cleanup function" {
    const test_ctx = try std.testing.allocator.create(TestContext);
    defer std.testing.allocator.destroy(test_ctx);
    test_ctx.* = TestContext{ .call_count = 0 };

    var provider = ProviderV2{
        .id = "test-provider-v2",
        .name = "Test Provider V2",
        .context = test_ctx,
        .stream_fn = testStreamFnWithContext,
        .deinit_fn = null,
    };

    provider.deinit(std.testing.allocator);
}

test "RegistryV2 register and get" {
    var registry = RegistryV2.init(std.testing.allocator);
    defer registry.deinit();

    const test_ctx = try std.testing.allocator.create(TestContext);
    test_ctx.* = TestContext{ .call_count = 0 };

    const provider = ProviderV2{
        .id = "test-provider-v2",
        .name = "Test Provider V2",
        .context = test_ctx,
        .stream_fn = testStreamFnWithContext,
        .deinit_fn = testDeinitFn,
    };

    try registry.register(provider);

    const retrieved = registry.get("test-provider-v2");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("test-provider-v2", retrieved.?.id);
    try std.testing.expectEqualStrings("Test Provider V2", retrieved.?.name);

    const not_found = registry.get("non-existent");
    try std.testing.expect(not_found == null);
}

test "RegistryV2 unregister" {
    var registry = RegistryV2.init(std.testing.allocator);
    defer registry.deinit();

    const test_ctx = try std.testing.allocator.create(TestContext);
    test_ctx.* = TestContext{ .call_count = 0 };

    const provider = ProviderV2{
        .id = "test-provider-v2",
        .name = "Test Provider V2",
        .context = test_ctx,
        .stream_fn = testStreamFnWithContext,
        .deinit_fn = testDeinitFn,
    };

    try registry.register(provider);
    try std.testing.expect(registry.get("test-provider-v2") != null);

    try registry.unregister("test-provider-v2");
    try std.testing.expect(registry.get("test-provider-v2") == null);
}

test "RegistryV2 multiple providers" {
    var registry = RegistryV2.init(std.testing.allocator);
    defer registry.deinit();

    const test_ctx1 = try std.testing.allocator.create(TestContext);
    test_ctx1.* = TestContext{ .call_count = 0 };

    const test_ctx2 = try std.testing.allocator.create(TestContext);
    test_ctx2.* = TestContext{ .call_count = 0 };

    const provider1 = ProviderV2{
        .id = "provider-v2-1",
        .name = "Provider V2 1",
        .context = test_ctx1,
        .stream_fn = testStreamFnWithContext,
        .deinit_fn = testDeinitFn,
    };

    const provider2 = ProviderV2{
        .id = "provider-v2-2",
        .name = "Provider V2 2",
        .context = test_ctx2,
        .stream_fn = testStreamFnWithContext,
        .deinit_fn = testDeinitFn,
    };

    try registry.register(provider1);
    try registry.register(provider2);

    const p1 = registry.get("provider-v2-1");
    const p2 = registry.get("provider-v2-2");

    try std.testing.expect(p1 != null);
    try std.testing.expect(p2 != null);
    try std.testing.expectEqualStrings("Provider V2 1", p1.?.name);
    try std.testing.expectEqualStrings("Provider V2 2", p2.?.name);
}
