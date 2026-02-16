const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const json_writer = @import("json_writer");

fn env(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
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

fn buildBody(model: ai_types.Model, context: ai_types.Context, options: ai_types.StreamOptions, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();

    try w.writeStringField("model", model.id);
    try w.writeBoolField("stream", true);

    try w.writeKey("messages");
    try w.beginArray();

    if (context.system_prompt) |sp| {
        try w.beginObject();
        try w.writeStringField("role", "system");
        try w.writeStringField("content", sp);
        try w.endObject();
    }

    for (context.messages) |m| {
        var text = std.ArrayList(u8){};
        defer text.deinit(allocator);
        try appendMessageText(m, &text, allocator);

        const role: []const u8 = switch (m) {
            .assistant => "assistant",
            .tool_result => "tool",
            else => "user",
        };

        try w.beginObject();
        try w.writeStringField("role", role);
        try w.writeStringField("content", text.items);

        // Check for tool_calls on assistant messages
        if (m == .assistant) {
            var has_tool_calls = false;
            for (m.assistant.content) |c| {
                if (c == .tool_call) {
                    has_tool_calls = true;
                    break;
                }
            }
            if (has_tool_calls) {
                try w.writeKey("tool_calls");
                try w.beginArray();
                for (m.assistant.content) |c| {
                    if (c == .tool_call) {
                        const tc = c.tool_call;
                        try w.beginObject();
                        try w.writeStringField("id", tc.id);
                        try w.writeStringField("type", "function");
                        try w.writeKey("function");
                        try w.beginObject();
                        try w.writeStringField("name", tc.name);
                        try w.writeStringField("arguments", tc.arguments_json);
                        try w.endObject();
                        try w.endObject();
                    }
                }
                try w.endArray();
            }
        }

        try w.endObject();
    }

    try w.endArray();

    // Add tools if provided (OpenAI-compatible format)
    if (context.tools) |tools| {
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

    try w.writeKey("options");
    try w.beginObject();
    if (options.temperature) |t| {
        try w.writeKey("temperature");
        try w.writeFloat(t);
    }
    try w.writeIntField("num_predict", options.max_tokens orelse model.max_tokens);
    try w.endObject();

    try w.endObject();
    return buf.toOwnedSlice(allocator);
}

/// Parsed tool call from Ollama response
const ParsedToolCall = struct {
    name: []const u8,
    arguments_json: []const u8,
};

/// Parse result from an Ollama response line
const OllamaParseResult = struct {
    text: ?[]const u8 = null,
    tool_calls: []const ParsedToolCall = &.{},
    usage: ai_types.Usage = .{},
    done_reason: ?[]const u8 = null,

    fn deinit(self: *const OllamaParseResult, allocator: std.mem.Allocator) void {
        if (self.text) |t| allocator.free(t);
        for (self.tool_calls) |tc| {
            allocator.free(tc.name);
            allocator.free(tc.arguments_json);
        }
        allocator.free(self.tool_calls);
        if (self.done_reason) |dr| allocator.free(dr);
    }
};

/// Stringify a std.json.Value to a buffer (helper for tool call arguments)
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

/// Parse an Ollama response line and extract text, tool calls, usage, and done reason
fn parseLineExtended(line: []const u8, allocator: std.mem.Allocator) ?OllamaParseResult {
    if (line.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    var result = OllamaParseResult{};

    // Extract message content and tool calls
    if (obj.get("message")) |m| {
        if (m == .object) {
            // Extract text content
            if (m.object.get("content")) |c| {
                if (c == .string and c.string.len > 0) {
                    result.text = allocator.dupe(u8, c.string) catch return null;
                }
            }

            // Extract tool calls
            if (m.object.get("tool_calls")) |tcs| {
                if (tcs == .array) {
                    var tool_calls_list = std.ArrayList(ParsedToolCall){};
                    defer tool_calls_list.deinit(allocator);

                    for (tcs.array.items) |tc| {
                        if (tc == .object) {
                            if (tc.object.get("function")) |func| {
                                if (func == .object) {
                                    const name = if (func.object.get("name")) |n|
                                        if (n == .string) n.string else ""
                                    else "";

                                    // Stringify arguments object to JSON
                                    const args_json = if (func.object.get("arguments")) |args| blk: {
                                        var buf = std.ArrayList(u8){};
                                        stringifyJsonValue(args, &buf, allocator) catch break :blk "";
                                        break :blk buf.toOwnedSlice(allocator) catch "";
                                    } else "{}";

                                    const name_copy = allocator.dupe(u8, name) catch {
                                        allocator.free(args_json);
                                        continue;
                                    };

                                    tool_calls_list.append(allocator, .{
                                        .name = name_copy,
                                        .arguments_json = args_json,
                                    }) catch {
                                        allocator.free(name_copy);
                                        allocator.free(args_json);
                                        continue;
                                    };
                                }
                            }
                        }
                    }

                    result.tool_calls = tool_calls_list.toOwnedSlice(allocator) catch return null;
                }
            }
        }
    }

    // Extract usage
    if (obj.get("prompt_eval_count")) |v| {
        if (v == .integer) result.usage.input = @intCast(v.integer);
    }
    if (obj.get("eval_count")) |v| {
        if (v == .integer) result.usage.output = @intCast(v.integer);
    }

    // Extract done reason
    if (obj.get("done_reason")) |dr| {
        if (dr == .string) {
            result.done_reason = allocator.dupe(u8, dr.string) catch null;
        }
    }

    return result;
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    base_url: []u8,
    api_key: ?[]u8,
    body: []u8,
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

fn runThread(ctx: *ThreadCtx) void {
    // Save values from ctx that we need after freeing ctx
    const allocator = ctx.allocator;
    const stream = ctx.stream;
    const model = ctx.model;
    const base_url = ctx.base_url;
    const api_key = ctx.api_key;
    const body = ctx.body;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(allocator, "{s}/api/chat", .{base_url}) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom url");
        return;
    };
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("invalid URL");
        return;
    };

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    headers.append(allocator, .{ .name = "content-type", .value = "application/json" }) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom headers");
        return;
    };

    var auth_value: ?[]u8 = null;
    defer if (auth_value) |v| allocator.free(v);

    if (api_key) |k| {
        auth_value = std.fmt.allocPrint(allocator, "Bearer {s}", .{k}) catch {
            allocator.free(base_url);
            allocator.free(k);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("oom auth header");
            return;
        };
        headers.append(allocator, .{ .name = "authorization", .value = auth_value.? }) catch {
            allocator.free(base_url);
            allocator.free(k);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("oom headers");
            return;
        };
    }

    var req = client.request(.POST, uri, .{ .extra_headers = headers.items }) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("request failed");
        return;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    req.sendBodyComplete(body) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("send failed");
        return;
    };

    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("receive failed");
        return;
    };

    if (response.head.status != .ok) {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("ollama request failed");
        return;
    }

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var line = std.ArrayList(u8){};
    defer line.deinit(allocator);

    // Content block accumulators
    var content_blocks = std.ArrayList(ai_types.AssistantContent){};
    defer content_blocks.deinit(allocator);
    var current_text = std.ArrayList(u8){};
    defer current_text.deinit(allocator);

    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;
    var tool_call_counter: usize = 0;
    var has_tool_calls = false;

    // Emit start event
    const partial_start = createPartialMessage(model);
    stream.push(.{ .start = .{ .partial = partial_start } }) catch {};

    while (true) {
        const n = reader.*.readSliceShort(&read_buf) catch {
            allocator.free(base_url);
            if (api_key) |k| allocator.free(k);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("read failed");
            return;
        };
        if (n == 0) break;

        for (read_buf[0..n]) |ch| {
            if (ch == '\n') {
                if (parseLineExtended(line.items, allocator)) |*result| {
                    defer result.deinit(allocator);

                    // Update usage
                    if (result.usage.input > 0) usage.input = result.usage.input;
                    if (result.usage.output > 0) usage.output = result.usage.output;

                    // Update stop reason
                    if (result.done_reason) |dr| {
                        if (std.mem.eql(u8, dr, "length")) {
                            stop_reason = .length;
                        } else if (std.mem.eql(u8, dr, "stop")) {
                            stop_reason = .stop;
                        }
                    }

                    // Process text content
                    if (result.text) |text_content| {
                        const prev_len = current_text.items.len;
                        current_text.appendSlice(allocator, text_content) catch {};

                        // Emit text_start if this is the first text
                        if (prev_len == 0 and current_text.items.len > 0) {
                            const partial = createPartialMessage(model);
                            stream.push(.{ .text_start = .{
                                .content_index = content_blocks.items.len,
                                .partial = partial,
                            } }) catch {};
                        }

                        // Emit text_delta with the newly appended content
                        if (current_text.items.len > prev_len) {
                            const delta = current_text.items[prev_len..];
                            const partial = createPartialMessage(model);
                            stream.push(.{ .text_delta = .{
                                .content_index = content_blocks.items.len,
                                .delta = delta,
                                .partial = partial,
                            } }) catch {};
                        }
                    }

                    // Process tool calls
                    for (result.tool_calls) |tc| {
                        has_tool_calls = true;

                        // Close text block if we have accumulated text
                        if (current_text.items.len > 0) {
                            const text_copy = allocator.dupe(u8, current_text.items) catch continue;
                            content_blocks.append(allocator, .{ .text = .{
                                .text = text_copy,
                            } }) catch {
                                allocator.free(text_copy);
                                continue;
                            };
                            const partial = createPartialMessage(model);
                            stream.push(.{ .text_end = .{
                                .content_index = content_blocks.items.len - 1,
                                .content = current_text.items,
                                .partial = partial,
                            } }) catch {};
                            current_text.clearRetainingCapacity();
                        }

                        // Generate unique ID for the tool call
                        tool_call_counter += 1;
                        const timestamp = std.time.milliTimestamp();
                        const tool_id = std.fmt.allocPrint(
                            allocator,
                            "{s}_{}_{}",
                            .{ tc.name, timestamp, tool_call_counter },
                        ) catch continue;

                        const tool_name = allocator.dupe(u8, tc.name) catch {
                            allocator.free(tool_id);
                            continue;
                        };
                        const tool_args = allocator.dupe(u8, tc.arguments_json) catch {
                            allocator.free(tool_id);
                            allocator.free(tool_name);
                            continue;
                        };

                        const content_idx = content_blocks.items.len;

                        // Emit toolcall_start
                        stream.push(.{ .toolcall_start = .{
                            .content_index = content_idx,
                            .partial = createPartialMessage(model),
                        } }) catch {
                            allocator.free(tool_id);
                            allocator.free(tool_name);
                            allocator.free(tool_args);
                            continue;
                        };

                        // Emit toolcall_delta with args_json
                        stream.push(.{ .toolcall_delta = .{
                            .content_index = content_idx,
                            .delta = tool_args,
                            .partial = createPartialMessage(model),
                        } }) catch {};

                        // Build the ToolCall struct for storage and toolcall_end
                        const tool_call_struct = ai_types.ToolCall{
                            .id = tool_id,
                            .name = tool_name,
                            .arguments_json = tool_args,
                        };

                        // Store the tool call in content_blocks
                        content_blocks.append(allocator, .{ .tool_call = tool_call_struct }) catch {
                            allocator.free(tool_id);
                            allocator.free(tool_name);
                            allocator.free(tool_args);
                            continue;
                        };

                        // Emit toolcall_end with the ToolCall struct
                        stream.push(.{ .toolcall_end = .{
                            .content_index = content_idx,
                            .tool_call = tool_call_struct,
                            .partial = createPartialMessage(model),
                        } }) catch {};
                    }
                }
                line.clearRetainingCapacity();
            } else {
                line.append(allocator, ch) catch {
                    allocator.free(base_url);
                    if (api_key) |k| allocator.free(k);
                    allocator.free(body);
                    allocator.destroy(ctx);
                    stream.completeWithError("oom line");
                    return;
                };
            }
        }
    }

    // Process any remaining content in the line buffer
    if (line.items.len > 0) {
        if (parseLineExtended(line.items, allocator)) |*result| {
            defer result.deinit(allocator);

            // Update usage
            if (result.usage.input > 0) usage.input = result.usage.input;
            if (result.usage.output > 0) usage.output = result.usage.output;

            // Update stop reason
            if (result.done_reason) |dr| {
                if (std.mem.eql(u8, dr, "length")) {
                    stop_reason = .length;
                } else if (std.mem.eql(u8, dr, "stop")) {
                    stop_reason = .stop;
                }
            }

            // Process text content
            if (result.text) |text_content| {
                const prev_len = current_text.items.len;
                current_text.appendSlice(allocator, text_content) catch {};

                // Emit text_start if this is the first text
                if (prev_len == 0 and current_text.items.len > 0) {
                    const partial = createPartialMessage(model);
                    stream.push(.{ .text_start = .{
                        .content_index = content_blocks.items.len,
                        .partial = partial,
                    } }) catch {};
                }

                // Emit text_delta with the newly appended content
                if (current_text.items.len > prev_len) {
                    const delta = current_text.items[prev_len..];
                    const partial = createPartialMessage(model);
                    stream.push(.{ .text_delta = .{
                        .content_index = content_blocks.items.len,
                        .delta = delta,
                        .partial = partial,
                    } }) catch {};
                }
            }

            // Process tool calls
            for (result.tool_calls) |tc| {
                has_tool_calls = true;

                // Close text block if we have accumulated text
                if (current_text.items.len > 0) {
                    const text_copy = allocator.dupe(u8, current_text.items) catch continue;
                    content_blocks.append(allocator, .{ .text = .{
                        .text = text_copy,
                    } }) catch {
                        allocator.free(text_copy);
                        continue;
                    };
                    const partial = createPartialMessage(model);
                    stream.push(.{ .text_end = .{
                        .content_index = content_blocks.items.len - 1,
                        .content = current_text.items,
                        .partial = partial,
                    } }) catch {};
                    current_text.clearRetainingCapacity();
                }

                // Generate unique ID for the tool call
                tool_call_counter += 1;
                const timestamp = std.time.milliTimestamp();
                const tool_id = std.fmt.allocPrint(
                    allocator,
                    "{s}_{}_{}",
                    .{ tc.name, timestamp, tool_call_counter },
                ) catch continue;

                const tool_name = allocator.dupe(u8, tc.name) catch {
                    allocator.free(tool_id);
                    continue;
                };
                const tool_args = allocator.dupe(u8, tc.arguments_json) catch {
                    allocator.free(tool_id);
                    allocator.free(tool_name);
                    continue;
                };

                const content_idx = content_blocks.items.len;

                // Emit toolcall_start
                stream.push(.{ .toolcall_start = .{
                    .content_index = content_idx,
                    .partial = createPartialMessage(model),
                } }) catch {
                    allocator.free(tool_id);
                    allocator.free(tool_name);
                    allocator.free(tool_args);
                    continue;
                };

                // Emit toolcall_delta with args_json
                stream.push(.{ .toolcall_delta = .{
                    .content_index = content_idx,
                    .delta = tool_args,
                    .partial = createPartialMessage(model),
                } }) catch {};

                // Build the ToolCall struct for storage and toolcall_end
                const tool_call_struct = ai_types.ToolCall{
                    .id = tool_id,
                    .name = tool_name,
                    .arguments_json = tool_args,
                };

                // Store the tool call in content_blocks
                content_blocks.append(allocator, .{ .tool_call = tool_call_struct }) catch {
                    allocator.free(tool_id);
                    allocator.free(tool_name);
                    allocator.free(tool_args);
                    continue;
                };

                // Emit toolcall_end with the ToolCall struct
                stream.push(.{ .toolcall_end = .{
                    .content_index = content_idx,
                    .tool_call = tool_call_struct,
                    .partial = createPartialMessage(model),
                } }) catch {};
            }
        }
    }

    // Close final text block if we have accumulated text
    if (current_text.items.len > 0) {
        const text_copy = allocator.dupe(u8, current_text.items) catch "";
        content_blocks.append(allocator, .{ .text = .{
            .text = text_copy,
        } }) catch {};
        const partial = createPartialMessage(model);
        stream.push(.{ .text_end = .{
            .content_index = content_blocks.items.len - 1,
            .content = current_text.items,
            .partial = partial,
        } }) catch {};
    }

    // Set stop_reason to tool_use if we have tool calls
    if (has_tool_calls) {
        stop_reason = .tool_use;
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output;
    usage.calculateCost(model.cost);

    // If no content blocks were collected, add an empty text block
    if (content_blocks.items.len == 0) {
        content_blocks.append(allocator, .{ .text = .{ .text = "" } }) catch {};
    }

    const content_slice = content_blocks.toOwnedSlice(allocator) catch {
        allocator.free(base_url);
        if (api_key) |k| allocator.free(k);
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
    if (api_key) |k| allocator.free(k);
    allocator.free(body);
    allocator.destroy(ctx);

    stream.complete(out);
}

pub fn streamOllama(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    // Ollama supports two modes:
    // 1. Local server (localhost:11434) - default, no auth required
    // 2. Cloud API (ollama.com) - requires OLLAMA_API_KEY via Authorization header
    const api_key: ?[]u8 = blk: {
        if (o.api_key) |k| break :blk try allocator.dupe(u8, k);
        if (env(allocator, "OLLAMA_API_KEY")) |k| break :blk @constCast(k);
        break :blk null;
    };
    errdefer if (api_key) |k| allocator.free(k);

    const base_url = blk: {
        if (model.base_url.len > 0) break :blk try allocator.dupe(u8, model.base_url);
        if (env(allocator, "OLLAMA_BASE_URL")) |v| break :blk @constCast(v);
        // When API key is present, use cloud endpoint (https://ollama.com)
        if (api_key != null) break :blk try allocator.dupe(u8, "https://ollama.com");
        // Otherwise use local server
        break :blk try allocator.dupe(u8, "http://127.0.0.1:11434");
    };
    errdefer allocator.free(base_url);

    const body = try buildBody(model, context, o, allocator);
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
        .base_url = base_url,
        .api_key = api_key,
        .body = body,
    };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

pub fn streamSimpleOllama(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};
    return streamOllama(model, context, .{
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
    }, allocator);
}

pub fn registerOllamaApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "ollama",
        .stream = streamOllama,
        .stream_simple = streamSimpleOllama,
    }, null);
}

test "buildBody includes model stream options and messages" {
    const model = ai_types.Model{
        .id = "llama3.2:1b",
        .name = "Llama 3.2 1B",
        .api = "ollama",
        .provider = "ollama",
        .base_url = "",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 131_072,
        .max_tokens = 64,
    };

    const msg = ai_types.Message{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 1,
    } };

    const ctx = ai_types.Context{ .system_prompt = "be concise", .messages = &[_]ai_types.Message{msg} };

    const body = try buildBody(model, ctx, .{ .temperature = 0.2, .max_tokens = 12 }, std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"llama3.2:1b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"num_predict\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hello\"") != null);
}

test "parseLineExtended - text content" {
    const allocator = std.testing.allocator;
    const line = "{\"message\":{\"role\":\"assistant\",\"content\":\"Hello world\"},\"done\":false}";

    var result = parseLineExtended(line, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.text != null);
    try std.testing.expectEqualStrings("Hello world", result.text.?);
    try std.testing.expectEqual(@as(usize, 0), result.tool_calls.len);
}

test "parseLineExtended - usage and done reason" {
    const allocator = std.testing.allocator;
    const line = "{\"message\":{\"role\":\"assistant\",\"content\":\"test\"},\"done\":true,\"prompt_eval_count\":10,\"eval_count\":5,\"done_reason\":\"length\"}";

    var result = parseLineExtended(line, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.text != null);
    try std.testing.expectEqualStrings("test", result.text.?);
    try std.testing.expectEqual(@as(u64, 10), result.usage.input);
    try std.testing.expectEqual(@as(u64, 5), result.usage.output);
    try std.testing.expect(result.done_reason != null);
    try std.testing.expectEqualStrings("length", result.done_reason.?);
}

test "parseLineExtended - tool call with arguments" {
    const allocator = std.testing.allocator;
    const line =
        \\{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"bash","arguments":{"cmd":"ls -la"}}}]},"done":true}
    ;

    var result = parseLineExtended(line, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);

    const tc = result.tool_calls[0];
    try std.testing.expectEqualStrings("bash", tc.name);
    try std.testing.expectEqualStrings("{\"cmd\":\"ls -la\"}", tc.arguments_json);
}

test "parseLineExtended - multiple tool calls" {
    const allocator = std.testing.allocator;
    const line =
        \\{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"bash","arguments":{"cmd":"ls"}}},{"function":{"name":"read_file","arguments":{"path":"test.txt"}}}]},"done":true}
    ;

    var result = parseLineExtended(line, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.tool_calls.len);

    try std.testing.expectEqualStrings("bash", result.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", result.tool_calls[0].arguments_json);

    try std.testing.expectEqualStrings("read_file", result.tool_calls[1].name);
    try std.testing.expectEqualStrings("{\"path\":\"test.txt\"}", result.tool_calls[1].arguments_json);
}

test "parseLineExtended - tool call with empty arguments" {
    const allocator = std.testing.allocator;
    const line =
        \\{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"no_args","arguments":{}}}]},"done":true}
    ;

    var result = parseLineExtended(line, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);

    const tc = result.tool_calls[0];
    try std.testing.expectEqualStrings("no_args", tc.name);
    try std.testing.expectEqualStrings("{}", tc.arguments_json);
}

test "parseLineExtended - mixed text and tool calls" {
    const allocator = std.testing.allocator;
    const line =
        \\{"model":"llama3.2","message":{"role":"assistant","content":"Let me help you.","tool_calls":[{"function":{"name":"search","arguments":{"query":"test"}}}]},"done":true}
    ;

    var result = parseLineExtended(line, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.text != null);
    try std.testing.expectEqualStrings("Let me help you.", result.text.?);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);
    try std.testing.expectEqualStrings("search", result.tool_calls[0].name);
}

test "parseLineExtended - tool call with nested arguments" {
    const allocator = std.testing.allocator;
    const line =
        \\{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"execute","arguments":{"options":{"verbose":true,"timeout":30},"command":"echo hello"}}}]},"done":true}
    ;

    var result = parseLineExtended(line, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);

    const tc = result.tool_calls[0];
    try std.testing.expectEqualStrings("execute", tc.name);
    // Verify nested structure is preserved
    try std.testing.expect(std.mem.indexOf(u8, tc.arguments_json, "\"options\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.arguments_json, "\"verbose\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.arguments_json, "\"command\":\"echo hello\"") != null);
}

test "parseLineExtended - tool call with array arguments" {
    const allocator = std.testing.allocator;
    const line =
        \\{"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"multi_cmd","arguments":{"commands":["ls","pwd","whoami"]}}}]},"done":true}
    ;

    var result = parseLineExtended(line, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.len);

    const tc = result.tool_calls[0];
    try std.testing.expectEqualStrings("multi_cmd", tc.name);
    try std.testing.expect(std.mem.indexOf(u8, tc.arguments_json, "[\"ls\",\"pwd\",\"whoami\"]") != null);
}
