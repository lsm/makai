const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const api_registry = @import("api_registry");
const oauth_storage = @import("oauth/storage");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");
const tool_call_tracker = @import("tool_call_tracker");
const sanitize = @import("sanitize");
const retry_util = @import("retry");
const pre_transform = @import("pre_transform");
const StringBuilder = @import("string_builder").StringBuilder;

fn anthropicRefresh(credentials: oauth_storage.Credentials, allocator: std.mem.Allocator) anyerror!oauth_storage.Credentials {
    const oauth = @import("oauth/anthropic");
    const refreshed = try oauth.refreshToken(.{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
    }, allocator);
    return .{
        .refresh = refreshed.refresh,
        .access = refreshed.access,
        .expires = refreshed.expires,
        .provider_data = null,
    };
}

fn anthropicGetApiKey(credentials: oauth_storage.Credentials, allocator: std.mem.Allocator) anyerror![]const u8 {
    const oauth = @import("oauth/anthropic");
    return oauth.getApiKey(.{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
    }, allocator);
}

fn anthropicIsAuthFailure(err_msg: []const u8) bool {
    return std.mem.find(u8, err_msg, "401") != null or
        std.mem.find(u8, err_msg, "403") != null or
        std.ascii.indexOfIgnoreCase(err_msg, "unauthorized") != null or
        std.ascii.indexOfIgnoreCase(err_msg, "forbidden") != null or
        std.ascii.indexOfIgnoreCase(err_msg, "authentication_error") != null or
        std.ascii.indexOfIgnoreCase(err_msg, "permission_error") != null or
        std.ascii.indexOfIgnoreCase(err_msg, "invalid api key") != null;
}

fn envApiKey(allocator: std.mem.Allocator) ?[]const u8 {
    // Support both OAuth tokens (sk-ant-oat) and API keys (sk-ant-api)
    // Check ANTHROPIC_AUTH_TOKEN first (OAuth), then ANTHROPIC_API_KEY
    if (compat.getEnvVarOwned(allocator, "ANTHROPIC_AUTH_TOKEN")) |key| return key else |_| {}
    if (compat.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY")) |key| return key else |_| {}
    return null;
}

fn isOAuthToken(key: []const u8) bool {
    return std.mem.find(u8, key, "sk-ant-oat") != null;
}

fn buildUrlWithSuffix(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8) ![]const u8 {
    var sb = StringBuilder{};
    sb.count(base_url);
    sb.count(suffix);
    try sb.allocate(allocator);
    errdefer sb.deinit(allocator);

    _ = sb.append(base_url);
    _ = sb.append(suffix);

    std.debug.assert(sb.len == sb.cap);
    const out = sb.ptr.?[0..sb.cap];
    sb.ptr = null;
    sb.cap = 0;
    sb.len = 0;
    return out;
}

fn buildBearerAuthValue(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var sb = StringBuilder{};
    sb.count("Bearer ");
    sb.count(token);
    try sb.allocate(allocator);
    errdefer sb.deinit(allocator);

    _ = sb.append("Bearer ");
    _ = sb.append(token);

    std.debug.assert(sb.len == sb.cap);
    const out = sb.ptr.?[0..sb.cap];
    sb.ptr = null;
    sb.cap = 0;
    sb.len = 0;
    return out;
}

/// Result of cache control resolution
const CacheControlResult = struct {
    retention: ai_types.CacheRetention,
    /// If non-null, contains the cache_control object to add
    has_ttl: bool,
};

/// Resolve cache retention and determine cache_control settings
fn getCacheControl(base_url: []const u8, cache_retention: ?ai_types.CacheRetention) ?CacheControlResult {
    const retention = cache_retention orelse .short;
    if (retention == .none) return null;

    // Only add ttl for "long" retention on api.anthropic.com
    const has_ttl = retention == .long and std.mem.find(u8, base_url, "api.anthropic.com") != null;

    return .{
        .retention = retention,
        .has_ttl = has_ttl,
    };
}

/// Check if a model supports adaptive thinking (Opus 4.6+)
fn supportsAdaptiveThinking(model_id: []const u8) bool {
    return std.mem.find(u8, model_id, "opus-4-6") != null or
        std.mem.find(u8, model_id, "opus-4.6") != null;
}

/// Map ThinkingLevel to Anthropic effort levels for adaptive thinking
fn mapThinkingLevelToEffort(level: ai_types.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "low", // off maps to lowest effort
        .minimal => "low",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "max",
    };
}

/// Get default thinking budget tokens for a thinking level (older models)
fn getDefaultThinkingBudget(level: ai_types.ThinkingLevel, budgets: ?ai_types.ThinkingBudgets) u32 {
    if (budgets) |b| {
        return switch (level) {
            .off => 0, // off means no thinking budget
            .minimal => b.minimal orelse 256,
            .low => b.low orelse 512,
            .medium => b.medium orelse 1024,
            .high => b.high orelse 2048,
            .xhigh => b.xhigh orelse 4096,
        };
    }
    return switch (level) {
        .off => 0,
        .minimal => 256,
        .low => 512,
        .medium => 1024,
        .high => 2048,
        .xhigh => 4096,
    };
}

fn appendMessageText(msg: ai_types.Message, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (msg) {
        .user => |u| switch (u.content) {
            .text => |t| try out.appendSlice(allocator, t),
            .parts => |parts| for (parts) |p| switch (p) {
                .text => |t| {
                    if (out.items.len > 0) try out.append(allocator, '\n');
                    try out.appendSlice(allocator, t.text);
                },
                .image => {},
            },
        },
        .assistant => |a| for (a.content) |c| switch (c) {
            .text => |t| {
                if (out.items.len > 0) try out.append(allocator, '\n');
                try out.appendSlice(allocator, t.text);
            },
            .thinking => |t| {
                if (out.items.len > 0) try out.append(allocator, '\n');
                try out.appendSlice(allocator, t.thinking);
            },
            .tool_call => {},
        },
        .tool_result => |tr| for (tr.content) |c| switch (c) {
            .text => |t| {
                if (out.items.len > 0) try out.append(allocator, '\n');
                try out.appendSlice(allocator, t.text);
            },
            .image => {},
        },
    }
}

/// Check if an assistant message contains tool_use blocks
fn hasToolUse(msg: ai_types.Message) bool {
    switch (msg) {
        .assistant => |a| {
            for (a.content) |c| {
                if (c == .tool_call) return true;
            }
        },
        else => {},
    }
    return false;
}

/// Check if an assistant message should be skipped (aborted or error)
fn shouldSkipAssistant(msg: ai_types.Message) bool {
    switch (msg) {
        .assistant => |a| {
            return a.stop_reason == .aborted or a.stop_reason == .@"error";
        },
        else => {},
    }
    return false;
}

/// Collect all tool call IDs from assistant messages into a hash set
fn collectToolCallIds(allocator: std.mem.Allocator, messages: []const ai_types.Message) !std.StringHashMap(void) {
    var tool_call_ids = std.StringHashMap(void).init(allocator);
    errdefer {
        var iter = tool_call_ids.keyIterator();
        while (iter.next()) |key| {
            allocator.free(key.*);
        }
        tool_call_ids.deinit();
    }

    for (messages) |msg| {
        switch (msg) {
            .assistant => |a| {
                for (a.content) |c| {
                    if (c == .tool_call) {
                        const id_dup = try allocator.dupe(u8, c.tool_call.id);
                        try tool_call_ids.put(id_dup, {});
                    }
                }
            },
            else => {},
        }
    }

    return tool_call_ids;
}

/// Check if a tool result is orphaned (no matching tool call)
/// Only returns true if there ARE tool calls in the context but none match this result
fn isOrphanedToolResult(msg: ai_types.Message, tool_call_ids: *const std.StringHashMap(void)) bool {
    // If there are no tool calls at all, don't filter - results might be from prior context
    if (tool_call_ids.count() == 0) {
        return false;
    }
    switch (msg) {
        .tool_result => |tr| {
            if (tr.tool_call_id.len > 0) {
                return !tool_call_ids.contains(tr.tool_call_id);
            }
        },
        else => {},
    }
    return false;
}

/// Free a StringHashMap's keys
fn freeToolCallIds(allocator: std.mem.Allocator, map: *std.StringHashMap(void)) void {
    var iter = map.keyIterator();
    while (iter.next()) |key| {
        allocator.free(key.*);
    }
    map.deinit();
}

fn buildRequestBody(model: ai_types.Model, context: ai_types.Context, options: ai_types.StreamOptions, allocator: std.mem.Allocator, is_oauth: bool) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    // Pre-transform messages: cross-model thinking conversion, tool ID normalization,
    // synthetic tool results for orphaned calls, aborted message filtering
    var transformed = try pre_transform.preTransform(allocator, context.messages, .{
        .target_api = model.api,
        .target_provider = model.provider,
        .target_model_id = model.id,
        .max_tool_id_len = 64, // Anthropic max tool ID length
        .insert_synthetic_results = true,
        .tools = context.tools,
        .is_oauth = is_oauth,
    });
    defer transformed.deinit();

    // Use transformed messages
    var tx_context = context;
    tx_context.messages = transformed.messages;

    // Resolve cache control settings
    const cache_control = getCacheControl(model.base_url, options.cache_retention);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try w.writeStringField("model", model.id);
    const default_max = @min(model.max_tokens / 3, 32000);
    try w.writeIntField("max_tokens", options.max_tokens orelse default_max);
    try w.writeBoolField("stream", true);

    if (options.temperature) |t| {
        try w.writeKey("temperature");
        try w.writeFloat(t);
    }

    // System prompt as array of content blocks with cache_control
    // For OAuth, prepend Claude Code identity to system prompt
    if (context.getSystemPrompt()) |sp| {
        try w.writeKey("system");
        try w.beginArray();

        try w.beginObject();
        try w.writeStringField("type", "text");
        if (is_oauth) {
            // Prepend Claude Code identity for OAuth
            const full_prompt = try std.fmt.allocPrint(allocator, "You are Claude Code, Anthropic's official CLI for Claude.\n\n{s}", .{sp});
            defer allocator.free(full_prompt);
            // Sanitize system prompt
            const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, full_prompt);
            defer {
                if (sanitized.ptr != full_prompt.ptr) {
                    allocator.free(@constCast(sanitized));
                }
            }
            try w.writeStringField("text", sanitized);
        } else {
            // Sanitize system prompt
            const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, sp);
            defer {
                if (sanitized.ptr != sp.ptr) {
                    allocator.free(@constCast(sanitized));
                }
            }
            try w.writeStringField("text", sanitized);
        }
        if (cache_control) |cc| {
            try w.writeKey("cache_control");
            try w.beginObject();
            try w.writeStringField("type", "ephemeral");
            if (cc.has_ttl) {
                try w.writeStringField("ttl", "1h");
            }
            try w.endObject();
        }
        try w.endObject();

        try w.endArray();
    } else if (is_oauth) {
        // OAuth requires at least the identity even without custom system prompt
        try w.writeKey("system");
        try w.beginArray();
        try w.beginObject();
        try w.writeStringField("type", "text");
        try w.writeStringField("text", "You are Claude Code, Anthropic's official CLI for Claude.");
        if (cache_control) |cc| {
            try w.writeKey("cache_control");
            try w.beginObject();
            try w.writeStringField("type", "ephemeral");
            if (cc.has_ttl) {
                try w.writeStringField("ttl", "1h");
            }
            try w.endObject();
        }
        try w.endObject();
        try w.endArray();
    }

    // Collect tool call IDs from transformed messages for any remaining filtering
    var tool_call_ids = collectToolCallIds(allocator, tx_context.messages) catch std.StringHashMap(void).init(allocator);
    defer freeToolCallIds(allocator, &tool_call_ids);

    // Find the last user message index for cache_control placement
    var last_user_idx: ?usize = null;
    for (tx_context.messages, 0..) |m, i| {
        switch (m) {
            .user => last_user_idx = i,
            else => {},
        }
    }

    try w.writeKey("messages");
    try w.beginArray();
    var msg_idx: usize = 0;
    while (msg_idx < tx_context.messages.len) {
        const m = tx_context.messages[msg_idx];

        // Skip aborted/error assistant messages
        if (shouldSkipAssistant(m)) {
            msg_idx += 1;
            continue;
        }

        // Skip orphaned tool results (no matching tool call)
        if (isOrphanedToolResult(m, &tool_call_ids)) {
            msg_idx += 1;
            continue;
        }

        const is_last_user = last_user_idx != null and msg_idx == last_user_idx.?;

        // Group consecutive tool_result messages into a single user message
        if (m == .tool_result) {
            try w.beginObject();
            try w.writeStringField("role", "user");
            try w.writeKey("content");
            try w.beginArray();

            // Collect ALL consecutive tool_results
            while (msg_idx < tx_context.messages.len and tx_context.messages[msg_idx] == .tool_result) {
                const tr = tx_context.messages[msg_idx].tool_result;

                try w.beginObject();
                try w.writeStringField("type", "tool_result");
                try w.writeStringField("tool_use_id", tr.tool_call_id);

                // Serialize content - can be text, images, or array of content blocks
                if (tr.content.len == 1 and tr.content[0] == .text) {
                    // Single text: serialize as string for simplicity
                    // Sanitize text to remove unpaired surrogates
                    const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, tr.content[0].text.text);
                    defer {
                        // Only free if a new allocation was made
                        if (sanitized.ptr != tr.content[0].text.text.ptr) {
                            allocator.free(@constCast(sanitized));
                        }
                    }
                    try w.writeStringField("content", sanitized);
                } else if (tr.content.len > 1 or (tr.content.len > 0 and tr.content[0] == .image)) {
                    // Multiple parts or image: serialize as array
                    try w.writeKey("content");
                    try w.beginArray();
                    for (tr.content) |c| {
                        switch (c) {
                            .text => |t| {
                                try w.beginObject();
                                try w.writeStringField("type", "text");
                                // Sanitize text to remove unpaired surrogates
                                const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.text);
                                defer {
                                    if (sanitized.ptr != t.text.ptr) {
                                        allocator.free(@constCast(sanitized));
                                    }
                                }
                                try w.writeStringField("text", sanitized);
                                try w.endObject();
                            },
                            .image => |img| {
                                try w.beginObject();
                                try w.writeStringField("type", "image");
                                try w.writeKey("source");
                                try w.beginObject();
                                try w.writeStringField("type", "base64");
                                try w.writeStringField("media_type", img.mime_type);
                                try w.writeStringField("data", img.data);
                                try w.endObject();
                                try w.endObject();
                            },
                        }
                    }
                    try w.endArray();
                } else {
                    // Empty content
                    try w.writeStringField("content", "");
                }

                try w.writeBoolField("is_error", tr.is_error);
                try w.endObject();

                msg_idx += 1;
            }

            try w.endArray();
            try w.endObject();
            continue; // Already incremented msg_idx
        }

        const role: []const u8 = switch (m) {
            .assistant => "assistant",
            else => "user",
        };

        // Handle assistant messages with tool_use blocks specially
        if (m == .assistant and hasToolUse(m)) {
            try w.beginObject();
            try w.writeStringField("role", role);
            try w.writeKey("content");
            try w.beginArray();

            // Serialize each content block
            for (m.assistant.content) |c| {
                switch (c) {
                    .text => |t| {
                        try w.beginObject();
                        try w.writeStringField("type", "text");
                        // Sanitize text to remove unpaired surrogates
                        const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.text);
                        defer {
                            if (sanitized.ptr != t.text.ptr) {
                                allocator.free(@constCast(sanitized));
                            }
                        }
                        try w.writeStringField("text", sanitized);
                        try w.endObject();
                    },
                    .thinking => |t| {
                        // If signature is missing (aborted stream), convert to text
                        if (t.thinking_signature == null or t.thinking_signature.?.len == 0) {
                            try w.beginObject();
                            try w.writeStringField("type", "text");
                            // Sanitize thinking text
                            const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.thinking);
                            defer {
                                if (sanitized.ptr != t.thinking.ptr) {
                                    allocator.free(@constCast(sanitized));
                                }
                            }
                            try w.writeStringField("text", sanitized);
                            try w.endObject();
                        } else {
                            try w.beginObject();
                            try w.writeStringField("type", "thinking");
                            // Sanitize thinking text
                            const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.thinking);
                            defer {
                                if (sanitized.ptr != t.thinking.ptr) {
                                    allocator.free(@constCast(sanitized));
                                }
                            }
                            try w.writeStringField("thinking", sanitized);
                            try w.writeStringField("signature", t.thinking_signature.?);
                            try w.endObject();
                        }
                    },
                    .tool_call => |tc| {
                        try w.beginObject();
                        try w.writeStringField("type", "tool_use");
                        try w.writeStringField("id", tc.id);
                        try w.writeStringField("name", tc.name);
                        try w.writeKey("input");
                        try w.writeRawJson(tc.arguments_json);
                        try w.endObject();
                    },
                    .image => |img| {
                        try w.beginObject();
                        try w.writeStringField("type", "image");
                        try w.writeKey("source");
                        try w.beginObject();
                        try w.writeStringField("type", "base64");
                        try w.writeStringField("media_type", img.mime_type);
                        try w.writeStringField("data", img.data);
                        try w.endObject();
                        try w.endObject();
                    },
                }
            }

            try w.endArray();
            try w.endObject();
        } else if (is_last_user and cache_control != null) {
            // For the last user message with cache_control, use content array format
            try w.beginObject();
            try w.writeStringField("role", role);
            try w.writeKey("content");
            try w.beginArray();

            // Serialize user message content (text and images)
            switch (m.user.content) {
                .text => |t| {
                    // Text block with cache_control
                    try w.beginObject();
                    try w.writeStringField("type", "text");
                    // Sanitize text to remove unpaired surrogates
                    const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t);
                    defer {
                        if (sanitized.ptr != t.ptr) {
                            allocator.free(@constCast(sanitized));
                        }
                    }
                    try w.writeStringField("text", sanitized);
                    try w.writeKey("cache_control");
                    try w.beginObject();
                    try w.writeStringField("type", "ephemeral");
                    if (cache_control.?.has_ttl) {
                        try w.writeStringField("ttl", "1h");
                    }
                    try w.endObject();
                    try w.endObject();
                },
                .parts => |parts| {
                    for (parts, 0..) |p, i| {
                        switch (p) {
                            .text => |t| {
                                try w.beginObject();
                                try w.writeStringField("type", "text");
                                // Sanitize text to remove unpaired surrogates
                                const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.text);
                                defer {
                                    if (sanitized.ptr != t.text.ptr) {
                                        allocator.free(@constCast(sanitized));
                                    }
                                }
                                try w.writeStringField("text", sanitized);
                                // Add cache_control only to the last block
                                if (i == parts.len - 1) {
                                    try w.writeKey("cache_control");
                                    try w.beginObject();
                                    try w.writeStringField("type", "ephemeral");
                                    if (cache_control.?.has_ttl) {
                                        try w.writeStringField("ttl", "1h");
                                    }
                                    try w.endObject();
                                }
                                try w.endObject();
                            },
                            .image => |img| {
                                try w.beginObject();
                                try w.writeStringField("type", "image");
                                try w.writeKey("source");
                                try w.beginObject();
                                try w.writeStringField("type", "base64");
                                try w.writeStringField("media_type", img.mime_type);
                                try w.writeStringField("data", img.data);
                                try w.endObject();
                                try w.endObject();
                            },
                        }
                    }
                },
            }

            try w.endArray();
            try w.endObject();
        } else {
            // Standard message serialization with image support
            switch (m) {
                .user => |u| {
                    try w.beginObject();
                    try w.writeStringField("role", role);

                    switch (u.content) {
                        .text => |t| {
                            // Sanitize text to remove unpaired surrogates
                            const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t);
                            defer {
                                if (sanitized.ptr != t.ptr) {
                                    allocator.free(@constCast(sanitized));
                                }
                            }
                            try w.writeStringField("content", sanitized);
                        },
                        .parts => |parts| {
                            try w.writeKey("content");
                            try w.beginArray();
                            for (parts) |p| {
                                switch (p) {
                                    .text => |t| {
                                        try w.beginObject();
                                        try w.writeStringField("type", "text");
                                        // Sanitize text to remove unpaired surrogates
                                        const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.text);
                                        defer {
                                            if (sanitized.ptr != t.text.ptr) {
                                                allocator.free(@constCast(sanitized));
                                            }
                                        }
                                        try w.writeStringField("text", sanitized);
                                        try w.endObject();
                                    },
                                    .image => |img| {
                                        try w.beginObject();
                                        try w.writeStringField("type", "image");
                                        try w.writeKey("source");
                                        try w.beginObject();
                                        try w.writeStringField("type", "base64");
                                        try w.writeStringField("media_type", img.mime_type);
                                        try w.writeStringField("data", img.data);
                                        try w.endObject();
                                    },
                                }
                            }
                            try w.endArray();
                        },
                    }

                    try w.endObject();
                },
                .assistant => |a| {
                    try w.beginObject();
                    try w.writeStringField("role", role);

                    // Serialize assistant content blocks
                    try w.writeKey("content");
                    try w.beginArray();
                    for (a.content) |c| {
                        switch (c) {
                            .text => |t| {
                                try w.beginObject();
                                try w.writeStringField("type", "text");
                                // Sanitize text to remove unpaired surrogates
                                const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.text);
                                defer {
                                    if (sanitized.ptr != t.text.ptr) {
                                        allocator.free(@constCast(sanitized));
                                    }
                                }
                                try w.writeStringField("text", sanitized);
                                try w.endObject();
                            },
                            .thinking => |t| {
                                // If signature is missing (aborted stream), convert to text
                                if (t.thinking_signature == null or t.thinking_signature.?.len == 0) {
                                    try w.beginObject();
                                    try w.writeStringField("type", "text");
                                    // Sanitize thinking text
                                    const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.thinking);
                                    defer {
                                        if (sanitized.ptr != t.thinking.ptr) {
                                            allocator.free(@constCast(sanitized));
                                        }
                                    }
                                    try w.writeStringField("text", sanitized);
                                    try w.endObject();
                                } else {
                                    try w.beginObject();
                                    try w.writeStringField("type", "thinking");
                                    // Sanitize thinking text
                                    const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.thinking);
                                    defer {
                                        if (sanitized.ptr != t.thinking.ptr) {
                                            allocator.free(@constCast(sanitized));
                                        }
                                    }
                                    try w.writeStringField("thinking", sanitized);
                                    try w.writeStringField("signature", t.thinking_signature.?);
                                    try w.endObject();
                                }
                            },
                            .tool_call => {},
                            .image => {},
                        }
                    }
                    try w.endArray();

                    try w.endObject();
                },
                .tool_result => unreachable, // Handled above
            }
        }

        msg_idx += 1;
    }
    try w.endArray();

    // Serialize tools if present
    if (context.tools) |tools| {
        if (tools.len > 0) {
            try w.writeKey("tools");
            try w.beginArray();
            for (tools) |tool| {
                try w.beginObject();
                try w.writeStringField("name", tool.name);
                try w.writeStringField("description", tool.description);
                try w.writeKey("input_schema");
                try w.writeRawJson(tool.parameters_schema_json);
                try w.endObject();
            }
            try w.endArray();
        }
    }

    // Serialize tool_choice if present
    if (options.tool_choice) |tc| {
        try w.writeKey("tool_choice");
        switch (tc) {
            .auto => {
                try w.beginObject();
                try w.writeStringField("type", "auto");
                try w.endObject();
            },
            .none => {
                try w.beginObject();
                try w.writeStringField("type", "none");
                try w.endObject();
            },
            .required => {
                try w.beginObject();
                try w.writeStringField("type", "any");
                try w.endObject();
            },
            .function => |name| {
                try w.beginObject();
                try w.writeStringField("type", "tool");
                try w.writeKey("name");
                try w.writeString(name);
                try w.endObject();
            },
        }
    }

    // Serialize metadata.user_id if present
    if (options.metadata) |meta| {
        if (meta.getUserId()) |user_id| {
            try w.writeKey("metadata");
            try w.beginObject();
            try w.writeStringField("user_id", user_id);
            try w.endObject();
        }
    }

    // Configure thinking mode: adaptive (Opus 4.6+) or budget-based (older models)
    if (options.thinking_enabled) {
        if (supportsAdaptiveThinking(model.id)) {
            // Adaptive thinking: Claude decides when and how much to think
            try w.writeKey("thinking");
            try w.beginObject();
            try w.writeStringField("type", "adaptive");
            try w.endObject();

            if (options.getThinkingEffort()) |effort| {
                try w.writeKey("output_config");
                try w.beginObject();
                try w.writeStringField("effort", effort);
                try w.endObject();
            }
        } else {
            // Budget-based thinking for older models
            try w.writeKey("thinking");
            try w.beginObject();
            try w.writeStringField("type", "enabled");
            try w.writeIntField("budget_tokens", options.thinking_budget_tokens orelse 1024);
            try w.endObject();
        }
    }

    try w.endObject();
    return buf.toOwnedSlice(allocator);
}

/// Result type for parsing an Anthropic SSE event
const ParseResult = union(enum) {
    none: void,
    message_start: struct { input_tokens: u64, output_tokens: u64, cache_read: u64, cache_write: u64 },
    content_block_start: struct {
        index: usize,
        block_type: ContentType,
        tool_id: []const u8 = "", // Only for tool_use
        tool_name: []const u8 = "", // Only for tool_use
    },
    content_block_delta: struct { index: usize, delta: ContentDelta },
    content_block_stop: struct { index: usize },
    message_delta: struct { stop_reason: ai_types.StopReason, output_tokens: u64 },
    message_stop: void,
    api_error: []const u8,

    const ContentType = enum { text, thinking, tool_use };
    const ContentDelta = union(enum) {
        text: []const u8,
        thinking: []const u8,
        signature: []const u8,
        input_json: []const u8,
    };
};

fn parseAnthropicEventType(data: []const u8, allocator: std.mem.Allocator) !ParseResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return .{ .none = {} };
    defer parsed.deinit();

    if (parsed.value != .object) return .{ .none = {} };
    const obj = parsed.value.object;

    const type_val = obj.get("type") orelse return .{ .none = {} };
    if (type_val != .string) return .{ .none = {} };

    if (std.mem.eql(u8, type_val.string, "message_start")) {
        const msg_val = obj.get("message") orelse return .{ .none = {} };
        if (msg_val != .object) return .{ .none = {} };
        const usage_val = msg_val.object.get("usage") orelse return .{ .none = {} };
        if (usage_val != .object) return .{ .none = {} };

        var input_tokens: u64 = 0;
        var output_tokens: u64 = 0;
        var cache_read: u64 = 0;
        var cache_write: u64 = 0;

        if (usage_val.object.get("input_tokens")) |v| {
            if (v == .integer) input_tokens = @intCast(v.integer);
        }
        if (usage_val.object.get("output_tokens")) |v| {
            if (v == .integer) output_tokens = @intCast(v.integer);
        }
        if (usage_val.object.get("cache_read_input_tokens")) |v| {
            if (v == .integer) cache_read = @intCast(v.integer);
        }
        if (usage_val.object.get("cache_creation_input_tokens")) |v| {
            if (v == .integer) cache_write = @intCast(v.integer);
        }

        return .{ .message_start = .{
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cache_read = cache_read,
            .cache_write = cache_write,
        } };
    }

    if (std.mem.eql(u8, type_val.string, "content_block_start")) {
        const index_val = obj.get("index") orelse return .{ .none = {} };
        if (index_val != .integer) return .{ .none = {} };
        const index: usize = @intCast(index_val.integer);

        const content_block = obj.get("content_block") orelse return .{ .none = {} };
        if (content_block != .object) return .{ .none = {} };
        const cb_type = content_block.object.get("type") orelse return .{ .none = {} };
        if (cb_type != .string) return .{ .none = {} };

        const block_type: ParseResult.ContentType = if (std.mem.eql(u8, cb_type.string, "text"))
            .text
        else if (std.mem.eql(u8, cb_type.string, "thinking"))
            .thinking
        else if (std.mem.eql(u8, cb_type.string, "tool_use"))
            .tool_use
        else
            return .{ .none = {} };

        // For tool_use, extract id and name
        if (block_type == .tool_use) {
            var tool_id: []const u8 = "";
            var tool_name: []const u8 = "";
            if (content_block.object.get("id")) |id_val| {
                if (id_val == .string) tool_id = id_val.string;
            }
            if (content_block.object.get("name")) |name_val| {
                if (name_val == .string) tool_name = name_val.string;
            }
            // Dupe the strings since they come from temporary JSON parse buffer
            const duped_id = try allocator.dupe(u8, tool_id);
            errdefer allocator.free(duped_id);
            const duped_name = try allocator.dupe(u8, tool_name);
            return .{ .content_block_start = .{ .index = index, .block_type = block_type, .tool_id = duped_id, .tool_name = duped_name } };
        }

        return .{ .content_block_start = .{ .index = index, .block_type = block_type } };
    }

    if (std.mem.eql(u8, type_val.string, "content_block_delta")) {
        const index_val = obj.get("index") orelse return .{ .none = {} };
        if (index_val != .integer) return .{ .none = {} };
        const index: usize = @intCast(index_val.integer);

        const delta_val = obj.get("delta") orelse return .{ .none = {} };
        if (delta_val != .object) return .{ .none = {} };

        const delta_type = delta_val.object.get("type") orelse return .{ .none = {} };
        if (delta_type != .string) return .{ .none = {} };

        if (std.mem.eql(u8, delta_type.string, "text_delta")) {
            if (delta_val.object.get("text")) |v| {
                if (v == .string) {
                    const duped = try allocator.dupe(u8, v.string);
                    return .{ .content_block_delta = .{ .index = index, .delta = .{ .text = duped } } };
                }
            }
        } else if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
            if (delta_val.object.get("thinking")) |v| {
                if (v == .string) {
                    const duped = try allocator.dupe(u8, v.string);
                    return .{ .content_block_delta = .{ .index = index, .delta = .{ .thinking = duped } } };
                }
            }
        } else if (std.mem.eql(u8, delta_type.string, "signature_delta")) {
            if (delta_val.object.get("signature")) |v| {
                if (v == .string) {
                    const duped = try allocator.dupe(u8, v.string);
                    return .{ .content_block_delta = .{ .index = index, .delta = .{ .signature = duped } } };
                }
            }
        } else if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
            if (delta_val.object.get("partial_json")) |v| {
                if (v == .string) {
                    const duped = try allocator.dupe(u8, v.string);
                    return .{ .content_block_delta = .{ .index = index, .delta = .{ .input_json = duped } } };
                }
            }
        }

        return .{ .none = {} };
    }

    if (std.mem.eql(u8, type_val.string, "content_block_stop")) {
        const index_val = obj.get("index") orelse return .{ .none = {} };
        if (index_val != .integer) return .{ .none = {} };
        const index: usize = @intCast(index_val.integer);
        return .{ .content_block_stop = .{ .index = index } };
    }

    if (std.mem.eql(u8, type_val.string, "message_delta")) {
        var stop_reason: ai_types.StopReason = .stop;
        var output_tokens: u64 = 0;

        if (obj.get("delta")) |delta_val| {
            if (delta_val == .object) {
                if (delta_val.object.get("stop_reason")) |sr| {
                    if (sr == .string) {
                        if (std.mem.eql(u8, sr.string, "max_tokens")) stop_reason = .length else if (std.mem.eql(u8, sr.string, "tool_use")) stop_reason = .tool_use else stop_reason = .stop;
                    }
                }
            }
        }

        if (obj.get("usage")) |usage_val| {
            if (usage_val == .object) {
                if (usage_val.object.get("output_tokens")) |v| {
                    if (v == .integer) output_tokens = @intCast(v.integer);
                }
            }
        }

        return .{ .message_delta = .{ .stop_reason = stop_reason, .output_tokens = output_tokens } };
    }

    if (std.mem.eql(u8, type_val.string, "message_stop")) {
        return .{ .message_stop = {} };
    }

    if (std.mem.eql(u8, type_val.string, "error")) {
        var err_msg: []const u8 = "anthropic api error";
        if (obj.get("error")) |ev| {
            if (ev == .object) {
                if (ev.object.get("message")) |m| {
                    if (m == .string) err_msg = m.string;
                }
            }
        }
        return .{ .api_error = try allocator.dupe(u8, err_msg) };
    }

    return .{ .none = {} };
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *event_stream.AssistantMessageEventStream,
    model: ai_types.Model,
    context: ai_types.Context,
    api_key: []u8,
    request_body: []u8,
    cancel_token: ?ai_types.CancelToken = null,
    on_payload_fn: ?*const fn (ctx: ?*anyopaque, payload_json: []const u8) void = null,
    on_payload_ctx: ?*anyopaque = null,
    retry: ?ai_types.RetryConfig = null,
    ping_interval_ms: ?u64 = null,

    /// Clean up all owned resources (model, context, api_key, request_body, self).
    fn deinit(self: *ThreadCtx) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.request_body);
        var mut_context = self.context;
        mut_context.deinit(self.allocator);
        var mut_model = self.model;
        mut_model.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const TestCancelStage = enum {
    connect_setup,
    response_headers,
    between_sse_events,
    mid_event_payload,
};

var test_cancel_stage: ?TestCancelStage = null;

fn testCancelAt(cancel_token: ?ai_types.CancelToken, stage: TestCancelStage) bool {
    if (!@import("builtin").is_test) return false;
    if (test_cancel_stage != stage) return false;
    const ct = cancel_token orelse return false;
    ct.cancelled.store(true, .release);
    return ct.isCancelled();
}

const AnthropicHeaderSet = struct {
    headers: std.ArrayList(std.http.Header),
    auth_header: ?[]u8 = null,

    pub fn deinit(self: *AnthropicHeaderSet, allocator: std.mem.Allocator) void {
        if (self.auth_header) |h| allocator.free(h);
        self.headers.deinit(allocator);
        self.* = undefined;
    }
};

fn buildAnthropicHeaders(allocator: std.mem.Allocator, api_key: []const u8) !AnthropicHeaderSet {
    var out = AnthropicHeaderSet{ .headers = .empty };
    errdefer out.deinit(allocator);

    const is_oauth = isOAuthToken(api_key);

    // OAuth tokens use Authorization: Bearer, API keys use x-api-key
    if (is_oauth) {
        out.auth_header = try buildBearerAuthValue(allocator, api_key);
        try out.headers.append(allocator, .{ .name = "authorization", .value = out.auth_header.? });
        // OAuth-specific headers (mimic Claude Code)
        try out.headers.append(allocator, .{ .name = "anthropic-beta", .value = "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14" });
        try out.headers.append(allocator, .{ .name = "anthropic-dangerous-direct-browser-access", .value = "true" });
        try out.headers.append(allocator, .{ .name = "user-agent", .value = "claude-cli/2.1.2 (external, cli)" });
        try out.headers.append(allocator, .{ .name = "x-app", .value = "cli" });
    } else {
        try out.headers.append(allocator, .{ .name = "x-api-key", .value = api_key });
        // Add beta headers for fine-grained tool streaming and interleaved thinking
        try out.headers.append(allocator, .{ .name = "anthropic-beta", .value = "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14" });
    }

    try out.headers.append(allocator, .{ .name = "anthropic-version", .value = "2023-06-01" });
    try out.headers.append(allocator, .{ .name = "content-type", .value = "application/json" });

    return out;
}


fn runThread(ctx: *ThreadCtx) void {
    // Save values from ctx that we need after freeing ctx
    const allocator = ctx.allocator;
    const stream = ctx.stream;
    const model = ctx.model;
    const api_key = ctx.api_key;
    const request_body = ctx.request_body;
    const cancel_token = ctx.cancel_token;
    const on_payload_fn = ctx.on_payload_fn;
    const on_payload_ctx = ctx.on_payload_ctx;
    const retry_options = ctx.retry;

    // Invoke on_payload callback before sending
    if (on_payload_fn) |cb| {
        cb(on_payload_ctx, request_body);
    }

    // Check cancellation before sending
    if (cancel_token) |ct| {
        if (ct.isCancelled()) {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("request cancelled");
            return;
        }
    }

    var http_client = compat.http.HttpClient.init(allocator);
    defer http_client.deinit();

    const url = buildUrlWithSuffix(allocator, model.base_url, "/v1/messages") catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("oom building url");
        return;
    };
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("invalid anthropic URL");
        return;
    };

    var header_set = buildAnthropicHeaders(allocator, api_key) catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("oom headers");
        return;
    };
    defer header_set.deinit(allocator);
    const headers = header_set.headers.items;

    // Retry configuration
    const MAX_RETRIES: u8 = 3;
    const BASE_DELAY_MS: u32 = 1000;
    const max_delay_ms: u32 = if (retry_options) |ro| ro.max_retry_delay_ms orelse 60000 else 60000;

    var response: compat.http.Response = undefined;
    var head_buf: [4096]u8 = undefined;
    var retry_attempt: u8 = 0;
    var last_error: ?[]u8 = null;
    defer if (last_error) |e| allocator.free(e);
    var req: compat.http.Request = undefined;
    var req_initialized = false;
    defer if (req_initialized) req.deinit();

    while (true) {
        // Check cancellation before each attempt
        if (cancel_token) |ct| {
            if (ct.isCancelled()) {
                ctx.deinit();
                stream.markThreadDone();
                stream.completeWithError("request cancelled");
                return;
            }
        }

        // Deinit previous request if this is a retry
        if (req_initialized) {
            req.deinit();
            req_initialized = false;
        }

        if (testCancelAt(cancel_token, .connect_setup)) {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("request cancelled");
            return;
        }

        // SSE streams must not be gzip-compressed — gzip buffers the entire
        // stream before delivery, breaking real-time event delivery.
        // Use .headers.accept_encoding = .{ .override = "identity" } to
        // replace the Zig HTTP client's built-in "accept-encoding: gzip, deflate"
        // with "accept-encoding: identity" (no compression).
        req = http_client.openRequest(.POST, uri, .{
            .extra_headers = headers,
            .accept_encoding = "identity",
        }) catch {
            // Network error - check if we should retry
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                    retry_attempt += 1;
                    continue;
                }
                // Sleep was cancelled
                ctx.deinit();
                stream.markThreadDone();
                stream.completeWithError("request cancelled");
                return;
            }
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("request open failed");
            return;
        };
        req_initialized = true;

        compat.http.sendRequest(&req, request_body) catch {
            // Network error - check if we should retry
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                    retry_attempt += 1;
                    continue;
                }
                // Sleep was cancelled
                ctx.deinit();
                stream.markThreadDone();
                stream.completeWithError("request cancelled");
                return;
            }
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("request send failed");
            return;
        };

        if (testCancelAt(cancel_token, .response_headers)) {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("request cancelled");
            return;
        }

        response = compat.http.receiveResponse(&req, &head_buf) catch {
            // Network error - check if we should retry
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                    retry_attempt += 1;
                    continue;
                }
                // Sleep was cancelled
                ctx.deinit();
                stream.markThreadDone();
                stream.completeWithError("request cancelled");
                return;
            }
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("response failed");
            return;
        };

        if (response.head.status == .ok) {
            // Success - break out of retry loop
            break;
        }

        // Check if status is retryable
        const status_code: u16 = @intFromEnum(response.head.status);
        const should_retry = retry_util.isRetryable(status_code) and retry_attempt < MAX_RETRIES;

        if (should_retry) {
            // Note: We skip reading the error body here because the response state machine
            // may not be in a valid state for body reading (e.g., after a redirect or when
            // the connection has been reset). The error body is only used for optional retry
            // delay hints, so we rely on status code and Retry-After header instead.
            const error_text: []const u8 = &.{};

            // Check if error body indicates a retryable error
            const is_retryable_error = retry_util.isRetryableError(error_text);

            // Calculate delay - prefer server-provided delay
            var delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);

            // Check Retry-After header (only if headers contain valid \r\n separator)
            if (std.mem.find(u8, response.head.bytes, "\r\n") != null) {
                var retry_after_iter = response.head.iterateHeaders();
                while (retry_after_iter.next()) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
                        if (retry_util.extractRetryDelayFromHeader(header.value)) |server_delay| {
                            if (server_delay <= max_delay_ms) {
                                delay = server_delay;
                            }
                        }
                        break;
                    }
                }
            }

            // Check body for retry delay
            if (retry_util.extractRetryDelayFromBody(error_text)) |body_delay| {
                if (body_delay <= max_delay_ms) {
                    delay = body_delay;
                }
            }

            // If not a retryable error message, don't retry
            if (!is_retryable_error and !retry_util.isRetryable(status_code)) {
                break;
            }

            // Wait before retry
            if (!retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                // Sleep was cancelled
                ctx.deinit();
                stream.markThreadDone();
                stream.completeWithError("request cancelled");
                return;
            }

            retry_attempt += 1;
            continue;
        }

        // Non-retryable error or max retries reached
        break;
    }

    // After retry loop, check final status
    if (response.head.status != .ok) {
        const status_code = @intFromEnum(response.head.status);
        if (last_error) |e| allocator.free(e);
        last_error = std.fmt.allocPrint(allocator, "anthropic request failed: HTTP {d}{s}", .{
            status_code,
            if (status_code == 401) " (check ANTHROPIC_API_KEY is valid)" else "",
        }) catch null;

        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError(last_error orelse "anthropic request failed");
        return;
    }

    var parser = sse_parser.SSEParser.init(allocator);
    defer parser.deinit();

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = compat.http.responseReader(&response, &transfer_buf);

    // Track content blocks by API index
    const BlockInfo = struct {
        content_type: ParseResult.ContentType,
        content_index: usize, // index in our content array
    };
    var block_map = std.AutoHashMap(usize, BlockInfo).init(allocator);
    defer block_map.deinit();

    // Track tool calls during streaming
    var tc_tracker = tool_call_tracker.ToolCallTracker.init(allocator);
    defer tc_tracker.deinit();

    // Accumulate content for final message
    var content_blocks = std.ArrayList(ai_types.AssistantContent).empty;
    defer content_blocks.deinit(allocator);
    var current_text = std.ArrayList(u8).empty;
    defer current_text.deinit(allocator);
    var current_thinking = std.ArrayList(u8).empty;
    defer current_thinking.deinit(allocator);
    var current_thinking_signature = std.ArrayList(u8).empty;
    defer current_thinking_signature.deinit(allocator);

    // Deferred frees for delta strings pushed to the stream.
    // stream.push() stores borrowed references (owns_events=false); we must not free
    // a delta string until AFTER the SSE loop exits to avoid a GPA timing issue where
    // an in-flight free interleaves with subsequent GPA allocations in the same thread
    // (content_blocks.append / block_map.put), which can silently fail under load.
    // By collecting delta pointers here and freeing them all at thread exit we:
    //   a) eliminate the leak the GPA would otherwise report, and
    //   b) guarantee the frees only happen after all SSE processing is complete.
    var pending_delta_frees = std.ArrayList([]const u8).empty;
    defer {
        for (pending_delta_frees.items) |s| allocator.free(s);
        pending_delta_frees.deinit(allocator);
    }

    // Accumulate raw response bytes for error diagnosis (up to 8 KB).
    // Used to detect non-SSE JSON error bodies returned with HTTP 200.
    var raw_body = std.ArrayList(u8).empty;
    defer raw_body.deinit(allocator);

    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;

    // Ping tracking
    var last_ping_time: i64 = 0;
    const ping_interval = ctx.ping_interval_ms orelse 0;

    // Emit start event with partial message
    const partial_start = createPartialMessage(model);
    stream.push(.{ .start = .{ .partial = partial_start } }) catch {};

    while (true) {
        // Emit ping if interval is configured
        if (ping_interval > 0) {
            const now = compat.time.nowMillis();
            if (now - last_ping_time >= ping_interval) {
                stream.push(.{ .keepalive = {} }) catch {};
                last_ping_time = now;
            }
        }

        // Check cancellation during streaming
        if (cancel_token) |ct| {
            if (ct.isCancelled()) {
                ctx.deinit();
                stream.markThreadDone();
                stream.completeWithError("request cancelled");
                return;
            }
        }

        if (testCancelAt(cancel_token, .between_sse_events)) {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("request cancelled");
            return;
        }

        const n = compat.http.readResponse(reader, &read_buf) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("read error");
            return;
        };
        if (n == 0) break;

        if (testCancelAt(cancel_token, .mid_event_payload)) {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("request cancelled");
            return;
        }

        // Accumulate raw bytes for error diagnosis (capped at 8 KB)
        if (raw_body.items.len < 8192) {
            const cap = 8192 - raw_body.items.len;
            raw_body.appendSlice(allocator, read_buf[0..@min(n, cap)]) catch {};
        }

        const events = parser.feed(read_buf[0..n]) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("sse parse error");
            return;
        };

        for (events) |ev| {
            const result = parseAnthropicEventType(ev.data, allocator) catch {
                ctx.deinit();
                stream.markThreadDone();
                stream.completeWithError("event parse error");
                return;
            };

            switch (result) {
                .none => {},
                .message_start => |ms| {
                    usage.input = ms.input_tokens;
                    usage.output = ms.output_tokens;
                    usage.cache_read = ms.cache_read;
                    usage.cache_write = ms.cache_write;
                    usage.calculateCost(model.cost);
                },
                .content_block_start => |cbs| {
                    const content_idx = content_blocks.items.len;

                    // Initialize accumulators based on block type
                    switch (cbs.block_type) {
                        .text => {
                            current_text.clearRetainingCapacity();
                            // Emit text_start event
                            const partial = createPartialMessage(model);
                            stream.push(.{ .text_start = .{ .content_index = content_idx, .partial = partial } }) catch {};
                        },
                        .thinking => {
                            current_thinking.clearRetainingCapacity();
                            current_thinking_signature.clearRetainingCapacity();
                            // Emit thinking_start event
                            const partial = createPartialMessage(model);
                            stream.push(.{ .thinking_start = .{ .content_index = content_idx, .partial = partial } }) catch {};
                        },
                        .tool_use => {
                            _ = tc_tracker.startCall(cbs.index, content_idx, cbs.tool_id, cbs.tool_name) catch {};

                            stream.push(.{ .toolcall_start = .{
                                .content_index = content_idx,
                                .id = cbs.tool_id,
                                .name = cbs.tool_name,
                                .partial = createPartialMessage(model),
                            } }) catch {};
                        },
                    }

                    block_map.put(cbs.index, .{ .content_type = cbs.block_type, .content_index = content_idx }) catch {};
                },
                .content_block_delta => |cbd| {
                    if (block_map.get(cbd.index)) |block_info| {
                        const partial = createPartialMessage(model);

                        switch (cbd.delta) {
                            .text => |txt| {
                                current_text.appendSlice(allocator, txt) catch {};
                                stream.push(.{ .text_delta = .{ .content_index = block_info.content_index, .delta = txt, .partial = partial } }) catch {};
                                // Defer the free: freeing a duped delta while the SSE loop is still
                                // running can interfere with subsequent GPA allocations (block_map.put,
                                // content_blocks.append) causing them to silently fail. Track the pointer
                                // and free the batch at thread exit via pending_delta_frees.
                                pending_delta_frees.append(allocator, txt) catch allocator.free(txt);
                            },
                            .thinking => |thk| {
                                current_thinking.appendSlice(allocator, thk) catch {};
                                stream.push(.{ .thinking_delta = .{ .content_index = block_info.content_index, .delta = thk, .partial = partial } }) catch {};
                                pending_delta_frees.append(allocator, thk) catch allocator.free(thk);
                            },
                            .signature => |sig| {
                                current_thinking_signature.appendSlice(allocator, sig) catch {};
                                // sig is not stored in the stream, so it is safe to free immediately.
                                allocator.free(sig);
                            },
                            .input_json => |json_delta| {
                                // appendDelta copies json_delta into its accumulator.
                                tc_tracker.appendDelta(cbd.index, json_delta) catch {};

                                if (tc_tracker.getContentIndex(cbd.index)) |content_idx| {
                                    stream.push(.{ .toolcall_delta = .{
                                        .content_index = content_idx,
                                        .delta = json_delta,
                                        .partial = createPartialMessage(model),
                                    } }) catch {};
                                }
                                pending_delta_frees.append(allocator, json_delta) catch allocator.free(json_delta);
                            },
                        }
                    } else {
                        switch (cbd.delta) {
                            inline else => |s| allocator.free(s),
                        }
                    }
                },
                .content_block_stop => |cbs| {
                    if (block_map.get(cbs.index)) |block_info| {
                        const partial = createPartialMessage(model);

                        switch (block_info.content_type) {
                            .text => {
                                // Store the completed text block
                                const text_copy = allocator.dupe(u8, current_text.items) catch {
                                    ctx.deinit();
                                    stream.markThreadDone();
                                    stream.completeWithError("oom text");
                                    return;
                                };
                                content_blocks.append(allocator, .{ .text = .{ .text = text_copy } }) catch {};

                                stream.push(.{ .text_end = .{ .content_index = block_info.content_index, .content = current_text.items, .partial = partial } }) catch {};
                            },
                            .thinking => {
                                // Store the completed thinking block
                                const thinking_copy = allocator.dupe(u8, current_thinking.items) catch {
                                    ctx.deinit();
                                    stream.markThreadDone();
                                    stream.completeWithError("oom thinking");
                                    return;
                                };
                                const sig_copy = if (current_thinking_signature.items.len > 0)
                                    allocator.dupe(u8, current_thinking_signature.items) catch null
                                else
                                    null;

                                content_blocks.append(allocator, .{ .thinking = .{
                                    .thinking = thinking_copy,
                                    .thinking_signature = sig_copy,
                                } }) catch {};

                                stream.push(.{ .thinking_end = .{ .content_index = block_info.content_index, .content = current_thinking.items, .partial = partial } }) catch {};
                            },
                            .tool_use => {
                                if (tc_tracker.completeCall(cbs.index, allocator)) |tool_call| {
                                    content_blocks.append(allocator, .{ .tool_call = tool_call }) catch {};

                                    // Dupe the tool_call for the event so it owns its own memory
                                    const event_tc = ai_types.ToolCall{
                                        .id = allocator.dupe(u8, tool_call.id) catch tool_call.id,
                                        .name = allocator.dupe(u8, tool_call.name) catch tool_call.name,
                                        .arguments_json = if (tool_call.arguments_json.len > 0) allocator.dupe(u8, tool_call.arguments_json) catch tool_call.arguments_json else "",
                                        .thought_signature = if (tool_call.thought_signature) |sig| allocator.dupe(u8, sig) catch sig else null,
                                    };

                                    stream.push(.{ .toolcall_end = .{
                                        .content_index = content_blocks.items.len - 1,
                                        .tool_call = event_tc,
                                        .partial = createPartialMessage(model),
                                    } }) catch {};
                                }
                            },
                        }
                    }
                },
                .message_delta => |md| {
                    stop_reason = md.stop_reason;
                    usage.output = md.output_tokens;
                    usage.calculateCost(model.cost);
                },
                .message_stop => {},
                .api_error => |err| {
                    defer allocator.free(err);
                    ctx.deinit();
                    stream.markThreadDone();
                    stream.completeWithError(err);
                    return;
                },
            }
        }
    }

    // Flush SSE parser: finalizes any partial event that was missing its trailing \n\n.
    // This handles truncated SSE responses where the API closes the connection before
    // sending the final blank line.  Only api_error is actionable here; other events
    // from a genuinely truncated stream are incomplete and best ignored.
    {
        const tail = parser.feed("\n\n") catch &.{};
        for (tail) |ev| {
            const result = parseAnthropicEventType(ev.data, allocator) catch continue;
            switch (result) {
                .api_error => |err| {
                    defer allocator.free(err);
                    ctx.deinit();
                    stream.markThreadDone();
                    stream.completeWithError(err);
                    return;
                },
                else => {},
            }
        }
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output;
    usage.calculateCost(model.cost);

    // If no content blocks were collected but we have text, create a text block
    if (content_blocks.items.len == 0 and current_text.items.len > 0) {
        const text_copy = allocator.dupe(u8, current_text.items) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("oom text");
            return;
        };
        content_blocks.append(allocator, .{ .text = .{ .text = text_copy } }) catch {};
    }

    // If still no content, try to detect a plain JSON error body (no SSE framing)
    // that Anthropic sometimes returns with HTTP 200 under load.
    if (content_blocks.items.len == 0) {
        var err_text: []const u8 = "anthropic returned empty response with no content blocks";
        var err_owned: ?[]u8 = null;
        defer if (err_owned) |e| allocator.free(e);

        if (raw_body.items.len > 0) {
            // Attempt to parse the entire raw body as a JSON error object
            if (std.json.parseFromSlice(std.json.Value, allocator, raw_body.items, .{})) |body_json| {
                defer body_json.deinit();
                if (body_json.value == .object) {
                    if (body_json.value.object.get("type")) |bt| {
                        if (bt == .string and std.mem.eql(u8, bt.string, "error")) {
                            var emsg: []const u8 = "anthropic api error";
                            if (body_json.value.object.get("error")) |e| {
                                if (e == .object) {
                                    if (e.object.get("message")) |m| {
                                        if (m == .string) emsg = m.string;
                                    }
                                }
                            }
                            err_owned = allocator.dupe(u8, emsg) catch null;
                            if (err_owned) |e| err_text = e;
                        }
                    }
                }
            } else |_| {}

            // If not a JSON error body, include the byte count for self-diagnosing failures
            if (err_owned == null) {
                err_owned = std.fmt.allocPrint(allocator, "anthropic: empty response ({d} raw bytes, no SSE events)", .{raw_body.items.len}) catch null;
                if (err_owned) |e| err_text = e;
            }
        }

        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError(err_text);
        return; // defer fires, freeing err_owned after completeWithError has duped err_text
    }

    const content_slice = content_blocks.toOwnedSlice(allocator) catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("oom content");
        return;
    };

    const out = ai_types.AssistantMessage{
        .content = content_slice,
        .api = allocator.dupe(u8, model.api) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("oom");
            return;
        },
        .provider = allocator.dupe(u8, model.provider) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("oom");
            return;
        },
        .model = allocator.dupe(u8, model.id) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("oom");
            return;
        },
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp = compat.time.nowMillis(),
        .is_owned = true, // Strings were duped above
    };

    // Do NOT push a .done event here — the same AssistantMessage would be
    // referenced by both the event and complete(), causing a double-free when
    // the consumer deinits either one. OpenAI Completions uses the same
    // pattern (complete() only, no preceding .done event).

    // Free ctx allocations before completing
    ctx.deinit();

    stream.markThreadDone();
    stream.complete(out);
}

fn createPartialMessage(model: ai_types.Model) ai_types.AssistantMessage {
    return ai_types.AssistantMessage{
        .content = &.{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = compat.time.nowMillis(),
    };
}

pub fn streamAnthropicMessages(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    const api_key: []u8 = blk: {
        if (o.getApiKey()) |k| break :blk try allocator.dupe(u8, k);
        const env = envApiKey(allocator);
        if (env) |k| break :blk @constCast(k);
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    // Clone model to own the memory (background thread outlives caller's memory)
    const owned_model = try ai_types.cloneModel(allocator, model);
    errdefer {
        var mut_m = owned_model;
        mut_m.deinit(allocator);
    }

    // Clone context to own the memory (background thread outlives caller's memory)
    const owned_context = try ai_types.cloneContext(allocator, context);
    errdefer {
        var mut_ctx = owned_context;
        mut_ctx.deinit(allocator);
    }

    const is_oauth = isOAuthToken(api_key);
    const body = try buildRequestBody(owned_model, owned_context, o, allocator, is_oauth);
    errdefer allocator.free(body);

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    errdefer allocator.destroy(s);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);
    s.wait_for_thread_on_deinit = true;
    if (o.requires_owned_stream_events) {
        s.owns_events = true;
        s.clone_event_fn = ai_types.cloneAssistantMessageEvent;
    }

    const ctx = try allocator.create(ThreadCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .stream = s,
        .model = owned_model,
        .context = owned_context,
        .api_key = api_key,
        .request_body = body,
        .cancel_token = o.cancel_token,
        .on_payload_fn = o.on_payload_fn,
        .on_payload_ctx = o.on_payload_ctx,
        .retry = o.retry,
        .ping_interval_ms = o.ping_interval_ms,
    };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

pub fn streamSimpleAnthropicMessages(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};

    // Build thinking options based on reasoning level and model capabilities
    var thinking_enabled: bool = false;
    var thinking_budget_tokens: ?u32 = null;
    var thinking_effort: ?[]const u8 = null;

    if (model.reasoning) {
        if (o.reasoning) |level| {
            thinking_enabled = true;
            if (supportsAdaptiveThinking(model.id)) {
                // Adaptive thinking: use effort level
                thinking_effort = mapThinkingLevelToEffort(level);
            } else {
                // Budget-based thinking for older models
                const max_tokens = o.max_tokens orelse model.max_tokens;
                thinking_budget_tokens = @min(getDefaultThinkingBudget(level, o.thinking_budgets), max_tokens - 1);
            }
        }
    }

    return streamAnthropicMessages(model, context, .{
        .temperature = o.temperature,
        .max_tokens = o.max_tokens,
        .api_key = if (o.api_key) |k| ai_types.OwnedSlice(u8).initBorrowed(k) else ai_types.OwnedSlice(u8).initBorrowed(""),
        .cache_retention = o.cache_retention,
        .session_id = if (o.session_id) |sid| ai_types.OwnedSlice(u8).initBorrowed(sid) else ai_types.OwnedSlice(u8).initBorrowed(""),
        .headers = o.headers,
        .retry = o.retry,
        .cancel_token = o.cancel_token,
        .on_payload_fn = o.on_payload_fn,
        .on_payload_ctx = o.on_payload_ctx,
        .thinking_enabled = thinking_enabled,
        .thinking_budget_tokens = thinking_budget_tokens,
        .thinking_effort = if (thinking_effort) |eff| ai_types.OwnedSlice(u8).initBorrowed(eff) else ai_types.OwnedSlice(u8).initBorrowed(""),
    }, allocator);
}

pub fn registerAnthropicMessagesApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "anthropic-messages",
        .stream = streamAnthropicMessages,
        .stream_simple = streamSimpleAnthropicMessages,
        .auth_provider_id = "anthropic",
        .auth_refresh_fn = anthropicRefresh,
        .auth_get_api_key_fn = anthropicGetApiKey,
        .is_auth_failure = anthropicIsAuthFailure,
    }, null);
}

test "getCacheControl returns null for none retention" {
    const result = getCacheControl("https://api.anthropic.com", .none);
    try std.testing.expect(result == null);
}

test "getCacheControl returns short retention without ttl for non-anthropic url" {
    const result = getCacheControl("https://custom.api.com", .short);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(ai_types.CacheRetention.short, result.?.retention);
    try std.testing.expectEqual(false, result.?.has_ttl);
}

test "getCacheControl returns long retention with ttl for anthropic url" {
    const result = getCacheControl("https://api.anthropic.com", .long);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(ai_types.CacheRetention.long, result.?.retention);
    try std.testing.expectEqual(true, result.?.has_ttl);
}

test "getCacheControl returns long retention without ttl for non-anthropic url" {
    const result = getCacheControl("https://custom.api.com", .long);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(ai_types.CacheRetention.long, result.?.retention);
    try std.testing.expectEqual(false, result.?.has_ttl);
}

test "buildRequestBody includes cache_control in system prompt" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "claude-3-5-sonnet-20241022",
        .name = "Claude 3.5 Sonnet",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 3.0, .output = 15.0, .cache_read = 0.3, .cache_write = 3.75 },
        .context_window = 200000,
        .max_tokens = 8192,
    };

    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .text = "Hello" }, .timestamp = 0 } },
    };

    const context = ai_types.Context{
        .system_prompt = ai_types.OwnedSlice(u8).initBorrowed("You are a helpful assistant."),
        .messages = &messages,
    };

    const options = ai_types.StreamOptions{
        .max_tokens = 1024,
        .cache_retention = .short,
    };

    const body = try buildRequestBody(model, context, options, allocator, false);
    defer allocator.free(body);

    // Verify system prompt is an array with cache_control
    try std.testing.expect(std.mem.find(u8, body, "\"system\":[") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"ttl\"") == null); // short retention, no ttl
}

test "buildRequestBody includes ttl for long retention on anthropic url" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "claude-3-5-sonnet-20241022",
        .name = "Claude 3.5 Sonnet",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 3.0, .output = 15.0, .cache_read = 0.3, .cache_write = 3.75 },
        .context_window = 200000,
        .max_tokens = 8192,
    };

    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .text = "Hello" }, .timestamp = 0 } },
    };

    const context = ai_types.Context{
        .system_prompt = ai_types.OwnedSlice(u8).initBorrowed("You are a helpful assistant."),
        .messages = &messages,
    };

    const options = ai_types.StreamOptions{
        .max_tokens = 1024,
        .cache_retention = .long,
    };

    const body = try buildRequestBody(model, context, options, allocator, false);
    defer allocator.free(body);

    // Verify ttl is included for long retention
    try std.testing.expect(std.mem.find(u8, body, "\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}") != null);
}

test "buildRequestBody serializes tool_result as tool_result content block" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "claude-3-5-sonnet-20241022",
        .name = "Claude 3.5 Sonnet",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 3.0, .output = 15.0, .cache_read = 0.3, .cache_write = 3.75 },
        .context_window = 200000,
        .max_tokens = 8192,
    };

    const tool_result_content = [_]ai_types.UserContentPart{
        .{ .text = .{ .text = "Tool execution result" } },
    };

    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .text = "Use the tool" }, .timestamp = 0 } },
        .{ .assistant = .{ .content = &.{
            .{ .tool_call = .{ .id = "toolu_123", .name = "bash", .arguments_json = "{\"cmd\": \"ls\"}" } },
        }, .api = "anthropic-messages", .provider = "anthropic", .model = "claude-3-5-sonnet-20241022", .usage = .{}, .stop_reason = .tool_use, .timestamp = 0 } },
        .{ .tool_result = .{ .tool_call_id = "toolu_123", .tool_name = "bash", .content = &tool_result_content, .is_error = false, .timestamp = 0 } },
    };

    const context = ai_types.Context{
        .system_prompt = ai_types.OwnedSlice(u8).initBorrowed("You are a helpful assistant."),
        .messages = &messages,
    };

    const options = ai_types.StreamOptions{
        .max_tokens = 1024,
    };

    const body = try buildRequestBody(model, context, options, allocator, false);
    defer allocator.free(body);

    // Parse to verify structure
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const msg_array = parsed.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 3), msg_array.items.len);

    // Tool result message should have role "user"
    const tool_result_msg = msg_array.items[2];
    try std.testing.expectEqualStrings("user", tool_result_msg.object.get("role").?.string);

    // Content should be an array
    const content = tool_result_msg.object.get("content").?;
    try std.testing.expect(content == .array);
    try std.testing.expectEqual(@as(usize, 1), content.array.items.len);

    // Verify tool_result content block structure
    const tool_result_block = content.array.items[0];
    try std.testing.expectEqualStrings("tool_result", tool_result_block.object.get("type").?.string);
    try std.testing.expectEqualStrings("toolu_123", tool_result_block.object.get("tool_use_id").?.string);
    try std.testing.expectEqualStrings("Tool execution result", tool_result_block.object.get("content").?.string);
    try std.testing.expectEqual(false, tool_result_block.object.get("is_error").?.bool);
}

test "buildRequestBody serializes tool_result with is_error=true" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "claude-3-5-sonnet-20241022",
        .name = "Claude 3.5 Sonnet",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 3.0, .output = 15.0, .cache_read = 0.3, .cache_write = 3.75 },
        .context_window = 200000,
        .max_tokens = 8192,
    };

    const tool_result_content = [_]ai_types.UserContentPart{
        .{ .text = .{ .text = "Error: command failed" } },
    };

    const messages = [_]ai_types.Message{
        .{ .tool_result = .{ .tool_call_id = "toolu_456", .tool_name = "bash", .content = &tool_result_content, .is_error = true, .timestamp = 0 } },
    };

    const context = ai_types.Context{
        .messages = &messages,
    };

    const options = ai_types.StreamOptions{
        .max_tokens = 1024,
    };

    const body = try buildRequestBody(model, context, options, allocator, false);
    defer allocator.free(body);

    // Verify is_error is true
    try std.testing.expect(std.mem.find(u8, body, "\"is_error\":true") != null);
}

test "buildRequestBody adds cache_control to last user message" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "claude-3-5-sonnet-20241022",
        .name = "Claude 3.5 Sonnet",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 3.0, .output = 15.0, .cache_read = 0.3, .cache_write = 3.75 },
        .context_window = 200000,
        .max_tokens = 8192,
    };

    const messages = [_]ai_types.Message{
        .{ .user = .{ .content = .{ .text = "First message" }, .timestamp = 0 } },
        .{ .assistant = .{ .content = &.{.{ .text = .{ .text = "Response" } }}, .api = "anthropic-messages", .provider = "anthropic", .model = "claude-3-5-sonnet-20241022", .usage = .{}, .stop_reason = .stop, .timestamp = 0 } },
        .{ .user = .{ .content = .{ .text = "Last message" }, .timestamp = 0 } },
    };

    const context = ai_types.Context{
        .system_prompt = ai_types.OwnedSlice(u8).initBorrowed("You are a helpful assistant."),
        .messages = &messages,
    };

    const options = ai_types.StreamOptions{
        .max_tokens = 1024,
        .cache_retention = .short,
    };

    const body = try buildRequestBody(model, context, options, allocator, false);
    defer allocator.free(body);

    // Parse to verify structure
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const msg_array = parsed.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 3), msg_array.items.len);

    // First user message should be string content
    try std.testing.expect(msg_array.items[0].object.get("content").? == .string);

    // Last user message should be array content with cache_control
    const last_content = msg_array.items[2].object.get("content").?;
    try std.testing.expect(last_content == .array);
    const last_block = last_content.array.items[0];
    try std.testing.expect(last_block.object.get("cache_control") != null);
}

test "parseAnthropicEventType extracts tool_use id and name" {
    const allocator = std.testing.allocator;
    const data =
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01A","name":"bash"}}
    ;

    const result = try parseAnthropicEventType(data, allocator);

    try std.testing.expectEqual(ParseResult.ContentType.tool_use, result.content_block_start.block_type);
    try std.testing.expectEqual(@as(usize, 0), result.content_block_start.index);
    try std.testing.expectEqualStrings("toolu_01A", result.content_block_start.tool_id);
    try std.testing.expectEqualStrings("bash", result.content_block_start.tool_name);

    // Free the duped strings
    allocator.free(result.content_block_start.tool_id);
    allocator.free(result.content_block_start.tool_name);
}


fn regressionModel(api_name: []const u8, provider_name: []const u8, base_url: []const u8) ai_types.Model {
    return .{
        .id = "regression-model",
        .name = "regression-model",
        .api = api_name,
        .provider = provider_name,
        .base_url = base_url,
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 16,
    };
}

fn regressionContext() ai_types.Context {
    const messages = struct {
        const items = [_]ai_types.Message{.{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } }};
    }.items[0..];
    return .{ .messages = messages };
}

fn expectCancelledStream(stream: *event_stream.AssistantMessageEventStream, allocator: std.mem.Allocator) !void {
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    const deadline = compat.time.nowMillis() + 5_000;
    while (!stream.isDone()) {
        if (compat.time.nowMillis() >= deadline) return error.TestUnexpectedResult;
        compat.time.sleepNs(std.time.ns_per_ms);
    }

    try std.testing.expect(stream.waitForThread(5_000));
    try std.testing.expect(stream.getError() != null);
    try std.testing.expectEqualStrings("request cancelled", stream.getError().?);
}

fn expectSyntheticAnthropicBoundaryCancellation(stage: TestCancelStage) !void {
    var cancelled = std.atomic.Value(bool).init(false);
    const cancel_token = ai_types.CancelToken{ .cancelled = &cancelled };

    test_cancel_stage = stage;
    defer test_cancel_stage = null;

    try std.testing.expect(testCancelAt(cancel_token, stage));
    try std.testing.expect(cancel_token.isCancelled());
}

test "provider_cancellation_anthropic_cancel_before_request" {
    var cancelled = std.atomic.Value(bool).init(true);
    const cancel_token = ai_types.CancelToken{ .cancelled = &cancelled };
    const stream = try streamSimpleAnthropicMessages(
        regressionModel("anthropic-messages", "anthropic", "https://example.invalid"),
        regressionContext(),
        .{ .api_key = "test-key", .cancel_token = cancel_token },
        std.testing.allocator,
    );
    try expectCancelledStream(stream, std.testing.allocator);
}

test "provider_cancellation_anthropic_cancel_during_connect_setup" {
    try expectSyntheticAnthropicBoundaryCancellation(.connect_setup);
}

test "provider_cancellation_anthropic_cancel_during_response_headers" {
    try expectSyntheticAnthropicBoundaryCancellation(.response_headers);
}

test "provider_cancellation_anthropic_cancel_between_sse_events" {
    try expectSyntheticAnthropicBoundaryCancellation(.between_sse_events);
}

test "provider_cancellation_anthropic_cancel_mid_event_payload" {
    try expectSyntheticAnthropicBoundaryCancellation(.mid_event_payload);
}

test "anthropic_api_key_headers_are_forwarded_exactly" {
    var header_set = try buildAnthropicHeaders(std.testing.allocator, "sk-ant-api-test");
    defer header_set.deinit(std.testing.allocator);

    const headers = header_set.headers.items;
    try std.testing.expectEqual(@as(usize, 4), headers.len);
    try std.testing.expectEqualStrings("x-api-key", headers[0].name);
    try std.testing.expectEqualStrings("sk-ant-api-test", headers[0].value);
    try std.testing.expectEqualStrings("anthropic-beta", headers[1].name);
    try std.testing.expectEqualStrings("fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14", headers[1].value);
    try std.testing.expectEqualStrings("anthropic-version", headers[2].name);
    try std.testing.expectEqualStrings("2023-06-01", headers[2].value);
    try std.testing.expectEqualStrings("content-type", headers[3].name);
    try std.testing.expectEqualStrings("application/json", headers[3].value);
}

test "anthropic_oauth_headers_are_forwarded_exactly" {
    var header_set = try buildAnthropicHeaders(std.testing.allocator, "sk-ant-oat-test");
    defer header_set.deinit(std.testing.allocator);

    const headers = header_set.headers.items;
    try std.testing.expectEqual(@as(usize, 7), headers.len);
    try std.testing.expectEqualStrings("authorization", headers[0].name);
    try std.testing.expectEqualStrings("Bearer sk-ant-oat-test", headers[0].value);
    try std.testing.expectEqualStrings("anthropic-beta", headers[1].name);
    try std.testing.expectEqualStrings("claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14", headers[1].value);
    try std.testing.expectEqualStrings("anthropic-dangerous-direct-browser-access", headers[2].name);
    try std.testing.expectEqualStrings("true", headers[2].value);
    try std.testing.expectEqualStrings("user-agent", headers[3].name);
    try std.testing.expectEqualStrings("claude-cli/2.1.2 (external, cli)", headers[3].value);
    try std.testing.expectEqualStrings("x-app", headers[4].name);
    try std.testing.expectEqualStrings("cli", headers[4].value);
    try std.testing.expectEqualStrings("anthropic-version", headers[5].name);
    try std.testing.expectEqualStrings("2023-06-01", headers[5].value);
    try std.testing.expectEqualStrings("content-type", headers[6].name);
    try std.testing.expectEqualStrings("application/json", headers[6].value);
}
