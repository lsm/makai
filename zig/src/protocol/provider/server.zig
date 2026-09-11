const std = @import("std");
const compat = @import("compat");
const protocol_types = @import("protocol_types");
const envelope = @import("protocol_envelope");
const partial_serializer = @import("partial_serializer.zig");
const model_ref = @import("model_ref");
const model_catalog_types = @import("model_catalog_types");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");
const hive_array = @import("hive_array");
const auth_resolver = @import("auth_resolver");
const oauth_storage = @import("oauth/storage");
const refresh_lock_mod = @import("oauth/refresh_lock");
const oom = @import("oom");
const provider_base_url = @import("provider_base_url");

pub const AuthStorage = oauth_storage.AuthStorage;

pub const SequenceError = error{
    InvalidSequence,
    DuplicateSequence,
    SequenceGap,
};

fn validateSequence(expected: u64, received: u64) SequenceError!void {
    if (received == 0) return error.InvalidSequence;
    if (received < expected) return error.DuplicateSequence;
    if (received > expected) return error.SequenceGap;
}

fn createSequenceNack(
    allocator: std.mem.Allocator,
    stream_id: protocol_types.Ulid,
    message_id: protocol_types.Ulid,
    err: SequenceError,
) !protocol_types.Envelope {
    const reason: []const u8 = switch (err) {
        error.InvalidSequence => "Invalid sequence number (must be >= 1)",
        error.DuplicateSequence => "Duplicate sequence number detected",
        error.SequenceGap => "Sequence gap detected (missing messages)",
    };
    const error_code: protocol_types.ErrorCode = switch (err) {
        error.InvalidSequence => .invalid_sequence,
        error.DuplicateSequence => .duplicate_sequence,
        error.SequenceGap => .sequence_gap,
    };
    return try envelope.createNack(
        .{
            .stream_id = stream_id,
            .message_id = message_id,
            .sequence = 0,
            .timestamp = compat.time.nowMillis(),
            .payload = .ping,
        },
        reason,
        error_code,
        allocator,
    );
}

const DYNAMIC_CACHE_MAX_AGE_MS: u64 = 300_000;
const STATIC_FALLBACK_CACHE_MAX_AGE_MS: u64 = 3_600_000;

const StaticCatalogEntry = struct {
    provider_id: []const u8,
    api: []const u8,
    model_id: []const u8,
    display_name: []const u8,
    base_url: []const u8 = "",
    auth_status: protocol_types.AuthStatus = .login_required,
    lifecycle: protocol_types.ModelLifecycle = .stable,
    capabilities: []const protocol_types.ModelCapability,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    reasoning_default: ?protocol_types.ReasoningLevel = null,
};

const CAP_CHAT_STREAMING = [_]protocol_types.ModelCapability{ .chat, .streaming };
const CAP_CHAT_STREAMING_REASONING = [_]protocol_types.ModelCapability{ .chat, .streaming, .reasoning };
const CAP_CHAT_STREAMING_TOOLS_REASONING = [_]protocol_types.ModelCapability{ .chat, .streaming, .tools, .reasoning };

const STATIC_MODEL_CATALOG = [_]StaticCatalogEntry{
    .{
        .provider_id = "anthropic",
        .api = "anthropic-messages",
        .model_id = "claude-sonnet-4-5",
        .display_name = "Claude Sonnet 4.5",
        .base_url = "https://api.anthropic.com",
        .auth_status = .unknown,
        .lifecycle = .stable,
        .capabilities = &CAP_CHAT_STREAMING_TOOLS_REASONING,
        .context_window = 200_000,
        .max_output_tokens = 8_192,
        .reasoning_default = .medium,
    },
    .{
        .provider_id = "openai",
        .api = "openai-responses",
        .model_id = "gpt-4o",
        .display_name = "GPT-4o (Responses)",
        .base_url = "https://api.openai.com",
        .auth_status = .unknown,
        .lifecycle = .stable,
        .capabilities = &CAP_CHAT_STREAMING_REASONING,
        .context_window = 128_000,
        .max_output_tokens = 16_384,
        .reasoning_default = .high,
    },
    .{
        .provider_id = "openai",
        .api = "openai-completions",
        .model_id = "gpt-4o",
        .display_name = "GPT-4o (Completions)",
        .base_url = "https://api.openai.com",
        .auth_status = .unknown,
        .lifecycle = .stable,
        .capabilities = &CAP_CHAT_STREAMING,
        .context_window = 128_000,
        .max_output_tokens = 4_096,
    },
    .{
        .provider_id = "ollama",
        .api = "ollama",
        .model_id = "qwen2.5:7b",
        .display_name = "Qwen2.5 7B",
        .base_url = "http://localhost:11434",
        .auth_status = .unknown,
        .lifecycle = .stable,
        .capabilities = &CAP_CHAT_STREAMING,
        .context_window = 32_768,
        .max_output_tokens = 8_192,
    },
    .{
        .provider_id = "openai",
        .api = "openai-completions",
        .model_id = "gpt-3.5-turbo",
        .display_name = "GPT-3.5 Turbo",
        .base_url = "https://api.openai.com",
        .auth_status = .unknown,
        .lifecycle = .deprecated,
        .capabilities = &CAP_CHAT_STREAMING,
        .context_window = 16_384,
        .max_output_tokens = 4_096,
    },
};

const ModelRequestResolveError = error{
    ModelNotFound,
    AmbiguousModelId,
    NotImplemented,
};

const AuthDispatchError = error{
    AuthRequired,
    AuthExpired,
    AuthRefreshFailed,
};

const AUTH_REFRESH_FAILED_MESSAGE = "auth_refresh_failed";
const AUTH_REQUIRED_MESSAGE = "auth_required";
const AUTH_EXPIRED_MESSAGE = "auth_expired";

fn defaultAuthFailureDetector(err_msg: []const u8) bool {
    return std.mem.eql(u8, err_msg, AUTH_REQUIRED_MESSAGE) or
        std.mem.eql(u8, err_msg, AUTH_EXPIRED_MESSAGE) or
        std.mem.find(u8, err_msg, "401") != null or
        std.mem.find(u8, err_msg, "403") != null or
        std.ascii.indexOfIgnoreCase(err_msg, "unauthorized") != null or
        std.ascii.indexOfIgnoreCase(err_msg, "forbidden") != null;
}

pub fn streamErrorCode(err_msg: []const u8) protocol_types.ErrorCode {
    if (std.mem.eql(u8, err_msg, AUTH_REFRESH_FAILED_MESSAGE)) return .auth_refresh_failed;
    if (std.mem.eql(u8, err_msg, AUTH_EXPIRED_MESSAGE)) return .auth_expired;
    if (std.mem.eql(u8, err_msg, AUTH_REQUIRED_MESSAGE)) return .auth_required;
    return .provider_error;
}

fn providerErrorCode(err: anyerror) protocol_types.ErrorCode {
    if (err == error.AuthRefreshFailed) return .auth_refresh_failed;
    if (err == error.AuthExpired) return .auth_expired;
    if (err == error.AuthRequired or err == error.MissingApiKey) return .auth_required;
    return .provider_error;
}

fn providerErrorMessage(err: anyerror) []const u8 {
    if (err == error.OutOfMemory) return "Out of memory";
    if (err == error.AuthRefreshFailed) return AUTH_REFRESH_FAILED_MESSAGE;
    if (err == error.AuthExpired) return AUTH_EXPIRED_MESSAGE;
    if (err == error.AuthRequired or err == error.MissingApiKey) return AUTH_REQUIRED_MESSAGE;
    return "Failed to create stream";
}

pub const ProtocolServer = struct {
    allocator: std.mem.Allocator,

    active_streams: std.AutoHashMap(protocol_types.Ulid, ActiveStream),

    registry: *api_registry.ApiRegistry,

    sequence_counters: std.AutoHashMap(protocol_types.Ulid, u64),

    expected_sequences: std.AutoHashMap(protocol_types.Ulid, u64),

    outbox: std.ArrayList(protocol_types.Envelope),

    pending_cleanup: std.ArrayList(ActiveStream),

    options: Options,

    refresh_lock: refresh_lock_mod.RefreshLock,

    pub const ActiveStream = struct {
        stream_id: protocol_types.Ulid,
        model: ai_types.Model,
        event_stream: *event_stream.AssistantMessageEventStream,
        partial_state: partial_serializer.PartialState,
        started_at: i64,
        cancelled: ?*std.atomic.Value(bool) = null,
    };

    pub const DynamicCatalogFetchFn = *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: protocol_types.ModelsRequest,
    ) anyerror!protocol_types.ModelsResponse;

    pub const LoadAuthStorageFn = *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!oauth_storage.AuthStorage;

    fn defaultLoadAuthStorage(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!oauth_storage.AuthStorage {
        _ = ctx;
        return oauth_storage.AuthStorage.loadDefault(allocator);
    }

    pub const Options = struct {
        include_partial: bool = false,
        max_streams: usize = 100,
        stream_timeout_ms: u64 = 300_000,
        supports_model_catalog: bool = true,
        enable_static_catalog_fallback: bool = true,
        dynamic_catalog_fetcher: ?DynamicCatalogFetchFn = null,
        dynamic_catalog_ctx: ?*anyopaque = null,
        load_auth_storage_fn: LoadAuthStorageFn = defaultLoadAuthStorage,
        load_auth_storage_ctx: ?*anyopaque = null,
        auth_storage: ?*AuthStorage = null,
    };

    pub fn init(allocator: std.mem.Allocator, registry: *api_registry.ApiRegistry, options: Options) ProtocolServer {
        return .{
            .allocator = allocator,
            .active_streams = std.AutoHashMap(protocol_types.Ulid, ActiveStream).init(allocator),
            .registry = registry,
            .sequence_counters = std.AutoHashMap(protocol_types.Ulid, u64).init(allocator),
            .expected_sequences = std.AutoHashMap(protocol_types.Ulid, u64).init(allocator),
            .outbox = std.ArrayList(protocol_types.Envelope).empty,
            .pending_cleanup = std.ArrayList(ActiveStream).empty,
            .options = options,
            .refresh_lock = refresh_lock_mod.RefreshLock.init(allocator),
        };
    }

    pub fn deinit(self: *ProtocolServer) void {
        self.refresh_lock.deinit();
        var iter = self.active_streams.iterator();
        while (iter.next()) |entry| {
            var active_stream = entry.value_ptr.*;
            active_stream.partial_state.deinit();
            active_stream.event_stream.deinit();
            self.allocator.destroy(active_stream.event_stream);
            if (active_stream.cancelled) |c| {
                self.allocator.destroy(c);
            }
        }
        self.active_streams.deinit();
        self.sequence_counters.deinit();
        self.expected_sequences.deinit();
        for (self.outbox.items) |*out| {
            out.deinit(self.allocator);
        }
        self.outbox.deinit(self.allocator);

        for (self.pending_cleanup.items) |*stream| {
            stream.partial_state.deinit();
            stream.event_stream.deinit();
            self.allocator.destroy(stream.event_stream);
            if (stream.cancelled) |c| {
                self.allocator.destroy(c);
            }
        }
        self.pending_cleanup.deinit(self.allocator);

        self.* = undefined;
    }

    pub fn popOutbound(self: *ProtocolServer) ?protocol_types.Envelope {
        if (self.outbox.items.len == 0) return null;
        return self.outbox.orderedRemove(0);
    }

    pub fn handleEnvelope(self: *ProtocolServer, env: protocol_types.Envelope) !?protocol_types.Envelope {
        if (env.version != protocol_types.PROTOCOL_VERSION) {
            return try envelope.createVersionMismatchNack(env, self.allocator);
        }

        switch (env.payload) {
            .stream_request => |req| {
                if (env.sequence != 1) {
                    return try createSequenceNack(self.allocator, env.stream_id, env.message_id, error.InvalidSequence);
                }
                return try handleStreamRequest(self, req, env.stream_id, env.message_id, env.sequence);
            },
            .models_request => |request| {
                return try handleModelsRequest(self, request, env.stream_id, env.message_id, env.sequence);
            },
            .abort_request => |req| {
                return try handleAbortRequest(self, req, env.stream_id, env.message_id, env.sequence);
            },
            .complete_request => |req| {
                if (env.sequence != 1) {
                    return try createSequenceNack(self.allocator, env.stream_id, env.message_id, error.InvalidSequence);
                }
                return try handleCompleteRequest(self, req, env.stream_id, env.message_id, env.sequence);
            },
            .ack, .nack, .event, .result, .stream_error, .models_response => {
                return null;
            },
            .ping => {
                const ping_id_str = try protocol_types.ulidToString(env.message_id, self.allocator);
                const pong_payload: protocol_types.Payload = .{ .pong = .{ .ping_id = protocol_types.OwnedSlice(u8).initOwned(ping_id_str) } };
                return envelope.createReply(env, pong_payload, self.allocator);
            },
            .pong => {
                return null;
            },
            .goodbye => {
                return null;
            },
            .sync_request => {
                return try envelope.createNack(
                    env,
                    "Sync not yet implemented",
                    protocol_types.ErrorCode.not_implemented,
                    self.allocator,
                );
            },
            .sync => {
                return null;
            },
        }
    }

    pub fn cleanupCompletedStreams(self: *ProtocolServer) void {
        const CleanupNode = struct {
            stream_id: protocol_types.Ulid,
            next: ?*@This() = null,
        };
        var remove_pool = hive_array.HiveArray(CleanupNode, 128).init();
        var remove_head: ?*CleanupNode = null;

        var overflow = std.ArrayList(protocol_types.Ulid).initCapacity(self.allocator, 8) catch return;
        defer overflow.deinit(self.allocator);

        var iter = self.active_streams.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.event_stream.isDone()) continue;

            if (remove_pool.get()) |node| {
                node.* = .{
                    .stream_id = entry.key_ptr.*,
                    .next = remove_head,
                };
                remove_head = node;
            } else {
                overflow.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        var current = remove_head;
        while (current) |node| {
            const stream_id = node.stream_id;
            const next = node.next;

            if (self.active_streams.fetchRemove(stream_id)) |removed| {
                var partial = removed.value.partial_state;
                partial.deinit();
                removed.value.event_stream.deinit();
                self.allocator.destroy(removed.value.event_stream);
                if (removed.value.cancelled) |c| {
                    self.allocator.destroy(c);
                }
            }
            _ = self.sequence_counters.remove(stream_id);
            _ = self.expected_sequences.remove(stream_id);

            remove_pool.put(node);
            current = next;
        }

        for (overflow.items) |stream_id| {
            if (self.active_streams.fetchRemove(stream_id)) |removed| {
                var partial = removed.value.partial_state;
                partial.deinit();
                removed.value.event_stream.deinit();
                self.allocator.destroy(removed.value.event_stream);
                if (removed.value.cancelled) |c| {
                    self.allocator.destroy(c);
                }
            }
            _ = self.sequence_counters.remove(stream_id);
            _ = self.expected_sequences.remove(stream_id);
        }

        var cleanup_list = self.pending_cleanup;
        self.pending_cleanup = std.ArrayList(ActiveStream).empty;
        for (cleanup_list.items) |*stream| {
            stream.partial_state.deinit();
            stream.event_stream.deinit();
            self.allocator.destroy(stream.event_stream);
            if (stream.cancelled) |c| {
                self.allocator.destroy(c);
            }
        }
        cleanup_list.deinit(self.allocator);
    }

    pub fn activeStreamCount(self: *ProtocolServer) usize {
        return self.active_streams.count();
    }

    pub const ActiveStreamIterator = struct {
        iter: std.AutoHashMap(protocol_types.Ulid, ActiveStream).Iterator,

        pub fn next(self: *ActiveStreamIterator) ?struct {
            stream_id: protocol_types.Ulid,
            stream: *ActiveStream,
        } {
            if (self.iter.next()) |entry| {
                return .{
                    .stream_id = entry.key_ptr.*,
                    .stream = entry.value_ptr,
                };
            }
            return null;
        }
    };

    pub fn activeStreamIterator(self: *ProtocolServer) ActiveStreamIterator {
        return .{
            .iter = self.active_streams.iterator(),
        };
    }

    pub fn getNextSequence(self: *ProtocolServer, stream_id: protocol_types.Ulid) u64 {
        return self.nextSequence(stream_id);
    }

    fn nextSequence(self: *ProtocolServer, stream_id: protocol_types.Ulid) u64 {
        const current = self.sequence_counters.get(stream_id) orelse 0;
        const next = current + 1;
        self.sequence_counters.put(stream_id, next) catch return next;
        return next;
    }

    fn validateAndUpdateSequence(self: *ProtocolServer, stream_id: protocol_types.Ulid, received: u64) SequenceError!void {
        const expected = self.expected_sequences.get(stream_id) orelse 1;
        try validateSequence(expected, received);
        self.expected_sequences.put(stream_id, received + 1) catch {};
    }
};

fn nackTemplate(stream_id: protocol_types.Ulid, in_reply_to: protocol_types.Ulid) protocol_types.Envelope {
    return .{
        .stream_id = stream_id,
        .message_id = in_reply_to,
        .sequence = 0,
        .timestamp = compat.time.nowMillis(),
        .payload = .ping,
    };
}

fn injectApiKey(
    allocator: std.mem.Allocator,
    options: ?ai_types.StreamOptions,
    api_key: []const u8,
) !ai_types.StreamOptions {
    var resolved = options orelse ai_types.StreamOptions{};
    resolved.api_key = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, api_key));
    return resolved;
}

fn deinitInjectedApiKey(allocator: std.mem.Allocator, injected: *ai_types.StreamOptions) void {
    injected.api_key.deinit(allocator);
    injected.api_key = ai_types.OwnedSlice(u8).initBorrowed("");
}

fn injectServerOptions(
    options: ?ai_types.StreamOptions,
    cancel_token: ai_types.CancelToken,
) ai_types.StreamOptions {
    var resolved = options orelse ai_types.StreamOptions{};
    resolved.cancel_token = cancel_token;
    resolved.requires_owned_stream_events = true;
    return resolved;
}

fn authProvider(provider: api_registry.ApiProvider) ?oauth_storage.OAuthProvider {
    const provider_id = provider.auth_provider_id orelse return null;
    return .{
        .id = provider_id,
        .refresh_fn = provider.auth_refresh_fn orelse return null,
        .get_api_key_fn = provider.auth_get_api_key_fn orelse return null,
    };
}

fn streamWithResolvedKey(
    server: *ProtocolServer,
    provider: api_registry.ApiProvider,
    provider_id: []const u8,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
) !*event_stream.AssistantMessageEventStream {
    var loaded_storage: ?oauth_storage.AuthStorage = null;
    defer if (loaded_storage) |*storage| storage.deinit();

    const storage = if (server.options.auth_storage) |auth_storage|
        auth_storage
    else
        blk: {
            loaded_storage = oauth_storage.AuthStorage.loadDefaultStoredOnly(server.allocator) catch
                break :blk null;
            break :blk @as(?*oauth_storage.AuthStorage, &loaded_storage.?);
        };

    const resolved = auth_resolver.resolveApiKey(server.allocator, storage, provider_id, null) catch |err| switch (err) {
        error.AuthRequired => return provider.stream(model, context, options, server.allocator),
        error.OutOfMemory => return error.OutOfMemory,
    };
    var resolved_options = try injectApiKey(server.allocator, options, resolved.api_key);
    defer {
        server.allocator.free(resolved.api_key);
        deinitInjectedApiKey(server.allocator, &resolved_options);
    }
    return provider.stream(model, context, resolved_options, server.allocator);
}

fn refreshWithLock(
    server: *ProtocolServer,
    provider_id: []const u8,
    storage: *oauth_storage.AuthStorage,
    oauth_provider: oauth_storage.OAuthProvider,
) !void {
    const lock_result = server.refresh_lock.acquire(provider_id, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AuthRefreshFailed,
    };

    switch (lock_result) {
        .acquired => |generation| {
            storage.refreshCredentials(provider_id, oauth_provider) catch |err| {
                server.refresh_lock.complete(provider_id, null, generation, err);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.AuthRefreshFailed,
                };
            };
            server.refresh_lock.complete(provider_id, null, generation, null);
        },
        .completed_ok => {
        },
        .completed_err => |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.AuthRefreshFailed,
            };
        },
        .timed_out => return error.AuthRefreshFailed,
    }
}

fn streamWithRefresh(
    server: *ProtocolServer,
    provider: api_registry.ApiProvider,
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
) !*event_stream.AssistantMessageEventStream {
    if (options) |opts| {
        if (opts.getApiKey() != null) return provider.stream(model, context, options, server.allocator);
    }

    if (provider.auth_provider_id) |auth_provider_id| {
        const is_vendor_oauth = std.mem.eql(u8, auth_provider_id, "anthropic") or
            std.mem.eql(u8, auth_provider_id, "openai-codex");
        if (is_vendor_oauth and !std.mem.eql(u8, model.provider, auth_provider_id)) return error.AuthRequired;
    }
    const provider_id = provider.auth_provider_id orelse model.provider;
    const oauth_provider = authProvider(provider) orelse
        return streamWithResolvedKey(server, provider, provider_id, model, context, options);

    var loaded_storage: ?oauth_storage.AuthStorage = null;
    defer if (loaded_storage) |*storage| storage.deinit();
    const storage = if (server.options.auth_storage) |auth_storage|
        auth_storage
    else
        blk: {
            loaded_storage = server.options.load_auth_storage_fn(server.options.load_auth_storage_ctx, server.allocator) catch
                break :blk null;
            break :blk @as(?*oauth_storage.AuthStorage, &loaded_storage.?);
        } orelse
            return streamWithResolvedKey(server, provider, provider_id, model, context, options);

    if (!storage.hasRefreshableCredentials(provider_id)) {
        const stored_key = storage.getApiKey(provider_id, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return err,
        };
        if (stored_key) |key| {
            defer server.allocator.free(key);
            var resolved_options = try injectApiKey(server.allocator, options, key);
            defer deinitInjectedApiKey(server.allocator, &resolved_options);
            return provider.stream(model, context, resolved_options, server.allocator);
        }
        return streamWithResolvedKey(server, provider, provider_id, model, context, options);
    }

    if (storage.credentialsExpired(provider_id)) {
        refreshWithLock(server, provider_id, storage, oauth_provider) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.AuthRefreshFailed,
        };
    }

    var api_key_opt: ?[]const u8 = (storage.getApiKey(provider_id, oauth_provider) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AuthRefreshFailed,
    }) orelse return error.AuthRequired;
    defer if (api_key_opt) |key| server.allocator.free(key);

    var resolved_options = try injectApiKey(server.allocator, options, api_key_opt.?);
    defer deinitInjectedApiKey(server.allocator, &resolved_options);

    var stream = provider.stream(model, context, resolved_options, server.allocator) catch |err| {
        if (err == error.MissingApiKey) return error.AuthRequired;
        return err;
    };
    if (!stream.isDone()) return stream;

    const err_msg = stream.getError() orelse return stream;
    const is_auth_failure = if (provider.is_auth_failure) |detector| detector(err_msg) else defaultAuthFailureDetector(err_msg);
    if (!is_auth_failure) return stream;

    server.allocator.free(api_key_opt.?);
    api_key_opt = null;
    stream.deinit();
    server.allocator.destroy(stream);

    refreshWithLock(server, provider_id, storage, oauth_provider) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AuthRefreshFailed,
    };
    api_key_opt = (storage.getApiKey(provider_id, oauth_provider) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AuthRefreshFailed,
    }) orelse return error.AuthRequired;

    var retry_options = try injectApiKey(server.allocator, options, api_key_opt.?);
    defer deinitInjectedApiKey(server.allocator, &retry_options);
    var retry_stream = provider.stream(model, context, retry_options, server.allocator) catch |err| {
        if (err == error.MissingApiKey) return error.AuthRequired;
        return err;
    };
    if (retry_stream.isDone()) {
        if (retry_stream.getError()) |retry_err_msg| {
            const retry_auth_failure = if (provider.is_auth_failure) |detector| detector(retry_err_msg) else defaultAuthFailureDetector(retry_err_msg);
            if (retry_auth_failure) {
                retry_stream.deinit();
                server.allocator.destroy(retry_stream);
                return error.AuthRequired;
            }
        }
    }
    return retry_stream;
}

const EffectiveModel = struct {
    model: ai_types.Model,
    defaulted_base_url: ?[]const u8 = null,

    fn deinit(self: *EffectiveModel, allocator: std.mem.Allocator) void {
        if (self.defaulted_base_url) |base| allocator.free(base);
        self.defaulted_base_url = null;
    }
};

const DEFAULT_MODEL_MAX_TOKENS: u32 = 4_096;

fn staticCatalogMaxTokens(model: ai_types.Model) ?u32 {
    for (STATIC_MODEL_CATALOG) |entry| {
        if (!std.mem.eql(u8, entry.provider_id, model.provider)) continue;
        if (!std.mem.eql(u8, entry.api, model.api)) continue;
        if (!std.mem.eql(u8, entry.model_id, model.id)) continue;
        return entry.max_output_tokens orelse DEFAULT_MODEL_MAX_TOKENS;
    }
    return null;
}

fn modelWithProtocolDefaults(
    server: *ProtocolServer,
    model: ai_types.Model,
) !EffectiveModel {
    const allocator = server.allocator;
    const client_supplied_base = model.base_url.len > 0;
    var effective = model;
    var defaulted_base: ?[]const u8 = null;
    errdefer if (defaulted_base) |base| allocator.free(base);

    if (!client_supplied_base and model.provider.len > 0 and model.api.len > 0) {
        const stored_kimi_region: ?[]const u8 = if (isKimiPair(model.provider, model.api))
            try storedKimiRegion(server)
        else
            null;
        const resolved = try provider_base_url.defaultBaseUrlForRefWithRegion(
            allocator,
            model.provider,
            model.api,
            stored_kimi_region,
        );
        if (resolved.len > 0) {
            defaulted_base = resolved;
            effective.base_url = resolved;
        } else {
            allocator.free(resolved);
        }
    }

    if (model.max_tokens == 0) {
        effective.max_tokens = staticCatalogMaxTokens(model) orelse
            provider_base_url.defaultMaxTokensForRef(model.provider, model.api);
    }

    if (!model.reasoning and !client_supplied_base and model.provider.len > 0 and model.id.len > 0) {
        effective.reasoning = provider_base_url.isReasoningModelRef(model.provider, model.id);
    }

    if (model.compat == null and !client_supplied_base) {
        effective.compat = try provider_base_url.transparentProxyCompat(allocator, model.provider);
    }

    return .{ .model = effective, .defaulted_base_url = defaulted_base };
}

fn isKimiPair(provider_id: []const u8, api: []const u8) bool {
    return std.mem.eql(u8, provider_id, "kimi") and std.mem.eql(u8, api, "openai-completions");
}

fn storedKimiRegion(server: *ProtocolServer) !?[]const u8 {
    var loaded_storage: ?oauth_storage.AuthStorage = null;
    defer if (loaded_storage) |*storage| storage.deinit();

    const storage = if (server.options.auth_storage) |auth_storage|
        auth_storage
    else
        blk: {
            loaded_storage = server.options.load_auth_storage_fn(
                server.options.load_auth_storage_ctx,
                server.allocator,
            ) catch break :blk null;
            break :blk @as(?*oauth_storage.AuthStorage, &loaded_storage.?);
        } orelse return null;

    const auth = storage.providers.get("kimi") orelse return null;
    if (auth != .oauth) return null;
    const provider_data = auth.oauth.provider_data orelse return null;
    if (!std.mem.startsWith(u8, provider_data, "region:")) return null;
    return provider_base_url.normalizeKimiRegion(provider_data["region:".len..]);
}

fn handleStreamRequest(server: *ProtocolServer, request: protocol_types.StreamRequest, stream_id: protocol_types.Ulid, in_reply_to: protocol_types.Ulid, received_seq: u64) !protocol_types.Envelope {
    if (server.active_streams.contains(stream_id)) {
        return try envelope.createNack(
            nackTemplate(stream_id, in_reply_to),
            "Stream ID already in use",
            .stream_already_exists,
            server.allocator,
        );
    }

    if (server.active_streams.count() >= server.options.max_streams) {
        return try envelope.createNack(
            nackTemplate(stream_id, in_reply_to),
            "Maximum concurrent streams limit reached",
            .rate_limited,
            server.allocator,
        );
    }

    const provider = server.registry.getApiProvider(request.model.api) orelse {
        return try envelope.createNack(
            nackTemplate(stream_id, in_reply_to),
            "Provider not found for API",
            .provider_error,
            server.allocator,
        );
    };

    const cancelled = oom.unreachableOnOom(server.allocator.create(std.atomic.Value(bool)));
    cancelled.* = std.atomic.Value(bool).init(false);
    const cancel_token = ai_types.CancelToken{ .cancelled = cancelled };

    const options_with_cancel = injectServerOptions(request.options, cancel_token);

    var effective_model = try modelWithProtocolDefaults(server, request.model);
    defer effective_model.deinit(server.allocator);

    const stream = streamWithRefresh(server, provider, effective_model.model, request.context, options_with_cancel) catch |err| {
        server.allocator.destroy(cancelled);
        return try envelope.createNack(
            nackTemplate(stream_id, in_reply_to),
            providerErrorMessage(err),
            providerErrorCode(err),
            server.allocator,
        );
    };
    if (!stream.owns_events) {
        cancelled.store(true, .release);
        stream.wait_for_thread_on_deinit = true;
        stream.deinit();
        server.allocator.destroy(stream);
        server.allocator.destroy(cancelled);
        return try envelope.createNack(
            nackTemplate(stream_id, in_reply_to),
            "Provider returned borrowed events for protocol streaming",
            .provider_error,
            server.allocator,
        );
    }
    stream.wait_for_thread_on_deinit = true;

    const active_stream = ProtocolServer.ActiveStream{
        .stream_id = stream_id,
        .model = request.model,
        .event_stream = stream,
        .partial_state = partial_serializer.PartialState.init(server.allocator),
        .started_at = compat.time.nowMillis(),
        .cancelled = cancelled,
    };

    try server.active_streams.put(stream_id, active_stream);

    try server.sequence_counters.put(stream_id, 1);

    try server.expected_sequences.put(stream_id, received_seq + 1);

    return .{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .in_reply_to = in_reply_to,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .ack = .{
            .acknowledged_id = in_reply_to,
        } },
    };
}

fn handleAbortRequest(server: *ProtocolServer, request: protocol_types.AbortRequest, stream_id: protocol_types.Ulid, in_reply_to: protocol_types.Ulid, received_seq: u64) !protocol_types.Envelope {
    server.validateAndUpdateSequence(request.target_stream_id, received_seq) catch |err| {
        return try createSequenceNack(server.allocator, stream_id, in_reply_to, err);
    };

    if (server.active_streams.fetchRemove(request.target_stream_id)) |removed| {
        if (removed.value.cancelled) |c| {
            c.store(true, .release);
        }

        const reason = request.getReason() orelse "Stream aborted";
        removed.value.event_stream.completeWithError(reason);

        server.pending_cleanup.append(server.allocator, removed.value) catch {
            var partial = removed.value.partial_state;
            partial.deinit();
            removed.value.event_stream.deinit();
            server.allocator.destroy(removed.value.event_stream);
            if (removed.value.cancelled) |c| {
                server.allocator.destroy(c);
            }
        };

        const seq = server.nextSequence(request.target_stream_id);

        const err_seq = seq + 1;

        _ = server.sequence_counters.remove(request.target_stream_id);
        _ = server.expected_sequences.remove(request.target_stream_id);

        const err_msg = server.allocator.dupe(u8, reason) catch null;
        if (err_msg) |msg| {
            server.outbox.append(server.allocator, .{
                .stream_id = request.target_stream_id,
                .message_id = protocol_types.generateUlid(),
                .sequence = err_seq,
                .in_reply_to = in_reply_to,
                .timestamp = compat.time.nowMillis(),
                .payload = .{ .stream_error = .{
                    .code = .stream_cancelled,
                    .message = protocol_types.OwnedSlice(u8).initOwned(msg),
                } },
            }) catch {
                server.allocator.free(msg);
            };
        }

        return .{
            .stream_id = request.target_stream_id,
            .message_id = protocol_types.generateUlid(),
            .sequence = seq,
            .in_reply_to = in_reply_to,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .ack = .{
                .acknowledged_id = in_reply_to,
            } },
        };
    } else {
        return .{
            .stream_id = request.target_stream_id,
            .message_id = protocol_types.generateUlid(),
            .sequence = 0,
            .in_reply_to = in_reply_to,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .ack = .{
                .acknowledged_id = in_reply_to,
            } },
        };
    }
}

fn handleCompleteRequest(server: *ProtocolServer, request: protocol_types.CompleteRequest, stream_id: protocol_types.Ulid, in_reply_to: protocol_types.Ulid, received_seq: u64) !protocol_types.Envelope {
    _ = received_seq;

    const provider = server.registry.getApiProvider(request.model.api) orelse {
        return try envelope.createNack(
            nackTemplate(stream_id, in_reply_to),
            "Provider not found for API",
            .provider_error,
            server.allocator,
        );
    };

    var effective_model = try modelWithProtocolDefaults(server, request.model);
    defer effective_model.deinit(server.allocator);

    const stream = streamWithRefresh(server, provider, effective_model.model, request.context, request.options) catch |err| {
        return try envelope.createNack(
            nackTemplate(stream_id, in_reply_to),
            providerErrorMessage(err),
            providerErrorCode(err),
            server.allocator,
        );
    };
    defer {
        stream.deinit();
        server.allocator.destroy(stream);
    }

    const timeout_ms = server.options.stream_timeout_ms;
    if (stream.waitForThread(timeout_ms)) {
        _ = stream.waitForCompletion(timeout_ms);
    }

    if (stream.getResult()) |result| {
        var cloned_result = try ai_types.cloneAssistantMessage(server.allocator, result);
        cloned_result.is_owned = true;

        return .{
            .stream_id = stream_id,
            .message_id = protocol_types.generateUlid(),
            .sequence = 1,
            .in_reply_to = in_reply_to,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .result = cloned_result },
        };
    } else if (stream.getError()) |err_msg| {
        return try envelope.createNack(
            .{
                .stream_id = stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = compat.time.nowMillis(),
                .payload = .ping,
            },
            err_msg,
            .provider_error,
            server.allocator,
        );
    } else {
        return try envelope.createNack(
            .{
                .stream_id = stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = compat.time.nowMillis(),
                .payload = .ping,
            },
            "Stream did not complete in time",
            .internal_error,
            server.allocator,
        );
    }
}

fn handleModelsRequest(
    server: *ProtocolServer,
    request: protocol_types.ModelsRequest,
    stream_id: protocol_types.Ulid,
    in_reply_to: protocol_types.Ulid,
    received_seq: u64,
) !protocol_types.Envelope {
    if (!server.options.supports_model_catalog) {
        return try makeModelsNack(
            server,
            stream_id,
            in_reply_to,
            .not_implemented,
            "models catalog is not implemented for this runtime",
        );
    }

    server.validateAndUpdateSequence(stream_id, received_seq) catch |err| {
        return try createSequenceNack(server.allocator, stream_id, in_reply_to, err);
    };

    var response = resolveModelsRequest(server, request) catch |err| switch (err) {
        error.NotImplemented => return try makeModelsNack(
            server,
            stream_id,
            in_reply_to,
            .not_implemented,
            "models catalog is not implemented for this runtime",
        ),
        error.ModelNotFound => return try makeModelsNack(
            server,
            stream_id,
            in_reply_to,
            .invalid_request,
            "model not found",
        ),
        error.AmbiguousModelId => return try makeModelsNack(
            server,
            stream_id,
            in_reply_to,
            .invalid_request,
            "model_id matches multiple APIs; specify api",
        ),
        error.OutOfMemory => return error.OutOfMemory,
        else => return try makeModelsNack(
            server,
            stream_id,
            in_reply_to,
            .provider_error,
            "failed to build model catalog response",
        ),
    };
    errdefer response.deinit(server.allocator);

    const ack = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = server.nextSequence(stream_id),
        .in_reply_to = in_reply_to,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .ack = .{
            .acknowledged_id = in_reply_to,
        } },
    };

    try server.outbox.append(server.allocator, .{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = server.nextSequence(stream_id),
        .in_reply_to = in_reply_to,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_response = response },
    });

    return ack;
}

fn resolveModelsRequest(
    server: *ProtocolServer,
    request: protocol_types.ModelsRequest,
) anyerror!protocol_types.ModelsResponse {
    if (server.options.dynamic_catalog_fetcher) |fetcher| {
        const dynamic_response = fetcher(server.options.dynamic_catalog_ctx, server.allocator, request) catch |err| switch (err) {
            error.NotImplemented => null,
            error.OutOfMemory => return error.OutOfMemory,
            else => return err,
        };

        if (dynamic_response) |response| {
            return try filterAndNormalizeModels(
                server,
                request,
                response,
                .dynamic,
                DYNAMIC_CACHE_MAX_AGE_MS,
            );
        }
    }

    if (!server.options.enable_static_catalog_fallback) {
        return error.NotImplemented;
    }

    const static_response = try buildStaticFallbackResponse(server.allocator);
    return try filterAndNormalizeModels(
        server,
        request,
        static_response,
        .static_fallback,
        STATIC_FALLBACK_CACHE_MAX_AGE_MS,
    );
}

fn buildStaticFallbackResponse(
    allocator: std.mem.Allocator,
) !protocol_types.ModelsResponse {
    const models = try allocator.alloc(protocol_types.ModelDescriptor, STATIC_MODEL_CATALOG.len);
    var built_count: usize = 0;
    errdefer {
        for (models[0..built_count]) |*model| model.deinit(allocator);
        allocator.free(models);
    }

    for (STATIC_MODEL_CATALOG, 0..) |entry, idx| {
        models[idx] = try buildDescriptorFromStaticEntry(allocator, entry);
        built_count += 1;
    }

    return .{
        .models = protocol_types.OwnedSlice(protocol_types.ModelDescriptor).initOwned(models),
        .fetched_at_ms = compat.time.nowMillis(),
        .cache_max_age_ms = STATIC_FALLBACK_CACHE_MAX_AGE_MS,
    };
}

fn buildDescriptorFromStaticEntry(
    allocator: std.mem.Allocator,
    entry: StaticCatalogEntry,
) !protocol_types.ModelDescriptor {
    const model_ref_value = try model_ref.formatModelRef(allocator, entry.provider_id, entry.api, entry.model_id);
    errdefer allocator.free(model_ref_value);

    const model_id = try allocator.dupe(u8, entry.model_id);
    errdefer allocator.free(model_id);
    const display_name = try allocator.dupe(u8, entry.display_name);
    errdefer allocator.free(display_name);
    const provider_id = try allocator.dupe(u8, entry.provider_id);
    errdefer allocator.free(provider_id);
    const api = try allocator.dupe(u8, entry.api);
    errdefer allocator.free(api);
    const base_url = try allocator.dupe(u8, entry.base_url);
    errdefer allocator.free(base_url);
    const capabilities = try allocator.dupe(protocol_types.ModelCapability, entry.capabilities);
    errdefer allocator.free(capabilities);

    return .{
        .model_ref = protocol_types.OwnedSlice(u8).initOwned(model_ref_value),
        .model_id = protocol_types.OwnedSlice(u8).initOwned(model_id),
        .display_name = protocol_types.OwnedSlice(u8).initOwned(display_name),
        .provider_id = protocol_types.OwnedSlice(u8).initOwned(provider_id),
        .api = protocol_types.OwnedSlice(u8).initOwned(api),
        .base_url = protocol_types.OwnedSlice(u8).initOwned(base_url),
        .auth_status = entry.auth_status,
        .lifecycle = entry.lifecycle,
        .capabilities = protocol_types.OwnedSlice(protocol_types.ModelCapability).initOwned(capabilities),
        .source = .static_fallback,
        .context_window = entry.context_window,
        .max_output_tokens = entry.max_output_tokens,
        .reasoning_default = entry.reasoning_default,
        .metadata = null,
    };
}

fn filterAndNormalizeModels(
    server: *ProtocolServer,
    request: protocol_types.ModelsRequest,
    input: protocol_types.ModelsResponse,
    source: protocol_types.ModelSource,
    default_cache_max_age_ms: u64,
) anyerror!protocol_types.ModelsResponse {
    var response = input;
    errdefer response.deinit(server.allocator);

    var filtered = std.ArrayList(protocol_types.ModelDescriptor).empty;
    defer filtered.deinit(server.allocator);
    errdefer {
        for (filtered.items) |*model| model.deinit(server.allocator);
    }

    for (response.models.slice()) |model| {
        if (!matchesModelFilters(request, model)) continue;

        var cloned = try model_catalog_types.cloneModelDescriptor(server.allocator, model);
        errdefer cloned.deinit(server.allocator);

        cloned.source = source;
        if (cloned.model_ref.slice().len == 0) {
            const generated_ref = try model_ref.formatModelRef(
                server.allocator,
                cloned.provider_id.slice(),
                cloned.api.slice(),
                cloned.model_id.slice(),
            );
            cloned.model_ref.deinit(server.allocator);
            cloned.model_ref = protocol_types.OwnedSlice(u8).initOwned(generated_ref);
        }

        try filtered.append(server.allocator, cloned);
    }

    const model_filter = request.getModelId();
    if (model_filter != null and filtered.items.len == 0) {
        return error.ModelNotFound;
    }
    if (model_filter != null and request.getApi() == null and filtered.items.len > 1) {
        return error.AmbiguousModelId;
    }

    const cache_max_age_ms = if (response.cache_max_age_ms > 0)
        response.cache_max_age_ms
    else
        default_cache_max_age_ms;

    response.deinit(server.allocator);

    const filtered_models = try filtered.toOwnedSlice(server.allocator);

    return .{
        .models = protocol_types.OwnedSlice(protocol_types.ModelDescriptor).initOwned(filtered_models),
        .fetched_at_ms = compat.time.nowMillis(),
        .cache_max_age_ms = cache_max_age_ms,
    };
}

fn matchesModelFilters(
    request: protocol_types.ModelsRequest,
    model: protocol_types.ModelDescriptor,
) bool {
    if (request.getProviderId()) |provider_filter| {
        if (!std.mem.eql(u8, model.provider_id.slice(), provider_filter)) {
            return false;
        }
    }

    if (request.getApi()) |api_filter| {
        if (!std.mem.eql(u8, model.api.slice(), api_filter)) {
            return false;
        }
    }

    if (request.getModelId()) |model_filter| {
        if (!std.mem.eql(u8, model.model_id.slice(), model_filter)) {
            return false;
        }
    }

    if (!request.include_deprecated and model.lifecycle == .deprecated) {
        return false;
    }
    if (!request.include_login_required and model.auth_status == .login_required) {
        return false;
    }

    return true;
}

fn makeModelsNack(
    server: *ProtocolServer,
    stream_id: protocol_types.Ulid,
    in_reply_to: protocol_types.Ulid,
    code: protocol_types.ErrorCode,
    reason: []const u8,
) !protocol_types.Envelope {
    return .{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = server.nextSequence(stream_id),
        .in_reply_to = in_reply_to,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .nack = .{
            .rejected_id = in_reply_to,
            .reason = protocol_types.OwnedSlice(u8).initOwned(try server.allocator.dupe(u8, reason)),
            .error_code = code,
        } },
    };
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
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;

    const result = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
    };
    s.complete(result);
    s.markThreadDone();

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
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;

    const result = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
    };
    s.complete(result);
    s.markThreadDone();

    return s;
}

const AuthTestState = struct {
    expires: i64,
    refresh_count: usize = 0,
    stream_calls: usize = 0,
    fail_refresh: bool = false,
    auth_fail_first_call: bool = false,
    auth_fail_all_calls: bool = false,
    use_api_key_storage: bool = false,
    last_api_key: [64]u8 = undefined,
    last_api_key_len: usize = 0,
};

var auth_test_state: ?*AuthTestState = null;

fn testModel() ai_types.Model {
    return .{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test-provider",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };
}

fn testContext() ai_types.Context {
    return .{ .messages = &.{} };
}

fn authTestRefresh(credentials: oauth_storage.Credentials, allocator: std.mem.Allocator) anyerror!oauth_storage.Credentials {
    const state = auth_test_state.?;
    if (state.fail_refresh) return error.RefreshFailed;
    state.refresh_count += 1;
    state.expires = compat.time.nowMillis() + 60_000;
    return .{
        .refresh = try allocator.dupe(u8, credentials.refresh),
        .access = try std.fmt.allocPrint(allocator, "access-{d}", .{state.refresh_count}),
        .expires = state.expires,
    };
}

fn authTestGetApiKey(credentials: oauth_storage.Credentials, allocator: std.mem.Allocator) anyerror![]const u8 {
    return allocator.dupe(u8, credentials.access);
}

fn authTestSaveStorage(storage: *const oauth_storage.AuthStorage) anyerror!void {
    _ = storage;
}

fn authTestLoadStorage(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!oauth_storage.AuthStorage {
    const state: *AuthTestState = @ptrCast(@alignCast(ctx.?));
    var storage = oauth_storage.AuthStorage{ .providers = std.StringHashMap(oauth_storage.ProviderAuth).init(allocator), .allocator = allocator, .save_fn = authTestSaveStorage };
    if (state.use_api_key_storage) {
        try storage.providers.put(try allocator.dupe(u8, "test-auth"), .{ .api_key = try allocator.dupe(u8, "stored-test-key") });
    } else {
        try storage.providers.put(try allocator.dupe(u8, "test-auth"), .{ .oauth = .{
            .refresh = try allocator.dupe(u8, "refresh"),
            .access = try allocator.dupe(u8, "access-0"),
            .expires = state.expires,
        } });
    }
    return storage;
}

fn authTestStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;
    const state = auth_test_state.?;
    state.stream_calls += 1;
    if (options) |opts| {
        if (opts.getApiKey()) |key| {
            const len = @min(key.len, state.last_api_key.len);
            @memcpy(state.last_api_key[0..len], key[0..len]);
            state.last_api_key_len = len;
        }
    }
    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
    if (state.auth_fail_all_calls or (state.auth_fail_first_call and state.stream_calls == 1)) {
        s.completeWithError("401 unauthorized");
    } else {
        s.complete(.{ .content = &.{}, .api = "test-api", .provider = "test-provider", .model = "test-model", .usage = .{}, .stop_reason = .stop, .timestamp = compat.time.nowMillis() });
    }
    s.markThreadDone();
    return s;
}

const DynamicFetcherMode = enum {
    success,
    unavailable,
};

const DynamicFetcherCtx = struct {
    mode: DynamicFetcherMode,
    call_count: usize = 0,
};

fn testDynamicCatalogFetcher(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: protocol_types.ModelsRequest,
) anyerror!protocol_types.ModelsResponse {
    const typed_ctx: *DynamicFetcherCtx = @ptrCast(@alignCast(ctx.?));
    typed_ctx.call_count += 1;

    if (typed_ctx.mode == .unavailable) {
        return error.NotImplemented;
    }

    const model_id_value = request.getModelId() orelse "dynamic:model";
    const capabilities = try allocator.alloc(protocol_types.ModelCapability, 2);
    capabilities[0] = .chat;
    capabilities[1] = .streaming;

    const models = try allocator.alloc(protocol_types.ModelDescriptor, 1);
    models[0] = .{
        .model_ref = protocol_types.OwnedSlice(u8).initBorrowed(""),
        .model_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, model_id_value)),
        .display_name = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "Dynamic Model")),
        .provider_id = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "dynamic-provider")),
        .api = protocol_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, "dynamic-api")),
        .base_url = protocol_types.OwnedSlice(u8).initBorrowed(""),
        .auth_status = .authenticated,
        .lifecycle = .stable,
        .capabilities = protocol_types.OwnedSlice(protocol_types.ModelCapability).initOwned(capabilities),
        .source = .static_fallback,
        .context_window = 16_000,
        .max_output_tokens = 2_000,
        .reasoning_default = .low,
        .metadata = null,
    };

    return .{
        .models = protocol_types.OwnedSlice(protocol_types.ModelDescriptor).initOwned(models),
        .fetched_at_ms = 0,
        .cache_max_age_ms = 0,
    };
}

test "handleModelsRequest emits ack then models_response from static fallback" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    var request = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{} },
    };
    defer request.deinit(std.testing.allocator);

    const maybe_ack = try server.handleEnvelope(request);
    try std.testing.expect(maybe_ack != null);
    var ack = maybe_ack.?;
    defer ack.deinit(std.testing.allocator);
    try std.testing.expect(ack.payload == .ack);
    try std.testing.expectEqual(@as(u64, 1), ack.sequence);

    const maybe_response = server.popOutbound();
    try std.testing.expect(maybe_response != null);
    var response = maybe_response.?;
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(response.payload == .models_response);
    try std.testing.expectEqual(@as(u64, 2), response.sequence);
    try std.testing.expectEqualSlices(u8, &request.message_id, &response.in_reply_to.?);
    try std.testing.expect(response.payload.models_response.fetched_at_ms > 0);
    try std.testing.expectEqual(STATIC_FALLBACK_CACHE_MAX_AGE_MS, response.payload.models_response.cache_max_age_ms);
    for (response.payload.models_response.models.slice()) |model| {
        try std.testing.expectEqual(protocol_types.ModelSource.static_fallback, model.source);
    }
}

test "handleModelsRequest returns not_implemented nack when unsupported" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{
        .supports_model_catalog = false,
    });
    defer server.deinit();

    var request = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{} },
    };
    defer request.deinit(std.testing.allocator);

    const maybe_response = try server.handleEnvelope(request);
    try std.testing.expect(maybe_response != null);
    var response = maybe_response.?;
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(response.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.not_implemented, response.payload.nack.error_code.?);
    try std.testing.expect(server.popOutbound() == null);
}

test "handleModelsRequest applies provider api and exact model filters" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    var by_provider = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{
            .provider_id = protocol_types.OwnedSlice(u8).initBorrowed("openai"),
        } },
    };
    defer by_provider.deinit(std.testing.allocator);

    _ = (try server.handleEnvelope(by_provider)).?;
    var provider_response = server.popOutbound().?;
    defer provider_response.deinit(std.testing.allocator);
    try std.testing.expect(provider_response.payload == .models_response);
    const provider_models = provider_response.payload.models_response.models.slice();
    try std.testing.expect(provider_models.len > 0);
    for (provider_models) |model| {
        try std.testing.expectEqualStrings("openai", model.provider_id.slice());
        try std.testing.expect(model.lifecycle != .deprecated);
    }

    var by_api = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{
            .api = protocol_types.OwnedSlice(u8).initBorrowed("openai-responses"),
        } },
    };
    defer by_api.deinit(std.testing.allocator);

    _ = (try server.handleEnvelope(by_api)).?;
    var api_response = server.popOutbound().?;
    defer api_response.deinit(std.testing.allocator);
    try std.testing.expect(api_response.payload == .models_response);
    const api_models = api_response.payload.models_response.models.slice();
    try std.testing.expect(api_models.len > 0);
    for (api_models) |model| {
        try std.testing.expectEqualStrings("openai-responses", model.api.slice());
    }

    var by_model_id = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{
            .api = protocol_types.OwnedSlice(u8).initBorrowed("ollama"),
            .model_id = protocol_types.OwnedSlice(u8).initBorrowed("qwen2.5:7b"),
        } },
    };
    defer by_model_id.deinit(std.testing.allocator);

    _ = (try server.handleEnvelope(by_model_id)).?;
    var model_response = server.popOutbound().?;
    defer model_response.deinit(std.testing.allocator);
    try std.testing.expect(model_response.payload == .models_response);
    const model_matches = model_response.payload.models_response.models.slice();
    try std.testing.expectEqual(@as(usize, 1), model_matches.len);
    try std.testing.expectEqualStrings("qwen2.5:7b", model_matches[0].model_id.slice());
}

test "handleModelsRequest returns invalid_request for ambiguous or missing model_id" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    var ambiguous = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{
            .provider_id = protocol_types.OwnedSlice(u8).initBorrowed("openai"),
            .model_id = protocol_types.OwnedSlice(u8).initBorrowed("gpt-4o"),
        } },
    };
    defer ambiguous.deinit(std.testing.allocator);

    const ambiguous_response = try server.handleEnvelope(ambiguous);
    try std.testing.expect(ambiguous_response != null);
    var ambiguous_nack = ambiguous_response.?;
    defer ambiguous_nack.deinit(std.testing.allocator);
    try std.testing.expect(ambiguous_nack.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.invalid_request, ambiguous_nack.payload.nack.error_code.?);
    try std.testing.expect(std.mem.find(u8, ambiguous_nack.payload.nack.reason.slice(), "multiple APIs") != null);

    var missing = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{
            .provider_id = protocol_types.OwnedSlice(u8).initBorrowed("anthropic"),
            .model_id = protocol_types.OwnedSlice(u8).initBorrowed("does-not-exist"),
        } },
    };
    defer missing.deinit(std.testing.allocator);

    const missing_response = try server.handleEnvelope(missing);
    try std.testing.expect(missing_response != null);
    var missing_nack = missing_response.?;
    defer missing_nack.deinit(std.testing.allocator);
    try std.testing.expect(missing_nack.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.invalid_request, missing_nack.payload.nack.error_code.?);
    try std.testing.expect(std.mem.find(u8, missing_nack.payload.nack.reason.slice(), "model not found") != null);
}

test "handleModelsRequest prefers dynamic fetch and falls back to static catalog when unavailable" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var dynamic_ctx = DynamicFetcherCtx{ .mode = .success };
    var server = ProtocolServer.init(std.testing.allocator, &registry, .{
        .dynamic_catalog_fetcher = testDynamicCatalogFetcher,
        .dynamic_catalog_ctx = @ptrCast(&dynamic_ctx),
    });
    defer server.deinit();

    var dynamic_request = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{} },
    };
    defer dynamic_request.deinit(std.testing.allocator);

    _ = (try server.handleEnvelope(dynamic_request)).?;
    var dynamic_response = server.popOutbound().?;
    defer dynamic_response.deinit(std.testing.allocator);
    try std.testing.expect(dynamic_response.payload == .models_response);
    try std.testing.expectEqual(@as(usize, 1), dynamic_response.payload.models_response.models.slice().len);
    try std.testing.expectEqual(protocol_types.ModelSource.dynamic, dynamic_response.payload.models_response.models.slice()[0].source);
    try std.testing.expectEqualStrings("dynamic:model", dynamic_response.payload.models_response.models.slice()[0].model_id.slice());
    try std.testing.expectEqualStrings("dynamic-provider", dynamic_response.payload.models_response.models.slice()[0].provider_id.slice());
    try std.testing.expectEqual(DYNAMIC_CACHE_MAX_AGE_MS, dynamic_response.payload.models_response.cache_max_age_ms);
    try std.testing.expectEqual(@as(usize, 1), dynamic_ctx.call_count);

    dynamic_ctx.mode = .unavailable;

    var fallback_request = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .models_request = .{} },
    };
    defer fallback_request.deinit(std.testing.allocator);

    _ = (try server.handleEnvelope(fallback_request)).?;
    var fallback_response = server.popOutbound().?;
    defer fallback_response.deinit(std.testing.allocator);
    try std.testing.expect(fallback_response.payload == .models_response);
    try std.testing.expect(fallback_response.payload.models_response.models.slice().len > 0);
    try std.testing.expectEqual(protocol_types.ModelSource.static_fallback, fallback_response.payload.models_response.models.slice()[0].source);
    try std.testing.expectEqual(STATIC_FALLBACK_CACHE_MAX_AGE_MS, fallback_response.payload.models_response.cache_max_age_ms);
    try std.testing.expectEqual(@as(usize, 2), dynamic_ctx.call_count);
}

test "expired stored credentials refresh before upstream call" {
    var state = AuthTestState{ .expires = compat.time.nowMillis() - 1 };
    auth_test_state = &state;
    defer auth_test_state = null;

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registerAuthTestProvider(&registry);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{ .load_auth_storage_fn = authTestLoadStorage, .load_auth_storage_ctx = &state });
    defer server.deinit();
    const stream = try streamWithRefresh(&server, registry.getApiProvider("test-api").?, testModel(), testContext(), null);
    defer {
        stream.deinit();
        std.testing.allocator.destroy(stream);
    }

    try std.testing.expectEqual(@as(usize, 1), state.refresh_count);
    try std.testing.expectEqual(@as(usize, 1), state.stream_calls);
    try std.testing.expectEqualStrings("access-1", state.last_api_key[0..state.last_api_key_len]);
}

test "upstream auth failure refreshes and retries once" {
    var state = AuthTestState{ .expires = compat.time.nowMillis() + 60_000, .auth_fail_first_call = true };
    auth_test_state = &state;
    defer auth_test_state = null;

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registerAuthTestProvider(&registry);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{ .load_auth_storage_fn = authTestLoadStorage, .load_auth_storage_ctx = &state });
    defer server.deinit();
    const stream = try streamWithRefresh(&server, registry.getApiProvider("test-api").?, testModel(), testContext(), null);
    defer {
        stream.deinit();
        std.testing.allocator.destroy(stream);
    }

    try std.testing.expectEqual(@as(usize, 1), state.refresh_count);
    try std.testing.expectEqual(@as(usize, 2), state.stream_calls);
    try std.testing.expect(stream.getResult() != null);
}

fn registerAuthTestProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "test-api",
        .stream = authTestStream,
        .stream_simple = mockStreamSimple,
        .auth_provider_id = "test-auth",
        .auth_refresh_fn = authTestRefresh,
        .auth_get_api_key_fn = authTestGetApiKey,
    }, null);
}

fn expectAuthRefreshFailedNack(state: *AuthTestState) !void {
    auth_test_state = state;
    defer auth_test_state = null;

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registerAuthTestProvider(&registry);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{ .load_auth_storage_fn = authTestLoadStorage, .load_auth_storage_ctx = state });
    defer server.deinit();
    const env = protocol_types.Envelope{ .stream_id = protocol_types.generateUlid(), .message_id = protocol_types.generateUlid(), .sequence = 1, .timestamp = compat.time.nowMillis(), .payload = .{ .stream_request = .{ .model = testModel(), .context = testContext() } } };
    var response = (try server.handleEnvelope(env)).?;
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol_types.ErrorCode.auth_refresh_failed, response.payload.nack.error_code.?);
}

test "pre-call refresh failure returns auth_refresh_failed nack" {
    var state = AuthTestState{ .expires = compat.time.nowMillis() - 1, .fail_refresh = true };
    try expectAuthRefreshFailedNack(&state);
}

test "retry refresh failure returns auth_refresh_failed nack" {
    var state = AuthTestState{ .expires = compat.time.nowMillis() + 60_000, .fail_refresh = true, .auth_fail_first_call = true };
    try expectAuthRefreshFailedNack(&state);
}

test "stored api_key used when provider has OAuth hook but storage has non-OAuth entry" {
    var state = AuthTestState{ .expires = compat.time.nowMillis() + 60_000, .use_api_key_storage = true };
    auth_test_state = &state;
    defer auth_test_state = null;

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registerAuthTestProvider(&registry);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{ .load_auth_storage_fn = authTestLoadStorage, .load_auth_storage_ctx = &state });
    defer server.deinit();
    const stream = try streamWithRefresh(&server, registry.getApiProvider("test-api").?, testModel(), testContext(), null);
    defer {
        stream.deinit();
        std.testing.allocator.destroy(stream);
    }

    try std.testing.expectEqual(@as(usize, 0), state.refresh_count);
    try std.testing.expectEqual(@as(usize, 1), state.stream_calls);
    try std.testing.expectEqualStrings("stored-test-key", state.last_api_key[0..state.last_api_key_len]);
}

test "retry auth failure returns auth_required nack" {
    var state = AuthTestState{ .expires = compat.time.nowMillis() + 60_000, .auth_fail_all_calls = true };
    auth_test_state = &state;
    defer auth_test_state = null;

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registerAuthTestProvider(&registry);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{ .load_auth_storage_fn = authTestLoadStorage, .load_auth_storage_ctx = &state });
    defer server.deinit();
    const env = protocol_types.Envelope{ .stream_id = protocol_types.generateUlid(), .message_id = protocol_types.generateUlid(), .sequence = 1, .timestamp = compat.time.nowMillis(), .payload = .{ .stream_request = .{ .model = testModel(), .context = testContext() } } };
    var response = (try server.handleEnvelope(env)).?;
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol_types.ErrorCode.auth_required, response.payload.nack.error_code.?);
    try std.testing.expectEqual(@as(usize, 1), state.refresh_count);
    try std.testing.expectEqual(@as(usize, 2), state.stream_calls);
}

test "stream refresh failure maps to error envelope code" {
    try std.testing.expectEqual(protocol_types.ErrorCode.auth_refresh_failed, streamErrorCode(AUTH_REFRESH_FAILED_MESSAGE));
}

test "ProtocolServer init and deinit" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    var mut_server = server;
    defer mut_server.deinit();

    try std.testing.expectEqual(@as(usize, 0), mut_server.activeStreamCount());
}

test "handleEnvelope returns pong for ping" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const ping_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .ping,
    };

    const response = try server.handleEnvelope(ping_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .pong);

    if (response) |r| {
        var mutable_resp = r;
        mutable_resp.deinit(std.testing.allocator);
    }
}

test "handleEnvelope returns nack for stream_request without provider" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "unknown-api",
        .provider = "unknown",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const client_stream_id = protocol_types.generateUlid();
    var stream_req_env = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    var response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.provider_error, response.?.payload.nack.error_code.?);
    try std.testing.expectEqualSlices(u8, &client_stream_id, &response.?.stream_id);

    stream_req_env.deinit(std.testing.allocator);
    if (response) |*r| r.deinit(std.testing.allocator);
}

test "handleEnvelope returns version_mismatch nack for unsupported version" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const ping_env = protocol_types.Envelope{
        .version = 2,
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .ping,
    };

    var response = try server.handleEnvelope(ping_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.version_mismatch, response.?.payload.nack.error_code.?);
    const supported_versions = response.?.payload.nack.supported_versions.slice();
    try std.testing.expectEqual(@as(usize, 1), supported_versions.len);
    try std.testing.expectEqualStrings("1", supported_versions[0].slice());

    if (response) |*r| r.deinit(std.testing.allocator);
}

test "handleStreamRequest creates stream and returns ack" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const client_stream_id = protocol_types.generateUlid();
    const msg_id = protocol_types.generateUlid();
    var stream_req_env = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = msg_id,
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    const response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .ack);
    try std.testing.expectEqualSlices(u8, &msg_id, &response.?.payload.ack.acknowledged_id);

    try std.testing.expectEqualSlices(u8, &client_stream_id, &response.?.stream_id);

    try std.testing.expectEqual(@as(usize, 1), server.activeStreamCount());
    const created = server.active_streams.get(client_stream_id).?;
    try std.testing.expect(created.event_stream.wait_for_thread_on_deinit);

    stream_req_env.deinit(std.testing.allocator);
}

test "handleStreamRequest rejects duplicate stream id" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const client_stream_id = protocol_types.generateUlid();
    var req1 = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    defer req1.deinit(std.testing.allocator);

    const resp1 = try server.handleEnvelope(req1);
    try std.testing.expect(resp1 != null);
    try std.testing.expect(resp1.?.payload == .ack);

    var req2 = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    defer req2.deinit(std.testing.allocator);

    var resp2 = try server.handleEnvelope(req2);
    defer if (resp2) |*r| r.deinit(std.testing.allocator);
    try std.testing.expect(resp2 != null);
    try std.testing.expect(resp2.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.stream_already_exists, resp2.?.payload.nack.error_code.?);
}

test "handleAbortRequest cancels stream" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    const create_response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(create_response != null);
    const stream_id = create_response.?.stream_id;

    stream_req_env.deinit(std.testing.allocator);

    const abort_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .abort_request = .{
            .target_stream_id = stream_id,
            .reason = protocol_types.OwnedSlice(u8).initBorrowed(""),
        } },
    };

    const abort_response = try server.handleEnvelope(abort_env);
    try std.testing.expect(abort_response != null);
    try std.testing.expect(abort_response.?.payload == .ack);
    try std.testing.expectEqual(@as(u64, 2), abort_response.?.sequence);

    try std.testing.expectEqual(@as(usize, 0), server.activeStreamCount());
    server.cleanupCompletedStreams();

    var outbox_env = server.popOutbound();
    try std.testing.expect(outbox_env != null);
    if (outbox_env) |*env| {
        try std.testing.expect(env.payload == .stream_error);
        try std.testing.expectEqual(protocol_types.ErrorCode.stream_cancelled, env.payload.stream_error.code);
        env.deinit(std.testing.allocator);
    }
}

test "handleAbortRequest returns ack for unknown stream (idempotent)" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const unknown_stream_id = protocol_types.generateUlid();

    const abort_env = protocol_types.Envelope{
        .stream_id = unknown_stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .abort_request = .{
            .target_stream_id = unknown_stream_id,
            .reason = protocol_types.OwnedSlice(u8).initBorrowed(""),
        } },
    };

    const response = try server.handleEnvelope(abort_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .ack);
}

test "cleanupCompletedStreams removes done streams" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    _ = try server.handleEnvelope(stream_req_env);
    try std.testing.expectEqual(@as(usize, 1), server.activeStreamCount());

    server.cleanupCompletedStreams();
    try std.testing.expectEqual(@as(usize, 0), server.activeStreamCount());

    stream_req_env.deinit(std.testing.allocator);
}

test "max streams limit enforced" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{
        .max_streams = 2,
    });
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const client_stream_id_1 = protocol_types.generateUlid();
    var req1 = protocol_types.Envelope{
        .stream_id = client_stream_id_1,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    const resp1 = try server.handleEnvelope(req1);
    try std.testing.expect(resp1 != null);
    try std.testing.expect(resp1.?.payload == .ack);
    try std.testing.expectEqualSlices(u8, &client_stream_id_1, &resp1.?.stream_id);
    req1.deinit(std.testing.allocator);

    const client_stream_id_2 = protocol_types.generateUlid();
    var req2 = protocol_types.Envelope{
        .stream_id = client_stream_id_2,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    const resp2 = try server.handleEnvelope(req2);
    try std.testing.expect(resp2 != null);
    try std.testing.expect(resp2.?.payload == .ack);
    try std.testing.expectEqualSlices(u8, &client_stream_id_2, &resp2.?.stream_id);
    req2.deinit(std.testing.allocator);

    const client_stream_id_3 = protocol_types.generateUlid();
    var req3 = protocol_types.Envelope{
        .stream_id = client_stream_id_3,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    var resp3 = try server.handleEnvelope(req3);
    try std.testing.expect(resp3 != null);
    try std.testing.expect(resp3.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.rate_limited, resp3.?.payload.nack.error_code.?);
    try std.testing.expectEqualSlices(u8, &client_stream_id_3, &resp3.?.stream_id);
    req3.deinit(std.testing.allocator);
    if (resp3) |*r| r.deinit(std.testing.allocator);
}

test "validateSequence accepts correct sequence" {
    try validateSequence(1, 1);
    try validateSequence(5, 5);
}

test "validateSequence rejects zero sequence" {
    try std.testing.expectError(error.InvalidSequence, validateSequence(1, 0));
}

test "validateSequence rejects duplicate sequence" {
    try std.testing.expectError(error.DuplicateSequence, validateSequence(5, 3));
    try std.testing.expectError(error.DuplicateSequence, validateSequence(5, 4));
}

test "validateSequence rejects sequence gap" {
    try std.testing.expectError(error.SequenceGap, validateSequence(5, 6));
    try std.testing.expectError(error.SequenceGap, validateSequence(5, 10));
}

test "handleEnvelope rejects stream_request with invalid sequence" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const client_stream_id = protocol_types.generateUlid();

    const req_seq0 = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 0,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    const resp_seq0 = try server.handleEnvelope(req_seq0);
    try std.testing.expect(resp_seq0 != null);
    try std.testing.expect(resp_seq0.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.invalid_sequence, resp_seq0.?.payload.nack.error_code.?);
    if (resp_seq0) |resp| {
        var mutable_resp = resp;
        mutable_resp.deinit(std.testing.allocator);
    }

    const req_seq2 = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    const resp_seq2 = try server.handleEnvelope(req_seq2);
    try std.testing.expect(resp_seq2 != null);
    try std.testing.expect(resp_seq2.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.invalid_sequence, resp_seq2.?.payload.nack.error_code.?);
    if (resp_seq2) |resp| {
        var mutable_resp = resp;
        mutable_resp.deinit(std.testing.allocator);
    }
}

test "handleEnvelope rejects complete_request with invalid sequence" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const client_stream_id = protocol_types.generateUlid();

    const req = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 5,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .complete_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    const resp = try server.handleEnvelope(req);
    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.invalid_sequence, resp.?.payload.nack.error_code.?);
    if (resp) |r| {
        var mutable_resp = r;
        mutable_resp.deinit(std.testing.allocator);
    }
}

test "handleAbortRequest rejects duplicate sequence" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    const create_response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(create_response != null);
    const stream_id = create_response.?.stream_id;
    stream_req_env.deinit(std.testing.allocator);

    const abort_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .abort_request = .{
            .target_stream_id = stream_id,
            .reason = protocol_types.OwnedSlice(u8).initBorrowed(""),
        } },
    };

    const abort_response = try server.handleEnvelope(abort_env);
    try std.testing.expect(abort_response != null);
    try std.testing.expect(abort_response.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.duplicate_sequence, abort_response.?.payload.nack.error_code.?);
    if (abort_response) |r| {
        var mutable_resp = r;
        mutable_resp.deinit(std.testing.allocator);
    }
}

test "handleAbortRequest rejects sequence gap" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    const create_response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(create_response != null);
    const stream_id = create_response.?.stream_id;
    stream_req_env.deinit(std.testing.allocator);

    const abort_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 10,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .abort_request = .{
            .target_stream_id = stream_id,
            .reason = protocol_types.OwnedSlice(u8).initBorrowed(""),
        } },
    };

    const abort_response = try server.handleEnvelope(abort_env);
    try std.testing.expect(abort_response != null);
    try std.testing.expect(abort_response.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.sequence_gap, abort_response.?.payload.nack.error_code.?);
    if (abort_response) |r| {
        var mutable_resp = r;
        mutable_resp.deinit(std.testing.allocator);
    }
}

const CancelMockState = struct {
    var received_cancel_token: ?ai_types.CancelToken = null;

    fn reset() void {
        received_cancel_token = null;
    }
};

fn cancelCapturingStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;

    if (options) |opts| {
        CancelMockState.received_cancel_token = opts.cancel_token;
    }

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;

    const result = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
    };
    s.complete(result);
    s.markThreadDone();

    return s;
}

test "handleStreamRequest injects CancelToken into provider stream options" {
    CancelMockState.reset();
    defer CancelMockState.reset();

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "cancel-test-api",
        .stream = cancelCapturingStream,
        .stream_simple = cancelCapturingStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "cancel-test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const stream_id = protocol_types.generateUlid();
    var req = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    const resp = try server.handleEnvelope(req);
    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.payload == .ack);
    req.deinit(std.testing.allocator);

    try std.testing.expect(CancelMockState.received_cancel_token != null);
    if (CancelMockState.received_cancel_token) |ct| {
        try std.testing.expect(!ct.isCancelled());
    }

    const active = server.active_streams.get(stream_id);
    try std.testing.expect(active != null);
    if (active) |a| {
        try std.testing.expect(a.cancelled != null);
        if (a.cancelled) |c| {
            try std.testing.expect(!c.load(.acquire));
        }
    }
}

const BaseUrlMockState = struct {
    var buffer: [512]u8 = undefined;
    var received_base_url: ?[]const u8 = null;
    var received_max_tokens: u32 = 0;
    var received_compat: ?ai_types.OpenAICompatOptions = null;
    var received_reasoning: bool = false;

    fn reset() void {
        received_base_url = null;
        received_max_tokens = 0;
        received_compat = null;
        received_reasoning = false;
    }

    fn capture(model: ai_types.Model) void {
        const len = @min(model.base_url.len, buffer.len);
        @memcpy(buffer[0..len], model.base_url[0..len]);
        received_base_url = buffer[0..len];
        received_max_tokens = model.max_tokens;
        received_compat = model.compat;
        received_reasoning = model.reasoning;
    }
};

fn baseUrlCapturingStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = context;
    _ = options;

    BaseUrlMockState.capture(model);

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
    s.complete(.{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
    });
    s.markThreadDone();
    return s;
}

fn baseUrlCapturingStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = context;
    _ = options;

    BaseUrlMockState.capture(model);

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
    s.complete(.{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
    });
    s.markThreadDone();
    return s;
}

fn baseUrlCaptureRegistry(allocator: std.mem.Allocator) !api_registry.ApiRegistry {
    var registry = api_registry.ApiRegistry.init(allocator);
    errdefer registry.deinit();
    const provider = api_registry.ApiProvider{
        .api = "anthropic-messages",
        .stream = baseUrlCapturingStream,
        .stream_simple = baseUrlCapturingStreamSimple,
    };
    try registry.registerApiProvider(provider, null);
    return registry;
}

fn emptyBaseUrlModel(provider_id: []const u8, api: []const u8, model_id: []const u8) ai_types.Model {
    return .{
        .id = model_id,
        .name = model_id,
        .api = api,
        .provider = provider_id,
        .base_url = "",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 0,
    };
}

test "handleStreamRequest defaults empty base URL for known provider" {
    BaseUrlMockState.reset();
    defer BaseUrlMockState.reset();

    var registry = try baseUrlCaptureRegistry(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    var req = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = emptyBaseUrlModel("anthropic", "anthropic-messages", "claude-test"),
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    const resp = try server.handleEnvelope(req);
    req.deinit(std.testing.allocator);

    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.payload == .ack);
    if (resp) |r| {
        var mutable_resp = r;
        mutable_resp.deinit(std.testing.allocator);
    }

    const captured = BaseUrlMockState.received_base_url orelse return error.TestUnexpectedResult;
    const expected = try provider_base_url.defaultBaseUrlForRef(std.testing.allocator, "anthropic", "anthropic-messages");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, captured);
    try std.testing.expectEqual(DEFAULT_MODEL_MAX_TOKENS, BaseUrlMockState.received_max_tokens);
}

test "handleStreamRequest preserves explicit base URL" {
    BaseUrlMockState.reset();
    defer BaseUrlMockState.reset();

    var registry = try baseUrlCaptureRegistry(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    var explicit_model = emptyBaseUrlModel("anthropic", "anthropic-messages", "claude-test");
    explicit_model.base_url = "https://explicit.example.com";
    explicit_model.max_tokens = 1234;

    var req = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = explicit_model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    const resp = try server.handleEnvelope(req);
    req.deinit(std.testing.allocator);
    if (resp) |r| {
        var mutable_resp = r;
        mutable_resp.deinit(std.testing.allocator);
    }

    const captured = BaseUrlMockState.received_base_url orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://explicit.example.com", captured);
    try std.testing.expectEqual(@as(u32, 1234), BaseUrlMockState.received_max_tokens);
}

test "handleStreamRequest keeps unknown provider base URL empty" {
    BaseUrlMockState.reset();
    defer BaseUrlMockState.reset();

    var registry = try baseUrlCaptureRegistry(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    var req = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = emptyBaseUrlModel("mystery-vendor", "anthropic-messages", "mystery-model"),
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    const resp = try server.handleEnvelope(req);
    req.deinit(std.testing.allocator);
    if (resp) |r| {
        var mutable_resp = r;
        mutable_resp.deinit(std.testing.allocator);
    }

    const captured = BaseUrlMockState.received_base_url orelse return error.TestUnexpectedResult;
    const expected = try provider_base_url.defaultBaseUrlForRefWithRegion(std.testing.allocator, "mystery-vendor", "anthropic-messages", null);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, captured);
}

test "handleStreamRequest defaults catalog-issued codex and kimi base URLs" {
    {
        BaseUrlMockState.reset();
        defer BaseUrlMockState.reset();

        var registry = api_registry.ApiRegistry.init(std.testing.allocator);
        defer registry.deinit();
        const provider = api_registry.ApiProvider{
            .api = "openai-codex-responses",
            .stream = baseUrlCapturingStream,
            .stream_simple = baseUrlCapturingStreamSimple,
        };
        try registry.registerApiProvider(provider, null);

        var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
        defer server.deinit();

        var req = protocol_types.Envelope{
            .stream_id = protocol_types.generateUlid(),
            .message_id = protocol_types.generateUlid(),
            .sequence = 1,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .stream_request = .{
                .model = emptyBaseUrlModel("openai-codex", "openai-codex-responses", "gpt-5-codex"),
                .context = .{ .messages = &.{} },
                .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
            } },
        };
        const resp = try server.handleEnvelope(req);
        req.deinit(std.testing.allocator);
        if (resp) |r| {
            var mutable_resp = r;
            mutable_resp.deinit(std.testing.allocator);
        }

        const captured = BaseUrlMockState.received_base_url orelse return error.TestUnexpectedResult;
        try std.testing.expect(captured.len > 0);
        const expected = try provider_base_url.defaultBaseUrlForRefWithRegion(std.testing.allocator, "openai-codex", "openai-codex-responses", null);
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, captured);
        try std.testing.expect(BaseUrlMockState.received_reasoning);
    }

    {
        BaseUrlMockState.reset();
        defer BaseUrlMockState.reset();

        var registry = api_registry.ApiRegistry.init(std.testing.allocator);
        defer registry.deinit();
        const provider = api_registry.ApiProvider{
            .api = "openai-completions",
            .stream = baseUrlCapturingStream,
            .stream_simple = baseUrlCapturingStreamSimple,
        };
        try registry.registerApiProvider(provider, null);

        var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
        defer server.deinit();

        var req = protocol_types.Envelope{
            .stream_id = protocol_types.generateUlid(),
            .message_id = protocol_types.generateUlid(),
            .sequence = 1,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .stream_request = .{
                .model = emptyBaseUrlModel("kimi", "openai-completions", "kimi-k2.7-code"),
                .context = .{ .messages = &.{} },
                .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
            } },
        };
        const resp = try server.handleEnvelope(req);
        req.deinit(std.testing.allocator);
        if (resp) |r| {
            var mutable_resp = r;
            mutable_resp.deinit(std.testing.allocator);
        }

        const captured = BaseUrlMockState.received_base_url orelse return error.TestUnexpectedResult;
        try std.testing.expect(captured.len > 0);
        const expected = try provider_base_url.defaultBaseUrlForRefWithRegion(std.testing.allocator, "kimi", "openai-completions", null);
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, captured);
    }
}

test "handleStreamRequest honors kimi region stored on OAuth credentials" {
    BaseUrlMockState.reset();
    defer BaseUrlMockState.reset();

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const provider = api_registry.ApiProvider{
        .api = "openai-completions",
        .stream = baseUrlCapturingStream,
        .stream_simple = baseUrlCapturingStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var storage = AuthStorage{
        .providers = std.StringHashMap(oauth_storage.ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer storage.deinit();
    {
        const provider_id = try std.testing.allocator.dupe(u8, "kimi");
        const provider_data = try std.testing.allocator.dupe(u8, "region:global");
        try storage.providers.put(provider_id, .{ .oauth = .{
            .refresh = try std.testing.allocator.dupe(u8, "refresh"),
            .access = try std.testing.allocator.dupe(u8, "access"),
            .expires = 0,
            .provider_data = provider_data,
        } });
    }

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{ .auth_storage = &storage });
    defer server.deinit();

    var req = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = emptyBaseUrlModel("kimi", "openai-completions", "kimi-k2.7-code"),
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    const resp = try server.handleEnvelope(req);
    req.deinit(std.testing.allocator);
    if (resp) |r| {
        var mutable_resp = r;
        mutable_resp.deinit(std.testing.allocator);
    }

    const captured = BaseUrlMockState.received_base_url orelse return error.TestUnexpectedResult;
    const expected = try provider_base_url.defaultBaseUrlForRefWithRegion(std.testing.allocator, "kimi", "openai-completions", "global");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, captured);
}

fn kimiRegionTestLoader(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!oauth_storage.AuthStorage {
    _ = ctx;
    var storage = oauth_storage.AuthStorage{
        .providers = std.StringHashMap(oauth_storage.ProviderAuth).init(allocator),
        .allocator = allocator,
    };
    errdefer storage.deinit();
    const provider_id = try allocator.dupe(u8, "kimi");
    const provider_data = try allocator.dupe(u8, "region:global");
    try storage.providers.put(provider_id, .{ .oauth = .{
        .refresh = try allocator.dupe(u8, "refresh"),
        .access = try allocator.dupe(u8, "access"),
        .expires = 0,
        .provider_data = provider_data,
    } });
    return storage;
}

test "handleStreamRequest reads kimi region via configured auth loader" {
    BaseUrlMockState.reset();
    defer BaseUrlMockState.reset();

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const provider = api_registry.ApiProvider{
        .api = "openai-completions",
        .stream = baseUrlCapturingStream,
        .stream_simple = baseUrlCapturingStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{
        .load_auth_storage_fn = kimiRegionTestLoader,
    });
    defer server.deinit();

    var req = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = emptyBaseUrlModel("kimi", "openai-completions", "kimi-k2.7-code"),
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    const resp = try server.handleEnvelope(req);
    req.deinit(std.testing.allocator);
    if (resp) |r| {
        var mutable_resp = r;
        mutable_resp.deinit(std.testing.allocator);
    }

    const captured = BaseUrlMockState.received_base_url orelse return error.TestUnexpectedResult;
    const expected = try provider_base_url.defaultBaseUrlForRefWithRegion(std.testing.allocator, "kimi", "openai-completions", "global");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, captured);
}

test "handleStreamRequest infers reasoning capability and preserves explicit flags" {
    {
        BaseUrlMockState.reset();
        defer BaseUrlMockState.reset();

        var registry = try baseUrlCaptureRegistry(std.testing.allocator);
        defer registry.deinit();

        var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
        defer server.deinit();

        var explicit_model = emptyBaseUrlModel("anthropic", "anthropic-messages", "claude-1-0");
        explicit_model.reasoning = true;

        var req = protocol_types.Envelope{
            .stream_id = protocol_types.generateUlid(),
            .message_id = protocol_types.generateUlid(),
            .sequence = 1,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .stream_request = .{
                .model = explicit_model,
                .context = .{ .messages = &.{} },
                .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
            } },
        };
        const resp = try server.handleEnvelope(req);
        req.deinit(std.testing.allocator);
        if (resp) |r| {
            var mutable_resp = r;
            mutable_resp.deinit(std.testing.allocator);
        }

        try std.testing.expect(BaseUrlMockState.received_reasoning);
    }
    {
        BaseUrlMockState.reset();
        defer BaseUrlMockState.reset();

        var registry = try baseUrlCaptureRegistry(std.testing.allocator);
        defer registry.deinit();

        var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
        defer server.deinit();

        var req = protocol_types.Envelope{
            .stream_id = protocol_types.generateUlid(),
            .message_id = protocol_types.generateUlid(),
            .sequence = 1,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .stream_request = .{
                .model = emptyBaseUrlModel("anthropic", "anthropic-messages", "claude-3-5-sonnet"),
                .context = .{ .messages = &.{} },
                .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
            } },
        };
        const resp = try server.handleEnvelope(req);
        req.deinit(std.testing.allocator);
        if (resp) |r| {
            var mutable_resp = r;
            mutable_resp.deinit(std.testing.allocator);
        }

        try std.testing.expect(!BaseUrlMockState.received_reasoning);
    }
    {
        BaseUrlMockState.reset();
        defer BaseUrlMockState.reset();

        var registry = try baseUrlCaptureRegistry(std.testing.allocator);
        defer registry.deinit();

        var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
        defer server.deinit();

        var explicit_model = emptyBaseUrlModel("anthropic", "anthropic-messages", "claude-sonnet-4-5");
        explicit_model.base_url = "https://explicit.example.com";
        explicit_model.reasoning = false;

        var req = protocol_types.Envelope{
            .stream_id = protocol_types.generateUlid(),
            .message_id = protocol_types.generateUlid(),
            .sequence = 1,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .stream_request = .{
                .model = explicit_model,
                .context = .{ .messages = &.{} },
                .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
            } },
        };
        const resp = try server.handleEnvelope(req);
        req.deinit(std.testing.allocator);
        if (resp) |r| {
            var mutable_resp = r;
            mutable_resp.deinit(std.testing.allocator);
        }

        try std.testing.expect(!BaseUrlMockState.received_reasoning);
    }
}

test "handleStreamRequest applies advertised catalog token limits" {
    {
        BaseUrlMockState.reset();
        defer BaseUrlMockState.reset();

        var registry = try baseUrlCaptureRegistry(std.testing.allocator);
        defer registry.deinit();

        var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
        defer server.deinit();

        var req = protocol_types.Envelope{
            .stream_id = protocol_types.generateUlid(),
            .message_id = protocol_types.generateUlid(),
            .sequence = 1,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .stream_request = .{
                .model = emptyBaseUrlModel("anthropic", "anthropic-messages", "claude-sonnet-4-5"),
                .context = .{ .messages = &.{} },
                .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
            } },
        };
        const resp = try server.handleEnvelope(req);
        req.deinit(std.testing.allocator);
        if (resp) |r| {
            var mutable_resp = r;
            mutable_resp.deinit(std.testing.allocator);
        }

        try std.testing.expectEqual(@as(u32, 8_192), BaseUrlMockState.received_max_tokens);
    }
    {
        BaseUrlMockState.reset();
        defer BaseUrlMockState.reset();

        var registry = api_registry.ApiRegistry.init(std.testing.allocator);
        defer registry.deinit();
        const provider = api_registry.ApiProvider{
            .api = "openai-completions",
            .stream = baseUrlCapturingStream,
            .stream_simple = baseUrlCapturingStreamSimple,
        };
        try registry.registerApiProvider(provider, null);

        var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
        defer server.deinit();

        var req = protocol_types.Envelope{
            .stream_id = protocol_types.generateUlid(),
            .message_id = protocol_types.generateUlid(),
            .sequence = 1,
            .timestamp = compat.time.nowMillis(),
            .payload = .{ .stream_request = .{
                .model = emptyBaseUrlModel("kimi", "openai-completions", "kimi-k2.7-code"),
                .context = .{ .messages = &.{} },
                .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
            } },
        };
        const resp = try server.handleEnvelope(req);
        req.deinit(std.testing.allocator);
        if (resp) |r| {
            var mutable_resp = r;
            mutable_resp.deinit(std.testing.allocator);
        }

        try std.testing.expectEqual(@as(u32, 16_384), BaseUrlMockState.received_max_tokens);
    }
}

test "handleCompleteRequest defaults empty base URL for known provider" {
    BaseUrlMockState.reset();
    defer BaseUrlMockState.reset();

    var registry = try baseUrlCaptureRegistry(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    var req = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .complete_request = .{
            .model = emptyBaseUrlModel("anthropic", "anthropic-messages", "claude-test"),
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };
    const resp = try server.handleEnvelope(req);
    req.deinit(std.testing.allocator);

    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.payload == .result);
    if (resp) |r| {
        var mutable_resp = r;
        mutable_resp.deinit(std.testing.allocator);
    }

    const captured = BaseUrlMockState.received_base_url orelse return error.TestUnexpectedResult;
    const expected = try provider_base_url.defaultBaseUrlForRef(std.testing.allocator, "anthropic", "anthropic-messages");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, captured);
}

fn cancelCapturingStreamSimple(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;

    if (options) |opts| {
        CancelMockState.received_cancel_token = opts.cancel_token;
    }

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
    s.complete(.{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
    });
    s.markThreadDone();
    return s;
}

test "handleAbortRequest signals CancelToken so provider stops early" {
    CancelMockState.reset();
    defer CancelMockState.reset();

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "cancel-test-api-2",
        .stream = cancelCapturingStream,
        .stream_simple = cancelCapturingStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "cancel-test-api-2",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const stream_id = protocol_types.generateUlid();
    var req = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    const resp = try server.handleEnvelope(req);
    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.payload == .ack);
    req.deinit(std.testing.allocator);

    try std.testing.expect(CancelMockState.received_cancel_token != null);
    if (CancelMockState.received_cancel_token) |ct| {
        try std.testing.expect(!ct.isCancelled());
    }

    const abort_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .abort_request = .{
            .target_stream_id = stream_id,
            .reason = protocol_types.OwnedSlice(u8).initBorrowed("User cancelled"),
        } },
    };

    const abort_resp = try server.handleEnvelope(abort_env);
    try std.testing.expect(abort_resp != null);
    try std.testing.expect(abort_resp.?.payload == .ack);

    try std.testing.expectEqual(@as(usize, 0), server.activeStreamCount());
    server.cleanupCompletedStreams();

    var outbox_env = server.popOutbound();
    try std.testing.expect(outbox_env != null);
    if (outbox_env) |*env| {
        try std.testing.expect(env.payload == .stream_error);
        try std.testing.expectEqual(protocol_types.ErrorCode.stream_cancelled, env.payload.stream_error.code);
        try std.testing.expectEqualStrings("User cancelled", env.payload.stream_error.message.slice());
        env.deinit(std.testing.allocator);
    }
}

test "handleAbortRequest with custom reason propagates to outbox stream_error" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const stream_id = protocol_types.generateUlid();
    var stream_req = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    const create_resp = try server.handleEnvelope(stream_req);
    try std.testing.expect(create_resp != null);
    stream_req.deinit(std.testing.allocator);

    const abort_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 2,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .abort_request = .{
            .target_stream_id = stream_id,
            .reason = protocol_types.OwnedSlice(u8).initBorrowed("AbortSignal triggered"),
        } },
    };

    const abort_resp = try server.handleEnvelope(abort_env);
    try std.testing.expect(abort_resp != null);
    try std.testing.expect(abort_resp.?.payload == .ack);

    var outbox_env = server.popOutbound();
    try std.testing.expect(outbox_env != null);
    if (outbox_env) |*env| {
        try std.testing.expect(env.payload == .stream_error);
        try std.testing.expectEqual(protocol_types.ErrorCode.stream_cancelled, env.payload.stream_error.code);
        try std.testing.expectEqualStrings("AbortSignal triggered", env.payload.stream_error.message.slice());
        env.deinit(std.testing.allocator);
    }

    try std.testing.expect(server.popOutbound() == null);
}

test "cleanupCompletedStreams frees cancel flag for completed streams" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const provider = api_registry.ApiProvider{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    };
    try registry.registerApiProvider(provider, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    const stream_id = protocol_types.generateUlid();
    var stream_req = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key") },
        } },
    };

    const resp = try server.handleEnvelope(stream_req);
    try std.testing.expect(resp != null);
    stream_req.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), server.activeStreamCount());

    server.cleanupCompletedStreams();
    try std.testing.expectEqual(@as(usize, 0), server.activeStreamCount());
}

test "ErrorCode.stream_cancelled serializes and deserializes in stream_error" {
    const allocator = std.testing.allocator;

    const msg = try allocator.dupe(u8, "Client aborted");
    var env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_error = .{
            .code = .stream_cancelled,
            .message = protocol_types.OwnedSlice(u8).initOwned(msg),
        } },
    };

    const json = try envelope.serializeEnvelope(env, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"code\":\"stream_cancelled\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"message\":\"Client aborted\"") != null);

    var parsed = try envelope.deserializeEnvelope(json, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.payload == .stream_error);
    try std.testing.expectEqual(protocol_types.ErrorCode.stream_cancelled, parsed.payload.stream_error.code);
    try std.testing.expectEqualStrings("Client aborted", parsed.payload.stream_error.message.slice());

    env.deinit(allocator);
}

const CapturedCreds = struct {
    var captured_key: ?[]u8 = null;
    var captured_allocator: ?std.mem.Allocator = null;

    fn reset() void {
        if (captured_key) |k| {
            captured_allocator.?.free(k);
        }
        captured_key = null;
        captured_allocator = null;
    }
};

fn capturingStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    _ = model;
    _ = context;

    if (options) |opts| {
        if (opts.getApiKey()) |key| {
            CapturedCreds.captured_key = try allocator.dupe(u8, key);
            CapturedCreds.captured_allocator = allocator;
        }
    }

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.owns_events = true;
    s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
    const result = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
    };
    s.complete(result);
    s.markThreadDone();
    return s;
}

test "credential resolution: explicit api_key bypasses storage lookup" {
    CapturedCreds.reset();
    defer CapturedCreds.reset();

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerApiProvider(.{
        .api = "test-api",
        .stream = capturingStream,
        .stream_simple = mockStreamSimple,
    }, null);

    var storage = AuthStorage{
        .providers = std.StringHashMap(oauth_storage.ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer storage.deinit();
    {
        const provider_id = try std.testing.allocator.dupe(u8, "test-provider");
        const stored = try std.testing.allocator.dupe(u8, "stored-key-MUST-NOT-BE-USED");
        try storage.providers.put(provider_id, .{ .api_key = stored });
    }

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{ .auth_storage = &storage });
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test-provider",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
            .options = .{ .api_key = ai_types.OwnedSlice(u8).initBorrowed("explicit-from-client") },
        } },
    };
    defer stream_req_env.deinit(std.testing.allocator);

    const response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .ack);

    try std.testing.expect(CapturedCreds.captured_key != null);
    try std.testing.expectEqualStrings("explicit-from-client", CapturedCreds.captured_key.?);
}

test "credential resolution: missing api_key loads credentials from storage by provider_id" {
    CapturedCreds.reset();
    defer CapturedCreds.reset();

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerApiProvider(.{
        .api = "test-api",
        .stream = capturingStream,
        .stream_simple = mockStreamSimple,
    }, null);

    var storage = AuthStorage{
        .providers = std.StringHashMap(oauth_storage.ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer storage.deinit();
    {
        const provider_id = try std.testing.allocator.dupe(u8, "test-provider");
        const stored = try std.testing.allocator.dupe(u8, "sk-from-storage");
        try storage.providers.put(provider_id, .{ .api_key = stored });
    }

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{ .auth_storage = &storage });
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test-provider",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };
    defer stream_req_env.deinit(std.testing.allocator);

    const response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .ack);

    try std.testing.expect(CapturedCreds.captured_key != null);
    try std.testing.expectEqualStrings("sk-from-storage", CapturedCreds.captured_key.?);
}

test "credential resolution: missing api_key and missing storage entry falls back to provider" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerApiProvider(.{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    }, null);

    var storage = AuthStorage{
        .providers = std.StringHashMap(oauth_storage.ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
    };
    defer storage.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{ .auth_storage = &storage });
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test-provider",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };
    defer stream_req_env.deinit(std.testing.allocator);

    var response = try server.handleEnvelope(stream_req_env);
    defer if (response) |*r| r.deinit(std.testing.allocator);

    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .ack);
    try std.testing.expectEqual(@as(usize, 1), server.activeStreamCount());
    server.cleanupCompletedStreams();
    try std.testing.expectEqual(@as(usize, 0), server.activeStreamCount());
}

test "credential resolution: complete_request without credentials falls back to provider" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerApiProvider(.{
        .api = "test-api",
        .stream = mockStream,
        .stream_simple = mockStreamSimple,
    }, null);

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const model = ai_types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = "test-api",
        .provider = "test-provider",
        .base_url = "https://api.test.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };

    var complete_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUlid(),
        .message_id = protocol_types.generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .{ .complete_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };
    defer complete_req_env.deinit(std.testing.allocator);

    var response = try server.handleEnvelope(complete_req_env);
    defer if (response) |*r| r.deinit(std.testing.allocator);

    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .result);
}

fn expectRefreshLockAcquired(result: refresh_lock_mod.RefreshLock.AcquireResult) !u64 {
    return switch (result) {
        .acquired => |generation| generation,
        else => error.TestUnexpectedResult,
    };
}

test "refresh lock prevents duplicate concurrent refresh calls" {
    var lock = refresh_lock_mod.RefreshLock.init(std.testing.allocator);
    defer lock.deinit();

    const gen1 = try expectRefreshLockAcquired(try lock.acquire("test-auth", null));

    lock.complete("test-auth", null, gen1, null);

    const gen2 = try expectRefreshLockAcquired(try lock.acquire("test-auth", null));
    lock.complete("test-auth", null, gen2, null);
}

test "refreshWithLock wraps refreshCredentials under the lock" {
    var state = AuthTestState{ .expires = compat.time.nowMillis() - 1 };
    auth_test_state = &state;
    defer auth_test_state = null;

    var storage = oauth_storage.AuthStorage{
        .providers = std.StringHashMap(oauth_storage.ProviderAuth).init(std.testing.allocator),
        .allocator = std.testing.allocator,
        .save_fn = authTestSaveStorage,
    };
    defer storage.deinit();

    const refresh = try std.testing.allocator.dupe(u8, "refresh");
    const access = try std.testing.allocator.dupe(u8, "access-0");
    try storage.providers.put(try std.testing.allocator.dupe(u8, "test-auth"), .{
        .oauth = .{
            .refresh = refresh,
            .access = access,
            .expires = compat.time.nowMillis() - 1,
        },
    });

    const oauth_provider = oauth_storage.OAuthProvider{
        .id = "test-auth",
        .refresh_fn = authTestRefresh,
        .get_api_key_fn = authTestGetApiKey,
    };

    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{
        .load_auth_storage_fn = authTestLoadStorage,
        .load_auth_storage_ctx = &state,
    });
    defer server.deinit();

    try refreshWithLock(&server, "test-auth", &storage, oauth_provider);
    try std.testing.expectEqual(@as(usize, 1), state.refresh_count);

    try refreshWithLock(&server, "test-auth", &storage, oauth_provider);
    try std.testing.expectEqual(@as(usize, 2), state.refresh_count);
}

test "refresh lock propagates refresh failure to waiters" {
    var lock = refresh_lock_mod.RefreshLock.init(std.testing.allocator);
    defer lock.deinit();

    const gen1 = try expectRefreshLockAcquired(try lock.acquire("failing-provider", null));

    lock.complete("failing-provider", null, gen1, error.AuthRefreshFailed);

    const gen2 = try expectRefreshLockAcquired(try lock.acquire("failing-provider", null));
    lock.complete("failing-provider", null, gen2, error.AuthRefreshFailed);
}

test "refresh lock timeout returns timed_out for stale locks" {
    var lock = refresh_lock_mod.RefreshLock.initWithTimeout(std.testing.allocator, 1);
    defer lock.deinit();

    const gen1 = try expectRefreshLockAcquired(try lock.acquire("slow-provider", null));

    compat.time.sleepNs(5 * std.time.ns_per_ms);

    const r2 = try lock.acquire("slow-provider", null);
    try std.testing.expect(r2 == .timed_out);

    lock.complete("slow-provider", null, gen1, null);
}

test "refresh lock independent providers do not block each other" {
    var lock = refresh_lock_mod.RefreshLock.init(std.testing.allocator);
    defer lock.deinit();

    const gen1 = try expectRefreshLockAcquired(try lock.acquire("provider-a", null));

    const gen2 = try expectRefreshLockAcquired(try lock.acquire("provider-b", null));

    lock.complete("provider-a", null, gen1, null);
    lock.complete("provider-b", null, gen2, null);
}
