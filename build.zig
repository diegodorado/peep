const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "resonic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const zaudio = b.dependency("zaudio", .{});

    exe.root_module.addImport(
        "zaudio",
        zaudio.module("root"),
    );

    exe.root_module.linkLibrary(
        zaudio.artifact("miniaudio"),
    );

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run resonic");
    run_step.dependOn(&run.step);
}
