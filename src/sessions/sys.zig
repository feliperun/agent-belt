//! Process, path and quoting helpers shared by the session engine. Runs on
//! macOS, Linux and Windows; on Windows tmux lives in MSYS2 and is reached
//! through its login bash, while git and the agents are native.
const std = @import("std");
const builtin = @import("builtin");

pub const Platform = enum { mac, linux, windows };
pub const platform: Platform = switch (builtin.os.tag) {
    .macos => .mac,
    .windows => .windows,
    else => .linux,
};

pub const msys_bash = "C:\\msys64\\usr\\bin\\bash.exe";

pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,

    pub fn getenv(ctx: Ctx, name: []const u8) ?[]const u8 {
        return ctx.env.get(name);
    }

    pub fn home(ctx: Ctx) []const u8 {
        if (platform == .windows) return ctx.getenv("USERPROFILE") orelse "C:\\Users\\Default";
        return ctx.getenv("HOME") orelse "/";
    }

    pub fn join(ctx: Ctx, parts: []const []const u8) ![]u8 {
        return std.fs.path.join(ctx.gpa, parts);
    }

    pub fn fmt(ctx: Ctx, comptime format: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(ctx.gpa, format, args);
    }
};

pub const Output = struct {
    ok: bool,
    code: u8,
    stdout: []u8,
    stderr: []u8,

    /// stdout without trailing whitespace (and without \r from Windows tools).
    pub fn text(self: Output) []const u8 {
        return std.mem.trimEnd(u8, self.stdout, " \r\n\t");
    }
};

/// Runs a program and captures its output. A missing program is a failed run,
/// not an error: callers treat "not installed" like "said no".
pub fn run(ctx: Ctx, argv: []const []const u8, cwd: ?[]const u8) Output {
    const result = std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv,
        .cwd = if (cwd) |dir| .{ .path = dir } else .inherit,
        .environ_map = ctx.env,
        .stdout_limit = .limited(16 * 1024 * 1024),
    }) catch return .{ .ok = false, .code = 127, .stdout = &.{}, .stderr = &.{} };
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };
    return .{ .ok = code == 0, .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// Runs a program on the user's terminal (inherited stdio) and returns its exit code.
var capture_seq = std.atomic.Value(u32).init(0);

/// Like run, with the output going through temporary files instead of pipes.
/// Windows' ssh.exe prints its output and then never exits when stdout is a
/// pipe inside an ssh session (a remote `agb ls` on Windows hung forever).
pub fn runCaptured(ctx: Ctx, argv: []const []const u8) Output {
    if (platform != .windows) return run(ctx, argv, null);
    const failed = Output{ .ok = false, .code = 127, .stdout = &.{}, .stderr = &.{} };
    const stamp = std.Io.Clock.real.now(ctx.io).toNanoseconds();
    const base = ctx.fmt("{s}\\agb-{d}-{d}", .{ ctx.getenv("TEMP") orelse ctx.home(), stamp, capture_seq.fetchAdd(1, .monotonic) }) catch return failed;
    const out_path = ctx.fmt("{s}.out", .{base}) catch return failed;
    const err_path = ctx.fmt("{s}.err", .{base}) catch return failed;
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteFile(ctx.io, out_path) catch {};
    defer cwd.deleteFile(ctx.io, err_path) catch {};
    const code: u8 = blk: {
        const out = cwd.createFile(ctx.io, out_path, .{}) catch return failed;
        defer out.close(ctx.io);
        const err = cwd.createFile(ctx.io, err_path, .{}) catch return failed;
        defer err.close(ctx.io);
        var child = std.process.spawn(ctx.io, .{ .argv = argv, .environ_map = ctx.env, .stdin = .ignore, .stdout = .{ .file = out }, .stderr = .{ .file = err } }) catch return failed;
        const term = child.wait(ctx.io) catch return failed;
        break :blk switch (term) {
            .exited => |c| c,
            else => 1,
        };
    };
    return .{ .ok = code == 0, .code = code, .stdout = readFile(ctx, out_path) orelse &.{}, .stderr = readFile(ctx, err_path) orelse &.{} };
}

pub fn interactive(ctx: Ctx, argv: []const []const u8, cwd: ?[]const u8) u8 {
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = if (cwd) |dir| .{ .path = dir } else .inherit,
        .environ_map = ctx.env,
    }) catch return 127;
    const term = child.wait(ctx.io) catch return 1;
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

/// Hands the terminal to another program for good: exec on POSIX; on Windows,
/// which has no exec, it waits and exits with the child's code.
pub fn handOver(ctx: Ctx, argv: []const []const u8) noreturn {
    if (platform != .windows) {
        const err = std.process.replace(ctx.io, .{ .argv = argv, .environ_map = ctx.env });
        std.debug.print("agb: could not run {s}: {s}\n", .{ argv[0], @errorName(err) });
        std.process.exit(127);
    }
    std.process.exit(interactive(ctx, argv, null));
}

/// Finds a program on PATH (and, like a login shell would, in the usual
/// per-user directories that non-interactive ssh sessions leave out).
pub fn which(ctx: Ctx, name: []const u8) ?[]const u8 {
    const exts: []const []const u8 = if (platform == .windows) &.{ ".exe", ".cmd", "" } else &.{""};
    const sep: u8 = if (platform == .windows) ';' else ':';
    var dirs: std.ArrayList([]const u8) = .empty;
    if (ctx.getenv("PATH")) |path| {
        var it = std.mem.splitScalar(u8, path, sep);
        while (it.next()) |dir| if (dir.len > 0) dirs.append(ctx.gpa, dir) catch {};
    }
    const home = ctx.home();
    const extra: []const []const u8 = switch (platform) {
        .mac => &.{ ".local/bin", "/opt/homebrew/bin", "/usr/local/bin" },
        .linux => &.{ ".local/bin", ".local/share/mise/shims", "/usr/local/bin" },
        .windows => &.{ ".local\\bin", "AppData\\Local\\Microsoft\\WinGet\\Links", "C:\\Program Files\\Git\\cmd", "C:\\Program Files\\nodejs", "C:\\Windows\\System32\\OpenSSH" },
    };
    for (extra) |dir| {
        const full = if (std.fs.path.isAbsolute(dir)) dir else (ctx.join(&.{ home, dir }) catch continue);
        dirs.append(ctx.gpa, full) catch {};
    }
    for (dirs.items) |dir| for (exts) |ext| {
        const candidate = ctx.fmt("{s}{c}{s}{s}", .{ dir, std.fs.path.sep, name, ext }) catch continue;
        if (isFile(ctx, candidate)) return candidate;
    };
    return null;
}

pub fn isFile(ctx: Ctx, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return false;
    return stat.kind == .file or stat.kind == .sym_link;
}

pub fn isDir(ctx: Ctx, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return false;
    return stat.kind == .directory;
}

pub fn exists(ctx: Ctx, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return false;
    return true;
}

pub fn readFile(ctx: Ctx, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(64 * 1024 * 1024)) catch null;
}

/// Holds an exclusive lock on `path` for as long as the returned file stays
/// open (the process's life): null when another process holds it. One panel
/// host however many times its key is pressed; the lock goes with the process.
pub fn lockInstance(ctx: Ctx, path: []const u8) ?std.Io.File {
    return std.Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch null;
}

/// Writes through a temporary file and a rename, so a crash never leaves a
/// half-written file behind.
pub fn writeFileAtomic(ctx: Ctx, path: []const u8, bytes: []const u8) !void {
    const tmp = try ctx.fmt("{s}.agb.tmp", .{path});
    var file = try std.Io.Dir.cwd().createFile(ctx.io, tmp, .{ .truncate = true });
    try file.writeStreamingAll(ctx.io, bytes);
    file.close(ctx.io);
    try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, ctx.io);
}

// ---------------------------------------------------------------- quoting

/// POSIX shell single-quoting: 'it'\''s'.
pub fn shQuote(ctx: Ctx, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(ctx.gpa, '\'');
    for (value) |c| {
        if (c == '\'') try out.appendSlice(ctx.gpa, "'\\''") else try out.append(ctx.gpa, c);
    }
    try out.append(ctx.gpa, '\'');
    return out.items;
}

/// PowerShell single-quoting: 'it''s'. Windows' sshd hands commands to PowerShell.
pub fn psQuote(ctx: Ctx, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(ctx.gpa, '\'');
    for (value) |c| {
        if (c == '\'') try out.appendSlice(ctx.gpa, "''") else try out.append(ctx.gpa, c);
    }
    try out.append(ctx.gpa, '\'');
    return out.items;
}

pub fn shJoin(ctx: Ctx, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(ctx.gpa, ' ');
        try out.appendSlice(ctx.gpa, try shQuote(ctx, arg));
    }
    return out.items;
}

// ---------------------------------------------------------------- paths

/// C:\dev\x or C:/dev/x -> /c/dev/x, the form MSYS2 tmux understands.
pub fn toMsys(ctx: Ctx, path: []const u8) ![]u8 {
    if (path.len >= 2 and path[1] == ':') {
        const rest = try std.mem.replaceOwned(u8, ctx.gpa, path[2..], "\\", "/");
        return ctx.fmt("/{c}{s}", .{ std.ascii.toLower(path[0]), rest });
    }
    return std.mem.replaceOwned(u8, ctx.gpa, path, "\\", "/");
}

/// /c/dev/x -> C:/dev/x (git and Claude Code on Windows).
pub fn fromMsys(ctx: Ctx, path: []const u8) ![]u8 {
    if (path.len >= 3 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == '/')
        return ctx.fmt("{c}:{s}", .{ std.ascii.toUpper(path[1]), path[2..] });
    return ctx.gpa.dupe(u8, path);
}

pub fn validSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 60) return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}

/// Repository names or paths; no backslashes (they break through PowerShell) and
/// nothing a shell would interpret.
pub fn validRepo(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._/:~-", c) != null)) return false;
    return true;
}

/// "Fix the login after the update!" -> "fix-the-login-after" (a tmux- and
/// branch-safe task name from the first words of a request).
pub fn slugFromWords(ctx: Ctx, words: []const u8, max_words: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, words, " \t\n");
    while (it.next()) |word| {
        var clean: std.ArrayList(u8) = .empty;
        for (word) |c| {
            if (std.ascii.isAlphanumeric(c)) try clean.append(ctx.gpa, std.ascii.toLower(c));
        }
        if (clean.items.len == 0) continue;
        if (out.items.len > 0) try out.append(ctx.gpa, '-');
        try out.appendSlice(ctx.gpa, clean.items);
        count += 1;
        if (count == max_words or out.items.len >= 30) break;
    }
    return out.items;
}

test "quoting, paths and slugs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const ctx = Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env };
    try std.testing.expectEqualStrings("'it'\\''s'", try shQuote(ctx, "it's"));
    try std.testing.expectEqualStrings("'it''s'", try psQuote(ctx, "it's"));
    try std.testing.expectEqualStrings("/c/dev/coreum", try toMsys(ctx, "C:\\dev\\coreum"));
    try std.testing.expectEqualStrings("/c/dev/x", try toMsys(ctx, "C:/dev/x"));
    try std.testing.expectEqualStrings("C:/dev/x", try fromMsys(ctx, "/c/dev/x"));
    try std.testing.expectEqualStrings("/home/a", try fromMsys(ctx, "/home/a"));
    try std.testing.expectEqualStrings("fix-the-login-after", try slugFromWords(ctx, "Fix the login, after the update!", 4));
    try std.testing.expectEqualStrings("corrigir-o-login", try slugFromWords(ctx, "corrigir o login", 4));
    try std.testing.expect(validSlug("coreum-xpto_1.2"));
    try std.testing.expect(!validSlug("tem espaço"));
    try std.testing.expect(validRepo("C:/dev/coreum"));
    try std.testing.expect(!validRepo("x; rm -rf ~"));
    try std.testing.expect(!validRepo("C:\\dev"));
}

test "one instance holds the lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(ctx.gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "panel.lock" });
    const first = lockInstance(ctx, path) orelse return error.TestUnexpectedResult;
    try std.testing.expect(lockInstance(ctx, path) == null);
    first.close(ctx.io);
    const again = lockInstance(ctx, path) orelse return error.TestUnexpectedResult;
    again.close(ctx.io);
}
