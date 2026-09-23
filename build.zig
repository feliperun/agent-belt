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

    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("CoreAudio", .{});
    exe.root_module.linkFramework("AudioToolbox", .{});
    exe.root_module.linkFramework("IOKit", .{});
    exe.root_module.linkFramework("AppKit", .{});

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
    b.step("test", "Test overlay placement, audio response and dismissal (macOS GUI)").dependOn(&test_cmd.step);
}
