const std = @import("std");

/// HID reports can repeat a held key. Actions fire only on physical transitions.
pub const KeyEdges = struct {
    down: [6]bool = @splat(false),

    pub fn update(self: *KeyEdges, key: u8, pressed: bool) bool {
        if (key >= self.down.len or self.down[key] == pressed) return false;
        self.down[key] = pressed;
        return true;
    }
};

test "one action per press, independent keys, stray release and invalid input" {
    var keys = KeyEdges{};
    try std.testing.expect(!keys.update(4, false));
    try std.testing.expect(keys.update(4, true));
    try std.testing.expect(!keys.update(4, true));
    try std.testing.expect(keys.update(3, true));
    try std.testing.expect(keys.update(4, false));
    try std.testing.expect(!keys.update(4, false));
    try std.testing.expect(keys.update(4, true));
    try std.testing.expect(keys.update(3, false));
    try std.testing.expect(!keys.update(255, true));
}
