const std = @import("std");

/// F5, the Mac's microphone key, as push-to-talk with macOS's own feel:
/// a quick tap starts recording and the next tap stops it; holding records
/// until release.
pub const Talk = struct {
    down_ns: u64 = 0,
    held: bool = false,
    active: bool = false,
    latched: bool = false, // started by a tap: keeps recording after release

    pub const tap_ns = 300 * std.time.ns_per_ms;
    pub const Action = enum { none, start, stop };

    pub fn press(self: *Talk, now_ns: u64) Action {
        if (self.held) return .none; // key repeat
        self.held = true;
        if (self.active) {
            if (!self.latched) return .none;
            self.active = false;
            self.latched = false;
            return .stop;
        }
        self.active = true;
        self.down_ns = now_ns;
        return .start;
    }

    pub fn release(self: *Talk, now_ns: u64) Action {
        if (!self.held) return .none;
        self.held = false;
        if (!self.active) return .none;
        if (!self.latched and now_ns -% self.down_ns < tap_ns) {
            self.latched = true;
            return .none;
        }
        self.active = false;
        self.latched = false;
        return .stop;
    }
};

test "tap toggles, hold is push-to-talk, repeats and stray releases are ignored" {
    const ms = std.time.ns_per_ms;
    var talk = Talk{};
    // Tap: start, keep recording after a quick release, stop on the next tap.
    try std.testing.expectEqual(Talk.Action.start, talk.press(0));
    try std.testing.expectEqual(Talk.Action.none, talk.release(120 * ms));
    try std.testing.expectEqual(Talk.Action.stop, talk.press(3000 * ms));
    try std.testing.expectEqual(Talk.Action.none, talk.release(3100 * ms));
    // Hold: start on press, stop on release.
    try std.testing.expectEqual(Talk.Action.start, talk.press(5000 * ms));
    try std.testing.expectEqual(Talk.Action.none, talk.press(5100 * ms)); // auto-repeat
    try std.testing.expectEqual(Talk.Action.stop, talk.release(6500 * ms));
    // A release without a press does nothing.
    try std.testing.expectEqual(Talk.Action.none, talk.release(7000 * ms));
}
