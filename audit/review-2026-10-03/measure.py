"""Run prebuilt corrected harnesses serially on CPU 2; preserve all samples."""
import json, statistics, subprocess, sys
from pathlib import Path

def read(binary):
    p = subprocess.run(["taskset", "-c", "2", binary], capture_output=True, text=True, check=True)
    rows = {}
    for line in (p.stdout + p.stderr).splitlines():
        cells = line.split("|")
        if len(cells) == 5 and cells[0] in ("bench", "lifecycle") and cells[2].isdigit():
            rows[cells[1]] = int(cells[3])
    if len(rows) not in (4, 6):
        raise RuntimeError(f"Expected 4 or 6 rows: {rows}")
    return rows

def main():
    rust, zig, out = sys.argv[1:]
    samples = {"rust": [], "zig": []}
    for i in range(9):
        for side in (["rust", "zig"] if i % 2 == 0 else ["zig", "rust"]):
            samples[side].append(read(rust if side == "rust" else zig))
    Path(out + ".json").write_text(json.dumps(samples, indent=2) + "\n")
    heading = "Persistent 1000-node flex; layout only" if len(samples["rust"][0]) == 4 else "Corrected fresh malloc build + layout + teardown"
    lines = [heading + "; CPU 2; median of 9", "scenario|rust_ns|zig_ns|ratio|rust_min|max|zig_min|max"]
    for name in samples["rust"][0]:
        r = [x[name] for x in samples["rust"]]; z = [x[name] for x in samples["zig"]]
        rm, zm = statistics.median(r), statistics.median(z)
        lines.append(f"{name}|{rm}|{zm}|{zm/rm:.3f}|{min(r)}|{max(r)}|{min(z)}|{max(z)}")
    Path(out + ".txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))

if __name__ == "__main__":
    main()
