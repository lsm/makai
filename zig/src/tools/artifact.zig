const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const common = @import("tools/common");

const max_artifact_bytes = 64 * 1024 * 1024;
const default_preview_max_bytes = 32 * 1024;
const default_range_max_bytes = 64 * 1024;
const default_grep_max_bytes = 64 * 1024;
const default_head_lines = 40;
const default_tail_lines = 20;
const default_range_lines = 120;
const default_grep_context_lines = 0;

const RetrieveMode = enum {
    preview,
    range,
    grep,
    full_for_display,
    full_for_context,
};

pub const retrieve_tool = agent.AgentTool{
    .label = "Artifact Retrieve",
    .name = "artifact_retrieve",
    .description = "Inspect output previously stored as a local artifact. Defaults to a capped preview so large outputs are not inserted into model context. Use explicit modes for line ranges, literal grep, display-only full output, or full context retrieval.",
    .short_description = "Preview, filter, or explicitly retrieve stored tool output.",
    .parameters_schema_json =
    \\{"type":"object","properties":{"description":{"type":"string","description":"Why this tool call is needed and what information or change it is intended to produce."},"reference":{"type":"string","description":"Artifact reference from the tool result."},"mode":{"type":"string","enum":["preview","range","grep","full_for_display","full_for_context"],"description":"preview is capped and is the default. full_for_display makes the full artifact available to the TUI without inserting it into model context. full_for_context explicitly returns the complete artifact to the model."},"start_line":{"type":"integer","minimum":1,"description":"First 1-based line for range mode."},"line_count":{"type":"integer","minimum":1,"description":"Maximum number of lines for range mode."},"pattern":{"type":"string","description":"Literal substring to search for in grep mode."},"context_lines":{"type":"integer","minimum":0,"description":"Number of surrounding lines for grep mode."},"max_bytes":{"type":"integer","minimum":1,"description":"Maximum bytes returned to model context for preview, range, or grep modes."}},"required":["description","reference"],"additionalProperties":false}
    ,
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
    _ = on_update_ctx;
    _ = on_update;
    if (common.isCancelled(cancel_token)) return error.Cancelled;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const reference = jsonString(parsed.value.object, "reference") orelse return error.InvalidArguments;
    const mode = parseMode(jsonString(parsed.value.object, "mode")) orelse .preview;
    if (common.isCancelled(cancel_token)) return error.Cancelled;

    const data = try common.retrieveArtifact(allocator, reference, max_artifact_bytes);
    defer allocator.free(data);
    if (common.isCancelled(cancel_token)) return error.Cancelled;

    const max_bytes = optionalUsize(parsed.value.object, "max_bytes") orelse switch (mode) {
        .preview, .full_for_display => default_preview_max_bytes,
        .range => default_range_max_bytes,
        .grep => default_grep_max_bytes,
        .full_for_context => data.len,
    };

    const content = switch (mode) {
        .preview => try previewContent(allocator, reference, data, default_head_lines, default_tail_lines, max_bytes),
        .range => blk: {
            const start_line = optionalUsize(parsed.value.object, "start_line") orelse 1;
            const line_count = optionalUsize(parsed.value.object, "line_count") orelse default_range_lines;
            break :blk try rangeContent(allocator, reference, data, start_line, line_count, max_bytes);
        },
        .grep => blk: {
            const pattern = jsonString(parsed.value.object, "pattern") orelse return error.InvalidArguments;
            const context_lines = optionalUsize(parsed.value.object, "context_lines") orelse default_grep_context_lines;
            break :blk try grepContent(allocator, reference, data, pattern, context_lines, max_bytes);
        },
        .full_for_display => try displayOnlyContent(allocator, reference, data, max_bytes),
        .full_for_context => try allocator.dupe(u8, data),
    };
    defer allocator.free(content);

    const returned_bytes = content.len;
    const compressed = returned_bytes < data.len or mode != .full_for_context;
    const details = try std.fmt.allocPrint(
        allocator,
        "{{\"raw_bytes\":{d},\"returned_bytes\":{d},\"saved_bytes\":{d},\"compressed\":{},\"artifact_path\":\"{s}\",\"mode\":\"{s}\",\"display_only\":{}}}",
        .{ data.len, returned_bytes, data.len -| returned_bytes, compressed, reference, @tagName(mode), mode == .full_for_display },
    );
    defer allocator.free(details);
    return common.makeTextResult(allocator, content, details);
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalUsize(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| if (i < 0) null else @intCast(i),
        .number_string => |s| std.fmt.parseUnsigned(usize, s, 10) catch null,
        else => null,
    };
}

fn parseMode(value: ?[]const u8) ?RetrieveMode {
    const text = value orelse return null;
    inline for (std.meta.fields(RetrieveMode)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn previewContent(allocator: std.mem.Allocator, reference: []const u8, data: []const u8, head_lines: usize, tail_lines: usize, max_bytes: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print(
        "artifact preview\nreference: {s}\nbytes: {d}\nlines: {d}\nreturned_to_model: capped at {d} bytes\n",
        .{ reference, data.len, countLines(data), max_bytes },
    );

    try writer.writeAll("\nhead:\n");
    try writeFirstLines(writer, data, head_lines);
    if (tail_lines > 0 and countLines(data) > head_lines) {
        try writer.writeAll("\n...\ntail:\n");
        try writeLastLines(allocator, writer, data, tail_lines);
    }
    try writer.writeAll("\n\nFor more, call artifact_retrieve with mode \"range\" or \"grep\". Use \"full_for_context\" only when the complete output is actually needed by the model.");
    const raw = try out.toOwnedSlice();
    return truncateWithNotice(allocator, raw, max_bytes);
}

fn rangeContent(allocator: std.mem.Allocator, reference: []const u8, data: []const u8, start_line: usize, line_count: usize, max_bytes: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("artifact range\nreference: {s}\nbytes: {d}\nlines: {d}\nrange: {d}..{d}\n\n", .{
        reference,
        data.len,
        countLines(data),
        start_line,
        start_line +| line_count -| 1,
    });

    var current: usize = 1;
    var emitted: usize = 0;
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| : (current += 1) {
        if (current < start_line) continue;
        if (emitted >= line_count) break;
        try writer.print("{d}:{s}\n", .{ current, line });
        emitted += 1;
    }
    const raw = try out.toOwnedSlice();
    return truncateWithNotice(allocator, raw, max_bytes);
}

fn grepContent(allocator: std.mem.Allocator, reference: []const u8, data: []const u8, pattern: []const u8, context_lines: usize, max_bytes: usize) ![]u8 {
    if (pattern.len == 0) return error.InvalidArguments;

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| try lines.append(allocator, line);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("artifact grep\nreference: {s}\nbytes: {d}\nlines: {d}\npattern: {s}\ncontext_lines: {d}\n\n", .{
        reference,
        data.len,
        lines.items.len,
        pattern,
        context_lines,
    });

    var matches: usize = 0;
    var last_emitted: usize = 0;
    for (lines.items, 0..) |line, idx| {
        if (std.mem.indexOf(u8, line, pattern) == null) continue;
        matches += 1;
        const start = idx -| context_lines;
        const end = @min(lines.items.len, idx + context_lines + 1);
        if (start > last_emitted) try writer.writeAll("--\n");
        var i = @max(start, last_emitted);
        while (i < end) : (i += 1) {
            try writer.print("{d}:{s}\n", .{ i + 1, lines.items[i] });
        }
        last_emitted = @max(last_emitted, end);
    }
    if (matches == 0) try writer.writeAll("no matches\n");
    try writer.print("\nmatches: {d}\n", .{matches});
    const raw = try out.toOwnedSlice();
    return truncateWithNotice(allocator, raw, max_bytes);
}

fn displayOnlyContent(allocator: std.mem.Allocator, reference: []const u8, data: []const u8, max_bytes: usize) ![]u8 {
    const preview = try previewContent(allocator, reference, data, default_head_lines, default_tail_lines, max_bytes);
    defer allocator.free(preview);
    return std.fmt.allocPrint(
        allocator,
        "artifact full output requested for display only\nreference: {s}\nbytes: {d}\nlines: {d}\n\nThe full artifact was not inserted into model context. Open it in the TUI artifact viewer for scrolling/copying.\n\n{s}",
        .{ reference, data.len, countLines(data), preview },
    );
}

fn writeFirstLines(writer: *std.Io.Writer, data: []const u8, max_lines: usize) !void {
    var emitted: usize = 0;
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (emitted >= max_lines) break;
        try writer.writeAll(line);
        try writer.writeByte('\n');
        emitted += 1;
    }
}

fn writeLastLines(allocator: std.mem.Allocator, writer: *std.Io.Writer, data: []const u8, max_lines: usize) !void {
    const capacity = max_lines + 1;
    var starts = try allocator.alloc(usize, capacity);
    defer allocator.free(starts);
    var starts_len: usize = 1;
    starts[0] = 0;
    for (data, 0..) |c, i| {
        if (c == '\n' and i + 1 < data.len) {
            if (starts_len == capacity) {
                std.mem.copyForwards(usize, starts[0 .. capacity - 1], starts[1..capacity]);
                starts_len -= 1;
            }
            starts[starts_len] = i + 1;
            starts_len += 1;
        }
    }
    const start_index = if (starts_len > max_lines) starts_len - max_lines else 0;
    var i = start_index;
    while (i < starts_len) : (i += 1) {
        const start = starts[i];
        const end = if (i + 1 < starts_len) starts[i + 1] - 1 else data.len;
        try writer.writeAll(data[start..end]);
        try writer.writeByte('\n');
    }
}

fn truncateWithNotice(allocator: std.mem.Allocator, owned: []u8, max_bytes: usize) ![]u8 {
    defer allocator.free(owned);
    if (owned.len <= max_bytes) return allocator.dupe(u8, owned);
    const suffix = "\n\n[artifact retrieve output capped; use range or grep to narrow, or full_for_context explicitly]\n";
    const keep = max_bytes -| suffix.len;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ owned[0..@min(owned.len, keep)], suffix });
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var lines: usize = 1;
    for (text) |c| {
        if (c == '\n') lines += 1;
    }
    if (text[text.len - 1] == '\n') lines -= 1;
    return lines;
}

test "artifact_retrieve defaults to preview instead of full output" {
    const allocator = std.testing.allocator;
    const path = try common.storeArtifact(allocator, "artifact-test", "line 1\nline 2\nline 3\n");
    defer allocator.free(path);
    const args = try std.fmt.allocPrint(allocator, "{{\"description\":\"preview\",\"reference\":\"{s}\"}}", .{path});
    defer allocator.free(args);
    var result = try executeRetrieve("call", args, null, null, null, allocator);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.content.slice()[0].text.text, "artifact preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content.slice()[0].text.text, "line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content.slice()[0].text.text, "full_for_context") != null);
    try std.testing.expectError(error.InvalidArtifactReference, common.retrieveArtifact(allocator, "../build.zig", 1024));
    try std.testing.expectError(error.InvalidArtifactReference, common.retrieveArtifact(allocator, "/tmp/not-an-artifact", 1024));
}

test "artifact_retrieve supports range grep and full context modes" {
    const allocator = std.testing.allocator;
    const path = try common.storeArtifact(allocator, "artifact-test-modes", "alpha\nbeta\nneedle\nomega\n");
    defer allocator.free(path);

    const range_args = try std.fmt.allocPrint(allocator, "{{\"description\":\"range\",\"reference\":\"{s}\",\"mode\":\"range\",\"start_line\":2,\"line_count\":2}}", .{path});
    defer allocator.free(range_args);
    var range = try executeRetrieve("call", range_args, null, null, null, allocator);
    defer range.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, range.content.slice()[0].text.text, "2:beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, range.content.slice()[0].text.text, "3:needle") != null);

    const grep_args = try std.fmt.allocPrint(allocator, "{{\"description\":\"grep\",\"reference\":\"{s}\",\"mode\":\"grep\",\"pattern\":\"needle\"}}", .{path});
    defer allocator.free(grep_args);
    var grep = try executeRetrieve("call", grep_args, null, null, null, allocator);
    defer grep.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, grep.content.slice()[0].text.text, "3:needle") != null);

    const full_args = try std.fmt.allocPrint(allocator, "{{\"description\":\"full\",\"reference\":\"{s}\",\"mode\":\"full_for_context\"}}", .{path});
    defer allocator.free(full_args);
    var full = try executeRetrieve("call", full_args, null, null, null, allocator);
    defer full.deinit(allocator);
    try std.testing.expectEqualStrings("alpha\nbeta\nneedle\nomega\n", full.content.slice()[0].text.text);
}
