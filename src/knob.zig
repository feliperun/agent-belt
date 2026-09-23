const std = @import("std");

/// Turns knob detents into scroll lines. Detents in the same direction less
/// than 60 ms apart accelerate up to 4x, so a flick travels far and a slow
/// turn stays precise. Positive result scrolls down.
pub const Knob = struct {
    last_ns: u64 = 0,
    last_direction: i8 = 0,
    streak: u2 = 0,

    pub const fast_ns = 60 * std.time.ns_per_ms;

    pub fn step(self: *Knob, direction: i8, now_ns: u64, lines: i32) i32 {
        const fast = direction == self.last_direction and now_ns -% self.last_ns < fast_ns;
        self.streak = if (!fast) 0 else if (self.streak == 3) 3 else self.streak + 1;
        self.last_ns = now_ns;
        self.last_direction = direction;
        return @as(i32, direction) * lines * (@as(i32, self.streak) + 1);
    }
};

test "slow turns stay precise, fast turns accelerate and cap, reversal resets" {
    const ms = std.time.ns_per_ms;
    var knob = Knob{};
    try std.testing.expectEqual(@as(i32, 3), knob.step(1, 1000 * ms, 3));
    try std.testing.expectEqual(@as(i32, 3), knob.step(1, 1200 * ms, 3));
    try std.testing.expectEqual(@as(i32, 6), knob.step(1, 1220 * ms, 3));
    try std.testing.expectEqual(@as(i32, 9), knob.step(1, 1240 * ms, 3));
    try std.testing.expectEqual(@as(i32, 12), knob.step(1, 1260 * ms, 3));
    try std.testing.expectEqual(@as(i32, 12), knob.step(1, 1280 * ms, 3));
    try std.testing.expectEqual(@as(i32, -3), knob.step(-1, 1290 * ms, 3));
    try std.testing.expectEqual(@as(i32, -6), knob.step(-1, 1300 * ms, 3));
    // A negative line count inverts the direction.
    var inverted = Knob{};
    try std.testing.expectEqual(@as(i32, -3), inverted.step(1, 0, -3));
}
