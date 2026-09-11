
const mouse = @import("mouse.zig");
const MouseEvent = mouse.MouseEvent;

pub const HitBox = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn init(x: u16, y: u16, w: u16, h: u16) HitBox {
        return .{ .x = x, .y = y, .width = w, .height = h };
    }

    pub fn contains(self: HitBox, event: MouseEvent) bool {
        return event.x >= self.x and
            event.x < self.x +| self.width and
            event.y >= self.y and
            event.y < self.y +| self.height;
    }

    pub fn containsPoint(self: HitBox, x: u16, y: u16) bool {
        return x >= self.x and
            x < self.x +| self.width and
            y >= self.y and
            y < self.y +| self.height;
    }

    pub fn clicked(self: HitBox, event: MouseEvent) bool {
        return event.button == .left and
            event.event_type == .press and
            self.contains(event);
    }

    pub fn rightClicked(self: HitBox, event: MouseEvent) bool {
        return event.button == .right and
            event.event_type == .press and
            self.contains(event);
    }

    pub fn localCoords(self: HitBox, event: MouseEvent) ?struct { x: u16, y: u16 } {
        if (!self.contains(event)) return null;
        return .{
            .x = event.x - self.x,
            .y = event.y - self.y,
        };
    }

    pub fn expand(self: HitBox, padding: u16) HitBox {
        return .{
            .x = self.x -| padding,
            .y = self.y -| padding,
            .width = self.width +| padding *| 2,
            .height = self.height +| padding *| 2,
        };
    }

    pub fn overlaps(self: HitBox, other: HitBox) bool {
        return self.x < other.x +| other.width and
            self.x +| self.width > other.x and
            self.y < other.y +| other.height and
            self.y +| self.height > other.y;
    }
};

pub const MouseState = struct {
    hover: bool = false,
    pressed: bool = false,
    last_x: u16 = 0,
    last_y: u16 = 0,

    pub fn update(self: *MouseState, hitbox: HitBox, event: MouseEvent) Interaction {
        self.last_x = event.x;
        self.last_y = event.y;

        const inside = hitbox.contains(event);
        const was_hover = self.hover;
        self.hover = inside;

        if (event.event_type == .press and event.button == .left and inside) {
            self.pressed = true;
            return .press;
        }

        if (event.event_type == .release and event.button == .left) {
            if (self.pressed and inside) {
                self.pressed = false;
                return .click;
            }
            self.pressed = false;
        }

        if (inside and !was_hover) return .enter;
        if (!inside and was_hover) return .leave;
        if (inside and event.event_type == .move) return .hover;

        if (event.button == .wheel_up and inside) return .scroll_up;
        if (event.button == .wheel_down and inside) return .scroll_down;

        return .none;
    }
};

pub const Interaction = enum {
    none,
    press,
    click,
    enter,
    leave,
    hover,
    scroll_up,
    scroll_down,
};
