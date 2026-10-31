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

## JSON (optional)

Taffy-compatible `serde` JSON for `Style` and friends is behind a build option;
the dependency is fetched only when it is enabled:

```zig
const zafi = b.dependency("zafi", .{ .target = target, .optimize = optimize, .serde = true });
```

The wire format matches Taffy's Rust `serde` output.

## Testing

```sh
zig build test                 # unit tests
zig build test -Dserde=true    # plus JSON wire-format tests
```

## License

MIT — see [LICENSE](LICENSE). zafi is a port of Taffy (MIT, Copyright (c) 2018
Visly Inc. and the Taffy Authors).
