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

/// Deepgram's results are JSON of a few kB. A longer message — or a longer run
/// of continuation frames — is a hostile or broken server, and the length is
/// attacker-controlled up to 2^64, so it is capped before anything is sized by it.
const max_message_len = 1 << 20;

/// A 101 response that never ends its header block must not hold the recording
/// thread forever.
const max_handshake_headers = 64;

const Frame = struct { fin: bool, opcode: u4, len: usize };

/// One frame header, validated against RFC 6455 before its length is trusted.
fn takeHeader(r: *std.Io.Reader) !Frame {
    const head = (try r.takeArray(2)).*;
    if (head[0] & 0x70 != 0) return error.WebSocketProtocol; // no extension was negotiated
    const fin = head[0] & 0x80 != 0;
    const opcode: u4 = @truncate(head[0] & 0x0f);
    var len: u64 = head[1] & 0x7f;
    if (len == 126) {
        len = std.mem.readInt(u16, try r.takeArray(2), .big);
    } else if (len == 127) {
        len = std.mem.readInt(u64, try r.takeArray(8), .big);
    }
    if (head[1] & 0x80 != 0) try r.discardAll(4); // servers never mask; tolerate it
    if (opcode & 0x8 != 0 and (!fin or len > 125)) return error.WebSocketProtocol;
    if (len > max_message_len) return error.WebSocketMessageTooLong;
    return .{ .fin = fin, .opcode = opcode, .len = @intCast(len) };
}

/// `GET /v1/listen?...`: every configured value is percent-encoded, so a model,
/// language or keyterm holding CRLF cannot inject a header into the upgrade request.
fn writeTarget(w: *std.Io.Writer, options: Options) !void {
    try w.writeAll("GET /v1/listen?model=");
    try std.Uri.Component.percentEncode(w, options.model, isUnreserved);
    try w.writeAll("&language=");
    try std.Uri.Component.percentEncode(w, options.language, isUnreserved);
    try w.print("&encoding=linear16&sample_rate=16000&channels=1&interim_results=true" ++
        "&smart_format={}&punctuate=true&mip_opt_out={}", .{ options.smart_format, options.mip_opt_out });
    for (options.keyterms) |term| {
        try w.writeAll("&keyterm=");
        try std.Uri.Component.percentEncode(w, term, isUnreserved);
    }
}

/// RFC 6455 4.1: the server proves it completed the WebSocket handshake by
/// echoing base64(sha1(key ++ guid)). Without the check, any 101 — a confused
/// HTTP endpoint, a proxy, a cache — would be read as a stream of frames.
fn acceptToken(key: []const u8) [28]u8 {
    var sha1: std.crypto.hash.Sha1 = .init(.{});
    sha1.update(key);
    sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    var token: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&token, &digest);
    return token;
}

fn headerValue(line: []const u8, name: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return null;
    return std.mem.trim(u8, line[colon + 1 ..], " ");
}

fn readHandshakeResponse(r: *std.Io.Reader, accept: []const u8) !void {
    const status = try r.takeDelimiterInclusive('\n');
    if (std.mem.indexOf(u8, status, " 101 ") == null) return error.DeepgramRejected;
    var confirmed = false;
    for (0..max_handshake_headers) |_| {
        const line = std.mem.trim(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
        if (line.len == 0) {
            if (!confirmed) return error.WebSocketHandshakeFailed;
            return;
        }
        if (headerValue(line, "sec-websocket-accept")) |value| confirmed = std.mem.eql(u8, value, accept);
    }
    return error.WebSocketHandshakeFailed;
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
        if (std.mem.indexOfAny(u8, options.api_key, "\r\n") != null) return error.InvalidApiKey;
        const w = self.connection.writer();
        try writeTarget(w, options);
        try w.print(" HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Token {s}\r\n\r\n", .{ host, &key, options.api_key });
        try self.connection.flush();
        const accept = acceptToken(&key);
        try readHandshakeResponse(self.connection.reader(), &accept);
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
            const frame = try takeHeader(r);
            if (frame.opcode == 0x8) return; // close
            if (frame.opcode & 0x8 != 0) { // ping/pong: Deepgram does not ping clients
                try r.discardAll(frame.len);
                continue;
            }
            if (frame.opcode > 0x2) return error.WebSocketProtocol; // continuation, text or binary
            const start = message.items.len;
            if (start + frame.len > max_message_len) return error.WebSocketMessageTooLong;
            try message.resize(self.gpa, start + frame.len);
            try r.readSliceAll(message.items[start..]);
            if (!frame.fin) continue;
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

test "a frame length above the message cap is refused before anything is sized by it" {
    var r = std.Io.Reader.fixed(&[_]u8{ 0x81, 127, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    try std.testing.expectError(error.WebSocketMessageTooLong, takeHeader(&r));
}

test "a 16-bit length of 127 stays a length" {
    var r = std.Io.Reader.fixed(&[_]u8{ 0x82, 126, 0x00, 0x7f, 0xaa });
    const frame = try takeHeader(&r);
    try std.testing.expectEqual(@as(usize, 127), frame.len);
    try std.testing.expectEqual(@as(u8, 0xaa), (try r.takeArray(1))[0]);
}

test "an oversized or fragmented control frame is refused" {
    var oversized = std.Io.Reader.fixed(&[_]u8{ 0x89, 126, 0x01, 0x00 });
    try std.testing.expectError(error.WebSocketProtocol, takeHeader(&oversized));
    var fragmented = std.Io.Reader.fixed(&[_]u8{ 0x09, 0x02 });
    try std.testing.expectError(error.WebSocketProtocol, takeHeader(&fragmented));
    var reserved = std.Io.Reader.fixed(&[_]u8{ 0xc1, 0x00 });
    try std.testing.expectError(error.WebSocketProtocol, takeHeader(&reserved));
}

test "the request target percent-encodes every configured value" {
    var buffer: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try writeTarget(&w, .{ .api_key = "k", .model = "nova-3\r\nX: y", .keyterms = &.{"Agent Belt"} });
    const target = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, target, "\r\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, target, "model=nova-3%0D%0AX%3A%20y&") != null);
    try std.testing.expect(std.mem.indexOf(u8, target, "&keyterm=Agent%20Belt") != null);
}

test "the 101 response is accepted only with the matching Sec-WebSocket-Accept" {
    const key = "dGhlIHNhbXBsZSBub25jZQ=="; // RFC 6455 1.3
    const accept = acceptToken(key);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
    var forged = std.Io.Reader.fixed("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: AAAA\r\n\r\n");
    try std.testing.expectError(error.WebSocketHandshakeFailed, readHandshakeResponse(&forged, &accept));
    var missing = std.Io.Reader.fixed("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n");
    try std.testing.expectError(error.WebSocketHandshakeFailed, readHandshakeResponse(&missing, &accept));
    var genuine = std.Io.Reader.fixed("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n");
    try readHandshakeResponse(&genuine, &accept);
}

test "an endless header block ends the handshake" {
    var buffer: [64 + max_handshake_headers * 8]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try w.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    for (0..max_handshake_headers) |_| try w.writeAll("X: y\r\n");
    var r = std.Io.Reader.fixed(w.buffered());
    try std.testing.expectError(error.WebSocketHandshakeFailed, readHandshakeResponse(&r, "x"));
}
