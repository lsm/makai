const std = @import("std");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const api_registry = @import("api_registry");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");
const github_copilot = @import("github_copilot");
const tool_call_tracker = @import("tool_call_tracker");
const provider_caps = @import("provider_caps");
const sanitize = @import("sanitize");
const retry = @import("retry");
const pre_transform = @import("pre_transform");

/// Merged compatibility options from model-level config and detected capabilities
const MergedCompat = struct {
    supports_store: bool,
    supports_developer_role: bool,
    supports_reasoning_effort: bool,
    supports_usage_in_streaming: bool,
    max_tokens_field: []const u8,
    requires_tool_result_name: bool,
    requires_assistant_after_tool_result: bool,
    requires_thinking_as_text: bool,
    requires_mistral_tool_ids: bool,
    thinking_format: enum { openai, zai, qwen },
    supports_strict_mode: bool,
};

/// Merge model-level compat options with detected provider capabilities
/// Model-level options take precedence over detected capabilities
fn mergeCompat(model: ai_types.Model) MergedCompat {
    const caps = provider_caps.detectCapabilities(model.base_url);
    const compat = model.compat;
    const is_openai_native = std.mem.indexOf(u8, model.base_url, "openai.com") != null;

    return .{
        .supports_store = if (compat) |c| c.supports_store orelse is_openai_native else is_openai_native,
        .supports_developer_role = if (compat) |c| c.supports_developer_role orelse caps.supports_developer_role else caps.supports_developer_role,
        .supports_reasoning_effort = if (compat) |c| c.supports_reasoning_effort orelse caps.supports_reasoning_effort else caps.supports_reasoning_effort,
        .supports_usage_in_streaming = if (compat) |c| c.supports_usage_in_streaming orelse true else true,
        .max_tokens_field = if (compat) |c| switch (c.max_tokens_field) {
            .max_completion_tokens => "max_completion_tokens",
            .max_tokens => "max_tokens",
        } else caps.max_tokens_field,
        .requires_tool_result_name = if (compat) |c| c.requires_tool_result_name orelse caps.requires_tool_result_name else caps.requires_tool_result_name,
        .requires_assistant_after_tool_result = if (compat) |c| c.requires_assistant_after_tool_result orelse caps.requires_assistant_after_tool else caps.requires_assistant_after_tool,
        .requires_thinking_as_text = if (compat) |c| c.requires_thinking_as_text orelse caps.requires_thinking_as_text else caps.requires_thinking_as_text,
        .requires_mistral_tool_ids = if (compat) |c| c.requires_mistral_tool_ids orelse caps.requires_mistral_tool_ids else caps.requires_mistral_tool_ids,
        .thinking_format = if (compat) |c| switch (c.thinking_format) {
            .openai => .openai,
            .zai => .zai,
            .qwen => .qwen,
        } else switch (caps.thinking_format) {
            .openai => .openai,
            .zai => .zai,
            .qwen => .qwen,
        },
        .supports_strict_mode = if (compat) |c| c.supports_strict_mode orelse true else true,
    };
}

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

/// Check if we're using OpenRouter with an Anthropic model
fn isOpenRouterAnthropic(model: ai_types.Model) bool {
    if (model.base_url.len == 0) return false;
    if (std.mem.indexOf(u8, model.base_url, "openrouter") == null) return false;
    if (!std.mem.startsWith(u8, model.id, "anthropic/")) return false;
    return true;
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

fn writeMessagesArray(
    writer: *json_writer.JsonWriter,
    context: ai_types.Context,
    model: ai_types.Model,
    allocator: std.mem.Allocator,
) !void {
    const merged = mergeCompat(model);
    const is_github_copilot = std.mem.eql(u8, model.provider, "github-copilot");

    // Find the last user message index for cache_control (OpenRouter + Anthropic)
    const should_add_cache_control = isOpenRouterAnthropic(model);
    var last_user_msg_idx: ?usize = null;
    if (should_add_cache_control) {
        var idx: usize = 0;
        for (context.messages) |msg| {
            if (msg == .user) {
                last_user_msg_idx = idx;
            }
            idx += 1;
        }
    }

    try writer.writeKey("messages");
    try writer.beginArray();

    // Collect tool call IDs for orphaned tool result filtering
    var tool_call_ids = collectToolCallIds(allocator, context.messages) catch std.StringHashMap(void).init(allocator);
    defer freeToolCallIds(allocator, &tool_call_ids);

    if (context.system_prompt) |sp| {
        try writer.beginObject();
        // Use developer role for reasoning models on providers that support it
        const use_developer = model.reasoning and merged.supports_developer_role;
        const system_role: []const u8 = if (use_developer) "developer" else "system";
        try writer.writeStringField("role", system_role);
        // Sanitize system prompt to remove unpaired surrogates
        const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, sp);
        defer {
            if (sanitized.ptr != sp.ptr) {
                allocator.free(@constCast(sanitized));
            }
        }
        try writer.writeStringField("content", sanitized);
        try writer.endObject();
    }

    var msg_idx: usize = 0;
    var prev_role: []const u8 = "";
    while (msg_idx < context.messages.len) : (msg_idx += 1) {
        const msg = context.messages[msg_idx];

        // Skip aborted/error assistant messages
        if (shouldSkipAssistant(msg)) continue;

        // Skip orphaned tool results
        if (isOrphanedToolResult(msg, &tool_call_ids)) continue;

        // Handle user messages
        if (msg == .user) {
            const u = msg.user;
            const is_last_user_msg = should_add_cache_control and last_user_msg_idx != null and msg_idx == last_user_msg_idx.?;

            try writer.beginObject();
            try writer.writeStringField("role", "user");

            switch (u.content) {
                .text => |t| {
                    // Sanitize text to remove unpaired surrogates
                    const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t);
                    defer {
                        if (sanitized.ptr != t.ptr) {
                            allocator.free(@constCast(sanitized));
                        }
                    }
                    if (is_last_user_msg) {
                        try writer.writeKey("content");
                        try writer.beginArray();
                        try writer.beginObject();
                        try writer.writeStringField("type", "text");
                        try writer.writeStringField("text", sanitized);
                        try writer.writeKey("cache_control");
                        try writer.beginObject();
                        try writer.writeStringField("type", "ephemeral");
                        try writer.endObject();
                        try writer.endArray();
                    } else {
                        try writer.writeStringField("content", sanitized);
                    }
                },
                .parts => |parts| {
                    var has_images = false;
                    for (parts) |p| {
                        if (p == .image) {
                            has_images = true;
                            break;
                        }
                    }

                    if (has_images or is_last_user_msg) {
                        try writer.writeKey("content");
                        try writer.beginArray();
                        for (parts, 0..) |p, part_idx| {
                            const is_last_part = part_idx == parts.len - 1;
                            switch (p) {
                                .text => |t| {
                                    // Sanitize text to remove unpaired surrogates
                                    const sanitized = try sanitize.sanitizeSurrogatesInPlace(allocator, t.text);
                                    defer {
                                        if (sanitized.ptr != t.text.ptr) {
                                            allocator.free(@constCast(sanitized));
                                        }
                                    }
                                    try writer.beginObject();
                                    try writer.writeStringField("type", "text");
                                    try writer.writeStringField("text", sanitized);
                                    if (is_last_user_msg and is_last_part) {
                                        try writer.writeKey("cache_control");
                                        try writer.beginObject();
                                        try writer.writeStringField("type", "ephemeral");
                                        try writer.endObject();
                                    }
                                    try writer.endObject();
                                },
                                .image => |img| {
                                    try writeImageUrlPart(writer, img, allocator);
                                },
                            }
                        }
                        try writer.endArray();
                    } else {
                        var text_buf = std.ArrayList(u8){};
                        defer text_buf.deinit(allocator);
                        for (parts) |p| {
                            switch (p) {
                                .text => |t| {
                                    if (text_buf.items.len > 0) try text_buf.append(allocator, '\n');
                                    try text_buf.appendSlice(allocator, t.text);
                                },
                                .image => {},
                            }
                        }
                        try writer.writeStringField("content", text_buf.items);
                    }
                },
            }
            try writer.endObject();
            prev_role = "user";
            continue;
        }

        // Handle assistant messages - proper structured serialization
        if (msg == .assistant) {
            const a = msg.assistant;

            // Collect text, thinking, and tool_call blocks
            var has_text = false;
            var has_thinking = false;
            var has_tool_calls = false;
            for (a.content) |c| switch (c) {
                .text => |t| {
                    if (t.text.len > 0 and std.mem.trim(u8, t.text, " \t\r\n").len > 0) has_text = true;
                },
                .thinking => |t| {
                    if (t.thinking.len > 0 and std.mem.trim(u8, t.thinking, " \t\r\n").len > 0) has_thinking = true;
                },
                .tool_call => {
                    has_tool_calls = true;
                },
                .image => {},
            };

            // Skip empty assistant messages (no content and no tool_calls)
            // Mistral explicitly requires "either content or tool_calls, but not none"
            if (!has_text and !has_thinking and !has_tool_calls) continue;

            try writer.beginObject();
            try writer.writeStringField("role", "assistant");

            // Serialize content - text blocks as array of {type: "text", text: ...}
            if (has_text) {
                if (is_github_copilot) {
                    // GitHub Copilot requires content as a flat string
                    var text_buf = std.ArrayList(u8){};
                    defer text_buf.deinit(allocator);
                    for (a.content) |c| switch (c) {
                        .text => |t| {
                            if (t.text.len > 0 and std.mem.trim(u8, t.text, " \t\r\n").len > 0) {
                                if (text_buf.items.len > 0) try text_buf.appendSlice(allocator, "");
                                try text_buf.appendSlice(allocator, t.text);
                            }
                        },
                        else => {},
                    };
                    try writer.writeStringField("content", text_buf.items);
                } else {
                    try writer.writeKey("content");
                    try writer.beginArray();
                    // If thinking needs to be prepended as text (for DeepSeek etc.)
                    if (has_thinking and merged.requires_thinking_as_text) {
                        for (a.content) |c| switch (c) {
                            .thinking => |t| {
                                if (t.thinking.len > 0 and std.mem.trim(u8, t.thinking, " \t\r\n").len > 0) {
                                    try writer.beginObject();
                                    try writer.writeStringField("type", "text");
                                    try writer.writeStringField("text", t.thinking);
                                    try writer.endObject();
                                }
                            },
                            else => {},
                        };
                    }
                    for (a.content) |c| switch (c) {
                        .text => |t| {
                            if (t.text.len > 0 and std.mem.trim(u8, t.text, " \t\r\n").len > 0) {
                                try writer.beginObject();
                                try writer.writeStringField("type", "text");
                                try writer.writeStringField("text", t.text);
                                try writer.endObject();
                            }
                        },
                        else => {},
                    };
                    try writer.endArray();
                }
            } else if (merged.requires_thinking_as_text and has_thinking) {
                // Only thinking content, converted to text
                try writer.writeKey("content");
                try writer.beginArray();
                for (a.content) |c| switch (c) {
                    .thinking => |t| {
                        if (t.thinking.len > 0 and std.mem.trim(u8, t.thinking, " \t\r\n").len > 0) {
                            try writer.beginObject();
                            try writer.writeStringField("type", "text");
                            try writer.writeStringField("text", t.thinking);
                            try writer.endObject();
                        }
                    },
                    else => {},
                };
                try writer.endArray();
            } else {
                // No text content - null or empty based on compat
                if (merged.requires_thinking_as_text) {
                    try writer.writeStringField("content", "");
                } else {
                    try writer.writeKey("content");
                    try writer.writeNull();
                }
            }

            // Serialize thinking as reasoning_content field (separate from content)
            // Only if not already converted to text above
            if (has_thinking and !merged.requires_thinking_as_text) {
                // Use the signature from the first thinking block for round-trip
                var reasoning_field: []const u8 = "reasoning_content";
                for (a.content) |c| switch (c) {
                    .thinking => |t| {
                        if (t.thinking_signature) |sig| {
                            if (sig.len > 0) reasoning_field = sig;
                        }
                        break;
                    },
                    else => {},
                };

                // Collect all thinking text
                var thinking_buf = std.ArrayList(u8){};
                defer thinking_buf.deinit(allocator);
                for (a.content) |c| switch (c) {
                    .thinking => |t| {
                        if (t.thinking.len > 0 and std.mem.trim(u8, t.thinking, " \t\r\n").len > 0) {
                            if (thinking_buf.items.len > 0) try thinking_buf.append(allocator, '\n');
                            try thinking_buf.appendSlice(allocator, t.thinking);
                        }
                    },
                    else => {},
                };
                if (thinking_buf.items.len > 0) {
                    try writer.writeStringField(reasoning_field, thinking_buf.items);
                }
            }

            // Serialize tool_calls
            if (has_tool_calls) {
                try writer.writeKey("tool_calls");
                try writer.beginArray();
                for (a.content) |c| switch (c) {
                    .tool_call => |tc| {
                        try writer.beginObject();
                        try writer.writeStringField("id", tc.id);
                        try writer.writeStringField("type", "function");
                        try writer.writeKey("function");
                        try writer.beginObject();
                        try writer.writeStringField("name", tc.name);
                        try writer.writeStringField("arguments", tc.arguments_json);
                        try writer.endObject();
                    },
                    else => {},
                };
                try writer.endArray();

                // Serialize reasoning_details for tool calls with thought_signature
                // This is for OpenAI encrypted reasoning round-trip
                var has_reasoning_details = false;
                for (a.content) |c| {
                    if (c == .tool_call and c.tool_call.thought_signature != null) {
                        has_reasoning_details = true;
                        break;
                    }
                }
                if (has_reasoning_details) {
                    try writer.writeKey("reasoning_details");
                    try writer.beginArray();
                    for (a.content) |c| {
                        if (c == .tool_call) {
                            if (c.tool_call.thought_signature) |sig| {
                                // The thought_signature is already a JSON-serialized reasoning_detail object
                                // Just write it directly as raw JSON
                                try writer.writeRawJson(sig);
                            }
                        }
                    }
                    try writer.endArray();
                }
            }

            try writer.endObject();
            prev_role = "assistant";
            continue;
        }

        // Handle tool_result messages - group consecutive ones, extract images
        if (msg == .tool_result) {
            // Collect image blocks from all consecutive tool results
            var image_blocks = std.ArrayList(ai_types.UserContentPart){};
            defer image_blocks.deinit(allocator);

            // Process consecutive tool_result messages
            while (msg_idx < context.messages.len and context.messages[msg_idx] == .tool_result) {
                const tr = context.messages[msg_idx].tool_result;

                // Insert synthetic assistant message if required (Mistral compat)
                if (merged.requires_assistant_after_tool_result and std.mem.eql(u8, prev_role, "tool")) {
                    try writer.beginObject();
                    try writer.writeStringField("role", "assistant");
                    try writer.writeStringField("content", "");
                    try writer.endObject();
                }

                // Extract text content
                var text_buf = std.ArrayList(u8){};
                defer text_buf.deinit(allocator);
                var has_images = false;
                for (tr.content) |c| switch (c) {
                    .text => |t| {
                        if (text_buf.items.len > 0) try text_buf.append(allocator, '\n');
                        try text_buf.appendSlice(allocator, t.text);
                    },
                    .image => {
                        has_images = true;
                    },
                };

                // Write tool result message
                try writer.beginObject();
                try writer.writeStringField("role", "tool");
                try writer.writeStringField("tool_call_id", tr.tool_call_id);
                if (merged.requires_tool_result_name) {
                    try writer.writeStringField("name", tr.tool_name);
                }
                const content_str = if (text_buf.items.len > 0) text_buf.items else if (has_images) "(see attached image)" else "";
                try writer.writeStringField("content", content_str);
                try writer.endObject();
                prev_role = "tool";

                // Collect images for separate user message
                if (has_images) {
                    for (tr.content) |c| switch (c) {
                        .image => |img| {
                            try image_blocks.append(allocator, .{ .image = img });
                        },
                        else => {},
                    };
                }

                msg_idx += 1;
            }
            // Back up one since the outer while will increment
            msg_idx -= 1;

            // If we collected images, send them as a separate user message
            if (image_blocks.items.len > 0) {
                // May need synthetic assistant before user message
                if (merged.requires_assistant_after_tool_result) {
                    try writer.beginObject();
                    try writer.writeStringField("role", "assistant");
                    try writer.writeStringField("content", "");
                    try writer.endObject();
                }

                try writer.beginObject();
                try writer.writeStringField("role", "user");
                try writer.writeKey("content");
                try writer.beginArray();
                for (image_blocks.items) |img_part| switch (img_part) {
                    .image => |img| {
                        try writeImageUrlPart(writer, img, allocator);
                    },
                    else => {},
                };
                try writer.endArray();
                try writer.endObject();
                prev_role = "user";
            }

            continue;
        }
    }

    try writer.endArray();
}

/// Write an image_url content part
fn writeImageUrlPart(writer: *json_writer.JsonWriter, img: ai_types.ImageContent, allocator: std.mem.Allocator) !void {
    try writer.beginObject();
    try writer.writeStringField("type", "image_url");
    try writer.writeKey("image_url");
    try writer.beginObject();
    try writer.writeKey("url");
    try writer.buffer.appendSlice(allocator, "\"data:");
    try writer.buffer.appendSlice(allocator, img.mime_type);
    try writer.buffer.appendSlice(allocator, ";base64,");
    try writer.buffer.appendSlice(allocator, img.data);
    try writer.buffer.append(allocator, '"');
    writer.needs_comma = true;
    try writer.endObject();
}

fn buildRequestBody(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    const merged = mergeCompat(model);

    // Pre-transform messages: cross-model thinking conversion, tool ID normalization,
    // synthetic tool results for orphaned calls, aborted message filtering
    var transformed = try pre_transform.preTransform(allocator, context.messages, .{
        .target_api = model.api,
        .target_provider = model.provider,
        .target_model_id = model.id,
        .max_tool_id_len = if (std.mem.indexOf(u8, model.base_url, "openai.com") != null) 40 else 0,
        .mistral_tool_ids = merged.requires_mistral_tool_ids,
        .insert_synthetic_results = true,
        .tools = context.tools,
    });
    defer transformed.deinit();

    // Build context with transformed messages
    var tx_context = context;
    tx_context.messages = transformed.messages;

    var w = json_writer.JsonWriter.init(&buf, allocator);
    try w.beginObject();
    try w.writeStringField("model", model.id);
    try writeMessagesArray(&w, tx_context, model, allocator);
    try w.writeBoolField("stream", true);
    // Only include stream_options if provider supports usage in streaming
    if (merged.supports_usage_in_streaming) {
        try w.writeKey("stream_options");
        try w.beginObject();
        try w.writeBoolField("include_usage", true);
        try w.endObject();
    }
    // Use appropriate max tokens field based on provider
    try w.writeIntField(merged.max_tokens_field, options.max_tokens orelse model.max_tokens);
    if (options.temperature) |t| {
        try w.writeKey("temperature");
        try w.writeFloat(t);
    }
    // Add reasoning_effort for providers that support it
    if (options.reasoning_effort) |effort| {
        if (model.reasoning and merged.supports_reasoning_effort) {
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
                // Add strict mode if supported
                if (merged.supports_strict_mode) {
                    try w.writeBoolField("strict", true);
                }
                try w.endObject();
            }
            try w.endArray();

            // Add tool_choice if specified
            if (options.tool_choice) |tc| {
                try w.writeKey("tool_choice");
                switch (tc) {
                    .auto => try w.writeString("auto"),
                    .none => try w.writeString("none"),
                    .required => try w.writeString("required"),
                    .function => |name| {
                        try w.beginObject();
                        try w.writeStringField("type", "function");
                        try w.writeKey("function");
                        try w.beginObject();
                        try w.writeStringField("name", name);
                        try w.endObject();
                    },
                }
            }
        }
    }
    // Privacy: don't store requests for OpenAI training
    // Only add for providers that support the store field
    if (merged.supports_store) {
        try w.writeBoolField("store", false);
    }
    try w.endObject();

    return buf.toOwnedSlice(allocator);
}

const ThreadCtx = struct {
    allocator: std.mem.Allocator,
    stream: *event_stream.AssistantMessageEventStream,
    model: ai_types.Model,
    api_key: []const u8,
    request_body: []u8,
    context: ai_types.Context,
    cancel_token: ?ai_types.CancelToken = null,
    on_payload_fn: ?*const fn (ctx: ?*anyopaque, payload_json: []const u8) void = null,
    on_payload_ctx: ?*anyopaque = null,
    retry_config: ?ai_types.RetryConfig = null,
    ping_interval_ms: ?u64 = null,

    /// Clean up all owned resources
    fn deinit(self: *ThreadCtx) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.request_body);
        var mut_context = self.context;
        mut_context.deinit(self.allocator);
        self.allocator.destroy(self);
    }
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

/// Reasoning detail event parsed from delta.reasoning_details
/// Used for OpenAI encrypted reasoning round-trip.
/// All strings are owned and must be freed with deinit.
const ReasoningDetailEvent = struct {
    tool_call_id: []const u8,
    /// JSON-serialized reasoning_detail object
    detail_json: []const u8,

    fn deinit(self: *ReasoningDetailEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.detail_json);
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
    reasoning_detail_events: *std.ArrayList(ReasoningDetailEvent),
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

                // Parse reasoning_details for encrypted reasoning round-trip (OpenAI)
                // Each detail with type="reasoning.encrypted" and matching tool_call id
                // stores the serialized JSON as thought_signature on the tool call
                if (d.object.get("reasoning_details")) |rd| {
                    if (rd == .array) {
                        for (rd.array.items) |detail| {
                            if (detail == .object) {
                                const detail_type = detail.object.get("type");
                                const detail_id = detail.object.get("id");
                                const detail_data = detail.object.get("data");

                                if (detail_type) |t| {
                                    if (t == .string and std.mem.eql(u8, t.string, "reasoning.encrypted")) {
                                        if (detail_id) |id| {
                                            if (id == .string and id.string.len > 0) {
                                                if (detail_data) |dat| {
                                                    if (dat == .string and dat.string.len > 0) {
                                                        // Serialize the detail object back to JSON
                                                        var detail_buf = std.ArrayList(u8){};
                                                        defer detail_buf.deinit(allocator);
                                                        detail_buf.writer(allocator).print("{{\"type\":\"reasoning.encrypted\",\"id\":\"{s}\",\"data\":\"{s}\"}}", .{ id.string, dat.string }) catch return;
                                                        const detail_json = try allocator.dupe(u8, detail_buf.items);
                                                        const tool_call_id = try allocator.dupe(u8, id.string);

                                                        try reasoning_detail_events.append(allocator, .{
                                                            .tool_call_id = tool_call_id,
                                                            .detail_json = detail_json,
                                                        });
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
    const cancel_token = ctx.cancel_token;
    const on_payload_fn = ctx.on_payload_fn;
    const on_payload_ctx = ctx.on_payload_ctx;
    const retry_config = ctx.retry_config;

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

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{model.base_url}) catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("oom building url");
        return;
    };
    defer allocator.free(url);

    const auth = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("oom building auth header");
        return;
    };
    defer allocator.free(auth);

    const uri = std.Uri.parse(url) catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("invalid provider URL");
        return;
    };

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(allocator);
    headers.append(allocator, .{ .name = "authorization", .value = auth }) catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("oom headers");
        return;
    };
    headers.append(allocator, .{ .name = "content-type", .value = "application/json" }) catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("oom headers");
        return;
    };
    headers.append(allocator, .{ .name = "accept", .value = "text/event-stream" }) catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("oom headers");
        return;
    };

    // Add GitHub Copilot headers if provider is github-copilot
    if (std.mem.eql(u8, model.provider, "github-copilot")) {
        // Static Copilot headers (required for all requests)
        headers.append(allocator, .{ .name = "user-agent", .value = github_copilot.COPILOT_HEADERS.user_agent }) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("oom copilot headers");
            return;
        };
        headers.append(allocator, .{ .name = "editor-version", .value = github_copilot.COPILOT_HEADERS.editor_version }) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("oom copilot headers");
            return;
        };
        headers.append(allocator, .{ .name = "editor-plugin-version", .value = github_copilot.COPILOT_HEADERS.editor_plugin_version }) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("oom copilot headers");
            return;
        };
        headers.append(allocator, .{ .name = "copilot-integration-id", .value = github_copilot.COPILOT_HEADERS.copilot_integration_id }) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("oom copilot headers");
            return;
        };

        // Dynamic Copilot headers (based on request content)
        const has_images = github_copilot.hasCopilotVisionInput(context.messages);
        const copilot_headers = github_copilot.buildCopilotDynamicHeaders(
            context.messages,
            has_images,
            allocator,
        ) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("oom copilot headers");
            return;
        };
        defer allocator.free(copilot_headers);

        for (copilot_headers) |h| {
            headers.append(allocator, h) catch {
                ctx.deinit();
                stream.markThreadDone();
                stream.completeWithError("oom headers");
                return;
            };
        }
    }

    // Retry configuration
    const MAX_RETRIES: u8 = 3;
    const BASE_DELAY_MS: u32 = 1000;
    const max_delay_ms: u32 = if (retry_config) |rc| rc.max_retry_delay_ms orelse 60000 else 60000;

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

        req = client.request(.POST, uri, .{ .extra_headers = headers.items }) catch {
            // Network error - check if we should retry
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
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
            stream.completeWithError("failed to open request");
            return;
        };
        req_initialized = true;

        req.transfer_encoding = .{ .content_length = request_body.len };

        req.sendBodyComplete(request_body) catch {
            // Network error - check if we should retry
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
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
            stream.completeWithError("failed to send request");
            return;
        };

        response = req.receiveHead(&head_buf) catch {
            // Network error - check if we should retry
            if (retry_attempt < MAX_RETRIES) {
                const delay = retry.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);
                if (retry.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
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
            stream.completeWithError("failed to receive response");
            return;
        };

        if (response.head.status == .ok) {
            // Success - break out of retry loop
            break;
        }

        // Check if status is retryable
        const status_code: u16 = @intFromEnum(response.head.status);
        const should_retry = retry.isRetryable(status_code) and retry_attempt < MAX_RETRIES;

        if (should_retry) {
            // Note: We skip reading the error body here because the response state machine
            // may not be in a valid state for body reading (e.g., after a redirect or when
            // the connection has been reset). The error body is only used for optional retry
            // delay hints, so we rely on status code and Retry-After header instead.
            const error_text: []const u8 = &.{};

            // Check if error body indicates a retryable error
            const is_retryable_error = retry.isRetryableError(error_text);

            // Calculate delay - prefer server-provided delay
            var delay = retry.calculateDelay(retry_attempt, BASE_DELAY_MS, max_delay_ms);

            // Check Retry-After header (only if headers contain valid \r\n separator)
            if (std.mem.indexOf(u8, response.head.bytes, "\r\n") != null) {
                var retry_after_iter = response.head.iterateHeaders();
                while (retry_after_iter.next()) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
                        if (retry.extractRetryDelayFromHeader(header.value)) |server_delay| {
                            if (server_delay <= max_delay_ms) {
                                delay = server_delay;
                            }
                        }
                        break;
                    }
                }
            }

            // Check body for retry delay
            if (retry.extractRetryDelayFromBody(error_text)) |body_delay| {
                if (body_delay <= max_delay_ms) {
                    delay = body_delay;
                }
            }

            // If not a retryable error message, don't retry
            if (!is_retryable_error and !retry.isRetryable(status_code)) {
                break;
            }

            // Wait before retry
            if (!retry.sleepMs(delay, if (cancel_token) |ct| ct.cancelled else null)) {
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
        // Read error body for debugging
        var error_buf: [4096]u8 = undefined;
        const error_body = response.reader(&error_buf).*.allocRemaining(allocator, std.io.Limit.limited(8192)) catch null;
        defer if (error_body) |eb| allocator.free(eb);

        std.debug.print("OpenAI API error: status={d}, model={s}\n", .{ @intFromEnum(response.head.status), model.name });
        if (error_body) |eb| {
            std.debug.print("Error body: {s}\n", .{eb});
        }

        ctx.deinit();
        stream.markThreadDone();
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
    var reasoning_detail_events = std.ArrayList(ReasoningDetailEvent){};
    defer {
        for (reasoning_detail_events.items) |*rde| {
            @constCast(rde).deinit(allocator);
        }
        reasoning_detail_events.deinit(allocator);
    }
    var next_content_index: usize = 0;
    var tool_call_count: usize = 0;

    var transfer_buf: [4096]u8 = undefined;
    var read_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    // Ping tracking
    var last_ping_time: i64 = 0;
    const ping_interval = ctx.ping_interval_ms orelse 0;

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
        // Emit ping if interval is configured
        if (ping_interval > 0) {
            const now = std.time.milliTimestamp();
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

        const n = reader.*.readSliceShort(&read_buf) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("read error");
            return;
        };
        if (n == 0) break;

        const events = parser.feed(read_buf[0..n]) catch {
            ctx.deinit();
            stream.markThreadDone();
            stream.completeWithError("sse parse error");
            return;
        };

        for (events) |ev| {
            // Free any previous tool call events
            for (tool_call_events.items) |*tce| {
                @constCast(tce).deinit(allocator);
            }
            tool_call_events.clearRetainingCapacity();
            // Free any previous reasoning detail events
            for (reasoning_detail_events.items) |*rde| {
                @constCast(rde).deinit(allocator);
            }
            reasoning_detail_events.clearRetainingCapacity();
            parseChunk(ev.data, &text, &thinking, &usage, &stop_reason, &current_block, &reasoning_signature, &tool_call_events, &reasoning_detail_events, allocator) catch {
                ctx.deinit();
                stream.markThreadDone();
                stream.completeWithError("json parse error");
                return;
            };

            // Process reasoning detail events - set thought_signature on matching tool calls
            for (reasoning_detail_events.items) |rde| {
                tool_call_tracker_instance.setThoughtSignatureById(rde.tool_call_id, rde.detail_json) catch {};
            }

            // Process tool call events
            for (tool_call_events.items) |tce| {
                if (tce.is_start) {
                    // Start a new tool call
                    const content_index = next_content_index;
                    const id = tce.id orelse "";
                    const name = tce.name orelse "";
                    _ = tool_call_tracker_instance.startCall(tce.api_index, content_index, id, name) catch {
                        ctx.deinit();
                        stream.markThreadDone();
                        stream.completeWithError("oom tool call start");
                        return;
                    };
                    next_content_index += 1;
                    tool_call_count += 1;

                    // Emit toolcall_start event
                    _ = stream.push(.{
                        .toolcall_start = .{
                            .content_index = content_index,
                            .id = id,
                            .name = name,
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
                        ctx.deinit();
                        stream.markThreadDone();
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
            ctx.deinit();
            stream.markThreadDone();
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
        ctx.deinit();
        stream.markThreadDone();
        stream.complete(out);
        return;
    }

    var content = allocator.alloc(ai_types.AssistantContent, content_count_final) catch {
        ctx.deinit();
        stream.markThreadDone();
        stream.completeWithError("oom building result");
        return;
    };
    var idx: usize = 0;

    if (has_thinking) {
        content[idx] = .{ .thinking = .{
            .thinking = allocator.dupe(u8, thinking.items) catch {
                allocator.free(content);
                ctx.deinit();
                stream.markThreadDone();
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
                ctx.deinit();
                stream.markThreadDone();
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
            ctx.deinit();
            stream.markThreadDone();
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

    ctx.deinit();
    stream.markThreadDone();
    stream.complete(out);
}

pub fn streamOpenAICompletions(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageEventStream {
    const resolved = options orelse ai_types.StreamOptions{};

    var key_owned: ?[]const u8 = null;
    const api_key = blk: {
        if (resolved.api_key) |k| break :blk try allocator.dupe(u8, k);
        key_owned = envApiKey(allocator);
        if (key_owned) |k| break :blk k;
        return error.MissingApiKey;
    };
    errdefer allocator.free(api_key);

    // Clone context to own the memory (background thread outlives caller's memory)
    const owned_context = try ai_types.cloneContext(allocator, context);
    errdefer {
        var mut_ctx = owned_context;
        mut_ctx.deinit(allocator);
    }

    const req_body = try buildRequestBody(model, owned_context, resolved, allocator);
    errdefer allocator.free(req_body);

    const s = try allocator.create(event_stream.AssistantMessageEventStream);
    errdefer allocator.destroy(s);
    s.* = event_stream.AssistantMessageEventStream.init(allocator);

    const ctx = try allocator.create(ThreadCtx);
    errdefer {
        allocator.destroy(s);
        allocator.free(req_body);
        var mut_ctx = owned_context;
        mut_ctx.deinit(allocator);
        allocator.free(api_key);
        allocator.destroy(ctx);
    }
    ctx.* = .{
        .allocator = allocator,
        .stream = s,
        .model = model,
        .api_key = @constCast(api_key),
        .request_body = req_body,
        .context = owned_context,
        .cancel_token = resolved.cancel_token,
        .on_payload_fn = resolved.on_payload_fn,
        .on_payload_ctx = resolved.on_payload_ctx,
        .retry_config = resolved.retry,
        .ping_interval_ms = resolved.ping_interval_ms,
    };

    const th = try std.Thread.spawn(.{}, runThread, .{ctx});
    th.detach();
    return s;
}

/// Convert ThinkingLevel enum to reasoning_effort string
fn thinkingLevelToString(level: ai_types.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
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
) !*event_stream.AssistantMessageEventStream {
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
    var reasoning_detail_events = std.ArrayList(ReasoningDetailEvent){};
    defer {
        for (reasoning_detail_events.items) |*rde| {
            @constCast(rde).deinit(allocator);
        }
        reasoning_detail_events.deinit(allocator);
    }

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
        &reasoning_detail_events,
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
    var reasoning_detail_events = std.ArrayList(ReasoningDetailEvent){};
    defer {
        for (reasoning_detail_events.items) |*rde| {
            @constCast(rde).deinit(allocator);
        }
        reasoning_detail_events.deinit(allocator);
    }

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
            &reasoning_detail_events,
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
    var reasoning_detail_events = std.ArrayList(ReasoningDetailEvent){};
    defer {
        for (reasoning_detail_events.items) |*rde| {
            @constCast(rde).deinit(allocator);
        }
        reasoning_detail_events.deinit(allocator);
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
        &reasoning_detail_events,
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
        &reasoning_detail_events,
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
        &reasoning_detail_events,
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
    var reasoning_detail_events = std.ArrayList(ReasoningDetailEvent){};
    defer {
        for (reasoning_detail_events.items) |*rde| {
            @constCast(rde).deinit(allocator);
        }
        reasoning_detail_events.deinit(allocator);
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
        &reasoning_detail_events,
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
        &reasoning_detail_events,
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
        &reasoning_detail_events,
        allocator,
    );

    try std.testing.expectEqual(@as(usize, 1), tool_call_events.items.len);
    try std.testing.expect(!tool_call_events.items[0].is_start);
    try std.testing.expectEqual(@as(usize, 0), tool_call_events.items[0].api_index);
}

test "isOpenRouterAnthropic detection" {
    // OpenRouter with Anthropic model
    const model1 = ai_types.Model{
        .id = "anthropic/claude-3-opus",
        .name = "Claude 3 Opus",
        .api = "openai-completions",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 200_000,
        .max_tokens = 100,
    };
    try std.testing.expect(isOpenRouterAnthropic(model1));

    // OpenRouter with non-Anthropic model
    const model2 = ai_types.Model{
        .id = "openai/gpt-4o",
        .name = "GPT-4o",
        .api = "openai-completions",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 100,
    };
    try std.testing.expect(!isOpenRouterAnthropic(model2));

    // OpenAI native (not OpenRouter)
    const model3 = ai_types.Model{
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
    try std.testing.expect(!isOpenRouterAnthropic(model3));
}

test "buildRequestBody adds cache_control for OpenRouter Anthropic models" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "anthropic/claude-3-opus",
        .name = "Claude 3 Opus",
        .api = "openai-completions",
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 200_000,
        .max_tokens = 100,
    };

    const user_msg1 = ai_types.Message{ .user = .{ .content = .{ .text = "First message" }, .timestamp = std.time.timestamp() } };
    const user_msg2 = ai_types.Message{ .user = .{ .content = .{ .text = "Second message" }, .timestamp = std.time.timestamp() } };

    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{ user_msg1, user_msg2 },
    };

    const body = try buildRequestBody(model, ctx, .{ .max_tokens = 100 }, allocator);
    defer allocator.free(body);

    // Verify cache_control is added to the last user message
    try std.testing.expect(std.mem.indexOf(u8, body, "cache_control") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ephemeral") != null);

    // The body should contain array content format for the last user message
    // Verify structure contains the expected format
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"text\"") != null);
}

test "buildRequestBody does not add cache_control for non-OpenRouter Anthropic" {
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

    const user_msg = ai_types.Message{ .user = .{ .content = .{ .text = "Hello" }, .timestamp = std.time.timestamp() } };

    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{user_msg},
    };

    const body = try buildRequestBody(model, ctx, .{ .max_tokens = 100 }, allocator);
    defer allocator.free(body);

    // Verify cache_control is NOT added for non-OpenRouter
    try std.testing.expect(std.mem.indexOf(u8, body, "cache_control") == null);
}

test "mergeCompat uses model-level compat options over detected capabilities" {
    // Model with explicit compat options that override detected capabilities
    const model = ai_types.Model{
        .id = "custom-model",
        .name = "Custom Model",
        .api = "openai-completions",
        .provider = "custom",
        .base_url = "https://api.openai.com", // Would normally detect supports_store=true
        .reasoning = true,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 100,
        .compat = .{
            .supports_store = false, // Override detected capability
            .supports_reasoning_effort = false,
            .max_tokens_field = .max_tokens, // Override default
            .supports_strict_mode = false,
        },
    };

    const merged = mergeCompat(model);

    // Model-level compat should take precedence
    try std.testing.expect(!merged.supports_store);
    try std.testing.expect(!merged.supports_reasoning_effort);
    try std.testing.expectEqualStrings("max_tokens", merged.max_tokens_field);
    try std.testing.expect(!merged.supports_strict_mode);
}

test "mergeCompat falls back to detected capabilities when model compat is null" {
    const model = ai_types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = true,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 100,
        // No compat field - should use detected capabilities
    };

    const merged = mergeCompat(model);

    // Should use detected capabilities for OpenAI native
    try std.testing.expect(merged.supports_store);
    try std.testing.expect(merged.supports_developer_role);
    try std.testing.expect(merged.supports_reasoning_effort);
    try std.testing.expectEqualStrings("max_completion_tokens", merged.max_tokens_field);
}

test "buildRequestBody uses max_tokens field from compat options" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "mistral-large",
        .name = "Mistral Large",
        .api = "openai-completions",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 100,
        .compat = .{
            .max_tokens_field = .max_tokens, // Mistral uses max_tokens
            .supports_store = false,
        },
    };

    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{},
    };

    const body = try buildRequestBody(model, ctx, .{ .max_tokens = 50 }, allocator);
    defer allocator.free(body);

    // Should use max_tokens, not max_completion_tokens
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "max_completion_tokens") == null);
    // Should not include store field
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\"") == null);
}

test "buildRequestBody adds strict mode when supported" {
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
        .compat = .{
            .supports_strict_mode = true,
        },
    };

    const tool = ai_types.Tool{
        .name = "test_tool",
        .description = "A test tool",
        .parameters_schema_json = "{\"type\":\"object\"}",
    };

    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{},
        .tools = &[_]ai_types.Tool{tool},
    };

    const body = try buildRequestBody(model, ctx, .{ .max_tokens = 100 }, allocator);
    defer allocator.free(body);

    // Should include strict: true in tool definition
    try std.testing.expect(std.mem.indexOf(u8, body, "\"strict\":true") != null);
}

test "buildRequestBody omits strict mode when not supported" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "custom-model",
        .name = "Custom Model",
        .api = "openai-completions",
        .provider = "custom",
        .base_url = "https://api.custom.com",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 100,
        .compat = .{
            .supports_strict_mode = false,
        },
    };

    const tool = ai_types.Tool{
        .name = "test_tool",
        .description = "A test tool",
        .parameters_schema_json = "{\"type\":\"object\"}",
    };

    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{},
        .tools = &[_]ai_types.Tool{tool},
    };

    const body = try buildRequestBody(model, ctx, .{ .max_tokens = 100 }, allocator);
    defer allocator.free(body);

    // Should NOT include strict field
    try std.testing.expect(std.mem.indexOf(u8, body, "\"strict\"") == null);
}

test "buildRequestBody adds store: false for OpenAI native" {
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

    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{},
    };

    const body = try buildRequestBody(model, ctx, .{ .max_tokens = 100 }, allocator);
    defer allocator.free(body);

    // Should include store: false
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
}

test "buildRequestBody omits store field for non-OpenAI providers" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "mistral-large",
        .name = "Mistral Large",
        .api = "openai-completions",
        .provider = "mistral",
        .base_url = "https://api.mistral.ai",
        .reasoning = false,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128_000,
        .max_tokens = 100,
    };

    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{},
    };

    const body = try buildRequestBody(model, ctx, .{ .max_tokens = 100 }, allocator);
    defer allocator.free(body);

    // Should NOT include store field for Mistral
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\"") == null);
}

test "parseChunk extracts reasoning_details for encrypted reasoning round-trip" {
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
    var reasoning_detail_events = std.ArrayList(ReasoningDetailEvent){};
    defer {
        for (reasoning_detail_events.items) |*rde| {
            @constCast(rde).deinit(allocator);
        }
        reasoning_detail_events.deinit(allocator);
    }

    // First, start a tool call
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
        &reasoning_detail_events,
        allocator,
    );

    try std.testing.expectEqual(@as(usize, 1), tool_call_events.items.len);
    for (tool_call_events.items) |*tce| {
        @constCast(tce).deinit(allocator);
    }
    tool_call_events.clearRetainingCapacity();

    // Now send reasoning_details with encrypted reasoning
    const chunk2 =
        \\{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.encrypted","id":"call_abc123","data":"encrypted_data_here"}]}}]}
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
        &reasoning_detail_events,
        allocator,
    );

    // Should have extracted the reasoning_detail event
    try std.testing.expectEqual(@as(usize, 1), reasoning_detail_events.items.len);
    try std.testing.expectEqualStrings("call_abc123", reasoning_detail_events.items[0].tool_call_id);
    try std.testing.expect(std.mem.indexOf(u8, reasoning_detail_events.items[0].detail_json, "reasoning.encrypted") != null);
    try std.testing.expect(std.mem.indexOf(u8, reasoning_detail_events.items[0].detail_json, "call_abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, reasoning_detail_events.items[0].detail_json, "encrypted_data_here") != null);
}

test "buildRequestBody includes reasoning_details for tool calls with thought_signature" {
    const allocator = std.testing.allocator;

    const model = ai_types.Model{
        .id = "o1",
        .name = "O1",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = true,
        .input = &[_][]const u8{"text"},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 200_000,
        .max_tokens = 100,
    };

    // Assistant message with tool call that has thought_signature
    const tool_call_id = try allocator.dupe(u8, "call_abc123");
    defer allocator.free(tool_call_id);
    const tool_call_name = try allocator.dupe(u8, "bash");
    defer allocator.free(tool_call_name);
    const tool_call_args = try allocator.dupe(u8, "{\"cmd\":\"ls\"}");
    defer allocator.free(tool_call_args);
    const thought_sig = try allocator.dupe(u8, "{\"type\":\"reasoning.encrypted\",\"id\":\"call_abc123\",\"data\":\"encrypted\"}");
    defer allocator.free(thought_sig);

    const assistant_content = try allocator.alloc(ai_types.AssistantContent, 1);
    defer allocator.free(assistant_content);
    assistant_content[0] = .{
        .tool_call = .{
            .id = tool_call_id,
            .name = tool_call_name,
            .arguments_json = tool_call_args,
            .thought_signature = thought_sig,
        },
    };

    const assistant_msg = ai_types.Message{
        .assistant = .{
            .content = assistant_content,
            .api = "openai-completions",
            .provider = "openai",
            .model = "o1",
            .usage = .{},
            .stop_reason = .tool_use,
            .timestamp = std.time.timestamp(),
        },
    };

    const ctx = ai_types.Context{
        .messages = &[_]ai_types.Message{assistant_msg},
    };

    const body = try buildRequestBody(model, ctx, .{ .max_tokens = 100 }, allocator);
    defer allocator.free(body);

    // Should include reasoning_details array
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_details") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning.encrypted") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "call_abc123") != null);
}
