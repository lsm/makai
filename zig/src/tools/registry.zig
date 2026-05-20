const std = @import("std");
const agent_types = @import("agent_types");
const artifact = @import("tools/artifact");
const file = @import("tools/file");
const edit = @import("tools/edit");
const shell = @import("tools/shell");
const search = @import("tools/search");
const workspace = @import("tools/workspace");

pub fn defaultTools() []const agent_types.AgentTool {
    return &[_]agent_types.AgentTool{
        shell.shellTool(),
        file.readTool(),
        file.writeTool(),
        file.statTool(),
        edit.editTool(),
        search.searchTool(),
        workspace.infoTool(),
        workspace.listTool(),
        workspace.gitStatusTool(),
        artifact.retrieveTool(),
    };
}

pub fn listToolsJson(allocator: std.mem.Allocator, tools: []const agent_types.AgentTool) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (tools, 0..) |tool, i| {
        if (i > 0) try out.append(allocator, ',');
        const formatted = try std.json.Stringify.valueAlloc(allocator, .{
            .name = tool.name,
            .label = tool.label,
            .description = tool.description,
            .short_description = tool.short_description orelse tool.description,
            .parameters_schema = tool.parameters_schema_json,
        }, .{});
        defer allocator.free(formatted);
        try out.appendSlice(allocator, formatted);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

test "default registry includes artifact_retrieve and short descriptions" {
    const tools = defaultTools();
    try std.testing.expectEqual(@as(usize, 10), tools.len);
    for (tools) |tool| {
        try std.testing.expect(tool.short_description != null);
    }
    try std.testing.expectEqualStrings("artifact_retrieve", tools[9].name);
}
