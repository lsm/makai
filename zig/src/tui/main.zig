const std = @import("std");
const app = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    try app.run(init);
}

test {
    std.testing.refAllDecls(@This());
}
