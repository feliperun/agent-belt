//! A second sshd on a Windows machine, MSYS2's, for attaching to its sessions.
//!
//! Windows' own sshd gives a session a pseudo console (ConPTY), which parses and
//! re-renders everything tmux draws. While an agent redraws its screen, a key
//! typed from the Mac took 1.5 to 2.7 s to echo on every other press. MSYS2's
//! sshd hands tmux a plain MSYS2 pty instead: 29 ms median, 131 ms at worst,
//! close to a Linux machine. It listens on loopback only; the client reaches it
//! through Windows' sshd as a jump host, so no new port is open on the network
//! (docs/adr/0007-attach-to-windows-through-msys2-sshd.md).

const std = @import("std");
const sys = @import("sys.zig");
const hosts = @import("hosts.zig");

pub const port = "58022";
const sshd_exe = "C:\\msys64\\usr\\bin\\sshd.exe";

fn dir(ctx: sys.Ctx) ![]const u8 {
    return ctx.join(&.{ ctx.home(), ".config", "agent-belt", "sshd" });
}

pub fn configPath(ctx: sys.Ctx) ![]const u8 {
    return ctx.join(&.{ try dir(ctx), "sshd_config" });
}

/// C:\Users\alice\x as MSYS2 programs read it: /c/Users/alice/x. sshd takes
/// "C:/Users/…" in its config for a relative path.
fn slashed(ctx: sys.Ctx, path: []const u8) ![]const u8 {
    if (path.len < 2 or path[1] != ':') return error.NotAWindowsPath;
    const out = try ctx.fmt("/{c}{s}", .{ std.ascii.toLower(path[0]), path[2..] });
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

/// The sshd's configuration: loopback only, keys only, the same keys Windows'
/// sshd accepts.
pub fn config(ctx: sys.Ctx, base: []const u8) ![]const u8 {
    const b = try slashed(ctx, base);
    return ctx.fmt(
        \\Port {s}
        \\ListenAddress 127.0.0.1
        \\HostKey {s}/host_key
        \\PidFile {s}/sshd.pid
        \\AuthorizedKeysFile {s}/authorized_keys
        \\PasswordAuthentication no
        \\KbdInteractiveAuthentication no
        \\StrictModes no
        \\SetEnv LANG=C.UTF-8
        \\
    , .{ port, b, b, b });
}

/// Windows side, from `agb install`: MSYS2's openssh, a host key, the config
/// and the authorized keys. Prints what it did; a failure only costs the fast
/// path (attaching falls back to Windows' sshd).
pub fn setup(ctx: sys.Ctx) void {
    const base = dir(ctx) catch return;
    std.Io.Dir.cwd().createDirPath(ctx.io, base) catch {};
    if (!sys.isFile(ctx, sshd_exe)) {
        std.debug.print("installing MSYS2 openssh for fast attaches...\n", .{});
        _ = sys.run(ctx, &.{ sys.msys_bash, "-lc", "pacman -S --noconfirm --needed openssh" }, null);
        if (!sys.isFile(ctx, sshd_exe)) {
            std.debug.print("fast attach unavailable: pacman could not install openssh\n", .{});
            return;
        }
    }
    const key = ctx.join(&.{ base, "host_key" }) catch return;
    if (!sys.isFile(ctx, key)) _ = sys.run(ctx, &.{ "C:\\msys64\\usr\\bin\\ssh-keygen.exe", "-q", "-t", "ed25519", "-N", "", "-f", slashed(ctx, key) catch return }, null);
    // An administrator's keys live in ProgramData, anyone else's in ~/.ssh.
    var keys: std.ArrayList(u8) = .empty;
    const admin = sys.readFile(ctx, "C:\\ProgramData\\ssh\\administrators_authorized_keys") orelse "";
    const own = sys.readFile(ctx, ctx.join(&.{ ctx.home(), ".ssh", "authorized_keys" }) catch "") orelse "";
    for ([_][]const u8{ admin, own }) |part| if (part.len > 0) {
        keys.appendSlice(ctx.gpa, part) catch return;
        if (part[part.len - 1] != '\n') keys.append(ctx.gpa, '\n') catch return;
    };
    sys.writeFileAtomic(ctx, ctx.join(&.{ base, "authorized_keys" }) catch return, keys.items) catch {};
    const cfg = configPath(ctx) catch return;
    sys.writeFileAtomic(ctx, cfg, config(ctx, base) catch return) catch return;
    // A running sshd keeps the old config: stop it, the tray starts it again.
    const pid = std.mem.trim(u8, sys.readFile(ctx, ctx.join(&.{ base, "sshd.pid" }) catch return) orelse "", " \r\n");
    if (pid.len > 0) _ = sys.run(ctx, &.{ "C:\\msys64\\usr\\bin\\kill.exe", pid }, null);
    const check = sys.run(ctx, &.{ sshd_exe, "-t", "-f", slashed(ctx, cfg) catch return }, null);
    if (!check.ok) {
        std.debug.print("fast attach unavailable: {s}\n", .{check.stderr});
        return;
    }
    std.debug.print("fast attach: MSYS2 sshd on 127.0.0.1:{s}{s}\n", .{ port, if (keys.items.len == 0) " (no authorized keys yet)" else "" });
}

/// Windows side, a tray thread: keeps the sshd running. It is started without
/// a console window and with real standard handles (without them sshd's
/// per-connection child dies at once: "startup pipe … Connection reset").
pub fn serve(ctx: sys.Ctx, log: *const fn ([]const u8) void) void {
    while (true) {
        const cfg = configPath(ctx) catch return;
        if (!sys.isFile(ctx, cfg) or !sys.isFile(ctx, sshd_exe)) {
            sleep(ctx, 60);
            continue;
        }
        const started = std.Io.Clock.awake.now(ctx.io);
        runOnce(ctx, cfg) catch |err| log(@errorName(err));
        // Quick exit: most likely an sshd left by an earlier tray holds the port
        // and still serves. Try again later rather than spin.
        const lived = started.durationTo(std.Io.Clock.awake.now(ctx.io)).toSeconds();
        sleep(ctx, if (lived < 10) 60 else 5);
    }
}

fn runOnce(ctx: sys.Ctx, cfg: []const u8) !void {
    const log_path = try ctx.join(&.{ try dir(ctx), "sshd.log" });
    const out = try std.Io.Dir.cwd().createFile(ctx.io, log_path, .{});
    defer out.close(ctx.io);
    // sshd-session.exe lives in /usr/lib/ssh and finds MSYS2's DLLs through
    // PATH ("error while loading shared libraries"). Only this child gets it:
    // the tray looks up Windows' ssh and git on its own PATH.
    var env = try ctx.env.clone(ctx.gpa);
    try env.put("PATH", try ctx.fmt("C:\\msys64\\usr\\bin;{s}", .{ctx.getenv("PATH") orelse ""}));
    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{ sshd_exe, "-D", "-e", "-f", try slashed(ctx, cfg) },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
        .create_no_window = true,
    });
    _ = try child.wait(ctx.io);
}

fn sleep(ctx: sys.Ctx, seconds: i64) void {
    std.Io.sleep(ctx.io, .fromSeconds(seconds), .awake) catch {};
}

/// Client side: ssh to a Windows machine's MSYS2 sshd, through its own sshd,
/// running tmux there on a real pty. The same options `agb attach` sets.
pub fn attachArgv(ctx: sys.Ctx, host: hosts.Host, name: []const u8, detach_others: bool) ![]const []const u8 {
    const at = std.mem.indexOfScalar(u8, host.target, '@') orelse return error.TargetWithoutUser;
    const user = host.target[0..at];
    const target = try sys.shQuote(ctx, try ctx.fmt("={s}", .{name}));
    const remote_cmd = try ctx.fmt(
        "tmux set-option -g set-clipboard on \\; set-option -g allow-passthrough on \\; set-option -g mouse on; " ++
            "tmux show-options -gqv terminal-features | grep -q '\\*:clipboard' || tmux set-option -as terminal-features ',*:clipboard'; " ++
            "exec tmux -u attach {s}-t {s}",
        .{ if (detach_others) "-d " else "", target },
    );
    return ctx.gpa.dupe([]const u8, &.{
        "ssh",                                 "-tt",
        "-o",                                  "ConnectTimeout=6",
        "-o",                                  "BatchMode=yes",
        "-o",                                  "StrictHostKeyChecking=accept-new",
        "-o",                                  try ctx.fmt("HostKeyAlias=agb-{s}-msys", .{host.name}),
        "-J",                                  host.target,
        "-p",                                  port,
        try ctx.fmt("{s}@127.0.0.1", .{user}), remote_cmd,
    });
}

test "the sshd listens on loopback with the keys beside its config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .gpa = arena.allocator(), .io = std.testing.io, .env = &env };
    const cfg = try config(ctx, "C:\\Users\\alice\\.config\\agent-belt\\sshd");
    try std.testing.expect(std.mem.indexOf(u8, cfg, "ListenAddress 127.0.0.1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "AuthorizedKeysFile /c/Users/alice/.config/agent-belt/sshd/authorized_keys\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "PasswordAuthentication no\n") != null);

    const argv = try attachArgv(ctx, .{ .name = "windows-pc", .target = "alice@windows-pc", .kind = .msys }, "web-app", true);
    try std.testing.expectEqualStrings("alice@windows-pc", argv[11]);
    try std.testing.expectEqualStrings("alice@127.0.0.1", argv[14]);
    try std.testing.expect(std.mem.endsWith(u8, argv[15], "exec tmux -u attach -d -t '=web-app'"));
    try std.testing.expectError(error.TargetWithoutUser, attachArgv(ctx, .{ .name = "windows-pc", .target = "windows-pc", .kind = .msys }, "x", false));
}
