//! A recording that is transcribed while it is made: the microphone feeds
//! Deepgram's live stream (src/transcribe_stream.zig) and `on_text` gets the
//! transcript as it grows. `stop` returns the audio and the final words about
//! 350 ms after release. If the stream cannot open (no network, no key), the
//! audio is transcribed on release as before. Used by dictation and by the
//! create-agent panel.
const std = @import("std");
const macos = @import("macos.zig");
const deepgram = @import("deepgram.zig");
const Config = @import("config.zig").Config;
const transcribe = @import("transcribe_stream.zig");

pub const OnText = *const fn (context: ?*anyopaque, text: []const u8) void;

pub const Result = struct {
    /// The WAV (owned by the caller's allocator), empty if nothing was captured.
    wav: []u8,
    /// The transcript (owned), null when it could not be had at all.
    text: ?[]u8,
};

pub const Live = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: *const Config,
    keyterms: []const []const u8,
    on_text: OnText,
    context: ?*anyopaque,
    recorder: macos.Recorder,
    lock: std.Io.Mutex = .init,
    pending: std.ArrayList(u8) = .empty,
    stopping: std.atomic.Value(bool) = .init(false),
    sender: ?std.Thread = null,
    final: ?[]u8 = null,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, config: *const Config, keyterms: []const []const u8, on_text: OnText, context: ?*anyopaque) !*Live {
        const self = try gpa.create(Live);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .config = config, .keyterms = keyterms, .on_text = on_text, .context = context, .recorder = macos.Recorder.init(gpa) };
        errdefer self.recorder.deinit();
        macos.recorderOnPcm(&self.recorder, onPcm, self);
        try self.recorder.start();
        self.sender = try std.Thread.spawn(.{}, sendLoop, .{self});
        return self;
    }

    fn onPcm(context: ?*anyopaque, pcm: ?*const anyopaque, len: usize) callconv(.c) void {
        const self: *Live = @ptrCast(@alignCast(context.?));
        const bytes: [*]const u8 = @ptrCast(pcm.?);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.pending.appendSlice(self.gpa, bytes[0..len]) catch {};
    }

    fn takePending(self: *Live) []u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.pending.toOwnedSlice(self.gpa) catch &.{};
    }

    /// Opens the stream (audio waits in `pending` meanwhile), then forwards it
    /// every 40 ms and passes new text on. On stop: the rest, then the final words.
    fn sendLoop(self: *Live) void {
        const key = macos.deepgramKey(self.gpa, self.config.deepgram_api_key_env) catch return;
        defer self.gpa.free(key);
        const stream = transcribe.Stream.open(self.gpa, self.io, .{
            .api_key = key,
            .model = self.config.deepgram_model,
            .language = self.config.deepgram_language,
            .smart_format = self.config.deepgram_smart_format,
            .mip_opt_out = self.config.deepgram_mip_opt_out,
            .keyterms = self.keyterms,
        }) catch |err| {
            std.debug.print("[agent-belt] streaming unavailable ({s}); transcribing on release\n", .{@errorName(err)});
            return;
        };
        var shown: u32 = 0;
        while (true) {
            const done = self.stopping.load(.acquire);
            const chunk = self.takePending();
            if (chunk.len > 0) stream.send(chunk) catch {};
            self.gpa.free(chunk);
            const rev = stream.revision.load(.acquire);
            if (rev != shown) {
                shown = rev;
                if (stream.text(self.gpa)) |t| {
                    self.on_text(self.context, t);
                    self.gpa.free(t);
                } else |_| {}
            }
            if (done) break;
            std.Io.sleep(self.io, .fromMilliseconds(40), .awake) catch {};
        }
        self.final = stream.finish(self.gpa) catch null;
    }

    /// Stops recording and returns the audio and the final transcript. Frees self.
    pub fn stop(self: *Live) Result {
        const gpa = self.gpa;
        const wav = self.recorder.finish() catch @constCast(&[_]u8{});
        self.recorder.deinit();
        self.stopping.store(true, .release);
        if (self.sender) |t| t.join();
        const text = self.final orelse batch(self, wav);
        self.pending.deinit(gpa);
        gpa.destroy(self);
        return .{ .wav = wav, .text = text };
    }

    fn batch(self: *Live, wav: []const u8) ?[]u8 {
        if (wav.len <= 44) return null;
        const key = macos.deepgramKey(self.gpa, self.config.deepgram_api_key_env) catch return null;
        defer self.gpa.free(key);
        const client = deepgram.Client{
            .io = self.io,
            .allocator = self.gpa,
            .api_key = key,
            .model = self.config.deepgram_model,
            .language = self.config.deepgram_language,
            .smart_format = self.config.deepgram_smart_format,
            .mip_opt_out = self.config.deepgram_mip_opt_out,
        };
        return client.transcribe(wav) catch null;
    }
};
