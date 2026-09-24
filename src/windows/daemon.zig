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
const audio_level = @import("../audio_level.zig");
const history = @import("../history.zig");
const overlay = @import("overlay.zig");
const intent = @import("../sessions/intent.zig");

const WM_TRAY = w.WM_APP + 1;
const WM_PTT = w.WM_APP + 2; // wparam 1 start, 0 stop
const WM_MENU = w.WM_APP + 3;
const WM_SESSIONS = w.WM_APP + 4;
const WM_OVERLAY = w.WM_APP + 5; // wparam: 0 hide, 1 recording, 2 transcribing
const WM_PREVIEW = w.WM_APP + 6;

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
var g_dialog: ?w.HWND = null;
var g_edit: ?w.HWND = null;
var g_hook: ?w.HHOOK = null;
var g_tray: w.NOTIFYICONDATAW = .{};
var g_ptt_down = false;

var g_state = std.atomic.Value(u8).init(0); // overlay: 0 hidden, 1 recording, 2 transcribing
var g_level = std.atomic.Value(u32).init(0); // microphone level, permille
var g_recording = std.atomic.Value(bool).init(false);

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
    headers: [8]w.WAVEHDR = undefined,
    buffers: [8][audio_level.window_bytes]u8 = undefined, // 20 ms each, like the Mac meter
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
            g_level.store(audio_level.permille(data), .release);
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
        history.saveAsync(g_ctx.io, history.dir(g_ctx.gpa, g_ctx.env) catch return, .dictation, audio, "");
        return;
    };
    history.saveAsync(g_ctx.io, history.dir(g_ctx.gpa, g_ctx.env) catch "", .dictation, audio, text);
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
        _ = w.AppendMenuW(menu, w.MF_STRING | w.MF_GRAYED, 0, w.L("Looking for sessions…"));
    } else if (rows.len == 0) {
        _ = w.AppendMenuW(menu, w.MF_STRING | w.MF_GRAYED, 0, w.L("No agent sessions"));
    }
    for (rows, 0..) |r, i| {
        if (i >= 30) break;
        // Win32 menus draw emoji in monochrome, so the agent is spelled out.
        const label = g_ctx.fmt("{s}\t{s} · {s}{s}", .{ r.name, if (r.agent.len > 0) r.agent else "shell", r.host.name, if (r.attached) " · attached" else "" }) catch continue;
        _ = w.AppendMenuW(menu, w.MF_STRING, CMD_SESSION + i, w.wide(g_ctx.gpa, label) catch continue);
    }
    _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(menu, w.MF_STRING, CMD_NEW, w.L("New agent…"));
    _ = w.AppendMenuW(menu, w.MF_STRING, CMD_SESSIONS, w.L("Sessions in a terminal    Ctrl+Alt+↑"));
    _ = w.AppendMenuW(menu, w.MF_STRING, CMD_REFRESH, w.L("Refresh"));
    _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(menu, w.MF_STRING | w.MF_GRAYED, 0, w.L("Dictate: hold Ctrl+Alt+D"));
    _ = w.AppendMenuW(menu, w.MF_STRING, CMD_LOG, w.L("Open log"));
    _ = w.AppendMenuW(menu, w.MF_STRING, CMD_QUIT, w.L("Quit Agent Belt"));
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

// A request typed into the dialog is read like the Mac's create panel: agent,
// machine, repo and intent (agb _intent, backed by Jev), shown as they are
// detected, the intent highlighted. Create runs agb new with exactly that.

const WM_PLAN = w.WM_APP + 7; // wparam: request serial, lparam: *Detected
const WM_SUMMARY = w.WM_APP + 8; // wparam: request serial, lparam: *Detected (with its summary)
const ID_CREATE = 1;
const ID_CANCEL = 2;
const ID_EDIT = 3;
const TIMER_DETECT = 7;

const Detected = struct {
    arena: std.heap.ArenaAllocator,
    plan: ?intent.Plan = null,
    failure: ?[]const u8 = null,
    summary: ?intent.Summary = null,
};

var g_create_pending = false; // Create was pressed before the session had a name

var g_fields: ?w.HWND = null;
var g_intent: ?w.HWND = null;
var g_hint: ?w.HWND = null;
var g_detected: ?*Detected = null;
var g_serial: usize = 0;

fn showNewDialog() void {
    if (g_dialog) |d| {
        _ = w.SetForegroundWindow(d);
        return;
    }
    const cx = w.GetSystemMetrics(0);
    const cy = w.GetSystemMetrics(1);
    const dialog = w.CreateWindowExW(w.WS_EX_TOPMOST, w.L("AgentBeltNew"), w.L("Agent Belt: new agent"), w.WS_CAPTION | w.WS_SYSMENU | w.WS_VISIBLE, @divTrunc(cx - 640, 2), @divTrunc(cy - 250, 3), 640, 250, null, null, g_instance, null) orelse return;
    g_dialog = dialog;
    const font = w.CreateFontW(-15, 0, 0, 0, w.FW_NORMAL, 0, 0, 0, 1, 0, 0, 5, 0, w.L("Segoe UI"));
    const small = w.CreateFontW(-13, 0, 0, 0, w.FW_NORMAL, 0, 0, 0, 1, 0, 0, 5, 0, w.L("Segoe UI"));
    const bold = w.CreateFontW(-18, 0, 0, 0, w.FW_SEMIBOLD, 0, 0, 0, 1, 0, 0, 5, 0, w.L("Segoe UI"));
    const label = w.CreateWindowExW(0, w.L("STATIC"), w.L("Describe the new agent: which agent, machine and repo, and what to do."), w.WS_CHILD | w.WS_VISIBLE, 16, 12, 600, 22, dialog, null, g_instance, null);
    g_edit = w.CreateWindowExW(w.WS_EX_CLIENTEDGE, w.L("EDIT"), w.L(""), w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP | w.ES_AUTOHSCROLL, 16, 40, 600, 28, dialog, @ptrFromInt(ID_EDIT), g_instance, null);
    g_fields = w.CreateWindowExW(0, w.L("STATIC"), w.L(""), w.WS_CHILD | w.WS_VISIBLE, 16, 80, 600, 22, dialog, null, g_instance, null);
    g_intent = w.CreateWindowExW(0, w.L("STATIC"), w.L(""), w.WS_CHILD | w.WS_VISIBLE, 16, 106, 600, 28, dialog, null, g_instance, null);
    g_hint = w.CreateWindowExW(0, w.L("STATIC"), w.L("e.g. codex on windows in coreum to look into the login error"), w.WS_CHILD | w.WS_VISIBLE, 16, 142, 600, 20, dialog, null, g_instance, null);
    const create = w.CreateWindowExW(0, w.L("BUTTON"), w.L("Create"), w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP | w.BS_DEFPUSHBUTTON, 516, 172, 100, 30, dialog, @ptrFromInt(ID_CREATE), g_instance, null);
    for ([_]?w.HWND{ label, g_edit, g_fields, create }) |c| if (c) |ctl| if (font) |f| {
        _ = w.SendMessageW(ctl, w.WM_SETFONT, @intFromPtr(f), 1);
    };
    if (small) |f| if (g_hint) |h| {
        _ = w.SendMessageW(h, w.WM_SETFONT, @intFromPtr(f), 1);
    };
    if (bold) |f| if (g_intent) |h| {
        _ = w.SendMessageW(h, w.WM_SETFONT, @intFromPtr(f), 1);
    };
    _ = w.SetForegroundWindow(dialog);
    _ = w.SetFocus(g_edit);
    // Fresh repo lists for the detection, in the background.
    _ = std.Thread.spawn(.{}, refreshRepos, .{}) catch null;
}

fn refreshRepos() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ctx = g_ctx;
    ctx.gpa = arena.allocator();
    const reg = hosts.load(ctx) catch return;
    intent.refreshCache(ctx, reg, cli.reposOf) catch {};
}

fn setText(hwnd: ?w.HWND, text: []const u8) void {
    const h = hwnd orelse return;
    const wide = w.wide(g_ctx.gpa, text) catch return;
    _ = w.SetWindowTextW(h, wide);
}

fn detectThread(dialog: w.HWND, serial: usize, text: []const u8) void {
    const d = std.heap.page_allocator.create(Detected) catch return;
    d.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    var ctx = g_ctx;
    ctx.gpa = d.arena.allocator();
    if (hosts.load(ctx)) |reg| {
        d.plan = intent.detect(ctx, reg, text, .{}) catch |err| blk: {
            d.failure = @errorName(err);
            break :blk null;
        };
    } else |err| d.failure = @errorName(err);
    if (w.PostMessageW(dialog, WM_PLAN, serial, @bitCast(@intFromPtr(d))) == 0) {
        d.arena.deinit();
        std.heap.page_allocator.destroy(d);
        return;
    }
    // Then the session name and summary, written by an agent (seconds).
    const s = std.heap.page_allocator.create(Detected) catch return;
    s.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    var sctx = g_ctx;
    sctx.gpa = s.arena.allocator();
    s.summary = intent.summarize(sctx, text) catch null;
    if (w.PostMessageW(dialog, WM_SUMMARY, serial, @bitCast(@intFromPtr(s))) == 0) {
        s.arena.deinit();
        std.heap.page_allocator.destroy(s);
    }
}

var g_summary: ?*Detected = null;

fn showPlan() void {
    const d = g_detected orelse return;
    const plan = d.plan orelse {
        setText(g_fields, "");
        setText(g_intent, "");
        setText(g_hint, if (d.failure) |f| (g_ctx.fmt("Could not read the request: {s}", .{f}) catch "") else "");
        return;
    };
    const unsure = struct {
        fn mark(c: f64) []const u8 {
            return if (c > 0 and c < 0.6) " ?" else ""; // 0 is a default, not a doubt
        }
    };
    setText(g_fields, g_ctx.fmt("Agent  {s}{s}        Machine  {s}{s}        Repo  {s}{s}", .{
        plan.agent,              unsure.mark(plan.agent_confidence),
        plan.host,               unsure.mark(plan.host_confidence),
        plan.repo orelse "none", if (plan.repo != null) unsure.mark(plan.repo_confidence) else "",
    }) catch "");
    const summary: ?intent.Summary = if (g_summary) |s| s.summary else null;
    setText(g_intent, if (summary) |s| (g_ctx.fmt("→ {s}", .{s.summary}) catch "") else "→ summarizing…");
    const session: []const u8 = if (summary) |s| (g_ctx.fmt("Session {s} · ", .{s.name}) catch "") else "";
    setText(g_hint, if (g_create_pending) "Naming the session…" else if (plan.repo == null) (g_ctx.fmt("{s}No repo: works in ~/agents · Enter creates · Esc cancels", .{session}) catch "") else (g_ctx.fmt("{s}Enter creates the agent · Esc cancels", .{session}) catch ""));
}

fn createFromPlan(dialog: w.HWND) void {
    const d = g_detected orelse {
        setText(g_hint, "Still reading the request…");
        return;
    };
    const plan = d.plan orelse return;
    const summary = (if (g_summary) |s| s.summary else null) orelse {
        g_create_pending = true; // created when the name arrives
        setText(g_hint, "Naming the session…");
        return;
    };
    g_create_pending = false;
    const task = summary.name;
    const title = g_ctx.fmt("{s} · {s} @ {s}", .{ task, plan.agent, plan.host }) catch "Agent Belt";
    // Without a repo the agent works in ~/agents/<task> (research).
    const repo_args: []const []const u8 = if (plan.repo) |r| &.{ "--repo", r } else &.{"--no-repo"};
    const args = std.mem.concat(g_ctx.gpa, []const u8, &.{ &.{ "new", "--agent", plan.agent, "--host", plan.host }, repo_args, &.{ "--task", task, "--prompt", plan.prompt } }) catch return;
    openTerminal(title, args);
    _ = w.DestroyWindow(dialog);
}

fn dialogProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        w.WM_COMMAND => {
            const id = wparam & 0xFFFF;
            const code = (wparam >> 16) & 0xFFFF;
            if (id == ID_CREATE) createFromPlan(hwnd);
            if (id == ID_CANCEL) _ = w.DestroyWindow(hwnd);
            if (id == ID_EDIT and code == 0x0300) { // EN_CHANGE: detect once typing pauses
                _ = w.SetTimer(hwnd, TIMER_DETECT, 400, null);
                setText(g_hint, "Reading…");
            }
            return 0;
        },
        w.WM_TIMER => if (wparam == TIMER_DETECT) {
            _ = w.KillTimer(hwnd, TIMER_DETECT);
            var buf: [2048]u16 = undefined;
            const n = if (g_edit) |e| w.GetWindowTextW(e, &buf, buf.len) else 0;
            const text = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, buf[0..@intCast(n)]) catch return 0;
            if (std.mem.trim(u8, text, " ").len == 0) return 0;
            g_serial += 1;
            _ = std.Thread.spawn(.{}, detectThread, .{ hwnd, g_serial, text }) catch {};
            return 0;
        },
        WM_PLAN => {
            const d: *Detected = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (wparam != g_serial) { // a newer request is on its way
                d.arena.deinit();
                std.heap.page_allocator.destroy(d);
                return 0;
            }
            if (g_detected) |old| {
                old.arena.deinit();
                std.heap.page_allocator.destroy(old);
            }
            g_detected = d;
            if (g_summary) |old| { // a new request: its name comes with its own summary
                old.arena.deinit();
                std.heap.page_allocator.destroy(old);
            }
            g_summary = null;
            showPlan();
            return 0;
        },
        WM_SUMMARY => {
            const s: *Detected = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (wparam != g_serial) {
                s.arena.deinit();
                std.heap.page_allocator.destroy(s);
                return 0;
            }
            if (g_summary) |old| {
                old.arena.deinit();
                std.heap.page_allocator.destroy(old);
            }
            g_summary = s;
            showPlan();
            if (g_create_pending) createFromPlan(hwnd);
            return 0;
        },
        0x0138 => if (g_intent != null and lparam == @as(isize, @bitCast(@intFromPtr(g_intent.?)))) { // WM_CTLCOLORSTATIC: the intent in the accent color
            _ = w.SetTextColor(@ptrFromInt(wparam), w.rgb(37, 99, 235));
            _ = w.SetBkMode(@ptrFromInt(wparam), w.TRANSPARENT);
            return @bitCast(@intFromPtr(w.GetSysColorBrush(15)));
        },
        w.WM_DESTROY => {
            g_dialog = null;
            g_edit = null;
            if (g_detected) |old| {
                old.arena.deinit();
                std.heap.page_allocator.destroy(old);
            }
            g_detected = null;
            if (g_summary) |old| {
                old.arena.deinit();
                std.heap.page_allocator.destroy(old);
            }
            g_summary = null;
            g_create_pending = false;
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------- overlay

var g_preview_started: f64 = 0; // agb preview: a synthetic voice drives the overlay

fn showOverlay(state: u8) void {
    g_state.store(state, .release);
    overlay.show(state);
}

fn overlayProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (msg == w.WM_TIMER) {
        var level: f64 = @as(f64, @floatFromInt(g_level.load(.acquire))) / 1000.0;
        if (g_preview_started > 0) {
            const elapsed = @as(f64, @floatFromInt(w.GetTickCount64())) / 1000.0 - g_preview_started;
            if (elapsed > 6.5) {
                g_preview_started = 0;
                showOverlay(0);
                return 0;
            }
            if (elapsed > 3.5 and g_state.load(.acquire) == 1) showOverlay(2);
            level = 0.04 + (0.25 + 0.6 * @min(1, elapsed / 3)) * std.math.pow(f64, @max(0, @sin(elapsed * 16)), 0.6);
        }
        overlay.tick(level);
        return 0;
    }
    return w.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// `agb preview`: asks the running tray daemon to play the overlay.
pub fn preview() u8 {
    const h = w.FindWindowW(w.L("AgentBelt"), null) orelse {
        std.debug.print("agent-belt.exe is not running (agb install starts it)\n", .{});
        return 1;
    };
    _ = w.PostMessageW(h, WM_PREVIEW, 0, 0);
    return 0;
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
        WM_PREVIEW => {
            if (g_state.load(.acquire) == 0) {
                g_preview_started = @as(f64, @floatFromInt(w.GetTickCount64())) / 1000.0;
                showOverlay(1);
            }
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
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = dialogProc, .hInstance = g_instance, .lpszClassName = w.L("AgentBeltNew"), .hIcon = icon, .hbrBackground = @ptrFromInt(16) }); // COLOR_BTNFACE + 1

    g_hwnd = w.CreateWindowExW(0, w.L("AgentBelt"), w.L("Agent Belt"), w.WS_OVERLAPPED, 0, 0, 0, 0, null, null, g_instance, null) orelse return error.NoWindow;
    overlay.create(g_instance, overlayProc);

    g_tray = .{ .hWnd = g_hwnd, .uFlags = w.NIF_MESSAGE | w.NIF_ICON | w.NIF_TIP, .uCallbackMessage = WM_TRAY, .hIcon = icon };
    const tip = w.L("Agent Belt · Ctrl+Alt+D dictates · Ctrl+Alt+Space menu");
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
