//! DeepSeek's chat API, for one short JSON answer (a dictated request cleaned
//! for a new agent): one HTTPS request without reasoning, about a second, no
//! agent CLI in between.
//! https://api-docs.deepseek.com
const std = @import("std");

pub const model = "deepseek-v4-flash";

/// One 400-token answer is a few kB. `fetch` grows its response writer without
/// bound, so the body it may write is capped here.
const max_response_len = 128 * 1024;

const Message = struct { role: []const u8, content: []const u8 };

fn parseContent(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const Reply = struct { choices: []const struct { message: Message } };
    const parsed = try std.json.parseFromSlice(Reply, gpa, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.choices.len == 0) return error.DeepSeekBadResponse;
    return gpa.dupe(u8, parsed.value.choices[0].message.content);
}

/// The model's reply to `system` + `user`, asked for as a JSON object.
/// Allocated with `gpa`.
pub fn json(gpa: std.mem.Allocator, io: std.Io, api_key: []const u8, system: []const u8, user: []const u8) ![]u8 {
    // std asserts that a header value holds no CRLF: a tampered key would abort
    // the daemon instead of failing the call.
    if (std.mem.indexOfAny(u8, api_key, "\r\n") != null) return error.InvalidApiKey;
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
    const buffer = try gpa.alloc(u8, max_response_len);
    defer gpa.free(buffer);
    var response = std.Io.Writer.fixed(buffer);
    const result = http.fetch(.{
        .location = .{ .url = "https://api.deepseek.com/chat/completions" },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = .{ .override = auth } },
        .response_writer = &response,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.DeepSeekResponseTooLarge,
        else => |e| return e,
    };
    if (result.status != .ok) return error.DeepSeekRequestFailed;
    return parseContent(gpa, response.buffered());
}

test "a hostile DeepSeek response fails instead of crashing" {
    const gpa = std.testing.allocator;
    const bodies = [_][]const u8{
        "",
        "[]",
        "null",
        "{}",
        "{\"choices\":null}",
        "{\"choices\":[]}",
        "{\"choices\":[{}]}",
        "{\"choices\":[{\"message\":{}}]}",
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":42}}]}",
    };
    for (bodies) |body| {
        if (parseContent(gpa, body)) |content| {
            gpa.free(content);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    const content = try parseContent(gpa, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"{}\"}}]}");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("{}", content);
}
