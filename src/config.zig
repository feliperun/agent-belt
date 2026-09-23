const std = @import("std");

pub const ActionType = enum {
    disabled,
    push_to_talk,
    cycle_agents,
    agents_menu,
    key,
    command,
    script,
    text,
};

pub const Binding = struct {
    action: []const u8 = "disabled",
    value: []const u8 = "",
};

pub const Config = struct {
    vendor_id: u16 = 0x514c,
    product_id: u16 = 0x8850,
    deepgram_api_key_env: []const u8 = "DEEPGRAM_API_KEY",
    deepgram_model: []const u8 = "nova-3",
    deepgram_language: []const u8 = "pt-BR",
    deepgram_smart_format: bool = true,
    deepgram_mip_opt_out: bool = true,
    /// "scroll": knob scrolls, its button returns agents to the bottom. "system": volume.
    knob: []const u8 = "scroll",
    /// Lines per detent; negative inverts the direction.
    knob_scroll_lines: i32 = 3,
    /// Key LEDs follow push-to-talk and agents: white recording, red waiting, green finished.
    led: bool = true,
    /// F5 as push-to-talk: fn+F5 on a Mac keyboard (plain F5 is the microphone
    /// key, which macOS keeps for its own Dictation).
    f5_push_to_talk: bool = true,
    /// Discreet sounds when recording starts and stops.
    sounds: bool = true,
    bindings: [6]Binding = .{
        .{ .action = "key", .value = "escape" },
        .{ .action = "agents_menu" },
        .{ .action = "key", .value = "delete" },
        .{ .action = "push_to_talk" },
        .{ .action = "cycle_agents" },
        .{ .action = "key", .value = "return" },
    },
};

pub const ConfigStore = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !ConfigStore {
        const home_ptr = std.c.getenv("HOME") orelse return error.HomeNotFound;
        const home = std.mem.span(home_ptr);

        const dir = try std.fs.path.join(allocator, &.{ home, ".config", "agent-belt" });
        defer allocator.free(dir);
        try std.Io.Dir.createDirPath(.cwd(), io, dir);

        const path = try std.fs.path.join(allocator, &.{ dir, "config.json" });
        return .{ .io = io, .allocator = allocator, .path = path };
    }

    pub fn deinit(self: *ConfigStore) void {
        self.allocator.free(self.path);
    }

    pub fn load(self: ConfigStore) !std.json.Parsed(Config) {
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), self.io, self.path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                const config = Config{};
                try self.save(config);
                return std.json.parseFromSlice(Config, self.allocator, defaultConfigJson(), .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                });
            },
            else => return err,
        };
        defer self.allocator.free(bytes);
        return std.json.parseFromSlice(Config, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    pub fn save(self: ConfigStore, config: Config) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, config, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);

        var file = try std.Io.Dir.createFileAbsolute(self.io, self.path, .{
            .truncate = true,
            .permissions = .default_file,
        });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes);
        try file.writeStreamingAll(self.io, "\n");
    }
};

pub fn defaultConfigJson() []const u8 {
    return "{\n" ++
        "  \"vendor_id\": 20812,\n" ++
        "  \"product_id\": 34896,\n" ++
        "  \"deepgram_api_key_env\": \"DEEPGRAM_API_KEY\",\n" ++
        "  \"deepgram_model\": \"nova-3\",\n" ++
        "  \"deepgram_language\": \"pt-BR\",\n" ++
        "  \"deepgram_smart_format\": true,\n" ++
        "  \"deepgram_mip_opt_out\": true,\n" ++
        "  \"knob\": \"scroll\",\n" ++
        "  \"knob_scroll_lines\": 3,\n" ++
        "  \"led\": true,\n" ++
        "  \"f5_push_to_talk\": true,\n" ++
        "  \"sounds\": true,\n" ++
        "  \"bindings\": [\n" ++
        "    {\"action\": \"key\", \"value\": \"escape\"},\n" ++
        "    {\"action\": \"agents_menu\", \"value\": \"\"},\n" ++
        "    {\"action\": \"key\", \"value\": \"delete\"},\n" ++
        "    {\"action\": \"push_to_talk\", \"value\": \"\"},\n" ++
        "    {\"action\": \"cycle_agents\", \"value\": \"\"},\n" ++
        "    {\"action\": \"key\", \"value\": \"return\"}\n" ++
        "  ]\n" ++
        "}\n";
}

pub fn bindingIndex(key: []const u8) !usize {
    if (key.len != 1) return error.InvalidKey;
    if (key[0] >= 'a' and key[0] <= 'f') return key[0] - 'a';
    if (key[0] >= '0' and key[0] <= '5') return key[0] - '0';
    return error.InvalidKey;
}

pub fn actionType(name: []const u8) !ActionType {
    if (std.mem.eql(u8, name, "disabled")) return .disabled;
    if (std.mem.eql(u8, name, "ptt") or std.mem.eql(u8, name, "push_to_talk")) return .push_to_talk;
    if (std.mem.eql(u8, name, "agents") or std.mem.eql(u8, name, "cycle_agents")) return .cycle_agents;
    if (std.mem.eql(u8, name, "menu") or std.mem.eql(u8, name, "agents_menu")) return .agents_menu;
    if (std.mem.eql(u8, name, "key")) return .key;
    if (std.mem.eql(u8, name, "command")) return .command;
    if (std.mem.eql(u8, name, "script")) return .script;
    if (std.mem.eql(u8, name, "text")) return .text;
    return error.InvalidAction;
}

pub const KeyChord = struct {
    code: u16,
    /// CGEventFlags modifier mask.
    flags: u64 = 0,
};

/// Parses the `key` action value: a key name with optional modifiers, e.g.
/// "escape", "shift+tab", "cmd+k". "delete" is the Mac Delete (backspace);
/// "forward_delete" is ⌦.
pub fn keyChord(value: []const u8) ?KeyChord {
    var chord = KeyChord{ .code = 0 };
    var parts = std.mem.splitScalar(u8, value, '+');
    var key: ?u16 = null;
    while (parts.next()) |part| {
        if (key != null) return null; // the key must come last
        if (modifierFlag(part)) |flag| {
            chord.flags |= flag;
        } else {
            key = keyCode(part) orelse return null;
        }
    }
    chord.code = key orelse return null;
    return chord;
}

fn modifierFlag(name: []const u8) ?u64 {
    const modifiers = [_]struct { []const u8, u64 }{
        .{ "shift", 0x20000 }, .{ "ctrl", 0x40000 },   .{ "control", 0x40000 },
        .{ "alt", 0x80000 },   .{ "option", 0x80000 }, .{ "opt", 0x80000 },
        .{ "cmd", 0x100000 },  .{ "command", 0x100000 },
    };
    for (modifiers) |entry| if (std.ascii.eqlIgnoreCase(entry[0], name)) return entry[1];
    return null;
}

pub fn keyCode(name: []const u8) ?u16 {
    const keys = [_]struct { []const u8, u16 }{
        .{ "escape", 53 },          .{ "esc", 53 },
        .{ "delete", 51 },          .{ "backspace", 51 },
        .{ "forward_delete", 117 }, .{ "return", 36 },
        .{ "enter", 36 },           .{ "tab", 48 },
        .{ "space", 49 },           .{ "up", 126 },
        .{ "down", 125 },           .{ "left", 123 },
        .{ "right", 124 },          .{ "home", 115 },
        .{ "end", 119 },            .{ "page_up", 116 },
        .{ "page_down", 121 },
    };
    for (keys) |entry| if (std.ascii.eqlIgnoreCase(entry[0], name)) return entry[1];
    if (name.len == 1) {
        // ANSI layout positions: macOS keycodes are physical.
        const letters = [26]u16{ 0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6 };
        const digits = [10]u16{ 29, 18, 19, 20, 21, 23, 22, 26, 28, 25 };
        const c = std.ascii.toLower(name[0]);
        if (c >= 'a' and c <= 'z') return letters[c - 'a'];
        if (c >= '0' and c <= '9') return digits[c - '0'];
    }
    return null;
}

test "key chords: names, letters, digits and modifiers" {
    try std.testing.expectEqual(KeyChord{ .code = 53 }, keyChord("escape").?);
    try std.testing.expectEqual(KeyChord{ .code = 53 }, keyChord("ESC").?);
    try std.testing.expectEqual(KeyChord{ .code = 51 }, keyChord("delete").?);
    try std.testing.expectEqual(KeyChord{ .code = 117 }, keyChord("forward_delete").?);
    try std.testing.expectEqual(KeyChord{ .code = 36 }, keyChord("enter").?);
    try std.testing.expectEqual(KeyChord{ .code = 48, .flags = 0x20000 }, keyChord("shift+tab").?);
    try std.testing.expectEqual(KeyChord{ .code = 40, .flags = 0x100000 }, keyChord("cmd+k").?);
    try std.testing.expectEqual(KeyChord{ .code = 29, .flags = 0x40000 | 0x80000 }, keyChord("ctrl+alt+0").?);
    try std.testing.expectEqual(@as(?KeyChord, null), keyChord("hyper"));
    try std.testing.expectEqual(@as(?KeyChord, null), keyChord(""));
    try std.testing.expectEqual(@as(?KeyChord, null), keyChord("shift"));
    try std.testing.expectEqual(@as(?KeyChord, null), keyChord("tab+shift"));
    try std.testing.expectEqual(@as(?KeyChord, null), keyChord("shift+"));
    try std.testing.expectEqual(ActionType.key, try actionType("key"));
}

test "numbered keys are zero-based aliases and agents action is configurable" {
    for ("012345", "abcdef", 0..) |digit, letter, index| {
        try std.testing.expectEqual(index, try bindingIndex(&.{digit}));
        try std.testing.expectEqual(index, try bindingIndex(&.{letter}));
    }
    try std.testing.expectError(error.InvalidKey, bindingIndex("6"));
    try std.testing.expectError(error.InvalidKey, bindingIndex(""));
    try std.testing.expectError(error.InvalidKey, bindingIndex("00"));
    try std.testing.expectEqual(ActionType.cycle_agents, try actionType("agents"));
    try std.testing.expectEqual(ActionType.cycle_agents, try actionType("cycle_agents"));
}

test "default JSON and struct agree: Esc 0, menu 1, Delete 2, PTT 3, agents 4, Return 5" {
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, defaultConfigJson(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings((Config{}).knob, parsed.value.knob);
    try std.testing.expectEqual((Config{}).knob_scroll_lines, parsed.value.knob_scroll_lines);
    try std.testing.expectEqual((Config{}).led, parsed.value.led);
    for ((Config{}).bindings, parsed.value.bindings, 0..) |expected, actual, index| {
        try std.testing.expectEqualStrings(expected.action, actual.action);
        const action = try actionType(actual.action);
        try std.testing.expectEqualStrings(expected.value, actual.value);
        try std.testing.expectEqual(switch (index) {
            0, 2, 5 => ActionType.key,
            1 => ActionType.agents_menu,
            3 => ActionType.push_to_talk,
            4 => ActionType.cycle_agents,
            else => ActionType.disabled,
        }, action);
        if (action == .key) try std.testing.expect(keyChord(actual.value) != null);
    }
}
