const std = @import("std");
const protocol_types = @import("protocol_types");
const envelope = @import("protocol_envelope");
const partial_serializer = @import("partial_serializer.zig");
const model_ref = @import("model_ref");
const model_catalog_types = @import("model_catalog_types");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const event_stream = @import("event_stream");
const hive_array = @import("hive_array");

/// Errors for sequence validation
pub const SequenceError = error{
    InvalidSequence,
    DuplicateSequence,
    SequenceGap,
};

/// Validate incoming sequence number
fn validateSequence(expected: u64, received: u64) SequenceError!void {
    if (received == 0) return error.InvalidSequence;
    if (received < expected) return error.DuplicateSequence;
    if (received > expected) return error.SequenceGap;
    // received == expected is OK
}

/// Helper to create a NACK for sequence errors
fn createSequenceNack(
    allocator: std.mem.Allocator,
    stream_id: protocol_types.Uuid,
    message_id: protocol_types.Uuid,
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
            .timestamp = std.time.milliTimestamp(),
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
        .auth_status = .authenticated,
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
        .auth_status = .authenticated,
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
        .auth_status = .authenticated,
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
        .auth_status = .login_required,
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
        .auth_status = .authenticated,
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

/// Server-side protocol handler for the Makai Wire Protocol
///
/// Current Limitation (v1.0): The server creates streams and returns ACK but does
/// not yet forward stream events as protocol envelopes. Event forwarding requires
/// integration with the async runtime to poll provider streams and wrap events.
/// This is planned for v2.0.
pub const ProtocolServer = struct {
    allocator: std.mem.Allocator,

    /// Active streams by stream_id
    /// NOTE: While this map supports multiple streams, event forwarding is not
    /// yet implemented. The server currently handles stream creation/abortion
    /// but does not poll and forward events from provider streams.
    active_streams: std.AutoHashMap(protocol_types.Uuid, ActiveStream),

    /// API registry for provider lookup
    registry: *api_registry.ApiRegistry,

    /// Sequence counter per stream (outgoing)
    sequence_counters: std.AutoHashMap(protocol_types.Uuid, u64),

    /// Expected next sequence number per stream (incoming)
    expected_sequences: std.AutoHashMap(protocol_types.Uuid, u64),

    /// Queued outbound server envelopes that must be emitted after immediate ACK.
    outbox: std.ArrayList(protocol_types.Envelope),

    /// Options
    options: Options,

    pub const ActiveStream = struct {
        stream_id: protocol_types.Uuid,
        model: ai_types.Model,
        event_stream: *event_stream.AssistantMessageEventStream,
        partial_state: partial_serializer.PartialState,
        started_at: i64,
    };

    pub const DynamicCatalogFetchFn = *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: protocol_types.ModelsRequest,
    ) anyerror!protocol_types.ModelsResponse;

    pub const Options = struct {
        include_partial: bool = false,
        max_streams: usize = 100,
        stream_timeout_ms: u64 = 300_000,
        supports_model_catalog: bool = true,
        enable_static_catalog_fallback: bool = true,
        dynamic_catalog_fetcher: ?DynamicCatalogFetchFn = null,
        dynamic_catalog_ctx: ?*anyopaque = null,
    };

    pub fn init(allocator: std.mem.Allocator, registry: *api_registry.ApiRegistry, options: Options) ProtocolServer {
        return .{
            .allocator = allocator,
            .active_streams = std.AutoHashMap(protocol_types.Uuid, ActiveStream).init(allocator),
            .registry = registry,
            .sequence_counters = std.AutoHashMap(protocol_types.Uuid, u64).init(allocator),
            .expected_sequences = std.AutoHashMap(protocol_types.Uuid, u64).init(allocator),
            .outbox = std.ArrayList(protocol_types.Envelope){},
            .options = options,
        };
    }

    pub fn deinit(self: *ProtocolServer) void {
        // Clean up all active streams
        var iter = self.active_streams.iterator();
        while (iter.next()) |entry| {
            var active_stream = entry.value_ptr.*;
            active_stream.partial_state.deinit();
            // Clean up the event stream
            active_stream.event_stream.deinit();
            self.allocator.destroy(active_stream.event_stream);
        }
        self.active_streams.deinit();
        self.sequence_counters.deinit();
        self.expected_sequences.deinit();
        for (self.outbox.items) |*out| {
            out.deinit(self.allocator);
        }
        self.outbox.deinit(self.allocator);

        // Poison freed memory to catch use-after-free in debug builds
        self.* = undefined;
    }

    pub fn popOutbound(self: *ProtocolServer) ?protocol_types.Envelope {
        if (self.outbox.items.len == 0) return null;
        return self.outbox.orderedRemove(0);
    }

    /// Handle incoming envelope, optionally return response envelope
    pub fn handleEnvelope(self: *ProtocolServer, env: protocol_types.Envelope) !?protocol_types.Envelope {
        if (env.version != protocol_types.PROTOCOL_VERSION) {
            return try envelope.createVersionMismatchNack(env, self.allocator);
        }

        switch (env.payload) {
            .stream_request => |req| {
                // Validate sequence - client should start at 1 for new streams
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
                // Validate sequence - client should start at 1 for complete requests
                if (env.sequence != 1) {
                    return try createSequenceNack(self.allocator, env.stream_id, env.message_id, error.InvalidSequence);
                }
                return try handleCompleteRequest(self, req, env.stream_id, env.message_id, env.sequence);
            },
            .ack, .nack, .event, .result, .stream_error, .models_response => {
                // Server receives these from clients - no response needed
                return null;
            },
            .ping => {
                // Respond with pong containing the ping's message_id as ping_id
                const ping_id_str = try protocol_types.uuidToString(env.message_id, self.allocator);
                const pong_payload: protocol_types.Payload = .{ .pong = .{ .ping_id = protocol_types.OwnedSlice(u8).initOwned(ping_id_str) } };
                return envelope.createReply(env, pong_payload, self.allocator);
            },
            .pong => {
                // No response to pong
                return null;
            },
            .goodbye => {
                // Handle graceful shutdown - no response needed
                return null;
            },
            .sync_request => {
                // Handle sync request - for now, return not implemented
                // TODO: Implement full state sync
                return try envelope.createNack(
                    env,
                    "Sync not yet implemented",
                    protocol_types.ErrorCode.not_implemented,
                    self.allocator,
                );
            },
            .sync => {
                // Handle sync response - for now, ignore
                // TODO: Implement full state sync
                return null;
            },
        }
    }

    /// Clean up completed streams
    pub fn cleanupCompletedStreams(self: *ProtocolServer) void {
        // Common path: avoid heap allocation by collecting IDs in a fixed pool.
        const CleanupNode = struct {
            stream_id: protocol_types.Uuid,
            next: ?*@This() = null,
        };
        var remove_pool = hive_array.HiveArray(CleanupNode, 128).init();
        var remove_head: ?*CleanupNode = null;

        // Overflow path for unusually large batches in a single cleanup pass.
        var overflow = std.ArrayList(protocol_types.Uuid).initCapacity(self.allocator, 8) catch return;
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

        // Remove pooled IDs
        var current = remove_head;
        while (current) |node| {
            const stream_id = node.stream_id;
            const next = node.next;

            if (self.active_streams.fetchRemove(stream_id)) |removed| {
                var partial = removed.value.partial_state;
                partial.deinit();
                removed.value.event_stream.deinit();
                self.allocator.destroy(removed.value.event_stream);
            }
            _ = self.sequence_counters.remove(stream_id);
            _ = self.expected_sequences.remove(stream_id);

            remove_pool.put(node);
            current = next;
        }

        // Remove overflow IDs
        for (overflow.items) |stream_id| {
            if (self.active_streams.fetchRemove(stream_id)) |removed| {
                var partial = removed.value.partial_state;
                partial.deinit();
                removed.value.event_stream.deinit();
                self.allocator.destroy(removed.value.event_stream);
            }
            _ = self.sequence_counters.remove(stream_id);
            _ = self.expected_sequences.remove(stream_id);
        }
    }

    /// Get active stream count
    pub fn activeStreamCount(self: *ProtocolServer) usize {
        return self.active_streams.count();
    }

    /// Public access to active streams for event polling
    pub const ActiveStreamIterator = struct {
        iter: std.AutoHashMap(protocol_types.Uuid, ActiveStream).Iterator,

        pub fn next(self: *ActiveStreamIterator) ?struct {
            stream_id: protocol_types.Uuid,
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

    /// Get iterator over active streams
    pub fn activeStreamIterator(self: *ProtocolServer) ActiveStreamIterator {
        return .{
            .iter = self.active_streams.iterator(),
        };
    }

    /// Get next sequence number for a stream (public for event forwarding)
    pub fn getNextSequence(self: *ProtocolServer, stream_id: protocol_types.Uuid) u64 {
        return self.nextSequence(stream_id);
    }

    /// Get next sequence number for a stream
    fn nextSequence(self: *ProtocolServer, stream_id: protocol_types.Uuid) u64 {
        const current = self.sequence_counters.get(stream_id) orelse 0;
        const next = current + 1;
        self.sequence_counters.put(stream_id, next) catch return next;
        return next;
    }

    /// Validates and updates expected sequence for a stream/query scope.
    /// Used by request payloads that accept per-stream incremental sequencing.
    fn validateAndUpdateSequence(self: *ProtocolServer, stream_id: protocol_types.Uuid, received: u64) SequenceError!void {
        const expected = self.expected_sequences.get(stream_id) orelse 1;
        try validateSequence(expected, received);
        // Update expected sequence for next message
        self.expected_sequences.put(stream_id, received + 1) catch {};
    }
};

/// Handle stream_request - create stream, return ack with stream_id
fn handleStreamRequest(server: *ProtocolServer, request: protocol_types.StreamRequest, stream_id: protocol_types.Uuid, in_reply_to: protocol_types.Uuid, received_seq: u64) !protocol_types.Envelope {
    // Reject duplicate stream_id
    if (server.active_streams.contains(stream_id)) {
        return try envelope.createNack(
            .{
                .stream_id = stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            "Stream ID already in use",
            .stream_already_exists,
            server.allocator,
        );
    }

    // Check max streams limit
    if (server.active_streams.count() >= server.options.max_streams) {
        return try envelope.createNack(
            .{
                .stream_id = stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            "Maximum concurrent streams limit reached",
            .rate_limited,
            server.allocator,
        );
    }

    // Look up provider in registry using model.api
    const provider = server.registry.getApiProvider(request.model.api) orelse {
        return try envelope.createNack(
            .{
                .stream_id = stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            "Provider not found for API",
            .provider_error,
            server.allocator,
        );
    };

    // Create new stream via provider.stream()
    const stream = provider.stream(request.model, request.context, request.options, server.allocator) catch |err| {
        const err_msg = switch (err) {
            error.OutOfMemory => "Out of memory",
            else => "Failed to create stream",
        };
        return try envelope.createNack(
            .{
                .stream_id = stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            err_msg,
            .provider_error,
            server.allocator,
        );
    };
    // Provider streams are produced by background threads; wait for producer completion
    // before deinit/destroy during abort and cleanup paths.
    stream.wait_for_thread_on_deinit = true;

    // Create ActiveStream entry
    const active_stream = ProtocolServer.ActiveStream{
        .stream_id = stream_id,
        .model = request.model,
        .event_stream = stream,
        .partial_state = partial_serializer.PartialState.init(server.allocator),
        .started_at = std.time.milliTimestamp(),
    };

    // Store in active_streams
    try server.active_streams.put(stream_id, active_stream);

    // Initialize sequence counter to 1 since we're about to return sequence 1 in ACK
    try server.sequence_counters.put(stream_id, 1);

    // Initialize expected sequence for incoming messages (starts at 1)
    // The first message for a new stream should have sequence 1
    try server.expected_sequences.put(stream_id, received_seq + 1);

    // Return ack with acknowledged_id
    return .{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .in_reply_to = in_reply_to,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .ack = .{
            .acknowledged_id = in_reply_to,
        } },
    };
}

/// Handle abort_request - cancel stream, return ack
fn handleAbortRequest(server: *ProtocolServer, request: protocol_types.AbortRequest, stream_id: protocol_types.Uuid, in_reply_to: protocol_types.Uuid, received_seq: u64) !protocol_types.Envelope {
    // Validate sequence for existing stream using validateAndUpdateSequence
    server.validateAndUpdateSequence(request.target_stream_id, received_seq) catch |err| {
        return try createSequenceNack(server.allocator, stream_id, in_reply_to, err);
    };

    // Find stream by stream_id
    if (server.active_streams.fetchRemove(request.target_stream_id)) |removed| {
        // Complete the stream with an error
        const reason = request.getReason() orelse "Stream aborted";
        removed.value.event_stream.completeWithError(reason);

        // Clean up - need to copy to mutable for deinit
        var partial = removed.value.partial_state;
        partial.deinit();
        removed.value.event_stream.deinit();
        server.allocator.destroy(removed.value.event_stream);

        // Get sequence BEFORE removing counter, then remove
        const seq = server.nextSequence(request.target_stream_id);
        _ = server.sequence_counters.remove(request.target_stream_id);
        _ = server.expected_sequences.remove(request.target_stream_id);

        // Return ack
        return .{
            .stream_id = request.target_stream_id,
            .message_id = protocol_types.generateUuid(),
            .sequence = seq,
            .in_reply_to = in_reply_to,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .ack = .{
                .acknowledged_id = in_reply_to,
            } },
        };
    } else {
        // Stream not found (already completed or never existed)
        // Per spec, abort is idempotent - return ACK even if stream not found
        return .{
            .stream_id = request.target_stream_id,
            .message_id = protocol_types.generateUuid(),
            .sequence = 0,
            .in_reply_to = in_reply_to,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .ack = .{
                .acknowledged_id = in_reply_to,
            } },
        };
    }
}

/// Handle complete_request - get final result
fn handleCompleteRequest(server: *ProtocolServer, request: protocol_types.CompleteRequest, stream_id: protocol_types.Uuid, in_reply_to: protocol_types.Uuid, received_seq: u64) !protocol_types.Envelope {
    _ = received_seq; // Sequence validation is done in handleEnvelope

    // For complete_request, we use the stream_id from the envelope
    // Since CompleteRequest doesn't have a target_stream_id, we need to find
    // a stream for this model/context combination, or create one for non-streaming

    // Look up provider
    const provider = server.registry.getApiProvider(request.model.api) orelse {
        return try envelope.createNack(
            .{
                .stream_id = stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            "Provider not found for API",
            .provider_error,
            server.allocator,
        );
    };

    // Create a stream for non-streaming completion
    const stream = provider.stream(request.model, request.context, request.options, server.allocator) catch |err| {
        const err_msg = switch (err) {
            error.OutOfMemory => "Out of memory",
            else => "Failed to create stream",
        };
        return try envelope.createNack(
            .{
                .stream_id = stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            err_msg,
            .provider_error,
            server.allocator,
        );
    };

    // Wait for stream to complete (with timeout)
    const timeout_ms = server.options.stream_timeout_ms;
    _ = stream.waitForThread(timeout_ms);

    // Get result
    if (stream.getResult()) |result| {
        // Clone the result to return (the stream owns the original)
        var cloned_result = try ai_types.cloneAssistantMessage(server.allocator, result);
        cloned_result.is_owned = true;

        return .{
            .stream_id = stream_id,
            .message_id = protocol_types.generateUuid(),
            .sequence = 1,
            .in_reply_to = in_reply_to,
            .timestamp = std.time.milliTimestamp(),
            .payload = .{ .result = cloned_result },
        };
    } else if (stream.getError()) |err_msg| {
        // Return error as nack
        return try envelope.createNack(
            .{
                .stream_id = stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
                .payload = .ping,
            },
            err_msg,
            .provider_error,
            server.allocator,
        );
    } else {
        // Timeout or unknown error
        return try envelope.createNack(
            .{
                .stream_id = stream_id,
                .message_id = in_reply_to,
                .sequence = 0,
                .timestamp = std.time.milliTimestamp(),
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
    stream_id: protocol_types.Uuid,
    in_reply_to: protocol_types.Uuid,
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
        .message_id = protocol_types.generateUuid(),
        .sequence = server.nextSequence(stream_id),
        .in_reply_to = in_reply_to,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .ack = .{
            .acknowledged_id = in_reply_to,
        } },
    };

    try server.outbox.append(server.allocator, .{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = server.nextSequence(stream_id),
        .in_reply_to = in_reply_to,
        .timestamp = std.time.milliTimestamp(),
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
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
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
        .fetched_at_ms = std.time.milliTimestamp(),
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

    var filtered = std.ArrayList(protocol_types.ModelDescriptor){};
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
        .fetched_at_ms = std.time.milliTimestamp(),
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
    stream_id: protocol_types.Uuid,
    in_reply_to: protocol_types.Uuid,
    code: protocol_types.ErrorCode,
    reason: []const u8,
) !protocol_types.Envelope {
    return .{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = server.nextSequence(stream_id),
        .in_reply_to = in_reply_to,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .nack = .{
            .rejected_id = in_reply_to,
            .reason = protocol_types.OwnedSlice(u8).initOwned(try server.allocator.dupe(u8, reason)),
            .error_code = code,
        } },
    };
}

// Tests

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

    // Complete immediately for tests
    const result = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = std.time.milliTimestamp(),
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

    const result = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = std.time.milliTimestamp(),
    };
    s.complete(result);
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
    try std.testing.expect(std.mem.indexOf(u8, ambiguous_nack.payload.nack.reason.slice(), "multiple APIs") != null);

    var missing = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
    try std.testing.expect(std.mem.indexOf(u8, missing_nack.payload.nack.reason.slice(), "model not found") != null);
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .ping,
    };

    const response = try server.handleEnvelope(ping_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .pong);

    // Clean up the response envelope
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

    const client_stream_id = protocol_types.generateUuid();
    var stream_req_env = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    var response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.provider_error, response.?.payload.nack.error_code.?);
    // Verify NACK echoes client's stream_id
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
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
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

    const client_stream_id = protocol_types.generateUuid();
    const msg_id = protocol_types.generateUuid();
    var stream_req_env = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = msg_id,
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    const response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(response != null);
    try std.testing.expect(response.?.payload == .ack);
    try std.testing.expectEqualSlices(u8, &msg_id, &response.?.payload.ack.acknowledged_id);

    // Server should echo client's stream_id, not generate a new one
    try std.testing.expectEqualSlices(u8, &client_stream_id, &response.?.stream_id);

    // Verify stream was created
    try std.testing.expectEqual(@as(usize, 1), server.activeStreamCount());
    const created = server.active_streams.get(client_stream_id).?;
    try std.testing.expect(created.event_stream.wait_for_thread_on_deinit);

    stream_req_env.deinit(std.testing.allocator);
    // ack response doesn't allocate memory, so no need to deinit
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

    const client_stream_id = protocol_types.generateUuid();
    var req1 = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };
    defer req1.deinit(std.testing.allocator);

    const resp1 = try server.handleEnvelope(req1);
    try std.testing.expect(resp1 != null);
    try std.testing.expect(resp1.?.payload == .ack);

    var req2 = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
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

    // First create a stream
    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    const create_response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(create_response != null);
    const stream_id = create_response.?.stream_id;

    stream_req_env.deinit(std.testing.allocator);

    // Now abort the stream
    const abort_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .abort_request = .{
            .target_stream_id = stream_id,
            .reason = protocol_types.OwnedSlice(u8).initBorrowed(""),
        } },
    };

    const abort_response = try server.handleEnvelope(abort_env);
    try std.testing.expect(abort_response != null);
    try std.testing.expect(abort_response.?.payload == .ack);
    try std.testing.expectEqual(@as(u64, 2), abort_response.?.sequence);

    // Verify stream was removed
    try std.testing.expectEqual(@as(usize, 0), server.activeStreamCount());
}

test "handleAbortRequest returns ack for unknown stream (idempotent)" {
    var registry = api_registry.ApiRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var server = ProtocolServer.init(std.testing.allocator, &registry, .{});
    defer server.deinit();

    const unknown_stream_id = protocol_types.generateUuid();

    const abort_env = protocol_types.Envelope{
        .stream_id = unknown_stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .abort_request = .{
            .target_stream_id = unknown_stream_id,
            .reason = protocol_types.OwnedSlice(u8).initBorrowed(""),
        } },
    };

    const response = try server.handleEnvelope(abort_env);
    try std.testing.expect(response != null);
    // Per spec, abort is idempotent - returns ACK even if stream not found
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

    // Create a stream
    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    _ = try server.handleEnvelope(stream_req_env);
    try std.testing.expectEqual(@as(usize, 1), server.activeStreamCount());

    // Mock stream is already complete, so cleanup should remove it
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

    // Create first stream - should succeed
    const client_stream_id_1 = protocol_types.generateUuid();
    var req1 = protocol_types.Envelope{
        .stream_id = client_stream_id_1,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };
    const resp1 = try server.handleEnvelope(req1);
    try std.testing.expect(resp1 != null);
    try std.testing.expect(resp1.?.payload == .ack);
    // Verify server echoes client's stream_id
    try std.testing.expectEqualSlices(u8, &client_stream_id_1, &resp1.?.stream_id);
    req1.deinit(std.testing.allocator);

    // Create second stream - should succeed
    const client_stream_id_2 = protocol_types.generateUuid();
    var req2 = protocol_types.Envelope{
        .stream_id = client_stream_id_2,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1, // Each new stream starts at sequence 1
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };
    const resp2 = try server.handleEnvelope(req2);
    try std.testing.expect(resp2 != null);
    try std.testing.expect(resp2.?.payload == .ack);
    // Verify server echoes client's stream_id
    try std.testing.expectEqualSlices(u8, &client_stream_id_2, &resp2.?.stream_id);
    req2.deinit(std.testing.allocator);

    // Create third stream - should fail with rate_limited
    const client_stream_id_3 = protocol_types.generateUuid();
    var req3 = protocol_types.Envelope{
        .stream_id = client_stream_id_3,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1, // Each new stream starts at sequence 1
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };
    var resp3 = try server.handleEnvelope(req3);
    try std.testing.expect(resp3 != null);
    try std.testing.expect(resp3.?.payload == .nack);
    try std.testing.expectEqual(protocol_types.ErrorCode.rate_limited, resp3.?.payload.nack.error_code.?);
    // Verify NACK also echoes client's stream_id
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

    const client_stream_id = protocol_types.generateUuid();

    // Test with sequence = 0 (invalid)
    const req_seq0 = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 0,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
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

    // Test with sequence = 2 (should be 1 for new stream)
    const req_seq2 = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 2,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
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

    const client_stream_id = protocol_types.generateUuid();

    // Test with sequence = 5 (should be 1 for complete_request)
    const req = protocol_types.Envelope{
        .stream_id = client_stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 5,
        .timestamp = std.time.milliTimestamp(),
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

    // First create a stream with sequence 1
    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    const create_response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(create_response != null);
    const stream_id = create_response.?.stream_id;
    stream_req_env.deinit(std.testing.allocator);

    // Now try to abort with duplicate sequence (should be 2, not 1)
    const abort_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 1, // Duplicate - should be 2
        .timestamp = std.time.milliTimestamp(),
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

    // First create a stream with sequence 1
    var stream_req_env = protocol_types.Envelope{
        .stream_id = protocol_types.generateUuid(),
        .message_id = protocol_types.generateUuid(),
        .sequence = 1,
        .timestamp = std.time.milliTimestamp(),
        .payload = .{ .stream_request = .{
            .model = model,
            .context = .{ .messages = &.{} },
        } },
    };

    const create_response = try server.handleEnvelope(stream_req_env);
    try std.testing.expect(create_response != null);
    const stream_id = create_response.?.stream_id;
    stream_req_env.deinit(std.testing.allocator);

    // Now try to abort with a sequence gap (should be 2, not 10)
    const abort_env = protocol_types.Envelope{
        .stream_id = stream_id,
        .message_id = protocol_types.generateUuid(),
        .sequence = 10, // Gap - expected 2
        .timestamp = std.time.milliTimestamp(),
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
