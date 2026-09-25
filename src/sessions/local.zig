//! What runs on the machine that hosts the session: tmux, worktrees, agents.
//! The same code serves local commands and the `agb _…` calls other machines
//! make over ssh.
const std = @import("std");
const sys = @import("sys.zig");

pub const sep = "|";

pub const Agent = enum { claude, codex, shell };

pub fn parseAgent(name: []const u8) ?Agent {
    return std.meta.stringToEnum(Agent, name);
}

// ---------------------------------------------------------------- tmux

/// tmux with arguments. On Windows tmux is an MSYS2 program: it runs inside
/// MSYS2's login bash, which gives it the paths and runtime it expects.
pub fn tmux(ctx: sys.Ctx, args: []const []const u8) sys.Output {
    if (sys.platform == .windows) {
        const line = std.mem.concat(ctx.gpa, u8, &.{ "tmux ", sys.shJoin(ctx, args) catch return failed() }) catch return failed();
        return sys.run(ctx, &.{ sys.msys_bash, "-lc", line }, null);
    }
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(ctx.gpa, tmuxBin(ctx)) catch return failed();
    argv.appendSlice(ctx.gpa, args) catch return failed();
    return sys.run(ctx, argv.items, null);
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
    return tmux(ctx, &.{ "has-session", "-t", ctx.fmt("={s}", .{name}) catch return false }).ok;
}

// ---------------------------------------------------------------- repos

pub fn reposDir(ctx: sys.Ctx) ![]const u8 {
    if (ctx.getenv("WORK_REPOS_DIR")) |d| return d;
    if (sys.platform == .windows) return "C:\\dev";
    const micromed = try ctx.join(&.{ ctx.home(), "dev", "micromed" });
    if (sys.isDir(ctx, micromed)) return micromed;
    return ctx.join(&.{ ctx.home(), "dev" });
}

/// Where repositories live on this machine: the paths listed in
/// ~/.config/agent-belt/repo-roots (one per line, ~ for home), or else the
/// repos directory plus ~/dev/frb and ~/dev.
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
    if (sys.platform != .windows) {
        try roots.append(ctx.gpa, try ctx.join(&.{ ctx.home(), "dev", "frb" }));
        try roots.append(ctx.gpa, try ctx.join(&.{ ctx.home(), "dev" }));
    }
    return roots.items;
}

/// Git repositories directly under the repo roots.
pub fn listRepos(ctx: sys.Ctx) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (try repoRoots(ctx)) |root| {
        var dir = std.Io.Dir.cwd().openDir(ctx.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(ctx.io);
        var it = dir.iterate();
        while (it.next(ctx.io) catch null) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            // A directory .git: a repository. A worktree (a session's) has a .git file.
            if (!sys.isDir(ctx, try ctx.join(&.{ root, entry.name, ".git" }))) continue;
            var seen = false;
            for (names.items) |n| if (std.mem.eql(u8, n, entry.name)) {
                seen = true;
            };
            if (!seen) try names.append(ctx.gpa, try ctx.gpa.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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

fn trustCodex(ctx: sys.Ctx, project: []const u8) void {
    const codex_home = ctx.getenv("CODEX_HOME") orelse (ctx.join(&.{ ctx.home(), ".codex" }) catch return);
    if (!sys.isDir(ctx, codex_home)) return;
    const file = ctx.join(&.{ codex_home, "config.toml" }) catch return;
    const current = sys.readFile(ctx, file) orelse "";
    const section = ctx.fmt("[projects.\"{s}\"]", .{project}) catch return;
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

fn agentCommand(ctx: sys.Ctx, opts: CreateOptions, worktree: []const u8) ![]const u8 {
    var cmd: std.ArrayList(u8) = .empty;
    switch (opts.agent) {
        .claude, .codex => {
            const bin = sys.which(ctx, @tagName(opts.agent)) orelse return error.AgentNotFound;
            if (sys.platform == .windows) try cmd.appendSlice(ctx.gpa, "winpty ");
            try cmd.appendSlice(ctx.gpa, try sys.shQuote(ctx, if (sys.platform == .windows) try sys.toMsys(ctx, bin) else bin));
            if (opts.agent == .claude) {
                try cmd.appendSlice(ctx.gpa, " --dangerously-skip-permissions");
                // A worktree that had a conversation continues it: a dead tmux
                // session should not mean starting over. WORK_NEW=1 forces a new one.
                const fresh = if (ctx.getenv("WORK_NEW")) |v| std.mem.eql(u8, v, "1") else false;
                if (!fresh and claudeConversationExists(ctx, worktree))
                    try cmd.appendSlice(ctx.gpa, " --continue")
                else
                    try cmd.appendSlice(ctx.gpa, try ctx.fmt(" --name {s}", .{try sys.shQuote(ctx, opts.task)}));
            } else {
                try cmd.appendSlice(ctx.gpa, " --dangerously-bypass-approvals-and-sandbox");
            }
            // The first instruction becomes the agent's first prompt. It goes
            // through a file: tmux caps a command at 16 KB, and a long spoken
            // request is longer.
            if (opts.prompt) |p| if (p.len > 0) {
                const dir = try ctx.join(&.{ ctx.home(), ".cache", "agent-belt", "prompts" });
                std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
                const file = try ctx.join(&.{ dir, try ctx.fmt("{s}.txt", .{opts.task}) });
                sys.writeFileAtomic(ctx, file, p) catch return error.WorktreeFailed;
                const shown = if (sys.platform == .windows) try sys.toMsys(ctx, file) else file;
                try cmd.appendSlice(ctx.gpa, try ctx.fmt(" \"$(cat {s})\"", .{try sys.shQuote(ctx, shown)}));
            };
        },
        .shell => try cmd.appendSlice(ctx.gpa, if (sys.platform == .windows) "bash -l" else ctx.getenv("SHELL") orelse "/bin/sh"),
    }
    return cmd.items;
}

pub const CreateError = error{ NotARepo, WorktreeClash, WorktreeFailed, TmuxFailed, AgentNotFound, InvalidTask } || std.mem.Allocator.Error;

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
        .shell => {},
    };

    const command = try agentCommand(ctx, opts, worktree);
    const cwd = if (sys.platform == .windows) try sys.toMsys(ctx, worktree) else worktree;
    // Start the server first, detached from this process's descriptors: on
    // Windows it would otherwise die with the console that created it.
    _ = tmux(ctx, &.{"start-server"});
    // The session and its marks in one tmux call: a listing in between (another
    // machine's `agb ls`) would otherwise rename it from the agent's title
    // before it knows its task. Printed back: the session id, which survives
    // renames, so attaching cannot miss it.
    const target = try paneTarget(ctx, session); // set-option takes a pane target on tmux 3.5+
    const made = tmux(ctx, &.{ "new-session", "-d", "-P", "-F", "#{session_id}", "-s", session, "-c", cwd, command, ";", "set-option", "-t", target, "@work_agent", @tagName(opts.agent), ";", "set-option", "-t", target, "@work_task", opts.task });
    const id = std.mem.trim(u8, made.stdout, " \r\n");
    if (!made.ok or id.len == 0 or id[0] != '$') {
        std.debug.print("{s}", .{made.stderr});
        return error.TmuxFailed;
    }
    tmuxSetup(ctx);
    if (opts.no_attach) return session;
    attachTarget(ctx, id, opts.detach_others);
}

/// A pane target for a session: "=name:" (its current window). Plain "=name"
/// is a session target that pane commands reject on tmux 3.5.
fn paneTarget(ctx: sys.Ctx, name: []const u8) ![]const u8 {
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
    return tmux(ctx, &.{ "kill-session", "-t", ctx.fmt("={s}", .{name}) catch return false }).ok;
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
        if (hasWord(out.stdout, "claude")) return "claude~";
        if (hasWord(out.stdout, "codex")) return "codex~";
    }
    const shells = [_][]const u8{ "bash", "zsh", "sh", "fish", "pwsh", "powershell" };
    for (shells) |s| if (std.mem.eql(u8, command, s)) return "shell";
    if (std.mem.eql(u8, command, "claude") or std.mem.eql(u8, command, "winpty")) return "claude~";
    if (std.mem.eql(u8, command, "codex")) return "codex~";
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
/// The repo prefix stays ("coreum-xpto" renamed to "bug" becomes "coreum-bug").
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
            if (std.mem.eql(u8, cmd, "winpty") or std.mem.eql(u8, cmd, "claude") or std.mem.eql(u8, cmd, "codex")) inside += 1;
        }
        const total = windowsAgentPids(ctx).len;
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
        if (!hasWord(args, "claude") and !hasWord(args, "codex")) continue;
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

fn windowsAgentPids(ctx: sys.Ctx) [][]const u8 {
    var pids: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "claude.exe", "codex.exe" }) |image| {
        const out = sys.run(ctx, &.{ "tasklist", "/FO", "CSV", "/NH", "/FI", ctx.fmt("IMAGENAME eq {s}", .{image}) catch continue }, null);
        var lines = std.mem.splitScalar(u8, out.stdout, '\n');
        while (lines.next()) |line| {
            var cols = std.mem.splitSequence(u8, line, "\",\"");
            _ = cols.next();
            const pid = cols.next() orelse continue;
            pids.append(ctx.gpa, pid) catch {};
        }
    }
    return pids.items;
}

/// `agb _ls-raw`: one line per session, name|windows|created|attached|agent|path,
/// then #outside|<count>, which also marks the answer as complete.
pub fn lsRaw(ctx: sys.Ctx) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
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
        try out.appendSlice(ctx.gpa, try ctx.fmt("{s}|{s}|{s}|{s}|{s}|{s}\n", .{ name, windows, created, attached, agent, path }));
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

/// --resume <id> / --session-id <id> in the process arguments names the exact conversation.
fn conversationId(args: []const u8) []const u8 {
    for ([_][]const u8{ "--resume ", "--resume=", "--session-id ", "--session-id=" }) |flag| {
        if (std.mem.indexOf(u8, args, flag)) |i| {
            const start = i + flag.len;
            if (start + 36 <= args.len) return args[start .. start + 36];
        }
    }
    return "";
}

pub fn adoptList(ctx: sys.Ctx) ![]Adoptable {
    var list: std.ArrayList(Adoptable) = .empty;
    if (sys.platform == .windows) return list.items; // native processes expose no cwd to agb
    for (posixOutside(ctx)) |loose| {
        const agent: []const u8 = if (hasWord(loose.args, "codex")) "codex" else "claude";
        try list.append(ctx.gpa, .{ .pid = loose.pid, .agent = agent, .dir = processCwd(ctx, loose.pid) orelse "?", .conversation = conversationId(loose.args) });
    }
    return list.items;
}

/// Stops process `pid` and reopens its conversation in a new tmux session.
/// Returns the session name.
pub fn adoptDo(ctx: sys.Ctx, pid: []const u8) ![]const u8 {
    for (try adoptList(ctx)) |a| {
        if (!std.mem.eql(u8, a.pid, pid)) continue;
        if (!sys.isDir(ctx, a.dir)) return error.UnknownDirectory;
        const bin = sys.which(ctx, a.agent) orelse return error.AgentNotFound;
        const command = if (std.mem.eql(u8, a.agent, "claude"))
            try ctx.fmt("{s} --dangerously-skip-permissions {s}", .{ try sys.shQuote(ctx, bin), if (a.conversation.len > 0) try ctx.fmt("--resume {s}", .{a.conversation}) else "--continue" })
        else
            try ctx.fmt("{s} --dangerously-bypass-approvals-and-sandbox resume {s}", .{ try sys.shQuote(ctx, bin), if (a.conversation.len > 0) a.conversation else "--last" });
        const base = try ctx.gpa.dupe(u8, std.fs.path.basename(a.dir));
        for (base) |*c| if (!(std.ascii.isAlphanumeric(c.*) or c.* == '.' or c.* == '_' or c.* == '-')) {
            c.* = '-';
        };
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
    return ctx.fmt("agb={s} tmux={s} git={s} claude={s} codex={s} repos={s}", .{
        version,
        if (tmux_version.len > 0) tmux_version else "NO",
        if (sys.which(ctx, "git") != null) "yes" else "NO",
        if (sys.which(ctx, "claude") != null) "yes" else "NO",
        if (sys.which(ctx, "codex") != null) "yes" else "NO",
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
    try std.testing.expectEqualStrings("Resposta-ao-Odelio-sobre-custodia", try sessionSlug(ctx, "⠂ Resposta ao Odelio sobre custódia"));
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
