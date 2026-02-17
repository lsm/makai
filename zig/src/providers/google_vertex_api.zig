const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");
const retry_util = @import("retry");
const pre_transform = @import("pre_transform");

/// Vertex-specific options for authentication and configuration
pub const VertexOptions = struct {
    /// Google Cloud project ID (from GOOGLE_CLOUD_PROJECT or GCLOUD_PROJECT env var)
    project: ?[]const u8 = null,
    /// Google Cloud region/location (from GOOGLE_CLOUD_LOCATION env var, e.g., "us-central1")
    location: ?[]const u8 = null,
    /// API key for authentication (fallback if ADC not available)
    api_key: ?[]const u8 = null,
    /// Temperature for generation
    temperature: ?f32 = null,
    /// Maximum tokens to generate
    max_tokens: ?u32 = null,
};

/// Error types for Vertex API
pub const VertexError = error{
    MissingProjectId,
    MissingLocation,
    MissingApiKey,
    InvalidConfiguration,
};

fn env(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

/// Resolve project ID from options or environment variables
/// Priority: options.project > GOOGLE_CLOUD_PROJECT > GCLOUD_PROJECT
fn resolveProject(options: ?VertexOptions, allocator: std.mem.Allocator) VertexError!?[]u8 {
    if (options) |o| {
        if (o.project) |p| {
            return allocator.dupe(u8, p) catch return null;
        }
    }

    if (std.process.getEnvVarOwned(allocator, "GOOGLE_CLOUD_PROJECT") catch null) |p| {
        return p;
    }

    if (std.process.getEnvVarOwned(allocator, "GCLOUD_PROJECT") catch null) |p| {
        return p;
    }

    return error.MissingProjectId;
}

/// Resolve location from options or environment variable
/// Priority: options.location > GOOGLE_CLOUD_LOCATION
fn resolveLocation(options: ?VertexOptions, allocator: std.mem.Allocator) VertexError!?[]u8 {
    if (options) |o| {
        if (o.location) |l| {
            return allocator.dupe(u8, l) catch return null;
        }
    }

    if (std.process.getEnvVarOwned(allocator, "GOOGLE_CLOUD_LOCATION") catch null) |l| {
        return l;
    }

    return error.MissingLocation;
}

/// Resolve API key from options or environment
fn resolveApiKey(options: ?VertexOptions, allocator: std.mem.Allocator) VertexError!?[]u8 {
    if (options) |o| {
        if (o.api_key) |k| {
            return allocator.dupe(u8, k) catch return null;
        }
    }

    if (env(allocator, "GOOGLE_API_KEY")) |k| {
        return k;
    }

    if (env(allocator, "GOOGLE_APPLICATION_CREDENTIALS")) |creds_path| {
        // For now, we don't implement full ADC (Application Default Credentials)
        // Just log that we found the path but need API key fallback
        allocator.free(creds_path);
    }

    return error.MissingApiKey;
}

// Model detection helpers (shared with google_generative_api)
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

/// Check if a thought signature is valid base64
fn isValidThoughtSignature(sig: ?[]const u8) bool {
    if (sig == null) return false;
    if (sig.?.len == 0) return false;
    for (sig.?) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '/' and c != '=') {
            return false;
        }
    }
    return true;
}

/// Map ThinkingLevel to Google thinking level string (for Gemini 3)
fn getGemini3ThinkingLevel(level: ai_types.ThinkingLevel, model: ai_types.Model) []const u8 {
    if (isGemini3ProModel(model.id)) {
        return switch (level) {
            .minimal, .low => "LOW",
            .medium, .high, .xhigh => "HIGH",
        };
    }
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

    // Pre-transform messages: cross-model thinking conversion, tool ID normalization,
    // synthetic tool results for orphaned calls, aborted message filtering
    var transformed = try pre_transform.preTransform(allocator, context.messages, .{
        .target_api = model.api,
        .target_provider = model.provider,
        .target_model_id = model.id,
        .max_tool_id_len = 64, // Google Vertex max tool call ID length
        .insert_synthetic_results = true,
        .tools = context.tools,
    });
    defer transformed.deinit();

    var tx_context = context;
    tx_context.messages = transformed.messages;

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();

    try w.writeKey("contents");
    try w.beginArray();
    for (tx_context.messages) |m| {
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
                            if (t.text_signature) |sig| {
                                if (sig.len > 0) {
                                    try w.writeStringField("thoughtSignature", sig);
                                }
                            }
                            try w.endObject();
                        }
                    },
                    .thinking => |t| {
                        if (t.thinking.len > 0) {
                            try w.beginObject();
                            try w.writeStringField("text", t.thinking);
                            try w.writeBoolField("thought", true);
                            if (t.thinking_signature) |sig| {
                                if (sig.len > 0) {
                                    try w.writeStringField("thoughtSignature", sig);
                                }
                            }
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
                        if (tc.thought_signature) |sig| {
                            if (sig.len > 0) {
                                try w.writeStringField("thoughtSignature", sig);
                            }
                        }
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
                var last_text: ?[]const u8 = null;
                for (tr.content) |c| switch (c) {
                    .text => |t| {
                        last_text = t.text;
                    },
                    .image => {},
                };
                if (last_text) |text| {
                    try w.writeStringField("result", text);
                }
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

    // Add tools if present
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

            // Add tool_config if tool_choice is specified
            if (options.tool_choice) |tc| {
                try w.writeKey("tool_config");
                try w.beginObject();
                try w.writeKey("function_calling_config");
                try w.beginObject();
                switch (tc) {
                    .auto => try w.writeStringField("mode", "AUTO"),
                    .none => try w.writeStringField("mode", "NONE"),
                    .required => try w.writeStringField("mode", "ANY"),
                    .function => |name| {
                        try w.writeStringField("mode", "ANY");
                        try w.writeKey("allowed_function_names");
                        try w.beginArray();
                        try w.writeString(name);
                        try w.endArray();
                    },
                }
                try w.endObject();
                try w.endObject();
            }
        }
    }

    // Add thinkingConfig if thinking is enabled and model supports reasoning
    if (options.thinking_enabled and model.reasoning) {
        try w.writeKey("thinkingConfig");
        try w.beginObject();
        try w.writeBoolField("includeThoughts", true);

        if (options.thinking_effort) |effort| {
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
const ParsedPart = union(enum) {
    text: struct {
        text: []const u8,
        is_thinking: bool,
        thought_signature: ?[]const u8,
    },
    tool_call: struct {
        id: ?[]const u8,
        name: []const u8,
        args_json: []const u8,
        thought_signature: ?[]const u8 = null,
    },
};

/// Parse result from a Google SSE event
const GoogleParseResult = struct {
    parts: []const ParsedPart,
    usage: ai_types.Usage,
    finish_reason: ?[]const u8,
};

/// Stringify a std.json.Value to a buffer
fn stringifyJsonValue(value: std.json.Value, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var num_buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&num_buf, "{}", .{i}) catch return;
            try buf.appendSlice(allocator, str);
        },
        .float => |f| {
            var num_buf: [64]u8 = undefined;
            const str = std.fmt.bufPrint(&num_buf, "{d}", .{f}) catch return;
            try buf.appendSlice(allocator, str);
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .string => |s| {
            try buf.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.append(allocator, '"');
        },
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try stringifyJsonValue(item, buf, allocator);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var iter = obj.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try stringifyJsonValue(.{ .string = entry.key_ptr.* }, buf, allocator);
                try buf.append(allocator, ':');
                try stringifyJsonValue(entry.value_ptr.*, buf, allocator);
            }
            try buf.append(allocator, '}');
        },
    }
}

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
                                                parts_list.append(allocator, .{ .text = .{
                                                    .text = text_copy,
                                                    .is_thinking = is_thinking,
                                                    .thought_signature = sig,
                                                }}) catch {
                                                    allocator.free(text_copy);
                                                    if (sig) |s| allocator.free(s);
                                                    continue;
                                                };
                                            }
                                        } else if (p.object.get("functionCall")) |fc| {
                                            if (fc == .object) {
                                                const name = if (fc.object.get("name")) |n|
                                                    if (n == .string) n.string else ""
                                                else "";

                                                const id = if (fc.object.get("id")) |i|
                                                    if (i == .string) allocator.dupe(u8, i.string) catch null else null
                                                else null;

                                                const sig = if (p.object.get("thoughtSignature")) |s| blk: {
                                                    if (s == .string) break :blk allocator.dupe(u8, s.string) catch null;
                                                    break :blk null;
                                                } else null;

                                                const args_json = if (fc.object.get("args")) |args| blk: {
                                                    var buf = std.ArrayList(u8){};
                                                    stringifyJsonValue(args, &buf, allocator) catch break :blk "";
                                                    break :blk buf.toOwnedSlice(allocator) catch "";
                                                } else "";

                                                const name_copy = allocator.dupe(u8, name) catch {
                                                    if (sig) |ss| allocator.free(ss);
                                                    continue;
                                                };
                                                parts_list.append(allocator, .{ .tool_call = .{
                                                    .id = id,
                                                    .name = name_copy,
                                                    .args_json = args_json,
                                                    .thought_signature = sig,
                                                }}) catch {
                                                    allocator.free(name_copy);
                                                    if (id) |i| allocator.free(i);
                                                    allocator.free(args_json);
                                                    if (sig) |ss| allocator.free(ss);
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
        switch (part) {
            .text => |t| {
                allocator.free(t.text);
                if (t.thought_signature) |sig| allocator.free(sig);
            },
            .tool_call => |tc| {
                if (tc.id) |id| allocator.free(id);
                allocator.free(tc.name);
                allocator.free(tc.args_json);
                if (tc.thought_signature) |sig| allocator.free(sig);
            },
        }
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

/// Create a partial message for events
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
    project: []u8,
    location: []u8,
    thinking_enabled: bool,
    retry_config: ?ai_types.RetryConfig = null,
};

fn runThread(ctx: *ThreadCtx) void {
    const allocator = ctx.allocator;
    const stream = ctx.stream;
    const model = ctx.model;
    const api_key = ctx.api_key;
    const body = ctx.body;
    const project = ctx.project;
    const location = ctx.location;
    const thinking_enabled = ctx.thinking_enabled;
    const retry_opts = ctx.retry_config;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Vertex AI URL structure:
    // https://<location>-aiplatform.googleapis.com/v1/projects/<project>/locations/<location>/publishers/google/models/<model>:streamGenerateContent?alt=sse
    const url = std.fmt.allocPrint(
        allocator,
        "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:streamGenerateContent?alt=sse&key={s}",
        .{ location, project, location, model.id, api_key },
    ) catch {
        allocator.free(project);
        allocator.free(location);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom url");
        return;
    };
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        allocator.free(project);
        allocator.free(location);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("invalid URL");
        return;
    };

    const headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};

    // Retry configuration
    const MAX_RETRIES: u8 = 3;
    const BASE_DELAY_MS: u32 = 1000;
    const max_delay_ms: u32 = if (retry_opts) |rc| rc.max_retry_delay_ms orelse 60000 else 60000;

    var response: std.http.Client.Response = undefined;
    var head_buf: [4096]u8 = undefined;
    var retry_attempt: u8 = 0;
    var req: std.http.Client.Request = undefined;
    var req_initialized = false;
    defer if (req_initialized) req.deinit();

    while (true) {
        // Deinit previous request if this is a retry
        if (req_initialized) {
            req.deinit();
            req_initialized = false;
        }

        req = client.request(.POST, uri, .{ .extra_headers = &headers }) catch {
            // Network error - check if we should retry
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry_util.sleepMs(delay, null)) {
                    retry_attempt += 1;
                    continue;
                }
                allocator.free(project);
                allocator.free(location);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
                stream.completeWithError("request failed");
                return;
            }
            allocator.free(project);
            allocator.free(location);
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("request failed");
            return;
        };
        req_initialized = true;

        req.transfer_encoding = .{ .content_length = body.len };
        req.sendBodyComplete(body) catch {
            // Network error - check if we should retry
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry_util.sleepMs(delay, null)) {
                    retry_attempt += 1;
                    continue;
                }
                allocator.free(project);
                allocator.free(location);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
                stream.completeWithError("send failed");
                return;
            }
            allocator.free(project);
            allocator.free(location);
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("send failed");
            return;
        };

        response = req.receiveHead(&head_buf) catch {
            // Network error - check if we should retry
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry_util.sleepMs(delay, null)) {
                    retry_attempt += 1;
                    continue;
                }
                allocator.free(project);
                allocator.free(location);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
                stream.completeWithError("receive failed");
                return;
            }
            allocator.free(project);
            allocator.free(location);
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("receive failed");
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
            // Read error body to check for retry delay hints
            var error_body: [4096]u8 = undefined;
            const error_body_len = response.reader(&head_buf).readSliceShort(&error_body) catch 0;
            const error_text = error_body[0..error_body_len];

            // Check if error body indicates a retryable error
            const is_retryable_error = retry_util.isRetryableError(error_text);

            // Calculate delay - prefer server-provided delay
            var delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);

            // Check Retry-After header
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
            if (!retry_util.sleepMs(delay, null)) {
                allocator.free(project);
                allocator.free(location);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
                stream.completeWithError("vertex request failed");
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
        allocator.free(project);
        allocator.free(location);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("vertex request failed");
        return;
    }

    var parser = sse_parser.SSEParser.init(allocator);
    defer parser.deinit();

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

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
    var tool_call_counter: usize = 0;

    // Emit start event
    const partial_start = createPartialMessage(model);
    stream.push(.{ .start = .{ .partial = partial_start } }) catch {};

    while (true) {
        const n = reader.*.readSliceShort(&read_buf) catch {
            allocator.free(project);
            allocator.free(location);
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("read failed");
            return;
        };
        if (n == 0) break;

        const events = parser.feed(read_buf[0..n]) catch {
            allocator.free(project);
            allocator.free(location);
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

                if (res.usage.input > 0) usage.input = res.usage.input;
                if (res.usage.output > 0) usage.output = res.usage.output;
                if (res.usage.total_tokens > 0) usage.total_tokens = res.usage.total_tokens;

                if (res.finish_reason) |fr| {
                    stop_reason = mapFinishReason(fr);
                }

                for (res.parts) |part| {
                    switch (part) {
                        .text => |text_part| {
                            const is_thinking = text_part.is_thinking;
                            const needs_new_block = current_block == .none or
                                (is_thinking and current_block != .thinking) or
                                (!is_thinking and current_block != .text);

                            if (needs_new_block and current_block != .none) {
                                const partial = createPartialMessage(model);
                                switch (current_block) {
                                    .text => {
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

                            const partial = createPartialMessage(model);
                            if (is_thinking) {
                                const prev_len = current_thinking.items.len;
                                current_thinking.appendSlice(allocator, text_part.text) catch {};
                                if (text_part.thought_signature) |sig| {
                                    current_thinking_signature.appendSlice(allocator, sig) catch {};
                                }
                                const delta = current_thinking.items[prev_len..];
                                stream.push(.{ .thinking_delta = .{
                                    .content_index = content_blocks.items.len,
                                    .delta = delta,
                                    .partial = partial,
                                } }) catch {};
                            } else {
                                const prev_len = current_text.items.len;
                                current_text.appendSlice(allocator, text_part.text) catch {};
                                if (text_part.thought_signature) |sig| {
                                    current_text_signature.appendSlice(allocator, sig) catch {};
                                }
                                const delta = current_text.items[prev_len..];
                                stream.push(.{ .text_delta = .{
                                    .content_index = content_blocks.items.len,
                                    .delta = delta,
                                    .partial = partial,
                                } }) catch {};
                            }
                        },
                        .tool_call => |tc| {
                            if (current_block != .none) {
                                const partial = createPartialMessage(model);
                                switch (current_block) {
                                    .text => {
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
                                        current_text.clearRetainingCapacity();
                                        current_text_signature.clearRetainingCapacity();
                                    },
                                    .thinking => {
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
                                        current_thinking.clearRetainingCapacity();
                                        current_thinking_signature.clearRetainingCapacity();
                                    },
                                    .none => {},
                                }
                                current_block = .none;
                            }

                            const is_gemini3 = isGemini3ProModel(model.id) or isGemini3FlashModel(model.id);
                            if (is_gemini3 and thinking_enabled) {
                                if (!isValidThoughtSignature(tc.thought_signature)) {
                                    std.log.debug("Gemini 3 tool call without valid thought signature: {s}", .{tc.name});
                                }
                            }

                            const tool_id = if (tc.id) |id|
                                allocator.dupe(u8, id) catch continue
                            else blk: {
                                tool_call_counter += 1;
                                const timestamp = std.time.milliTimestamp();
                                break :blk std.fmt.allocPrint(
                                    allocator,
                                    "{s}_{}_{}",
                                    .{ tc.name, timestamp, tool_call_counter },
                                ) catch continue;
                            };

                            const tool_name = allocator.dupe(u8, tc.name) catch {
                                allocator.free(tool_id);
                                continue;
                            };
                            const tool_args = allocator.dupe(u8, tc.args_json) catch {
                                allocator.free(tool_id);
                                allocator.free(tool_name);
                                continue;
                            };

                            const content_idx = content_blocks.items.len;

                            stream.push(.{ .toolcall_start = .{
                                .content_index = content_idx,
                                .partial = createPartialMessage(model),
                            } }) catch {
                                allocator.free(tool_id);
                                allocator.free(tool_name);
                                allocator.free(tool_args);
                                continue;
                            };

                            stream.push(.{ .toolcall_delta = .{
                                .content_index = content_idx,
                                .delta = tool_args,
                                .partial = createPartialMessage(model),
                            } }) catch {};

                            const tool_call_struct = ai_types.ToolCall{
                                .id = tool_id,
                                .name = tool_name,
                                .arguments_json = tool_args,
                            };

                            content_blocks.append(allocator, .{ .tool_call = tool_call_struct }) catch {
                                allocator.free(tool_id);
                                allocator.free(tool_name);
                                allocator.free(tool_args);
                                continue;
                            };

                            const event_tc = ai_types.ToolCall{
                                .id = allocator.dupe(u8, tool_call_struct.id) catch tool_call_struct.id,
                                .name = allocator.dupe(u8, tool_call_struct.name) catch tool_call_struct.name,
                                .arguments_json = if (tool_call_struct.arguments_json.len > 0) allocator.dupe(u8, tool_call_struct.arguments_json) catch tool_call_struct.arguments_json else "",
                            };

                            stream.push(.{ .toolcall_end = .{
                                .content_index = content_idx,
                                .tool_call = event_tc,
                                .partial = createPartialMessage(model),
                            } }) catch {};
                        },
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
    usage.calculateCost(model.cost);

    if (content_blocks.items.len == 0) {
        content_blocks.append(allocator, .{ .text = .{ .text = "" } }) catch {};
    }

    const content_slice = content_blocks.toOwnedSlice(allocator) catch {
        allocator.free(project);
        allocator.free(location);
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

    allocator.free(project);
    allocator.free(location);
    allocator.free(api_key);
    allocator.free(body);
    allocator.destroy(ctx);

    stream.complete(out);
}

/// Stream from Google Vertex AI with full authentication support
pub fn streamGoogleVertex(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) VertexError!*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    // Resolve project and location from environment
    const project = try resolveProject(null, allocator) orelse {
        std.log.err("Vertex AI requires a project ID. Set GOOGLE_CLOUD_PROJECT/GCLOUD_PROJECT environment variable.", .{});
        return error.MissingProjectId;
    };
    errdefer allocator.free(project);

    const location = try resolveLocation(null, allocator) orelse {
        std.log.err("Vertex AI requires a location. Set GOOGLE_CLOUD_LOCATION environment variable.", .{});
        allocator.free(project);
        return error.MissingLocation;
    };
    errdefer allocator.free(location);

    // Resolve API key (required for Vertex AI with API key auth)
    const api_key: []u8 = blk: {
        if (o.api_key) |k| break :blk try allocator.dupe(u8, k);
        const e = env(allocator, "GOOGLE_API_KEY");
        if (e) |k| break :blk @constCast(k);
        std.log.err("Vertex AI requires an API key. Set GOOGLE_API_KEY environment variable or pass api_key in options.", .{});
        allocator.free(project);
        allocator.free(location);
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    const body = buildBody(context, o, model, allocator) catch {
        allocator.free(project);
        allocator.free(location);
        allocator.free(api_key);
        return error.InvalidConfiguration;
    };
    errdefer allocator.free(body);

    const s = allocator.create(ai_types.AssistantMessageEventStream) catch {
        allocator.free(project);
        allocator.free(location);
        allocator.free(api_key);
        allocator.free(body);
        return error.InvalidConfiguration;
    };
    errdefer allocator.destroy(s);
    s.* = ai_types.AssistantMessageEventStream.init(allocator);

    const ctx = allocator.create(ThreadCtx) catch {
        allocator.free(project);
        allocator.free(location);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(s);
        return error.InvalidConfiguration;
    };
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .stream = s,
        .model = model,
        .api_key = api_key,
        .body = body,
        .project = project,
        .location = location,
        .thinking_enabled = o.thinking_enabled,
        .retry_config = o.retry,
    };

    const th = std.Thread.spawn(.{}, runThread, .{ctx}) catch {
        allocator.free(project);
        allocator.free(location);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        allocator.destroy(s);
        return error.InvalidConfiguration;
    };
    th.detach();
    return s;
}

/// Stream from Google Vertex AI with simple options
pub fn streamSimpleGoogleVertex(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) VertexError!*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};

    // Build thinking options based on reasoning level and model capabilities
    var thinking_enabled: bool = false;
    var thinking_budget_tokens: ?u32 = null;
    var thinking_effort: ?[]const u8 = null;

    if (o.reasoning) |level| {
        if (model.reasoning) {
            thinking_enabled = true;

            if (isGemini3ProModel(model.id) or isGemini3FlashModel(model.id)) {
                thinking_effort = getGemini3ThinkingLevel(level, model);
            } else {
                const budget = getGoogleBudget(level, o.thinking_budgets, model.id);
                if (budget > 0) {
                    thinking_budget_tokens = @intCast(budget);
                }
            }
        }
    }

    return streamGoogleVertex(model, context, .{
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

/// Register the Google Vertex API provider
pub fn registerGoogleVertexApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "google-vertex",
        .stream = streamGoogleVertex,
        .stream_simple = streamSimpleGoogleVertex,
    }, null);
}

// Tests

test "resolveProject - from environment" {
    const allocator = std.testing.allocator;

    // Test with explicit option
    const result1 = try resolveProject(.{ .project = "my-project" }, allocator);
    if (result1) |p| {
        defer allocator.free(p);
        try std.testing.expectEqualStrings("my-project", p);
    }

    // Test without options (depends on env vars being set or not)
    // This should return error.MissingProjectId if no env vars are set
    const result2 = resolveProject(null, allocator);
    if (result2) |maybe_p| {
        if (maybe_p) |p| {
            allocator.free(p);
        }
    } else |_| {
        // Expected if no env vars set
    }
}

test "resolveLocation - from environment" {
    const allocator = std.testing.allocator;

    // Test with explicit option
    const result1 = try resolveLocation(.{ .location = "us-central1" }, allocator);
    if (result1) |l| {
        defer allocator.free(l);
        try std.testing.expectEqualStrings("us-central1", l);
    }

    // Test without options
    const result2 = resolveLocation(null, allocator);
    if (result2) |maybe_l| {
        if (maybe_l) |l| {
            allocator.free(l);
        }
    } else |_| {
        // Expected if GOOGLE_CLOUD_LOCATION not set
    }
}

test "VertexOptions defaults" {
    const opts = VertexOptions{};

    try std.testing.expect(opts.project == null);
    try std.testing.expect(opts.location == null);
    try std.testing.expect(opts.api_key == null);
    try std.testing.expect(opts.temperature == null);
    try std.testing.expect(opts.max_tokens == null);
}

test "VertexOptions with values" {
    const opts = VertexOptions{
        .project = "test-project",
        .location = "europe-west1",
        .api_key = "test-key",
        .temperature = 0.7,
        .max_tokens = 1000,
    };

    try std.testing.expectEqualStrings("test-project", opts.project.?);
    try std.testing.expectEqualStrings("europe-west1", opts.location.?);
    try std.testing.expectEqualStrings("test-key", opts.api_key.?);
    try std.testing.expectEqual(@as(f32, 0.7), opts.temperature.?);
    try std.testing.expectEqual(@as(u32, 1000), opts.max_tokens.?);
}

test "VertexError error types" {
    // Verify error types exist and can be used
    const err: VertexError = error.MissingProjectId;
    try std.testing.expect(err == error.MissingProjectId);

    const err2: VertexError = error.MissingLocation;
    try std.testing.expect(err2 == error.MissingLocation);

    const err3: VertexError = error.MissingApiKey;
    try std.testing.expect(err3 == error.MissingApiKey);
}

test "parseGoogleEventExtended - text part" {
    const allocator = std.testing.allocator;
    const data =
        \\{"candidates":[{"content":{"parts":[{"text":"Hello from Vertex AI"}]}}]}
    ;

    const result = parseGoogleEventExtended(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer deinitGoogleParseResult(&result, allocator);

    try std.testing.expectEqual(@as(usize, 1), result.parts.len);
    try std.testing.expectEqualStrings("Hello from Vertex AI", result.parts[0].text.text);
    try std.testing.expectEqual(false, result.parts[0].text.is_thinking);
}

test "parseGoogleEventExtended - thinking part" {
    const allocator = std.testing.allocator;
    const data =
        \\{"candidates":[{"content":{"parts":[{"text":"Thinking...","thought":true,"thoughtSignature":"vertex-sig"}]}}]}
    ;

    const result = parseGoogleEventExtended(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer deinitGoogleParseResult(&result, allocator);

    try std.testing.expectEqual(@as(usize, 1), result.parts.len);
    try std.testing.expectEqualStrings("Thinking...", result.parts[0].text.text);
    try std.testing.expectEqual(true, result.parts[0].text.is_thinking);
    if (result.parts[0].text.thought_signature) |sig| {
        try std.testing.expectEqualStrings("vertex-sig", sig);
    } else {
        try std.testing.expect(false);
    }
}

test "parseGoogleEventExtended - tool call part" {
    const allocator = std.testing.allocator;
    const data =
        \\{"candidates":[{"content":{"parts":[{"functionCall":{"name":"query_bigquery","args":{"sql":"SELECT * FROM table"}}}]}}]}
    ;

    const result = parseGoogleEventExtended(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer deinitGoogleParseResult(&result, allocator);

    try std.testing.expectEqual(@as(usize, 1), result.parts.len);
    try std.testing.expectEqual(std.meta.activeTag(result.parts[0]), ParsedPart.tool_call);

    const tc = result.parts[0].tool_call;
    try std.testing.expect(tc.id == null);
    try std.testing.expectEqualStrings("query_bigquery", tc.name);
    try std.testing.expectEqualStrings("{\"sql\":\"SELECT * FROM table\"}", tc.args_json);
}

test "mapFinishReason - Vertex finish reasons" {
    try std.testing.expectEqual(ai_types.StopReason.stop, mapFinishReason("STOP"));
    try std.testing.expectEqual(ai_types.StopReason.length, mapFinishReason("MAX_TOKENS"));
    try std.testing.expectEqual(ai_types.StopReason.@"error", mapFinishReason("SAFETY"));
    try std.testing.expectEqual(ai_types.StopReason.stop, mapFinishReason(null));
}
