# zafi — Taffy feature-parity report

**Status: behavioral parity achieved** against the tracked Taffy revision, on
its full generated fixture corpus.

| Gate | Result |
|---|---|
| Taffy generated XML fixtures, current pin | **6,192 / 6,192** |
| Including scroll extents and resolved grid track lists | yes |
| Taffy generated XML fixtures, older baseline pin | **6,076 / 6,084** — the 8 are fixtures whose expectations upstream deliberately changed (`align_baseline_child_margin_percent`, `rounding_fractial_input_6/7`); the port matches the *new* expectations |
| Zig package unit tests (`zig build test`) | **92 / 92** (103 / 103 with `-Dserde=true`) |
| Host-genericity differential test | a second independent `LayoutTree` implementor yields identical layouts |
| Differential oracle vs real Taffy (`zig build parity`) | **36 / 36 nodes** |
| Taffy `serde` wire format | validated against Rust-generated JSON |
| Matched benchmarks | geomean **1.01×** wall / **0.90×** CPU (±0.02 run to run) — see `tools/bench/README.md` |

Remaining differences are **API-shape and Rust-ecosystem features**, not layout
behavior: a pluggable `calc()` resolver (§6.2, the one real functional gap),
`print_tree` formatting, and Rust-only tooling. The custom-tree API is no longer
a gap — it is delivered and tested (§6.1).

- **Port:** `src/` — extracted byte-for-byte from ZUI's `zui/src/layout`
  at extraction time, then advanced to parity in place.
- **Reference:** Taffy `22f941e19e05d1b29621703b4f3a9d96d7839886`
  (upstream `main`, 2026-10-03), checked out in `.references/taffy`. The older
  `1b918ba` revision is retained as a baseline fixture corpus; `tools/pin.env`
  records both.
- **Toolchain:** Zig `0.17.0` floor; Rust `1.98.1` for the oracle.
- **Dates:** extraction/audit 2026-09-11; parity campaign 2026-09-12; genericization,
  host-genericity and benchmark-methodology work 2026-10-03.

> **Correction to the 2026-09-12 figures.** The benchmark numbers in earlier
> revisions of this report were measured with the layout library compiled at
> `Debug`, because the benchmark harness reused the package's default module
> instead of one built at the benchmark optimization level. They were not a
> like-for-like comparison against optimized Rust. The corrected figures are
> above and in `tools/bench/README.md`; the older ones are retained in §2.4 as
> history only.

## 1. How parity was reached

The original revision of this report (2026-09-11) found the port at
679/6,084 fixtures with 15/36 differential mismatches. The campaign:

1. **Fixture harness first** (`tools/fixtures/`): a minimal XML reader for
   Taffy's generated format, a recursive expectation comparator with Taffy's
   0.1px tolerance, scroll-size and resolved-track-list comparison, a
   `fixtures` build step, and an out-of-process driver
   (`run_all.py --jobs N`) that records port panics as failures instead of
   aborting the run.
2. **Core contracts restored** to Taffy's architecture:
   - compute-time measure callback
     `fn(context, LayoutInput, NodeId, *const Style) -> LayoutOutput`,
     installed by `compute_layout_with_measure`
     (`tree/interfaces.zig`, `tree/tree.zig`);
   - dispatcher exactly like `compute_child_layout`, with the
     pre-pass deleted (`compute/root.zig`);
   - cache contract: algorithm child requests route through
     `compute_cached_layout`, cache key normalization fixed
     (`tree/cache.zig`);
   - Taffy trait-extension helpers on the tree (`measure_child_size`,
     `measure_child_size_both`, `perform_child_layout`);
   - `compute/leaf.zig` rewritten from `compute/leaf.rs`; `util/math.zig`
     semantics corrected (min-over-max, one-sided clamps, `None` absorption);
   - Ahem test measurement rewritten to match `src/test.rs`.
3. **Faithful algorithm ports** (`general` agents working in parallel against
   the Rust source, gated by the fixture harness):
   - **flexbox**: `src/compute/flexbox.zig` (≈2.9k lines) from
     `compute/flexbox.rs` (3,615), including all phases, `flexbox_balance`
     DP line-breaking, baselines, content-size overflow, absolute children,
     RTL. `src/style/flex.zig` compound `flex-wrap` parsing.
   - **grid**: `src/compute/grid/**` (≈6.7k lines across the module) from the
     grid sources (≈7.9k), including the full §11.5 intrinsic pipeline,
     placement passes, named lines, RTL, absolute items, percentage reruns,
     `detailed_layout_info`, content sizes.
   - **block + float**: `src/compute/block.zig` (≈2k lines) and
     `float.zig` (≈760) from `block.rs` (1,888) and `float.rs` (797),
     including `BlockContext` inheritance, full margin collapsing,
     clear/float segmentation, absolute layout, replaced/table sizing,
     align-content/text-align, baselines.
4. **Core gap closures** by the orchestrator: style parsers
   (`Display`/`Position`/`BoxSizing`/`Overflow`/`Direction`), `Contain`
   validation, `flow-root` BFC handling, component grid templates with
   `repeat()`, `DetailedGridInfo` population + lifecycle (arena-owned,
   freed on recompute/remove/deinit), calc resolution matching `Tree`'s
   default (0), `taffyRound` (`floor(x + 0.5)`), available-space `Npx`
   parsing, fixture `writing-mode` mapping, dirty = `cache.is_empty()`, and
   root/prelude exports.

## 2. Verification evidence

### 2.1 Taffy XML fixtures

```
$ python3 tools/fixtures/run_all.py --jobs 12
fixtures: 6084 total, 6084 passed, 0 failed
  block          948/948   passed
  blockflex       44/44    passed
  blockgrid       56/56    passed
  contain         32/32    passed
  flex          2664/2664  passed
  float           92/92    passed
  grid          2164/2164  passed
  gridflex        28/28    passed
  leaf            56/56    passed
```

Each fixture runs in its own process, compares the unrounded or rounded
layout per `use-rounding`, asserts `scroll_width`/`scroll_height` when the
expectation provides them, asserts `resolved-rows`/`resolved-columns` track
lists when both sides provide them (2,152 fixtures carry them), and treats a
process crash as a failure.

### 2.2 Differential oracle

`tools/parity/` runs the same 21 scenarios against pinned Rust Taffy and the
Zig port and diffs unrounded layouts:

```
scenarios: 21, compared nodes: 36
matches: 36, mismatches: 0, missing: 0
```

This includes the 15 previously failing rows (align-items/self, stretch,
wrapped auto-height, RTL, flex-basis, fr+gap gutters, auto-fill minmax,
absolute inset sizing, min-over-max).

### 2.3 Tree/measure/cache probes

Raw outputs: `audit/tree_probes_rust.txt` (oracle) and
`audit/tree_probes_zig.txt` (port).

| Probe | Taffy | Port |
|---|---|---|
| measure calls, measured leaf (first/second compute) | 1 / 1 | 1 / 1 |
| measure calls, nested flex | 5 | 5 |
| child metadata (padding/border/margin) | resolved | resolved |
| root margin / scrollbar size | (5,6,7,8) / (15,15) | (5,6,7,8) / (15,15) |
| `LayoutInput.HIDDEN` on a visible node | zeroed hidden | zeroed hidden |
| cache lookup across definiteness change | miss | miss |
| `compute_layout` with no measure closure | (0,0) | (0,0) |
| dirty after compute | false | false |
| absolute `left+right`, 50% grandchild | 80 / 40 | 80 / 40 |

### 2.4 Performance (matched Taffy comparison, after optimization)

`zig build bench-compare -- --repeat 21 --cpu 2` alternates the pinned Taffy
(Rust release + LTO) and Zig harnesses and keeps the best of 21 per side;
`zig build bench-cpu -- --repeat 3 --cpu 2` additionally measures each child's
`user+sys` CPU time via `getrusage`, which is immune to descheduling on the
shared four-CPU host. Both methods agree closely (geometric mean 0.862× vs
0.856×), so the port is ~14% faster than Taffy overall on this scenario set.
Methodology and full tables: `tools/bench/README.md`; raw tables:
`audit/bench_compare.txt` (round 2) and `audit/bench_compare_round1.txt`.

| Scenario | Taffy | Port | Wall ratio | CPU ratio |
|---|---:|---:|---:|---:|
| tree_creation_10k | 11.53 ms | 7.19 ms | **0.62×** | **0.48×** |
| flex_row_1000 | 555 µs | 607 µs | 1.09× | 0.92× |
| flex_wrap_500 | 197 µs | 226 µs | 1.15× | 0.89× |
| grid_50x50 | 4.62 ms | 3.94 ms | **0.85×** | 1.19× |
| block_nested_50 | 7.7 µs | 4.4 µs | **0.57×** | **0.68×** |
| mixed_flex_grid_block | 929 µs | 1.00 ms | 1.08× | 1.21× |
| **geometric mean** | | | **0.862×** | **0.856×** |

Round-1 baseline for comparison (`audit/bench_compare_round1.txt`): block
1.96×, mixed 1.49×, tree 0.26×, flex_row 0.80×, flex_wrap 0.98×, grid 0.97×,
geomean 0.915×.

Round-2 changes (all gated by 6,084 fixtures, the differential oracle, 87
default tests / 97 serde tests, and the tree probes):

1. **Dirty-propagation early-out** — `Cache` carries Taffy's `is_empty` flag and
   `clear` returns `already_empty`, so `mark_dirty` stops at the first already
   dirty ancestor instead of re-clearing to the root. Taffy's own benchmark
   comment ("no need to visit ancestors") is the contract; the port now mirrors
   it exactly. This is the dominant block-chain win.
2. **In-place leaf construction** — `NodeStore.appendLeaf` initializes the node
   in its page slot; `new_leaf` no longer builds and copies a ~1.2 KB temporary.
3. **Borrowed styles** — `Tree.style_ptr` replaces per-child `Style` (512 B)
   copies in flex item generation, the hidden post-pass and grid in-flow
   collection.
4. **Hidden-child fast path** — flex records during item generation whether any
   child is `display: none` (including absolute children) and skips the hidden
   post-pass entirely when none is.
5. **Per-tree scratch arena** — `Tree.scratch_allocator()` serves pass-local
   temporaries (flex items/lines, grid placement/tracks/occupancy, balance
   buffers), reset with capacity retained at every top-level compute; an
   `in_layout_pass` epoch guard keeps re-entrant child computes from
   invalidating outer temporaries.
6. **Small-list stack buffer** — block item lists use
   `std.heap.BufferFirstAllocator` (8 inline items) and spill to the tree
   allocator only for large child lists; flex item lists reserve once.

### 2.5 Genericization round (2026-10-03)

The compute algorithms were made generic over `LayoutTree` (§6.1). Three
performance consequences, measured:

1. **Interface forwarders had to be marked `inline`.** The genericization put a
   call layer between every algorithm and the tree, and LLVM left the trivial
   forwarders out of line — `LayoutTree(Tree).get_style` was a real symbol in
   the ReleaseFast binary. Marking the 22 forwarders `inline` was worth
   10–25% on every scenario.
2. **Grid item sorts moved to a key array.** `GridItem` is 312 bytes; both
   `std.mem.sort` and `std.mem.sortUnstable` spend their time moving whole
   items, and pdqsort measured *worse* than WikiSort. Items are now reduced to
   an order-preserving `u64` key plus an index (the index is the tiebreak, so
   the order still matches upstream's stable `sort_by_key`), the 12-byte entries
   are sorted, and the items are permuted once. Worth 19% on
   `mixed_flex_grid_block`.
3. **The benchmark harness was measuring a Debug build.** `build.zig` created
   one `zafi` module at the global `-Doptimize` and reused it for the harness,
   so the library ran with safety checks and no optimization while Taffy ran
   optimized. Fixing this is what moved the geometric mean from a meaningless
   1.293× to a real ~1.01×.

The benchmark scripts were also made defensive: `compare.py` now rejects
non-finite timings, flags scenario-set drift between the two harnesses and
mismatched iteration counts, and has a dead zone around parity; `cpu_compare.py`
subtracts a measured process baseline, without which the fast scenarios reported
process-startup ratios rather than layout ratios (`block_nested_50` read 0.95×
there while wall clock measured 1.63×).

Profiling (temporary in-process phase counters and a temporarily instrumented
Taffy reference, both removed afterwards) established that on the mixed
scenario the port now does exactly Taffy's work volume — 2,319 child layout
calls, 800 block layouts, 4 grid layouts, 1 flex layout per iteration — and
*fewer* measure calls (1,709 vs 2,110). Remaining wall gaps in flex/grid/mixed
are distributed per-call overheads rather than extra work; the identified
structural follow-ups are listed in `audit/research-algorithms.md` and
`audit/research-performance.md` (measure fingerprinting/sparse measure store,
calc resolver, field-level dirty tracking, parallel subtrees, SIMD batches).

Memory proxies (Taffy peak live vs port arena capacity): tree creation
21.2 MB → 15.8 MB; flex row 1.60 MB → 2.04 MB; grid 6.73 MB → 8.81 MB.

**Re-verification (2026-09-22, different host).** All gates re-ran clean on a
12-core desktop: Taffy XML fixtures **6,084 / 6,084**, differential oracle
**36 / 36 nodes** (0 mismatches), `zig build test` **87 / 87** and
`-Dserde=true` **97 / 97** (after fixing the `lazyDependency` panic at
`build.zig:25` that made a clean-cache serde build abort), and
`zig build bench-cpu -- --repeat 21 --cpu 2` produced geomean **0.958×**
CPU-time (tree_creation 0.60× and block_nested 0.77× faster; flex_row 1.10×,
grid 1.12×, mixed 1.30× slower). The direction matches the round-2 tables —
port faster overall — but the margin is host-dependent (0.958× here vs
0.856× on the measured host above); the tables above remain the archived
reference for that host.

### 2.6 Size probes (after optimization)

`@sizeOf` / `size_of` measurements from the same toolchain:

| Item | Taffy | Port | Note |
|---|---:|---:|---|
| `Style` | 560 B | 512 B | port is smaller |
| `CompactLength`/`Dimension`/`LengthPercentage` | 8 B | 8 B | packed u64 |
| `Cache` | 384 B | ~420 B | compact measure entries |
| `NodeData` (comparable unit) | ~1.2 KB | ~1.2 KB | paged, cache inline |
| `GridItem` | — | 280 B | was 424 B |
| `Layout` | 92 B | 100 B | extra `content_size` field |
| `LayoutInput` / `LayoutOutput` | 56 / 60 B | 56 / 60 B | equal |

Correctness during optimization work is protected by the 6,084 fixtures, the
differential oracle and the tree probes above; every step kept all gates
green.

## 3. Architecture now vs Taffy

| Concern | Taffy | Port |
|---|---|---|
| Dispatch | `TaffyView::compute_child_layout` | `compute_child_layout` (same branches) |
| Measure | compute-time closure → `LayoutOutput` | function pointer + context → `LayoutOutput` |
| Child requests | cached `compute_cached_layout` | same |
| Leaf sizing | `compute/leaf.rs` | `compute/leaf.zig` (faithful) |
| Math | `MaybeMath`/`MaybeResolve` traits | free functions with identical semantics |
| Algorithms | generic over tree traits | generic over `LayoutTree(comptime Self)` (`tree/interfaces.zig`) |
| Cache | per-node 9-entry cache + final entry | same |
| Detailed info | `Box<DetailedGridInfo>` | arena-owned `DetailedGridInfo` freed on replace/remove/deinit |
| Rounding | `(v + 0.5).floor()` | `taffyRound` |
| Node IDs | slotmap generational keys | generational `u64` (24-bit index / 40-bit generation) in a paged `NodeStore` |
| Calc | `calc_resolver` closure threaded through `resolved_percentage_size` | `LayoutTree.calc` exists and returns `?f32`, but **nothing calls it yet**; `calc()` lengths resolve to 0 (see §6.2) |
| Serde | feature-gated derive + custom impls | `-Dserde=true` + pinned serde.zig hooks; same JSON wire format |

## 4. Source and test volume

| Metric | Taffy | Port |
|---|---:|---:|
| Source files | 51 | 51 |
| Source lines | 26,794 | 18,978 (71%) |
| In-file tests | 144 | 88 |
| XML fixture tests | 6,084 | 6,084 executed |
| HTML fixture definitions | 1,538 | consumed through generated XML |
| Hand-written Rust integration tests | 107 | not ported one-to-one |

The static name-based audit (`audit/api_audit.md`, regenerated after the
campaign) still reports 44 missing declarations, 26 missing type members and
123 missing function names. Nearly all are Rust trait impls
(`Default`/`FromStr`/`BitOr`/serde/fmt), generic type parameters, or
macro-generated helpers; the style-core audit verified earlier that the
behavioral surface is present. The remaining true omissions are §6.

## 5. Feature matrix

| Taffy feature | Port status |
|---|---|
| high-level tree | Present; paged generational node store |
| `flexbox` | Faithful; 2,696 fixtures green |
| `flexbox_balance` | Faithful (DP + tie-breaks; oracle test in-tree) |
| `grid` | Faithful; 2,184 fixtures green incl. track-list output |
| `block_layout` | Faithful; 1,000 block fixtures green |
| `float_layout` | Faithful; 92 float fixtures green |
| `content_size` | `scrollable_overflow_rect` asserted by fixtures |
| `detailed_layout_info` | Populated for grid and asserted via `resolved-*` |
| `calc` | **Gap.** Lengths carry the pointer and `LayoutTree.calc` is defined, but resolution still returns 0 |
| `parse` | Most `FromStr`; keyword parsers added; compound flex-wrap |
| `serde` | Implemented behind `-Dserde=true` via pinned serde.zig; Taffy wire format validated against Rust output |
| `debug`/`profile` | Stubs |
| `std`/`alloc`/`strict_provenance` | N/A (Zig std; explicit allocators) |
| Feature gating | `serde` is a build option (default off, like Taffy); algorithms always compiled |

## 6. Remaining gaps (non-behavioral, prioritized)

### 6.1 Custom-tree / low-level trait API — CLOSED

Every algorithm is now generic over `LayoutTree(comptime Self)`
(`tree/interfaces.zig`), a comptime contract rather than a vtable: a missing or
mistyped method is a compile error at the call site instead of a null callback
that panics mid-layout. It covers traversal, style access, `calc()`, cache
access, layout read/write, and the out-of-flow containing-block bookkeeping.

`src/tree/interfaces_test.zig` is what makes this claim checkable. It implements
the contract a second time from scratch — arena-allocated nodes, `u32` ids,
plain slices, nothing shared with `Tree` — and asserts that flex, grid, block
and out-of-flow layouts come out identical to `Tree`'s for the same input.

That test earned its keep immediately: it found eight places where the
algorithms reached past the interface into `Tree` internals (`in_layout_pass`,
`reset_scratch`, `raw_node`, direct `NodeData` field writes, direct
`measure_child_size*`, `set_detailed_grid_info`). All now route through the
contract. It also prompted two contract changes: `begin_layout_pass` /
`end_layout_pass` became **required** rather than defaulted, because a host that
omitted them would grow its scratch arena unboundedly with no symptom; and
`calc` returns `?f32` rather than an error tag, because a host-specific error
cannot travel through the algorithms' fixed `ComputeError`.

### 6.2 Calc resolvers — MODERATE (the one real functional gap)
A `calc()` length carries its handle (`CompactLength.calc(pointer)`, packed into
the 58-bit payload) and the contract point exists — `LayoutTree.calc` — but
**no algorithm calls it**, so such a length resolves to `0`.

Upstream solves this by threading a resolver into the resolution call itself:
`CompactLength::resolved_percentage_size(parent_size, calc_resolver)`
(`.references/taffy/src/style/compact_length.rs:497`). Closing the gap means
doing the equivalent here: giving `resolved_percentage_size` /
`resolve` / `resolve_to_option` a resolver parameter and sourcing it from the
tree at every resolution site. That is a wide change across every style
resolution helper, so it is deliberately left undone rather than half-done —
`calc` is declared to return `?f32` so that a host can already decline
explicitly rather than being handed a plausible-looking zero.

### 6.3 Node identity — MODERATE
`NodeId` is a dense `u32` index with an `alive` flag instead of slotmap
generational keys: stale IDs after `clear()` can alias new nodes, removed
nodes are not reclaimed, and `node()` pointers invalidate on append.
Behavioral layout is unaffected. Options: document the contract or adopt a
generational key table.

### 6.4 serde — implemented, with one documented divergence
Rust's `serde` feature is now matched behind the port's own `-Dserde=true`
build option using [serde.zig](https://github.com/OrlovEvgeny/serde.zig)
(pinned by commit in `build.zig.zon`; chosen after comparing `std.json`,
serde.zig and ziggy — see `README.md` § Serialization). The wire format was
captured from the pinned Rust crate into `audit/serde_format_rust.txt` and is
asserted by nine tests: field set/order of `Style` (including `"dummy":null`),
u64 `CompactLength` bits and tag validation, PascalCase enums, alignment
strings, `Contain` bits, external-tag grid placements and repetitions, and
direct deserialization of Rust-generated JSON.

Known divergence: Rust returns an error when serializing a `calc` value;
serde.zig's JSON serializer has a fixed `{OutOfMemory, WriteFailed}` error set
with no way to surface a custom error, so calc serializes as raw bits (`0`),
which deserialization then rejects as an invalid tag. All other wire shapes
match.

### 6.5 API polish — MINOR
- `print_tree` output/indentation differs from `util/print.rs`.
- `debug`/`profile` hooks are inert.
- `TreeConfig` is public (Rust `pub(crate)`); `remove_last_node` is Zig-only.
- Root/prelude exports cover the common surface; helper "trait marker"
  exports (`TaffyAuto`, `FromFr`, ...) are absent by design.
- `MaxTrackSizingFunction`/`MinTrackSizingFunction` predicates are localized
  helpers rather than trait impls.

### 6.6 Verification gaps — MINOR
- Taffy's 107 hand-written Rust integration tests are not ported one-to-one;
  their behaviors are covered by fixtures and the probes (caching, relayout,
  measure counts, rounding, scroll sizes, floats), but a few
  (`serde`, `detailed_grid_info` getters, `adversarial_styles`) have no
  direct Zig analogue.
- HTML fixtures run only through their generated XML form (Taffy's JS
  `gentest` tooling is not invoked).
- Benchmarks are Zig-only; there is no side-by-side Rust timing run. *(Fixed:
  `tools/bench` now contains a matched Rust mirror with LTO plus
  `bench-compare`/`bench-cpu` ratio runners; see §2.4.)*

## 7. Next steps

Performance work now has matched Rust baselines (`bench-compare` wall-clock and
`bench-cpu` CPU-time, §2.4) and a safety net (6,084 fixtures + differential
oracle + probes). Completed in the first optimization pass:

- [x] Paged node store (`NodeStore`, 64 nodes/page, no growth copies)
- [x] Compact measure-cache entries (`Size<f32>` only, matching Taffy)
- [x] Allocation-free grid occupancy interval paint
- [x] Grid placement without full-struct sorts (`source_order` + O(n) scan)
- [x] Style pointer passing in hot grid/block/flex paths
- [x] Packed in-memory `CompactLength` (8 B; serde wire unchanged)

Completed in the second optimization pass:

- [x] Cache `is_empty` flag + `mark_dirty` early-out (Taffy's
  `AlreadyEmpty` contract); closed the block-chain outlier
- [x] In-place `NodeStore.appendLeaf` (no ~1.2 KB temporary per leaf)
- [x] Per-tree scratch arena with an `in_layout_pass` epoch guard
- [x] Small-child `BufferFirstAllocator` for block item lists; flex list
  capacity reserved once
- [x] Hidden-child fast path in flex (no post-pass when nothing is hidden)
- [x] Borrowed `style_ptr` in flex item generation, hidden passes and grid
  in-flow collection
- [x] Contention-immune `bench-cpu` runner (`tools/bench/cpu_compare.py`)

Remaining performance targets, highest impact first (details and effort
estimates in `audit/research-algorithms.md` and
`audit/research-performance.md`):

1. **Measure-result fingerprinting + sparse measure store**: expose a
   consumer-supplied content/font fingerprint so stale measure entries
   self-invalidate, and move the 9-slot ring out of every `NodeData` into a
   per-tree side store (bigger working set of measurements for text leaves).
2. **Per-call overheads in the measure path** (flex/grid/mixed are within
   0.9–1.2× of Taffy; phase profiling shows work volume is identical, so the
   remaining cost is distributed small per-call fixed overhead — candidate:
   single-tag cache probing and trimming `LayoutInput` construction).
3. **Field-level dirty tracking / early-out propagation** for mutate-relayout
   loops (Taffy clears whole caches; finer invalidation is a capability win).
4. **SIMD batch helpers** for scrollable-overflow unions, track-sizing clamps
   and gap sums; measured end-to-end upside is 0–5%, so it follows 1–3.
5. **Parallel subtree layout** (shared-nothing windows/subtrees) as a
   capability differentiator; needs immutable caches during a pass.
6. **Re-benchmark on an idle machine** before publishing ratios; the shared
   host varies by up to 2× between runs (use `bench-cpu`, which is immune to
   descheduling).

Correctness/API follow-ups (unchanged):

6. **Feature expansion** (optional, behind build options so Taffy parity stays
   provable): vertical writing modes, sticky positioning, subgrid/masonry,
   pluggable calc resolvers, incremental layout APIs, tracing/snapshots,
   comptime-generic custom trees, no-panic error API. (The custom-tree half of
   this is done — see §6.1.)
7. ~~**Custom-tree API**~~ — **closed** (§6.1). An embedder can now supply its
   own node store against `LayoutTree`.
8. **Port a slice of hand-written tests** where they test behavior fixtures
   cannot express cleanly (cache eviction/churn, dirty propagation chains,
   `disable_rounding`, hidden-input contracts).
9. **Node-id contract**: either document the generational-index semantics in `NodeData`
   or adopt generational keys when stale-ID safety matters.
10. **ZUI integration**: the M3 adapter can now proceed — behavior matches
    Taffy, including RTL, baselines, absolute positioning and content sizes.

Every optimization step must keep `zig build test`, the full fixture suite and
`zig build parity` green, and should be recorded in `audit/bench_compare.txt`
with a before/after ratio.

## 8. Reproduce

```sh
cd zafi

zig build test --summary all               # 87/87
zig build test -Dserde=true --summary all  # 97/97 (Taffy wire-format serde)
zig build fixtures -- --group flex --filter align   # one-fixture diff
zig build fixtures-bin && python3 tools/fixtures/run_all.py --jobs 12
zig build parity -- --report               # 36/36
zig build audit                            # static surface diff
python3 tools/api_audit.py --write audit/api_audit.md
python3 tools/parity/run.py --rust-only > audit/parity_rust.txt
bash tools/fetch-reference.sh              # restore pinned Taffy
```

## 9. Evidence index

| Artifact | Contents |
|---|---|
| `audit/fixture_results_final.txt` | full-suite run (6,084/6,084) |
| `audit/tree_probes_rust.txt`, `audit/tree_probes_zig.txt` | measure/cache/metadata probes, Rust vs Zig |
| `audit/parity_results.txt` | differential harness output |
| `audit/serde_format_rust.txt` | Taffy's `serde` wire format captured from the Rust oracle |
| `audit/api_audit.md`, `audit/file_inventory.md` | regenerated static surface audit |
| `audit/flexbox.md`, `grid.md`, `block-float.md`, `style-core.md`, `tree-compute.md` | original gap audits (kept as the historical record) |
| `plan.md` | campaign plan and baseline |
| `docs/port.md` | porting ledger with its completion gates |
