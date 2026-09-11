const std = @import("std");
const ai_types = @import("ai_types");
const json_writer = @import("json_writer");
const content_partial = @import("content_partial");

pub const SerializationOptions = struct {
    include_partial: bool = false,
    use_lightweight_partial: bool = true,
};

pub const PartialState = struct {
    allocator: std.mem.Allocator,

    blocks: std.AutoHashMap(usize, content_partial.ContentBlockPartial),

    usage: ai_types.Usage,

    model: []const u8 = "",
    api: []const u8 = "",
    provider: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) PartialState {
        return .{
            .allocator = allocator,
            .blocks = std.AutoHashMap(usize, content_partial.ContentBlockPartial).init(allocator),
            .usage = .{},
        };
    }

    pub fn deinit(self: *PartialState) void {
        var iter = self.blocks.iterator();
        while (iter.next()) |entry| {
            var partial = entry.value_ptr.*;
            partial.deinit(self.allocator);
        }
        self.blocks.deinit();
    }

    pub fn processEvent(self: *PartialState, event: ai_types.AssistantMessageEvent) !void {
        switch (event) {
            .start => |s| {
                self.model = s.partial.model;
                self.api = s.partial.api;
                self.provider = s.partial.provider;
            },
            .text_start => |e| {
                try self.blocks.put(e.content_index, .{ .text = .{} });
            },
            .text_delta => |d| {
                const entry = try self.blocks.getOrPut(d.content_index);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{ .text = .{} };
                }
                switch (entry.value_ptr.*) {
                    .text => |*t| {
                        t.accumulated_len += d.delta.len;
                    },
                    else => {
                        entry.value_ptr.* = .{ .text = .{ .accumulated_len = d.delta.len } };
                    },
                }
            },
            .thinking_start => |e| {
                try self.blocks.put(e.content_index, .{ .thinking = .{} });
            },
            .thinking_delta => |d| {
                const entry = try self.blocks.getOrPut(d.content_index);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{ .thinking = .{} };
                }
                switch (entry.value_ptr.*) {
                    .thinking => |*t| {
                        t.accumulated_len += d.delta.len;
                    },
                    else => {
                        entry.value_ptr.* = .{ .thinking = .{ .accumulated_len = d.delta.len } };
                    },
                }
            },
            .toolcall_start => |e| {
                try self.blocks.put(e.content_index, .{ .tool_call = .{} });
            },
            .toolcall_delta => |d| {
                const entry = try self.blocks.getOrPut(d.content_index);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{ .tool_call = .{} };
                }
                switch (entry.value_ptr.*) {
                    .tool_call => |*tc| {
                        tc.json_len += d.delta.len;
                    },
                    else => {
                        entry.value_ptr.* = .{ .tool_call = .{ .json_len = d.delta.len } };
                    },
                }
            },
            .toolcall_end => |e| {
                const id = try self.allocator.dupe(u8, e.tool_call.id);
                const name = try self.allocator.dupe(u8, e.tool_call.name);
                try self.blocks.put(e.content_index, .{
                    .tool_call = .{
                        .id = content_partial.OwnedSlice(u8).initOwned(id),
                        .name = content_partial.OwnedSlice(u8).initOwned(name),
                        .json_len = e.tool_call.arguments_json.len,
                    },
                });
            },
            .done => |d| {
                self.usage = d.message.usage;
            },
            .text_end, .thinking_end, .@"error", .keepalive => {},
        }
    }

    pub fn getBlockPartial(self: *PartialState, content_index: usize) ?content_partial.ContentBlockPartial {
        return self.blocks.get(content_index);
    }
};

pub fn serializeEvent(
    event: ai_types.AssistantMessageEvent,
    partial_state: ?*PartialState,
    options: SerializationOptions,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
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

            if (options.include_partial and options.use_lightweight_partial) {
                if (partial_state) |state| {
                    if (state.getBlockPartial(d.content_index)) |block_partial| {
                        try serializeBlockPartial(&w, d.content_index, block_partial);
                    }
                }
            }
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

            if (options.include_partial and options.use_lightweight_partial) {
                if (partial_state) |state| {
                    if (state.getBlockPartial(d.content_index)) |block_partial| {
                        try serializeBlockPartial(&w, d.content_index, block_partial);
                    }
                }
            }
        },
        .thinking_end => |e| {
            try w.writeStringField("type", "thinking_end");
            try w.writeIntField("content_index", e.content_index);
        },
        .toolcall_start => |e| {
            try w.writeStringField("type", "toolcall_start");
            try w.writeIntField("content_index", e.content_index);
            try w.writeStringField("id", e.id);
            try w.writeStringField("name", e.name);
        },
        .toolcall_delta => |d| {
            try w.writeStringField("type", "toolcall_delta");
            try w.writeIntField("content_index", d.content_index);
            try w.writeStringField("delta", d.delta);

            if (options.include_partial and options.use_lightweight_partial) {
                if (partial_state) |state| {
                    if (state.getBlockPartial(d.content_index)) |block_partial| {
                        try serializeBlockPartial(&w, d.content_index, block_partial);
                    }
                }
            }
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
            try w.writeStringField("stop_reason", @tagName(d.message.stop_reason));
            try w.writeStringField("model", d.message.model);
            try w.writeStringField("api", d.message.api);
            try w.writeStringField("provider", d.message.provider);
            try w.writeIntField("timestamp", d.message.timestamp);
            try w.writeIntField("input", d.message.usage.input);
            try w.writeIntField("output", d.message.usage.output);
            try w.writeIntField("cache_read", d.message.usage.cache_read);
            try w.writeIntField("cache_write", d.message.usage.cache_write);

            try w.writeKey("content");
            try w.beginArray();
            for (d.message.content) |block| {
                try serializeAssistantContent(&w, block);
            }
            try w.endArray();
        },
        .@"error" => |e| {
            try w.writeStringField("type", "error");
            try w.writeStringField("reason", @tagName(e.reason));
        },
        .keepalive => {
            try w.writeStringField("type", "keepalive");
        },
    }

    try w.endObject();

    const result = try allocator.dupe(u8, buffer.items);
    buffer.deinit(allocator);
    return result;
}

pub fn serializeEventForEnvelope(
    event: ai_types.AssistantMessageEvent,
    partial_state: ?*PartialState,
    options: SerializationOptions,
    allocator: std.mem.Allocator,
) ![]u8 {
    return try serializeEvent(event, partial_state, options, allocator);
}

fn serializeBlockPartial(w: *json_writer.JsonWriter, content_index: usize, partial: content_partial.ContentBlockPartial) !void {
    try w.writeKey("partial");
    try w.beginObject();

    switch (partial) {
        .text => |t| {
            try w.writeKey("text");
            try w.beginObject();
            try w.writeIntField("accumulated_len", t.accumulated_len);
            try w.endObject();
        },
        .thinking => |t| {
            try w.writeKey("thinking");
            try w.beginObject();
            try w.writeIntField("accumulated_len", t.accumulated_len);
            try w.endObject();
        },
        .tool_call => |tc| {
            try w.writeKey("tool_call");
            try w.beginObject();
            if (tc.getId()) |id| {
                try w.writeStringField("id", id);
            }
            if (tc.getName()) |name| {
                try w.writeStringField("name", name);
            }
            try w.writeIntField("json_len", tc.json_len);
            try w.endObject();
        },
        .inactive => {
            try w.endObject();
            return;
        },
    }

    try w.writeIntField("content_index", content_index);
    try w.endObject();
}

fn serializeAssistantContent(w: *json_writer.JsonWriter, block: ai_types.AssistantContent) !void {
    try w.beginObject();

    switch (block) {
        .text => |t| {
            try w.writeStringField("type", "text");
            try w.writeStringField("text", t.text);
        },
        .thinking => |t| {
            try w.writeStringField("type", "thinking");
            try w.writeStringField("thinking", t.thinking);
        },
        .tool_call => |tc| {
            try w.writeStringField("type", "tool_call");
            try w.writeStringField("id", tc.id);
            try w.writeStringField("name", tc.name);
            try w.writeStringField("arguments_json", tc.arguments_json);
        },
        .image => |img| {
            try w.writeStringField("type", "image");
            try w.writeStringField("data", img.data);
            try w.writeStringField("mime_type", img.mime_type);
        },
    }

    try w.endObject();
}

test "PartialState init and deinit" {
    var state = PartialState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(state.blocks.count() == 0);
    try std.testing.expect(state.usage.input == 0);
    try std.testing.expect(state.usage.output == 0);
}

test "processEvent tracks text accumulation" {
    var state = PartialState.init(std.testing.allocator);
    defer state.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const start_event: ai_types.AssistantMessageEvent = .{ .start = .{ .partial = partial } };
    try state.processEvent(start_event);

    const text_start_event: ai_types.AssistantMessageEvent = .{ .text_start = .{ .content_index = 0, .partial = partial } };
    try state.processEvent(text_start_event);

    const delta1_event: ai_types.AssistantMessageEvent = .{ .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = partial } };
    try state.processEvent(delta1_event);

    const block = state.getBlockPartial(0);
    try std.testing.expect(block != null);
    if (block) |b| {
        try std.testing.expectEqual(@as(@TypeOf(b), .{ .text = .{ .accumulated_len = 5 } }), b);
    }

    const delta2_event: ai_types.AssistantMessageEvent = .{ .text_delta = .{ .content_index = 0, .delta = " World", .partial = partial } };
    try state.processEvent(delta2_event);

    const block2 = state.getBlockPartial(0);
    try std.testing.expect(block2 != null);
    if (block2) |b| {
        try std.testing.expectEqual(@as(usize, 11), b.text.accumulated_len);
    }
}

test "processEvent tracks tool call accumulation" {
    var state = PartialState.init(std.testing.allocator);
    defer state.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const tc_start_event: ai_types.AssistantMessageEvent = .{ .toolcall_start = .{ .content_index = 0, .id = "tool-123", .name = "bash", .partial = partial } };
    try state.processEvent(tc_start_event);

    const delta1_event: ai_types.AssistantMessageEvent = .{ .toolcall_delta = .{ .content_index = 0, .delta = "{\"cmd\":", .partial = partial } };
    try state.processEvent(delta1_event);

    const block = state.getBlockPartial(0);
    try std.testing.expect(block != null);
    if (block) |b| {
        try std.testing.expectEqual(@as(usize, 7), b.tool_call.json_len);
    }

    const tc_end_event: ai_types.AssistantMessageEvent = .{ .toolcall_end = .{
        .content_index = 0,
        .tool_call = .{
            .id = "tool-123",
            .name = "bash",
            .arguments_json = "{\"cmd\": \"ls\"}",
        },
        .partial = partial,
    } };
    try state.processEvent(tc_end_event);

    const block2 = state.getBlockPartial(0);
    try std.testing.expect(block2 != null);
    if (block2) |b| {
        try std.testing.expectEqualStrings("tool-123", b.tool_call.getId().?);
        try std.testing.expectEqualStrings("bash", b.tool_call.getName().?);
        try std.testing.expectEqual(@as(usize, 13), b.tool_call.json_len);
    }
}

test "serializeEvent without partial omits partial field" {
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event: ai_types.AssistantMessageEvent = .{ .text_delta = .{
        .content_index = 0,
        .delta = "Hello",
        .partial = partial,
    } };

    const options = SerializationOptions{
        .include_partial = false,
        .use_lightweight_partial = true,
    };

    const json = try serializeEvent(event, null, options, std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"partial\"") == null);

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"text_delta\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"content_index\":0") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"delta\":\"Hello\"") != null);
}

test "serializeEvent with lightweight partial includes block partial" {
    var state = PartialState.init(std.testing.allocator);
    defer state.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const start_event: ai_types.AssistantMessageEvent = .{ .start = .{ .partial = partial } };
    try state.processEvent(start_event);

    const text_start_event: ai_types.AssistantMessageEvent = .{ .text_start = .{ .content_index = 0, .partial = partial } };
    try state.processEvent(text_start_event);

    const delta1_event: ai_types.AssistantMessageEvent = .{ .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = partial } };
    try state.processEvent(delta1_event);

    const delta2_event: ai_types.AssistantMessageEvent = .{ .text_delta = .{ .content_index = 0, .delta = " World", .partial = partial } };
    try state.processEvent(delta2_event);

    const options = SerializationOptions{
        .include_partial = true,
        .use_lightweight_partial = true,
    };

    const json = try serializeEvent(delta2_event, &state, options, std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"partial\"") != null);

    try std.testing.expect(std.mem.find(u8, json, "\"accumulated_len\":11") != null);

    try std.testing.expect(std.mem.find(u8, json, "\"text\":") != null);
}

test "serializeEvent produces valid JSON" {
    var state = PartialState.init(std.testing.allocator);
    defer state.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const events = [_]ai_types.AssistantMessageEvent{
        .{ .start = .{ .partial = partial } },
        .{ .text_start = .{ .content_index = 0, .partial = partial } },
        .{ .text_delta = .{ .content_index = 0, .delta = "test", .partial = partial } },
        .{ .text_end = .{ .content_index = 0, .content = "test", .partial = partial } },
        .{ .keepalive = {} },
    };

    const options = SerializationOptions{};

    for (events) |event| {
        const json = try serializeEvent(event, null, options, std.testing.allocator);
        defer std.testing.allocator.free(json);

        try std.testing.expect(json[0] == '{');
        try std.testing.expect(json[json.len - 1] == '}');

        try std.testing.expect(std.mem.find(u8, json, "\"type\"") != null);
    }
}

test "serializeEvent for thinking_delta includes partial" {
    var state = PartialState.init(std.testing.allocator);
    defer state.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const thinking_start_event: ai_types.AssistantMessageEvent = .{ .thinking_start = .{ .content_index = 0, .partial = partial } };
    try state.processEvent(thinking_start_event);

    const delta_event: ai_types.AssistantMessageEvent = .{ .thinking_delta = .{ .content_index = 0, .delta = "thinking...", .partial = partial } };
    try state.processEvent(delta_event);

    const block = state.getBlockPartial(0);
    try std.testing.expect(block != null);
    if (block) |b| {
        try std.testing.expectEqual(@as(usize, 11), b.thinking.accumulated_len);
    }

    const options = SerializationOptions{
        .include_partial = true,
        .use_lightweight_partial = true,
    };

    const json = try serializeEvent(delta_event, &state, options, std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"thinking\":") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"accumulated_len\":11") != null);
}

test "serializeEvent for toolcall_delta includes partial" {
    var state = PartialState.init(std.testing.allocator);
    defer state.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const tc_start_event: ai_types.AssistantMessageEvent = .{ .toolcall_start = .{ .content_index = 0, .id = "tool-123", .name = "bash", .partial = partial } };
    try state.processEvent(tc_start_event);

    const delta_event: ai_types.AssistantMessageEvent = .{ .toolcall_delta = .{ .content_index = 0, .delta = "{\"cmd\":", .partial = partial } };
    try state.processEvent(delta_event);

    const options = SerializationOptions{
        .include_partial = true,
        .use_lightweight_partial = true,
    };

    const json = try serializeEvent(delta_event, &state, options, std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.find(u8, json, "\"tool_call\":") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"json_len\":7") != null);
}

test "processEvent handles multiple blocks" {
    var state = PartialState.init(std.testing.allocator);
    defer state.deinit();

    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const text_start: ai_types.AssistantMessageEvent = .{ .text_start = .{ .content_index = 0, .partial = partial } };
    try state.processEvent(text_start);

    const text_delta: ai_types.AssistantMessageEvent = .{ .text_delta = .{ .content_index = 0, .delta = "Hello", .partial = partial } };
    try state.processEvent(text_delta);

    const tc_start: ai_types.AssistantMessageEvent = .{ .toolcall_start = .{ .content_index = 1, .id = "tool-456", .name = "search", .partial = partial } };
    try state.processEvent(tc_start);

    const tc_delta: ai_types.AssistantMessageEvent = .{ .toolcall_delta = .{ .content_index = 1, .delta = "{}", .partial = partial } };
    try state.processEvent(tc_delta);

    try std.testing.expect(state.blocks.count() == 2);

    const block0 = state.getBlockPartial(0);
    try std.testing.expect(block0 != null);
    if (block0) |b| {
        try std.testing.expectEqual(@as(usize, 5), b.text.accumulated_len);
    }

    const block1 = state.getBlockPartial(1);
    try std.testing.expect(block1 != null);
    if (block1) |b| {
        try std.testing.expectEqual(@as(usize, 2), b.tool_call.json_len);
    }
}

test "SerializationOptions defaults" {
    const opts = SerializationOptions{};

    try std.testing.expect(opts.include_partial == false);
    try std.testing.expect(opts.use_lightweight_partial == true);
}

test "serializeEventForEnvelope produces valid output" {
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    const event: ai_types.AssistantMessageEvent = .{ .text_delta = .{
        .content_index = 0,
        .delta = "test",
        .partial = partial,
    } };

    const options = SerializationOptions{};

    const json = try serializeEventForEnvelope(event, null, options, std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(json[0] == '{');
    try std.testing.expect(json[json.len - 1] == '}');
}
