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

fn allowsAnonymous(model: ai_types.Model) bool {
    if (!model.allows_anonymous) return false;
    return !std.mem.eql(u8, model.provider, "anthropic");
}

fn envApiKeyForProvider(allocator: std.mem.Allocator, provider_id: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, provider_id, "anthropic")) return null;
    if (compat.getEnvVarOwned(allocator, "ANTHROPIC_AUTH_TOKEN")) |key| return key else |_| {}
    if (compat.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY")) |key| return key else |_| {}
    return null;
}

fn isOAuthToken(key: []const u8) bool {
    return std.mem.find(u8, key, "sk-ant-oat") != null;
}

fn buildUrlWithSuffix(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, suffix)) return allocator.dupe(u8, trimmed);
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

const CacheControlResult = struct {
    retention: ai_types.CacheRetention,
    has_ttl: bool,
};

fn getCacheControl(base_url: []const u8, cache_retention: ?ai_types.CacheRetention, supports_long_ttl: bool) ?CacheControlResult {
    const retention = cache_retention orelse .short;
    if (retention == .none) return null;

    const has_ttl = retention == .long and (isAnthropicHost(base_url) or supports_long_ttl);

    return .{
        .retention = retention,
        .has_ttl = has_ttl,
    };
}

fn isAnthropicHost(base_url: []const u8) bool {
    const uri = std.Uri.parse(base_url) catch return false;
    const host = uri.host orelse return false;
    const value = host.percent_encoded;
    return std.ascii.eqlIgnoreCase(value, "api.anthropic.com");
}

fn supportsAdaptiveThinking(model_id: []const u8) bool {
    return std.mem.find(u8, model_id, "opus-4-6") != null or
        std.mem.find(u8, model_id, "opus-4.6") != null;
}

fn mapThinkingLevelToEffort(level: ai_types.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "low",
        .minimal => "low",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "max",
    };
}

fn getDefaultThinkingBudget(level: ai_types.ThinkingLevel, budgets: ?ai_types.ThinkingBudgets) u32 {
    if (budgets) |b| {
        return switch (level) {
            .off => 0,
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

fn shouldSkipAssistant(msg: ai_types.Message) bool {
    switch (msg) {
        .assistant => |a| {
            return a.stop_reason == .aborted or a.stop_reason == .@"error";
        },
        else => {},
    }
    return false;
}

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

fn isOrphanedToolResult(msg: ai_types.Message, tool_call_ids: *const std.StringHashMap(void)) bool {
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

    var transformed = try pre_transform.preTransform(allocator, context.messages, .{
        .target_api = model.api,
        .target_provider = model.provider,
        .target_model_id = model.id,
        .max_tool_id_len = 64,
        .insert_synthetic_results = true,
        .tools = context.tools,
        .is_oauth = is_oauth,
    });
    defer transformed.deinit();

    var tx_context = context;
    tx_context.messages = transformed.messages;

    const supports_long_cache_ttl = if (model.compat) |compat_options|
        compat_options.supports_anthropic_cache_ttl == true
    else
        false;
    const cache_control = getCacheControl(model.base_url, options.cache_retention, supports_long_cache_ttl);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try w.writeStringField("model", model.id);
    const default_max = @min(model.max_tokens / 3, 32000);
    const requested_max = options.max_tokens orelse default_max;
    try w.writeIntField("max_tokens", requested_max);
    try w.writeBoolField("stream", true);

    const emits_thinking = options.thinking_enabled and model.reasoning and
        (supportsAdaptiveThinking(model.id) or requested_max > 1024);
    if (options.temperature) |t| {
        if (emits_thinking and t != 1) {} else {
            try w.writeKey("temperature");
            try w.writeFloat(t);
        }
    }

    if (context.getSystemPrompt()) |sp| {
        try w.writeKey("system");
        try w.beginArray();

        try w.beginObject();
        try w.writeStringField("type", "text");
        if (is_oauth) {
            const full_prompt = try std.fmt.allocPrint(allocator, "You are Claude Code, Anthropic's official CLI for Claude.\n\n{s}", .{sp});
            defer allocator.free(full_prompt);
            const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, full_prompt);
            defer {
                if (sanitized.ptr != full_prompt.ptr) {
                    allocator.free(@constCast(sanitized));
                }
            }
            try w.writeStringField("text", sanitized);
        } else {
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

    var tool_call_ids = collectToolCallIds(allocator, tx_context.messages) catch std.StringHashMap(void).init(allocator);
    defer freeToolCallIds(allocator, &tool_call_ids);

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

        if (shouldSkipAssistant(m)) {
            msg_idx += 1;
            continue;
        }

        if (isOrphanedToolResult(m, &tool_call_ids)) {
            msg_idx += 1;
            continue;
        }

        const is_last_user = last_user_idx != null and msg_idx == last_user_idx.?;

        if (m == .tool_result) {
            try w.beginObject();
            try w.writeStringField("role", "user");
            try w.writeKey("content");
            try w.beginArray();

            while (msg_idx < tx_context.messages.len and tx_context.messages[msg_idx] == .tool_result) {
                const tr = tx_context.messages[msg_idx].tool_result;

                try w.beginObject();
                try w.writeStringField("type", "tool_result");
                try w.writeStringField("tool_use_id", tr.tool_call_id);

                if (tr.content.len == 1 and tr.content[0] == .text) {
                    const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, tr.content[0].text.text);
                    defer {
                        if (sanitized.ptr != tr.content[0].text.text.ptr) {
                            allocator.free(@constCast(sanitized));
                        }
                    }
                    try w.writeStringField("content", sanitized);
                } else if (tr.content.len > 1 or (tr.content.len > 0 and tr.content[0] == .image)) {
                    try w.writeKey("content");
                    try w.beginArray();
                    for (tr.content) |c| {
                        switch (c) {
                            .text => |t| {
                                try w.beginObject();
                                try w.writeStringField("type", "text");
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
                    try w.writeStringField("content", "");
                }

                try w.writeBoolField("is_error", tr.is_error);
                try w.endObject();

                msg_idx += 1;
            }

            try w.endArray();
            try w.endObject();
            continue;
        }

        const role: []const u8 = switch (m) {
            .assistant => "assistant",
            else => "user",
        };

        if (m == .assistant and hasToolUse(m)) {
            try w.beginObject();
            try w.writeStringField("role", role);
            try w.writeKey("content");
            try w.beginArray();

            for (m.assistant.content) |c| {
                switch (c) {
                    .text => |t| {
                        try w.beginObject();
                        try w.writeStringField("type", "text");
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
                        if (t.thinking_signature == null or t.thinking_signature.?.len == 0) {
                            try w.beginObject();
                            try w.writeStringField("type", "text");
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
            try w.beginObject();
            try w.writeStringField("role", role);
            try w.writeKey("content");
            try w.beginArray();

            switch (m.user.content) {
                .text => |t| {
                    try w.beginObject();
                    try w.writeStringField("type", "text");
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
                                const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.text);
                                defer {
                                    if (sanitized.ptr != t.text.ptr) {
                                        allocator.free(@constCast(sanitized));
                                    }
                                }
                                try w.writeStringField("text", sanitized);
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
            switch (m) {
                .user => |u| {
                    try w.beginObject();
                    try w.writeStringField("role", role);

                    switch (u.content) {
                        .text => |t| {
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

                    try w.writeKey("content");
                    try w.beginArray();
                    for (a.content) |c| {
                        switch (c) {
                            .text => |t| {
                                try w.beginObject();
                                try w.writeStringField("type", "text");
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
                                if (t.thinking_signature == null or t.thinking_signature.?.len == 0) {
                                    try w.beginObject();
                                    try w.writeStringField("type", "text");
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
                .tool_result => unreachable,
            }
        }

        msg_idx += 1;
    }
    try w.endArray();

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

    if (options.metadata) |meta| {
        if (meta.getUserId()) |user_id| {
            try w.writeKey("metadata");
            try w.beginObject();
            try w.writeStringField("user_id", user_id);
            try w.endObject();
        }
    }

    if (options.thinking_enabled and model.reasoning) {
        if (supportsAdaptiveThinking(model.id)) {
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
        } else if (requested_max > 1024) {
            try w.writeKey("thinking");
            try w.beginObject();
            try w.writeStringField("type", "enabled");
            const max_thinking_budget = if (requested_max > 0) requested_max - 1 else 0;
            try w.writeIntField("budget_tokens", @max(1024, @min(options.thinking_budget_tokens orelse 1024, max_thinking_budget)));
            try w.endObject();
        }
    }

    try w.endObject();
    return buf.toOwnedSlice(allocator);
}

const ParseResult = union(enum) {
    none: void,
    message_start: struct { input_tokens: u64, output_tokens: u64, cache_read: u64, cache_write: u64 },
    content_block_start: struct {
        index: usize,
        block_type: ContentType,
        tool_id: []const u8 = "",
        tool_name: []const u8 = "",
    },
    content_block_delta: struct { index: usize, delta: ContentDelta },
    content_block_stop: struct { index: usize },
    message_delta: struct { stop_reason: ai_types.StopReason, output_tokens: u64 },
    message_stop: void,
    api_error: []const u8,

    fn deinit(self: ParseResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .content_block_start => |cbs| {
                if (cbs.block_type == .tool_use) {
                    allocator.free(cbs.tool_id);
                    allocator.free(cbs.tool_name);
                }
            },
            .content_block_delta => |cbd| switch (cbd.delta) {
                inline else => |slice| allocator.free(slice),
            },
            .api_error => |err| allocator.free(err),
            .none, .message_start, .content_block_stop, .message_delta, .message_stop => {},
        }
    }

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

        if (block_type == .tool_use) {
            var tool_id: []const u8 = "";
            var tool_name: []const u8 = "";
            if (content_block.object.get("id")) |id_val| {
                if (id_val == .string) tool_id = id_val.string;
            }
            if (content_block.object.get("name")) |name_val| {
                if (name_val == .string) tool_name = name_val.string;
            }
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

fn buildAnthropicHeaders(allocator: std.mem.Allocator, api_key: []const u8, model_headers: ?[]const ai_types.HeaderPair) !AnthropicHeaderSet {
    var out = AnthropicHeaderSet{ .headers = .empty };
    errdefer out.deinit(allocator);

    const is_oauth = isOAuthToken(api_key);

    if (api_key.len == 0) {
        try out.headers.append(allocator, .{ .name = "anthropic-beta", .value = "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14" });
    } else if (is_oauth) {
        out.auth_header = try buildBearerAuthValue(allocator, api_key);
        try out.headers.append(allocator, .{ .name = "authorization", .value = out.auth_header.? });
        try out.headers.append(allocator, .{ .name = "anthropic-beta", .value = "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14" });
        try out.headers.append(allocator, .{ .name = "anthropic-dangerous-direct-browser-access", .value = "true" });
        try out.headers.append(allocator, .{ .name = "user-agent", .value = "claude-cli/2.1.2 (external, cli)" });
        try out.headers.append(allocator, .{ .name = "x-app", .value = "cli" });
    } else {
        try out.headers.append(allocator, .{ .name = "x-api-key", .value = api_key });
        try out.headers.append(allocator, .{ .name = "anthropic-beta", .value = "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14" });
    }

    try out.headers.append(allocator, .{ .name = "anthropic-version", .value = "2023-06-01" });
    try out.headers.append(allocator, .{ .name = "content-type", .value = "application/json" });

    if (model_headers) |extra| {
        for (extra) |header| {
            if (compat.http.headerPresent(out.headers.items, header.name)) continue;
            try out.headers.append(allocator, .{ .name = header.name, .value = header.value });
        }
    }

    return out;
}

fn retireDeltaSlice(
    allocator: std.mem.Allocator,
    pending: *std.ArrayList([]const u8),
    stream_clones_events: bool,
    slice: []const u8,
) void {
    if (stream_clones_events) {
        allocator.free(slice);
        return;
    }
    pending.append(allocator, slice) catch {};
}

fn runThread(ctx: *ThreadCtx) void {
    const allocator = ctx.allocator;
    const stream = ctx.stream;
    defer stream.markThreadDone();
    const model = ctx.model;
    const api_key = ctx.api_key;
    const request_body = ctx.request_body;
    const cancel_token = ctx.cancel_token;
    const on_payload_fn = ctx.on_payload_fn;
    const on_payload_ctx = ctx.on_payload_ctx;
    const retry_options = ctx.retry;

    if (on_payload_fn) |cb| {
        cb(on_payload_ctx, request_body);
    }

    if (cancel_token) |ct| {
        if (ct.isCancelled()) {
            ctx.deinit();
            stream.completeWithError("request cancelled");
            return;
        }
    }

    var http_client = compat.http.HttpClient.init(allocator);
    defer http_client.deinit();

    const url = buildUrlWithSuffix(allocator, model.base_url, "/v1/messages") catch {
        ctx.deinit();
        stream.completeWithError("oom building url");
        return;
    };
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        ctx.deinit();
        stream.completeWithError("invalid anthropic URL");
        return;
    };

    var header_set = buildAnthropicHeaders(allocator, api_key, model.headers) catch {
        ctx.deinit();
        stream.completeWithError("oom headers");
        return;
    };
    defer header_set.deinit(allocator);
    const headers = header_set.headers.items;

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
        if (cancel_token) |ct| {
            if (ct.isCancelled()) {
                ctx.deinit();
                stream.completeWithError("request cancelled");
                return;
            }
        }

        if (req_initialized) {
            req.deinit();
            req_initialized = false;
        }

        if (testCancelAt(cancel_token, .connect_setup)) {
            ctx.deinit();
            stream.completeWithError("request cancelled");
            return;
        }

        req = http_client.openRequest(.POST, uri, .{
            .extra_headers = headers,
            .accept_encoding = "identity",
        }) catch {
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                    retry_attempt += 1;
                    continue;
                }
                ctx.deinit();
                stream.completeWithError("request cancelled");
                return;
            }
            ctx.deinit();
            stream.completeWithError("request open failed");
            return;
        };
        req_initialized = true;

        compat.http.sendRequest(&req, request_body) catch {
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                    retry_attempt += 1;
                    continue;
                }
                ctx.deinit();
                stream.completeWithError("request cancelled");
                return;
            }
            ctx.deinit();
            stream.completeWithError("request send failed");
            return;
        };

        if (testCancelAt(cancel_token, .response_headers)) {
            ctx.deinit();
            stream.completeWithError("request cancelled");
            return;
        }

        response = compat.http.receiveResponse(&req, &head_buf) catch {
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                    retry_attempt += 1;
                    continue;
                }
                ctx.deinit();
                stream.completeWithError("request cancelled");
                return;
            }
            ctx.deinit();
            stream.completeWithError("response failed");
            return;
        };

        if (response.head.status == .ok) {
            break;
        }

        const status_code: u16 = @intFromEnum(response.head.status);
        const should_retry = retry_util.isRetryable(status_code) and retry_attempt < MAX_RETRIES;

        if (should_retry) {
            const error_text: []const u8 = &.{};

            const is_retryable_error = retry_util.isRetryableError(error_text);

            var delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);

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

            if (retry_util.extractRetryDelayFromBody(error_text)) |body_delay| {
                if (body_delay <= max_delay_ms) {
                    delay = body_delay;
                }
            }

            if (!is_retryable_error and !retry_util.isRetryable(status_code)) {
                break;
            }

            if (!retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                ctx.deinit();
                stream.completeWithError("request cancelled");
                return;
            }

            retry_attempt += 1;
            continue;
        }

        break;
    }

    if (response.head.status != .ok) {
        const status_code = @intFromEnum(response.head.status);
        if (last_error) |e| allocator.free(e);
        var error_transfer_buf: [4096]u8 = undefined;
        const error_reader = compat.http.responseReader(&response, &error_transfer_buf);
        const error_body = compat.http.allocRemainingResponse(allocator, error_reader, 8192) catch null;
        defer if (error_body) |body| allocator.free(body);
        const detail = if (error_body) |body| anthropicErrorDetail(allocator, body) catch null else null;
        defer if (detail) |text| allocator.free(text);
        last_error = std.fmt.allocPrint(allocator, "anthropic request failed: HTTP {d}{s}{s}", .{
            status_code,
            if (status_code == 401) " (check ANTHROPIC_API_KEY is valid)" else "",
            detail orelse "",
        }) catch null;

        ctx.deinit();
        stream.completeWithError(last_error orelse "anthropic request failed");
        return;
    }

    var parser = sse_parser.SSEParser.init(allocator);
    defer parser.deinit();

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = compat.http.responseReader(&response, &transfer_buf);

    const BlockInfo = struct {
        content_type: ParseResult.ContentType,
        content_index: usize,
    };
    var block_map = std.AutoHashMap(usize, BlockInfo).init(allocator);
    defer block_map.deinit();

    var tc_tracker = tool_call_tracker.ToolCallTracker.init(allocator);
    defer tc_tracker.deinit();

    var content_blocks = std.ArrayList(ai_types.AssistantContent).empty;
    defer {
        ai_types.deinitAssistantContentElements(allocator, content_blocks.items);
        content_blocks.deinit(allocator);
    }
    var current_text = std.ArrayList(u8).empty;
    defer current_text.deinit(allocator);
    var current_thinking = std.ArrayList(u8).empty;
    defer current_thinking.deinit(allocator);
    var current_thinking_signature = std.ArrayList(u8).empty;
    defer current_thinking_signature.deinit(allocator);

    var pending_delta_frees = std.ArrayList([]const u8).empty;
    defer {
        for (pending_delta_frees.items) |s| allocator.free(s);
        pending_delta_frees.deinit(allocator);
    }
    const stream_clones_events = stream.owns_events and stream.clone_event_fn != null;

    var raw_body = std.ArrayList(u8).empty;
    defer raw_body.deinit(allocator);

    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;

    var last_ping_time: i64 = 0;
    const ping_interval = ctx.ping_interval_ms orelse 0;

    const partial_start = createPartialMessage(model);
    _ = stream.pushBlocking(.{ .start = .{ .partial = partial_start } });

    while (true) {
        if (ping_interval > 0) {
            const now = compat.time.nowMillis();
            if (now - last_ping_time >= ping_interval) {
                stream.push(.{ .keepalive = {} }) catch {};
                last_ping_time = now;
            }
        }

        if (cancel_token) |ct| {
            if (ct.isCancelled()) {
                ctx.deinit();
                stream.completeWithError("request cancelled");
                return;
            }
        }

        if (testCancelAt(cancel_token, .between_sse_events)) {
            ctx.deinit();
            stream.completeWithError("request cancelled");
            return;
        }

        const n = compat.http.readResponse(reader, &read_buf) catch {
            ctx.deinit();
            stream.completeWithError("read error");
            return;
        };
        if (n == 0) break;

        if (testCancelAt(cancel_token, .mid_event_payload)) {
            ctx.deinit();
            stream.completeWithError("request cancelled");
            return;
        }

        if (raw_body.items.len < 8192) {
            const cap = 8192 - raw_body.items.len;
            raw_body.appendSlice(allocator, read_buf[0..@min(n, cap)]) catch {};
        }

        const events = parser.feed(read_buf[0..n]) catch |err| {
            ctx.deinit();
            stream.completeWithError(sse_parser.errorMessage(err));
            return;
        };

        for (events) |ev| {
            const result = parseAnthropicEventType(ev.data, allocator) catch {
                ctx.deinit();
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

                    switch (cbs.block_type) {
                        .text => {
                            current_text.clearRetainingCapacity();
                            const partial = createPartialMessage(model);
                            _ = stream.pushBlocking(.{ .text_start = .{ .content_index = content_idx, .partial = partial } });
                        },
                        .thinking => {
                            current_thinking.clearRetainingCapacity();
                            current_thinking_signature.clearRetainingCapacity();
                            const partial = createPartialMessage(model);
                            _ = stream.pushBlocking(.{ .thinking_start = .{ .content_index = content_idx, .partial = partial } });
                        },
                        .tool_use => {
                            _ = tc_tracker.startCall(cbs.index, content_idx, cbs.tool_id, cbs.tool_name) catch {};

                            _ = stream.pushBlocking(.{ .toolcall_start = .{
                                .content_index = content_idx,
                                .id = cbs.tool_id,
                                .name = cbs.tool_name,
                                .partial = createPartialMessage(model),
                            } });

                            retireDeltaSlice(allocator, &pending_delta_frees, stream_clones_events, cbs.tool_id);
                            retireDeltaSlice(allocator, &pending_delta_frees, stream_clones_events, cbs.tool_name);
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
                                _ = stream.pushBlocking(.{ .text_delta = .{ .content_index = block_info.content_index, .delta = txt, .partial = partial } });
                                retireDeltaSlice(allocator, &pending_delta_frees, stream_clones_events, txt);
                            },
                            .thinking => |thk| {
                                current_thinking.appendSlice(allocator, thk) catch {};
                                _ = stream.pushBlocking(.{ .thinking_delta = .{ .content_index = block_info.content_index, .delta = thk, .partial = partial } });
                                retireDeltaSlice(allocator, &pending_delta_frees, stream_clones_events, thk);
                            },
                            .signature => |sig| {
                                current_thinking_signature.appendSlice(allocator, sig) catch {};
                                allocator.free(sig);
                            },
                            .input_json => |json_delta| {
                                tc_tracker.appendDelta(cbd.index, json_delta) catch {};

                                if (tc_tracker.getContentIndex(cbd.index)) |content_idx| {
                                    _ = stream.pushBlocking(.{ .toolcall_delta = .{
                                        .content_index = content_idx,
                                        .delta = json_delta,
                                        .partial = createPartialMessage(model),
                                    } });
                                }
                                retireDeltaSlice(allocator, &pending_delta_frees, stream_clones_events, json_delta);
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
                                const text_copy = allocator.dupe(u8, current_text.items) catch {
                                    ctx.deinit();
                                    stream.completeWithError("oom text");
                                    return;
                                };
                                content_blocks.append(allocator, .{ .text = .{ .text = text_copy } }) catch {
                                    allocator.free(text_copy);
                                    ctx.deinit();
                                    stream.completeWithError("oom text");
                                    return;
                                };

                                _ = stream.pushBlocking(.{ .text_end = .{ .content_index = block_info.content_index, .content = current_text.items, .partial = partial } });
                            },
                            .thinking => {
                                const thinking_copy = allocator.dupe(u8, current_thinking.items) catch {
                                    ctx.deinit();
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
                                } }) catch {
                                    allocator.free(thinking_copy);
                                    if (sig_copy) |sig| allocator.free(sig);
                                    ctx.deinit();
                                    stream.completeWithError("oom thinking");
                                    return;
                                };

                                _ = stream.pushBlocking(.{ .thinking_end = .{ .content_index = block_info.content_index, .content = current_thinking.items, .partial = partial } });
                            },
                            .tool_use => {
                                if (tc_tracker.completeCall(cbs.index, allocator)) |tool_call| {
                                    content_blocks.append(allocator, .{ .tool_call = tool_call }) catch {
                                        var orphan = tool_call;
                                        ai_types.deinitToolCall(allocator, &orphan);
                                        ctx.deinit();
                                        stream.completeWithError("oom tool call");
                                        return;
                                    };

                                    _ = stream.pushBlocking(.{ .toolcall_end = .{
                                        .content_index = content_blocks.items.len - 1,
                                        .tool_call = tool_call,
                                        .partial = createPartialMessage(model),
                                    } });
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
                    stream.completeWithError(err);
                    return;
                },
            }
        }
    }

    {
        const tail = parser.feed("\n\n") catch |err| {
            ctx.deinit();
            stream.completeWithError(sse_parser.errorMessage(err));
            return;
        };
        for (tail) |ev| {
            const result = parseAnthropicEventType(ev.data, allocator) catch continue;
            defer result.deinit(allocator);
            if (result == .api_error) {
                ctx.deinit();
                stream.completeWithError(result.api_error);
                return;
            }
        }
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output;
    usage.calculateCost(model.cost);

    if (content_blocks.items.len == 0 and current_text.items.len > 0) {
        const text_copy = allocator.dupe(u8, current_text.items) catch {
            ctx.deinit();
            stream.completeWithError("oom text");
            return;
        };
        content_blocks.append(allocator, .{ .text = .{ .text = text_copy } }) catch {
            allocator.free(text_copy);
            ctx.deinit();
            stream.completeWithError("oom text");
            return;
        };
    }

    if (content_blocks.items.len == 0) {
        var err_text: []const u8 = "anthropic returned empty response with no content blocks";
        var err_owned: ?[]u8 = null;
        defer if (err_owned) |e| allocator.free(e);

        if (raw_body.items.len > 0) {
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

            if (err_owned == null) {
                err_owned = std.fmt.allocPrint(allocator, "anthropic: empty response ({d} raw bytes, no SSE events)", .{raw_body.items.len}) catch null;
                if (err_owned) |e| err_text = e;
            }
        }

        ctx.deinit();
        stream.completeWithError(err_text);
        return;
    }

    const content_slice = content_blocks.toOwnedSlice(allocator) catch {
        ctx.deinit();
        stream.completeWithError("oom content");
        return;
    };

    const out = ai_types.AssistantMessage{
        .content = content_slice,
        .api = allocator.dupe(u8, model.api) catch {
            ctx.deinit();
            stream.completeWithError("oom");
            return;
        },
        .provider = allocator.dupe(u8, model.provider) catch {
            ctx.deinit();
            stream.completeWithError("oom");
            return;
        },
        .model = allocator.dupe(u8, model.id) catch {
            ctx.deinit();
            stream.completeWithError("oom");
            return;
        },
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp = compat.time.nowMillis(),
        .is_owned = true,
    };

    ctx.deinit();

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
        if (o.getApiKey()) |k| {
            if (k.len > 0) break :blk try allocator.dupe(u8, k);
        }
        if (envApiKeyForProvider(allocator, model.provider)) |k| {
            if (k.len > 0) break :blk @constCast(k);
            allocator.free(k);
        }
        if (allowsAnonymous(model)) break :blk try allocator.dupe(u8, "");
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    const owned_model = try ai_types.cloneModel(allocator, model);
    errdefer {
        var mut_m = owned_model;
        mut_m.deinit(allocator);
    }

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

    var thinking_enabled: bool = false;
    var thinking_budget_tokens: ?u32 = null;
    var thinking_effort: ?[]const u8 = null;

    if (model.reasoning) {
        if (o.reasoning) |level| {
            thinking_enabled = true;
            if (supportsAdaptiveThinking(model.id)) {
                thinking_effort = mapThinkingLevelToEffort(level);
            } else {
                const max_tokens = o.max_tokens orelse model.max_tokens;
                if (level != .off and max_tokens > 1024) {
                    thinking_budget_tokens = @max(1024, @min(getDefaultThinkingBudget(level, o.thinking_budgets), max_tokens - 1));
                } else {
                    thinking_enabled = false;
                }
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

fn anthropicErrorDetail(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const err_value = parsed.value.object.get("error") orelse return null;
    if (err_value != .object) return null;
    const message = err_value.object.get("message") orelse return null;
    if (message != .string or message.string.len == 0) return null;
    const kind = err_value.object.get("type");
    if (kind != null and kind.? == .string and kind.?.string.len > 0) {
        return try std.fmt.allocPrint(allocator, " ({s}: {s})", .{ kind.?.string, message.string });
    }
    return try std.fmt.allocPrint(allocator, " ({s})", .{message.string});
}

test "anonymous streaming is opt-in and never applies to the anthropic vendor id" {
    const base: ai_types.Model = .{
        .id = "m",
        .name = "M",
        .api = "anthropic-messages",
        .provider = "gateway",
        .base_url = "https://gw.test",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1000,
        .max_tokens = 100,
    };
    try std.testing.expect(!allowsAnonymous(base));

    var opted = base;
    opted.allows_anonymous = true;
    try std.testing.expect(allowsAnonymous(opted));

    var vendor = opted;
    vendor.provider = "anthropic";
    try std.testing.expect(!allowsAnonymous(vendor));
}

test "anthropic headers carry no credential when the key is empty" {
    var out = try buildAnthropicHeaders(std.testing.allocator, "", null);
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(!compat.http.headerPresent(out.headers.items, "x-api-key"));
    try std.testing.expect(!compat.http.headerPresent(out.headers.items, "authorization"));
    try std.testing.expect(compat.http.headerPresent(out.headers.items, "anthropic-version"));
    try std.testing.expect(compat.http.headerPresent(out.headers.items, "content-type"));

    var keyed = try buildAnthropicHeaders(std.testing.allocator, "sk-ant-plain", null);
    defer keyed.deinit(std.testing.allocator);
    try std.testing.expect(compat.http.headerPresent(keyed.headers.items, "x-api-key"));
}

test "buildUrlWithSuffix does not double a suffix already present" {
    const doubled = try buildUrlWithSuffix(std.testing.allocator, "https://api.anthropic.com/v1/messages", "/v1/messages");
    defer std.testing.allocator.free(doubled);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", doubled);
    const plain = try buildUrlWithSuffix(std.testing.allocator, "https://api.anthropic.com/", "/v1/messages");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("https://api.anthropic.com//v1/messages", plain);
    const bare = try buildUrlWithSuffix(std.testing.allocator, "https://api.anthropic.com", "/v1/messages");
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", bare);
}

test "anthropicErrorDetail surfaces the API error type and message" {
    const detail = (try anthropicErrorDetail(std.testing.allocator, "{\"type\":\"error\",\"error\":{\"type\":\"not_found_error\",\"message\":\"model: claude-sonnet-5\"}}")).?;
    defer std.testing.allocator.free(detail);
    try std.testing.expectEqualStrings(" (not_found_error: model: claude-sonnet-5)", detail);
    try std.testing.expect((try anthropicErrorDetail(std.testing.allocator, "<html>oops</html>")) == null);
    try std.testing.expect((try anthropicErrorDetail(std.testing.allocator, "{\"error\":\"plain\"}")) == null);
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
    const result = getCacheControl("https://api.anthropic.com", .none, false);
    try std.testing.expect(result == null);
}

test "getCacheControl returns short retention without ttl for non-anthropic url" {
    const result = getCacheControl("https://custom.api.com", .short, false);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(ai_types.CacheRetention.short, result.?.retention);
    try std.testing.expectEqual(false, result.?.has_ttl);
}

test "getCacheControl returns long retention with ttl for anthropic url" {
    const result = getCacheControl("https://api.anthropic.com", .long, false);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(ai_types.CacheRetention.long, result.?.retention);
    try std.testing.expectEqual(true, result.?.has_ttl);
}

test "getCacheControl returns long retention without ttl for non-anthropic url" {
    const result = getCacheControl("https://custom.api.com", .long, false);
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

    try std.testing.expect(std.mem.find(u8, body, "\"system\":[") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"ttl\"") == null);
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

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const msg_array = parsed.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 3), msg_array.items.len);

    const tool_result_msg = msg_array.items[2];
    try std.testing.expectEqualStrings("user", tool_result_msg.object.get("role").?.string);

    const content = tool_result_msg.object.get("content").?;
    try std.testing.expect(content == .array);
    try std.testing.expectEqual(@as(usize, 1), content.array.items.len);

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

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const msg_array = parsed.value.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 3), msg_array.items.len);

    try std.testing.expect(msg_array.items[0].object.get("content").? == .string);

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

    allocator.free(result.content_block_start.tool_id);
    allocator.free(result.content_block_start.tool_name);
}

test "a parse result frees every string it duped, so an event nothing consumes cannot leak" {
    const allocator = std.testing.allocator;

    const owning_events = [_][]const u8{
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":" ++
            "{\"type\":\"tool_use\",\"id\":\"toolu_01A\",\"name\":\"bash\"}}",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":" ++
            "{\"type\":\"text_delta\",\"text\":\"a slice long enough to be a real allocation\"}}",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":" ++
            "{\"type\":\"thinking_delta\",\"thinking\":\"a slice long enough to be a real allocation\"}}",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":" ++
            "{\"type\":\"signature_delta\",\"signature\":\"a slice long enough to be a real allocation\"}}",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":" ++
            "{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"long enough\\\"}\"}}",
        "{\"type\":\"error\",\"error\":{\"message\":\"a message long enough to be a real allocation\"}}",
    };

    for (owning_events) |data| {
        const result = try parseAnthropicEventType(data, allocator);
        try std.testing.expect(result != .none);
        result.deinit(allocator);
    }

    const borrowing_events = [_][]const u8{
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}",
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\"}}",
        "{\"type\":\"content_block_stop\",\"index\":0}",
        "{\"type\":\"message_stop\"}",
    };

    for (borrowing_events) |data| {
        const result = try parseAnthropicEventType(data, allocator);
        result.deinit(allocator);
    }
}

const MockAnthropicServer = struct {
    server: compat.net.Server,
    body: []const u8,
    thread: ?std.Thread = null,
    served: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_messages_path: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const sse_events =
        \\event: message_start
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":3,"output_tokens":0}}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01LEAKCHECK","name":"bash"}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"ls\"}"}}
        \\
        \\event: content_block_stop
        \\data: {"type":"content_block_stop","index":0}
        \\
        \\event: message_delta
        \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}
        \\
        \\event: message_stop
        \\data: {"type":"message_stop"}
    ;
    const truncated_events =
        \\event: message_start
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":3,"output_tokens":0}}}
        \\
        \\event: content_block_start
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01LEAKCHECK","name":"bash"}}
        \\
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls\"}"}}
    ;

    const complete_stream = sse_events ++ "\n\n";
    const truncated_stream = truncated_events;

    fn listen(body: []const u8) !MockAnthropicServer {
        const address = try compat.net.resolveAddress(std.testing.allocator, "127.0.0.1", 0);
        return .{
            .server = try compat.net.tcpListen(address, .{ .reuse_address = true }),
            .body = body,
        };
    }

    fn baseUrl(self: *const MockAnthropicServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{compat.net.listenAddress(&self.server).getPort()});
    }

    fn start(self: *MockAnthropicServer) !void {
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn stop(self: *MockAnthropicServer) void {
        if (self.thread) |thread| {
            if (!self.served.load(.acquire)) {
                if (compat.net.tcpConnect(compat.net.listenAddress(&self.server))) |opened| {
                    var kick = opened;
                    kick.close();
                } else |_| {}
            }
            thread.join();
            self.thread = null;
        }
        compat.net.closeServer(&self.server);
    }

    fn contentLength(head: []const u8) ?usize {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        while (lines.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                return std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \t"), 10) catch null;
            }
        }
        return null;
    }

    fn readHead(stream: *compat.net.Stream, buffer: []u8) !usize {
        var filled: usize = 0;
        while (filled < buffer.len) {
            const read = try stream.read(buffer[filled .. filled + 1]);
            if (read == 0) return error.EndOfStream;
            filled += read;
            if (filled >= 4 and std.mem.eql(u8, buffer[filled - 4 .. filled], "\r\n\r\n")) return filled - 4;
        }
        return error.StreamTooLong;
    }

    fn serve(self: *MockAnthropicServer) void {
        defer self.served.store(true, .release);

        var conn = compat.net.accept(&self.server) catch return;
        defer conn.stream.close();

        var request: [16384]u8 = undefined;
        const head_len = readHead(&conn.stream, &request) catch return;
        const head = request[0..head_len];

        if (contentLength(head)) |length| {
            if (length > 0 and length <= request.len) {
                var body: [16384]u8 = undefined;
                _ = conn.stream.read(body[0..length]) catch return;
            }
        }

        if (std.mem.indexOf(u8, head, "POST /v1/messages ") != null) {
            self.saw_messages_path.store(true, .release);
        }

        var head_buffer: [128]u8 = undefined;
        const response_head = std.fmt.bufPrint(
            &head_buffer,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{self.body.len},
        ) catch return;

        conn.stream.writeAll(response_head) catch return;
        conn.stream.writeAll(self.body) catch return;
    }
};

test "a streamed tool call frees the id and name it hands the consumer, cloned or borrowed" {
    const allocator = std.testing.allocator;

    for ([_]bool{ false, true }) |owned_events| {
        var mock = try MockAnthropicServer.listen(MockAnthropicServer.complete_stream);
        var stopped = false;
        defer if (!stopped) mock.stop();

        const base_url = try mock.baseUrl(allocator);
        defer allocator.free(base_url);

        try mock.start();

        const stream = try streamAnthropicMessages(
            regressionModel("anthropic-messages", "anthropic", base_url),
            regressionContext(),
            .{
                .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key"),
                .requires_owned_stream_events = owned_events,
            },
            allocator,
        );
        defer {
            stream.deinit();
            allocator.destroy(stream);
        }

        var tool_calls_started: usize = 0;
        while (stream.wait()) |event| {
            var polled = event;
            defer if (owned_events) ai_types.deinitAssistantMessageEvent(allocator, &polled);
            if (polled != .toolcall_start) continue;
            tool_calls_started += 1;
            if (owned_events) {
                try std.testing.expectEqualStrings("toolu_01LEAKCHECK", polled.toolcall_start.id);
                try std.testing.expectEqualStrings("bash", polled.toolcall_start.name);
            }
        }

        try std.testing.expect(stream.waitForThread(5_000));
        mock.stop();
        stopped = true;

        try std.testing.expect(mock.saw_messages_path.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), tool_calls_started);
        try std.testing.expect(stream.getError() == null);

        const result = stream.getResult() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), result.content.len);
        try std.testing.expectEqualStrings("toolu_01LEAKCHECK", result.content[0].tool_call.id);
        try std.testing.expectEqualStrings("bash", result.content[0].tool_call.name);
        try std.testing.expectEqualStrings("{\"command\":\"ls\"}", result.content[0].tool_call.arguments_json);
    }
}

test "a response ending mid event frees what the tail flush parses and drops" {
    const allocator = std.testing.allocator;

    var mock = try MockAnthropicServer.listen(MockAnthropicServer.truncated_stream);
    var stopped = false;
    defer if (!stopped) mock.stop();

    const base_url = try mock.baseUrl(allocator);
    defer allocator.free(base_url);

    try mock.start();

    const stream = try streamAnthropicMessages(
        regressionModel("anthropic-messages", "anthropic", base_url),
        regressionContext(),
        .{
            .api_key = ai_types.OwnedSlice(u8).initBorrowed("test-key"),
            .requires_owned_stream_events = true,
        },
        allocator,
    );
    defer {
        stream.deinit();
        allocator.destroy(stream);
    }

    var tool_calls_started: usize = 0;
    while (stream.wait()) |event| {
        var owned = event;
        defer ai_types.deinitAssistantMessageEvent(allocator, &owned);
        if (owned == .toolcall_start) tool_calls_started += 1;
    }

    try std.testing.expect(stream.waitForThread(5_000));
    mock.stop();
    stopped = true;

    try std.testing.expect(mock.saw_messages_path.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), tool_calls_started);
    try std.testing.expect(stream.getError() != null);
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

test "anthropic model headers are forwarded and never shadow a built-in" {
    var header_set = try buildAnthropicHeaders(std.testing.allocator, "sk-ant-api-test", &.{
        .{ .name = "X-Tenant", .value = "acme" },
        .{ .name = "Anthropic-Version", .value = "1999-01-01" },
    });
    defer header_set.deinit(std.testing.allocator);

    var tenant: ?[]const u8 = null;
    var version_count: usize = 0;
    for (header_set.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-tenant")) tenant = header.value;
        if (std.ascii.eqlIgnoreCase(header.name, "anthropic-version")) {
            version_count += 1;
            try std.testing.expectEqualStrings("2023-06-01", header.value);
        }
    }
    try std.testing.expectEqualStrings("acme", tenant.?);
    try std.testing.expectEqual(@as(usize, 1), version_count);
}

test "the anthropic env key never resolves for another provider id" {
    const allocator = std.testing.allocator;

    try std.testing.expect(envApiKeyForProvider(allocator, "gateway") == null);
    try std.testing.expect(envApiKeyForProvider(allocator, "openai-codex") == null);
    try std.testing.expect(envApiKeyForProvider(allocator, "") == null);
    try std.testing.expect(envApiKeyForProvider(allocator, "anthropic-gateway") == null);
}

test "anthropic_api_key_headers_are_forwarded_exactly" {
    var header_set = try buildAnthropicHeaders(std.testing.allocator, "sk-ant-api-test", null);
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
    var header_set = try buildAnthropicHeaders(std.testing.allocator, "sk-ant-oat-test", null);
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
