const std = @import("std");

/// Deepgram's batch answer is a JSON transcript of at most a few hundred kB;
/// anything larger is a broken or hostile server, not a transcription.
const max_response_len = 1024 * 1024;

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// The batch endpoint with every configured value percent-encoded, so a model
/// or language holding `&`, a space or CRLF cannot reshape the request.
fn writeUrl(w: *std.Io.Writer, model: []const u8, language: []const u8, smart_format: bool, mip_opt_out: bool) !void {
    try w.writeAll("https://api.deepgram.com/v1/listen?model=");
    try std.Uri.Component.percentEncode(w, model, isUnreserved);
    try w.writeAll("&language=");
    try std.Uri.Component.percentEncode(w, language, isUnreserved);
    try w.print("&smart_format={}&mip_opt_out={}", .{ smart_format, mip_opt_out });
}

/// Server-controlled bytes reach the log bounded, never a megabyte of them.
fn preview(body: []const u8) []const u8 {
    return body[0..@min(body.len, 512)];
}

fn parseTranscript(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(Response, gpa, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const channels = parsed.value.results.channels;
    if (channels.len == 0 or channels[0].alternatives.len == 0) return error.DeepgramEmptyResponse;
    return gpa.dupe(u8, channels[0].alternatives[0].transcript);
}

pub const Client = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    language: []const u8,
    smart_format: bool,
    mip_opt_out: bool,

    pub fn transcribe(self: Client, wav: []const u8) ![]u8 {
        // std asserts that a header value holds no CRLF: a key read from a
        // tampered config would abort the daemon instead of failing the call.
        if (std.mem.indexOfAny(u8, self.api_key, "\r\n") != null) return error.InvalidApiKey;
        var client = std.http.Client{ .io = self.io, .allocator = self.allocator };
        defer client.deinit();

        var uri_buffer: [1024]u8 = undefined;
        var uri_writer = std.Io.Writer.fixed(&uri_buffer);
        try writeUrl(&uri_writer, self.model, self.language, self.smart_format, self.mip_opt_out);
        const uri = try std.Uri.parse(uri_writer.buffered());

        var authorization_buffer: [4096]u8 = undefined;
        const authorization = try std.fmt.bufPrint(&authorization_buffer, "Token {s}", .{self.api_key});
        var request = try client.request(.POST, uri, .{
            // The key rides in a header std keeps across a cross-domain
            // redirect, and the endpoint never redirects: do not follow one.
            .redirect_behavior = .unhandled,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = authorization },
                .{ .name = "Content-Type", .value = "audio/wav" },
            },
        });
        defer request.deinit();

        try request.sendBodyComplete(@constCast(wav));
        var transfer_buffer: [16 * 1024]u8 = undefined;
        var response = try request.receiveHead(&.{});
        const status = response.head.status;
        var decompress: std.http.Decompress = undefined;
        var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
        const body = try body_reader.allocRemaining(self.allocator, .limited(max_response_len));
        defer self.allocator.free(body);

        if (status != .ok) {
            std.log.err("Deepgram returned HTTP {d}: {s}", .{ @intFromEnum(status), preview(body) });
            return error.DeepgramRequestFailed;
        }
        return parseTranscript(self.allocator, body) catch |err| {
            std.log.err("unexpected response from Deepgram ({d} bytes): {s}", .{ body.len, preview(body) });
            return err;
        };
    }
};

const Response = struct {
    results: Results,
};

const Results = struct {
    channels: []Channel,
};

const Channel = struct {
    alternatives: []Alternative,
};

const Alternative = struct {
    transcript: []const u8,
};

test "the batch URL percent-encodes every configured value" {
    var buffer: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try writeUrl(&w, "nova-3&language=xx", "pt-BR\r\nX: y", true, false);
    const url = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, url, "\r\n") == null);
    try std.testing.expectEqualStrings(
        "https://api.deepgram.com/v1/listen?model=nova-3%26language%3Dxx&language=pt-BR%0D%0AX%3A%20y&smart_format=true&mip_opt_out=false",
        url,
    );
    _ = try std.Uri.parse(url);
}

test "a hostile Deepgram response fails instead of crashing" {
    const gpa = std.testing.allocator;
    const bodies = [_][]const u8{
        "", "[]", "null", "{}", "{\"results\":null}", "{\"results\":{}}",
        "{\"results\":{\"channels\":[]}}", "{\"results\":{\"channels\":[{\"alternatives\":[]}]}}",
        "{\"results\":{\"channels\":[{\"alternatives\":[{}]}]}}",
    };
    for (bodies) |body| {
        if (parseTranscript(gpa, body)) |text| {
            gpa.free(text);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    const text = try parseTranscript(gpa, "{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\"hi\"}]}]}}");
    defer gpa.free(text);
    try std.testing.expectEqualStrings("hi", text);
}
