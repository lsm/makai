const std = @import("std");
const ai_types = @import("ai_types");
const agent = @import("agent");
const artifact_store = @import("artifact/store");
const compat = @import("compat");

pub const max_file_bytes: usize = 16 * 1024 * 1024;
pub const process_output_bytes: usize = 16 * 1024 * 1024;
pub const process_poll_ms: u64 = 100;
pub const max_results: usize = 200;
pub const default_shell_limit: usize = 10 * 1024;
pub const default_file_limit: usize = 20 * 1024;
pub const default_search_limit: usize = 15 * 1024;
pub const default_fallback_limit: usize = 4 * 1024;
pub const tool_output_threshold: usize = default_fallback_limit;
pub const snippet_bytes: usize = 512;

pub const ToolOutputLimits = struct {
    shell: usize = default_shell_limit,
    file: usize = default_file_limit,
    search: usize = default_search_limit,
    fallback: usize = default_fallback_limit,

    pub fn forTool(self: ToolOutputLimits, tool_name: []const u8) usize {
        return switch (classifyTool(tool_name)) {
            .shell => self.shell,
            .file => self.file,
            .search => self.search,
            .other => self.fallback,
        };
    }
};

const ToolKind = enum { shell, file, search, other };

pub const TextResultOptions = struct {
    tool_name: []const u8,
    call_id: []const u8,
    text: []const u8,
    stderr: []const u8 = "",
    details_json: []const u8 = "",
    force_artifact: bool = false,
    limits: ToolOutputLimits = .{},
    store: ?*artifact_store.ArtifactStore = null,
};

pub const TextResult = struct {
    result: agent.AgentToolResult,
    raw_bytes: usize,
    returned_bytes: usize,
    compressed: bool,
    artifact_path: ?[]const u8 = null,

    pub fn deinit(self: *TextResult, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        if (self.artifact_path) |path| allocator.free(path);
    }
};

fn classifyTool(tool_name: []const u8) ToolKind {
    if (matchesToolName(tool_name, "shell")) return .shell;
    if (matchesToolName(tool_name, "file") or matchesToolName(tool_name, "read") or matchesToolName(tool_name, "write") or matchesToolName(tool_name, "edit")) return .file;
    if (matchesToolName(tool_name, "search") or matchesToolName(tool_name, "grep")) return .search;
    return .other;
}

fn matchesToolName(tool_name: []const u8, token: []const u8) bool {
    if (std.mem.eql(u8, tool_name, token)) return true;
    if (!std.mem.startsWith(u8, tool_name, token)) return false;
    if (tool_name.len <= token.len) return false;
    const separator = tool_name[token.len];
    return separator == '_' or separator == '-';
}

pub fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub fn nowMs() i64 {
    return compat.time.nowMillis();
}

pub fn durationMs(start_ms: i64) u64 {
    const elapsed = nowMs() - start_ms;
    return if (elapsed <= 0) 0 else @intCast(elapsed);
}

pub fn isCancelled(cancel_token: ?ai_types.CancelToken) bool {
    if (cancel_token) |token| return token.isCancelled();
    return false;
}

pub fn parseArgs(allocator: std.mem.Allocator, args_json: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return error.InvalidArgumentsJson;
    if (parsed.value != .object) {
        var mutable = parsed;
        mutable.deinit();
        return error.InvalidArgumentsJson;
    }
    return parsed;
}

pub fn requiredString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.MissingRequiredArgument;
    if (value != .string) return error.InvalidArgumentType;
    return value.string;
}

pub fn optionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn optionalBool(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = obj.get(key) orelse return default;
    if (value != .bool) return default;
    return value.bool;
}

pub fn optionalU64(obj: std.json.ObjectMap, key: []const u8, default: u64) u64 {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .integer => |i| if (i < 0) default else @intCast(i),
        .float => |f| floatToU64(f) orelse default,
        .number_string => |s| std.fmt.parseUnsigned(u64, s, 10) catch default,
        else => default,
    };
}

pub fn optionalUsize(obj: std.json.ObjectMap, key: []const u8, default: usize) usize {
    const value = optionalU64(obj, key, default);
    if (value > std.math.maxInt(usize)) return default;
    return @intCast(value);
}

fn floatToU64(value: f64) ?u64 {
    if (!std.math.isFinite(value) or value < 0 or value >= 18446744073709551616.0) return null;
    return @intFromFloat(value);
}

test "optional numeric helpers reject overflow floats" {
    var parsed = try parseArgs(std.testing.allocator, "{\"timeout_ms\":1e30,\"ok\":42}");
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(u64, 30_000), optionalU64(obj, "timeout_ms", 30_000));
    try std.testing.expectEqual(@as(usize, 42), optionalUsize(obj, "ok", 0));
}

pub fn hasParentTraversal(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

pub fn openWorkspace(workspace_root: []const u8, iterate: bool) !std.Io.Dir {
    if (!std.Io.Dir.path.isAbsolute(workspace_root)) return error.WorkspaceRootMustBeAbsolute;
    return std.Io.Dir.openDirAbsolute(defaultIo(), workspace_root, .{ .iterate = iterate });
}

pub fn resolveWorkspacePath(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(path_value)) {
        const normalized_root = try std.Io.Dir.path.resolve(allocator, &.{workspace_root});
        defer allocator.free(normalized_root);
        const normalized_path = try std.Io.Dir.path.resolve(allocator, &.{path_value});
        defer allocator.free(normalized_path);
        if (std.mem.eql(u8, normalized_path, normalized_root)) return try allocator.dupe(u8, "");
        if (isFilesystemRoot(normalized_root)) {
            if (!std.mem.startsWith(u8, normalized_path, normalized_root)) return error.PathEscapesWorkspace;
            const offset: usize = if (std.mem.endsWith(u8, normalized_root, &.{std.Io.Dir.path.sep})) normalized_root.len else normalized_root.len + 1;
            if (normalized_path.len < offset) return try allocator.dupe(u8, "");
            return try allocator.dupe(u8, normalized_path[offset..]);
        }
        if (!std.mem.startsWith(u8, normalized_path, normalized_root)) return error.PathEscapesWorkspace;
        if (normalized_path.len <= normalized_root.len) return error.PathEscapesWorkspace;
        const sep = normalized_path[normalized_root.len];
        if (sep != std.Io.Dir.path.sep) return error.PathEscapesWorkspace;
        return try allocator.dupe(u8, normalized_path[normalized_root.len + 1 ..]);
    }
    if (hasParentTraversal(path_value)) return error.PathEscapesWorkspace;
    return try allocator.dupe(u8, path_value);
}

fn isFilesystemRoot(path: []const u8) bool {
    if (std.mem.eql(u8, path, &.{std.Io.Dir.path.sep})) return true;
    if (@import("builtin").os.tag == .windows) {
        return path.len == 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
    }
    return false;
}

pub fn readWorkspaceFile(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8, max_bytes: usize) ![]u8 {
    var file = try openWorkspaceFile(allocator, workspace_root, path_value);
    defer file.close(defaultIo());
    var file_reader = file.reader(defaultIo(), &.{});
    return file_reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

pub fn writeWorkspaceFile(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8, data: []const u8) !void {
    const relative_path = try resolveWorkspacePath(allocator, workspace_root, path_value);
    defer allocator.free(relative_path);
    var dir = try openWorkspace(workspace_root, false);
    defer dir.close(defaultIo());
    try ensureNoSymlinkComponents(allocator, dir, relative_path);
    var file = try dir.createFile(defaultIo(), relative_path, .{ .truncate = true, .permissions = compat.fs.default_file_mode, .resolve_beneath = true });
    defer file.close(defaultIo());
    try file.writeStreamingAll(defaultIo(), data);
}

pub fn statWorkspaceFile(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8) !std.Io.File.Stat {
    const relative_path = try resolveWorkspacePath(allocator, workspace_root, path_value);
    defer allocator.free(relative_path);
    var dir = try openWorkspace(workspace_root, false);
    defer dir.close(defaultIo());
    try ensureNoSymlinkComponents(allocator, dir, relative_path);
    return dir.statFile(defaultIo(), relative_path, .{ .follow_symlinks = false });
}

pub fn openWorkspaceFile(allocator: std.mem.Allocator, workspace_root: []const u8, path_value: []const u8) !std.Io.File {
    const relative_path = try resolveWorkspacePath(allocator, workspace_root, path_value);
    defer allocator.free(relative_path);
    var dir = try openWorkspace(workspace_root, false);
    defer dir.close(defaultIo());
    try ensureNoSymlinkComponents(allocator, dir, relative_path);
    return dir.openFile(defaultIo(), relative_path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
}

fn ensureNoSymlinkComponents(allocator: std.mem.Allocator, dir: std.Io.Dir, relative_path: []const u8) !void {
    if (relative_path.len == 0) return error.InvalidFilePath;
    var prefix = std.ArrayList(u8).empty;
    defer prefix.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, relative_path, "/\\");
    while (it.next()) |part| {
        if (prefix.items.len != 0) try prefix.append(allocator, std.Io.Dir.path.sep);
        try prefix.appendSlice(allocator, part);
        dir.access(defaultIo(), prefix.items, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const st = try dir.statFile(defaultIo(), prefix.items, .{ .follow_symlinks = false });
        if (st.kind == .sym_link) return error.PathEscapesWorkspace;
    }
}

pub fn isBinary(data: []const u8) bool {
    const limit = @min(data.len, 4096);
    return std.mem.indexOfScalar(u8, data[0..limit], 0) != null;
}

pub fn lineHash(line: []const u8) [16]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(line);
    return hexU64(hasher.final());
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

pub fn storeArtifact(allocator: std.mem.Allocator, key: []const u8, data: []const u8) ![]u8 {
    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(defaultIo(), ".makai/tool-artifacts") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const safe = try sanitizeKey(allocator, key);
    defer allocator.free(safe);
    const path = try std.fmt.allocPrint(allocator, ".makai/tool-artifacts/{s}.txt", .{safe});
    errdefer allocator.free(path);
    try cwd.writeFile(defaultIo(), .{ .sub_path = path, .data = data });
    return path;
}

pub fn cleanupArtifacts() !void {
    var cwd = std.Io.Dir.cwd();
    if (cwd.access(defaultIo(), ".makai/tool-artifacts", .{})) {
        try cwd.deleteTree(defaultIo(), ".makai/tool-artifacts");
    } else |_| {}
}

pub fn retrieveArtifact(allocator: std.mem.Allocator, reference: []const u8, max_bytes: usize) ![]u8 {
    if (!std.mem.startsWith(u8, reference, ".makai/tool-artifacts/")) return error.InvalidArtifactReference;
    if (hasParentTraversal(reference) or std.Io.Dir.path.isAbsolute(reference)) return error.InvalidArtifactReference;
    var cwd = std.Io.Dir.cwd();
    const st = try cwd.statFile(defaultIo(), reference, .{ .follow_symlinks = false });
    if (st.kind == .sym_link) return error.InvalidArtifactReference;
    var file = try cwd.openFile(defaultIo(), reference, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(defaultIo());
    var reader = file.reader(defaultIo(), &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

pub fn telemetryDetails(allocator: std.mem.Allocator, raw_bytes: usize, returned_bytes: usize, compressed: bool) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"raw_bytes\":{d},\"returned_bytes\":{d},\"saved_bytes\":{d},\"compressed\":{s}}}", .{ raw_bytes, returned_bytes, raw_bytes -| returned_bytes, if (compressed) "true" else "false" });
}

pub fn makeTextResult(allocator: std.mem.Allocator, text: []const u8, details_json: []const u8) !agent.AgentToolResult {
    const parts = try allocator.alloc(ai_types.UserContentPart, 1);
    errdefer allocator.free(parts);
    parts[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    errdefer parts[0].deinit(allocator);
    return .{
        .content = ai_types.OwnedSlice(ai_types.UserContentPart).initOwned(parts),
        .details_json = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, details_json)),
    };
}

pub fn makeTextResultOwned(allocator: std.mem.Allocator, text: []u8, details_json: []u8) !agent.AgentToolResult {
    const parts = try allocator.alloc(ai_types.UserContentPart, 1);
    errdefer allocator.free(parts);
    parts[0] = .{ .text = .{ .text = text } };
    return .{
        .content = ai_types.OwnedSlice(ai_types.UserContentPart).initOwned(parts),
        .details_json = ai_types.OwnedSlice(u8).initOwned(details_json),
    };
}

pub fn jsonString(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn makeTextResultWithArtifact(allocator: std.mem.Allocator, options: TextResultOptions) !TextResult {
    const raw_bytes = options.text.len + options.stderr.len;
    const limit = options.limits.forTool(options.tool_name);
    const should_store = options.force_artifact or options.text.len > limit;
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

    var reference = if (options.store) |store|
        try store.write(.{ .content = options.text, .mime_type = "text/plain", .description = key })
    else
        try makeFileArtifactReference(allocator, key, options.text, raw_bytes);
    errdefer reference.deinit(if (options.store) |store| store.allocator else allocator);

    const artifact_uri = reference.getUri() orelse reference.artifact_id;
    const artifact_path = if (options.store == null) try allocator.dupe(u8, artifact_uri) else null;
    errdefer if (artifact_path) |path| allocator.free(path);

    const summary = try summarizeArtifactBackedOutput(allocator, options.text, options.stderr, artifact_uri);
    defer allocator.free(summary);
    const details = if (options.details_json.len > 0)
        try std.fmt.allocPrint(allocator, "{{\"raw_bytes\":{d},\"returned_bytes\":{d},\"saved_bytes\":{d},\"compressed\":true,\"artifact_path\":\"{s}\",\"details\":{s}}}", .{ raw_bytes, summary.len, raw_bytes -| summary.len, artifact_uri, options.details_json })
    else
        try std.fmt.allocPrint(allocator, "{{\"raw_bytes\":{d},\"returned_bytes\":{d},\"saved_bytes\":{d},\"compressed\":true,\"artifact_path\":\"{s}\"}}", .{ raw_bytes, summary.len, raw_bytes -| summary.len, artifact_uri });
    defer allocator.free(details);
    var result = try makeTextResult(allocator, summary, details);
    errdefer result.deinit(allocator);
    const artifact_refs = try allocator.alloc(ai_types.ArtifactReference, 1);
    errdefer allocator.free(artifact_refs);
    artifact_refs[0] = if (options.store != null) try cloneArtifactReference(allocator, reference) else reference;
    errdefer artifact_refs[0].deinit(allocator);
    if (options.store) |store| reference.deinit(store.allocator);
    result.artifacts = ai_types.OwnedSlice(ai_types.ArtifactReference).initOwned(artifact_refs);
    return .{ .result = result, .raw_bytes = raw_bytes, .returned_bytes = summary.len + details.len, .compressed = true, .artifact_path = artifact_path };
}

fn makeFileArtifactReference(allocator: std.mem.Allocator, key: []const u8, text: []const u8, raw_bytes: usize) !ai_types.ArtifactReference {
    const artifact_path = try storeArtifact(allocator, key, text);
    errdefer allocator.free(artifact_path);
    const artifact_id = try allocator.dupe(u8, key);
    errdefer allocator.free(artifact_id);
    return .{
        .artifact_id = artifact_id,
        .uri = ai_types.OwnedSlice(u8).initOwned(artifact_path),
        .byte_size = raw_bytes,
    };
}

fn cloneArtifactReference(allocator: std.mem.Allocator, reference: ai_types.ArtifactReference) !ai_types.ArtifactReference {
    var cloned = ai_types.ArtifactReference{
        .artifact_id = try allocator.dupe(u8, reference.artifact_id),
        .byte_size = reference.byte_size,
    };
    errdefer cloned.deinit(allocator);

    if (reference.uri.slice().len > 0) cloned.uri = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, reference.uri.slice()));
    if (reference.mime_type.slice().len > 0) cloned.mime_type = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, reference.mime_type.slice()));
    if (reference.sha256.slice().len > 0) cloned.sha256 = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, reference.sha256.slice()));
    if (reference.description.slice().len > 0) cloned.description = ai_types.OwnedSlice(u8).initOwned(try allocator.dupe(u8, reference.description.slice()));
    return cloned;
}

fn summarizeArtifactBackedOutput(allocator: std.mem.Allocator, text: []const u8, stderr: []const u8, artifact_path: []const u8) ![]u8 {
    const head = text[0..@min(text.len, snippet_bytes)];
    const tail_start = if (text.len > snippet_bytes) text.len - snippet_bytes else 0;
    const tail = text[tail_start..];
    if (stderr.len > 0) {
        return std.fmt.allocPrint(
            allocator,
            "output stored as artifact\nbytes: {d}\nlines: {d}\nartifact_reference: {s}\nretrieve_full_output: call artifact_retrieve with reference exactly \"{s}\"\nhead:\n{s}\ntail:\n{s}\nstderr:\n{s}",
            .{ text.len, countLines(text), artifact_path, artifact_path, head, tail, stderr },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "output stored as artifact\nbytes: {d}\nlines: {d}\nartifact_reference: {s}\nretrieve_full_output: call artifact_retrieve with reference exactly \"{s}\"\nhead:\n{s}\ntail:\n{s}",
        .{ text.len, countLines(text), artifact_path, artifact_path, head, tail },
    );
}

test "artifact-backed summary tells the model how to retrieve full output" {
    const summary = try summarizeArtifactBackedOutput(std.testing.allocator, "line 1\nline 2\n", "", ".makai/tool-artifacts/test.txt");
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "artifact_reference: .makai/tool-artifacts/test.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "artifact_retrieve with reference exactly") != null);
}

fn sanitizeKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, key.len);
    for (key, 0..) |c, i| out[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
    return out;
}

fn hexU64(value: u64) [16]u8 {
    const alphabet = "0123456789abcdef";
    var out: [16]u8 = undefined;
    for (&out, 0..) |*c, i| {
        const shift: u6 = @intCast((15 - i) * 4);
        c.* = alphabet[@as(u4, @truncate(value >> shift))];
    }
    return out;
}

test "common path and binary helpers" {
    const cwd = try std.process.currentPathAlloc(defaultIo(), std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", "common-test-root" });
    defer std.testing.allocator.free(root);
    const inside_abs = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "dir", "file.txt" });
    defer std.testing.allocator.free(inside_abs);
    const inside_rel = try resolveWorkspacePath(std.testing.allocator, root, inside_abs);
    defer std.testing.allocator.free(inside_rel);
    try std.testing.expectEqualStrings("dir/file.txt", inside_rel);
    const root_rel = try resolveWorkspacePath(std.testing.allocator, root, root);
    defer std.testing.allocator.free(root_rel);
    try std.testing.expectEqualStrings("", root_rel);
    if (@import("builtin").os.tag != .windows) {
        const root_child = try resolveWorkspacePath(std.testing.allocator, "/", "/tmp/root-child.txt");
        defer std.testing.allocator.free(root_child);
        try std.testing.expectEqualStrings("tmp/root-child.txt", root_child);
    } else {
        try std.testing.expect(isFilesystemRoot("C:\\"));
    }
    const outside = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "outside.txt" });
    defer std.testing.allocator.free(outside);
    try std.testing.expectError(error.PathEscapesWorkspace, resolveWorkspacePath(std.testing.allocator, root, outside));
    const traversal = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "..", "outside.txt" });
    defer std.testing.allocator.free(traversal);
    try std.testing.expectError(error.PathEscapesWorkspace, resolveWorkspacePath(std.testing.allocator, root, traversal));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try std.Io.Dir.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer std.testing.allocator.free(tmp_root);
    try tmp.dir.symLink(defaultIo(), "/", "link", .{ .is_directory = true });
    try std.testing.expectError(error.PathEscapesWorkspace, readWorkspaceFile(std.testing.allocator, tmp_root, "link/passwd", 1024));
    try std.testing.expect(hasParentTraversal("a/../b"));
    try std.testing.expect(hasParentTraversal("a\\..\\b"));
    try std.testing.expect(!hasParentTraversal("a/..b/c"));
    try std.testing.expect(!isBinary(""));
    try std.testing.expect(!isBinary("abc"));
    try std.testing.expect(isBinary("a\x00b"));
    var boundary = [_]u8{'a'} ** 4097;
    boundary[4095] = 0;
    try std.testing.expect(isBinary(&boundary));
    boundary[4095] = 'a';
    boundary[4096] = 0;
    try std.testing.expect(!isBinary(&boundary));
}

test "line hash and artifact helpers" {
    try std.testing.expectEqual(@as(usize, 16), lineHash("one").len);
    try std.testing.expect(!std.mem.eql(u8, &lineHash("one"), &lineHash("two")));
    const buf = try std.testing.allocator.alloc(u8, tool_output_threshold + 10);
    defer std.testing.allocator.free(buf);
    @memset(buf, 'x');
    var made = try makeTextResultWithArtifact(std.testing.allocator, .{ .tool_name = "test", .call_id = "call", .text = buf });
    defer made.deinit(std.testing.allocator);
    try std.testing.expect(made.compressed);
    try std.testing.expect(made.artifact_path != null);
    try std.testing.expectEqual(@as(usize, 1), made.result.artifacts.slice().len);
    try std.testing.expectEqualStrings("test:call", made.result.artifacts.slice()[0].artifact_id);
    try std.testing.expectEqualStrings(made.artifact_path.?, made.result.artifacts.slice()[0].getUri().?);
    try std.testing.expectEqual(@as(?u64, buf.len), made.result.artifacts.slice()[0].byte_size);
    try std.testing.expect(std.mem.indexOf(u8, made.result.content.slice()[0].text.text, "output stored as artifact") != null);
    const full = try retrieveArtifact(std.testing.allocator, made.artifact_path.?, buf.len + 1);
    defer std.testing.allocator.free(full);
    try std.testing.expectEqualStrings(buf, full);
    try cleanupArtifacts();
    try std.testing.expectError(error.FileNotFound, retrieveArtifact(std.testing.allocator, made.artifact_path.?, buf.len + 1));
}

test "tool output limits classify by exact token prefix" {
    const limits = ToolOutputLimits{ .shell = 8, .file = 16, .search = 24, .fallback = 4 };
    try std.testing.expectEqual(@as(usize, 8), limits.forTool("shell_execute"));
    try std.testing.expectEqual(@as(usize, 16), limits.forTool("file_read"));
    try std.testing.expectEqual(@as(usize, 24), limits.forTool("search_text"));
    try std.testing.expectEqual(@as(usize, 4), limits.forTool("profile_read"));
    try std.testing.expectEqual(@as(usize, 4), limits.forTool("seashell_analyzer"));
}

test "artifact helper respects per-tool limits" {
    const buf = try std.testing.allocator.alloc(u8, 12);
    defer std.testing.allocator.free(buf);
    @memset(buf, 'x');

    var shell_made = try makeTextResultWithArtifact(std.testing.allocator, .{ .tool_name = "shell_execute", .call_id = "shell", .text = buf, .limits = .{ .shell = 8, .file = 32, .search = 32, .fallback = 32 } });
    defer shell_made.deinit(std.testing.allocator);
    try std.testing.expect(shell_made.compressed);

    var file_made = try makeTextResultWithArtifact(std.testing.allocator, .{ .tool_name = "file_read", .call_id = "file", .text = buf, .limits = .{ .shell = 8, .file = 32, .search = 32, .fallback = 32 } });
    defer file_made.deinit(std.testing.allocator);
    try std.testing.expect(!file_made.compressed);
    try cleanupArtifacts();
}

test "artifact helper uses ArtifactStore backend when provided" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    const root_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "artifacts" });
    defer allocator.free(root_path);
    try compat.fs.createDir(compat.fs.getCwd(), root_path);
    var store = try artifact_store.ArtifactStore.initWithPath(allocator, root_path, null);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var made = try makeTextResultWithArtifact(allocator, .{ .tool_name = "search_text", .call_id = "call", .text = "abcdefghijklmnopqrstuvwxyz", .limits = .{ .search = 8 }, .store = &store });
    defer made.deinit(allocator);
    try std.testing.expect(made.compressed);
    try std.testing.expectEqual(@as(?[]const u8, null), made.artifact_path);
    try std.testing.expectEqual(@as(usize, 1), made.result.artifacts.slice().len);
    const artifact = made.result.artifacts.slice()[0];
    try std.testing.expect(std.mem.startsWith(u8, artifact.getUri().?, "makai-artifact://"));

    var stored = try store.read(artifact.artifact_id);
    defer stored.deinit(allocator);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz", stored.content);
}

test "artifact retrieval rejects symlink targets" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var cwd = std.Io.Dir.cwd();
    cwd.createDirPath(defaultIo(), ".makai/tool-artifacts") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer cleanupArtifacts() catch {};
    try cwd.writeFile(defaultIo(), .{ .sub_path = ".makai/artifact-outside.txt", .data = "secret" });
    defer cwd.deleteFile(defaultIo(), ".makai/artifact-outside.txt") catch {};
    try cwd.symLink(defaultIo(), "../artifact-outside.txt", ".makai/tool-artifacts/link.txt", .{ .is_directory = false });
    try std.testing.expectError(error.InvalidArtifactReference, retrieveArtifact(std.testing.allocator, ".makai/tool-artifacts/link.txt", 1024));
}
