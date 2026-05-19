const std = @import("std");
const agent = @import("agent");
const shell = @import("tools/shell");
const file = @import("tools/file");
const edit = @import("tools/edit");
const search = @import("tools/search");
const workspace = @import("tools/workspace");

pub const ToolRegistry = struct {
    tools: std.ArrayList(agent.AgentTool) = .empty,

    pub fn init() ToolRegistry {
        return .{};
    }

    pub fn deinit(self: *ToolRegistry, allocator: std.mem.Allocator) void {
        self.tools.deinit(allocator);
        self.* = undefined;
    }

    pub fn register(self: *ToolRegistry, allocator: std.mem.Allocator, tool: agent.AgentTool) !void {
        if (self.resolve(tool.name) != null) return error.DuplicateTool;
        try self.tools.append(allocator, tool);
    }

    pub fn registerDefaults(self: *ToolRegistry, allocator: std.mem.Allocator) !void {
        for (defaultTools()) |tool| try self.register(allocator, tool);
    }

    pub fn resolve(self: *const ToolRegistry, name: []const u8) ?agent.AgentTool {
        for (self.tools.items) |tool| if (std.mem.eql(u8, tool.name, name)) return tool;
        return null;
    }

    pub fn list(self: *const ToolRegistry) []const agent.AgentTool {
        return self.tools.items;
    }
};

pub fn defaultTools() []const agent.AgentTool {
    return &.{
        shell.execute_tool,
        file.read_tool,
        file.write_tool,
        file.stat_tool,
        edit.apply_tool,
        search.regex_tool,
        workspace.info_tool,
        workspace.list_tool,
        workspace.git_status_tool,
    };
}

test "registry registers resolves and lists defaults" {
    var registry = ToolRegistry.init();
    defer registry.deinit(std.testing.allocator);
    try registry.registerDefaults(std.testing.allocator);
    try std.testing.expect(registry.resolve("shell_execute") != null);
    try std.testing.expect(registry.resolve("file_read") != null);
    try std.testing.expectEqual(@as(usize, 9), registry.list().len);
    try std.testing.expectError(error.DuplicateTool, registry.register(std.testing.allocator, shell.execute_tool));
}
