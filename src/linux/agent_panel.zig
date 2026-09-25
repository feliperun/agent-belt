//! The create-agent panel on Linux (Omarchy): hold Shift+F9 and say the agent
//! ("codex no windows no coreum que investigue o login"). A centered Quickshell
//! panel (src/linux/agent_panel.qml), the Mac panel's twin (src/create_panel.m),
//! shows the words as they stream in and what was understood (`agb _intent`,
//! backed by Jev): harness, machine and repo, and the session's name and summary
//! (`agb _summary`). Release to review; hold again to add, type to fix, pick
//! from a field to correct it; Return creates the agent, Esc cancels.
//!
//! The bind (`agb agent-ptt start|stop`) and the menu (`agb agent-panel`) talk
//! to one host process (`agb _agent-panel`) through files in XDG_RUNTIME_DIR:
//! agb-agent.rec (hold), agb-agent.state (host → panel), agb-agent.cmd
//! (panel → host: edits, choices and actions).
const std = @import("std");
const sys = @import("../sessions/sys.zig");
const cli = @import("../sessions/cli.zig");
const intent = @import("../sessions/intent.zig");
const history = @import("../history.zig");
const wav_stream = @import("../wav_stream.zig");
const desktop = @import("desktop.zig");

pub fn isCommand(name: []const u8) bool {
    for ([_][]const u8{ "agent-ptt", "agent-panel", "_agent-panel" }) |c| if (std.mem.eql(u8, name, c)) return true;
    return false;
}

pub fn main(ctx: sys.Ctx, argv: []const []const u8) !u8 {
    if (std.mem.eql(u8, argv[0], "_agent-panel")) return host(ctx);
    const hold = std.mem.eql(u8, argv[0], "agent-ptt") and !(argv.len > 1 and std.mem.eql(u8, argv[1], "stop"));
    try sys.writeFileAtomic(ctx, try desktop.runtimeFile(ctx, "agb-agent.rec"), if (hold) "1" else "0");
    // A host already open keeps the panel: this one sees its lock and leaves.
    if (hold or std.mem.eql(u8, argv[0], "agent-panel")) {
        _ = std.process.spawn(ctx.io, .{ .argv = &.{ desktop.selfExe(ctx), "_agent-panel" }, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
            desktop.notify(ctx, "Agent Belt", ctx.fmt("could not open the panel: {s}", .{@errorName(err)}) catch "", 5000);
            return 1;
        };
    }
    return 0;
}

/// A subprocess run off the UI loop (`agb _intent`, `agb _summary`).
const Job = struct {
    argv: []const []const u8,
    text: []const u8,
    out: []const u8 = "",
    done: std.atomic.Value(bool) = .init(false),

    const gpa = std.heap.smp_allocator;

    fn start(ctx: sys.Ctx, argv: []const []const u8, text: []const u8) ?*Job {
        const job = gpa.create(Job) catch return null;
        job.* = .{ .argv = argv, .text = text };
        const t = std.Thread.spawn(.{}, run, .{ job, ctx.io, ctx.env }) catch {
            gpa.destroy(job);
            return null;
        };
        t.detach();
        return job;
    }

    fn run(job: *Job, io: std.Io, env: *std.process.Environ.Map) void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const result = sys.run(.{ .io = io, .gpa = arena.allocator(), .env = env }, job.argv, null);
        job.out = gpa.dupe(u8, result.text()) catch "";
        job.done.store(true, .release);
    }
};

const Host = struct {
    ctx: sys.Ctx,
    keyterms: []const []const u8,
    key: ?[]const u8,
    base: []const u8 = "",
    recorder: ?std.process.Child = null,
    live: ?*wav_stream.Live = null,
    finishing_since: ?i96 = null,
    fixed: struct { agent: ?[]const u8 = null, host: ?[]const u8 = null, repo: ?[]const u8 = null } = .{},
    applied: i64 = 0,
    detect: ?*Job = null,
    plan: []const u8 = "",
    planned: ?[]const u8 = null,
    summary_job: ?*Job = null,
    summary: []const u8 = "",
    summarized: ?[]const u8 = null,
    last_text: []const u8 = "",
    changed_at: i96 = 0,
    create_pending: bool = false,
    problem: []const u8 = "",

    fn now(self: *Host) i96 {
        return std.Io.Clock.awake.now(self.ctx.io).toNanoseconds();
    }

    fn text(self: *Host) []const u8 {
        const live = if (self.live) |l| l.snapshot(self.ctx.gpa) else "";
        return join(self.ctx, self.base, live);
    }

    fn startRecording(self: *Host) !void {
        const ctx = self.ctx;
        for ([_][]const u8{ "agb-agent.stream", "agb-agent.final" }) |f| std.Io.Dir.cwd().deleteFile(ctx.io, try desktop.runtimeFile(ctx, f)) catch {};
        const wav = try desktop.runtimeFile(ctx, "agb-agent.wav");
        self.recorder = try std.process.spawn(ctx.io, .{ .argv = &.{ "pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", wav }, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        self.problem = "";
        const key = self.key orelse {
            self.problem = "no Deepgram key: DEEPGRAM_API_KEY=… agb install";
            return;
        };
        const live = try std.heap.smp_allocator.create(wav_stream.Live);
        live.* = .{
            .io = ctx.io,
            .env = ctx.env,
            .key = key,
            .keyterms = self.keyterms,
            .wav_path = wav,
            .status_path = try desktop.runtimeFile(ctx, "agb-agent.stream"),
            .final_path = try desktop.runtimeFile(ctx, "agb-agent.final"),
        };
        try live.start();
        self.live = live;
    }

    fn stopRecording(self: *Host) void {
        var rec = self.recorder orelse return;
        // SIGINT lets pw-record finish the WAV header.
        std.posix.kill(rec.id.?, std.posix.SIG.INT) catch {};
        _ = rec.wait(self.ctx.io) catch {};
        self.recorder = null;
        if (self.live) |l| l.finish();
        self.finishing_since = self.now();
    }

    /// The streamed words are final: they join the text, the recording goes
    /// to the history.
    fn collect(self: *Host) void {
        const since = self.finishing_since orelse return;
        const ctx = self.ctx;
        const final = sys.readFile(ctx, desktop.runtimeFile(ctx, "agb-agent.final") catch return);
        const failed = std.mem.eql(u8, sys.readFile(ctx, desktop.runtimeFile(ctx, "agb-agent.stream") catch return) orelse "", "failed");
        if (final == null and !failed and self.live != null and self.now() - since < 6 * std.time.ns_per_s) return;
        const words = final orelse if (self.live) |l| l.snapshot(ctx.gpa) else "";
        if (words.len == 0 and failed) self.problem = "could not transcribe: check the network or the Deepgram key";
        self.base = join(ctx, self.base, words);
        self.live = null; // its thread has ended; the little it holds stays
        self.finishing_since = null;
        const wav_path = desktop.runtimeFile(ctx, "agb-agent.wav") catch return;
        if (sys.readFile(ctx, wav_path)) |wav| history.saveAsync(ctx.io, history.dir(ctx.gpa, ctx.env) catch return, .@"new-agent", wav, words);
        // The history keeps the recording; the runtime copy of the voice and
        // of its transcript does not outlive the panel.
        for ([_][]const u8{ "agb-agent.wav", "agb-agent.final" }) |f| {
            std.Io.Dir.cwd().deleteFile(ctx.io, desktop.runtimeFile(ctx, f) catch continue) catch {};
        }
    }

    /// Edits, choices and actions from the panel, applied once per sequence.
    fn applyCommand(self: *Host) bool {
        const ctx = self.ctx;
        const bytes = sys.readFile(ctx, desktop.runtimeFile(ctx, "agb-agent.cmd") catch return true) orelse return true;
        const Cmd = struct { seq: i64 = 0, text: ?[]const u8 = null, agent: ?[]const u8 = null, host: ?[]const u8 = null, repo: ?[]const u8 = null, action: []const u8 = "" };
        const cmd = std.json.parseFromSliceLeaky(Cmd, ctx.gpa, bytes, .{ .ignore_unknown_fields = true }) catch return true;
        if (cmd.seq <= self.applied) return true;
        self.applied = cmd.seq;
        if (std.mem.eql(u8, cmd.action, "cancel")) return false;
        if (cmd.text) |t| if (self.recorder == null and self.finishing_since == null) {
            self.base = t;
        };
        const chose = cmd.agent != null or cmd.host != null or cmd.repo != null;
        if (cmd.agent) |a| self.fixed.agent = a;
        if (cmd.host) |h| self.fixed.host = h;
        if (cmd.repo) |r| self.fixed.repo = r; // "": no repo
        if (chose) self.planned = null; // detect again with the choice
        if (std.mem.eql(u8, cmd.action, "create")) self.create_pending = true;
        return true;
    }

    fn understand(self: *Host, current: []const u8) void {
        const ctx = self.ctx;
        const settled = self.now() - self.changed_at;
        if (self.detect) |job| if (job.done.load(.acquire)) {
            self.detect = null;
            if (std.mem.indexOf(u8, job.out, "\"agent\"") != null) {
                self.plan = job.out;
                self.planned = job.text;
            } else self.problem = ctx.fmt("could not understand: {s}", .{job.out}) catch "";
        };
        if (self.summary_job) |job| if (job.done.load(.acquire)) {
            self.summary_job = null;
            if (std.mem.indexOf(u8, job.out, "\"name\"") != null) {
                self.summary = job.out;
                self.summarized = job.text;
            }
        };
        if (current.len == 0) return;
        const busy = self.recorder != null or self.finishing_since != null;
        if (self.detect == null and !eqlOpt(self.planned, current) and settled > 350 * std.time.ns_per_ms) {
            var argv: std.ArrayList([]const u8) = .empty;
            argv.appendSlice(ctx.gpa, &.{ desktop.selfExe(ctx), "_intent" }) catch return;
            if (self.fixed.agent) |a| argv.appendSlice(ctx.gpa, &.{ "--agent", a }) catch return;
            if (self.fixed.host) |h| argv.appendSlice(ctx.gpa, &.{ "--host", h }) catch return;
            if (self.fixed.repo) |r| (if (r.len == 0) argv.append(ctx.gpa, "--no-repo") else argv.appendSlice(ctx.gpa, &.{ "--repo", r })) catch return;
            argv.append(ctx.gpa, current) catch return;
            self.detect = Job.start(ctx, argv.items, current);
        }
        if (!busy and self.summary_job == null and !eqlOpt(self.summarized, current) and settled > 700 * std.time.ns_per_ms)
            self.summary_job = Job.start(ctx, &.{ desktop.selfExe(ctx), "_summary", current }, current);
    }

    /// Opens the agent's terminal once the plan and the name match the text.
    fn create(self: *Host, current: []const u8) bool {
        if (!self.create_pending or self.recorder != null or self.finishing_since != null) return false;
        if (current.len == 0) {
            self.create_pending = false;
            return false;
        }
        if (!eqlOpt(self.planned, current) or !eqlOpt(self.summarized, current)) return false;
        const ctx = self.ctx;
        const Plan = struct { agent: []const u8, host: []const u8, repo: ?[]const u8 = null };
        const Named = struct { name: []const u8, prompt: []const u8 = "" };
        const plan = std.json.parseFromSliceLeaky(Plan, ctx.gpa, self.plan, .{ .ignore_unknown_fields = true }) catch return false;
        const named = std.json.parseFromSliceLeaky(Named, ctx.gpa, self.summary, .{ .ignore_unknown_fields = true }) catch return false;
        const repo: ?[]const u8 = if (self.fixed.repo) |r| (if (r.len == 0) null else r) else plan.repo;
        const args = cli.newArgs(ctx.gpa, self.fixed.agent orelse plan.agent, self.fixed.host orelse plan.host, repo, named.name, if (named.prompt.len > 0) named.prompt else current) catch return false;
        desktop.openTerminal(ctx, args);
        return true;
    }

    fn publish(self: *Host, state_path: []const u8, current: []const u8) !void {
        const ctx = self.ctx;
        const recording = self.recorder != null;
        try sys.writeFileAtomic(ctx, state_path, try ctx.fmt("{f}", .{std.json.fmt(.{
            .recording = recording,
            .finishing = self.finishing_since != null,
            .detecting = self.detect != null,
            .creating = self.create_pending,
            .level = if (recording) desktop.levelOf(ctx, "agb-agent.wav") else 0,
            .text = current,
            .seq = self.applied,
            .plan = self.plan, // the last one while a newer is on its way
            .summary = if (eqlOpt(self.summarized, current)) self.summary else "",
            .fixed = self.fixed,
            .problem = self.problem,
        }, .{})}));
    }
};

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

/// Speech appended to what is there, one space between.
fn join(ctx: sys.Ctx, base: []const u8, more: []const u8) []const u8 {
    const a = std.mem.trimEnd(u8, base, " ");
    const b = std.mem.trim(u8, more, " ");
    if (b.len == 0) return a;
    if (a.len == 0) return b;
    return ctx.fmt("{s} {s}", .{ a, b }) catch a;
}

fn host(ctx: sys.Ctx) !u8 {
    if (sys.which(ctx, "quickshell") == null) {
        desktop.notify(ctx, "Agent Belt", "the new agent panel needs Quickshell (Omarchy ships it)", 5000);
        return 1;
    }
    // One panel: a second press while it is open adds to it (agb-agent.rec).
    const lock = sys.lockInstance(ctx, try desktop.runtimeFile(ctx, "agb-agent.lock")) orelse return 0;
    defer lock.close(ctx.io);
    // The repo index for detection, refreshed in the background.
    _ = std.process.spawn(ctx.io, .{ .argv = &.{ desktop.selfExe(ctx), "_repos-cache" }, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {};
    const reg = cli.loadRegistry(ctx) catch null;
    var self = Host{ .ctx = ctx, .keyterms = if (reg) |r| intent.keyterms(ctx, r) catch &.{} else &.{}, .key = desktop.deepgramKey(ctx) };

    const state_path = try desktop.runtimeFile(ctx, "agb-agent.state");
    const cmd_path = try desktop.runtimeFile(ctx, "agb-agent.cmd");
    const rec_path = try desktop.runtimeFile(ctx, "agb-agent.rec");
    const qml = try desktop.runtimeFile(ctx, "agb-agent.qml");
    std.Io.Dir.cwd().deleteFile(ctx.io, cmd_path) catch {};
    try sys.writeFileAtomic(ctx, qml, @embedFile("agent_panel.qml"));
    try self.publish(state_path, "");
    try ctx.env.put("AGB_PANEL_STATE", state_path);
    try ctx.env.put("AGB_PANEL_CMD", cmd_path);
    var shell = try std.process.spawn(ctx.io, .{ .argv = &.{ "quickshell", "-p", qml }, .environ_map = ctx.env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer shell.kill(ctx.io);
    // The state carries the whole request: it goes when the panel goes.
    defer for ([_][]const u8{ state_path, cmd_path }) |p| std.Io.Dir.cwd().deleteFile(ctx.io, p) catch {};

    const opened = self.now();
    while (self.now() - opened < 15 * std.time.ns_per_min) {
        const hold = std.mem.eql(u8, sys.readFile(ctx, rec_path) orelse "0", "1");
        if (hold and self.recorder == null and self.finishing_since == null) self.startRecording() catch |err| {
            self.problem = ctx.fmt("could not record: {s}", .{@errorName(err)}) catch "";
        };
        if (!hold and self.recorder != null) self.stopRecording();
        self.collect();
        if (!self.applyCommand()) break;
        const current = self.text();
        if (!std.mem.eql(u8, current, self.last_text)) {
            self.last_text = current;
            self.changed_at = self.now();
        }
        self.understand(current);
        if (self.create(current)) break;
        try self.publish(state_path, current);
        try std.Io.sleep(ctx.io, .fromMilliseconds(33), .awake);
    }
    self.stopRecording();
    return 0;
}
