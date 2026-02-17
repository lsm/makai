const std = @import("std");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const json_writer = @import("json_writer");

// --- Async byte stream types ---

/// A chunk of bytes with ownership semantics
pub const ByteChunk = struct {
    data: []const u8,
    /// If true, caller owns the data and must free it
    owned: bool = true,

    pub fn deinit(self: *ByteChunk, allocator: std.mem.Allocator) void {
        if (self.owned and self.data.len > 0) {
            allocator.free(self.data);
        }
    }
};

/// Stream of byte chunks with void result
pub const ByteStream = event_stream.EventStream(ByteChunk, void);

// --- Wire message type ---

pub const MessageOrControl = union(enum) {
    event: ai_types.AssistantMessageEvent,
    result: ai_types.AssistantMessage,
    stream_error: []const u8,
};

// --- Transport interfaces ---

pub const Sender = struct {
    context: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
    flush_fn: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    close_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn write(self: *const Sender, data: []const u8) !void {
        return self.write_fn(self.context, data);
    }

    pub fn flush(self: *const Sender) !void {
        if (self.flush_fn) |f| return f(self.context);
    }

    pub fn close(self: *const Sender) void {
        if (self.close_fn) |f| f(self.context);
    }
};

pub const Receiver = struct {
    context: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]const u8,
    close_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn read(self: *const Receiver, allocator: std.mem.Allocator) !?[]const u8 {
        return self.read_fn(self.context, allocator);
    }

    pub fn close(self: *const Receiver) void {
        if (self.close_fn) |f| f(self.context);
    }
};

// --- Async transport interfaces ---

pub const AsyncSender = struct {
    context: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
    flush_fn: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    close_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn write(self: *const AsyncSender, data: []const u8) !void {
        return self.write_fn(self.context, data);
    }

    pub fn flush(self: *const AsyncSender) !void {
        if (self.flush_fn) |f| return f(self.context);
    }

    pub fn close(self: *const AsyncSender) void {
        if (self.close_fn) |f| f(self.context);
    }
};

pub const AsyncReceiver = struct {
    context: *anyopaque,

    /// Create a new byte stream for receiving data
    receive_stream_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror!*ByteStream,

    /// Optional: synchronous read for backward compatibility
    read_fn: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror!?[]const u8 = null,

    close_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn receiveStream(self: *AsyncReceiver, allocator: std.mem.Allocator) !*ByteStream {
        return self.receive_stream_fn(self.context, allocator);
    }

    pub fn read(self: *AsyncReceiver, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.read_fn) |rf| return rf(self.context, allocator);
        return error.AsyncOnly;
    }

    pub fn close(self: *AsyncReceiver) void {
        if (self.close_fn) |f| f(self.context);
    }
};

// --- Generic adapters ---

/// Forward all events from a stream to a Sender. Blocks until stream is complete.
pub fn forwardStream(
    stream: *event_stream.AssistantMessageStream,
    sender: *const Sender,
    allocator: std.mem.Allocator,
) !void {
    while (stream.wait()) |ev| {
        const json_bytes = try serializeEvent(ev, allocator);
        defer allocator.free(json_bytes);
        try sender.write(json_bytes);
        try sender.flush();
    }

    if (stream.getError()) |err_msg| {
        const json_bytes = try serializeError(err_msg, allocator);
        defer allocator.free(json_bytes);
        try sender.write(json_bytes);
    } else if (stream.getResult()) |result| {
        const json_bytes = try serializeResult(result, allocator);
        defer allocator.free(json_bytes);
        try sender.write(json_bytes);
    }
    try sender.flush();
}

/// Receive from a Receiver and push into a local stream. Blocks until done.
pub fn receiveStream(
    receiver: *const Receiver,
    stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
) !void {
    while (try receiver.read(allocator)) |line| {
        defer allocator.free(line);
        const msg = try deserialize(line, allocator);
        switch (msg) {
            .event => |ev| try stream.push(ev),
            .result => |r| {
                stream.complete(r);
                return;
            },
            .stream_error => |e| {
                stream.completeWithError(e);
                return;
            },
        }
    }
    stream.completeWithError("Transport closed unexpectedly");
}

// --- Async stream bridge functions ---

/// Free allocated strings in an event (used when event is not pushed to stream)
fn freeEventStrings(ev: ai_types.AssistantMessageEvent, allocator: std.mem.Allocator) void {
    switch (ev) {
        .start => |e| {
            var mutable = e.partial;
            mutable.deinit(allocator);
        },
        .text_delta => |e| {
            allocator.free(e.delta);
        },
        .thinking_delta => |e| {
            allocator.free(e.delta);
        },
        .toolcall_end => |e| {
            allocator.free(e.tool_call.id);
            allocator.free(e.tool_call.name);
            allocator.free(e.tool_call.arguments_json);
            if (e.tool_call.thought_signature) |sig| {
                allocator.free(sig);
            }
        },
        .done => |e| {
            var mutable = e.message;
            mutable.deinit(allocator);
        },
        else => {},
    }
}

/// Receive from a ByteStream and push into an AssistantMessageStream
pub fn receiveStreamFromByteStream(
    byte_stream: *ByteStream,
    msg_stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
) void {
    defer byte_stream.complete({});

    while (byte_stream.wait()) |chunk| {
        defer {
            var mutable_chunk = chunk;
            mutable_chunk.deinit(allocator);
        }

        const msg = deserialize(chunk.data, allocator) catch {
            msg_stream.completeWithError("Deserialization error");
            return;
        };

        switch (msg) {
            .event => |ev| {
                msg_stream.push(ev) catch {
                    msg_stream.completeWithError("Stream queue full");
                    freeEventStrings(ev, allocator);
                    return;
                };
            },
            .result => |r| {
                msg_stream.complete(r);
                return;
            },
            .stream_error => |e| {
                const err_copy = allocator.dupe(u8, e) catch e;
                msg_stream.completeWithError(err_copy);
                allocator.free(e);
                return;
            },
        }
    }

    if (byte_stream.getError()) |err| {
        msg_stream.completeWithError(err);
    } else {
        msg_stream.completeWithError("Transport closed unexpectedly");
    }
}

/// Context for spawnReceiver thread
const ReceiverThreadContext = struct {
    byte_stream: *ByteStream,
    msg_stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,

    fn run(ctx: *@This()) void {
        defer ctx.allocator.destroy(ctx);
        receiveStreamFromByteStream(ctx.byte_stream, ctx.msg_stream, ctx.allocator);
        ctx.byte_stream.deinit();
        ctx.allocator.destroy(ctx.byte_stream);
    }
};

/// Spawn a receiver thread that bridges AsyncReceiver -> AssistantMessageStream
pub fn spawnReceiver(
    receiver: *const AsyncReceiver,
    msg_stream: *event_stream.AssistantMessageStream,
    allocator: std.mem.Allocator,
) !std.Thread {
    const byte_stream = try receiver.receiveStream(allocator);

    const ctx = try allocator.create(ReceiverThreadContext);
    ctx.* = .{
        .byte_stream = byte_stream,
        .msg_stream = msg_stream,
        .allocator = allocator,
    };

    return std.Thread.spawn(.{}, ReceiverThreadContext.run, .{ctx});
}

// --- Serialization ---

pub fn serializeEvent(event: ai_types.AssistantMessageEvent, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();

    switch (event) {
        .start => |s| {
            try w.writeStringField("type", "start");
            try w.writeStringField("model", s.partial.model);
        },
        .text_start => |e| {
            try w.writeStringField("type", "text_start");
            try w.writeIntField("content_index", e.content_index);
        },
        .text_delta => |d| {
            try w.writeStringField("type", "text_delta");
            try w.writeIntField("content_index", d.content_index);
            try w.writeStringField("delta", d.delta);
        },
        .text_end => |e| {
            try w.writeStringField("type", "text_end");
            try w.writeIntField("content_index", e.content_index);
        },
        .thinking_start => |e| {
            try w.writeStringField("type", "thinking_start");
            try w.writeIntField("content_index", e.content_index);
        },
        .thinking_delta => |d| {
            try w.writeStringField("type", "thinking_delta");
            try w.writeIntField("content_index", d.content_index);
            try w.writeStringField("delta", d.delta);
        },
        .thinking_end => |e| {
            try w.writeStringField("type", "thinking_end");
            try w.writeIntField("content_index", e.content_index);
        },
        .toolcall_start => |e| {
            try w.writeStringField("type", "toolcall_start");
            try w.writeIntField("content_index", e.content_index);
        },
        .toolcall_delta => |d| {
            try w.writeStringField("type", "toolcall_delta");
            try w.writeIntField("content_index", d.content_index);
            try w.writeStringField("delta", d.delta);
        },
        .toolcall_end => |e| {
            try w.writeStringField("type", "toolcall_end");
            try w.writeIntField("content_index", e.content_index);
            try w.writeStringField("id", e.tool_call.id);
            try w.writeStringField("name", e.tool_call.name);
            try w.writeStringField("arguments_json", e.tool_call.arguments_json);
            if (e.tool_call.thought_signature) |sig| {
                try w.writeStringField("thought_signature", sig);
            }
        },
        .done => |d| {
            try w.writeStringField("type", "done");
            try w.writeStringField("reason", @tagName(d.reason));
            try w.writeIntField("input", d.message.usage.input);
            try w.writeIntField("output", d.message.usage.output);
            try w.writeIntField("cache_read", d.message.usage.cache_read);
            try w.writeIntField("cache_write", d.message.usage.cache_write);
        },
        .@"error" => |e| {
            try w.writeStringField("type", "error");
            try w.writeStringField("reason", @tagName(e.reason));
        },
        .ping => {
            try w.writeStringField("type", "ping");
        },
    }

    try w.endObject();

    const result = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return result;
}

pub fn serializeResult(result: ai_types.AssistantMessage, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("type", "result");
    try w.writeStringField("stop_reason", @tagName(result.stop_reason));
    try w.writeStringField("model", result.model);
    try w.writeStringField("api", result.api);
    try w.writeStringField("provider", result.provider);
    try w.writeIntField("timestamp", result.timestamp);
    try w.writeIntField("input", result.usage.input);
    try w.writeIntField("output", result.usage.output);
    try w.writeIntField("cache_read", result.usage.cache_read);
    try w.writeIntField("cache_write", result.usage.cache_write);

    try w.writeKey("content");
    try w.beginArray();
    for (result.content) |block| {
        try serializeAssistantContent(&w, block);
    }
    try w.endArray();

    try w.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

pub fn serializeError(msg: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8){};
    errdefer buffer.deinit(allocator);
    var w = json_writer.JsonWriter.init(&buffer, allocator);

    try w.beginObject();
    try w.writeStringField("type", "stream_error");
    try w.writeStringField("message", msg);
    try w.endObject();

    const out = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return out;
}

fn serializeAssistantContent(w: *json_writer.JsonWriter, content: ai_types.AssistantContent) !void {
    try w.beginObject();
    switch (content) {
        .text => |t| {
            try w.writeStringField("type", "text");
            try w.writeStringField("text", t.text);
            if (t.text_signature) |sig| {
                try w.writeStringField("text_signature", sig);
            }
        },
        .tool_call => |tc| {
            try w.writeStringField("type", "tool_call");
            try w.writeStringField("id", tc.id);
            try w.writeStringField("name", tc.name);
            try w.writeStringField("arguments_json", tc.arguments_json);
            if (tc.thought_signature) |sig| {
                try w.writeStringField("thought_signature", sig);
            }
        },
        .thinking => |t| {
            try w.writeStringField("type", "thinking");
            try w.writeStringField("thinking", t.thinking);
            if (t.thinking_signature) |sig| {
                try w.writeStringField("thinking_signature", sig);
            }
        },
        .image => |img| {
            try w.writeStringField("type", "image");
            try w.writeStringField("data", img.data);
            try w.writeStringField("mime_type", img.mime_type);
        },
    }
    try w.endObject();
}

// --- Deserialization ---

pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !MessageOrControl {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const type_str = obj.get("type").?.string;

    if (std.mem.eql(u8, type_str, "result")) {
        return .{ .result = try parseAssistantMessage(obj, allocator) };
    }
    if (std.mem.eql(u8, type_str, "stream_error")) {
        const msg = obj.get("message").?.string;
        return .{ .stream_error = try allocator.dupe(u8, msg) };
    }

    return .{ .event = try parseAssistantMessageEvent(type_str, obj, allocator) };
}

fn parseAssistantMessageEvent(
    type_str: []const u8,
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.AssistantMessageEvent {
    // Create a minimal partial message for events
    const empty_partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    if (std.mem.eql(u8, type_str, "start")) {
        const model = try allocator.dupe(u8, obj.get("model").?.string);
        var partial = empty_partial;
        partial.model = model;
        partial.owned_strings = true;
        return .{ .start = .{ .partial = partial } };
    }
    if (std.mem.eql(u8, type_str, "text_start")) {
        return .{ .text_start = .{
            .content_index = @intCast(obj.get("content_index").?.integer),
            .partial = empty_partial,
        } };
    }
    if (std.mem.eql(u8, type_str, "text_delta")) {
        return .{ .text_delta = .{
            .content_index = @intCast(obj.get("content_index").?.integer),
            .delta = try allocator.dupe(u8, obj.get("delta").?.string),
            .partial = empty_partial,
        } };
    }
    if (std.mem.eql(u8, type_str, "text_end")) {
        return .{ .text_end = .{
            .content_index = @intCast(obj.get("content_index").?.integer),
            .content = "",
            .partial = empty_partial,
        } };
    }
    if (std.mem.eql(u8, type_str, "thinking_start")) {
        return .{ .thinking_start = .{
            .content_index = @intCast(obj.get("content_index").?.integer),
            .partial = empty_partial,
        } };
    }
    if (std.mem.eql(u8, type_str, "thinking_delta")) {
        return .{ .thinking_delta = .{
            .content_index = @intCast(obj.get("content_index").?.integer),
            .delta = try allocator.dupe(u8, obj.get("delta").?.string),
            .partial = empty_partial,
        } };
    }
    if (std.mem.eql(u8, type_str, "thinking_end")) {
        return .{ .thinking_end = .{
            .content_index = @intCast(obj.get("content_index").?.integer),
            .content = "",
            .partial = empty_partial,
        } };
    }
    if (std.mem.eql(u8, type_str, "toolcall_start")) {
        return .{ .toolcall_start = .{
            .content_index = @intCast(obj.get("content_index").?.integer),
            .partial = empty_partial,
        } };
    }
    if (std.mem.eql(u8, type_str, "toolcall_delta")) {
        return .{ .toolcall_delta = .{
            .content_index = @intCast(obj.get("content_index").?.integer),
            .delta = try allocator.dupe(u8, obj.get("delta").?.string),
            .partial = empty_partial,
        } };
    }
    if (std.mem.eql(u8, type_str, "toolcall_end")) {
        const thought_signature = if (obj.get("thought_signature")) |sig_val|
            try allocator.dupe(u8, sig_val.string)
        else
            null;
        return .{ .toolcall_end = .{
            .content_index = @intCast(obj.get("content_index").?.integer),
            .tool_call = .{
                .id = try allocator.dupe(u8, obj.get("id").?.string),
                .name = try allocator.dupe(u8, obj.get("name").?.string),
                .arguments_json = try allocator.dupe(u8, obj.get("arguments_json").?.string),
                .thought_signature = thought_signature,
            },
            .partial = empty_partial,
        } };
    }
    if (std.mem.eql(u8, type_str, "done")) {
        const message = try parseAssistantMessage(obj, allocator);
        return .{ .done = .{
            .reason = parseStopReason(obj.get("reason").?.string),
            .message = message,
        } };
    }
    if (std.mem.eql(u8, type_str, "error")) {
        var err_msg = empty_partial;
        err_msg.owned_strings = true;
        return .{ .@"error" = .{
            .reason = parseStopReason(obj.get("reason").?.string),
            .err = err_msg,
        } };
    }
    if (std.mem.eql(u8, type_str, "ping")) {
        return .{ .ping = {} };
    }

    return error.UnknownEventType;
}

fn parseAssistantMessage(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.AssistantMessage {
    const content_array = obj.get("content").?.array;
    var content = try allocator.alloc(ai_types.AssistantContent, content_array.items.len);
    errdefer allocator.free(content);

    for (content_array.items, 0..) |item, i| {
        content[i] = try parseAssistantContent(item.object, allocator);
    }

    return .{
        .content = content,
        .stop_reason = parseStopReason(obj.get("stop_reason").?.string),
        .model = try allocator.dupe(u8, obj.get("model").?.string),
        .api = try allocator.dupe(u8, obj.get("api").?.string),
        .provider = try allocator.dupe(u8, obj.get("provider").?.string),
        .timestamp = obj.get("timestamp").?.integer,
        .usage = .{
            .input = @intCast(obj.get("input").?.integer),
            .output = @intCast(obj.get("output").?.integer),
            .cache_read = @intCast(obj.get("cache_read").?.integer),
            .cache_write = @intCast(obj.get("cache_write").?.integer),
        },
        .owned_strings = true,
    };
}

fn parseAssistantContent(
    obj: std.json.ObjectMap,
    allocator: std.mem.Allocator,
) !ai_types.AssistantContent {
    const type_str = obj.get("type").?.string;

    if (std.mem.eql(u8, type_str, "text")) {
        const text_signature = if (obj.get("text_signature")) |sig_val|
            try allocator.dupe(u8, sig_val.string)
        else
            null;
        return .{ .text = .{
            .text = try allocator.dupe(u8, obj.get("text").?.string),
            .text_signature = text_signature,
        } };
    }
    if (std.mem.eql(u8, type_str, "tool_call")) {
        const thought_signature = if (obj.get("thought_signature")) |sig_val|
            try allocator.dupe(u8, sig_val.string)
        else
            null;
        return .{ .tool_call = .{
            .id = try allocator.dupe(u8, obj.get("id").?.string),
            .name = try allocator.dupe(u8, obj.get("name").?.string),
            .arguments_json = try allocator.dupe(u8, obj.get("arguments_json").?.string),
            .thought_signature = thought_signature,
        } };
    }
    if (std.mem.eql(u8, type_str, "thinking")) {
        const thinking_signature = if (obj.get("thinking_signature")) |sig_val|
            try allocator.dupe(u8, sig_val.string)
        else
            null;
        return .{ .thinking = .{
            .thinking = try allocator.dupe(u8, obj.get("thinking").?.string),
            .thinking_signature = thinking_signature,
        } };
    }
    if (std.mem.eql(u8, type_str, "image")) {
        return .{ .image = .{
            .data = try allocator.dupe(u8, obj.get("data").?.string),
            .mime_type = try allocator.dupe(u8, obj.get("mime_type").?.string),
        } };
    }

    return error.UnknownContentBlockType;
}

fn parseStopReason(str: []const u8) ai_types.StopReason {
    if (std.mem.eql(u8, str, "stop")) return .stop;
    if (std.mem.eql(u8, str, "length")) return .length;
    if (std.mem.eql(u8, str, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, str, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, str, "error")) return .@"error";
    if (std.mem.eql(u8, str, "aborted")) return .aborted;
    return .@"error";
}

// Custom error set
pub const TransportError = error{
    UnknownEventType,
    UnknownContentBlockType,
};

// --- Tests ---

test "serialize and deserialize start event" {
    const allocator = std.testing.allocator;
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "claude-3",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event = ai_types.AssistantMessageEvent{ .start = .{ .partial = partial } };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .start);
    // Clean up partial message
    var mutable_partial = msg.event.start.partial;
    mutable_partial.deinit(allocator);
}

test "serialize and deserialize text_delta event" {
    const allocator = std.testing.allocator;
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event = ai_types.AssistantMessageEvent{
        .text_delta = .{ .content_index = 2, .delta = "Hello world", .partial = partial },
    };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .text_delta);
    try std.testing.expectEqual(@as(usize, 2), msg.event.text_delta.content_index);
    try std.testing.expectEqualStrings("Hello world", msg.event.text_delta.delta);
    allocator.free(msg.event.text_delta.delta);
}

test "serialize and deserialize done event" {
    const allocator = std.testing.allocator;
    const content = [_]ai_types.AssistantContent{.{ .text = .{ .text = "result" } }};
    const message = ai_types.AssistantMessage{
        .content = &content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{
            .input = 100,
            .output = 50,
            .cache_read = 20,
            .cache_write = 10,
        },
        .stop_reason = .tool_use,
        .timestamp = 0,
        .owned_strings = false,
    };
    const event = ai_types.AssistantMessageEvent{ .done = .{
        .reason = .tool_use,
        .message = message,
    } };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .done);
    try std.testing.expectEqual(ai_types.StopReason.tool_use, msg.event.done.reason);
    try std.testing.expectEqual(@as(u64, 100), msg.event.done.message.usage.input);
    try std.testing.expectEqual(@as(u64, 50), msg.event.done.message.usage.output);
    try std.testing.expectEqual(@as(u64, 20), msg.event.done.message.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 10), msg.event.done.message.usage.cache_write);
    var mutable_msg = msg.event.done.message;
    mutable_msg.deinit(allocator);
}

test "serialize and deserialize toolcall_end event" {
    const allocator = std.testing.allocator;
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const event = ai_types.AssistantMessageEvent{ .toolcall_end = .{
        .content_index = 1,
        .tool_call = .{
            .id = "toolu_123",
            .name = "search",
            .arguments_json = "{\"q\":\"test\"}",
        },
        .partial = partial,
    } };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .toolcall_end);
    try std.testing.expectEqual(@as(usize, 1), msg.event.toolcall_end.content_index);
    try std.testing.expectEqualStrings("toolu_123", msg.event.toolcall_end.tool_call.id);
    try std.testing.expectEqualStrings("search", msg.event.toolcall_end.tool_call.name);
    allocator.free(msg.event.toolcall_end.tool_call.id);
    allocator.free(msg.event.toolcall_end.tool_call.name);
    allocator.free(msg.event.toolcall_end.tool_call.arguments_json);
}

test "serialize and deserialize ping event" {
    const allocator = std.testing.allocator;
    const event = ai_types.AssistantMessageEvent{ .ping = {} };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .ping);
}

test "serialize and deserialize error event" {
    const allocator = std.testing.allocator;
    const err_msg = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .@"error",
        .timestamp = 0,
    };
    const event = ai_types.AssistantMessageEvent{ .@"error" = .{
        .reason = .@"error",
        .err = err_msg,
    } };

    const json = try serializeEvent(event, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .event);
    try std.testing.expect(msg.event == .@"error");
    try std.testing.expectEqual(ai_types.StopReason.@"error", msg.event.@"error".reason);
}

test "serialize and deserialize result" {
    const allocator = std.testing.allocator;
    const content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "Hello world" } },
    };
    const result = ai_types.AssistantMessage{
        .content = &content,
        .usage = .{
            .input = 100,
            .output = 50,
            .cache_read = 0,
            .cache_write = 0,
        },
        .stop_reason = .stop,
        .model = "claude-3",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .timestamp = 1234567890,
        .owned_strings = false,
    };

    const json = try serializeResult(result, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .result);
    try std.testing.expectEqualStrings("claude-3", msg.result.model);
    try std.testing.expectEqual(@as(i64, 1234567890), msg.result.timestamp);
    try std.testing.expectEqual(ai_types.StopReason.stop, msg.result.stop_reason);
    try std.testing.expectEqual(@as(u64, 100), msg.result.usage.input);
    try std.testing.expectEqual(@as(usize, 1), msg.result.content.len);
    try std.testing.expect(msg.result.content[0] == .text);
    try std.testing.expectEqualStrings("Hello world", msg.result.content[0].text.text);
    var mutable_result = msg.result;
    mutable_result.deinit(allocator);
}

test "serialize and deserialize stream_error" {
    const allocator = std.testing.allocator;

    const json = try serializeError("Connection failed", allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .stream_error);
    try std.testing.expectEqualStrings("Connection failed", msg.stream_error);
    allocator.free(msg.stream_error);
}

test "serialize and deserialize result with multiple content block types" {
    const allocator = std.testing.allocator;
    const content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "Here is the result" } },
        .{ .tool_call = .{ .id = "t1", .name = "search", .arguments_json = "{}" } },
        .{ .thinking = .{ .thinking = "I should search" } },
        .{ .image = .{ .data = "iVBOR", .mime_type = "image/png" } },
    };
    const result = ai_types.AssistantMessage{
        .content = &content,
        .usage = .{ .output = 25 },
        .stop_reason = .tool_use,
        .model = "claude-3",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 999,
        .owned_strings = false,
    };

    const json = try serializeResult(result, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .result);
    try std.testing.expectEqual(@as(usize, 4), msg.result.content.len);

    try std.testing.expect(msg.result.content[0] == .text);
    try std.testing.expectEqualStrings("Here is the result", msg.result.content[0].text.text);

    try std.testing.expect(msg.result.content[1] == .tool_call);
    try std.testing.expectEqualStrings("t1", msg.result.content[1].tool_call.id);
    try std.testing.expectEqualStrings("search", msg.result.content[1].tool_call.name);

    try std.testing.expect(msg.result.content[2] == .thinking);
    try std.testing.expectEqualStrings("I should search", msg.result.content[2].thinking.thinking);

    try std.testing.expect(msg.result.content[3] == .image);
    try std.testing.expectEqualStrings("image/png", msg.result.content[3].image.mime_type);

    var mutable_result1 = msg.result;
    mutable_result1.deinit(allocator);
}

test "serialize and deserialize text block with signature" {
    const allocator = std.testing.allocator;
    const content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "hello world", .text_signature = "sig_abc123" } },
    };
    const result = ai_types.AssistantMessage{
        .content = &content,
        .usage = .{ .output = 2 },
        .stop_reason = .stop,
        .model = "test-model",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 1000,
        .owned_strings = false,
    };

    const json = try serializeResult(result, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .result);
    try std.testing.expectEqual(@as(usize, 1), msg.result.content.len);
    try std.testing.expect(msg.result.content[0] == .text);
    try std.testing.expectEqualStrings("hello world", msg.result.content[0].text.text);
    try std.testing.expect(msg.result.content[0].text.text_signature != null);
    try std.testing.expectEqualStrings("sig_abc123", msg.result.content[0].text.text_signature.?);

    var mutable_result2 = msg.result;
    mutable_result2.deinit(allocator);
}

test "serialize and deserialize thinking block with signature" {
    const allocator = std.testing.allocator;
    const content = [_]ai_types.AssistantContent{
        .{ .thinking = .{ .thinking = "Let me analyze this...", .thinking_signature = "think_sig_xyz" } },
    };
    const result = ai_types.AssistantMessage{
        .content = &content,
        .usage = .{ .output = 5 },
        .stop_reason = .stop,
        .model = "test-model",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 2000,
        .owned_strings = false,
    };

    const json = try serializeResult(result, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .result);
    try std.testing.expectEqual(@as(usize, 1), msg.result.content.len);
    try std.testing.expect(msg.result.content[0] == .thinking);
    try std.testing.expectEqualStrings("Let me analyze this...", msg.result.content[0].thinking.thinking);
    try std.testing.expect(msg.result.content[0].thinking.thinking_signature != null);
    try std.testing.expectEqualStrings("think_sig_xyz", msg.result.content[0].thinking.thinking_signature.?);

    var mutable_result3 = msg.result;
    mutable_result3.deinit(allocator);
}

test "serialize and deserialize tool_call with thought_signature" {
    const allocator = std.testing.allocator;
    const content = [_]ai_types.AssistantContent{
        .{ .tool_call = .{
            .id = "toolu_456",
            .name = "calculator",
            .arguments_json = "{\"expr\":\"2+2\"}",
            .thought_signature = "tool_thought_sig",
        } },
    };
    const result = ai_types.AssistantMessage{
        .content = &content,
        .usage = .{ .output = 10 },
        .stop_reason = .tool_use,
        .model = "test-model",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 3000,
        .owned_strings = false,
    };

    const json = try serializeResult(result, allocator);
    defer allocator.free(json);

    const msg = try deserialize(json, allocator);
    try std.testing.expect(msg == .result);
    try std.testing.expectEqual(@as(usize, 1), msg.result.content.len);
    try std.testing.expect(msg.result.content[0] == .tool_call);
    try std.testing.expectEqualStrings("toolu_456", msg.result.content[0].tool_call.id);
    try std.testing.expectEqualStrings("calculator", msg.result.content[0].tool_call.name);
    try std.testing.expectEqualStrings("{\"expr\":\"2+2\"}", msg.result.content[0].tool_call.arguments_json);
    try std.testing.expect(msg.result.content[0].tool_call.thought_signature != null);
    try std.testing.expectEqualStrings("tool_thought_sig", msg.result.content[0].tool_call.thought_signature.?);

    var mutable_result4 = msg.result;
    mutable_result4.deinit(allocator);
}

// --- Async interface tests ---

test "ByteChunk creation and deinit" {
    const allocator = std.testing.allocator;

    // Test owned chunk
    const data = try allocator.dupe(u8, "hello world");
    var chunk = ByteChunk{ .data = data, .owned = true };
    chunk.deinit(allocator);

    // Test non-owned chunk (should not free)
    const static_data = "static data";
    var chunk2 = ByteChunk{ .data = static_data, .owned = false };
    chunk2.deinit(allocator); // Should be safe
}

test "ByteStream basic operations" {
    var stream = ByteStream.init(std.testing.allocator);
    defer stream.deinit();

    const data1 = try std.testing.allocator.dupe(u8, "first");
    const data2 = try std.testing.allocator.dupe(u8, "second");

    try stream.push(.{ .data = data1, .owned = true });
    try stream.push(.{ .data = data2, .owned = true });

    const chunk1 = stream.poll();
    try std.testing.expect(chunk1 != null);
    try std.testing.expectEqualStrings("first", chunk1.?.data);
    var mutable_chunk1 = chunk1.?;
    mutable_chunk1.deinit(std.testing.allocator);

    const chunk2 = stream.poll();
    try std.testing.expect(chunk2 != null);
    try std.testing.expectEqualStrings("second", chunk2.?.data);
    var mutable_chunk2 = chunk2.?;
    mutable_chunk2.deinit(std.testing.allocator);

    stream.complete({});
}

test "AsyncReceiver mock implementation" {
    const MockAsyncReceiver = struct {
        data: []const []const u8,
        index: usize = 0,

        fn receiveStreamFn(ctx: *anyopaque, allocator: std.mem.Allocator) !*ByteStream {
            const self: *@This() = @ptrCast(@alignCast(ctx));

            const stream = try allocator.create(ByteStream);
            stream.* = ByteStream.init(allocator);

            // Push all data into the stream
            for (self.data) |item| {
                const data = try allocator.dupe(u8, item);
                try stream.push(.{ .data = data, .owned = true });
            }
            stream.complete({});

            return stream;
        }
    };

    const allocator = std.testing.allocator;

    var mock = MockAsyncReceiver{ .data = &.{ "line1", "line2", "line3" } };

    var async_receiver = AsyncReceiver{
        .context = @ptrCast(&mock),
        .receive_stream_fn = MockAsyncReceiver.receiveStreamFn,
    };

    const byte_stream = try async_receiver.receiveStream(allocator);
    defer {
        byte_stream.deinit();
        allocator.destroy(byte_stream);
    }

    // Read all chunks
    var count: usize = 0;
    while (byte_stream.wait()) |chunk| {
        defer {
            var mutable_chunk = chunk;
            mutable_chunk.deinit(allocator);
        }
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "receiveStreamFromByteStream bridge" {
    const allocator = std.testing.allocator;

    // Create a ByteStream with serialized events
    var byte_stream = ByteStream.init(allocator);
    defer byte_stream.deinit();

    // Empty partial for event construction
    const empty_partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    // Push a text_delta event
    const event_json = try serializeEvent(.{
        .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = empty_partial },
    }, allocator);
    defer allocator.free(event_json);
    try byte_stream.push(.{ .data = try allocator.dupe(u8, event_json), .owned = true });

    // Push a result
    const result_json = try serializeResult(.{
        .content = &.{},
        .usage = .{},
        .stop_reason = .stop,
        .model = "test-model",
        .api = "test-api",
        .provider = "test-provider",
        .timestamp = 0,
    }, allocator);
    defer allocator.free(result_json);
    try byte_stream.push(.{ .data = try allocator.dupe(u8, result_json), .owned = true });

    byte_stream.complete({});

    // Create the message stream
    var msg_stream = event_stream.AssistantMessageStream.init(allocator);
    defer msg_stream.deinit();

    // Bridge the streams
    receiveStreamFromByteStream(&byte_stream, &msg_stream, allocator);

    // Poll the text_delta event
    const event = msg_stream.poll();
    try std.testing.expect(event != null);
    try std.testing.expect(event.? == .text_delta);
    try std.testing.expectEqualStrings("Hello", event.?.text_delta.delta);
    allocator.free(event.?.text_delta.delta);

    // Stream should be done
    try std.testing.expect(msg_stream.isDone());
}

