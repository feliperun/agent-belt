//! What runs on the machine that hosts the session: tmux, worktrees, agents.
//! The same code serves local commands and the `agb _…` calls other machines
//! make over ssh.
const std = @import("std");
const sys = @import("sys.zig");

pub const sep = "|";

/// The harnesses a session can run. DeepSeek Harness installs as `dsh`, the
/// others under their own name.
pub const Agent = enum {
    claude,
    codex,
    deepseek,
    zcode,
    fx,
    shell,

    pub fn program(agent: Agent) []const u8 {
        return if (agent == .deepseek) "dsh" else @tagName(agent);
    }
};

/// Every harness by name, in the order the pickers show them.
pub const agent_names = std.meta.fieldNames(Agent);

pub fn parseAgent(name: []const u8) ?Agent {
    return std.meta.stringToEnum(Agent, name);
}

/// Programs that are a harness when they run in a pane, and the agent each
/// one is listed as (inferred: agb did not start it).
const agent_programs = [_]struct { []const u8, []const u8 }{
    .{ "claude", "claude~" }, .{ "codex", "codex~" }, .{ "zcode", "zcode~" }, .{ "fx", "fx~" }, .{ "dsh", "deepseek~" },
};

// ---------------------------------------------------------------- tmux

/// tmux with arguments. On Windows tmux is an MSYS2 program. What starts the
/// server or a session runs in MSYS2's login bash, so the agents inherit its
/// paths; everything else calls tmux.exe directly: a login bash costs about
/// 2 s there, and the listing every machine polls made a dozen calls.
pub fn tmux(ctx: sys.Ctx, args: []const []const u8) sys.Output {
    if (sys.platform == .windows) {
        const starts = args.len > 0 and (std.mem.eql(u8, args[0], "start-server") or std.mem.eql(u8, args[0], "new-session"));
        if (!starts) return windowsTmux(ctx, args);
        const line = std.mem.concat(ctx.gpa, u8, &.{ "tmux ", sys.shJoin(ctx, args) catch return failed() }) catch return failed();
        return sys.run(ctx, &.{ sys.msys_bash, "-lc", line }, null);
    }
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(ctx.gpa, tmuxBin(ctx)) catch return failed();
    argv.appendSlice(ctx.gpa, args) catch return failed();
    return sys.run(ctx, argv.items, null);
}

/// tmux.exe from a native process. MSYS2 programs glob and brace-expand their
/// command line when a Windows program starts them, which turns every
/// "#{format}" into "#format": MSYS=noglob stops it. Without a UTF-8 locale
/// tmux prints the agents' title glyphs as "_".
fn windowsTmux(ctx: sys.Ctx, args: []const []const u8) sys.Output {
    ctx.env.put("MSYS", "noglob") catch return failed();
    if (ctx.getenv("LANG") == null) ctx.env.put("LANG", "C.UTF-8") catch return failed();
    const argv = std.mem.concat(ctx.gpa, []const u8, &.{ &.{"C:\\msys64\\usr\\bin\\tmux.exe"}, args }) catch return failed();
    return sys.run(ctx, argv, null);
}

/// tmux by full path: a non-interactive ssh session on macOS has no Homebrew on PATH.
fn tmuxBin(ctx: sys.Ctx) []const u8 {
    return sys.which(ctx, "tmux") orelse "tmux";
}

fn failed() sys.Output {
    return .{ .ok = false, .code = 1, .stdout = &.{}, .stderr = &.{} };
}

/// Replaces this process with tmux on the user's terminal (attach, tm).
pub fn tmuxHandOver(ctx: sys.Ctx, args: []const []const u8) noreturn {
    const full = clientArgs(ctx, args) catch unreachable;
    if (sys.platform == .windows) {
        // MSYS2's tmux refuses a native console ("not a terminal"); script(1)
        // gives it a pty, in Windows Terminal and over ssh alike.
        const cmd = std.mem.concat(ctx.gpa, u8, &.{ "tmux ", sys.shJoin(ctx, full) catch unreachable }) catch unreachable;
        const line = std.mem.concat(ctx.gpa, u8, &.{ "exec script -qfc ", sys.shQuote(ctx, cmd) catch unreachable, " /dev/null" }) catch unreachable;
        sys.handOver(ctx, &.{ sys.msys_bash, "-lc", line });
    }
    sys.handOver(ctx, std.mem.concat(ctx.gpa, []const u8, &.{ &.{tmuxBin(ctx)}, full }) catch unreachable);
}

/// A tmux client's arguments. `-u`: the terminal takes UTF-8 even without a
/// locale; an ssh session has no LANG, and tmux would draw every accent and
/// symbol as "_".
fn clientArgs(ctx: sys.Ctx, args: []const []const u8) ![]const []const u8 {
    return std.mem.concat(ctx.gpa, []const u8, &.{ &.{"-u"}, args });
}

/// The target tmux server forwards the clipboard over OSC 52 (remote attaches
/// land here directly) and lets the wheel scroll copy-mode instead of sending
/// arrow keys to the agent's prompt.
pub fn tmuxSetup(ctx: sys.Ctx) void {
    // One tmux call (";" chains commands): on Windows each call is a login shell.
    const features = tmux(ctx, &.{ "set-option", "-g", "set-clipboard", "on", ";", "set-option", "-g", "allow-passthrough", "on", ";", "set-option", "-g", "mouse", "on", ";", "show-options", "-gqv", "terminal-features" });
    if (features.ok and std.mem.indexOf(u8, features.stdout, "*:clipboard") == null)
        _ = tmux(ctx, &.{ "set-option", "-as", "terminal-features", ",*:clipboard" });
}

pub fn hasSession(ctx: sys.Ctx, name: []const u8) bool {
    if (!sys.validTarget(name)) return false;
    return tmux(ctx, &.{ "has-session", "-t", ctx.fmt("={s}", .{name}) catch return false }).ok;
}

// ---------------------------------------------------------------- repos

pub fn reposDir(ctx: sys.Ctx) ![]const u8 {
    if (ctx.getenv("WORK_REPOS_DIR")) |d| return d;
    if (sys.platform == .windows) return "C:\\dev";
    return ctx.join(&.{ ctx.home(), "dev" });
}

/// Where repositories live on this machine: the paths listed in
/// ~/.config/agent-belt/repo-roots (one per line, ~ for home), or else the
/// repos directory and ~/dev. Anything else is named in repo-roots.
pub fn repoRoots(ctx: sys.Ctx) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    const config = try ctx.join(&.{ ctx.home(), ".config", "agent-belt", "repo-roots" });
    if (sys.readFile(ctx, config)) |text| {
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            try roots.append(ctx.gpa, if (std.mem.startsWith(u8, line, "~")) try std.mem.concat(ctx.gpa, u8, &.{ ctx.home(), line[1..] }) else line);
        }
        if (roots.items.len > 0) return roots.items;
    }
    try roots.append(ctx.gpa, try reposDir(ctx));
    if (sys.platform != .windows) try roots.append(ctx.gpa, try ctx.join(&.{ ctx.home(), "dev" }));
    return roots.items;
}

pub const Repo = struct { name: []const u8, path: []const u8 };

/// Git repositories under the repo roots: directly inside one, or one folder
/// down, where people group them by owner or client (~/dev/work/api). The
/// first repository with a name wins.
pub fn findRepos(ctx: sys.Ctx) ![]Repo {
    var repos: std.ArrayList(Repo) = .empty;
    for (try repoRoots(ctx)) |root| try scanRepos(ctx, root, 2, &repos);
    std.mem.sort(Repo, repos.items, {}, byName);
    return repos.items;
}

fn scanRepos(ctx: sys.Ctx, path: []const u8, depth: u8, repos: *std.ArrayList(Repo)) !void {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (entry.name[0] == '.') continue;
        const child = try ctx.join(&.{ path, entry.name });
        const git = try ctx.join(&.{ child, ".git" });
        // A directory .git: a repository. A worktree (a session's) has a .git file.
        if (sys.isDir(ctx, git)) {
            for (repos.items) |r| {
                if (std.mem.eql(u8, r.name, entry.name)) break;
            } else try repos.append(ctx.gpa, .{ .name = try ctx.gpa.dupe(u8, entry.name), .path = child });
        } else if (depth > 1 and !sys.exists(ctx, git)) try scanRepos(ctx, child, depth - 1, repos);
    }
}

fn byName(_: void, a: Repo, b: Repo) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The names `agb new` accepts as a repo on this machine.
pub fn listRepos(ctx: sys.Ctx) ![]const []const u8 {
    const repos = try findRepos(ctx);
    const names = try ctx.gpa.alloc([]const u8, repos.len);
    for (repos, names) |r, *n| n.* = r.name;
    return names;
}

fn gitBin(ctx: sys.Ctx) []const u8 {
    return sys.which(ctx, "git") orelse "git";
}

fn gitTop(ctx: sys.Ctx, path: []const u8) ?[]const u8 {
    const out = sys.run(ctx, &.{ gitBin(ctx), "-C", path, "rev-parse", "--show-toplevel" }, null);
    return if (out.ok) out.text() else null;
}

fn gitCommon(ctx: sys.Ctx, path: []const u8) ?[]const u8 {
    const out = sys.run(ctx, &.{ gitBin(ctx), "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir" }, null);
    return if (out.ok) out.text() else null;
}

/// A repository argument as a path, or a name under the repos directories.
pub fn resolveRepo(ctx: sys.Ctx, arg: []const u8) !?[]const u8 {
    const as_path = if (sys.platform == .windows) try sys.fromMsys(ctx, arg) else arg;
    if (gitTop(ctx, as_path)) |top| return top;
    for (try repoRoots(ctx)) |root| if (gitTop(ctx, try ctx.join(&.{ root, arg }))) |top| return top;
    for (try findRepos(ctx)) |r| if (std.mem.eql(u8, r.name, arg)) return r.path;
    return null;
}

// ---------------------------------------------------------------- trust

/// Worktrees are new directories, and agents stop at a trust dialog waiting for
/// Enter — which defeats an autonomous session. The repo was chosen by the
/// user, so its worktree starts trusted. WORK_NO_AUTOTRUST=1 turns this off.
fn trustClaude(ctx: sys.Ctx, dir: []const u8) void {
    // Claude Code keys projects by path with forward slashes, on Windows too
    // ("C:/Users/…"): a backslash key is never matched and the trust dialog waits.
    const project = if (sys.platform == .windows) (std.mem.replaceOwned(u8, ctx.gpa, dir, "\\", "/") catch return) else dir;
    const file = ctx.join(&.{ ctx.home(), ".claude.json" }) catch return;
    const bytes = sys.readFile(ctx, file) orelse return;
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, bytes, .{}) catch return;
    if (parsed.value != .object) return;
    const backup = ctx.fmt("{s}.pre-agb.bak", .{file}) catch return;
    if (!sys.exists(ctx, backup)) sys.writeFileAtomic(ctx, backup, bytes) catch return;
    const root = &parsed.value.object;
    const projects = root.getOrPut(ctx.gpa, "projects") catch return;
    if (!projects.found_existing or projects.value_ptr.* != .object)
        projects.value_ptr.* = .{ .object = .empty };
    const entry = projects.value_ptr.object.getOrPut(ctx.gpa, project) catch return;
    if (!entry.found_existing or entry.value_ptr.* != .object) entry.value_ptr.* = .{ .object = .empty };
    entry.value_ptr.object.put(ctx.gpa, "hasTrustDialogAccepted", .{ .bool = true }) catch return;
    const out = std.json.Stringify.valueAlloc(ctx.gpa, parsed.value, .{ .whitespace = .indent_2 }) catch return;
    sys.writeFileAtomic(ctx, file, out) catch {};
}

/// A path inside a TOML basic string. A Windows path is all backslashes (an
/// invalid escape that makes Codex reject its own config), and a quote or a
/// newline in a directory name would close the key and let the rest of the path
/// open a table of its own — trusting a directory nobody chose.
fn tomlQuote(ctx: sys.Ctx, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(ctx.gpa, "\\\""),
        '\\' => try out.appendSlice(ctx.gpa, "\\\\"),
        '\n' => try out.appendSlice(ctx.gpa, "\\n"),
        '\r' => try out.appendSlice(ctx.gpa, "\\r"),
        '\t' => try out.appendSlice(ctx.gpa, "\\t"),
        else => try out.append(ctx.gpa, c),
    };
    return out.items;
}

fn trustCodex(ctx: sys.Ctx, project: []const u8) void {
    const codex_home = ctx.getenv("CODEX_HOME") orelse (ctx.join(&.{ ctx.home(), ".codex" }) catch return);
    if (!sys.isDir(ctx, codex_home)) return;
    const file = ctx.join(&.{ codex_home, "config.toml" }) catch return;
    const current = sys.readFile(ctx, file) orelse "";
    const section = ctx.fmt("[projects.\"{s}\"]", .{tomlQuote(ctx, project) catch return}) catch return;
    if (std.mem.indexOf(u8, current, section) != null) return;
    const backup = ctx.fmt("{s}.pre-agb.bak", .{file}) catch return;
    if (!sys.exists(ctx, backup)) sys.writeFileAtomic(ctx, backup, current) catch return;
    const next = ctx.fmt("{s}\n{s}\ntrust_level = \"trusted\"\n", .{ current, section }) catch return;
    sys.writeFileAtomic(ctx, file, next) catch {};
}

// ---------------------------------------------------------------- create

pub const CreateOptions = struct {
    task: []const u8,
    repo: ?[]const u8,
    agent: Agent = .claude,
    prompt: ?[]const u8 = null,
    detach_others: bool = false,
    /// Create and return the session name instead of attaching (orchestrators, scripts).
    no_attach: bool = false,
};

/// Finds the tmux session of a task: the @work_task mark first (the name may
/// have followed the agent's rename), then a name ending in -<task>.
pub fn findTaskSession(ctx: sys.Ctx, task: []const u8) ?[]const u8 {
    const out = tmux(ctx, &.{ "list-sessions", "-F", "#{session_name}|#{?@work_task,#{@work_task},}" });
    if (!out.ok) return null;
    var fallback: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const bar = std.mem.indexOfScalar(u8, line, '|') orelse continue;
        const name = line[0..bar];
        if (std.mem.eql(u8, line[bar + 1 ..], task)) return name;
        if (fallback == null and (std.mem.eql(u8, name, task) or (std.mem.endsWith(u8, name, task) and name.len > task.len and name[name.len - task.len - 1] == '-')))
            fallback = name;
    }
    return fallback;
}

fn claudeConversationExists(ctx: sys.Ctx, path: []const u8) bool {
    const native = if (sys.platform == .windows) (std.mem.replaceOwned(u8, ctx.gpa, path, "/", "\\") catch return false) else path;
    const slug = ctx.gpa.dupe(u8, native) catch return false;
    for (slug) |*c| if (std.mem.indexOfScalar(u8, "/\\:. ", c.*) != null) {
        c.* = '-';
    };
    const dir = ctx.join(&.{ ctx.home(), ".claude", "projects", slug }) catch return false;
    var d = std.Io.Dir.cwd().openDir(ctx.io, dir, .{ .iterate = true }) catch return false;
    defer d.close(ctx.io);
    var it = d.iterate();
    while (it.next(ctx.io) catch null) |entry| if (std.mem.endsWith(u8, entry.name, ".jsonl")) return true;
    return false;
}

/// What starts the agent, and the file with a first prompt tmux must type
/// into it (a harness that takes none on its command line).
const Launch = struct { command: []const u8, typed_prompt: ?[]const u8 = null };

/// This machine's shell, as tmux hands a line to /bin/sh: $SHELL is a path.
fn loginShell(ctx: sys.Ctx) ![]const u8 {
    return if (sys.platform == .windows) "bash -l" else sys.shQuote(ctx, ctx.getenv("SHELL") orelse "/bin/sh");
}

fn agentCommand(ctx: sys.Ctx, opts: CreateOptions, worktree: []const u8) !Launch {
    if (opts.agent == .shell) return .{ .command = try loginShell(ctx) };
    const bin = sys.which(ctx, opts.agent.program()) orelse return error.AgentNotFound;
    // The first instruction becomes the agent's first prompt. It goes through a
    // file: tmux caps a command at 16 KB, and a long spoken request is longer.
    const prompt_file: ?[]const u8 = if (opts.prompt) |p| (if (p.len > 0) try promptFile(ctx, opts.task, p) else null) else null;
    var cmd: std.ArrayList(u8) = .empty;
    if (sys.platform == .windows) try cmd.appendSlice(ctx.gpa, "winpty ");
    try cmd.appendSlice(ctx.gpa, try sys.shQuote(ctx, if (sys.platform == .windows) try sys.toMsys(ctx, bin) else bin));
    switch (opts.agent) {
        .claude => {
            try cmd.appendSlice(ctx.gpa, " --dangerously-skip-permissions");
            // A worktree that had a conversation continues it: a dead tmux
            // session should not mean starting over. WORK_NEW=1 forces a new one.
            const fresh = if (ctx.getenv("WORK_NEW")) |v| std.mem.eql(u8, v, "1") else false;
            if (!fresh and claudeConversationExists(ctx, worktree))
                try cmd.appendSlice(ctx.gpa, " --continue")
            else
                try cmd.appendSlice(ctx.gpa, try ctx.fmt(" --name {s}", .{try sys.shQuote(ctx, opts.task)}));
        },
        .codex => try cmd.appendSlice(ctx.gpa, " --dangerously-bypass-approvals-and-sandbox"),
        // DeepSeek Harness has no terminal UI: it answers one task headless, and
        // the pane keeps a shell to go on from there.
        .deepseek => try cmd.appendSlice(ctx.gpa, " --profile headless"),
        .zcode, .fx => return .{ .command = cmd.items, .typed_prompt = prompt_file },
        .shell => unreachable,
    }
    if (prompt_file) |file| {
        const shown = if (sys.platform == .windows) try sys.toMsys(ctx, file) else file;
        try cmd.appendSlice(ctx.gpa, try ctx.fmt(" \"$(cat {s})\"", .{try sys.shQuote(ctx, shown)}));
    } else if (opts.agent == .deepseek) return error.PromptRequired;
    if (opts.agent == .deepseek) try cmd.appendSlice(ctx.gpa, try ctx.fmt("; exec {s}", .{try loginShell(ctx)}));
    return .{ .command = cmd.items };
}

/// A spoken request is private: the file is the owner's, and so is the
/// directory, whose entries are the task names.
fn promptFile(ctx: sys.Ctx, task: []const u8, prompt: []const u8) ![]const u8 {
    const dir = try ctx.join(&.{ ctx.home(), ".cache", "agent-belt", "prompts" });
    sys.createPrivateDir(ctx.io, dir) catch {};
    const file = try ctx.join(&.{ dir, try ctx.fmt("{s}.txt", .{task}) });
    sys.writeFileAtomic(ctx, file, prompt) catch return error.WorktreeFailed;
    return file;
}

/// zcode and fx take no first prompt on their command line: tmux types it
/// once the program has drawn its screen (the same screen twice, half a second
/// apart; at most 20 s). In tmux's background, so attaching does not wait.
fn typePrompt(ctx: sys.Ctx, session_id: []const u8, task: []const u8, file: []const u8) void {
    const t = sys.shQuote(ctx, ctx.fmt("{s}:", .{session_id}) catch return) catch return;
    const tm = sys.shQuote(ctx, if (sys.platform == .windows) "tmux" else tmuxBin(ctx)) catch return;
    const f = sys.shQuote(ctx, if (sys.platform == .windows) (sys.toMsys(ctx, file) catch return) else file) catch return;
    const buffer = sys.shQuote(ctx, ctx.fmt("agb-prompt-{s}", .{task}) catch return) catch return;
    const script = ctx.fmt("i=0; last=; while [ $i -lt 40 ]; do sleep 0.5; now=$({0s} capture-pane -p -t {1s}); " ++
        "[ -n \"$now\" ] && [ \"$now\" = \"$last\" ] && [ $i -ge 3 ] && break; last=$now; i=$((i+1)); done; " ++
        "{0s} load-buffer -b {3s} {2s} && {0s} paste-buffer -p -d -b {3s} -t {1s} && sleep 0.3 && {0s} send-keys -t {1s} Enter", .{ tm, t, f, buffer }) catch return;
    _ = tmux(ctx, &.{ "run-shell", "-b", script });
}

pub const CreateError = error{ NotARepo, WorktreeClash, WorktreeFailed, TmuxFailed, AgentNotFound, PromptRequired, InvalidTask, InvalidTarget } || std.mem.Allocator.Error;

/// Creates (or reuses) the task's session and attaches this terminal to it, or,
/// with no_attach, returns its name.
pub fn create(ctx: sys.Ctx, opts: CreateOptions) CreateError![]const u8 {
    if (!sys.validSlug(opts.task)) return error.InvalidTask;
    if (findTaskSession(ctx, opts.task)) |name| {
        tmuxSetup(ctx);
        // A new request for an agent that already exists is typed into it.
        if (opts.prompt) |p| if (p.len > 0) {
            _ = send(ctx, name, p);
        };
        if (opts.no_attach) return name;
        attach(ctx, name, opts.detach_others);
    }
    // No repo (research, a first sketch): a plain directory ~/agents/<task>,
    // kept after the session so what the agent wrote can be found.
    const repo_arg = opts.repo orelse {
        const workdir = try ctx.join(&.{ agentsDir(ctx), opts.task });
        std.Io.Dir.cwd().createDirPath(ctx.io, workdir) catch return error.WorktreeFailed;
        return startAgent(ctx, opts, opts.task, workdir);
    };
    const repo_root = (resolveRepo(ctx, repo_arg) catch null) orelse return error.NotARepo;
    const repo_name = std.fs.path.basename(repo_root);
    const worktree = try ctx.fmt("{s}-{s}", .{ repo_root, opts.task });
    const branch = try ctx.fmt("work/{s}", .{opts.task});
    const session = try ctx.fmt("{s}-{s}", .{ repo_name, opts.task });

    // <repo>-<task> can clash with a real neighbouring repo: reuse an existing
    // directory only when it is a worktree of this repo.
    if (sys.exists(ctx, worktree)) {
        const a = gitCommon(ctx, worktree) orelse "";
        const b = gitCommon(ctx, repo_root) orelse "-";
        if (!std.mem.eql(u8, a, b)) return error.WorktreeClash;
    } else {
        const has_branch = sys.run(ctx, &.{ gitBin(ctx), "-C", repo_root, "show-ref", "--verify", "--quiet", try ctx.fmt("refs/heads/{s}", .{branch}) }, null).ok;
        const out = if (has_branch)
            sys.run(ctx, &.{ gitBin(ctx), "-C", repo_root, "worktree", "add", worktree, branch }, null)
        else
            sys.run(ctx, &.{ gitBin(ctx), "-C", repo_root, "worktree", "add", worktree, "-b", branch }, null);
        if (!out.ok) {
            std.debug.print("{s}", .{out.stderr});
            return error.WorktreeFailed;
        }
    }

    return startAgent(ctx, opts, session, worktree);
}

/// Where agents without a repo work: ~/agents.
pub fn agentsDir(ctx: sys.Ctx) []const u8 {
    return ctx.join(&.{ ctx.home(), "agents" }) catch "agents";
}

/// Starts the agent in `dir` as tmux session `session`, then attaches (or
/// returns the name with no_attach).
fn startAgent(ctx: sys.Ctx, opts: CreateOptions, session: []const u8, dir: []const u8) CreateError![]const u8 {
    const worktree = dir;
    const no_trust = if (ctx.getenv("WORK_NO_AUTOTRUST")) |v| std.mem.eql(u8, v, "1") else false;
    if (!no_trust) switch (opts.agent) {
        .claude => trustClaude(ctx, worktree),
        .codex => trustCodex(ctx, worktree),
        .deepseek, .zcode, .fx, .shell => {},
    };

    const launch = try agentCommand(ctx, opts, worktree);
    const cwd = if (sys.platform == .windows) try sys.toMsys(ctx, worktree) else worktree;
    // Start the server first, detached from this process's descriptors: on
    // Windows it would otherwise die with the console that created it.
    _ = tmux(ctx, &.{"start-server"});
    // The session and its marks in one tmux call: a listing in between (another
    // machine's `agb ls`) would otherwise rename it from the agent's title
    // before it knows its task. Printed back: the session id, which survives
    // renames, so attaching cannot miss it.
    const target = try paneTarget(ctx, session); // set-option takes a pane target on tmux 3.5+
    const made = tmux(ctx, &.{ "new-session", "-d", "-P", "-F", "#{session_id}", "-s", session, "-c", cwd, launch.command, ";", "set-option", "-t", target, "@work_agent", @tagName(opts.agent), ";", "set-option", "-t", target, "@work_task", opts.task });
    const id = std.mem.trim(u8, made.stdout, " \r\n");
    if (!made.ok or id.len == 0 or id[0] != '$') {
        std.debug.print("{s}", .{made.stderr});
        return error.TmuxFailed;
    }
    if (launch.typed_prompt) |file| typePrompt(ctx, id, opts.task, file);
    tmuxSetup(ctx);
    if (opts.no_attach) return session;
    attachTarget(ctx, id, opts.detach_others);
}

/// A pane target for a session: "=name:" (its current window). Plain "=name"
/// is a session target that pane commands reject on tmux 3.5. A name holding
/// ":" would name a different session, so it is not a target at all.
fn paneTarget(ctx: sys.Ctx, name: []const u8) ![]const u8 {
    if (!sys.validTarget(name)) return error.InvalidTarget;
    return ctx.fmt("={s}:", .{name});
}

/// Types text into a session's agent and presses Enter.
pub fn send(ctx: sys.Ctx, name: []const u8, text: []const u8) bool {
    const target = paneTarget(ctx, name) catch return false;
    if (!tmux(ctx, &.{ "send-keys", "-t", target, "-l", "--", text }).ok) return false;
    return tmux(ctx, &.{ "send-keys", "-t", target, "Enter" }).ok;
}

/// The last `lines` lines of a session's screen and scrollback.
pub fn peek(ctx: sys.Ctx, name: []const u8, lines: usize) ?[]const u8 {
    const target = paneTarget(ctx, name) catch return null;
    const out = tmux(ctx, &.{ "capture-pane", "-p", "-J", "-t", target, "-S", ctx.fmt("-{d}", .{lines}) catch return null });
    if (!out.ok) return null;
    // The screen below the prompt is empty lines: drop them, keep a final newline.
    const trimmed = std.mem.trimEnd(u8, out.stdout, " \r\n\t");
    return ctx.fmt("{s}\n", .{trimmed}) catch null;
}

pub fn stop(ctx: sys.Ctx, name: []const u8) bool {
    if (!sys.validTarget(name)) return false;
    return tmux(ctx, &.{ "kill-session", "-t", ctx.fmt("={s}", .{name}) catch return false }).ok;
}

/// Windows: an ssh connection that drops leaves its tmux client attached (its
/// script(1) parent dies, the client does not). tmux keeps drawing for every
/// one of them, each at its own size, and the window flickers between sizes.
/// A client whose parent process is gone is detached.
fn dropOrphanClients(ctx: sys.Ctx) void {
    const clients = tmux(ctx, &.{ "list-clients", "-F", "#{client_pid} #{client_tty}" });
    if (!clients.ok or clients.stdout.len == 0) return;
    const ps = sys.run(ctx, &.{ "C:\\msys64\\usr\\bin\\ps.exe", "-e" }, null);
    if (!ps.ok) return;
    for (orphanTtys(ctx.gpa, clients.stdout, ps.stdout) catch return) |tty| _ = tmux(ctx, &.{ "detach-client", "-t", tty });
}

/// The ttys of clients (`pid tty` lines) whose parent is not in MSYS2's
/// `ps -e` (PID PPID … columns).
fn orphanTtys(gpa: std.mem.Allocator, clients: []const u8, ps: []const u8) ![]const []const u8 {
    var ttys: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, clients, '\n');
    while (it.next()) |raw| {
        var words = std.mem.tokenizeAny(u8, raw, " \r");
        const pid = words.next() orelse continue;
        const tty = words.next() orelse continue;
        var parent: ?[]const u8 = null;
        var rows = std.mem.splitScalar(u8, ps, '\n');
        while (rows.next()) |row| {
            var cols = std.mem.tokenizeAny(u8, row, " \r");
            if (std.mem.eql(u8, cols.next() orelse continue, pid)) parent = cols.next();
        }
        const ppid = parent orelse continue; // not in the listing: leave it alone
        var alive = false;
        rows = std.mem.splitScalar(u8, ps, '\n');
        while (rows.next()) |row| {
            var cols = std.mem.tokenizeAny(u8, row, " \r");
            if (std.mem.eql(u8, cols.next() orelse continue, ppid)) alive = true;
        }
        if (!alive) try ttys.append(gpa, tty);
    }
    return ttys.toOwnedSlice(gpa);
}

/// Attaches this terminal to a local session (switching client inside tmux).
pub fn attach(ctx: sys.Ctx, name: []const u8, detach_others: bool) noreturn {
    if (!hasSession(ctx, name)) {
        std.debug.print("agb: no session '{s}' on this machine\n", .{name});
        std.process.exit(1);
    }
    tmuxSetup(ctx);
    attachTarget(ctx, ctx.fmt("={s}", .{name}) catch unreachable, detach_others);
}

/// Attaches to a tmux target: "=name" or a session id ("$3").
fn attachTarget(ctx: sys.Ctx, target: []const u8, detach_others: bool) noreturn {
    if (ctx.getenv("TMUX") != null) tmuxHandOver(ctx, &.{ "switch-client", "-t", target });
    // -d detaches other clients: with two, tmux shrinks the window to the smaller one.
    if (detach_others) tmuxHandOver(ctx, &.{ "attach", "-d", "-t", target });
    tmuxHandOver(ctx, &.{ "attach", "-t", target });
}

// ---------------------------------------------------------------- listing

/// The agent in a session agb did not create: the pane's foreground process.
/// Claude's binary is versioned and shows up as "2.1.269", so look at args.
fn inferAgent(ctx: sys.Ctx, tty: []const u8, command: []const u8) []const u8 {
    if (sys.platform != .windows and tty.len > 0) {
        const t = if (std.mem.startsWith(u8, tty, "/dev/")) tty[5..] else tty;
        const out = sys.run(ctx, &.{ "ps", "-t", t, "-o", "args=" }, null);
        for (agent_programs) |a| if (hasWord(out.stdout, a[0])) return a[1];
    }
    const shells = [_][]const u8{ "bash", "zsh", "sh", "fish", "pwsh", "powershell" };
    for (shells) |s| if (std.mem.eql(u8, command, s)) return "shell";
    if (std.mem.eql(u8, command, "winpty")) return "claude~";
    for (agent_programs) |a| if (std.mem.eql(u8, command, a[0])) return a[1];
    return if (command.len == 0) "-" else command;
}

/// Is `word` a whole path/command word in `text` ("…/bin/claude --x", "claude")?
fn hasWord(text: []const u8, word: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, word)) |i| {
        const before_ok = i == 0 or text[i - 1] == ' ' or text[i - 1] == '/' or text[i - 1] == '\n';
        const after = i + word.len;
        const after_ok = after == text.len or text[after] == ' ' or text[after] == '\n';
        if (before_ok and after_ok) return true;
        start = i + 1;
    }
    return false;
}

/// Renaming the conversation in the agent renames the tmux session: the agent
/// publishes its name as the terminal title, which tmux keeps as pane_title.
/// The repo prefix stays ("web-app-xpto" renamed to "bug" becomes "web-app-bug").
/// A session name from an agent's terminal title: without the console's
/// prefix (an elevated Windows console shows "Administrador: …") and the
/// agent's status glyph, accents folded ("custódia" is "custodia"), words
/// joined by dashes.
pub fn sessionSlug(ctx: sys.Ctx, raw: []const u8) ![]const u8 {
    var title = std.mem.trim(u8, raw, " ");
    for ([_][]const u8{ "Administrador: ", "Administrator: ", "Administrador:", "Administrator:" }) |prefix| {
        if (std.mem.startsWith(u8, title, prefix)) title = title[prefix.len..];
    }
    const folds = [_]struct { []const u8, u8 }{
        .{ "á", 'a' }, .{ "à", 'a' }, .{ "â", 'a' }, .{ "ã", 'a' }, .{ "ä", 'a' }, .{ "é", 'e' }, .{ "ê", 'e' }, .{ "è", 'e' },
        .{ "í", 'i' }, .{ "ó", 'o' }, .{ "ô", 'o' }, .{ "õ", 'o' }, .{ "ö", 'o' }, .{ "ú", 'u' }, .{ "ü", 'u' }, .{ "ç", 'c' },
        .{ "ñ", 'n' }, .{ "Á", 'A' }, .{ "À", 'A' }, .{ "Â", 'A' }, .{ "Ã", 'A' }, .{ "É", 'E' }, .{ "Ê", 'E' }, .{ "Í", 'I' },
        .{ "Ó", 'O' }, .{ "Ô", 'O' }, .{ "Õ", 'O' }, .{ "Ú", 'U' }, .{ "Ç", 'C' },
    };
    var name: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < title.len) {
        for (folds) |f| if (std.mem.startsWith(u8, title[i..], f[0])) {
            try name.append(ctx.gpa, f[1]);
            i += f[0].len;
            continue :outer;
        };
        const c = title[i];
        i += 1;
        if (std.ascii.isAlphanumeric(c)) {
            try name.append(ctx.gpa, c);
        } else if ((c == ' ' or c == '-' or c == '_') and name.items.len > 0 and name.items[name.items.len - 1] != '-') {
            try name.append(ctx.gpa, '-');
        }
        // Anything else (status glyphs, punctuation) is dropped.
    }
    return std.mem.trim(u8, name.items, "-");
}

fn syncName(ctx: sys.Ctx, session: []const u8, agent: []const u8, task: []const u8, title: []const u8) ?[]const u8 {
    if (ctx.getenv("WORK_NO_RENAME")) |v| if (std.mem.eql(u8, v, "1")) return null;
    if (!(std.mem.startsWith(u8, agent, "claude") or std.mem.startsWith(u8, agent, "codex"))) return null;
    var slug = sessionSlug(ctx, title) catch return null;
    // A title that names the program, not the work ("claude" before the
    // conversation has a name, a shell): nothing to rename to.
    for ([_][]const u8{ "claude", "codex", "Claude-Code", "claude-code", "bash", "zsh", "sh", "fish", "pwsh", "winpty", "tmux" }) |generic| {
        if (std.ascii.eqlIgnoreCase(slug, generic)) return null;
    }
    if (slug.len > 40) slug = slug[0..40];
    if (slug.len == 0 or std.mem.eql(u8, slug, task) or std.mem.eql(u8, slug, session)) return null;
    var next: []const u8 = slug;
    if (task.len > 0 and std.mem.endsWith(u8, session, task) and session.len > task.len + 1)
        next = ctx.fmt("{s}-{s}", .{ session[0 .. session.len - task.len - 1], slug }) catch return null;
    if (std.mem.eql(u8, next, session) or hasSession(ctx, next)) return null;
    // Old sessions have no @work_task: record the current name so `agb new
    // <old-name>` still finds it after the rename.
    if (task.len == 0) _ = tmux(ctx, &.{ "set-option", "-t", session, "@work_task", session });
    if (!tmux(ctx, &.{ "rename-session", "-t", ctx.fmt("={s}", .{session}) catch return null, next }).ok) return null;
    return next;
}

/// Terminals running an agent outside tmux (they cannot be attached). Counted
/// per tty: an agent spawns many child processes.
fn agentsOutside(ctx: sys.Ctx) usize {
    if (sys.platform == .windows) {
        const panes = tmux(ctx, &.{ "list-panes", "-a", "-F", "#{pane_current_command}" });
        var inside: usize = 0;
        var it = std.mem.splitScalar(u8, panes.stdout, '\n');
        while (it.next()) |c| {
            const cmd = std.mem.trimEnd(u8, c, "\r");
            if (std.mem.eql(u8, cmd, "winpty") or isAgentCommand(cmd)) inside += 1;
        }
        const total = windowsAgentCount();
        return if (total > inside) total - inside else 0;
    }
    return posixOutside(ctx).len;
}

pub const Loose = struct { pid: []const u8, tty: []const u8, args: []const u8 };

fn normTty(t: []const u8) []const u8 {
    var s = t;
    if (std.mem.startsWith(u8, s, "/dev/")) s = s[5..];
    if (std.mem.startsWith(u8, s, "tty")) s = s[3..];
    return s;
}

/// Agent processes with a terminal that no tmux pane owns. Claude Code's own
/// background workers (bg-spare, versioned binaries) are nobody's session.
/// The process is the agent itself, not a program that mentions one
/// (`agb new --agent claude …`, an ssh carrying it).
fn isAgentCommand(args: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const exe = std.fs.path.basename(words.next() orelse return false);
    const node = std.mem.eql(u8, exe, "node");
    for (agent_programs) |a| if (std.mem.eql(u8, exe, a[0]) or (node and hasWord(args, a[0]))) return true;
    return false;
}

fn posixOutside(ctx: sys.Ctx) []Loose {
    var result: std.ArrayList(Loose) = .empty;
    const panes = tmux(ctx, &.{ "list-panes", "-a", "-F", "#{pane_tty}" });
    const ps = sys.run(ctx, &.{ "ps", "axo", "pid=,tty=,args=" }, null);
    var seen: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, ps.stdout, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const pid = words.next() orelse continue;
        const tty = words.next() orelse continue;
        const args = std.mem.trim(u8, words.rest(), " ");
        if (std.mem.eql(u8, tty, "??") or std.mem.eql(u8, tty, "?")) continue;
        if (std.mem.indexOf(u8, args, "bg-spare") != null or std.mem.indexOf(u8, args, "/versions/") != null) continue;
        if (!isAgentCommand(args)) continue;
        const t = normTty(tty);
        var owned = false;
        var p = std.mem.splitScalar(u8, panes.stdout, '\n');
        while (p.next()) |pane| if (std.mem.eql(u8, normTty(std.mem.trimEnd(u8, pane, "\r")), t)) {
            owned = true;
        };
        if (owned) continue;
        var dup = false;
        for (seen.items) |s| if (std.mem.eql(u8, s, t)) {
            dup = true;
        };
        if (dup) continue;
        seen.append(ctx.gpa, t) catch {};
        result.append(ctx.gpa, .{ .pid = pid, .tty = t, .args = args }) catch {};
    }
    return result.items;
}

/// Harness processes on this Windows machine, from a process snapshot (a
/// `tasklist` per image took 2 s each).
fn windowsAgentCount() usize {
    if (sys.platform != .windows) return 0;
    const snapshot = win.CreateToolhelp32Snapshot(2, 0); // TH32CS_SNAPPROCESS
    if (@intFromPtr(snapshot) == std.math.maxInt(usize)) return 0; // INVALID_HANDLE_VALUE
    defer _ = win.CloseHandle(snapshot);
    var entry: win.PROCESSENTRY32W = .{};
    var count: usize = 0;
    var more = win.Process32FirstW(snapshot, &entry) != 0;
    while (more) : (more = win.Process32NextW(snapshot, &entry) != 0) {
        const name = std.mem.sliceTo(&entry.szExeFile, 0);
        for ([_][]const u8{ "claude.exe", "codex.exe", "zcode.exe", "fx.exe" }) |image| {
            if (name.len == image.len and for (name, image) |c, i| {
                if (std.ascii.toLower(@truncate(c)) != i) break false;
            } else true) count += 1;
        }
    }
    return count;
}

const win = struct {
    const PROCESSENTRY32W = extern struct {
        dwSize: u32 = @sizeOf(PROCESSENTRY32W),
        cntUsage: u32 = 0,
        th32ProcessID: u32 = 0,
        th32DefaultHeapID: usize = 0,
        th32ModuleID: u32 = 0,
        cntThreads: u32 = 0,
        th32ParentProcessID: u32 = 0,
        pcPriClassBase: i32 = 0,
        dwFlags: u32 = 0,
        szExeFile: [260]u16 = .{0} ** 260,
    };
    extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) *anyopaque;
    extern "kernel32" fn Process32FirstW(snapshot: *anyopaque, entry: *PROCESSENTRY32W) callconv(.winapi) c_int;
    extern "kernel32" fn Process32NextW(snapshot: *anyopaque, entry: *PROCESSENTRY32W) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) c_int;
};

/// A value inside the "|"-separated answer. tmux allows "|" in a session name
/// and a path can hold anything: unescaped, one such session shifts every column
/// for the machine reading the answer, so its rows name the wrong session.
fn field(ctx: sys.Ctx, value: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, value, "|\r\n") == null) return value;
    const copy = try ctx.gpa.dupe(u8, value);
    for (copy) |*c| if (c.* == '|' or c.* == '\r' or c.* == '\n') {
        c.* = ' ';
    };
    return copy;
}

/// `agb _ls-raw`: one line per session, name|windows|created|attached|agent|path,
/// then #outside|<count>, which also marks the answer as complete.
pub fn lsRaw(ctx: sys.Ctx) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (sys.platform == .windows) dropOrphanClients(ctx);
    const fields = "#{session_name}|#{session_windows}|#{session_created}|#{?session_attached,1,0}|#{?@work_agent,#{@work_agent},}|#{session_path}|#{pane_tty}|#{pane_current_command}|#{?@work_task,#{@work_task},}|#{pane_title}";
    const list = tmux(ctx, &.{ "list-sessions", "-F", fields });
    var lines = std.mem.splitScalar(u8, list.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        var f = std.mem.splitScalar(u8, line, '|');
        var name = f.next() orelse continue;
        if (name.len == 0) continue;
        const windows = f.next() orelse "";
        const created = f.next() orelse "";
        const attached = f.next() orelse "0";
        var agent = f.next() orelse "";
        const path = f.next() orelse "";
        const tty = f.next() orelse "";
        const command = f.next() orelse "";
        const task = f.next() orelse "";
        const title = f.rest();
        if (agent.len == 0) agent = inferAgent(ctx, tty, command);
        if (syncName(ctx, name, agent, task, title)) |renamed| name = renamed;
        try out.appendSlice(ctx.gpa, try ctx.fmt("{s}|{s}|{s}|{s}|{s}|{s}\n", .{ try field(ctx, name), windows, created, attached, agent, try field(ctx, path) }));
    }
    try out.appendSlice(ctx.gpa, try ctx.fmt("#outside|{d}\n", .{agentsOutside(ctx)}));
    return out.items;
}

// ---------------------------------------------------------------- adoption

/// An agent started outside tmux cannot be attached, but its conversation lives
/// on disk: stop the process and reopen the same conversation inside tmux.
pub const Adoptable = struct { pid: []const u8, agent: []const u8, dir: []const u8, conversation: []const u8 };

fn processCwd(ctx: sys.Ctx, pid: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const link = ctx.fmt("/proc/{s}/cwd", .{pid}) catch return null;
    if (std.Io.Dir.cwd().readLink(ctx.io, link, &buf)) |n| return ctx.gpa.dupe(u8, buf[0..n]) catch null else |_| {}
    const out = sys.run(ctx, &.{ "lsof", "-a", "-d", "cwd", "-p", pid, "-Fn" }, null);
    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "n")) return line[1..];
    return null;
}

/// --resume <id> / --session-id <id> in the process arguments names the exact
/// conversation (a name, as in `--resume fx-deepseek`, does not).
fn conversationId(args: []const u8) []const u8 {
    for ([_][]const u8{ "--resume ", "--resume=", "--session-id ", "--session-id=" }) |flag| {
        if (std.mem.indexOf(u8, args, flag)) |i| {
            const start = i + flag.len;
            if (start + 36 <= args.len and isUuid(args[start .. start + 36])) return args[start .. start + 36];
        }
    }
    return "";
}

fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash != (c == '-')) return false;
        if (!dash and !std.ascii.isHex(c)) return false;
    }
    return true;
}

/// The conversation in Claude Code's record of a process
/// (~/.claude/sessions/<pid>.json).
fn sessionIdFromJson(bytes: []const u8) ?[]const u8 {
    const key = "\"sessionId\":\"";
    const at = std.mem.indexOf(u8, bytes, key) orelse return null;
    const start = at + key.len;
    if (start + 36 > bytes.len or !isUuid(bytes[start .. start + 36])) return null;
    return bytes[start .. start + 36];
}

/// The conversation of a Codex process: the rollout file it keeps open
/// (`lsof -Fn` output), rollout-<time>-<id>.jsonl.
fn rolloutId(lsof: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, lsof, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, ".jsonl") or std.mem.indexOf(u8, line, "/rollout-") == null) continue;
        const stem = line[0 .. line.len - ".jsonl".len];
        if (stem.len >= 36 and isUuid(stem[stem.len - 36 ..])) return stem[stem.len - 36 ..];
    }
    return null;
}

/// The exact conversation of a running agent: its arguments, else what the
/// agent itself records. Empty when it cannot be known.
fn runningConversation(ctx: sys.Ctx, pid: []const u8, agent: []const u8, args: []const u8) []const u8 {
    const said = conversationId(args);
    if (said.len > 0) return said;
    if (std.mem.eql(u8, agent, "claude")) {
        const path = ctx.join(&.{ ctx.home(), ".claude", "sessions", ctx.fmt("{s}.json", .{pid}) catch return "" }) catch return "";
        return sessionIdFromJson(sys.readFile(ctx, path) orelse return "") orelse "";
    }
    return rolloutId(sys.run(ctx, &.{ "lsof", "-p", pid, "-Fn" }, null).stdout) orelse "";
}

pub fn adoptList(ctx: sys.Ctx) ![]Adoptable {
    var list: std.ArrayList(Adoptable) = .empty;
    if (sys.platform == .windows) return list.items; // native processes expose no cwd to agb
    for (posixOutside(ctx)) |loose| {
        // Only Claude Code and Codex keep a conversation agb can reopen.
        if (!hasWord(loose.args, "claude") and !hasWord(loose.args, "codex")) continue;
        const agent: []const u8 = if (hasWord(loose.args, "codex")) "codex" else "claude";
        try list.append(ctx.gpa, .{ .pid = loose.pid, .agent = agent, .dir = processCwd(ctx, loose.pid) orelse "?", .conversation = runningConversation(ctx, loose.pid, agent, loose.args) });
    }
    return list.items;
}

/// Stops process `pid` and reopens its conversation in a new tmux session.
/// Returns the session name.
pub fn adoptDo(ctx: sys.Ctx, pid: []const u8) ![]const u8 {
    for (try adoptList(ctx)) |a| {
        if (!std.mem.eql(u8, a.pid, pid)) continue;
        if (!sys.isDir(ctx, a.dir)) return error.UnknownDirectory;
        // Never "the latest conversation here": it can be another agent's, and
        // two processes on one conversation fight over it. Unknown: not adopted.
        if (a.conversation.len == 0) return error.ConversationUnknown;
        const bin = sys.which(ctx, a.agent) orelse return error.AgentNotFound;
        const command = if (std.mem.eql(u8, a.agent, "claude"))
            try ctx.fmt("{s} --dangerously-skip-permissions --resume {s}", .{ try sys.shQuote(ctx, bin), a.conversation })
        else
            try ctx.fmt("{s} --dangerously-bypass-approvals-and-sandbox resume {s}", .{ try sys.shQuote(ctx, bin), a.conversation });
        const cleaned = try ctx.gpa.dupe(u8, std.fs.path.basename(a.dir));
        for (cleaned) |*c| if (!(std.ascii.isAlphanumeric(c.*) or c.* == '.' or c.* == '_' or c.* == '-')) {
            c.* = '-';
        };
        // "/" and ".." leave nothing usable, and tmux would take an empty -s.
        const base: []const u8 = if (sys.validSlug(cleaned)) cleaned else a.agent;
        var name: []const u8 = base;
        var n: usize = 2;
        while (hasSession(ctx, name)) : (n += 1) name = try ctx.fmt("{s}-{d}", .{ base, n });
        _ = sys.run(ctx, &.{ "kill", "-TERM", pid }, null);
        var tries: usize = 0;
        while (tries < 5 and sys.run(ctx, &.{ "kill", "-0", pid }, null).ok) : (tries += 1)
            std.Io.sleep(ctx.io, .fromSeconds(1), .awake) catch {};
        if (sys.run(ctx, &.{ "kill", "-0", pid }, null).ok) _ = sys.run(ctx, &.{ "kill", "-KILL", pid }, null);
        if (!tmux(ctx, &.{ "new-session", "-d", "-s", name, "-c", a.dir, command }).ok) return error.TmuxFailed;
        _ = tmux(ctx, &.{ "set-option", "-t", name, "@work_agent", a.agent });
        return name;
    }
    return error.NotOutsideTmux;
}

// ---------------------------------------------------------------- probe

/// `agb _probe`: what this machine can do, in one line.
pub fn probe(ctx: sys.Ctx, version: []const u8) ![]const u8 {
    const tmux_version = std.mem.trim(u8, tmux(ctx, &.{"-V"}).text(), " ");
    var agents: std.ArrayList(u8) = .empty;
    inline for (std.meta.fields(Agent)) |f| if (@field(Agent, f.name) != .shell and sys.which(ctx, @field(Agent, f.name).program()) != null)
        try agents.appendSlice(ctx.gpa, if (agents.items.len > 0) "," ++ f.name else f.name);
    return ctx.fmt("agb={s} tmux={s} git={s} agents={s} repos={s}", .{
        version,
        if (tmux_version.len > 0) tmux_version else "NO",
        if (sys.which(ctx, "git") != null) "yes" else "NO",
        if (agents.items.len > 0) agents.items else "NONE",
        try reposDir(ctx),
    });
}

test "session names from titles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
    try std.testing.expectEqualStrings("criar-1-novo-agente", try sessionSlug(ctx, "Administrador: ✳ criar 1 novo agente"));
    try std.testing.expectEqualStrings("leave", try sessionSlug(ctx, "✳ leave"));
    try std.testing.expectEqualStrings("Resposta-ao-cliente-sobre-custodia", try sessionSlug(ctx, "⠂ Resposta ao cliente sobre custódia"));
}

test "word match, conversation ids and tty normalization" {
    try std.testing.expect(hasWord("/usr/local/bin/claude --continue", "claude"));
    try std.testing.expect(hasWord("claude", "claude"));
    try std.testing.expect(!hasWord("claude-helper", "claude"));
    try std.testing.expect(!hasWord("myclaude", "claude"));
    try std.testing.expectEqualStrings("0cce7bc0-1111-2222-3333-444455556666", conversationId("claude --resume 0cce7bc0-1111-2222-3333-444455556666 --x"));
    try std.testing.expectEqualStrings("", conversationId("claude --continue"));
    try std.testing.expectEqualStrings("s001", normTty("/dev/ttys001"));
    try std.testing.expectEqualStrings("s001", normTty("s001"));
}

test "a tmux client draws UTF-8 without a locale" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
    const got = try clientArgs(ctx, &.{ "attach", "-t", "$1" });
    try std.testing.expectEqualStrings("-u", got[0]);
    try std.testing.expectEqualStrings("attach", got[1]);
}

test "the exact conversation of a running agent" {
    try std.testing.expectEqualStrings("2016788a-06be-43f8-a304-c6845c8be72e", sessionIdFromJson("{\"pid\":36749,\"sessionId\":\"2016788a-06be-43f8-a304-c6845c8be72e\",\"cwd\":\"/Users/x\"}").?);
    try std.testing.expect(sessionIdFromJson("{\"pid\":1}") == null);
    try std.testing.expect(sessionIdFromJson("{\"sessionId\":\"../../etc\"}") == null);
    const lsof = "p123\nn/Users/x/.codex/log/codex-tui.log\nn/Users/x/.codex/sessions/2026/09/22/rollout-2026-09-22T17-23-32-01a0cac9-b973-7250-bbea-5c0287900a45.jsonl\n";
    try std.testing.expectEqualStrings("01a0cac9-b973-7250-bbea-5c0287900a45", rolloutId(lsof).?);
    try std.testing.expect(rolloutId("p1\nn/tmp/x\n") == null);
    try std.testing.expect(isAgentCommand("/Users/x/.local/bin/claude --continue"));
    try std.testing.expect(isAgentCommand("codex resume --last"));
    try std.testing.expect(isAgentCommand("node /opt/homebrew/bin/codex"));
    try std.testing.expect(!isAgentCommand("/Applications/Agent Belt.app/Contents/MacOS/agb new --agent claude --host w"));
    try std.testing.expect(!isAgentCommand("ssh -t w agb new --agent claude"));
    // A name after --resume is not an id.
    try std.testing.expectEqualStrings("", conversationId("claude --resume fx-deepseek"));
}

test "the listing answer keeps its columns whatever a session is called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
    // `tmux new -s 'a|b'` is legal: unescaped it shifts every later column, so
    // the machine reading the answer shows the wrong agent and path for the row.
    try std.testing.expectEqualStrings("a b", try field(ctx, "a|b"));
    try std.testing.expectEqualStrings("a b c", try field(ctx, "a\nb\rc"));
    try std.testing.expectEqualStrings("web-app-login", try field(ctx, "web-app-login"));
}

test "a worktree path cannot write its own Codex trust entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
    // A backslash is an invalid TOML escape, and a quote would close the key and
    // let the rest of the path open a table that trusts a directory nobody chose.
    try std.testing.expectEqualStrings("C:\\\\dev\\\\x", try tomlQuote(ctx, "C:\\dev\\x"));
    try std.testing.expectEqualStrings("a\\\"]\\n[projects.\\\"/\\\"", try tomlQuote(ctx, "a\"]\n[projects.\"/\""));
    try std.testing.expectEqualStrings("/home/alice/dev/web-app", try tomlQuote(ctx, "/home/alice/dev/web-app"));
}

test "repositories one folder down are found, worktrees are not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    for ([_][]const u8{ "dev/api/.git", "dev/work/web-app/.git", "dev/work/deep/nested/.git", "dev/.hidden/.git" }) |d|
        try std.Io.Dir.cwd().createDirPath(std.testing.io, try std.fs.path.join(gpa, &.{ root, d }));
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try std.fs.path.join(gpa, &.{ root, "dev/api-login" }));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fs.path.join(gpa, &.{ root, "dev/api-login/.git" }), .data = "gitdir: x" });
    var env = std.process.Environ.Map.init(gpa);
    try env.put("HOME", root);
    try env.put("USERPROFILE", root);
    try env.put("WORK_REPOS_DIR", try std.fs.path.join(gpa, &.{ root, "dev" }));
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = gpa, .env = &env };
    const names = try listRepos(ctx);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("api", names[0]);
    try std.testing.expectEqualStrings("web-app", names[1]);
    try std.testing.expect(std.mem.endsWith(u8, (try findRepos(ctx))[1].path, "web-app"));
}

test "every harness is recognized in a pane" {
    try std.testing.expect(isAgentCommand("/home/alice/.local/bin/fx"));
    try std.testing.expect(isAgentCommand("zcode"));
    try std.testing.expect(isAgentCommand("node /usr/lib/node_modules/@deepseek-ai/dsh/lib/dsh --profile headless job"));
    try std.testing.expect(!isAgentCommand("fxtop"));
    try std.testing.expectEqualStrings("dsh", Agent.deepseek.program());
    try std.testing.expectEqual(Agent.zcode, parseAgent("zcode").?);
}

test "an orphan tmux client is found by its missing parent" {
    const ps =
        \\      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND
        \\   330309  330279  330309     165648  pty3      197609 14:26:54 /usr/bin/tmux
        \\   348605       1  348605      70832  cons0     197609 15:58:47 /usr/bin/script
        \\   348623  348605  348623      90168  pty8      197609 15:58:49 /usr/bin/tmux
    ;
    const ttys = try orphanTtys(std.testing.allocator, "330309 /dev/pty3\n348623 /dev/pty8\n999 /dev/pty9\n", ps);
    defer std.testing.allocator.free(ttys);
    try std.testing.expectEqual(@as(usize, 1), ttys.len);
    try std.testing.expectEqualStrings("/dev/pty3", ttys[0]);
}
