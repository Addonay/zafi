//! Randomized robustness tests: random trees with hostile styles (NaN and
//! infinite lengths, huge spans, negative sizes, absolute boxes, hidden
//! subtrees), laid out, restyled, pruned and laid out again; and random input
//! for every CSS parser. They must never crash, leak or fail. Found: a stale
//! hoisted-child list after a container lost its children or became hidden,
//! and an assert on NaN scrollable-overflow edges (both also in Taffy).
//! Longer runs: raise the iteration counts locally.

const std = @import("std");
const zafi = @import("root.zig");
const grid = zafi.style.grid;
fn rlen(r: std.Random) zafi.Dimension {
    return switch (r.uintLessThan(u8, 9)) {
        0 => .auto,
        1 => .length(r.float(f32) * 200 - 20),
        2 => .percent(r.float(f32) * 1.5),
        3 => .min_content,
        4 => .max_content,
        5 => .fit_content_px(r.float(f32) * 100),
        6 => .length(std.math.inf(f32)),
        7 => .length(std.math.nan(f32)),
        else => .length(1e30),
    };
}
fn rlpa(r: std.Random) zafi.LengthPercentageAuto {
    return switch (r.uintLessThan(u8, 4)) {
        0 => .auto(),
        1 => .length(r.float(f32) * 40 - 10),
        2 => .percent(r.float(f32)),
        else => .length(0),
    };
}
fn rlp(r: std.Random) zafi.LengthPercentage {
    return if (r.boolean()) .length(r.float(f32) * 20) else .percent(r.float(f32) * 0.5);
}
var tracks_buf: [6]zafi.GridTemplateComponent = undefined;
fn rstyle(r: std.Random) zafi.Style {
    const displays = [_]zafi.Display{ .flex, .grid, .block, .none, .flow_root };
    var s: zafi.Style = .{};
    s.display = displays[r.uintLessThan(usize, displays.len)];
    s.position = if (r.uintLessThan(u8, 6) == 0) .absolute else .relative;
    s.size = .{ .width = rlen(r), .height = rlen(r) };
    s.min_size = .{ .width = rlpa(r), .height = rlpa(r) };
    s.max_size = .{ .width = rlpa(r), .height = rlpa(r) };
    s.margin = .{ .left = rlpa(r), .right = rlpa(r), .top = rlpa(r), .bottom = rlpa(r) };
    s.padding = .{ .left = rlp(r), .right = rlp(r), .top = rlp(r), .bottom = rlp(r) };
    s.inset = .{ .left = rlpa(r), .right = rlpa(r), .top = rlpa(r), .bottom = rlpa(r) };
    s.gap = .{ .width = rlp(r), .height = rlp(r) };
    s.flex_wrap = if (r.boolean()) .wrap else .no_wrap;
    s.flex_direction = @enumFromInt(r.uintLessThan(u8, 4));
    s.flex_grow = r.float(f32) * 3;
    s.flex_shrink = r.float(f32) * 3;
    s.flex_basis = rlen(r);
    s.aspect_ratio = if (r.uintLessThan(u8, 5) == 0) r.float(f32) * 3 else null;
    s.overflow = .{ .x = @enumFromInt(r.uintLessThan(u8, 4)), .y = @enumFromInt(r.uintLessThan(u8, 4)) };
    s.float = @enumFromInt(r.uintLessThan(u8, 3));
    s.box_sizing = if (r.boolean()) .border_box else .content_box;
    if (r.boolean()) {
        s.grid_template_columns = tracks_buf[0..r.uintLessThan(usize, 6)];
        s.grid_auto_flow = @enumFromInt(r.uintLessThan(u8, 4));
    }
    s.grid_row = .{ .start = if (r.boolean()) .auto else .{ .line = @as(i16, @intCast(r.uintLessThan(u8, 9))) - 4 }, .end = if (r.boolean()) .{ .span = r.uintLessThan(u16, 70) } else .auto };
    s.grid_column = .{ .start = .auto, .end = if (r.boolean()) .{ .span = r.uintLessThan(u16, 5) } else .{ .line = -1 } };
    return s;
}
test "layout fuzz" {
    inline for (.{ 1, 42 }) |seed| {
    tracks_buf = .{ .{ .single = .auto }, .{ .single = .from_fr(1) }, .{ .single = .from_length(20) }, .{ .single = .min_content }, .{ .single = .from_percent(0.3) }, .{ .single = .max_content } };
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (0..300) |_| {
        var tree = zafi.Tree.init(std.testing.allocator);
        defer tree.deinit();
        var ids: [40]zafi.NodeId = undefined;
        const n = 1 + r.uintLessThan(usize, ids.len);
        for (0..n) |i| ids[i] = try tree.new_leaf(rstyle(r));
        var i: usize = n;
        while (i > 1) {
            i -= 1;
            const parent = ids[r.uintLessThan(usize, i)];
            try tree.add_child(parent, ids[i]);
        }
        const spaces = [_]zafi.AvailableSpace{ .max_content, .min_content, .{ .definite = 300 }, .{ .definite = 0 } };
        try tree.compute_layout(ids[0], .{ .width = spaces[r.uintLessThan(usize, 4)], .height = spaces[r.uintLessThan(usize, 4)] });
        try tree.set_style(ids[r.uintLessThan(usize, n)], rstyle(r));
        try tree.compute_layout(ids[0], .{ .width = .{ .definite = 500 }, .height = .max_content });
        if (n > 2) _ = try tree.remove(ids[n - 1]);
        try tree.compute_layout(ids[0], .{ .width = .{ .definite = 200 }, .height = .{ .definite = 200 } });
    }
  }
}

test "parser fuzz" {
    const alphabet = " \t\n()[],-+.%/*0123456789eEpxfrautosnminxcolumnrowspandensefit-content(minmax repeat(auto-fill\\\"'#@:;";
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var buf: [48]u8 = undefined;
    const a = std.testing.allocator;
    for (0..20_000) |_| {
        const len = r.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = if (r.uintLessThan(u8, 8) == 0) r.int(u8) else alphabet[r.uintLessThan(usize, alphabet.len)];
        const in = buf[0..len];
        _ = zafi.Dimension.from_str(in) catch {};
        _ = zafi.LengthPercentage.from_str(in) catch {};
        _ = zafi.LengthPercentageAuto.from_str(in) catch {};
        _ = zafi.AvailableSpace.from_str(in) catch {};
        _ = zafi.AlignItems.from_str(in) catch {};
        _ = zafi.AlignContent.from_str(in) catch {};
        _ = zafi.Contain.from_str(in) catch {};
        _ = zafi.FlexWrap.from_str(in) catch {};
        _ = zafi.GridAutoFlow.from_str(in) catch {};
        _ = zafi.GridPlacement.from_str(in) catch {};
        _ = zafi.RepetitionCount.from_str(in) catch {};
        _ = zafi.TrackSizingFunction.from_str(in) catch {};
        if (grid.GridTemplateComponent.from_str(a, in)) |v| v.deinit(a) else |_| {}
        if (grid.GridTemplateTracks.from_str(a, in)) |v| v.deinit(a) else |_| {}
        if (grid.GridTemplateComponents.from_str(a, in)) |v| v.deinit(a) else |_| {}
        if (grid.grid_auto_tracks_from_str(a, in)) |v| a.free(v) else |_| {}
    }
}
