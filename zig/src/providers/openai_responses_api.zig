const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");
const tool_call_tracker = @import("tool_call_tracker");
const sanitize = @import("sanitize");
const retry_util = @import("retry");
const pre_transform = @import("pre_transform");

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

fn envApiKey(allocator: std.mem.Allocator) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY") catch null;
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

fn buildRequestBody(model: ai_types.Model, context: ai_types.Context, options: ai_types.StreamOptions, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    // Pre-transform messages: cross-model thinking conversion, tool ID normalization,
    // synthetic tool results for orphaned calls, aborted message filtering
    var transformed = try pre_transform.preTransform(allocator, context.messages, .{
        .target_api = model.api,
        .target_provider = model.provider,
        .target_model_id = model.id,
        .max_tool_id_len = 40, // OpenAI max tool call ID length
        .insert_synthetic_results = true,
        .tools = context.tools,
    });
    defer transformed.deinit();

    var tx_context = context;
    tx_context.messages = transformed.messages;

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try w.writeStringField("model", model.id);

    // Add tools if present
    if (context.tools) |tools| {
        if (tools.len > 0) {
            try w.writeKey("tools");
            try w.beginArray();
            for (tools) |tool| {
                try w.beginObject();
                try w.writeStringField("type", "function");
                try w.writeStringField("name", tool.name);
                try w.writeStringField("description", tool.description);
                try w.writeBoolField("strict", true);
                try w.writeKey("parameters");
                try w.writeRawJson(tool.parameters_schema_json);
                try w.endObject();
            }
            try w.endArray();
        }
    }

    try w.writeBoolField("stream", true);
    try w.writeIntField("max_output_tokens", options.max_tokens orelse model.max_tokens);

    // Add reasoning parameters for reasoning models (o1, o3, etc.)
    if (model.reasoning) {
        try w.writeKey("reasoning");
        try w.beginObject();
        if (options.reasoning_effort) |effort| {
            try w.writeStringField("effort", effort);
        } else {
            try w.writeStringField("effort", "medium"); // default
        }
        if (options.reasoning_summary) |summary| {
            try w.writeStringField("summary", summary);
        } else {
            try w.writeStringField("summary", "auto"); // default
        }
        try w.endObject();

        try w.writeKey("include");
        try w.beginArray();
        try w.writeString("reasoning.encrypted_content");
        try w.endArray();
    }

    // Privacy: don't store requests for OpenAI training
    if (std.mem.indexOf(u8, model.base_url, "openai.com") != null) {
        try w.writeBoolField("store", false);
    }

    // Service tier for OpenAI Responses API
    if (options.service_tier) |tier| {
        const tier_str: []const u8 = switch (tier) {
            .default => "default",
            .flex => "flex",
            .priority => "priority",
        };
        try w.writeStringField("service_tier", tier_str);
    }

    // Session-based caching
    if (options.session_id) |sid| {
        if (options.cache_retention) |retention| {
            if (retention != .none) {
                try w.writeStringField("prompt_cache_key", sid);
            }
        }
    }

    // Cache retention for OpenAI API
    if (options.cache_retention) |retention| {
        if (retention == .long and std.mem.indexOf(u8, model.base_url, "openai.com") != null) {
            try w.writeStringField("prompt_cache_retention", "24h");
        }
    }

    try w.writeKey("input");
    try w.beginArray();

    // Collect tool call IDs for orphaned tool result filtering
    var tool_call_ids = collectToolCallIds(allocator, tx_context.messages) catch std.StringHashMap(void).init(allocator);
    defer freeToolCallIds(allocator, &tool_call_ids);

    if (context.system_prompt) |sp| {
        try w.beginObject();
        const system_role: []const u8 = if (model.reasoning) "developer" else "system";
        try w.writeStringField("role", system_role);
        // Sanitize system prompt to remove unpaired surrogates
        const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, sp);
        defer {
            if (sanitized.ptr != sp.ptr) {
                allocator.free(@constCast(sanitized));
            }
        }
        try w.writeStringField("content", sanitized);
        try w.endObject();
    }

    // GPT-5 "juice" workaround: when reasoning is disabled for GPT-5 models,
    // inject a developer message to restore model capability
    if (std.mem.startsWith(u8, model.name, "gpt-5") and !options.reasoning_enabled) {
        try w.beginObject();
        try w.writeStringField("role", "developer");
        try w.writeStringField("content", "# Juice: 0 !important");
        try w.endObject();
    }

    for (tx_context.messages) |m| {
        // Skip aborted/error assistant messages
        if (shouldSkipAssistant(m)) continue;

        // Skip orphaned tool results
        if (isOrphanedToolResult(m, &tool_call_ids)) continue;

        switch (m) {
            .user => |u| {
                try w.beginObject();
                try w.writeStringField("type", "message");
                try w.writeStringField("role", "user");

                // Handle content
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
                                    try w.writeStringField("type", "input_text");
                                    try w.writeStringField("text", t.text);
                                    try w.endObject();
                                },
                                .image => |img| {
                                    try w.beginObject();
                                    try w.writeStringField("type", "input_image");
                                    try w.writeStringField("image_url", img.data);
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
                // Output each content item as appropriate type
                for (a.content) |c| {
                    switch (c) {
                        .text => |t| {
                            try w.beginObject();
                            try w.writeStringField("type", "message");
                            try w.writeStringField("role", "assistant");
                            try w.writeStringField("content", t.text);
                            try w.endObject();
                        },
                        .thinking => |t| {
                            // Thinking content - skip or handle as needed
                            _ = t;
                        },
                        .tool_call => |tc| {
                            // Output as function_call item
                            try w.beginObject();
                            try w.writeStringField("type", "function_call");
                            try w.writeStringField("call_id", tc.id);
                            try w.writeStringField("name", tc.name);
                            try w.writeStringField("arguments", tc.arguments_json);
                            try w.endObject();
                        },
                    }
                }
            },
            .tool_result => |tr| {
                // Output as function_call_output
                var result_text = std.ArrayList(u8){};
                defer result_text.deinit(allocator);
                for (tr.content) |c| {
                    switch (c) {
                        .text => |t| {
                            if (result_text.items.len > 0) try result_text.append(allocator, '\n');
                            try result_text.appendSlice(allocator, t.text);
                        },
                        .image => {},
                    }
                }
                try w.beginObject();
                try w.writeStringField("type", "function_call_output");
                try w.writeStringField("call_id", tr.tool_call_id);
                try w.writeStringField("output", result_text.items);
                try w.endObject();
            },
        }
    }

    try w.endArray();
    try w.endObject();
    return buf.toOwnedSlice(allocator);
}

/// Build compound ID for OpenAI Responses tool calls: {call_id}|{item_id}
fn buildCompoundId(allocator: std.mem.Allocator, call_id: []const u8, item_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}|{s}", .{ call_id, item_id });
}

/// Event parsed from a response SSE event
const ParsedEvent = struct {
    event_type: EventType,
    output_index: usize,

    const EventType = union(enum) {
        text_delta: []const u8,
        output_item_added: OutputItem,
        function_call_args_delta: struct { item_id: []const u8, delta: []const u8 },
        function_call_args_done: struct { item_id: []const u8, arguments: []const u8 },
        reasoning_delta: []const u8,
        reasoning_done: void,
        output_item_done: OutputItem,
        completed: CompletedInfo,
    };

    const OutputItem = struct {
        item_type: []const u8,
        id: ?[]const u8,
        call_id: ?[]const u8,
        name: ?[]const u8,
        arguments: ?[]const u8,
    };

    const CompletedInfo = struct {
        status: ?[]const u8,
        usage: ?ai_types.Usage,
    };
};

/// Parse a response event from the SSE data
/// The returned ParsedEvent contains slices that point into `json_value` - they are
/// only valid as long as `json_value` remains valid.
fn parseResponseEventFromValue(json_value: std.json.Value) ?ParsedEvent {
    if (json_value != .object) return null;
    const obj = json_value.object;

    const type_val = obj.get("type") orelse return null;
    if (type_val != .string) return null;
    const event_type_str = type_val.string;

    const output_index: usize = if (obj.get("output_index")) |oi|
        if (oi == .integer) @intCast(oi.integer) else 0
    else
        0;

    if (std.mem.eql(u8, event_type_str, "response.output_text.delta")) {
        const delta = obj.get("delta") orelse return null;
        if (delta != .string) return null;
        return .{
            .event_type = .{ .text_delta = delta.string },
            .output_index = output_index,
        };
    }

    if (std.mem.eql(u8, event_type_str, "response.output_item.added")) {
        const item_val = obj.get("item") orelse return null;
        if (item_val != .object) return null;
        const item = item_val.object;

        const output_item: ParsedEvent.OutputItem = .{
            .item_type = if (item.get("type")) |t| if (t == .string) t.string else "" else "",
            .id = if (item.get("id")) |i| if (i == .string) i.string else null else null,
            .call_id = if (item.get("call_id")) |c| if (c == .string) c.string else null else null,
            .name = if (item.get("name")) |n| if (n == .string) n.string else null else null,
            .arguments = if (item.get("arguments")) |a| if (a == .string) a.string else null else null,
        };

        return .{
            .event_type = .{ .output_item_added = output_item },
            .output_index = output_index,
        };
    }

    if (std.mem.eql(u8, event_type_str, "response.function_call_arguments.delta")) {
        const item_id = obj.get("item_id") orelse return null;
        if (item_id != .string) return null;
        const delta = obj.get("delta") orelse return null;
        if (delta != .string) return null;

        return .{
            .event_type = .{ .function_call_args_delta = .{
                .item_id = item_id.string,
                .delta = delta.string,
            } },
            .output_index = output_index,
        };
    }

    if (std.mem.eql(u8, event_type_str, "response.function_call_arguments.done")) {
        const item_id = obj.get("item_id") orelse return null;
        if (item_id != .string) return null;
        const arguments = obj.get("arguments") orelse return null;
        if (arguments != .string) return null;

        return .{
            .event_type = .{ .function_call_args_done = .{
                .item_id = item_id.string,
                .arguments = arguments.string,
            } },
            .output_index = output_index,
        };
    }

    if (std.mem.eql(u8, event_type_str, "response.reasoning.delta")) {
        const delta = obj.get("delta") orelse return null;
        if (delta != .string) return null;

        return .{
            .event_type = .{ .reasoning_delta = delta.string },
            .output_index = output_index,
        };
    }

    if (std.mem.eql(u8, event_type_str, "response.reasoning.done")) {
        return .{
            .event_type = .reasoning_done,
            .output_index = output_index,
        };
    }

    if (std.mem.eql(u8, event_type_str, "response.output_item.done")) {
        const item_val = obj.get("item") orelse return null;
        if (item_val != .object) return null;
        const item = item_val.object;

        const output_item: ParsedEvent.OutputItem = .{
            .item_type = if (item.get("type")) |t| if (t == .string) t.string else "" else "",
            .id = if (item.get("id")) |i| if (i == .string) i.string else null else null,
            .call_id = if (item.get("call_id")) |c| if (c == .string) c.string else null else null,
            .name = if (item.get("name")) |n| if (n == .string) n.string else null else null,
            .arguments = if (item.get("arguments")) |a| if (a == .string) a.string else null else null,
        };

        return .{
            .event_type = .{ .output_item_done = output_item },
            .output_index = output_index,
        };
    }

    if (std.mem.eql(u8, event_type_str, "response.completed")) {
        var info: ParsedEvent.CompletedInfo = .{
            .status = null,
            .usage = null,
        };

        if (obj.get("response")) |resp| {
            if (resp == .object) {
                if (resp.object.get("status")) |st| {
                    if (st == .string) info.status = st.string;
                }
                if (resp.object.get("usage")) |u| {
                    if (u == .object) {
                        var usage = ai_types.Usage{};
                        if (u.object.get("input_tokens")) |v| {
                            if (v == .integer) usage.input = @intCast(v.integer);
                        }
                        if (u.object.get("output_tokens")) |v| {
                            if (v == .integer) usage.output = @intCast(v.integer);
                        }
                        usage.total_tokens = usage.input + usage.output;
                        info.usage = usage;
                    }
                }
            }
        }

        return .{
            .event_type = .{ .completed = info },
            .output_index = output_index,
        };
    }

    return null;
}

/// Parse a response event from raw SSE data bytes
/// Allocates temporary memory for JSON parsing which is freed before returning.
/// Note: The returned ParsedEvent contains slices that are invalid after this function returns!
/// For tests, use parseResponseEventFromValue with a long-lived JSON value instead.
fn parseResponseEventToStruct(data: []const u8, allocator: std.mem.Allocator) ?ParsedEvent {
    if (std.mem.eql(u8, data, "[DONE]")) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();

    return parseResponseEventFromValue(parsed.value);
}

/// Tracking state for in-progress tool calls
const ToolCallState = struct {
    content_index: usize,
    compound_id: []const u8,
    name: []const u8,
};

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *ai_types.AssistantMessageEventStream,
    model: ai_types.Model,
    api_key: []u8,
    body: []u8,
    service_tier: ?ai_types.ServiceTier,
    cancel_token: ?ai_types.CancelToken = null,
    on_payload_fn: ?*const fn (on_ctx: ?*anyopaque, payload_json: []const u8) void = null,
    on_payload_ctx: ?*anyopaque = null,
    retry_config: ?ai_types.RetryConfig = null,
};

fn runThread(ctx: *ThreadCtx) void {
    // Save values from ctx that we need after freeing ctx
    const allocator = ctx.allocator;
    const stream = ctx.stream;
    const model = ctx.model;
    const api_key = ctx.api_key;
    const body = ctx.body;
    const service_tier = ctx.service_tier;
    const cancel_token = ctx.cancel_token;
    const on_payload_fn = ctx.on_payload_fn;
    const on_payload_ctx = ctx.on_payload_ctx;
    const retry_opts = ctx.retry_config;

    // Invoke on_payload callback before sending
    if (on_payload_fn) |cb| {
        cb(on_payload_ctx, body);
    }

    // Check cancellation before sending
    if (cancel_token) |ct| {
        if (ct.isCancelled()) {
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("request cancelled");
            return;
        }
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(allocator, "{s}/v1/responses", .{model.base_url}) catch {
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom url");
        return;
    };

    const auth = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch {
        allocator.free(url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom auth");
        return;
    };

    const uri = std.Uri.parse(url) catch {
        allocator.free(auth);
        allocator.free(url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("invalid URL");
        return;
    };

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    headers.append(allocator, .{ .name = "authorization", .value = auth }) catch {
        allocator.free(auth);
        allocator.free(url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom headers");
        return;
    };
    headers.append(allocator, .{ .name = "content-type", .value = "application/json" }) catch {
        allocator.free(auth);
        allocator.free(url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom headers");
        return;
    };

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
        // Check cancellation before each attempt
        if (cancel_token) |ct| {
            if (ct.isCancelled()) {
                allocator.free(auth);
                allocator.free(url);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
                stream.completeWithError("request cancelled");
                return;
            }
        }

        // Deinit previous request if this is a retry
        if (req_initialized) {
            req.deinit();
            req_initialized = false;
        }

        req = client.request(.POST, uri, .{ .extra_headers = headers.items }) catch {
            // Network error - check if we should retry
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry_util.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                    retry_attempt += 1;
                    continue;
                }
                // Sleep was cancelled
                allocator.free(auth);
                allocator.free(url);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
                stream.completeWithError("request cancelled");
                return;
            }
            allocator.free(auth);
            allocator.free(url);
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
                if (retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                    retry_attempt += 1;
                    continue;
                }
                // Sleep was cancelled
                allocator.free(auth);
                allocator.free(url);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
                stream.completeWithError("request cancelled");
                return;
            }
            allocator.free(auth);
            allocator.free(url);
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
                if (retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                    retry_attempt += 1;
                    continue;
                }
                // Sleep was cancelled
                allocator.free(auth);
                allocator.free(url);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
                stream.completeWithError("request cancelled");
                return;
            }
            allocator.free(auth);
            allocator.free(url);
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
            var error_body_len: usize = 0;
            if (response.head.content_length) |_| {
                error_body_len = response.reader(&head_buf).readSliceShort(&error_body) catch 0;
            }
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
            if (!retry_util.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
                // Sleep was cancelled
                allocator.free(auth);
                allocator.free(url);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
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
        allocator.free(auth);
        allocator.free(url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("responses request failed");
        return;
    }

    var parser = sse_parser.SSEParser.init(allocator);
    defer parser.deinit();

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var text = std.ArrayList(u8){};
    defer text.deinit(allocator);
    var thinking = std.ArrayList(u8){};
    defer thinking.deinit(allocator);
    var usage = ai_types.Usage{};
    var stop_reason: ai_types.StopReason = .stop;

    // Tool call tracking
    var tool_call_tracker_instance = tool_call_tracker.ToolCallTracker.init(allocator);
    defer tool_call_tracker_instance.deinit();

    // Map from item_id to content_index for tool calls
    var item_id_to_content_index = std.StringHashMap(usize).init(allocator);
    defer {
        var iter = item_id_to_content_index.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        item_id_to_content_index.deinit();
    }

    // Map from item_id to compound_id for tool calls
    var item_id_to_compound_id = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = item_id_to_compound_id.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        item_id_to_compound_id.deinit();
    }

    var next_content_index: usize = 0;
    var tool_call_count: usize = 0;
    var thinking_started = false;
    var thinking_content_index: ?usize = null;
    var text_content_index: ?usize = null;
    var text_started = false;

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
        // Check cancellation during streaming
        if (cancel_token) |ct| {
            if (ct.isCancelled()) {
                allocator.free(auth);
                allocator.free(url);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
                stream.completeWithError("request cancelled");
                return;
            }
        }

        const n = reader.*.readSliceShort(&read_buf) catch {
            allocator.free(auth);
            allocator.free(url);
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("read failed");
            return;
        };
        if (n == 0) break;

        const events = parser.feed(read_buf[0..n]) catch {
            allocator.free(auth);
            allocator.free(url);
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("parse failed");
            return;
        };

        for (events) |ev| {
            const parsed = parseResponseEventToStruct(ev.data, allocator) orelse continue;

            switch (parsed.event_type) {
                .text_delta => |delta| {
                    if (!text_started) {
                        text_content_index = next_content_index;
                        next_content_index += 1;
                        text_started = true;

                        // Emit text_start event
                        _ = stream.push(.{
                            .text_start = .{
                                .content_index = text_content_index.?,
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

                    text.appendSlice(allocator, delta) catch {};

                    // Emit text_delta event
                    if (text_content_index) |idx| {
                        _ = stream.push(.{
                            .text_delta = .{
                                .content_index = idx,
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
                },
                .output_item_added => |item| {
                    if (std.mem.eql(u8, item.item_type, "function_call")) {
                        // Start a new tool call
                        const call_id = item.call_id orelse "";
                        const item_id = item.id orelse "";
                        const name = item.name orelse "";

                        // Build compound ID
                        const compound_id = buildCompoundId(allocator, call_id, item_id) catch {
                            allocator.free(auth);
                            allocator.free(url);
                            allocator.free(api_key);
                            allocator.free(body);
                            allocator.destroy(ctx);
                            stream.completeWithError("oom compound id");
                            return;
                        };

                        const content_index = next_content_index;
                        next_content_index += 1;
                        tool_call_count += 1;

                        // Store mapping from item_id to content_index
                        const duped_item_id = allocator.dupe(u8, item_id) catch {
                            allocator.free(compound_id);
                            allocator.free(auth);
                            allocator.free(url);
                            allocator.free(api_key);
                            allocator.free(body);
                            allocator.destroy(ctx);
                            stream.completeWithError("oom item_id");
                            return;
                        };
                        item_id_to_content_index.put(duped_item_id, content_index) catch {
                            allocator.free(duped_item_id);
                            allocator.free(compound_id);
                            allocator.free(auth);
                            allocator.free(url);
                            allocator.free(api_key);
                            allocator.free(body);
                            allocator.destroy(ctx);
                            stream.completeWithError("oom item map");
                            return;
                        };

                        // Store mapping from item_id to compound_id
                        item_id_to_compound_id.put(allocator.dupe(u8, item_id) catch {
                            allocator.free(compound_id);
                            allocator.free(auth);
                            allocator.free(url);
                            allocator.free(api_key);
                            allocator.free(body);
                            allocator.destroy(ctx);
                            stream.completeWithError("oom compound map");
                            return;
                        }, compound_id) catch {
                            allocator.free(compound_id);
                            allocator.free(auth);
                            allocator.free(url);
                            allocator.free(api_key);
                            allocator.free(body);
                            allocator.destroy(ctx);
                            stream.completeWithError("oom compound map");
                            return;
                        };

                        // Start the tool call in tracker
                        _ = tool_call_tracker_instance.startCall(content_index, content_index, compound_id, name) catch {
                            allocator.free(auth);
                            allocator.free(url);
                            allocator.free(api_key);
                            allocator.free(body);
                            allocator.destroy(ctx);
                            stream.completeWithError("oom tool call start");
                            return;
                        };

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
                    }
                },
                .function_call_args_delta => |args| {
                    // Find content_index for this item_id
                    if (item_id_to_content_index.get(args.item_id)) |content_index| {
                        tool_call_tracker_instance.appendDelta(content_index, args.delta) catch {};

                        // Emit toolcall_delta event
                        _ = stream.push(.{
                            .toolcall_delta = .{
                                .content_index = content_index,
                                .delta = args.delta,
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
                },
                .function_call_args_done => |args| {
                    // Arguments are complete but we wait for output_item_done to finalize
                    _ = args;
                },
                .reasoning_delta => |delta| {
                    if (!thinking_started) {
                        thinking_content_index = next_content_index;
                        next_content_index += 1;
                        thinking_started = true;

                        // Emit thinking_start event
                        _ = stream.push(.{
                            .thinking_start = .{
                                .content_index = thinking_content_index.?,
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

                    thinking.appendSlice(allocator, delta) catch {};

                    // Emit thinking_delta event
                    if (thinking_content_index) |idx| {
                        _ = stream.push(.{
                            .thinking_delta = .{
                                .content_index = idx,
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
                },
                .reasoning_done => {
                    // Emit thinking_end event
                    if (thinking_content_index) |idx| {
                        _ = stream.push(.{
                            .thinking_end = .{
                                .content_index = idx,
                                .content = thinking.items,
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
                },
                .output_item_done => |item| {
                    if (std.mem.eql(u8, item.item_type, "function_call")) {
                        const item_id = item.id orelse "";
                        if (item_id_to_content_index.get(item_id)) |content_index| {
                            // Complete the tool call
                            if (tool_call_tracker_instance.completeCall(content_index, allocator)) |tc| {
                                // Emit toolcall_end event
                                _ = stream.push(.{
                                    .toolcall_end = .{
                                        .content_index = content_index,
                                        .tool_call = tc,
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
                },
                .completed => |info| {
                    if (info.status) |st| {
                        if (std.mem.eql(u8, st, "incomplete")) stop_reason = .length;
                    }
                    if (info.usage) |u| {
                        usage = u;
                    }
                },
            }
        }
    }

    if (usage.total_tokens == 0) usage.total_tokens = usage.input + usage.output;

    // Calculate base cost
    usage.calculateCost(model.cost);

    // Apply service tier cost multiplier
    if (service_tier) |tier| {
        const tier_multiplier: f64 = switch (tier) {
            .flex => 0.5, // 50% of base price
            .priority => 2.0, // 200% of base price
            .default => 1.0, // 100% base price
        };
        usage.cost.input *= tier_multiplier;
        usage.cost.output *= tier_multiplier;
        usage.cost.cache_read *= tier_multiplier;
        usage.cost.cache_write *= tier_multiplier;
        usage.cost.total *= tier_multiplier;
    }

    // Build content blocks - thinking first if present, then text, then tool calls
    const has_thinking = thinking.items.len > 0;
    const has_text = text.items.len > 0;
    const content_count: usize = if (has_thinking) 1 else 0;
    const content_count_final = content_count + if (has_text) @as(usize, 1) else @as(usize, 0) + tool_call_count;

    if (content_count_final == 0) {
        // No content - create empty text block
        var content = allocator.alloc(ai_types.AssistantContent, 1) catch {
            allocator.free(auth);
            allocator.free(url);
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("oom result");
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
        allocator.free(auth);
        allocator.free(url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.complete(out);
        return;
    }

    var content = allocator.alloc(ai_types.AssistantContent, content_count_final) catch {
        allocator.free(auth);
        allocator.free(url);
        allocator.free(api_key);
        allocator.free(body);
        allocator.destroy(ctx);
        stream.completeWithError("oom building result");
        return;
    };
    var idx: usize = 0;

    if (has_thinking) {
        content[idx] = .{ .thinking = .{
            .thinking = allocator.dupe(u8, thinking.items) catch {
                allocator.free(content);
                allocator.free(auth);
                allocator.free(url);
                allocator.free(api_key);
                allocator.free(body);
                allocator.destroy(ctx);
                stream.completeWithError("oom building thinking");
                return;
            },
        } };
        idx += 1;
    }

    if (has_text) {
        content[idx] = .{ .text = .{ .text = allocator.dupe(u8, text.items) catch {
            // Free previously allocated content
            for (content[0..idx]) |*block| {
                switch (block.*) {
                    .thinking => |t| allocator.free(t.thinking),
                    else => {},
                }
            }
            allocator.free(content);
            allocator.free(auth);
            allocator.free(url);
            allocator.free(api_key);
            allocator.free(body);
            allocator.destroy(ctx);
            stream.completeWithError("oom building text");
            return;
        } } };
        idx += 1;
    }

    // Note: tool calls are already emitted via toolcall_end events during streaming
    // and completed in the tracker. We don't need to iterate again here since
    // output_item_done events already handled them.

    const out = ai_types.AssistantMessage{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp = std.time.milliTimestamp(),
    };

    // Free ctx allocations before completing
    allocator.free(auth);
    allocator.free(url);
    allocator.free(api_key);
    allocator.free(body);
    allocator.destroy(ctx);

    stream.complete(out);
}

pub fn streamOpenAIResponses(model: ai_types.Model, context: ai_types.Context, options: ?ai_types.StreamOptions, allocator: std.mem.Allocator) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.StreamOptions{};

    const api_key: []u8 = blk: {
        if (o.api_key) |k| break :blk try allocator.dupe(u8, k);
        const env = envApiKey(allocator);
        if (env) |k| break :blk @constCast(k);
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    const body = try buildRequestBody(model, context, o, allocator);
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
        .body = body,
        .service_tier = o.service_tier,
        .cancel_token = o.cancel_token,
        .on_payload_fn = o.on_payload_fn,
        .on_payload_ctx = o.on_payload_ctx,
        .retry_config = o.retry,
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

pub fn streamSimpleOpenAIResponses(model: ai_types.Model, context: ai_types.Context, options: ?ai_types.SimpleStreamOptions, allocator: std.mem.Allocator) !*ai_types.AssistantMessageEventStream {
    const o = options orelse ai_types.SimpleStreamOptions{};
    return streamOpenAIResponses(model, context, .{
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
        .reasoning_summary = o.reasoning_summary,
    }, allocator);
}

pub fn registerOpenAIResponsesApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "openai-responses",
        .stream = streamOpenAIResponses,
        .stream_simple = streamSimpleOpenAIResponses,
    }, null);
}

pub fn registerOpenAICodexResponsesApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "openai-codex-responses",
        .stream = streamOpenAIResponses,
        .stream_simple = streamSimpleOpenAIResponses,
    }, null);
}

// =============================================================================
// Tests
// =============================================================================

/// Helper to parse JSON and return ParsedEvent for tests
fn parseEventForTest(data: []const u8, allocator: std.mem.Allocator) ?struct { parsed: std.json.Parsed(std.json.Value), event: ParsedEvent } {
    if (std.mem.eql(u8, data, "[DONE]")) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    const event = parseResponseEventFromValue(parsed.value) orelse {
        parsed.deinit();
        return null;
    };
    return .{ .parsed = parsed, .event = event };
}

test "parseResponseEventFromValue handles text delta" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"Hello\"}";

    const result = parseEventForTest(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.event.output_index);
    try std.testing.expectEqualStrings("Hello", result.event.event_type.text_delta);
}

test "parseResponseEventFromValue handles output_item.added for function_call" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_123\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"\"}}";

    const result = parseEventForTest(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.event.output_index);

    switch (result.event.event_type) {
        .output_item_added => |item| {
            try std.testing.expectEqualStrings("function_call", item.item_type);
            try std.testing.expectEqualStrings("fc_123", item.id.?);
            try std.testing.expectEqualStrings("call_abc", item.call_id.?);
            try std.testing.expectEqualStrings("bash", item.name.?);
        },
        else => try std.testing.expect(false),
    }
}

test "parseResponseEventFromValue handles function_call_arguments.delta" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc_123\",\"delta\":\"{\\\"cmd\\\": \\\"ls\\\"\"}";

    const result = parseEventForTest(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.event.output_index);

    switch (result.event.event_type) {
        .function_call_args_delta => |args| {
            try std.testing.expectEqualStrings("fc_123", args.item_id);
            try std.testing.expectEqualStrings("{\"cmd\": \"ls\"", args.delta);
        },
        else => try std.testing.expect(false),
    }
}

test "parseResponseEventFromValue handles function_call_arguments.done" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc_123\",\"arguments\":\"{\\\"cmd\\\": \\\"ls -la\\\"}\"}";

    const result = parseEventForTest(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.event.output_index);

    switch (result.event.event_type) {
        .function_call_args_done => |args| {
            try std.testing.expectEqualStrings("fc_123", args.item_id);
            try std.testing.expectEqualStrings("{\"cmd\": \"ls -la\"}", args.arguments);
        },
        else => try std.testing.expect(false),
    }
}

test "parseResponseEventFromValue handles reasoning.delta" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"response.reasoning.delta\",\"output_index\":0,\"delta\":\"Let me think...\"}";

    const result = parseEventForTest(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.event.output_index);
    try std.testing.expectEqualStrings("Let me think...", result.event.event_type.reasoning_delta);
}

test "parseResponseEventFromValue handles reasoning.done" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"response.reasoning.done\",\"output_index\":0}";

    const result = parseEventForTest(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.event.output_index);
    try std.testing.expect(result.event.event_type == .reasoning_done);
}

test "parseResponseEventFromValue handles output_item.done" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_123\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}";

    const result = parseEventForTest(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.event.output_index);

    switch (result.event.event_type) {
        .output_item_done => |item| {
            try std.testing.expectEqualStrings("function_call", item.item_type);
            try std.testing.expectEqualStrings("fc_123", item.id.?);
        },
        else => try std.testing.expect(false),
    }
}

test "parseResponseEventFromValue handles response.completed with usage" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}";

    const result = parseEventForTest(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.parsed.deinit();

    switch (result.event.event_type) {
        .completed => |info| {
            try std.testing.expectEqualStrings("completed", info.status.?);
            try std.testing.expectEqual(@as(u64, 100), info.usage.?.input);
            try std.testing.expectEqual(@as(u64, 50), info.usage.?.output);
            try std.testing.expectEqual(@as(u64, 150), info.usage.?.total_tokens);
        },
        else => try std.testing.expect(false),
    }
}

test "parseResponseEventFromValue handles response.completed with incomplete status" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"response.completed\",\"response\":{\"status\":\"incomplete\"}}";

    const result = parseEventForTest(data, allocator) orelse {
        try std.testing.expect(false);
        return;
    };
    defer result.parsed.deinit();

    switch (result.event.event_type) {
        .completed => |info| {
            try std.testing.expectEqualStrings("incomplete", info.status.?);
        },
        else => try std.testing.expect(false),
    }
}

test "buildCompoundId creates correct format" {
    const allocator = std.testing.allocator;
    const compound_id = try buildCompoundId(allocator, "call_abc", "fc_123");
    defer allocator.free(compound_id);

    try std.testing.expectEqualStrings("call_abc|fc_123", compound_id);
}

test "parseResponseEventToStruct returns null for [DONE]" {
    const allocator = std.testing.allocator;
    const result = parseResponseEventToStruct("[DONE]", allocator);
    try std.testing.expect(result == null);
}

test "parseResponseEventToStruct returns null for invalid JSON" {
    const allocator = std.testing.allocator;
    const result = parseResponseEventToStruct("not valid json", allocator);
    try std.testing.expect(result == null);
}

test "parseResponseEventFromValue returns null for unknown event type" {
    const allocator = std.testing.allocator;
    const data = "{\"type\":\"unknown.event\",\"output_index\":0}";

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        try std.testing.expect(false);
        return;
    };
    defer parsed.deinit();

    const result = parseResponseEventFromValue(parsed.value);
    try std.testing.expect(result == null);
}

test "buildRequestBody includes service_tier when set" {
    const allocator = std.testing.allocator;
    const model: ai_types.Model = .{
        .id = "gpt-4o",
        .name = "gpt-4o",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 2.5, .output = 10.0, .cache_read = 1.25, .cache_write = 2.5 },
        .context_window = 128000,
        .max_tokens = 16384,
    };
    const context: ai_types.Context = .{
        .messages = &.{},
    };
    const options: ai_types.StreamOptions = .{
        .service_tier = .flex,
    };

    const body = try buildRequestBody(model, context, options, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"service_tier\":\"flex\"") != null);
}

test "buildRequestBody omits service_tier when null" {
    const allocator = std.testing.allocator;
    const model: ai_types.Model = .{
        .id = "gpt-4o",
        .name = "gpt-4o",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 2.5, .output = 10.0, .cache_read = 1.25, .cache_write = 2.5 },
        .context_window = 128000,
        .max_tokens = 16384,
    };
    const context: ai_types.Context = .{
        .messages = &.{},
    };
    const options: ai_types.StreamOptions = .{};

    const body = try buildRequestBody(model, context, options, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "service_tier") == null);
}

test "buildRequestBody includes GPT-5 juice workaround when reasoning disabled" {
    const allocator = std.testing.allocator;
    const model: ai_types.Model = .{
        .id = "gpt-5",
        .name = "gpt-5-turbo",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = true,
        .input = &.{},
        .cost = .{ .input = 5.0, .output = 15.0, .cache_read = 2.5, .cache_write = 5.0 },
        .context_window = 200000,
        .max_tokens = 16384,
    };
    const context: ai_types.Context = .{
        .system_prompt = "You are helpful.",
        .messages = &.{},
    };
    const options: ai_types.StreamOptions = .{
        .reasoning_enabled = false,
    };

    const body = try buildRequestBody(model, context, options, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "# Juice: 0 !important") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"developer\"") != null);
}

test "buildRequestBody omits GPT-5 juice workaround when reasoning enabled" {
    const allocator = std.testing.allocator;
    const model: ai_types.Model = .{
        .id = "gpt-5",
        .name = "gpt-5-turbo",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = true,
        .input = &.{},
        .cost = .{ .input = 5.0, .output = 15.0, .cache_read = 2.5, .cache_write = 5.0 },
        .context_window = 200000,
        .max_tokens = 16384,
    };
    const context: ai_types.Context = .{
        .system_prompt = "You are helpful.",
        .messages = &.{},
    };
    const options: ai_types.StreamOptions = .{
        .reasoning_enabled = true,
    };

    const body = try buildRequestBody(model, context, options, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "Juice") == null);
}

test "buildRequestBody omits juice workaround for non-GPT-5 models" {
    const allocator = std.testing.allocator;
    const model: ai_types.Model = .{
        .id = "gpt-4o",
        .name = "gpt-4o",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 2.5, .output = 10.0, .cache_read = 1.25, .cache_write = 2.5 },
        .context_window = 128000,
        .max_tokens = 16384,
    };
    const context: ai_types.Context = .{
        .system_prompt = "You are helpful.",
        .messages = &.{},
    };
    const options: ai_types.StreamOptions = .{
        .reasoning_enabled = false,
    };

    const body = try buildRequestBody(model, context, options, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "Juice") == null);
}

test "ServiceTier enum values are correct" {
    try std.testing.expectEqual(ai_types.ServiceTier.default, .default);
    try std.testing.expectEqual(ai_types.ServiceTier.flex, .flex);
    try std.testing.expectEqual(ai_types.ServiceTier.priority, .priority);
}

test "ReasoningSummary enum values are correct" {
    try std.testing.expectEqual(ai_types.ReasoningSummary.auto, .auto);
    try std.testing.expectEqual(ai_types.ReasoningSummary.concise, .concise);
    try std.testing.expectEqual(ai_types.ReasoningSummary.detailed, .detailed);
}
