const std = @import("std");
const ai_types = @import("ai_types");
const agent_types = @import("agent_types");
const common = @import("tools/common");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub fn retrieveTool() agent_types.AgentTool {
    return .{
        .label = "Artifact Retrieve",
        .name = "artifact_retrieve",
        .description = "Retrieve full tool output previously stored as a local artifact. Use when a tool result summary references an artifact path and complete output is needed.",
        .short_description = "Retrieve stored full tool output by artifact path.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"reference\":{\"type\":\"string\"}},\"required\":[\"reference\"]}",
        .execute = executeRetrieve,
    };
}

pub fn executeRetrieve(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent_types.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent_types.AgentToolResult {
    _ = tool_call_id;
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const reference_value = parsed.value.object.get("reference") orelse return error.InvalidArguments;
    if (reference_value != .string) return error.InvalidArguments;

    const data = try common.retrieveArtifact(allocator, reference_value.string, 64 * 1024 * 1024);
    defer allocator.free(data);
    const details = try common.telemetryDetails(allocator, data.len, data.len, false);
    defer allocator.free(details);
    return common.makeTextResult(allocator, data, details);
}

test "artifact_retrieve loads stored output" {
    const allocator = std.testing.allocator;
    const path = try common.storeArtifact(allocator, "artifact-test", "full output");
    defer allocator.free(path);
    const args = try std.fmt.allocPrint(allocator, "{{\"reference\":\"{s}\"}}", .{path});
    defer allocator.free(args);
    var result = try executeRetrieve("call", args, null, null, null, allocator);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("full output", result.content.slice()[0].text.text);
}
