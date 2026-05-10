//! Compatibility seams for the Zig 0.15.2 -> 0.16.0 migration.
//!
//! These modules intentionally expose Makai-owned wrapper boundaries, not raw
//! `std.Io`, matching `docs/zig-0.16.0-io-architecture-decision.md`.
//! Current implementations are thin Zig 0.15.2-compatible pass-throughs; later
//! migration PRs will remap internals to Zig 0.16 `std.Io.Threaded`/default
//! context plumbing without changing these stable names unnecessarily.
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

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, allocator, name);
}

test {
    _ = time;
    _ = random;
    _ = fs;
    _ = stdio;
    _ = http;
    _ = net;
}
