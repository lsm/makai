
const std = @import("std");
const Writer = std.Io.Writer;
const Context = @import("context.zig").Context;
const keys = @import("../input/keys.zig");
const measure = @import("../layout/measure.zig");
const join = @import("../layout/join.zig");

pub const Action = union(enum) {
    none,
    pop,
    replace: Screen,
    push: Screen,
    quit,
};

pub const HandleResult = enum { none, pushed, popped, replaced, quit };

pub const Screen = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    title: []const u8 = "",
    modal: bool = false,

    pub const VTable = struct {
        update: *const fn (ctx: *anyopaque, msg_ctx: *Context, key: keys.KeyEvent) Action,
        view: *const fn (ctx: *anyopaque, msg_ctx: *const Context, allocator: std.mem.Allocator) anyerror![]const u8,
        deinit: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void = null,
        on_enter: ?*const fn (ctx: *anyopaque, msg_ctx: *Context) void = null,
        on_suspend: ?*const fn (ctx: *anyopaque, msg_ctx: *Context) void = null,
        on_resume: ?*const fn (ctx: *anyopaque, msg_ctx: *Context) void = null,
    };
};

pub const ScreenStack = struct {
    allocator: std.mem.Allocator,
    stack: std.array_list.Managed(Screen),

    pub fn init(allocator: std.mem.Allocator) ScreenStack {
        return .{
            .allocator = allocator,
            .stack = std.array_list.Managed(Screen).init(allocator),
        };
    }

    pub fn deinit(self: *ScreenStack) void {
        while (self.stack.pop()) |s| {
            if (s.vtable.deinit) |fn_ptr| fn_ptr(s.ptr, self.allocator);
        }
        self.stack.deinit();
    }

    pub fn depth(self: *const ScreenStack) usize {
        return self.stack.items.len;
    }

    pub fn isEmpty(self: *const ScreenStack) bool {
        return self.stack.items.len == 0;
    }

    pub fn top(self: *const ScreenStack) ?Screen {
        if (self.stack.items.len == 0) return null;
        return self.stack.items[self.stack.items.len - 1];
    }

    pub fn push(self: *ScreenStack, screen: Screen) !void {
        if (self.top()) |prev| {
            if (prev.vtable.on_suspend) |fn_ptr| fn_ptr(prev.ptr, undefined);
        }
        try self.stack.append(screen);
        if (screen.vtable.on_enter) |fn_ptr| fn_ptr(screen.ptr, undefined);
    }

    pub fn pushWithCtx(self: *ScreenStack, screen: Screen, ctx: *Context) !void {
        if (self.top()) |prev| {
            if (prev.vtable.on_suspend) |fn_ptr| fn_ptr(prev.ptr, ctx);
        }
        try self.stack.append(screen);
        if (screen.vtable.on_enter) |fn_ptr| fn_ptr(screen.ptr, ctx);
    }

    pub fn pop(self: *ScreenStack) void {
        if (self.stack.pop()) |s| {
            if (s.vtable.deinit) |fn_ptr| fn_ptr(s.ptr, self.allocator);
            if (self.top()) |new_top| {
                if (new_top.vtable.on_resume) |fn_ptr| fn_ptr(new_top.ptr, undefined);
            }
        }
    }

    pub fn popWithCtx(self: *ScreenStack, ctx: *Context) void {
        if (self.stack.pop()) |s| {
            if (s.vtable.deinit) |fn_ptr| fn_ptr(s.ptr, self.allocator);
            if (self.top()) |new_top| {
                if (new_top.vtable.on_resume) |fn_ptr| fn_ptr(new_top.ptr, ctx);
            }
        }
    }

    pub fn replace(self: *ScreenStack, screen: Screen) !void {
        if (self.stack.pop()) |s| {
            if (s.vtable.deinit) |fn_ptr| fn_ptr(s.ptr, self.allocator);
        }
        try self.stack.append(screen);
        if (screen.vtable.on_enter) |fn_ptr| fn_ptr(screen.ptr, undefined);
    }

    pub fn handleKey(self: *ScreenStack, ctx: *Context, key: keys.KeyEvent) !HandleResult {
        const current = self.top() orelse return .none;
        const action = current.vtable.update(current.ptr, ctx, key);
        return self.applyAction(action, ctx);
    }

    fn applyAction(self: *ScreenStack, action: Action, ctx: *Context) !HandleResult {
        switch (action) {
            .none => return .none,
            .quit => return .quit,
            .pop => {
                self.popWithCtx(ctx);
                return .popped;
            },
            .push => |screen| {
                try self.pushWithCtx(screen, ctx);
                return .pushed;
            },
            .replace => |screen| {
                if (self.stack.pop()) |s| {
                    if (s.vtable.deinit) |fn_ptr| fn_ptr(s.ptr, self.allocator);
                }
                try self.stack.append(screen);
                if (screen.vtable.on_enter) |fn_ptr| fn_ptr(screen.ptr, ctx);
                return .replaced;
            },
        }
    }

    pub fn view(self: *const ScreenStack, ctx: *const Context, allocator: std.mem.Allocator) ![]const u8 {
        if (self.stack.items.len == 0) return try allocator.dupe(u8, "");

        var background_idx: usize = self.stack.items.len - 1;
        while (background_idx > 0 and self.stack.items[background_idx].modal) {
            background_idx -= 1;
        }

        var current = try self.stack.items[background_idx].vtable.view(
            self.stack.items[background_idx].ptr,
            ctx,
            allocator,
        );

        var i = background_idx + 1;
        while (i < self.stack.items.len) : (i += 1) {
            const overlay = try self.stack.items[i].vtable.view(
                self.stack.items[i].ptr,
                ctx,
                allocator,
            );
            defer allocator.free(overlay);
            const composed = try compose(allocator, current, overlay);
            allocator.free(current);
            current = composed;
        }

        return current;
    }
};

fn compose(allocator: std.mem.Allocator, background: []const u8, overlay: []const u8) ![]const u8 {
    const bg_w = measure.maxLineWidth(background);
    const bg_h = measure.height(background);
    const ov_w = measure.maxLineWidth(overlay);
    const ov_h = measure.height(overlay);

    if (ov_w == 0 or ov_h == 0) return allocator.dupe(u8, background);
    if (bg_w == 0 or bg_h == 0) return allocator.dupe(u8, overlay);

    const top: usize = if (bg_h > ov_h) (bg_h - ov_h) / 2 else 0;
    const left: usize = if (bg_w > ov_w) (bg_w - ov_w) / 2 else 0;

    var bg_lines = std.array_list.Managed([]const u8).init(allocator);
    defer bg_lines.deinit();
    {
        var iter = std.mem.splitScalar(u8, background, '\n');
        while (iter.next()) |line| try bg_lines.append(line);
    }

    var ov_lines = std.array_list.Managed([]const u8).init(allocator);
    defer ov_lines.deinit();
    {
        var iter = std.mem.splitScalar(u8, overlay, '\n');
        while (iter.next()) |line| try ov_lines.append(line);
    }

    var result: Writer.Allocating = .init(allocator);
    const w = &result.writer;

    var row: usize = 0;
    while (row < bg_lines.items.len) : (row += 1) {
        if (row > 0) try w.writeByte('\n');
        const ov_row_idx = if (row >= top) row - top else null;
        if (ov_row_idx) |oidx| {
            if (oidx < ov_lines.items.len) {
                const bg_line = bg_lines.items[row];
                const padded = try padOrTrim(allocator, bg_line, left);
                defer allocator.free(padded);
                try w.writeAll(padded);
                try w.writeAll(ov_lines.items[oidx]);
                continue;
            }
        }
        try w.writeAll(bg_lines.items[row]);
    }

    return result.toOwnedSlice();
}

fn padOrTrim(allocator: std.mem.Allocator, line: []const u8, target: usize) ![]u8 {
    const w = measure.width(line);
    if (w == target) return allocator.dupe(u8, line);
    if (w < target) {
        const pad = target - w;
        const out = try allocator.alloc(u8, line.len + pad);
        @memcpy(out[0..line.len], line);
        @memset(out[line.len..], ' ');
        return out;
    }
    const trimmed = try measure.truncate(allocator, line, target);
    return @constCast(trimmed);
}

const testing = std.testing;

const TestScreen = struct {
    name: []const u8,
    pop_on_q: bool = true,
    quit_on_x: bool = false,
    pub var enter_count: usize = 0;
    pub var leave_count: usize = 0;

    fn update(ptr: *anyopaque, _: *Context, key: keys.KeyEvent) Action {
        const self: *TestScreen = @ptrCast(@alignCast(ptr));
        switch (key.key) {
            .char => |c| {
                if (self.pop_on_q and c == 'q') return .pop;
                if (self.quit_on_x and c == 'x') return .quit;
            },
            else => {},
        }
        return .none;
    }

    fn view(ptr: *anyopaque, _: *const Context, allocator: std.mem.Allocator) ![]const u8 {
        const self: *TestScreen = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.name);
    }

    fn onEnter(_: *anyopaque, _: *Context) void {
        enter_count += 1;
    }

    fn onSuspend(_: *anyopaque, _: *Context) void {
        leave_count += 1;
    }

    pub const vtable = Screen.VTable{
        .update = update,
        .view = view,
        .on_enter = onEnter,
        .on_suspend = onSuspend,
    };
};

test "push and pop" {
    var stack = ScreenStack.init(testing.allocator);
    defer stack.deinit();

    var s1 = TestScreen{ .name = "first" };
    var s2 = TestScreen{ .name = "second" };

    try stack.push(.{ .ptr = &s1, .vtable = &TestScreen.vtable, .title = "first" });
    try testing.expectEqual(@as(usize, 1), stack.depth());
    try stack.push(.{ .ptr = &s2, .vtable = &TestScreen.vtable, .title = "second" });
    try testing.expectEqual(@as(usize, 2), stack.depth());

    stack.pop();
    try testing.expectEqual(@as(usize, 1), stack.depth());
    const t = stack.top().?;
    try testing.expectEqualStrings("first", t.title);
}

test "handleKey processes pop action" {
    var stack = ScreenStack.init(testing.allocator);
    defer stack.deinit();

    var s = TestScreen{ .name = "screen" };
    try stack.push(.{ .ptr = &s, .vtable = &TestScreen.vtable });

    var ctx: Context = undefined;
    const result = try stack.handleKey(&ctx, .{ .key = .{ .char = 'q' } });
    try testing.expectEqual(HandleResult.popped, result);
    try testing.expect(stack.isEmpty());
}

test "quit action propagates" {
    var stack = ScreenStack.init(testing.allocator);
    defer stack.deinit();

    var s = TestScreen{ .name = "screen", .quit_on_x = true };
    try stack.push(.{ .ptr = &s, .vtable = &TestScreen.vtable });

    var ctx: Context = undefined;
    const result = try stack.handleKey(&ctx, .{ .key = .{ .char = 'x' } });
    try testing.expectEqual(HandleResult.quit, result);
}

test "modal screen overlays previous screen" {
    var stack = ScreenStack.init(testing.allocator);
    defer stack.deinit();

    var bg = TestScreen{ .name = "background background background background\nbackground background background background\nbackground background background background\nbackground background background background" };
    var modal = TestScreen{ .name = "MODAL" };

    try stack.push(.{ .ptr = &bg, .vtable = &TestScreen.vtable });
    try stack.push(.{ .ptr = &modal, .vtable = &TestScreen.vtable, .modal = true });

    var ctx: Context = undefined;
    const out = try stack.view(&ctx, testing.allocator);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "background") != null);
    try testing.expect(std.mem.indexOf(u8, out, "MODAL") != null);
}
