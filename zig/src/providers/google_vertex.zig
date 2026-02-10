const std = @import("std");
const types = @import("types");
const event_stream = @import("event_stream");
const provider = @import("provider");
const config = @import("config");
const sse_parser = @import("sse_parser");
const json_writer = @import("json_writer");
const google_shared = @import("google_shared");

/// Google Vertex AI provider config
pub const GoogleVertexConfig = struct {
    allocator: std.mem.Allocator,
    access_token: []const u8, // OAuth token
    project_id: []const u8,
    location: []const u8 = "us-central1",
    model_id: []const u8 = "gemini-2.5-flash",
    base_url: ?[]const u8 = null,
    params: config.RequestParams = .{},
    thinking: ?google.ThinkingConfig = null,
    custom_headers: ?[]const config.HeaderPair = null,
    retry_config: config.RetryConfig = .{},
    cancel_token: ?config.CancelToken = null,
};

// Import Google provider for shared types
const google = @import("google");

/// Vertex provider context
pub const VertexContext = struct {
    config: GoogleVertexConfig,
    allocator: std.mem.Allocator,
};

/// Create a Google Vertex AI provider
pub fn createProvider(cfg: GoogleVertexConfig, allocator: std.mem.Allocator) !provider.Provider {
    const ctx = try allocator.create(VertexContext);
    ctx.* = .{
        .config = cfg,
        .allocator = allocator,
    };

    return provider.Provider{
        .id = "google_vertex",
        .name = "Google Vertex AI",
        .context = @ptrCast(ctx),
        .stream_fn = vertexStreamFn,
        .deinit_fn = vertexDeinitFn,
    };
}

/// Stream function implementation
fn vertexStreamFn(
    ctx_ptr: *anyopaque,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !*event_stream.AssistantMessageStream {
    const ctx: *VertexContext = @ptrCast(@alignCast(ctx_ptr));

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
fn vertexDeinitFn(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const vertex_ctx: *VertexContext = @ptrCast(@alignCast(ctx));
    allocator.destroy(vertex_ctx);
}

/// Thread context for background streaming
const StreamThreadContext = struct {
    stream: *event_stream.AssistantMessageStream,
    request_body: []u8,
    config: GoogleVertexConfig,
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
    // Check cancellation
    if (ctx.config.cancel_token) |token| {
        if (token.isCancelled()) {
            ctx.stream.completeWithError("Stream cancelled");
            return;
        }
    }

    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    // Build Vertex AI endpoint URL
    const base = ctx.config.base_url orelse blk: {
        break :blk try std.fmt.allocPrint(
            ctx.allocator,
            "https://{s}-aiplatform.googleapis.com",
            .{ctx.config.location},
        );
    };
    defer if (ctx.config.base_url == null) ctx.allocator.free(base);

    const url = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:streamGenerateContent",
        .{ base, ctx.config.project_id, ctx.config.location, ctx.config.model_id },
    );
    defer ctx.allocator.free(url);

    const uri = try std.Uri.parse(url);

    // Build headers
    const auth_header = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{ctx.config.access_token});
    defer ctx.allocator.free(auth_header);

    var headers: std.ArrayList(std.http.Header) = .{};
    defer headers.deinit(ctx.allocator);
    try headers.append(ctx.allocator, .{ .name = "authorization", .value = auth_header });
    try headers.append(ctx.allocator, .{ .name = "content-type", .value = "application/json" });

    // Custom headers
    if (ctx.config.custom_headers) |custom| {
        for (custom) |h| {
            headers.append(ctx.allocator, .{ .name = h.name, .value = h.value }) catch {};
        }
    }

    var request = try client.request(.POST, uri, .{
        .extra_headers = headers.items,
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = ctx.request_body.len };

    try request.sendBodyComplete(ctx.request_body);

    var header_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&header_buffer);

    if (response.head.status != .ok) {
        var buffer: [4096]u8 = undefined;
        const error_body = try response.reader(&buffer).*.allocRemaining(ctx.allocator, std.io.Limit.limited(8192));
        defer ctx.allocator.free(error_body);
        const err_msg = try std.fmt.allocPrint(
            ctx.allocator,
            "API error {d}: {s}",
            .{ @intFromEnum(response.head.status), error_body },
        );
        ctx.stream.completeWithError(err_msg);
        return;
    }

    // Reuse Google's response parser
    var transfer_buffer: [4096]u8 = undefined;
    try google.parseResponse(
        @as(*google.StreamThreadContext, @ptrCast(@alignCast(ctx))),
        response.reader(&transfer_buffer),
    );
}

/// Build request body JSON (same format as Google Generative AI)
fn buildRequestBody(
    cfg: GoogleVertexConfig,
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);

    var writer = json_writer.JsonWriter.init(&buffer, allocator);

    try writer.beginObject();

    // Convert messages
    var contents = try google_shared.convertMessages(messages, allocator);
    defer {
        for (contents.items) |content| {
            allocator.free(content.parts);
        }
        contents.deinit(allocator);
    }

    // System instruction
    if (cfg.params.system_prompt) |system| {
        try writer.writeKey("systemInstruction");
        try writer.beginObject();
        try writer.writeKey("parts");
        try writer.beginArray();
        try writer.beginObject();
        try writer.writeStringField("text", system);
        try writer.endObject();
        try writer.endArray();
        try writer.endObject();
    }

    // Contents
    try writer.writeKey("contents");
    try google_shared.writeContents(&writer, contents.items);

    // Generation config
    try writer.writeKey("generationConfig");
    try writer.beginObject();

    if (cfg.params.temperature != 1.0) {
        try writer.writeKey("temperature");
        try writer.writeFloat(cfg.params.temperature);
    }

    if (cfg.params.top_p) |top_p| {
        try writer.writeKey("topP");
        try writer.writeFloat(top_p);
    }

    if (cfg.params.top_k) |top_k| {
        try writer.writeIntField("topK", top_k);
    }

    try writer.writeIntField("maxOutputTokens", cfg.params.max_tokens);

    if (cfg.params.stop_sequences) |stop_seqs| {
        try writer.writeKey("stopSequences");
        try writer.beginArray();
        for (stop_seqs) |seq| {
            try writer.writeString(seq);
        }
        try writer.endArray();
    }

    try writer.endObject();

    // Tools
    if (cfg.params.tools) |tools| {
        var declarations = try google_shared.convertTools(tools, allocator);
        defer declarations.deinit(allocator);

        try writer.writeKey("tools");
        try writer.beginArray();
        try writer.beginObject();
        try writer.writeKey("functionDeclarations");
        try google_shared.writeFunctionDeclarations(&writer, declarations.items);
        try writer.endObject();
        try writer.endArray();

        // Tool config
        if (cfg.params.tool_choice) |tc| {
            try writer.writeKey("toolConfig");
            try writer.beginObject();
            try writer.writeKey("functionCallingConfig");
            try writer.beginObject();
            const mode = switch (tc) {
                .auto => "AUTO",
                .none => "NONE",
                .any => "ANY",
                .specific => "AUTO",
            };
            try writer.writeStringField("mode", mode);
            try writer.endObject();
            try writer.endObject();
        }
    }

    // Thinking config
    if (cfg.thinking) |thinking_cfg| {
        if (thinking_cfg.enabled) {
            try writer.writeKey("thinkingConfig");
            try writer.beginObject();

            if (thinking_cfg.level) |level| {
                const level_str = switch (level) {
                    .minimal => "MINIMAL",
                    .low => "LOW",
                    .medium => "MEDIUM",
                    .high => "HIGH",
                };
                try writer.writeStringField("thinkingLevel", level_str);
            } else if (thinking_cfg.budget_tokens) |budget| {
                try writer.writeIntField("thinkingBudget", budget);
            }

            try writer.endObject();
        }
    }

    try writer.endObject();

    return buffer.toOwnedSlice(allocator);
}

// Tests
test "buildRequestBody basic" {
    const allocator = std.testing.allocator;

    const cfg = GoogleVertexConfig{
        .allocator = allocator,
        .access_token = "test-token",
        .project_id = "test-project",
        .location = "us-central1",
        .model_id = "gemini-2.5-flash",
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

    try std.testing.expect(std.mem.indexOf(u8, body, "\"contents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"generationConfig\"") != null);
}

test "buildRequestBody with thinking level" {
    const allocator = std.testing.allocator;

    const cfg = GoogleVertexConfig{
        .allocator = allocator,
        .access_token = "test-token",
        .project_id = "test-project",
        .thinking = .{
            .enabled = true,
            .level = .high,
        },
    };

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Think!" } },
            },
            .timestamp = 0,
        },
    };

    const body = try buildRequestBody(cfg, &messages, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinkingConfig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinkingLevel\":\"HIGH\"") != null);
}
