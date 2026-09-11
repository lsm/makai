
const std = @import("std");
const Color = @import("../style/color.zig").Color;
const progress_mod = @import("../components/progress.zig");

pub const Easing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,
    bounce,
    elastic,

    pub fn apply(self: Easing, t: f64) f64 {
        const clamped = @max(0.0, @min(1.0, t));
        return switch (self) {
            .linear => clamped,
            .ease_in => clamped * clamped,
            .ease_out => 1.0 - (1.0 - clamped) * (1.0 - clamped),
            .ease_in_out => if (clamped < 0.5)
                2.0 * clamped * clamped
            else
                1.0 - std.math.pow(f64, -2.0 * clamped + 2.0, 2) / 2.0,
            .ease_in_cubic => clamped * clamped * clamped,
            .ease_out_cubic => 1.0 - std.math.pow(f64, 1.0 - clamped, 3),
            .ease_in_out_cubic => if (clamped < 0.5)
                4.0 * clamped * clamped * clamped
            else
                1.0 - std.math.pow(f64, -2.0 * clamped + 2.0, 3) / 2.0,
            .bounce => blk: {
                var b = 1.0 - clamped;
                if (b < 1.0 / 2.75) {
                    break :blk 1.0 - (7.5625 * b * b);
                } else if (b < 2.0 / 2.75) {
                    b -= 1.5 / 2.75;
                    break :blk 1.0 - (7.5625 * b * b + 0.75);
                } else if (b < 2.5 / 2.75) {
                    b -= 2.25 / 2.75;
                    break :blk 1.0 - (7.5625 * b * b + 0.9375);
                } else {
                    b -= 2.625 / 2.75;
                    break :blk 1.0 - (7.5625 * b * b + 0.984375);
                }
            },
            .elastic => if (clamped == 0.0 or clamped == 1.0)
                clamped
            else
                -std.math.pow(f64, 2.0, 10.0 * clamped - 10.0) *
                    @sin((clamped * 10.0 - 10.75) * (2.0 * std.math.pi / 3.0)),
        };
    }
};

pub const Tween = struct {
    start_val: f64,
    end_val: f64,
    duration_ns: u64,
    elapsed_ns: u64,
    easing: Easing,
    state: State,
    loop_mode: LoopMode,

    pub const State = enum {
        idle,
        running,
        finished,
    };

    pub const LoopMode = enum {
        once,
        loop,
        ping_pong,
    };

    pub fn init(from: f64, to: f64, duration_ms: u64) Tween {
        return .{
            .start_val = from,
            .end_val = to,
            .duration_ns = duration_ms * std.time.ns_per_ms,
            .elapsed_ns = 0,
            .easing = .linear,
            .state = .idle,
            .loop_mode = .once,
        };
    }

    pub fn setEasing(self: *Tween, easing: Easing) void {
        self.easing = easing;
    }

    pub fn setLoop(self: *Tween, mode: LoopMode) void {
        self.loop_mode = mode;
    }

    pub fn start(self: *Tween) void {
        self.state = .running;
        self.elapsed_ns = 0;
    }

    pub fn reset(self: *Tween) void {
        self.elapsed_ns = 0;
        self.state = .idle;
    }

    pub fn update(self: *Tween, delta_ns: u64) void {
        if (self.state != .running) return;

        self.elapsed_ns += delta_ns;

        if (self.elapsed_ns >= self.duration_ns) {
            switch (self.loop_mode) {
                .once => {
                    self.elapsed_ns = self.duration_ns;
                    self.state = .finished;
                },
                .loop => {
                    self.elapsed_ns = self.elapsed_ns % self.duration_ns;
                },
                .ping_pong => {
                    self.elapsed_ns = self.elapsed_ns % (self.duration_ns * 2);
                },
            }
        }
    }

    pub fn value(self: *const Tween) f64 {
        if (self.duration_ns == 0) return self.end_val;

        var t: f64 = @as(f64, @floatFromInt(self.elapsed_ns)) / @as(f64, @floatFromInt(self.duration_ns));

        if (self.loop_mode == .ping_pong and t > 1.0) {
            t = 2.0 - t;
        }

        t = @max(0.0, @min(1.0, t));
        const eased = self.easing.apply(t);
        return self.start_val + (self.end_val - self.start_val) * eased;
    }

    pub fn intValue(self: *const Tween) i64 {
        return @intFromFloat(self.value());
    }

    pub fn isFinished(self: *const Tween) bool {
        return self.state == .finished;
    }

    pub fn isRunning(self: *const Tween) bool {
        return self.state == .running;
    }

    pub fn progress(self: *const Tween) f64 {
        if (self.duration_ns == 0) return 1.0;
        return @min(1.0, @as(f64, @floatFromInt(self.elapsed_ns)) / @as(f64, @floatFromInt(self.duration_ns)));
    }
};

pub fn tweenColor(start: Color, end: Color, t: f64) Color {
    return progress_mod.interpolateColor(start, end, @max(0.0, @min(1.0, t)));
}

pub fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * @max(0.0, @min(1.0, t));
}
