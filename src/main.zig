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
        try installLaunchAgent(init.io, allocator, store);
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

fn installLaunchAgent(io: std.Io, allocator: std.mem.Allocator, store: config.ConfigStore) !void {
    const exe = try macos.selfExePath(allocator);
    defer allocator.free(exe);
    const home_ptr = std.c.getenv("HOME") orelse return error.HomeNotFound;
    const home = std.mem.span(home_ptr);
    const launch_agents = try std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents" });
    defer allocator.free(launch_agents);
    try std.Io.Dir.createDirPath(.cwd(), io, launch_agents);
    const plist_path = try std.fs.path.join(allocator, &.{ launch_agents, "com.frb.minikeyboard.plist" });
    defer allocator.free(plist_path);

    const plist = try std.fmt.allocPrint(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
        "<plist version=\"1.0\"><dict>\n" ++
        "<key>Label</key><string>com.frb.minikeyboard</string>\n" ++
        "<key>ProgramArguments</key><array><string>{s}</string><string>daemon</string></array>\n" ++
        "<key>RunAtLoad</key><true/>\n" ++
        "<key>KeepAlive</key><true/>\n" ++
        "<key>StandardOutPath</key><string>{s}/Library/Logs/minikeyboard.log</string>\n" ++
        "<key>StandardErrorPath</key><string>{s}/Library/Logs/minikeyboard.log</string>\n" ++
        "</dict></plist>\n", .{ exe, home, home });
    defer allocator.free(plist);

    var file = try std.Io.Dir.createFileAbsolute(io, plist_path, .{
        .truncate = true,
        .permissions = .default_file,
    });
    defer file.close(io);
    try file.writeStreamingAll(io, plist);
    _ = store;
    std.debug.print("LaunchAgent instalado em {s}\n", .{plist_path});
    std.debug.print("carregue-o com: launchctl load {s}\n", .{plist_path});
}

fn usage() !void {
    std.debug.print("minikeyboard — daemon de teclas HID configuráveis\n" ++
        "\n" ++
        "uso:\n" ++
        "  minikeyboard init\n" ++
        "  minikeyboard bind <a-f> ptt\n" ++
        "  minikeyboard bind <0-5|a-f> agents [desktop]\n" ++
        "  minikeyboard bind <a-f> command <comando>\n" ++
        "  minikeyboard bind <a-f> script <comando-ou-script>\n" ++
        "  minikeyboard bind <a-f> text <texto>\n" ++
        "  minikeyboard bind <a-f> disabled\n" ++
        "  minikeyboard devices\n" ++
        "  minikeyboard daemon\n" ++
        "  minikeyboard preview\n" ++
        "  minikeyboard agents <list|next|bottom> [desktop]\n" ++
        "  minikeyboard install\n", .{});
    return error.InvalidArguments;
}
