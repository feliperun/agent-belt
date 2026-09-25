//! Agent Belt on a Linux desktop (Wayland; made for Omarchy's Hyprland, Waybar,
//! walker and mako): an agent menu, a Waybar module and push-to-talk dictation
//! driven by compositor key binds. No daemon: each bind runs agb.
const std = @import("std");
const sys = @import("../sessions/sys.zig");
const cli = @import("../sessions/cli.zig");
const hosts = @import("../sessions/hosts.zig");
const deepgram = @import("../deepgram.zig");
const config = @import("../config.zig");
const audio_level = @import("../audio_level.zig");
const history = @import("../history.zig");
const wav_stream = @import("../wav_stream.zig");

pub fn isCommand(name: []const u8) bool {
    for ([_][]const u8{ "menu", "waybar", "ptt", "install", "uninstall", "preview", "_overlay" }) |c| if (std.mem.eql(u8, name, c)) return true;
    return false;
}

pub fn main(ctx: sys.Ctx, argv: []const []const u8) !u8 {
    const cmd = argv[0];
    if (std.mem.eql(u8, cmd, "menu")) return menu(ctx);
    if (std.mem.eql(u8, cmd, "waybar")) return waybar(ctx);
    if (std.mem.eql(u8, cmd, "install")) return install(ctx);
    if (std.mem.eql(u8, cmd, "uninstall")) return uninstall(ctx);
    if (std.mem.eql(u8, cmd, "preview")) return overlayHost(ctx, true);
    if (std.mem.eql(u8, cmd, "_overlay")) return overlayHost(ctx, false);
    const action = if (argv.len > 1) argv[1] else "toggle";
    if (std.mem.eql(u8, action, "start")) return pttStart(ctx);
    if (std.mem.eql(u8, action, "stop")) return pttStop(ctx);
    if (std.mem.eql(u8, action, "toggle")) return if (recorderPid(ctx) != null) pttStop(ctx) else pttStart(ctx);
    std.debug.print("usage: agb ptt start|stop|toggle\n", .{});
    return 2;
}

pub fn selfExe(ctx: sys.Ctx) []const u8 {
    return std.process.executablePathAlloc(ctx.io, ctx.gpa) catch "agb";
}

/// One Agent Belt bubble that changes state: each notification replaces the
/// previous one by the id notify-send printed for it.
pub fn notify(ctx: sys.Ctx, title: []const u8, body: []const u8, timeout_ms: u32) void {
    const id_path = runtimeFile(ctx, "agb-notify.id") catch return;
    const last = std.mem.trim(u8, sys.readFile(ctx, id_path) orelse "0", " \n");
    const out = sys.run(ctx, &.{ "notify-send", "-a", "Agent Belt", "-p", "-r", last, "-t", ctx.fmt("{d}", .{timeout_ms}) catch "3000", title, body }, null);
    if (out.ok) sys.writeFileAtomic(ctx, id_path, std.mem.trim(u8, out.stdout, " \n")) catch {};
}

/// Opens a terminal running agb with these arguments, detached from us.
pub fn openTerminal(ctx: sys.Ctx, args: []const []const u8) void {
    const launcher: []const []const u8 = if (sys.which(ctx, "xdg-terminal-exec")) |t| &.{t} else if (ctx.getenv("TERMINAL")) |t| &.{ t, "-e" } else &.{ "foot", "-e" };
    // A failure keeps the window open long enough to read why.
    const script = "\"$0\" \"$@\" || { printf '\\nagb ended with an error; Enter closes this window. '; read -r _; }";
    const argv = std.mem.concat(ctx.gpa, []const u8, &.{ launcher, &.{ "sh", "-c", script, selfExe(ctx) }, args }) catch return;
    _ = std.process.spawn(ctx.io, .{ .argv = argv, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err|
        notify(ctx, "Agent Belt", ctx.fmt("could not open a terminal: {s}", .{@errorName(err)}) catch "", 5000);
}

/// Shows lines in the desktop's picker and returns the chosen one (with no
/// lines, the typed text): Omarchy's own menu, else a dmenu-style program.
fn pick(ctx: sys.Ctx, prompt: []const u8, lines: []const u8) ?[]const u8 {
    if (sys.which(ctx, "omarchy-shell") != null) return omarchyPick(ctx, prompt, lines);
    const pickers = [_][]const u8{ "walker --dmenu -p \"$AGB_PROMPT\"", "fuzzel --dmenu -p \"$AGB_PROMPT \"", "wofi --dmenu -p \"$AGB_PROMPT\"", "rofi -dmenu -p \"$AGB_PROMPT\"" };
    for (pickers) |picker| {
        const bin = picker[0..std.mem.indexOfScalar(u8, picker, ' ').?];
        if (sys.which(ctx, bin) == null) continue;
        ctx.env.put("AGB_MENU", lines) catch return null;
        ctx.env.put("AGB_PROMPT", prompt) catch return null;
        // No lines at all for free text: an empty entry would be picked instead of the typed words.
        const feed = if (lines.len > 0) "printf '%s\\n' \"$AGB_MENU\"" else "true";
        const out = sys.run(ctx, &.{ "sh", "-c", ctx.fmt("{s} | {s}", .{ feed, picker }) catch return null }, null);
        const choice = std.mem.trim(u8, out.stdout, " \r\n");
        return if (choice.len > 0) choice else null;
    }
    notify(ctx, "Agent Belt", "no menu program: install walker, fuzzel, wofi or rofi", 5000);
    return null;
}

/// Omarchy's menu in dmenu mode: a JSON payload names a selection file and a
/// done file, like omarchy-menu-input.
fn omarchyPick(ctx: sys.Ctx, prompt: []const u8, lines: []const u8) ?[]const u8 {
    // Summoning the menu again replaces the request without answering the
    // previous one, which would wait forever: a new agb menu ends the old one.
    const pid_path = runtimeFile(ctx, "agb-menu.pid") catch return null;
    if (sys.readFile(ctx, pid_path)) |old| {
        const old_pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, old, " \n"), 10) catch 0;
        if (old_pid > 0 and old_pid != std.os.linux.getpid()) std.posix.kill(old_pid, std.posix.SIG.TERM) catch {};
    }
    const me = std.os.linux.getpid();
    sys.writeFileAtomic(ctx, pid_path, ctx.fmt("{d}", .{me}) catch return null) catch {};
    const base = runtimeFile(ctx, ctx.fmt("agb-menu-{d}", .{me}) catch return null) catch return null;
    const selection = ctx.fmt("{s}.selection", .{base}) catch return null;
    const done = ctx.fmt("{s}.done", .{base}) catch return null;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(ctx.io, done) catch {};
    cwd.deleteFile(ctx.io, selection) catch {};
    defer cwd.deleteFile(ctx.io, done) catch {};
    defer cwd.deleteFile(ctx.io, selection) catch {};
    var options: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| if (line.len > 0) options.append(ctx.gpa, line) catch return null;
    const payload = ctx.fmt("{f}", .{std.json.fmt(.{
        .mode = if (lines.len > 0) "select" else "input",
        .prompt = prompt,
        .options = options.items,
        .selectionFile = selection,
        .doneFile = done,
        .width = 560,
    }, .{})}) catch return null;
    if (!sys.run(ctx, &.{ "omarchy-shell", "shell", "summon", "omarchy.menu", payload }, null).ok) return null;
    while (!sys.exists(ctx, done)) std.Io.sleep(ctx.io, .fromMilliseconds(50), .awake) catch return null;
    const choice = std.mem.trim(u8, sys.readFile(ctx, selection) orelse return null, " \r\n");
    return if (choice.len > 0) choice else null;
}

const new_agent = "+ New agent…";

fn menu(ctx: sys.Ctx) !u8 {
    const reg = try hosts.load(ctx);
    const c = try cli.collect(ctx, reg);
    var lines: std.ArrayList(u8) = .empty;
    try lines.appendSlice(ctx.gpa, new_agent);
    for (c.rows) |r| try lines.print(ctx.gpa, "\n{s} · {s} · {s}", .{ r.name, if (r.agent.len > 0) r.agent else "shell", r.host.name });
    const choice = pick(ctx, "Agent Belt", lines.items) orelse return 0;
    if (std.mem.eql(u8, choice, new_agent)) {
        // The panel, to type or hold Shift+F9 and say it; else a typed line.
        if (sys.which(ctx, "quickshell") != null) {
            _ = std.process.spawn(ctx.io, .{ .argv = &.{ selfExe(ctx), "agent-panel" }, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {};
            return 0;
        }
        const words = pick(ctx, "agent, machine, repo, what to do", "") orelse return 0;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(ctx.gpa, "new");
        var it = std.mem.tokenizeAny(u8, words, " \t");
        while (it.next()) |w| try argv.append(ctx.gpa, w);
        openTerminal(ctx, argv.items);
        return 0;
    }
    for (c.rows) |r| {
        const line = try ctx.fmt("{s} · {s} · {s}", .{ r.name, if (r.agent.len > 0) r.agent else "shell", r.host.name });
        if (std.mem.eql(u8, line, choice)) openTerminal(ctx, &.{ "attach", r.name, r.host.name });
    }
    return 0;
}

/// A Waybar custom module: `"exec": "agb waybar", "return-type": "json"`.
fn waybar(ctx: sys.Ctx) !u8 {
    const reg = try hosts.load(ctx);
    const c = try cli.collect(ctx, reg);
    var tooltip: std.ArrayList(u8) = .empty;
    for (c.rows) |r| try tooltip.print(ctx.gpa, "{s}{s} · {s} · {s}", .{ if (tooltip.items.len > 0) "\n" else "", r.name, if (r.agent.len > 0) r.agent else "shell", r.host.name });
    var down: usize = 0;
    for (reg.hosts, c.states) |h, s| if (!s.ok) {
        down += 1;
        try tooltip.print(ctx.gpa, "{s}{s} unreachable", .{ if (tooltip.items.len > 0) "\n" else "", h.name });
    };
    const out = std.json.fmt(.{
        .text = try ctx.fmt("🦇 {d}", .{c.rows.len}),
        .tooltip = if (tooltip.items.len > 0) tooltip.items else "no agent sessions",
        .class = if (c.rows.len == 0) "idle" else "active",
        .alt = if (down > 0) "degraded" else "ok",
    }, .{});
    try std.Io.File.stdout().writeStreamingAll(ctx.io, try ctx.fmt("{f}\n", .{out}));
    return 0;
}

// ---------------------------------------------------------------- push-to-talk

pub fn runtimeFile(ctx: sys.Ctx, name: []const u8) ![]const u8 {
    return ctx.join(&.{ ctx.getenv("XDG_RUNTIME_DIR") orelse "/tmp", name });
}

fn recorderPid(ctx: sys.Ctx) ?std.posix.pid_t {
    const text = sys.readFile(ctx, runtimeFile(ctx, "agb-ptt.pid") catch return null) orelse return null;
    const pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \n"), 10) catch return null;
    // A recorder that exited but was not reaped yet is a zombie: gone for us.
    // /proc files report size 0, so a sized read returns nothing; read what is there.
    const file = std.Io.Dir.cwd().openFile(ctx.io, ctx.fmt("/proc/{d}/stat", .{pid}) catch return null, .{}) catch return null;
    defer file.close(ctx.io);
    var buf: [512]u8 = undefined;
    const stat = buf[0 .. file.readStreaming(ctx.io, &.{&buf}) catch return null];
    const state_at = (std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null) + 2;
    return if (state_at < stat.len and stat[state_at] != 'Z') pid else null;
}

fn pttStart(ctx: sys.Ctx) !u8 {
    if (recorderPid(ctx) != null) return 0;
    if (sys.which(ctx, "pw-record") == null) {
        notify(ctx, "Agent Belt", "pw-record (PipeWire) is missing", 5000);
        return 1;
    }
    for ([_][]const u8{ "agb-ptt.stream", "agb-ptt.final" }) |f| std.Io.Dir.cwd().deleteFile(ctx.io, try runtimeFile(ctx, f)) catch {};
    const wav = try runtimeFile(ctx, "agb-ptt.wav");
    const child = try std.process.spawn(ctx.io, .{ .argv = &.{ "pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", wav }, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    try sys.writeFileAtomic(ctx, try runtimeFile(ctx, "agb-ptt.pid"), try ctx.fmt("{d}", .{child.id.?}));
    setMode(ctx, 1);
    // The host streams the words while recording, and draws them if it can.
    _ = std.process.spawn(ctx.io, .{ .argv = &.{ selfExe(ctx), "_overlay" }, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {};
    if (sys.which(ctx, "quickshell") == null) notify(ctx, "🎙️ Listening", "release the shortcut to transcribe", 60_000);
    return 0;
}

pub fn deepgramKey(ctx: sys.Ctx) ?[]const u8 {
    if (ctx.getenv("DEEPGRAM_API_KEY")) |k| if (k.len > 0) return k;
    const path = keyPath(ctx) catch return null;
    const key = std.mem.trim(u8, sys.readFile(ctx, path) orelse return null, " \r\n");
    return if (key.len > 0) key else null;
}

fn keyPath(ctx: sys.Ctx) ![]const u8 {
    const base = ctx.getenv("XDG_CONFIG_HOME") orelse try ctx.join(&.{ ctx.home(), ".config" });
    return ctx.join(&.{ base, "agent-belt", "deepgram.key" });
}

fn pttStop(ctx: sys.Ctx) !u8 {
    const pid = recorderPid(ctx) orelse return 0;
    // SIGINT lets pw-record finish the WAV header.
    std.posix.kill(pid, std.posix.SIG.INT) catch {};
    var waited: usize = 0;
    while (recorderPid(ctx) != null and waited < 40) : (waited += 1) try std.Io.sleep(ctx.io, .fromMilliseconds(50), .awake);
    std.Io.Dir.cwd().deleteFile(ctx.io, try runtimeFile(ctx, "agb-ptt.pid")) catch {};
    const wav_path = try runtimeFile(ctx, "agb-ptt.wav");
    const wav = sys.readFile(ctx, wav_path) orelse "";
    defer std.Io.Dir.cwd().deleteFile(ctx.io, wav_path) catch {};
    if (wav.len < 44 + 16000 / 5) { // under ~100 ms: an accidental tap
        setMode(ctx, 0);
        notify(ctx, "Agent Belt", "recording too short", 1500);
        return 0;
    }
    const key = deepgramKey(ctx) orelse {
        setMode(ctx, 0);
        notify(ctx, "Agent Belt", "no Deepgram key: DEEPGRAM_API_KEY=… agb install", 6000);
        return 1;
    };
    defer setMode(ctx, 0);
    const text = streamedText(ctx) orelse batch: {
        setMode(ctx, 2);
        if (sys.which(ctx, "quickshell") == null) notify(ctx, "🔐 Transcribing", "deciphering your voice…", 30_000);
        const defaults = config.Config{};
        const client = deepgram.Client{ .io = ctx.io, .allocator = ctx.gpa, .api_key = key, .model = defaults.deepgram_model, .language = defaults.deepgram_language, .smart_format = defaults.deepgram_smart_format, .mip_opt_out = defaults.deepgram_mip_opt_out };
        break :batch client.transcribe(wav) catch |err| {
            notify(ctx, "Agent Belt", ctx.fmt("transcription failed: {s}", .{@errorName(err)}) catch "", 5000);
            return 1;
        };
    };
    if (text.len == 0) {
        notify(ctx, "Agent Belt", "no speech detected", 1500);
        return 0;
    }
    // Like on the Mac, the overlay leaves before the text is typed.
    setMode(ctx, 0);
    std.Io.sleep(ctx.io, .fromMilliseconds(120), .awake) catch {};
    notify(ctx, "Agent Belt", text, 1);
    // wtype waits for the compositor to take its keymap, or the first key is lost.
    const typed = if (sys.which(ctx, "wtype") != null) sys.run(ctx, &.{ "wtype", "-s", "120", "--", text }, null) else sys.run(ctx, &.{ "ydotool", "type", "--", text }, null);
    if (!typed.ok) {
        // Nowhere to type (or no wtype): the text still reaches the clipboard.
        ctx.env.put("AGB_TEXT", text) catch return 1;
        // wl-copy leaves a process serving the clipboard; with our pipes open we would wait on it forever.
        const copied = sys.run(ctx, &.{ "sh", "-c", "printf '%s' \"$AGB_TEXT\" | wl-copy >/dev/null 2>&1" }, null).ok;
        notify(ctx, "Agent Belt", if (copied) "copied: paste with Ctrl+V" else "install wtype to type the text", 5000);
    }
    // After typing, so the text is not delayed; this process exits right after.
    history.save(ctx.io, history.dir(ctx.gpa, ctx.env) catch return 0, .dictation, wav, text);
    return 0;
}

/// The words the overlay host streamed: it is told the recording ended (mode
/// 3) and writes the final transcript. Null when the stream did not open.
fn streamedText(ctx: sys.Ctx) ?[]const u8 {
    const status_path = runtimeFile(ctx, "agb-ptt.stream") catch return null;
    const final_path = runtimeFile(ctx, "agb-ptt.final") catch return null;
    // A stream still opening gets a moment (TLS and the handshake).
    var waited: usize = 0;
    while (sys.readFile(ctx, status_path) == null and waited < 30) : (waited += 1) std.Io.sleep(ctx.io, .fromMilliseconds(50), .awake) catch {};
    const status = sys.readFile(ctx, status_path) orelse return null;
    if (!std.mem.eql(u8, status, "open")) return null;
    setMode(ctx, 3);
    waited = 0;
    while (waited < 120) : (waited += 1) {
        if (sys.readFile(ctx, final_path)) |text| return text;
        if (std.mem.eql(u8, sys.readFile(ctx, status_path) orelse "", "failed")) return null;
        std.Io.sleep(ctx.io, .fromMilliseconds(50), .awake) catch {};
    }
    return null;
}

// ---------------------------------------------------------------- overlay

/// ptt start/stop tell the overlay host what is happening: 1 listening,
/// 2 transcribing the whole recording, 3 recording ended while streaming (the
/// host sends the rest and writes the final words), 0 done.
fn setMode(ctx: sys.Ctx, mode: u8) void {
    sys.writeFileAtomic(ctx, runtimeFile(ctx, "agb-ptt.mode") catch return, &.{'0' + mode}) catch {};
}

fn readMode(ctx: sys.Ctx) u8 {
    const text = sys.readFile(ctx, runtimeFile(ctx, "agb-ptt.mode") catch return 0) orelse return 0;
    return if (text.len > 0 and text[0] >= '0' and text[0] <= '3') text[0] - '0' else 0;
}

/// The level of the last 20 ms pw-record wrote.
fn recordingLevel(ctx: sys.Ctx) f64 {
    return levelOf(ctx, "agb-ptt.wav");
}

/// The level of the last 20 ms pw-record wrote to this runtime file.
pub fn levelOf(ctx: sys.Ctx, name: []const u8) f64 {
    const file = std.Io.Dir.cwd().openFile(ctx.io, runtimeFile(ctx, name) catch return 0, .{}) catch return 0;
    defer file.close(ctx.io);
    const len = file.length(ctx.io) catch return 0;
    var buf: [audio_level.window_bytes]u8 = undefined;
    if (len < 44 + buf.len) return 0;
    const n = file.readPositionalAll(ctx.io, &buf, (len - buf.len) & ~@as(u64, 1)) catch return 0;
    return @as(f64, @floatFromInt(audio_level.permille(buf[0..n]))) / 1000.0;
}

/// Hosts a recording: streams it to Deepgram (src/wav_stream.zig) and, with
/// Quickshell, the QML overlay (src/linux/overlay.qml), fed the mode, the
/// microphone level, the time and the words about 30 times a second until
/// dictation ends. `agb preview` plays it with a synthetic voice, as on the Mac.
fn overlayHost(ctx: sys.Ctx, demo: bool) !u8 {
    const draws = sys.which(ctx, "quickshell") != null;
    if (demo and !draws) {
        std.debug.print("the dictation overlay needs Quickshell (Omarchy ships it)\n", .{});
        return 1;
    }
    var live: ?wav_stream.Live = null;
    if (!demo) if (deepgramKey(ctx)) |key| {
        live = .{
            .io = ctx.io,
            .env = ctx.env,
            .key = key,
            .wav_path = try runtimeFile(ctx, "agb-ptt.wav"),
            .status_path = try runtimeFile(ctx, "agb-ptt.stream"),
            .final_path = try runtimeFile(ctx, "agb-ptt.final"),
        };
        live.?.start() catch {
            live = null;
        };
    };
    const state = try runtimeFile(ctx, "agb-overlay.state");
    var shell: ?std.process.Child = null;
    if (draws) {
        const qml = try runtimeFile(ctx, "agb-overlay.qml");
        try sys.writeFileAtomic(ctx, qml, @embedFile("overlay.qml"));
        try sys.writeFileAtomic(ctx, state, "0 0 0");
        try ctx.env.put("AGB_OVERLAY_STATE", state);
        shell = try std.process.spawn(ctx.io, .{ .argv = &.{ "quickshell", "-p", qml }, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    }
    const started = std.Io.Clock.real.now(ctx.io).toNanoseconds();
    var released: ?f64 = null;
    while (true) {
        const elapsed: f64 = @as(f64, @floatFromInt(std.Io.Clock.real.now(ctx.io).toNanoseconds() - started)) / 1e9;
        const mode: u8 = if (demo) (if (elapsed < 5) 1 else if (elapsed < 6.5) 3 else 0) else readMode(ctx);
        if (mode == 0 or elapsed > 180) break;
        if (mode != 1 and released == null) released = elapsed;
        if (mode == 3) if (live) |*l| l.finish();
        if (!draws) {
            try std.Io.sleep(ctx.io, .fromMilliseconds(33), .awake);
            continue;
        }
        // The preview voice: syllables that grow louder, like the macOS preview.
        const level = if (mode != 1) 0 else if (demo)
            0.04 + (0.25 + 0.6 * @min(1, elapsed / 3)) * std.math.pow(f64, @max(0, @sin(elapsed * 16)), 0.6)
        else
            recordingLevel(ctx);
        const words = if (demo) demoWords(elapsed) else if (live) |*l| l.snapshot(ctx.gpa) else "";
        // Streaming, the recording's end is not "Transcribing": the words are there.
        const shown: u8 = if (mode == 3) 1 else mode;
        try sys.writeFileAtomic(ctx, state, try ctx.fmt("{d} {d:.3} {d:.1}\n{s}", .{ shown, level, released orelse elapsed, words }));
        try std.Io.sleep(ctx.io, .fromMilliseconds(33), .awake);
    }
    if (shell) |*sh| {
        try sys.writeFileAtomic(ctx, state, "0 0 0");
        try std.Io.sleep(ctx.io, .fromMilliseconds(220), .awake); // the fade out
        try sys.writeFileAtomic(ctx, state, "-1 0 0");
        try std.Io.sleep(ctx.io, .fromMilliseconds(150), .awake);
        sh.kill(ctx.io);
    }
    return 0;
}

/// The preview's words, arriving as if spoken.
fn demoWords(elapsed: f64) []const u8 {
    const phrase = "Agent Belt types what you say while you are still saying it, then pastes it where you are.";
    var end: usize = @intFromFloat(@min(@as(f64, @floatFromInt(phrase.len)), elapsed * 22));
    while (end < phrase.len and phrase[end] != ' ') end += 1;
    return phrase[0..end];
}

// ---------------------------------------------------------------- install

/// Hyprland binds, in whichever config language this Hyprland reads: Omarchy
/// configures it in Lua (hyprland.lua), plain Hyprland in hyprland.conf. Each
/// gets its own file, included from the main one inside a marked block; @AGB@
/// stands for this binary.
const HyprConfig = struct { main: []const u8, file: []const u8, snippet: []const u8, include: []const u8, comment: []const u8 };

const hypr_configs = [_]HyprConfig{
    .{
        .main = "hyprland.lua",
        .file = "agent-belt.lua",
        .comment = "--",
        .include = "require(\"hypr.agent-belt\")",
        .snippet =
        \\-- Agent Belt (written by agb install; agb uninstall removes it)
        \\o.bind("CTRL + ALT + D", "Agent Belt: dictate", "@AGB@ ptt start")
        \\o.bind("CTRL + ALT + D", "Agent Belt: stop dictating", "@AGB@ ptt stop", { release = true })
        \\o.bind("SHIFT + F9", "Agent Belt: new agent by voice", "@AGB@ agent-ptt start")
        \\o.bind("SHIFT + F9", "Agent Belt: new agent, stop listening", "@AGB@ agent-ptt stop", { release = true })
        \\o.bind("CTRL + ALT + SPACE", "Agent Belt: agent menu", "@AGB@ menu")
        \\o.bind("CTRL + ALT + UP", "Agent Belt: agent sessions", "xdg-terminal-exec @AGB@ sessions")
        \\
        ,
    },
    .{
        .main = "hyprland.conf",
        .file = "agent-belt.conf",
        .comment = "#",
        .include = "source = ~/.config/hypr/agent-belt.conf",
        .snippet =
        \\# Agent Belt (written by agb install; agb uninstall removes it)
        \\bind = CTRL ALT, D, exec, @AGB@ ptt start
        \\bindr = CTRL ALT, D, exec, @AGB@ ptt stop
        \\bind = SHIFT, F9, exec, @AGB@ agent-ptt start
        \\bindr = SHIFT, F9, exec, @AGB@ agent-ptt stop
        \\bind = CTRL ALT, SPACE, exec, @AGB@ menu
        \\bind = CTRL ALT, UP, exec, xdg-terminal-exec @AGB@ sessions
        \\
        ,
    },
};

fn hyprDir(ctx: sys.Ctx) ![]const u8 {
    const base = ctx.getenv("XDG_CONFIG_HOME") orelse try ctx.join(&.{ ctx.home(), ".config" });
    return ctx.join(&.{ base, "hypr" });
}

fn includeBlock(ctx: sys.Ctx, cfg: HyprConfig) ![]const u8 {
    return ctx.fmt("{0s} >>> agent-belt >>>\n{1s}\n{0s} <<< agent-belt <<<\n", .{ cfg.comment, cfg.include });
}

fn install(ctx: sys.Ctx) !u8 {
    if (ctx.getenv("DEEPGRAM_API_KEY")) |key| if (key.len > 0) {
        const path = try keyPath(ctx);
        std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(path).?) catch {};
        const file = try std.Io.Dir.cwd().createFile(ctx.io, path, .{ .permissions = .fromMode(0o600) });
        defer file.close(ctx.io);
        try file.writeStreamingAll(ctx.io, key);
        std.debug.print("Deepgram key saved to {s} (0600)\n", .{path});
    };
    const hypr = try hyprDir(ctx);
    const bound = for (hypr_configs) |cfg| {
        const main_path = try ctx.join(&.{ hypr, cfg.main });
        const conf = sys.readFile(ctx, main_path) orelse continue;
        try sys.writeFileAtomic(ctx, try ctx.join(&.{ hypr, cfg.file }), try std.mem.replaceOwned(u8, ctx.gpa, cfg.snippet, "@AGB@", selfExe(ctx)));
        const block = try includeBlock(ctx, cfg);
        if (std.mem.indexOf(u8, conf, block) == null)
            try sys.writeFileAtomic(ctx, main_path, try ctx.fmt("{s}{s}\n{s}", .{ conf, if (conf.len > 0 and conf[conf.len - 1] != '\n') "\n" else "", block }));
        _ = sys.run(ctx, &.{ "hyprctl", "reload" }, null);
        break true;
    } else false;
    if (bound) {
        std.debug.print("Hyprland: hold Ctrl+Alt+D to dictate, Shift+F9 for a new agent by voice, Ctrl+Alt+Space for the agent menu, Ctrl+Alt+Up for agb sessions\n", .{});
    } else {
        std.debug.print("no Hyprland config: bind `agb ptt start` / `agb ptt stop` (or `agb ptt toggle`) and `agb menu` in your desktop\n", .{});
    }
    if (sys.which(ctx, "omarchy-bar") != null) {
        installOmarchyBar(ctx);
    } else {
        std.debug.print(
            \\Waybar module (add "custom/agent-belt" to a modules list):
            \\  "custom/agent-belt": {{ "exec": "{s} waybar", "return-type": "json", "interval": 15, "on-click": "{s} menu" }}
            \\
        , .{ selfExe(ctx), selfExe(ctx) });
    }
    if (deepgramKey(ctx) == null) std.debug.print("no Deepgram key yet: DEEPGRAM_API_KEY=… agb install\n", .{});
    return 0;
}

/// A command module in Omarchy's bar, which reads the same JSON as Waybar.
/// `omarchy bar put` only knows plugin widgets, so it goes into shell.json.
fn installOmarchyBar(ctx: sys.Ctx) void {
    const shell_json = omarchyShellJson(ctx) catch return;
    const json = sys.readFile(ctx, shell_json) orelse {
        std.debug.print("Omarchy bar: no {s} yet; customize the bar once, then run agb install again\n", .{shell_json});
        return;
    };
    if (std.mem.indexOf(u8, json, "\"agent-belt\"") == null) {
        const self = selfExe(ctx);
        const module = ctx.fmt("{f}", .{std.json.fmt(.{
            .id = "agent-belt",
            .type = "command",
            .exec = ctx.fmt("{s} waybar", .{self}) catch return,
            .interval = 15,
            .tooltip = "Agent Belt",
            .onClick = ctx.fmt("{s} menu", .{self}) catch return,
        }, .{})}) catch return;
        const out = sys.run(ctx, &.{ "jq", "--argjson", "m", module, ".bar.layout.right = [$m] + (.bar.layout.right // [])", shell_json }, null);
        if (!out.ok) {
            std.debug.print("Omarchy bar: could not edit {s}\n", .{shell_json});
            return;
        }
        sys.writeFileAtomic(ctx, shell_json, out.stdout) catch return;
    }
    std.debug.print("Omarchy bar: 🦇 with the agent sessions (click for the menu)\n", .{});
}

fn omarchyShellJson(ctx: sys.Ctx) ![]const u8 {
    return ctx.join(&.{ ctx.getenv("XDG_CONFIG_HOME") orelse try ctx.join(&.{ ctx.home(), ".config" }), "omarchy", "shell.json" });
}

fn uninstall(ctx: sys.Ctx) !u8 {
    const hypr = try hyprDir(ctx);
    for (hypr_configs) |cfg| {
        const main_path = try ctx.join(&.{ hypr, cfg.main });
        const conf = sys.readFile(ctx, main_path) orelse continue;
        const block = try includeBlock(ctx, cfg);
        if (std.mem.indexOf(u8, conf, block)) |at| {
            const before = std.mem.trimEnd(u8, conf[0..at], "\n");
            try sys.writeFileAtomic(ctx, main_path, try ctx.fmt("{s}\n{s}", .{ before, conf[at + block.len ..] }));
        }
        std.Io.Dir.cwd().deleteFile(ctx.io, try ctx.join(&.{ hypr, cfg.file })) catch {};
    }
    _ = sys.run(ctx, &.{ "hyprctl", "reload" }, null);
    const shell_json = try omarchyShellJson(ctx);
    if (sys.readFile(ctx, shell_json)) |json| if (std.mem.indexOf(u8, json, "\"agent-belt\"") != null) {
        const out = sys.run(ctx, &.{ "jq", ".bar.layout |= map_values(map(select(.id != \"agent-belt\")))", shell_json }, null);
        if (out.ok) try sys.writeFileAtomic(ctx, shell_json, out.stdout);
    };
    std.debug.print("Agent Belt binds and bar module removed; the Deepgram key stays in {s}\n", .{try keyPath(ctx)});
    return 0;
}
