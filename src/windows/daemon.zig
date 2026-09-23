//! Agent Belt on Windows: a notification-area icon whose menu lists the agent
//! sessions of every machine, a dictation overlay, and push-to-talk on a hotkey
//! (hold Ctrl+Alt+D). Runs as agent-belt.exe (GUI subsystem, started at login);
//! agb.exe is the CLI.
const std = @import("std");
const w = @import("win32.zig");
const sys = @import("../sessions/sys.zig");
const cli = @import("../sessions/cli.zig");
const hosts = @import("../sessions/hosts.zig");
const deepgram = @import("../deepgram.zig");
const config = @import("../config.zig");

const WM_TRAY = w.WM_APP + 1;
const WM_PTT = w.WM_APP + 2; // wparam 1 start, 0 stop
const WM_MENU = w.WM_APP + 3;
const WM_SESSIONS = w.WM_APP + 4;
const WM_OVERLAY = w.WM_APP + 5; // wparam: 0 hide, 1 recording, 2 transcribing

const CMD_NEW = 1;
const CMD_SESSIONS = 2;
const CMD_LOG = 3;
const CMD_QUIT = 4;
const CMD_REFRESH = 5;
const CMD_SESSION = 1000;

var g_ctx: sys.Ctx = undefined;
var g_version: []const u8 = "";
var g_instance: ?w.HINSTANCE = null;
var g_hwnd: ?w.HWND = null;
var g_overlay: ?w.HWND = null;
var g_dialog: ?w.HWND = null;
var g_edit: ?w.HWND = null;
var g_hook: ?w.HHOOK = null;
var g_tray: w.NOTIFYICONDATAW = .{};
var g_ptt_down = false;

var g_state = std.atomic.Value(u8).init(0); // overlay: 0 hidden, 1 recording, 2 transcribing
var g_level = std.atomic.Value(u32).init(0); // microphone level, permille
var g_recording = std.atomic.Value(bool).init(false);
var g_phase: f64 = 0;
var g_shown_at: u64 = 0;

var g_rows_lock: std.Io.Mutex = .init;
var g_rows: []cli.Row = &.{};
var g_rows_ready = false;

// ---------------------------------------------------------------- log

fn logPath(ctx: sys.Ctx) ![]const u8 {
    const base = ctx.getenv("LOCALAPPDATA") orelse ctx.home();
    const dir = try ctx.join(&.{ base, "agent-belt" });
    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
    return ctx.join(&.{ dir, "agent-belt.log" });
}

fn log(comptime format: []const u8, args: anytype) void {
    const path = logPath(g_ctx) catch return;
    const line = std.fmt.allocPrint(g_ctx.gpa, "[agent-belt] " ++ format ++ "\n", args) catch return;
    const old = sys.readFile(g_ctx, path) orelse "";
    const keep = if (old.len > 1024 * 1024) old[old.len - 256 * 1024 ..] else old;
    sys.writeFileAtomic(g_ctx, path, std.mem.concat(g_ctx.gpa, u8, &.{ keep, line }) catch return) catch {};
}

// ---------------------------------------------------------------- secrets

const cred_target = w.L("agent-belt");

fn deepgramKey(ctx: sys.Ctx) ?[]const u8 {
    if (ctx.getenv("DEEPGRAM_API_KEY")) |k| if (k.len > 0) return k;
    var cred: ?*w.CREDENTIALW = null;
    if (w.CredReadW(cred_target, w.CRED_TYPE_GENERIC, 0, &cred) != 0) if (cred) |c| {
        defer w.CredFree(c);
        const blob = c.CredentialBlob orelse return null;
        return ctx.gpa.dupe(u8, blob[0..c.CredentialBlobSize]) catch null;
    };
    const pending = pendingKeyPath(ctx) catch return null;
    const key = std.mem.trim(u8, sys.readFile(ctx, pending) orelse return null, " \r\n");
    return if (key.len > 0) key else null;
}

fn storeKey(key: []const u8) bool {
    const cred = w.CREDENTIALW{ .Type = w.CRED_TYPE_GENERIC, .TargetName = cred_target, .CredentialBlobSize = @intCast(key.len), .CredentialBlob = @constCast(key.ptr), .Persist = w.CRED_PERSIST_LOCAL_MACHINE, .UserName = w.L("deepgram") };
    return w.CredWriteW(&cred, 0) != 0;
}

/// An ssh logon has no credential vault (CredWrite fails with 1312), so
/// `agb install` over ssh leaves the key in the user's own LOCALAPPDATA and the
/// daemon, running on the desktop, moves it into Credential Manager.
fn pendingKeyPath(ctx: sys.Ctx) ![]const u8 {
    const base = ctx.getenv("LOCALAPPDATA") orelse ctx.home();
    return ctx.join(&.{ base, "agent-belt", "deepgram.key" });
}

fn adoptPendingKey(ctx: sys.Ctx) void {
    const pending = pendingKeyPath(ctx) catch return;
    const key = std.mem.trim(u8, sys.readFile(ctx, pending) orelse return, " \r\n");
    if (key.len == 0 or !storeKey(key)) return;
    std.Io.Dir.cwd().deleteFile(ctx.io, pending) catch {};
    log("Deepgram key moved into Credential Manager (agent-belt)", .{});
}

// ---------------------------------------------------------------- install

fn exeDir(ctx: sys.Ctx) ![]const u8 {
    return std.process.executableDirPathAlloc(ctx.io, ctx.gpa);
}

/// `agb install` on Windows: Deepgram key into Credential Manager (from
/// DEEPGRAM_API_KEY), agent-belt.exe started at login, and started now.
pub fn install(ctx: sys.Ctx) !u8 {
    g_ctx = ctx;
    const dir = try exeDir(ctx);
    const daemon = try ctx.join(&.{ dir, "agent-belt.exe" });
    if (!sys.isFile(ctx, daemon)) {
        std.debug.print("agb install: {s} is missing (run agb deploy from the Mac)\n", .{daemon});
        return 1;
    }
    if (ctx.getenv("DEEPGRAM_API_KEY")) |key| if (key.len > 0) {
        if (storeKey(key)) {
            std.debug.print("Deepgram key stored in Credential Manager (agent-belt)\n", .{});
        } else {
            const pending = try pendingKeyPath(ctx);
            std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(pending).?) catch {};
            try sys.writeFileAtomic(ctx, pending, key);
            std.debug.print("Deepgram key saved for the daemon, which moves it into Credential Manager on start\n", .{});
        }
    };
    const value = try w.wide(ctx.gpa, try ctx.fmt("\"{s}\"", .{daemon}));
    const rc = w.RegSetKeyValueW(w.HKEY_CURRENT_USER, w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Run"), w.L("AgentBelt"), w.REG_SZ, value.ptr, @intCast((value.len + 1) * 2));
    std.debug.print("{s}\n", .{if (rc == 0) "starts at login (HKCU Run: AgentBelt)" else "could not register the login item"});
    // Started on the logged-on user's desktop, also when installing over ssh.
    _ = sys.run(ctx, &.{ "taskkill", "/im", "agent-belt.exe", "/f" }, null);
    _ = sys.run(ctx, &.{ "schtasks", "/create", "/tn", "AgentBelt", "/tr", try ctx.fmt("\"{s}\"", .{daemon}), "/sc", "once", "/st", "00:00", "/it", "/f" }, null);
    const started = sys.run(ctx, &.{ "schtasks", "/run", "/tn", "AgentBelt" }, null);
    std.debug.print("{s}\n", .{if (started.ok) "running: tray icon, hold Ctrl+Alt+D to dictate, Ctrl+Alt+Space for the menu" else "start it by logging in again"});
    if (deepgramKey(ctx) == null) std.debug.print("no Deepgram key yet: set DEEPGRAM_API_KEY and run agb install again\n", .{});
    return 0;
}

pub fn uninstall(ctx: sys.Ctx) !u8 {
    _ = ctx;
    _ = w.RegDeleteKeyValueW(w.HKEY_CURRENT_USER, w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Run"), w.L("AgentBelt"));
    std.debug.print("login item removed; the Deepgram key stays in Credential Manager (agent-belt)\n", .{});
    return 0;
}

// ---------------------------------------------------------------- recording

const rate = 16000;
const Recorder = struct {
    handle: ?w.HWAVEIN = null,
    headers: [4]w.WAVEHDR = undefined,
    buffers: [4][3200]u8 = undefined, // 100 ms each
    pcm: std.ArrayList(u8) = .empty,

    fn start(self: *Recorder) bool {
        const format = w.WAVEFORMATEX{ .wFormatTag = w.WAVE_FORMAT_PCM, .nChannels = 1, .nSamplesPerSec = rate, .nAvgBytesPerSec = rate * 2, .nBlockAlign = 2, .wBitsPerSample = 16, .cbSize = 0 };
        if (w.waveInOpen(&self.handle, w.WAVE_MAPPER, &format, 0, 0, w.CALLBACK_NULL) != 0) return false;
        const h = self.handle.?;
        for (&self.headers, &self.buffers) |*hdr, *buf| {
            hdr.* = .{ .lpData = buf, .dwBufferLength = buf.len };
            _ = w.waveInPrepareHeader(h, hdr, @sizeOf(w.WAVEHDR));
            _ = w.waveInAddBuffer(h, hdr, @sizeOf(w.WAVEHDR));
        }
        return w.waveInStart(h) == 0;
    }

    /// Collects finished buffers and hands them back to the driver.
    fn poll(self: *Recorder, requeue: bool) void {
        const h = self.handle orelse return;
        for (&self.headers) |*hdr| {
            if (hdr.dwFlags & w.WHDR_DONE == 0) continue;
            const data = hdr.lpData[0..hdr.dwBytesRecorded];
            self.pcm.appendSlice(g_ctx.gpa, data) catch {};
            g_level.store(levelPermille(data), .release);
            hdr.dwFlags &= ~@as(w.DWORD, w.WHDR_DONE);
            hdr.dwBytesRecorded = 0;
            if (requeue) _ = w.waveInAddBuffer(h, hdr, @sizeOf(w.WAVEHDR));
        }
    }

    fn finish(self: *Recorder) []const u8 {
        const h = self.handle orelse return &.{};
        _ = w.waveInStop(h);
        _ = w.waveInReset(h);
        self.poll(false);
        for (&self.headers) |*hdr| _ = w.waveInUnprepareHeader(h, hdr, @sizeOf(w.WAVEHDR));
        _ = w.waveInClose(h);
        return wav(self.pcm.items);
    }
};

/// RMS of 16-bit samples on a voice-friendly dB scale, 0..1000.
fn levelPermille(data: []const u8) u32 {
    const samples = data.len / 2;
    if (samples == 0) return 0;
    var sum: f64 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        const s: f64 = @floatFromInt(std.mem.readInt(i16, data[i..][0..2], .little));
        sum += s * s;
    }
    const rms = @sqrt(sum / @as(f64, @floatFromInt(samples))) / 32768.0;
    const db = 20 * std.math.log10(@max(rms, 1e-6));
    const level = std.math.clamp((db + 55) / 45, 0, 1);
    return @intFromFloat(level * 1000);
}

fn wav(pcm: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const header_len = 44;
    out.ensureTotalCapacity(g_ctx.gpa, header_len + pcm.len) catch return &.{};
    const put32 = struct {
        fn f(list: *std.ArrayList(u8), v: u32) void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            list.appendSliceAssumeCapacity(&b);
        }
    }.f;
    const put16 = struct {
        fn f(list: *std.ArrayList(u8), v: u16) void {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, v, .little);
            list.appendSliceAssumeCapacity(&b);
        }
    }.f;
    out.appendSliceAssumeCapacity("RIFF");
    put32(&out, @intCast(36 + pcm.len));
    out.appendSliceAssumeCapacity("WAVEfmt ");
    put32(&out, 16);
    put16(&out, 1);
    put16(&out, 1);
    put32(&out, rate);
    put32(&out, rate * 2);
    put16(&out, 2);
    put16(&out, 16);
    out.appendSliceAssumeCapacity("data");
    put32(&out, @intCast(pcm.len));
    out.appendSliceAssumeCapacity(pcm);
    return out.items;
}

fn recordAndTranscribe() void {
    var recorder = Recorder{};
    if (!recorder.start()) {
        log("microphone unavailable (waveInOpen)", .{});
        g_recording.store(false, .release);
        _ = w.PostMessageW(g_hwnd, WM_OVERLAY, 0, 0);
        return;
    }
    while (g_recording.load(.acquire)) {
        recorder.poll(true);
        w.Sleep(20);
    }
    const audio = recorder.finish();
    _ = w.PostMessageW(g_hwnd, WM_OVERLAY, 2, 0);
    defer _ = w.PostMessageW(g_hwnd, WM_OVERLAY, 0, 0);
    if (audio.len <= 44 + rate / 5) { // under ~100 ms: an accidental tap
        log("recording too short, ignored", .{});
        return;
    }
    const key = deepgramKey(g_ctx) orelse {
        log("no Deepgram key: set DEEPGRAM_API_KEY and run agb install", .{});
        return;
    };
    const defaults = config.Config{};
    const client = deepgram.Client{ .io = g_ctx.io, .allocator = g_ctx.gpa, .api_key = key, .model = defaults.deepgram_model, .language = defaults.deepgram_language, .smart_format = defaults.deepgram_smart_format, .mip_opt_out = defaults.deepgram_mip_opt_out };
    const text = client.transcribe(audio) catch |err| {
        log("transcription failed: {s}", .{@errorName(err)});
        return;
    };
    if (text.len == 0) {
        log("no speech detected", .{});
        return;
    }
    // The overlay never takes focus; hide it first, then type.
    _ = w.PostMessageW(g_hwnd, WM_OVERLAY, 0, 0);
    w.Sleep(80);
    typeText(text);
    log("inserted {d} characters", .{text.len});
}

/// Types text into the focused window as Unicode key events.
fn typeText(text: []const u8) void {
    const utf16 = std.unicode.utf8ToUtf16LeAlloc(g_ctx.gpa, text) catch return;
    for (utf16) |unit| {
        var inputs: [2]w.INPUT = undefined;
        if (unit == '\n') {
            inputs[0] = .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = w.VK_RETURN, .wScan = 0, .dwFlags = 0 } } };
            inputs[1] = .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = w.VK_RETURN, .wScan = 0, .dwFlags = w.KEYEVENTF_KEYUP } } };
        } else {
            inputs[0] = .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = 0, .wScan = unit, .dwFlags = w.KEYEVENTF_UNICODE } } };
            inputs[1] = .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = 0, .wScan = unit, .dwFlags = w.KEYEVENTF_UNICODE | w.KEYEVENTF_KEYUP } } };
        }
        _ = w.SendInput(2, &inputs, @sizeOf(w.INPUT));
    }
}

// ---------------------------------------------------------------- sessions snapshot

fn refreshLoop() void {
    while (true) {
        refreshOnce();
        w.Sleep(15_000);
    }
}

fn refreshOnce() void {
    const reg = hosts.load(g_ctx) catch return;
    const c = cli.collect(g_ctx, reg) catch return;
    g_rows_lock.lockUncancelable(g_ctx.io);
    defer g_rows_lock.unlock(g_ctx.io);
    g_rows = c.rows;
    g_rows_ready = true;
}

/// Runs agb in a new console window, which Windows 11 hands to the default
/// terminal (Windows Terminal). Not through wt.exe: started from here it
/// opens no tab.
fn openTerminal(title: []const u8, args: []const []const u8) void {
    const dir = exeDir(g_ctx) catch return;
    const agb = g_ctx.join(&.{ dir, "agb.exe" }) catch return;
    var line: std.ArrayList(u8) = .empty;
    appendQuoted(&line, agb) catch return;
    for (args) |arg| {
        line.append(g_ctx.gpa, ' ') catch return;
        appendQuoted(&line, arg) catch return;
    }
    log("open: {s}", .{line.items});
    var si = w.STARTUPINFOW{ .lpTitle = w.wide(g_ctx.gpa, title) catch return };
    var pi = w.PROCESS_INFORMATION{};
    const cmd = w.wide(g_ctx.gpa, line.items) catch return;
    if (w.CreateProcessW(null, cmd, null, null, 0, w.CREATE_NEW_CONSOLE, null, w.wide(g_ctx.gpa, g_ctx.home()) catch null, &si, &pi) == 0) {
        log("could not open a terminal: {d}", .{w.GetLastError()});
        return;
    }
    if (pi.hProcess) |h| _ = w.CloseHandle(h);
    if (pi.hThread) |h| _ = w.CloseHandle(h);
}

/// Command-line quoting as CommandLineToArgvW reads it.
fn appendQuoted(out: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\"") == null) return out.appendSlice(g_ctx.gpa, arg);
    try out.append(g_ctx.gpa, '"');
    var slashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            slashes += 1;
            continue;
        }
        try out.appendNTimes(g_ctx.gpa, '\\', if (c == '"') slashes * 2 + 1 else slashes);
        slashes = 0;
        try out.append(g_ctx.gpa, c);
    }
    try out.appendNTimes(g_ctx.gpa, '\\', slashes * 2);
    try out.append(g_ctx.gpa, '"');
}

fn showMenu() void {
    const hwnd = g_hwnd orelse return;
    const menu = w.CreatePopupMenu() orelse return;
    defer _ = w.DestroyMenu(menu);
    const header = w.wide(g_ctx.gpa, g_ctx.fmt("Agent Belt {s}", .{g_version}) catch "Agent Belt") catch return;
    _ = w.AppendMenuW(menu, w.MF_STRING | w.MF_GRAYED, 0, header);
    _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    g_rows_lock.lockUncancelable(g_ctx.io);
    const rows = g_rows;
    const ready = g_rows_ready;
    g_rows_lock.unlock(g_ctx.io);
    if (!ready) {
        _ = w.AppendMenuW(menu, w.MF_STRING | w.MF_GRAYED, 0, w.L("Procurando sessões…"));
    } else if (rows.len == 0) {
        _ = w.AppendMenuW(menu, w.MF_STRING | w.MF_GRAYED, 0, w.L("Nenhuma sessão de agente"));
    }
    for (rows, 0..) |r, i| {
        if (i >= 30) break;
        // Win32 menus draw emoji in monochrome, so the agent is spelled out.
        const label = g_ctx.fmt("{s}\t{s} · {s}{s}", .{ r.name, if (r.agent.len > 0) r.agent else "shell", r.host.name, if (r.attached) " · anexada" else "" }) catch continue;
        _ = w.AppendMenuW(menu, w.MF_STRING, CMD_SESSION + i, w.wide(g_ctx.gpa, label) catch continue);
    }
    _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(menu, w.MF_STRING, CMD_NEW, w.L("Novo agente…"));
    _ = w.AppendMenuW(menu, w.MF_STRING, CMD_SESSIONS, w.L("Sessões no terminal    Ctrl+Alt+↑"));
    _ = w.AppendMenuW(menu, w.MF_STRING, CMD_REFRESH, w.L("Atualizar lista"));
    _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(menu, w.MF_STRING | w.MF_GRAYED, 0, w.L("Ditar: segure Ctrl+Alt+D"));
    _ = w.AppendMenuW(menu, w.MF_STRING, CMD_LOG, w.L("Abrir log"));
    _ = w.AppendMenuW(menu, w.MF_STRING, CMD_QUIT, w.L("Sair do Agent Belt"));
    var pt = w.POINT{};
    _ = w.GetCursorPos(&pt);
    _ = w.SetForegroundWindow(hwnd); // required for the menu to close on outside clicks
    const cmd = w.TrackPopupMenu(menu, w.TPM_RIGHTBUTTON | w.TPM_RETURNCMD | w.TPM_NONOTIFY, pt.x, pt.y, 0, hwnd, null);
    if (cmd <= 0) return;
    const id: usize = @intCast(cmd);
    switch (id) {
        CMD_NEW => showNewDialog(),
        CMD_SESSIONS => openTerminal("Agent Belt", &.{"sessions"}),
        CMD_REFRESH => _ = std.Thread.spawn(.{}, refreshOnce, .{}) catch null,
        CMD_LOG => if (logPath(g_ctx)) |p| {
            _ = std.process.spawn(g_ctx.io, .{ .argv = &.{ "notepad.exe", p }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {};
        } else |_| {},
        CMD_QUIT => w.PostQuitMessage(0),
        else => if (id >= CMD_SESSION and id - CMD_SESSION < rows.len) {
            const r = rows[id - CMD_SESSION];
            openTerminal(r.name, &.{ "attach", r.name, r.host.name });
        },
    }
}

// ---------------------------------------------------------------- new agent dialog

fn showNewDialog() void {
    if (g_dialog) |d| {
        _ = w.SetForegroundWindow(d);
        return;
    }
    const cx = w.GetSystemMetrics(0);
    const cy = w.GetSystemMetrics(1);
    const dialog = w.CreateWindowExW(w.WS_EX_TOPMOST, w.L("AgentBeltNew"), w.L("Agent Belt: novo agente"), w.WS_CAPTION | w.WS_SYSMENU | w.WS_VISIBLE, @divTrunc(cx - 560, 2), @divTrunc(cy - 170, 3), 560, 170, null, null, g_instance, null) orelse return;
    g_dialog = dialog;
    const font = w.CreateFontW(-15, 0, 0, 0, w.FW_NORMAL, 0, 0, 0, 1, 0, 0, 5, 0, w.L("Segoe UI"));
    const label = w.CreateWindowExW(0, w.L("STATIC"), w.L("Descreva o agente: agente, máquina, repo e o que fazer. Ex.: codex linux2 mac-debian rode os testes"), w.WS_CHILD | w.WS_VISIBLE, 16, 12, 520, 40, dialog, null, g_instance, null);
    g_edit = w.CreateWindowExW(w.WS_EX_CLIENTEDGE, w.L("EDIT"), w.L(""), w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP | w.ES_AUTOHSCROLL, 16, 58, 520, 28, dialog, null, g_instance, null);
    const button = w.CreateWindowExW(0, w.L("BUTTON"), w.L("Criar"), w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP | w.BS_DEFPUSHBUTTON, 436, 96, 100, 30, dialog, @ptrFromInt(1), g_instance, null);
    if (font) |f| for ([_]?w.HWND{ label, g_edit, button }) |c| if (c) |ctl| {
        _ = w.SendMessageW(ctl, w.WM_SETFONT, @intFromPtr(f), 1);
    };
    _ = w.SetForegroundWindow(dialog);
    _ = w.SetFocus(g_edit);
}

fn dialogProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        w.WM_COMMAND => if ((wparam & 0xFFFF) == 1) {
            var buf: [1024]u16 = undefined;
            const n = if (g_edit) |e| w.GetWindowTextW(e, &buf, buf.len) else 0;
            const text = std.unicode.utf16LeToUtf8Alloc(g_ctx.gpa, buf[0..@intCast(n)]) catch "";
            _ = w.DestroyWindow(hwnd);
            if (text.len > 0) {
                var words: std.ArrayList([]const u8) = .empty;
                words.append(g_ctx.gpa, "new") catch {};
                var it = std.mem.tokenizeAny(u8, text, " \t");
                while (it.next()) |word| words.append(g_ctx.gpa, word) catch {};
                openTerminal("Agent Belt: novo agente", words.items);
            }
            return 0;
        },
        w.WM_DESTROY => {
            g_dialog = null;
            g_edit = null;
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------- overlay

const overlay_w = 300;
const overlay_h = 72;

fn showOverlay(state: u8) void {
    g_state.store(state, .release);
    const ov = g_overlay orelse return;
    if (state == 0) {
        _ = w.KillTimer(ov, 1);
        _ = w.ShowWindow(ov, w.SW_HIDE);
        return;
    }
    var area = w.RECT{};
    _ = w.SystemParametersInfoW(w.SPI_GETWORKAREA, 0, &area, 0);
    _ = w.SetWindowPos(ov, w.HWND_TOPMOST, area.right - overlay_w - 18, area.top + 18, overlay_w, overlay_h, w.SWP_NOACTIVATE | w.SWP_SHOWWINDOW);
    g_shown_at = w.GetTickCount64();
    _ = w.SetTimer(ov, 1, 33, null);
    _ = w.InvalidateRect(ov, null, 0);
}

fn paintOverlay(hwnd: w.HWND) void {
    var ps: w.PAINTSTRUCT = undefined;
    const screen = w.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w.EndPaint(hwnd, &ps);
    const dc = w.CreateCompatibleDC(screen) orelse return;
    defer _ = w.DeleteDC(dc);
    const bmp = w.CreateCompatibleBitmap(screen, overlay_w, overlay_h) orelse return;
    defer _ = w.DeleteObject(@ptrCast(bmp));
    _ = w.SelectObject(dc, @ptrCast(bmp));

    const bg = w.CreateSolidBrush(w.rgb(24, 27, 36)) orelse return;
    defer _ = w.DeleteObject(@ptrCast(bg));
    var all = w.RECT{ .right = overlay_w, .bottom = overlay_h };
    _ = w.FillRect(dc, &all, bg);

    const state = g_state.load(.acquire);
    const level: f64 = @as(f64, @floatFromInt(g_level.load(.acquire))) / 1000.0;
    const ink = w.rgb(150, 188, 245);

    // Core: a ring that breathes with the voice.
    const pen = w.CreatePen(w.PS_SOLID, 2, ink) orelse return;
    defer _ = w.DeleteObject(@ptrCast(pen));
    const old_pen = w.SelectObject(dc, @ptrCast(pen));
    const r: c_int = @intFromFloat(11 + (if (state == 1) level * 5 else 2 * @sin(g_phase * 3)));
    const hollow = w.CreateSolidBrush(w.rgb(24, 27, 36)) orelse return;
    defer _ = w.DeleteObject(@ptrCast(hollow));
    const old_brush = w.SelectObject(dc, @ptrCast(hollow));
    _ = w.Ellipse(dc, 34 - r, 36 - r, 34 + r, 36 + r);
    _ = w.SelectObject(dc, old_brush orelse @ptrCast(hollow));

    _ = w.SetBkMode(dc, w.TRANSPARENT);
    const title_font = w.CreateFontW(-17, 0, 0, 0, w.FW_SEMIBOLD, 0, 0, 0, 1, 0, 0, 5, 0, w.L("Segoe UI"));
    if (title_font) |f| _ = w.SelectObject(dc, @ptrCast(f));
    _ = w.SetTextColor(dc, w.rgb(222, 229, 245));
    var title_rect = w.RECT{ .left = 64, .top = 10, .right = overlay_w - 12, .bottom = 32 };
    const title = if (state == 1) w.L("Ouvindo") else w.L("Transcrevendo");
    _ = w.DrawTextW(dc, title.ptr, @intCast(title.len), &title_rect, w.DT_LEFT | w.DT_SINGLELINE | w.DT_VCENTER);
    if (title_font) |f| _ = w.DeleteObject(@ptrCast(f));

    if (state == 1) {
        // The waveform follows the microphone: louder is taller and faster.
        var pts: [64]w.POINT = undefined;
        for (&pts, 0..) |*p, i| {
            const u: f64 = @as(f64, @floatFromInt(i)) / 63.0;
            const envelope = std.math.pow(f64, @sin(u * std.math.pi), 1.5);
            const amp = (1.0 + level * 14.0) * envelope;
            const y = 50.0 + amp * (@sin(u * 5.0 * std.math.pi - g_phase * (3 + level * 10)) * 0.75 + @sin(u * 11.0 * std.math.pi + g_phase * 2) * 0.25);
            p.* = .{ .x = @intFromFloat(64 + u * 222), .y = @intFromFloat(y) };
        }
        _ = w.Polyline(dc, &pts, pts.len);
    } else {
        // While the text is on its way, glyphs keep deciphering into a phrase.
        const phrase = "decifrando sua voz";
        const pool = "abcdefghijklmnopqrstuvwxyz0123456789#$%&*+=<>/?!";
        const cycle = 2.8;
        const local = @mod(g_phase, cycle) / cycle;
        const settled: f64 = if (local < 0.45) local / 0.45 * phrase.len else if (local < 0.75) phrase.len else (1 - (local - 0.75) / 0.25) * phrase.len;
        const tick: u64 = @intFromFloat(g_phase * 18);
        var line: [phrase.len]u16 = undefined;
        for (phrase, 0..) |c, i| {
            const fixed = @as(f64, @floatFromInt(i)) < settled or c == ' ';
            line[i] = if (fixed) c else pool[(i *% 2654435761 ^ tick *% 40503) % pool.len];
        }
        const mono = w.CreateFontW(-15, 0, 0, 0, w.FW_NORMAL, 0, 0, 0, 1, 0, 0, 5, 1, w.L("Consolas"));
        if (mono) |f| _ = w.SelectObject(dc, @ptrCast(f));
        _ = w.SetTextColor(dc, w.rgb(180, 196, 230));
        var rect = w.RECT{ .left = 64, .top = 38, .right = overlay_w - 12, .bottom = 62 };
        _ = w.DrawTextW(dc, &line, line.len, &rect, w.DT_LEFT | w.DT_SINGLELINE | w.DT_VCENTER);
        if (mono) |f| _ = w.DeleteObject(@ptrCast(f));
    }
    _ = w.SelectObject(dc, old_pen orelse @ptrCast(pen));
    _ = w.BitBlt(screen, 0, 0, overlay_w, overlay_h, dc, 0, 0, w.SRCCOPY);
}

fn overlayProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        w.WM_PAINT => {
            paintOverlay(hwnd);
            return 0;
        },
        w.WM_ERASEBKGND => return 1,
        w.WM_TIMER => {
            g_phase += 0.033;
            _ = w.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------- hotkeys

fn hookProc(code: c_int, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (code == 0) {
        const k: *const w.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (k.flags & w.LLKHF_INJECTED == 0) {
            const down = wparam == w.WM_KEYDOWN or wparam == w.WM_SYSKEYDOWN;
            const ctrl = w.GetAsyncKeyState(w.VK_CONTROL) < 0;
            const alt = w.GetAsyncKeyState(w.VK_MENU) < 0;
            // Hold Ctrl+Alt+D to dictate; D decides both edges, swallowed while held.
            if (k.vkCode == 'D' and ((ctrl and alt) or g_ptt_down)) {
                if (down and !g_ptt_down) {
                    g_ptt_down = true;
                    _ = w.PostMessageW(g_hwnd, WM_PTT, 1, 0);
                } else if (!down and g_ptt_down) {
                    g_ptt_down = false;
                    _ = w.PostMessageW(g_hwnd, WM_PTT, 0, 0);
                }
                return 1;
            }
            if (ctrl and alt and k.vkCode == w.VK_SPACE) {
                if (down) _ = w.PostMessageW(g_hwnd, WM_MENU, 0, 0);
                return 1;
            }
            if (ctrl and alt and k.vkCode == w.VK_UP) {
                if (down) _ = w.PostMessageW(g_hwnd, WM_SESSIONS, 0, 0);
                return 1;
            }
        }
    }
    return w.CallNextHookEx(null, code, wparam, lparam);
}

// ---------------------------------------------------------------- main window

fn mainProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        WM_TRAY => {
            const event: u32 = @intCast(@as(usize, @bitCast(lparam)) & 0xFFFF);
            if (event == w.WM_LBUTTONUP or event == w.WM_RBUTTONUP) showMenu();
            return 0;
        },
        WM_MENU => {
            showMenu();
            return 0;
        },
        w.WM_COMMAND => {
            if (wparam == CMD_NEW) showNewDialog();
            return 0;
        },
        WM_SESSIONS => {
            openTerminal("Agent Belt", &.{"sessions"});
            return 0;
        },
        WM_PTT => {
            if (wparam == 1 and !g_recording.load(.acquire) and g_state.load(.acquire) == 0) {
                g_recording.store(true, .release);
                showOverlay(1);
                _ = std.Thread.spawn(.{}, recordAndTranscribe, .{}) catch {
                    g_recording.store(false, .release);
                    showOverlay(0);
                };
            } else if (wparam == 0) {
                g_recording.store(false, .release);
            }
            return 0;
        },
        WM_OVERLAY => {
            showOverlay(@intCast(wparam));
            return 0;
        },
        w.WM_DESTROY => {
            w.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn run(ctx: sys.Ctx, version: []const u8) !u8 {
    g_ctx = ctx;
    g_version = version;
    // One daemon per user session: two would double every hotkey.
    _ = w.CreateMutexW(null, 1, w.L("Local\\AgentBelt"));
    if (w.GetLastError() == w.ERROR_ALREADY_EXISTS) {
        log("already running", .{});
        return 1;
    }
    adoptPendingKey(ctx);
    g_instance = w.GetModuleHandleW(null);
    const icon: ?w.HICON = @ptrCast(w.LoadImageW(g_instance, 1, w.IMAGE_ICON, 0, 0, w.LR_DEFAULTSIZE));
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = mainProc, .hInstance = g_instance, .lpszClassName = w.L("AgentBelt"), .hIcon = icon });
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = overlayProc, .hInstance = g_instance, .lpszClassName = w.L("AgentBeltOverlay") });
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = dialogProc, .hInstance = g_instance, .lpszClassName = w.L("AgentBeltNew"), .hIcon = icon, .hbrBackground = @ptrFromInt(16) }); // COLOR_BTNFACE + 1

    g_hwnd = w.CreateWindowExW(0, w.L("AgentBelt"), w.L("Agent Belt"), w.WS_OVERLAPPED, 0, 0, 0, 0, null, null, g_instance, null) orelse return error.NoWindow;
    g_overlay = w.CreateWindowExW(w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE | w.WS_EX_LAYERED | w.WS_EX_TRANSPARENT, w.L("AgentBeltOverlay"), w.L("Agent Belt overlay"), w.WS_POPUP, 0, 0, overlay_w, overlay_h, null, null, g_instance, null);
    if (g_overlay) |ov| {
        _ = w.SetLayeredWindowAttributes(ov, 0, 240, w.LWA_ALPHA);
        _ = w.SetWindowRgn(ov, w.CreateRoundRectRgn(0, 0, overlay_w + 1, overlay_h + 1, 36, 36), 0);
    }

    g_tray = .{ .hWnd = g_hwnd, .uFlags = w.NIF_MESSAGE | w.NIF_ICON | w.NIF_TIP, .uCallbackMessage = WM_TRAY, .hIcon = icon };
    const tip = w.L("Agent Belt · Ctrl+Alt+D dita · Ctrl+Alt+Espaço menu");
    @memcpy(g_tray.szTip[0..tip.len], tip);
    _ = w.Shell_NotifyIconW(w.NIM_ADD, &g_tray);
    defer _ = w.Shell_NotifyIconW(w.NIM_DELETE, &g_tray);

    g_hook = w.SetWindowsHookExW(w.WH_KEYBOARD_LL, hookProc, g_instance, 0);
    if (g_hook == null) log("keyboard hook unavailable: hotkeys disabled", .{});
    _ = std.Thread.spawn(.{}, refreshLoop, .{}) catch null;
    log("ready {s}: tray icon, Ctrl+Alt+D dictation, Ctrl+Alt+Space menu", .{version});

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        if (g_dialog) |d| if (w.IsDialogMessageW(d, &msg) != 0) continue;
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    return 0;
}
