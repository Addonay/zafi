//! Differential parity candidate: runs the same scenarios against the Zig port.
//!
//! Companion to `tools/parity/rust/src/main.rs`; `tools/parity/run.py` diffs
//! the outputs. Output format: `scenario|label|x|y|w|h` (unrounded zafi).

const std = @import("std");
const zafi = @import("zafi");
const grid = zafi.style.grid;

const Pair = struct { []const u8, zafi.NodeId };

fn emit(name: []const u8, t: *zafi.Tree, nodes: []const Pair) void {
    for (nodes) |pair| {
        const l = t.unrounded_layout(pair[1]) catch return;
        std.debug.print("{s}|{s}|{d:.3}|{d:.3}|{d:.3}|{d:.3}\n", .{
            name, pair[0], l.location.x, l.location.y, l.size.width, l.size.height,
        });
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 1. flex container align-items: center
    {
        var t = zafi.Tree.init(alloc);
        const child = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(20), .height = zafi.Dimension.length(20) },
        });
        const root = try t.new_with_children(.{
            .display = .flex,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(100) },
            .align_items = zafi.AlignItems.center,
        }, &[_]zafi.NodeId{child});
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
        emit("flex_align_items_center", &t, &.{ .{ "root", root }, .{ "child", child } });
    }

    // 2. flex default align-items: stretch on an auto-cross child
    {
        var t = zafi.Tree.init(alloc);
        const child = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(20), .height = zafi.Dimension.auto },
        });
        const root = try t.new_with_children(.{
            .display = .flex,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(100) },
        }, &[_]zafi.NodeId{child});
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
        emit("flex_stretch_default", &t, &.{ .{ "root", root }, .{ "child", child } });
    }

    // 3. wrapped flex container with auto height
    {
        var t = zafi.Tree.init(alloc);
        const s = zafi.Style{
            .size = .{ .width = zafi.Dimension.length(60), .height = zafi.Dimension.length(10) },
        };
        const a = try t.new_leaf(s);
        const b = try t.new_leaf(s);
        const c = try t.new_leaf(s);
        const d = try t.new_leaf(s);
        const root = try t.new_with_children(.{
            .display = .flex,
            .flex_wrap = .wrap,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.auto },
        }, &[_]zafi.NodeId{ a, b, c, d });
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .max_content });
        emit("flex_wrap_auto_height", &t, &.{.{ "root", root }});
    }

    // 4. RTL flex row
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(20), .height = zafi.Dimension.length(10) },
        });
        const b = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(30), .height = zafi.Dimension.length(10) },
        });
        const root = try t.new_with_children(.{
            .display = .flex,
            .direction = .rtl,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(20) },
        }, &[_]zafi.NodeId{ a, b });
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
        emit("flex_rtl_row", &t, &.{ .{ "a", a }, .{ "b", b } });
    }

    // 5. flex gap
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(20), .height = zafi.Dimension.length(10) },
        });
        const b = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(30), .height = zafi.Dimension.length(10) },
        });
        const root = try t.new_with_children(.{
            .display = .flex,
            .gap = .{ .width = zafi.LengthPercentage.length(10), .height = zafi.LengthPercentage.length(10) },
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(20) },
        }, &[_]zafi.NodeId{ a, b });
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
        emit("flex_gap_row", &t, &.{ .{ "a", a }, .{ "b", b } });
    }

    // 6. flex-basis on an exactly-fitting line
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(10), .height = zafi.Dimension.length(10) },
            .flex_basis = zafi.Dimension.length(40),
            .flex_grow = 0,
            .flex_shrink = 0,
        });
        const root = try t.new_with_children(.{
            .display = .flex,
            .size = .{ .width = zafi.Dimension.length(40), .height = zafi.Dimension.length(20) },
        }, &[_]zafi.NodeId{a});
        try t.compute_layout(root, .{ .width = .{ .definite = 40 }, .height = .{ .definite = 20 } });
        emit("flex_basis_exact", &t, &.{.{ "a", a }});
    }

    // 7. align-self overrides container flex-start
    {
        var t = zafi.Tree.init(alloc);
        const child = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(20), .height = zafi.Dimension.length(20) },
            .align_self = zafi.AlignSelf.center,
        });
        const root = try t.new_with_children(.{
            .display = .flex,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(100) },
            .align_items = zafi.AlignItems.flex_start,
        }, &[_]zafi.NodeId{child});
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
        emit("flex_align_self_center", &t, &.{.{ "child", child }});
    }

    // 8. flex-grow distribution
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(20), .height = zafi.Dimension.length(10) },
            .flex_grow = 1,
        });
        const b = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(30), .height = zafi.Dimension.length(10) },
            .flex_grow = 2,
        });
        const root = try t.new_with_children(.{
            .display = .flex,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(20) },
        }, &[_]zafi.NodeId{ a, b });
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
        emit("flex_grow", &t, &.{ .{ "a", a }, .{ "b", b } });
    }

    // 9. grid fr tracks with gap
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(10), .height = zafi.Dimension.length(10) },
        });
        const b = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(10), .height = zafi.Dimension.length(10) },
        });
        const columns = [_]grid.GridTemplateComponent{
            .{ .single = grid.TrackSizingFunction.from_fr(1) },
            .{ .single = grid.TrackSizingFunction.from_fr(1) },
        };
        const root = try t.new_with_children(.{
            .display = .grid,
            .grid_template_columns = &columns,
            .gap = .{ .width = zafi.LengthPercentage.length(10), .height = zafi.LengthPercentage.length(10) },
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(50) },
        }, &[_]zafi.NodeId{ a, b });
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
        emit("grid_fr_gap", &t, &.{ .{ "a", a }, .{ "b", b } });
    }

    // 10. grid fixed + fr with gap
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(10), .height = zafi.Dimension.length(10) },
        });
        const b = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(10), .height = zafi.Dimension.length(10) },
        });
        const columns = [_]grid.GridTemplateComponent{
            .{ .single = grid.TrackSizingFunction.from_length(20) },
            .{ .single = grid.TrackSizingFunction.from_fr(1) },
        };
        const root = try t.new_with_children(.{
            .display = .grid,
            .grid_template_columns = &columns,
            .gap = .{ .width = zafi.LengthPercentage.length(10), .height = zafi.LengthPercentage.length(10) },
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(50) },
        }, &[_]zafi.NodeId{ a, b });
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
        emit("grid_fixed_gap", &t, &.{ .{ "a", a }, .{ "b", b } });
    }

    // 11. grid repeat(auto-fill, minmax(100px, 1fr))
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(10), .height = zafi.Dimension.length(10) },
        });
        const repeats = [_]grid.GridTemplateComponent{.{ .repeat = .{
            .count = .auto_fill,
            .tracks = &[_]grid.TrackSizingFunction{.{
                .min = grid.MinTrackSizingFunction.length(100),
                .max = grid.MaxTrackSizingFunction.fr(1),
            }},
        } }};
        const root = try t.new_with_children(.{
            .display = .grid,
            .grid_template_columns = &repeats,
            .size = .{ .width = zafi.Dimension.length(250), .height = zafi.Dimension.length(50) },
        }, &[_]zafi.NodeId{a});
        try t.compute_layout(root, .{ .width = .{ .definite = 250 }, .height = .{ .definite = 50 } });
        emit("grid_autofill_minmax", &t, &.{.{ "a", a }});
    }

    // 12. grid auto track sized by content
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(50), .height = zafi.Dimension.length(10) },
        });
        const b = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(10), .height = zafi.Dimension.length(10) },
        });
        const columns = [_]grid.GridTemplateComponent{
            .{ .single = grid.TrackSizingFunction.auto },
            .{ .single = grid.TrackSizingFunction.from_fr(1) },
        };
        const root = try t.new_with_children(.{
            .display = .grid,
            .grid_template_columns = &columns,
            .size = .{ .width = zafi.Dimension.length(300), .height = zafi.Dimension.length(50) },
        }, &[_]zafi.NodeId{ a, b });
        try t.compute_layout(root, .{ .width = .{ .definite = 300 }, .height = .{ .definite = 50 } });
        emit("grid_auto_content", &t, &.{ .{ "a", a }, .{ "b", b } });
    }

    // 13. block sibling margin collapse
    {
        var t = zafi.Tree.init(alloc);
        const zero = zafi.LengthPercentageAuto.zero();
        const a = try t.new_leaf(.{
            .display = .block,
            .size = .{ .width = zafi.Dimension.auto, .height = zafi.Dimension.length(10) },
            .margin = .{ .left = zero, .right = zero, .top = zero, .bottom = zafi.LengthPercentageAuto.length(20) },
        });
        const b = try t.new_leaf(.{
            .display = .block,
            .size = .{ .width = zafi.Dimension.auto, .height = zafi.Dimension.length(10) },
            .margin = .{ .left = zero, .right = zero, .top = zafi.LengthPercentageAuto.length(30), .bottom = zero },
        });
        const root = try t.new_with_children(.{
            .display = .block,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.auto },
        }, &[_]zafi.NodeId{ a, b });
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .max_content });
        emit("block_sibling_margins", &t, &.{ .{ "root", root }, .{ "a", a }, .{ "b", b } });
    }

    // 14. block parent/child margin collapse
    {
        var t = zafi.Tree.init(alloc);
        const zero = zafi.LengthPercentageAuto.zero();
        const child = try t.new_leaf(.{
            .display = .block,
            .size = .{ .width = zafi.Dimension.auto, .height = zafi.Dimension.length(20) },
            .margin = .{ .left = zero, .right = zero, .top = zafi.LengthPercentageAuto.length(10), .bottom = zafi.LengthPercentageAuto.length(10) },
        });
        const root = try t.new_with_children(.{
            .display = .block,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.auto },
        }, &[_]zafi.NodeId{child});
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .max_content });
        emit("block_parent_child_margins", &t, &.{ .{ "root", root }, .{ "child", child } });
    }

    // 15. min overrides max
    {
        var t = zafi.Tree.init(alloc);
        const root = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(20), .height = zafi.Dimension.length(20) },
            .min_size = .{ .width = zafi.LengthPercentageAuto.length(100), .height = zafi.LengthPercentageAuto.auto() },
            .max_size = .{ .width = zafi.LengthPercentageAuto.length(10), .height = zafi.LengthPercentageAuto.auto() },
        });
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
        emit("min_over_max", &t, &.{.{ "root", root }});
    }

    // 16. absolute child with left+right insets and a percentage grandchild
    {
        var t = zafi.Tree.init(alloc);
        const gc = try t.new_leaf(.{
            .display = .block,
            .size = .{ .width = zafi.Dimension.percent(0.5), .height = zafi.Dimension.length(10) },
        });
        const abs = try t.new_with_children(.{
            .display = .block,
            .position = .absolute,
            .inset = .{
                .left = zafi.LengthPercentageAuto.length(10),
                .right = zafi.LengthPercentageAuto.length(10),
                .top = zafi.LengthPercentageAuto.length(10),
                .bottom = zafi.LengthPercentageAuto.auto(),
            },
        }, &[_]zafi.NodeId{gc});
        const root = try t.new_with_children(.{
            .display = .block,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(100) },
        }, &[_]zafi.NodeId{abs});
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
        emit("absolute_lr", &t, &.{ .{ "abs", abs }, .{ "gc", gc } });
    }

    // 17. grid 1fr sanity without gap
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(10), .height = zafi.Dimension.length(10) },
        });
        const columns = [_]grid.GridTemplateComponent{.{ .single = grid.TrackSizingFunction.from_fr(1) }};
        const root = try t.new_with_children(.{
            .display = .grid,
            .grid_template_columns = &columns,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(50) },
        }, &[_]zafi.NodeId{a});
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
        emit("grid_1fr", &t, &.{.{ "a", a }});
    }

    // 18. grid fr tracks with gap, stretched items reveal actual track widths
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{});
        const b = try t.new_leaf(.{});
        const columns = [_]grid.GridTemplateComponent{
            .{ .single = grid.TrackSizingFunction.from_fr(1) },
            .{ .single = grid.TrackSizingFunction.from_fr(1) },
        };
        const root = try t.new_with_children(.{
            .display = .grid,
            .grid_template_columns = &columns,
            .gap = .{ .width = zafi.LengthPercentage.length(10), .height = zafi.LengthPercentage.length(10) },
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(50) },
        }, &[_]zafi.NodeId{ a, b });
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
        emit("grid_fr_gap_stretch", &t, &.{ .{ "a", a }, .{ "b", b } });
    }

    // 19. flex align-content: center on a wrapped container
    {
        var t = zafi.Tree.init(alloc);
        const s = zafi.Style{
            .size = .{ .width = zafi.Dimension.length(60), .height = zafi.Dimension.length(10) },
        };
        const a = try t.new_leaf(s);
        const b = try t.new_leaf(s);
        const c = try t.new_leaf(s);
        const d = try t.new_leaf(s);
        const root = try t.new_with_children(.{
            .display = .flex,
            .flex_wrap = .wrap,
            .align_content = zafi.AlignContent.center,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(100) },
        }, &[_]zafi.NodeId{ a, b, c, d });
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
        emit("flex_align_content_center", &t, &.{ .{ "a", a }, .{ "b", b } });
    }

    // 20. flex justify-content: center
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(20), .height = zafi.Dimension.length(10) },
        });
        const root = try t.new_with_children(.{
            .display = .flex,
            .justify_content = zafi.JustifyContent.center,
            .size = .{ .width = zafi.Dimension.length(100), .height = zafi.Dimension.length(20) },
        }, &[_]zafi.NodeId{a});
        try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
        emit("flex_justify_center", &t, &.{.{ "a", a }});
    }

    // 21. auto-fill minmax with stretched items reveals the generated track count
    {
        var t = zafi.Tree.init(alloc);
        const a = try t.new_leaf(.{});
        const b = try t.new_leaf(.{});
        const repeats = [_]grid.GridTemplateComponent{.{ .repeat = .{
            .count = .auto_fill,
            .tracks = &[_]grid.TrackSizingFunction{.{
                .min = grid.MinTrackSizingFunction.length(100),
                .max = grid.MaxTrackSizingFunction.fr(1),
            }},
        } }};
        const root = try t.new_with_children(.{
            .display = .grid,
            .grid_template_columns = &repeats,
            .size = .{ .width = zafi.Dimension.length(250), .height = zafi.Dimension.length(50) },
        }, &[_]zafi.NodeId{ a, b });
        try t.compute_layout(root, .{ .width = .{ .definite = 250 }, .height = .{ .definite = 50 } });
        emit("grid_autofill_minmax_stretch", &t, &.{ .{ "a", a }, .{ "b", b } });
    }
}
