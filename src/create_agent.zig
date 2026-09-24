//! Key 5 on the keypad: hold to speak a new agent into the create panel, with
//! the transcript streaming in real time; a tap confirms it while the panel is
//! open, else is the key's plain press (Return). The panel itself, detection
//! and creation live in src/create_panel.m and `agb _intent`.
const std = @import("std");
const macos = @import("macos.zig");
const Config = @import("config.zig").Config;
const live_recording = @import("live_recording.zig");

/// Longer than a tap: the key is held to speak.
const hold_ns = 300 * std.time.ns_per_ms;

pub const Controller = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    config: *const Config,
    history_dir: []const u8,
    lock: std.Io.Mutex = .init,
    /// Bumped on every press, so a late hold timer knows it is stale.
    press: u32 = 0,
    pressed: bool = false,
    recording: ?*Recording = null,

    pub fn onKey(self: *Controller, pressed: bool, tap_key: ?@import("config.zig").KeyChord) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (pressed) {
            if (self.pressed) return;
            self.pressed = true;
            self.press +%= 1;
            _ = std.Thread.spawn(.{}, holdTimer, .{ self, self.press }) catch {};
            return;
        }
        if (!self.pressed) return;
        self.pressed = false;
        if (self.recording) |rec| {
            self.recording = null;
            _ = std.Thread.spawn(.{}, Recording.stop, .{rec}) catch rec.stop();
            return;
        }
        // A tap: confirm the panel, or the key's usual press.
        if (macos.createPanelVisible()) return macos.createPanelConfirm();
        if (tap_key) |chord| {
            macos.pressKey(chord, true);
            macos.pressKey(chord, false);
        }
    }

    fn holdTimer(self: *Controller, press: u32) void {
        std.Io.sleep(self.io, .fromNanoseconds(hold_ns), .awake) catch return;
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (!self.pressed or self.press != press or self.recording != null) return;
        self.recording = Recording.start(self) catch |err| {
            std.debug.print("[agent-belt] new agent: {s}\n", .{@errorName(err)});
            return;
        };
    }
};

/// One held key: the recorder feeds the stream as audio arrives; the panel
/// One held key: a live recording whose words go to the panel as they come.
const Recording = struct {
    owner: *Controller,
    live: *live_recording.Live,

    fn start(owner: *Controller) !*Recording {
        const self = try owner.gpa.create(Recording);
        errdefer owner.gpa.destroy(self);
        macos.createPanelShow("");
        macos.createPanelRecording(true);
        if (owner.config.sounds) macos.playCue(.start);
        const terms = keyterms(owner.gpa, owner.io) catch &.{};
        self.* = .{ .owner = owner, .live = try live_recording.Live.start(owner.gpa, owner.io, owner.config, terms, onText, owner) };
        std.debug.print("[agent-belt] NEW AGENT: recording, release 5 to review\n", .{});
        return self;
    }

    fn onText(context: ?*anyopaque, text: []const u8) void {
        const owner: *Controller = @ptrCast(@alignCast(context.?));
        macos.createPanelLive(owner.gpa, text);
    }

    fn stop(self: *Recording) void {
        const gpa = self.owner.gpa;
        const result = self.live.stop();
        defer if (result.wav.len > 0) gpa.free(result.wav);
        defer if (result.text) |t| gpa.free(t);
        if (self.owner.config.sounds) macos.playCue(.stop);
        std.debug.print("[agent-belt] NEW AGENT: recording stopped\n", .{});
        @import("history.zig").saveAsync(self.owner.io, self.owner.history_dir, .@"new-agent", result.wav, result.text orelse "");
        macos.createPanelCommit(gpa, result.text orelse "");
        macos.createPanelRecording(false);
        gpa.destroy(self);
    }
};

/// the machines and every repo in the index (the panel refreshes it).
fn keyterms(gpa: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var terms: std.ArrayList([]const u8) = .empty;
    try terms.appendSlice(gpa, &.{ "claude", "codex", "shell" });
    const home = std.mem.span(std.c.getenv("HOME") orelse return terms.items);
    const dir_path = try std.fs.path.join(gpa, &.{ home, ".cache", "agent-belt", "repos" });
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return terms.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        try terms.append(gpa, try gpa.dupe(u8, entry.name));
        const list = dir.readFileAlloc(io, entry.name, gpa, .limited(64 * 1024)) catch continue;
        var names = std.mem.tokenizeAny(u8, list, "\r\n");
        while (names.next()) |n| if (terms.items.len < 90 and n.len <= 40) try terms.append(gpa, n);
    }
    return terms.items;
}
