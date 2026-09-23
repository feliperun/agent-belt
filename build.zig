const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "minikeyboard",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
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

    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("CoreAudio", .{});
    exe.root_module.linkFramework("AudioToolbox", .{});
    exe.root_module.linkFramework("IOKit", .{});
    exe.root_module.linkFramework("AppKit", .{});
    exe.root_module.linkFramework("ApplicationServices", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run minikeyboard");
    run_step.dependOn(&run_cmd.step);

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
    const test_step = b.step("test", "Test bindings, agent switching and overlay (macOS GUI)");
    test_step.dependOn(&test_cmd.step);
    const agent_test = b.addExecutable(.{
        .name = "agent-switcher-test",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    agent_test.root_module.addCSourceFile(.{
        .file = b.path("tests/agent_switcher_test.m"),
        .flags = &.{ "-fobjc-arc", "-UNDEBUG" },
    });
    agent_test.root_module.addIncludePath(b.path("src"));
    agent_test.root_module.linkFramework("AppKit", .{});
    agent_test.root_module.linkFramework("ApplicationServices", .{});
    test_step.dependOn(&b.addRunArtifact(agent_test).step);
    inline for (.{ "src/config.zig", "src/key_edges.zig", "src/knob.zig" }) |path| {
        const unit_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path), .target = target, .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(unit_test).step);
    }
}
