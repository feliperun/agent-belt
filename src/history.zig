//! Every recording, kept for 60 days: the audio (WAV) and its transcript, from
//! push-to-talk dictation and from the create-agent panel. Long requests are
//! not lost, and `agb history` lists them. Writing happens off the UI path.
//!
//!   macOS    ~/Library/Application Support/agent-belt/history
//!   Linux    $XDG_DATA_HOME/agent-belt/history (~/.local/share/…)
//!   Windows  %LOCALAPPDATA%\agent-belt\history
//!
//! One pair per recording: <stamp>-<kind>.wav and <stamp>-<kind>.json, where
//! the stamp is UTC (20260924T154700Z) so names sort by time.
const std = @import("std");
const builtin = @import("builtin");

pub const retention_days = 60;

/// Voice and transcripts are the most private thing here: the directory and
/// every file in it belong to the owner alone (on Windows the per-user
/// profile is protected by its own ACL).
const owner_only_file: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
const owner_only_dir: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o700);

pub const Kind = enum { dictation, @"new-agent" };

pub const Entry = struct {
    kind: []const u8,
    created: i64, // unix seconds
    seconds: f64, // audio length
    text: []const u8,
    audio: []const u8, // file name of the WAV next to the JSON, or ""
};

/// The history directory, from the environment (home and data dirs).
pub fn dir(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => std.fs.path.join(gpa, &.{ env.get("HOME") orelse "/tmp", "Library", "Application Support", "agent-belt", "history" }),
        .windows => std.fs.path.join(gpa, &.{ env.get("LOCALAPPDATA") orelse env.get("USERPROFILE") orelse ".", "agent-belt", "history" }),
        else => if (env.get("XDG_DATA_HOME")) |d|
            std.fs.path.join(gpa, &.{ d, "agent-belt", "history" })
        else
            std.fs.path.join(gpa, &.{ env.get("HOME") orelse "/tmp", ".local", "share", "agent-belt", "history" }),
    };
}

/// Saves a recording in the background: the caller hands over copies and
/// returns at once. Old entries are pruned on the way.
pub fn saveAsync(io: std.Io, history_dir: []const u8, kind: Kind, wav: []const u8, text: []const u8) void {
    const gpa = std.heap.page_allocator;
    const job = gpa.create(Job) catch return;
    job.* = .{
        .io = io,
        .dir = gpa.dupe(u8, history_dir) catch return gpa.destroy(job),
        .kind = kind,
        .wav = gpa.dupe(u8, wav) catch return gpa.destroy(job),
        .text = gpa.dupe(u8, text) catch return gpa.destroy(job),
    };
    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch return job.run();
    thread.detach();
}

/// The same, in this thread: for one-shot processes that exit right after.
pub fn save(io: std.Io, history_dir: []const u8, kind: Kind, wav: []const u8, text: []const u8) void {
    var job = Job{ .io = io, .dir = history_dir, .kind = kind, .wav = wav, .text = text, .owned = false };
    job.run();
}

const Job = struct {
    io: std.Io,
    dir: []const u8,
    kind: Kind,
    wav: []const u8,
    text: []const u8,
    owned: bool = true,

    fn run(self: *Job) void {
        write(self) catch |err| std.debug.print("[agent-belt] history: {s}\n", .{@errorName(err)});
        prune(self.io, self.dir) catch {};
        if (self.owned) {
            const gpa = std.heap.page_allocator;
            gpa.free(self.dir);
            gpa.free(self.wav);
            gpa.free(self.text);
            gpa.destroy(self);
        }
    }

    fn write(self: *Job) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const gpa = arena.allocator();
        const cwd = std.Io.Dir.cwd();
        try makeDir(self.io, self.dir);
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const base = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ try stamp(gpa, now), @tagName(self.kind) });
        const audio = if (self.wav.len > 44) try std.fmt.allocPrint(gpa, "{s}.wav", .{base}) else "";
        if (audio.len > 0) {
            const f = try cwd.createFile(self.io, try std.fs.path.join(gpa, &.{ self.dir, audio }), .{ .permissions = owner_only_file });
            defer f.close(self.io);
            try f.writeStreamingAll(self.io, self.wav);
        }
        const entry = Entry{
            .kind = @tagName(self.kind),
            .created = now,
            .seconds = wavSeconds(self.wav),
            .text = self.text,
            .audio = audio,
        };
        const json = try std.fmt.allocPrint(gpa, "{f}\n", .{std.json.fmt(entry, .{})});
        const f = try cwd.createFile(self.io, try std.fs.path.join(gpa, &.{ self.dir, try std.fmt.allocPrint(gpa, "{s}.json", .{base}) }), .{ .permissions = owner_only_file });
        defer f.close(self.io);
        try f.writeStreamingAll(self.io, json);
    }
};

/// The history directory, owner-only. One left open by an older version is
/// closed on the way: the recordings already in it are as private as the new one.
fn makeDir(io: std.Io, history_dir: []const u8) !void {
    if (try std.Io.Dir.cwd().createDirPathStatus(io, history_dir, owner_only_dir) == .created) return;
    if (builtin.os.tag != .windows) makePrivate(io, history_dir) catch {};
}

fn makePrivate(io: std.Io, history_dir: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(io, history_dir, .{});
    defer d.close(io);
    const info = try d.stat(io);
    if (info.permissions.toMode() & 0o077 != 0) try d.setPermissions(io, owner_only_dir);
}

/// Length of a 16 kHz mono PCM16 WAV (the format every recorder here uses).
fn wavSeconds(wav: []const u8) f64 {
    if (wav.len <= 44) return 0;
    return @as(f64, @floatFromInt(wav.len - 44)) / 32000.0;
}

/// UTC "20260924T154700Z" for unix seconds.
pub fn stamp(gpa: std.mem.Allocator, unix: i64) ![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(unix, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(gpa, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

/// Deletes entries older than the retention.
fn prune(io: std.Io, history_dir: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cutoff = try stamp(gpa, std.Io.Clock.real.now(io).toSeconds() - retention_days * std.time.s_per_day);
    var d = std.Io.Dir.cwd().openDir(io, history_dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    var old: std.ArrayList([]const u8) = .empty;
    while (try it.next(io)) |e| {
        if (e.name.len >= 16 and std.mem.order(u8, e.name[0..16], cutoff) == .lt) try old.append(gpa, try gpa.dupe(u8, e.name));
    }
    for (old.items) |name| d.deleteFile(io, name) catch {};
}

/// Entries of the last `days`, newest first.
pub fn list(gpa: std.mem.Allocator, io: std.Io, history_dir: []const u8, days: u32) ![]Entry {
    const cutoff = try stamp(gpa, std.Io.Clock.real.now(io).toSeconds() - @as(i64, days) * std.time.s_per_day);
    var d = std.Io.Dir.cwd().openDir(io, history_dir, .{ .iterate = true }) catch return &.{};
    defer d.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".json") or e.name.len < 16) continue;
        if (std.mem.order(u8, e.name[0..16], cutoff) == .lt) continue;
        try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn newer(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .gt;
        }
    }.newer);
    var out: std.ArrayList(Entry) = .empty;
    for (names.items) |name| {
        const bytes = d.readFileAlloc(io, name, gpa, .limited(4 << 20)) catch continue;
        const parsed = std.json.parseFromSliceLeaky(Entry, gpa, bytes, .{ .ignore_unknown_fields = true }) catch continue;
        try out.append(gpa, parsed);
    }
    return out.items;
}

/// `agb history [days] [--json]`: what was said, newest first.
pub fn command(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: []const []const u8) !u8 {
    var days: u32 = retention_days;
    var json = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) json = true else days = std.fmt.parseInt(u32, a, 10) catch {
            std.debug.print("usage: agb history [days] [--json]\n", .{});
            return 2;
        };
    }
    const d = try dir(gpa, env);
    // 60 days is a promise, not an effect of recording again: someone who
    // stops dictating keeps nothing older than that either.
    prune(io, d) catch {};
    const entries = try list(gpa, io, d, days);
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    if (json) {
        try w.print("{f}\n", .{std.json.fmt(entries, .{})});
    } else if (entries.len == 0) {
        try w.print("no recordings in the last {d} days ({s})\n", .{ days, d });
    } else {
        for (entries) |e| {
            const when = try stamp(gpa, e.created);
            const text = std.mem.trim(u8, e.text, " \n");
            const shown = if (text.len > 110) try std.fmt.allocPrint(gpa, "{s}…", .{text[0..utf8Boundary(text, 110)]}) else text;
            try w.print("{s}-{s}-{s} {s}:{s}  {s:<10} {d:>5.1}s  {s}\n", .{
                when[0..4], when[4..6], when[6..8], when[9..11], when[11..13], e.kind, e.seconds, if (shown.len > 0) shown else "(no speech)",
            });
        }
        try w.print("\n{d} recordings, audio and transcripts in {s}\n", .{ entries.len, d });
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
    return 0;
}

fn utf8Boundary(s: []const u8, max: usize) usize {
    var i = @min(max, s.len);
    while (i > 0 and i < s.len and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

test "stamps sort by time and prune compares prefixes" {
    const gpa = std.testing.allocator;
    const a = try stamp(gpa, 1790000000);
    defer gpa.free(a);
    const b = try stamp(gpa, 1790000060);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("20260921T141320Z", a);
    try std.testing.expect(std.mem.order(u8, a, b) == .lt);
    try std.testing.expectEqual(@as(f64, 1), wavSeconds(&([_]u8{0} ** (44 + 32000))));
}

test "a recording is readable by its owner and by nobody else" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const history_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "history" });
    defer gpa.free(history_dir);
    // A directory an older version left open to everyone is closed again.
    try std.Io.Dir.cwd().createDirPath(io, history_dir);
    var loose = try std.Io.Dir.cwd().openDir(io, history_dir, .{});
    try loose.setPermissions(io, .fromMode(0o755));
    loose.close(io);

    save(io, history_dir, .dictation, &([_]u8{0} ** (44 + 32000)), "what was said");

    const cwd = std.Io.Dir.cwd();
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try cwd.statFile(io, history_dir, .{})).permissions.toMode() & 0o777);
    var d = try cwd.openDir(io, history_dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var files: usize = 0;
    while (try it.next(io)) |e| {
        files += 1;
        const info = try d.statFile(io, e.name, .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), info.permissions.toMode() & 0o777);
    }
    try std.testing.expectEqual(@as(usize, 2), files); // the WAV and its transcript
}
