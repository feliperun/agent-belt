const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // version.txt is bumped by release-please; the binary and the updater read it.
    const version = std.mem.trim(u8, b.build_root.handle.readFileAlloc(b.graph.io, "version.txt", b.allocator, .limited(64)) catch "0.0.0", " \n\r\t");
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    // agb deploy builds the other machines' binaries from this checkout.
    options.addOption([]const u8, "source_root", b.build_root.path orelse ".");
    const is_macos = target.result.os.tag == .macos;

    const exe = b.addExecutable(.{
        .name = "agb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    // The keypad daemon, overlay and agent UI are macOS code (AppKit, IOKit);
    // other systems get the session CLI.
    if (is_macos) {
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/macos_shim.c"),
            .flags = &.{"-fblocks"},
        });
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/status_item.m"),
            .flags = &.{"-fobjc-arc"},
        });
        exe.root_module.addIncludePath(b.path("src"));
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/agent_switcher.m"),
            .flags = &.{"-fobjc-arc"},
        });
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/knob.m"),
            .flags = &.{"-fobjc-arc"},
        });
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/system.m"),
            .flags = &.{"-fobjc-arc"},
        });
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/led.m"),
            .flags = &.{"-fobjc-arc"},
        });
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/updater.m"),
            .flags = &.{"-fobjc-arc"},
        });
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/agent_stats.m"),
            .flags = &.{"-fobjc-arc"},
        });

        exe.root_module.linkFramework("CoreFoundation", .{});
        exe.root_module.linkFramework("CoreGraphics", .{});
        exe.root_module.linkFramework("CoreAudio", .{});
        exe.root_module.linkFramework("AudioToolbox", .{});
        exe.root_module.linkFramework("IOKit", .{});
        exe.root_module.linkFramework("AppKit", .{});
        exe.root_module.linkFramework("ApplicationServices", .{});
        exe.root_module.linkFramework("Security", .{});
        exe.root_module.linkFramework("UserNotifications", .{});
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run agent-belt");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Test the CLI, bindings, agent switching and overlay (GUI parts on macOS)");
    inline for (.{ "src/config.zig", "src/key_edges.zig", "src/knob.zig", "src/f5.zig", "src/sessions/cli.zig" }) |path| {
        const unit_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path), .target = target, .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(unit_test).step);
    }
    if (!is_macos) return;
    const overlay_test = b.addExecutable(.{
        .name = "overlay-test",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    overlay_test.root_module.addCSourceFile(.{
        .file = b.path("tests/overlay_test.m"),
        .flags = &.{"-fobjc-arc"},
    });
    overlay_test.root_module.addIncludePath(b.path("src"));
    overlay_test.root_module.linkFramework("AppKit", .{});
    overlay_test.root_module.linkFramework("CoreFoundation", .{});
    const test_cmd = b.addRunArtifact(overlay_test);
    test_step.dependOn(&test_cmd.step);
    const agent_test = b.addExecutable(.{
        .name = "agent-switcher-test",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    agent_test.root_module.addCSourceFile(.{
        .file = b.path("tests/agent_switcher_test.m"),
        .flags = &.{ "-fobjc-arc", "-UNDEBUG" },
    });
    agent_test.root_module.addCSourceFile(.{
        .file = b.path("src/agent_stats.m"),
        .flags = &.{"-fobjc-arc"},
    });
    agent_test.root_module.addIncludePath(b.path("src"));
    agent_test.root_module.linkFramework("AppKit", .{});
    agent_test.root_module.linkFramework("ApplicationServices", .{});
    test_step.dependOn(&b.addRunArtifact(agent_test).step);
}
