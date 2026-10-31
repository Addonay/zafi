# Taffy source-port ledger

This ledger is the completion gate for the literal Zig pass. The authoritative
source is `.references/taffy/src`; every Rust source file has one destination
below. A source row is not complete merely because a file exists: every type,
function, method, default, comment, and algorithm phase must be represented.

During the first pass a missing callable is required to fail loudly with
`@panic("unimplemented Taffy port")` or an equivalent compile-time gate. That
prevents a quiet approximation from being mistaken for a port. Once its real
body is written, the failure gate is removed and its Taffy call sites are
covered by tests.

The literal pass keeps Rust naming and phase order where Zig allows it. Rust
traits, operator implementations, lifetimes, and feature gates are recorded
at their exact boundary and translated to explicit Zig interfaces only when
the language has no direct construct.

## Source inventory

| visited | Taffy source | Zig destination | port state |
|---|---|---|---|
| [x] | `lib.rs` | `root.zig` | module exports |
| [x] | `prelude.rs` | `prelude.zig` | module exports |
| [x] | `geometry.rs` | `geometry.zig` | generic values and helpers |
| [x] | `style/mod.rs` | `style/root.zig` | style fields and defaults |
| [x] | `style/alignment.rs` | `style/alignment.zig` | alignment values |
| [x] | `style/available_space.rs` | `style/available_space.zig` | constraint values |
| [x] | `style/block.rs` | `style/block.zig` | block values |
| [x] | `style/compact_length.rs` | `style/compact_length.zig` | semantic tags, predicates, and stable semantic serialization |
| [x] | `style/dimension.rs` | `style/dimension.zig` | dimension constructors and resolution |
| [x] | `style/flex.rs` | `style/flex.zig` | flex enums and predicates |
| [x] | `style/float.rs` | `style/float.zig` | float enums |
| [x] | `style/grid.rs` | `style/grid.zig` | grid placements, tracks, template areas, and line resolution |
| [x] | `style_helpers.rs` | `style_helpers.zig` | constructors |
| [x] | `tree/mod.rs` | `tree/root.zig` | tree exports |
| [x] | `tree/cache.rs` | `tree/cache.zig` | cache records and storage |
| [x] | `tree/layout.rs` | `tree/layout.zig` | hidden inputs, margin collapse, outputs, scroll extents, and layout |
| [x] | `tree/node.rs` | `tree/node.zig` | node identity |
| [x] | `tree/taffy_tree.rs` | `tree/tree.zig` | allocator-backed mutations, traversal, cache, layout, and style API |
| [x] | `tree/traits.rs` | `tree/interfaces.zig` | traversal/measure interface boundary, as the comptime `LayoutTree(comptime Self)` contract |
| [x] | `compute/mod.rs` | `compute/root.zig` | cache/dispatch/root contracts |
| [x] | `compute/leaf.rs` | `compute/leaf.zig` | leaf sizing sequence |
| [x] | `compute/flexbox.rs` | `compute/flexbox.zig` | flex records, sizing, line, and final-placement phases |
| [x] | `compute/block.rs` | `compute/block.zig` | block flow, absolute placement, and item generation |
| [x] | `compute/float.rs` | `compute/float.zig` | float state, clearance, slots, and intrinsic contribution |
| [x] | `compute/common/mod.rs` | `compute/common/root.zig` | helper exports |
| [x] | `compute/common/alignment.rs` | `compute/common/alignment.zig` | alignment calculations |
| [x] | `compute/common/scrollable_overflow.rs` | `compute/common/scrollable_overflow.zig` | overflow contribution |
| [x] | `compute/common/sizing_keyword.rs` | `compute/common/sizing_keyword.zig` | sizing keyword resolution |
| [x] | `compute/grid/mod.rs` | `compute/grid/root.zig` | grid entry point and staged dispatch |
| [x] | `compute/grid/alignment.rs` | `compute/grid/alignment.zig` | track and item alignment |
| [x] | `compute/grid/explicit_grid.rs` | `compute/grid/explicit_grid.zig` | explicit sizing and track initialization |
| [x] | `compute/grid/implicit_grid.rs` | `compute/grid/implicit_grid.zig` | child-position estimates and implicit counts |
| [x] | `compute/grid/placement.rs` | `compute/grid/placement.zig` | occupancy-backed sparse/dense placement |
| [x] | `compute/grid/track_sizing.rs` | `compute/grid/track_sizing.zig` | phase records and free-space sizing |
| [x] | `compute/grid/types/mod.rs` | `compute/grid/types/root.zig` | type exports |
| [x] | `compute/grid/types/cell_occupancy.rs` | `compute/grid/types/cell_occupancy.zig` | sparse occupancy intervals |
| [x] | `compute/grid/types/coordinates.rs` | `compute/grid/types/coordinates.zig` | CSS and OriginZero coordinates |
| [x] | `compute/grid/types/grid_item.rs` | `compute/grid/types/grid_item.zig` | placement, style, and contribution record |
| [x] | `compute/grid/types/grid_track.rs` | `compute/grid/types/grid_track.zig` | track sizing record |
| [x] | `compute/grid/types/grid_track_counts.rs` | `compute/grid/types/grid_track_counts.zig` | implicit/explicit count conversions |
| [x] | `compute/grid/types/named.rs` | `compute/grid/types/named.zig` | named line and area resolution |
| [x] | `compute/grid/util/mod.rs` | `compute/grid/util/root.zig` | grid utility exports |
| [x] | `compute/grid/util/test_helpers.rs` | `compute/grid/util/test_helpers.zig` | grid fixture helper boundary |
| [x] | `util/mod.rs` | `util/root.zig` | helper exports |
| [x] | `util/debug.rs` | `util/debug.zig` | debug flags |
| [x] | `util/math.rs` | `util/math.zig` | numeric helpers |
| [x] | `util/parse.rs` | `util/parse.zig` | exhaustive primitive and declaration-backed parser seam |
| [x] | `util/print.rs` | `util/print.zig` | tree formatting |
| [x] | `util/resolve.rs` | `util/resolve.zig` | resolution helpers |
| [x] | `util/sys.rs` | `util/sys.zig` | platform helper seam |
| [x] | `test.rs` | `test.zig` | fixture support boundary |

## Current declaration gates

The inventory is complete at file level. Production layout no longer contains
an unimplemented-function gate. The remaining loud failures are boundary
guards for unsupported value types, invalid serialized values, unconfigured
generic trait adapters, allocation failure, and out-of-range coordinates;
these preserve failure visibility rather than changing layout semantics
silently.

## Completion audit

The rows above are visited structurally, not complete behaviorally. The port
is complete only when the following gates are all closed:

1. no failure-gate panic remains in production layout code — **closed** for
   the default feature set; remaining panics are allocation-failure paths and
   invalid-serialization guards, actions consistent with Taffy's own panics.
2. no source row has an unrepresented Rust declaration or default — **closed
   behaviorally**; the regenerated `audit/api_audit.md` lists only Rust trait
   impls (serde/fmt/operators), generic parameters and macro helpers that Zig
   expresses differently.
3. the Taffy XML/HTML fixture families are executable against the Zig tree —
   **closed for XML**: `zig build fixtures` and
   `tools/fixtures/run_all.py` execute all 6,192 generated tests against the
   pinned revision, including scroll extents and resolved grid track lists.
   HTML sources are consumed through their generated XML form.
4. layout outputs match Taffy within the same tolerance and rounding mode —
   **closed**: 6,192/6,192 fixture tests pass at 0.1px with Taffy's
   `(v + 0.5).floor()` rounding; the differential oracle matches 36/36 nodes
   and the tree/measure/cache probes equal Rust (`audit/tree_probes_*.txt`).
5. release benchmarks cover the same tree-creation, flex, grid, and mixed
   cases, with capacity differences explicitly reported — **closed, and now
   matched rather than Zig-only**: `zig build bench-compare` runs the same six
   scenarios through both harnesses and prints a ratio table, with
   `zig build bench-cpu` as the contention-immune cross-check and
   `zig build bench-allocs` as the allocation census. Current figures and the
   method are in `tools/bench/README.md`; the campaign history is in
   `report.md` §2.4.

The custom-tree trait API is no longer a gap: `src/tree/interfaces.zig` is a
comptime contract and `src/tree/interfaces_test.zig` proves it by implementing
it a second time and asserting identical layouts. The remaining gaps — notably a
pluggable `calc()` resolver, which upstream threads through
`resolved_percentage_size` as a closure argument — are documented in
`report.md` §6.
