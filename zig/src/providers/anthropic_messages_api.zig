const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");
const tool_call_tracker = @import("tool_call_tracker");

fn envApiKey(allocator: std.mem.Allocator) ?[]const u8 {
    // Support both OAuth tokens (sk-ant-oat) and API keys (sk-ant-api)
    // Check ANTHROPIC_AUTH_TOKEN first (OAuth), then ANTHROPIC_API_KEY
    if (std.process.getEnvVarOwned(allocator, "ANTHROPIC_AUTH_TOKEN")) |key| return key else |_| {}
    if (std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY")) |key| return key else |_| {}
    return null;
}

fn isOAuthToken(key: []const u8) bool {
    return std.mem.indexOf(u8, key, "sk-ant-oat") != null;
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
    const has_ttl = retention == .long and std.mem.indexOf(u8, base_url, "api.anthropic.com") != null;

    return .{
        .retention = retention,
        .has_ttl = has_ttl,
    };
}

/// Check if a model supports adaptive thinking (Opus 4.6+)
fn supportsAdaptiveThinking(model_id: []const u8) bool {
    return std.mem.indexOf(u8, model_id, "opus-4-6") != null or
           std.mem.indexOf(u8, model_id, "opus-4.6") != null;
}

/// Map ThinkingLevel to Anthropic effort levels for adaptive thinking
fn mapThinkingLevelToEffort(level: ai_types.ThinkingLevel) []const u8 {
    return switch (level) {
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
            .minimal => b.minimal orelse 256,
            .low => b.low orelse 512,
            .medium => b.medium orelse 1024,
            .high => b.high orelse 2048,
            .xhigh => 4096,
        };
    }
    return switch (level) {
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

fn buildRequestBody(model: ai_types.Model, context: ai_types.Context, options: ai_types.StreamOptions, allocator: std.mem.Allocator, is_oauth: bool) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

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
    if (context.system_prompt) |sp| {
        try w.writeKey("system");
        try w.beginArray();

        try w.beginObject();
        try w.writeStringField("type", "text");
        if (is_oauth) {
            // Prepend Claude Code identity for OAuth
            const full_prompt = try std.fmt.allocPrint(allocator, "You are Claude Code, Anthropic's official CLI for Claude.\n\n{s}", .{sp});
            defer allocator.free(full_prompt);
            try w.writeStringField("text", full_prompt);
        } else {
            try w.writeStringField("text", sp);
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

    // Find the last user message index for cache_control placement
    var last_user_idx: ?usize = null;
    for (context.messages, 0..) |m, i| {
        switch (m) {
            .user => last_user_idx = i,
            else => {},
        }
    }

    try w.writeKey("messages");
    try w.beginArray();
    for (context.messages, 0..) |m, msg_idx| {
        const role: []const u8 = switch (m) {
            .assistant => "assistant",
            else => "user",
        };

        const is_last_user = last_user_idx != null and msg_idx == last_user_idx.?;

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
                        try w.writeStringField("text", t.text);
                        try w.endObject();
                    },
                    .thinking => |t| {
                        try w.beginObject();
                        try w.writeStringField("type", "thinking");
                        try w.writeStringField("thinking", t.thinking);
                        try w.endObject();
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
                }
            }

            try w.endArray();
            try w.endObject();
        } else if (m == .tool_result) {
            // Tool result messages must be serialized as user messages with tool_result content blocks
            const tr = m.tool_result;

            try w.beginObject();
            try w.writeStringField("role", "user");
            try w.writeKey("content");
            try w.beginArray();

            try w.beginObject();
            try w.writeStringField("type", "tool_result");
            try w.writeStringField("tool_use_id", tr.tool_call_id);

            // Serialize content - can be a string or array of content blocks
            // For simplicity, extract text content and serialize as string
            var text = std.ArrayList(u8){};
            defer text.deinit(allocator);
            for (tr.content) |c| switch (c) {
                .text => |t| {
                    if (text.items.len > 0) try text.append(allocator, '\n');
                    try text.appendSlice(allocator, t.text);
                },
                .image => {},
            };

            try w.writeStringField("content", text.items);
            try w.writeBoolField("is_error", tr.is_error);
            try w.endObject();

            try w.endArray();
            try w.endObject();
        } else if (is_last_user and cache_control != null) {
            // For the last user message with cache_control, use content array format
            var text = std.ArrayList(u8){};
            defer text.deinit(allocator);
            try appendMessageText(m, &text, allocator);

            try w.beginObject();
            try w.writeStringField("role", role);
            try w.writeKey("content");
            try w.beginArray();

            // Text block with cache_control
            try w.beginObject();
            try w.writeStringField("type", "text");
            try w.writeStringField("text", text.items);
            try w.writeKey("cache_control");
            try w.beginObject();
            try w.writeStringField("type", "ephemeral");
            if (cache_control.?.has_ttl) {
                try w.writeStringField("ttl", "1h");
            }
            try w.endObject();
            try w.endObject();

            try w.endArray();
            try w.endObject();
        } else {
            // Standard message serialization
            var text = std.ArrayList(u8){};
            defer text.deinit(allocator);
            try appendMessageText(m, &text, allocator);

            try w.beginObject();
            try w.writeStringField("role", role);
            try w.writeStringField("content", text.items);
            try w.endObject();
        }
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

    // Configure thinking mode: adaptive (Opus 4.6+) or budget-based (older models)
    if (options.thinking_enabled) {
        if (supportsAdaptiveThinking(model.id)) {
            // Adaptive thinking: Claude decides when and how much to think
            try w.writeKey("thinking");
            try w.beginObject();
            try w.writeStringField("type", "adaptive");
            try w.endObject();

            if (options.thinking_effort) |effort| {
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
                if (v == .string) return .{ .content_block_delta = .{ .index = index, .delta = .{ .text = v.string } } };
            }
        } else if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
            if (delta_val.object.get("thinking")) |v| {
                if (v == .string) return .{ .content_block_delta = .{ .index = index, .delta = .{ .thinking = v.string } } };
            }
        } else if (std.mem.eql(u8, delta_type.string, "signature_delta")) {
            if (delta_val.object.get("signature")) |v| {
                if (v == .string) return .{ .content_block_delta = .{ .index = index, .delta = .{ .signature = v.string } } };
            }
        } else if (std.mem.eql(u8, delta_type.string, "input_json_delta")) {
            if (delta_val.object.get("partial_json")) |v| {
                if (v == .string) return .{ .content_block_delta = .{ .index = index, .delta = .{ .input_json = v.string } } };
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
                        if (std.mem.eql(u8, sr.string, "max_tokens")) stop_reason = .length
                        else if (std.mem.eql(u8, sr.string, "tool_use")) stop_reason = .tool_use
                        else stop_reason = .stop;
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

    return .{ .none = {} };
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    api_key: []u8,
    request_body: []u8,
};

fn runThread(ctx: *ThreadCtx) void {
    // Save values from ctx that we need after freeing ctx
    const allocator = ctx.allocator;
    const stream = ctx.stream;
    const model = ctx.model;
    const api_key = ctx.api_key;
    const request_body = ctx.request_body;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(allocator, "{s}/v1/messages", .{model.base_url}) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom building url");
        return;
    };
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("invalid anthropic URL");
        return;
    };

    const is_oauth = isOAuthToken(api_key);

    // Allocate auth header for OAuth tokens (needs to persist until after request)
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |h| allocator.free(h);

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);

    // OAuth tokens use Authorization: Bearer, API keys use x-api-key
    if (is_oauth) {
        auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom auth header");
            return;
        };
        headers.append(allocator, .{ .name = "authorization", .value = auth_header.? }) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom headers");
            return;
        };
        // OAuth-specific headers (mimic Claude Code)
        headers.append(allocator, .{ .name = "anthropic-beta", .value = "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14" }) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom headers");
            return;
        };
        headers.append(allocator, .{ .name = "anthropic-dangerous-direct-browser-access", .value = "true" }) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom headers");
            return;
        };
        headers.append(allocator, .{ .name = "user-agent", .value = "claude-cli/2.1.2 (external, cli)" }) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom headers");
            return;
        };
        headers.append(allocator, .{ .name = "x-app", .value = "cli" }) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom headers");
            return;
        };
    } else {
        headers.append(allocator, .{ .name = "x-api-key", .value = api_key }) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom headers");
            return;
        };
        // Add beta headers for fine-grained tool streaming and interleaved thinking
        headers.append(allocator, .{ .name = "anthropic-beta", .value = "fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14" }) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom headers");
            return;
        };
    }

    headers.append(allocator, .{ .name = "anthropic-version", .value = "2023-06-01" }) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom headers");
        return;
    };
    headers.append(allocator, .{ .name = "content-type", .value = "application/json" }) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom headers");
        return;
    };

    var req = client.request(.POST, uri, .{ .extra_headers = headers.items }) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("request open failed");
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = request_body.len };
    req.sendBodyComplete(request_body) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("request send failed");
        return;
    };

    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("response failed");
        return;
    };

    if (response.head.status != .ok) {
        const status_code = @intFromEnum(response.head.status);
        const err = std.fmt.allocPrint(allocator, "anthropic request failed: HTTP {d}{s}", .{
            status_code,
            if (status_code == 401) " (check ANTHROPIC_API_KEY is valid)" else "",
        }) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("anthropic request failed");
            return;
        };
        defer allocator.free(err);
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError(err);
        return;
    }

    var parser = sse_parser.SSEParser.init(allocator);
    defer parser.deinit();

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

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
    var content_blocks = std.ArrayList(ai_types.AssistantContent){};
    defer content_blocks.deinit(allocator);
    var current_text = std.ArrayList(u8){};
    defer current_text.deinit(allocator);
    var current_thinking = std.ArrayList(u8){};
    defer current_thinking.deinit(allocator);
    var current_thinking_signature = std.ArrayList(u8){};
    defer current_thinking_signature.deinit(allocator);

    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;

    // Emit start event with partial message
    const partial_start = createPartialMessage(model);
    stream.push(.{ .start = .{ .partial = partial_start } }) catch {};

    while (true) {
        const n = reader.*.readSliceShort(&read_buf) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("read error");
            return;
        };
        if (n == 0) break;

        const events = parser.feed(read_buf[0..n]) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("sse parse error");
            return;
        };

        for (events) |ev| {
            const result = parseAnthropicEventType(ev.data, allocator) catch {
                allocator.free(api_key);
                allocator.free(request_body);
                allocator.destroy(ctx);
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
                            // Free the duped strings from parseAnthropicEventType
                            allocator.free(cbs.tool_id);
                            allocator.free(cbs.tool_name);

                            stream.push(.{ .toolcall_start = .{
                                .content_index = content_idx,
                                .partial = createPartialMessage(model),
                            }}) catch {};
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
                            },
                            .thinking => |thk| {
                                current_thinking.appendSlice(allocator, thk) catch {};
                                stream.push(.{ .thinking_delta = .{ .content_index = block_info.content_index, .delta = thk, .partial = partial } }) catch {};
                            },
                            .signature => |sig| {
                                current_thinking_signature.appendSlice(allocator, sig) catch {};
                            },
                            .input_json => |json_delta| {
                                tc_tracker.appendDelta(cbd.index, json_delta) catch {};

                                if (tc_tracker.getContentIndex(cbd.index)) |content_idx| {
                                    stream.push(.{ .toolcall_delta = .{
                                        .content_index = content_idx,
                                        .delta = json_delta,
                                        .partial = createPartialMessage(model),
                                    }}) catch {};
                                }
                            },
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
                                    allocator.free(api_key);
                                    allocator.free(request_body);
                                    allocator.destroy(ctx);
                                    stream.completeWithError("oom text");
                                    return;
                                };
                                content_blocks.append(allocator, .{ .text = .{ .text = text_copy } }) catch {};

                                stream.push(.{ .text_end = .{ .content_index = block_info.content_index, .content = current_text.items, .partial = partial } }) catch {};
                            },
                            .thinking => {
                                // Store the completed thinking block
                                const thinking_copy = allocator.dupe(u8, current_thinking.items) catch {
                                    allocator.free(api_key);
                                    allocator.free(request_body);
                                    allocator.destroy(ctx);
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
                                    }}) catch {};
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
            }
        }
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output;
    usage.calculateCost(model.cost);

    // If no content blocks were collected but we have text, create a text block
    if (content_blocks.items.len == 0 and current_text.items.len > 0) {
        const text_copy = allocator.dupe(u8, current_text.items) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom text");
            return;
        };
        content_blocks.append(allocator, .{ .text = .{ .text = text_copy } }) catch {};
    }

    // If still no content, add an empty text block
    if (content_blocks.items.len == 0) {
        content_blocks.append(allocator, .{ .text = .{ .text = "" } }) catch {};
    }

    const content_slice = content_blocks.toOwnedSlice(allocator) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom content");
        return;
    };

    const out = ai_types.AssistantMessage{
        .content = content_slice,
        .api = allocator.dupe(u8, model.api) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom");
            return;
        },
        .provider = allocator.dupe(u8, model.provider) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom");
            return;
        },
        .model = allocator.dupe(u8, model.id) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom");
            return;
        },
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp = std.time.milliTimestamp(),
        .owned_strings = true, // Strings were duped above
    };

    stream.push(.{ .done = .{ .reason = stop_reason, .message = out } }) catch {};

    // Free ctx allocations before completing
    allocator.free(api_key);
    allocator.free(request_body);
    allocator.destroy(ctx);

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
        .timestamp = std.time.milliTimestamp(),
    };
}

pub fn streamAnthropicMessages(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    const api_key: []u8 = blk: {
        if (o.api_key) |k| break :blk try allocator.dupe(u8, k);
        const env = envApiKey(allocator);
        if (env) |k| break :blk @constCast(k);
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    const is_oauth = isOAuthToken(api_key);
    const body = try buildRequestBody(model, context, o, allocator, is_oauth);
    errdefer allocator.free(body);

    const s = try allocator.create(ai_types.AssistantMessageEventStream);
    errdefer allocator.destroy(s);
    s.* = ai_types.AssistantMessageEventStream.init(allocator);

    const ctx = try allocator.create(ThreadCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .stream = s,
        .model = model,
        .api_key = api_key,
        .request_body = body,
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
) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};

    // Build thinking options based on reasoning level and model capabilities
    var thinking_enabled: bool = false;
    var thinking_budget_tokens: ?u32 = null;
    var thinking_effort: ?[]const u8 = null;

    if (o.reasoning) |level| {
        thinking_enabled = true;
        if (supportsAdaptiveThinking(model.id)) {
            // Adaptive thinking: use effort level
            thinking_effort = mapThinkingLevelToEffort(level);
        } else {
            // Budget-based thinking for older models
            thinking_budget_tokens = getDefaultThinkingBudget(level, o.thinking_budgets);
        }
    }

    return streamAnthropicMessages(model, context, .{
        .temperature = o.temperature,
        .max_tokens = o.max_tokens,
        .api_key = o.api_key,
        .cache_retention = o.cache_retention,
        .session_id = o.session_id,
        .headers = o.headers,
        .retry = o.retry,
        .cancel_token = o.cancel_token,
        .on_payload_fn = o.on_payload_fn,
        .on_payload_ctx = o.on_payload_ctx,
        .thinking_enabled = thinking_enabled,
        .thinking_budget_tokens = thinking_budget_tokens,
        .thinking_effort = thinking_effort,
    }, allocator);
}

pub fn registerAnthropicMessagesApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "anthropic-messages",
        .stream = streamAnthropicMessages,
        .stream_simple = streamSimpleAnthropicMessages,
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
        .system_prompt = "You are a helpful assistant.",
        .messages = &messages,
    };

    const options = ai_types.StreamOptions{
        .max_tokens = 1024,
        .cache_retention = .short,
    };

    const body = try buildRequestBody(model, context, options, allocator, false);
    defer allocator.free(body);

    // Verify system prompt is an array with cache_control
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ttl\"") == null); // short retention, no ttl
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
        .system_prompt = "You are a helpful assistant.",
        .messages = &messages,
    };

    const options = ai_types.StreamOptions{
        .max_tokens = 1024,
        .cache_retention = .long,
    };

    const body = try buildRequestBody(model, context, options, allocator, false);
    defer allocator.free(body);

    // Verify ttl is included for long retention
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}") != null);
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
        .system_prompt = "You are a helpful assistant.",
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
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_error\":true") != null);
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
        .system_prompt = "You are a helpful assistant.",
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
