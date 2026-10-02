//! cmux's side of a new agent's tab (`tabs.zig`). A cmux workspace is a plain
//! folder with its terminals, so there is nothing to register: each agent gets a
//! workspace of its own in its worktree. The workspace's first terminal runs the
//! command, which cmux types into the shell it starts, and `--focus true` brings it
//! forward. cmux only answers processes it started unless Settings > Automation
//! allows others, and the daemon is not one of them. See ADR 0009.
const std = @import("std");
const sys = @import("sys.zig");

/// cmux's CLI, when cmux is installed.
pub fn bin(ctx: sys.Ctx) ?[]const u8 {
    if (ctx.getenv("AGENT_BELT_CMUX_CLI")) |p| if (p.len > 0) return p;
    if (sys.which(ctx, "cmux")) |p| return p;
    const app = "/Applications/cmux.app/Contents/Resources/bin/cmux";
    return if (sys.isFile(ctx, app)) app else null;
}

/// A workspace named `title` whose terminal starts in `dir` and runs `command`.
pub fn createWorkspace(ctx: sys.Ctx, cli_bin: []const u8, dir: []const u8, title: []const u8, command: []const u8) bool {
    const out = sys.run(ctx, &.{ cli_bin, "workspace", "create", "--cwd", dir, "--name", title, "--command", command, "--focus", "true" }, null);
    if (!out.ok) std.debug.print("agb: cmux did not open the workspace: {s}\n", .{std.mem.trim(u8, out.stderr, " \r\n")});
    return out.ok;
}
