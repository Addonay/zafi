const std = @import("std");

// Standalone package build for the extracted Taffy port. The source tree under
// `src/` is a byte-for-byte copy of `zui/src/layout/`; the package exposes the
// same `layout` module so it can be consumed independently of ZUI.
//
// `zig build test` runs the port's unit tests. It is the same root module the
// parent ZUI build compiles at `src/layout/root.zig`, so a failure here is a
// port failure, not an integration failure.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Taffy gates serde behind a feature; so does this package. The serde
    // dependency is lazy, so the default build neither fetches nor compiles it.
    const enable_serde = b.option(bool, "serde", "Enable Taffy-compatible JSON serde support") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "serde", enable_serde);

    var module_imports: [2]std.Build.Module.Import = undefined;
    var import_count: usize = 0;
    module_imports[import_count] = .{ .name = "zlay_options", .module = build_options.createModule() };
    import_count += 1;
    if (enable_serde) {
        // Lazy-fetch contract (std.Build.dependencyLazy): when `serde` has not
        // been fetched yet this reports `error.LazyDependencyNeeded` after
        // marking it needed; propagating lets the build runner fetch it and
        // re-run this script. The previous `lazyDependency(...) orelse @panic`
        // aborted `-Dserde=true` from a clean cache instead of fetching.
        const serde_dep = try b.dependencyLazy("serde", .{});
        module_imports[import_count] = .{ .name = "serde", .module = serde_dep.module("serde") };
        import_count += 1;
    }

    const zlay_mod = b.addModule("zlay", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = module_imports[0..import_count],
    });

    const mod_tests = b.addTest(.{
        .root_module = zlay_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run layout unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // `zig build check` is an alias kept for symmetry with the sibling ports
    // (.ports/cozmic, .ports/wgpu, .ports/vellz). Today it is the test step.
    const check_step = b.step("check", "Compile and test the layout package");
    check_step.dependOn(&run_mod_tests.step);

    // Static API/feature audit against the pinned Taffy checkout. Requires
    // the reference at .references/taffy and python3; it never mutates source.
    const audit_step = b.step("audit", "Diff the port's public surface against pinned Taffy");
    const audit = b.addSystemCommand(&.{ "python3", "tools/api_audit.py" });
    audit_step.dependOn(&audit.step);

    // Differential verification: the same scenarios run against the pinned
    // Rust Taffy crate and the Zig port, then get diffed. Requires Cargo for
    // the oracle and the .references/taffy checkout.
    const parity_step = b.step("parity", "Run the Rust-vs-Zig differential parity harness");
    const parity = b.addSystemCommand(&.{ "python3", "tools/parity/run.py" });
    parity.addPassthruArgs();
    parity_step.dependOn(&parity.step);

    // The parity gate from port.md: run Taffy's generated XML fixture suite
    // against the port. `zig build fixtures -- --group flex --filter ...`.
    const fixtures_opts = b.addOptions();
    fixtures_opts.addOption([]const u8, "fixtures_dir", ".references/taffy/tests/xml");
    const fixtures_exe = b.addExecutable(.{
        .name = "fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fixtures/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zlay", .module = zlay_mod },
                .{ .name = "build_options", .module = fixtures_opts.createModule() },
            },
        }),
    });
    const fixtures_run = b.addRunArtifact(fixtures_exe);
    fixtures_run.setCwd(b.path("."));
    fixtures_run.addPassthruArgs();
    const fixtures_step = b.step("fixtures", "Run Taffy XML fixtures against the port");
    fixtures_step.dependOn(&fixtures_run.step);

    // Install the fixture runner so tools/fixtures/run_all.py can execute one
    // fixture per process (a port panic then becomes a recorded failure
    // instead of aborting the whole suite).
    const fixtures_install = b.addInstallArtifact(fixtures_exe, .{});
    const fixtures_bin_step = b.step("fixtures-bin", "Install the fixture runner into zig-out/bin");
    fixtures_bin_step.dependOn(&fixtures_install.step);

    // Benchmarks covering Taffy's benchmark categories. Default to
    // ReleaseFast because comparing debug builds against Rust release builds
    // would be meaningless; override with -Dbench-optimize=... if needed.
    const bench_optimize = b.option(std.builtin.OptimizeMode, "bench-optimize", "Optimize mode for benchmarks (default fast)") orelse .fast;
    // The harness needs its own copy of the library module at the benchmark
    // optimization level. Reusing `zlay_mod` would compile the layout code at
    // the *global* `-Doptimize` level, which defaults to Debug: the port would
    // then be timed with safety checks and no optimization while Taffy ran
    // optimized, which compares nothing. Same reasoning applies to the
    // fixtures runner.
    const bench_zlay_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = module_imports[0..import_count],
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench/main.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{.{ .name = "zlay", .module = bench_zlay_mod }},
        }),
    });
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.addPassthruArgs();
    const bench_step = b.step("bench", "Run layout benchmarks (defaults to ReleaseFast)");
    bench_step.dependOn(&bench_run.step);

    // Rust mirror of the same scenarios (Cargo profile: LTO, one codegen unit).
    const bench_rust_step = b.step("bench-rust", "Run the Rust Taffy benchmark mirror");
    const bench_rust = b.addSystemCommand(&.{ "cargo", "run", "--release", "--quiet", "--manifest-path", "tools/bench/rust/Cargo.toml" });
    bench_rust_step.dependOn(&bench_rust.step);

    // Allocation census: runs each scenario once with a counting allocator, so
    // a regression in per-pass allocation volume is visible even when wall time
    // is dominated by compute.
    const alloc_probe_exe = b.addExecutable(.{
        .name = "alloc_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench/alloc_probe.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{.{ .name = "zlay", .module = bench_zlay_mod }},
        }),
    });
    const alloc_probe_run = b.addRunArtifact(alloc_probe_exe);
    const alloc_probe_step = b.step("bench-allocs", "Report allocation counts per layout pass");
    alloc_probe_step.dependOn(&alloc_probe_run.step);

    // Matched comparison: runs both harnesses and prints a ratio table
    // (`zig build bench-compare [-- --filter flex] [-- --strict]`).
    const bench_compare_step = b.step("bench-compare", "Run matched Taffy-vs-port benchmarks");
    const bench_compare = b.addSystemCommand(&.{ "python3", "tools/bench/compare.py", "--zig-bin" });
    bench_compare.addArtifactArg(bench_exe);
    bench_compare.addPassthruArgs();
    bench_compare_step.dependOn(&bench_compare.step);

    // Contention-immune comparison: measures child CPU time (user+sys) instead
    // of wall time, so it stays meaningful on a shared/loaded host
    // (`zig build bench-cpu [-- --repeat 3 --cpu 2]`).
    const bench_cpu_step = b.step("bench-cpu", "Run matched benchmarks using child CPU time");
    const bench_cpu = b.addSystemCommand(&.{ "python3", "tools/bench/cpu_compare.py", "--zig-bin" });
    bench_cpu.addArtifactArg(bench_exe);
    bench_cpu.addPassthruArgs();
    bench_cpu_step.dependOn(&bench_cpu.step);
}
