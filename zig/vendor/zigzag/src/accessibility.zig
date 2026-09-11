
const std = @import("std");
const Writer = std.Io.Writer;
const Color = @import("style/color.zig").Color;

pub const ContrastLevel = enum {
    fail,
    aa_large,
    aa,
    aaa,
};

pub fn checkContrast(fg: Color, bg: Color) ContrastLevel {
    const ratio = fg.contrastRatio(bg);
    if (ratio >= 7.0) return .aaa;
    if (ratio >= 4.5) return .aa;
    if (ratio >= 3.0) return .aa_large;
    return .fail;
}

pub fn meetsAA(fg: Color, bg: Color) bool {
    return fg.contrastRatio(bg) >= 4.5;
}

pub fn meetsAAA(fg: Color, bg: Color) bool {
    return fg.contrastRatio(bg) >= 7.0;
}

pub fn suggestForeground(bg: Color) Color {
    const white = Color.white;
    const black = Color.black;
    const white_ratio = white.contrastRatio(bg);
    const black_ratio = black.contrastRatio(bg);
    return if (white_ratio >= black_ratio) white else black;
}

pub const Role = enum {
    button,
    checkbox,
    radio,
    textbox,
    listbox,
    option,
    menu,
    menuitem,
    dialog,
    alert,
    status,
    progressbar,
    slider,
    tab,
    tabpanel,
    tree,
    treeitem,
    heading,
    separator,
    tooltip,
    form,
    list,
    listitem,
    link,
    img,
    none,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .button => "button",
            .checkbox => "checkbox",
            .radio => "radio button",
            .textbox => "text field",
            .listbox => "list box",
            .option => "option",
            .menu => "menu",
            .menuitem => "menu item",
            .dialog => "dialog",
            .alert => "alert",
            .status => "status",
            .progressbar => "progress bar",
            .slider => "slider",
            .tab => "tab",
            .tabpanel => "tab panel",
            .tree => "tree",
            .treeitem => "tree item",
            .heading => "heading",
            .separator => "separator",
            .tooltip => "tooltip",
            .form => "form",
            .list => "list",
            .listitem => "list item",
            .link => "link",
            .img => "image",
            .none => "",
        };
    }
};

pub const AccessibleLabel = struct {
    role: Role = .none,
    name: []const u8 = "",
    description: []const u8 = "",
    value: []const u8 = "",
    state: []const u8 = "",

    pub fn format(self: AccessibleLabel, allocator: std.mem.Allocator) ![]const u8 {
        var parts: Writer.Allocating = .init(allocator);
        const w = &parts.writer;

        if (self.role != .none) {
            try w.writeAll(self.role.label());
        }

        if (self.name.len > 0) {
            if (parts.writer.buffered().len > 0) try w.writeAll(": ");
            try w.writeAll(self.name);
        }

        if (self.value.len > 0) {
            if (parts.writer.buffered().len > 0) try w.writeAll(", ");
            try w.writeAll(self.value);
        }

        if (self.state.len > 0) {
            if (parts.writer.buffered().len > 0) try w.writeAll(", ");
            try w.writeAll(self.state);
        }

        if (self.description.len > 0) {
            if (parts.writer.buffered().len > 0) try w.writeAll(" - ");
            try w.writeAll(self.description);
        }

        return parts.toOwnedSlice();
    }
};

pub fn announceViaTitle(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "\x1b]0;{s}\x07", .{message});
}

pub fn bell() []const u8 {
    return "\x07";
}

pub fn progressDescription(allocator: std.mem.Allocator, value: f64, max: f64) ![]const u8 {
    const pct = if (max > 0) (value / max) * 100.0 else 0.0;
    return std.fmt.allocPrint(allocator, "{d:.0}% complete", .{pct});
}
