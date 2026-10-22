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
    const lib = b.addLibrary(.{ .name = "ArpStick", .linkage = .dynamic, .root_module = module });
    if (target.result.os.tag == .macos) {
        const install = b.addInstallFile(lib.getEmittedBin(), "ArpStick.clap/Contents/MacOS/ArpStick");
        b.getInstallStep().dependOn(&install.step);
        b.getInstallStep().dependOn(&b.addInstallFile(b.path("resources/Info.plist"), "ArpStick.clap/Contents/Info.plist").step);
    } else {
        b.getInstallStep().dependOn(&b.addInstallFile(lib.getEmittedBin(), "ArpStick.clap").step);
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
    }
}
