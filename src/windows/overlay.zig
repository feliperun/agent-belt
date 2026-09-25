//! The dictation overlay on Windows, drawn like the macOS one (src/status_item.m)
//! and the Linux one (src/linux/overlay.qml): a core that breathes with the
//! voice, ribbons that follow it, and a phrase that keeps deciphering while the
//! text is on its way. GDI+ renders it with antialiasing and alpha into a
//! layered window, so the rounded corners are real.
const std = @import("std");
const w = @import("win32.zig");

const width = 252;
const height = 78;

const gp = @import("gdiplus.zig");
const Gp = gp.Gp;
const PointF = gp.PointF;
const RectF = gp.RectF;
const ink = gp.ink;

// ---------------------------------------------------------------- state

var hwnd: ?w.HWND = null;
var scale: f32 = 1;
var dc: ?w.HDC = null;
var bits: ?*anyopaque = null;
var bitmap: ?Gp = null;
var label_font: ?Gp = null;
var mono_font: ?Gp = null;
var mono_bold: ?Gp = null;

var mode: u8 = 0; // 1 listening, 2 transcribing, 0 hidden
var level: f64 = 0;
var release_level: f64 = 0;
var motion: f64 = 0;
var previous_target: f64 = 0;
var phase: f64 = 0;
var signal_phase: f64 = 0;
var mode_started: f64 = 0;
var last_tick: f64 = 0;
var shown_at: f64 = 0;

fn now() f64 {
    return @as(f64, @floatFromInt(w.GetTickCount64())) / 1000.0;
}

fn ease(t: f64) f64 {
    const c = std.math.clamp(t, 0, 1);
    return c * c * (3 - 2 * c);
}

/// Called once from the daemon's UI thread. The window stays hidden until show.
pub fn create(instance: ?w.HINSTANCE, proc: w.WNDPROC) void {
    _ = w.SetProcessDPIAware();
    if (!gp.startup()) return;
    const screen = w.GetDC(null) orelse return;
    defer _ = w.ReleaseDC(null, screen);
    scale = @as(f32, @floatFromInt(w.GetDeviceCaps(screen, 88))) / 96.0; // LOGPIXELSX
    const pw: c_int = @intFromFloat(width * scale);
    const ph: c_int = @intFromFloat(height * scale);
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = proc, .hInstance = instance, .lpszClassName = w.L("AgentBeltOverlay") });
    hwnd = w.CreateWindowExW(w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE | w.WS_EX_LAYERED | w.WS_EX_TRANSPARENT, w.L("AgentBeltOverlay"), w.L("Agent Belt"), w.WS_POPUP, 0, 0, pw, ph, null, null, instance, null);
    dc = w.CreateCompatibleDC(screen);
    const info = w.BITMAPINFOHEADER{ .width = pw, .height = -ph }; // top-down
    const dib = w.CreateDIBSection(screen, &info, 0, &bits, null, 0) orelse return;
    _ = w.SelectObject(dc.?, @ptrCast(dib));
    _ = gp.GdipCreateBitmapFromScan0(pw, ph, pw * 4, gp.pixel_format_32bpp_pargb, bits, &bitmap);
    var family: ?Gp = null;
    if (gp.GdipCreateFontFamilyFromName(w.L("Segoe UI Semibold"), null, &family) == 0 or gp.GdipCreateFontFamilyFromName(w.L("Segoe UI"), null, &family) == 0)
        _ = gp.GdipCreateFont(family.?, 12 * scale, 0, gp.unit_pixel, &label_font);
    var mono: ?Gp = null;
    if (gp.GdipCreateFontFamilyFromName(w.L("Consolas"), null, &mono) == 0) {
        _ = gp.GdipCreateFont(mono.?, 11 * scale, 0, gp.unit_pixel, &mono_font);
        _ = gp.GdipCreateFont(mono.?, 11 * scale, 1, gp.unit_pixel, &mono_bold);
    }
}

/// 1 listening, 2 transcribing, 0 hides. The level comes with each tick.
pub fn show(new_mode: u8) void {
    const h = hwnd orelse return;
    if (new_mode == 0) {
        mode = 0;
        _ = w.KillTimer(h, 1);
        _ = w.ShowWindow(h, w.SW_HIDE);
        level = 0;
        motion = 0;
        previous_target = 0;
        return;
    }
    const t = now();
    if (mode == 0) {
        shown_at = t;
        last_tick = t;
        _ = w.SetTimer(h, 1, 16, null);
    }
    release_level = level;
    mode = new_mode;
    mode_started = t;
    render();
}

/// The timer tick: follow the microphone level (0..1) and redraw.
pub fn tick(target_level: f64) void {
    if (mode == 0) return;
    const t = now();
    const dt = @min(0.1, t - last_tick);
    last_tick = t;
    phase += dt;
    // Fast attack follows syllables; the short release leaves space between words.
    const target = if (mode == 1) target_level else 0;
    level += (target - level) * (1 - @exp(-dt / (if (target > level) @as(f64, 0.016) else 0.085)));
    const onset = @max(0, target - previous_target - 0.025);
    motion = @max(@min(1, onset * 2.5), motion * @exp(-dt / 0.1));
    previous_target = target;
    signal_phase += dt * (2 + level * 10 + motion * 14);
    render();
}

// ---------------------------------------------------------------- drawing

fn pt(x: f64, y: f64) PointF {
    return .{ .x = @floatCast(x * scale), .y = @floatCast(y * scale) };
}

fn stroke(g: Gp, points: []const PointF, color: u32, line_width: f32) void {
    var pen: ?Gp = null;
    if (gp.GdipCreatePen1(color, line_width * scale, gp.unit_pixel, &pen) != 0) return;
    defer _ = gp.GdipDeletePen(pen.?);
    _ = gp.GdipDrawLines(g, pen.?, points.ptr, @intCast(points.len));
}

fn text(g: Gp, str: []const u16, font: ?Gp, x: f64, y: f64, color: u32) void {
    var brush: ?Gp = null;
    if (gp.GdipCreateSolidFill(color, &brush) != 0) return;
    defer _ = gp.GdipDeleteBrush(brush.?);
    const rect = RectF{ .x = @floatCast(x * scale), .y = @floatCast(y * scale), .w = 200 * scale, .h = 24 * scale };
    _ = gp.GdipDrawString(g, str.ptr, @intCast(str.len), font orelse return, &rect, null, brush.?);
}

fn render() void {
    const h = hwnd orelse return;
    const bmp = bitmap orelse return;
    var gg: ?Gp = null;
    if (gp.GdipGetImageGraphicsContext(bmp, &gg) != 0) return;
    const g = gg.?;
    defer _ = gp.GdipDeleteGraphics(g);
    _ = gp.GdipSetSmoothingMode(g, gp.smoothing_antialias);
    _ = gp.GdipSetTextRenderingHint(g, gp.text_antialias);
    _ = gp.GdipGraphicsClear(g, 0);

    const t_now = now();
    const t = phase;
    const morph = if (mode == 2) ease((t_now - mode_started) / 0.7) else 0;

    gp.drawShell(g, scale, width, height, 23);

    drawCore(g, t, morph);
    text(g, if (mode == 1) w.L("Listening") else w.L("Transcribing"), label_font, 62, 13, ink(0.92));
    drawSignal(g, t, morph);

    var pos = w.POINT{};
    var area = w.RECT{};
    _ = w.SystemParametersInfoW(w.SPI_GETWORKAREA, 0, &area, 0);
    pos.x = area.right - @as(c_int, @intFromFloat((width + 18) * scale));
    pos.y = area.top + @as(c_int, @intFromFloat(14 * scale));
    const size = w.SIZE{ .cx = @intFromFloat(width * scale), .cy = @intFromFloat(height * scale) };
    var origin = w.POINT{};
    // A short fade in, as on the Mac.
    const blend = w.BLENDFUNCTION{ .alpha = @intFromFloat(255 * ease((t_now - shown_at) / 0.18)) };
    _ = w.UpdateLayeredWindow(h, null, &pos, &size, dc.?, &origin, 0, &blend, 2); // ULW_ALPHA
    _ = w.ShowWindow(h, 4); // SW_SHOWNOACTIVATE
}

fn drawCore(g: Gp, t: f64, morph: f64) void {
    gp.drawCore(g, scale, 34, 39, level, t, morph, mode == 2);
}

fn drawSignal(g: Gp, t: f64, morph: f64) void {
    const energy = @max(0, if (mode == 1) level else release_level);
    // Continuous ribbons settle into the typographic baseline.
    for (0..3) |layer_i| {
        const layer: f64 = @floatFromInt(layer_i);
        var points: [91]PointF = undefined;
        for (&points, 0..) |*p, i| {
            const u = @as(f64, @floatFromInt(i)) / 90;
            const envelope = std.math.pow(f64, @sin(u * std.math.pi), 1.5);
            const amplitude = (0.5 + energy * 14.5) * envelope * (1 - morph);
            const y = 50 - amplitude * (@sin(u * (4 + motion * 2) * std.math.pi - signal_phase + layer * 0.6) * 0.72 +
                @sin(u * 9 * std.math.pi + signal_phase * 0.6) * 0.28);
            const inset = 28 * ease(morph * 2);
            p.* = pt(66 + inset + u * (160 - inset), y);
        }
        stroke(g, &points, ink((0.7 - layer * 0.19) * (1 - morph)), 1.2);
    }
    if (morph > 0) drawCipher(g, t, ease((morph - 0.25) / 0.75));
}

// Letters settle left to right, hold, then scramble again.
fn drawCipher(g: Gp, t: f64, opacity: f64) void {
    const phrase = "deciphering your voice";
    const pool = "abcdefghijklmnopqrstuvwxyz0123456789#$%&*+=<>/\\|?!";
    const cycle = 2.8;
    const local = @mod(t, cycle) / cycle;
    const count: f64 = phrase.len;
    const settled = if (local < 0.45) local / 0.45 * count else if (local < 0.75) count else (1 - (local - 0.75) / 0.25) * count;
    const tick_n: u64 = @intFromFloat(t * 18);
    for (phrase, 0..) |c, i| {
        const fixed = @as(f64, @floatFromInt(i)) < settled or c == ' ';
        var glyph: u16 = c;
        if (!fixed) {
            const hash = (@as(u32, @truncate(i *% 2654435761))) ^ @as(u32, @truncate(tick_n *% 40503 + i * 97));
            glyph = pool[(hash >> 3) % pool.len];
        }
        text(g, &.{glyph}, if (fixed) mono_bold else mono_font, 64 + @as(f64, @floatFromInt(i)) * 7.4, 45, ink(opacity * (if (fixed) @as(f64, 0.85) else 0.4)));
    }
}
