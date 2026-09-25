//! Jev (TypeSafe System One): a decision model. A request carries a `state` and
//! typed questions; the answer to each comes back under the same key. Agent
//! Belt only asks `choice` questions. https://docs.typesafe.ai/api
const std = @import("std");

pub const model = "jev-1.13.0"; // pinned: confidence thresholds are calibrated against it

pub const Option = struct { name: []const u8, description: ?[]const u8 = null };

pub const Question = struct {
    key: []const u8,
    instructions: []const u8,
    options: []const Option,
};

pub const Choice = struct { choice: []const u8, confidence: f64 };

/// Jev answers one small JSON object per request. `fetch` grows its response
/// writer without bound, so the body it may write is capped here.
const max_response_len = 256 * 1024;

fn field(value: std.json.Value, key: []const u8) !std.json.Value {
    if (value != .object) return error.JevBadResponse;
    return value.object.get(key) orelse error.JevBadResponse;
}

fn confidenceOf(answer: std.json.Value) f64 {
    return switch (field(answer, "confidence") catch return 0) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

/// The answers, in question order. Every shape other than the documented one is
/// an error: reading a `json.Value` as the wrong union field would abort.
fn parseChoices(gpa: std.mem.Allocator, body: []const u8, questions: []const Question) ![]Choice {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const answers = try field(parsed.value, "answers");
    const out = try gpa.alloc(Choice, questions.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |c| gpa.free(c.choice);
        gpa.free(out);
    }
    for (questions, out) |q, *o| {
        const answer = try field(answers, q.key);
        const choice = try field(answer, "choice");
        if (choice != .string) return error.JevBadResponse;
        o.* = .{ .choice = try gpa.dupe(u8, choice.string), .confidence = confidenceOf(answer) };
        filled += 1;
    }
    return out;
}

pub const Client = struct {
    http: std.http.Client,
    api_key: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, api_key: []const u8) Client {
        return .{ .http = .{ .io = io, .allocator = gpa }, .api_key = api_key };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    /// Asks every question against the same state in one request. Answers come
    /// back in question order, allocated with `gpa`.
    pub fn choices(self: *Client, gpa: std.mem.Allocator, state: anytype, questions: []const Question) ![]Choice {
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        var s: std.json.Stringify = .{ .writer = &body.writer };
        try s.beginObject();
        try s.objectField("model");
        try s.write(model);
        try s.objectField("state");
        try s.write(state);
        try s.objectField("questions");
        try s.beginObject();
        for (questions) |q| {
            try s.objectField(q.key);
            try s.beginObject();
            try s.objectField("type");
            try s.write("choice");
            try s.objectField("instructions");
            try s.write(q.instructions);
            try s.objectField("criteria");
            try s.beginObject();
            for (q.options) |o| {
                try s.objectField(o.name);
                try s.write(o.description);
            }
            try s.endObject();
            try s.endObject();
        }
        try s.endObject();
        try s.endObject();

        // std asserts that a header value holds no CRLF: a tampered key would
        // abort the daemon instead of failing the call.
        if (std.mem.indexOfAny(u8, self.api_key, "\r\n") != null) return error.InvalidApiKey;
        const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{self.api_key});
        defer gpa.free(auth);
        const buffer = try gpa.alloc(u8, max_response_len);
        defer gpa.free(buffer);
        var response = std.Io.Writer.fixed(buffer);
        const result = self.http.fetch(.{
            .location = .{ .url = "https://api.typesafe.ai/v1/systemone" },
            .method = .POST,
            .payload = body.written(),
            .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = .{ .override = auth } },
            .response_writer = &response,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.JevResponseTooLarge,
            else => |e| return e,
        };
        if (result.status != .ok) return error.JevRequestFailed;
        return parseChoices(gpa, response.buffered(), questions);
    }
};

test "a hostile Jev response fails instead of crashing" {
    const gpa = std.testing.allocator;
    const questions = [_]Question{.{ .key = "machine", .instructions = "", .options = &.{} }};
    const bodies = [_][]const u8{
        "",
        "[]",
        "null",
        "\"answers\"",
        "{}",
        "{\"answers\":[]}",
        "{\"answers\":\"machine\"}",
        "{\"answers\":{}}",
        "{\"answers\":{\"machine\":[]}}",
        "{\"answers\":{\"machine\":{}}}",
        "{\"answers\":{\"machine\":{\"choice\":42}}}",
        "{\"answers\":{\"machine\":{\"choice\":null}}}",
    };
    for (bodies) |body| {
        if (parseChoices(gpa, body, &questions)) |out| {
            for (out) |c| gpa.free(c.choice);
            gpa.free(out);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "a Jev answer without a usable confidence reads as zero" {
    const gpa = std.testing.allocator;
    const questions = [_]Question{.{ .key = "machine", .instructions = "", .options = &.{} }};
    const out = try parseChoices(gpa, "{\"answers\":{\"machine\":{\"choice\":\"orca\",\"confidence\":\"high\"}}}", &questions);
    defer {
        for (out) |c| gpa.free(c.choice);
        gpa.free(out);
    }
    try std.testing.expectEqualStrings("orca", out[0].choice);
    try std.testing.expectEqual(@as(f64, 0), out[0].confidence);
}

test "a Jev answer missing from the reply frees what was already parsed" {
    const gpa = std.testing.allocator;
    const questions = [_]Question{
        .{ .key = "machine", .instructions = "", .options = &.{} },
        .{ .key = "repo", .instructions = "", .options = &.{} },
    };
    try std.testing.expectError(
        error.JevBadResponse,
        parseChoices(gpa, "{\"answers\":{\"machine\":{\"choice\":\"orca\",\"confidence\":1}}}", &questions),
    );
}
