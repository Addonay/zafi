const std = @import("std");

// zafi package build: the library module and its unit tests.
//
// Development tooling (Taffy fixture corpus, differential parity harness,
// benchmarks, API audit) lives on the `dev` branch as a separate package in
// `tools/` that depends on this one; see DEVELOPMENT.md there.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Taffy-compatible JSON serde is optional; the dependency is only fetched
    // and compiled when `-Dserde=true`.
    const enable_serde = b.option(bool, "serde", "Enable Taffy-compatible JSON serde support") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "serde", enable_serde);

    var module_imports: [2]std.Build.Module.Import = undefined;
    var import_count: usize = 0;
    module_imports[import_count] = .{ .name = "zafi_options", .module = build_options.createModule() };
    import_count += 1;
    if (enable_serde) {
        // Propagating `error.LazyDependencyNeeded` lets the build runner fetch
        // the dependency and re-run this script.
        const serde_dep = try b.dependencyLazy("serde", .{});
        module_imports[import_count] = .{ .name = "serde", .module = serde_dep.module("serde") };
        import_count += 1;
    }

    const zafi_mod = b.addModule("zafi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = module_imports[0..import_count],
    });

    const run_mod_tests = b.addRunArtifact(b.addTest(.{ .root_module = zafi_mod }));

    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&run_mod_tests.step);

    const check_step = b.step("check", "Alias for `test`");
    check_step.dependOn(&run_mod_tests.step);
}
