# zlay

A standalone Zig layout engine: a behavior-verified port of
[Taffy](https://github.com/DioxusLabs/taffy) (pinned at `22f941e`, upstream
`main` as of 2026-10-03). Flexbox, grid, block/float layout, RTL, baselines,
absolute positioning, content sizing and scrollable overflow — with Taffy's
behavior, and a Zig-idiomatic API over it.

**Status: behavioral parity with the pinned Taffy on its full generated fixture
corpus, and roughly at parity overall in the matched benchmark suite** —
geometric mean **1.01×** Taffy's wall-clock time and **0.90×** on CPU time
(both figures move by roughly ±0.02 between runs on a shared host). See
[tools/bench/README.md](tools/bench/README.md) for the full table, the
per-scenario breakdown and the method.

| Gate | Result |
| --- | --- |
| Taffy generated XML fixtures (current pin) | **6,192 / 6,192** |
| Taffy generated XML fixtures (older baseline pin) | **6,076 / 6,084** — the 8 failures are fixtures whose expectations upstream deliberately changed (`align_baseline_child_margin_percent`, `rounding_fractial_input_6/7`) |
| Unit tests (`zig build test`) | **92 / 92** (**103 / 103** with `-Dserde=true`) |
| Host-genericity differential test | a second, independent `LayoutTree` implementor produces identical layouts — see `src/tree/interfaces_test.zig` |
| Matched benchmarks (`zig build bench-compare -- --repeat 5`) | geomean **1.01×** wall / **0.90×** CPU |
| Taffy `serde` wire format | validated against Rust-generated JSON (`audit/serde_format_rust.txt`) |

> Two earlier claims in this file were wrong and have been corrected. The
> benchmark figure was measured with the library compiled at `Debug`, so it was
> not a like-for-like comparison; and the fixture count predates the upstream
> pin move. Both are recorded rather than quietly replaced — see
> `tools/bench/README.md` § "Known trade-off" and the round-3 notes.

The port is checked in file-by-file against the pinned Rust sources; the parity
verdict, evidence and the (non-behavioral) remaining API gaps are documented in
[report.md](report.md). Per-subsystem audit history and raw evidence live under
[`audit/`](audit/).

## Using zlay

```sh
zig fetch --save=zlay <git-url>
```

This pins the package in your `build.zig.zon`; expose its module to a build:

```zig
// build.zig
const zlay = b.dependency("zlay", .{ .target = target, .optimize = optimize });

const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "zlay", .module = zlay.module("zlay") }},
});
```

```zig
// src/main.zig
const zlay = @import("zlay");

var tree = zlay.Tree.init(allocator);
const root = try tree.new_with_children(
    .{
        .display = .flex,
        .size = .{ .width = zlay.Dimension.length(400), .height = zlay.Dimension.auto },
    },
    &.{ try tree.new_leaf(.{ .size = .{
        .width = zlay.Dimension.length(60),
        .height = zlay.Dimension.length(10),
    } }) },
);
try tree.compute_layout(root, .{ .width = .{ .definite = 400 }, .height = .max_content });
```

Taffy-compatible JSON serde is an optional package feature; enable it at the
dependency call and it is fetched lazily:

```zig
const zlay = b.dependency("zlay", .{
    .target = target,
    .optimize = optimize,
    .serde = true, // compiles `zlay.serde_support`
});
```

## Repository layout

```
build.zig              package build: module, tests, fixtures, parity, audit, bench
build.zig.zon          package manifest (serde is the only, lazy, dependency)
src/                   the port (Taffy-shaped topology)
  root.zig             module entry point
  geometry.zig, style/, tree/, compute/, util/, prelude.zig, ...
  port.md              porting ledger with its completion gates
tools/
  fetch-reference.sh   clone pinned Taffy into .references/taffy
  pin.env              Taffy repo + immutable revision
  api_audit.py         static public-surface diff (Rust -> Zig)
  parity/              differential harness: Rust oracle vs Zig port
  fixtures/            Taffy XML fixture runner + out-of-process driver
  bench/               tree/flex/grid/block/mixed benchmarks
audit/                 generated results, probes, audits and reports
report.md              parity verdict, evidence, remaining gaps
plan.md                campaign plan and optimization results
.references/            ignored: pinned Taffy source checkout
```

## Building and testing

```sh
zig build test                 # 92 unit tests
zig build test -Dserde=true    # 103 tests, including Taffy wire-format serde
zig build check                # alias for `test`
zig build fixtures             # run the XML fixture suite in-process
zig build fixtures-bin         # install the fixture runner into zig-out/bin
python3 tools/fixtures/run_all.py --jobs 12   # one process per fixture (robust)
zig build parity -- --report   # differential harness (needs cargo)
zig build audit                # static Rust-vs-Zig declaration diff
zig build bench                # Zig benchmarks (defaults to ReleaseFast)
zig build bench-rust           # Rust Taffy mirror benchmarks
zig build bench-compare        # matched ratio table (`-- --repeat 5 --out ...`)
zig build bench-cpu            # CPU-time ratio table (`-- --repeat 5 --cpu 2`)
zig build bench-allocs         # allocation census per layout pass
```

Useful filters and helpers:

```sh
zig build fixtures -- --group flex --filter align --max-failures 10
python3 tools/fixtures/run_all.py --group grid --jobs 8 --failures /tmp/grid.txt
zig build bench -Doptimize=ReleaseFast -- --filter grid
bash tools/fetch-reference.sh                  # restore .references/taffy
```

`fixtures`, `parity` and `audit` require the pinned reference checkout;
`fetch-reference.sh` restores it. The parity oracle uses Cargo and the local
`.references/taffy` path only.

## Serialization (serde)

Zig has no derive-macro serde. The closest ecosystem equivalents are
[`std.json`](https://github.com/ziglang/zig/blob/master/lib/std/json.zig)
(first-party reflection plus `jsonStringify`/`jsonParse` hooks),
[`serde.zig`](https://github.com/OrlovEvgeny/serde.zig) (format-agnostic
options, custom hooks, JSON/YAML/TOML/MessagePack/...), and
[`ziggy`](https://github.com/kristoff-it/ziggy) (schema-based). This package
uses **serde.zig**, pinned by commit in `build.zig.zon`, because it offers
serde-like `serde` options and `zerdeSerialize`/`zerdeDeserialize` hooks while
supporting Zig 0.17 development builds.

`zig build test -Dserde=true` compiles Taffy-compatible JSON support:

- `Style` serializes with the same field set and order as Rust, including
  `"dummy": null`.
- `CompactLength` and its wrappers use Taffy's u64 wire bits with the same
  deserialization tag validation (calc is rejected on read).
- Enums use PascalCase names; alignments use `Safe`-prefixed strings;
  `GridPlacement`/`RepetitionCount` use Taffy's external tagging, which serde.zig
  handles natively, so those two need only a `rename` map.

Most of `src/serde_hooks.zig` is **not** a workaround: it is a port of the
`impl Serialize` / `impl Deserialize` blocks that Taffy itself hand-writes for
`CompactLength` (`.references/taffy/src/style/compact_length.rs:550`), the
alignment types (`alignment.rs:452`) and their wrappers. Those types exist
precisely because their in-memory shape differs from their wire shape, and no
reflection-based serializer can bridge that. Only `NamedLine`/`NamedSpan` keep a
hook for a structural reason: upstream models them as Rust *tuple variants*
(`["foo", -1]`), and serde.zig renders a struct as an object with no
newtype/transparent mode.

The expected wire format was captured from the pinned Rust crate into
`audit/serde_format_rust.txt`, and the tests deserialize Rust-generated JSON
directly. Serde is optional: without `-Dserde=true` no serde code is compiled
and the dependency is not imported (Zig materializes the pinned package under
the gitignored `zig-pkg/` directory at configure time).

## Reference pin

| Component | Revision |
| --- | --- |
| Taffy (tracked) | `22f941e19e05d1b29621703b4f3a9d96d7839886` (upstream `main`, 2026-10-03) |
| Taffy (baseline fixtures) | `1b918bafcab101dd234ebeb27da0443e24fd9de2`, kept for the historical corpus |
| Zig | `0.17.0` floor, per `build.zig.zon` |

`tools/pin.env` records both revisions and the gates they gate.

## License and provenance

MIT — see [LICENSE](LICENSE).

The Zig sources are a port of Taffy (MIT, Copyright (c) 2018 Visly Inc. and the
Taffy Authors) and started life as the layout engine of the ZUI project
(`zui/src/layout`). The Taffy checkout under `.references/` is used only as a
verification oracle and is not distributed with this package.
