//! Orca's side of a new agent's tab (`tabs.zig`). Orca keys a project by the
//! repository's git remote and shows each worktree of a registered repo as a
//! workspace, agb's worktrees included (`--worktree path:<dir>`). A repo Orca does
//! not know yet is registered (`orca repo add`). See ADR 0005.
const std = @import("std");
const sys = @import("sys.zig");

/// Orca's CLI, when Orca is installed.
pub fn bin(ctx: sys.Ctx) ?[]const u8 {
    if (ctx.getenv("AGENT_BELT_ORCA_CLI")) |p| if (p.len > 0) return p;
    if (sys.which(ctx, "orca")) |p| return p;
    const app = "/Applications/Orca.app/Contents/Resources/bin/orca";
    return if (sys.isFile(ctx, app)) app else null;
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
pub fn ensureRegistered(ctx: sys.Ctx, cli_bin: []const u8, root: []const u8) bool {
    const selector = ctx.fmt("path:{s}", .{root}) catch return false;
    if (succeeded(orca(ctx, cli_bin, &.{ "worktree", "show", "--worktree", selector }))) return true;
    return succeeded(orca(ctx, cli_bin, &.{ "repo", "add", "--path", root }));
}

/// A tab in `dir`'s workspace, brought forward. `--focus` on a workspace Orca
/// keeps hidden (its repo hides worktrees it did not create) times out, so the
/// tab is created in the background and switched to. A worktree created a
/// moment ago may not be adopted yet: one more try after a second.
pub fn createTab(ctx: sys.Ctx, cli_bin: []const u8, dir: []const u8, title: []const u8, command: []const u8) bool {
    const selector = ctx.fmt("path:{s}", .{dir}) catch return false;
    // The shell titles the tab with the command it runs: the line names it first.
    const line = titled(ctx, title, command) catch return false;
    var out = orca(ctx, cli_bin, &.{ "terminal", "create", "--worktree", selector, "--title", title, "--command", line });
    if (!succeeded(out)) {
        std.Io.sleep(ctx.io, .fromSeconds(1), .awake) catch {};
        out = orca(ctx, cli_bin, &.{ "terminal", "create", "--worktree", selector, "--title", title, "--command", line });
    }
    const handle = handleOf(ctx.gpa, out.stdout) orelse {
        std.debug.print("agb: Orca did not open the tab: {s}\n", .{std.mem.trim(u8, out.stdout, " \r\n")});
        return false;
    };
    _ = orca(ctx, cli_bin, &.{ "terminal", "switch", "--terminal", handle });
    return true;
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

test "the tab's title line survives a quote and a space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
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
