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
- Toolchain: **Zig 0.17.0** (installed via zvm locally; in a cloud session,
  download the tarball from ziglang.org/download/index.json). Behind the cloud
  proxy `zig build -Dserde=true` cannot fetch serde.zig: `git clone` it, check
  out the pinned commit, `rm -rf .git`, then `zig fetch <dir>` (the hash
  matches build.zig.zon). Zig 0.17 spellings:
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

### Done but not merged: custom style types (branch `feat/style-view`, carried on `claude/festive-ptolemy-vdv58m`)

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
- README section: done ("Custom style types").

### Done: perf regression from #24 (calc) (branch `claude/festive-ptolemy-vdv58m`)

The work continued on `claude/festive-ptolemy-vdv58m`, which is
`feat/style-view` plus the fix; PR that branch (it supersedes
`feat/style-view`).

Result (A/B vs 0.3.0, interleaved, pinned, min over 20-40 rounds):
`relayout_grid_50x50` 1.43x (#24) -> 1.00x; every other scenario within ~3%
(`mixed_flex_grid_block`, `flex_row_1000` ~1.03x). Callgrind instruction
counts are at or below 0.3.0 except flex (~+4%).

Root cause (found with `perf annotate` + callgrind cache/branch sim):

- Zig lowers `?f32` by reference. A resolve `switch` whose arms each return
  `?f32` is merged as a pointer select between a rodata `null` constant and a
  stack slot. Once an arm cannot be if-converted (the calc arm's call; even a
  constant extra arm did it in an experiment), SROA cannot scalarise it, and
  the optional is written with two narrow stores (f32, flag byte) then read
  back with one 8-byte load: a **store-forwarding stall** (~15 cycles), in
  the innermost grid loops. Instruction counts barely move; time does.
- Also: tiny rect/size wrappers stopped inlining once the arms held a call.

Fixes (see commits on the branch):

- `CompactLength.maybe_resolve_with(basis, comptime with_calc)` and
  `resolve_or_with`: every case (calc too) merges on scalars and the optional
  is built once via `some_if` (`var r: ?f32 = v; if (!ok) r = null;`), never
  from a `null` constant. All ~15 duplicated length/percent/calc switches
  (block, flexbox, grid, util/resolve, track `definite_value`, `Dimension`/
  `LengthPercentage(Auto)`) go through it.
- `CompactLength.any_calc(.{...})`: branch-free "is any of these calc()".
  `GridItem.has_calc` and flex item construction (`Resolvers(with_calc)`)
  comptime-specialise on it. Tried for leaves too: the check cost more than it
  saved on a once-per-node path, reverted.
- `inline` on the small resolve wrappers in every algorithm.
- `if (c) x else null` on `?f32` in hot code is a smell; prefer the
  `some_if` shape. Code shape matters more than instruction count here.

Tooling: `perf` works in cloud VMs only with software events
(`-e cpu-clock`); there are no HW counters. Callgrind needs a
`-Dcpu=x86_64_v3` build (valgrind chokes on AVX-512). This VM is very noisy:
same-binary runs vary 30%; always run an A/A control.

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

1. ~~Fix the #24 perf regression~~ DONE; ~~README for custom style types~~
   DONE. PR `claude/festive-ptolemy-vdv58m` into dev (needs the owner's go).
2. CSS parsing completeness: IN PROGRESS. Plan: a differential oracle
   (`tools/parse_oracle`, Rust, Taffy `parse`+`serde`) prints Taffy's serde
   JSON (or ERR) for a corpus of `(type, input)`; a Zig checker does the same
   through zafi's `from_str` + serde and diffs. Known gaps: no `from_str` for
   `GridPlacement`, `RepetitionCount`, `GridAutoTracks` (zafi's accepts line
   names; Taffy's does not); the template parsers map OOM to
   `InvalidGridSyntax` and leak partial allocations on error.
3. More perf: fresh-tree glibc trimming behaviour, flex (~+4% instructions
   vs 0.3.0), `relayout_grid_50x50` vs Taffy.
4. Codex adversarial review (two runs max, in the background):
   `codex exec -m gpt-6.1-sol -c model_reasoning_effort='"medium"' -s read-only -o <file> "<prompt>"`.
   Fix the findings in PRs.
5. Bump to 0.4.0 and run `tools/release.sh 0.4.0`; push main and the tag; ask
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
