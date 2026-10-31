#!/usr/bin/env python3
"""Contention-immune comparison: pinned Taffy (Rust) vs Zig port.

The host is shared, so wall-clock benchmarks are dominated by descheduling.
This runner measures each scenario in its own child process and reports the
child's user+sys CPU time from getrusage(RUSAGE_CHILDREN), which is unaffected
by contention, pinned to one CPU.

## Why the baseline subtraction is not optional

A child's CPU time includes process startup: dynamic linking, runtime
initialisation, and teardown. For the fast scenarios that startup is the same
order of magnitude as the layout work itself, so a raw per-process total
compares start-up costs rather than algorithms. Concretely, before this was
fixed, `block_nested_50` reported 0.95x here while the wall-clock harness
measured the same scenario at 1.64x -- the CPU number was almost entirely
process init.

So the process baseline is measured directly, with a filter that matches no
scenario, and subtracted from each per-scenario total. A scenario whose
remaining work is not clearly above the baseline is reported as
`noise-dominated` and excluded from the geometric mean rather than being
allowed to contribute a meaningless ratio.

Usage:
    python3 tools/bench/cpu_compare.py --zig-bin /path/to/bench [--repeat 3] [--filter flex]
"""

from __future__ import annotations

import argparse
import math
import resource
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUST_BIN = HERE / "rust" / "target" / "release" / "zafi-bench-rust"

SCENARIOS = [
    "tree_creation_10k",
    "flex_row_1000",
    "flex_wrap_500",
    "grid_50x50",
    "block_nested_50",
    "mixed_flex_grid_block",
]

# A filter no scenario contains, so the child runs no scenario at all and its
# CPU time is pure process overhead.
NO_MATCH = "__no_such_scenario__"

# Below this many multiples of the baseline, the scenario's own work is not
# separable from process overhead and the ratio is not meaningful.
MIN_SIGNAL = 3.0


def run_child(command: list[str]) -> float:
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    proc = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if proc.returncode != 0:
        raise SystemExit(f"failed ({proc.returncode}): {' '.join(command)}")
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)


def best(command: list[str], repeat: int) -> float:
    return min(run_child(command) for _ in range(repeat))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig-bin", type=Path, required=True)
    parser.add_argument("--repeat", type=int, default=5)
    parser.add_argument("--filter")
    parser.add_argument("--cpu", type=int, default=2)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    if shutil.which("taskset") is None:
        raise SystemExit("taskset is required on PATH (--cpu pinning)")
    prefix = ["taskset", "-c", str(args.cpu)]
    scenarios = [s for s in SCENARIOS if not args.filter or args.filter in s]

    if not RUST_BIN.exists():
        manifest = HERE / "rust" / "Cargo.toml"
        print(f"building Rust mirror (missing {RUST_BIN})...", file=sys.stderr)
        subprocess.run(
            ["cargo", "build", "--release", "--quiet", "--manifest-path", str(manifest)],
            check=True,
        )

    # Process overhead for each side, measured with no scenario selected.
    taffy_baseline = best(prefix + [str(RUST_BIN), "--filter", NO_MATCH], args.repeat)
    port_baseline = best(prefix + [str(args.zig_bin), "--filter", NO_MATCH], args.repeat)

    lines = [
        "CPU-time benchmark (user+sys, best of %d, pinned CPU %d)" % (args.repeat, args.cpu),
        "ratio = port_work / taffy_work; < 1.0 means the port is faster",
        "process baseline subtracted: taffy %.1f ms, port %.1f ms" % (taffy_baseline * 1e3, port_baseline * 1e3),
        "",
        f"{'scenario':26s} {'taffy_ms':>10s} {'port_ms':>10s} {'ratio':>8s}",
        "-" * 60,
    ]

    ratios: list[float] = []
    excluded: list[str] = []
    for name in scenarios:
        t_total = best(prefix + [str(RUST_BIN), "--filter", name], args.repeat)
        p_total = best(prefix + [str(args.zig_bin), "--filter", name], args.repeat)
        t = t_total - taffy_baseline
        p = p_total - port_baseline

        # If either side's signal is small next to its own baseline, the
        # subtraction has dominated and the ratio is noise.
        if t_total < taffy_baseline * MIN_SIGNAL or p_total < port_baseline * MIN_SIGNAL:
            lines.append(f"{name:26s} {t * 1e3:10.2f} {p * 1e3:10.2f} {'noise':>8s}  (startup-dominated)")
            excluded.append(name)
            continue
        if t <= 0 or p <= 0:
            lines.append(f"{name:26s} {t * 1e3:10.2f} {p * 1e3:10.2f} {'noise':>8s}  (non-positive after baseline)")
            excluded.append(name)
            continue

        ratio = p / t
        if not math.isfinite(ratio):
            excluded.append(name)
            continue
        ratios.append(ratio)
        if ratio > 1.05:
            marker = "  <-- slower"
        elif ratio < 0.95:
            marker = "  <-- faster"
        else:
            marker = "  (parity)"
        lines.append(f"{name:26s} {t * 1e3:10.2f} {p * 1e3:10.2f} {ratio:7.2f}x{marker}")

    if ratios:
        geometric = math.exp(sum(math.log(r) for r in ratios) / len(ratios))
        lines += ["", f"geometric mean ratio: {geometric:.3f}x ({len(ratios)} comparable scenarios)"]
    if excluded:
        lines += ["", "excluded (process startup dominates): " + ", ".join(excluded)]
        lines += ["use `zig build bench-compare -- --repeat N` for per-iteration wall-clock numbers"]

    table = "\n".join(lines)
    print(table)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(table + "\n")
        print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())