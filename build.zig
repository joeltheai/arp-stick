const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(b.path("vendor/clap/include"));
    module.addIncludePath(b.path("src"));
    if (target.result.os.tag == .macos) addNativeUI(b, module);
    const lib = b.addLibrary(.{ .name = "ArpStick", .linkage = .dynamic, .root_module = module });
    if (target.result.os.tag == .macos) {
        const install = b.addInstallFile(lib.getEmittedBin(), "ArpStick.clap/Contents/MacOS/ArpStick");
        b.getInstallStep().dependOn(&install.step);
        b.getInstallStep().dependOn(&b.addInstallFile(b.path("resources/Info.plist"), "ArpStick.clap/Contents/Info.plist").step);
    } else {
        b.getInstallStep().dependOn(&b.addInstallFile(lib.getEmittedBin(), "ArpStick.clap").step);
    }
    if (target.result.os.tag == .macos) {
        const preview_module = b.createModule(.{
            .root_source_file = b.path("src/preview.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        preview_module.addIncludePath(b.path("src"));
        addNativeUI(b, preview_module);
        const preview = b.addExecutable(.{ .name = "arp-stick-preview", .root_module = preview_module });
        const run_preview = b.addRunArtifact(preview);
        if (b.args) |args| run_preview.addArgs(args);
        b.step("preview", "Open the standalone UI preview (no DAW, no audio)").dependOn(&run_preview.step);
    }
    const unit_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const test_step = b.step("test", "Run MIDI engine tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    if (target.result.os.tag == .macos or target.result.os.tag == .linux) {
        const host = b.addExecutable(.{ .name = "clap-smoke-test", .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        host.root_module.addIncludePath(b.path("vendor/clap/include"));
        host.root_module.addCSourceFile(.{ .file = b.path("tests/host.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        if (target.result.os.tag == .linux) host.root_module.linkSystemLibrary("dl", .{});
        const run = b.addRunArtifact(host);
        run.addArtifactArg(lib);
        test_step.dependOn(&run.step);
        if (target.result.os.tag == .macos) {
            const gui_test = b.addExecutable(.{ .name = "clap-gui-test", .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }) });
            gui_test.root_module.addIncludePath(b.path("vendor/clap/include"));
            gui_test.root_module.addCSourceFile(.{ .file = b.path("tests/gui_host.m"), .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" } });
            gui_test.root_module.linkFramework("Cocoa", .{});
            gui_test.root_module.linkSystemLibrary("objc", .{});
            const run_gui_test = b.addRunArtifact(gui_test);
            run_gui_test.addArtifactArg(lib);
            b.step("test-ui", "Check the actual CLAP editor in a small Cocoa host").dependOn(&run_gui_test.step);
        }
    }
}

fn addNativeUI(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{ .file = b.path("src/ui/macos.m"), .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra" } });
    module.linkFramework("Cocoa", .{});
    module.linkFramework("QuartzCore", .{});
    module.linkSystemLibrary("objc", .{});
}
