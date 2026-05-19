const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const OwnedSlice = @import("owned_slice").OwnedSlice;
const mock_provider = @import("tui_tests_mock_provider");

pub const expected_text = "fixture response";
pub const final_text = "tools complete";

pub const shell_args = "{\"command\":\"pwd\"}";
pub const read_args = "{\"path\":\"/workspace/README.md\"}";
pub const edit_args = "{\"path\":\"/workspace/README.md\",\"old\":\"old\",\"new\":\"new\"}";
pub const search_args = "{\"query\":\"needle\"}";
pub const error_args = "{\"error\":true}";

pub const phase1_tool_calls = [_]mock_provider.ToolCallSpec{
    .{ .id = "call-shell", .name = "shell_command", .arguments_json = shell_args },
    .{ .id = "call-read", .name = "read_file", .arguments_json = read_args },
    .{ .id = "call-edit", .name = "edit_file", .arguments_json = edit_args },
    .{ .id = "call-search", .name = "search", .arguments_json = search_args },
};

pub const approval_tool_calls = [_]mock_provider.ToolCallSpec{
    .{ .id = "call-approval", .name = "shell_command", .arguments_json = shell_args },
};

pub const error_tool_calls = [_]mock_provider.ToolCallSpec{
    .{ .id = "call-error", .name = "shell_command", .arguments_json = error_args },
};

pub const ToolFixtureState = struct {
    shell_count: usize = 0,
    read_count: usize = 0,
    edit_count: usize = 0,
    search_count: usize = 0,

    pub fn total(self: ToolFixtureState) usize {
        return self.shell_count + self.read_count + self.edit_count + self.search_count;
    }
};

var active_state: ?*ToolFixtureState = null;

pub fn setActiveState(state: *ToolFixtureState) void {
    active_state = state;
}

fn currentState() *ToolFixtureState {
    return active_state.?;
}

fn resultText(allocator: std.mem.Allocator, text: []const u8, details_json: []const u8) !agent.AgentToolResult {
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    errdefer content[0].deinit(allocator);

    return .{
        .content = OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, details_json)),
    };
}

fn maybeFail(args_json: []const u8) !void {
    if (std.mem.indexOf(u8, args_json, "\"error\":true") != null) return error.FixtureToolFailed;
}

fn shellCommand(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent.AgentToolResult {
    _ = cancel_token;
    const state = currentState();
    state.shell_count += 1;
    if (on_update) |update| update(on_update_ctx, tool_call_id, "shell_command", "{\"phase\":\"shell\"}");
    try maybeFail(args_json);
    return resultText(allocator, "shell: /workspace", "{\"tool\":\"shell_command\",\"ok\":true}");
}

fn readFile(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent.AgentToolResult {
    _ = cancel_token;
    const state = currentState();
    state.read_count += 1;
    if (on_update) |update| update(on_update_ctx, tool_call_id, "read_file", "{\"phase\":\"read\"}");
    try maybeFail(args_json);
    return resultText(allocator, "read: old", "{\"tool\":\"read_file\",\"ok\":true}");
}

fn editFile(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent.AgentToolResult {
    _ = cancel_token;
    const state = currentState();
    state.edit_count += 1;
    if (on_update) |update| update(on_update_ctx, tool_call_id, "edit_file", "{\"phase\":\"edit\"}");
    try maybeFail(args_json);
    return resultText(allocator, "edit: replaced", "{\"tool\":\"edit_file\",\"ok\":true}");
}

fn search(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent.AgentToolResult {
    _ = cancel_token;
    const state = currentState();
    state.search_count += 1;
    if (on_update) |update| update(on_update_ctx, tool_call_id, "search", "{\"phase\":\"search\"}");
    try maybeFail(args_json);
    return resultText(allocator, "search: needle at README.md:1", "{\"tool\":\"search\",\"ok\":true}");
}

pub fn tools(state: *ToolFixtureState) [4]agent.AgentTool {
    return .{
        .{
            .label = "Shell Command",
            .name = "shell_command",
            .description = "Run deterministic shell fixture",
            .parameters_schema_json = "{}",
            .execute = shellCommand,
            .approval_ctx = state,
            .approval_ui_ctx = state,
        },
        .{
            .label = "Read File",
            .name = "read_file",
            .description = "Read deterministic file fixture",
            .parameters_schema_json = "{}",
            .execute = readFile,
            .approval_ctx = state,
            .approval_ui_ctx = state,
        },
        .{
            .label = "Edit File",
            .name = "edit_file",
            .description = "Edit deterministic file fixture",
            .parameters_schema_json = "{}",
            .execute = editFile,
            .approval_ctx = state,
            .approval_ui_ctx = state,
        },
        .{
            .label = "Search",
            .name = "search",
            .description = "Search deterministic fixture",
            .parameters_schema_json = "{}",
            .execute = search,
            .approval_ctx = state,
            .approval_ui_ctx = state,
        },
    };
}

test "fixture tools expose expected names" {
    var state = ToolFixtureState{};
    const fixture_tools = tools(&state);
    try std.testing.expectEqualStrings("shell_command", fixture_tools[0].name);
    try std.testing.expectEqualStrings("read_file", fixture_tools[1].name);
    try std.testing.expectEqualStrings("edit_file", fixture_tools[2].name);
    try std.testing.expectEqualStrings("search", fixture_tools[3].name);
}
