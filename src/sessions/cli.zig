//! `agb` session commands: humane on the outside, a small line protocol
//! (`agb _…`) between machines over ssh.
//!
//!   agb new [agent] [machine|here] [repo] [what to do…]
//!   agb sessions | ls | repos [machine] | attach [-d] <session> [machine]
//!   agb hosts [discover|add|rm|self] | doctor | adopt [machine] | tm [name] | deploy [machine…|--all]
//!   agb send <session> [machine] <text…> | peek <session> [machine] [lines] | stop <session> [machine]
const std = @import("std");
const sys = @import("sys.zig");
const hosts = @import("hosts.zig");
const local = @import("local.zig");
const intent = @import("intent.zig");

pub const Env = struct {
    ctx: sys.Ctx,
    version: []const u8,
    /// Where this binary was built from, for `agb deploy`.
    source_root: []const u8,
};

pub fn isSessionCommand(verb: []const u8) bool {
    const verbs = [_][]const u8{ "new", "sessions", "ls", "repos", "attach", "hosts", "doctor", "adopt", "tm", "deploy", "send", "peek", "stop", "_ls-raw", "_run", "_probe", "_repos", "_adopt-list", "_adopt-do", "_send", "_peek", "_stop", "_intent", "_summary", "_repos-cache" };
    for (verbs) |v| if (std.mem.eql(u8, v, verb)) return true;
    return false;
}

pub fn main(env: Env, args: []const []const u8) anyerror!u8 {
    const ctx = env.ctx;
    const verb = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, verb, "new")) return cmdNew(env, rest);
    if (std.mem.eql(u8, verb, "sessions")) return cmdSessions(env);
    if (std.mem.eql(u8, verb, "ls")) return cmdLs(env);
    if (std.mem.eql(u8, verb, "repos")) return cmdRepos(env, rest);
    if (std.mem.eql(u8, verb, "attach")) return cmdAttach(env, rest);
    if (std.mem.eql(u8, verb, "hosts")) return cmdHosts(env, rest);
    if (std.mem.eql(u8, verb, "doctor")) return cmdDoctor(env);
    if (std.mem.eql(u8, verb, "adopt")) return cmdAdopt(env, rest);
    if (std.mem.eql(u8, verb, "deploy")) return cmdDeploy(env, rest);
    if (std.mem.eql(u8, verb, "send") or std.mem.eql(u8, verb, "peek") or std.mem.eql(u8, verb, "stop")) return cmdSessionAction(env, verb, rest);
    if (std.mem.eql(u8, verb, "_send")) {
        if (rest.len < 2) return 2;
        return if (local.send(ctx, rest[0], try std.mem.join(ctx.gpa, " ", rest[1..]))) 0 else 1;
    }
    if (std.mem.eql(u8, verb, "_peek")) {
        if (rest.len < 1) return 2;
        const lines = if (rest.len > 1) std.fmt.parseInt(usize, rest[1], 10) catch 40 else 40;
        return print(ctx, local.peek(ctx, rest[0], lines) orelse return 1);
    }
    if (std.mem.eql(u8, verb, "_stop")) return if (rest.len == 1 and local.stop(ctx, rest[0])) 0 else 1;
    if (std.mem.eql(u8, verb, "tm")) local.tmuxHandOver(ctx, &.{ "new", "-A", "-s", if (rest.len > 0) rest[0] else "main" });
    // Machine-to-machine protocol.
    if (std.mem.eql(u8, verb, "_ls-raw")) return print(ctx, try local.lsRaw(ctx));
    if (std.mem.eql(u8, verb, "_probe")) return print(ctx, try ctx.fmt("{s}\n", .{try local.probe(ctx, env.version)}));
    if (std.mem.eql(u8, verb, "_repos")) {
        for (try local.listRepos(ctx)) |r| _ = print(ctx, try ctx.fmt("{s}\n", .{r}));
        return 0;
    }
    if (std.mem.eql(u8, verb, "_run")) return runLocal(env, try parseRun(rest));
    if (std.mem.eql(u8, verb, "_intent")) return cmdIntent(env, rest);
    if (std.mem.eql(u8, verb, "_summary")) {
        const summary = try intent.summarize(ctx, try std.mem.join(ctx.gpa, " ", rest));
        return print(ctx, try ctx.fmt("{f}\n", .{std.json.fmt(summary, .{})}));
    }
    if (std.mem.eql(u8, verb, "_repos-cache")) {
        try intent.refreshCache(ctx, try loadRegistry(ctx), reposOf);
        return 0;
    }
    if (std.mem.eql(u8, verb, "_adopt-list")) {
        for (try local.adoptList(ctx)) |a| _ = print(ctx, try ctx.fmt("{s}|{s}|{s}|{s}\n", .{ a.pid, a.agent, a.dir, a.conversation }));
        return 0;
    }
    if (std.mem.eql(u8, verb, "_adopt-do")) {
        if (rest.len != 1) return 2;
        const name = local.adoptDo(ctx, rest[0]) catch |err| return print(ctx, try ctx.fmt("error|{s}\n", .{@errorName(err)}));
        return print(ctx, try ctx.fmt("ok|{s}\n", .{name}));
    }
    return 2;
}

/// `agb _intent [--agent a] [--host h] [--repo r] <words…>`: the create-agent
/// panel's detection, as JSON. Fixed parts are taken as is and not asked.
fn cmdIntent(env: Env, args: []const []const u8) !u8 {
    const ctx = env.ctx;
    var fixed: intent.Fixed = .{};
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (i + 1 < args.len and std.mem.eql(u8, a, "--agent")) {
            i += 1;
            fixed.agent = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--host")) {
            i += 1;
            fixed.host = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, a, "--repo")) {
            i += 1;
            fixed.repo = args[i];
        } else if (std.mem.eql(u8, a, "--no-repo")) {
            fixed.no_repo = true;
        } else try words.append(ctx.gpa, a);
    }
    const reg = try loadRegistry(ctx);
    const plan = intent.detect(ctx, reg, try std.mem.join(ctx.gpa, " ", words.items), fixed) catch |err| {
        _ = print(ctx, try ctx.fmt("{f}\n", .{std.json.fmt(.{ .@"error" = @errorName(err) }, .{})}));
        return 1;
    };
    return print(ctx, try ctx.fmt("{f}\n", .{std.json.fmt(plan, .{})}));
}

pub fn reposOf(ctx: sys.Ctx, h: hosts.Host) ?[]const u8 {
    const reg = loadRegistry(ctx) catch return null;
    if (reg.isSelf(h)) {
        const names = local.listRepos(ctx) catch return null;
        return std.mem.join(ctx.gpa, "\n", names) catch null;
    }
    const out = remote(ctx, h, &.{"_repos"});
    return if (out.ok) out.stdout else null;
}

fn print(ctx: sys.Ctx, bytes: []const u8) u8 {
    std.Io.File.stdout().writeStreamingAll(ctx.io, bytes) catch return 1;
    return 0;
}

fn say(comptime format: []const u8, args: anytype) void {
    std.debug.print(format ++ "\n", args);
}

// ---------------------------------------------------------------- remote

/// How to call agb on another machine. Windows' sshd hands the command to
/// PowerShell, so arguments are quoted for PowerShell there, for sh elsewhere.
fn remoteArgv(ctx: sys.Ctx, host: hosts.Host, tty: bool, args: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(ctx.gpa, &.{ "ssh", if (tty) "-t" else "-n" });
    if (!tty) try argv.appendSlice(ctx.gpa, &.{ "-o", "BatchMode=yes" });
    try argv.appendSlice(ctx.gpa, &.{ "-o", "ConnectTimeout=6", "-o", "StrictHostKeyChecking=accept-new", host.target });
    switch (host.kind) {
        .posix => try argv.append(ctx.gpa, "$HOME/.local/bin/agb"),
        .msys => {
            const user = host.target[0 .. std.mem.indexOfScalar(u8, host.target, '@') orelse 0];
            try argv.append(ctx.gpa, try ctx.fmt("C:\\Users\\{s}\\.local\\bin\\agb.exe", .{user}));
        },
    }
    for (args) |arg| try argv.append(ctx.gpa, switch (host.kind) {
        .posix => try sys.shQuote(ctx, arg),
        .msys => try sys.psQuote(ctx, arg),
    });
    return argv.items;
}

fn remote(ctx: sys.Ctx, host: hosts.Host, args: []const []const u8) sys.Output {
    const argv = remoteArgv(ctx, host, false, args) catch return .{ .ok = false, .code = 1, .stdout = &.{}, .stderr = &.{} };
    return sys.runCaptured(ctx, argv);
}

/// Hands this terminal to agb on another machine (attach, create).
fn remoteHandOver(ctx: sys.Ctx, host: hosts.Host, args: []const []const u8) !u8 {
    // Newer terminals name themselves (xterm-ghostty, xterm-kitty…) with terminfo
    // the other machine lacks, and its tmux then refuses to open.
    if (ctx.getenv("TERM")) |term| if (!knownTerm(term)) try ctx.env.put("TERM", "xterm-256color");
    const code = sys.interactive(ctx, try remoteArgv(ctx, host, true, args), null);
    if (code != 0) say("agb: {s} on {s} ended with code {d}", .{ args[0], host.name, code });
    return code;
}

fn knownTerm(term: []const u8) bool {
    for ([_][]const u8{ "xterm", "xterm-256color", "screen", "screen-256color", "tmux", "tmux-256color", "vt100", "linux", "dumb" }) |t|
        if (std.mem.eql(u8, term, t)) return true;
    return false;
}

fn loadRegistry(ctx: sys.Ctx) !hosts.Registry {
    return hosts.load(ctx);
}

// ---------------------------------------------------------------- new

pub const Plan = struct {
    agent: local.Agent = .claude,
    host: ?hosts.Host = null, // null: this machine
    repo: ?[]const u8 = null,
    task: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    detach_others: bool = false,
    dry_run: bool = false,
    /// Run without a repo (research): in ~/agents/<task>, even inside a repo.
    no_repo: bool = false,
    no_attach: bool = false,
};

const here_words = [_][]const u8{ "here", "local", "default", "aqui", "this" };
const nl_verbs = [_][]const u8{ "crie", "cria", "criar", "create", "abra", "abre", "open", "start", "inicie", "inicia", "make", "spawn", "coloque", "bota" };

fn isHereWord(token: []const u8) bool {
    for (here_words) |w| if (std.ascii.eqlIgnoreCase(w, token)) return true;
    return false;
}

fn isNaturalLanguage(token: []const u8) bool {
    for (nl_verbs) |w| if (std.ascii.eqlIgnoreCase(w, token)) return true;
    return false;
}

/// `agb new [agent] [machine|here] [repo] [what to do…]`, flags anywhere:
/// --agent --host --repo --task --prompt -d --dry-run.
pub fn parseNew(ctx: sys.Ctx, reg: hosts.Registry, args: []const []const u8, repoCheck: *const fn (sys.Ctx, ?hosts.Host, []const u8) bool) !Plan {
    var plan = Plan{};
    var words: std.ArrayList([]const u8) = .empty;
    var host_set = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const value = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, a, "--agent")) {
            plan.agent = local.parseAgent(value orelse return error.MissingValue) orelse return error.UnknownAgent;
            i += 1;
        } else if (std.mem.eql(u8, a, "--host")) {
            const v = value orelse return error.MissingValue;
            plan.host = if (isHereWord(v)) null else reg.find(v) orelse return error.UnknownHost;
            host_set = true;
            i += 1;
        } else if (std.mem.eql(u8, a, "--repo")) {
            plan.repo = value orelse return error.MissingValue;
            i += 1;
        } else if (std.mem.eql(u8, a, "--task")) {
            plan.task = value orelse return error.MissingValue;
            i += 1;
        } else if (std.mem.eql(u8, a, "--prompt")) {
            plan.prompt = value orelse return error.MissingValue;
            i += 1;
        } else if (std.mem.eql(u8, a, "-d")) {
            plan.detach_others = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            plan.dry_run = true;
        } else if (std.mem.eql(u8, a, "--detach") or std.mem.eql(u8, a, "--no-attach")) {
            plan.no_attach = true;
        } else if (std.mem.eql(u8, a, "--no-repo")) {
            plan.no_repo = true;
        } else {
            try words.append(ctx.gpa, a);
        }
    }
    // Positional: [agent] [machine|here] [repo] [prompt…]
    var w: usize = 0;
    if (w < words.items.len) if (local.parseAgent(words.items[w])) |agent| {
        plan.agent = agent;
        w += 1;
    };
    if (!host_set and w < words.items.len) {
        if (isHereWord(words.items[w])) {
            w += 1;
        } else if (reg.find(words.items[w])) |h| {
            plan.host = if (reg.isSelf(h)) null else h;
            w += 1;
        }
    }
    if (plan.host) |h| if (reg.isSelf(h)) {
        plan.host = null;
    };
    if (plan.repo == null and w < words.items.len and sys.validRepo(words.items[w]) and repoCheck(ctx, plan.host, words.items[w])) {
        plan.repo = words.items[w];
        w += 1;
    }
    if (plan.prompt == null and w < words.items.len)
        plan.prompt = try std.mem.join(ctx.gpa, " ", words.items[w..]);
    if (plan.task == null) {
        plan.task = if (plan.prompt) |p| try sys.slugFromWords(ctx, p, 4) else @tagName(plan.agent);
        if (plan.task.?.len == 0) plan.task = @tagName(plan.agent);
    }
    return plan;
}

fn repoExists(ctx: sys.Ctx, host: ?hosts.Host, name: []const u8) bool {
    if (host) |h| {
        const out = remote(ctx, h, &.{"_repos"});
        var lines = std.mem.splitScalar(u8, out.stdout, '\n');
        while (lines.next()) |line| if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), name)) return true;
        return std.mem.indexOfScalar(u8, name, '/') != null;
    }
    return (local.resolveRepo(ctx, name) catch null) != null;
}

fn cmdNew(env: Env, args: []const []const u8) !u8 {
    const ctx = env.ctx;
    const reg = try loadRegistry(ctx);
    if (args.len > 0 and isNaturalLanguage(args[0])) {
        // Flags are not words of the request.
        var words: std.ArrayList([]const u8) = .empty;
        var flags = Plan{};
        for (args) |a| {
            if (std.mem.eql(u8, a, "--dry-run")) flags.dry_run = true else if (std.mem.eql(u8, a, "--no-repo")) flags.no_repo = true else if (std.mem.eql(u8, a, "--detach") or std.mem.eql(u8, a, "--no-attach")) flags.no_attach = true else if (std.mem.eql(u8, a, "-d")) flags.detach_others = true else try words.append(ctx.gpa, a);
        }
        return newFromWords(env, reg, try std.mem.join(ctx.gpa, " ", words.items), flags);
    }
    const plan = parseNew(ctx, reg, args, repoExists) catch |err| {
        say("agb new: {s}", .{switch (err) {
            error.UnknownHost => "unknown machine (see: agb hosts)",
            error.UnknownAgent => "agent must be claude, codex or shell",
            else => @errorName(err),
        }});
        usageNew();
        return 2;
    };
    return execute(env, plan);
}

fn usageNew() void {
    say(
        \\usage: agb new [claude|codex|shell] [machine|here] [repo] [what to do…]
        \\  agb new                                   claude here, in this repo
        \\  agb new codex windows coreum fix the login
        \\  agb new claude linux2 agent-belt review the README
        \\  agb new create an agent on windows with codex in coreum to look into the login
        \\  agb new claude here --no-repo research tmux alternatives   (no repo: works in ~/agents/<task>)
        \\flags: --agent --host --repo --no-repo --task --prompt --detach (print the session, don't attach) -d --dry-run
    , .{});
}

fn execute(env: Env, input: Plan) !u8 {
    const ctx = env.ctx;
    var plan = input;
    // Here, no repo given: the repo this terminal is in (none outside a repo,
    // or with --no-repo: the agent works in ~/agents/<task>).
    if (plan.no_repo) plan.repo = null;
    if (plan.host == null and plan.repo == null and !plan.no_repo) {
        const out = sys.run(ctx, &.{ sys.which(ctx, "git") orelse "git", "rev-parse", "--show-toplevel" }, null);
        if (out.ok) plan.repo = out.text();
    }
    const where = if (plan.host) |h| h.name else "here";
    if (plan.dry_run) {
        _ = print(ctx, try ctx.fmt("agent={s} machine={s} repo={s} task={s} prompt={s}\n", .{ @tagName(plan.agent), where, plan.repo orelse "none (~/agents)", plan.task.?, plan.prompt orelse "-" }));
        return 0;
    }
    if (plan.host) |h| {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(ctx.gpa, &.{ "_run", "--agent", @tagName(plan.agent) });
        if (plan.prompt) |p| try args.appendSlice(ctx.gpa, &.{ "--prompt", p });
        if (plan.detach_others) try args.append(ctx.gpa, "-d");
        if (plan.no_attach) try args.append(ctx.gpa, "--detach");
        try args.append(ctx.gpa, plan.task.?);
        if (plan.repo) |r| try args.append(ctx.gpa, r);
        if (plan.no_attach) {
            const out = remote(ctx, h, args.items);
            _ = print(ctx, out.stdout);
            if (!out.ok) std.debug.print("{s}", .{out.stderr});
            return out.code;
        }
        return remoteHandOver(ctx, h, args.items);
    }
    return runLocal(env, plan);
}

fn runLocal(env: Env, plan: Plan) !u8 {
    const ctx = env.ctx;
    const name = local.create(ctx, .{ .task = plan.task.?, .repo = plan.repo, .agent = plan.agent, .prompt = plan.prompt, .detach_others = plan.detach_others, .no_attach = plan.no_attach }) catch |err| {
        switch (err) {
            error.NotARepo => say("agb: '{s}' is not a git repository here", .{plan.repo orelse ""}),
            error.WorktreeClash => say("agb: the worktree path exists and is not a worktree of this repo; pick another task name", .{}),
            error.AgentNotFound => say("agb: {s} is not installed on this machine", .{@tagName(plan.agent)}),
            error.InvalidTask => say("agb: task names are letters, digits, . _ - ({s})", .{plan.task.?}),
            else => say("agb: {s}", .{@errorName(err)}),
        }
        return 1;
    };
    return print(ctx, try ctx.fmt("{s}\n", .{name}));
}

/// `agb _run [--agent a] [--prompt p] [-d] <task> [repo]`
fn parseRun(args: []const []const u8) !Plan {
    var plan = Plan{};
    var positional: [2]?[]const u8 = .{ null, null };
    var n: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--agent") and i + 1 < args.len) {
            plan.agent = local.parseAgent(args[i + 1]) orelse return error.UnknownAgent;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--prompt") and i + 1 < args.len) {
            plan.prompt = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-d")) {
            plan.detach_others = true;
        } else if (std.mem.eql(u8, args[i], "--detach")) {
            plan.no_attach = true;
        } else if (n < 2) {
            positional[n] = args[i];
            n += 1;
        }
    }
    plan.task = positional[0] orelse return error.MissingTask;
    plan.repo = positional[1];
    return plan;
}

/// Sentences like "create an agent on windows with codex in coreum to …":
/// a small model turns them into a plan, checked like any other input.
/// `agb new crie um agente no windows com codex …`: the same detection as the
/// create-agent panel (agb _intent, backed by Jev).
fn newFromWords(env: Env, reg: hosts.Registry, text: []const u8, flags: Plan) !u8 {
    const ctx = env.ctx;
    const detected = intent.detect(ctx, reg, text, .{}) catch |err| {
        say("agb: could not read that request ({s}); use: agb new <agent> <machine> <repo> <what to do>", .{@errorName(err)});
        return 1;
    };
    var plan = planFromIntent(reg, detected) catch |err| {
        say("agb: could not turn that into a session ({s})", .{@errorName(err)});
        return 1;
    };
    // A short name and the work alone as the agent's prompt.
    if (intent.summarize(ctx, text)) |summary| {
        if (sys.validSlug(summary.name)) plan.task = summary.name;
        if (summary.prompt.len > 0) plan.prompt = summary.prompt;
    } else |_| {}
    plan.dry_run = flags.dry_run;
    plan.no_repo = flags.no_repo;
    plan.no_attach = flags.no_attach;
    plan.detach_others = flags.detach_others;
    say("agb: {s} on {s} in {s}: {s}", .{ @tagName(plan.agent), if (plan.host) |h| h.name else "this machine", plan.repo orelse "-", plan.task.? });
    return execute(env, plan);
}

/// A detected request as a session plan, checked like typed arguments: a known
/// machine, a repo and task that are safe as names.
pub fn planFromIntent(reg: hosts.Registry, detected: intent.Plan) !Plan {
    var plan = Plan{ .agent = local.parseAgent(detected.agent) orelse .claude };
    const host = reg.find(detected.host) orelse return error.UnknownHost;
    plan.host = if (reg.isSelf(host)) null else host;
    if (detected.repo) |repo| {
        if (!sys.validRepo(repo)) return error.UnsafeRepo;
        plan.repo = repo;
    } else plan.no_repo = true; // research: ~/agents/<task>
    if (!sys.validSlug(detected.task)) return error.UnsafeTask;
    plan.task = detected.task;
    plan.prompt = if (detected.prompt.len > 0) detected.prompt else null;
    return plan;
}

// ---------------------------------------------------------------- listing

pub const Row = struct { host: hosts.Host, name: []const u8, windows: []const u8, created: []const u8, attached: bool, agent: []const u8, path: []const u8 };
pub const HostState = struct { ok: bool = false, outside: usize = 0, sessions: usize = 0 };

pub const Collected = struct { rows: []Row, states: []HostState };

pub fn collect(ctx: sys.Ctx, reg: hosts.Registry) !Collected {
    const outputs = try ctx.gpa.alloc([]const u8, reg.hosts.len);
    const threads = try ctx.gpa.alloc(?std.Thread, reg.hosts.len);
    const Worker = struct {
        fn run(c: sys.Ctx, r: hosts.Registry, i: usize, slot: *[]const u8) void {
            const h = r.hosts[i];
            slot.* = if (r.isSelf(h)) (local.lsRaw(c) catch "") else remote(c, h, &.{"_ls-raw"}).stdout;
        }
    };
    for (reg.hosts, 0..) |_, i| {
        outputs[i] = "";
        threads[i] = std.Thread.spawn(.{}, Worker.run, .{ ctx, reg, i, &outputs[i] }) catch null;
    }
    for (threads) |t| if (t) |thread| thread.join();
    var rows: std.ArrayList(Row) = .empty;
    const states = try ctx.gpa.alloc(HostState, reg.hosts.len);
    for (reg.hosts, 0..) |h, i| {
        states[i] = .{};
        var lines = std.mem.splitScalar(u8, outputs[i], '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            var f = std.mem.splitScalar(u8, line, '|');
            const name = f.next() orelse continue;
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, "#outside") or std.mem.eql(u8, name, "#fora")) {
                // The closing line: without it the machine did not answer.
                states[i].ok = true;
                states[i].outside = std.fmt.parseInt(usize, f.next() orelse "0", 10) catch 0;
                continue;
            }
            try rows.append(ctx.gpa, .{ .host = h, .name = name, .windows = f.next() orelse "", .created = f.next() orelse "", .attached = std.mem.eql(u8, f.next() orelse "0", "1"), .agent = f.next() orelse "-", .path = f.rest() });
            states[i].sessions += 1;
        }
    }
    return .{ .rows = rows.items, .states = states };
}

fn age(ctx: sys.Ctx, created: []const u8) []const u8 {
    const then = std.fmt.parseInt(i64, created, 10) catch return "?";
    const now = std.Io.Clock.real.now(ctx.io).toSeconds();
    const delta = @max(now - then, 0);
    if (delta < 3600) return ctx.fmt("{d}m", .{@divTrunc(delta, 60)}) catch "?";
    if (delta < 86400) return ctx.fmt("{d}h", .{@divTrunc(delta, 3600)}) catch "?";
    return ctx.fmt("{d}d", .{@divTrunc(delta, 86400)}) catch "?";
}

fn render(ctx: sys.Ctx, reg: hosts.Registry, c: Collected) !void {
    var wh: usize = 7;
    var ws: usize = 7;
    for (c.rows) |r| {
        wh = @max(wh, r.host.name.len);
        ws = @max(ws, r.name.len);
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(ctx.gpa, try ctx.fmt("{s:>3}  {s}  {s}  {s:<8}  {s:>3}  {s:>5}\n", .{ "#", try pad(ctx, "MACHINE", wh), try pad(ctx, "SESSION", ws), "AGENT", "WIN", "AGE" }));
    for (c.rows, 0..) |r, i|
        try out.appendSlice(ctx.gpa, try ctx.fmt("{d:>3}  {s}  {s}  {s:<8}  {s:>3}  {s:>5}  {s}\n", .{ i + 1, try pad(ctx, r.host.name, wh), try pad(ctx, r.name, ws), r.agent, r.windows, age(ctx, r.created), if (r.attached) "attached" else "" }));
    var silent: std.ArrayList(u8) = .empty;
    var loose: std.ArrayList(u8) = .empty;
    var with: usize = 0;
    var without: usize = 0;
    var inferred = false;
    for (c.rows) |r| if (std.mem.endsWith(u8, r.agent, "~")) {
        inferred = true;
    };
    for (reg.hosts, c.states) |h, s| {
        if (!s.ok) {
            try silent.appendSlice(ctx.gpa, try ctx.fmt("{s}{s}", .{ if (silent.items.len > 0) ", " else "", h.name }));
            continue;
        }
        if (s.sessions > 0) with += 1 else without += 1;
        if (s.outside > 0) try loose.appendSlice(ctx.gpa, try ctx.fmt("{s}{s} ({d})", .{ if (loose.items.len > 0) ", " else "", h.name, s.outside }));
    }
    if (inferred) try out.appendSlice(ctx.gpa, "\n~ = agent inferred from the process (session not created by agb)\n");
    try out.appendSlice(ctx.gpa, try ctx.fmt("\n{d} machines: {d} with sessions, {d} without", .{ reg.hosts.len, with, without }));
    if (silent.items.len > 0) try out.appendSlice(ctx.gpa, try ctx.fmt(", no answer from {s}  ->  agb doctor", .{silent.items}));
    try out.append(ctx.gpa, '\n');
    if (loose.items.len > 0) try out.appendSlice(ctx.gpa, try ctx.fmt("agents outside tmux (cannot attach; see agb adopt): {s}\n", .{loose.items}));
    _ = print(ctx, out.items);
}

fn pad(ctx: sys.Ctx, s: []const u8, width: usize) ![]const u8 {
    if (s.len >= width) return s;
    const spaces = try ctx.gpa.alloc(u8, width - s.len);
    @memset(spaces, ' ');
    return std.mem.concat(ctx.gpa, u8, &.{ s, spaces });
}

fn cmdLs(env: Env) !u8 {
    const ctx = env.ctx;
    const reg = try loadRegistry(ctx);
    if (reg.hosts.len == 0) {
        say("no machines registered; start with: agb hosts discover", .{});
        return 1;
    }
    try render(ctx, reg, try collect(ctx, reg));
    return 0;
}

/// `agb repos [machine]`: the repository names `agb new` accepts there.
fn cmdRepos(env: Env, args: []const []const u8) anyerror!u8 {
    const ctx = env.ctx;
    const reg = try loadRegistry(ctx);
    if (args.len > 0) {
        const h = reg.find(args[0]) orelse {
            say("agb: unknown machine {s} (see: agb hosts)", .{args[0]});
            return 1;
        };
        if (!reg.isSelf(h)) {
            const out = remote(ctx, h, &.{"_repos"});
            _ = print(ctx, out.stdout);
            return out.code;
        }
    }
    return main(env, &.{"_repos"});
}

fn readLine(ctx: sys.Ctx) ?[]const u8 {
    var buf: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(ctx.io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch return null;
    return ctx.gpa.dupe(u8, std.mem.trim(u8, line orelse return null, " \r\t")) catch null;
}

fn cmdSessions(env: Env) !u8 {
    const ctx = env.ctx;
    const reg = try loadRegistry(ctx);
    const c = try collect(ctx, reg);
    try render(ctx, reg, c);
    if (c.rows.len == 0) {
        say("\nno sessions yet: agb new [agent] [machine] [repo] [what to do]", .{});
        return 0;
    }
    std.debug.print("\nsession (number or name, empty to quit): ", .{});
    const choice = readLine(ctx) orelse return 0;
    if (choice.len == 0 or std.mem.eql(u8, choice, "q")) return 0;
    const index = blk: {
        if (std.fmt.parseInt(usize, choice, 10)) |n| {
            if (n >= 1 and n <= c.rows.len) break :blk n - 1;
        } else |_| {
            for (c.rows, 0..) |r, i| if (std.mem.eql(u8, r.name, choice)) break :blk i;
        }
        say("agb: '{s}' is not on the list", .{choice});
        return 1;
    };
    return attachRow(env, reg, c.rows[index], false);
}

fn attachRow(env: Env, reg: hosts.Registry, row: Row, detach_others: bool) !u8 {
    if (reg.isSelf(row.host)) local.attach(env.ctx, row.name, detach_others);
    return remoteHandOver(env.ctx, row.host, if (detach_others) &.{ "attach", "-d", row.name } else &.{ "attach", row.name });
}

fn cmdAttach(env: Env, args: []const []const u8) !u8 {
    const ctx = env.ctx;
    var detach_others = false;
    var positional: std.ArrayList([]const u8) = .empty;
    for (args) |a| if (std.mem.eql(u8, a, "-d")) {
        detach_others = true;
    } else try positional.append(ctx.gpa, a);
    if (positional.items.len == 0) {
        say("usage: agb attach [-d] <session> [machine]", .{});
        return 2;
    }
    const name = positional.items[0];
    const reg = try loadRegistry(ctx);
    if (positional.items.len > 1) {
        const h = reg.find(positional.items[1]) orelse {
            say("agb: unknown machine {s} (see: agb hosts)", .{positional.items[1]});
            return 1;
        };
        if (reg.isSelf(h)) local.attach(ctx, name, detach_others);
        return remoteHandOver(ctx, h, if (detach_others) &.{ "attach", "-d", name } else &.{ "attach", name });
    }
    // Called over ssh by another machine: the session is here, skip the network scan.
    if (local.hasSession(ctx, name)) local.attach(ctx, name, detach_others);
    const c = try collect(ctx, reg);
    for (c.rows) |r| if (std.mem.eql(u8, r.name, name)) return attachRow(env, reg, r, detach_others);
    say("agb: no session '{s}' on any registered machine", .{name});
    return 1;
}

/// send/peek/stop <session> [machine] …: the machine is found by asking every
/// registered one when not given.
fn cmdSessionAction(env: Env, verb: []const u8, args: []const []const u8) anyerror!u8 {
    const ctx = env.ctx;
    if (args.len == 0 or (std.mem.eql(u8, verb, "send") and args.len < 2)) {
        say("usage: agb send <session> [machine] <text…> | agb peek <session> [machine] [lines] | agb stop <session> [machine]", .{});
        return 2;
    }
    const reg = try loadRegistry(ctx);
    const name = args[0];
    var rest = args[1..];
    var host: ?hosts.Host = null;
    if (rest.len > 0) if (reg.find(rest[0])) |h| {
        // A lone word after the session is a machine only if it names one.
        if (!(std.mem.eql(u8, verb, "send") and rest.len == 1)) {
            host = h;
            rest = rest[1..];
        }
    };
    if (host == null) {
        if (local.hasSession(ctx, name)) {
            for (reg.hosts) |h| if (reg.isSelf(h)) {
                host = h;
            };
        } else {
            const c = try collect(ctx, reg);
            for (c.rows) |r| if (std.mem.eql(u8, r.name, name)) {
                host = r.host;
            };
        }
    }
    const internal = try ctx.fmt("_{s}", .{verb});
    var call: std.ArrayList([]const u8) = .empty;
    try call.appendSlice(ctx.gpa, &.{ internal, name });
    if (std.mem.eql(u8, verb, "send")) try call.append(ctx.gpa, try std.mem.join(ctx.gpa, " ", rest));
    if (std.mem.eql(u8, verb, "peek") and rest.len > 0) try call.append(ctx.gpa, rest[0]);
    const h = host orelse {
        if (local.hasSession(ctx, name)) return main(env, call.items);
        say("agb: no session '{s}' on any registered machine", .{name});
        return 1;
    };
    if (reg.isSelf(h)) return main(env, call.items);
    const out = remote(ctx, h, call.items);
    _ = print(ctx, out.stdout);
    return out.code;
}

// ---------------------------------------------------------------- hosts

fn cmdHosts(env: Env, args: []const []const u8) !u8 {
    const ctx = env.ctx;
    var reg = try loadRegistry(ctx);
    const sub = if (args.len > 0) args[0] else "show";
    if (std.mem.eql(u8, sub, "show") or std.mem.eql(u8, sub, "list")) {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(ctx.gpa, try ctx.fmt("{s}  {s}  {s}\n", .{ try pad(ctx, "MACHINE", 18), try pad(ctx, "SSH TARGET", 28), "KIND" }));
        for (reg.hosts) |h| try out.appendSlice(ctx.gpa, try ctx.fmt("{s}  {s}  {s}{s}\n", .{ try pad(ctx, h.name, 18), try pad(ctx, h.target, 28), try pad(ctx, @tagName(h.kind), 6), if (reg.isSelf(h)) "  <- this machine" else "" }));
        try out.appendSlice(ctx.gpa, try ctx.fmt("\nregistry: {s}\n", .{reg.path}));
        _ = print(ctx, out.items);
        return 0;
    }
    if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 3) {
            say("usage: agb hosts add <name> <user@host> [posix|msys]", .{});
            return 2;
        }
        if (!sys.validSlug(args[1])) return 2;
        if (reg.find(args[1]) != null and std.mem.eql(u8, reg.find(args[1]).?.name, args[1])) {
            say("{s} is already registered", .{args[1]});
            return 0;
        }
        var list: std.ArrayList(hosts.Host) = .empty;
        try list.appendSlice(ctx.gpa, reg.hosts);
        try list.append(ctx.gpa, .{ .name = args[1], .target = args[2], .kind = if (args.len > 3 and std.mem.eql(u8, args[3], "msys")) .msys else .posix });
        reg.hosts = list.items;
        try hosts.save(ctx, reg, reg.self_line);
        say("registered: {s} -> {s}", .{ args[1], args[2] });
        return 0;
    }
    if (std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "remove")) {
        if (args.len < 2) return 2;
        var list: std.ArrayList(hosts.Host) = .empty;
        for (reg.hosts) |h| if (!std.mem.eql(u8, h.name, args[1])) try list.append(ctx.gpa, h);
        reg.hosts = list.items;
        try hosts.save(ctx, reg, reg.self_line);
        say("removed: {s}", .{args[1]});
        return 0;
    }
    if (std.mem.eql(u8, sub, "self")) {
        if (args.len < 2) return 2;
        try hosts.save(ctx, reg, args[1]);
        say("this machine is: {s}", .{args[1]});
        return 0;
    }
    if (std.mem.eql(u8, sub, "discover")) {
        const peers = hosts.tailnetPeers(ctx) orelse {
            say("agb: tailscale not found; register by hand: agb hosts add <name> <user@host> [posix|msys]", .{});
            return 1;
        };
        var list: std.ArrayList(hosts.Host) = .empty;
        try list.appendSlice(ctx.gpa, reg.hosts);
        var added: usize = 0;
        for (peers) |p| {
            if (std.mem.eql(u8, p.os, "iOS") or std.mem.eql(u8, p.os, "android") or std.mem.eql(u8, p.os, "tvOS")) continue;
            var known = false;
            for (list.items) |h| if (std.mem.eql(u8, h.name, p.name)) {
                known = true;
            };
            if (known) continue;
            const user = sshUser(ctx, p.name);
            try list.append(ctx.gpa, .{ .name = p.name, .target = try ctx.fmt("{s}@{s}", .{ user, p.name }), .kind = if (std.mem.eql(u8, p.os, "windows")) .msys else .posix });
            say("registered: {s} ({s})", .{ p.name, p.os });
            added += 1;
        }
        if (added == 0) say("nothing new: every tailnet machine is registered", .{});
        reg.hosts = list.items;
        try hosts.save(ctx, reg, reg.self_line orelse hosts.tailnetSelf(ctx));
        return 0;
    }
    say("usage: agb hosts [show|discover|add|rm|self]", .{});
    return 2;
}

/// The ssh user for a host: what ~/.ssh/config says, else the local user.
fn sshUser(ctx: sys.Ctx, host: []const u8) []const u8 {
    const out = sys.run(ctx, &.{ "ssh", "-G", host }, null);
    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "user ")) return std.mem.trimEnd(u8, line[5..], "\r");
    return ctx.getenv("USER") orelse ctx.getenv("USERNAME") orelse "user";
}

// ---------------------------------------------------------------- doctor, adopt

fn cmdDoctor(env: Env) !u8 {
    const ctx = env.ctx;
    const reg = try loadRegistry(ctx);
    _ = print(ctx, try ctx.fmt("registry: {s}\nthis machine: {s}\n\n", .{ reg.path, reg.self orelse "<not identified: agb hosts self <name>>" }));
    for (reg.hosts) |h| {
        _ = print(ctx, try ctx.fmt("== {s} {s}\n", .{ try pad(ctx, h.name, 18), h.target }));
        if (reg.isSelf(h)) {
            _ = print(ctx, try ctx.fmt("   local      {s}\n", .{try local.probe(ctx, env.version)}));
            continue;
        }
        const out = remote(ctx, h, &.{"_probe"});
        const line = std.mem.trim(u8, out.stdout, " \r\n");
        if (out.ok and std.mem.startsWith(u8, line, "agb=")) {
            _ = print(ctx, try ctx.fmt("   ssh ok     {s}\n", .{line}));
        } else {
            _ = print(ctx, try ctx.fmt("   FAILED     ssh or agb unavailable (code {d}); check the key is authorized there and run: agb deploy {s}\n", .{ out.code, h.name }));
        }
    }
    return 0;
}

fn cmdAdopt(env: Env, args: []const []const u8) !u8 {
    const ctx = env.ctx;
    const reg = try loadRegistry(ctx);
    const only: ?hosts.Host = if (args.len > 0) reg.find(args[0]) orelse {
        say("agb: unknown machine {s}", .{args[0]});
        return 1;
    } else null;
    const Item = struct { host: hosts.Host, pid: []const u8, agent: []const u8, dir: []const u8, conversation: []const u8 };
    var items: std.ArrayList(Item) = .empty;
    for (reg.hosts) |h| {
        if (only) |o| if (!std.mem.eql(u8, o.name, h.name)) continue;
        if (reg.isSelf(h)) {
            for (try local.adoptList(ctx)) |a| try items.append(ctx.gpa, .{ .host = h, .pid = a.pid, .agent = a.agent, .dir = a.dir, .conversation = a.conversation });
            continue;
        }
        var lines = std.mem.splitScalar(u8, remote(ctx, h, &.{"_adopt-list"}).stdout, '\n');
        while (lines.next()) |raw| {
            var f = std.mem.splitScalar(u8, std.mem.trimEnd(u8, raw, "\r"), '|');
            const pid = f.next() orelse continue;
            if (pid.len == 0) continue;
            try items.append(ctx.gpa, .{ .host = h, .pid = pid, .agent = f.next() orelse "?", .dir = f.next() orelse "?", .conversation = f.next() orelse "" });
        }
    }
    if (items.items.len == 0) {
        say("no agent running outside tmux", .{});
        return 0;
    }
    for (items.items, 0..) |it, i| _ = print(ctx, try ctx.fmt("{d:>3}  {s}  {s:<7}  {s}  {s}\n", .{ i + 1, try pad(ctx, it.host.name, 16), it.agent, if (it.conversation.len > 0) it.conversation[0..8] else "latest  ", it.dir }));
    _ = print(ctx, "\nadopting STOPS the process and reopens the same conversation inside tmux\n(the turn in progress and the scrollback are lost).\n");
    std.debug.print("\nwhich one? (number, empty to quit): ", .{});
    const choice = readLine(ctx) orelse return 0;
    const n = std.fmt.parseInt(usize, choice, 10) catch return 0;
    if (n < 1 or n > items.items.len) return 0;
    const it = items.items[n - 1];
    std.debug.print("stop {s} (pid {s}) on {s} and reopen it in tmux? [y/N] ", .{ it.agent, it.pid, it.host.name });
    const confirm = readLine(ctx) orelse return 0;
    if (!(std.mem.eql(u8, confirm, "y") or std.mem.eql(u8, confirm, "s"))) return 0;
    if (reg.isSelf(it.host)) {
        const name = local.adoptDo(ctx, it.pid) catch |err| {
            say("agb: {s}", .{@errorName(err)});
            return 1;
        };
        local.attach(ctx, name, false);
    }
    const reply = std.mem.trim(u8, remote(ctx, it.host, &.{ "_adopt-do", it.pid }).stdout, " \r\n");
    if (!std.mem.startsWith(u8, reply, "ok|")) {
        say("agb: {s}", .{reply});
        return 1;
    }
    return remoteHandOver(ctx, it.host, &.{ "attach", reply[3..] });
}

// ---------------------------------------------------------------- deploy

/// Builds agb for each machine's OS and CPU from this checkout and installs it
/// there with the registry (its own `self` line).
fn cmdDeploy(env: Env, args: []const []const u8) !u8 {
    const ctx = env.ctx;
    const reg = try loadRegistry(ctx);
    if (args.len == 0) {
        say("usage: agb deploy <machine…|--all>", .{});
        return 2;
    }
    if (sys.which(ctx, "zig") == null or !sys.isFile(ctx, try ctx.join(&.{ env.source_root, "build.zig" }))) {
        say("agb deploy builds from source: needs zig and the checkout at {s}", .{env.source_root});
        return 1;
    }
    var failures: usize = 0;
    for (reg.hosts) |h| {
        if (reg.isSelf(h)) continue;
        var wanted = std.mem.eql(u8, args[0], "--all");
        for (args) |a| if (reg.find(a)) |f| if (std.mem.eql(u8, f.name, h.name)) {
            wanted = true;
        };
        if (!wanted) continue;
        deployOne(env, reg, h) catch |err| {
            say("== {s}: FAILED ({s})", .{ h.name, @errorName(err) });
            failures += 1;
        };
    }
    return if (failures == 0) 0 else 1;
}

fn deployOne(env: Env, reg: hosts.Registry, h: hosts.Host) !void {
    const ctx = env.ctx;
    const ssh_opts = [_][]const u8{ "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new" };
    const target: []const u8 = switch (h.kind) {
        .msys => "x86_64-windows-gnu",
        .posix => blk: {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(ctx.gpa, "ssh");
            try argv.appendSlice(ctx.gpa, &ssh_opts);
            try argv.appendSlice(ctx.gpa, &.{ h.target, "uname -sm" });
            const out = sys.run(ctx, argv.items, null);
            if (!out.ok) return error.Unreachable;
            const u = out.text();
            const arm = std.mem.indexOf(u8, u, "arm64") != null or std.mem.indexOf(u8, u, "aarch64") != null;
            if (std.mem.startsWith(u8, u, "Darwin")) break :blk if (arm) "aarch64-macos" else "x86_64-macos";
            break :blk if (arm) "aarch64-linux-musl" else "x86_64-linux-musl";
        },
    };
    std.debug.print("== {s}: building for {s}\n", .{ h.name, target });
    const prefix = try ctx.fmt("{s}/zig-out/deploy-{s}", .{ env.source_root, target });
    const build = sys.run(ctx, &.{ "zig", "build", try ctx.fmt("-Dtarget={s}", .{target}), "-Doptimize=ReleaseSafe", "--prefix", prefix }, env.source_root);
    if (!build.ok) {
        std.debug.print("{s}", .{build.stderr});
        return error.BuildFailed;
    }
    const exe = if (h.kind == .msys) "agb.exe" else "agb";
    const built = try ctx.fmt("{s}/bin/{s}", .{ prefix, exe });
    const config = try hosts.renderFor(ctx, reg, h.name);
    const user = h.target[0 .. std.mem.indexOfScalar(u8, h.target, '@') orelse 0];
    var mk: std.ArrayList([]const u8) = .empty;
    try mk.append(ctx.gpa, "ssh");
    try mk.appendSlice(ctx.gpa, &ssh_opts);
    try mk.append(ctx.gpa, h.target);
    switch (h.kind) {
        // The bash tools agb replaced (work, work-session, tm) go, as install.sh does on the Mac.
        .posix => try mk.append(ctx.gpa, "mkdir -p ~/.local/bin ~/.config/work && rm -f ~/.local/bin/work ~/.local/bin/work-session ~/.local/bin/tm"),
        // Also puts ~\.local\bin on the user's PATH, so `agb` works in any new terminal.
        .msys => try mk.append(ctx.gpa, try ctx.fmt("New-Item -ItemType Directory -Force -Path C:\\Users\\{s}\\.local\\bin,C:\\Users\\{s}\\.config\\work | Out-Null; $b='C:\\Users\\{s}\\.local\\bin'; $p=[Environment]::GetEnvironmentVariable('Path','User'); if (($p -split ';') -notcontains $b) {{ [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(';') + ';' + $b), 'User') }}; " ++
            // A running agb.exe (an attached terminal) cannot be overwritten, only renamed.
            "Remove-Item \"$b\\agb.old-*.exe\",\"$b\\work\",\"$b\\work-session\",\"$b\\tm\" -ErrorAction SilentlyContinue; if (Test-Path \"$b\\agb.exe\") {{ Move-Item -Force \"$b\\agb.exe\" \"$b\\agb.old-$([DateTime]::Now.Ticks).exe\" }}", .{ user, user, user })),
    }
    if (!sys.run(ctx, mk.items, null).ok) return error.Unreachable;
    const dest_bin = switch (h.kind) {
        // Copied aside and renamed over: a running agb (an attached terminal) is "text file busy".
        .posix => try ctx.fmt("{s}:.local/bin/agb.new", .{h.target}),
        .msys => try ctx.fmt("{s}:C:/Users/{s}/.local/bin/agb.exe", .{ h.target, user }),
    };
    const tmp_conf = try ctx.fmt("{s}/hosts.conf", .{prefix});
    try sys.writeFileAtomic(ctx, tmp_conf, config);
    const dest_conf = switch (h.kind) {
        .posix => try ctx.fmt("{s}:.config/work/hosts.conf", .{h.target}),
        .msys => try ctx.fmt("{s}:C:/Users/{s}/.config/work/hosts.conf", .{ h.target, user }),
    };
    var scp: std.ArrayList([]const u8) = .empty;
    try scp.append(ctx.gpa, "scp");
    try scp.appendSlice(ctx.gpa, &ssh_opts);
    try scp.appendSlice(ctx.gpa, &.{ "-q", built, dest_bin });
    if (!sys.run(ctx, scp.items, null).ok) return error.CopyFailed;
    scp.items[scp.items.len - 2] = tmp_conf;
    scp.items[scp.items.len - 1] = dest_conf;
    if (!sys.run(ctx, scp.items, null).ok) return error.CopyFailed;
    if (h.kind == .posix) {
        var mv: std.ArrayList([]const u8) = .empty;
        try mv.append(ctx.gpa, "ssh");
        try mv.appendSlice(ctx.gpa, &ssh_opts);
        try mv.appendSlice(ctx.gpa, &.{ h.target, "mv -f ~/.local/bin/agb.new ~/.local/bin/agb" });
        if (!sys.run(ctx, mv.items, null).ok) return error.CopyFailed;
    }
    if (h.kind == .msys) try deployTray(ctx, h, user, prefix, &ssh_opts);
    const probe = remote(ctx, h, &.{"_probe"});
    std.debug.print("   {s}\n", .{if (probe.ok) std.mem.trim(u8, probe.stdout, " \r\n") else "installed, but agb did not answer"});
}

/// The Windows tray daemon is locked while it runs: it is copied aside, swapped
/// in, and a running one is restarted in the logged-on user's desktop session
/// (a process started over ssh would live in the invisible service session).
fn deployTray(ctx: sys.Ctx, h: hosts.Host, user: []const u8, prefix: []const u8, ssh_opts: []const []const u8) !void {
    const bin = try ctx.fmt("C:\\Users\\{s}\\.local\\bin", .{user});
    var scp: std.ArrayList([]const u8) = .empty;
    try scp.append(ctx.gpa, "scp");
    try scp.appendSlice(ctx.gpa, ssh_opts);
    try scp.appendSlice(ctx.gpa, &.{ "-q", try ctx.fmt("{s}/bin/agent-belt.exe", .{prefix}), try ctx.fmt("{s}:C:/Users/{s}/.local/bin/agent-belt.new.exe", .{ h.target, user }) });
    if (!sys.run(ctx, scp.items, null).ok) return error.CopyFailed;
    const script = try ctx.fmt(
        "$b='{s}'; $run=[bool](Get-Process agent-belt -ErrorAction SilentlyContinue); " ++
            "Stop-Process -Name agent-belt -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; " ++
            "Move-Item -Force \"$b\\agent-belt.new.exe\" \"$b\\agent-belt.exe\"; " ++
            "if ($run) {{ schtasks /create /tn AgentBelt /tr \"$b\\agent-belt.exe\" /sc once /st 00:00 /it /f | Out-Null; schtasks /run /tn AgentBelt | Out-Null; 'tray restarted' }} else {{ 'tray installed (agb install starts it at login)' }}",
        .{bin},
    );
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.gpa, "ssh");
    try argv.appendSlice(ctx.gpa, ssh_opts);
    try argv.appendSlice(ctx.gpa, &.{ h.target, script });
    const out = sys.run(ctx, argv.items, null);
    std.debug.print("   {s}\n", .{std.mem.trim(u8, if (out.ok) out.stdout else out.stderr, " \r\n")});
}

// ---------------------------------------------------------------- tests

fn noRepos(_: sys.Ctx, _: ?hosts.Host, name: []const u8) bool {
    return std.mem.eql(u8, name, "coreum") or std.mem.eql(u8, name, "agent-belt");
}

test "humane agb new" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
    var list = [_]hosts.Host{
        .{ .name = "macbook-pro", .target = "frb@macbook-pro", .kind = .posix },
        .{ .name = "felipe-windows", .target = "Micromed@felipe-windows", .kind = .msys },
        .{ .name = "frb-linux2", .target = "frb@frb-linux2", .kind = .posix },
    };
    const reg = hosts.Registry{ .path = "", .hosts = &list, .self_line = "macbook-pro", .self = "macbook-pro" };

    var p = try parseNew(ctx, reg, &.{ "codex", "windows", "coreum", "fix", "the", "login" }, noRepos);
    try std.testing.expectEqual(local.Agent.codex, p.agent);
    try std.testing.expectEqualStrings("felipe-windows", p.host.?.name);
    try std.testing.expectEqualStrings("coreum", p.repo.?);
    try std.testing.expectEqualStrings("fix the login", p.prompt.?);
    try std.testing.expectEqualStrings("fix-the-login", p.task.?);

    p = try parseNew(ctx, reg, &.{}, noRepos); // agb new: claude, here, this repo
    try std.testing.expectEqual(local.Agent.claude, p.agent);
    try std.testing.expect(p.host == null and p.repo == null and p.prompt == null);
    try std.testing.expectEqualStrings("claude", p.task.?);

    p = try parseNew(ctx, reg, &.{ "here", "agent-belt", "review", "the", "readme" }, noRepos);
    try std.testing.expect(p.host == null);
    try std.testing.expectEqualStrings("agent-belt", p.repo.?);

    p = try parseNew(ctx, reg, &.{ "macbook-pro", "coreum" }, noRepos); // naming this machine = here
    try std.testing.expect(p.host == null);

    p = try parseNew(ctx, reg, &.{ "linux2", "look", "at", "logs" }, noRepos); // no repo word: all prompt
    try std.testing.expectEqualStrings("frb-linux2", p.host.?.name);
    try std.testing.expect(p.repo == null);
    try std.testing.expectEqualStrings("look at logs", p.prompt.?);

    p = try parseNew(ctx, reg, &.{ "shell", "--task", "scratch", "--host", "here" }, noRepos);
    try std.testing.expectEqual(local.Agent.shell, p.agent);
    try std.testing.expectEqualStrings("scratch", p.task.?);

    try std.testing.expectError(error.UnknownHost, parseNew(ctx, reg, &.{ "--host", "mars" }, noRepos));
    try std.testing.expect(isNaturalLanguage("crie"));
    try std.testing.expect(!isNaturalLanguage("codex"));

    const detected = intent.Plan{ .agent = "codex", .agent_confidence = 1, .host = "felipe-windows", .host_confidence = 1, .repo = "coreum", .repo_confidence = 1, .task = "login-bug", .prompt = "Look into it", .hosts = &.{}, .repos = &.{} };
    const plan = try planFromIntent(reg, detected);
    try std.testing.expectEqualStrings("felipe-windows", plan.host.?.name);
    try std.testing.expectEqual(local.Agent.codex, plan.agent);
    try std.testing.expectEqualStrings("login-bug", plan.task.?);
    var unsafe = detected;
    unsafe.repo = "x; rm -rf ~";
    try std.testing.expectError(error.UnsafeRepo, planFromIntent(reg, unsafe));
    var mars = detected;
    mars.host = "mars";
    try std.testing.expectError(error.UnknownHost, planFromIntent(reg, mars));
    var here = detected;
    here.host = "macbook-pro";
    try std.testing.expect((try planFromIntent(reg, here)).host == null);
}
