# AGENTS.md: handoff notes for agents working on zafi

Read this first. It records what has been done, what is in flight, and how to
get a fresh machine (e.g. a cloud session) productive. `DEVELOPMENT.md` covers
the branch layout and gates in less detail; `tools/pin.env` is authoritative
for the Taffy pin.

## What zafi is

- A Zig port of **Taffy** (Rust CSS layout: flexbox, grid, block, floats,
  absolute positioning). Goal set by the owner: *as good as or better than
  current upstream Taffy, a little faster, and noticeably more memory-efficient.*
- Repo: https://github.com/Addonay/zafi (renamed from "zlay").
- **Do not confuse with github.com/Addonay/zlay**: that is a *different*
  project (a Zig port of the Clay UI layout library). Never push to it,
  rename it, or put Taffy-port code there.
- Toolchain: **Zig 0.17.0** (installed via zvm locally). Zig 0.17 spellings:
  `std.lang.Optimize` values `.debug/.safe/.fast/.small`, `@backingInt` /
  `@fromBackingInt`.

## Branches, PRs, releases

- `main` = the package only: `build.zig build.zig.zon src README.md LICENSE
  .gitignore`. Never commit tooling to main.
- `dev` = everything (tools, audits, docs, this file). All work lands here.
- Work on short branches off `dev`, open a PR **into `dev`**, squash-merge
  (`gh pr merge <n> --squash --delete-branch`).
- Release: from a clean `dev`, bump `.version` in `build.zig.zon`, then
  `tools/release.sh <version>`. It copies the package paths to `main`, runs the
  test gates, commits and tags `v<version>`. **It never pushes**: push `main`
  and the tag yourself. Creating the GitHub release (`gh release create`)
  needs the owner's explicit OK.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  PR bodies end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

### PR history

| PR | What |
|---|---|
| #1–#4, #7, #8, #11 | Ported upstream Taffy commits (alignment model, grid placement/named lines/min contributions, hidden-layout reset, OOF fast path, block/float, flexbox, baselines, physical scrollable overflow) |
| #5 | Serde wire fixtures regenerated from a Rust oracle |
| #6 | Untracked accidentally committed agent worktrees (`.claude/` is now ignored) |
| #9 | Ported Taffy's hand-written scroll tests |
| #10, #17 | Benchmark harness: like-for-like vs Taffy; retained-tree scenarios |
| #12, #13 | Pinned Taffy `c6421c1` |
| #14–#16, #18 | Perf/memory: allocation-free child validation, compact SoA cache (328 B), node page sizing, scratch stack allocator, cheaper grid placement |
| #19 | Fix: cached layouts dropped out-of-flow candidates (stale abspos on relayout) |
| #20 | No hidden `page_allocator`: callers own every allocation |
| #21 | Fixes from a Codex adversarial review |
| #22 | Fix: stale layouts from cached block children sharing a float context (Taffy has this bug too) |
| #23 | Release prep 0.3.0 (**v0.3.0 is released**: main + tag + GitHub release) |
| #24 | `calc()` resolves through the host resolver (see below). Merged to dev. |

## Getting a fresh checkout running

```sh
git clone https://github.com/Addonay/zafi && cd zafi
git checkout feat/style-view        # the in-flight work (or dev)
bash tools/fetch-reference.sh       # clones Taffy at the pin into .references/taffy
zig build test && zig build test -Dserde=true
cd tools && zig build fixtures      # full Taffy XML corpus; expect 6652/6652
```

- The Taffy reference **must** live at `.references/taffy` (gitignored). The
  fixture runner has that path baked in (`tools/build.zig`). It must be a real
  clone of upstream `https://github.com/DioxusLabs/taffy` at
  `c6421c1cb20df5845e83285d3ce63c716f52186c`. **No symlinks to other local
  projects**: the owner was explicit about this.
- Tools are a separate Zig package in `tools/` that depends on `..` by path:
  `cd tools && zig build fixtures | fixtures-bin | bench-bin | bench-compare | audit | parity`.
- Rust mirror benchmark: `tools/bench/rust` (`cargo build --release`). Its
  `target/` was deleted locally to free disk; rebuild it if you need the
  zafi-vs-Taffy comparison.

## Gates (all must pass before a PR)

1. `zig build test`
2. `zig build test -Dserde=true`
3. `cd tools && zig build fixtures` → **6652/6652** at `c6421c1`
4. `zig build test -Doptimize=ReleaseSafe` is a good extra check.
5. No benchmark regression (see "Benchmarking" below).

## The current goal (owner's words)

> "fix those feature gaps and continue making it faster … then release a 0.4.0"

The feature gaps vs Taffy were:

1. **`calc()` support.** DONE (#24).
2. **Custom style types**, the counterpart of Taffy's 8 style traits. DONE on
   `feat/style-view`, not yet PR'd (see below).
3. **CSS parsing completeness**: TODO. `from_str` parsers exist for some
   types but are less complete than Taffy's; they should take an allocator
   (no hidden allocations).

Then: more speed, a Codex review, and release **0.4.0**.

### Done: calc() (#24)

- `src/style/calc.zig`: a thread-local `Resolver` (`current`) and `resolve()`.
- `src/compute/common/calc_scope.zig`: `bind(Tree, tree)` / `restore(prev)`.
  Bound in `compute_root_layout`, `compute_flexbox_layout`,
  `compute_grid_layout` and `compute_block_layout`; it calls
  `LayoutTree(Tree).calc(tree, handle, basis) orelse 0`.
- Every resolution site goes through it: `style/dimension.zig`,
  `style/compact_length.zig`, `style/grid.zig`,
  `compute/common/sizing_keyword.zig`, `util/resolve.zig`, and the local
  `MaybeResolve` helpers in flexbox, block, grid/root and grid_item.
- Taffy semantics: a calc value with no definite basis is indefinite (null);
  with no resolver it is 0.
- `Tree.set_calc_resolver(?CalcResolver)` (also `mark_all_dirty`).
- Fixed a latent bug: `util/resolve.maybe_resolve_length/auto` hit
  `unreachable` on calc values.
- Test: "calc() values resolve through the tree's calc resolver in flex, grid
  and block" (`src/tree/tree.zig`).

### Done but not merged: custom style types (branch `feat/style-view`)

- `src/style/view.zig`: algorithms read every property as `s.get(.field)`.
  - For zafi's `Style`, `Style.get` is an inlined field load: zero cost.
  - For a host style type `S`, `View(S).get` resolves at compile time to
    (1) a host method `pub fn name(self: *const S) T`, else (2) a field of the
    same type, else (3) zafi's default. Derived queries (`is_block`,
    `is_replaced`, …) can be overridden by host methods.
- `LayoutTree(Self).HostStyle` / `.StyleRef`: `get_style` may now return
  `*const HostStyle`.
- About 260 style reads in `src/compute` were rewritten mechanically to
  `.get(.field)`; functions that took `*const style.Style` now take `anytype`;
  `style.view.of(ptr)` normalises arguments (used in the leaf entry points).
- New hook `LayoutTree.general_allocator(tree)`: the host's `allocator` field,
  else its scratch allocator. It replaced 4 direct `tree_ref.allocator` reads
  (block, grid) that silently required hosts to have that field.
- `MeasureFunc` still takes `*const zafi.Style`; hosts with their own style
  type measure via `compute_leaf_layout`'s size callback (there's an assert).
- Test: "a host-defined style type lays out identically to zafi.Style"
  (`src/tree/interfaces_test.zig`; `CustomTree` is now `CustomTreeOf(NodeStyle)`
  with a `UiStyle` host type). Because Zig analyses every instantiated generic
  body, this test also proves at compile time that no algorithm code reaches a
  style field directly.
- Status: all gates pass (tests, serde, 6652/6652 fixtures).
- TODO before PR: README section for custom style types; resolve the perf
  regression below (it predates this branch, but the branch also carries the
  in-progress fix attempts).

### In progress: perf regression from #24 (calc)

Measured zafi vs zafi (base `e979025` = 0.3.0 vs current), ReleaseFast,
pinned to one core, min over both run orders:

| scenario | ratio (new / base) |
|---|---|
| relayout_grid_50x50 | **~1.38–1.46×** |
| mixed_flex_grid_block | ~1.15× |
| block_nested_50, flex_wrap_500 | ~1.08–1.11× |
| others | ~1.0–1.07× |

Findings so far:

- Bisected: the regression is entirely in #24; the style-view change adds
  nothing measurable.
- **Not** the TLS resolver binding (disabling `bind` changed nothing).
- **Not** the `style/grid.zig` calc arms (reverting that file changed nothing).
- `perf` shows small resolve helpers that used to inline now as out-of-line
  functions with frame setup and register saves
  (`grid_item.resolve_dimension_size`, `common.resolve_length_rect`,
  `grid.alignment.resolve_length_rect_or_zero`), plus growth in
  `GridItem.known_dimensions` / `minimum_contribution`. About +7% instructions
  and lower IPC overall. Before #24 the calc arm was a constant (`=> 0`), so
  LLVM could if-convert the switch; now there is a call in it.
- Already tried (committed on this branch, not sufficient on its own):
  making `calc.resolve` `noinline` + `@branchHint(.cold)`; `inline` on the
  `Dimension`/`LengthPercentage(Auto)` resolve methods,
  `resolve_length_rect` and grid_item `resolve_dimension_size`; folding the
  early `if (tag == .calc)` checks into the switch.
- **Next idea (was about to try):** make `calc.resolve` an `inline` wrapper
  whose first statement is `@branchHint(.cold)` and which calls a `noinline
  resolveSlow`, so each call site's calc branch itself is cold and LLVM can
  shrink-wrap the hot path (no prologue). If that does not work, try keeping
  the hot switch branch-free (compute the non-calc result with the old
  constant `.calc => 0` arm, then `if (tag == .calc) { @branchHint(.cold); … }`),
  or check a per-pass "any calc present" flag before entering slow paths.
  Also inspect `alignment.resolve_length_rect_or_zero` (not yet `inline`).

### Benchmarking notes

- `tools/zig-out/bin/bench [scenario]` prints `bench|scenario|iters|ns_per_iter|peak_live_bytes|allocs_per_iter`.
- This machine shows a strong **run-order effect** (whichever binary runs
  second is much faster). Always interleave, rotate the order, and take the min
  per binary across both orders. The A/B used `git worktree add <dir> <rev>`,
  then `cd <dir>/tools && zig build bench-bin -Doptimize=ReleaseFast`.
- vs Taffy at 0.3.0: time geomean 1.22× with default glibc; 0.84× with
  `MALLOC_TRIM_THRESHOLD_=1000000000 MALLOC_MMAP_THRESHOLD_=1000000000`
  (the fresh-tree gap is glibc trim/page-fault cost on teardown); memory 0.79×.
- Both sides use glibc malloc through a counting allocator (peak live bytes).

## Remaining roadmap to 0.4.0

1. Fix the #24 perf regression (above), then PR `feat/style-view` into dev.
2. README: document custom style types (`calc()` is already documented).
3. CSS parsing completeness (allocator-taking `from_str`, parity with Taffy's
   parsers).
4. More perf: fresh-tree glibc trimming behaviour, `relayout_grid_50x50`
   (was 1.09× vs Taffy before the regression).
5. Codex adversarial review (two runs max, in the background):
   `codex exec -m gpt-6.1-sol -c model_reasoning_effort='"medium"' -s read-only -o <file> "<prompt>"`.
   Fix the findings in PRs.
6. Bump to 0.4.0 and run `tools/release.sh 0.4.0`; push main and the tag; ask
   the owner before `gh release create`.

## Architecture notes worth knowing

- Generic algorithms over a `LayoutTree(Self)` interface
  (`src/tree/interfaces.zig`); `zafi.Tree` (`src/tree/tree.zig`) is the
  built-in host. Optional hooks are comptime-selected:
  `scratch_mark/scratch_release`, `cache_float_coupled`, `calc`,
  `general_allocator`.
- Memory: `ScratchStack` bump allocator with marks (`cachedDispatch` releases a
  child's temporaries when it returns no out-of-flow candidates; debug builds
  poison); compact SoA cache; node pages doubling 8→128 slots; generational
  NodeIds; epoch-based duplicate-child detection.
- Cache correctness rules: cached `perform_layout` entries keep their OOF
  candidates (`cached_oof_candidates`); float-coupled cache rule;
  `cache_store` propagates OutOfMemory.
- `CompactLength`: 8-bit tag + 56-bit payload (f32 bits or a calc pointer).

## Working conventions

- Subagents: Haiku 5.5 (high effort) may do PRs; Codex may also open PRs.
- Don't use `git checkout <file>` to discard: it has destroyed uncommitted
  work before. Check `git status` first.
- Never `git add -A` at the repo root without checking: agent worktrees
  under `.claude/` were once committed by accident.
- When simulating "old behaviour" in tests, make sure the simulation actually
  compiles (check the whole error output, not just one grep pattern).
