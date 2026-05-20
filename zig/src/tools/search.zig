const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const common = @import("tools/common");

pub const schema_text =
    \\{"type":"object","properties":{"workspace_root":{"type":"string"},"query":{"type":"string"},"glob":{"type":"string"},"max_results":{"type":"integer","minimum":0}},"required":["workspace_root","query"],"additionalProperties":false}
;

pub const text_tool = agent.AgentTool{ .label = "Text Search", .name = "search_text", .description = "Search workspace text files using literal text plus '.' wildcard and '.*' gaps, optional glob substring filter, and return file:line:content results. Large result sets are stored as artifacts.", .short_description = "Search text; large results become artifact.", .parameters_schema_json = schema_text, .execute = textExecute };
pub const regex_tool = text_tool;

const Match = struct { path: []u8, line: usize, content: []u8 };

pub fn textExecute(tool_call_id: []const u8, args_json: []const u8, cancel_token: ?ai_types.CancelToken, on_update_ctx: ?*anyopaque, on_update: ?agent.ToolUpdateCallback, allocator: std.mem.Allocator) anyerror!agent.AgentToolResult {
    _ = on_update_ctx;
    _ = on_update;
    if (common.isCancelled(cancel_token)) return error.Cancelled;
    const start_ms = common.nowMs();
    var parsed = try common.parseArgs(allocator, args_json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const workspace_root = try common.requiredString(obj, "workspace_root");
    const query = try common.requiredString(obj, "query");
    const glob = common.optionalString(obj, "glob");
    const max = @min(common.optionalUsize(obj, "max_results", 50), common.max_results);
    var root = try common.openWorkspace(workspace_root, true);
    defer root.close(common.defaultIo());
    var walker = try root.walk(allocator);
    defer walker.deinit();

    var matches = std.ArrayList(Match).empty;
    var scanned_files: usize = 0;
    var skipped_oversized_files: usize = 0;
    var skipped_read_error_files: usize = 0;
    defer {
        for (matches.items) |m| {
            allocator.free(m.path);
            allocator.free(m.content);
        }
        matches.deinit(allocator);
    }

    while (try walker.next(common.defaultIo())) |entry| {
        if (common.isCancelled(cancel_token)) return error.Cancelled;
        if (matches.items.len >= max) break;
        if (entry.kind != .file) continue;
        if (glob) |g| if (!globMatches(g, entry.path)) continue;
        scanned_files += 1;
        const st = root.statFile(common.defaultIo(), entry.path, .{ .follow_symlinks = false }) catch {
            skipped_read_error_files += 1;
            continue;
        };
        if (st.size >= 1024 * 1024) {
            skipped_oversized_files += 1;
            continue;
        }
        const data = root.readFileAlloc(common.defaultIo(), entry.path, allocator, .limited(1024 * 1024)) catch {
            skipped_read_error_files += 1;
            continue;
        };
        defer allocator.free(data);
        if (common.isBinary(data)) continue;
        var line_no: usize = 1;
        var line_it = std.mem.splitScalar(u8, data, '\n');
        while (line_it.next()) |line| {
            if (common.isCancelled(cancel_token)) return error.Cancelled;
            if (textLikeMatch(query, line)) {
                try matches.append(allocator, .{ .path = try allocator.dupe(u8, entry.path), .line = line_no, .content = try allocator.dupe(u8, line) });
                if (matches.items.len >= max) break;
            }
            line_no += 1;
        }
    }

    std.mem.sort(Match, matches.items, {}, lessMatch);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (matches.items) |m| {
        const line = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}\n", .{ m.path, m.line, m.content });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    const text = try out.toOwnedSlice(allocator);
    defer allocator.free(text);
    const details = try common.jsonString(allocator, .{ .ok = true, .query = query, .duration_ms = common.durationMs(start_ms), .raw_bytes = text.len, .returned_bytes = text.len, .match_count = matches.items.len, .scanned_files = scanned_files, .skipped_oversized_files = skipped_oversized_files, .skipped_read_error_files = skipped_read_error_files });
    defer allocator.free(details);
    const made = try common.makeTextResultWithArtifact(allocator, .{ .tool_name = "search_text", .call_id = tool_call_id, .text = text, .details_json = details });
    defer if (made.artifact_path) |path| allocator.free(path);
    return made.result;
}

fn lessMatch(_: void, a: Match, b: Match) bool {
    const order = std.mem.order(u8, a.path, b.path);
    if (order != .eq) return order == .lt;
    return a.line < b.line;
}

fn textLikeMatch(pattern: []const u8, text: []const u8) bool {
    // Minimal text search surface for local TUI search bootstrap: literal substring,
    // `.` wildcard, and `.*` gaps. Full indexing belongs later.
    var start: usize = 0;
    while (start <= text.len) : (start += 1) {
        if (matchFromIterative(pattern, text[start..])) return true;
        if (start == text.len) break;
    }
    return false;
}

fn matchFromIterative(pattern: []const u8, text: []const u8) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_pattern_index: ?usize = null;
    var star_text_index: usize = 0;

    while (text_index < text.len) {
        if (pattern_index == pattern.len) return true;
        if (pattern_index + 1 < pattern.len and pattern[pattern_index] == '.' and pattern[pattern_index + 1] == '*') {
            star_pattern_index = pattern_index;
            pattern_index += 2;
            star_text_index = text_index;
        } else if (pattern_index < pattern.len and (pattern[pattern_index] == '.' or pattern[pattern_index] == text[text_index])) {
            pattern_index += 1;
            text_index += 1;
        } else if (star_pattern_index) |star| {
            pattern_index = star + 2;
            star_text_index += 1;
            text_index = star_text_index;
        } else return false;
    }

    while (pattern_index + 1 < pattern.len and pattern[pattern_index] == '.' and pattern[pattern_index + 1] == '*') pattern_index += 2;
    return pattern_index == pattern.len;
}

fn globMatches(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0 or std.mem.eql(u8, pattern, "**/*")) return true;
    var cleaned = pattern;
    if (std.mem.startsWith(u8, cleaned, "**/")) cleaned = cleaned[3..];
    if (std.mem.startsWith(u8, cleaned, "*")) cleaned = cleaned[1..];
    if (std.mem.endsWith(u8, cleaned, "*")) cleaned = cleaned[0 .. cleaned.len - 1];
    return std.mem.indexOf(u8, path, cleaned) != null;
}

test "search text returns file line content and empty results" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(common.defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "a.zig", .data = "const needle = 1;\n" });
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "b.txt", .data = "nothing\n" });
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"query\":\"needle\",\"glob\":\"*.zig\"}}", .{root});
    defer std.testing.allocator.free(args);
    var result = try textExecute("call", args, null, null, null, std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a.zig:1:const needle = 1;\n", result.content.slice()[0].text.text);
    const empty_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"query\":\"absent\"}}", .{root});
    defer std.testing.allocator.free(empty_args);
    var empty = try textExecute("call", empty_args, null, null, null, std.testing.allocator);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", empty.content.slice()[0].text.text);
    const long_line = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(long_line);
    @memset(long_line, 'a');
    try tmp.dir.writeFile(common.defaultIo(), .{ .sub_path = "long.txt", .data = long_line });
    const long_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"workspace_root\":\"{s}\",\"query\":\".*z\",\"glob\":\"*.txt\"}}", .{root});
    defer std.testing.allocator.free(long_args);
    var long = try textExecute("call", long_args, null, null, null, std.testing.allocator);
    defer long.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", long.content.slice()[0].text.text);
    try std.testing.expect(std.mem.indexOf(u8, long.getDetailsJson().?, "\"skipped_oversized_files\":1") != null);
    var cancelled = std.atomic.Value(bool).init(true);
    const token = ai_types.CancelToken{ .cancelled = &cancelled };
    try std.testing.expectError(error.Cancelled, textExecute("call", long_args, token, null, null, std.testing.allocator));
}
