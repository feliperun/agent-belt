//! Agent Belt on a Linux desktop (Wayland; made for Omarchy's Hyprland, Waybar,
//! walker and mako): an agent menu, a Waybar module and push-to-talk dictation
//! driven by compositor key binds. No daemon: each bind runs agb.
const std = @import("std");
const sys = @import("../sessions/sys.zig");
const cli = @import("../sessions/cli.zig");
const hosts = @import("../sessions/hosts.zig");
const deepgram = @import("../deepgram.zig");
const config = @import("../config.zig");

pub fn isCommand(name: []const u8) bool {
    for ([_][]const u8{ "menu", "waybar", "ptt", "install", "uninstall" }) |c| if (std.mem.eql(u8, name, c)) return true;
    return false;
}

pub fn main(ctx: sys.Ctx, argv: []const []const u8) !u8 {
    const cmd = argv[0];
    if (std.mem.eql(u8, cmd, "menu")) return menu(ctx);
    if (std.mem.eql(u8, cmd, "waybar")) return waybar(ctx);
    if (std.mem.eql(u8, cmd, "install")) return install(ctx);
    if (std.mem.eql(u8, cmd, "uninstall")) return uninstall(ctx);
    const action = if (argv.len > 1) argv[1] else "toggle";
    if (std.mem.eql(u8, action, "start")) return pttStart(ctx);
    if (std.mem.eql(u8, action, "stop")) return pttStop(ctx);
    if (std.mem.eql(u8, action, "toggle")) return if (recorderPid(ctx) != null) pttStop(ctx) else pttStart(ctx);
    std.debug.print("usage: agb ptt start|stop|toggle\n", .{});
    return 2;
}

fn selfExe(ctx: sys.Ctx) []const u8 {
    return std.process.executablePathAlloc(ctx.io, ctx.gpa) catch "agb";
}

fn notify(ctx: sys.Ctx, title: []const u8, body: []const u8, timeout_ms: u32) void {
    // A fixed replace id keeps one Agent Belt bubble that changes state.
    _ = sys.run(ctx, &.{ "notify-send", "-a", "Agent Belt", "-r", "8850", "-t", ctx.fmt("{d}", .{timeout_ms}) catch "3000", title, body }, null);
}

/// Opens a terminal running agb with these arguments, detached from us.
fn openTerminal(ctx: sys.Ctx, args: []const []const u8) void {
    const launcher: []const []const u8 = if (sys.which(ctx, "xdg-terminal-exec")) |t| &.{t} else if (ctx.getenv("TERMINAL")) |t| &.{ t, "-e" } else &.{ "foot", "-e" };
    const argv = std.mem.concat(ctx.gpa, []const u8, &.{ launcher, &.{selfExe(ctx)}, args }) catch return;
    _ = std.process.spawn(ctx.io, .{ .argv = argv, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err|
        notify(ctx, "Agent Belt", ctx.fmt("could not open a terminal: {s}", .{@errorName(err)}) catch "", 5000);
}

/// Shows lines in the desktop's dmenu-style picker and returns the chosen one.
fn pick(ctx: sys.Ctx, prompt: []const u8, lines: []const u8) ?[]const u8 {
    const pickers = [_][]const u8{ "walker --dmenu -p \"$AGB_PROMPT\"", "fuzzel --dmenu -p \"$AGB_PROMPT \"", "wofi --dmenu -p \"$AGB_PROMPT\"", "rofi -dmenu -p \"$AGB_PROMPT\"" };
    for (pickers) |picker| {
        const bin = picker[0..std.mem.indexOfScalar(u8, picker, ' ').?];
        if (sys.which(ctx, bin) == null) continue;
        ctx.env.put("AGB_MENU", lines) catch return null;
        ctx.env.put("AGB_PROMPT", prompt) catch return null;
        const out = sys.run(ctx, &.{ "sh", "-c", ctx.fmt("printf '%s\\n' \"$AGB_MENU\" | {s}", .{picker}) catch return null }, null);
        const choice = std.mem.trim(u8, out.stdout, " \r\n");
        return if (choice.len > 0) choice else null;
    }
    notify(ctx, "Agent Belt", "no menu program: install walker, fuzzel, wofi or rofi", 5000);
    return null;
}

const new_agent = "+ Novo agente…";

fn menu(ctx: sys.Ctx) !u8 {
    const reg = try hosts.load(ctx);
    const c = try cli.collect(ctx, reg);
    var lines: std.ArrayList(u8) = .empty;
    try lines.appendSlice(ctx.gpa, new_agent);
    for (c.rows) |r| try lines.print(ctx.gpa, "\n{s} · {s} · {s}", .{ r.name, if (r.agent.len > 0) r.agent else "shell", r.host.name });
    const choice = pick(ctx, "Agent Belt", lines.items) orelse return 0;
    if (std.mem.eql(u8, choice, new_agent)) {
        const words = pick(ctx, "agente máquina repo o que fazer", "") orelse return 0;
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

fn runtimeFile(ctx: sys.Ctx, name: []const u8) ![]const u8 {
    return ctx.join(&.{ ctx.getenv("XDG_RUNTIME_DIR") orelse "/tmp", name });
}

fn recorderPid(ctx: sys.Ctx) ?std.posix.pid_t {
    const text = sys.readFile(ctx, runtimeFile(ctx, "agb-ptt.pid") catch return null) orelse return null;
    const pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \n"), 10) catch return null;
    return if (sys.exists(ctx, ctx.fmt("/proc/{d}", .{pid}) catch return null)) pid else null;
}

fn pttStart(ctx: sys.Ctx) !u8 {
    if (recorderPid(ctx) != null) return 0;
    if (sys.which(ctx, "pw-record") == null) {
        notify(ctx, "Agent Belt", "pw-record (PipeWire) is missing", 5000);
        return 1;
    }
    const wav = try runtimeFile(ctx, "agb-ptt.wav");
    const child = try std.process.spawn(ctx.io, .{ .argv = &.{ "pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", wav }, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    try sys.writeFileAtomic(ctx, try runtimeFile(ctx, "agb-ptt.pid"), try ctx.fmt("{d}", .{child.id.?}));
    notify(ctx, "🎙️ Ouvindo", "solte o atalho para transcrever", 60_000);
    return 0;
}

fn deepgramKey(ctx: sys.Ctx) ?[]const u8 {
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
        notify(ctx, "Agent Belt", "gravação curta demais", 1500);
        return 0;
    }
    const key = deepgramKey(ctx) orelse {
        notify(ctx, "Agent Belt", "sem chave do Deepgram: DEEPGRAM_API_KEY=… agb install", 6000);
        return 1;
    };
    notify(ctx, "🔐 Transcrevendo", "decifrando sua voz…", 30_000);
    const defaults = config.Config{};
    const client = deepgram.Client{ .io = ctx.io, .allocator = ctx.gpa, .api_key = key, .model = defaults.deepgram_model, .language = defaults.deepgram_language, .smart_format = defaults.deepgram_smart_format, .mip_opt_out = defaults.deepgram_mip_opt_out };
    const text = client.transcribe(wav) catch |err| {
        notify(ctx, "Agent Belt", ctx.fmt("transcrição falhou: {s}", .{@errorName(err)}) catch "", 5000);
        return 1;
    };
    if (text.len == 0) {
        notify(ctx, "Agent Belt", "nenhuma fala detectada", 1500);
        return 0;
    }
    notify(ctx, "Agent Belt", text, 1);
    const typed = if (sys.which(ctx, "wtype") != null) sys.run(ctx, &.{ "wtype", "--", text }, null) else sys.run(ctx, &.{ "ydotool", "type", "--", text }, null);
    if (!typed.ok) notify(ctx, "Agent Belt", "instale wtype para digitar o texto", 5000);
    return 0;
}

// ---------------------------------------------------------------- install

const hypr_snippet =
    \\# Agent Belt (written by agb install; agb uninstall removes it)
    \\bind = CTRL ALT, D, exec, {0s} ptt start
    \\bindr = CTRL ALT, D, exec, {0s} ptt stop
    \\bind = CTRL ALT, SPACE, exec, {0s} menu
    \\bind = CTRL ALT, UP, exec, xdg-terminal-exec {0s} sessions
    \\
;

fn hyprDir(ctx: sys.Ctx) ![]const u8 {
    const base = ctx.getenv("XDG_CONFIG_HOME") orelse try ctx.join(&.{ ctx.home(), ".config" });
    return ctx.join(&.{ base, "hypr" });
}

fn sourceLine(ctx: sys.Ctx) ![]const u8 {
    return ctx.fmt("source = {s}", .{try ctx.join(&.{ try hyprDir(ctx), "agent-belt.conf" })});
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
    const main_conf = try ctx.join(&.{ hypr, "hyprland.conf" });
    if (sys.readFile(ctx, main_conf)) |conf| {
        try sys.writeFileAtomic(ctx, try ctx.join(&.{ hypr, "agent-belt.conf" }), try ctx.fmt(hypr_snippet, .{selfExe(ctx)}));
        const line = try sourceLine(ctx);
        if (std.mem.indexOf(u8, conf, line) == null)
            try sys.writeFileAtomic(ctx, main_conf, try ctx.fmt("{s}{s}{s}\n", .{ conf, if (conf.len > 0 and conf[conf.len - 1] != '\n') "\n" else "", line }));
        _ = sys.run(ctx, &.{ "hyprctl", "reload" }, null);
        std.debug.print("Hyprland: hold Ctrl+Alt+D to dictate, Ctrl+Alt+Space for the agent menu, Ctrl+Alt+Up for agb sessions\n", .{});
    } else {
        std.debug.print("no Hyprland config: bind `agb ptt start` / `agb ptt stop` (or `agb ptt toggle`) and `agb menu` in your desktop\n", .{});
    }
    std.debug.print(
        \\Waybar module (add "custom/agent-belt" to a modules list):
        \\  "custom/agent-belt": {{ "exec": "{s} waybar", "return-type": "json", "interval": 15, "on-click": "{s} menu" }}
        \\
    , .{ selfExe(ctx), selfExe(ctx) });
    if (deepgramKey(ctx) == null) std.debug.print("no Deepgram key yet: DEEPGRAM_API_KEY=… agb install\n", .{});
    return 0;
}

fn uninstall(ctx: sys.Ctx) !u8 {
    const hypr = try hyprDir(ctx);
    const main_conf = try ctx.join(&.{ hypr, "hyprland.conf" });
    if (sys.readFile(ctx, main_conf)) |conf| {
        const line = try ctx.fmt("{s}\n", .{try sourceLine(ctx)});
        if (std.mem.indexOf(u8, conf, line)) |at| try sys.writeFileAtomic(ctx, main_conf, try std.mem.concat(ctx.gpa, u8, &.{ conf[0..at], conf[at + line.len ..] }));
        std.Io.Dir.cwd().deleteFile(ctx.io, try ctx.join(&.{ hypr, "agent-belt.conf" })) catch {};
        _ = sys.run(ctx, &.{ "hyprctl", "reload" }, null);
    }
    std.debug.print("Hyprland binds removed; the Deepgram key stays in {s}\n", .{try keyPath(ctx)});
    return 0;
}
