# zafi benchmarks: matched Taffy (Rust) vs Zig port

Two harnesses run the same six scenarios with the same iteration counts, so
`compare.py` can print a direct ratio table:

| Scenario | What it stresses |
| --- | --- |
| `tree_creation_10k` | node insertion, storage growth, style init |
| `flex_row_1000` | single-line flex with grow/shrink and margins |
| `flex_wrap_500` | multi-line flex with gaps and align-content |
| `grid_50x50` | 2,500 items, fixed tracks, placement + occupancy |
| `block_nested_50` | 50-deep block chain with vertical margins |
| `mixed_flex_grid_block` | nested flex > grid > block tree |

Both measure **build + layout per iteration** with a fresh tree (Rust drops the
tree at the end of each call; Zig resets a layout arena), after a warm-up call.

## Running

```sh
zig build bench                              # Zig only (defaults to ReleaseFast)
zig build bench-rust                         # Rust mirror only (LTO build)
zig build bench-allocs                       # allocation census per layout pass
zig build bench-compare                      # ratio table, both harnesses
zig build bench-compare -- --filter grid     # one scenario
zig build bench-compare -- --repeat 5        # best-of-5 per side (default is 3)
zig build bench-compare -- --strict          # non-zero on any regression or exclusion
zig build bench-cpu                          # CPU-time mode (wall-clock immune)
zig build bench-cpu -- --repeat 5 --cpu 2    # best-of-5 CPU-time ratio table
```

The Zig binary is built by the build system and its path is passed to the
comparison script, so `bench-compare` never nests a `zig build` invocation.
`--bench-optimize=debug|safe|fast|small` overrides the default `fast` for the
Zig side; the Rust side always uses its `release` profile (`opt-level = 3`,
`lto = true`, `codegen-units = 1`) so Taffy is measured at its best.

> **The library module is built at `bench-optimize`, not at the global
> `-Doptimize`.** This is deliberate and load-bearing. `build.zig` creates a
> separate module for the benchmark harness because reusing the default one
> compiles the layout code at the global optimization level, which defaults to
> `Debug` — the port would then be timed with safety checks and no
> optimization while Taffy ran optimized. That mistake invalidated every
> comparison before it was found; the symptom was `zig build bench` reporting
> ~2.58 ms for `grid_50x50` where a direct `ReleaseFast` build of the same source
> reported ~1.95 ms.

## Output format

```
bench|<scenario>|<iters>|<ns_per_iter>|<bytes>
```

`bytes` is a memory proxy, not an identical metric:

- Rust: peak live bytes during the measured iterations, tracked by a counting
  `GlobalAlloc`.
- Zig: the layout arena's capacity (high-water, retained across iterations by
  `reset(.retain_capacity)`).

Use it for order-of-magnitude comparisons; the timing columns are the primary
signal.

## Why the scripts are defensive

Both harnesses are independent programs with independently maintained scenario
lists, so a silent drift between them yields a table that looks authoritative
while comparing different work.

- `compare.py` reports a scenario present on only one side as `MISSING` and
  excludes it from the mean, flags mismatched iteration counts, and rejects
  non-positive or non-finite timings instead of computing an infinite ratio that
  poisons the geometric mean. It has a dead zone around parity, so "faster" is
  not claimed for a difference inside the noise band (`--tolerance`, default 5%).
- `cpu_compare.py` subtracts a measured **process baseline** (a child run with a
  filter matching no scenario). Without this, a child's `user+sys` total is
  dominated by process startup for the fast scenarios: `block_nested_50` has
  ~0.7 ms of real layout work behind ~1.9 ms of process init, and previously
  reported 0.95× here while wall-clock measured the same scenario at 1.64×. A
  scenario whose signal is under `MIN_SIGNAL` times its own baseline is reported
  as `noise` and excluded rather than contributing a meaningless ratio.

## Current method (2026-10-31)

Both harnesses use glibc `malloc` and report peak live bytes; every tree is
built and torn down inside the iteration, plus two retained-tree scenarios
(`rebuild_flex_1000`, `relayout_grid_50x50`). The current results are in the
top-level README. The rounds below used a reused arena on the Zig side and are
kept as history only; they are not comparable.

## Round 3 (2026-10-03, Taffy pinned at `22f941e`)

Measured with `zig build bench-compare -- --repeat 5`. Ratios are
`port_ns / taffy_ns`; below 1.0 means the port is faster. Absolute nanoseconds
vary with host load, so treat the ratios as the result and the absolute columns
as context.

| Scenario | taffy ns | port ns | Wall ratio | Verdict |
|---|---:|---:|---:|---|
| `tree_creation_10k` | 3,217,844 | 1,856,458 | **0.58×** | faster |
| `flex_wrap_500` | 327,189 | 284,451 | **0.87×** | faster |
| `flex_row_1000` | 629,355 | 578,215 | **0.92×** | faster |
| `mixed_flex_grid_block` | 835,284 | 945,351 | 1.13× | slower |
| `grid_50x50` | 1,501,336 | 1,900,861 | 1.27× | slower |
| `block_nested_50` | 11,402 | 18,270 | 1.60× | slower |
| **geometric mean** | | | **1.009×** | |

Repeat runs land within about ±0.02 of these ratios; the ordering of the
scenarios is stable across runs, the third decimal place is not.

CPU-time mode over the five scenarios with signal above the process baseline
reports a geometric mean of **0.90×** — the port is ahead on CPU time
overall, and `grid_50x50` is at parity there (1.04×) while remaining 1.27× on
wall clock. That gap is the signature of a memory-bound path rather than extra
compute: `grid_50x50` is CPU-parity but loses wall-clock time, consistent with
moving 312-byte `GridItem` records around.

### What changed in round 3

1. **Interface forwarders marked `inline`.** The compute algorithms are generic
   over `LayoutTree`, and each call went through a non-inlined wrapper
   (`LayoutTree(Tree).get_style` was a real symbol in the ReleaseFast binary).
   Marking the 22 trivial forwarders `inline` was worth 10–25% across every
   scenario.
2. **Grid item sorts reduced to a key array.** `GridItem` is 312 bytes, so both
   `std.mem.sort` (WikiSort: a `[512]T` cache plus an 8-element sorting network)
   and `std.mem.sortUnstable` (pdqsort) spend their time moving whole items;
   pdqsort measured *worse*. Items are now reduced to one order-preserving
   `u64` key plus an index, the 12-byte entries are sorted with the original
   comparator order preserved via the index tiebreak (so the result is
   identical to a stable sort, matching upstream's `sort_by_key`), and the items
   are permuted once through a scratch buffer. Worth 19% on
   `mixed_flex_grid_block`. Permuting by cycling through the entries instead of
   using a buffer was tried and is markedly slower.
3. **Harness optimization level fixed** (see the note above).

Round 3 also **removed** an earlier claim: round 2 reported the port at
0.862× geometric mean. That number was measured with the library compiled at
`Debug`, so it was not a like-for-like comparison and should be disregarded.

### Known trade-off

The key-array sort allocates `n * sizeof(GridItem)` of scratch per
`track_sizing_algorithm` call, and the layout arena does not reclaim on free.
This raises `mixed_flex_grid_block`'s arena from 1.2 MB to 3.7 MB. Peak memory
across the suite is unchanged (`grid_50x50` at 11.1 MB dominates either way), and
the CPU-time/wall-clock disagreement above is unrelated to it.

## Earlier rounds

Rounds 1 and 2 (2026-09-12) are kept in `docs/report.md` §2.4 together with the
optimization list they produced. Their absolute numbers were taken on a
less-loaded host and their ratios were computed with the `Debug` library
described above, so they are recorded as history rather than as results.

## Remaining targets

From `audit/research-algorithms.md` and `audit/research-performance.md`:
measure-result fingerprinting plus a larger sparse measure store, a
consumer-supplied `calc()` resolver, field-level dirty tracking, parallel subtree
layout, and batch SIMD helpers.

The two measured gaps and where they point:

- `grid_50x50` is CPU-parity but 1.27× on wall clock. The next thing to try is
  shrinking what a sort or a list append moves, not removing work.
- `block_nested_50` allocates **zero** scratch bytes, so its 1.63× is pure
  compute in a 52-deep chain. It is also the smallest scenario (~18 µs), so it
  is the noisiest; treat it as a direction, not a precise figure.