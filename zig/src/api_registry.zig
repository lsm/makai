const std = @import("std");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");

pub const ApiStreamFunction = *const fn (
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream;

pub const ApiStreamSimpleFunction = *const fn (
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream.AssistantMessageEventStream;

pub const ApiProvider = struct {
    api: []const u8,
    stream: ApiStreamFunction,
    stream_simple: ApiStreamSimpleFunction,
};

const RegisteredApiProvider = struct {
    provider: ApiProvider,
    source_id: ?[]const u8,
};

pub const ApiRegistry = struct {
    providers: std.StringHashMap(RegisteredApiProvider),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ApiRegistry {
        return .{
            .providers = std.StringHashMap(RegisteredApiProvider).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ApiRegistry) void {
        var it = self.providers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.source_id) |source_id| self.allocator.free(source_id);
        }
        self.providers.deinit();

        // Poison freed memory to catch use-after-free in debug builds
        self.* = undefined;
    }

    pub fn registerApiProvider(self: *ApiRegistry, provider: ApiProvider, source_id: ?[]const u8) !void {
        const key = try self.allocator.dupe(u8, provider.api);
        errdefer self.allocator.free(key);

        const source_dup = if (source_id) |sid| try self.allocator.dupe(u8, sid) else null;
        errdefer if (source_dup) |sid| self.allocator.free(sid);

        if (self.providers.fetchRemove(provider.api)) |existing| {
            self.allocator.free(existing.key);
            if (existing.value.source_id) |sid| self.allocator.free(sid);
        }

        try self.providers.put(key, .{ .provider = provider, .source_id = source_dup });
    }

    pub fn getApiProvider(self: *ApiRegistry, api: []const u8) ?ApiProvider {
        if (self.providers.get(api)) |entry| return entry.provider;
        return null;
    }

    pub fn unregisterApiProviders(self: *ApiRegistry, source_id: []const u8) void {
        while (true) {
            var found_key: ?[]const u8 = null;

            var it = self.providers.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.source_id) |sid| {
                    if (std.mem.eql(u8, sid, source_id)) {
                        found_key = entry.key_ptr.*;
                        break;
                    }
                }
            }

            if (found_key == null) break;

            if (self.providers.fetchRemove(found_key.?)) |removed| {
                self.allocator.free(removed.key);
                if (removed.value.source_id) |sid| self.allocator.free(sid);
            }
        }
    }

    pub fn clearApiProviders(self: *ApiRegistry) void {
        var it = self.providers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.source_id) |sid| self.allocator.free(sid);
        }
        self.providers.clearAndFree();
    }
};

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
    return s;
}

fn mockStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;
    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    return s;
}

test "register and get api provider" {
    var registry = ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = ApiProvider{
        .api = "openai-completions",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };

    try registry.registerApiProvider(provider, null);

    const found = registry.getApiProvider("openai-completions");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("openai-completions", found.?.api);
}

test "unregister by source id" {
    var registry = ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = ApiProvider{
        .api = "openai-completions",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };

    try registry.registerApiProvider(provider, "ext-1");
    try std.testing.expect(registry.getApiProvider("openai-completions") != null);

    registry.unregisterApiProviders("ext-1");
    try std.testing.expect(registry.getApiProvider("openai-completions") == null);
}
