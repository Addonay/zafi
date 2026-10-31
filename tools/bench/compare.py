#!/usr/bin/env python3
"""Matched performance comparison: pinned Taffy (Rust) vs the Zig port.

Both harnesses run the same scenarios with the same iteration counts:

    Rust (tools/bench/rust, Cargo profile: opt-level 3 + LTO):
        bench|<scenario>|<iters>|<ns_per_iter>|<peak_live_bytes>
    Zig (tools/bench/main.zig, ReleaseFast, libc malloc):
        bench|<scenario>|<iters>|<ns_per_iter>|<peak_live_bytes>|<allocs_per_iter>

The memory field is the same metric on both sides: peak live bytes through a
counting allocator wrapping system malloc, with each tree built and torn down
inside the iteration. (Earlier Zig harnesses timed a reused arena and reported
its capacity, which flattered Zig's time and overstated its memory.)

## Why this script is defensive

The two harnesses are independent programs with independently maintained
scenario lists, and a silent drift between them produces a table that looks
authoritative while comparing different work. So:

  * a scenario present on only one side is reported as a MISMATCH and excluded
    from the mean, rather than being quietly dropped;
  * a scenario whose iteration counts differ between sides is reported, because
    the two numbers are then not per-comparable;
  * non-positive or non-finite timings are rejected instead of producing an
    infinite ratio that poisons the geometric mean;
  * the verdict band has a dead zone, so "faster" is not claimed for a 0.1%
    difference that is indistinguishable from noise.

Usage (through the build, recommended):
    zig build bench-compare -- --filter flex
    zig build bench-compare -- --repeat 5 --strict

Direct usage:
    python3 tools/bench/compare.py --zig-bin /path/to/bench [--filter flex]
    python3 tools/bench/compare.py --rust-only
"""

from __future__ import annotations

import argparse
import math
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent  # package root
RUST_MANIFEST = HERE / "rust" / "Cargo.toml"

Row = tuple[int, int, int]  # iters, ns_per_iter, bytes


class Invalid(Exception):
    """A harness produced a timing that cannot be compared."""


def parse(output: str, side: str) -> dict[str, Row]:
    rows: dict[str, Row] = {}
    for line in output.splitlines():
        parts = line.strip().split("|")
        if len(parts) not in (5, 6) or parts[0] != "bench":
            continue
        name = parts[1]
        try:
            iters, ns, bytes_ = int(parts[2]), int(parts[3]), int(parts[4])
        except ValueError:
            print(f"warning: {side} row {name!r} is not numeric, skipped", file=sys.stderr)
            continue
        rows[name] = (iters, ns, bytes_)
    return rows


def usable(name: str, row: Row, side: str) -> bool:
    """Reject timings that would silently distort the comparison."""
    _, ns, _ = row
    if ns <= 0:
        print(f"warning: {side}/{name} reported ns_per_iter={ns}, excluded", file=sys.stderr)
        return False
    if not math.isfinite(float(ns)):
        print(f"warning: {side}/{name} reported non-finite ns_per_iter, excluded", file=sys.stderr)
        return False
    return True


def run_zig(binary: Path, filter_text: str | None, prefix: list[str]) -> dict[str, Row]:
    command = prefix + [str(binary)]
    if filter_text:
        command += ["--filter", filter_text]
    proc = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        raise SystemExit(f"zig bench failed ({proc.returncode})")
    return parse(proc.stdout, "port")


def run_rust(filter_text: str | None, prefix: list[str]) -> dict[str, Row]:
    command = prefix + ["cargo", "run", "--release", "--quiet", "--manifest-path", str(RUST_MANIFEST)]
    if filter_text:
        command += ["--", "--filter", filter_text]
    proc = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout)
        raise SystemExit(f"rust bench failed ({proc.returncode})")
    return parse(proc.stdout, "taffy")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig-bin", type=Path, help="Zig bench executable (built by the build system)")
    parser.add_argument("--filter", help="scenario-name substring")
    parser.add_argument("--out", type=Path, help="write the table to this file")
    parser.add_argument("--zig-only", action="store_true")
    parser.add_argument("--rust-only", action="store_true")
    parser.add_argument("--strict", action="store_true", help="exit 1 if the port is slower on any scenario")
    parser.add_argument("--tolerance", type=float, default=0.05, help="noise band, fraction (default 0.05 = 5%%)")
    parser.add_argument("--repeat", type=int, default=3, help="run each harness N times and keep the best ns per scenario")
    parser.add_argument("--cpu", type=int, help="pin both harnesses to this CPU with taskset (reduces scheduler noise)")
    args = parser.parse_args()

    if not RUST_MANIFEST.exists():
        raise SystemExit(f"missing Rust bench manifest: {RUST_MANIFEST}")

    prefix: list[str] = []
    if args.cpu is not None:
        if shutil.which("taskset") is None:
            raise SystemExit("--cpu requires taskset on PATH")
        prefix = ["taskset", "-c", str(args.cpu)]

    def merge(best: dict[str, Row], run: dict[str, Row]) -> None:
        """Keep the fastest observed ns for each scenario."""
        for name, values in run.items():
            current = best.get(name)
            if current is None or values[1] < current[1]:
                best[name] = values

    taffy: dict[str, Row] = {}
    port: dict[str, Row] = {}
    for _ in range(max(1, args.repeat)):
        if not args.zig_only:
            merge(taffy, run_rust(args.filter, prefix))
        if not args.rust_only:
            if args.zig_bin is None:
                raise SystemExit("--zig-bin is required unless --rust-only is passed")
            merge(port, run_zig(args.zig_bin, args.filter, prefix))

    if args.rust_only:
        for name, (iters, ns, bytes_) in taffy.items():
            print(f"taffy|{name}|{iters}|{ns}|{bytes_}")
        return 0
    if args.zig_only:
        for name, (iters, ns, bytes_) in port.items():
            print(f"port|{name}|{iters}|{ns}|{bytes_}")
        return 0

    only_taffy = sorted(set(taffy) - set(port))
    only_port = sorted(set(port) - set(taffy))

    lines = [
        "Matched benchmark: pinned Taffy (Rust, LTO) vs Zig port (ReleaseFast)",
        "ratio = port_ns / taffy_ns; < 1.0 means the port is faster",
        f"best of {max(1, args.repeat)} run(s) per side; noise band +/-{args.tolerance * 100:.0f}%",
        "",
        f"{'scenario':26s} {'taffy_ns':>12s} {'port_ns':>12s} {'ratio':>8s} {'taffy_bytes':>12s} {'port_bytes':>12s}",
        "-" * 92,
    ]

    regressions: list[str] = []
    wins: list[str] = []
    ratios: list[float] = []
    excluded: list[str] = []

    for name in sorted(set(taffy) & set(port)):
        t, p = taffy[name], port[name]
        if t[0] != p[0]:
            excluded.append(f"{name} (iters {t[0]} vs {p[0]})")
            lines.append(f"{name:26s} {'ITERS DIFFER':>12s} {p[1]:12d}")
            continue
        if not usable(name, t, "taffy") or not usable(name, p, "port"):
            excluded.append(f"{name} (unusable timing)")
            lines.append(f"{name:26s} {'UNUSABLE':>12s}")
            continue
        ratio = p[1] / t[1]
        if not math.isfinite(ratio):
            excluded.append(f"{name} (non-finite ratio)")
            continue
        ratios.append(ratio)
        if ratio > 1.0 + args.tolerance:
            marker = "  <-- slower"
            regressions.append(f"{name} ({ratio:.2f}x)")
        elif ratio < 1.0 - args.tolerance:
            marker = "  <-- faster"
            wins.append(f"{name} ({ratio:.2f}x)")
        else:
            marker = "  (parity)"
        lines.append(f"{name:26s} {t[1]:12d} {p[1]:12d} {ratio:7.2f}x {t[2]:12d} {p[2]:12d}{marker}")

    # Scenario-set drift between two independently maintained harnesses.
    for name in only_taffy:
        lines.append(f"{name:26s} {'MISSING IN PORT':>12s}")
        excluded.append(f"{name} (taffy only)")
    for name in only_port:
        lines.append(f"{name:26s} {'MISSING IN TAFFY':>12s}")
        excluded.append(f"{name} (port only)")

    if ratios:
        geometric = math.exp(sum(math.log(r) for r in ratios) / len(ratios))
        lines += ["", f"geometric mean ratio: {geometric:.3f}x ({len(ratios)} comparable scenarios)"]

    if excluded:
        lines += ["", "EXCLUDED from the mean: " + ", ".join(excluded)]
    if wins:
        lines += ["", "faster than taffy: " + ", ".join(wins)]
    if regressions:
        lines += ["", f"slower than taffy (>{args.tolerance * 100:.0f}%): " + ", ".join(regressions)]

    if not ratios:
        lines += ["", "no comparable scenarios: the two harness scenario sets do not overlap"]

    table = "\n".join(lines)
    print(table)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(table + "\n")
        print(f"\nwrote {args.out}")

    # Scenario-set drift is a harness bug, not a performance regression, but it
    # invalidates the table either way, so it fails the strict gate too.
    if args.strict and (regressions or excluded):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())