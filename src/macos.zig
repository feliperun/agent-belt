const std = @import("std");

const c = @cImport({
    @cInclude("macos_shim.h");
});

pub fn selfExePath(allocator: std.mem.Allocator) ![]u8 {
    const path = c.mk_self_exe_path() orelse return error.ExecutablePathUnavailable;
    defer c.mk_free_buffer(path);
    return allocator.dupe(u8, std.mem.span(path));
}

pub const HidEvent = struct {
    key: u8,
    pressed: bool,
};

pub const KnobEvent = enum(i8) {
    counter_clockwise = -1,
    press = 0,
    clockwise = 1,
};

/// Environment first (terminal runs), then the login Keychain (LaunchAgent).
pub fn deepgramKey(allocator: std.mem.Allocator, env_name: []const u8) ![]u8 {
    var name: [256]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name, "{s}", .{env_name}) catch return error.DeepgramApiKeyMissing;
    if (std.c.getenv(name_z)) |value| return allocator.dupe(u8, std.mem.span(value));
    const secret = c.mk_keychain_secret("minikeyboard", "deepgram") orelse return error.DeepgramApiKeyMissing;
    defer c.mk_free_buffer(@ptrCast(secret));
    return allocator.dupe(u8, std.mem.span(secret));
}

pub fn singleInstance() !void {
    if (c.mk_single_instance() != 0) return error.DaemonAlreadyRunning;
}

pub fn checkPermissions() !void {
    if (c.mk_check_permissions() != 0) return error.PermissionsMissing;
}

pub fn setKnobIntercept(intercept: bool) void {
    c.mk_knob_set_intercept(@intFromBool(intercept));
}

pub fn scrollDown(lines: i32) void {
    c.mk_scroll_down(lines);
}

pub fn agentsBottom() void {
    c.mk_agents_bottom();
}

pub fn monotonicNs() u64 {
    return c.mk_monotonic_ns();
}

pub const Status = enum(c_int) {
    ready = 0,
    recording = 1,
    transcribing = 2,
    failed = 3,
};

pub fn setStatus(status: Status) void {
    c.mk_status_set(@intFromEnum(status));
}

pub fn dismissOverlay() !void {
    if (c.mk_status_dismiss() != 0) return error.OverlayDismissTimeout;
}

pub fn previewOverlay() !void {
    if (c.mk_status_preview() != 0) return error.OverlayPreviewFailed;
}

pub fn cycleAgents(desktop: bool) void {
    c.mk_agents_next(@intFromBool(desktop));
}

pub const AgentsMode = enum(c_int) { list = 0, next = 1, bottom = 2 };

pub fn agentsCommand(mode: AgentsMode, desktop: bool) !void {
    if (c.mk_agents_command(@intFromEnum(mode), @intFromBool(desktop)) != 0) return error.AgentSwitchFailed;
}

pub const HidListener = struct {
    allocator: std.mem.Allocator,
    vendor_id: u16,
    product_id: u16,
    on_event: *const fn (context: *anyopaque, event: HidEvent) void,
    on_knob: *const fn (context: *anyopaque, event: KnobEvent) void,
    context: *anyopaque,
    pressed: std.atomic.Value(u8) = .init(0),
    release_until_ns: [6]std.atomic.Value(u64) = .{
        .init(0), .init(0), .init(0), .init(0), .init(0), .init(0),
    },
    debug_input: bool = false,

    pub fn run(self: *HidListener) !void {
        _ = self.allocator;
        if (c.mk_status_init() != 0) {
            std.log.warn("não consegui criar indicador na barra de menus", .{});
        }
        self.debug_input = std.c.getenv("MINIKEYBOARD_DEBUG_INPUT") != null;
        const hid_thread = try std.Thread.spawn(.{}, hidThread, .{self});
        hid_thread.detach();

        const result = c.mk_event_tap_run(eventFilter, self);
        if (result != 0) {
            if (result == -4) {
                std.log.err("não consegui criar o event tap; dê ao binário a permissão de Accessibility", .{});
            } else {
                std.log.err("não consegui abrir o monitor HID (código={d}); dê ao binário a permissão de Input Monitoring", .{result});
            }
            return error.HidOpenFailed;
        }
    }
};

fn hidThread(listener: *HidListener) void {
    const result = c.mk_hid_run(listener.vendor_id, listener.product_id, hidCallback, knobCallback, listener);
    if (result != 0) {
        std.log.err("não consegui abrir o monitor HID (código={d}); dê ao binário a permissão de Input Monitoring", .{result});
    } else {
        std.log.info("monitor HID encerrado", .{});
    }
}

fn hidCallback(context: ?*anyopaque, key: u8, pressed: u8) callconv(.c) void {
    const listener: *HidListener = @ptrCast(@alignCast(context.?));
    noteKey(listener, key, pressed != 0);
    if (listener.debug_input) {
        std.debug.print("[minikeyboard] HID key={d} {s}\n", .{ key, if (pressed != 0) "down" else "up" });
    }
    listener.on_event(listener.context, .{ .key = key, .pressed = pressed != 0 });
}

fn knobCallback(context: ?*anyopaque, event: i8) callconv(.c) void {
    const listener: *HidListener = @ptrCast(@alignCast(context.?));
    const knob: KnobEvent = @enumFromInt(event);
    if (listener.debug_input) std.debug.print("[minikeyboard] KNOB {s}\n", .{@tagName(knob)});
    listener.on_knob(listener.context, knob);
}

fn noteKey(self: *HidListener, key: u8, pressed: bool) void {
    const bit: u3 = @intCast(key);
    if (pressed) {
        _ = self.pressed.bitSet(bit, .acq_rel);
        self.release_until_ns[key].store(0, .release);
    } else {
        self.release_until_ns[key].store(c.mk_monotonic_ns() + 100 * std.time.ns_per_ms, .release);
        _ = self.pressed.bitReset(bit, .acq_rel);
    }
}

fn eventFilter(context: ?*anyopaque, keycode: u16, pressed: u8, repeated: u8) callconv(.c) c_int {
    const listener: *HidListener = @ptrCast(@alignCast(context.?));
    const key = keyFromKeycode(keycode) orelse return 0;
    const bit: u3 = @intCast(key);
    const held = (listener.pressed.load(.acquire) & (@as(u8, 1) << bit)) != 0;
    const release_until = listener.release_until_ns[key].load(.acquire);
    const should_suppress = held or (release_until != 0 and c.mk_monotonic_ns() <= release_until);
    if (listener.debug_input and (repeated == 0 or !should_suppress)) {
        std.debug.print("[minikeyboard] TAP keycode={d} key={d} {s} suppress={s}\n", .{
            keycode,
            key,
            if (pressed != 0) "down" else "up",
            if (should_suppress) "yes" else "no",
        });
    }
    return if (should_suppress) 1 else 0;
}

fn keyFromKeycode(keycode: u16) ?u8 {
    return switch (keycode) {
        0 => 0, // a
        11 => 1, // b
        8 => 2, // c
        2 => 3, // d
        14 => 4, // e
        3 => 5, // f
        else => null,
    };
}

pub fn pressKey(keycode: u16, pressed: bool) void {
    c.mk_press_key(keycode, @intFromBool(pressed));
}

pub fn insertText(text: []const u8) !void {
    var utf16: std.ArrayList(u16) = .empty;
    defer utf16.deinit(std.heap.page_allocator);
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xffff) {
            try utf16.append(std.heap.page_allocator, @intCast(codepoint));
        } else {
            const value = codepoint - 0x10000;
            try utf16.append(std.heap.page_allocator, @intCast(0xd800 + (value >> 10)));
            try utf16.append(std.heap.page_allocator, @intCast(0xdc00 + (value & 0x3ff)));
        }
    }
    if (c.mk_insert_text(utf16.items.ptr, utf16.items.len) != 0) return error.EventCreationFailed;
}

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    handle: ?*c.mk_recorder,

    pub fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator, .handle = c.mk_recorder_create() };
    }

    pub fn deinit(self: *Recorder) void {
        if (self.handle) |handle| c.mk_recorder_destroy(handle);
        self.handle = null;
    }

    pub fn start(self: *Recorder) !void {
        if (self.handle == null) return error.AudioInputUnavailable;
        if (c.mk_recorder_start(self.handle.?) != 0) return error.AudioStartFailed;
    }

    pub fn finish(self: *Recorder) ![]u8 {
        if (self.handle == null) return error.AudioInputUnavailable;
        var wav_ptr: [*c]u8 = undefined;
        var wav_size: usize = 0;
        if (c.mk_recorder_finish(self.handle.?, &wav_ptr, &wav_size) != 0) return error.AudioStopFailed;
        const copy = try self.allocator.dupe(u8, wav_ptr[0..wav_size]);
        c.mk_free_buffer(wav_ptr);
        return copy;
    }
};
