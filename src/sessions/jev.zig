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

        const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{self.api_key});
        defer gpa.free(auth);
        var response: std.Io.Writer.Allocating = .init(gpa);
        defer response.deinit();
        const result = try self.http.fetch(.{
            .location = .{ .url = "https://api.typesafe.ai/v1/systemone" },
            .method = .POST,
            .payload = body.written(),
            .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = .{ .override = auth } },
            .response_writer = &response.writer,
        });
        if (result.status != .ok) return error.JevRequestFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, response.written(), .{});
        defer parsed.deinit();
        const answers = (parsed.value.object.get("answers") orelse return error.JevBadResponse).object;
        const out = try gpa.alloc(Choice, questions.len);
        for (questions, out) |q, *o| {
            const a = (answers.get(q.key) orelse return error.JevBadResponse).object;
            o.* = .{
                .choice = try gpa.dupe(u8, (a.get("choice") orelse return error.JevBadResponse).string),
                .confidence = switch (a.get("confidence") orelse std.json.Value{ .float = 0 }) {
                    .float => |f| f,
                    .integer => |i| @floatFromInt(i),
                    else => 0,
                },
            };
        }
        return out;
    }
};
