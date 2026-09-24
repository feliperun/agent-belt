//! The dictation overlay on Windows, drawn like the macOS one (src/status_item.m)
//! and the Linux one (src/linux/overlay.qml): a core that breathes with the
//! voice, ribbons that follow it, and a phrase that keeps deciphering while the
//! text is on its way. GDI+ renders it with antialiasing and alpha into a
//! layered window, so the rounded corners are real.
const std = @import("std");
const w = @import("win32.zig");

const width = 252;
const height = 78;

// ---------------------------------------------------------------- GDI+

const Status = c_int;
const PointF = extern struct { x: f32, y: f32 };
const RectF = extern struct { x: f32, y: f32, w: f32, h: f32 };
const StartupInput = extern struct { version: u32 = 1, callback: ?*anyopaque = null, no_thread: w.BOOL = 0, no_codecs: w.BOOL = 0 };
const Gp = *opaque {};
const unit_pixel = 2;
const smoothing_antialias = 4;
const text_antialias = 4;
const pixel_format_32bpp_pargb = 0xE200B;

extern "gdiplus" fn GdiplusStartup(token: *usize, input: *const StartupInput, output: ?*anyopaque) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreateBitmapFromScan0(w: c_int, h: c_int, stride: c_int, format: c_int, scan0: ?*anyopaque, bitmap: *?Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipGetImageGraphicsContext(image: Gp, graphics: *?Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipDisposeImage(image: Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeleteGraphics(graphics: Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetSmoothingMode(graphics: Gp, mode: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetTextRenderingHint(graphics: Gp, hint: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipGraphicsClear(graphics: Gp, argb: u32) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreatePen1(argb: u32, width: f32, unit: c_int, pen: *?Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeletePen(pen: Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipDrawLines(graphics: Gp, pen: Gp, points: [*]const PointF, count: c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreatePath(fill_mode: c_int, path: *?Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipAddPathArc(path: Gp, x: f32, y: f32, w: f32, h: f32, start: f32, sweep: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipAddPathEllipse(path: Gp, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipClosePathFigure(path: Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeletePath(path: Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipFillPath(graphics: Gp, brush: Gp, path: Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipDrawPath(graphics: Gp, pen: Gp, path: Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreateLineBrushFromRect(rect: *const RectF, argb1: u32, argb2: u32, mode: c_int, wrap: c_int, brush: *?Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreatePathGradientFromPath(path: Gp, brush: *?Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetPathGradientCenterColor(brush: Gp, argb: u32) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetPathGradientSurroundColorsWithCount(brush: Gp, colors: [*]const u32, count: *c_int) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreateSolidFill(argb: u32, brush: *?Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipSetSolidFillColor(brush: Gp, argb: u32) callconv(.winapi) Status;
extern "gdiplus" fn GdipDeleteBrush(brush: Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipFillEllipse(graphics: Gp, brush: Gp, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreateFontFamilyFromName(name: w.LPCWSTR, collection: ?*anyopaque, family: *?Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipCreateFont(family: Gp, size: f32, style: c_int, unit: c_int, font: *?Gp) callconv(.winapi) Status;
extern "gdiplus" fn GdipDrawString(graphics: Gp, text: [*]const u16, len: c_int, font: Gp, rect: *const RectF, format: ?*anyopaque, brush: Gp) callconv(.winapi) Status;

const BITMAPINFOHEADER = extern struct { size: u32 = @sizeOf(BITMAPINFOHEADER), width: i32, height: i32, planes: u16 = 1, bit_count: u16 = 32, compression: u32 = 0, size_image: u32 = 0, xppm: i32 = 0, yppm: i32 = 0, clr_used: u32 = 0, clr_important: u32 = 0 };
const SIZE = extern struct { cx: w.LONG, cy: w.LONG };
const BLENDFUNCTION = extern struct { op: u8 = 0, flags: u8 = 0, alpha: u8 = 255, format: u8 = 1 };
extern "gdi32" fn CreateDIBSection(hdc: ?w.HDC, info: *const BITMAPINFOHEADER, usage: w.UINT, bits: *?*anyopaque, section: ?w.HANDLE, offset: w.DWORD) callconv(.winapi) ?w.HBITMAP;
extern "gdi32" fn GetDeviceCaps(hdc: w.HDC, index: c_int) callconv(.winapi) c_int;
extern "user32" fn GetDC(hwnd: ?w.HWND) callconv(.winapi) ?w.HDC;
extern "user32" fn ReleaseDC(hwnd: ?w.HWND, hdc: w.HDC) callconv(.winapi) c_int;
extern "user32" fn UpdateLayeredWindow(hwnd: w.HWND, dst: ?w.HDC, pos: ?*const w.POINT, size: ?*const SIZE, src: w.HDC, src_pos: ?*const w.POINT, key: w.DWORD, blend: *const BLENDFUNCTION, flags: w.DWORD) callconv(.winapi) w.BOOL;
extern "user32" fn SetProcessDPIAware() callconv(.winapi) w.BOOL;

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

fn argb(a: f64, r: u8, g: u8, b: u8) u32 {
    const alpha: u32 = @intFromFloat(std.math.clamp(a, 0, 1) * 255);
    return (alpha << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

fn ink(a: f64) u32 {
    return argb(a, 184, 201, 245);
}

/// Called once from the daemon's UI thread. The window stays hidden until show.
pub fn create(instance: ?w.HINSTANCE, proc: w.WNDPROC) void {
    _ = SetProcessDPIAware();
    var token: usize = 0;
    if (GdiplusStartup(&token, &.{}, null) != 0) return;
    const screen = GetDC(null) orelse return;
    defer _ = ReleaseDC(null, screen);
    scale = @as(f32, @floatFromInt(GetDeviceCaps(screen, 88))) / 96.0; // LOGPIXELSX
    const pw: c_int = @intFromFloat(width * scale);
    const ph: c_int = @intFromFloat(height * scale);
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = proc, .hInstance = instance, .lpszClassName = w.L("AgentBeltOverlay") });
    hwnd = w.CreateWindowExW(w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE | w.WS_EX_LAYERED | w.WS_EX_TRANSPARENT, w.L("AgentBeltOverlay"), w.L("Agent Belt"), w.WS_POPUP, 0, 0, pw, ph, null, null, instance, null);
    dc = w.CreateCompatibleDC(screen);
    const info = BITMAPINFOHEADER{ .width = pw, .height = -ph }; // top-down
    const dib = CreateDIBSection(screen, &info, 0, &bits, null, 0) orelse return;
    _ = w.SelectObject(dc.?, @ptrCast(dib));
    _ = GdipCreateBitmapFromScan0(pw, ph, pw * 4, pixel_format_32bpp_pargb, bits, &bitmap);
    var family: ?Gp = null;
    if (GdipCreateFontFamilyFromName(w.L("Segoe UI Semibold"), null, &family) == 0 or GdipCreateFontFamilyFromName(w.L("Segoe UI"), null, &family) == 0)
        _ = GdipCreateFont(family.?, 12 * scale, 0, unit_pixel, &label_font);
    var mono: ?Gp = null;
    if (GdipCreateFontFamilyFromName(w.L("Consolas"), null, &mono) == 0) {
        _ = GdipCreateFont(mono.?, 11 * scale, 0, unit_pixel, &mono_font);
        _ = GdipCreateFont(mono.?, 11 * scale, 1, unit_pixel, &mono_bold);
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
    if (GdipCreatePen1(color, line_width * scale, unit_pixel, &pen) != 0) return;
    defer _ = GdipDeletePen(pen.?);
    _ = GdipDrawLines(g, pen.?, points.ptr, @intCast(points.len));
}

fn text(g: Gp, str: []const u16, font: ?Gp, x: f64, y: f64, color: u32) void {
    var brush: ?Gp = null;
    if (GdipCreateSolidFill(color, &brush) != 0) return;
    defer _ = GdipDeleteBrush(brush.?);
    const rect = RectF{ .x = @floatCast(x * scale), .y = @floatCast(y * scale), .w = 200 * scale, .h = 24 * scale };
    _ = GdipDrawString(g, str.ptr, @intCast(str.len), font orelse return, &rect, null, brush.?);
}

fn render() void {
    const h = hwnd orelse return;
    const bmp = bitmap orelse return;
    var gg: ?Gp = null;
    if (GdipGetImageGraphicsContext(bmp, &gg) != 0) return;
    const g = gg.?;
    defer _ = GdipDeleteGraphics(g);
    _ = GdipSetSmoothingMode(g, smoothing_antialias);
    _ = GdipSetTextRenderingHint(g, text_antialias);
    _ = GdipGraphicsClear(g, 0);

    const t_now = now();
    const t = phase;
    const morph = if (mode == 2) ease((t_now - mode_started) / 0.7) else 0;

    // Shell: a rounded surface with a faint edge.
    var path: ?Gp = null;
    if (GdipCreatePath(0, &path) == 0) {
        defer _ = GdipDeletePath(path.?);
        const x0: f32 = 2 * scale;
        const y0: f32 = 2 * scale;
        const x1: f32 = (width - 2) * scale;
        const y1: f32 = (height - 2) * scale;
        const d: f32 = 46 * scale;
        _ = GdipAddPathArc(path.?, x0, y0, d, d, 180, 90);
        _ = GdipAddPathArc(path.?, x1 - d, y0, d, d, 270, 90);
        _ = GdipAddPathArc(path.?, x1 - d, y1 - d, d, d, 0, 90);
        _ = GdipAddPathArc(path.?, x0, y1 - d, d, d, 90, 90);
        _ = GdipClosePathFigure(path.?);
        const rect = RectF{ .x = 0, .y = 0, .w = width * scale, .h = height * scale };
        var surface: ?Gp = null;
        if (GdipCreateLineBrushFromRect(&rect, argb(0.98, 29, 32, 41), argb(0.98, 17, 19, 26), 1, 0, &surface) == 0) {
            _ = GdipFillPath(g, surface.?, path.?);
            _ = GdipDeleteBrush(surface.?);
        }
        var edge: ?Gp = null;
        if (GdipCreatePen1(ink(0.16), 0.75 * scale, unit_pixel, &edge) == 0) {
            _ = GdipDrawPath(g, edge.?, path.?);
            _ = GdipDeletePen(edge.?);
        }
    }

    drawCore(g, t, morph);
    text(g, if (mode == 1) w.L("Listening") else w.L("Transcribing"), label_font, 62, 13, ink(0.92));
    drawSignal(g, t, morph);

    var pos = w.POINT{};
    var area = w.RECT{};
    _ = w.SystemParametersInfoW(w.SPI_GETWORKAREA, 0, &area, 0);
    pos.x = area.right - @as(c_int, @intFromFloat((width + 18) * scale));
    pos.y = area.top + @as(c_int, @intFromFloat(14 * scale));
    const size = SIZE{ .cx = @intFromFloat(width * scale), .cy = @intFromFloat(height * scale) };
    var origin = w.POINT{};
    // A short fade in, as on the Mac.
    const blend = BLENDFUNCTION{ .alpha = @intFromFloat(255 * ease((t_now - shown_at) / 0.18)) };
    _ = UpdateLayeredWindow(h, null, &pos, &size, dc.?, &origin, 0, &blend, 2); // ULW_ALPHA
    _ = w.ShowWindow(h, 4); // SW_SHOWNOACTIVATE
}

fn drawCore(g: Gp, t: f64, morph: f64) void {
    const cx = 34.0;
    const cy = 39.0;
    const energy = @sqrt(@max(0, level));
    const radius = 11 + energy * 2.8;
    // A low-contrast halo and three drifting contours share the same center.
    var halo_path: ?Gp = null;
    if (GdipCreatePath(0, &halo_path) == 0) {
        defer _ = GdipDeletePath(halo_path.?);
        _ = GdipAddPathEllipse(halo_path.?, @floatCast((cx - 22) * scale), @floatCast((cy - 22) * scale), 44 * scale, 44 * scale);
        var halo: ?Gp = null;
        if (GdipCreatePathGradientFromPath(halo_path.?, &halo) == 0) {
            _ = GdipSetPathGradientCenterColor(halo.?, ink(0.11 + energy * 0.05));
            const surround = [_]u32{ink(0)};
            var count: c_int = 1;
            _ = GdipSetPathGradientSurroundColorsWithCount(halo.?, &surround, &count);
            _ = GdipFillPath(g, halo.?, halo_path.?);
            _ = GdipDeleteBrush(halo.?);
        }
    }
    for (0..3) |layer_i| {
        const layer: f64 = @floatFromInt(layer_i);
        var points: [91]PointF = undefined;
        for (&points, 0..) |*p, i| {
            const a = @as(f64, @floatFromInt(i)) * 2 * std.math.pi / 90;
            const ripple = @sin(a * 3 + t * 1.25 + layer * 1.7) * (1.1 + energy * 2) * (1 - morph * 0.6);
            const r = radius + layer * 1.3 + ripple;
            const turn = t * (0.12 + morph * 0.25) + layer * 0.25;
            p.* = pt(cx + @cos(a + turn) * r, cy - @sin(a + turn) * r * 0.88);
        }
        const red: u8 = @intFromFloat((0.58 + layer * 0.12) * 255);
        const green: u8 = @intFromFloat((0.76 - layer * 0.05) * 255);
        stroke(g, &points, argb(0.58 - layer * 0.12, red, green, 245), 1.05);
    }
    const angle = t * (if (mode == 2) @as(f64, 1.5) else 0.5);
    var light: ?Gp = null;
    if (GdipCreateSolidFill(ink(0.88), &light) == 0) {
        const p = pt(cx + @cos(angle) * radius - 1.4, cy - @sin(angle) * radius * 0.88 - 1.4);
        _ = GdipFillEllipse(g, light.?, p.x, p.y, 2.8 * scale, 2.8 * scale);
        _ = GdipDeleteBrush(light.?);
    }
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
