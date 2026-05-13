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

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (!@import("builtin").is_test) {
        if (std.mem.eql(u8, name, "HOME")) {
            if (std.Io.Threaded.global_single_threaded.environString("HOME")) |value| {
                return allocator.dupe(u8, value);
            }
        }
    }
    return std.process.Environ.getAlloc(runtimeEnviron(), allocator, name);
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
