
const std = @import("std");
const keys = @import("keys.zig");
const mouse = @import("mouse.zig");

pub const Key = keys.Key;
pub const KeyEvent = keys.KeyEvent;
pub const Modifiers = keys.Modifiers;
pub const MouseEvent = mouse.MouseEvent;

pub const ParseResult = union(enum) {
    key: KeyEvent,
    mouse: MouseEvent,
    none,
};

pub const ParseReturn = struct { result: ParseResult, consumed: usize };

pub fn parse(data: []const u8) ParseReturn {
    if (data.len == 0) return .{ .result = .none, .consumed = 0 };

    if (data[0] == 0x1b) {
        if (data.len == 1) {
            return .{ .result = .{ .key = .{ .key = .escape } }, .consumed = 1 };
        }

        if (data.len >= 2 and data[1] == '[') {
            if (parseCsi(data)) |result| {
                return result;
            }
        }

        if (data.len >= 2 and data[1] == 'O') {
            if (parseSs3(data)) |result| {
                return result;
            }
        }

        if (data.len >= 2 and data[1] != '[' and data[1] != 'O') {
            const inner = parse(data[1..]);
            if (inner.result == .key) {
                var key_event = inner.result.key;
                key_event.modifiers.alt = true;
                return .{ .result = .{ .key = key_event }, .consumed = 1 + inner.consumed };
            }
        }

        return .{ .result = .{ .key = .{ .key = .escape } }, .consumed = 1 };
    }

    if (data[0] < 32) {
        const key_event = parseControl(data[0]);
        return .{ .result = .{ .key = key_event }, .consumed = 1 };
    }

    if (data[0] == 127) {
        return .{ .result = .{ .key = .{ .key = .backspace } }, .consumed = 1 };
    }

    const len = std.unicode.utf8ByteSequenceLength(data[0]) catch 1;
    if (len <= data.len) {
        const codepoint = std.unicode.utf8Decode(data[0..len]) catch data[0];
        return .{ .result = .{ .key = .{ .key = .{ .char = codepoint } } }, .consumed = len };
    }

    return .{ .result = .{ .key = .{ .key = .{ .char = data[0] } } }, .consumed = 1 };
}

fn parseControl(c: u8) KeyEvent {
    return switch (c) {
        0 => .{ .key = .null_key, .modifiers = .{ .ctrl = true } },
        9 => .{ .key = .tab },
        10 => .{ .key = .enter, .modifiers = .{ .shift = true } },
        13 => .{ .key = .enter },
        27 => .{ .key = .escape },
        1...8, 11, 12, 14...26 => .{
            .key = .{ .char = 'a' + c - 1 },
            .modifiers = .{ .ctrl = true },
        },
        else => .{ .key = .{ .char = c } },
    };
}

fn parseCsi(data: []const u8) ?ParseReturn {
    if (data.len < 3) return null;
    if (data[0] != 0x1b or data[1] != '[') return null;

    if (data.len >= 6 and std.mem.startsWith(u8, data[2..], "200~")) {
        return parseBracketedPaste(data);
    }

    if (data.len >= 3 and data[2] == '<') {
        if (mouse.parseSgr(data)) |m| {
            return .{ .result = .{ .mouse = m.event }, .consumed = m.consumed };
        }
    }

    var idx: usize = 2;
    var params: [8]u16 = @splat(0);
    var param_count: usize = 0;
    var has_colon = false;
    var sub_params: [8]u16 = @splat(0);

    while (idx < data.len and param_count < params.len) {
        const c = data[idx];
        if (c >= '0' and c <= '9') {
            params[param_count] = params[param_count] * 10 + @as(u16, @intCast(c - '0'));
            idx += 1;
        } else if (c == ';') {
            param_count += 1;
            idx += 1;
        } else if (c == ':') {
            has_colon = true;
            sub_params[param_count] = 0;
            idx += 1;
            while (idx < data.len and data[idx] >= '0' and data[idx] <= '9') {
                sub_params[param_count] = sub_params[param_count] * 10 + @as(u16, @intCast(data[idx] - '0'));
                idx += 1;
            }
        } else {
            break;
        }
    }
    param_count += 1;

    if (idx >= data.len) return null;

    const final_byte = data[idx];
    idx += 1;

    if (final_byte == 'u') {
        return parseKittyCsi(params[0..param_count], sub_params[0..param_count], has_colon, idx);
    }

    var modifiers = Modifiers{};
    if (param_count >= 2 and params[1] > 1) {
        const mod_param = params[1] - 1;
        modifiers.shift = (mod_param & 1) != 0;
        modifiers.alt = (mod_param & 2) != 0;
        modifiers.ctrl = (mod_param & 4) != 0;
    }

    const key: Key = switch (final_byte) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => {
            modifiers.shift = true;
            return .{ .result = .{ .key = .{ .key = .tab, .modifiers = modifiers } }, .consumed = idx };
        },
        '~' => switch (params[0]) {
            1 => .home,
            2 => .insert,
            3 => .delete,
            4 => .end,
            5 => .page_up,
            6 => .page_down,
            7 => .home,
            8 => .end,
            11 => .f1,
            12 => .f2,
            13 => .f3,
            14 => .f4,
            15 => .f5,
            17 => .f6,
            18 => .f7,
            19 => .f8,
            20 => .f9,
            21 => .f10,
            23 => .f11,
            24 => .f12,
            else => return null,
        },
        else => return null,
    };

    return .{ .result = .{ .key = .{ .key = key, .modifiers = modifiers } }, .consumed = idx };
}

fn parseKittyCsi(params: []const u16, sub_params: []const u16, has_colon: bool, consumed: usize) ?ParseReturn {
    if (params.len == 0) return null;

    const keycode = params[0];

    var modifiers = Modifiers{};
    if (params.len >= 2 and params[1] > 1) {
        const mod_param = params[1] - 1;
        modifiers.shift = (mod_param & 1) != 0;
        modifiers.alt = (mod_param & 2) != 0;
        modifiers.ctrl = (mod_param & 4) != 0;
        modifiers.super = (mod_param & 8) != 0;
    }

    var event_type: keys.KeyEventType = .press;
    if (has_colon and params.len >= 2) {
        event_type = switch (sub_params[1]) {
            2 => .repeat,
            3 => .release,
            else => .press,
        };
    }

    const key: Key = switch (keycode) {
        9 => .tab,
        13 => .enter,
        27 => .escape,
        32 => .space,
        127 => .backspace,
        57358 => .{ .char = 0 },
        else => blk: {
            if (keycode >= 32 and keycode < 127) {
                break :blk .{ .char = @intCast(keycode) };
            }
            if (keycode > 127 and keycode <= 0x10FFFF) {
                break :blk .{ .char = @intCast(keycode) };
            }
            break :blk .null_key;
        },
    };

    return .{
        .result = .{ .key = .{
            .key = key,
            .modifiers = modifiers,
            .event_type = event_type,
        } },
        .consumed = consumed,
    };
}

fn parseBracketedPaste(data: []const u8) ?ParseReturn {
    const paste_start = 6;
    const end_marker = "\x1b[201~";

    if (std.mem.indexOf(u8, data[paste_start..], end_marker)) |end_offset| {
        const paste_content = data[paste_start .. paste_start + end_offset];
        const total_consumed = paste_start + end_offset + end_marker.len;
        return .{
            .result = .{ .key = .{
                .key = .{ .paste = paste_content },
            } },
            .consumed = total_consumed,
        };
    }

    return .{
        .result = .{ .key = .{
            .key = .{ .paste = data[paste_start..] },
        } },
        .consumed = data.len,
    };
}

fn parseSs3(data: []const u8) ?ParseReturn {
    if (data.len < 3) return null;
    if (data[0] != 0x1b or data[1] != 'O') return null;

    const key: Key = switch (data[2]) {
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => return null,
    };

    return .{ .result = .{ .key = .{ .key = key } }, .consumed = 3 };
}

pub fn parseAll(allocator: std.mem.Allocator, data: []const u8) ![]ParseResult {
    var results = std.array_list.Managed(ParseResult).init(allocator);
    errdefer results.deinit();

    var offset: usize = 0;
    while (offset < data.len) {
        const parsed = parse(data[offset..]);
        if (parsed.consumed == 0) break;

        if (parsed.result != .none) {
            try results.append(parsed.result);
        }
        offset += parsed.consumed;
    }

    return results.toOwnedSlice();
}
