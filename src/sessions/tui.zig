//! `agb sessions`: every machine's sessions in a live list. It opens at once
//! on the last listing (the snapshot the daemon, tray or bar keeps fresh),
//! refreshes in the background every few seconds, and acts on the selected
//! session: open it (and come back here on detach), close it, rename it, or
//! look at its screen.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const hosts = @import("hosts.zig");
const cli = @import("cli.zig");

const refresh_every_s = 5;

// ---------------------------------------------------------------- terminal

const Term = struct {
    const windows = builtin.os.tag == .windows;
    saved: if (windows) [2]u32 else std.posix.termios = undefined,

    const k32 = if (windows) struct {
        const HANDLE = *anyopaque;
        const COORD = extern struct { X: i16, Y: i16 };
        const RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
        const INFO = extern struct { dwSize: COORD, dwCursorPosition: COORD, wAttributes: u16, srWindow: RECT, dwMaximumWindowSize: COORD };
        extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?HANDLE;
        extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *u32) callconv(.winapi) i32;
        extern "kernel32" fn SetConsoleMode(h: HANDLE, mode: u32) callconv(.winapi) i32;
        extern "kernel32" fn SetConsoleCP(cp: u32) callconv(.winapi) i32;
        extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) i32;
        extern "kernel32" fn GetConsoleScreenBufferInfo(h: HANDLE, info: *INFO) callconv(.winapi) i32;
        extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
        extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
        const input: u32 = @bitCast(@as(i32, -10));
        const output: u32 = @bitCast(@as(i32, -11));
    } else struct {};

    /// Keys one at a time, no echo; the screen switches to the alternate
    /// buffer and back, as full-screen programs do.
    fn enter(t: *Term, io: std.Io) bool {
        if (windows) {
            const in = k32.GetStdHandle(k32.input) orelse return false;
            const out = k32.GetStdHandle(k32.output) orelse return false;
            if (k32.GetConsoleMode(in, &t.saved[0]) == 0 or k32.GetConsoleMode(out, &t.saved[1]) == 0) return false;
            _ = k32.SetConsoleCP(65001);
            _ = k32.SetConsoleOutputCP(65001);
            // Virtual terminal input (arrows arrive as ESC [ A), no line editing, no echo.
            _ = k32.SetConsoleMode(in, 0x0200);
            _ = k32.SetConsoleMode(out, t.saved[1] | 0x0004 | 0x0001);
        } else {
            t.saved = std.posix.tcgetattr(0) catch return false;
            var raw = t.saved;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            raw.lflag.ISIG = false;
            raw.iflag.IXON = false;
            raw.iflag.ICRNL = false;
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            std.posix.tcsetattr(0, .NOW, raw) catch return false;
        }
        write(io, "\x1b[?1049h\x1b[?25l");
        return true;
    }

    fn leave(t: *Term, io: std.Io) void {
        write(io, "\x1b[?25h\x1b[?1049l");
        if (windows) {
            if (k32.GetStdHandle(k32.input)) |in| _ = k32.SetConsoleMode(in, t.saved[0]);
            if (k32.GetStdHandle(k32.output)) |out| _ = k32.SetConsoleMode(out, t.saved[1]);
        } else std.posix.tcsetattr(0, .NOW, t.saved) catch {};
    }

    fn size() struct { cols: usize, rows: usize } {
        if (windows) {
            var info: k32.INFO = undefined;
            const out = k32.GetStdHandle(k32.output) orelse return .{ .cols = 100, .rows = 30 };
            if (k32.GetConsoleScreenBufferInfo(out, &info) == 0) return .{ .cols = 100, .rows = 30 };
            return .{ .cols = @intCast(info.srWindow.Right - info.srWindow.Left + 1), .rows = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1) };
        }
        var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = switch (builtin.os.tag) {
            .linux => std.os.linux.ioctl(1, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws)),
            else => @as(usize, @bitCast(@as(isize, std.c.ioctl(1, std.c.T.IOCGWINSZ, &ws)))),
        };
        if (rc != 0 or ws.col == 0) return .{ .cols = 100, .rows = 30 };
        return .{ .cols = ws.col, .rows = ws.row };
    }

    /// Up to `buf.len` bytes of input, or none after `ms` milliseconds.
    fn read(buf: []u8, ms: u32) usize {
        if (windows) {
            const in = k32.GetStdHandle(k32.input) orelse return 0;
            if (k32.WaitForSingleObject(in, ms) != 0) return 0;
            var n: u32 = 0;
            if (k32.ReadFile(in, buf.ptr, @intCast(buf.len), &n, null) == 0) return 0;
            return n;
        }
        var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, @intCast(ms)) catch return 0;
        if (ready == 0) return 0;
        return std.posix.read(0, buf) catch 0;
    }

    fn write(io: std.Io, bytes: []const u8) void {
        std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
    }
};

const Key = union(enum) { up, down, home, end, enter, escape, char: u8, none };

/// The first key in `bytes` and how many bytes it took: one read can hold
/// several (a pasted name, keys pressed quickly).
fn nextKey(bytes: []const u8) struct { key: Key, len: usize } {
    if (bytes.len == 0) return .{ .key = .none, .len = 0 };
    if (bytes[0] == 0x1b) {
        if (bytes.len == 1 or (bytes[1] != '[' and bytes[1] != 'O')) return .{ .key = .escape, .len = 1 };
        // CSI/SS3: parameters, then a final byte (a letter or ~).
        var end: usize = 2;
        while (end < bytes.len and !(std.ascii.isAlphabetic(bytes[end]) or bytes[end] == '~')) end += 1;
        const len = @min(end + 1, bytes.len);
        const seq = bytes[1..len];
        const key: Key = if (std.mem.eql(u8, seq, "[A") or std.mem.eql(u8, seq, "OA")) .up else if (std.mem.eql(u8, seq, "[B") or std.mem.eql(u8, seq, "OB")) .down else if (std.mem.eql(u8, seq, "[H") or std.mem.eql(u8, seq, "[1~")) .home else if (std.mem.eql(u8, seq, "[F") or std.mem.eql(u8, seq, "[4~")) .end else .none;
        return .{ .key = key, .len = len };
    }
    const key: Key = switch (bytes[0]) {
        '\r', '\n' => .enter,
        3 => .{ .char = 'q' }, // Ctrl-C
        else => .{ .char = bytes[0] },
    };
    return .{ .key = key, .len = 1 };
}

/// Does `bytes` end in the middle of an escape sequence?
fn incomplete(bytes: []const u8) bool {
    const esc = std.mem.lastIndexOfScalar(u8, bytes, 0x1b) orelse return false;
    const seq = bytes[esc + 1 ..];
    if (seq.len == 0) return true;
    if (seq[0] != '[' and seq[0] != 'O') return false;
    for (seq[1..]) |c| if (std.ascii.isAlphabetic(c) or c == '~') return false;
    return true;
}

fn decode(bytes: []const u8) Key {
    return nextKey(bytes).key;
}

// ---------------------------------------------------------------- state

/// One listing and the memory it lives in: each refresh brings its own, and
/// the one it replaces is freed on the main thread.
const Listing = struct {
    arena: *std.heap.ArenaAllocator,
    collected: cli.Collected,
    at: i64,
};

const Shared = struct {
    lock: std.Io.Mutex = .init,
    pending: ?Listing = null,
    refreshing: bool = false,
    /// The selected session's screen, in memory of its own (preview_arena).
    preview: ?[]const u8 = null,
    preview_for: []const u8 = "",
    preview_arena: ?*std.heap.ArenaAllocator = null,
    wake: std.atomic.Value(bool) = .init(false),
};

const Mode = enum { list, confirm_close, rename };

const Ui = struct {
    ctx: sys.Ctx,
    reg: hosts.Registry,
    shared: *Shared,
    listing: ?Listing = null,
    selected: usize = 0,
    selected_key: []const u8 = "",
    mode: Mode = .list,
    input: std.ArrayList(u8) = .empty,
    show_preview: bool = false,
    message: []const u8 = "",
    quit: bool = false,

    fn rows(ui: *const Ui) []const cli.Row {
        return if (ui.listing) |l| l.collected.rows else &.{};
    }

    fn current(ui: *const Ui) ?cli.Row {
        const r = ui.rows();
        return if (ui.selected < r.len) r[ui.selected] else null;
    }
};

fn newArena() ?*std.heap.ArenaAllocator {
    const a = std.heap.page_allocator.create(std.heap.ArenaAllocator) catch return null;
    a.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return a;
}

fn freeListing(l: Listing) void {
    l.arena.deinit();
    std.heap.page_allocator.destroy(l.arena);
}

fn refresher(ctx: sys.Ctx, reg: hosts.Registry, shared: *Shared) void {
    while (true) {
        shared.lock.lockUncancelable(ctx.io);
        shared.refreshing = true;
        shared.lock.unlock(ctx.io);
        shared.wake.store(true, .release);
        if (newArena()) |arena| {
            var c = ctx;
            c.gpa = arena.allocator();
            if (cli.collect(c, reg)) |collected| {
                shared.lock.lockUncancelable(ctx.io);
                if (shared.pending) |old| freeListing(old);
                shared.pending = .{ .arena = arena, .collected = collected, .at = std.Io.Clock.real.now(ctx.io).toSeconds() };
                shared.lock.unlock(ctx.io);
            } else |_| freeListing(.{ .arena = arena, .collected = undefined, .at = 0 });
        }
        shared.lock.lockUncancelable(ctx.io);
        shared.refreshing = false;
        shared.lock.unlock(ctx.io);
        shared.wake.store(true, .release);
        std.Io.sleep(ctx.io, .fromSeconds(refresh_every_s), .awake) catch {};
    }
}

/// The end of the selected session's screen, fetched off the main thread
/// (from another machine it takes an ssh round trip). The worker works on
/// copies in its own arena: a refresh frees the listing the row came from.
const PreviewJob = struct { arena: *std.heap.ArenaAllocator, ctx: sys.Ctx, row: cli.Row, key: []const u8 };

fn previewJob(ctx: sys.Ctx, row: cli.Row, key: []const u8) ?PreviewJob {
    const arena = newArena() orelse return null;
    const a = arena.allocator();
    var c = ctx;
    c.gpa = a;
    var r = row;
    r.name = a.dupe(u8, row.name) catch return null;
    r.host = .{ .name = a.dupe(u8, row.host.name) catch return null, .target = a.dupe(u8, row.host.target) catch return null, .kind = row.host.kind };
    return .{ .arena = arena, .ctx = c, .row = r, .key = a.dupe(u8, key) catch return null };
}

fn previewer(job: PreviewJob, shared: *Shared) void {
    const text = cli.peekRow(job.ctx, job.row, 12);
    shared.lock.lockUncancelable(job.ctx.io);
    const old = shared.preview_arena;
    shared.preview = text;
    shared.preview_for = job.key;
    shared.preview_arena = job.arena;
    shared.lock.unlock(job.ctx.io);
    if (old) |arena| freeListing(.{ .arena = arena, .collected = undefined, .at = 0 });
    shared.wake.store(true, .release);
}

fn rowKey(ctx: sys.Ctx, r: cli.Row) []const u8 {
    return ctx.fmt("{s}\x00{s}", .{ r.host.name, r.name }) catch r.name;
}

// ---------------------------------------------------------------- drawing

const dim = "\x1b[2m";
const bold = "\x1b[1m";
const reset = "\x1b[0m";
const inverse = "\x1b[7m";

fn stateCell(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "working")) return "\x1b[36m● working\x1b[0m";
    if (std.mem.eql(u8, state, "waiting")) return "\x1b[31m● waiting\x1b[0m";
    return "\x1b[2m○ idle\x1b[0m   ";
}

/// Width on screen of UTF-8 text: one column per code point (agb's names and
/// recaps have no wide characters worth measuring), colors not counted.
fn width(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == 0x1b) {
            while (i < text.len and text[i] != 'm') i += 1;
            continue;
        }
        if (text[i] & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// `text` cut to `cols` columns, or padded to them.
fn fit(ctx: sys.Ctx, text: []const u8, cols: usize) []const u8 {
    if (width(text) <= cols) {
        const pad = ctx.gpa.alloc(u8, cols - width(text)) catch return text;
        @memset(pad, ' ');
        return std.mem.concat(ctx.gpa, u8, &.{ text, pad }) catch text;
    }
    if (cols == 0) return "";
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] & 0xC0 != 0x80) {
            if (n == cols - 1) break;
            n += 1;
        }
    }
    return std.mem.concat(ctx.gpa, u8, &.{ text[0..i], "…" }) catch text;
}

fn tokensText(ctx: sys.Ctx, tokens: u64) []const u8 {
    if (tokens == 0) return "";
    const t: f64 = @floatFromInt(tokens);
    if (t >= 1e6) return ctx.fmt("{d:.1}M", .{t / 1e6}) catch "";
    return ctx.fmt("{d:.0}k", .{t / 1e3}) catch "";
}

fn costText(ctx: sys.Ctx, cost: []const u8) []const u8 {
    if (cost.len == 0) return "";
    return ctx.fmt("${s}", .{cost}) catch "";
}

fn ago(ctx: sys.Ctx, seconds: i64) []const u8 {
    if (seconds < 60) return ctx.fmt("{d}s ago", .{seconds}) catch "";
    if (seconds < 3600) return ctx.fmt("{d} min ago", .{@divTrunc(seconds, 60)}) catch "";
    return ctx.fmt("{d} h ago", .{@divTrunc(seconds, 3600)}) catch "";
}

/// Wraps `text` into at most `lines` lines of `cols` columns.
fn wrap(ctx: sys.Ctx, out: *std.ArrayList(u8), text: []const u8, cols: usize, lines: usize, indent: []const u8) void {
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    var line: std.ArrayList(u8) = .empty;
    var used: usize = 0;
    while (words.next()) |w| {
        if (line.items.len > 0 and width(line.items) + 1 + width(w) > cols) {
            used += 1;
            const last = used == lines;
            out.appendSlice(ctx.gpa, indent) catch return;
            out.appendSlice(ctx.gpa, if (last) fit(ctx, std.mem.concat(ctx.gpa, u8, &.{ line.items, " ", w, " …" }) catch line.items, cols) else line.items) catch return;
            out.appendSlice(ctx.gpa, "\x1b[K\r\n") catch return;
            if (last) return;
            line = .empty;
        }
        if (line.items.len > 0) line.append(ctx.gpa, ' ') catch return;
        line.appendSlice(ctx.gpa, w) catch return;
    }
    if (line.items.len > 0) {
        out.appendSlice(ctx.gpa, indent) catch return;
        out.appendSlice(ctx.gpa, fit(ctx, line.items, cols)) catch return;
        out.appendSlice(ctx.gpa, "\x1b[K\r\n") catch return;
    }
}

/// One frame: its text built in its own arena, written at once.
const Frame = struct {
    ctx: sys.Ctx,
    out: std.ArrayList(u8) = .empty,
    cols: usize,

    fn add(f: *Frame, text: []const u8) void {
        f.out.appendSlice(f.ctx.gpa, text) catch {};
    }

    /// A line: the text, the rest of the row cleared.
    fn line(f: *Frame, comptime format: []const u8, args: anytype) void {
        f.add(f.ctx.fmt(format ++ "\x1b[K\r\n", args) catch "");
    }
};

fn draw(ui: *Ui) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ctx = ui.ctx;
    ctx.gpa = arena.allocator();
    const sz = Term.size();
    var f: Frame = .{ .ctx = ctx, .cols = @max(sz.cols, 40) };
    f.add("\x1b[H");
    drawHeader(ui, &f);
    const detail_lines: usize = if (ui.show_preview) 16 else 6;
    drawTable(ui, &f, if (sz.rows > detail_lines + 5) sz.rows - detail_lines - 5 else 3);
    drawDetail(ui, &f, detail_lines);
    drawFooter(ui, &f);
    Term.write(ctx.io, f.out.items);
}

/// Counts by state, when the list was updated, and the machines worth a note.
fn drawHeader(ui: *Ui, f: *Frame) void {
    const ctx = f.ctx;
    const rows = ui.rows();
    var working: usize = 0;
    var waiting: usize = 0;
    for (rows) |r| {
        if (std.mem.eql(u8, r.state, "working")) working += 1;
        if (std.mem.eql(u8, r.state, "waiting")) waiting += 1;
    }
    ui.shared.lock.lockUncancelable(ctx.io);
    const refreshing = ui.shared.refreshing;
    ui.shared.lock.unlock(ctx.io);
    const now = std.Io.Clock.real.now(ctx.io).toSeconds();
    const updated = if (ui.listing) |l| (if (l.at > 0) ago(ctx, now - l.at) else "") else "loading…";
    const head = ctx.fmt(" {s}Agent Belt · sessions{s}   \x1b[36m●{s} {d} working   \x1b[31m●{s} {d} waiting   {s}○ {d} idle{s}", .{ bold, reset, reset, working, reset, waiting, dim, rows.len - working - waiting, reset }) catch "";
    const right = ctx.fmt("{s}{s}{s} ", .{ dim, if (refreshing) "refreshing… " else "", updated }) catch "";
    const gap = if (f.cols > width(head) + width(right)) f.cols - width(head) - width(right) else 1;
    f.add(head);
    f.out.appendNTimes(ctx.gpa, ' ', gap) catch {};
    f.line("{s}{s}", .{ right, reset });
    // Machines that did not answer, agents that tmux cannot attach.
    var note: std.ArrayList(u8) = .empty;
    if (ui.listing) |l| for (ui.reg.hosts, l.collected.states) |h, st| {
        if (!st.ok) note.appendSlice(ctx.gpa, ctx.fmt("{s}{s} offline", .{ if (note.items.len > 0) " · " else "", h.name }) catch "") catch {};
        if (st.outside > 0) note.appendSlice(ctx.gpa, ctx.fmt("{s}{s}: {d} outside tmux (agb adopt)", .{ if (note.items.len > 0) " · " else "", h.name, st.outside }) catch "") catch {};
    };
    f.line(" {s}{s}{s}", .{ dim, fit(ctx, note.items, f.cols - 2), reset });
}

/// MACHINE SESSION AGENT STATE AGE TOKENS COST, scrolled to the selection.
fn drawTable(ui: *Ui, f: *Frame, room: usize) void {
    const ctx = f.ctx;
    const rows = ui.rows();
    var wm: usize = 7;
    var wn: usize = 7;
    for (rows) |r| {
        wm = @max(wm, width(r.host.name));
        wn = @max(wn, width(r.name));
    }
    wm = @min(wm, 16);
    wn = @min(wn, 28);
    f.line("{s}   {s}  {s}  {s}  {s}  {s:>4}  {s:>7}  {s:>8}{s}", .{ dim, fit(ctx, "MACHINE", wm), fit(ctx, "SESSION", wn), fit(ctx, "AGENT", 8), fit(ctx, "STATE", 9), "AGE", "TOKENS", "COST", reset });
    const first = if (ui.selected >= room) ui.selected - room + 1 else 0;
    var shown: usize = 0;
    for (rows[first..], first..) |r, i| {
        if (shown == room) break;
        shown += 1;
        const sel = i == ui.selected;
        f.line("{s} {s} {s}  {s}  {s}  {s}  {s:>4}  {s:>7}  {s:>8}{s}{s}", .{
            if (sel) bold else "",
            if (sel) "▶" else " ",
            fit(ctx, r.host.name, wm),
            fit(ctx, r.name, wn),
            fit(ctx, r.agent, 8),
            stateCell(r.state),
            ageText(ctx, r.created),
            tokensText(ctx, r.tokens),
            costText(ctx, r.cost),
            if (r.attached) dim ++ "  attached" else "",
            reset,
        });
    }
    if (rows.len == 0 and ui.listing != null) {
        f.line("{s}   no sessions yet: agb new [agent] [machine] [repo] [what to do]{s}", .{ dim, reset });
        shown += 1;
    }
    while (shown < room) : (shown += 1) f.line("", .{});
}

/// The selected session: where it runs, what it did, the end of its screen.
fn drawDetail(ui: *Ui, f: *Frame, lines: usize) void {
    const ctx = f.ctx;
    f.add(dim);
    f.out.appendNTimes(ctx.gpa, '-', f.cols) catch {};
    f.add(reset ++ "\r\n");
    const before = f.out.items.len;
    if (ui.current()) |r| {
        f.line(" {s}{s}{s} on {s}  {s}{s}{s}", .{ bold, r.name, reset, r.host.name, dim, fit(ctx, r.path, f.cols -| (r.name.len + r.host.name.len + 8)), reset });
        if (r.summary.len > 0) wrap(ctx, &f.out, r.summary, f.cols - 2, 3, " ") else f.line("{s} no recap yet{s}", .{ dim, reset });
        if (ui.show_preview) drawScreen(ui, f);
    }
    var used = 1 + std.mem.count(u8, f.out.items[before..], "\r\n");
    while (used < lines) : (used += 1) f.line("", .{});
}

/// The bottom of the selected session's screen: the agent's prompt and status.
fn drawScreen(ui: *Ui, f: *Frame) void {
    const ctx = f.ctx;
    // A copy, taken under the lock: the next preview frees this one.
    ui.shared.lock.lockUncancelable(ctx.io);
    const shown = if (std.mem.eql(u8, ui.shared.preview_for, ui.selected_key)) ui.shared.preview else null;
    const text = if (shown) |t| ctx.gpa.dupe(u8, t) catch null else null;
    ui.shared.lock.unlock(ctx.io);
    f.line("{s} screen:{s}", .{ dim, reset });
    const screen = std.mem.trimEnd(u8, text orelse "  (loading…)", " \r\n");
    var start = screen.len;
    var taken: usize = 0;
    while (start > 0 and taken < 10) {
        start -= 1;
        if (screen[start] == '\n') taken += 1;
    }
    if (start > 0) start += 1;
    var it = std.mem.splitScalar(u8, screen[start..], '\n');
    while (it.next()) |l| f.line("  {s}{s}{s}", .{ dim, fit(ctx, std.mem.trimEnd(u8, l, " \r"), f.cols - 4), reset });
}

/// The prompt of the current mode, a message, or the keys.
fn drawFooter(ui: *Ui, f: *Frame) void {
    const ctx = f.ctx;
    const r = ui.current();
    const bottom = switch (ui.mode) {
        .confirm_close => ctx.fmt(" {s}close {s} on {s}? the agent stops (y/N){s}", .{ bold, if (r) |x| x.name else "", if (r) |x| x.host.name else "", reset }) catch "",
        .rename => ctx.fmt(" {s}new name:{s} {s}█", .{ bold, reset, ui.input.items }) catch "",
        .list => if (ui.message.len > 0)
            ctx.fmt(" {s}", .{ui.message}) catch ""
        else
            dim ++ " ↑↓ select   ⏎ open   x close   r rename   p screen   R refresh   q quit" ++ reset,
    };
    f.add(bottom);
    f.add("\x1b[K\x1b[J");
}

fn ageText(ctx: sys.Ctx, created: []const u8) []const u8 {
    const then = std.fmt.parseInt(i64, created, 10) catch return "?";
    const delta = @max(std.Io.Clock.real.now(ctx.io).toSeconds() - then, 0);
    if (delta < 3600) return ctx.fmt("{d}m", .{@divTrunc(delta, 60)}) catch "?";
    if (delta < 86400) return ctx.fmt("{d}h", .{@divTrunc(delta, 3600)}) catch "?";
    return ctx.fmt("{d}d", .{@divTrunc(delta, 86400)}) catch "?";
}

// ---------------------------------------------------------------- loop

/// Takes a refreshed listing, keeping the same session selected.
fn adopt(ui: *Ui) bool {
    ui.shared.lock.lockUncancelable(ui.ctx.io);
    const pending = ui.shared.pending;
    ui.shared.pending = null;
    ui.shared.lock.unlock(ui.ctx.io);
    const next = pending orelse return false;
    if (ui.listing) |old| freeListing(old);
    ui.listing = next;
    ui.selected = 0;
    for (next.collected.rows, 0..) |r, i| if (std.mem.eql(u8, rowKey(ui.ctx, r), ui.selected_key)) {
        ui.selected = i;
    };
    return true;
}

fn select(ui: *Ui, index: usize) void {
    const rows = ui.rows();
    if (rows.len == 0) return;
    ui.selected = @min(index, rows.len - 1);
    const key = rowKey(ui.ctx, rows[ui.selected]);
    if (std.mem.eql(u8, key, ui.selected_key)) return;
    ui.selected_key = key;
    if (ui.show_preview) askPreview(ui);
}

fn askPreview(ui: *Ui) void {
    const r = ui.current() orelse return;
    const job = previewJob(ui.ctx, r, ui.selected_key) orelse return;
    const t = std.Thread.spawn(.{}, previewer, .{ job, ui.shared }) catch return;
    t.detach();
}

/// Runs `agb <args>` on this terminal, then takes the screen back.
fn runHere(ui: *Ui, term: *Term, args: []const []const u8) u8 {
    term.leave(ui.ctx.io);
    defer _ = term.enter(ui.ctx.io);
    const self = std.process.executablePathAlloc(ui.ctx.io, ui.ctx.gpa) catch "agb";
    const argv = std.mem.concat(ui.ctx.gpa, []const u8, &.{ &.{self}, args }) catch return 1;
    return sys.interactive(ui.ctx, argv, null);
}

fn handle(ui: *Ui, term: *Term, key: Key) void {
    switch (ui.mode) {
        .confirm_close => confirmClose(ui, key),
        .rename => editName(ui, key),
        .list => {
            ui.message = "";
            switch (key) {
                .up => select(ui, ui.selected -| 1),
                .down => select(ui, ui.selected + 1),
                .home => select(ui, 0),
                .end => select(ui, ui.rows().len -| 1),
                .escape => ui.quit = true,
                .enter => open(ui, term),
                .char => |c| command(ui, term, c),
                .none => {},
            }
        },
    }
}

fn command(ui: *Ui, term: *Term, c: u8) void {
    switch (c) {
        'k' => select(ui, ui.selected -| 1),
        'j' => select(ui, ui.selected + 1),
        'g' => select(ui, 0),
        'G' => select(ui, ui.rows().len -| 1),
        'q' => ui.quit = true,
        'o' => open(ui, term),
        'x', 'd' => if (ui.current() != null) {
            ui.mode = .confirm_close;
        },
        'r' => if (ui.current()) |r| {
            ui.mode = .rename;
            ui.input = .empty;
            ui.input.appendSlice(ui.ctx.gpa, r.name) catch {};
        },
        'p', ' ' => {
            ui.show_preview = !ui.show_preview;
            if (ui.show_preview) askPreview(ui);
        },
        'R' => requestRefresh(ui),
        else => {},
    }
}

fn confirmClose(ui: *Ui, key: Key) void {
    ui.mode = .list;
    ui.message = "";
    const yes = key == .char and (key.char == 'y' or key.char == 'Y' or key.char == 's');
    const r = ui.current() orelse return;
    if (!yes) return;
    ui.message = if (cli.stopRow(ui.ctx, ui.reg, r)) ui.ctx.fmt("closed {s}", .{r.name}) catch "" else ui.ctx.fmt("could not close {s}", .{r.name}) catch "";
    requestRefresh(ui);
}

fn editName(ui: *Ui, key: Key) void {
    switch (key) {
        .escape => ui.mode = .list,
        .enter => {
            ui.mode = .list;
            const r = ui.current() orelse return;
            if (ui.input.items.len == 0) return;
            ui.message = cli.renameRow(ui.ctx, ui.reg, r, ui.input.items);
            requestRefresh(ui);
        },
        // Backspace takes the last code point.
        .char => |c| if (c == 127 or c == 8) {
            while (ui.input.pop()) |last| if (last & 0xC0 != 0x80) break;
        } else if (c >= 32) {
            ui.input.append(ui.ctx.gpa, c) catch {};
        },
        else => {},
    }
}

fn open(ui: *Ui, term: *Term) void {
    const r = ui.current() orelse return;
    // Inside tmux a local session is switched to; this list stays in its pane.
    const code = runHere(ui, term, &.{ "attach", r.name, r.host.name });
    ui.message = if (code == 0) "" else ui.ctx.fmt("attach ended with code {d}", .{code}) catch "";
    requestRefresh(ui);
}

fn requestRefresh(ui: *Ui) void {
    const t = std.Thread.spawn(.{}, refreshOnce, .{ ui.ctx, ui.reg, ui.shared }) catch return;
    t.detach();
}

fn refreshOnce(ctx: sys.Ctx, reg: hosts.Registry, shared: *Shared) void {
    const arena = newArena() orelse return;
    var c = ctx;
    c.gpa = arena.allocator();
    const collected = cli.collect(c, reg) catch {
        freeListing(.{ .arena = arena, .collected = undefined, .at = 0 });
        return;
    };
    shared.lock.lockUncancelable(ctx.io);
    if (shared.pending) |old| freeListing(old);
    shared.pending = .{ .arena = arena, .collected = collected, .at = std.Io.Clock.real.now(ctx.io).toSeconds() };
    shared.lock.unlock(ctx.io);
    shared.wake.store(true, .release);
}

/// The live list. Returns null when this is not a terminal (the caller
/// prints the plain listing instead).
pub fn run(ctx: sys.Ctx, reg: hosts.Registry) ?u8 {
    var term: Term = .{};
    if (!term.enter(ctx.io)) return null;
    defer term.leave(ctx.io);
    var shared: Shared = .{};
    var ui: Ui = .{ .ctx = ctx, .reg = reg, .shared = &shared };
    // The snapshot first: on screen before any machine answers.
    if (newArena()) |arena| {
        var c = ctx;
        c.gpa = arena.allocator();
        if (cli.loadSnapshot(c, reg)) |snap| {
            ui.listing = .{ .arena = arena, .collected = snap.collected, .at = snap.at };
        } else freeListing(.{ .arena = arena, .collected = undefined, .at = 0 });
    }
    select(&ui, 0);
    const t = std.Thread.spawn(.{}, refresher, .{ ctx, reg, &shared }) catch null;
    if (t) |thread| thread.detach();
    var last_draw: i64 = 0;
    var buf: [64]u8 = undefined;
    while (!ui.quit) {
        const now = std.Io.Clock.real.now(ctx.io).toSeconds();
        const woke = shared.wake.swap(false, .acq_rel);
        if (adopt(&ui)) select(&ui, ui.selected);
        if (woke or now != last_draw) {
            draw(&ui);
            last_draw = now;
        }
        var n = Term.read(&buf, 200);
        if (n == 0) continue;
        // An arrow key can arrive in two reads (ESC, then "[A"): a sequence
        // cut short waits a moment for the rest instead of reading as Escape.
        while (n < buf.len and incomplete(buf[0..n])) {
            const more = Term.read(buf[n..], 50);
            if (more == 0) break;
            n += more;
        }
        var rest: []const u8 = buf[0..n];
        while (rest.len > 0 and !ui.quit) {
            const k = nextKey(rest);
            rest = rest[k.len..];
            handle(&ui, &term, k.key);
        }
        draw(&ui);
    }
    return 0;
}

test "keys decode from what terminals send" {
    try std.testing.expectEqual(Key.up, decode("\x1b[A"));
    try std.testing.expectEqual(Key.down, decode("\x1bOB"));
    try std.testing.expectEqual(Key.enter, decode("\r"));
    try std.testing.expectEqual(Key.escape, decode("\x1b"));
    try std.testing.expectEqual(Key{ .char = 'x' }, decode("x"));
    try std.testing.expect(incomplete("\x1b"));
    try std.testing.expect(incomplete("j\x1b["));
    try std.testing.expect(!incomplete("\x1b[A"));
    try std.testing.expect(!incomplete("x"));
    const typed = "\x1b[Bp";
    const first = nextKey(typed);
    try std.testing.expectEqual(Key.down, first.key);
    try std.testing.expectEqual(Key{ .char = 'p' }, nextKey(typed[first.len..]).key);
}

test "cells fit their columns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env };
    try std.testing.expectEqualStrings("revisão   ", fit(ctx, "revisão", 10));
    try std.testing.expectEqualStrings("revis…", fit(ctx, "revisão do login", 6));
    try std.testing.expectEqualStrings("610.8M", tokensText(ctx, 610_792_093));
    try std.testing.expectEqualStrings("42k", tokensText(ctx, 42_000));
    try std.testing.expectEqual(@as(usize, 9), width("\x1b[36m● working\x1b[0m"));
}
