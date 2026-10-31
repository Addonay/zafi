#!/usr/bin/env python3
"""Out-of-process fixture driver.

Runs the installed fixture runner one file at a time so that a panic in the
port is recorded as a failure instead of aborting the whole suite. Parallel
across `--jobs` processes.

Usage:
    zig build fixtures-bin
    python3 tools/fixtures/run_all.py                 # all groups
    python3 tools/fixtures/run_all.py --group flex
    python3 tools/fixtures/run_all.py --group grid --filter intrinsic
    python3 tools/fixtures/run_all.py --failures out.txt --jobs 8

Exit code is 0 when every fixture passes, 1 otherwise.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent  # package root
FIXTURE_ROOT = ROOT / ".references" / "taffy" / "tests" / "xml"
EXE = HERE.parent / "zig-out" / "bin" / "fixtures"


def collect(groups: list[str] | None, filter_text: str | None) -> list[tuple[str, str]]:
    files: list[tuple[str, str]] = []
    for group_dir in sorted(FIXTURE_ROOT.iterdir()):
        if not group_dir.is_dir():
            continue
        if groups and group_dir.name not in groups:
            continue
        for xml in sorted(group_dir.glob("*.xml")):
            if filter_text and filter_text not in xml.name:
                continue
            files.append((group_dir.name, xml.name))
    return files


def run_one(item: tuple[str, str]) -> tuple[str, str, int, str]:
    group, name = item
    proc = subprocess.run(
        [str(EXE), "--group", group, "--filter", name[: -len(".xml")], "--limit", "1", "--max-failures", "1"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    return group, name, proc.returncode, proc.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--group", action="append", dest="groups")
    parser.add_argument("--filter")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--failures", help="write failure details to this file")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    if not EXE.exists():
        print(f"error: {EXE} missing; run `zig build fixtures-bin` first", file=sys.stderr)
        return 2

    files = collect(args.groups, args.filter)
    if args.limit:
        files = files[: args.limit]
    if not files:
        print("no fixtures matched", file=sys.stderr)
        return 2

    passed = 0
    failed: list[tuple[str, str, str]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for group, name, code, output in pool.map(run_one, files):
            if code == 0:
                passed += 1
            else:
                kind = "crash" if code < 0 or code > 1 else "fail"
                failed.append((group, name, f"[{kind}] {output.strip()}"))
            if not args.quiet and (passed + len(failed)) % 100 == 0:
                print(f"  ... {passed + len(failed)}/{len(files)}", file=sys.stderr)

    print(f"fixtures: {len(files)} total, {passed} passed, {len(failed)} failed")
    per_group: dict[str, list[int]] = {}
    for group, _name, _msg in failed:
        per_group.setdefault(group, []).append(0)
    for group in sorted({g for g, _ in files}):
        failed_count = len(per_group.get(group, []))
        total = sum(1 for g, _ in files if g == group)
        print(f"  {group:12s} {total - failed_count:5d}/{total:<5d} passed")

    if failed and args.failures:
        with open(args.failures, "w") as handle:
            for group, name, message in failed:
                handle.write(f"{group}/{name}: {message}\n")
        print(f"failure details: {args.failures}")
    elif failed and not args.quiet:
        for group, name, message in failed[:20]:
            print(f"FAIL {group}/{name}: {message.splitlines()[0] if message else ''}")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
