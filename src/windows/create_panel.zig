//! The create-agent panel on Windows, the twin of the Mac's (src/create_panel.m)
//! and Linux's (src/linux/agent_panel.qml): the same dark rounded surface and
//! breathing core, the request as it is typed, what was understood (agent,
//! machine, repo; `intent.detect`, backed by Jev) as chips to correct, the
//! session's name and a one-line summary. Return creates the agent, Esc
//! cancels. GDI+ draws it into a layered window, like the dictation overlay.
const std = @import("std");
const w = @import("win32.zig");
const gp = @import("gdiplus.zig");
const sys = @import("../sessions/sys.zig");
const hosts = @import("../sessions/hosts.zig");
const intent = @import("../sessions/intent.zig");
const local = @import("../sessions/local.zig");
const cli = @import("../sessions/cli.zig");

const panel_width = 600;
const max_height = 460;
const pad = 68;
const text_width = panel_width - pad - 24;

const WM_PLAN = w.WM_APP + 7; // wparam: request serial, lparam: *Detected
const WM_SUMMARY = w.WM_APP + 8; // wparam: request serial, lparam: *Detected (with its summary)
const TIMER_FRAME = 1;
const TIMER_DETECT = 7;

pub const OpenTerminal = *const fn (title: []const u8, args: []const []const u8) void;

const Detected = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8 = "", // what was detected (and what the agent gets)
    plan: ?intent.Plan = null,
    failure: ?[]const u8 = null,
    summary: ?intent.Summary = null,

    fn create() ?*Detected {
        const d = std.heap.page_allocator.create(Detected) catch return null;
        d.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
        return d;
    }

    fn destroy(d: *Detected) void {
        d.arena.deinit();
        std.heap.page_allocator.destroy(d);
    }
};

const keys = [_][]const u8{ "agent", "host", "repo" };
const labels = [_][]const u8{ "agent", "machine", "repo" };
const none_repo = "none (research, in ~/agents)";

var g_ctx: sys.Ctx = undefined;
var g_open: OpenTerminal = undefined;
var g_instance: ?w.HINSTANCE = null;
var hwnd: ?w.HWND = null;
var scale: f32 = 1;
var dc: ?w.HDC = null;
var bits: ?*anyopaque = null;
var bitmap: ?gp.Gp = null;
var fonts: struct { text: ?gp.Gp = null, title: ?gp.Gp = null, name: ?gp.Gp = null, label: ?gp.Gp = null, value: ?gp.Gp = null, summary: ?gp.Gp = null, hint: ?gp.Gp = null } = .{};
var single_line: ?gp.Gp = null;

var text: std.ArrayList(u16) = .empty;
var session: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator); // choices, for one opening
var fixed: [3]?[]const u8 = .{ null, null, null }; // agent, host, repo ("" = no repo)
var detected: ?*Detected = null;
var summary: ?*Detected = null;
var serial: usize = 0;
var detecting = false;
var create_pending = false;
var chips: [3]gp.RectF = undefined;
var origin = w.POINT{};
var phase: f64 = 0;
var last_tick: f64 = 0;
var shown_at: f64 = 0;

fn now() f64 {
    return @as(f64, @floatFromInt(w.GetTickCount64())) / 1000.0;
}

fn ease(t: f64) f64 {
    const c = std.math.clamp(t, 0, 1);
    return c * c * (3 - 2 * c);
}

/// Called once from the daemon's UI thread; the window is made on first show.
pub fn init(ctx: sys.Ctx, instance: ?w.HINSTANCE, open: OpenTerminal) void {
    g_ctx = ctx;
    g_instance = instance;
    g_open = open;
}

fn build() bool {
    if (hwnd != null) return true;
    if (!gp.startup()) return false;
    const screen = w.GetDC(null) orelse return false;
    defer _ = w.ReleaseDC(null, screen);
    scale = @as(f32, @floatFromInt(w.GetDeviceCaps(screen, 88))) / 96.0; // LOGPIXELSX
    const pw: c_int = @intFromFloat(panel_width * scale);
    const ph: c_int = @intFromFloat(max_height * scale);
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = proc, .hInstance = g_instance, .lpszClassName = w.L("AgentBeltPanel") });
    hwnd = w.CreateWindowExW(w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW | w.WS_EX_LAYERED, w.L("AgentBeltPanel"), w.L("Agent Belt: new agent"), w.WS_POPUP, 0, 0, pw, ph, null, null, g_instance, null);
    dc = w.CreateCompatibleDC(screen);
    const info = w.BITMAPINFOHEADER{ .width = pw, .height = -ph }; // top-down
    const dib = w.CreateDIBSection(screen, &info, 0, &bits, null, 0) orelse return false;
    _ = w.SelectObject(dc.?, @ptrCast(dib));
    _ = gp.GdipCreateBitmapFromScan0(pw, ph, pw * 4, gp.pixel_format_32bpp_pargb, bits, &bitmap);
    const ui = [_][:0]const u16{w.L("Segoe UI")};
    const semibold = [_][:0]const u16{ w.L("Segoe UI Semibold"), w.L("Segoe UI") };
    fonts = .{
        .text = gp.font(&ui, 15 * scale, gp.font_regular),
        .title = gp.font(&semibold, 13 * scale, gp.font_regular),
        .name = gp.font(&.{ w.L("Cascadia Mono"), w.L("Consolas") }, 12.5 * scale, gp.font_bold),
        .label = gp.font(&ui, 11 * scale, gp.font_regular),
        .value = gp.font(&semibold, 12 * scale, gp.font_regular),
        .summary = gp.font(&ui, 13 * scale, gp.font_regular),
        .hint = gp.font(&ui, 11 * scale, gp.font_regular),
    };
    if (gp.GdipCreateStringFormat(0x1000, 0, &single_line) == 0) _ = gp.GdipSetStringFormatTrimming(single_line.?, 3); // no wrap, ellipsis
    return hwnd != null and bitmap != null;
}

// ---------------------------------------------------------------- open, close

pub fn show() void {
    if (!build()) return;
    const h = hwnd.?;
    if (w.IsWindowVisible(h) == 0) {
        text.clearRetainingCapacity();
        _ = session.reset(.retain_capacity);
        fixed = .{ null, null, null };
        dropResults();
        create_pending = false;
        detecting = false;
        var area = w.RECT{};
        _ = w.SystemParametersInfoW(w.SPI_GETWORKAREA, 0, &area, 0);
        origin.x = @divTrunc(area.left + area.right, 2) - @as(c_int, @intFromFloat(panel_width * scale / 2));
        origin.y = area.top + @divTrunc(area.bottom - area.top, 5);
        shown_at = now();
        last_tick = shown_at;
        _ = w.SetTimer(h, TIMER_FRAME, 16, null);
        // Fresh repo lists for the detection, in the background.
        _ = std.Thread.spawn(.{}, refreshRepos, .{}) catch null;
    }
    render();
    _ = w.SetForegroundWindow(h);
    _ = w.SetFocus(h);
}

fn close() void {
    const h = hwnd orelse return;
    _ = w.KillTimer(h, TIMER_FRAME);
    _ = w.KillTimer(h, TIMER_DETECT);
    _ = w.ShowWindow(h, w.SW_HIDE);
    dropResults();
    // The request is private: it does not stay in memory after the panel.
    @memset(text.items, 0);
    text.clearRetainingCapacity();
}

fn dropResults() void {
    if (detected) |d| d.destroy();
    if (summary) |s| s.destroy();
    detected = null;
    summary = null;
}

fn refreshRepos() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ctx = g_ctx;
    ctx.gpa = arena.allocator();
    const reg = hosts.load(ctx) catch return;
    intent.refreshCache(ctx, reg, cli.reposOf) catch {};
}

// ---------------------------------------------------------------- the request

fn utf8(gpa: std.mem.Allocator) []const u8 {
    const t = std.unicode.utf16LeToUtf8Alloc(gpa, text.items) catch return "";
    return std.mem.trim(u8, t, " \r\n\t");
}

fn edited() void {
    const h = hwnd orelse return;
    _ = w.SetTimer(h, TIMER_DETECT, 400, null);
}

fn typed(c: u16) void {
    switch (c) {
        0x08 => { // backspace, a surrogate pair at once
            if (text.items.len == 0) return;
            _ = text.pop();
            if (text.items.len > 0 and text.items[text.items.len - 1] >= 0xD800 and text.items[text.items.len - 1] < 0xDC00) _ = text.pop();
        },
        0x7F, 0x17 => { // Ctrl+Backspace, Ctrl+W: the last word
            while (text.items.len > 0 and text.items[text.items.len - 1] == ' ') _ = text.pop();
            while (text.items.len > 0 and text.items[text.items.len - 1] != ' ') _ = text.pop();
        },
        0x16 => paste(),
        0x0D => return confirm(),
        0x1B => return close(),
        else => {
            if (c < 0x20) return;
            text.append(std.heap.page_allocator, c) catch return;
        },
    }
    edited();
}

fn paste() void {
    if (w.OpenClipboard(hwnd) == 0) return;
    defer _ = w.CloseClipboard();
    const data = w.GetClipboardData(w.CF_UNICODETEXT) orelse return;
    const chars = w.GlobalLock(data) orelse return;
    defer _ = w.GlobalUnlock(data);
    for (std.mem.span(chars)) |c| text.append(std.heap.page_allocator, if (c == '\r' or c == '\n' or c == '\t') ' ' else c) catch return;
}

// ---------------------------------------------------------------- detection

fn detect() void {
    const h = hwnd orelse return;
    // The thread gets its own copy of the request and the choices: the panel
    // may close (and forget them) before it answers.
    const d = Detected.create() orelse return;
    const gpa = d.arena.allocator();
    d.text = utf8(gpa);
    if (d.text.len == 0) return d.destroy();
    var choice: intent.Fixed = .{};
    choice.agent = if (fixed[0]) |v| gpa.dupe(u8, v) catch null else null;
    choice.host = if (fixed[1]) |v| gpa.dupe(u8, v) catch null else null;
    if (fixed[2]) |r| {
        if (r.len == 0) choice.no_repo = true else choice.repo = gpa.dupe(u8, r) catch null;
    }
    serial += 1;
    detecting = true;
    _ = std.Thread.spawn(.{}, detectThread, .{ h, serial, d, choice }) catch {
        detecting = false;
        d.destroy();
    };
}

fn detectThread(panel: w.HWND, request_serial: usize, d: *Detected, choice: intent.Fixed) void {
    var ctx = g_ctx;
    ctx.gpa = d.arena.allocator();
    if (hosts.load(ctx)) |reg| {
        d.plan = intent.detect(ctx, reg, d.text, choice) catch |err| blk: {
            d.failure = @errorName(err);
            break :blk null;
        };
    } else |err| d.failure = @errorName(err);
    // Then the session name and summary, written by an agent (seconds).
    const s = Detected.create();
    if (s) |named| {
        const sgpa = named.arena.allocator();
        named.text = sgpa.dupe(u8, d.text) catch "";
    }
    if (w.PostMessageW(panel, WM_PLAN, request_serial, @bitCast(@intFromPtr(d))) == 0) {
        d.destroy();
        if (s) |named| named.destroy();
        return;
    }
    const named = s orelse return;
    var sctx = g_ctx;
    sctx.gpa = named.arena.allocator();
    named.summary = intent.summarize(sctx, named.text) catch null;
    if (w.PostMessageW(panel, WM_SUMMARY, request_serial, @bitCast(@intFromPtr(named))) == 0) named.destroy();
}

/// A chip's value: the choice, else the detection.
fn value(i: usize) ?[]const u8 {
    if (fixed[i]) |v| return if (v.len == 0) null else v;
    const plan = (detected orelse return null).plan orelse return null;
    return switch (i) {
        0 => plan.agent,
        1 => plan.host,
        else => plan.repo,
    };
}

fn confidence(i: usize) f64 {
    if (fixed[i] != null) return 1;
    const plan = (detected orelse return 0).plan orelse return 0;
    return switch (i) {
        0 => plan.agent_confidence,
        1 => plan.host_confidence,
        else => plan.repo_confidence,
    };
}

/// A chip's options, the current one checked; the choice fixes that part.
fn pick(i: usize) void {
    const h = hwnd orelse return;
    const plan: ?intent.Plan = if (detected) |d| d.plan else null;
    const options: []const []const u8 = switch (i) {
        0 => local.agent_names,
        1 => if (plan) |p| p.hosts else &.{},
        else => if (plan) |p| p.repos else &.{},
    };
    const menu = w.CreatePopupMenu() orelse return;
    defer _ = w.DestroyMenu(menu);
    const current = value(i);
    const gpa = session.allocator();
    if (i == 2) {
        _ = w.AppendMenuW(menu, if (current == null) w.MF_CHECKED else w.MF_STRING, 1, w.L(none_repo));
        _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    }
    for (options, 0..) |option, n| {
        const checked = if (current) |c| std.mem.eql(u8, c, option) else false;
        _ = w.AppendMenuW(menu, if (checked) w.MF_CHECKED else w.MF_STRING, n + 2, w.wide(gpa, option) catch continue);
    }
    const r = chips[i];
    const x = origin.x + @as(c_int, @intFromFloat(r.x));
    const y = origin.y + @as(c_int, @intFromFloat(r.y + r.h + 4 * scale));
    const cmd = w.TrackPopupMenu(menu, w.TPM_RETURNCMD | w.TPM_NONOTIFY, x, y, 0, h, null);
    if (cmd <= 0) return;
    const id: usize = @intCast(cmd);
    fixed[i] = if (id == 1) "" else gpa.dupe(u8, options[id - 2]) catch return;
    // Another machine has other repos: its repo is asked again.
    if (i == 1) fixed[2] = null;
    detect();
}

fn confirm() void {
    const request = utf8(session.allocator());
    if (request.len == 0) return;
    // The fields must come from this very text, and the session needs its
    // name: whichever is missing is asked for, and creating waits for it.
    const d = detected orelse return pending(true);
    if (!std.mem.eql(u8, d.text, request)) return pending(true);
    const plan = d.plan orelse return;
    const named = (if (summary) |s| (if (std.mem.eql(u8, s.text, request)) s.summary else null) else null) orelse return pending(false);
    create_pending = false;
    const gpa = session.allocator();
    const agent = fixed[0] orelse plan.agent;
    const host = fixed[1] orelse plan.host;
    const repo: ?[]const u8 = if (fixed[2]) |r| (if (r.len == 0) null else r) else plan.repo;
    const args = cli.newArgs(gpa, agent, host, repo, named.name, if (named.prompt.len > 0) named.prompt else request) catch return;
    g_open(std.fmt.allocPrint(gpa, "{s} · {s} @ {s}", .{ named.name, agent, host }) catch "Agent Belt", args);
    close();
}

fn pending(stale: bool) void {
    create_pending = true;
    if (stale) detect();
}

// ---------------------------------------------------------------- drawing

fn drawText(g: gp.Gp, str: []const u16, font: ?gp.Gp, x: f32, y: f32, width: f32, color: u32, format: ?gp.Gp) void {
    if (str.len == 0) return;
    var brush: ?gp.Gp = null;
    if (gp.GdipCreateSolidFill(color, &brush) != 0) return;
    defer _ = gp.GdipDeleteBrush(brush.?);
    const rect = gp.RectF{ .x = x * scale, .y = y * scale, .w = width * scale, .h = max_height * scale };
    _ = gp.GdipDrawString(g, str.ptr, @intCast(str.len), font orelse return, &rect, format, brush.?);
}

/// Logical size of text wrapped at `width`.
fn measure(g: gp.Gp, str: []const u16, font: ?gp.Gp, width: f32) gp.RectF {
    var box = gp.RectF{ .x = 0, .y = 0, .w = 0, .h = 0 };
    if (str.len == 0) return box;
    const rect = gp.RectF{ .x = 0, .y = 0, .w = width * scale, .h = max_height * scale };
    _ = gp.GdipMeasureString(g, str.ptr, @intCast(str.len), font orelse return box, &rect, null, &box, null, null);
    return .{ .x = 0, .y = 0, .w = box.w / scale, .h = box.h / scale };
}

fn render() void {
    const h = hwnd orelse return;
    const bmp = bitmap orelse return;
    var frame = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer frame.deinit();
    const gpa = frame.allocator();
    var gg: ?gp.Gp = null;
    if (gp.GdipGetImageGraphicsContext(bmp, &gg) != 0) return;
    const g = gg.?;
    defer _ = gp.GdipDeleteGraphics(g);
    _ = gp.GdipSetSmoothingMode(g, gp.smoothing_antialias);
    _ = gp.GdipSetTextRenderingHint(g, gp.text_antialias);
    _ = gp.GdipGraphicsClear(g, 0);

    const request = utf8(gpa);
    const named: ?intent.Summary = if (summary) |s| (if (std.mem.eql(u8, s.text, request)) s.summary else null) else null;
    // The words, wrapped, with a blinking caret after them.
    const caret: []const u16 = if (@mod(now() - shown_at, 1.0) < 0.55) w.L("▏") else w.L(" ");
    const shown = std.mem.concat(gpa, u16, &.{ text.items, caret }) catch return;
    const text_height: f32 = @min(180, @max(24, measure(g, shown, fonts.text, text_width).h + 6));
    const chips_y: f32 = 42 + text_height + 10;
    const height: f32 = chips_y + 80;

    gp.drawShell(g, scale, panel_width, height, 23);
    gp.drawCore(g, scale, 36, 38, 0.02, phase, 0, detecting);
    drawTitle(g, gpa, named);
    drawRequest(g, shown, caret, text_height);
    drawChips(g, gpa, chips_y);
    drawFooter(g, gpa, chips_y, named, request.len > 0);

    const size = w.SIZE{ .cx = @intFromFloat(panel_width * scale), .cy = @intFromFloat(height * scale) };
    var src = w.POINT{};
    const blend = w.BLENDFUNCTION{ .alpha = @intFromFloat(255 * ease((now() - shown_at) / 0.16)) };
    _ = w.UpdateLayeredWindow(h, null, &origin, &size, dc.?, &src, 0, &blend, 2); // ULW_ALPHA
    if (w.IsWindowVisible(h) == 0) _ = w.ShowWindow(h, w.SW_SHOW);
}

/// "New agent", and the session's name as it will appear in every list.
fn drawTitle(g: gp.Gp, gpa: std.mem.Allocator, named: ?intent.Summary) void {
    const title = w.L("New agent");
    drawText(g, title, fonts.title, pad, 16, 200, gp.ink(0.92), single_line);
    const n = named orelse return;
    const x = pad + measure(g, title, fonts.title, 200).w + 10;
    const label = w.wide(gpa, std.fmt.allocPrint(gpa, "·  {s}", .{n.name}) catch "") catch return;
    drawText(g, label, fonts.name, x, 16, panel_width - x - 24, gp.argb(0.98, 158, 219, 184), single_line);
}

/// The request, its latest lines when they do not all fit; an example when empty.
fn drawRequest(g: gp.Gp, shown: []const u16, caret: []const u16, text_height: f32) void {
    if (text.items.len == 0) {
        drawText(g, w.L("Type the agent: “codex on linux in web-app to look into the login”"), fonts.text, pad, 42, text_width, gp.ink(0.35), null);
        drawText(g, caret, fonts.text, pad - 4, 42, 20, gp.ink(0.9), null);
        return;
    }
    const full = measure(g, shown, fonts.text, text_width).h;
    _ = gp.GdipSetClipRect(g, pad * scale, 42 * scale, text_width * scale, text_height * scale, 0);
    drawText(g, shown, fonts.text, pad, 42 + @min(0, text_height - 6 - full), text_width, gp.ink(0.95), null);
    _ = gp.GdipResetClip(g);
}

/// Agent, machine, repo: 0 is a default (not said), dimmer; below 0.6 Jev is
/// unsure, marked "?". Their rectangles are kept for clicks.
fn drawChips(g: gp.Gp, gpa: std.mem.Allocator, y: f32) void {
    var x: f32 = pad;
    for (0..3) |i| {
        const v = value(i);
        const c = confidence(i);
        const unsure = v != null and c > 0 and c < 0.6;
        const shown = if (v) |s| (std.fmt.allocPrint(gpa, "{s}{s} ▾", .{ s, if (unsure) " ?" else "" }) catch "") else (if (i == 2) "none ▾" else "? ▾");
        const label = w.wide(gpa, labels[i]) catch continue;
        const val = w.wide(gpa, shown) catch continue;
        const lw = measure(g, label, fonts.label, 300).w;
        const vw = measure(g, val, fonts.value, 300).w;
        const width = lw + 6 + vw + 18;
        chips[i] = .{ .x = x * scale, .y = y * scale, .w = width * scale, .h = 22 * scale };
        if (gp.roundedPath(x * scale, y * scale, (x + width) * scale, (y + 22) * scale, 9 * scale)) |p| {
            gp.fillPath(g, p, gp.ink(0.09));
            _ = gp.GdipDeletePath(p);
        }
        const alpha: f64 = if (v == null or c == 0) 0.55 else if (unsure) 0.6 else 0.95;
        drawText(g, label, fonts.label, x + 9, y + 4, lw + 4, gp.ink(0.5), single_line);
        drawText(g, val, fonts.value, x + 9 + lw + 6, y + 3, vw + 4, gp.ink(alpha), single_line);
        x += width + 8;
    }
}

/// The one-line summary, and the hint of what happens next.
fn drawFooter(g: gp.Gp, gpa: std.mem.Allocator, y: f32, named: ?intent.Summary, typed_any: bool) void {
    const line: []const u8 = if (named) |n| (std.fmt.allocPrint(gpa, "→ {s}", .{n.summary}) catch "") else if (typed_any) "→ summarizing…" else "";
    drawText(g, w.wide(gpa, line) catch w.L(""), fonts.summary, pad, y + 30, text_width, gp.ink(0.72), single_line);
    drawText(g, w.wide(gpa, hint(gpa)) catch w.L(""), fonts.hint, pad, y + 52, text_width, gp.ink(0.45), single_line);
}

fn hint(gpa: std.mem.Allocator) []const u8 {
    if (detected) |d| if (d.failure) |f| return std.fmt.allocPrint(gpa, "could not understand: {s}", .{f}) catch "";
    if (create_pending) return "naming the session…";
    if (detecting and detected == null) return "understanding…";
    if (detected != null and value(2) == null) return "no repo: in ~/agents   ·   Return creates   ·   Esc cancels";
    return "Return creates   ·   Esc cancels";
}

// ---------------------------------------------------------------- messages

fn proc(h: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        w.WM_TIMER => {
            if (wparam == TIMER_DETECT) {
                _ = w.KillTimer(h, TIMER_DETECT);
                detect();
            } else {
                const t = now();
                phase += @min(0.1, t - last_tick);
                last_tick = t;
                render();
            }
            return 0;
        },
        w.WM_CHAR => {
            typed(@truncate(wparam));
            return 0;
        },
        w.WM_LBUTTONDOWN => {
            const px: f32 = @floatFromInt(@as(i16, @truncate(lparam & 0xFFFF)));
            const py: f32 = @floatFromInt(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
            for (chips, 0..) |r, i| if (px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h) pick(i);
            return 0;
        },
        WM_PLAN => {
            const d: *Detected = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (wparam != serial or w.IsWindowVisible(h) == 0) { // a newer request is on its way
                d.destroy();
                return 0;
            }
            detecting = false;
            if (detected) |old| old.destroy();
            detected = d;
            if (create_pending and d.plan != null) confirm(); // waits for the name next
            return 0;
        },
        WM_SUMMARY => {
            const s: *Detected = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (wparam != serial or w.IsWindowVisible(h) == 0) {
                s.destroy();
                return 0;
            }
            if (summary) |old| old.destroy();
            summary = s;
            if (create_pending) confirm();
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(h, msg, wparam, lparam);
}
