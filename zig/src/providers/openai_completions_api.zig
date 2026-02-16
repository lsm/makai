const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");
const github_copilot = @import("github_copilot");
const tool_call_tracker = @import("tool_call_tracker");

fn envApiKey(allocator: std.mem.Allocator) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY") catch null;
}

fn appendTextContent(msg: ai_types.Message, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (msg) {
        .user => |u| switch (u.content) {
            .text => |t| try out.appendSlice(allocator, t),
            .parts => |parts| {
                for (parts) |p| {
                    switch (p) {
                        .text => |t| {
                            if (out.items.len > 0) try out.append(allocator, '\n');
                            try out.appendSlice(allocator, t.text);
                        },
                        .image => {},
                    }
                }
            },
        },
        .assistant => |a| {
            for (a.content) |c| {
                switch (c) {
                    .text => |t| {
                        if (out.items.len > 0) try out.append(allocator, '\n');
                        try out.appendSlice(allocator, t.text);
                    },
                    .thinking => |t| {
                        if (out.items.len > 0) try out.append(allocator, '\n');
                        try out.appendSlice(allocator, t.thinking);
                    },
                    .tool_call => {},
                }
            }
        },
        .tool_result => |tr| {
            for (tr.content) |c| {
                switch (c) {
                    .text => |t| {
                        if (out.items.len > 0) try out.append(allocator, '\n');
                        try out.appendSlice(allocator, t.text);
                    },
                    .image => {},
                }
            }
        },
    }
}

fn writeMessagesArray(
    writer: *json_writer.JsonWriter,
    context: ai_types.Context,
    allocator: std.mem.Allocator,
) !void {
    try writer.writeKey("messages");
    try writer.beginArray();

    if (context.system_prompt) |sp| {
        try writer.beginObject();
        try writer.writeStringField("role", "system");
        try writer.writeStringField("content", sp);
        try writer.endObject();
    }

    for (context.messages) |msg| {
        var text_buf = std.ArrayList(u8){};
        defer text_buf.deinit(allocator);
        try appendTextContent(msg, &text_buf, allocator);

        const role: []const u8 = switch (msg) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "tool",
        };

        try writer.beginObject();
        try writer.writeStringField("role", role);
        switch (msg) {
            .tool_result => |tr| try writer.writeStringField("tool_call_id", tr.tool_call_id),
            else => {},
        }
        try writer.writeStringField("content", text_buf.items);

        // Check for tool_calls on assistant messages
        if (msg == .assistant) {
            var has_tool_calls = false;
            for (msg.assistant.content) |c| {
                if (c == .tool_call) {
                    has_tool_calls = true;
                    break;
                }
            }
            if (has_tool_calls) {
                try writer.writeKey("tool_calls");
                try writer.beginArray();
                for (msg.assistant.content) |c| {
                    if (c == .tool_call) {
                        const tc = c.tool_call;
                        try writer.beginObject();
                        try writer.writeStringField("id", tc.id);
                        try writer.writeStringField("type", "function");
                        try writer.writeKey("function");
                        try writer.beginObject();
                        try writer.writeStringField("name", tc.name);
                        try writer.writeStringField("arguments", tc.arguments_json);
                        try writer.endObject();
                        try writer.endObject();
                    }
                }
                try writer.endArray();
            }
        }

        try writer.endObject();
    }

    try writer.endArray();
}

fn buildRequestBody(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try w.writeStringField("model", model.id);
    try writeMessagesArray(&w, context, allocator);
    try w.writeBoolField("stream", true);
    try w.writeKey("stream_options");
    try w.beginObject();
    try w.writeBoolField("include_usage", true);
    try w.endObject();
    try w.writeIntField("max_tokens", options.max_tokens orelse model.max_tokens);
    if (options.temperature) |t| {
        try w.writeKey("temperature");
        try w.writeFloat(t);
    }
    // Add reasoning_effort for OpenAI-compatible endpoints that support it
    if (options.reasoning_effort) |effort| {
        if (model.reasoning) {
            try w.writeStringField("reasoning_effort", effort);
        }
    }
    // Add tools if present
    if (context.tools) |tools| {
        if (tools.len > 0) {
            try w.writeKey("tools");
            try w.beginArray();
            for (tools) |tool| {
                try w.beginObject();
                try w.writeStringField("type", "function");
                try w.writeKey("function");
                try w.beginObject();
                try w.writeStringField("name", tool.name);
                try w.writeStringField("description", tool.description);
                try w.writeKey("parameters");
                try w.writeRawJson(tool.parameters_schema_json);
                try w.endObject();
                try w.endObject();
            }
            try w.endArray();
        }
    }
    // Privacy: don't store requests for OpenAI training
    // Only add for OpenAI endpoints (not third-party compatible APIs)
    if (std.mem.indexOf(u8, model.base_url, "openai.com") != null) {
        try w.writeBoolField("store", false);
    }
    try w.endObject();

    return buf.toOwnedSlice(allocator);
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    api_key: []const u8,
    request_body: []u8,
    context: ai_types.Context,
};

/// Current block type being parsed
const BlockType = enum {
    none,
    text,
    thinking,
    tool_call,
};

/// Tool call event parsed from delta, to be processed after parseChunk returns
/// All strings are owned and must be freed with deinit.
const ToolCallEvent = struct {
    api_index: usize,
    is_start: bool, // true if this is a start event (has id)
    id: ?[]const u8,
    name: ?[]const u8,
    arguments_delta: ?[]const u8,

    fn deinit(self: *ToolCallEvent, allocator: std.mem.Allocator) void {
        if (self.id) |id| allocator.free(id);
        if (self.name) |name| allocator.free(name);
        if (self.arguments_delta) |delta| allocator.free(delta);
    }
};

/// Reasoning field names to check (in priority order)
const reasoning_fields: []const []const u8 = &.{ "reasoning_content", "reasoning", "reasoning_text" };

/// Find the first non-empty reasoning field in a delta object
fn findReasoningField(delta: std.json.ObjectMap) ?struct { field: []const u8, value: []const u8 } {
    for (reasoning_fields) |field| {
        if (delta.get(field)) |val| {
            if (val == .string and val.string.len > 0) {
                return .{ .field = field, .value = val.string };
            }
        }
    }
    return null;
}

fn parseChunk(
    data: []const u8,
    text: *std.ArrayList(u8),
    thinking: *std.ArrayList(u8),
    usage: *ai_types.Usage,
    stop_reason: *ai_types.StopReason,
    current_block: *BlockType,
    reasoning_signature: *?[]const u8,
    tool_call_events: *std.ArrayList(ToolCallEvent),
    allocator: std.mem.Allocator,
) !void {
    if (std.mem.eql(u8, data, "[DONE]")) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;

    // Parse usage including reasoning tokens
    if (root.object.get("usage")) |u| {
        if (u == .object) {
            if (u.object.get("prompt_tokens")) |v| {
                if (v == .integer) usage.input = @intCast(v.integer);
            }
            // Check for cached tokens in prompt_tokens_details
            if (u.object.get("prompt_tokens_details")) |details| {
                if (details == .object) {
                    if (details.object.get("cached_tokens")) |cached| {
                        if (cached == .integer) {
                            const cached_tokens: u64 = @intCast(cached.integer);
                            usage.cache_read = cached_tokens;
                            // Subtract cached from input since OpenAI includes them in prompt_tokens
                            if (usage.input > cached_tokens) {
                                usage.input -= cached_tokens;
                            }
                        }
                    }
                }
            }
            // Get base completion tokens
            var completion_tokens: u64 = 0;
            if (u.object.get("completion_tokens")) |v| {
                if (v == .integer) completion_tokens = @intCast(v.integer);
            }
            // Check for reasoning tokens in completion_tokens_details
            var reasoning_tokens: u64 = 0;
            if (u.object.get("completion_tokens_details")) |details| {
                if (details == .object) {
                    if (details.object.get("reasoning_tokens")) |rt| {
                        if (rt == .integer) reasoning_tokens = @intCast(rt.integer);
                    }
                }
            }
            // Output includes both regular completion and reasoning tokens
            usage.output = completion_tokens + reasoning_tokens;
            if (u.object.get("total_tokens")) |v| {
                if (v == .integer) usage.total_tokens = @intCast(v.integer);
            }
        }
    }

    if (root.object.get("choices")) |choices| {
        if (choices != .array or choices.array.items.len == 0) return;
        const ch = choices.array.items[0];
        if (ch != .object) return;

        if (ch.object.get("finish_reason")) |fr| {
            if (fr == .string) {
                if (std.mem.eql(u8, fr.string, "length")) stop_reason.* = .length
                else if (std.mem.eql(u8, fr.string, "tool_calls")) stop_reason.* = .tool_use
                else if (std.mem.eql(u8, fr.string, "content_filter")) stop_reason.* = .@"error"
                else stop_reason.* = .stop;
            }
        }

        if (ch.object.get("delta")) |d| {
            if (d == .object) {
                // Check for tool_calls first (priority over reasoning and text)
                if (d.object.get("tool_calls")) |tool_calls| {
                    if (tool_calls == .array) {
                        for (tool_calls.array.items) |tc| {
                            if (tc == .object) {
                                const tc_index: usize = if (tc.object.get("index")) |idx|
                                    if (idx == .integer) @intCast(idx.integer) else 0
                                else
                                    0;

                                const tc_id = tc.object.get("id");
                                const tc_func = tc.object.get("function");

                                // If has id, it's a new tool call start
                                if (tc_id) |id| {
                                    if (id == .string and id.string.len > 0) {
                                        current_block.* = .tool_call;
                                        // Get name from function object
                                        var name_str: []const u8 = "";
                                        if (tc_func) |f| {
                                            if (f == .object) {
                                                if (f.object.get("name")) |n| {
                                                    if (n == .string) {
                                                        name_str = n.string;
                                                    }
                                                }
                                            }
                                        }

                                        // Dupe the strings since parsed JSON will be freed
                                        const duped_id = try allocator.dupe(u8, id.string);
                                        const duped_name = try allocator.dupe(u8, name_str);

                                        // Add start event
                                        try tool_call_events.append(allocator, .{
                                            .api_index = tc_index,
                                            .is_start = true,
                                            .id = duped_id,
                                            .name = duped_name,
                                            .arguments_delta = null,
                                        });
                                    }
                                }

                                // Append arguments delta (can come with or without id)
                                if (tc_func) |f| {
                                    if (f == .object) {
                                        if (f.object.get("arguments")) |args| {
                                            if (args == .string and args.string.len > 0) {
                                                current_block.* = .tool_call;
                                                // Dupe the string since parsed JSON will be freed
                                                const duped_args = try allocator.dupe(u8, args.string);
                                                // Add delta event
                                                try tool_call_events.append(allocator, .{
                                                    .api_index = tc_index,
                                                    .is_start = false,
                                                    .id = null,
                                                    .name = null,
                                                    .arguments_delta = duped_args,
                                                });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if (findReasoningField(d.object)) |reasoning| {
                    // Check for reasoning content (priority over text)
                    // Track which field reasoning came from (for round-trip)
                    if (reasoning_signature.* == null) {
                        reasoning_signature.* = try allocator.dupe(u8, reasoning.field);
                    }
                    current_block.* = .thinking;
                    try thinking.appendSlice(allocator, reasoning.value);
                } else if (d.object.get("content")) |c| {
                    // Regular text content
                    if (c == .string and c.string.len > 0) {
                        current_block.* = .text;
                        try text.appendSlice(allocator, c.string);
                    }
                }
            }
        }
    }
}

fn runThread(ctx: *ThreadCtx) void {
    // Save values from ctx that we need after freeing ctx
    const allocator = ctx.allocator;
    const stream = ctx.stream;
    const model = ctx.model;
    const api_key = ctx.api_key;
    const request_body = ctx.request_body;
    const context = ctx.context;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{model.base_url}) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom building url");
        return;
    };
    defer allocator.free(url);

    const auth = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom building auth header");
        return;
    };
    defer allocator.free(auth);

    const uri = std.Uri.parse(url) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("invalid provider URL");
        return;
    };

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    headers.append(allocator, .{ .name = "authorization", .value = auth }) catch {
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
    headers.append(allocator, .{ .name = "accept", .value = "text/event-stream" }) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom headers");
        return;
    };

    // Add GitHub Copilot dynamic headers if provider is github-copilot
    if (std.mem.eql(u8, model.provider, "github-copilot")) {
        const has_images = github_copilot.hasCopilotVisionInput(context.messages);
        const copilot_headers = github_copilot.buildCopilotDynamicHeaders(
            context.messages,
            has_images,
            allocator,
        ) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom copilot headers");
            return;
        };
        defer allocator.free(copilot_headers);

        for (copilot_headers) |h| {
            headers.append(allocator, h) catch {
                allocator.free(api_key);
                allocator.free(request_body);
                allocator.destroy(ctx);
                stream.completeWithError("oom headers");
                return;
            };
        }
    }

    var req = client.request(.POST, uri, .{ .extra_headers = headers.items }) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("failed to open request");
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = request_body.len };

    req.sendBodyComplete(request_body) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("failed to send request");
        return;
    };

    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("failed to receive response");
        return;
    };

    if (response.head.status != .ok) {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("openai request failed");
        return;
    }

    var parser = sse_parser.SSEParser.init(allocator);
    defer parser.deinit();

    var text = std.ArrayList(u8){};
    defer text.deinit(allocator);
    var thinking = std.ArrayList(u8){};
    defer thinking.deinit(allocator);
    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;
    var current_block: BlockType = .none;
    var reasoning_signature: ?[]const u8 = null;
    defer if (reasoning_signature) |sig| allocator.free(sig);

    // Tool call tracking
    var tool_call_tracker_instance = tool_call_tracker.ToolCallTracker.init(allocator);
    defer tool_call_tracker_instance.deinit();
    var tool_call_events = std.ArrayList(ToolCallEvent){};
    defer {
        for (tool_call_events.items) |*tce| {
            @constCast(tce).deinit(allocator);
        }
        tool_call_events.deinit(allocator);
    }
    var next_content_index: usize = 0;
    var tool_call_count: usize = 0;

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    // Emit start event
    _ = stream.push(.{
        .start = .{
            .partial = .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = .{},
                .stop_reason = .stop,
                .timestamp = std.time.milliTimestamp(),
            },
        },
    }) catch {};

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
            // Free any previous tool call events
            for (tool_call_events.items) |*tce| {
                @constCast(tce).deinit(allocator);
            }
            tool_call_events.clearRetainingCapacity();
            parseChunk(ev.data, &text, &thinking, &usage, &stop_reason, &current_block, &reasoning_signature, &tool_call_events, allocator) catch {
                allocator.free(api_key);
                allocator.free(request_body);
                allocator.destroy(ctx);
                stream.completeWithError("json parse error");
                return;
            };

            // Process tool call events
            for (tool_call_events.items) |tce| {
                if (tce.is_start) {
                    // Start a new tool call
                    const content_index = next_content_index;
                    const id = tce.id orelse "";
                    const name = tce.name orelse "";
                    _ = tool_call_tracker_instance.startCall(tce.api_index, content_index, id, name) catch {
                        allocator.free(api_key);
                        allocator.free(request_body);
                        allocator.destroy(ctx);
                        stream.completeWithError("oom tool call start");
                        return;
                    };
                    next_content_index += 1;
                    tool_call_count += 1;

                    // Emit toolcall_start event
                    _ = stream.push(.{
                        .toolcall_start = .{
                            .content_index = content_index,
                            .partial = .{
                                .content = &.{},
                                .api = model.api,
                                .provider = model.provider,
                                .model = model.id,
                                .usage = usage,
                                .stop_reason = stop_reason,
                                .timestamp = std.time.milliTimestamp(),
                            },
                        },
                    }) catch {};
                } else if (tce.arguments_delta) |delta| {
                    // Append arguments delta
                    tool_call_tracker_instance.appendDelta(tce.api_index, delta) catch {
                        allocator.free(api_key);
                        allocator.free(request_body);
                        allocator.destroy(ctx);
                        stream.completeWithError("oom tool call delta");
                        return;
                    };

                    // Emit toolcall_delta event
                    if (tool_call_tracker_instance.getContentIndex(tce.api_index)) |content_index| {
                        _ = stream.push(.{
                            .toolcall_delta = .{
                                .content_index = content_index,
                                .delta = delta,
                                .partial = .{
                                    .content = &.{},
                                    .api = model.api,
                                    .provider = model.provider,
                                    .model = model.id,
                                    .usage = usage,
                                    .stop_reason = stop_reason,
                                    .timestamp = std.time.milliTimestamp(),
                                },
                            },
                        }) catch {};
                    }
                }
            }
        }
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output + usage.cache_read + usage.cache_write;
    usage.calculateCost(model.cost);

    // Complete all tool calls and emit toolcall_end events
    // We need to complete tool calls in content_index order
    var api_indices = std.ArrayList(usize){};
    defer api_indices.deinit(allocator);
    api_indices.ensureTotalCapacity(allocator, tool_call_tracker_instance.count()) catch {};

    // Collect all api indices
    var tc_iter = tool_call_tracker_instance.calls.iterator();
    while (tc_iter.next()) |entry| {
        api_indices.append(allocator, entry.key_ptr.*) catch {};
    }

    // Sort by content_index for consistent ordering
    std.mem.sort(usize, api_indices.items, tool_call_tracker_instance, struct {
        fn lessThan(tracker: tool_call_tracker.ToolCallTracker, a: usize, b: usize) bool {
            const a_idx = tracker.getContentIndex(a) orelse 0;
            const b_idx = tracker.getContentIndex(b) orelse 0;
            return a_idx < b_idx;
        }
    }.lessThan);

    // Build content blocks - thinking first if present, then text, then tool calls
    const has_thinking = thinking.items.len > 0;
    const has_text = text.items.len > 0;
    const content_count: usize = if (has_thinking) 1 else 0;
    const content_count_final = content_count + if (has_text) @as(usize, 1) else @as(usize, 0) + tool_call_count;

    if (content_count_final == 0) {
        // No content - create empty text block with borrowed empty string reference
        // Using a static empty string avoids an unnecessary allocation for the empty case
        var content = allocator.alloc(ai_types.AssistantContent, 1) catch {
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom building result");
            return;
        };
        content[0] = .{ .text = .{ .text = "" } };
        const out = ai_types.AssistantMessage{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = usage,
            .stop_reason = stop_reason,
            .timestamp = std.time.milliTimestamp(),
        };
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.complete(out);
        return;
    }

    var content = allocator.alloc(ai_types.AssistantContent, content_count_final) catch {
        allocator.free(api_key);
        allocator.free(request_body);
        allocator.destroy(ctx);
        stream.completeWithError("oom building result");
        return;
    };
    var idx: usize = 0;

    if (has_thinking) {
        content[idx] = .{ .thinking = .{
            .thinking = allocator.dupe(u8, thinking.items) catch {
                allocator.free(content);
                allocator.free(api_key);
                allocator.free(request_body);
                allocator.destroy(ctx);
                stream.completeWithError("oom building thinking");
                return;
            },
            .thinking_signature = if (reasoning_signature) |sig| allocator.dupe(u8, sig) catch {
                // Free previously allocated content
                for (content[0..idx]) |*block| {
                    switch (block.*) {
                        .thinking => |t| allocator.free(t.thinking),
                        else => {},
                    }
                }
                allocator.free(content);
                allocator.free(api_key);
                allocator.free(request_body);
                allocator.destroy(ctx);
                stream.completeWithError("oom building signature");
                return;
            } else null,
        } };
        idx += 1;
    }

    if (has_text) {
        content[idx] = .{ .text = .{ .text = allocator.dupe(u8, text.items) catch {
            // Free previously allocated content
            for (content[0..idx]) |*block| {
                switch (block.*) {
                    .thinking => |t| {
                        allocator.free(t.thinking);
                        if (t.thinking_signature) |sig| allocator.free(sig);
                    },
                    else => {},
                }
            }
            allocator.free(content);
            allocator.free(api_key);
            allocator.free(request_body);
            allocator.destroy(ctx);
            stream.completeWithError("oom building text");
            return;
        } } };
        idx += 1;
    }

    // Complete tool calls and add to content, emit toolcall_end events
    for (api_indices.items) |api_idx| {
        if (tool_call_tracker_instance.completeCall(api_idx, allocator)) |tc| {
            content[idx] = .{ .tool_call = tc };

            // Dupe the tool_call for the event so it owns its own memory
            // The content array's tool_call is owned by the final message,
            // and the event's tool_call needs its own copies for proper cleanup
            const event_tc = ai_types.ToolCall{
                .id = allocator.dupe(u8, tc.id) catch tc.id,
                .name = allocator.dupe(u8, tc.name) catch tc.name,
                .arguments_json = if (tc.arguments_json.len > 0) allocator.dupe(u8, tc.arguments_json) catch tc.arguments_json else "",
                .thought_signature = if (tc.thought_signature) |sig| allocator.dupe(u8, sig) catch sig else null,
            };

            // Emit toolcall_end event
            _ = stream.push(.{
                .toolcall_end = .{
                    .content_index = idx,
                    .tool_call = event_tc,
                    .partial = .{
                        .content = content[0..idx],
                        .api = model.api,
                        .provider = model.provider,
                        .model = model.id,
                        .usage = usage,
                        .stop_reason = stop_reason,
                        .timestamp = std.time.milliTimestamp(),
                    },
                },
            }) catch {};

            idx += 1;
        }
    }

    const out = ai_types.AssistantMessage{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp = std.time.milliTimestamp(),
    };

    allocator.free(api_key);
    allocator.free(request_body);
    allocator.destroy(ctx);
    stream.complete(out);
}

pub fn streamOpenAICompletions(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const resolved = options orelse ai_types.StreamOptions{};

    var key_owned: ?[]const u8 = null;
    const api_key = blk: {
        if (resolved.api_key) |k| break :blk try allocator.dupe(u8, k);
        key_owned = envApiKey(allocator);
        if (key_owned) |k| break :blk k;
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    const req_body = try buildRequestBody(model, context, resolved, allocator);
    errdefer allocator.free(req_body);

    const s = try allocator.create(ai_types.AssistantMessageEventStream);
    errdefer allocator.destroy(s);
    s.* = ai_types.AssistantMessageEventStream.init(allocator);

    const ctx = try allocator.create(ThreadCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .stream = s,
        .model = model,
        .api_key = @constCast(api_key),
        .request_body = req_body,
        .context = context,
    };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

/// Convert ThinkingLevel enum to reasoning_effort string
fn thinkingLevelToString(level: ai_types.ThinkingLevel) []const u8 {
    return switch (level) {
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

pub fn streamSimpleOpenAICompletions(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};
    return streamOpenAICompletions(model, context, .{
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
        .reasoning_effort = if (o.reasoning) |r| thinkingLevelToString(r) else null,
    }, allocator);
}

pub fn registerOpenAICompletionsApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "openai-completions",
        .stream = streamOpenAICompletions,
        .stream_simple = streamSimpleOpenAICompletions,
    }, null);
}

test "buildRequestBody includes stream_options and tools without memory leak" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "gpt-4o-mini",
        .name = "GPT-4o Mini",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 100,
    };

    const tool = ai_types.Tool{
        .name = "test_tool",
        .description = "A test tool",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"arg\":{\"type\":\"string\"}}}",
    };

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .tool_call = .{
            .id = "call_123",
            .name = "test_tool",
            .arguments_json = "{\"arg\":\"value\"}",
        } },
    };

    const assistant_msg = ai_types.Message{ .assistant = .{
        .content = &assistant_content,
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o-mini",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{assistant_msg},
        .tools = &[_]ai_types.Tool{tool},
    };

    const body = try buildRequestBody(model, ctx, .{ .max_tokens = 100 }, allocator);
    defer allocator.free(body);

    // Verify the body contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, body, "stream_options") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "include_usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "test_tool") != null);
}

test "buildRequestBody with assistant message containing tool_calls" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "gpt-4o-mini",
        .name = "GPT-4o Mini",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 100,
    };

    const assistant_content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "Let me help you with that." } },
        .{ .tool_call = .{
            .id = "call_456",
            .name = "bash",
            .arguments_json = "{\"cmd\":\"ls -la\"}",
        } },
    };

    const assistant_msg = ai_types.Message{ .assistant = .{
        .content = &assistant_content,
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4o-mini",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = std.time.timestamp(),
    } };

    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{assistant_msg},
    };

    const body = try buildRequestBody(model, ctx, .{ .max_tokens = 100 }, allocator);
    defer allocator.free(body);

    // Verify the body contains tool_calls
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "call_456") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ls -la") != null);
}

test "parseChunk does not leak memory with reasoning content" {
    const allocator = std.testing.allocator;

    var text = std.ArrayList(u8){};
    defer text.deinit(allocator);
    var thinking = std.ArrayList(u8){};
    defer thinking.deinit(allocator);
    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;
    var current_block: BlockType = .none;
    var reasoning_signature: ?[]const u8 = null;
    defer if (reasoning_signature) |sig| allocator.free(sig);
    var tool_call_events = std.ArrayList(ToolCallEvent){};
    defer tool_call_events.deinit(allocator);

    // Simulate a chunk with reasoning_content (like DeepSeek responses)
    const chunk_data =
        \\{"choices":[{"delta":{"reasoning_content":"Let me think about this..."}}]}
    ;

    try parseChunk(
        chunk_data,
        &text,
        &thinking,
        &usage,
        &stop_reason,
        &current_block,
        &reasoning_signature,
        &tool_call_events,
        allocator,
    );

    try std.testing.expectEqual(@as(usize, 0), text.items.len);
    try std.testing.expect(thinking.items.len > 0);
    try std.testing.expectEqualStrings("reasoning_content", reasoning_signature.?);
    try std.testing.expectEqual(BlockType.thinking, current_block);
}

test "parseChunk handles multiple chunks without leaking" {
    const allocator = std.testing.allocator;

    var text = std.ArrayList(u8){};
    defer text.deinit(allocator);
    var thinking = std.ArrayList(u8){};
    defer thinking.deinit(allocator);
    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;
    var current_block: BlockType = .none;
    var reasoning_signature: ?[]const u8 = null;
    defer if (reasoning_signature) |sig| allocator.free(sig);
    var tool_call_events = std.ArrayList(ToolCallEvent){};
    defer tool_call_events.deinit(allocator);

    const chunks = [_][]const u8{
        \\{"choices":[{"delta":{"reasoning_content":"First"}}]}
        ,
        \\{"choices":[{"delta":{"reasoning_content":" Second"}}]}
        ,
        \\{"choices":[{"delta":{"content":"Final text"}}]}
        ,
    };

    for (chunks) |chunk| {
        try parseChunk(
            chunk,
            &text,
            &thinking,
            &usage,
            &stop_reason,
            &current_block,
            &reasoning_signature,
            &tool_call_events,
            allocator,
        );
    }

    try std.testing.expectEqualStrings("Final text", text.items);
    try std.testing.expectEqualStrings("First Second", thinking.items);
}

test "parseChunk handles tool_calls without leaking" {
    const allocator = std.testing.allocator;

    var text = std.ArrayList(u8){};
    defer text.deinit(allocator);
    var thinking = std.ArrayList(u8){};
    defer thinking.deinit(allocator);
    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;
    var current_block: BlockType = .none;
    var reasoning_signature: ?[]const u8 = null;
    defer if (reasoning_signature) |sig| allocator.free(sig);
    var tool_call_events = std.ArrayList(ToolCallEvent){};
    defer {
        for (tool_call_events.items) |*tce| {
            @constCast(tce).deinit(allocator);
        }
        tool_call_events.deinit(allocator);
    }

    // Simulate tool call start chunk
    const chunk1 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc123","type":"function","function":{"name":"bash","arguments":""}}]}}]}
    ;

    try parseChunk(
        chunk1,
        &text,
        &thinking,
        &usage,
        &stop_reason,
        &current_block,
        &reasoning_signature,
        &tool_call_events,
        allocator,
    );

    try std.testing.expectEqual(@as(usize, 1), tool_call_events.items.len);
    try std.testing.expect(tool_call_events.items[0].is_start);
    try std.testing.expectEqual(@as(usize, 0), tool_call_events.items[0].api_index);
    try std.testing.expectEqualStrings("call_abc123", tool_call_events.items[0].id.?);
    try std.testing.expectEqualStrings("bash", tool_call_events.items[0].name.?);

    // Free events before clearing
    for (tool_call_events.items) |*tce| {
        @constCast(tce).deinit(allocator);
    }
    tool_call_events.clearRetainingCapacity();

    // Simulate tool call arguments delta chunk
    const chunk2 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"cmd\": \"ls\""}}]}}]}
    ;

    try parseChunk(
        chunk2,
        &text,
        &thinking,
        &usage,
        &stop_reason,
        &current_block,
        &reasoning_signature,
        &tool_call_events,
        allocator,
    );

    try std.testing.expectEqual(@as(usize, 1), tool_call_events.items.len);
    try std.testing.expect(!tool_call_events.items[0].is_start);
    try std.testing.expectEqual(@as(usize, 0), tool_call_events.items[0].api_index);
    try std.testing.expectEqualStrings("{\"cmd\": \"ls\"", tool_call_events.items[0].arguments_delta.?);

    // Free events before clearing
    for (tool_call_events.items) |*tce| {
        @constCast(tce).deinit(allocator);
    }
    tool_call_events.clearRetainingCapacity();

    // Simulate finish_reason for tool_calls
    const chunk3 =
        \\{"choices":[{"finish_reason":"tool_calls"}]}
    ;

    try parseChunk(
        chunk3,
        &text,
        &thinking,
        &usage,
        &stop_reason,
        &current_block,
        &reasoning_signature,
        &tool_call_events,
        allocator,
    );

    try std.testing.expectEqual(ai_types.StopReason.tool_use, stop_reason);
}

test "parseChunk handles multiple tool_calls" {
    const allocator = std.testing.allocator;

    var text = std.ArrayList(u8){};
    defer text.deinit(allocator);
    var thinking = std.ArrayList(u8){};
    defer thinking.deinit(allocator);
    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;
    var current_block: BlockType = .none;
    var reasoning_signature: ?[]const u8 = null;
    defer if (reasoning_signature) |sig| allocator.free(sig);
    var tool_call_events = std.ArrayList(ToolCallEvent){};
    defer {
        for (tool_call_events.items) |*tce| {
            @constCast(tce).deinit(allocator);
        }
        tool_call_events.deinit(allocator);
    }

    // Start first tool call
    const chunk1 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_001","type":"function","function":{"name":"read","arguments":""}}]}}]}
    ;

    try parseChunk(
        chunk1,
        &text,
        &thinking,
        &usage,
        &stop_reason,
        &current_block,
        &reasoning_signature,
        &tool_call_events,
        allocator,
    );

    try std.testing.expectEqual(@as(usize, 1), tool_call_events.items.len);
    try std.testing.expect(tool_call_events.items[0].is_start);
    try std.testing.expectEqualStrings("call_001", tool_call_events.items[0].id.?);

    // Free events before clearing
    for (tool_call_events.items) |*tce| {
        @constCast(tce).deinit(allocator);
    }
    tool_call_events.clearRetainingCapacity();

    // Start second tool call
    const chunk2 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_002","type":"function","function":{"name":"write","arguments":""}}]}}]}
    ;

    try parseChunk(
        chunk2,
        &text,
        &thinking,
        &usage,
        &stop_reason,
        &current_block,
        &reasoning_signature,
        &tool_call_events,
        allocator,
    );

    try std.testing.expectEqual(@as(usize, 1), tool_call_events.items.len);
    try std.testing.expect(tool_call_events.items[0].is_start);
    try std.testing.expectEqualStrings("call_002", tool_call_events.items[0].id.?);
    try std.testing.expectEqualStrings("write", tool_call_events.items[0].name.?);

    // Free events before clearing
    for (tool_call_events.items) |*tce| {
        @constCast(tce).deinit(allocator);
    }
    tool_call_events.clearRetainingCapacity();

    // Delta for first tool call
    const chunk3 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}]}
    ;

    try parseChunk(
        chunk3,
        &text,
        &thinking,
        &usage,
        &stop_reason,
        &current_block,
        &reasoning_signature,
        &tool_call_events,
        allocator,
    );

    try std.testing.expectEqual(@as(usize, 1), tool_call_events.items.len);
    try std.testing.expect(!tool_call_events.items[0].is_start);
    try std.testing.expectEqual(@as(usize, 0), tool_call_events.items[0].api_index);
}
