const std = @import("std");

pub const Client = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    language: []const u8,
    smart_format: bool,
    mip_opt_out: bool,

    pub fn transcribe(self: Client, wav: []const u8) ![]u8 {
        var client = std.http.Client{ .io = self.io, .allocator = self.allocator };
        defer client.deinit();

        var uri_buffer: [1024]u8 = undefined;
        const uri_text = try std.fmt.bufPrint(&uri_buffer, "https://api.deepgram.com/v1/listen?model={s}&language={s}&smart_format={s}&mip_opt_out={s}", .{
            self.model,
            self.language,
            if (self.smart_format) "true" else "false",
            if (self.mip_opt_out) "true" else "false",
        });
        const uri = try std.Uri.parse(uri_text);

        var authorization_buffer: [4096]u8 = undefined;
        const authorization = try std.fmt.bufPrint(&authorization_buffer, "Token {s}", .{self.api_key});
        var request = try client.request(.POST, uri, .{
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
        const body = try body_reader.allocRemaining(self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(body);

        if (status != .ok) {
            std.log.err("Deepgram retornou HTTP {d}: {s}", .{ @intFromEnum(status), body });
            return error.DeepgramRequestFailed;
        }

        const parsed = std.json.parseFromSlice(Response, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("resposta inválida do Deepgram (HTTP {d}, {d} bytes): {s}", .{
                @intFromEnum(status), body.len, body[0..@min(body.len, 1024)],
            });
            return err;
        };
        defer parsed.deinit();
        if (parsed.value.results.channels.len == 0 or
            parsed.value.results.channels[0].alternatives.len == 0)
        {
            return error.DeepgramEmptyResponse;
        }
        return try self.allocator.dupe(u8, parsed.value.results.channels[0].alternatives[0].transcript);
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
