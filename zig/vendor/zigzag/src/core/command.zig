
const std = @import("std");

pub const ImagePlacement = enum {
    cursor,
    top_left,
    top_center,
    center,
};

pub const ImageProtocol = enum {
    auto,
    kitty,
    iterm2,
    sixel,
};

pub const ImageFormat = enum(u16) {
    rgb = 24,
    rgba = 32,
    png = 100,
};

pub const ImageFile = struct {
    path: []const u8,
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    placement: ImagePlacement = .top_left,
    row: ?u16 = null,
    col: ?u16 = null,
    row_offset: i16 = 0,
    col_offset: i16 = 0,
    preserve_aspect_ratio: bool = true,
    image_id: ?u32 = null,
    placement_id: ?u32 = null,
    move_cursor: bool = true,
    quiet: bool = true,
    protocol: ImageProtocol = .auto,
    z_index: ?i32 = null,
    unicode_placeholder: bool = false,
};

pub const ImageData = struct {
    data: []const u8,
    format: ImageFormat = .png,
    pixel_width: ?u32 = null,
    pixel_height: ?u32 = null,
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    placement: ImagePlacement = .top_left,
    row: ?u16 = null,
    col: ?u16 = null,
    row_offset: i16 = 0,
    col_offset: i16 = 0,
    image_id: ?u32 = null,
    placement_id: ?u32 = null,
    move_cursor: bool = true,
    quiet: bool = true,
    protocol: ImageProtocol = .auto,
    z_index: ?i32 = null,
    unicode_placeholder: bool = false,
};

pub const CacheImage = struct {
    source: ImageSource,
    image_id: u32,
    format: ImageFormat = .png,
    pixel_width: ?u32 = null,
    pixel_height: ?u32 = null,
    quiet: bool = true,
};

pub const ImageSource = union(enum) {
    file: []const u8,
    data: []const u8,
};

pub const PlaceCachedImage = struct {
    image_id: u32,
    placement_id: ?u32 = null,
    width_cells: ?u16 = null,
    height_cells: ?u16 = null,
    placement: ImagePlacement = .top_left,
    row: ?u16 = null,
    col: ?u16 = null,
    row_offset: i16 = 0,
    col_offset: i16 = 0,
    move_cursor: bool = true,
    quiet: bool = true,
    z_index: ?i32 = null,
    unicode_placeholder: bool = false,
};

pub const DeleteImage = union(enum) {
    by_id: u32,
    by_placement: struct { image_id: u32, placement_id: u32 },
    all,
};

pub const KittyImageFile = ImageFile;

pub fn Cmd(comptime Msg: type) type {
    return union(enum) {
        none,

        quit,

        tick: u64,

        every: u64,

        batch: []const Cmd(Msg),

        sequence: []const Cmd(Msg),

        msg: Msg,

        perform: *const fn () ?Msg,

        suspend_process,

        enable_mouse,
        disable_mouse,
        show_cursor,
        hide_cursor,
        enter_alt_screen,
        exit_alt_screen,
        set_title: []const u8,

        println: []const u8,

        image_file: ImageFile,

        kitty_image_file: KittyImageFile,

        image_data: ImageData,

        cache_image: CacheImage,

        place_cached_image: PlaceCachedImage,

        delete_image: DeleteImage,

        const Self = @This();

        pub fn none_cmd() Self {
            return .none;
        }

        pub fn quit_cmd() Self {
            return .quit;
        }

        pub fn tickMs(ms: u64) Self {
            return .{ .tick = ms * std.time.ns_per_ms };
        }

        pub fn tickSec(sec: u64) Self {
            return .{ .tick = sec * std.time.ns_per_s };
        }

        pub fn everyMs(ms: u64) Self {
            return .{ .every = ms * std.time.ns_per_ms };
        }

        pub fn everySec(sec: u64) Self {
            return .{ .every = sec * std.time.ns_per_s };
        }

        pub fn batchOf(cmds: []const Self) Self {
            return .{ .batch = cmds };
        }

        pub fn sequenceOf(cmds: []const Self) Self {
            return .{ .sequence = cmds };
        }

        pub fn send(message: Msg) Self {
            return .{ .msg = message };
        }

        pub fn performFn(func: *const fn () ?Msg) Self {
            return .{ .perform = func };
        }

        pub fn isNone(self: Self) bool {
            return self == .none;
        }

        pub fn isQuit(self: Self) bool {
            return self == .quit;
        }
    };
}

pub const StandardCmd = union(enum) {
    none,
    quit,
    tick: u64,
    set_title: []const u8,
    enable_mouse,
    disable_mouse,
    show_cursor,
    hide_cursor,
    enter_alt_screen,
    exit_alt_screen,
    image_file: ImageFile,
    kitty_image_file: KittyImageFile,
    image_data: ImageData,
    cache_image: CacheImage,
    place_cached_image: PlaceCachedImage,
    delete_image: DeleteImage,
};

pub fn batch(comptime Msg: type, cmds: []const Cmd(Msg)) Cmd(Msg) {
    return .{ .batch = cmds };
}

pub fn sequence(comptime Msg: type, cmds: []const Cmd(Msg)) Cmd(Msg) {
    return .{ .sequence = cmds };
}

pub fn tick(comptime Msg: type, ms: u64) Cmd(Msg) {
    return Cmd(Msg).tickMs(ms);
}

pub fn everyFrame(comptime Msg: type) Cmd(Msg) {
    return Cmd(Msg).tickMs(16);
}
