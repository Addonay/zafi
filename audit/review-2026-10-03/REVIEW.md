# Zlay code review and Taffy comparison

Audit date: 2026-10-03. Zlay source revision: `cc03ca02079ea5c5651b48226f66c986377e0d1d`.

## 1. Assessment

**Zlay is one of the most comprehensive standalone CSS box layout engines written in Zig that I can identify. I would not claim that it is definitively the most versatile Zig layout engine.** Its combination of flexbox, grid, block layout, floats, intrinsic sizing, RTL, baselines, overflow, and absolute positioning is unusually broad. “Versatile” also includes custom tree integration, allocation policy, safe persistent use, and deployment support; those areas need work.

**It is close to the documented Taffy revision in tested layout behavior, but it is not on par with Taffy as a complete library, or with the newer Taffy checkout supplied for this review.** The distinction matters:

| Dimension | Assessment |
| --- | --- |
| Layout behavior against documented pin | All 6,084 generated fixtures pass; 36 differential nodes match. Strong evidence for the covered inputs. |
| Layout behavior against supplied newer checkout | 6,114/6,192 fixtures pass; 78 fail. Several newer fixes and positioning features are missing. |
| Tree safety and mutation correctness | Confirmed stale IDs, invalid graph acceptance, partial failed mutations, allocation leaks, and cache invalidation hazards. |
| Memory ownership | Confirmed use-after-free in persistent grid metadata. Several public helpers hide allocation or borrow caller storage. |
| Custom tree and style integration | Much less flexible than Taffy's working generic traits. Zlay's compute algorithms require its concrete tree. |
| Performance | Competitive in some cases; substantially workload- and allocator-dependent. The existing “faster overall” claim is too broad. |
| Smallness | Less source text; slightly smaller Style; larger Cache and Layout; fast executable larger in the measured harness. ReleaseSmall substantially reduces executable size. |
| Readiness | A substantial and useful port with strong fixture coverage, but persistent application use needs the safety fixes below. |

A defensible description today is: **“A broad Zig port of Taffy's CSS box layout algorithms, passing the pinned fixture suite, with remaining API, ownership, mutation, and upstream synchronization gaps.”**

### Comparison with other Zig options

I checked public primary sources for a limited ecosystem comparison. [TUI.zig's layout guide](https://muhammad-fiaz.github.io/tui.zig/guide/layout.html) describes a Flexbox-inspired terminal layout system. [Zigzag](https://github.com/meszmate/zigzag) is a terminal UI framework. [Clay](https://github.com/nicbarker/clay) offers a compact C layout library with a Flexbox-like model, rendering commands, and a fixed arena; [its Zig bindings](https://github.com/johan0A/clay-zig-bindings) expose that C implementation. These are different scopes and useful alternatives, but their documentation does not establish the same CSS algorithm coverage as Zlay. This was a sampled search, not a source audit of every Zig layout project. It cannot certify an ecosystem-wide superlative.

Neither Zlay nor the tested Taffy configuration is a complete browser layout engine. Font shaping and real text measurement come from the host. A table/replaced-item sizing flag is not a complete HTML table algorithm. Browser-level inline formatting, pagination, painting, and interaction should not be inferred from the broad box-layout feature list.

## 2. Scope, references, and reproducibility

Two different Taffy references were used:

- **Documented pin:** `1b918bafcab101dd234ebeb27da0443e24fd9de2`, recorded in committed `tools/pin.env` and README at the start of the review.
- **Supplied checkout:** `22f941e19e05d1b29621703b4f3a9d96d7839886`, the actual HEAD of `.references/taffy`. The reference is a symlink to the ZUI checkout and was clean when inspected.

The supplied checkout still calls itself version 0.14.0, so the crate version alone cannot identify the algorithm baseline. Its commits add positioning/hoisting behavior and fix rounding, percentage sizing, margins, root layout, and column intrinsic sizing.

I reconstructed the documented revision with `git archive` under `/tmp/zlay-audit-pin`; I did not move or modify the user's reference checkout. The working `build.zig.zon` already had user changes, including a newer serde pin and removal of `.lazy = true`. Findings about that working manifest are distinguished from committed source. During the review the working `tools/pin.env` was independently changed to `8391a3471d9ed37345a6da5681c7dee05e170ccd`; the supplied reference HEAD remained `22f941e`. Those edits were preserved. Production source was not changed. Benchmark-generated Cargo lockfile changes were restored to their original committed contents.

Environment: x86_64 Linux, AMD Ryzen 5 5625U, 12 logical CPUs; Zig **0.17.0**, Rust **1.98.1**. Timing runs were pinned to CPU 2. Frequency scaling and other machine activity were not controlled. Corrected comparisons ran each side serially, alternated order, and kept all nine samples, reporting medians and ranges. These are measurements on this machine, not universal speed guarantees.

The review covered the public style/tree surface, storage and mutation, cache and dispatch contracts, rounding, allocation/ownership boundaries, fixture and parity tooling, benchmark construction, algorithm structure, and changes between the two Taffy revisions. The deeper source inspection focused on lifecycle and grid metadata, plus relevant flex/block sizing and placement phases. It is not a mathematical proof of every algorithm branch, a fuzz campaign, or a full platform/runtime certification.

Evidence and reproductions are in [audit/review-2026-10-03](audit/review-2026-10-03). The standalone [probes.zig](audit/review-2026-10-03/probes.zig) deliberately exercises problematic APIs; it does not patch the library.

## 3. Current verification results

| Check | Result | Evidence |
| --- | --- | --- |
| Default Debug tests | 87/87 pass | [unit-tests.txt](audit/review-2026-10-03/unit-tests.txt) |
| Serde Debug tests | 97/97 pass | [serde-tests.txt](audit/review-2026-10-03/serde-tests.txt) |
| Documented-pin XML suite, ReleaseSafe runner | 6,084/6,084 pass | [fixtures-pinned.txt](audit/review-2026-10-03/fixtures-pinned.txt) |
| Supplied-checkout XML suite, Debug in process | 6,114/6,192 pass; 78 fail | [fixtures-current.txt](audit/review-2026-10-03/fixtures-current.txt) |
| Supplied-checkout XML suite, ReleaseSafe, process per fixture | Same 6,114 pass / 78 fail; no recorded crashes | [fixtures-current-safe.txt](audit/review-2026-10-03/fixtures-current-safe.txt) |
| Documented-pin differential suite | 21 scenarios, 36/36 nodes match | [parity-pinned.txt](audit/review-2026-10-03/parity-pinned.txt) |
| Supplied-checkout differential suite | Same 36/36 match | [parity-current.txt](audit/review-2026-10-03/parity-current.txt) |
| Mutation, ownership, rounding probes | Multiple confirmed defects | [probes.txt](audit/review-2026-10-03/probes.txt) |

The small differential suite passing against the newer reference while 78 XML fixtures fail demonstrates why “36/36” cannot establish comprehensive parity. Likewise, 6,084 static fixture successes do not establish safe dynamic tree mutation, style ownership, allocation failure recovery, or long-lived memory behavior.

The parity build still supplies the old `build_options` import name, whereas the package expects `zlay_options` in `src/serde_support.zig`. The checked-in harness currently passes because the relevant declarations are lazily analyzed; the archived-copy harness used the corrected name. Fix the import mapping before extending that harness to inspect serde configuration.

### Newer-reference failures

| Family | Passed / total | Failed |
| --- | ---: | ---: |
| block | 966 / 1,000 | 34 |
| blockflex | 44 / 48 | 4 |
| blockgrid | 56 / 56 | 0 |
| contain | 32 / 32 | 0 |
| flex | 2,668 / 2,696 | 28 |
| float | 92 / 92 | 0 |
| grid | 2,172 / 2,184 | 12 |
| gridflex | 28 / 28 | 0 |
| leaf | 56 / 56 | 0 |

The [complete failure log](audit/review-2026-10-03/fixture-current-failures.txt) contains 23 base test names with box-sizing/direction variants. Examples:

- Absolute block with only a right inset and auto margins: expected x=130, Zlay produces x=65.
- Root absolute insets: expected x=50, y=20, width=320, height=240; Zlay produces x=0, y=0, width=400, height=10.
- Percentage padding in stretched flex items: expected height=110, Zlay produces 95.
- Fractional nested rounding: children can differ by one pixel.
- Hoisted absolute descendants use the wrong containing block.

These reflect real semantic gaps, including behavior inherited from the old pin. They are not all Zig translation mistakes. Updating to the supplied source requires coordinated changes, particularly for out-of-flow hoisting; adding enum variants alone will not close that gap.

## 4. Confirmed code review findings

Severity reflects practical consequences. “High” means incorrect persistent state, memory safety, or invalid graphs; it does not claim a demonstrated security exploit.

### F1 — High: persistent grid names refer to freed memory

Sources: [named resolver initialization](/home/addo/dev/stupid/zlay/src/compute/grid/types/named.zig:57), [detailed_line_names](/home/addo/dev/stupid/zlay/src/compute/grid/types/named.zig:161), [resolver lifetime](/home/addo/dev/stupid/zlay/src/compute/grid/mod.zig:407), [persistent details construction](/home/addo/dev/stupid/zlay/src/compute/grid/mod.zig:799).

Grid area names generate strings such as `header-start` in the named resolver's arena. `detailed_line_names()` allocates the outer arrays in the persistent detail allocator but copies the string slices without copying their bytes. `defer name_resolver.deinit()` frees the originating arena before the caller reads `DetailedGridInfo`.

The reproduction uses an allocator which poisons freed memory while retaining its backing storage. After layout, the first byte of the persistent generated name is **0xdd**, instead of **0x68** (`h`). This demonstrates a library-created dangling string, independently of whether caller-owned style strings have valid lifetimes. An ordinary allocator can leave the bytes readable, which explains why fixture comparisons often conceal the problem.

**Fix:** deep-copy every escaping generated name into the detail arena, or adopt the newer Taffy policy excluding implicit area line names from detailed output. Audit all three levels of nested slices. Add a regression that reads details after the resolver is destroyed and after subsequent allocations/layouts.

### F2 — High: tree mutations accept duplicate edges and cycles

Sources: [set_children](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:258), [add_child](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:285), [insert_child_at_index](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:294), [remove_child](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:304), [recursive traversal](/home/addo/dev/stupid/zlay/src/compute/mod.zig:152).

`add_child(parent, parent)` succeeds. Attaching a parent below its child also succeeds. Adding the same child twice succeeds; removing it once leaves one edge in the parent while the child's `parent` becomes null. The probe records `remaining=1 child_parent=null`.

A cycle can cause recursive layout/rounding/printing to overflow the stack. Invalidation can also depend on impossible ancestry. Duplicate edges violate the single-parent structure and make later reparent/remove operations inconsistent.

**Fix:** enforce uniqueness and reject self/ancestor attachment before mutation. Decide explicitly whether attaching an existing child is an error or a move within the sibling list. Apply the policy across every mutation API. Taffy's high-level mutation methods also rely on valid-tree usage in places; Rust's memory guarantees should not be confused with automatic graph validation. Zlay should define and enforce its own contract.

### F3 — High: `clear()` aliases old IDs to new nodes

Sources: [clear](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:230), [dense node storage](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:65), [identity type](src/tree/node.zig).

The probe creates ID 0, clears the tree, creates another node, and gets ID 0 again. `style_ptr(old_id)` now succeeds for the new node. A widget retaining the old ID can silently edit/remove an unrelated node.

Taffy's high-level tree uses slotmap generations and a u64 ID. Zlay's u32 index plus `alive` rejects a removed node only while that slot remains dead; it does not provide generation safety across clear.

**Fix:** generational handles with a free list, including correct generation changes on clear/reuse. Do not reset the generation history on clear. Test stale IDs across all getters, mutations, remove, layout, and context operations. Stable addresses from paged storage are useful, but do not make stable identity automatic.

### F4 — High: rejected and failed mutations leave partial state

Sources: [new_with_children](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:252), [set_children](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:258), [add_child](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:285), [replace_child_at_index](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:331).

Confirmed examples:

- Replacing a valid child with ID 99999 returns `InvalidChildNode`, but the original child has already been removed. Parent child count becomes zero.
- `new_with_children(..., [invalid_id])` returns an error after allocating a live node. Live node count increases from 2 to 3 despite failure.
- When allocation fails in `add_child`, child count remains zero but `child.parent` already points to the new parent.

`set_children` validates IDs first, which is good, but it does not reserve destination capacity before clearing/detaching edges. Its allocation failure path can still partially alter the graph without reaching `mark_dirty`.

**Fix:** validate IDs/graph rules, snapshot aliased input, reserve all required storage, then commit mutation and invalidate affected ancestors. Roll back newly created nodes on failure. Allocation errors should leave the tree consistent, preferably unchanged. Cover failure points with a failing allocator.

### F5 — High: `set_children(parent, tree.children(parent))` corrupts its input

Sources: [borrowed children accessor](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:362), [set_children](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:258).

The input slice can point into the exact child array that `set_children` clears. Debug clearing poisons the array before the function reads it again. The probe returns `InvalidChildNode` and loses the original edge; other build modes need not fail in the same way.

The alias can be a subrange, not only the complete array. Public APIs returning borrowed slices make this a plausible caller pattern.

**Fix:** handle overlap using a temporary snapshot, or document and detect the unsupported alias. Snapshotting plus pre-reservation fits the transactional mutation fix.

### F6 — High: cache-clearing and dirty propagation expose a stale-layout sequence

Sources: [cache_clear](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:440), [mark_dirty](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:488), [set_style](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:382).

The early-out in `mark_dirty` assumes that an empty child cache implies that every ancestor was already invalidated. The public `cache_clear(child)` clears only that node and violates the assumption.

Reproduction: lay out a block parent with a 10px child; call `cache_clear(child)`; set the child's height to 30; recompute the parent. Both stored heights remain **10**. The setter reaches an already-empty child cache and stops before clearing the parent's cached layout.

**Fix:** distinguish internal cache eviction from public invalidation. Public clearing should invalidate ancestors, or become a private implementation seam with an explicit invariant. Preserve the early-out on paths which maintain that invariant. Also constrain mutable access to cache fields through `node()`.

### F7 — Medium: removed nodes accumulate storage forever

Sources: [appendLeaf](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:100), [remove](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:615), [total_node_count](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:220).

Removing a node leaves its slot and child-list capacity allocated. New nodes always append. After creating/removing 1,000 nodes one at a time, the probe has zero live nodes but **1,000 slots and 16 pages**. The page payload alone is approximately **1.29 MB**. Longer-running UI churn keeps growing storage until clear/deinit and eventually reaches u32 capacity boundaries. Live counting and deinit scan all historical slots.

This is predictable retention, not an unreachable allocation leak, but it is a poor fit for dynamic applications and can be mistaken for one by consumers.

**Fix:** recycle dead slots using generations; release dead child arrays according to a documented retention policy; maintain an O(1) live count. Consider a `trim` operation for large retained scratch capacity. Keep paged storage's address stability where it is useful.

### F8 — High on failure paths: allocated page leaks when page-list growth fails

Source: [NodeStore.ensurePages](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:89).

A page is allocated, then appended to the pages list with `try`. If the list allocation fails, no cleanup frees the page. The failing-allocator reproduction allocates **80,384 bytes**, frees **0**, and exits the attempted insertion with no stored page to clean up.

Other failure cleanup deserves the same treatment: `NamedLineResolver.init` lacks an arena cleanup on early error; detailed-grid construction destroys the outer record on error but does not deinitialize its partially populated arena.

**Fix:** add scoped `errdefer` cleanup immediately after acquiring owned allocations. Audit constructors and multi-stage allocation functions under failure injection. Some grid/float allocation paths still panic while others return `OutOfMemory`; a coherent error policy is needed.

### F9 — Medium: `flow_root` is implemented inconsistently

Sources: [Style.is_block](/home/addo/dev/stupid/zlay/src/style/mod.zig:459), [module is_block](/home/addo/dev/stupid/zlay/src/style/mod.zig:612), [root sizing](/home/addo/dev/stupid/zlay/src/compute/mod.zig:84), [block dispatch](/home/addo/dev/stupid/zlay/src/compute/mod.zig:54).

The module helper treats `flow_root` as block; the method treats only `.block` as block. Root layout calls the method. A flow-root containing a 10px child under a definite 100px viewport produces width **10**; changing only display to block produces **100**. Establishing an independent formatting context should not by itself turn a normal block root into shrink-to-content sizing.

**Fix:** consolidate the block classification and explicitly define flow-root's formatting-context semantics. Test root width, nested floats, margin collapse, hidden children, and serialization. This is a Zlay-added enum boundary, so pinned Taffy fixtures cannot by themselves validate it.

### F10 — Medium: grid metadata survives a change to a non-grid display

Sources: [set_style](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:382), [details getter](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:397), [hidden compute](/home/addo/dev/stupid/zlay/src/compute/mod.zig:147), [details cleanup](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:51).

After computing a grid, changing display to flex, and recomputing, `detailed_layout_info` still returns `.grid`. The old allocations remain until replacement/removal/deinit. Consumers can display obsolete track data or treat it as current geometry.

**Fix:** define freshness and ownership of detail results; clear obsolete detail data when the completed layout is no longer a grid, including hidden/leaf transitions. Merely retaining the last grid result needs an explicit separate API.

### F11 — Medium: public helpers hide allocations and borrowing

Sources: [grid parsing](/home/addo/dev/stupid/zlay/src/style/grid.zig:956), [GridTemplateTracks.from_str](/home/addo/dev/stupid/zlay/src/style/grid.zig:992), [GridTemplateComponents.from_str](/home/addo/dev/stupid/zlay/src/style/grid.zig:1033), [evenly_sized_tracks](/home/addo/dev/stupid/zlay/src/style_helpers.zig:82), [track-list formatting](/home/addo/dev/stupid/zlay/src/compute/grid/mod.zig:171).

Grid parsers allocate result arrays through `page_allocator`; parsed identifiers borrow bytes from the input string. The result types have no unified deinit/ownership interface. Partial parse failures can strand nested allocations. `grid_auto_tracks_from_str` returns only tracks while discarding the separately allocated line-name result. `evenly_sized_tracks` allocates nested arrays. `to_track_list_string` allocates a returned string through a hard-coded allocator while exposing it as `[]const u8`.

A caller can manually free some arrays with the right allocator and traversal, but those requirements are not apparent from the API and are not enforced by tree cleanup. For example, allocating/reparsing styles in a live editor does not gain cleanup from `TaffyTree.deinit()`.

**Fix:** allocator-taking parse/format functions returning owned result types with `deinit`, or caller-provided arenas with documented lifetime. Offer explicit borrowed builders for application-owned style storage. Prefer the existing writer-based formatting API for allocation-free output. Avoid replacing serde solely to solve these independent ownership issues.

### F12 — Medium: shallow styles can change without invalidating layout

Sources: [Style slices](/home/addo/dev/stupid/zlay/src/style/mod.zig:442), [new_leaf](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:239), [set_style](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:382), [node](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:665).

The tree copies the Style record, not its referenced arrays/strings. Mutating a caller-owned grid column array changes the effective style without notifying the tree. In the probe a track changes from 10 to 80: recompute still yields width **10** until `mark_dirty`, then yields **80**. Freeing those arrays too early creates dangling style data. `node()` also permits style/cache/graph changes which bypass the setters entirely.

This is partly a borrowed-API contract problem rather than a standalone algorithm defect. Taffy's owned style containers and Rust borrowing make accidental ownership misuse much harder.

**Fix:** explicitly choose owned versus borrowed style APIs, document lifetime and mutation requirements, and make normal application access immutable. A typed `edit_style`/context edit operation could guarantee invalidation. Keep low-level mutable access only as an explicitly advanced interface.

## 5. Additional source concerns and capability gaps

### Custom trees and calc resolution

Sources: [function-table traits](src/tree/traits.zig), [concrete compute signatures](/home/addo/dev/stupid/zlay/src/compute/mod.zig:27), [flex entry](/home/addo/dev/stupid/zlay/src/compute/flexbox.zig:227), [grid entry](src/compute/grid/mod.zig), [default calc resolver](/home/addo/dev/stupid/zlay/src/tree/taffy_tree.zig:473), [dimension resolution](/home/addo/dev/stupid/zlay/src/style/dimension.zig:63).

Taffy can run its low-level algorithms against host tree/style traits. Zlay exposes similarly named function-table structures, but the real algorithms accept `*TaffyTree`, not those interfaces. That means the exported surface does not deliver the same embedding capability. Hosts must maintain a second tree or adapt data into Zlay's storage.

Both default high-level trees resolve calc to zero. Taffy's low-level generic tree can supply the resolver; Zlay's concrete algorithms and direct dimension helpers prevent the equivalent end-to-end integration. Describing current calc values as generally resolved expressions is misleading.

**Add:** a working comptime tree interface, with typed cache/style/measurement/detail contracts, and a resolver actually used throughout sizing. Validate it with a second minimal custom tree, not only the built-in tree. Prefer compile-time completeness checking to exported callback tables containing null/panic defaults. The two placeholder container trait wrappers at the end of `tree/traits.zig` are not working algorithm adapters.

### Newer Taffy changes to port deliberately

The supplied history includes:

| Commit | Change | Relevance |
| --- | --- | --- |
| `887a847` | Round relative locations using cumulative coordinates | Confirmed one-pixel rounding errors; fix is localized. |
| `de9ef87` | Block child percentage padding/border use container width | Zlay still uses per-axis bases at `block.zig:746`. |
| `fc379ea` | Block content-size percentage basis | Confirmed block/flex fixture failures. |
| `c17b313` | Margin collapse-through uses used height | Confirmed max-height collapse fixture failures. |
| `46c4e9c`, `dc2fe8b` | Static/fixed/sticky positioning and absolute/fixed hoisting | Structural containing-block work; current default position also changes. |
| `3307c7e`, `b52be36` | Absolute auto margins and replaced-item stretch | Correctness at out-of-flow boundaries. |
| `8fab2bd`, `fb461a7` | Initial containing block and root insets | Confirmed root position/size differences. |
| `8391a34` | Flex percentage padding uses inline width | Zlay's flex basis uses main-axis size at `flexbox.zig:847`; stretch uses per-axis resolution at `:2048`. |
| `22f941e` | Clamp column intrinsic cross sizing | Confirmed column intrinsic fixture family failures. |
| `63b2737` | Exclude implicit area names from detailed output | Also useful for the escaping-name ownership problem. |

[Core diff](audit/review-2026-10-03/upstream-core-diff.txt) and [algorithm diff](audit/review-2026-10-03/upstream-algorithm-diff.txt) preserve local source evidence. Keep the old pin suite as a baseline, and add the newer regression families as explicit gates. Some previously expected values intentionally change when applying upstream fixes.

### Lower-priority risks to investigate

These are source concerns or contract limitations, not additional proven layout failures:

- Named-area fallback builds `name-start`/`name-end` in a fixed 512-byte buffer (`named.zig:211`). Long valid identifiers can take a different resolution path. Allocate by actual length or look up area boundaries directly.
- Public direct compute entry points can allocate scratch outside the managed root epoch; document which entry point owns/reset the scratch arena. Per-pass comments are not enough for callers using exposed lower-level algorithms.
- Measurement callbacks can recover a tree pointer through opaque context and mutate/re-enter the same tree. Zig does not enforce Rust's exclusive borrow. Define and guard forbidden reentrant mutation; do not interpret `in_layout_pass` as a general safety guarantee.
- `get_node_context_mut()` returns an opaque mutable pointer without automatically invalidating measurement caches. Context edits require explicit dirtying; a content revision or edit API would help. Taffy callers also need cache invalidation after content changes.
- Recursive traversal has no practical depth limit/error. Even a valid extremely deep tree can exhaust stack. Measure maximum useful depth and consider iterative rounding/printing before imposing arbitrary limits on normal layouts.
- Public integer counts/casts and packed-length tags assume bounded valid inputs. Add explicit input/count errors where a host can reasonably recover, and test large track/repetition counts and non-finite values. The 58-bit calc-pointer encoding deserves a documented target assumption; do not claim all pointer/address architectures from x86_64 execution.
- `util.sys.fract()` uses `value - floor(value)`; negative values differ from Rust's truncation-based fractional part. `util.sys.round()` uses `@round`, while actual layout uses Taffy's floor(x+0.5) rule. Consolidate or clearly separate public numeric semantics before users depend on them.
- CSS string parsing is a handcrafted seam, not the same tokenization machinery as Rust's cssparser. Fixture syntax is narrow. Comments, escapes, invalid nesting, identifiers, and non-finite numeric strings need differential parser coverage before claiming general parse parity.
- Serde tests pass, but calc serialization intentionally emits `0` rather than returning Taffy's serialization error (`serde_hooks.zig:103`). The result cannot round-trip. Document the exception prominently and consider an explicit preflight validation API returning a recoverable unsupported-value error.

## 6. Performance measurements and benchmark review

### Existing suite: reproducible numbers, limited interpretation

The checked-in suite measures building a fresh tree and layout together, with exceptions: tree creation performs no layout. Zig uses a retained outer arena and does not call tree deinit; Rust uses System allocation, drops trees, and has an atomic counting allocator in the timed path. They are distinct lifetime and allocation policies.

More seriously, `benchBlockNested`/`block_nested` builds a chain but attaches its **last leaf** beneath the measured root. The chain above that leaf is not traversed from that root. The historical “block chain” speedup therefore does not measure a 50-deep layout. Both runners contain the construction error.

Other tooling concerns:

- CPU-time comparison includes process startup/teardown and warmup. With only 30 extremely short block iterations, that overhead can dominate.
- `cpu_compare.py` rebuilds Rust only if its binary is absent. An existing stale binary can be compared with newly built Zig source.
- CPU time excludes descheduling but is not contention-immune: frequency, shared caches, memory bandwidth, and startup work still matter.
- `compare.py` keeps independently selected best samples; that is useful for lower-bound measurements but does not characterize typical latency or uncertainty.
- Strict comparison does not reject missing scenario rows, mismatched iteration counts, or an empty matched set. The parity parser likewise needs a nonempty expected scenario manifest and explicit finite-value checks; NaN differences should never pass by numerical comparison accident.
- Published ratios mix allocator choices, tree building, layout, and destruction. They do not directly quantify incremental layout speed.

Fresh runs of the **unmodified suite** (best of five, CPU 2) yielded:

| Scenario | Taffy documented pin | Zlay | Ratio Zlay/Taffy |
| --- | ---: | ---: | ---: |
| tree creation 10k | 3.081 ms | 1.654 ms | 0.54 |
| flex row 1000 | 561.7 µs | 740.5 µs | 1.32 |
| flex wrap 500 | 297.4 µs | 363.7 µs | 1.22 |
| grid 50×50 | 1.859 ms | 2.469 ms | 1.33 |
| mislabeled block chain | 10.48 µs | 5.03 µs | 0.48 |
| mixed | 929.2 µs | 1.383 ms | 1.49 |

The geometric mean is **0.967**, while four of six scenarios are slower. Against the supplied checkout the corresponding geometric mean was **0.906**, with grid **1.53×** and mixed **1.60×**. [Pinned results](audit/review-2026-10-03/bench-pinned.txt), [current results](audit/review-2026-10-03/bench-current.txt).

A geometric mean giving equal weight to six unrelated workloads is not a prediction for an application. Two construction/lifecycle wins can outweigh slower real layout cases in that statistic.

### Corrected cold lifecycle comparison

The audit-only corrected sources use **fresh libc/System allocation and tree teardown on both sides**, remove Rust's counting allocator from the timed path, attach the **top** of the block chain, and use matching iteration counts (100 per scenario, 1,000 for block). Median of nine alternating runs, CPU 2. These changes intentionally measure a different, better-defined workload from the retained-arena suite.

| Scenario | Pinned Taffy | Zlay ReleaseFast | Ratio to pin | Ratio to supplied Taffy |
| --- | ---: | ---: | ---: | ---: |
| tree creation 10k | 2.729 ms | 12.491 ms | 4.58 | 4.23 |
| flex row 1000 | 607.9 µs | 1.020 ms | 1.68 | 1.46 |
| flex wrap 500 | 312.7 µs | 258.1 µs | 0.83 | 0.71 |
| grid 50×50 | 1.938 ms | 4.510 ms | 2.33 | 2.84 |
| actual block chain | 36.0 µs | 28.3 µs | 0.78 | 0.73 |
| mixed | 991.2 µs | 1.118 ms | 1.13 | 1.32 |

Corrected six-case geometric means: **1.534×** the pin and **1.511×** the supplied checkout. These compare full cold lifecycles; they are not layout-only algorithm ratios. The samples have noticeable tails, preserved in [pinned raw samples](audit/review-2026-10-03/bench-corrected-pinned.json) and [current raw samples](audit/review-2026-10-03/bench-corrected-current.json). The Zlay columns in the two comparisons were sampled separately.

The tree-creation reversal is particularly important: the paged store and retained-arena setup can be fast, but that result does not carry over to fresh general-purpose allocations and complete destruction. Profile this workload before deciding whether allocation granularity, initialization, or deinit traversal should change. This audit did not attribute the entire gap to one hot function.

### ReleaseSafe cost on the corrected cold suite

A separate median-of-nine comparison using the same corrected Zig source in ReleaseSafe measured ratios to pinned Rust release of **5.22×** tree creation, **2.40×** flex row, **1.25×** flex wrap, **3.08×** grid, **1.16×** the real block chain, and **1.71×** mixed. [Results and ranges](audit/review-2026-10-03/bench-safe-pinned.txt). Rust was resampled for this comparison; these are not direct Safe/Fast ratios from one simultaneous run. The safety configuration therefore has a material cost on this host. The changed numbers are another reason to state optimization/safety mode in performance claims.

### Persistent tree: representative incremental usage

A separate matched harness builds a 1,000-leaf flex tree once, retains it, and times layout calls. Width is 100% of a definite viewport; leaves have fixed sizes and flex grow. Rounding is enabled on both sides. Each reported number is a median of nine runs against the documented pin.

| Operation | Taffy | Zlay ReleaseFast | Ratio |
| --- | ---: | ---: | ---: |
| unchanged cached layout | 67.1 µs | 17.7 µs | 0.26 |
| mark root dirty, recompute | 310.4 µs | 370.3 µs | 1.19 |
| change one child's width, recompute | 360.3 µs | 399.0 µs | 1.11 |
| alternate viewport width, recompute | 349.6 µs | 403.0 µs | 1.15 |

Evidence: [lifecycle.txt](audit/review-2026-10-03/lifecycle.txt), [raw samples](audit/review-2026-10-03/lifecycle.json), [Zig source](audit/review-2026-10-03/lifecycle.zig), [Rust source](audit/review-2026-10-03/lifecycle.rs).

This establishes a strong cached-layout result for this simple flex tree, and reasonably close changed-layout performance. It does not establish the same result for grid, text-heavy measured content, large scroll trees, or mutation churn. Cached calls still run rounding traversal, so even the “cached” operation is not a pure O(1) cache lookup.

**Performance priorities:** fix correctness and ownership first; repair the official benchmark; separate creation, initial layout, cached layout, single-node changes, resize, removal/churn, measurement callbacks, and teardown. Then profile allocation-heavy grid and fresh-tree construction. Retained scratch is worth preserving, with a documented memory policy. SIMD and parallel layout should follow profiles showing a real opportunity; they are not the first response to these numbers.

## 7. Safety, memory, and smallness

### Safety compared with Rust Taffy

Zlay offers useful checked error paths and caller allocator control, but ReleaseFast removes many runtime safety checks. Rust release retains its language ownership/borrowing guarantees. These are different guarantees even where benchmark compiler optimization levels look comparable.

The confirmed escaping metadata string is a memory safety defect. Invalid graphs, stale IDs, hidden borrow lifetimes, and failed mutation consistency are independent concerns. Zig's explicit allocator model can be excellent for bounded applications, but only when allocation/ownership contracts are consistently exposed.

A safer default recommendation for host applications is ReleaseSafe until the ownership/mutation issues are fixed and validated. It still cannot detect every stale slice or logical invalidation bug. No blanket mutex is needed for ordinary single-threaded tree use; document that callers must provide exclusive access and forbid callback mutation of the active tree.

### Measured type sizes

Native x86_64, documented-pin default features:

| Type | Taffy Rust | Zlay Zig |
| --- | ---: | ---: |
| Style | 560 B | 512 B |
| Cache | 384 B | 464 B |
| Layout | 92 B | 100 B |
| NodeId | 8 B | 4 B |
| Zlay NodeData | not publicly measured | 1,256 B |

Evidence: [Rust sizes](audit/review-2026-10-03/type-sizes-rust.txt), first line of [probes](audit/review-2026-10-03/probes.txt). Rust's NodeData is private; comparing only those two storage structs would still omit Rust's separate children/parent/context stores.

A Zlay 64-node page is **80,384 bytes**, including allocation of that full page for the first leaf. Small independent trees therefore have substantial minimum storage and slack. The old arena capacity versus Rust peak-live memory fields are useful only as rough proxies. For example, pinned suite flex wrap reports approximately 0.80 MB on Rust versus 2.30 MB retained arena capacity on Zig; those are not equivalent peak-memory metrics. They cannot support a precise “Zlay uses X% less memory” claim.

Useful improvements: generational reuse, smaller initial pages or configurable page policy, optional detailed grid output, better ownership cleanup, live-node counting, and a bounded/trimmed scratch policy. Measure peak requested live bytes, retained bytes after shrink, allocation count, and RSS separately with equivalent instrumentation outside timing runs.

### Source and executable footprint

| Source inventory | Files | Lines | Bytes |
| --- | ---: | ---: | ---: |
| Zlay `src/**/*.zig` | 54 | 20,204 | 946,716 |
| Taffy documented pin `src/**/*.rs` | 51 | 26,794 | 1,157,343 |
| Taffy supplied checkout | 52 | 27,730 | 1,199,666 |

These counts include comments and in-source tests. Zlay is about 25% smaller in lines than the pin, but language syntax, omitted generic machinery, and test coverage affect that number. It does not prove an implementation is more efficient or complete.

Stripped corrected benchmark executables on this host:

| Build | File size | ELF text | ELF BSS |
| --- | ---: | ---: | ---: |
| Taffy pinned Rust release + LTO | 733,456 B | 715,948 B | 1,418 B |
| Zlay ReleaseFast | 1,015,552 B | 986,597 B | 264,333 B |
| Zlay ReleaseSmall | 361,064 B | 333,347 B | 263,357 B |

Evidence: [binary-size.txt](audit/review-2026-10-03/binary-size.txt). These are whole harness executables, including different language runtimes, IO/formatting, and startup code. BSS is not per-node heap memory. The sizes support neither a universal “Zig is smaller” claim nor a claim that all that BSS belongs to the layout engine. ReleaseSmall is a meaningful size option; its performance was not benchmarked here.

Taffy has algorithm/output feature flags; Zlay's public build option currently gates serde only. Zig lazily analyzes unused declarations, but the concrete display dispatcher references all main algorithms. Explicit algorithm/output options would help users seeking a flex-only engine or avoiding persistent grid details. Add them with clear unsupported-display errors and configuration tests rather than silently changing layout semantics.

## 8. What to add, consolidate, or remove

### Add first

1. Generational IDs and free-slot reuse.
2. Transactional tree edits with cycle/duplicate/alias checking.
3. Owned parsed style results and explicit borrowed style contracts.
4. Complete cleanup on allocator failures and a consistent error policy.
5. A working custom-tree interface and end-to-end calc resolver.
6. Current Taffy rounding/sizing/positioning fixes, with an immutable verified reference gate.
7. Persistent-tree/churn/measurement benchmarks and dynamic differential scenarios.
8. Optional detailed layout output and algorithm feature flags if footprint requirements justify them.
9. API documentation showing deinit, context ownership, pointer validity, mutation invalidation, and exclusive tree access. The README usage example should include `defer tree.deinit()`.

### Consolidate or remove

- **Duplicate style accessor implementations.** Methods, module helpers, and wrapper structs repeat similar logic; the flow-root bug demonstrates semantic drift. Use one authoritative definition. Preserve convenience aliases where they serve consumers.
- **Unconnected trait scaffolding and empty marker types.** `TaffyZero`, `FromLength`, and similar empty structs mimic Rust trait names without providing the trait behavior. Implement a usable Zig interface or deprecate misleading exports. Their removal is an API change, not a guaranteed binary-size win.
- **Hidden page-allocator conveniences.** Replace them with explicit ownership interfaces rather than removing useful parsing/formatting functionality.
- **Multiple tree printers.** Tree methods and util helpers duplicate traversal and currently fail to grow the prefix correctly for hierarchy indentation. Consolidate around one writer-based traversal, with labels and cycle/depth handling.
- **Stale claims and comments.** `src/port.md` calls remaining generational/serde/trait issues “non-behavioral”; this audit disproves that grouping. The ledger's benchmark gate still describes a Zig-only comparison despite the later matched harness. README/report's unconditional parity and faster-overall headlines need qualification. Build/root comments describing extraction or an early literal pass should distinguish history from current contracts.
- **Brittle success criteria.** Remove success on empty/missing comparison data and “only rebuild if absent” benchmark behavior. Keep older raw evidence as history with dates and exact revisions.

I would retain the algorithm families, staged layout structure, cache separation, paged storage concept, caller allocator entry point, scratch reuse, fixture tooling, and serde compatibility work. There is no evidence here that block, float, grid, baselines, or intrinsic sizing are unnecessary for the stated goal of broad layout coverage. Large files can be split at phase boundaries for readability, but deleting phases to reduce line count would sacrifice semantics.

Do not add a renderer, fonts, event routing, constraints solver, or blanket parallelism just to make the engine look more comprehensive. Those are separate product choices. Better integration and reliable persistent operation offer more immediate value.

## 9. Suggested implementation order and acceptance gates

| Stage | Work | Acceptance evidence |
| --- | --- | --- |
| 1: correctness/ownership | F1–F6, F8; generation/free-list design; failure cleanup | Every probe becomes a targeted passing regression; errors leave consistent graphs; poison/failing allocators find no escaping/failure leaks. |
| 2: persistent lifecycle | F7, F9–F12; style/context/details contracts | Dynamic remove/reparent/clear/display-change sequences; borrowed and owned style examples; bounded live-tree churn memory. |
| 3: upstream sync | Rounding, percentage bases, margins/root fixes, then positioning/hoisting | New fixture families close deliberately; source pin verified before each run; changed expectations documented. |
| 4: integration/size | Working generic tree, calc, feature flags | Second custom tree runs flex/grid/block; real calc resolver affects layout; selected builds compile and reject unsupported display modes. |
| 5: performance | Repair/expand official benchmark, profile measured gaps | Matched lifetimes, correctness checks outside timed loops, distributions, stable build revisions, equivalent memory instrumentation. |

Existing unit and pinned fixture gates should remain, but must not be the sole release gates. Add dynamic differential sequences against Taffy and generated valid-tree/property scenarios, especially where fixtures currently have no lifecycle coverage.

## 10. Reproducing the audit experiments

The audit source files are checked in under `audit/review-2026-10-03`; compiled executables and archived references were kept in `/tmp`. Example probe compilation:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/zlay-review-cache zig build-exe -O Debug \
  --dep zlay -Mroot=audit/review-2026-10-03/probes.zig \
  --dep zlay_options -Mzlay=src/root.zig \
  -Mzlay_options=audit/review-2026-10-03/options.zig \
  -femit-bin=/tmp/zlay-review-probes
/tmp/zlay-review-probes
```

For corrected timing, substitute `bench-corrected.zig`, `-O ReleaseFast -lc`, and the desired output executable. The matching Rust [bench-corrected.rs](audit/review-2026-10-03/bench-corrected.rs) uses a temporary standalone Cargo package whose dependency path points to the selected Taffy reference and whose release profile is `opt-level=3`, `lto=true`, `codegen-units=1`. The lifecycle Rust source uses the same package/profile. Run prebuilt binaries serially:

```sh
python3 audit/review-2026-10-03/measure.py \
  /path/to/rust-benchmark /path/to/zig-benchmark /tmp/comparison
```

That runner accepts the six cold scenarios or four lifecycle scenarios, pins CPU 2, alternates execution order, and writes JSON samples and a median/range table. The cold corrected output's memory field is zero by design; memory instrumentation was removed from timing and it is not a measured memory result.

To recreate the documented reference without altering the supplied checkout:

```sh
mkdir -p /tmp/zlay-audit-pin/.references/taffy
git -C .references/taffy archive 1b918bafcab101dd234ebeb27da0443e24fd9de2 \
  | tar -x -C /tmp/zlay-audit-pin/.references/taffy
```

The fixture binary resolves its reference path relative to its working directory. Running the installed ReleaseSafe binary from the archived root selects the pinned XML suite. Running from this repository selects the supplied newer suite.

No cross-target runtime validation, sanitizer campaign, complete parser differential campaign, or exhaustive randomized layout comparison was performed. Those remain meaningful work before claiming comprehensive equivalence or production hardening.
