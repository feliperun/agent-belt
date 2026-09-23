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

    if (std.mem.eql(u8, argv[1], "status")) {
        var parsed = try store.load();
        defer parsed.deinit();
        const cfg = parsed.value;
        return macos.statusReport(cfg.vendor_id, cfg.product_id, cfg.deepgram_api_key_env);
    }

    if (std.mem.eql(u8, argv[1], "version")) {
        std.debug.print("agb (Agent Belt) {s}\n", .{@import("build_options").version});
        return;
    }

    if (std.mem.eql(u8, argv[1], "update")) {
        // agb update [tag]: builds that release (default: the latest) from source.
        if (argc > 3) return usage();
        const tag: ?[:0]const u8 = if (argc == 3) try allocator.dupeZ(u8, argv[2]) else null;
        defer if (tag) |t| allocator.free(t);
        return macos.updateRun(tag);
    }

    // Agent sessions (the work engine, bundled in the app): one CLI for everything.
    if (std.mem.eql(u8, argv[1], "sessions")) return execWork(allocator, "bin/work", &.{});
    inline for (.{ "ls", "attach", "hosts", "doctor", "adopt" }) |verb| {
        if (std.mem.eql(u8, argv[1], verb)) return execWork(allocator, "bin/work", argv[1..argc]);
    }
    if (std.mem.eql(u8, argv[1], "tm")) return execWork(allocator, "bin/tm", argv[2..argc]);
    if (std.mem.eql(u8, argv[1], "deploy")) return execWork(allocator, "scripts/deploy.sh", argv[2..argc]);

    if (std.mem.eql(u8, argv[1], "new") and argc > 2 and std.mem.startsWith(u8, argv[2], "--") and
        !std.mem.eql(u8, argv[2], "--dry-run"))
    {
        return execWork(allocator, "bin/work", try newSessionArgs(allocator, argv[2..argc]));
    }

    if (std.mem.eql(u8, argv[1], "new")) {
        // agb new [--dry-run] <pedido em linguagem natural>
        var rest = argv[2..argc];
        const dry_run = rest.len > 0 and std.mem.eql(u8, rest[0], "--dry-run");
        if (dry_run) rest = rest[1..];
        if (rest.len == 0) return usage();
        const text = try joinArgs(allocator, rest);
        defer allocator.free(text);
        return macos.agentsNew(allocator, text, dry_run);
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

/// agb new --task t [--repo r] [--host h] [--agent claude|codex|shell] [--prompt p]
/// becomes work's own arguments: [host] task [repo] --agent a [--prompt p].
fn newSessionArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var task: ?[]const u8 = null;
    var repo: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var agent: []const u8 = "claude";
    var prompt: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const value = args[i + 1];
        if (std.mem.eql(u8, args[i], "--task")) task = value
        else if (std.mem.eql(u8, args[i], "--repo")) repo = value
        else if (std.mem.eql(u8, args[i], "--host")) host = value
        else if (std.mem.eql(u8, args[i], "--agent")) agent = value
        else if (std.mem.eql(u8, args[i], "--prompt")) prompt = value
        else return error.InvalidArguments;
    }
    var out: std.ArrayList([]const u8) = .empty;
    if (host) |h| try out.append(allocator, h);
    try out.append(allocator, task orelse return error.InvalidArguments);
    if (repo) |r| try out.append(allocator, r);
    try out.appendSlice(allocator, &.{ "--agent", agent });
    if (prompt) |p| try out.appendSlice(allocator, &.{ "--prompt", p });
    return out.items;
}

/// Replaces this process with a tool of the work engine: the copy bundled in
/// Agent Belt.app, else the one installed in ~/.local/bin.
fn execWork(allocator: std.mem.Allocator, tool: []const u8, args: []const []const u8) !void {
    const path = blk: {
        const exe = try macos.selfExePath(allocator);
        var buffer: [std.c.PATH_MAX]u8 = undefined;
        const exe_z = try allocator.dupeZ(u8, exe);
        if (std.c.realpath(exe_z, &buffer)) |real| {
            const contents = std.fs.path.dirname(std.fs.path.dirname(std.mem.span(real)) orelse "") orelse "";
            const bundled = try std.fs.path.join(allocator, &.{ contents, "Resources", "work", tool });
            if (std.c.access(try allocator.dupeZ(u8, bundled), std.c.X_OK) == 0) break :blk bundled;
        }
        const home = std.mem.span(std.c.getenv("HOME") orelse return error.HomeNotFound);
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "bin", std.fs.path.basename(tool) });
    };
    const argv = try allocator.alloc(?[*:0]const u8, args.len + 2);
    argv[0] = try allocator.dupeZ(u8, path);
    for (args, 0..) |arg, i| argv[i + 1] = try allocator.dupeZ(u8, arg);
    argv[args.len + 1] = null;
    _ = std.c.execve(argv[0].?, @ptrCast(argv.ptr), std.c.environ);
    std.debug.print("agb: não consegui executar {s}\n", .{path});
    return error.ExecFailed;
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
        "  agb new [--dry-run] <pedido>   (ex.: crie um agente no windows com codex no coreum para …)\n" ++
        "  agb new --task <t> [--repo r] [--host m] [--agent claude|codex|shell] [--prompt p]\n" ++
        "  agb sessions | ls | attach <s> [m] | hosts | doctor | adopt   (sessões de agente em qualquer máquina)\n" ++
        "  agb tm [nome] · agb deploy <máquina…|--all>\n" ++
        "  agb permissions   (abre Monitoramento de Entrada, Acessibilidade e Microfone)\n" ++
        "  agb led <cor 0-7> <modo 0-5>   (1 vermelho … 7 roxo; 0 apagado, 1 fixo, 2 reativo, 5 branco)\n" ++
        "  agb daemon\n" ++
        "  agb preview\n" ++
        "  agb agents <list|next|bottom> [desktop]\n" ++
        "  ./install.sh [--keep-config|--uninstall]\n", .{});
    return error.InvalidArguments;
}
