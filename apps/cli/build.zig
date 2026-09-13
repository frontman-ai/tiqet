const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.dependency("tiqet_core", .{
        .target = target,
        .optimize = optimize,
    });

    const core_module = core.module("tiqet_core");
    const cli_logic_module = b.addModule("tiqet_cli", .{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tiqet_core", .module = core_module },
        },
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tiqet_core", .module = core_module },
            .{ .name = "tiqet_cli", .module = cli_logic_module },
        },
    });

    const cli = b.addExecutable(.{
        .name = "tiqet",
        .root_module = cli_module,
    });
    b.installArtifact(cli);

    const test_step = b.step("test", "Run CLI tests");
    const e2e = b.addExecutable(.{
        .name = "cli-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/e2e.zig"),
            .target = b.graph.host,
        }),
    });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.addArtifactArg(cli);
    test_step.dependOn(&run_e2e.step);

    const run_scale = b.addRunArtifact(e2e);
    run_scale.addArtifactArg(cli);
    run_scale.addArg("--scale");
    b.step("benchmark", "Measure CLI latency with large task histories").dependOn(&run_scale.step);
}
