//! Makai-owned I/O compatibility seams for Zig 0.16.0.
//!
//! These modules intentionally expose Makai-owned wrapper boundaries, not raw
//! `std.Io`, matching `docs/zig-0.16.0-io-architecture-decision.md`.
//! Implementations route through the selected Zig 0.16 `std.Io.Threaded`/default
//! context plumbing without forcing callers to thread `std.Io` through Makai
//! public APIs.
//!
//! Names intentionally follow the task's stable helper list where it is more
//! specific than the architecture note's examples (`monotonicNanos`, `sleepNs`,
//! `getCwd`, `resolveAddress`, `tcpListen`). The examples in the architecture
//! decision remain guidance; this skeleton records the concrete names that
//! follow-up PRs will migrate without exposing raw `std.Io`.

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

/// `Io.Threaded`'s memoized environ scan only carries `HOME` on targets whose
/// `Environ.String` struct has the field; Windows and WASI use an empty struct
/// there, so the comptime `environString("HOME")` lookup must stay behind this
/// guard or cross-compiling for Windows fails with "no field named 'HOME'".
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
            // Windows has no HOME convention; resolve the home directory
            // through USERPROFILE, then HOMEDRIVE ++ HOMEPATH. A plain HOME
            // (e.g. set by Git Bash) is still honored as a last resort by
            // the generic lookup below.
            if (getWindowsHomeDir(allocator)) |home| {
                return home;
            } else |_| {}
        }
    }
    return std.process.Environ.getAlloc(runtimeEnviron(), allocator, name);
}

fn getWindowsHomeDir(allocator: std.mem.Allocator) ![]u8 {
    return getHomeDirFromEnviron(allocator, runtimeEnviron());
}

/// Windows home-directory resolution: `USERPROFILE` first, then
/// `HOMEDRIVE` ++ `HOMEPATH` (e.g. "C:" ++ "\Users\name"). Takes the environ
/// explicitly so tests can feed synthetic values on any host.
fn getHomeDirFromEnviron(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    if (std.process.Environ.getAlloc(environ, allocator, "USERPROFILE")) |value| {
        return value;
    } else |_| {}

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

// The remaining tests exercise the Windows home-dir resolution against a
// synthetic environ. The synthetic block below is a POSIX shape, so the test
// bodies live inside a comptime OS guard and skip on Windows/WASI hosts where
// `std.process.Environ.Block` is not a `PosixBlock`.
test "windows home resolution prefers USERPROFILE over HOMEDRIVE/HOMEPATH" {
    if (@import("builtin").os.tag != .windows) {
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
    if (@import("builtin").os.tag != .windows) {
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
    if (@import("builtin").os.tag != .windows) {
        const allocator = std.testing.allocator;
        const empty_entries = [_]?[*:0]const u8{null};
        const empty_env: std.process.Environ = .{ .block = .{ .slice = empty_entries[0..0 :null] } };
        try std.testing.expectError(
            error.EnvironmentVariableMissing,
            getHomeDirFromEnviron(allocator, empty_env),
        );

        // HOMEDRIVE alone must not leak its allocation when HOMEPATH is missing.
        const drive_only = [_]?[*:0]const u8{ "HOMEDRIVE=C:", null };
        const drive_env: std.process.Environ = .{ .block = .{ .slice = drive_only[0..1 :null] } };
        try std.testing.expectError(
            error.EnvironmentVariableMissing,
            getHomeDirFromEnviron(allocator, drive_env),
        );
    } else return error.SkipZigTest;
}
