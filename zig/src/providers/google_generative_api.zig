const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");

fn env(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

// Model detection helpers
fn isGemini3ProModel(model_id: []const u8) bool {
    return std.mem.indexOf(u8, model_id, "3-pro") != null;
}

fn isGemini3FlashModel(model_id: []const u8) bool {
    return std.mem.indexOf(u8, model_id, "3-flash") != null;
}

fn isGemini25ProModel(model_id: []const u8) bool {
    return std.mem.indexOf(u8, model_id, "2.5-pro") != null;
}

fn isGemini25FlashModel(model_id: []const u8) bool {
    return std.mem.indexOf(u8, model_id, "2.5-flash") != null;
}

/// Map ThinkingLevel to Google thinking level string (for Gemini 3)
fn getGemini3ThinkingLevel(level: ai_types.ThinkingLevel, model: ai_types.Model) []const u8 {
    if (isGemini3ProModel(model.id)) {
        return switch (level) {
            .minimal, .low => "LOW",
            .medium, .high, .xhigh => "HIGH",
        };
    }
    // Gemini 3 Flash supports MINIMAL, LOW, MEDIUM, HIGH
    return switch (level) {
        .minimal => "MINIMAL",
        .low => "LOW",
        .medium => "MEDIUM",
        .high, .xhigh => "HIGH",
    };
}

/// Get default thinking budget for Gemini 2.5 models
fn getGoogleBudget(level: ai_types.ThinkingLevel, budgets: ?ai_types.ThinkingBudgets, model_id: []const u8) i32 {
    if (budgets) |b| {
        return switch (level) {
            .minimal => if (b.minimal) |v| @intCast(v) else -1,
            .low => if (b.low) |v| @intCast(v) else -1,
            .medium => if (b.medium) |v| @intCast(v) else -1,
            .high => if (b.high) |v| @intCast(v) else -1,
            .xhigh => -1,
        };
    }

    if (isGemini25ProModel(model_id)) {
        return switch (level) {
            .minimal => 128,
            .low => 2048,
            .medium => 8192,
            .high, .xhigh => 32768,
        };
    }

    if (isGemini25FlashModel(model_id)) {
        return switch (level) {
            .minimal => 128,
            .low => 2048,
            .medium => 8192,
            .high, .xhigh => 24576,
        };
    }

    return -1;
}

fn buildBody(context: ai_types.Context, options: ai_types.StreamOptions, model: ai_types.Model, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();

    try w.writeKey("contents");
    try w.beginArray();
    for (context.messages) |m| {
        const role: []const u8 = switch (m) {
            .assistant => "model",
            else => "user",
        };

        try w.beginObject();
        try w.writeStringField("role", role);
        try w.writeKey("parts");
        try w.beginArray();

        switch (m) {
            .user => |u| switch (u.content) {
                .text => |t| {
                    try w.beginObject();
                    try w.writeStringField("text", t);
                    try w.endObject();
                },
                .parts => |parts| {
                    for (parts) |p| switch (p) {
                        .text => |t| {
                            try w.beginObject();
                            try w.writeStringField("text", t.text);
                            try w.endObject();
                        },
                        .image => |img| {
                            try w.beginObject();
                            try w.writeKey("inlineData");
                            try w.beginObject();
                            try w.writeStringField("mimeType", img.mime_type);
                            try w.writeStringField("data", img.data);
                            try w.endObject();
                            try w.endObject();
                        },
                    };
                },
            },
            .assistant => |a| {
                for (a.content) |c| switch (c) {
                    .text => |t| {
                        if (t.text.len > 0) {
                            try w.beginObject();
                            try w.writeStringField("text", t.text);
                            try w.endObject();
                        }
                    },
                    .thinking => |t| {
                        if (t.thinking.len > 0) {
                            try w.beginObject();
                            try w.writeStringField("text", t.thinking);
                            try w.endObject();
                        }
                    },
                    .tool_call => |tc| {
                        try w.beginObject();
                        try w.writeKey("functionCall");
                        try w.beginObject();
                        try w.writeStringField("name", tc.name);
                        try w.writeKey("args");
                        try w.writeRawJson(tc.arguments_json);
                        try w.endObject();
                        try w.endObject();
                    },
                };
            },
            .tool_result => |tr| {
                try w.beginObject();
                try w.writeKey("functionResponse");
                try w.beginObject();
                try w.writeStringField("name", tr.tool_name);
                try w.writeKey("response");
                try w.beginObject();
                // Serialize content parts as the response
                for (tr.content) |c| switch (c) {
                    .text => |t| {
                        try w.writeStringField("result", t.text);
                    },
                    .image => {},
                };
                // Include details_json if present
                if (tr.details_json) |dj| {
                    try w.writeKey("details");
                    try w.writeRawJson(dj);
                }
                if (tr.is_error) {
                    try w.writeBoolField("error", true);
                }
                try w.endObject();
                try w.endObject();
                try w.endObject();
            },
        }

        try w.endArray();
        try w.endObject();
    }
    try w.endArray();

    if (context.system_prompt) |sp| {
        try w.writeKey("systemInstruction");
        try w.beginObject();
        try w.writeKey("parts");
        try w.beginArray();
        try w.beginObject();
        try w.writeStringField("text", sp);
        try w.endObject();
        try w.endArray();
        try w.endObject();
    }

    try w.writeKey("generationConfig");
    try w.beginObject();
    try w.writeIntField("maxOutputTokens", options.max_tokens orelse model.max_tokens);
    if (options.temperature) |t| {
        try w.writeKey("temperature");
        try w.writeFloat(t);
    }
    try w.endObject();

    // Add tools if present (Google uses functionDeclarations inside a tools array)
    if (context.tools) |tools| {
        if (tools.len > 0) {
            try w.writeKey("tools");
            try w.beginArray();
            try w.beginObject();
            try w.writeKey("functionDeclarations");
            try w.beginArray();
            for (tools) |tool| {
                try w.beginObject();
                try w.writeStringField("name", tool.name);
                try w.writeStringField("description", tool.description);
                try w.writeKey("parameters");
                try w.writeRawJson(tool.parameters_schema_json);
                try w.endObject();
            }
            try w.endArray();
            try w.endObject();
            try w.endArray();
        }
    }

    // Add thinkingConfig if thinking is enabled and model supports reasoning
    if (options.thinking_enabled and model.reasoning) {
        try w.writeKey("thinkingConfig");
        try w.beginObject();
        try w.writeBoolField("includeThoughts", true);

        // Gemini 3 uses thinkingLevel, Gemini 2.5 uses thinkingBudget
        if (options.thinking_effort) |effort| {
            // Effort was provided directly (string like "LOW", "HIGH", etc.)
            try w.writeStringField("thinkingLevel", effort);
        } else if (options.thinking_budget_tokens) |budget| {
            try w.writeIntField("thinkingBudget", budget);
        }
        try w.endObject();
    }

    try w.endObject();
    return buf.toOwnedSlice(allocator);
}

/// Parsed part from a Google response
const ParsedPart = struct {
    text: []const u8,
    is_thinking: bool,
    thought_signature: ?[]const u8,
};

/// Parse result from a Google SSE event
const GoogleParseResult = struct {
    parts: []const ParsedPart,
    usage: ai_types.Usage,
    finish_reason: ?[]const u8,
};

/// Parse a Google SSE event and extract parts with thinking info
fn parseGoogleEventExtended(data: []const u8, allocator: std.mem.Allocator) ?GoogleParseResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    var parts_list = std.ArrayList(ParsedPart){};
    defer parts_list.deinit(allocator);

    var usage = ai_types.Usage{};
    var finish_reason: ?[]const u8 = null;

    if (obj.get("candidates")) |cands| {
        if (cands == .array and cands.array.items.len > 0) {
            const c = cands.array.items[0];
            if (c == .object) {
                // Get finish reason
                if (c.object.get("finishReason")) |fr| {
                    if (fr == .string) {
                        finish_reason = allocator.dupe(u8, fr.string) catch null;
                    }
                }

                if (c.object.get("content")) |content| {
                    if (content == .object) {
                        if (content.object.get("parts")) |parts| {
                            if (parts == .array) {
                                for (parts.array.items) |p| {
                                    if (p == .object) {
                                        if (p.object.get("text")) |t| {
                                            if (t == .string and t.string.len > 0) {
                                                // Check if this is a thinking part
                                                const is_thinking = blk: {
                                                    if (p.object.get("thought")) |thought| {
                                                        if (thought == .bool and thought.bool) break :blk true;
                                                    }
                                                    break :blk false;
                                                };

                                                const sig = if (p.object.get("thoughtSignature")) |s| blk: {
                                                    if (s == .string) break :blk allocator.dupe(u8, s.string) catch null;
                                                    break :blk null;
                                                } else null;

                                                const text_copy = allocator.dupe(u8, t.string) catch continue;
                                                parts_list.append(allocator, .{
                                                    .text = text_copy,
                                                    .is_thinking = is_thinking,
                                                    .thought_signature = sig,
                                                }) catch {
                                                    allocator.free(text_copy);
                                                    continue;
                                                };
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (obj.get("usageMetadata")) |u| {
        if (u == .object) {
            if (u.object.get("promptTokenCount")) |v| {
                if (v == .integer) usage.input = @intCast(v.integer);
            }
            if (u.object.get("candidatesTokenCount")) |v| {
                if (v == .integer) usage.output = @intCast(v.integer);
            }
            if (u.object.get("thoughtsTokenCount")) |v| {
                // Include thinking tokens in output count
                if (v == .integer) usage.output += @as(u64, @intCast(v.integer));
            }
            if (u.object.get("totalTokenCount")) |v| {
                if (v == .integer) usage.total_tokens = @intCast(v.integer);
            }
        }
    }

    const parts_slice = parts_list.toOwnedSlice(allocator) catch return null;
    return .{
        .parts = parts_slice,
        .usage = usage,
        .finish_reason = finish_reason,
    };
}

fn deinitGoogleParseResult(result: *const GoogleParseResult, allocator: std.mem.Allocator) void {
    for (result.parts) |part| {
        allocator.free(part.text);
        if (part.thought_signature) |sig| allocator.free(sig);
    }
    allocator.free(result.parts);
    if (result.finish_reason) |fr| allocator.free(fr);
}

/// Current block type being streamed
const CurrentBlock = enum {
    none,
    text,
    thinking,
};

/// Create a partial message for events (references model strings directly, no allocation)
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

/// Map Google finish reason to StopReason
fn mapFinishReason(reason: ?[]const u8) ai_types.StopReason {
    if (reason) |r| {
        if (std.mem.eql(u8, r, "STOP")) return .stop;
        if (std.mem.eql(u8, r, "MAX_TOKENS")) return .length;
        return .@"error";
    }
    return .stop;
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    api_key: []u8,
    body: []u8,
    base_url: []u8,
};

fn runThread(ctx: *ThreadCtx) void {
    // Save values from ctx that we need after freeing ctx
    const allocator = ctx.allocator;
    const stream = ctx.stream;
    const model = ctx.model;
    const api_key = ctx.api_key;
    const body = ctx.body;
    const base_url = ctx.base_url;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(
        allocator,
        "{s}/v1beta/models/{s}:streamGenerateContent?alt=sse&key={s}",
        .{ base_url, model.id, api_key },
    ) catch {
        allocator.free(base_url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom url");
        return;
    };
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        allocator.free(base_url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("invalid URL");
        return;
    };

    const headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};

    var req = client.request(.POST, uri, .{ .extra_headers = &headers }) catch {
        allocator.free(base_url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("request failed");
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    req.sendBodyComplete(body) catch {
        allocator.free(base_url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("send failed");
        return;
    };

    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        allocator.free(base_url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("receive failed");
        return;
    };

    if (response.head.status != .ok) {
        allocator.free(base_url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("google request failed");
        return;
    }

    var parser = sse_parser.SSEParser.init(allocator);
    defer parser.deinit();

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    // Content block accumulators
    var content_blocks = std.ArrayList(ai_types.AssistantContent){};
    defer content_blocks.deinit(allocator);
    var current_text = std.ArrayList(u8){};
    defer current_text.deinit(allocator);
    var current_thinking = std.ArrayList(u8){};
    defer current_thinking.deinit(allocator);
    var current_thinking_signature = std.ArrayList(u8){};
    defer current_thinking_signature.deinit(allocator);
    var current_text_signature = std.ArrayList(u8){};
    defer current_text_signature.deinit(allocator);

    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;
    var current_block: CurrentBlock = .none;

    // Emit start event
    const partial_start = createPartialMessage(model);
    stream.push(.{ .start = .{ .partial = partial_start } }) catch {};

    while (true) {
        const n = reader.*.readSliceShort(&read_buf) catch {
            allocator.free(base_url);
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("read failed");
            return;
        };
        if (n == 0) break;

        const events = parser.feed(read_buf[0..n]) catch {
            allocator.free(base_url);
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("parse failed");
            return;
        };

        for (events) |ev| {
            const result = parseGoogleEventExtended(ev.data, allocator);
            if (result) |*res| {
                defer deinitGoogleParseResult(res, allocator);

                // Update usage
                if (res.usage.input > 0) usage.input = res.usage.input;
                if (res.usage.output > 0) usage.output = res.usage.output;
                if (res.usage.total_tokens > 0) usage.total_tokens = res.usage.total_tokens;

                // Update finish reason if provided
                if (res.finish_reason) |fr| {
                    stop_reason = mapFinishReason(fr);
                }

                // Process each part
                for (res.parts) |part| {
                    const is_thinking = part.is_thinking;
                    const needs_new_block = current_block == .none or
                        (is_thinking and current_block != .thinking) or
                        (!is_thinking and current_block != .text);

                    // Close current block if we need to switch
                    if (needs_new_block and current_block != .none) {
                        const partial = createPartialMessage(model);
                        switch (current_block) {
                            .text => {
                                // Store completed text block
                                const text_copy = allocator.dupe(u8, current_text.items) catch continue;
                                const sig_copy = if (current_text_signature.items.len > 0)
                                    allocator.dupe(u8, current_text_signature.items) catch null
                                else
                                    null;
                                content_blocks.append(allocator, .{ .text = .{
                                    .text = text_copy,
                                    .text_signature = sig_copy,
                                } }) catch {};
                                stream.push(.{ .text_end = .{
                                    .content_index = content_blocks.items.len - 1,
                                    .content = current_text.items,
                                    .partial = partial,
                                } }) catch {};
                                current_text.clearRetainingCapacity();
                                current_text_signature.clearRetainingCapacity();
                            },
                            .thinking => {
                                // Store completed thinking block
                                const thinking_copy = allocator.dupe(u8, current_thinking.items) catch continue;
                                const sig_copy = if (current_thinking_signature.items.len > 0)
                                    allocator.dupe(u8, current_thinking_signature.items) catch null
                                else
                                    null;
                                content_blocks.append(allocator, .{ .thinking = .{
                                    .thinking = thinking_copy,
                                    .thinking_signature = sig_copy,
                                } }) catch {};
                                stream.push(.{ .thinking_end = .{
                                    .content_index = content_blocks.items.len - 1,
                                    .content = current_thinking.items,
                                    .partial = partial,
                                } }) catch {};
                                current_thinking.clearRetainingCapacity();
                                current_thinking_signature.clearRetainingCapacity();
                            },
                            .none => {},
                        }
                    }

                    // Start new block if needed
                    if (needs_new_block) {
                        const content_idx = content_blocks.items.len;
                        const partial = createPartialMessage(model);

                        if (is_thinking) {
                            current_block = .thinking;
                            stream.push(.{ .thinking_start = .{
                                .content_index = content_idx,
                                .partial = partial,
                            } }) catch {};
                        } else {
                            current_block = .text;
                            stream.push(.{ .text_start = .{
                                .content_index = content_idx,
                                .partial = partial,
                            } }) catch {};
                        }
                    }

                    // Append content and emit delta
                    // NOTE: We must dupe part.text for the event delta because:
                    // 1. deinitGoogleParseResult() frees part.text
                    // 2. EventStream.deinit() also frees event deltas
                    // Using the same pointer would cause a double-free.
                    // The ArrayList appendSlice keeps the content for final message.
                    const partial = createPartialMessage(model);
                    if (is_thinking) {
                        current_thinking.appendSlice(allocator, part.text) catch {};
                        if (part.thought_signature) |sig| {
                            current_thinking_signature.appendSlice(allocator, sig) catch {};
                        }
                        const delta_copy = allocator.dupe(u8, part.text) catch continue;
                        stream.push(.{ .thinking_delta = .{
                            .content_index = content_blocks.items.len,
                            .delta = delta_copy,
                            .partial = partial,
                        } }) catch {
                            allocator.free(delta_copy);
                        };
                    } else {
                        current_text.appendSlice(allocator, part.text) catch {};
                        if (part.thought_signature) |sig| {
                            current_text_signature.appendSlice(allocator, sig) catch {};
                        }
                        const delta_copy = allocator.dupe(u8, part.text) catch continue;
                        stream.push(.{ .text_delta = .{
                            .content_index = content_blocks.items.len,
                            .delta = delta_copy,
                            .partial = partial,
                        } }) catch {
                            allocator.free(delta_copy);
                        };
                    }
                }
            }
        }
    }

    // Close final block if open
    if (current_block != .none) {
        switch (current_block) {
            .text => {
                const partial = createPartialMessage(model);
                const text_copy = allocator.dupe(u8, current_text.items) catch "";
                const sig_copy = if (current_text_signature.items.len > 0)
                    allocator.dupe(u8, current_text_signature.items) catch null
                else
                    null;
                content_blocks.append(allocator, .{ .text = .{
                    .text = text_copy,
                    .text_signature = sig_copy,
                } }) catch {};
                stream.push(.{ .text_end = .{
                    .content_index = content_blocks.items.len - 1,
                    .content = current_text.items,
                    .partial = partial,
                } }) catch {};
            },
            .thinking => {
                const partial = createPartialMessage(model);
                const thinking_copy = allocator.dupe(u8, current_thinking.items) catch "";
                const sig_copy = if (current_thinking_signature.items.len > 0)
                    allocator.dupe(u8, current_thinking_signature.items) catch null
                else
                    null;
                content_blocks.append(allocator, .{ .thinking = .{
                    .thinking = thinking_copy,
                    .thinking_signature = sig_copy,
                } }) catch {};
                stream.push(.{ .thinking_end = .{
                    .content_index = content_blocks.items.len - 1,
                    .content = current_thinking.items,
                    .partial = partial,
                } }) catch {};
            },
            .none => {},
        }
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output;

    // If no content blocks were collected, add an empty text block
    if (content_blocks.items.len == 0) {
        content_blocks.append(allocator, .{ .text = .{ .text = "" } }) catch {};
    }

    const content_slice = content_blocks.toOwnedSlice(allocator) catch {
        allocator.free(base_url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom content");
        return;
    };

    const out = ai_types.AssistantMessage{
        .content = content_slice,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp = std.time.milliTimestamp(),
    };

    stream.push(.{ .done = .{ .reason = stop_reason, .message = out } }) catch {};

    // Free ctx allocations before completing
    allocator.free(base_url);
    allocator.free(api_key);
    allocator.free(body);
    allocator.destroy(ctx);

    stream.complete(out);
}

pub fn streamGoogleGenerativeAI(model: ai_types.Model, context: ai_types.Context, options: ?ai_types.StreamOptions, allocator: std.mem.Allocator) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    const api_key: []u8 = blk: {
        if (o.api_key) |k| break :blk try allocator.dupe(u8, k);
        const e = env(allocator, "GOOGLE_API_KEY");
        if (e) |k| break :blk @constCast(k);
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    const base_url: []u8 = blk: {
        if (model.base_url.len > 0) break :blk try allocator.dupe(u8, model.base_url);
        const e = env(allocator, "GOOGLE_BASE_URL");
        if (e) |v| break :blk @constCast(v);
        break :blk try allocator.dupe(u8, "https://generativelanguage.googleapis.com");
    };
    errdefer allocator.free(base_url);

    const body = try buildBody(context, o, model, allocator);
    errdefer allocator.free(body);

    const s = try allocator.create(ai_types.AssistantMessageEventStream);
    errdefer allocator.destroy(s);
    s.* = ai_types.AssistantMessageEventStream.init(allocator);

    const ctx = try allocator.create(ThreadCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .allocator = allocator, .stream = s, .model = model, .api_key = api_key, .body = body, .base_url = base_url };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

pub fn streamSimpleGoogleGenerativeAI(model: ai_types.Model, context: ai_types.Context, options: ?ai_types.SimpleStreamOptions, allocator: std.mem.Allocator) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};

    // Build thinking options based on reasoning level and model capabilities
    var thinking_enabled: bool = false;
    var thinking_budget_tokens: ?u32 = null;
    var thinking_effort: ?[]const u8 = null;

    if (o.reasoning) |level| {
        if (model.reasoning) {
            thinking_enabled = true;

            if (isGemini3ProModel(model.id) or isGemini3FlashModel(model.id)) {
                // Gemini 3 uses thinkingLevel
                thinking_effort = getGemini3ThinkingLevel(level, model);
            } else {
                // Gemini 2.5 uses thinkingBudget
                const budget = getGoogleBudget(level, o.thinking_budgets, model.id);
                if (budget > 0) {
                    thinking_budget_tokens = @intCast(budget);
                }
            }
        }
    }

    return streamGoogleGenerativeAI(model, context, .{
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

pub fn registerGoogleGenerativeApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "google-generative-ai",
        .stream = streamGoogleGenerativeAI,
        .stream_simple = streamSimpleGoogleGenerativeAI,
    }, null);
}

pub fn registerGoogleGeminiCliApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "google-gemini-cli",
        .stream = streamGoogleGenerativeAI,
        .stream_simple = streamSimpleGoogleGenerativeAI,
    }, null);
}
