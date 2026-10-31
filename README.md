# zafi

A CSS box layout engine for Zig: flexbox, grid, block layout with floats,
absolute positioning, RTL, baselines, intrinsic (content) sizing and scrollable
overflow. No dependencies.

zafi began as a behavior-exact port of [Taffy](https://github.com/DioxusLabs/taffy)
and is verified against Taffy's generated layout fixture corpus. It keeps Taffy's
layout behavior and exposes it through a Zig API: explicit allocators, a
generational node handle, and layout algorithms that are generic over your own
tree type.

## Status

| | |
| --- | --- |
| Layout behavior | Passes all 6,652 Taffy fixtures at Taffy `c6421c1` (upstream `main`, after v0.15.1) |
| Zig | 0.17.0 or newer |
| Dependencies | none (optional `serde.zig` for Taffy-compatible JSON) |

## Performance

Measured against Taffy `c6421c1` (Rust, `opt-level=3`, LTO) with the same
allocator (glibc `malloc`) and the same memory metric (peak live bytes) on
both sides, interleaved, best of 5, one core. Ratios are zafi / Taffy; lower
is better.

| scenario | time | memory |
| --- | --- | --- |
| rebuild a 1000-item flex row every frame (`clear` + rebuild + layout) | **0.91x** | 1.00x |
| relayout a 50x50 auto grid after restyling one cell | 1.09x | **0.76x** |
| flex row, 1000 items | 1.08x | 1.00x |
| wrapping flex, 500 items | **0.86x** | 1.00x |
| 50-deep nested blocks | **0.87x** | **0.47x** |
| nested flex > grid > block | **0.97x** | 1.06x |
| 50x50 fixed grid, fresh tree | 2.22x | **0.76x** |
| create a 10,000-node tree | 2.87x | **0.54x** |
| **geometric mean** | 1.22x | **0.79x** |

The last two scenarios build and destroy a whole tree per iteration, and their
time is dominated by glibc returning the freed memory to the OS and faulting it
back in. With that trimming disabled on both sides
(`MALLOC_TRIM_THRESHOLD_`/`MALLOC_MMAP_THRESHOLD_`), zafi is faster in every
scenario but relayout: tree creation 0.39x, grid 0.94x, geometric mean 0.84x.
Applications that rebuild a tree every frame should reuse it with
`Tree.clear()`, as the first row does.

Reproduce with the `dev` branch's `tools/` package (`zig build bench-compare`).

## Install

```sh
zig fetch --save=zafi git+https://github.com/Addonay/zafi
```

```zig
// build.zig
const zafi = b.dependency("zafi", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zafi", zafi.module("zafi"));
```

## Example

```zig
const std = @import("std");
const zafi = @import("zafi");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var tree = zafi.Tree.init(gpa.allocator());
    defer tree.deinit();

    const child = try tree.new_leaf(.{ .size = .{
        .width = zafi.Dimension.length(60),
        .height = zafi.Dimension.length(10),
    } });
    const root = try tree.new_with_children(.{
        .display = .flex,
        .size = .{ .width = zafi.Dimension.length(400), .height = zafi.Dimension.auto },
    }, &.{child});

    try tree.compute_layout(root, .{ .width = .{ .definite = 400 }, .height = .max_content });

    const layout = try tree.layout_of(child);
    std.debug.print("child at ({d}, {d}) size {d}x{d}\n", .{
        layout.location.x, layout.location.y, layout.size.width, layout.size.height,
    });
}
```

Text and other content are measured by the host: pass a measure function to
`compute_layout_with_measure` and attach per-node context with the tree's
context APIs.

### Using your own tree

The algorithms (`compute_flexbox_layout`, `compute_grid_layout`,
`compute_block_layout`, …) are generic over a `LayoutTree` interface, so a
host with its own node storage — a retained UI tree, an ECS — can run layout
directly on it instead of mirroring nodes into `zafi.Tree`.

## `calc()`

`calc()` values are opaque host handles: zafi stores the pointer and asks the
host to evaluate it against the basis that percentages would use.

```zig
const Expr = struct { percent: f32, px: f32 }; // your expression type

fn evalCalc(_: ?*anyopaque, handle: *const anyopaque, basis: f32) f32 {
    const e: *const Expr = @ptrCast(@alignCast(handle));
    return basis * e.percent / 100 + e.px;
}

tree.set_calc_resolver(.{ .func = evalCalc });
const half_plus_ten: Expr = .{ .percent = 50, .px = 10 };
_ = try tree.new_leaf(.{ .size = .{ .width = .calc(&half_plus_ten), .height = .auto } });
```

Custom `LayoutTree` hosts implement `calc(tree, handle, basis) ?f32` instead.
Like Taffy, a calc value with no definite basis is treated as indefinite (e.g.
`auto` for sizes), and with no resolver it evaluates to 0.

## JSON (optional)

Taffy-compatible `serde` JSON for `Style` and friends is behind a build option;
the dependency is fetched only when it is enabled:

```zig
const zafi = b.dependency("zafi", .{ .target = target, .optimize = optimize, .serde = true });
```

The wire format matches Taffy's Rust `serde` output.

## Known limitations

- Text, images and other content are measured by the host (see above); there is
  no built-in text shaping, inline formatting or table layout.

## Testing

```sh
zig build test                 # unit tests
zig build test -Dserde=true    # plus JSON wire-format tests
```

## License

MIT — see [LICENSE](LICENSE). zafi is a port of Taffy (MIT, Copyright (c) 2018
Visly Inc. and the Taffy Authors).
