//! A spoken request for a new agent ("crie um agente com codex no windows no
//! web-app para investigar o login") turned into its four parts: harness,
//! machine, repo and intent. Jev picks harness, machine and repo from the known
//! options (it decides, it does not generate); the intent is the request
//! itself. `agb _intent` answers the create-agent panel in JSON.
const std = @import("std");
const sys = @import("sys.zig");
const hosts = @import("hosts.zig");
const local = @import("local.zig");
const jev = @import("jev.zig");
const deepseek = @import("deepseek.zig");

pub const Fixed = struct { agent: ?[]const u8 = null, host: ?[]const u8 = null, repo: ?[]const u8 = null, no_repo: bool = false };

pub const Plan = struct {
    agent: []const u8,
    agent_confidence: f64,
    host: []const u8,
    host_confidence: f64,
    repo: ?[]const u8,
    repo_confidence: f64,
    task: []const u8,
    prompt: []const u8,
    hosts: []const []const u8,
    repos: []const []const u8,
};

// ---------------------------------------------------------------- repo index

fn cacheDir(ctx: sys.Ctx) ![]const u8 {
    const base = if (sys.platform == .windows)
        ctx.getenv("LOCALAPPDATA") orelse ctx.home()
    else
        ctx.getenv("XDG_CACHE_HOME") orelse try ctx.join(&.{ ctx.home(), ".cache" });
    return ctx.join(&.{ base, "agent-belt", "repos" });
}

/// The repos of a machine from the index, without touching the network.
pub fn cachedRepos(ctx: sys.Ctx, host: []const u8) ![]const []const u8 {
    const text = sys.readFile(ctx, try ctx.join(&.{ try cacheDir(ctx), host })) orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |n| try names.append(ctx.gpa, n);
    return names.items;
}

/// Words the speech model should favor when a new agent is dictated: the
/// harnesses, the machines and every repo in the index.
pub fn keyterms(ctx: sys.Ctx, reg: hosts.Registry) ![]const []const u8 {
    var terms: std.ArrayList([]const u8) = .empty;
    try terms.appendSlice(ctx.gpa, &.{ "claude", "codex", "shell" });
    for (reg.hosts) |h| {
        try terms.append(ctx.gpa, h.name);
        for (try cachedRepos(ctx, h.name)) |r| {
            if (terms.items.len >= 90) break;
            if (r.len <= 40 and !contains(terms.items, r)) try terms.append(ctx.gpa, r);
        }
    }
    return terms.items;
}

/// `agb _repos-cache`: asks every machine for its repos (in parallel) and
/// rewrites the index. Run in the background when the panel opens.
pub fn refreshCache(ctx: sys.Ctx, reg: hosts.Registry, repos_of: *const fn (sys.Ctx, hosts.Host) ?[]const u8) !void {
    const dir = try cacheDir(ctx);
    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
    const Worker = struct {
        fn run(c: sys.Ctx, h: hosts.Host, d: []const u8, f: *const fn (sys.Ctx, hosts.Host) ?[]const u8) void {
            const list = f(c, h) orelse return; // unreachable machine: keep the old index
            sys.writeFileAtomic(c, c.join(&.{ d, h.name }) catch return, list) catch {};
        }
    };
    const threads = try ctx.gpa.alloc(?std.Thread, reg.hosts.len);
    for (reg.hosts, threads) |h, *t| t.* = std.Thread.spawn(.{}, Worker.run, .{ ctx, h, dir, repos_of }) catch null;
    for (threads) |t| if (t) |th| th.join();
}

// ---------------------------------------------------------------- key

/// A service key: the environment, else the Keychain (service agent-belt),
/// else ~/.config/agent-belt/<account>.key.
fn apiKey(ctx: sys.Ctx, env_name: []const u8, account: []const u8) ?[]const u8 {
    if (ctx.getenv(env_name)) |k| if (k.len > 0) return k;
    if (sys.platform == .mac) {
        const out = sys.run(ctx, &.{ "security", "find-generic-password", "-s", "agent-belt", "-a", account, "-w" }, null);
        const k = std.mem.trim(u8, out.stdout, " \r\n");
        if (out.ok and k.len > 0) return k;
    }
    const file = ctx.join(&.{ ctx.home(), ".config", "agent-belt", ctx.fmt("{s}.key", .{account}) catch return null }) catch return null;
    const k = std.mem.trim(u8, sys.readFile(ctx, file) orelse return null, " \r\n");
    return if (k.len > 0) k else null;
}

// ---------------------------------------------------------------- intent text

/// Words that make an opening clause a request for a session, not the work.
const session_words = [_][]const u8{ "agente", "agent", "sessão", "sessao", "session", "shell", "terminal", "claude", "codex", "codecs" };

/// The work, in the person's own words: what follows "para"/"pra" when the
/// short opening clause before it asks for a session ("crie um agente no linux
/// com claude code para …"), else the whole request. Never rewritten.
pub fn intentOf(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " .\r\n");
    var lower_buf: [160]u8 = undefined;
    const n = @min(t.len, lower_buf.len);
    const lower = std.ascii.lowerString(lower_buf[0..n], t[0..n]);
    for ([_][]const u8{ " para ", " pra ", " to " }) |marker| {
        const at = std.mem.indexOf(u8, lower, marker) orelse continue;
        const before = lower[0..at];
        for (session_words) |w| if (std.mem.indexOf(u8, before, w) != null) {
            const rest = std.mem.trim(u8, t[at + marker.len ..], " .");
            if (rest.len > 0) return rest;
        };
    }
    return t;
}

const stopwords = [_][]const u8{ "o", "a", "os", "as", "um", "uma", "de", "do", "da", "dos", "das", "no", "na", "em", "e", "que", "the", "a", "an", "to", "of" };

/// A short task slug from the first meaningful words of the intent.
pub fn taskOf(ctx: sys.Ctx, intent: []const u8) ![]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, intent, " ,.;:!?\t");
    while (it.next()) |w| {
        var skip = false;
        for (stopwords) |s| if (std.ascii.eqlIgnoreCase(w, s)) {
            skip = true;
        };
        if (!skip) try words.append(ctx.gpa, w);
        if (words.items.len == 4) break;
    }
    const slug = try sys.slugFromWords(ctx, try std.mem.join(ctx.gpa, " ", words.items), 4);
    return if (slug.len > 0) slug else "agent";
}

// ---------------------------------------------------------------- name and summary

pub const Summary = struct { name: []const u8, summary: []const u8, prompt: []const u8 = "", by: []const u8 };

/// The whole instruction for the cleaning model (kept identical, first).
const cleaning =
    \\You clean a voice-dictated request to start a coding agent. The speech-to-text may misspell names ("cloud" or "clode" = Claude, "codecs" = Codex).
    \\The request mixes routing (asking to create or open an agent or session, which agent, which machine, which repository or folder) with the work. Routing is decided elsewhere: drop it entirely.
    \\Reply with only JSON:
    \\{"prompt": "<the work, in the request's language and the person's own words: routing removed, obvious transcription errors fixed; add nothing, no headings, no lists, no rephrasing beyond that>", "summary": "<one short sentence, in the request's language, of what the agent will do>", "name": "<2 to 4 lowercase English words joined by hyphens naming the work>"}
    \\Example: "crie um agente com cloud no repositório xyz que revise o login e veja por que o token expira sedo" -> {"prompt": "Revise o login e veja por que o token expira cedo.", "summary": "Revisar o login e investigar a expiração precoce do token.", "name": "login-token-expiry"}
;

/// The request cleaned for the agent: the spoken routing ("crie um agente
/// com claude no repositório xyz que…", which Jev decides) removed and
/// transcription errors fixed, in the person's own words, never embellished;
/// plus a short session name and a one-line summary. Written by a small model
/// with no reasoning: DeepSeek Flash over HTTP, about a second
/// (DEEPSEEK_API_KEY); without it, Codex (gpt-6-luna), then Claude Sonnet.
/// Without any, the words after the routing clause (`intentOf`). Cached by text.
pub fn summarize(ctx: sys.Ctx, text: []const u8) !Summary {
    const request = std.mem.trim(u8, text, " \r\n");
    const work = intentOf(request);
    const fallback = Summary{ .name = try taskOf(ctx, work), .summary = work, .prompt = work, .by = "words" };
    if (request.len == 0) return fallback;
    const cache = try ctx.join(&.{ try cacheDir(ctx), "..", "names", try ctx.fmt("{x}", .{std.hash.Wyhash.hash(0, request)}) });
    if (sys.readFile(ctx, cache)) |bytes| {
        if (std.json.parseFromSliceLeaky(Summary, ctx.gpa, bytes, .{ .ignore_unknown_fields = true })) |cached| return cached else |_| {}
    }
    const workdir = std.fs.path.dirname(cache).?;
    std.Io.Dir.cwd().createDirPath(ctx.io, workdir) catch {};
    const reply = generate(ctx, request, workdir) orelse return fallback;
    // A CLI's answer may be fenced (```json … ```): the outermost braces.
    const open = std.mem.indexOfScalar(u8, reply.text, '{') orelse return fallback;
    const close = std.mem.lastIndexOfScalar(u8, reply.text, '}') orelse return fallback;
    if (close < open) return fallback;
    const Parsed = struct { name: []const u8 = "", summary: []const u8 = "", prompt: []const u8 = "" };
    const parsed = std.json.parseFromSliceLeaky(Parsed, ctx.gpa, reply.text[open .. close + 1], .{ .ignore_unknown_fields = true }) catch return fallback;
    const name = try sys.slugFromWords(ctx, try std.mem.replaceOwned(u8, ctx.gpa, parsed.name, "-", " "), 4);
    if (name.len == 0 or name.len > 32 or !sys.validSlug(name)) return fallback;
    const result = Summary{
        .name = name,
        .summary = if (parsed.summary.len > 0) parsed.summary else fallback.summary,
        .prompt = if (parsed.prompt.len > 0) parsed.prompt else work,
        .by = reply.by,
    };
    sys.writeFileAtomic(ctx, cache, try ctx.fmt("{f}", .{std.json.fmt(result, .{})})) catch {};
    return result;
}

const Reply = struct { text: []const u8, by: []const u8 };

/// DeepSeek over HTTP when its key is at hand. Otherwise an agent CLI with low
/// reasoning (Claude with its own system prompt and tools replaced), on macOS
/// and Linux through the user's interactive login shell: processes started by
/// launchd lack the PATH (asdf shims) set in ~/.zshrc.
fn generate(ctx: sys.Ctx, request: []const u8, workdir: []const u8) ?Reply {
    if (deepseekKey(ctx)) |key| {
        if (deepseek.json(ctx.gpa, ctx.io, key, cleaning, request)) |t| return .{ .text = t, .by = "deepseek" } else |err|
            std.debug.print("[agent-belt] cleaning by DeepSeek failed ({s})\n", .{@errorName(err)});
    }
    const task = ctx.fmt("{s}\n\nRequest: {s}", .{ cleaning, request }) catch return null;
    if (sys.platform == .windows) {
        const attempts = [_]struct { []const u8, []const []const u8 }{
            .{ "codex", &.{ "exec", "--skip-git-repo-check", "-m", "gpt-6-luna", "-c", "model_reasoning_effort=low", task } },
            .{ "claude", &.{ "-p", "--model", "sonnet", "--effort", "low", "--tools", "", "--system-prompt", cleaning, "--output-format", "text", request } },
        };
        for (attempts) |a| {
            const bin = sys.which(ctx, a[0]) orelse continue;
            const out = sys.run(ctx, std.mem.concat(ctx.gpa, []const u8, &.{ &.{bin}, a[1] }) catch continue, workdir);
            if (out.ok and std.mem.indexOf(u8, out.stdout, "\"name\"") != null) return .{ .text = out.stdout, .by = a[0] };
        }
        return null;
    }
    const script = "try() { by=$1; shift; command -v \"$1\" >/dev/null 2>&1 || return 1; out=$(\"$@\" 2>/dev/null) || return 1; " ++
        "case \"$out\" in *'\"name\"'*) printf 'AGB-BY:%s\\n%s' \"$by\" \"$out\"; exit 0;; esac; return 1; }; " ++
        "try codex codex exec --skip-git-repo-check -m gpt-6-luna -c model_reasoning_effort=low \"$AGB_TASK\"; " ++
        "try claude claude -p --model sonnet --effort low --tools '' --system-prompt \"$AGB_SYSTEM\" --output-format text " ++
        "--setting-sources '' --strict-mcp-config --disable-slash-commands \"$AGB_REQUEST\"; exit 1";
    ctx.env.put("AGB_TASK", task) catch return null;
    ctx.env.put("AGB_SYSTEM", cleaning) catch return null;
    ctx.env.put("AGB_REQUEST", request) catch return null;
    const shell = ctx.getenv("SHELL") orelse "/bin/sh";
    const out = sys.run(ctx, &.{ shell, "-lic", script }, workdir);
    if (!out.ok) return null;
    const marker = std.mem.lastIndexOf(u8, out.stdout, "AGB-BY:") orelse return null;
    const rest = out.stdout[marker + 7 ..];
    const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
    return .{ .text = rest[nl + 1 ..], .by = rest[0..nl] };
}

/// DEEPSEEK_API_KEY from the environment, else as the login shell sets it
/// (~/.zshrc: launchd's daemon does not have it; it imports it once at start,
/// see `importDeepseekKey`), else ~/.config/agent-belt/deepseek.key.
fn deepseekKey(ctx: sys.Ctx) ?[]const u8 {
    if (ctx.getenv("DEEPSEEK_API_KEY")) |k| if (k.len > 0) return k;
    if (loginShellKey(ctx)) |k| return k;
    const file = ctx.join(&.{ ctx.home(), ".config", "agent-belt", "deepseek.key" }) catch return null;
    const k = std.mem.trim(u8, sys.readFile(ctx, file) orelse return null, " \r\n");
    return if (k.len > 0) k else null;
}

fn loginShellKey(ctx: sys.Ctx) ?[]const u8 {
    if (sys.platform == .windows) return null;
    const shell = ctx.getenv("SHELL") orelse return null;
    const out = sys.run(ctx, &.{ shell, "-lic", "printf 'AGB-KEY:%s' \"$DEEPSEEK_API_KEY\"" }, null);
    const at = std.mem.lastIndexOf(u8, out.stdout, "AGB-KEY:") orelse return null;
    const k = std.mem.trim(u8, out.stdout[at + 8 ..], " \r\n");
    return if (out.ok and k.len > 0) k else null;
}

/// For a daemon started without the login environment: DEEPSEEK_API_KEY read
/// once from the login shell into this process's environment, so every
/// `agb _summary` it runs finds it without starting a shell.
pub fn importDeepseekKey(ctx: sys.Ctx) void {
    if (sys.platform == .windows) return;
    if (ctx.getenv("DEEPSEEK_API_KEY") != null) return;
    const k = loginShellKey(ctx) orelse return;
    const z = ctx.gpa.dupeZ(u8, k) catch return;
    _ = setenv("DEEPSEEK_API_KEY", z, 1);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// ---------------------------------------------------------------- detection

/// Harness, machine and repo for a request. Exact names are matched in code;
/// Jev decides the rest (misheard names, "linux dois", the repo). With one
/// machine, the machine is this one and never asked. `fixed` parts are kept.
pub fn detect(ctx: sys.Ctx, reg: hosts.Registry, text: []const u8, fixed: Fixed) !Plan {
    var host_names: std.ArrayList([]const u8) = .empty;
    for (reg.hosts) |h| try host_names.append(ctx.gpa, h.name);
    const self_name = reg.self orelse (if (reg.hosts.len > 0) reg.hosts[0].name else "here");
    const intent = intentOf(text);
    var plan = Plan{
        .agent = fixed.agent orelse "claude",
        .agent_confidence = if (fixed.agent != null) 1 else 0,
        .host = fixed.host orelse self_name,
        .host_confidence = if (fixed.host != null or reg.hosts.len <= 1) 1 else 0,
        .repo = fixed.repo,
        .repo_confidence = if (fixed.repo != null) 1 else 0,
        .task = try taskOf(ctx, intent),
        // The work in the person's own words, without the routing clause.
        .prompt = intent,
        .hosts = host_names.items,
        .repos = &.{},
    };
    if (std.mem.trim(u8, text, " ").len == 0) {
        plan.repos = try cachedRepos(ctx, plan.host);
        return plan;
    }
    var said_agent = fixed.agent != null;
    var said_host = fixed.host != null or reg.hosts.len <= 1;
    if (!said_agent) if (exactAgent(text)) |a| {
        plan.agent = a;
        plan.agent_confidence = 1;
        said_agent = true;
    };
    if (!said_host) if (try exactHost(ctx, reg, text)) |h| {
        plan.host = h;
        plan.host_confidence = 0.9;
        said_host = true;
    };
    // Named outright (or fixed): it beats the repo. Jev's answer does not.
    const host_named = said_host;

    const key = apiKey(ctx, "TYPESAFE_API_KEY", "jev") orelse return error.JevKeyMissing;
    var client = jev.Client.init(ctx.gpa, ctx.io, key);
    defer client.deinit();
    const State = struct { request: []const u8 };
    const state = State{ .request = text };

    // What code could not match exactly, and the repo, in one request: the repo
    // among every machine's repos (Jev takes up to 255 options).
    var questions: std.ArrayList(jev.Question) = .empty;
    if (!said_agent) try questions.append(ctx.gpa, .{
        .key = "harness",
        .instructions = "Which coding agent does the spoken request ask to start? It was transcribed from speech, so names may be misspelled: \"codecs\" means codex, \"cloud\" means claude.",
        .options = &.{
            .{ .name = "claude", .description = "Claude Code" },
            .{ .name = "codex", .description = "OpenAI Codex" },
            .{ .name = "shell", .description = "a plain shell or terminal, no agent" },
            .{ .name = "unspecified", .description = "the request names no agent" },
        },
    });
    if (!said_host) {
        var options: std.ArrayList(jev.Option) = .empty;
        for (reg.hosts) |h| try options.append(ctx.gpa, .{ .name = h.name, .description = try hostDescription(ctx, h, self_name) });
        try options.append(ctx.gpa, .{ .name = "unspecified", .description = "the request names no machine" });
        try questions.append(ctx.gpa, .{ .key = "machine", .instructions = "On which machine should the new agent run?", .options = options.items });
    }
    var said_repo = fixed.repo != null or fixed.no_repo;
    // "no mac debian" names where to work; "alternativas ao tmux" names a topic.
    var repo_as_place = false;
    if (!said_repo) {
        const sources: []const []const u8 = if (fixed.host != null) &.{plan.host} else host_names.items;
        if (try exactRepo(ctx, reg, sources, text, if (said_host and fixed.host == null) plan.host else null)) |r| {
            plan.repo = r;
            plan.repo_confidence = 0.95;
            said_repo = true;
            repo_as_place = try saidAsPlace(ctx, text, r);
        }
    }
    if (!said_repo) {
        const sources: []const []const u8 = if (fixed.host != null) &.{plan.host} else host_names.items;
        if (try repoQuestion(ctx, reg, sources)) |q| try questions.append(ctx.gpa, q);
    }
    // Research needs no repo, even when it is about something that names one
    // ("alternativas ao tmux" when there is a tmux repo).
    if (!fixed.no_repo and fixed.repo == null) try questions.append(ctx.gpa, .{
        .key = "workspace",
        .instructions = "Where will the new coding agent work? Names of tools or topics that the request is about are not where it works.",
        .options = &.{
            .{ .name = "repository", .description = "changing, reviewing, debugging or building code in an existing repository" },
            .{ .name = "research", .description = "research, comparison, writing or exploration that needs no existing codebase" },
        },
    });
    var found = Found{ .said_host = said_host };
    if (questions.items.len > 0) {
        const answers = try client.choices(ctx.gpa, state, questions.items);
        applyAnswers(&plan, &found, text, questions.items, answers);
    }
    said_host = found.said_host;

    if (found.research and !repo_as_place) {
        plan.repo = null;
        plan.repo_confidence = 1;
    }

    if (fixed.host == null) try settleMachine(ctx, reg, &plan, host_named, said_host, found.host_guess, self_name);
    plan.repos = try cachedRepos(ctx, plan.host);
    return plan;
}

/// The repo among every machine's repos (Jev takes up to 255 options), or
/// null when no repo is known.
fn repoQuestion(ctx: sys.Ctx, reg: hosts.Registry, sources: []const []const u8) !?jev.Question {
    var repo_names: std.ArrayList([]const u8) = .empty;
    for (sources) |h| for (try cachedRepos(ctx, h)) |r| {
        if (!contains(repo_names.items, r)) try repo_names.append(ctx.gpa, r);
    };
    if (repo_names.items.len == 0) return null;
    var options: std.ArrayList(jev.Option) = .empty;
    for (repo_names.items[0..@min(repo_names.items.len, 250)]) |r| try options.append(ctx.gpa, .{ .name = r });
    try options.append(ctx.gpa, .{ .name = "unspecified", .description = "the request names no repository" });
    return .{
        .key = "repo",
        .instructions = try ctx.fmt("Which of these git repositories should the new agent work in? Names were transcribed from speech and may be split or misspelled (\"web app\" can be \"web-app\", \"mac tools\" is \"mac-tools\"). The request may also name the machine ({s}); a machine name is not the repository.", .{try machineWords(ctx, reg)}),
        .options = options.items,
    };
}

/// What Jev's answers said beyond the plan itself.
const Found = struct {
    said_host: bool,
    host_guess: ?[]const u8 = null,
    research: bool = false,
};

fn applyAnswers(plan: *Plan, found: *Found, text: []const u8, questions: []const jev.Question, answers: anytype) void {
    for (questions, answers) |q, ans| {
        if (std.mem.eql(u8, ans.choice, "unspecified")) continue;
        if (std.mem.eql(u8, q.key, "harness")) {
            plan.agent = ans.choice;
            plan.agent_confidence = ans.confidence;
        } else if (std.mem.eql(u8, q.key, "workspace")) {
            found.research = std.mem.eql(u8, ans.choice, "research") and ans.confidence >= 0.8 and !saysRepo(text);
        } else if (std.mem.eql(u8, q.key, "machine")) {
            // Unsure (it confuses "mac-debian" with the Mac): only a tiebreak.
            if (ans.confidence >= 0.6) {
                plan.host = ans.choice;
                plan.host_confidence = ans.confidence;
                found.said_host = true;
            } else found.host_guess = ans.choice;
        } else {
            plan.repo = ans.choice;
            plan.repo_confidence = ans.confidence;
        }
    }
}

/// The repo settles the machine: kept if the machine said has it, moved when
/// only one other machine has it ("mac debian" lives on the second Linux).
/// A machine named outright stays: a repo it lacks is dropped instead (the
/// person picks one, or the agent works without).
fn settleMachine(ctx: sys.Ctx, reg: hosts.Registry, plan: *Plan, host_named: bool, said_host: bool, host_guess: ?[]const u8, self_name: []const u8) !void {
    const repo = plan.repo orelse return;
    const has = try hostsWith(ctx, reg, repo);
    if (contains(has, plan.host)) return;
    if (host_named) {
        plan.repo = null;
        plan.repo_confidence = 0;
        return;
    }
    // Jev's machine, or none: the repo's machine instead.
    const guess = host_guess orelse (if (said_host) plan.host else null);
    const pick: ?[]const u8 = if (has.len == 1) has[0] else if (guess != null and contains(has, guess.?)) guess else if (contains(has, self_name)) self_name else null;
    if (pick) |h| {
        plan.host = h;
        plan.host_confidence = plan.repo_confidence;
    }
}

/// The repo's name follows a word that makes it a place: "no mac tools",
/// "em api", "in web-app", "repo agent-belt".
fn saidAsPlace(ctx: sys.Ctx, text: []const u8, repo: []const u8) !bool {
    const list = try wordsOf(ctx, text);
    const lower = try std.ascii.allocLowerString(ctx.gpa, repo);
    const first = std.mem.sliceTo(try std.mem.replaceOwned(u8, ctx.gpa, lower, "-", " "), ' ');
    for (list, 0..) |w, i| {
        if (i == 0 or !(std.mem.eql(u8, w, lower) or std.mem.eql(u8, w, first))) continue;
        for ([_][]const u8{ "no", "na", "em", "in", "on", "repo", "repositório", "repositorio", "dentro" }) |place| {
            if (std.mem.eql(u8, list[i - 1], place)) return true;
        }
    }
    return false;
}

/// The request names the repo as such ("no repositório X", "in repo X").
fn saysRepo(text: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const n = @min(text.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], text[0..n]);
    for ([_][]const u8{ "repositório", "repositorio", "repo ", "repository" }) |w| if (std.mem.indexOf(u8, lower, w) != null) return true;
    return false;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn hostsWith(ctx: sys.Ctx, reg: hosts.Registry, repo: []const u8) ![]const []const u8 {
    var with: std.ArrayList([]const u8) = .empty;
    for (reg.hosts) |h| if (contains(try cachedRepos(ctx, h.name), repo)) try with.append(ctx.gpa, h.name);
    return with.items;
}

/// Lowercase words of the request, split on anything but letters, digits and
/// dashes ("mac-debian" stays one word, unlike "mac debian").
fn wordsOf(ctx: sys.Ctx, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !(std.ascii.isAlphanumeric(text[i]) or text[i] == '-' or text[i] >= 0x80)) i += 1;
        const start = i;
        while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-' or text[i] >= 0x80)) i += 1;
        if (i > start) try out.append(ctx.gpa, try std.ascii.allocLowerString(ctx.gpa, text[start..i]));
    }
    return out.items;
}

fn hasPhrase(list: []const []const u8, phrase: []const u8) bool {
    var pw = std.mem.tokenizeScalar(u8, phrase, ' ');
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    while (pw.next()) |p| : (n += 1) {
        if (n == parts.len) return false;
        parts[n] = p;
    }
    if (n == 0 or list.len < n) return false;
    var i: usize = 0;
    while (i + n <= list.len) : (i += 1) {
        for (parts[0..n], 0..) |p, j| {
            if (!std.mem.eql(u8, list[i + j], p)) break;
        } else return true;
    }
    return false;
}

fn exactAgent(text: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, text, " ,.;:!?\t");
    while (it.next()) |w| for ([_][]const u8{ "claude", "codex", "shell" }) |a| if (std.ascii.eqlIgnoreCase(w, a)) {
        if (found != null and !std.mem.eql(u8, found.?, a)) return null; // two named: let Jev decide
        found = a;
    };
    return found;
}

/// The repo whose name appears as whole words ("mac-debian", or "mac debian"
/// as it is said); the longest wins. A word that named the machine does not
/// also name a repo ("omarchy" is a machine and a repo there).
fn exactRepo(ctx: sys.Ctx, reg: hosts.Registry, sources: []const []const u8, text: []const u8, host_said: ?[]const u8) !?[]const u8 {
    const list = try wordsOf(ctx, text);
    var host_words: []const u8 = "";
    if (host_said) |name| for (reg.hosts) |h| if (std.mem.eql(u8, h.name, name)) {
        host_words = try spokenName(ctx, h);
    };
    var best: ?[]const u8 = null;
    var best_len: usize = 0;
    var tie = false;
    for (sources) |src| for (try cachedRepos(ctx, src)) |repo| {
        const lower = try std.ascii.allocLowerString(ctx.gpa, repo);
        const spaced = try std.mem.replaceOwned(u8, ctx.gpa, lower, "-", " ");
        if (!hasPhrase(list, lower) and !hasPhrase(list, spaced)) continue;
        var aliases = std.mem.tokenizeAny(u8, host_words, ",");
        const is_host_word = while (aliases.next()) |a| {
            if (std.mem.eql(u8, std.mem.trim(u8, a, " "), lower)) break true;
        } else false;
        if (is_host_word) continue;
        if (repo.len > best_len) {
            best = repo;
            best_len = repo.len;
            tie = false;
        } else if (repo.len == best_len and !std.mem.eql(u8, best.?, repo)) tie = true;
    };
    return if (tie) null else best;
}

/// The machine whose spoken name appears as whole words; the longest name wins
/// ("linux 2" over "linux"). None, or a tie, leaves it to Jev.
fn exactHost(ctx: sys.Ctx, reg: hosts.Registry, text: []const u8) !?[]const u8 {
    const all = try wordsOf(ctx, text);
    // Words that spell a repo's name are the repo, not a machine: "mac" in
    // "mac debian" (the mac-debian repo) does not mean the Mac.
    var covered = try ctx.gpa.alloc(bool, all.len);
    @memset(covered, false);
    for (reg.hosts) |h| for (cachedRepos(ctx, h.name) catch &.{}) |repo| {
        const spaced = try std.mem.replaceOwned(u8, ctx.gpa, try std.ascii.allocLowerString(ctx.gpa, repo), "-", " ");
        var parts: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, spaced, ' ');
        while (it.next()) |p| try parts.append(ctx.gpa, p);
        if (parts.items.len < 2) continue;
        var i: usize = 0;
        while (i + parts.items.len <= all.len) : (i += 1) {
            for (parts.items, 0..) |p, j| {
                if (!std.mem.eql(u8, all[i + j], p)) break;
            } else @memset(covered[i .. i + parts.items.len], true);
        }
    };
    var kept: std.ArrayList([]const u8) = .empty;
    for (all, covered) |w, c| try kept.append(ctx.gpa, if (c) "" else w);
    const list = kept.items;
    var best: ?[]const u8 = null;
    var best_len: usize = 0;
    var tie = false;
    for (reg.hosts) |h| {
        var aliases = std.mem.tokenizeAny(u8, try spokenName(ctx, h), ",");
        while (aliases.next()) |raw| {
            const alias = std.mem.trim(u8, raw, " ");
            if (alias.len == 0 or !hasPhrase(list, alias)) continue;
            if (alias.len > best_len) {
                best = h.name;
                best_len = alias.len;
                tie = false;
            } else if (alias.len == best_len and !std.mem.eql(u8, best.?, h.name)) tie = true;
        }
        if (hasPhrase(list, h.name) and h.name.len > best_len) {
            best = h.name;
            best_len = h.name.len;
            tie = false;
        }
    }
    return if (tie) null else best;
}

fn machineWords(ctx: sys.Ctx, reg: hosts.Registry) ![]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    for (reg.hosts) |h| try words.append(ctx.gpa, try spokenName(ctx, h));
    return std.mem.join(ctx.gpa, "; ", words.items);
}

/// How a machine is said aloud: the owner prefix dropped ("home-omarchy" is
/// "omarchy"), the OS for Windows and the Mac, digits spelled ("linux 2",
/// "linux dois", "the second linux").
fn spokenName(ctx: sys.Ctx, h: hosts.Host) ![]const u8 {
    if (h.kind == .msys) return "windows";
    if (std.mem.startsWith(u8, h.name, "mac")) return "mac, macbook";
    const tail = h.name[if (std.mem.indexOfScalar(u8, h.name, '-')) |i| i + 1 else 0..];
    const base = std.mem.trimEnd(u8, tail, "0123456789");
    if (base.len == tail.len) {
        // "home-linux-builder" is said "builder" (or "linux builder").
        const last = tail[if (std.mem.lastIndexOfScalar(u8, tail, '-')) |i| i + 1 else 0..];
        if (last.len == tail.len) return tail;
        return ctx.fmt("{s}, {s}", .{ last, try std.mem.replaceOwned(u8, ctx.gpa, tail, "-", " ") });
    }
    const ordinals = [_][]const u8{ "", "one, um, first", "two, dois, second", "three, três, third", "four, quatro, fourth", "five, cinco, fifth" };
    const d = tail[base.len] - '0';
    return ctx.fmt("{s} {c}, {s} {s}", .{ base, tail[base.len], base, if (d < ordinals.len) ordinals[d] else "" });
}

fn hostDescription(ctx: sys.Ctx, h: hosts.Host, self_name: []const u8) ![]const u8 {
    const os: []const u8 = if (h.kind == .msys) "Windows" else if (std.mem.startsWith(u8, h.name, "mac")) "macOS" else "Linux";
    const here: []const u8 = if (std.mem.eql(u8, h.name, self_name)) "; this machine: here, local, aqui" else "";
    return ctx.fmt("the {s} computer said as \"{s}\"{s}", .{ os, try spokenName(ctx, h), here });
}

test "intent drops the routing words" {
    try std.testing.expectEqualStrings("investigar o erro de login", intentOf("Crie um agente com codex no Windows, no repositório Web-App, para investigar o erro de login."));
    try std.testing.expectEqualStrings("revise o README", intentOf("revise o README"));
    try std.testing.expectEqualStrings("Deixe o menu mais rápido para todos", intentOf("Deixe o menu mais rápido para todos"));
    try std.testing.expectEqualStrings("fazer uma CLI de controle de temperatura, em Rust", intentOf("Crie um agente na minha máquina Linux com Claude Code para fazer uma CLI de controle de temperatura, em Rust."));
    try std.testing.expectEqualStrings("ver por que o build quebra", intentOf("Abre uma sessão no mac tools pra ver por que o build quebra"));
    // The work itself may name a repo or a machine before "para": kept whole.
    const work = "Revise o repositório inteiro e ajuste os testes do linux para rodarem mais rápido";
    try std.testing.expectEqualStrings(work, intentOf(work));
}

test "exact names are whole words" {
    try std.testing.expectEqualStrings("codex", exactAgent("abre um codex no api").?);
    try std.testing.expect(exactAgent("abre um agente no api") == null);
    try std.testing.expect(exactAgent("claude ou codex?") == null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
    const list = try wordsOf(ctx, "Shell no mac-tools, no Linux 2.");
    try std.testing.expect(hasPhrase(list, "mac-tools"));
    try std.testing.expect(!hasPhrase(list, "mac"));
    try std.testing.expect(hasPhrase(list, "linux 2"));
    var machines = [_]hosts.Host{
        .{ .name = "macbook", .target = "alice@macbook", .kind = .posix },
        .{ .name = "home-linux", .target = "alice@home-linux", .kind = .posix },
        .{ .name = "home-linux2", .target = "alice@home-linux2", .kind = .posix },
        .{ .name = "windows-pc", .target = "alice@windows-pc", .kind = .msys },
    };
    const reg = hosts.Registry{ .path = "", .hosts = &machines, .self_line = "macbook", .self = "macbook" };
    try std.testing.expectEqualStrings("home-linux2", (try exactHost(ctx, reg, "um shell no linux 2")).?);
    try std.testing.expectEqualStrings("home-linux", (try exactHost(ctx, reg, "um shell no linux")).?);
    try std.testing.expectEqualStrings("windows-pc", (try exactHost(ctx, reg, "codex no Windows")).?);
    var with_suffix = machines ++ [_]hosts.Host{.{ .name = "home-linux-builder", .target = "alice@home-linux-builder", .kind = .posix }};
    const reg2 = hosts.Registry{ .path = "", .hosts = &with_suffix, .self_line = "macbook", .self = "macbook" };
    try std.testing.expectEqualStrings("home-linux-builder", (try exactHost(ctx, reg2, "abrir nova sessão do Builder para criar uma skill")).?);
    try std.testing.expectEqualStrings("home-linux", (try exactHost(ctx, reg2, "um shell no linux")).?);
    // A repo whose first word is also a machine's is the repo, not the machine.
    try std.testing.expect((try exactHost(ctx, reg, "no mac-tools")) == null);
}

test "a repo said as such" {
    try std.testing.expect(saysRepo("pesquisa no repositório tmux"));
    try std.testing.expect(saysRepo("claude in the repo api"));
    try std.testing.expect(!saysRepo("pesquisar alternativas ao tmux"));
}

test "a repo named as the place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env_map = std.process.Environ.Map.init(arena.allocator());
    const ctx = sys.Ctx{ .io = std.testing.io, .gpa = arena.allocator(), .env = &env_map };
    try std.testing.expect(try saidAsPlace(ctx, "quero um shell no mac tools", "mac-tools"));
    try std.testing.expect(try saidAsPlace(ctx, "codex em api", "api"));
    try std.testing.expect(!(try saidAsPlace(ctx, "pesquisar alternativas ao tmux", "tmux")));
}
