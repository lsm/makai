const std = @import("std");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const AuthStatus = enum {
    authenticated,
    login_required,
    expired,
    refreshing,
    login_in_progress,
    failed,
    unknown,
};

pub const ModelLifecycle = enum {
    stable,
    preview,
    deprecated,
};

pub const ModelSource = enum {
    dynamic,
    static_fallback,
};

pub const ModelCapability = enum {
    chat,
    streaming,
    tools,
    vision,
    reasoning,
    prompt_cache,
    audio_input,
    audio_output,
};

pub const ReasoningLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const MetadataEntry = struct {
    key: OwnedSlice(u8),
    value: OwnedSlice(u8),

    pub fn deinit(self: *MetadataEntry, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        self.value.deinit(allocator);
    }
};

pub const ModelDescriptor = struct {
    model_ref: OwnedSlice(u8),
    model_id: OwnedSlice(u8),
    display_name: OwnedSlice(u8),
    provider_id: OwnedSlice(u8),
    api: OwnedSlice(u8),
    base_url: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    auth_status: AuthStatus,
    lifecycle: ModelLifecycle,
    capabilities: OwnedSlice(ModelCapability),
    source: ModelSource,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    reasoning_default: ?ReasoningLevel = null,
    metadata: ?OwnedSlice(MetadataEntry) = null,

    pub fn deinit(self: *ModelDescriptor, allocator: std.mem.Allocator) void {
        self.model_ref.deinit(allocator);
        self.model_id.deinit(allocator);
        self.display_name.deinit(allocator);
        self.provider_id.deinit(allocator);
        self.api.deinit(allocator);
        self.base_url.deinit(allocator);
        self.capabilities.deinit(allocator);

        if (self.metadata) |*entries| {
            entries.deinit(allocator);
            self.metadata = null;
        }
    }
};

pub const ModelsResponse = struct {
    models: OwnedSlice(ModelDescriptor),
    fetched_at_ms: i64,
    cache_max_age_ms: u64,

    pub fn deinit(self: *ModelsResponse, allocator: std.mem.Allocator) void {
        self.models.deinit(allocator);
    }
};

pub fn cloneModelDescriptor(
    allocator: std.mem.Allocator,
    descriptor: ModelDescriptor,
) !ModelDescriptor {
    const model_ref = try allocator.dupe(u8, descriptor.model_ref.slice());
    errdefer allocator.free(model_ref);

    const model_id = try allocator.dupe(u8, descriptor.model_id.slice());
    errdefer allocator.free(model_id);

    const display_name = try allocator.dupe(u8, descriptor.display_name.slice());
    errdefer allocator.free(display_name);

    const provider_id = try allocator.dupe(u8, descriptor.provider_id.slice());
    errdefer allocator.free(provider_id);

    const api = try allocator.dupe(u8, descriptor.api.slice());
    errdefer allocator.free(api);

    const base_url = try allocator.dupe(u8, descriptor.base_url.slice());
    errdefer allocator.free(base_url);

    const capabilities = try allocator.dupe(ModelCapability, descriptor.capabilities.slice());
    errdefer allocator.free(capabilities);

    var metadata: ?OwnedSlice(MetadataEntry) = null;
    if (descriptor.metadata) |entries| {
        const src_entries = entries.slice();
        const copied_entries = try allocator.alloc(MetadataEntry, src_entries.len);
        var copied_count: usize = 0;
        errdefer {
            for (copied_entries[0..copied_count]) |*entry| {
                entry.deinit(allocator);
            }
            allocator.free(copied_entries);
        }

        for (src_entries, 0..) |entry, idx| {
            copied_entries[idx] = .{
                .key = OwnedSlice(u8).initOwned(try allocator.dupe(u8, entry.key.slice())),
                .value = OwnedSlice(u8).initOwned(try allocator.dupe(u8, entry.value.slice())),
            };
            copied_count += 1;
        }

        metadata = OwnedSlice(MetadataEntry).initOwned(copied_entries);
    }

    return .{
        .model_ref = OwnedSlice(u8).initOwned(model_ref),
        .model_id = OwnedSlice(u8).initOwned(model_id),
        .display_name = OwnedSlice(u8).initOwned(display_name),
        .provider_id = OwnedSlice(u8).initOwned(provider_id),
        .api = OwnedSlice(u8).initOwned(api),
        .base_url = OwnedSlice(u8).initOwned(base_url),
        .auth_status = descriptor.auth_status,
        .lifecycle = descriptor.lifecycle,
        .capabilities = OwnedSlice(ModelCapability).initOwned(capabilities),
        .source = descriptor.source,
        .context_window = descriptor.context_window,
        .max_output_tokens = descriptor.max_output_tokens,
        .reasoning_default = descriptor.reasoning_default,
        .metadata = metadata,
    };
}

test "cloneModelDescriptor duplicates nested owned fields" {
    const allocator = std.testing.allocator;

    const capabilities = try allocator.alloc(ModelCapability, 2);
    capabilities[0] = .chat;
    capabilities[1] = .streaming;

    const metadata = try allocator.alloc(MetadataEntry, 1);
    metadata[0] = .{
        .key = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "tier")),
        .value = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "standard")),
    };

    var original = ModelDescriptor{
        .model_ref = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic/anthropic-messages@claude-sonnet-4-5")),
        .model_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "claude-sonnet-4-5")),
        .display_name = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "Claude Sonnet 4.5")),
        .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic")),
        .api = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic-messages")),
        .base_url = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "https://api.anthropic.com")),
        .auth_status = .authenticated,
        .lifecycle = .stable,
        .capabilities = OwnedSlice(ModelCapability).initOwned(capabilities),
        .source = .dynamic,
        .context_window = 200_000,
        .max_output_tokens = 8_192,
        .reasoning_default = .medium,
        .metadata = OwnedSlice(MetadataEntry).initOwned(metadata),
    };
    defer original.deinit(allocator);

    var cloned = try cloneModelDescriptor(allocator, original);
    defer cloned.deinit(allocator);

    try std.testing.expectEqualStrings(original.model_id.slice(), cloned.model_id.slice());
    try std.testing.expectEqualStrings("tier", cloned.metadata.?.slice()[0].key.slice());
    try std.testing.expectEqualStrings("standard", cloned.metadata.?.slice()[0].value.slice());
}
