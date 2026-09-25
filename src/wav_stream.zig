//! Real-time dictation from a WAV being written (Linux: pw-record): its new
//! samples go to Deepgram's live stream (src/transcribe_stream.zig) and the
//! transcript grows in the overlay. `agb ptt stop` reads the final words from a
//! file a moment after release; when the stream never opened, it transcribes
//! the recording whole, as before.
const std = @import("std");
const sys = @import("sessions/sys.zig");
const config = @import("config.zig");
const transcribe = @import("transcribe_stream.zig");

/// pw-record's header: the samples start right after it.
pub const wav_header = 44;

/// The bytes of whole samples written past `sent` (PCM16: an even count).
pub fn pending(len: u64, sent: u64) u64 {
    if (len <= sent) return 0;
    return (len - sent) & ~@as(u64, 1);
}

/// Streams one recording. Runs on its own thread, with its own allocator
/// (the command's arena is not thread-safe).
pub const Live = struct {
    io: std.Io,
    env: *std.process.Environ.Map,
    key: []const u8,
    /// Words Deepgram should favor (harness, machine and repo names).
    keyterms: []const []const u8 = &.{},
    wav_path: []const u8,
    /// "open" or "failed" once the stream is decided.
    status_path: []const u8,
    /// The final transcript, written when the stream is finished.
    final_path: []const u8,
    lock: std.Io.Mutex = .init,
    text: []u8 = &.{},
    finishing: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    const gpa = std.heap.smp_allocator;

    pub fn start(self: *Live) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// The transcript so far, copied with `into`.
    pub fn snapshot(self: *Live, into: std.mem.Allocator) []const u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return into.dupe(u8, self.text) catch "";
    }

    /// The recorder has stopped: send the rest and finish.
    pub fn finish(self: *Live) void {
        self.finishing.store(true, .release);
    }

    fn ctx(self: *Live) sys.Ctx {
        return .{ .io = self.io, .gpa = gpa, .env = self.env };
    }

    fn run(self: *Live) void {
        self.stream() catch |err| {
            std.debug.print("[agent-belt] streaming unavailable ({s}); transcribing on release\n", .{@errorName(err)});
            sys.writeFileAtomic(self.ctx(), self.status_path, "failed") catch {};
        };
    }

    fn stream(self: *Live) !void {
        const defaults = config.Config{};
        const s = try transcribe.Stream.open(gpa, self.io, .{
            .api_key = self.key,
            .model = defaults.deepgram_model,
            .language = defaults.deepgram_language,
            .smart_format = defaults.deepgram_smart_format,
            .mip_opt_out = defaults.deepgram_mip_opt_out,
            .keyterms = self.keyterms,
        });
        try sys.writeFileAtomic(self.ctx(), self.status_path, "open");
        var sent: u64 = wav_header;
        var shown: u32 = 0;
        while (true) {
            const last = self.finishing.load(.acquire);
            sent += self.sendNew(s, sent) catch 0;
            const rev = s.revision.load(.acquire);
            if (rev != shown) {
                shown = rev;
                self.publish(try s.text(gpa));
            }
            if (last) break;
            try std.Io.sleep(self.io, .fromMilliseconds(40), .awake);
        }
        const final = try s.finish(gpa);
        self.publish(try gpa.dupe(u8, final));
        try sys.writeFileAtomic(self.ctx(), self.final_path, final);
    }

    fn publish(self: *Live, text: []u8) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        gpa.free(self.text);
        self.text = text;
    }

    /// Sends what pw-record wrote since `sent`; returns how much.
    fn sendNew(self: *Live, s: *transcribe.Stream, sent: u64) !u64 {
        const file = try std.Io.Dir.cwd().openFile(self.io, self.wav_path, .{});
        defer file.close(self.io);
        var buf: [64 * 1024]u8 = undefined;
        const n = @min(pending(try file.length(self.io), sent), buf.len);
        if (n == 0) return 0;
        const got = try file.readPositionalAll(self.io, buf[0..n], sent);
        const whole = got & ~@as(usize, 1);
        try s.send(buf[0..whole]);
        return whole;
    }
};

test "only whole samples past what was sent" {
    try std.testing.expectEqual(@as(u64, 0), pending(44, 44));
    try std.testing.expectEqual(@as(u64, 0), pending(40, 44));
    try std.testing.expectEqual(@as(u64, 100), pending(145, 45));
    try std.testing.expectEqual(@as(u64, 320), pending(364, 44));
}
