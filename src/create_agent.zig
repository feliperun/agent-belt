//! Key 5 on the keypad: hold to speak a new agent into the create panel, with
//! the transcript streaming in real time; a tap confirms it while the panel is
//! open, else is the key's plain press (Return). The panel itself, detection
//! and creation live in src/create_panel.m and `agb _intent`.
const std = @import("std");
const macos = @import("macos.zig");
const deepgram = @import("deepgram.zig");
const Config = @import("config.zig").Config;
const stream_mod = @import("transcribe_stream.zig");

/// Longer than a tap: the key is held to speak.
const hold_ns = 300 * std.time.ns_per_ms;

pub const Controller = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    config: *const Config,
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
            std.debug.print("[agent-belt] criar agente: {s}\n", .{@errorName(err)});
            return;
        };
    }
};

/// One held key: the recorder feeds the stream as audio arrives; the panel
/// shows the transcript as it grows.
const Recording = struct {
    owner: *Controller,
    recorder: macos.Recorder,
    lock: std.Io.Mutex = .init,
    pending: std.ArrayList(u8) = .empty,
    stopping: std.atomic.Value(bool) = .init(false),
    sender: ?std.Thread = null,
    final: ?[]u8 = null,

    fn start(owner: *Controller) !*Recording {
        const self = try owner.gpa.create(Recording);
        errdefer owner.gpa.destroy(self);
        self.* = .{ .owner = owner, .recorder = macos.Recorder.init(owner.gpa) };
        macos.createPanelShow("");
        macos.createPanelRecording(true);
        if (owner.config.sounds) macos.playCue(.start);
        macos.recorderOnPcm(&self.recorder, onPcm, self);
        try self.recorder.start();
        self.sender = try std.Thread.spawn(.{}, sendLoop, .{self});
        return self;
    }

    fn onPcm(context: ?*anyopaque, pcm: ?*const anyopaque, len: usize) callconv(.c) void {
        const self: *Recording = @ptrCast(@alignCast(context.?));
        const bytes: [*]const u8 = @ptrCast(pcm.?);
        self.lock.lockUncancelable(self.owner.io);
        defer self.lock.unlock(self.owner.io);
        self.pending.appendSlice(self.owner.gpa, bytes[0..len]) catch {};
    }

    fn takePending(self: *Recording) []u8 {
        self.lock.lockUncancelable(self.owner.io);
        defer self.lock.unlock(self.owner.io);
        return self.pending.toOwnedSlice(self.owner.gpa) catch &.{};
    }

    /// Opens the stream (audio waits in `pending` meanwhile), then forwards it
    /// every 40 ms and shows new text. On stop: the rest, then the final words.
    fn sendLoop(self: *Recording) void {
        const io = self.owner.io;
        const gpa = self.owner.gpa;
        const key = macos.deepgramKey(gpa, self.owner.config.deepgram_api_key_env) catch return;
        defer gpa.free(key);
        const terms = keyterms(gpa, io) catch &.{};
        const stream = stream_mod.Stream.open(gpa, io, .{
            .api_key = key,
            .model = self.owner.config.deepgram_model,
            .language = self.owner.config.deepgram_language,
            .keyterms = terms,
        }) catch |err| {
            std.debug.print("[agent-belt] streaming indisponível ({s}); transcrevo ao soltar\n", .{@errorName(err)});
            return;
        };
        var shown: u32 = 0;
        while (true) {
            const done = self.stopping.load(.acquire);
            const chunk = self.takePending();
            if (chunk.len > 0) stream.send(chunk) catch {};
            gpa.free(chunk);
            const rev = stream.revision.load(.acquire);
            if (rev != shown) {
                shown = rev;
                if (stream.text(gpa)) |t| {
                    macos.createPanelLive(gpa, t);
                    gpa.free(t);
                } else |_| {}
            }
            if (done) break;
            std.Io.sleep(io, .fromMilliseconds(40), .awake) catch {};
        }
        self.final = stream.finish(gpa) catch null;
    }

    fn stop(self: *Recording) void {
        const gpa = self.owner.gpa;
        const wav = self.recorder.finish() catch &.{};
        defer if (wav.len > 0) gpa.free(wav);
        self.recorder.deinit();
        self.stopping.store(true, .release);
        if (self.sender) |t| t.join();
        if (self.owner.config.sounds) macos.playCue(.stop);
        // The stream never opened (no network, no key): transcribe the recording.
        const text = self.final orelse batch(self.owner, wav);
        macos.createPanelCommit(gpa, text orelse "");
        macos.createPanelRecording(false);
        if (self.final) |f| gpa.free(f);
        self.pending.deinit(gpa);
        gpa.destroy(self);
    }
};

fn batch(owner: *Controller, wav: []const u8) ?[]u8 {
    if (wav.len <= 44) return null;
    const key = macos.deepgramKey(owner.gpa, owner.config.deepgram_api_key_env) catch return null;
    defer owner.gpa.free(key);
    const client = deepgram.Client{
        .io = owner.io,
        .allocator = owner.gpa,
        .api_key = key,
        .model = owner.config.deepgram_model,
        .language = owner.config.deepgram_language,
        .smart_format = owner.config.deepgram_smart_format,
        .mip_opt_out = owner.config.deepgram_mip_opt_out,
    };
    return client.transcribe(wav) catch null;
}

/// Names Deepgram should favor while a new agent is described: the harnesses,
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
