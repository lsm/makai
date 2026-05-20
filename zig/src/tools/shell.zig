const std = @import("std");
const ai_types = @import("ai_types");
const agent_types = @import("agent_types");
const common = @import("tools/common");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub fn shellTool() agent_types.AgentTool {
    return .{
        .label = "Shell Execute",
        .name = "shell_execute",
        .description = "Execute a shell command and return stdout/stderr. Large stdout is stored as retrievable artifact; compact_output returns terse success metadata.",
        .short_description = "Run shell command; large output becomes artifact.",
        .parameters_schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"compact_output\":{\"type\":\"boolean\"}},\"required\":[\"command\"]}",
        .execute = executeShell,
    };
}

pub fn executeShell(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent_types.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent_types.AgentToolResult {
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;
    const parsed = try parseArgs(allocator, args_json);
    defer parsed.deinit();
    const output = try std.process.run(allocator, defaultIo(), .{
        .argv = &.{ "/bin/sh", "-c", parsed.command },
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    defer allocator.free(output.stdout);
    defer allocator.free(output.stderr);
    const code: u8 = switch (output.term) { .exited => |c| c, else => 1 };
    const raw_bytes = output.stdout.len + output.stderr.len;

    if (parsed.compact_output and code == 0) {
        const body = try std.fmt.allocPrint(allocator, "ok stdout={d} stderr={d}", .{ output.stdout.len, output.stderr.len });
        defer allocator.free(body);
        const details = try common.telemetryDetails(allocator, raw_bytes, body.len, false);
        defer allocator.free(details);
        return common.makeTextResult(allocator, body, details);
    }

    const body = if (code == 0)
        try allocator.dupe(u8, output.stdout)
    else
        try std.fmt.allocPrint(allocator, "exit_code: {d}\nstderr:\n{s}\nstdout:\n{s}", .{ code, output.stderr, output.stdout });
    defer allocator.free(body);
    const details = try std.fmt.allocPrint(allocator, "{{\"exit_code\":{d}}}", .{code});
    defer allocator.free(details);
    const made = try common.makeTextResultWithArtifact(allocator, .{ .tool_name = "shell_execute", .call_id = tool_call_id, .text = body, .stderr = if (code == 0) output.stderr else "", .details_json = details });
    defer if (made.artifact_path) |path| allocator.free(path);
    return made.result;
}

const ParsedArgs = struct {
    parsed: std.json.Parsed(std.json.Value),
    command: []const u8,
    compact_output: bool = false,

    fn deinit(self: *const ParsedArgs) void {
        self.parsed.deinit();
    }
};

fn parseArgs(allocator: std.mem.Allocator, args_json: []const u8) !ParsedArgs {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const obj = parsed.value.object;
    const command = obj.get("command") orelse return error.InvalidArguments;
    if (command != .string) return error.InvalidArguments;
    const compact = if (obj.get("compact_output")) |value| value == .bool and value.bool else false;
    return .{ .parsed = parsed, .command = command.string, .compact_output = compact };
}

test "shell compact success format" {
    const allocator = std.testing.allocator;
    const body = try std.fmt.allocPrint(allocator, "ok stdout={d} stderr={d}", .{ 3, 0 });
    defer allocator.free(body);
    try std.testing.expectEqualStrings("ok stdout=3 stderr=0", body);
}
