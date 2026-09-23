const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const config = @import("config.zig");
const daemon = @import("daemon.zig");
const macos = @import("macos.zig");
const sessions = @import("sessions/cli.zig");
const sys = @import("sessions/sys.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    var args: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |arg| try args.append(allocator, arg[0..arg.len]);
    const argv = args.items;
    const argc = argv.len;

    // Agent sessions: every platform.
    if (argc >= 2 and sessions.isSessionCommand(argv[1])) {
        const ctx = sys.Ctx{ .io = init.io, .gpa = init.arena.allocator(), .env = init.environ_map };
        std.process.exit(try sessions.main(.{ .ctx = ctx, .version = build_options.version, .source_root = build_options.source_root }, argv[1..argc]));
    }
    if (argc >= 2 and std.mem.eql(u8, argv[1], "version")) {
        std.debug.print("agb (Agent Belt) {s}\n", .{build_options.version});
        return;
    }
    if (comptime builtin.os.tag == .windows) return windowsMain(init, argv);
    // The keypad daemon and its UI exist on macOS and Windows for now.
    if (comptime builtin.os.tag != .macos) return usageSessions();
    return macMain(init, argv);
}

/// agent-belt.exe (GUI subsystem, started at login) is the tray daemon;
/// agb.exe adds `daemon`, `install` and `uninstall` to the session CLI.
fn windowsMain(init: std.process.Init, argv: []const []const u8) !void {
    const win = @import("windows/daemon.zig");
    const ctx = sys.Ctx{ .io = init.io, .gpa = init.arena.allocator(), .env = init.environ_map };
    const self = std.fs.path.basename(argv[0]);
    const is_daemon = std.ascii.startsWithIgnoreCase(self, "agent-belt");
    const command = if (argv.len >= 2) argv[1] else if (is_daemon) "daemon" else "";
    if (std.mem.eql(u8, command, "daemon")) std.process.exit(try win.run(ctx, build_options.version));
    if (std.mem.eql(u8, command, "install")) std.process.exit(try win.install(ctx));
    if (std.mem.eql(u8, command, "uninstall")) std.process.exit(try win.uninstall(ctx));
    return usageSessions();
}

fn usageSessions() !void {
    std.debug.print(
        \\agb (Agent Belt) {s}: agent sessions on any machine of your tailnet
        \\
        \\  agb new [claude|codex|shell] [machine|here] [repo] [what to do…]
        \\  agb sessions | ls | repos [machine] | attach [-d] <session> [machine]
        \\  agb send <session> [machine] <text…> | peek <session> [machine] [lines] | stop <session> [machine]
        \\  agb hosts [discover|add|rm|self] | doctor | adopt [machine] | tm [name] | deploy <machine…|--all>
        \\  agb version
        \\  Windows: agb install | uninstall | daemon (tray icon, Ctrl+Alt+D dictation, Ctrl+Alt+Space menu)
        \\
    , .{build_options.version});
    return error.InvalidArguments;
}

fn macMain(init: std.process.Init, argv: []const []const u8) !void {
    const allocator = init.gpa;
    const argc = argv.len;
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

    if (std.mem.eql(u8, argv[1], "status")) {
        var parsed = try store.load();
        defer parsed.deinit();
        const cfg = parsed.value;
        return macos.statusReport(cfg.vendor_id, cfg.product_id, cfg.deepgram_api_key_env);
    }


    if (std.mem.eql(u8, argv[1], "update")) {
        // agb update [tag]: builds that release (default: the latest) from source.
        if (argc > 3) return usage();
        const tag: ?[:0]const u8 = if (argc == 3) try allocator.dupeZ(u8, argv[2]) else null;
        defer if (tag) |t| allocator.free(t);
        return macos.updateRun(tag);
    }

    if (std.mem.eql(u8, argv[1], "permissions")) {
        // Opens the three lists the app must be enabled in.
        for ([_][*:0]const u8{ "ListenEvent", "Accessibility", "Microphone" }) |pane| {
            macos.openPrivacy(pane);
            std.Io.sleep(init.io, .fromMilliseconds(700), .awake) catch {};
        }
        return;
    }

    if (std.mem.eql(u8, argv[1], "led")) {
        if (argc != 4) return usage();
        const color = std.fmt.parseInt(u8, argv[2], 10) catch return usage();
        const mode = std.fmt.parseInt(u8, argv[3], 10) catch return usage();
        var parsed = try store.load();
        defer parsed.deinit();
        return macos.ledSet(parsed.value.vendor_id, parsed.value.product_id, color, mode);
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
        .disabled, .push_to_talk, .agents_menu => "",
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
        .agents_menu => .{ .action = "agents_menu", .value = value },
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
    std.debug.print("agb (Agent Belt) — daemon de teclas HID configuráveis\n" ++
        "\n" ++
        "uso:\n" ++
        "  agb init\n" ++
        "  agb bind <a-f> ptt\n" ++
        "  agb bind <0-5|a-f> agents [desktop]\n" ++
        "  agb bind <0-5|a-f> menu\n" ++
        "  agb bind <0-5|a-f> key <[cmd+|shift+|alt+|ctrl+]escape|delete|return|tab|a-z|0-9|...>\n" ++
        "  agb bind <a-f> command <comando>\n" ++
        "  agb bind <a-f> script <comando-ou-script>\n" ++
        "  agb bind <a-f> text <texto>\n" ++
        "  agb bind <a-f> disabled\n" ++
        "  agb devices\n" ++
        "  agb status\n" ++
        "  agb version\n" ++
        "  agb update [tag]\n" ++
        "  agb new [claude|codex|shell] [machine|here] [repo] [what to do…]\n" ++
        "  agb sessions | ls | attach <s> [m] | hosts | doctor | adopt | tm [name] | deploy <m…|--all>\n" ++
        "  agb permissions   (abre Monitoramento de Entrada, Acessibilidade e Microfone)\n" ++
        "  agb led <cor 0-7> <modo 0-5>   (1 vermelho … 7 roxo; 0 apagado, 1 fixo, 2 reativo, 5 branco)\n" ++
        "  agb daemon\n" ++
        "  agb preview\n" ++
        "  agb agents <list|next|bottom> [desktop]\n" ++
        "  ./install.sh [--keep-config|--uninstall]\n", .{});
    return error.InvalidArguments;
}
