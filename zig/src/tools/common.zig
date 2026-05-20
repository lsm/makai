const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const agent_types = @import("agent_types");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const tool_output_threshold: usize = 4 * 1024;
pub const snippet_bytes: usize = 512;

pub const ToolRuntimeConfig = struct {
    compact_output: bool = false,
    artifact_dir: ?[]const u8 = null,
};

pub const TextResultOptions = struct {
    tool_name: []const u8,
    call_id: []const u8,
    text: []const u8,
    stderr: []const u8 = "",
    details_json: []const u8 = "",
    compact_output: bool = false,
    force_artifact: bool = false,
};

pub const TextResult = struct {
    result: agent_types.AgentToolResult,
    raw_bytes: usize,
    returned_bytes: usize,
    compressed: bool,
    artifact_path: ?[]const u8 = null,

    pub fn deinit(self: *TextResult, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        if (self.artifact_path) |path| allocator.free(path);
    }
};

pub fn lineHash(line: []const u8) [2]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(line);
    const value = hasher.final();
    const byte: u8 = @truncate(value >> 56);
    return hexByte(byte);
}

pub fn lineHashAlloc(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const hash = lineHash(line);
    return allocator.dupe(u8, &hash);
}

pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    if (text[text.len - 1] == '\n') count -= 1;
    return count;
}

pub fn makeTextResult(allocator: std.mem.Allocator, text: []const u8, details_json: []const u8) !agent_types.AgentToolResult {
    const content = try allocator.alloc(ai_types.UserContentPart, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    errdefer allocator.free(content[0].text.text);

    return .{
        .content = OwnedSlice(ai_types.UserContentPart).initOwned(content),
        .details_json = OwnedSlice(u8).initOwned(try allocator.dupe(u8, details_json)),
    };
}

pub fn makeTextResultWithArtifact(allocator: std.mem.Allocator, options: TextResultOptions) !TextResult {
    const raw_bytes = options.text.len + options.stderr.len;
    const should_store = options.force_artifact or options.text.len > tool_output_threshold;
    if (!should_store) {
        const body = if (options.stderr.len > 0)
            try std.fmt.allocPrint(allocator, "{s}\nstderr:\n{s}", .{ options.text, options.stderr })
        else
            try allocator.dupe(u8, options.text);
        defer allocator.free(body);
        const result = try makeTextResult(allocator, body, options.details_json);
        const returned_bytes = body.len + options.details_json.len;
        return .{ .result = result, .raw_bytes = raw_bytes, .returned_bytes = returned_bytes, .compressed = false };
    }

    const key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ options.tool_name, options.call_id });
    defer allocator.free(key);
    const artifact_path = try storeArtifact(allocator, key, options.text);
    errdefer allocator.free(artifact_path);

    const summary = try summarizeArtifactBackedOutput(allocator, options.text, options.stderr, artifact_path);
    defer allocator.free(summary);

    const details = if (options.details_json.len > 0)
        try std.fmt.allocPrint(allocator, "{{\"raw_bytes\":{d},\"returned_bytes\":{d},\"saved_bytes\":{d},\"compressed\":true,\"artifact_path\":\"{s}\",\"details\":{s}}}", .{ raw_bytes, summary.len, raw_bytes -| summary.len, artifact_path, options.details_json })
    else
        try std.fmt.allocPrint(allocator, "{{\"raw_bytes\":{d},\"returned_bytes\":{d},\"saved_bytes\":{d},\"compressed\":true,\"artifact_path\":\"{s}\"}}", .{ raw_bytes, summary.len, raw_bytes -| summary.len, artifact_path });
    defer allocator.free(details);

    const result = try makeTextResult(allocator, summary, details);
    const returned_bytes = summary.len + details.len;
    return .{ .result = result, .raw_bytes = raw_bytes, .returned_bytes = returned_bytes, .compressed = true, .artifact_path = artifact_path };
}

pub fn storeArtifact(allocator: std.mem.Allocator, key: []const u8, data: []const u8) ![]u8 {
    const cwd = compat.fs.getCwd();
    try compat.fs.createDir(cwd, ".makai/tool-artifacts");
    const safe = try sanitizeKey(allocator, key);
    defer allocator.free(safe);
    const path = try std.fmt.allocPrint(allocator, ".makai/tool-artifacts/{s}.txt", .{safe});
    errdefer allocator.free(path);
    try compat.fs.writeFile(cwd, path, data);
    return path;
}

pub fn retrieveArtifact(allocator: std.mem.Allocator, reference: []const u8, max_bytes: usize) ![]u8 {
    return compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), reference, max_bytes);
}

pub fn telemetryDetails(allocator: std.mem.Allocator, raw_bytes: usize, returned_bytes: usize, compressed: bool) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"raw_bytes\":{d},\"returned_bytes\":{d},\"saved_bytes\":{d},\"compressed\":{s}}}", .{ raw_bytes, returned_bytes, raw_bytes -| returned_bytes, if (compressed) "true" else "false" });
}

fn summarizeArtifactBackedOutput(allocator: std.mem.Allocator, text: []const u8, stderr: []const u8, artifact_path: []const u8) ![]u8 {
    const head = text[0..@min(text.len, snippet_bytes)];
    const tail_start = if (text.len > snippet_bytes) text.len - snippet_bytes else 0;
    const tail = text[tail_start..];
    if (stderr.len > 0) {
        return std.fmt.allocPrint(allocator,
            "output stored as artifact\nbytes: {d}\nlines: {d}\nartifact: {s}\nhead:\n{s}\ntail:\n{s}\nstderr:\n{s}",
            .{ text.len, countLines(text), artifact_path, head, tail, stderr },
        );
    }
    return std.fmt.allocPrint(allocator,
        "output stored as artifact\nbytes: {d}\nlines: {d}\nartifact: {s}\nhead:\n{s}\ntail:\n{s}",
        .{ text.len, countLines(text), artifact_path, head, tail },
    );
}

fn sanitizeKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, key.len);
    for (key, 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
    }
    return out;
}

fn hexByte(value: u8) [2]u8 {
    const alphabet = "0123456789abcdef";
    return .{ alphabet[value >> 4], alphabet[value & 0x0f] };
}

test "lineHash changes with content" {
    try std.testing.expect(!std.mem.eql(u8, &lineHash("one"), &lineHash("two")));
}

test "makeTextResultWithArtifact stores and summarizes large output" {
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, tool_output_threshold + 10);
    defer allocator.free(buf);
    @memset(buf, 'x');
    var made = try makeTextResultWithArtifact(allocator, .{ .tool_name = "test", .call_id = "call", .text = buf });
    defer made.deinit(allocator);
    try std.testing.expect(made.compressed);
    try std.testing.expect(made.artifact_path != null);
    try std.testing.expect(std.mem.indexOf(u8, made.result.content.slice()[0].text.text, "output stored as artifact") != null);
    const full = try retrieveArtifact(allocator, made.artifact_path.?, buf.len + 1);
    defer allocator.free(full);
    try std.testing.expectEqualStrings(buf, full);
}
