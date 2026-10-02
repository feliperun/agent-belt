//! A new agent's tab in the terminal app that is running, Orca or cmux. Both
//! show each agent as its own workspace in the agent's repository:
//!
//!   here, with a repo    agb creates the worktree and the tmux session, and the
//!                        tab attaches to it inside that worktree: one new
//!                        workspace per agent
//!   another machine      the tab runs `agb new --host …` in this machine's clone
//!                        of the same repo
//!   no repo, or no clone the caller keeps its own terminal (`agb _tab-open`
//!                        exits 2)
//!
//! What opening the workspace takes is the host's own (`orca.zig`, `cmux.zig`).
//! See ADR 0009.
const std = @import("std");
const sys = @import("sys.zig");
const hosts = @import("hosts.zig");
const local = @import("local.zig");
const cli = @import("cli.zig");
const orca = @import("orca.zig");
const cmux = @import("cmux.zig");

pub const not_placed: u8 = 2;

pub const Host = enum { orca, cmux };

pub const Placement = enum { here, elsewhere, none };

/// Where a new agent's tab belongs.
pub fn placement(plan: cli.Plan) Placement {
    if (plan.no_repo or plan.repo == null) return .none;
    return if (plan.host == null) .here else .elsewhere;
}

/// A shell line running agb with these arguments (the terminal runs it in the user's shell).
pub fn commandLine(ctx: sys.Ctx, agb: []const u8, args: []const []const u8) ![]const u8 {
    return sys.shJoin(ctx, try std.mem.concat(ctx.gpa, []const u8, &.{ &.{agb}, args }));
}

fn bin(ctx: sys.Ctx, host: Host) ?[]const u8 {
    return switch (host) {
        .orca => orca.bin(ctx),
        .cmux => cmux.bin(ctx),
    };
}

/// A workspace for the agent in `dir`, brought forward. `root` is the
/// repository's main checkout, which Orca needs registered as a project.
fn place(ctx: sys.Ctx, host: Host, cli_bin: []const u8, root: []const u8, dir: []const u8, title: []const u8, command: []const u8) u8 {
    switch (host) {
        .orca => {
            if (!orca.ensureRegistered(ctx, cli_bin, root)) return not_placed;
            return if (orca.createTab(ctx, cli_bin, dir, title, command)) 0 else not_placed;
        },
        .cmux => return if (cmux.createWorkspace(ctx, cli_bin, dir, title, command)) 0 else not_placed,
    }
}

/// `agb _tab-open <orca|cmux> <agb new arguments>`: opens the new agent's tab in
/// that app. Exits 2 when there is no workspace to put it in (the caller opens
/// its own terminal), 1 when creating the agent failed.
pub fn open(env: cli.Env, args: []const []const u8) !u8 {
    const ctx = env.ctx;
    if (args.len == 0) return not_placed;
    const host = std.meta.stringToEnum(Host, args[0]) orelse return not_placed;
    const cli_bin = bin(ctx, host) orelse return not_placed;
    const rest = args[1..];
    const reg = try cli.loadRegistry(ctx);
    // The panel already checked the repo against the machine's index.
    const plan = cli.parseNew(ctx, reg, rest, trustRepo) catch return not_placed;
    const agb = try std.process.executablePathAlloc(ctx.io, ctx.gpa);
    switch (placement(plan)) {
        .none => return not_placed,
        .here => {
            const session = local.create(ctx, .{ .task = plan.task.?, .repo = plan.repo, .agent = plan.agent, .prompt = plan.prompt, .no_attach = true }) catch |err| {
                std.debug.print("agb: {s}\n", .{@errorName(err)});
                return 1;
            };
            const worktree = local.sessionPath(ctx, session) orelse return 1;
            const root = local.repoRootOf(ctx, worktree) orelse return 1;
            const title = try ctx.fmt("{s} · {s}", .{ plan.task.?, @tagName(plan.agent) });
            return place(ctx, host, cli_bin, root, worktree, title, try commandLine(ctx, agb, &.{ "attach", session }));
        },
        .elsewhere => {
            // This machine's clone of the same repository holds the workspace.
            const root = (local.resolveRepo(ctx, plan.repo.?) catch null) orelse return not_placed;
            const title = try ctx.fmt("{s} @ {s}", .{ plan.task.?, plan.host.?.name });
            return place(ctx, host, cli_bin, root, root, title, try commandLine(ctx, agb, rest));
        },
    }
}

fn trustRepo(_: sys.Ctx, _: ?hosts.Host, _: []const u8) bool {
    return true;
}

test "where a new agent's tab goes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
    var list = [_]hosts.Host{
        .{ .name = "macbook", .target = "alice@macbook", .kind = .posix },
        .{ .name = "windows-pc", .target = "alice@windows-pc", .kind = .msys },
    };
    const reg = hosts.Registry{ .path = "", .hosts = &list, .self_line = "macbook", .self = "macbook" };
    const here = try cli.parseNew(ctx, reg, &.{ "--agent", "codex", "--host", "macbook", "--repo", "web-app", "--task", "login" }, trustRepo);
    try std.testing.expectEqual(Placement.here, placement(here));
    const there = try cli.parseNew(ctx, reg, &.{ "--agent", "claude", "--host", "windows-pc", "--repo", "api", "--task", "fix" }, trustRepo);
    try std.testing.expectEqual(Placement.elsewhere, placement(there));
    const research = try cli.parseNew(ctx, reg, &.{ "--agent", "claude", "--host", "macbook", "--no-repo", "--task", "tmux-alternatives" }, trustRepo);
    try std.testing.expectEqual(Placement.none, placement(research));
    // The tab's command survives the app path's space and a quote in the prompt.
    try std.testing.expectEqualStrings("'/Applications/Agent Belt.app/Contents/MacOS/agb' 'attach' 'api-fix'", try commandLine(ctx, "/Applications/Agent Belt.app/Contents/MacOS/agb", &.{ "attach", "api-fix" }));
    try std.testing.expectEqualStrings("'agb' 'new' '--prompt' 'it'\\''s broken'", try commandLine(ctx, "agb", &.{ "new", "--prompt", "it's broken" }));
}

test "the host is named by its app" {
    try std.testing.expectEqual(Host.cmux, std.meta.stringToEnum(Host, "cmux").?);
    try std.testing.expectEqual(Host.orca, std.meta.stringToEnum(Host, "orca").?);
    try std.testing.expect(std.meta.stringToEnum(Host, "tmux") == null);
}
