//! DeepSeek's chat API, for one short JSON answer (a dictated request cleaned
//! for a new agent): one HTTPS request without reasoning, about a second, no
//! agent CLI in between.
//! https://api-docs.deepseek.com
const std = @import("std");

pub const model = "deepseek-v4-flash";

/// The model's reply to `system` + `user`, asked for as a JSON object.
/// Allocated with `gpa`.
pub fn json(gpa: std.mem.Allocator, io: std.Io, api_key: []const u8, system: []const u8, user: []const u8) ![]u8 {
    const Message = struct { role: []const u8, content: []const u8 };
    const body = try std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(.{
        .model = model,
        .temperature = 0,
        .max_tokens = 400,
        .thinking = .{ .type = "disabled" },
        .response_format = .{ .type = "json_object" },
        .messages = [_]Message{ .{ .role = "system", .content = system }, .{ .role = "user", .content = user } },
    }, .{})});
    defer gpa.free(body);
    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key});
    defer gpa.free(auth);

    var http: std.http.Client = .{ .io = io, .allocator = gpa };
    defer http.deinit();
    var response: std.Io.Writer.Allocating = .init(gpa);
    defer response.deinit();
    const result = try http.fetch(.{
        .location = .{ .url = "https://api.deepseek.com/chat/completions" },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = .{ .override = auth } },
        .response_writer = &response.writer,
    });
    if (result.status != .ok) return error.DeepSeekRequestFailed;

    const Reply = struct { choices: []const struct { message: Message } };
    const parsed = try std.json.parseFromSlice(Reply, gpa, response.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.choices.len == 0) return error.DeepSeekBadResponse;
    return gpa.dupe(u8, parsed.value.choices[0].message.content);
}
