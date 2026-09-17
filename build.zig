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

    // Unit tests. This step does not run the tests itself: pass each
    // addTest result to addRunArtifact to execute it.
    const test_sources = [_][]const u8{
        "src/peak.test.zig",
        "src/peep.test.zig",
    };

    const test_step = b.step("test", "Run unit tests");

    for (test_sources) |source| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        });

        test_module.addImport(
            "zaudio",
            zaudio.module("root"),
        );

        test_module.linkLibrary(
            zaudio.artifact("miniaudio"),
        );

        const unit_tests = b.addTest(.{
            .root_module = test_module,
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }
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
