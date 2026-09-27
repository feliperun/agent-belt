//! A new agent's tab in Orca, in its repository's project. Orca keys a project
//! by the repository's git remote and shows each worktree of a registered repo
//! as a workspace, agb's worktrees included (`--worktree path:<dir>`). So:
//!
//!   here, with a repo    agb creates the worktree and the tmux session, and the
//!                        tab attaches to it inside that worktree: one new
//!                        workspace per agent in the repo's project
//!   another machine      the tab runs `agb new --host …` in the project of this
//!                        machine's clone of the same repo
//!   no repo, or no clone the caller keeps its own terminal (`agb _orca-open`
//!                        exits 2)
//!
//! A repo Orca does not know yet is registered (`orca repo add`). See ADR 0005.
const std = @import("std");
const sys = @import("sys.zig");
const hosts = @import("hosts.zig");
const local = @import("local.zig");
const cli = @import("cli.zig");

pub const not_placed: u8 = 2;

/// Orca's CLI, when Orca is installed.
pub fn bin(ctx: sys.Ctx) ?[]const u8 {
    if (ctx.getenv("AGENT_BELT_ORCA_CLI")) |p| if (p.len > 0) return p;
    if (sys.which(ctx, "orca")) |p| return p;
    const app = "/Applications/Orca.app/Contents/Resources/bin/orca";
    return if (sys.isFile(ctx, app)) app else null;
}

pub const Placement = enum { here, elsewhere, none };

/// Where a new agent's tab belongs.
pub fn placement(plan: cli.Plan) Placement {
    if (plan.no_repo or plan.repo == null) return .none;
    return if (plan.host == null) .here else .elsewhere;
}

/// A shell line running agb with these arguments (Orca runs it in the user's shell).
pub fn commandLine(ctx: sys.Ctx, agb: []const u8, args: []const []const u8) ![]const u8 {
    return sys.shJoin(ctx, try std.mem.concat(ctx.gpa, []const u8, &.{ &.{agb}, args }));
}

fn orca(ctx: sys.Ctx, cli_bin: []const u8, args: []const []const u8) sys.Output {
    const argv = std.mem.concat(ctx.gpa, []const u8, &.{ &.{cli_bin}, args, &.{"--json"} }) catch
        return .{ .ok = false, .code = 1, .stdout = &.{}, .stderr = &.{} };
    return sys.run(ctx, argv, null);
}

/// Orca answers {"ok": true, "result": …}; a failed call can still exit 0.
fn succeeded(out: sys.Output) bool {
    return answered(out.ok, out.stdout);
}

fn answered(ok: bool, stdout: []const u8) bool {
    return ok and (std.mem.indexOf(u8, stdout, "\"ok\": true") != null or std.mem.indexOf(u8, stdout, "\"ok\":true") != null);
}

/// The repository becomes an Orca project when Orca does not know it yet.
fn ensureRegistered(ctx: sys.Ctx, cli_bin: []const u8, root: []const u8) bool {
    const selector = ctx.fmt("path:{s}", .{root}) catch return false;
    if (succeeded(orca(ctx, cli_bin, &.{ "worktree", "show", "--worktree", selector }))) return true;
    return succeeded(orca(ctx, cli_bin, &.{ "repo", "add", "--path", root }));
}

/// `agb _orca-open <agb new arguments>`: opens the new agent's tab in Orca, in
/// its repository's project. Exits 2 when there is no project to put it in (the
/// caller opens its own terminal), 1 when creating the agent failed.
pub fn open(env: cli.Env, args: []const []const u8) !u8 {
    const ctx = env.ctx;
    const cli_bin = bin(ctx) orelse return not_placed;
    const reg = try cli.loadRegistry(ctx);
    // The panel already checked the repo against the machine's index.
    const plan = cli.parseNew(ctx, reg, args, trustRepo) catch return not_placed;
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
            if (!ensureRegistered(ctx, cli_bin, root)) return not_placed;
            const title = try ctx.fmt("{s} · {s}", .{ plan.task.?, @tagName(plan.agent) });
            return createTab(ctx, cli_bin, worktree, title, try commandLine(ctx, agb, &.{ "attach", session }));
        },
        .elsewhere => {
            // This machine's clone of the same repository holds the project.
            const root = (local.resolveRepo(ctx, plan.repo.?) catch null) orelse return not_placed;
            if (!ensureRegistered(ctx, cli_bin, root)) return not_placed;
            const title = try ctx.fmt("{s} @ {s}", .{ plan.task.?, plan.host.?.name });
            return createTab(ctx, cli_bin, root, title, try commandLine(ctx, agb, args));
        },
    }
}

/// A tab in `dir`'s workspace, brought forward. `--focus` on a workspace Orca
/// keeps hidden (its repo hides worktrees it did not create) times out, so the
/// tab is created in the background and switched to. A worktree created a
/// moment ago may not be adopted yet: one more try after a second.
fn createTab(ctx: sys.Ctx, cli_bin: []const u8, dir: []const u8, title: []const u8, command: []const u8) u8 {
    const selector = ctx.fmt("path:{s}", .{dir}) catch return 1;
    // The shell titles the tab with the command it runs: the line names it first.
    const line = titled(ctx, title, command) catch return 1;
    var out = orca(ctx, cli_bin, &.{ "terminal", "create", "--worktree", selector, "--title", title, "--command", line });
    if (!succeeded(out)) {
        std.Io.sleep(ctx.io, .fromSeconds(1), .awake) catch {};
        out = orca(ctx, cli_bin, &.{ "terminal", "create", "--worktree", selector, "--title", title, "--command", line });
    }
    const handle = handleOf(ctx.gpa, out.stdout) orelse {
        std.debug.print("agb: Orca did not open the tab: {s}\n", .{std.mem.trim(u8, out.stdout, " \r\n")});
        return not_placed;
    };
    _ = orca(ctx, cli_bin, &.{ "terminal", "switch", "--terminal", handle });
    return 0;
}

/// A shell line that sets the terminal's title, then runs `command`.
fn titled(ctx: sys.Ctx, title: []const u8, command: []const u8) ![]const u8 {
    return ctx.fmt("printf '\\033]0;%s\\007' {s}; {s}", .{ try sys.shQuote(ctx, title), command });
}

/// The new terminal's handle in a successful `terminal create` answer.
fn handleOf(gpa: std.mem.Allocator, answer: []const u8) ?[]const u8 {
    const Answer = struct { ok: bool = false, result: ?struct { terminal: ?struct { handle: []const u8 = "" } = null } = null };
    const a = std.json.parseFromSliceLeaky(Answer, gpa, answer, .{ .ignore_unknown_fields = true }) catch return null;
    if (!a.ok) return null;
    const handle = (a.result orelse return null).terminal orelse return null;
    return if (handle.handle.len > 0) handle.handle else null;
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
    try std.testing.expectEqualStrings("printf '\\033]0;%s\\007' 'fix @ windows-pc'; 'agb' 'attach' 'api-fix'", try titled(ctx, "fix @ windows-pc", "'agb' 'attach' 'api-fix'"));
}

test "the new tab's handle, only from a successful answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqualStrings("term_1", handleOf(gpa, "{\"ok\": true, \"result\": {\"terminal\": {\"handle\": \"term_1\", \"surface\": \"visible\"}}}").?);
    try std.testing.expect(handleOf(gpa, "{\"ok\": false, \"error\": {\"message\": \"Timed out waiting for terminal handle after creation\"}}") == null);
    try std.testing.expect(handleOf(gpa, "not json") == null);
}

test "an Orca answer is a success only when it says so" {
    try std.testing.expect(answered(true, "{\n  \"ok\": true,\n  \"result\": {}\n}"));
    try std.testing.expect(!answered(true, "{\"ok\": false, \"error\": {\"code\": \"selector_not_found\"}}"));
    try std.testing.expect(!answered(false, ""));
}
