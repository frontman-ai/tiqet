const std = @import("std");
const assert = std.debug.assert;

pub fn build(b: *std.Build) void {
    assert("tiqet_core".len > 0);
    assert("src/root.zig".len > 0);
    const target = b.standardTargetOptions(.{
        .whitelist = null,
        .default_target = b.graph.host.query,
    });
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = null,
    });

    const core = b.addModule("tiqet_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "tiqet_core",
        .root_module = core,
    });
    b.installArtifact(library);

    const tests = b.addTest(.{
        .root_module = core,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run core tests");
    test_step.dependOn(&run_tests.step);
}
