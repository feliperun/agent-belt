const std = @import("std");
const config = @import("config.zig");
const daemon = @import("daemon.zig");
const macos = @import("macos.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var iterator = std.process.Args.Iterator.init(init.minimal.args);
    var argv: [32][]const u8 = undefined;
    var argc: usize = 0;
    while (iterator.next()) |arg| {
        if (argc == argv.len) return error.TooManyArguments;
        argv[argc] = arg[0..arg.len];
        argc += 1;
    }
    if (argc < 2) return usage();

    var store = try config.ConfigStore.init(init.io, allocator);
    defer store.deinit();

    if (std.mem.eql(u8, argv[1], "init")) {
        const cfg = config.Config{};
        try store.save(cfg);
        std.debug.print("configuração criada em {s}\n", .{store.path});
        return;
    }

    if (std.mem.eql(u8, argv[1], "daemon")) {
        var parsed = try store.load();
        defer parsed.deinit();
        try daemon.run(init.io, allocator, parsed.value);
        return;
    }

    if (std.mem.eql(u8, argv[1], "preview")) {
        try macos.previewOverlay();
        return;
    }

    if (std.mem.eql(u8, argv[1], "agents")) {
        if (argc != 3 and argc != 4) return usage();
        const desktop = argc == 4 and std.mem.eql(u8, argv[3], "desktop");
        if (argc == 4 and !desktop) return usage();
        const mode = std.meta.stringToEnum(macos.AgentsMode, argv[2]) orelse return usage();
        return macos.agentsCommand(mode, desktop);
    }

    if (std.mem.eql(u8, argv[1], "bind")) {
        try bindCommand(allocator, store, argv[2..argc]);
        return;
    }

    if (std.mem.eql(u8, argv[1], "devices")) {
        const defaults = config.Config{};
        std.debug.print("HID configurado: VID=0x{x}, PID=0x{x}\n", .{ defaults.vendor_id, defaults.product_id });
        std.debug.print("(o suporte a descoberta de todos os HID será adicionado junto com o knob)\n", .{});
        return;
    }

    if (std.mem.eql(u8, argv[1], "install")) {
        std.debug.print("use ./install.sh na raiz do repositório (app assinado + LaunchAgent)\n", .{});
        return;
    }

    return usage();
}

fn bindCommand(allocator: std.mem.Allocator, store: config.ConfigStore, args: []const []const u8) !void {
    if (args.len < 2) return usage();
    const index = try config.bindingIndex(args[0]);
    const action = try config.actionType(args[1]);

    var parsed = try store.load();
    defer parsed.deinit();
    var cfg = parsed.value;

    var owned_value: ?[]const u8 = null;
    defer if (owned_value) |value| allocator.free(value);
    const value = switch (action) {
        .disabled, .push_to_talk => "",
        .cycle_agents => if (args.len > 2 and std.mem.eql(u8, args[2], "desktop")) "desktop" else if (args.len > 2) return usage() else "",
        .key => if (args.len == 3 and config.keyChord(args[2]) != null) args[2] else return usage(),
        .command, .script, .text => blk: {
            const joined = try joinArgs(allocator, args[2..]);
            owned_value = joined;
            break :blk joined;
        },
    };
    cfg.bindings[index] = switch (action) {
        .disabled => .{ .action = "disabled", .value = value },
        .push_to_talk => .{ .action = "push_to_talk", .value = value },
        .cycle_agents => .{ .action = "cycle_agents", .value = value },
        .key => .{ .action = "key", .value = value },
        .command => .{ .action = "command", .value = value },
        .script => .{ .action = "script", .value = value },
        .text => .{ .action = "text", .value = value },
    };
    try store.save(cfg);
    std.debug.print("tecla {s} configurada como {s}{s}\n", .{ args[0], args[1], if (args.len > 2) "" else "" });
}

fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return error.MissingValue;
    return std.mem.join(allocator, " ", args);
}

fn usage() !void {
    std.debug.print("minikeyboard — daemon de teclas HID configuráveis\n" ++
        "\n" ++
        "uso:\n" ++
        "  minikeyboard init\n" ++
        "  minikeyboard bind <a-f> ptt\n" ++
        "  minikeyboard bind <0-5|a-f> agents [desktop]\n" ++
        "  minikeyboard bind <0-5|a-f> key <[cmd+|shift+|alt+|ctrl+]escape|delete|return|tab|a-z|0-9|...>\n" ++
        "  minikeyboard bind <a-f> command <comando>\n" ++
        "  minikeyboard bind <a-f> script <comando-ou-script>\n" ++
        "  minikeyboard bind <a-f> text <texto>\n" ++
        "  minikeyboard bind <a-f> disabled\n" ++
        "  minikeyboard devices\n" ++
        "  minikeyboard daemon\n" ++
        "  minikeyboard preview\n" ++
        "  minikeyboard agents <list|next|bottom> [desktop]\n" ++
        "  ./install.sh [--keep-config|--uninstall]\n", .{});
    return error.InvalidArguments;
}
