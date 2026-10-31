const std = @import("std");

// zafi development tooling. Run from this directory, e.g.
//
//   zig build fixtures -- --group flex       Taffy XML fixture corpus
//   zig build bench-compare -- --repeat 5    matched benchmarks vs Rust Taffy
//
// The pinned Taffy checkout lives at ../.references/taffy (fetch-reference.sh).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const repo_root = b.path("..");

    const zafi_mod = b.dependency("zafi", .{ .target = target, .optimize = optimize }).module("zafi");

    // Static API/feature audit against the pinned Taffy checkout.
    const audit_step = b.step("audit", "Diff the public surface against pinned Taffy");
    const audit = b.addSystemCommand(&.{ "python3", "tools/api_audit.py" });
    audit.setCwd(repo_root);
    audit_step.dependOn(&audit.step);

    // Differential verification: same scenarios on Rust Taffy and zafi.
    const parity_step = b.step("parity", "Run the Rust-vs-Zig differential parity harness");
    const parity = b.addSystemCommand(&.{ "python3", "tools/parity/run.py" });
    parity.setCwd(repo_root);
    parity.addPassthruArgs();
    parity_step.dependOn(&parity.step);

    // Taffy's generated XML fixture corpus, read relative to the cwd.
    const fixtures_opts = b.addOptions();
    fixtures_opts.addOption([]const u8, "fixtures_dir", ".references/taffy/tests/xml");
    const fixtures_exe = b.addExecutable(.{
        .name = "fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fixtures/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zafi", .module = zafi_mod },
                .{ .name = "build_options", .module = fixtures_opts.createModule() },
            },
        }),
    });
    const fixtures_run = b.addRunArtifact(fixtures_exe);
    fixtures_run.setCwd(repo_root);
    fixtures_run.addPassthruArgs();
    const fixtures_step = b.step("fixtures", "Run Taffy XML fixtures");
    fixtures_step.dependOn(&fixtures_run.step);

    // Installed runner for fixtures/run_all.py (one process per fixture).
    const fixtures_bin_step = b.step("fixtures-bin", "Install the fixture runner into tools/zig-out/bin");
    fixtures_bin_step.dependOn(&b.addInstallArtifact(fixtures_exe, .{}).step);

    // Benchmarks build the library at their own optimize level (default
    // ReleaseFast): timing a Debug library against optimized Rust compares
    // nothing.
    const bench_optimize = b.option(std.builtin.OptimizeMode, "bench-optimize", "Optimize mode for benchmarks (default fast)") orelse .fast;
    const bench_zafi_mod = b.dependency("zafi", .{ .target = target, .optimize = bench_optimize }).module("zafi");

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{.{ .name = "zafi", .module = bench_zafi_mod }},
        }),
    });
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.addPassthruArgs();
    const bench_step = b.step("bench", "Run zafi benchmarks");
    bench_step.dependOn(&bench_run.step);
    const bench_bin_step = b.step("bench-bin", "Install the benchmark binary");
    bench_bin_step.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);

    const bench_rust_step = b.step("bench-rust", "Run the Rust Taffy benchmark mirror");
    const bench_rust = b.addSystemCommand(&.{ "cargo", "run", "--release", "--quiet", "--manifest-path", "tools/bench/rust/Cargo.toml" });
    bench_rust.setCwd(repo_root);
    bench_rust_step.dependOn(&bench_rust.step);

    const alloc_probe_exe = b.addExecutable(.{
        .name = "alloc_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/alloc_probe.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{.{ .name = "zafi", .module = bench_zafi_mod }},
        }),
    });
    const alloc_probe_step = b.step("bench-allocs", "Report allocation counts per layout pass");
    alloc_probe_step.dependOn(&b.addRunArtifact(alloc_probe_exe).step);

    const bench_compare_step = b.step("bench-compare", "Run matched Taffy-vs-zafi benchmarks");
    const bench_compare = b.addSystemCommand(&.{ "python3", "tools/bench/compare.py", "--zig-bin" });
    bench_compare.setCwd(repo_root);
    bench_compare.addArtifactArg(bench_exe);
    bench_compare.addPassthruArgs();
    bench_compare_step.dependOn(&bench_compare.step);

    const bench_cpu_step = b.step("bench-cpu", "Run matched benchmarks using child CPU time");
    const bench_cpu = b.addSystemCommand(&.{ "python3", "tools/bench/cpu_compare.py", "--zig-bin" });
    bench_cpu.setCwd(repo_root);
    bench_cpu.addArtifactArg(bench_exe);
    bench_cpu.addPassthruArgs();
    bench_cpu_step.dependOn(&bench_cpu.step);
}
