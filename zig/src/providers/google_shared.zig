const std = @import("std");
const types = @import("types");
const json_writer = @import("json_writer");

/// Google API Content structure
pub const GoogleContent = struct {
    role: []const u8,
    parts: []const GooglePart,
};

/// Google API Part structure
pub const GooglePart = union(enum) {
    text: struct { text: []const u8, thought: bool = false },
    function_call: struct { name: []const u8, args: std.json.Value, id: ?[]const u8 = null },
    function_response: struct { name: []const u8, response: std.json.Value, id: ?[]const u8 = null },
    inline_data: struct { mime_type: []const u8, data: []const u8 },
};

/// Google API FunctionDeclaration structure
pub const FunctionDeclaration = struct {
    name: []const u8,
    description: ?[]const u8,
    parameters: std.json.Value,
};

/// Convert Makai messages to Google Content format
pub fn convertMessages(
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) !std.ArrayList(GoogleContent) {
    var contents: std.ArrayList(GoogleContent) = .{};
    errdefer contents.deinit(allocator);

    for (messages) |msg| {
        // System messages are handled separately in systemInstruction
        if (msg.role == .assistant or msg.role == .user or msg.role == .tool_result) {
            const role = switch (msg.role) {
                .user => "user",
                .assistant => "model",
                .tool_result => "user", // Tool results go in user role
            };

            var parts: std.ArrayList(GooglePart) = .{};
            errdefer parts.deinit(allocator);

            // Handle tool results
            if (msg.role == .tool_result) {
                // Create function response part
                const content_text = if (msg.content.len > 0 and msg.content[0] == .text)
                    msg.content[0].text.text
                else
                    "{}";

                const response_parsed = std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    content_text,
                    .{},
                ) catch blk: {
                    const empty = std.json.ObjectMap.init(allocator);
                    break :blk std.json.Parsed(std.json.Value){
                        .arena = undefined,
                        .value = .{ .object = empty },
                    };
                };

                try parts.append(allocator, .{
                    .function_response = .{
                        .name = msg.tool_name orelse "unknown",
                        .response = response_parsed.value,
                        .id = msg.tool_call_id,
                    },
                });
            } else {
                // Regular content blocks
                for (msg.content) |block| {
                    switch (block) {
                        .text => |t| {
                            try parts.append(allocator, .{
                                .text = .{ .text = t.text, .thought = false },
                            });
                        },
                        .thinking => |th| {
                            try parts.append(allocator, .{
                                .text = .{ .text = th.thinking, .thought = true },
                            });
                        },
                        .tool_use => |tu| {
                            const args = try std.json.parseFromSlice(
                                std.json.Value,
                                allocator,
                                tu.input_json,
                                .{},
                            );

                            try parts.append(allocator, .{
                                .function_call = .{
                                    .name = tu.name,
                                    .args = args.value,
                                    .id = tu.id,
                                },
                            });
                        },
                        .image => |img| {
                            try parts.append(allocator, .{
                                .inline_data = .{
                                    .mime_type = img.media_type,
                                    .data = img.data,
                                },
                            });
                        },
                    }
                }
            }

            try contents.append(allocator, .{
                .role = role,
                .parts = try parts.toOwnedSlice(allocator),
            });
        }
    }

    return contents;
}

/// Free all nested allocations in FunctionDeclaration array
pub fn deinitFunctionDeclarations(declarations: *std.ArrayList(FunctionDeclaration), allocator: std.mem.Allocator) void {
    for (declarations.items) |decl| {
        if (decl.parameters == .object) {
            var params_obj = decl.parameters.object;
            if (params_obj.get("properties")) |props| {
                if (props == .object) {
                    var props_obj = props.object;
                    var props_iter = props_obj.iterator();
                    while (props_iter.next()) |entry| {
                        if (entry.value_ptr.* == .object) {
                            entry.value_ptr.object.deinit();
                        }
                    }
                    props_obj.deinit();
                }
            }
            if (params_obj.get("required")) |req| {
                if (req == .array) {
                    allocator.free(req.array.items);
                }
            }
            params_obj.deinit();
        }
    }
    declarations.deinit(allocator);
}

/// Convert Makai tools to Google FunctionDeclaration format
pub fn convertTools(
    tools: []const types.Tool,
    allocator: std.mem.Allocator,
) !std.ArrayList(FunctionDeclaration) {
    var declarations: std.ArrayList(FunctionDeclaration) = .{};
    errdefer deinitFunctionDeclarations(&declarations, allocator);

    for (tools) |tool| {
        // Build JSON Schema from ToolParameter array
        var params_obj = std.json.ObjectMap.init(allocator);
        errdefer params_obj.deinit();

        try params_obj.put("type", .{ .string = "object" });

        var properties = std.json.ObjectMap.init(allocator);
        errdefer {
            // Free any property objects already added before properties was put into params_obj
            var props_iter = properties.iterator();
            while (props_iter.next()) |entry| {
                if (entry.value_ptr.* == .object) {
                    entry.value_ptr.object.deinit();
                }
            }
            properties.deinit();
        }

        var required_list: std.ArrayList(std.json.Value) = .{};
        errdefer required_list.deinit(allocator);

        for (tool.parameters) |param| {
            var prop = std.json.ObjectMap.init(allocator);
            errdefer prop.deinit();

            try prop.put("type", .{ .string = param.param_type });
            if (param.description) |desc| {
                try prop.put("description", .{ .string = desc });
            }
            try properties.put(param.name, .{ .object = prop });

            if (param.required) {
                try required_list.append(allocator, .{ .string = param.name });
            }
        }

        try params_obj.put("properties", .{ .object = properties });

        // Convert unmanaged ArrayList to managed for JSON
        const slice = try required_list.toOwnedSlice(allocator);
        errdefer allocator.free(slice);

        var managed_array = std.array_list.Managed(std.json.Value).init(allocator);
        managed_array.items = slice;
        managed_array.capacity = slice.len;
        try params_obj.put("required", .{ .array = managed_array });

        try declarations.append(allocator, .{
            .name = tool.name,
            .description = tool.description,
            .parameters = .{ .object = params_obj },
        });
    }

    return declarations;
}

/// Generate a tool call ID (Google sometimes doesn't provide them)
pub fn generateToolCallId(name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    const hex_chars = "0123456789abcdef";
    var hex: [16]u8 = undefined;
    for (random_bytes, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0xF];
    }

    return try std.fmt.allocPrint(allocator, "call_{s}_{s}", .{ name[0..@min(name.len, 8)], hex[0..] });
}

/// Write Google content array to JSON
pub fn writeContents(
    writer: *json_writer.JsonWriter,
    contents: []const GoogleContent,
) !void {
    try writer.beginArray();
    for (contents) |content| {
        try writer.beginObject();
        try writer.writeStringField("role", content.role);

        try writer.writeKey("parts");
        try writer.beginArray();
        for (content.parts) |part| {
            try writer.beginObject();
            switch (part) {
                .text => |t| {
                    try writer.writeStringField("text", t.text);
                    if (t.thought) {
                        try writer.writeBoolField("thought", true);
                    }
                },
                .function_call => |fc| {
                    try writer.writeKey("functionCall");
                    try writer.beginObject();
                    try writer.writeStringField("name", fc.name);
                    try writer.writeKey("args");
                    const args_json = try std.json.Stringify.valueAlloc(writer.allocator, fc.args, .{});
                    defer writer.allocator.free(args_json);
                    try writer.buffer.appendSlice(writer.allocator, args_json);
                    writer.needs_comma = true;
                    if (fc.id) |id| {
                        try writer.writeStringField("id", id);
                    }
                    try writer.endObject();
                },
                .function_response => |fr| {
                    try writer.writeKey("functionResponse");
                    try writer.beginObject();
                    try writer.writeStringField("name", fr.name);
                    try writer.writeKey("response");
                    const resp_json = try std.json.Stringify.valueAlloc(writer.allocator, fr.response, .{});
                    defer writer.allocator.free(resp_json);
                    try writer.buffer.appendSlice(writer.allocator, resp_json);
                    writer.needs_comma = true;
                    if (fr.id) |id| {
                        try writer.writeStringField("id", id);
                    }
                    try writer.endObject();
                },
                .inline_data => |data| {
                    try writer.writeKey("inlineData");
                    try writer.beginObject();
                    try writer.writeStringField("mimeType", data.mime_type);
                    try writer.writeStringField("data", data.data);
                    try writer.endObject();
                },
            }
            try writer.endObject();
        }
        try writer.endArray();

        try writer.endObject();
    }
    try writer.endArray();
}

/// Write function declarations to JSON
pub fn writeFunctionDeclarations(
    writer: *json_writer.JsonWriter,
    declarations: []const FunctionDeclaration,
) !void {
    try writer.beginArray();
    for (declarations) |decl| {
        try writer.beginObject();
        try writer.writeStringField("name", decl.name);
        if (decl.description) |desc| {
            try writer.writeStringField("description", desc);
        }
        try writer.writeKey("parameters");
        const params_json = try std.json.Stringify.valueAlloc(writer.allocator, decl.parameters, .{});
        defer writer.allocator.free(params_json);
        try writer.buffer.appendSlice(writer.allocator, params_json);
        writer.needs_comma = true;
        try writer.endObject();
    }
    try writer.endArray();
}

// Tests
test "generateToolCallId creates valid ID" {
    const allocator = std.testing.allocator;
    const id = try generateToolCallId("search", allocator);
    defer allocator.free(id);

    try std.testing.expect(std.mem.startsWith(u8, id, "call_"));
    try std.testing.expect(id.len > 10);
}

test "convertMessages basic user message" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentBlock{
                .{ .text = .{ .text = "Hello" } },
            },
            .timestamp = 0,
        },
    };

    var contents = try convertMessages(&messages, allocator);
    defer {
        for (contents.items) |content| {
            allocator.free(content.parts);
        }
        contents.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), contents.items.len);
    try std.testing.expectEqualStrings("user", contents.items[0].role);
    try std.testing.expectEqual(@as(usize, 1), contents.items[0].parts.len);
}

test "convertMessages thinking block" {
    const allocator = std.testing.allocator;

    const messages = [_]types.Message{
        .{
            .role = .assistant,
            .content = &[_]types.ContentBlock{
                .{ .thinking = .{ .thinking = "Let me think..." } },
            },
            .timestamp = 0,
        },
    };

    var contents = try convertMessages(&messages, allocator);
    defer {
        for (contents.items) |content| {
            allocator.free(content.parts);
        }
        contents.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), contents.items.len);
    try std.testing.expectEqualStrings("model", contents.items[0].role);
    try std.testing.expectEqual(@as(usize, 1), contents.items[0].parts.len);
    try std.testing.expect(contents.items[0].parts[0] == .text);
    try std.testing.expect(contents.items[0].parts[0].text.thought);
}

test "convertTools basic tool" {
    const allocator = std.testing.allocator;

    const param = types.ToolParameter{
        .name = "query",
        .param_type = "string",
        .description = "Search query",
        .required = true,
    };

    const tool = types.Tool{
        .name = "search",
        .description = "Search the web",
        .parameters = &[_]types.ToolParameter{param},
    };

    var declarations = try convertTools(&[_]types.Tool{tool}, allocator);
    defer deinitFunctionDeclarations(&declarations, allocator);

    try std.testing.expectEqual(@as(usize, 1), declarations.items.len);
    try std.testing.expectEqualStrings("search", declarations.items[0].name);
    try std.testing.expectEqualStrings("Search the web", declarations.items[0].description.?);
}
