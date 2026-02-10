const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const provider = @import("provider");
const config = @import("config");
const json_writer = @import("json_writer");

/// Ollama provider context
pub const OllamaContext = struct {
    config: config.OllamaConfig,
    allocator: std.mem.Allocator,
};

/// Create an Ollama provider
pub fn createProvider(
    cfg: config.OllamaConfig,
    allocator: std.mem.Allocator,
) !provider.Provider {
    const ctx = try allocator.create(OllamaContext);
    ctx.* = .{
        .config = cfg,
        .allocator = allocator,
    };

    return provider.Provider{
        .id = "ollama",
        .name = "Ollama Local",
        .context = @ptrCast(ctx),
        .stream_fn = ollamaStreamFn,
        .deinit_fn = ollamaDeinitFn,
    };
}

/// Stream function implementation
fn ollamaStreamFn(
    ctx_ptr: *anyopaque,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    const ctx: *OllamaContext = @ptrCast(@alignCast(ctx_ptr));

    const stream = try allocator.create(event_stream.AssistantMessageStream);
    stream.* = event_stream.AssistantMessageStream.init(allocator);

    const request_body = try buildRequestBody(ctx.config, messages, allocator);
    defer allocator.free(request_body);

    const thread_ctx = try allocator.create(StreamThreadContext);
    thread_ctx.* = .{
        .stream = stream,
        .request_body = try allocator.dupe(u8, request_body),
        .config = ctx.config,
        .allocator = allocator,
    };

    const thread = try std.Thread.spawn(.{}, streamThread, .{thread_ctx});
    thread.detach();

    return stream;
}

/// Cleanup function
fn ollamaDeinitFn(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const ollama_ctx: *OllamaContext = @ptrCast(@alignCast(ctx));
    allocator.destroy(ollama_ctx);
}

/// Thread context for background streaming
const StreamThreadContext = struct {
    stream: *event_stream.AssistantMessageStream,
    request_body: []u8,
    config: config.OllamaConfig,
    allocator: std.mem.Allocator,
};

/// Background thread function
fn streamThread(ctx: *StreamThreadContext) void {
    defer {
        ctx.allocator.free(ctx.request_body);
        ctx.allocator.destroy(ctx);
    }

    streamImpl(ctx) catch |err| {
        const err_msg = std.fmt.allocPrint(ctx.allocator, "Stream error: {}", .{err}) catch "Unknown stream error";
        ctx.stream.completeWithError(err_msg);
    };
}

/// Main streaming implementation
fn streamImpl(ctx: *StreamThreadContext) !void {
    // Check cancellation before starting
    if (ctx.config.cancel_token) |token| {
        if (token.isCancelled()) {
            ctx.stream.completeWithError("Stream cancelled");
            return;
        }
    }

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    const url = try std.fmt.allocPrint(ctx.allocator, "{s}/api/chat", .{ctx.config.base_url});
    defer ctx.allocator.free(url);

    const uri = try std.Uri.parse(url);

    var header_buffer: [4096]u8 = undefined;
    var request = try client.open(.POST, uri, .{
        .server_header_buffer = &header_buffer,
    });
    defer request.deinit();

    request.transfer_encoding = .chunked;

    try request.headers.append("content-type", "application/json");

    // Apply custom headers
    if (ctx.config.custom_headers) |headers| {
        for (headers) |h| {
            request.headers.append(h.name, h.value) catch {};
        }
    }

    try request.send();
    try request.writeAll(ctx.request_body);
    try request.finish();

    try request.wait();

    if (request.response.status != .ok) {
        const error_body = try request.reader().readAllAlloc(ctx.allocator, 8192);
        defer ctx.allocator.free(error_body);
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "API error {d}: {s}", .{ @intFromEnum(request.response.status), error_body });
        ctx.stream.completeWithError(err_msg);
        return;
    }

    var buffer: [4096]u8 = undefined;
    var line_buffer = std.ArrayList(u8).init(ctx.allocator);
    defer line_buffer.deinit();

    var state = OllamaStreamState.init(ctx.allocator);
    defer state.deinit();

    var accumulated_content = std.ArrayList(types.ContentBlock).init(ctx.allocator);
    defer {
        for (accumulated_content.items) |block| {
            switch (block) {
                .text => |t| ctx.allocator.free(t.text),
                .tool_use => |tu| {
                    ctx.allocator.free(tu.id);
                    ctx.allocator.free(tu.name);
                    ctx.allocator.free(tu.input_json);
                },
                .thinking => |th| ctx.allocator.free(th.thinking),
                .image => |img| {
                    ctx.allocator.free(img.media_type);
                    ctx.allocator.free(img.data);
                },
            }
        }
        accumulated_content.deinit();
    }

    var usage = types.Usage{};
    var stop_reason: types.StopReason = .stop;
    var model_owned: ?[]u8 = null;
    defer if (model_owned) |m| ctx.allocator.free(m);

    while (true) {
        // Check cancellation between chunks
        if (ctx.config.cancel_token) |token| {
            if (token.isCancelled()) {
                ctx.stream.completeWithError("Stream cancelled");
                return;
            }
        }

        const bytes_read = try request.reader().read(&buffer);
        if (bytes_read == 0) break;

        // Process newline-delimited JSON
        for (buffer[0..bytes_read]) |byte| {
            if (byte == '\n') {
                if (line_buffer.items.len > 0) {
                    const message_event = try parseOllamaLine(line_buffer.items, &state, ctx.allocator);
                    if (message_event) |evt| {
                        switch (evt) {
                            .start => |s| {
                                if (model_owned) |m| ctx.allocator.free(m);
                                model_owned = try ctx.allocator.dupe(u8, s.model);
                            },
                            .text_start => {
                                try accumulated_content.append(types.ContentBlock{ .text = .{ .text = "" } });
                            },
                            .text_delta => |delta| {
                                if (delta.index < accumulated_content.items.len) {
                                    const block = &accumulated_content.items[delta.index];
                                    switch (block.*) {
                                        .text => |*t| {
                                            const old_text = t.text;
                                            t.text = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ old_text, delta.delta });
                                            if (old_text.len > 0) ctx.allocator.free(old_text);
                                        },
                                        else => {},
                                    }
                                }
                            },
                            .done => |d| {
                                usage = d.usage;
                                stop_reason = d.stop_reason;
                            },
                            else => {},
                        }

                        try ctx.stream.push(evt);
                    }
                    line_buffer.clearRetainingCapacity();
                }
            } else {
                try line_buffer.append(byte);
            }
        }
    }

    // Process any remaining line
    if (line_buffer.items.len > 0) {
        const message_event = try parseOllamaLine(line_buffer.items, &state, ctx.allocator);
        if (message_event) |evt| {
            try ctx.stream.push(evt);
        }
    }

    const final_content = try ctx.allocator.alloc(types.ContentBlock, accumulated_content.items.len);
    @memcpy(final_content, accumulated_content.items);

    const result = types.AssistantMessage{
        .content = final_content,
        .usage = usage,
        .stop_reason = stop_reason,
        .model = model_owned orelse try ctx.allocator.dupe(u8, ctx.config.model),
        .timestamp = std.time.timestamp(),
    };

    ctx.stream.complete(result);
}

/// Build request body for Ollama API
pub fn buildRequestBody(
    cfg: config.OllamaConfig,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    var writer = json_writer.JsonWriter.init(&buffer, allocator);

    try writer.beginObject();

    try writer.writeStringField("model", cfg.model);
    try writer.writeBoolField("stream", true);

    // Add keep_alive if set
    if (cfg.keep_alive) |keep_alive| {
        try writer.writeStringField("keep_alive", keep_alive);
    }

    // Add format if set
    if (cfg.format) |format| {
        switch (format) {
            .text => {}, // Don't write anything for text format (default)
            .json_object => {
                try writer.writeStringField("format", "json");
            },
            .json_schema => |schema| {
                try writer.writeStringField("format", schema);
            },
        }
    }

    // Build messages array
    try writer.writeKey("messages");
    try writer.beginArray();

    // Prepend system message if system_prompt is provided
    if (cfg.params.system_prompt) |system| {
        try writer.beginObject();
        try writer.writeStringField("role", "system");
        try writer.writeStringField("content", system);
        try writer.endObject();
    }

    for (messages) |message| {
        try writer.beginObject();

        const role_str = switch (message.role) {
            .user => "user",
            .assistant => "assistant",
            .tool_result => "user",
        };
        try writer.writeStringField("role", role_str);

        // Extract text content from content blocks
        if (message.content.len > 0) {
            var content_text = std.ArrayList(u8){};
            defer content_text.deinit(allocator);
            var has_images = false;
            var image_list = std.ArrayList([]const u8){};
            defer image_list.deinit(allocator);

            for (message.content) |block| {
                switch (block) {
                    .text => |text| {
                        try content_text.appendSlice(allocator, text.text);
                    },
                    .image => |img| {
                        has_images = true;
                        try image_list.append(allocator, img.data);
                    },
                    else => {},
                }
            }

            try writer.writeStringField("content", content_text.items);

            // Add images if present (Ollama format)
            if (has_images) {
                try writer.writeKey("images");
                try writer.beginArray();
                for (image_list.items) |img_data| {
                    try writer.writeString(img_data);
                }
                try writer.endArray();
            }
        }

        try writer.endObject();
    }
    try writer.endArray();

    // Add options
    try writer.writeKey("options");
    try writer.beginObject();

    if (cfg.params.temperature != 1.0) {
        try writer.writeKey("temperature");
        try writer.writeFloat(cfg.params.temperature);
    }

    if (cfg.params.top_p) |top_p| {
        try writer.writeKey("top_p");
        try writer.writeFloat(top_p);
    }

    if (cfg.params.top_k) |top_k| {
        try writer.writeIntField("top_k", top_k);
    }

    // Add num_ctx if set
    if (cfg.num_ctx) |num_ctx| {
        try writer.writeIntField("num_ctx", num_ctx);
    }

    // Add num_predict: use cfg.num_predict if set, otherwise use max_tokens
    if (cfg.num_predict) |num_predict| {
        try writer.writeKey("num_predict");
        try writer.writeInt(num_predict);
    } else {
        try writer.writeIntField("num_predict", cfg.params.max_tokens);
    }

    // Add repeat_penalty if set
    if (cfg.repeat_penalty) |repeat_penalty| {
        try writer.writeKey("repeat_penalty");
        try writer.writeFloat(repeat_penalty);
    }

    // Add seed if set
    if (cfg.seed) |seed| {
        try writer.writeIntField("seed", seed);
    }

    try writer.endObject();

    try writer.endObject();

    return buffer.toOwnedSlice(allocator);
}

/// State for tracking Ollama stream
pub const OllamaStreamState = struct {
    text_started: bool = false,
    model: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OllamaStreamState {
        return OllamaStreamState{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OllamaStreamState) void {
        if (self.model) |m| {
            self.allocator.free(m);
        }
    }
};

/// Parse Ollama JSON line and emit MessageEvent
pub fn parseOllamaLine(
    line: []const u8,
    state: *OllamaStreamState,
    allocator: std.mem.Allocator,
) !?types.MessageEvent {
    if (line.len == 0) return null;

    const parsed = std.json.parseFromSlice(
        struct {
            model: ?[]const u8 = null,
            created_at: ?[]const u8 = null,
            message: ?struct {
                role: []const u8,
                content: []const u8,
            } = null,
            done: bool,
            total_duration: ?u64 = null,
            prompt_eval_count: ?u64 = null,
            eval_count: ?u64 = null,
        },
        allocator,
        line,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();

    const data = parsed.value;

    // First chunk: emit start event
    if (!state.text_started) {
        if (data.model) |model| {
            if (state.model) |m| allocator.free(m);
            state.model = try allocator.dupe(u8, model);

            const start_event = types.MessageEvent{ .start = .{
                .model = try allocator.dupe(u8, model),
            } };
            state.text_started = true;
            return start_event;
        }
    }

    // Content delta
    if (data.message) |msg| {
        if (msg.content.len > 0) {
            // First content emits text_start
            if (state.text_started and std.mem.eql(u8, msg.role, "assistant")) {
                state.text_started = false;
                const text_start = types.MessageEvent{ .text_start = .{ .index = 0 } };
                // We need to emit both text_start and text_delta, but can only return one
                // So we'll just emit the text_delta and assume text_start is implicit
                // Actually, let's emit text_start first
                return text_start;
            }

            const delta = try allocator.dupe(u8, msg.content);
            return types.MessageEvent{ .text_delta = .{
                .index = 0,
                .delta = delta,
            } };
        }
    }

    // Done event
    if (data.done) {
        const usage = types.Usage{
            .input_tokens = data.prompt_eval_count orelse 0,
            .output_tokens = data.eval_count orelse 0,
        };

        return types.MessageEvent{ .done = .{
            .usage = usage,
            .stop_reason = .stop,
        } };
    }

    return null;
}

// Tests
test "buildRequestBody basic" {
    const allocator = std.testing.allocator;

    const cfg = config.OllamaConfig{
        .model = "llama3.2",
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello, Ollama!" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"llama3.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hello, Ollama!\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"options\"") != null);
}

test "buildRequestBody with custom parameters" {
    const allocator = std.testing.allocator;

    const cfg = config.OllamaConfig{
        .model = "mistral",
        .params = .{
            .max_tokens = 2048,
            .temperature = 0.7,
            .top_p = 0.9,
        },
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Test" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"mistral\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"num_predict\":2048") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.7") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"top_p\":0.9") != null);
}

test "parseOllamaLine first chunk" {
    const allocator = std.testing.allocator;

    var state = OllamaStreamState.init(allocator);
    defer state.deinit();

    const line = "{\"model\":\"llama3\",\"created_at\":\"2024-01-01T00:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":false}";

    const event = try parseOllamaLine(line, &state, allocator);
    defer if (event) |evt| {
        switch (evt) {
            .start => |s| allocator.free(s.model),
            else => {},
        }
    };

    try std.testing.expect(event != null);
    try std.testing.expect(std.meta.activeTag(event.?) == .start);
    try std.testing.expectEqualStrings("llama3", event.?.start.model);
}

test "parseOllamaLine content chunk" {
    const allocator = std.testing.allocator;

    var state = OllamaStreamState.init(allocator);
    defer state.deinit();
    state.text_started = true; // Already past the start phase

    const line = "{\"model\":\"llama3\",\"created_at\":\"2024-01-01T00:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"done\":false}";

    const event = try parseOllamaLine(line, &state, allocator);
    defer if (event) |evt| {
        switch (evt) {
            .text_delta => |d| allocator.free(d.delta),
            .text_start => {},
            else => {},
        }
    };

    try std.testing.expect(event != null);
    // First content after start emits text_start
    try std.testing.expect(std.meta.activeTag(event.?) == .text_start);
}

test "parseOllamaLine done chunk" {
    const allocator = std.testing.allocator;

    var state = OllamaStreamState.init(allocator);
    defer state.deinit();
    state.text_started = true; // Already past the start phase

    // Done chunk with no message content, just done=true
    const line = "{\"model\":\"llama3\",\"created_at\":\"2024-01-01T00:00:00Z\",\"done\":true,\"total_duration\":5000000000,\"prompt_eval_count\":10,\"eval_count\":25}";

    const event = try parseOllamaLine(line, &state, allocator);

    try std.testing.expect(event != null);
    try std.testing.expect(std.meta.activeTag(event.?) == .done);
    try std.testing.expectEqual(@as(u64, 10), event.?.done.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 25), event.?.done.usage.output_tokens);
    try std.testing.expect(event.?.done.stop_reason == .stop);
}

test "parseOllamaLine empty line" {
    const allocator = std.testing.allocator;

    var state = OllamaStreamState.init(allocator);
    defer state.deinit();

    const event = try parseOllamaLine("", &state, allocator);
    try std.testing.expect(event == null);
}

test "OllamaStreamState init and deinit" {
    const allocator = std.testing.allocator;

    var state = OllamaStreamState.init(allocator);
    try std.testing.expect(state.text_started == false);
    try std.testing.expect(state.model == null);

    state.model = try allocator.dupe(u8, "test-model");
    state.deinit();
}

test "buildRequestBody with system prompt" {
    const allocator = std.testing.allocator;

    const cfg = config.OllamaConfig{
        .model = "llama3.2",
        .params = .{
            .system_prompt = "You are a helpful assistant.",
        },
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello!" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"You are a helpful assistant.\"") != null);
}
