
const std = @import("std");
const keys = @import("../input/keys.zig");
const style_mod = @import("../style/style.zig");
const border_mod = @import("../style/border.zig");
const Color = @import("../style/color.zig").Color;

pub fn isFocusable(comptime T: type) bool {
    return @hasField(T, "focused") and
        @hasDecl(T, "focus") and
        @hasDecl(T, "blur");
}

const max_binds = 4;

pub const KeyBind = struct {
    key: keys.Key,
    modifiers: keys.Modifiers = .{},

    pub fn matches(self: KeyBind, event: keys.KeyEvent) bool {
        return self.key.eql(event.key) and self.modifiers.eql(event.modifiers);
    }
};

pub const default_next_keys = [max_binds]?KeyBind{
    .{ .key = .tab },
    null,
    null,
    null,
};

pub const default_prev_keys = [max_binds]?KeyBind{
    .{ .key = .tab, .modifiers = .{ .shift = true } },
    null,
    null,
    null,
};

pub fn FocusGroup(comptime max_items: usize) type {
    return struct {
        const Self = @This();

        pub const FocusItem = struct {
            focus_fn: *const fn (*anyopaque) void,
            blur_fn: *const fn (*anyopaque) void,
            is_focused_fn: *const fn (*const anyopaque) bool,
            ptr: *anyopaque,
        };

        items: [max_items]?FocusItem = @splat(null),
        count: usize = 0,
        active: usize = 0,
        wrap: bool = true,
        next_keys: [max_binds]?KeyBind = default_next_keys,
        prev_keys: [max_binds]?KeyBind = default_prev_keys,

        pub fn add(self: *Self, item_ptr: anytype) void {
            const Ptr = @TypeOf(item_ptr);
            const T = @typeInfo(Ptr).pointer.child;

            comptime {
                if (!@hasField(T, "focused"))
                    @compileError("FocusGroup item must have a 'focused: bool' field. " ++
                        "Type '" ++ @typeName(T) ++ "' does not satisfy the focusable protocol.");
                if (!@hasDecl(T, "focus"))
                    @compileError("FocusGroup item must have a 'pub fn focus(*Self) void' method. " ++
                        "Type '" ++ @typeName(T) ++ "' does not satisfy the focusable protocol.");
                if (!@hasDecl(T, "blur"))
                    @compileError("FocusGroup item must have a 'pub fn blur(*Self) void' method. " ++
                        "Type '" ++ @typeName(T) ++ "' does not satisfy the focusable protocol.");
            }

            if (self.count >= max_items) return;

            self.items[self.count] = .{
                .focus_fn = @ptrCast(&struct {
                    fn call(raw_ptr: *anyopaque) void {
                        const ptr: *T = @ptrCast(@alignCast(raw_ptr));
                        ptr.focus();
                    }
                }.call),
                .blur_fn = @ptrCast(&struct {
                    fn call(raw_ptr: *anyopaque) void {
                        const ptr: *T = @ptrCast(@alignCast(raw_ptr));
                        ptr.blur();
                    }
                }.call),
                .is_focused_fn = @ptrCast(&struct {
                    fn call(raw_ptr: *const anyopaque) bool {
                        const ptr: *const T = @ptrCast(@alignCast(raw_ptr));
                        return ptr.focused;
                    }
                }.call),
                .ptr = @ptrCast(item_ptr),
            };
            self.count += 1;
        }

        pub fn focusAt(self: *Self, index: usize) void {
            if (index >= self.count) return;
            for (0..self.count) |i| {
                if (self.items[i]) |item| {
                    if (i == index) {
                        item.focus_fn(item.ptr);
                    } else {
                        item.blur_fn(item.ptr);
                    }
                }
            }
            self.active = index;
        }

        pub fn focusNext(self: *Self) void {
            if (self.count == 0) return;
            if (self.active + 1 < self.count) {
                self.focusAt(self.active + 1);
            } else if (self.wrap) {
                self.focusAt(0);
            }
        }

        pub fn focusPrev(self: *Self) void {
            if (self.count == 0) return;
            if (self.active > 0) {
                self.focusAt(self.active - 1);
            } else if (self.wrap) {
                self.focusAt(self.count - 1);
            }
        }

        pub fn handleKey(self: *Self, key: keys.KeyEvent) bool {
            for (self.next_keys) |maybe_bind| {
                if (maybe_bind) |bind| {
                    if (bind.matches(key)) {
                        self.focusNext();
                        return true;
                    }
                }
            }
            for (self.prev_keys) |maybe_bind| {
                if (maybe_bind) |bind| {
                    if (bind.matches(key)) {
                        self.focusPrev();
                        return true;
                    }
                }
            }
            return false;
        }

        pub fn addNextKey(self: *Self, bind: KeyBind) bool {
            for (&self.next_keys) |*slot| {
                if (slot.* == null) {
                    slot.* = bind;
                    return true;
                }
            }
            return false;
        }

        pub fn addPrevKey(self: *Self, bind: KeyBind) bool {
            for (&self.prev_keys) |*slot| {
                if (slot.* == null) {
                    slot.* = bind;
                    return true;
                }
            }
            return false;
        }

        pub fn setNextKey(self: *Self, bind: KeyBind) void {
            self.next_keys = .{ bind, null, null, null };
        }

        pub fn setPrevKey(self: *Self, bind: KeyBind) void {
            self.prev_keys = .{ bind, null, null, null };
        }

        pub fn clearNextKeys(self: *Self) void {
            self.next_keys = .{ null, null, null, null };
        }

        pub fn clearPrevKeys(self: *Self) void {
            self.prev_keys = .{ null, null, null, null };
        }

        pub fn focused(self: *const Self) usize {
            return self.active;
        }

        pub fn isFocused(self: *const Self, index: usize) bool {
            return self.active == index;
        }

        pub fn initFocus(self: *Self) void {
            if (self.count > 0) {
                self.focusAt(0);
            }
        }

        pub fn blurAll(self: *Self) void {
            for (0..self.count) |i| {
                if (self.items[i]) |item| {
                    item.blur_fn(item.ptr);
                }
            }
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }
    };
}

pub const FocusStyle = struct {
    focused_border_fg: Color = .cyan,
    blurred_border_fg: Color = .gray(12),
    border_chars: border_mod.BorderChars = .rounded,

    pub fn apply(self: FocusStyle, base: style_mod.Style, is_focused: bool) style_mod.Style {
        var s = base;
        s = s.borderAll(self.border_chars);
        if (is_focused) {
            s = s.borderForeground(self.focused_border_fg);
        } else {
            s = s.borderForeground(self.blurred_border_fg);
        }
        return s;
    }
};

test "isFocusable positive" {
    const Focusable = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };
    try std.testing.expect(isFocusable(Focusable));
}

test "isFocusable negative — missing field" {
    const NotFocusable = struct {
        pub fn focus(_: *@This()) void {}
        pub fn blur(_: *@This()) void {}
    };
    try std.testing.expect(!isFocusable(NotFocusable));
}

test "isFocusable negative — missing method" {
    const NotFocusable = struct {
        focused: bool = false,
        pub fn focus(_: *@This()) void {}
    };
    try std.testing.expect(!isFocusable(NotFocusable));
}

test "FocusGroup — basic cycling" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};
    var c = Item{};

    var fg: FocusGroup(3) = .{};
    fg.add(&a);
    fg.add(&b);
    fg.add(&c);
    fg.initFocus();

    try std.testing.expect(a.focused);
    try std.testing.expect(!b.focused);
    try std.testing.expect(!c.focused);
    try std.testing.expectEqual(@as(usize, 0), fg.focused());

    fg.focusNext();
    try std.testing.expect(!a.focused);
    try std.testing.expect(b.focused);
    try std.testing.expect(!c.focused);
    try std.testing.expectEqual(@as(usize, 1), fg.focused());

    fg.focusNext();
    try std.testing.expectEqual(@as(usize, 2), fg.focused());
    try std.testing.expect(c.focused);

    fg.focusNext();
    try std.testing.expectEqual(@as(usize, 0), fg.focused());
    try std.testing.expect(a.focused);
    try std.testing.expect(!c.focused);
}

test "FocusGroup — prev cycling" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};

    var fg: FocusGroup(2) = .{};
    fg.add(&a);
    fg.add(&b);
    fg.initFocus();

    fg.focusPrev();
    try std.testing.expectEqual(@as(usize, 1), fg.focused());
    try std.testing.expect(b.focused);
    try std.testing.expect(!a.focused);

    fg.focusPrev();
    try std.testing.expectEqual(@as(usize, 0), fg.focused());
    try std.testing.expect(a.focused);
}

test "FocusGroup — no wrap" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};

    var fg: FocusGroup(2) = .{ .wrap = false };
    fg.add(&a);
    fg.add(&b);
    fg.initFocus();

    fg.focusPrev();
    try std.testing.expectEqual(@as(usize, 0), fg.focused());

    fg.focusAt(1);
    fg.focusNext();
    try std.testing.expectEqual(@as(usize, 1), fg.focused());
}

test "FocusGroup — handleKey Tab" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};

    var fg: FocusGroup(2) = .{};
    fg.add(&a);
    fg.add(&b);
    fg.initFocus();

    const tab_event = keys.KeyEvent{ .key = .tab, .modifiers = .{} };
    const consumed = fg.handleKey(tab_event);
    try std.testing.expect(consumed);
    try std.testing.expectEqual(@as(usize, 1), fg.focused());

    const shift_tab = keys.KeyEvent{ .key = .tab, .modifiers = .{ .shift = true } };
    const consumed2 = fg.handleKey(shift_tab);
    try std.testing.expect(consumed2);
    try std.testing.expectEqual(@as(usize, 0), fg.focused());

    const other = keys.KeyEvent{ .key = .{ .char = 'a' }, .modifiers = .{} };
    const consumed3 = fg.handleKey(other);
    try std.testing.expect(!consumed3);
}

test "FocusGroup — focusAt and isFocused" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};
    var c = Item{};

    var fg: FocusGroup(3) = .{};
    fg.add(&a);
    fg.add(&b);
    fg.add(&c);

    fg.focusAt(2);
    try std.testing.expect(!fg.isFocused(0));
    try std.testing.expect(!fg.isFocused(1));
    try std.testing.expect(fg.isFocused(2));
    try std.testing.expect(!a.focused);
    try std.testing.expect(!b.focused);
    try std.testing.expect(c.focused);
}

test "FocusGroup — blurAll" {
    const Item = struct {
        focused: bool = false,
        pub fn focus(self: *@This()) void {
            self.focused = true;
        }
        pub fn blur(self: *@This()) void {
            self.focused = false;
        }
    };

    var a = Item{};
    var b = Item{};

    var fg: FocusGroup(2) = .{};
    fg.add(&a);
    fg.add(&b);
    fg.initFocus();
    try std.testing.expect(a.focused);

    fg.blurAll();
    try std.testing.expect(!a.focused);
    try std.testing.expect(!b.focused);
}
