//! What a Claude Code session has done, for the session listing on every
//! machine: tokens, cost, and a one-line recap. The same reading as the Mac
//! menu's (src/agent_stats.m): the transcript
//! (~/.claude/projects/*/<sessionId>.jsonl, and its subagents) carries usage
//! per message, the titles and the recap. A transcript grows to hundreds of
//! megabytes, and the listing runs every 15 s, so each one is read once and
//! then only from where the last reading stopped; that position and the sums
//! live in the cache (<cache>/agent-belt/transcripts/<name>.json).

const std = @import("std");
const sys = @import("sys.zig");

pub const Info = struct {
    tokens: u64 = 0,
    cost: f64 = 0,
    cost_known: bool = true,
    /// The recap Claude writes when you step away, else your last prompt.
    recap: []const u8 = "",
    title: []const u8 = "",
};

/// What is kept between readings of one transcript.
const State = struct {
    inode: u64 = 0,
    offset: u64 = 0,
    tokens: u64 = 0,
    cost: f64 = 0,
    unknown_price: bool = false,
    /// A message's content blocks repeat its usage on consecutive lines.
    last_id: []const u8 = "",
    ai_title: []const u8 = "",
    custom_title: []const u8 = "",
    away_summary: []const u8 = "",
    last_prompt: []const u8 = "",
};

// USD per million tokens (platform.claude.com/docs/en/about-claude/pricing,
// 2026-09-23): input, cache write 5 min, cache write 1 h, cache read, output.
// Longest prefix first; keep in step with src/agent_stats.m.
const Price = struct { prefix: []const u8, in: f64, write5m: f64, write1h: f64, read: f64, out: f64 };
const prices = [_]Price{
    .{ .prefix = "claude-fable-5-1", .in = 10, .write5m = 12.5, .write1h = 20, .read = 0.25, .out = 50 },
    .{ .prefix = "claude-fable-5", .in = 10, .write5m = 12.5, .write1h = 20, .read = 1, .out = 50 },
    .{ .prefix = "claude-opus-5-5", .in = 4, .write5m = 5, .write1h = 8, .read = 0.2, .out = 20 },
    .{ .prefix = "claude-opus-5", .in = 5, .write5m = 6.25, .write1h = 10, .read = 0.5, .out = 25 },
    .{ .prefix = "claude-opus-4-8", .in = 5, .write5m = 6.25, .write1h = 10, .read = 0.5, .out = 25 },
    .{ .prefix = "claude-opus-4-6", .in = 5, .write5m = 6.25, .write1h = 10, .read = 0.5, .out = 25 },
    .{ .prefix = "claude-sonnet-5", .in = 2, .write5m = 2.5, .write1h = 4, .read = 0.2, .out = 10 },
    .{ .prefix = "claude-haiku-4-5", .in = 1, .write5m = 1.25, .write1h = 2, .read = 0.1, .out = 5 },
};

fn priceFor(model: []const u8) ?Price {
    for (prices) |p| if (std.mem.startsWith(u8, model, p.prefix)) return p;
    return null;
}

const Usage = struct {
    input_tokens: f64 = 0,
    output_tokens: f64 = 0,
    cache_read_input_tokens: f64 = 0,
    cache_creation_input_tokens: f64 = 0,
    cache_creation: ?struct { ephemeral_5m_input_tokens: f64 = 0, ephemeral_1h_input_tokens: f64 = 0 } = null,
    inference_geo: []const u8 = "",
};

const Line = struct {
    type: []const u8 = "",
    subtype: []const u8 = "",
    aiTitle: []const u8 = "",
    customTitle: []const u8 = "",
    lastPrompt: []const u8 = "",
    content: std.json.Value = .null,
    message: ?struct { id: []const u8 = "", model: []const u8 = "", usage: ?Usage = null } = null,
};

/// Adds one transcript line to the state. Most lines (tool results, the
/// user's messages) matter to none of the sums and are skipped unparsed.
fn take(gpa: std.mem.Allocator, st: *State, line: []const u8) void {
    const assistant = std.mem.indexOf(u8, line, "\"type\":\"assistant\"") != null;
    const markers = [_][]const u8{ "\"ai-title\"", "\"custom-title\"", "\"away_summary\"", "\"last-prompt\"" };
    if (!assistant) {
        const interesting = for (markers) |m| {
            if (std.mem.indexOf(u8, line, m) != null) break true;
        } else false;
        if (!interesting) return;
    }
    // Copies: the line lives in the reader's buffer, which the next read reuses.
    const r = std.json.parseFromSliceLeaky(Line, gpa, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
    if (std.mem.eql(u8, r.type, "ai-title")) {
        if (r.aiTitle.len > 0) st.ai_title = r.aiTitle;
    } else if (std.mem.eql(u8, r.type, "custom-title")) {
        if (r.customTitle.len > 0) st.custom_title = r.customTitle;
    } else if (std.mem.eql(u8, r.type, "last-prompt")) {
        if (r.lastPrompt.len > 0) st.last_prompt = r.lastPrompt;
    } else if (std.mem.eql(u8, r.type, "system") and std.mem.eql(u8, r.subtype, "away_summary")) {
        if (r.content == .string) st.away_summary = r.content.string;
    } else if (std.mem.eql(u8, r.type, "assistant")) {
        const m = r.message orelse return;
        const u = m.usage orelse return;
        if (m.id.len == 0 or m.model.len == 0 or std.mem.eql(u8, m.model, "<synthetic>") or std.mem.eql(u8, m.id, st.last_id)) return;
        st.last_id = m.id;
        const written = u.cache_creation_input_tokens;
        const write1h = if (u.cache_creation) |c| c.ephemeral_1h_input_tokens else 0;
        const write5m = if (u.cache_creation) |c| c.ephemeral_5m_input_tokens else written;
        st.tokens += @intFromFloat(u.input_tokens + u.output_tokens + u.cache_read_input_tokens + written);
        const p = priceFor(m.model) orelse {
            st.unknown_price = true;
            return;
        };
        var cost = (u.input_tokens * p.in + write5m * p.write5m + write1h * p.write1h + u.cache_read_input_tokens * p.read + u.output_tokens * p.out) / 1e6;
        if (std.mem.eql(u8, u.inference_geo, "us")) cost *= 1.1;
        st.cost += cost;
    }
}

/// Reads what was appended to a transcript since the last reading (the whole
/// file the first time, or when it was replaced or truncated).
fn read(ctx: sys.Ctx, path: []const u8) ?State {
    const cache = cachePath(ctx, path) catch return null;
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(ctx.io, path, .{}) catch return null;
    defer file.close(ctx.io);
    const stat = file.stat(ctx.io) catch return null;
    var st: State = .{};
    if (sys.readFile(ctx, cache)) |bytes| {
        if (std.json.parseFromSliceLeaky(State, ctx.gpa, bytes, .{ .ignore_unknown_fields = true })) |saved| st = saved else |_| {}
    }
    // The file's identity: an inode, or on Windows a file index (signed there).
    const inode: u64 = @bitCast(stat.inode);
    if (st.inode != inode or stat.size < st.offset) st = .{ .inode = inode };
    if (stat.size == st.offset) return st;
    var buf: [256 * 1024]u8 = undefined;
    var reader = file.reader(ctx.io, &buf);
    reader.seekTo(st.offset) catch return st;
    // Whole lines only: a line still being written is read next time.
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            // Longer than the buffer: a big tool result or file, no usage in it.
            error.StreamTooLong => {
                st.offset += reader.interface.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            else => break,
        };
        take(ctx.gpa, &st, line[0 .. line.len - 1]);
        st.offset += line.len;
    }
    std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(cache).?) catch {};
    const json = std.json.Stringify.valueAlloc(ctx.gpa, st, .{}) catch return st;
    sys.writeFileAtomic(ctx, cache, json) catch {};
    return st;
}

fn cachePath(ctx: sys.Ctx, transcript: []const u8) ![]const u8 {
    const name = try ctx.fmt("{x}.json", .{std.hash.Wyhash.hash(0, transcript)});
    return ctx.join(&.{ try sys.cacheDir(ctx), "transcripts", name });
}

/// The transcript of a conversation: the project folder encodes the working
/// directory lossily, so it is searched.
fn transcriptPath(ctx: sys.Ctx, session_id: []const u8) ?[]const u8 {
    const projects = ctx.join(&.{ ctx.home(), ".claude", "projects" }) catch return null;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, projects, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);
    const file = ctx.fmt("{s}.jsonl", .{session_id}) catch return null;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const path = ctx.join(&.{ projects, entry.name, file }) catch continue;
        if (sys.isFile(ctx, path)) return path;
    }
    return null;
}

/// A conversation's sums, its subagents' included.
pub fn claude(ctx: sys.Ctx, session_id: []const u8) ?Info {
    const path = transcriptPath(ctx, session_id) orelse return null;
    const main = read(ctx, path) orelse return null;
    var info = Info{ .tokens = main.tokens, .cost = main.cost, .cost_known = !main.unknown_price };
    info.title = if (main.custom_title.len > 0) main.custom_title else main.ai_title;
    info.recap = oneLine(ctx, if (main.away_summary.len > 0) main.away_summary else main.last_prompt);
    const subagents = ctx.join(&.{ path[0 .. path.len - ".jsonl".len], "subagents" }) catch return info;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, subagents, .{ .iterate = true }) catch return info;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const sub = read(ctx, ctx.join(&.{ subagents, entry.name }) catch continue) orelse continue;
        info.tokens += sub.tokens;
        info.cost += sub.cost;
        if (sub.unknown_price) info.cost_known = false;
    }
    return info;
}

/// Text for one column: lines joined, the recap's footer and "|" (the
/// listing's separator) removed.
pub fn oneLine(ctx: sys.Ctx, text: []const u8) []const u8 {
    const cut = std.mem.indexOf(u8, text, " (disable recaps in /config)") orelse text.len;
    const out = ctx.gpa.dupe(u8, std.mem.trim(u8, text[0..cut], " \r\n\t")) catch return "";
    for (out) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t' or c.* == '|') {
        c.* = ' ';
    };
    return out;
}

test "a transcript's usage is summed once per message, with the recap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var st: State = .{};
    const lines = [_][]const u8{
        \\{"type":"user","message":{"content":"fix the login"}}
        ,
        \\{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        ,
        \\{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        ,
        \\{"type":"assistant","message":{"id":"m2","model":"claude-sonnet-5","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":0}}}
        ,
        \\{"type":"system","subtype":"away_summary","content":"Login fixed;\nnext: the tests. (disable recaps in /config)"}
        ,
        \\{"type":"custom-title","customTitle":"login review"}
    };
    for (lines) |l| take(gpa, &st, l);
    try std.testing.expectEqual(@as(u64, 1_001_500), st.tokens);
    // opus-5-5: 1000 in at 4 + 500 out at 20 = 0.014; sonnet-5: 1M cache reads at 0.2
    try std.testing.expectApproxEqAbs(@as(f64, 0.214), st.cost, 1e-9);
    try std.testing.expectEqualStrings("login review", st.custom_title);

    var env = std.process.Environ.Map.init(gpa);
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = gpa, .env = &env };
    try std.testing.expectEqualStrings("Login fixed; next: the tests.", oneLine(ctx, st.away_summary));
    try std.testing.expectEqualStrings("a b", oneLine(ctx, "a|b"));
}
