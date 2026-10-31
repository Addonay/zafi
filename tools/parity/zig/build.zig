const std = @import("std");

// Verification-only build for the Zig side of the differential parity harness.
// It imports the package's layout module directly; it is not part of `zig build
// test` and does not affect the published package.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // root.zig imports `build_options` for the optional serde feature; the
    // harness never enables serde.
    const build_options = b.addOptions();
    build_options.addOption(bool, "serde", false);

    const zafi_mod = b.addModule("zafi", .{
        .root_source_file = b.path("../../../src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = build_options.createModule() }},
    });

    const exe = b.addExecutable(.{
        .name = "layout-parity-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zafi", .module = zafi_mod }},
        }),
    });

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const run_step = b.step("run", "Run the Zig parity candidate");
    run_step.dependOn(&run.step);
}
