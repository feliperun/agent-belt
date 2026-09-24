const std = @import("std");
const Config = @import("config.zig").Config;
const Binding = @import("config.zig").Binding;
const macos = @import("macos.zig");
const deepgram = @import("deepgram.zig");
const history = @import("history.zig");

const Daemon = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    recording: ?macos.Recorder = null,
    recording_key: ?usize = null,
    busy: bool = false,
    /// Push-to-talk started with the agent menu open: the speech is a command.
    command: bool = false,
    /// The keypad's HID thread and the F5 queue both drive push-to-talk.
    ptt_lock: std.Io.Mutex = .init,
    keys: @import("key_edges.zig").KeyEdges = .{},
    knob: @import("knob.zig").Knob = .{},
    talk: @import("f5.zig").Talk = .{},
    /// Where recordings and transcripts are kept (history.zig).
    history_dir: []const u8 = "",
    /// Key 5: speak a new agent into the create panel.
    create: @import("create_agent.zig").Controller = undefined,

    /// F5 (fn+F5 on a Mac keyboard) records like the push-to-talk key, under a
    /// key index no binding uses. Runs on its own queue, not the event tap.
    fn onF5(context: *anyopaque, pressed: bool) void {
        const daemon: *Daemon = @ptrCast(@alignCast(context));
        const now = macos.monotonicNs();
        const action = if (pressed) daemon.talk.press(now) else daemon.talk.release(now);
        if (action == .none) return;
        daemon.handlePushToTalk(.{ .key = 6, .pressed = action == .start }) catch |err| {
            macos.setStatus(.failed);
            std.debug.print("[agent-belt] error: {s}\n", .{@errorName(err)});
        };
    }

    fn onKnob(context: *anyopaque, event: macos.KnobEvent) void {
        const daemon: *Daemon = @ptrCast(@alignCast(context));
        switch (event) {
            .press => macos.agentsBottom(),
            .clockwise, .counter_clockwise => macos.scrollDown(
                daemon.knob.step(@intFromEnum(event), macos.monotonicNs(), daemon.config.knob_scroll_lines),
            ),
        }
    }

    fn onHidEvent(context: *anyopaque, event: macos.HidEvent) void {
        const daemon: *Daemon = @ptrCast(@alignCast(context));
        daemon.handleEvent(event) catch |err| {
            macos.setStatus(.failed);
            std.debug.print("[agent-belt] error: {s}\n", .{@errorName(err)});
        };
    }

    fn handleEvent(self: *Daemon, event: macos.HidEvent) !void {
        if (!self.keys.update(event.key, event.pressed)) return;
        const binding = self.config.bindings[event.key];
        const action = @import("config.zig").actionType(binding.action) catch .disabled;
        switch (action) {
            .disabled => {},
            .push_to_talk => try self.handlePushToTalk(event),
            .cycle_agents => if (event.pressed) macos.cycleAgents(std.mem.eql(u8, binding.value, "desktop")),
            .agents_menu => if (event.pressed) macos.agentsMenuPress(),
            .create_agent => self.create.onKey(event.pressed, @import("config.zig").keyChord(binding.value)),
            .key => macos.pressKey(@import("config.zig").keyChord(binding.value) orelse return error.UnknownKey, event.pressed),
            .command => if (event.pressed) try runShell(self.io, binding.value),
            .script => if (event.pressed) try runShell(self.io, binding.value),
            .text => if (event.pressed) try macos.insertText(binding.value),
        }
    }

    fn handlePushToTalk(self: *Daemon, event: macos.HidEvent) !void {
        self.ptt_lock.lockUncancelable(self.io);
        defer self.ptt_lock.unlock(self.io);
        if (event.pressed) {
            if (self.recording != null or self.busy) return;
            var recorder = macos.Recorder.init(self.allocator);
            errdefer recorder.deinit();
            try recorder.start();
            self.recording = recorder;
            self.recording_key = event.key;
            self.command = macos.agentsMenuVisible();
            if (self.command) macos.agentsMenuClose();
            macos.setStatus(if (self.command) .command else .recording);
            if (self.config.sounds) macos.playCue(.start);
            std.debug.print("[agent-belt] RECORDING, release the key to transcribe\n", .{});
            return;
        }

        if (self.recording_key != event.key) return;
        var recorder = self.recording orelse return;
        self.recording = null;
        self.recording_key = null;
        self.busy = true;
        if (self.config.sounds) macos.playCue(.stop);
        defer self.busy = false;
        defer macos.setStatus(.ready);
        defer recorder.deinit();

        macos.setStatus(.transcribing);

        const wav = try recorder.finish();
        defer self.allocator.free(wav);
        if (wav.len <= 44) return error.EmptyRecording;

        const api_key = try macos.deepgramKey(self.allocator, self.config.deepgram_api_key_env);
        defer self.allocator.free(api_key);
        const dg = deepgram.Client{
            .io = self.io,
            .allocator = self.allocator,
            .api_key = api_key,
            .model = self.config.deepgram_model,
            .language = self.config.deepgram_language,
            .smart_format = self.config.deepgram_smart_format,
            .mip_opt_out = self.config.deepgram_mip_opt_out,
        };
        std.debug.print("[agent-belt] TRANSCRIBING...\n", .{});
        const text = try dg.transcribe(wav);
        defer self.allocator.free(text);
        history.saveAsync(self.io, self.history_dir, .dictation, wav, text);
        if (text.len == 0) {
            std.debug.print("[agent-belt] no speech detected\n", .{});
            return;
        }
        try macos.dismissOverlay();
        if (self.command) {
            std.debug.print("[agent-belt] VOICE COMMAND: {s}\n", .{text});
            try macos.voiceCommand(self.allocator, text);
            return;
        }
        try macos.insertText(text);
        std.debug.print("[agent-belt] INSERTED ({d} characters)\n", .{text.len});
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, config: Config, history_dir: []const u8) !void {
    macos.trimLog();
    macos.singleInstance() catch |err| {
        std.debug.print("[agent-belt] another daemon is already running (launchctl print gui/$UID/com.frb.agentbelt)\n", .{});
        return err;
    };
    macos.checkPermissions() catch |err| {
        // Exit and let launchd restart us: only a new process sees a fresh grant.
        std.Io.sleep(io, .fromSeconds(10), .awake) catch {};
        return err;
    };
    macos.agentsMonitor();
    macos.updaterStart(@import("build_options").version);
    if (config.led) macos.ledStart(config.vendor_id, config.product_id);
    std.debug.print("[agent-belt] ready: VID=0x{x} PID=0x{x}\n", .{ config.vendor_id, config.product_id });
    var daemon = Daemon{ .io = io, .allocator = allocator, .config = config };
    daemon.history_dir = history_dir;
    daemon.create = .{ .io = io, .gpa = allocator, .config = &daemon.config, .history_dir = history_dir };
    // "system" leaves the knob as the device's volume control.
    macos.setKnobIntercept(!std.mem.eql(u8, config.knob, "system"));
    var listener = macos.HidListener{
        .allocator = allocator,
        .vendor_id = config.vendor_id,
        .product_id = config.product_id,
        .on_event = Daemon.onHidEvent,
        .on_knob = Daemon.onKnob,
        .on_f5 = if (config.f5_push_to_talk) Daemon.onF5 else null,
        .context = @ptrCast(&daemon),
    };
    try listener.run();
}

fn runShell(io: std.Io, command: []const u8) !void {
    if (command.len == 0) return error.EmptyCommand;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-lc", command },
    });
    _ = try child.wait(io);
}
