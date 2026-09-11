
const std = @import("std");

pub const time = @import("time.zig");
pub const random = @import("random.zig");
pub const fs = @import("fs.zig");
pub const stdio = @import("stdio.zig");
pub const http = @import("http.zig");
pub const net = @import("net.zig");

fn runtimeEnviron() std.process.Environ {
    const builtin = @import("builtin");
    if (builtin.is_test) {
        return std.testing.environ;
    }

    const Block = std.process.Environ.Block;
    if (@hasField(Block, "use_global")) {
        return .{ .block = .global };
    }

    if (!builtin.link_libc) {
        return .empty;
    }

    const c_environ = std.c.environ;
    var env_count: usize = 0;
    while (c_environ[env_count] != null) : (env_count += 1) {}
    return .{ .block = .{ .slice = @ptrCast(c_environ[0..env_count :null]) } };
}

const environ_scan_has_home = @hasField(std.Io.Threaded.Environ.String, "HOME");

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const builtin = @import("builtin");
    if (!builtin.is_test and std.mem.eql(u8, name, "HOME")) {
        if (comptime environ_scan_has_home) {
            if (std.Io.Threaded.global_single_threaded.environString("HOME")) |value| {
                return allocator.dupe(u8, value);
            }
        }
        if (builtin.os.tag == .windows) {
            if (getWindowsHomeDir(allocator)) |home| {
                return home;
            } else |err| switch (err) {
                error.EnvironmentVariableMissing => {},
                else => return err,
            }
        }
    }
    return std.process.Environ.getAlloc(runtimeEnviron(), allocator, name);
}

fn getWindowsHomeDir(allocator: std.mem.Allocator) ![]u8 {
    return getHomeDirFromEnviron(allocator, runtimeEnviron());
}

fn getHomeDirFromEnviron(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    if (std.process.Environ.getAlloc(environ, allocator, "USERPROFILE")) |value| {
        return value;
    } else |err| switch (err) {
        error.EnvironmentVariableMissing => {},
        else => return err,
    }

    const drive = try std.process.Environ.getAlloc(environ, allocator, "HOMEDRIVE");
    const path = std.process.Environ.getAlloc(environ, allocator, "HOMEPATH") catch |err| {
        allocator.free(drive);
        return err;
    };
    defer allocator.free(drive);
    defer allocator.free(path);
    return std.mem.concat(allocator, u8, &.{ drive, path });
}

pub fn createEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return std.process.Environ.createMap(runtimeEnviron(), allocator);
}

test {
    _ = time;
    _ = random;
    _ = fs;
    _ = stdio;
    _ = http;
    _ = net;
}

test "getEnvVarOwned HOME matches the environ lookup" {
    const allocator = std.testing.allocator;
    const expected = std.process.Environ.getAlloc(std.testing.environ, allocator, "HOME");
    const actual = getEnvVarOwned(allocator, "HOME");
    if (expected) |value| {
        defer allocator.free(value);
        const home = try actual;
        defer allocator.free(home);
        try std.testing.expectEqualStrings(value, home);
    } else |_| {
        try std.testing.expectError(error.EnvironmentVariableMissing, actual);
    }
}

test "windows home resolution prefers USERPROFILE over HOMEDRIVE/HOMEPATH" {
    if (@hasField(std.process.Environ.Block, "slice")) {
        const allocator = std.testing.allocator;
        const entries = [_]?[*:0]const u8{
            "USERPROFILE=C:\\Users\\tester",
            "HOMEDRIVE=D:",
            "HOMEPATH=\\Users\\ignored",
            null,
        };
        const fake: std.process.Environ = .{ .block = .{ .slice = entries[0..3 :null] } };
        const home = try getHomeDirFromEnviron(allocator, fake);
        defer allocator.free(home);
        try std.testing.expectEqualStrings("C:\\Users\\tester", home);
    } else return error.SkipZigTest;
}

test "windows home resolution falls back to HOMEDRIVE ++ HOMEPATH" {
    if (@hasField(std.process.Environ.Block, "slice")) {
        const allocator = std.testing.allocator;
        const entries = [_]?[*:0]const u8{
            "HOMEDRIVE=C:",
            "HOMEPATH=\\Users\\tester",
            null,
        };
        const fake: std.process.Environ = .{ .block = .{ .slice = entries[0..2 :null] } };
        const home = try getHomeDirFromEnviron(allocator, fake);
        defer allocator.free(home);
        try std.testing.expectEqualStrings("C:\\Users\\tester", home);
    } else return error.SkipZigTest;
}

test "windows home resolution fails without USERPROFILE and HOMEDRIVE/HOMEPATH" {
    if (@hasField(std.process.Environ.Block, "slice")) {
        const allocator = std.testing.allocator;
        const empty_entries = [_]?[*:0]const u8{null};
        const empty_env: std.process.Environ = .{ .block = .{ .slice = empty_entries[0..0 :null] } };
        try std.testing.expectError(
            error.EnvironmentVariableMissing,
            getHomeDirFromEnviron(allocator, empty_env),
        );

        const drive_only = [_]?[*:0]const u8{ "HOMEDRIVE=C:", null };
        const drive_env: std.process.Environ = .{ .block = .{ .slice = drive_only[0..1 :null] } };
        try std.testing.expectError(
            error.EnvironmentVariableMissing,
            getHomeDirFromEnviron(allocator, drive_env),
        );
    } else return error.SkipZigTest;
}
