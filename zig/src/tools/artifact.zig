const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const common = @import("tools/common");

pub const retrieve_tool = agent.AgentTool{
    .label = "Artifact Retrieve",
    .name = "artifact_retrieve",
    .description = "Retrieve full tool output previously stored as a local artifact. Use when a tool result summary references an artifact path and complete output is needed.",
    .short_description = "Retrieve stored full tool output by artifact path.",
    .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"reference\":{\"type\":\"string\"}},\"required\":[\"reference\"],\"additionalProperties\":false}",
    .execute = executeRetrieve,
};

pub fn executeRetrieve(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent.AgentToolResult {
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
    try std.testing.expectError(error.InvalidArtifactReference, common.retrieveArtifact(allocator, "../build.zig", 1024));
    try std.testing.expectError(error.InvalidArtifactReference, common.retrieveArtifact(allocator, "/tmp/not-an-artifact", 1024));
}
