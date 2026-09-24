//! Real-time transcription: audio goes to Deepgram's live API over a WebSocket
//! while the key is held, and the transcript grows as results come back, so the
//! text is ready the moment the key comes up. One stream per recording: open,
//! send PCM as it is captured, read `text()` whenever the UI wants it, `finish`.
//!
//! Portable (std only): the WebSocket client is the minimum RFC 6455 needs on
//! the client side (masked frames out, unmasked frames in) over std's TLS.
const std = @import("std");

pub const Options = struct {
    api_key: []const u8,
    model: []const u8 = "nova-3",
    language: []const u8 = "pt-BR",
    smart_format: bool = true,
    mip_opt_out: bool = true,
    /// Words Deepgram should favor (nova-3 keyterm prompting): harness, machine
    /// and repo names that it would otherwise hear as "codecs" or "core 1".
    keyterms: []const []const u8 = &.{},
};

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

pub const Stream = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    connection: *std.http.Client.Connection,
    reader_thread: ?std.Thread = null,
    lock: std.Io.Mutex = .init,
    /// Results Deepgram marked final, joined; the next one is appended.
    final: std.ArrayList(u8) = .empty,
    /// The latest interim result, replaced by every new one.
    interim: std.ArrayList(u8) = .empty,
    /// Bumped on every result: the UI redraws only on change.
    revision: std.atomic.Value(u32) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    mask_state: u64,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Stream {
        const self = try gpa.create(Stream);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .client = .{ .io = io, .allocator = gpa }, .connection = undefined, .mask_state = 0 };
        errdefer self.client.deinit();
        var seed: [8]u8 = undefined;
        io.random(&seed);
        self.mask_state = std.mem.readInt(u64, &seed, .little) | 1;

        // What request() does before a TLS connection: load the root certificates.
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(gpa);
        const now = std.Io.Clock.real.now(io);
        try bundle.rescan(gpa, io, now);
        self.client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &self.client.ca_bundle, &bundle);

        const host = "api.deepgram.com";
        self.connection = try self.client.connect(try std.Io.net.HostName.init(host), 443, .tls);
        try self.handshake(host, options);
        self.reader_thread = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    fn handshake(self: *Stream, host: []const u8, options: Options) !void {
        var key_raw: [16]u8 = undefined;
        self.io.random(&key_raw);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_raw);
        const w = self.connection.writer();
        try w.print("GET /v1/listen?model={s}&language={s}&encoding=linear16&sample_rate=16000&channels=1" ++
            "&interim_results=true&smart_format={}&punctuate=true&mip_opt_out={}", .{ options.model, options.language, options.smart_format, options.mip_opt_out });
        for (options.keyterms) |term| {
            try w.writeAll("&keyterm=");
            try std.Uri.Component.percentEncode(w, term, isUnreserved);
        }
        try w.print(" HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Token {s}\r\n\r\n", .{ host, &key, options.api_key });
        try self.connection.flush();
        const r = self.connection.reader();
        const status = try r.takeDelimiterInclusive('\n');
        if (std.mem.indexOf(u8, status, " 101 ") == null) return error.DeepgramRejected;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            if (std.mem.trim(u8, line, "\r\n").len == 0) break;
        }
    }

    /// PCM16 mono 16 kHz, as captured. Safe to call from the recording thread
    /// while the reader thread runs.
    pub fn send(self: *Stream, pcm: []const u8) !void {
        if (self.closed.load(.acquire)) return error.StreamClosed;
        try self.writeFrame(0x2, pcm);
    }

    /// The transcript so far: final results, then the current interim one.
    pub fn text(self: *Stream, gpa: std.mem.Allocator) ![]u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const sep: []const u8 = if (self.final.items.len > 0 and self.interim.items.len > 0) " " else "";
        return std.mem.concat(gpa, u8, &.{ self.final.items, sep, self.interim.items });
    }

    /// Ends the audio, waits for Deepgram's last results and returns the full
    /// transcript. The stream is freed.
    pub fn finish(self: *Stream, gpa: std.mem.Allocator) ![]u8 {
        self.writeFrame(0x1, "{\"type\":\"CloseStream\"}") catch {};
        if (self.reader_thread) |t| t.join();
        self.reader_thread = null;
        // Deepgram finalizes everything on CloseStream; a leftover interim is kept.
        const result = try self.text(gpa);
        self.destroy();
        return result;
    }

    /// Drops the stream without waiting for results (Esc, errors).
    pub fn cancel(self: *Stream) void {
        self.closed.store(true, .release);
        self.connection.end() catch {};
        if (self.reader_thread) |t| t.join();
        self.reader_thread = null;
        self.destroy();
    }

    fn destroy(self: *Stream) void {
        // The socket was upgraded to a WebSocket: never reusable for HTTP.
        self.connection.closing = true;
        self.client.connection_pool.release(self.connection, self.io);
        self.final.deinit(self.gpa);
        self.interim.deinit(self.gpa);
        self.client.deinit();
        self.gpa.destroy(self);
    }

    fn nextMask(self: *Stream) [4]u8 {
        // xorshift: the mask only has to vary; servers do not check it.
        var x = self.mask_state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.mask_state = x;
        var m: [4]u8 = undefined;
        std.mem.writeInt(u32, &m, @truncate(x), .little);
        return m;
    }

    fn writeFrame(self: *Stream, opcode: u8, payload: []const u8) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const w = self.connection.writer();
        var header: [14]u8 = undefined;
        header[0] = 0x80 | opcode;
        var n: usize = 2;
        if (payload.len < 126) {
            header[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 0xffff) {
            header[1] = 0x80 | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            n = 4;
        } else {
            header[1] = 0x80 | 127;
            std.mem.writeInt(u64, header[2..10], payload.len, .big);
            n = 10;
        }
        const mask = self.nextMask();
        @memcpy(header[n .. n + 4], &mask);
        try w.writeAll(header[0 .. n + 4]);
        var chunk: [1024]u8 = undefined;
        var i: usize = 0;
        while (i < payload.len) {
            const len = @min(chunk.len, payload.len - i);
            for (0..len) |j| chunk[j] = payload[i + j] ^ mask[(i + j) % 4];
            try w.writeAll(chunk[0..len]);
            i += len;
        }
        try self.connection.flush();
    }

    fn readLoop(self: *Stream) void {
        self.readFrames() catch |err| {
            if (!self.closed.load(.acquire)) self.failure = err;
        };
        self.closed.store(true, .release);
    }

    fn readFrames(self: *Stream) !void {
        const r = self.connection.reader();
        var message: std.ArrayList(u8) = .empty;
        defer message.deinit(self.gpa);
        while (true) {
            const head = try r.takeArray(2);
            const fin = head[0] & 0x80 != 0;
            const opcode = head[0] & 0x0f;
            var len: u64 = head[1] & 0x7f;
            if (len == 126) len = std.mem.readInt(u16, try r.takeArray(2), .big);
            if (len == 127) len = std.mem.readInt(u64, try r.takeArray(8), .big);
            if (head[1] & 0x80 != 0) try r.discardAll(4); // servers never mask; tolerate it
            if (opcode == 0x8) return; // close
            const start = message.items.len;
            try message.resize(self.gpa, start + @as(usize, @intCast(len)));
            try r.readSliceAll(message.items[start..]);
            if (opcode == 0x9 or opcode == 0xA) { // ping/pong: Deepgram does not ping clients
                message.shrinkRetainingCapacity(start);
                continue;
            }
            if (!fin) continue;
            self.onMessage(message.items);
            message.clearRetainingCapacity();
        }
    }

    fn onMessage(self: *Stream, json: []const u8) void {
        const Result = struct {
            type: []const u8 = "",
            is_final: bool = false,
            channel: struct { alternatives: []const struct { transcript: []const u8 = "" } = &.{} } = .{},
        };
        const parsed = std.json.parseFromSlice(Result, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const result = parsed.value;
        if (!std.mem.eql(u8, result.type, "Results") or result.channel.alternatives.len == 0) return;
        const transcript = std.mem.trim(u8, result.channel.alternatives[0].transcript, " ");
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (result.is_final) {
            if (transcript.len > 0) {
                if (self.final.items.len > 0) self.final.append(self.gpa, ' ') catch return;
                self.final.appendSlice(self.gpa, transcript) catch return;
            }
            self.interim.clearRetainingCapacity();
        } else {
            self.interim.clearRetainingCapacity();
            self.interim.appendSlice(self.gpa, transcript) catch return;
        }
        _ = self.revision.fetchAdd(1, .release);
    }
};
