
const std = @import("std");
const keyboard = @import("../input/keyboard.zig");
const mouse = @import("../input/mouse.zig");

pub const Key = keyboard.KeyEvent;

pub const Mouse = mouse.MouseEvent;

pub const WindowSize = struct {
    width: u16,
    height: u16,
};

pub const Tick = struct {
    timestamp: i64,
    delta: u64,
};

pub const Focus = enum {
    gained,
    lost,
};

pub const Batch = struct {
    messages: []const SystemMsg,
};

pub const SystemMsg = union(enum) {
    key: Key,
    mouse: Mouse,
    window_size: WindowSize,
    tick: Tick,
    focus: Focus,
    batch: Batch,
    none,

    pub fn isQuit(self: SystemMsg) bool {
        return switch (self) {
            .key => |k| k.key == .{ .char = 'c' } and k.modifiers.ctrl,
            else => false,
        };
    }
};

pub fn keyToChar(key: Key) ?u21 {
    return key.key.toChar();
}

pub fn isChar(key: Key, c: u21) bool {
    return switch (key.key) {
        .char => |ch| ch == c and !key.modifiers.any(),
        else => false,
    };
}

pub fn isCtrl(key: Key, c: u21) bool {
    return switch (key.key) {
        .char => |ch| ch == c and key.modifiers.ctrl and !key.modifiers.alt and !key.modifiers.shift,
        else => false,
    };
}

pub fn isAlt(key: Key, c: u21) bool {
    return switch (key.key) {
        .char => |ch| ch == c and key.modifiers.alt and !key.modifiers.ctrl and !key.modifiers.shift,
        else => false,
    };
}
