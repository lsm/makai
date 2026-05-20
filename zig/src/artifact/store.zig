const std = @import("std");
const builtin = @import("builtin");
const ai_types = @import("ai_types");
const compat = @import("compat");
const json_writer = @import("json_writer");
const owned_slice_mod = @import("owned_slice");

const OwnedSlice = owned_slice_mod.OwnedSlice;
const default_mime_type = "application/octet-stream";
const uri_prefix = "makai-artifact://";
const index_file_name = "index.json";
const index_tmp_file_name = "index.json.tmp";

fn defaultIo() std.Io {
    return if (builtin.is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

fn sha256Hex(content: []const u8) [64]u8 {
    const alphabet = "0123456789abcdef";
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});
    var out: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

pub const ArtifactInput = struct {
    content: []const u8,
    mime_type: []const u8 = default_mime_type,
    description: []const u8 = "",
};

pub const StoredArtifact = struct {
    artifact_id: []const u8,
    mime_type: []const u8,
    byte_size: u64,
    sha256: []const u8,
    created_at_ms: i64,
    last_accessed_ms: i64,
    description: []const u8 = "",

    pub fn deinit(self: *StoredArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_id);
        allocator.free(self.mime_type);
        allocator.free(self.sha256);
        allocator.free(self.description);
        self.* = undefined;
    }
};

pub const ListFilter = struct {
    mime_type: ?[]const u8 = null,
    artifact_id_prefix: ?[]const u8 = null,
};

pub const EvictionPolicy = struct {
    max_total_bytes: ?u64 = null,
    older_than_ms: ?i64 = null,
    now_ms: ?i64 = null,
};

pub const ReadResult = struct {
    content: []u8,
    reference: ai_types.ArtifactReference,

    pub fn deinit(self: *ReadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        self.reference.deinit(allocator);
        self.* = undefined;
    }
};

const Metadata = struct {
    artifact_id: []const u8,
    mime_type: []const u8,
    byte_size: u64,
    sha256: []const u8,
    created_at_ms: i64,
    last_accessed_ms: i64,
    description: []const u8 = "",

    fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_id);
        allocator.free(self.mime_type);
        allocator.free(self.sha256);
        allocator.free(self.description);
        self.* = undefined;
    }
};

pub const ArtifactStore = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    max_total_bytes: ?u64 = null,
    entries: std.ArrayList(Metadata) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, max_total_bytes: ?u64) !ArtifactStore {
        const home = try compat.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        const root_path = try std.fs.path.join(allocator, &.{ home, ".makai", "artifacts" });
        errdefer allocator.free(root_path);
        return initWithPathOwned(allocator, root_path, max_total_bytes, true);
    }

    pub fn initWithPath(allocator: std.mem.Allocator, root_path: []const u8, max_total_bytes: ?u64) !ArtifactStore {
        return initWithPathOwned(allocator, try allocator.dupe(u8, root_path), max_total_bytes, true);
    }

    pub fn initInPlace(allocator: std.mem.Allocator, max_total_bytes: ?u64) !ArtifactStore {
        return initWithPathOwned(allocator, try allocator.dupe(u8, "."), max_total_bytes, true);
    }

    fn initWithPathOwned(allocator: std.mem.Allocator, root_path: []const u8, max_total_bytes: ?u64, create_path: bool) !ArtifactStore {
        var store = ArtifactStore{
            .allocator = allocator,
            .root_path = root_path,
            .max_total_bytes = max_total_bytes,
        };
        errdefer store.deinit();

        if (create_path) try compat.fs.createDir(compat.fs.getCwd(), root_path);
        try store.loadIndex();
        if (max_total_bytes) |limit| try store.evictUnlocked(.{ .max_total_bytes = limit });
        return store;
    }

    pub fn deinit(self: *ArtifactStore) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.root_path);
        self.* = undefined;
    }

    pub fn write(self: *ArtifactStore, input: ArtifactInput) !ai_types.ArtifactReference {
        self.mutex.lockUncancelable(defaultIo());
        defer self.mutex.unlock(defaultIo());

        var hex_buf = sha256Hex(input.content);
        const artifact_id = hex_buf[0..];
        const now = nowMillis();

        if (self.max_total_bytes) |limit| {
            if (input.content.len > limit) return error.ArtifactTooLarge;
        }

        const file_path = try self.artifactPath(artifact_id);
        defer self.allocator.free(file_path);
        const had_valid_blob = try blobMatches(file_path, input.content, self.allocator);
        if (!had_valid_blob) {
            try compat.fs.writeFile(compat.fs.getCwd(), file_path, input.content);
        }

        if (self.findIndex(artifact_id)) |idx| {
            const entry = &self.entries.items[idx];
            const old_last_accessed_ms = entry.last_accessed_ms;
            const old_mime_type = entry.mime_type;
            const old_description = entry.description;
            const new_mime_type = try self.allocator.dupe(u8, input.mime_type);
            var free_new_mime_type = true;
            defer if (free_new_mime_type) self.allocator.free(new_mime_type);
            const new_description = try self.allocator.dupe(u8, input.description);
            var free_new_description = true;
            defer if (free_new_description) self.allocator.free(new_description);

            entry.last_accessed_ms = now;
            entry.mime_type = new_mime_type;
            entry.description = new_description;

            self.persistIndex() catch |err| {
                entry.last_accessed_ms = old_last_accessed_ms;
                entry.mime_type = old_mime_type;
                entry.description = old_description;
                if (!had_valid_blob) deleteFileIfExists(file_path);
                return err;
            };

            free_new_mime_type = false;
            free_new_description = false;
            self.allocator.free(old_mime_type);
            self.allocator.free(old_description);
        } else {
            const entry_artifact_id = try self.allocator.dupe(u8, artifact_id);
            errdefer self.allocator.free(entry_artifact_id);
            const entry_mime_type = try self.allocator.dupe(u8, input.mime_type);
            errdefer self.allocator.free(entry_mime_type);
            const entry_sha256 = try self.allocator.dupe(u8, artifact_id);
            errdefer self.allocator.free(entry_sha256);
            const entry_description = try self.allocator.dupe(u8, input.description);
            errdefer self.allocator.free(entry_description);

            try self.entries.append(self.allocator, .{
                .artifact_id = entry_artifact_id,
                .mime_type = entry_mime_type,
                .byte_size = @intCast(input.content.len),
                .sha256 = entry_sha256,
                .created_at_ms = now,
                .last_accessed_ms = now,
                .description = entry_description,
            });

            self.persistIndex() catch |err| {
                var removed = self.entries.orderedRemove(self.entries.items.len - 1);
                removed.deinit(self.allocator);
                if (!had_valid_blob) deleteFileIfExists(file_path);
                return err;
            };
        }

        if (self.max_total_bytes) |limit| try self.evictUnlocked(.{ .max_total_bytes = limit });

        return self.referenceFor(artifact_id);
    }

    pub fn read(self: *ArtifactStore, artifact_id: []const u8) !ReadResult {
        self.mutex.lockUncancelable(defaultIo());
        defer self.mutex.unlock(defaultIo());

        const idx = self.findIndex(artifact_id) orelse return error.ArtifactNotFound;
        const file_path = try self.artifactPath(artifact_id);
        defer self.allocator.free(file_path);
        const byte_size = std.math.cast(usize, self.entries.items[idx].byte_size) orelse return error.FileTooBig;
        const max_bytes = std.math.add(usize, byte_size, 1) catch return error.FileTooBig;
        const content = compat.fs.readFileAlloc(self.allocator, compat.fs.getCwd(), file_path, max_bytes) catch |err| switch (err) {
            error.FileNotFound => return error.ArtifactNotFound,
            else => return err,
        };
        errdefer self.allocator.free(content);
        if (content.len != byte_size or !contentMatchesArtifactId(content, artifact_id)) return error.ArtifactCorrupt;

        const reference = try self.referenceFor(artifact_id);
        errdefer reference.deinit(self.allocator);

        self.entries.items[idx].last_accessed_ms = nowMillis();
        self.persistIndex() catch {};

        return .{
            .content = content,
            .reference = reference,
        };
    }

    pub fn list(self: *ArtifactStore, filter: ListFilter) ![]StoredArtifact {
        self.mutex.lockUncancelable(defaultIo());
        defer self.mutex.unlock(defaultIo());

        var out: std.ArrayList(StoredArtifact) = .empty;
        errdefer {
            for (out.items) |*item| item.deinit(self.allocator);
            out.deinit(self.allocator);
        }

        for (self.entries.items) |entry| {
            if (filter.mime_type) |mime| {
                if (!std.mem.eql(u8, entry.mime_type, mime)) continue;
            }
            if (filter.artifact_id_prefix) |prefix| {
                if (!std.mem.startsWith(u8, entry.artifact_id, prefix)) continue;
            }
            try out.append(self.allocator, try cloneStoredArtifact(self.allocator, entry));
        }

        return out.toOwnedSlice(self.allocator);
    }

    pub fn freeList(self: *ArtifactStore, artifacts: []StoredArtifact) void {
        for (artifacts) |*artifact| artifact.deinit(self.allocator);
        self.allocator.free(artifacts);
    }

    pub fn evict(self: *ArtifactStore, policy: EvictionPolicy) !void {
        self.mutex.lockUncancelable(defaultIo());
        defer self.mutex.unlock(defaultIo());
        try self.evictUnlocked(policy);
    }

    fn loadIndex(self: *ArtifactStore) !void {
        const path = try self.indexPath(index_file_name);
        defer self.allocator.free(path);
        const data = compat.fs.readFileAlloc(self.allocator, compat.fs.getCwd(), path, 1024 * 1024 * 16) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(data);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();
        const array = switch (parsed.value) {
            .array => |items| items,
            else => return error.InvalidArtifactIndex,
        };

        for (array.items) |item| {
            const obj = switch (item) {
                .object => |object| object,
                else => return error.InvalidArtifactIndex,
            };
            const artifact_id_value = try requiredString(obj, "artifact_id");
            if (!isValidArtifactId(artifact_id_value)) return error.InvalidArtifactIndex;
            if (self.findIndex(artifact_id_value) != null) return error.InvalidArtifactIndex;
            const sha256_value = try requiredString(obj, "sha256");
            if (!std.mem.eql(u8, artifact_id_value, sha256_value)) return error.InvalidArtifactIndex;

            const entry_artifact_id = try self.allocator.dupe(u8, artifact_id_value);
            errdefer self.allocator.free(entry_artifact_id);
            const entry_mime_type = try self.allocator.dupe(u8, try requiredString(obj, "mime_type"));
            errdefer self.allocator.free(entry_mime_type);
            const entry_sha256 = try self.allocator.dupe(u8, sha256_value);
            errdefer self.allocator.free(entry_sha256);
            const entry_description = try self.allocator.dupe(u8, optionalString(obj, "description") orelse "");
            errdefer self.allocator.free(entry_description);

            try self.entries.append(self.allocator, .{
                .artifact_id = entry_artifact_id,
                .mime_type = entry_mime_type,
                .byte_size = try requiredU64(obj, "byte_size"),
                .sha256 = entry_sha256,
                .created_at_ms = try requiredI64(obj, "created_at_ms"),
                .last_accessed_ms = try requiredI64(obj, "last_accessed_ms"),
                .description = entry_description,
            });
        }
    }

    fn persistIndex(self: *ArtifactStore) !void {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(self.allocator);
        var writer = json_writer.JsonWriter.init(&buffer, self.allocator);
        try writer.beginArray();
        for (self.entries.items) |entry| {
            try writer.beginObject();
            try writer.writeStringField("artifact_id", entry.artifact_id);
            try writer.writeStringField("mime_type", entry.mime_type);
            try writer.writeIntField("byte_size", entry.byte_size);
            try writer.writeStringField("sha256", entry.sha256);
            try writer.writeIntField("created_at_ms", entry.created_at_ms);
            try writer.writeIntField("last_accessed_ms", entry.last_accessed_ms);
            if (entry.description.len > 0) try writer.writeStringField("description", entry.description);
            try writer.endObject();
        }
        try writer.endArray();

        const target_path = try self.indexPath(index_file_name);
        defer self.allocator.free(target_path);
        const tmp_path = try self.indexPath(index_tmp_file_name);
        defer self.allocator.free(tmp_path);
        try compat.fs.atomicReplace(compat.fs.getCwd(), target_path, tmp_path, buffer.items);
        buffer.deinit(self.allocator);
    }

    fn evictUnlocked(self: *ArtifactStore, policy: EvictionPolicy) !void {
        var remove_indexes: std.ArrayList(usize) = .empty;
        defer remove_indexes.deinit(self.allocator);

        if (policy.older_than_ms) |age| {
            const now = policy.now_ms orelse nowMillis();
            for (self.entries.items, 0..) |entry, i| {
                if (isOlderThan(entry.last_accessed_ms, now, age)) try remove_indexes.append(self.allocator, i);
            }
        }

        if (policy.max_total_bytes) |limit| {
            while (try totalBytesAfterRemoving(self.entries.items, remove_indexes.items) > limit and remove_indexes.items.len < self.entries.items.len) {
                const idx = oldestIndexExcluding(self.entries.items, remove_indexes.items);
                try remove_indexes.append(self.allocator, idx);
            }
        }

        if (remove_indexes.items.len == 0) return;
        sortIndexesDescending(remove_indexes.items);

        var removed_entries: std.ArrayList(Metadata) = .empty;
        errdefer {
            for (removed_entries.items) |*entry| entry.deinit(self.allocator);
            removed_entries.deinit(self.allocator);
        }

        for (remove_indexes.items) |idx| {
            try removed_entries.append(self.allocator, self.entries.orderedRemove(idx));
        }

        self.persistIndex() catch |err| {
            var i = removed_entries.items.len;
            while (i > 0) {
                i -= 1;
                const entry = removed_entries.orderedRemove(i);
                try self.entries.insert(self.allocator, remove_indexes.items[i], entry);
            }
            return err;
        };

        for (removed_entries.items) |entry| {
            const path = try self.artifactPath(entry.artifact_id);
            defer self.allocator.free(path);
            deleteFileIfExists(path);
        }
        for (removed_entries.items) |*entry| entry.deinit(self.allocator);
        removed_entries.deinit(self.allocator);
    }

    fn artifactPath(self: *ArtifactStore, artifact_id: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root_path, artifact_id });
    }

    fn indexPath(self: *ArtifactStore, file_name: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root_path, file_name });
    }

    fn findIndex(self: *const ArtifactStore, artifact_id: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.artifact_id, artifact_id)) return i;
        }
        return null;
    }

    fn referenceFor(self: *ArtifactStore, artifact_id: []const u8) !ai_types.ArtifactReference {
        const idx = self.findIndex(artifact_id) orelse return error.ArtifactNotFound;
        const entry = self.entries.items[idx];
        var reference = ai_types.ArtifactReference{
            .artifact_id = try self.allocator.dupe(u8, entry.artifact_id),
            .byte_size = entry.byte_size,
        };
        errdefer reference.deinit(self.allocator);

        reference.uri = OwnedSlice(u8).initOwned(try std.mem.concat(self.allocator, u8, &.{ uri_prefix, entry.artifact_id }));
        reference.mime_type = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, entry.mime_type));
        reference.sha256 = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, entry.sha256));
        reference.description = OwnedSlice(u8).initOwned(try self.allocator.dupe(u8, entry.description));
        return reference;
    }
};

fn cloneStoredArtifact(allocator: std.mem.Allocator, entry: Metadata) !StoredArtifact {
    const artifact_id = try allocator.dupe(u8, entry.artifact_id);
    errdefer allocator.free(artifact_id);
    const mime_type = try allocator.dupe(u8, entry.mime_type);
    errdefer allocator.free(mime_type);
    const sha256 = try allocator.dupe(u8, entry.sha256);
    errdefer allocator.free(sha256);
    const description = try allocator.dupe(u8, entry.description);
    errdefer allocator.free(description);

    return .{
        .artifact_id = artifact_id,
        .mime_type = mime_type,
        .byte_size = entry.byte_size,
        .sha256 = sha256,
        .created_at_ms = entry.created_at_ms,
        .last_accessed_ms = entry.last_accessed_ms,
        .description = description,
    };
}

fn blobMatches(path: []const u8, content: []const u8, allocator: std.mem.Allocator) !bool {
    const max_bytes = std.math.add(usize, content.len, 1) catch return error.FileTooBig;
    const existing = compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), path, max_bytes) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.StreamTooLong => return false,
        else => return err,
    };
    defer allocator.free(existing);
    return std.mem.eql(u8, existing, content);
}

fn contentMatchesArtifactId(content: []const u8, artifact_id: []const u8) bool {
    var hex_buf = sha256Hex(content);
    return std.mem.eql(u8, hex_buf[0..], artifact_id);
}

fn totalBytesAfterRemoving(entries: []const Metadata, remove_indexes: []const usize) !u64 {
    var total: u64 = 0;
    for (entries, 0..) |entry, i| {
        if (containsIndex(remove_indexes, i)) continue;
        total = try std.math.add(u64, total, entry.byte_size);
    }
    return total;
}

fn oldestIndexExcluding(entries: []const Metadata, exclude_indexes: []const usize) usize {
    var idx: ?usize = null;
    for (entries, 0..) |entry, i| {
        if (containsIndex(exclude_indexes, i)) continue;
        if (idx == null or entry.last_accessed_ms < entries[idx.?].last_accessed_ms) idx = i;
    }
    return idx.?;
}

fn containsIndex(indexes: []const usize, idx: usize) bool {
    for (indexes) |candidate| {
        if (candidate == idx) return true;
    }
    return false;
}

fn sortIndexesDescending(indexes: []usize) void {
    var i: usize = 1;
    while (i < indexes.len) : (i += 1) {
        const value = indexes[i];
        var j = i;
        while (j > 0 and indexes[j - 1] < value) : (j -= 1) {
            indexes[j] = indexes[j - 1];
        }
        indexes[j] = value;
    }
}

fn deleteFileIfExists(path: []const u8) void {
    compat.fs.getCwd().deleteFile(defaultIo(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}

fn isOlderThan(last_accessed_ms: i64, now_ms: i64, age_ms: i64) bool {
    if (age_ms < 0) return false;
    if (last_accessed_ms > now_ms) return false;
    const threshold = std.math.sub(i64, now_ms, age_ms) catch return true;
    return last_accessed_ms < threshold;
}

fn nowMillis() i64 {
    return compat.time.nowMillis();
}

fn isValidArtifactId(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |ch| {
        switch (ch) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        }
    }
    return true;
}

fn requiredString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.InvalidArtifactIndex;
    return switch (value) {
        .string => |s| s,
        else => error.InvalidArtifactIndex,
    };
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn requiredU64(obj: std.json.ObjectMap, key: []const u8) !u64 {
    const value = obj.get(key) orelse return error.InvalidArtifactIndex;
    return switch (value) {
        .integer => |n| std.math.cast(u64, n) orelse error.InvalidArtifactIndex,
        else => error.InvalidArtifactIndex,
    };
}

fn requiredI64(obj: std.json.ObjectMap, key: []const u8) !i64 {
    const value = obj.get(key) orelse return error.InvalidArtifactIndex;
    return switch (value) {
        .integer => |n| std.math.cast(i64, n) orelse error.InvalidArtifactIndex,
        else => error.InvalidArtifactIndex,
    };
}

fn expectSha256Hex(content: []const u8, expected: []const u8) !void {
    var hex_buf = sha256Hex(content);
    try std.testing.expectEqualStrings(expected, hex_buf[0..]);
}

fn tmpStore(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, max_total_bytes: ?u64) !ArtifactStore {
    const root_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "artifacts" });
    errdefer allocator.free(root_path);
    try compat.fs.createDir(compat.fs.getCwd(), root_path);
    return ArtifactStore{
        .allocator = allocator,
        .root_path = root_path,
        .max_total_bytes = max_total_bytes,
    };
}

test "artifact store writes and reads content" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, null);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var reference = try store.write(.{ .content = "hello artifact", .mime_type = "text/plain" });
    defer reference.deinit(allocator);

    var result = try store.read(reference.artifact_id);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("hello artifact", result.content);
    try std.testing.expectEqualStrings("text/plain", result.reference.getMimeType().?);
}

test "artifact store deduplicates same content" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, null);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var first = try store.write(.{ .content = "same blob", .mime_type = "text/plain" });
    defer first.deinit(allocator);
    var second = try store.write(.{ .content = "same blob", .mime_type = "text/plain" });
    defer second.deinit(allocator);

    try std.testing.expectEqualStrings(first.artifact_id, second.artifact_id);
    const artifacts = try store.list(.{});
    defer store.freeList(artifacts);
    try std.testing.expectEqual(@as(usize, 1), artifacts.len);
}

test "artifact store reference has sha256 byte size and mime type" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, null);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var reference = try store.write(.{ .content = "abc", .mime_type = "text/plain" });
    defer reference.deinit(allocator);

    try std.testing.expectEqual(@as(?u64, 3), reference.byte_size);
    try std.testing.expectEqualStrings("text/plain", reference.getMimeType().?);
    try expectSha256Hex("abc", reference.getSha256().?);
    try std.testing.expectEqualStrings(reference.artifact_id, reference.getSha256().?);
}

test "artifact store evicts oldest when size limit exceeded" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, 8);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var first = try store.write(.{ .content = "12345", .mime_type = "text/plain" });
    defer first.deinit(allocator);
    store.entries.items[0].last_accessed_ms = 1;

    var second = try store.write(.{ .content = "abcde", .mime_type = "text/plain" });
    defer second.deinit(allocator);

    try std.testing.expectError(error.ArtifactNotFound, store.read(first.artifact_id));
    var result = try store.read(second.artifact_id);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("abcde", result.content);
}

test "artifact store rejects oversized write without evicting existing artifact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, 5);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var existing = try store.write(.{ .content = "12345", .mime_type = "text/plain" });
    defer existing.deinit(allocator);

    try std.testing.expectError(error.ArtifactTooLarge, store.write(.{ .content = "123456", .mime_type = "text/plain" }));

    var result = try store.read(existing.artifact_id);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("12345", result.content);
}

test "artifact store dedup metadata update allocates before swapping" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, null);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var first = try store.write(.{ .content = "same blob", .mime_type = "text/plain", .description = "old" });
    defer first.deinit(allocator);
    var second = try store.write(.{ .content = "same blob", .mime_type = "application/json", .description = "new" });
    defer second.deinit(allocator);

    const artifacts = try store.list(.{});
    defer store.freeList(artifacts);
    try std.testing.expectEqual(@as(usize, 1), artifacts.len);
    try std.testing.expectEqualStrings("application/json", artifacts[0].mime_type);
    try std.testing.expectEqualStrings("new", artifacts[0].description);
}

test "artifact store rewrites corrupt existing blob" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, null);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var hex_buf = sha256Hex("correct");
    const artifact_id = hex_buf[0..];
    const path = try store.artifactPath(artifact_id);
    defer allocator.free(path);
    try compat.fs.writeFile(compat.fs.getCwd(), path, "wrong");

    var reference = try store.write(.{ .content = "correct", .mime_type = "text/plain" });
    defer reference.deinit(allocator);

    var result = try store.read(reference.artifact_id);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("correct", result.content);
}

test "artifact store read rejects corrupt or missing blobs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, null);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var reference = try store.write(.{ .content = "original", .mime_type = "text/plain" });
    defer reference.deinit(allocator);
    const path = try store.artifactPath(reference.artifact_id);
    defer allocator.free(path);

    try compat.fs.writeFile(compat.fs.getCwd(), path, "trunc");
    try std.testing.expectError(error.ArtifactCorrupt, store.read(reference.artifact_id));

    deleteFileIfExists(path);
    try std.testing.expectError(error.ArtifactNotFound, store.read(reference.artifact_id));
}

test "artifact store rewrites oversized existing blob" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, null);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var hex_buf = sha256Hex("small");
    const artifact_id = hex_buf[0..];
    const path = try store.artifactPath(artifact_id);
    defer allocator.free(path);
    try compat.fs.writeFile(compat.fs.getCwd(), path, "small but with poison suffix");

    var reference = try store.write(.{ .content = "small", .mime_type = "text/plain" });
    defer reference.deinit(allocator);

    var result = try store.read(reference.artifact_id);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("small", result.content);
}

test "artifact store rejects duplicate artifact ids in index" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, null);
    const root_path = try allocator.dupe(u8, store.root_path);
    defer allocator.free(root_path);
    defer tmp.cleanup();

    var reference = try store.write(.{ .content = "duplicate", .mime_type = "text/plain" });
    defer reference.deinit(allocator);
    store.deinit();

    const index_path = try std.fs.path.join(allocator, &.{ root_path, index_file_name });
    defer allocator.free(index_path);
    const original = try compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), index_path, 1024 * 1024);
    defer allocator.free(original);
    const duplicate = try std.mem.concat(allocator, u8, &.{ "[", original[1 .. original.len - 1], ",", original[1 .. original.len - 1], "]" });
    defer allocator.free(duplicate);
    try compat.fs.writeFile(compat.fs.getCwd(), index_path, duplicate);

    try std.testing.expectError(error.InvalidArtifactIndex, ArtifactStore.initWithPath(allocator, root_path, null));
}

test "artifact store age eviction handles overflow safely" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, null);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    var future = try store.write(.{ .content = "future", .mime_type = "text/plain" });
    defer future.deinit(allocator);
    store.entries.items[0].last_accessed_ms = std.math.maxInt(i64);

    try store.evict(.{ .older_than_ms = 1, .now_ms = std.math.minInt(i64) });

    var result = try store.read(future.artifact_id);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("future", result.content);
}

test "artifact store middleware stores large output reference" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});

    var store = try tmpStore(allocator, &tmp, null);
    defer {
        store.deinit();
        tmp.cleanup();
    }

    const raw_output = "raw log line 1\nraw log line 2\nraw log line 3";
    var reference = try store.write(.{
        .content = raw_output,
        .mime_type = "text/plain",
        .description = "raw tool output",
    });
    errdefer reference.deinit(allocator);

    const artifacts = try allocator.alloc(ai_types.ArtifactReference, 1);
    artifacts[0] = reference;

    const summary = try allocator.alloc(ai_types.UserContentPart, 1);
    summary[0] = .{ .text = .{ .text = try allocator.dupe(u8, "3 raw log lines stored as artifact") } };

    var tool_result = ai_types.ToolResultMessage{
        .tool_call_id = try allocator.dupe(u8, "call_1"),
        .tool_name = try allocator.dupe(u8, "shell"),
        .content = summary,
        .artifacts = OwnedSlice(ai_types.ArtifactReference).initOwned(artifacts),
        .is_error = false,
        .timestamp = nowMillis(),
    };
    defer tool_result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tool_result.artifacts.slice().len);
    try std.testing.expectEqualStrings("text/plain", tool_result.artifacts.slice()[0].getMimeType().?);

    var stored = try store.read(tool_result.artifacts.slice()[0].artifact_id);
    defer stored.deinit(allocator);
    try std.testing.expectEqualStrings(raw_output, stored.content);
}
