const std = @import("std");
const ai_types = @import("ai_types");
const compat_mod = @import("compat");
const provider_base_url = @import("provider_base_url");

pub const config_file_name = "providers.json";
pub const max_config_bytes = 2 * 1024 * 1024;

pub const supported_apis = [_][]const u8{
    "openai-completions",
    "openai-responses",
    "anthropic-messages",
};

pub const reserved_ids = [_][]const u8{
    "anthropic",
    "openai",
    "openai-codex",
    "github-copilot",
    "google",
    "google-gemini-cli",
    "azure",
    "ollama",
    "kimi",
    "deepseek",
};

pub const ConfigError = error{
    InvalidConfig,
    MissingProviderId,
    InvalidProviderId,
    ReservedProviderId,
    DuplicateProviderId,
    MissingBaseUrl,
    InvalidBaseUrl,
    UnsupportedApi,
    InvalidAuthMode,
};

pub const ModelSpec = struct {
    id: []const u8,
    name: []const u8,
    context_window: ?u32 = null,
    max_tokens: ?u32 = null,

    fn deinit(self: *ModelSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const CustomProvider = struct {
    id: []const u8,
    name: []const u8,
    api: []const u8,
    base_url: []const u8,
    env_key: ?[]const u8 = null,
    auth_none: bool = false,
    headers: []const ai_types.HeaderPair = &.{},
    models: []const ModelSpec = &.{},
    compat: ?ai_types.OpenAICompatOptions = null,
    reasoning: bool = false,
    context_window: u32 = 128_000,
    max_tokens: u32 = 8_192,

    pub fn deinit(self: *CustomProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.api);
        allocator.free(self.base_url);
        if (self.env_key) |key| allocator.free(key);
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(self.headers);
        for (self.models) |*model| {
            var owned = model.*;
            owned.deinit(allocator);
        }
        allocator.free(self.models);
        self.* = undefined;
    }

    pub fn allows(self: *const CustomProvider, model_id: []const u8) bool {
        if (self.models.len == 0) return true;
        for (self.models) |spec| {
            if (std.mem.eql(u8, spec.id, model_id)) return true;
        }
        return false;
    }

    pub fn specFor(self: *const CustomProvider, model_id: []const u8) ?ModelSpec {
        for (self.models) |spec| {
            if (std.mem.eql(u8, spec.id, model_id)) return spec;
        }
        return null;
    }
};

pub fn deinitProviders(allocator: std.mem.Allocator, providers: []CustomProvider) void {
    for (providers) |*provider| provider.deinit(allocator);
    allocator.free(providers);
}

pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try compat_mod.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".makai", config_file_name });
}

pub fn load(allocator: std.mem.Allocator, max_bytes: usize) ![]CustomProvider {
    const path = configPath(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return allocator.alloc(CustomProvider, 0),
    };
    defer allocator.free(path);
    const data = compat_mod.fs.readFileAlloc(allocator, compat_mod.fs.getCwd(), path, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return allocator.alloc(CustomProvider, 0),
    };
    defer allocator.free(data);
    return parse(allocator, data);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) ![]CustomProvider {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ConfigError.InvalidConfig,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return ConfigError.InvalidConfig;

    const list = parsed.value.object.get("providers") orelse return allocator.alloc(CustomProvider, 0);
    if (list != .array) return ConfigError.InvalidConfig;

    var providers = std.ArrayList(CustomProvider).empty;
    errdefer {
        for (providers.items) |*provider| provider.deinit(allocator);
        providers.deinit(allocator);
    }

    for (list.array.items) |item| {
        if (item != .object) return ConfigError.InvalidConfig;
        const provider = try parseProvider(allocator, &item.object);
        errdefer {
            var owned = provider;
            owned.deinit(allocator);
        }
        for (providers.items) |existing| {
            if (std.mem.eql(u8, existing.id, provider.id)) return ConfigError.DuplicateProviderId;
        }
        try providers.append(allocator, provider);
    }

    return providers.toOwnedSlice(allocator);
}

fn parseProvider(allocator: std.mem.Allocator, obj: *const std.json.ObjectMap) !CustomProvider {
    const raw_id = objectString(obj, "id") orelse return ConfigError.MissingProviderId;
    try validateId(raw_id);

    const raw_base = objectString(obj, "base_url") orelse return ConfigError.MissingBaseUrl;
    const base_trimmed = provider_base_url.normalizeVersionedBaseUrl(raw_base);
    if (base_trimmed.len == 0) return ConfigError.MissingBaseUrl;
    _ = std.Uri.parse(base_trimmed) catch return ConfigError.InvalidBaseUrl;

    const raw_api = objectString(obj, "api") orelse "openai-completions";
    if (!isSupportedApi(raw_api)) return ConfigError.UnsupportedApi;

    var provider = CustomProvider{
        .id = try allocator.dupe(u8, raw_id),
        .name = undefined,
        .api = undefined,
        .base_url = undefined,
    };
    errdefer allocator.free(provider.id);

    provider.name = try allocator.dupe(u8, objectString(obj, "name") orelse raw_id);
    errdefer allocator.free(provider.name);

    provider.api = try allocator.dupe(u8, raw_api);
    errdefer allocator.free(provider.api);

    provider.base_url = try allocator.dupe(u8, base_trimmed);
    errdefer allocator.free(provider.base_url);

    if (obj.getPtr("auth")) |auth_value| {
        switch (auth_value.*) {
            .string => |mode| {
                if (!std.mem.eql(u8, mode, "none")) return ConfigError.InvalidAuthMode;
                provider.auth_none = true;
            },
            .object => {
                const env_name = objectString(&auth_value.object, "env") orelse
                    return ConfigError.InvalidAuthMode;
                if (env_name.len == 0) return ConfigError.InvalidAuthMode;
                provider.env_key = try allocator.dupe(u8, env_name);
            },
            else => return ConfigError.InvalidAuthMode,
        }
    }
    errdefer if (provider.env_key) |key| allocator.free(key);

    provider.headers = try parseHeaders(allocator, obj);
    errdefer {
        for (provider.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(provider.headers);
    }

    provider.models = try parseModels(allocator, obj);
    errdefer {
        for (provider.models) |*model| {
            var owned = model.*;
            owned.deinit(allocator);
        }
        allocator.free(provider.models);
    }

    provider.reasoning = objectBool(obj, "reasoning") orelse false;
    provider.context_window = objectU32(obj, "context_window") orelse 128_000;
    provider.max_tokens = objectU32(obj, "max_tokens") orelse 8_192;
    provider.compat = parseCapabilities(obj);
    return provider;
}

fn parseHeaders(allocator: std.mem.Allocator, obj: *const std.json.ObjectMap) ![]const ai_types.HeaderPair {
    const headers = objectObject(obj, "headers") orelse return &.{};
    var list = std.ArrayList(ai_types.HeaderPair).empty;
    errdefer {
        for (list.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        list.deinit(allocator);
    }
    var it = headers.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        if (entry.key_ptr.*.len == 0) continue;
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, entry.value_ptr.*.string);
        errdefer allocator.free(value);
        try list.append(allocator, .{ .name = name, .value = value });
    }
    return list.toOwnedSlice(allocator);
}

fn parseModels(allocator: std.mem.Allocator, obj: *const std.json.ObjectMap) ![]const ModelSpec {
    const value = obj.get("models") orelse return &.{};
    if (value != .array) return ConfigError.InvalidConfig;

    var list = std.ArrayList(ModelSpec).empty;
    errdefer {
        for (list.items) |*spec| spec.deinit(allocator);
        list.deinit(allocator);
    }

    for (value.array.items) |entry| {
        switch (entry) {
            .string => |id| {
                if (id.len == 0) continue;
                const owned_id = try allocator.dupe(u8, id);
                errdefer allocator.free(owned_id);
                const owned_name = try allocator.dupe(u8, id);
                errdefer allocator.free(owned_name);
                try list.append(allocator, .{ .id = owned_id, .name = owned_name });
            },
            .object => |model_obj| {
                const id = objectString(&model_obj, "id") orelse return ConfigError.InvalidConfig;
                if (id.len == 0) return ConfigError.InvalidConfig;
                const owned_id = try allocator.dupe(u8, id);
                errdefer allocator.free(owned_id);
                const owned_name = try allocator.dupe(u8, objectString(&model_obj, "name") orelse id);
                errdefer allocator.free(owned_name);
                try list.append(allocator, .{
                    .id = owned_id,
                    .name = owned_name,
                    .context_window = objectU32(&model_obj, "context_window"),
                    .max_tokens = objectU32(&model_obj, "max_tokens"),
                });
            },
            else => return ConfigError.InvalidConfig,
        }
    }

    return list.toOwnedSlice(allocator);
}

fn parseCapabilities(obj: *const std.json.ObjectMap) ?ai_types.OpenAICompatOptions {
    const caps = objectObject(obj, "capabilities") orelse return null;
    var options = ai_types.OpenAICompatOptions{};
    var any = false;

    if (objectBool(caps, "cache_ttl")) |value| {
        options.supports_anthropic_cache_ttl = value;
        any = true;
    }
    if (objectBool(caps, "reasoning_effort")) |value| {
        options.supports_reasoning_effort = value;
        any = true;
    }
    if (objectBool(caps, "developer_role")) |value| {
        options.supports_developer_role = value;
        any = true;
    }
    if (objectBool(caps, "store")) |value| {
        options.supports_store = value;
        any = true;
    }
    if (objectBool(caps, "strict_mode")) |value| {
        options.supports_strict_mode = value;
        any = true;
    }
    if (objectBool(caps, "thinking_as_text")) |value| {
        options.requires_thinking_as_text = value;
        any = true;
    }
    if (objectBool(caps, "usage_in_streaming")) |value| {
        options.supports_usage_in_streaming = value;
        any = true;
    }
    if (objectString(caps, "max_tokens_field")) |value| {
        if (std.mem.eql(u8, value, "max_tokens")) {
            options.max_tokens_field = .max_tokens;
            any = true;
        } else if (std.mem.eql(u8, value, "max_completion_tokens")) {
            options.max_tokens_field = .max_completion_tokens;
            any = true;
        }
    }
    if (objectString(caps, "thinking_format")) |value| {
        if (std.mem.eql(u8, value, "zai")) {
            options.thinking_format = .zai;
            any = true;
        } else if (std.mem.eql(u8, value, "qwen")) {
            options.thinking_format = .qwen;
            any = true;
        } else if (std.mem.eql(u8, value, "openai")) {
            options.thinking_format = .openai;
            any = true;
        }
    }

    return if (any) options else null;
}

test "declaring one capability leaves the rest unset" {
    const json =
        \\{"providers":[{
        \\  "id":"gateway","name":"Gateway","api":"openai-completions",
        \\  "base_url":"https://gw.internal",
        \\  "capabilities":{"cache_ttl":true}
        \\}]}
    ;
    const providers = try parse(testing.allocator, json);
    defer deinitProviders(testing.allocator, providers);

    const caps = providers[0].compat orelse return error.TestExpectedCapabilities;
    try testing.expectEqual(@as(?bool, true), caps.supports_anthropic_cache_ttl);
    try testing.expect(caps.max_tokens_field == null);
    try testing.expect(caps.thinking_format == null);
    try testing.expectEqual(@as(?bool, null), caps.supports_strict_mode);
    try testing.expectEqual(@as(?bool, null), caps.supports_usage_in_streaming);
    try testing.expectEqual(@as(?bool, null), caps.supports_store);
    try testing.expectEqual(@as(?bool, null), caps.supports_developer_role);
    try testing.expectEqual(@as(?bool, null), caps.supports_reasoning_effort);
}

test "an explicit max_tokens_field is carried through" {
    const json =
        \\{"providers":[{
        \\  "id":"gateway","name":"Gateway","api":"openai-completions",
        \\  "base_url":"https://gw.internal",
        \\  "capabilities":{"max_tokens_field":"max_completion_tokens","strict_mode":true}
        \\}]}
    ;
    const providers = try parse(testing.allocator, json);
    defer deinitProviders(testing.allocator, providers);

    const caps = providers[0].compat orelse return error.TestExpectedCapabilities;
    try testing.expect(caps.max_tokens_field.? == .max_completion_tokens);
    try testing.expectEqual(@as(?bool, true), caps.supports_strict_mode);
}

fn validateId(id: []const u8) ConfigError!void {
    if (id.len == 0) return ConfigError.MissingProviderId;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return ConfigError.InvalidProviderId;
    }
    for (reserved_ids) |reserved| {
        if (std.mem.eql(u8, id, reserved)) return ConfigError.ReservedProviderId;
    }
}

fn isSupportedApi(api: []const u8) bool {
    for (supported_apis) |supported| {
        if (std.mem.eql(u8, api, supported)) return true;
    }
    return false;
}

fn objectString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn objectBool(obj: *const std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn objectU32(obj: *const std.json.ObjectMap, key: []const u8) ?u32 {
    const value = obj.get(key) orelse return null;
    if (value != .integer) return null;
    if (value.integer < 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

fn objectObject(obj: *const std.json.ObjectMap, key: []const u8) ?*const std.json.ObjectMap {
    const value = obj.getPtr(key) orelse return null;
    if (value.* != .object) return null;
    return &value.object;
}

const testing = std.testing;

fn parseOne(allocator: std.mem.Allocator, data: []const u8) !CustomProvider {
    const providers = try parse(allocator, data);
    errdefer deinitProviders(allocator, providers);
    try testing.expectEqual(@as(usize, 1), providers.len);
    const single = providers[0];
    allocator.free(providers);
    return single;
}

test "custom providers parse a minimal entry and default the api" {
    var provider = try parseOne(testing.allocator,
        \\{"providers":[{"id":"vllm","base_url":"http://localhost:8000/v1/"}]}
    );
    defer provider.deinit(testing.allocator);

    try testing.expectEqualStrings("vllm", provider.id);
    try testing.expectEqualStrings("vllm", provider.name);
    try testing.expectEqualStrings("openai-completions", provider.api);
    try testing.expectEqualStrings("http://localhost:8000", provider.base_url);
    try testing.expect(provider.env_key == null);
    try testing.expect(provider.compat == null);
    try testing.expectEqual(@as(usize, 0), provider.models.len);
    try testing.expect(provider.allows("anything-at-all"));
}

test "custom providers parse headers models capabilities and auth" {
    var provider = try parseOne(testing.allocator,
        \\{"providers":[{
        \\  "id":"gateway","name":"Internal Gateway","api":"anthropic-messages",
        \\  "base_url":"https://gw.internal/anthropic",
        \\  "auth":{"env":"GATEWAY_TOKEN"},
        \\  "headers":{"X-Tenant":"acme"},
        \\  "reasoning":true,
        \\  "models":["claude-sonnet-4-5",{"id":"claude-opus-4-1","name":"Opus","context_window":200000,"max_tokens":32000}],
        \\  "capabilities":{"cache_ttl":true,"max_tokens_field":"max_tokens","thinking_format":"zai"}
        \\}]}
    );
    defer provider.deinit(testing.allocator);

    try testing.expectEqualStrings("Internal Gateway", provider.name);
    try testing.expectEqualStrings("anthropic-messages", provider.api);
    try testing.expectEqualStrings("GATEWAY_TOKEN", provider.env_key.?);
    try testing.expect(provider.reasoning);

    try testing.expectEqual(@as(usize, 1), provider.headers.len);
    try testing.expectEqualStrings("X-Tenant", provider.headers[0].name);
    try testing.expectEqualStrings("acme", provider.headers[0].value);

    try testing.expectEqual(@as(usize, 2), provider.models.len);
    try testing.expectEqualStrings("claude-sonnet-4-5", provider.models[0].id);
    try testing.expectEqualStrings("claude-sonnet-4-5", provider.models[0].name);
    try testing.expect(provider.models[0].context_window == null);
    try testing.expectEqualStrings("Opus", provider.models[1].name);
    try testing.expectEqual(@as(?u32, 200000), provider.models[1].context_window);

    const caps = provider.compat.?;
    try testing.expectEqual(@as(?bool, true), caps.supports_anthropic_cache_ttl);
    try testing.expect(caps.max_tokens_field.? == .max_tokens);
    try testing.expect(caps.thinking_format.? == .zai);
}

test "custom providers treat a declared model list as an allowlist" {
    var provider = try parseOne(testing.allocator,
        \\{"providers":[{"id":"router","base_url":"https://openrouter.ai/api/v1","models":["a/one","b/two"]}]}
    );
    defer provider.deinit(testing.allocator);

    try testing.expect(provider.allows("a/one"));
    try testing.expect(provider.allows("b/two"));
    try testing.expect(!provider.allows("c/three"));
    try testing.expect(provider.specFor("b/two") != null);
    try testing.expect(provider.specFor("c/three") == null);
}

test "custom providers reject malformed entries" {
    const cases = [_]struct { data: []const u8, want: ConfigError }{
        .{ .data =
        \\{"providers":[{"base_url":"https://x.test"}]}
        , .want = ConfigError.MissingProviderId },
        .{ .data =
        \\{"providers":[{"id":"anthropic","base_url":"https://x.test"}]}
        , .want = ConfigError.ReservedProviderId },
        .{ .data =
        \\{"providers":[{"id":"has space","base_url":"https://x.test"}]}
        , .want = ConfigError.InvalidProviderId },
        .{ .data =
        \\{"providers":[{"id":"ok"}]}
        , .want = ConfigError.MissingBaseUrl },
        .{ .data =
        \\{"providers":[{"id":"ok","base_url":"not a url"}]}
        , .want = ConfigError.InvalidBaseUrl },
        .{ .data =
        \\{"providers":[{"id":"ok","base_url":"https://x.test","api":"google-generative-ai"}]}
        , .want = ConfigError.UnsupportedApi },
        .{ .data =
        \\{"providers":[{"id":"dup","base_url":"https://x.test"},{"id":"dup","base_url":"https://y.test"}]}
        , .want = ConfigError.DuplicateProviderId },
        .{ .data =
        \\not json at all
        , .want = ConfigError.InvalidConfig },
        .{ .data =
        \\{"providers":[{"id":"ok","base_url":"https://x.test","models":[12]}]}
        , .want = ConfigError.InvalidConfig },
        .{ .data =
        \\{"providers":[{"id":"ok","base_url":"https://x.test","auth":"anonymous"}]}
        , .want = ConfigError.InvalidAuthMode },
        .{ .data =
        \\{"providers":[{"id":"ok","base_url":"https://x.test","auth":true}]}
        , .want = ConfigError.InvalidAuthMode },
        .{ .data =
        \\{"providers":[{"id":"ok","base_url":"https://x.test","auth":{"env":5}}]}
        , .want = ConfigError.InvalidAuthMode },
        .{ .data =
        \\{"providers":[{"id":"ok","base_url":"https://x.test","auth":{"env":""}}]}
        , .want = ConfigError.InvalidAuthMode },
        .{ .data =
        \\{"providers":[{"id":"ok","base_url":"https://x.test","auth":{}}]}
        , .want = ConfigError.InvalidAuthMode },
        .{ .data =
        \\{"providers":[{"id":"ok","base_url":"https://x.test","auth":{"environment":"K"}}]}
        , .want = ConfigError.InvalidAuthMode },
    };

    for (cases) |case| {
        try testing.expectError(case.want, parse(testing.allocator, case.data));
    }
}

test "auth none is an explicit opt-in and stays off otherwise" {
    var keyless = try parseOne(testing.allocator,
        \\{"providers":[{"id":"local","base_url":"http://localhost:8000/v1","auth":"none"}]}
    );
    defer keyless.deinit(testing.allocator);
    try testing.expect(keyless.auth_none);
    try testing.expect(keyless.env_key == null);

    var env_keyed = try parseOne(testing.allocator,
        \\{"providers":[{"id":"gw","base_url":"https://gw.test","auth":{"env":"GW_KEY"}}]}
    );
    defer env_keyed.deinit(testing.allocator);
    try testing.expect(!env_keyed.auth_none);
    try testing.expectEqualStrings("GW_KEY", env_keyed.env_key.?);

    var silent = try parseOne(testing.allocator,
        \\{"providers":[{"id":"gw","base_url":"https://gw.test"}]}
    );
    defer silent.deinit(testing.allocator);
    try testing.expect(!silent.auth_none);
    try testing.expect(silent.env_key == null);
}

test "custom providers tolerate an absent or empty providers array" {
    for ([_][]const u8{ "{}", "{\"providers\":[]}" }) |data| {
        const providers = try parse(testing.allocator, data);
        defer deinitProviders(testing.allocator, providers);
        try testing.expectEqual(@as(usize, 0), providers.len);
    }
}

fn parseProbe(allocator: std.mem.Allocator) !void {
    const providers = try parse(allocator,
        \\{"providers":[
        \\ {"id":"one","base_url":"https://one.test","headers":{"A":"1","B":"2"},"models":["m1",{"id":"m2"}]},
        \\ {"id":"two","name":"Two","base_url":"https://two.test","auth":{"env":"K"},"capabilities":{"store":true}}
        \\]}
    );
    defer deinitProviders(allocator, providers);
    try testing.expectEqual(@as(usize, 2), providers.len);
}

test "custom providers free every allocation when parsing fails midway" {
    try parseProbe(testing.allocator);
    try testing.checkAllAllocationFailures(testing.allocator, parseProbe, .{});
}

test "custom providers normalise a versioned base url to the origin the providers expect" {
    const cases = [_]struct { given: []const u8, want: []const u8 }{
        .{ .given = "https://api.groq.com/openai/v1", .want = "https://api.groq.com/openai" },
        .{ .given = "https://api.groq.com/openai/v1/", .want = "https://api.groq.com/openai" },
        .{ .given = "http://localhost:8000/v1", .want = "http://localhost:8000" },
        .{ .given = "https://gw.internal/anthropic", .want = "https://gw.internal/anthropic" },
    };
    for (cases) |case| {
        const data = try std.fmt.allocPrint(testing.allocator,
            \\{{"providers":[{{"id":"probe","base_url":"{s}"}}]}}
        , .{case.given});
        defer testing.allocator.free(data);
        var provider = try parseOne(testing.allocator, data);
        defer provider.deinit(testing.allocator);
        try testing.expectEqualStrings(case.want, provider.base_url);
    }
}
