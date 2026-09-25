//! The GDI+ Agent Belt draws with on Windows (the dictation overlay, the
//! create-agent panel, the tray icon), and the pieces they share with the
//! macOS and Linux surfaces: the ink, the dark rounded shell and the
//! breathing core (mk_draw_core in src/status_item.m).
const std = @import("std");
const w = @import("win32.zig");

pub const Status = c_int;
pub const PointF = extern struct { x: f32, y: f32 };
pub const RectF = extern struct { x: f32, y: f32, w: f32, h: f32 };
const StartupInput = extern struct { version: u32 = 1, callback: ?*anyopaque = null, no_thread: w.BOOL = 0, no_codecs: w.BOOL = 0 };
pub const Gp = *opaque {};
pub const unit_pixel = 2;
pub const smoothing_antialias = 4;
pub const text_antialias = 4;
pub const pixel_format_32bpp_pargb = 0xE200B;
pub const pixel_format_32bpp_argb = 0x26200A;
pub const font_regular = 0;
pub const font_bold = 1;

extern "gdiplus" fn GdiplusStartup(token: *usize, input: *const StartupInput, output: ?*anyopaque) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipCreateBitmapFromScan0(w: c_int, h: c_int, stride: c_int, format: c_int, scan0: ?*anyopaque, bitmap: *?Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipCreateHICONFromBitmap(bitmap: Gp, icon: *?w.HICON) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipGetImageGraphicsContext(image: Gp, graphics: *?Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipDisposeImage(image: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipDeleteGraphics(graphics: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipSetSmoothingMode(graphics: Gp, mode: c_int) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipSetTextRenderingHint(graphics: Gp, hint: c_int) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipGraphicsClear(graphics: Gp, argb: u32) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipCreatePen1(argb: u32, width: f32, unit: c_int, pen: *?Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipDeletePen(pen: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipDrawLines(graphics: Gp, pen: Gp, points: [*]const PointF, count: c_int) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipCreatePath(fill_mode: c_int, path: *?Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipAddPathArc(path: Gp, x: f32, y: f32, w: f32, h: f32, start: f32, sweep: f32) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipAddPathEllipse(path: Gp, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipClosePathFigure(path: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipDeletePath(path: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipFillPath(graphics: Gp, brush: Gp, path: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipDrawPath(graphics: Gp, pen: Gp, path: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipCreateLineBrushFromRect(rect: *const RectF, argb1: u32, argb2: u32, mode: c_int, wrap: c_int, brush: *?Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipCreatePathGradientFromPath(path: Gp, brush: *?Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipSetPathGradientCenterColor(brush: Gp, argb: u32) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipSetPathGradientSurroundColorsWithCount(brush: Gp, colors: [*]const u32, count: *c_int) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipCreateSolidFill(argb: u32, brush: *?Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipDeleteBrush(brush: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipFillEllipse(graphics: Gp, brush: Gp, x: f32, y: f32, w: f32, h: f32) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipCreateFontFamilyFromName(name: w.LPCWSTR, collection: ?*anyopaque, family: *?Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipCreateFont(family: Gp, size: f32, style: c_int, unit: c_int, font: *?Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipDrawString(graphics: Gp, text: [*]const u16, len: c_int, font: Gp, rect: *const RectF, format: ?Gp, brush: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipMeasureString(graphics: Gp, text: [*]const u16, len: c_int, font: Gp, rect: *const RectF, format: ?Gp, box: *RectF, fitted: ?*c_int, lines: ?*c_int) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipCreateStringFormat(flags: c_int, language: u16, format: *?Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipSetClipRect(graphics: Gp, x: f32, y: f32, w: f32, h: f32, mode: c_int) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipResetClip(graphics: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipDeleteStringFormat(format: Gp) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipSetStringFormatTrimming(format: Gp, trimming: c_int) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipSetStringFormatAlign(format: Gp, alignment: c_int) callconv(.winapi) Status;
pub extern "gdiplus" fn GdipSetStringFormatLineAlign(format: Gp, alignment: c_int) callconv(.winapi) Status;

var started = false;

pub fn startup() bool {
    if (started) return true;
    var token: usize = 0;
    started = GdiplusStartup(&token, &.{}, null) == 0;
    return started;
}

pub fn argb(a: f64, r: u8, g: u8, b: u8) u32 {
    const alpha: u32 = @intFromFloat(std.math.clamp(a, 0, 1) * 255);
    return (alpha << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

/// The one ink of every surface: sRGB 0.72, 0.79, 0.96.
pub fn ink(a: f64) u32 {
    return argb(a, 184, 201, 245);
}

/// A font by family, the first of `families` this machine has.
pub fn font(families: []const [:0]const u16, size: f32, style: c_int) ?Gp {
    for (families) |name| {
        var family: ?Gp = null;
        if (GdipCreateFontFamilyFromName(name, null, &family) != 0) continue;
        var f: ?Gp = null;
        if (GdipCreateFont(family.?, size, style, unit_pixel, &f) == 0) return f;
    }
    return null;
}

/// A rounded rectangle, in pixels.
pub fn roundedPath(x0: f32, y0: f32, x1: f32, y1: f32, radius: f32) ?Gp {
    var path: ?Gp = null;
    if (GdipCreatePath(0, &path) != 0) return null;
    const d = radius * 2;
    _ = GdipAddPathArc(path.?, x0, y0, d, d, 180, 90);
    _ = GdipAddPathArc(path.?, x1 - d, y0, d, d, 270, 90);
    _ = GdipAddPathArc(path.?, x1 - d, y1 - d, d, d, 0, 90);
    _ = GdipAddPathArc(path.?, x0, y1 - d, d, d, 90, 90);
    _ = GdipClosePathFigure(path.?);
    return path;
}

pub fn fillPath(g: Gp, path: Gp, color: u32) void {
    var brush: ?Gp = null;
    if (GdipCreateSolidFill(color, &brush) != 0) return;
    _ = GdipFillPath(g, brush.?, path);
    _ = GdipDeleteBrush(brush.?);
}

pub fn strokePath(g: Gp, path: Gp, color: u32, line_width: f32) void {
    var pen: ?Gp = null;
    if (GdipCreatePen1(color, line_width, unit_pixel, &pen) != 0) return;
    _ = GdipDrawPath(g, pen.?, path);
    _ = GdipDeletePen(pen.?);
}

pub fn fillCircle(g: Gp, cx: f32, cy: f32, r: f32, color: u32) void {
    var brush: ?Gp = null;
    if (GdipCreateSolidFill(color, &brush) != 0) return;
    _ = GdipFillEllipse(g, brush.?, cx - r, cy - r, r * 2, r * 2);
    _ = GdipDeleteBrush(brush.?);
}

/// The surface of every panel: a dark vertical gradient in a rounded shell
/// with a faint edge. Logical size, drawn at `scale`.
pub fn drawShell(g: Gp, scale: f32, width: f32, height: f32, radius: f32) void {
    const path = roundedPath(2 * scale, 2 * scale, (width - 2) * scale, (height - 2) * scale, radius * scale) orelse return;
    defer _ = GdipDeletePath(path);
    const rect = RectF{ .x = 0, .y = 0, .w = width * scale, .h = height * scale };
    var surface: ?Gp = null;
    if (GdipCreateLineBrushFromRect(&rect, argb(0.98, 29, 32, 41), argb(0.98, 17, 19, 26), 1, 0, &surface) == 0) {
        _ = GdipFillPath(g, surface.?, path);
        _ = GdipDeleteBrush(surface.?);
    }
    strokePath(g, path, ink(0.16), 0.75 * scale);
}

fn stroke(g: Gp, points: []const PointF, color: u32, line_width: f32) void {
    var pen: ?Gp = null;
    if (GdipCreatePen1(color, line_width, unit_pixel, &pen) != 0) return;
    defer _ = GdipDeletePen(pen.?);
    _ = GdipDrawLines(g, pen.?, points.ptr, @intCast(points.len));
}

/// A halo and three drifting contours that breathe with the voice, and a light
/// orbiting them (faster while something is being worked out).
pub fn drawCore(g: Gp, scale: f32, cx: f64, cy: f64, level: f64, t: f64, morph: f64, fast: bool) void {
    const s: f64 = scale;
    const energy = @sqrt(@max(0, level));
    const radius = 11 + energy * 2.8;
    var halo_path: ?Gp = null;
    if (GdipCreatePath(0, &halo_path) == 0) {
        defer _ = GdipDeletePath(halo_path.?);
        _ = GdipAddPathEllipse(halo_path.?, @floatCast((cx - 22) * s), @floatCast((cy - 22) * s), 44 * scale, 44 * scale);
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
            p.* = .{ .x = @floatCast((cx + @cos(a + turn) * r) * s), .y = @floatCast((cy - @sin(a + turn) * r * 0.88) * s) };
        }
        const red: u8 = @intFromFloat((0.58 + layer * 0.12) * 255);
        const green: u8 = @intFromFloat((0.76 - layer * 0.05) * 255);
        stroke(g, &points, argb(0.58 - layer * 0.12, red, green, 245), 1.05 * scale);
    }
    const angle = t * (if (fast) @as(f64, 1.5) else 0.5);
    fillCircle(g, @floatCast((cx + @cos(angle) * radius) * s), @floatCast((cy - @sin(angle) * radius * 0.88) * s), 1.4 * scale, ink(0.88));
}

/// mk_belt_icon (src/status_item.m) in a `size`-pixel square: a strap behind
/// a rounded buckle, the lamp in its middle, or the count of agents instead.
pub fn drawBelt(g: Gp, size: f32, color: u32, count: usize, count_font: ?Gp) void {
    const k = size / 22.0; // the 22x16 drawing, centered
    const oy = (size - 16 * k) / 2;
    for ([_][2]f32{ .{ 0.5, 4.8 }, .{ 17.2, 21.5 } }) |span| if (roundedPath(span[0] * k, oy + 6.4 * k, span[1] * k, oy + 9.6 * k, 1.6 * k)) |p| {
        fillPath(g, p, color);
        _ = GdipDeletePath(p);
    };
    if (roundedPath(6 * k, oy + 1.5 * k, 16 * k, oy + 14.5 * k, 3.4 * k)) |p| {
        strokePath(g, p, color, 1.7 * k);
        _ = GdipDeletePath(p);
    }
    if (count == 0 or count_font == null) return fillCircle(g, 11 * k, oy + 8 * k, 1.5 * k, color);
    var buf: [4]u8 = undefined;
    const digits = if (count > 9) "9+" else (std.fmt.bufPrint(&buf, "{d}", .{count}) catch return);
    var wide: [4]u16 = undefined;
    for (digits, 0..) |c, i| wide[i] = c;
    var format: ?Gp = null;
    if (GdipCreateStringFormat(0x1000, 0, &format) != 0) return; // no wrap
    defer _ = GdipDeleteStringFormat(format.?);
    _ = GdipSetStringFormatAlign(format.?, 1);
    _ = GdipSetStringFormatLineAlign(format.?, 1);
    var brush: ?Gp = null;
    if (GdipCreateSolidFill(color, &brush) != 0) return;
    defer _ = GdipDeleteBrush(brush.?);
    const rect = RectF{ .x = 4 * k, .y = oy, .w = 14 * k, .h = 16 * k };
    _ = GdipDrawString(g, &wide, @intCast(digits.len), count_font.?, &rect, format, brush.?);
}
