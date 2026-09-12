const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zaudio = b.dependency("zaudio", .{});

    const peep = addExecutable(b, "peep", "src/peep.zig", target, optimize, zaudio);
    const peak = addExecutable(b, "peak", "src/peak.zig", target, optimize, zaudio);

    b.installArtifact(peep);
    b.installArtifact(peak);

    const run = b.addRunArtifact(peep);

    const run_step = b.step("run", "Run peep");
    run_step.dependOn(&run.step);
}

fn addExecutable(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zaudio: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport(
        "zaudio",
        zaudio.module("root"),
    );

    exe.root_module.linkLibrary(
        zaudio.artifact("miniaudio"),
    );

    return exe;
}
