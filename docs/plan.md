# zafi roadmap: beyond Taffy 0.14 parity

**Status:** proposed roadmap (2026-09-12), synthesized from five research tracks:
production-engine comparison, lightweight/embeddable-engine comparison, incremental
layout architecture, verification/product strategy, and a codebase audit.
Sections marked *target* are provisional engineering goals, not measured results;
only cited measurements are claims.

**Scope:** evolve zafi from a behavior-compatible Taffy 0.14 port into a
first-class standalone Zig layout engine: correctness under change and failure,
memory and speed, an incremental API surface, a stable C ABI, and a verification
program strong enough to gate releases.

The previous parity campaign (6,084/6,084 fixtures, differential oracle,
benchmark rounds) is complete; its history remains in `report.md`, `README.md`,
and `audit/`. This file replaces the parity plan with the post-parity roadmap.

---

## 0. Baseline

### 0.1 Verified state (2026-09-12)

| Area | State | Evidence |
|---|---|---|
| Behavioral parity | 6,084 / 6,084 XML fixtures; every group 100% (block, blockflex, blockgrid, contain, flex, float, grid, gridflex, leaf) | `plan.md` history, `report.md` §2 |
| Differential oracle | 36 / 36 nodes across 21 Rust-vs-Zig scenarios | `report.md` |
| Unit tests | 87/87 default; 97/97 with serde on a warm dependency cache | `plan.md` |
| Benchmarks | geomean **0.862× wall / 0.856× CPU** vs pinned Taffy (best-of-N, pinned CPU; second optimization pass); earlier baseline 0.915× | `audit/bench_compare.txt` |
| Toolchain floor | Zig `0.17.0-dev.2085+5e36170b5` | `build.zig.zon:10` |
| CI | none (no workflow files) | repository |
| Reproducibility | `zig build test -Dserde=true` aborts from a clean cache (defect 1 below) | reproduced 2026-09-12 |

Ratios are Zig/Taffy; below 1.0× means the port is faster. Host variance on this
machine is documented at up to 2×, so every number in this document that matters
is a ratio, never an absolute-time promise.

### 0.2 Architecture ground truth

- **Storage:** 64-node pages, dense monotonic `u32` ids, per-node `alive` flag.
  `clear()` resets `nodes.len`, so numeric ids are reused after clear.
  `src/tree/taffy_tree.zig:61-144`, `src/tree/taffy_tree.zig:230-235`
- **Node payload:** ~1.2 KB per `NodeData`: `Style` 512 B, `Cache` final entry +
  9-slot measure ring (~420–464 B), inline context/`has_context`, detailed grid
  info. `audit/research-performance.md` §1.1
- **Dirty model:** cache emptiness is the single source of truth; `mark_dirty`
  already early-stops on an already-empty cache. `src/tree/taffy_tree.zig:488-510`
- **Pass model:** one reusable scratch arena per tree with an `in_layout_pass`
  epoch guard; scratch allocations must not escape the pass.
  `src/tree/taffy_tree.zig:150-218`
- **Measure ABI:** compute-time callback
  `fn(context, LayoutInput, NodeId, *const Style) -> LayoutOutput`; default
  returns zero size. `src/tree/traits.zig`
- **Style:** value type containing borrowed `[]const` slices for grid templates
  and line names. `src/style/mod.zig:442-449`
- **Containment:** `Contain` has only `layout` and `paint` bits plus reserved
  bits; there is no `size` bit. `src/style/mod.zig:113-183`
- **serde:** optional Taffy-compatible JSON behind a lazy dependency.
  `build.zig`, `build.zig.zon:16-22`

### 0.3 Corrections to older audit documents

These corrections matter because `audit/research-*.md` are used as planning inputs:

1. `audit/research-algorithms.md` §0/§1.1 and `audit/research-performance.md`
   §1.4 claim `Cache.clear()` returns `void` and `mark_dirty` re-clears the whole
   ancestor chain. Both are already fixed: `src/tree/cache.zig` has the `empty`
   flag / `ClearState`, and `mark_dirty` early-stops. The cache *representation*
   work (bitmask, sparse measure store) is still pending.
2. The claim that block layout allocates only from the tree allocator is
   partially stale: block item lists use a `BufferFirstAllocator` fallback.
   Some tree-allocator allocations remain elsewhere (see M1/M2).
3. The research documents predate benchmark round 2 in places; prefer
   `audit/bench_compare.txt` for current ratios.
4. Upstream Taffy `main` is **ahead** of zafi's pin (`1b918ba`, v0.14.0-7).
   Upstream is a source of ideas, never an oracle; the pinned revision is the
   compatibility contract.

### 0.4 Confirmed defect backlog (inputs to M1)

Verified locally; every item needs a regression test before its fix lands.

| # | Defect | Evidence | Severity |
|---|---|---|---|
| 1 | `zig build test -Dserde=true` panics from a clean cache: `lazyDependency(...) orelse @panic` defeats Zig's lazy-fetch retry contract | `build.zig:25`; reproduced | High (gate) |
| 2 | `with_capacity` panics on allocation failure instead of returning an error | `src/tree/taffy_tree.zig:184-188` | High |
| 3 | `ensurePages` can leak a page if the page-list append fails (alloc then append, no `errdefer`) | `src/tree/taffy_tree.zig:89-97` | High (OOM) |
| 4 | `clear()` reuses ids; stale numeric ids silently alias new nodes (the `alive` check cannot detect it) | `src/tree/taffy_tree.zig:230-235`; `report.md` §6.3 | High |
| 5 | No recursion/depth budget; deep trees recurse through `compute_child_layout` until the native stack overflows | `src/tree/taffy_tree.zig:477-486`; no depth symbol in `src/` | High |
| 6 | `std.heap.page_allocator` bypasses the caller allocator and leak tracking in several paths; at least one returns a heap slice with no free API | `src/compute/float.zig:168`; `src/compute/grid/mod.zig:171-175`; `src/compute/grid/types/cell_occupancy.zig:142`; `src/style_helpers.zig:83-85` | High |
| 7 | `catch @panic` on allocation failure in algorithm paths (float, grid, occupancy, traits) | 20+ matches under `src/compute/` | Medium–High |
| 8 | `Style` ownership of borrowed grid slices is undocumented; structural equality must not use raw byte compare | `src/style/mod.zig:442-449` | Medium |
| 9 | Documentation drift: advertised serde gate not reproducible; stale audit claims (see §0.3) | this document | Medium |

A deeper audit pass (ownership diagrams, cycle/reparenting invariants, callback
fallibility, detailed-info lifecycle) is running; its file-level work packages
fold into M1 without changing the milestone order.

---

## 1. Product definition

### 1.1 Measurable contract

| Dimension | Definition |
|---|---|
| **Conformance** | 100% of the pinned Taffy XML corpus, zero skips, executed == manifest, no crashes |
| **Differential** | Oracle compares full layout structs (rect, content size, baselines, scroll overflow, resolved grid tracks) at exact equality for same-arch unrounded output |
| **Determinism** | Same tree + target + optimize mode ⇒ bit-identical unrounded layouts across runs; cross-target differences limited to a documented ULP budget |
| **Robustness** | No panic on well-formed input; allocation failure returns an error from every public entry point; no leaks under the testing allocator; recursion depth bounded by an explicit error |
| **API stability** | Zig module follows SemVer; C ABI has a version handshake and `struct_size` negotiation |
| **Performance** | Relative ratios with a defined statistical decision rule; no absolute-time promises on shared runners |
| **Packaging** | Builds on pinned/current Zig; static + shared libraries; `wasm32-*`; freestanding smoke target |

### 1.2 Anti-goals

1. **Not a browser engine.** No DOM, cascade, selectors, paint, compositing, or
   text shaping in-tree.
2. **Not future-Taffy chasing.** Rebasing past the pin is a deliberate,
   separately-versioned event; new upstream behavior is not silently absorbed.
3. **No immediate-mode rewrite.** Keep the retained constraint-keyed core; offer
   an optional declarative/frame facade (M7).
4. **No speculative parallelism in the core.** Serial stays the default;
   concurrency ships only with evidence, an injected pool, and bit-equality
   tests.
5. **No new layout language without an oracle.** Subgrid, sticky, vertical
   writing, content-visibility, etc. need browser/WPT-derived fixtures and go in
   separate opt-in groups — they never borrow the Taffy parity claim.
6. **No vanity metrics.** Test/fixture counts are not gates; behavior diversity
   and oracle equality are.
7. **No internal types across the C ABI.** Opaque handles and versioned POD
   structs only.
8. **No `no_std`/freestanding guarantee until the matrix is proven** (M6).

---

## 2. Principles

- **P1 — Parity is a hard gate.** Every change keeps fixtures, oracle, and
  probes green. Features without a Taffy oracle are opt-in and separately
  counted.
- **P2 — Conservative invalidation.** The default engine behavior never skips
  work unless the existing exact-key cache allows it. New invalidation paths
  are opt-in; uncertainty escalates to the full Taffy clear. Under-invalidation
  is the bug class to fear; over-invalidation is merely slower.
- **P3 — Additive state, never wire state.** Incremental metadata (dirty masks,
  generations, fingerprints, measure stores) is never serialized; the Taffy
  wire format and `Style` layout stay untouched.
- **P4 — Measure before optimizing.** Counters and statistical gates land before
  the optimization they justify; no gains are claimed without evidence.
- **P5 — Determinism is an API property.** Same-arch bit-exactness; index-ordered
  reductions; no fast-math/FMA in the layout core.
- **P6 — Errors over panics.** Public entry points return errors; only truly
  unrecoverable invariants may panic.
- **P7 — Stable surfaces.** Curate the Zig module; design the C ABI for
  compatibility from the start (opaque handles, POD, `struct_size`).

---

## 3. Milestones

Dependency order: **M0 → M1 → {M2, M3, M6}**; **M3 → M4**; **M1/M3 → M5**;
**M3 → M7**; **{M4, M5, M6, M7} → M8/M9**. Each milestone lands its own gates
and keeps the parity configuration green.

### M0 — Reproducible gates, CI bootstrap, instrumentation

**Goal:** make every advertised gate reproducible from a clean checkout and give
later work a measurement spine.

**Work**

1. Fix the lazy-serde build defect: replace the `orelse @panic` at
   `build.zig:25` with the lazy-fetch-compatible pattern (`b.dependency("serde", .{})`
   inside the `enable_serde` branch, or propagate `error.LazyDependencyNeeded`).
   Add a clean-cache `-Dserde=true` job so this cannot regress.
2. Pin toolchains in `tools/pin.env` (floor + tested revision); print exact
   versions in CI; pin the Taffy fixture revision.
3. CI bootstrap: Tier A per-PR (linux x86_64, Debug + ReleaseFast, serde
   on/off, unit tests, fast fixture subset, oracle subset, `zig fmt --check`,
   README/example compile) and Tier B nightly (cross-arch matrix, all fixtures,
   full oracle, fuzz smoke, benchmarks). Tier C at release.
4. Metrics module, compiled off by default: cache get/hit/miss, measure calls,
   nodes visited, mark-dirty depth, boundary skips, allocations per pass,
   scratch high-water. Counters are `threadlocal` from day one.
5. Bench taxonomy v1: keep the six cold scenarios and add warm relayout,
   mutation (`noop_set_style`, `touch_leaf`, `restyle_leaf`), callback-heavy,
   memory (counting allocator, `@sizeOf`), deep/wide.
6. Policy: PR gates use correctness + (optionally) instruction counts; wall
   ratios gate releases only, with median/MAD + bootstrap CIs, interleaved A/B,
   ≥30 samples, pinned CPU.

**Acceptance:** clean-cache `zig build test -Dserde=true` passes; CI green from
an empty cache on the floor; metrics off = no symbols/size; new bench scenarios
recorded in `audit/`.

**Touch:** `build.zig`, `build.zig.zon`, `tools/pin.env`, new CI configs,
`src/util/debug.zig`, new `src/metrics.zig`, `tools/bench/*`.

### M1 — Reliability, identity, lifecycle

**Goal:** eliminate the crash/leak/stale-handle classes and make all public
resource behavior explicit.

**Work**

1. **Allocator hygiene.** Every public API fallible; `with_capacity` returns an
   error; `ensurePages` uses `errdefer`/rollback; replace `page_allocator` with
   the tree allocator (or explicit tree ownership); remove `catch @panic` from
   algorithm paths; `checkAllAllocationFailures` sweep over constructors and
   mutation entry points; document which allocations outlive a call.
2. **Depth budget.** Configurable max depth with a documented error (e.g.
   `error.DepthLimitExceeded`); tests at 10k+ nesting.
3. **Identity.** Generational public handles: `NodeHandle{index, generation}`
   while `NodeId` stays a dense `u32` internally. Generation bumps on
   `remove()`/`clear()`; stale handles resolve to `error.InvalidInputNode`.
   `report.md` §6.3 is the tracking item.
4. **Transactional mutation.** Validate all inputs before mutating (the
   `set_children` pattern), pre-reserve capacity before detach/attach, and leave
   the tree unchanged on OOM.
5. **Lifecycle ownership.** Audit `context`, `detailed_layout_info`, and
   `detailed_info_deinit` for double-free/leak; make `clear()` reset all
   metadata; fix the `to_track_list_string` ownership (returned buffer has no
   free path today).
6. **Style ownership.** Document the borrowed-slice contract; add a deep-copy
   helper for embedders that cannot guarantee slice lifetime; add a structural
   equality helper (slice-content aware, never `@memcmp`) for M3.

**Acceptance:** OOM injection leaves no leak and no partially-mutated tree;
stale handle after `clear`/`remove` errors; deep tree returns the documented
error; fixtures/oracle/probes unchanged.

**Touch:** `src/tree/taffy_tree.zig`, `src/tree/node.zig`, `src/compute/**`,
`src/style_helpers.zig`, `src/style/grid.zig`, `src/root.zig`.

### M2 — Memory and parity-neutral performance

**Goal:** shrink per-node footprint and remove remaining per-pass allocation
overheads without touching layout semantics.

**Work**

1. **Cache representation.** Replace the 9-slot optional measure ring and
   optional final entry with a validity bitmask representation, keeping the
   exact-key semantics, the CLOCK/second-chance behavior, and the rule that
   margin-collapse metadata is never cached. Co-design with the M3 measure
   store: keep a small hot inline ring (L1) if it measurably wins.
2. **Sparse context store.** Move `context`/`has_context` out of every
   `NodeData` (Taffy uses a `SecondaryMap`); this is a parity-neutral memory
   win.
3. **Scratch coverage.** Route remaining block/grid/flex temporaries through
   `scratchAllocator()`; track allocations per pass in the bench gate; target
   single-digit allocations per layout for the mixed scenario after warmup.
4. **Node size report.** Publish `@sizeOf(NodeData)` / `@sizeOf(Cache)` before
   and after; target *≥20% reduction* in `NodeData`.
5. **Statistical bench gates.** Replace best-of-N minima with distributions and
   a documented decision rule (median ratio + non-overlapping bootstrap CIs;
   1.05 wall / 1.02 CPU thresholds; two-run hysteresis).

**Acceptance:** fixtures/oracle/probes green; `NodeData` size reduced per
target; no scenario regresses beyond the noise rule; allocations per pass
recorded and reduced.

**Touch:** `src/tree/cache.zig`, `src/tree/taffy_tree.zig`, `src/compute/**`,
`tools/bench/*`.

### M3 — Incremental foundation (safe, additive)

**Goal:** give consumers change signals and measurement correctness without
changing default engine behavior.

**Work**

1. **Style equality fast path.** If the incoming `Style` structurally equals the
   stored one (field-wise, slice-content aware), skip `mark_dirty` entirely.
   `set_style` otherwise stays conservative (full Taffy dirty).
2. **Measurement revisions.** `set_measure_fingerprint(id, u64)` plus a
   tree-level font/theme epoch; `MeasureKey = (node, content_fp, font_fp,
   packed-constraint-key)`; a bounded, versioned measure store with per-node and
   global caps and CLOCK/LRU eviction. Default fingerprint `0` preserves today's
   "context set ⇒ dirty" behavior exactly.
3. **Changed-node output.** `layout_generation` (tree + node), `has_new_layout`,
   `changed_nodes` (id-sorted, deterministic), and a dense `LayoutSnapshot`
   with `diff`. Purely additive; never serialized.
4. **Property/mutation harness.** Seeded mutation sequences asserting
   incremental == fresh-baseline node-by-node; `changed_nodes` == brute-force
   snapshot diff; idempotence (relayout with no mutation is bit-identical);
   null-op style set changes nothing.
5. **Snapshot/replay tooling.** Canonical JSON (sorted keys, one line, SHA-256)
   with replay/diff CLI; failing fixtures emit a snapshot and seed as CI
   artifacts.

**Acceptance:** measure-call counts drop on callback scenarios with identical
output; `changed_nodes` exact; property suite zero mismatches; default-path
fixtures unchanged.

**Touch:** `src/tree/taffy_tree.zig`, `src/tree/cache.zig`, `src/compute/mod.zig`,
new `src/snapshot.zig`, `tools/bench/*`, new CLI.

### M4 — Opt-in incremental v2 (proof-gated)

**Goal:** the high-upside, high-risk invalidation work, only behind explicit
contracts and verification.

**Work**

1. **Width-stable measurement contract.** Opt-in callback contract enabling
   Yoga/Flutter-style reuse rules (a max-content result valid when the requested
   width ≥ measured intrinsic width; stricter-width reuse). Default remains
   exact.
2. **Containment boundaries.** `contain: size` bit plus proven boundaries
   (absolute-with-definite-insets, explicit embedder markings), with verified
   backdating: recompute the boundary output and escalate to the full clear if
   any observable changed. Soundness requires overflow containment proof, not
   just size independence.
3. **Field-level dirty masks / Salsa-style revisions.** Only if (a) boundaries
   land, (b) the mutation property suite proves equality, and (c) measurements
   show benefit. Otherwise parked; do not enter the critical path.

**Acceptance:** property tests prove hinted == default node-by-node over seeded
mutations; the full Taffy corpus stays green with these features off; new
features have browser-derived fixtures in their own group.

**Touch:** `src/style/mod.zig`, `src/tree/taffy_tree.zig`, `src/tree/cache.zig`,
`src/compute/**`.

### M5 — API and C ABI

**Goal:** curate the Zig surface and ship a compatibility-designed C ABI.

**Work**

1. Define the stable Zig module: `TaffyTree`, `Style`, geometry, enums,
   `Layout`, `LayoutInput/Output`, `TaffyError`, measure callback. Mark
   everything else `experimental`. SemVer policy with `@compileError` guards for
   removals; compile README/example snippets as tests.
2. C ABI v0.1: opaque `zafi_tree`; `zafi_node{index, generation}` by value; POD
   `extern struct` wire types with `{struct_size, abi_version}` headers; single
   measure callback + `user_data`; `int32_t` error codes + last-error accessor;
   caller-supplied allocator ownership; `zafi_abi_version` +
   `zafi_abi_is_compatible`.
3. Hand-author `include/zafi.h`; diff against `-femit-h` output in CI; symbol
   version script (`zafi_*` global, `local: *`) + SONAME; `abidiff` at release.
4. Packaging: static + shared artifacts, `pkg-config`, install headers, add
   `include/` to the package manifest.

**Acceptance:** C and C++ consumers compile and run; `nm -D` shows only
`zafi_*`; `abidiff` clean across a simulated minor bump; version negotiation
rejects incompatible majors.

**Touch:** `src/root.zig`, new `src/capi/`, new `include/zafi.h`, `build.zig`,
`build.zig.zon`, CI.

### M6 — Platform reach: WASM/freestanding, feature gates, FP determinism

**Goal:** make portability claims provable instead of aspirational.

**Work**

1. Platform seam: injectable panic/log handlers; remove `std.debug` from
   library paths; document per-target support.
2. Feature gates: `-Dgrid`, `-Dfloat`, `-Dno_heap` (fixed-buffer allocator),
   `-Dvalidate`; the default configuration is the parity configuration; gates
   never alter it.
3. Fixed-capacity mode: `FixedBufferAllocator` over a caller block, growth
   returns `error.CapacityExceeded`; document what can never be allocation-free
   (dynamic growth, detailed grid info, serde, caller callbacks).
4. FP determinism: forbid `@setFloatMode(.optimized)`/`@mulAdd`/FMA contraction
   in the core; cross-target golden corpus; same-arch bit-exact, documented ULP
   budget elsewhere; disassembly check for packed reductions/FMA in
   deterministic builds.

**Acceptance:** `wasm32-freestanding` smoke lays out a tree with
`FixedBufferAllocator`; feature-off builds compile and test; determinism gate
passes.

**Touch:** new `src/util/sys.zig`, `src/util/debug.zig`, `build.zig`,
`src/root.zig`, `src/compute/**`.

### M7 — Ecosystem surface (demand-gated)

**Goal:** ergonomic entry points that reuse the core instead of forking it.

**Work**

1. **`zafi.frame` facade.** Declarative per-frame scene declaration over a
   retained `TaffyTree`: hashed-path stable ids (ImGui-style id stack),
   per-frame arena, explicit prune/hide policy. First-frame geometry is exact —
   no DVUI-style two-frame warm-up.
2. **Foreign-tree host seam.** A `TreeHost` vtable boundary for ECS/foreign
   storage, only when an embedder needs it; the concrete algorithms keep
   direct `*TaffyTree` calls in the hot path.
3. **Inspect tooling.** CLI for tree dumps, snapshot diff, and Chrome Trace
   Event JSON export (Perfetto-importable); snapshots deterministic, traces
   explicitly not.

**Acceptance:** facade layout equals direct-tree layout on the fixture corpus;
host seam parity on oracle scenarios; no trait-object dispatch added to the
engine hot path.

**Touch:** new `src/frame.zig`, new `src/tree/host.zig`, `tools/inspect/`,
`src/root.zig`.

### M8 — Features beyond Taffy (demand-gated, new oracles)

**Goal:** expand the layout language deliberately, never at the cost of the
parity contract.

Candidates (each requires its own oracle class — WPT reftests/browser dumps —
and an opt-in fixture group): vertical writing modes, `contain: size`, sticky
positioning, `content-visibility`-style skipping with remembered intrinsic size,
scrollable-overflow semantics, subgrid, and inline/text integration hooks.

Rules: prioritize by real embedder demand; no feature enters the default
configuration without an oracle; each ships with property tests and documented
divergence from browsers where relevant.

**Anti-goals:** block fragmentation/pagination, tables, in-tree text shaping.

### M9 — Release engineering

**Goal:** deterministic, compatible releases.

**Work:** SemVer/ABI audit, changelog, release checklist, docs publish
(`-femit-docs`), header-drift check, long fuzz run with corpus promotion,
checksummed artifacts, Tier C matrix on pinned runners.

**Acceptance:** a release candidate passes Tier C; the version bump is justified
by the API/ABI diff.

---

## 4. Architecture decisions

- **ADR-1 — Dense ids, generational handles at the boundary.** `NodeId = u32`
  stays in algorithms, `children`, and caches (a measured advantage); the public
  API gains `NodeHandle{index, generation}` with generation bumps on
  `remove`/`clear`.
- **ADR-2 — Retained core + optional facade.** Every fast immediate-mode engine
  still keeps ID-keyed retained state; converting the core would break
  first-frame CSS geometry. The facade (M7) provides ergonomics without touching
  invalidation.
- **ADR-3 — Conservative incremental model.** Tier A: exact cache key (always
  on, Taffy-proven). Tier B: proven containment boundaries (opt-in, M4). Tier C:
  verified backdating — recompute and compare bit-exactly before suppressing
  ancestor invalidation. Any uncertainty escalates to the full clear.
- **ADR-4 — Tiered measurement cache.** Inline hot ring (L1) + bounded versioned
  global store (L2) keyed by constraint + content/font fingerprint; per-node and
  global caps; margin-carrying results are never cached.
- **ADR-5 — Changed-node output is separate from invalidation.** Generation
  stamps and `changed_nodes` never influence correctness; they enable painting,
  snapshots, and tests.
- **ADR-6 — No core parallelism until evidence.** If ever needed, the pool is
  injected by the embedder, workers get separate scratch arenas, reductions are
  index-ordered, and bit-equality with serial is the gate. Measure callbacks are
  documented single-threaded until then.
- **ADR-7 — C ABI from day one of the public surface.** Opaque handles, POD
  structs with `struct_size`, error codes, caller allocator ownership, symbol
  versioning, ABI diffing.
- **ADR-8 — Gates preserve the parity configuration.** Feature flags default on
  for the parity build; oracle-less features live in separate groups.
- **ADR-9 — Test diversity over test count.** Every behavior class needs at
  least one oracle-independent check (property, metamorphic, OOM, or fuzz) so a
  systematic porting error cannot pass by agreeing with itself.

---

## 5. Verification program

### 5.1 Gates

| Gate | Command | When | Blocks |
|---|---|---|---|
| Unit + leaks | `zig build test` (Debug, ReleaseSafe) | PR | merge |
| serde build | `zig build test -Dserde=true` from empty cache | PR | merge |
| Fixtures (fast group) | `zig build fixtures-bin && python3 tools/fixtures/run_all.py --jobs N --group ...` | PR | merge |
| Fixtures (full 6,084) | full `run_all.py`, manifest asserted (executed == total, zero skips) | nightly/release | release |
| Differential oracle | `zig build parity` — full layout structs, exact same-arch | PR subset / nightly full | merge/release |
| Property + mutation | seeded generator: incremental == fresh baseline, `changed_nodes` == brute force, idempotence | PR (seeded subset) / nightly | merge |
| OOM sweep | `checkAllAllocationFailures` + `FailingAllocator` | PR | merge |
| Fuzz smoke | `zig build test --fuzz=...` tree IR + serde + XML parser | nightly/release | release |
| Determinism | same-arch bit-exact across runs/optimize modes; cross-target ULP budget | nightly | release |
| Bench | statistical gate (see §5.4) | nightly/release | release |
| ABI | `abidiff` + header drift | release | release |

### 5.2 CI tiers

- **Tier A (per-PR, ≤10 min):** linux x86_64, floor + tested Zig, Debug and
  ReleaseFast, serde off + one clean serde-on job, fast fixture group, oracle
  subset, property seeded subset, fmt/docs/example compile.
- **Tier B (nightly, ≤2 h):** cross-OS/arch (linux x86_64/aarch64, macOS
  aarch64, Windows x86_64, wasm32-wasi/freestanding), all optimize modes, full
  fixtures/oracle, fuzz, sanitizer runs, determinism, distributional benchmarks,
  aarch64 results recorded separately.
- **Tier C (release):** pinned runners, all of A+B, high-sample benchmarks,
  ABI dump/diff, header drift, long fuzz with corpus promotion, docs publish.

### 5.3 Test classes to add

Allocation-failure sweeps; debug invariants (cache emptiness after `mark_dirty`,
layout written after `perform_layout`, rounding idempotence, cache-key equality
on store/load); handle lifetime; depth bounds; float edge cases (`-0.0`, NaN,
subnormals, inf, huge values); full-struct differential; structure-aware tree IR
fuzzing; serde fuzzing; differential fuzzing; deep/wide/adversarial profiles
(100k children, 10k nested, pathological `minmax(auto, 1fr)`); concurrency at
the multi-tree level; C/C++ ABI smoke tests; compiled README examples.

### 5.4 Benchmark policy

- Report distributions, not points: median + MAD + bootstrap 95% CI over ≥30
  interleaved samples, CPU-pinned, warmup, same time window.
- Regression decision: median ratio > 1.05 wall or > 1.02 CPU **and**
  non-overlapping CIs; require two consecutive nightly occurrences before
  opening an issue; prefer instruction counts on CI.
- Record methodology (runner, CPU, load, sample count, commit) with every
  artifact; never publish an absolute-time SLA.
- Target classes: cold build+layout, warm relayout, mutation, memory,
  callback-heavy, huge/deep/adversarial, cross-language.

---

## 6. Risk register

| Risk | Impact | Mitigation | Trigger to reassess |
|---|---|---|---|
| Under-invalidation (stale layout) | Critical | Conservative default; boundaries only with proof + verified backdating; mutation property suite | Any property-test mismatch |
| `contain: size` insufficient (overflow escapes) | High | Require overflow-containment proof; escalate on any observable change | New boundary fixtures |
| Borrowed `Style` slices become dangling | High | Documented contract; deep-copy helper; structural equality (no `@memcmp`) | Embedder report |
| Fingerprint misuse / collisions | Medium | Default 0 = unversioned; 64-bit hash documented; fingerprint changes force remeasure | Property test hole |
| Cache eviction cliffs after store move | Medium | Budget from measured hit rate; inline L1; report evictions | Bench regression |
| Handle refactor churns hot paths | Medium | Handles at boundary only; `NodeId` stays `u32` internally | Bench regression |
| Depth budget breaks legitimate deep UI | Low | Configurable limit with clear error; document default | User report |
| Parallelism nondeterminism/races | Medium | Not in core until evidence; per-worker arenas; ordered reductions; bit-equality gate | Only if parallel work is approved |
| New features silently break parity | High | Separate fixture groups; opt-in flags; parity config unchanged | Any default-path fixture change |
| Benchmark noise causes churn | Medium | Distributional gates + hysteresis; instruction counts | Gate instability |
| OOM paths regress during refactors | High | Allocation-failure sweep in PR tier | Any sweep failure |

---

## 7. Source index

**Local evidence:** `report.md`; `audit/research-algorithms.md`;
`audit/research-performance.md`; `audit/bench_compare*.txt`; `README.md`;
`docs/port.md`.

**Upstream primary sources used by the research tracks:**

- Taffy — <https://github.com/DioxusLabs/taffy> (`src/tree/cache.rs`,
  `src/tree/taffy_tree.rs`, `src/tree/traits.rs`, `CHANGELOG.md`), PR #904
  (incremental/hasNewLayout draft), issues #917, #823, #1010, #1155.
- Yoga — <https://www.yogalayout.dev/docs/advanced/incremental-layout>,
  <https://www.yogalayout.dev/docs/advanced/external-layout-systems>,
  `yoga/algorithm/Cache.cpp`.
- Blink/LayoutNG —
  <https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/core/layout/layout_ng.md>,
  inline layout README, Chrome RenderingNG deep-dives.
- Flutter — `RenderObject.markNeedsLayout`, `PipelineOwner.flushLayout`,
  `TextPainter`, relayout-boundary internals.
- Servo — layout blog posts and PR numbers (parallel job sizing, fragment
  reuse).
- Salsa — red-green algorithm, revisions, backdating, LRU tuning.
- Bevy UI — `bevy_ui` layout system, change detection, issues #22909/#22914.
- Skia — `modules/skparagraph/src/ParagraphCache.cpp`.
- slotmap / generational-arena / zig-slotmap — generational handle designs.
- Clay, LVGL, Nuklear, Dear ImGui, DVUI, Morphorm, Stretch — lightweight engine
  comparison (see the lightweight-engine research for exact files/revisions).
- Zig language/build docs — lazy dependencies, testing allocator, integrated
  fuzzing, `extern struct`, `-femit-h`, `-femit-docs`, sanitizers, WASM targets.
- WPT, OSS-Fuzz/ClusterFuzz, libFuzzer structure-aware fuzzing, RFC 8785 JCS,
  Perfetto trace format, libabigail/`abidiff`, SemVer/Keep a Changelog.

---

## Appendix A — first two weeks

1. Land M0 defect fix #1 (lazy serde) with a clean-cache test.
2. Merge the metrics skeleton and record baseline counters for the six existing
   bench scenarios.
3. Add `noop_set_style`, `touch_leaf`, and a warm-relayout scenario to the bench
   harness.
4. Fix defects #2–#6 with regression tests (`with_capacity`, `ensurePages`
   rollback, `clear` aliasing via handles design RFC, depth budget stub, and an
   inventory of `page_allocator`/`@panic` paths).
5. Stand up the property harness with idempotence + null-op checks (the full
   incremental-equality check activates in M3).
6. Write the identity RFC (ADR-1) and the cache-representation RFC (M2) for
   review before code.
