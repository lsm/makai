const std = @import("std");
const ai_types = @import("ai_types");
const types = @import("oap_provider_types");
const server_mod = @import("oap_provider_server");

pub const Server = server_mod.Server;

pub fn mapStopReason(reason: ai_types.StopReason) types.StopReason {
    return switch (reason) {
        .stop => .stop,
        .length => .length,
        .tool_use => .tool_use,
        .content_filter => .content_filter,
        .@"error" => .@"error",
        .aborted => .aborted,
    };
}

pub const CompatibilityMapping = struct {
    facts: types.CompatibilityFacts,
    usage_in_streaming_undecidable: bool,
};

pub fn mapCompatibility(compat: ?ai_types.OpenAICompatOptions) CompatibilityMapping {
    const options = compat orelse return .{ .facts = .{}, .usage_in_streaming_undecidable = false };

    var facts = types.CompatibilityFacts{
        .requires_assistant_after_tool_result = options.requires_assistant_after_tool_result,
        .requires_tool_result_name = options.requires_tool_result_name,
        .requires_thinking_as_text = options.requires_thinking_as_text,
        .supports_strict_mode = options.supports_strict_mode,
        .supports_store = options.supports_store,
        .supports_developer_role = options.supports_developer_role,
        .supports_reasoning_effort = options.supports_reasoning_effort,
        .cache_ttl_control = options.supports_anthropic_cache_ttl,
    };

    if (options.max_tokens_field) |field| {
        facts.max_tokens_field = switch (field) {
            .max_tokens => .max_tokens,
            .max_completion_tokens => .max_completion_tokens,
        };
    }

    if (options.thinking_format) |format| {
        facts.thinking_format = switch (format) {
            .openai => .openai,
            .zai => .zai,
            .qwen => .qwen,
        };
    }

    if (options.requires_mistral_tool_ids) |constrained| {
        facts.tool_call_id_format = if (constrained) .constrained else .unconstrained;
    }

    var undecidable = false;
    if (options.supports_usage_in_streaming) |accepts_option| {
        if (accepts_option) {
            facts.usage_in_streaming = .always;
        } else {
            undecidable = true;
        }
    }

    return .{ .facts = facts, .usage_in_streaming_undecidable = undecidable };
}

pub fn thinkingSignature(partial: ai_types.AssistantMessage, content_index: usize) ?[]const u8 {
    if (content_index >= partial.content.len) return null;
    return switch (partial.content[content_index]) {
        .thinking => |thinking| thinking.thinking_signature,
        else => null,
    };
}

pub fn pumpEvent(
    server: *Server,
    inference_id: []const u8,
    event: ai_types.AssistantMessageEvent,
) !void {
    switch (event) {
        .start => try server.noteStarted(inference_id),
        .keepalive => {},
        .text_start => |value| try server.notePartStarted(
            inference_id,
            @intCast(value.content_index),
            .text,
            null,
            null,
        ),
        .text_delta => |value| try server.notePartDelta(
            inference_id,
            @intCast(value.content_index),
            value.delta,
        ),
        .text_end => |value| try server.notePartEndedText(
            inference_id,
            @intCast(value.content_index),
            .text,
            value.content,
        ),
        .thinking_start => |value| try server.notePartStarted(
            inference_id,
            @intCast(value.content_index),
            .reasoning,
            null,
            null,
        ),
        .thinking_delta => |value| try server.notePartDelta(
            inference_id,
            @intCast(value.content_index),
            value.delta,
        ),
        .thinking_end => |value| try server.notePartEndedTextWithCarry(
            inference_id,
            @intCast(value.content_index),
            .reasoning,
            value.content,
            thinkingSignature(value.partial, value.content_index),
        ),
        .toolcall_start => |value| try server.notePartStarted(
            inference_id,
            @intCast(value.content_index),
            .tool_call,
            value.id,
            value.name,
        ),
        .toolcall_delta => |value| try server.notePartDelta(
            inference_id,
            @intCast(value.content_index),
            value.delta,
        ),
        .toolcall_end => |value| try server.notePartEndedToolCall(
            inference_id,
            @intCast(value.content_index),
            value.tool_call.id,
            value.tool_call.name,
            value.tool_call.arguments_json,
            value.tool_call.thought_signature,
        ),
        .done => |value| try server.settleCompleted(
            inference_id,
            mapStopReason(value.reason),
            null,
        ),
        .@"error" => try server.settleFailed(
            inference_id,
            .provider_unavailable,
            "the provider stream failed",
            null,
        ),
    }
}

test "every stop reason maps without approximation" {
    try std.testing.expectEqual(types.StopReason.stop, mapStopReason(.stop));
    try std.testing.expectEqual(types.StopReason.length, mapStopReason(.length));
    try std.testing.expectEqual(types.StopReason.tool_use, mapStopReason(.tool_use));
    try std.testing.expectEqual(types.StopReason.content_filter, mapStopReason(.content_filter));
    try std.testing.expectEqual(types.StopReason.@"error", mapStopReason(.@"error"));
    try std.testing.expectEqual(types.StopReason.aborted, mapStopReason(.aborted));
}

test "eleven of twelve compatibility facts carry across unchanged" {
    const mapping = mapCompatibility(.{
        .supports_store = true,
        .supports_developer_role = false,
        .supports_reasoning_effort = true,
        .max_tokens_field = .max_completion_tokens,
        .requires_tool_result_name = true,
        .requires_assistant_after_tool_result = false,
        .requires_thinking_as_text = true,
        .requires_mistral_tool_ids = true,
        .thinking_format = .qwen,
        .supports_strict_mode = false,
        .supports_anthropic_cache_ttl = true,
    });

    try std.testing.expectEqual(true, mapping.facts.supports_store.?);
    try std.testing.expectEqual(false, mapping.facts.supports_developer_role.?);
    try std.testing.expectEqual(true, mapping.facts.supports_reasoning_effort.?);
    try std.testing.expectEqual(types.MaxTokensField.max_completion_tokens, mapping.facts.max_tokens_field.?);
    try std.testing.expectEqual(true, mapping.facts.requires_tool_result_name.?);
    try std.testing.expectEqual(false, mapping.facts.requires_assistant_after_tool_result.?);
    try std.testing.expectEqual(true, mapping.facts.requires_thinking_as_text.?);
    try std.testing.expectEqual(types.ToolCallIdFormat.constrained, mapping.facts.tool_call_id_format.?);
    try std.testing.expectEqual(types.ThinkingFormat.qwen, mapping.facts.thinking_format.?);
    try std.testing.expectEqual(false, mapping.facts.supports_strict_mode.?);
    try std.testing.expectEqual(true, mapping.facts.cache_ttl_control.?);
}

test "a false usage boolean cannot choose between never and terminal only" {
    const accepts = mapCompatibility(.{ .supports_usage_in_streaming = true });
    try std.testing.expectEqual(types.UsageInStreaming.always, accepts.facts.usage_in_streaming.?);
    try std.testing.expect(!accepts.usage_in_streaming_undecidable);

    const refuses = mapCompatibility(.{ .supports_usage_in_streaming = false });
    try std.testing.expect(refuses.facts.usage_in_streaming == null);
    try std.testing.expect(refuses.usage_in_streaming_undecidable);

    const unstated = mapCompatibility(.{});
    try std.testing.expect(unstated.facts.usage_in_streaming == null);
    try std.testing.expect(!unstated.usage_in_streaming_undecidable);
}

test "an absent compat block states no facts rather than guessing defaults" {
    const mapping = mapCompatibility(null);
    try std.testing.expect(mapping.facts.isEmpty());
    try std.testing.expect(!mapping.usage_in_streaming_undecidable);
}

const envelope = @import("oap_provider_envelope");

fn scriptedServer(allocator: std.mem.Allocator) !Server {
    var server = Server.init(allocator, .{ .accepts_inference = true });
    errdefer server.deinit();

    const provider_id = try allocator.dupe(u8, "acme");
    errdefer allocator.free(provider_id);
    const endpoint = try allocator.dupe(u8, "https://acme.test");
    errdefer allocator.free(endpoint);

    try server.addProvider(.{
        .id = provider_id,
        .wire = .@"anthropic-messages",
        .framing = .sse,
        .endpoint = endpoint,
        .allows_anonymous = true,
    });

    return server;
}

fn acceptInference(allocator: std.mem.Allocator, server: *Server) ![]const u8 {
    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"inference.create.request\",\"id\":\"q1\",\"payload\":{{\"model_ref\":\"acme/anthropic-messages@m\",\"messages\":[]}}}}",
        .{types.PROFILE},
    );
    defer allocator.free(line);
    try server.handleLine(line);

    const response_line = server.popOutbound() orelse return error.TestExpectedOutbound;
    defer allocator.free(response_line);
    var response = try envelope.deserializeEnvelope(response_line, allocator);
    defer response.deinit(allocator);
    return allocator.dupe(u8, response.inference_id.?);
}

test "a provider stream with reasoning and a tool call crosses without approximation" {
    const allocator = std.testing.allocator;
    var server = try scriptedServer(allocator);
    defer server.deinit();

    const inference_id = try acceptInference(allocator, &server);
    defer allocator.free(inference_id);

    const empty = ai_types.AssistantMessage{
        .content = &.{},
        .api = "anthropic-messages",
        .provider = "acme",
        .model = "m",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const script = [_]ai_types.AssistantMessageEvent{
        .{ .start = .{ .partial = empty } },
        .{ .thinking_start = .{ .content_index = 0, .partial = empty } },
        .{ .thinking_delta = .{ .content_index = 0, .delta = "ponder", .partial = empty } },
        .{ .thinking_end = .{ .content_index = 0, .content = "ponder", .partial = empty } },
        .keepalive,
        .{ .text_start = .{ .content_index = 1, .partial = empty } },
        .{ .text_delta = .{ .content_index = 1, .delta = "he", .partial = empty } },
        .{ .text_delta = .{ .content_index = 1, .delta = "re", .partial = empty } },
        .{ .text_end = .{ .content_index = 1, .content = "here", .partial = empty } },
        .{ .toolcall_start = .{ .content_index = 2, .id = "call_1", .name = "search", .partial = empty } },
        .{ .toolcall_delta = .{ .content_index = 2, .delta = "{\"q\":", .partial = empty } },
        .{ .toolcall_end = .{
            .content_index = 2,
            .tool_call = .{ .id = "call_1", .name = "search", .arguments_json = "{\"q\":\"zig\"}" },
            .partial = empty,
        } },
        .{ .done = .{ .reason = .tool_use, .message = empty } },
    };

    for (script) |event| try pumpEvent(&server, inference_id, event);

    var kinds_seen: [3]bool = .{ false, false, false };
    var tool_call_identity_on_start = false;
    var tool_call_complete_on_end = false;
    var expected_sequence: u64 = 1;
    var terminal: ?types.StopReason = null;

    while (server.popOutbound()) |line| {
        defer allocator.free(line);
        var env = try envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);

        try std.testing.expectEqual(expected_sequence, env.sequence.?);
        expected_sequence += 1;

        switch (env.payload) {
            .inference_part_started => |started| {
                kinds_seen[@intFromEnum(started.part_kind)] = true;
                if (started.part_kind == .tool_call) {
                    tool_call_identity_on_start =
                        std.mem.eql(u8, started.tool_call_id.?, "call_1") and
                        std.mem.eql(u8, started.name.?, "search");
                } else {
                    try std.testing.expect(started.tool_call_id == null);
                }
            },
            .inference_part_ended => |ended| {
                if (ended.part_kind == .tool_call) {
                    tool_call_complete_on_end =
                        std.mem.eql(u8, ended.tool_call.?.arguments_json, "{\"q\":\"zig\"}");
                    try std.testing.expect(ended.text == null);
                } else {
                    try std.testing.expect(ended.tool_call == null);
                }
            },
            .inference_completed => |completed| terminal = completed.stop_reason,
            else => {},
        }
    }

    try std.testing.expect(kinds_seen[0] and kinds_seen[1] and kinds_seen[2]);
    try std.testing.expect(tool_call_identity_on_start);
    try std.testing.expect(tool_call_complete_on_end);
    try std.testing.expectEqual(types.StopReason.tool_use, terminal.?);
}

test "a keepalive does not consume a sequence number" {
    const allocator = std.testing.allocator;
    var server = try scriptedServer(allocator);
    defer server.deinit();

    const inference_id = try acceptInference(allocator, &server);
    defer allocator.free(inference_id);

    try pumpEvent(&server, inference_id, .keepalive);
    try pumpEvent(&server, inference_id, .keepalive);
    try std.testing.expect(server.popOutbound() == null);
    try std.testing.expectEqual(@as(u64, 1), server.findInference(inference_id).?.next_sequence);
}

test "an opaque carry survives the round trip on both kinds that can hold one" {
    const allocator = std.testing.allocator;
    var server = try scriptedServer(allocator);
    defer server.deinit();

    const inference_id = try acceptInference(allocator, &server);
    defer allocator.free(inference_id);

    const thinking_content = [_]ai_types.AssistantContent{
        .{ .thinking = .{ .thinking = "ponder", .thinking_signature = "sig-reasoning" } },
    };
    const partial = ai_types.AssistantMessage{
        .content = &thinking_content,
        .api = "google-generative-ai",
        .provider = "google",
        .model = "m",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try pumpEvent(&server, inference_id, .{ .thinking_start = .{ .content_index = 0, .partial = partial } });
    try pumpEvent(&server, inference_id, .{ .thinking_end = .{
        .content_index = 0,
        .content = "ponder",
        .partial = partial,
    } });
    try pumpEvent(&server, inference_id, .{ .toolcall_start = .{
        .content_index = 1,
        .id = "call_1",
        .name = "search",
        .partial = partial,
    } });
    try pumpEvent(&server, inference_id, .{ .toolcall_end = .{
        .content_index = 1,
        .tool_call = .{
            .id = "call_1",
            .name = "search",
            .arguments_json = "{}",
            .thought_signature = "sig-toolcall",
        },
        .partial = partial,
    } });

    var reasoning_carry: ?[]const u8 = null;
    var tool_carry: ?[]const u8 = null;
    while (server.popOutbound()) |line| {
        defer allocator.free(line);
        var env = try envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        switch (env.payload) {
            .inference_part_ended => |ended| {
                const carry = ended.carry orelse continue;
                switch (ended.part_kind) {
                    .reasoning => reasoning_carry = try allocator.dupe(u8, carry),
                    .tool_call => tool_carry = try allocator.dupe(u8, carry),
                    .text => unreachable,
                }
            },
            else => {},
        }
    }
    defer if (reasoning_carry) |value| allocator.free(value);
    defer if (tool_carry) |value| allocator.free(value);

    try std.testing.expectEqualStrings("sig-reasoning", reasoning_carry.?);
    try std.testing.expectEqualStrings("sig-toolcall", tool_carry.?);
}

test "a text part cannot carry an opaque value at either end of the wire" {
    const allocator = std.testing.allocator;
    var server = try scriptedServer(allocator);
    defer server.deinit();

    const inference_id = try acceptInference(allocator, &server);
    defer allocator.free(inference_id);

    try server.notePartStarted(inference_id, 0, .text, null, null);
    try std.testing.expectError(
        error.CarryRefusedOnText,
        server.notePartEndedTextWithCarry(inference_id, 0, .text, "hi", "sig"),
    );

    const line =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.part.ended\",\"id\":\"m1\",\"inference_id\":\"i1\",\"sequence\":1," ++
        "\"payload\":{\"part_index\":0,\"part_kind\":\"text\",\"text\":\"hi\",\"carry\":\"sig\"}}";
    try std.testing.expectError(
        envelope.DecodeError.InvalidField,
        envelope.deserializeEnvelope(line, allocator),
    );
}
