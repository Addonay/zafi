//! Port of Taffy's hand-written scroll tests (`tests/hand_written/scrollable_overflow.rs`
//! and `tests/hand_written/scroll_size.rs`). These cover scrollable-overflow behaviour that
//! the generated XML fixtures do not (reversed scroll origins, end padding, clipping).

const std = @import("std");
const zafi = @import("root.zig");

const testing = std.testing;
const geometry = zafi.geometry;
const Style = zafi.Style;
const Display = zafi.Display;
const Direction = zafi.Direction;
const Overflow = zafi.Overflow;
const Layout = zafi.Layout;
const NodeId = zafi.NodeId;
const FlexDirection = zafi.FlexDirection;
const FlexWrap = zafi.FlexWrap;
const BoxSizing = zafi.BoxSizing;
const Position = zafi.Position;
const LengthPercentage = zafi.LengthPercentage;
const LengthPercentageAuto = zafi.LengthPercentageAuto;
const TestNodeContext = zafi.testing.TestNodeContext;

const length = zafi.style_helpers.length;

/// Rust `Size::MAX_CONTENT`.
const MAX_CONTENT: geometry.Size(zafi.AvailableSpace) = .{ .width = .max_content, .height = .max_content };
/// Rust `Rect::ZERO`.
const ZERO_RECT: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 };

const CONTAINER: f32 = 200.0;
const CHILD: f32 = 50.0;

// Constants from scroll_size.rs
const CONTENT: f32 = 1000.0;
const BORDER: f32 = 20.0;
const PADDING: f32 = 20.0;

/// Rust `Rect { left, right, top, bottom }` of `LengthPercentage` lengths.
fn lp_rect(left: f32, right: f32, top: f32, bottom: f32) geometry.Rect(LengthPercentage) {
    return .{
        .left = LengthPercentage.length(left),
        .right = LengthPercentage.length(right),
        .top = LengthPercentage.length(top),
        .bottom = LengthPercentage.length(bottom),
    };
}

/// Rust `Rect<LengthPercentageAuto>`; `null` is `auto()`, a number is `length()`.
fn lpa_rect(left: ?f32, right: ?f32, top: ?f32, bottom: ?f32) geometry.Rect(LengthPercentageAuto) {
    return .{
        .left = lpa_value(left),
        .right = lpa_value(right),
        .top = lpa_value(top),
        .bottom = lpa_value(bottom),
    };
}

fn lpa_value(value: ?f32) LengthPercentageAuto {
    return if (value) |number| LengthPercentageAuto.length(number) else LengthPercentageAuto.auto();
}

// ---------------------------------------------------------------------------
// scrollable_overflow.rs
// ---------------------------------------------------------------------------

// The scrollable overflow rectangle captures start-side (negative) overflow as well as
// end-side overflow. Boxes wholly in the unreachable scrollable overflow region are
// excluded for scroll containers, while boxes only partially in the unreachable region
// contribute their border box, clipped to the reachable side of each scroll origin.

test "block_end_margins_do_not_extend_scrollable_overflow" {
    for ([_]Direction{ .ltr, .rtl }) |direction| {
        for ([_]f32{ -100.0, 0.0, 150.0 }) |bottom_margin| {
            for ([_]f32{ 0.0, 8.0 }) |padding| {
                errdefer std.debug.print("{s} margin {d} padding {d}\n", .{ @tagName(direction), bottom_margin, padding });
                var tree = zafi.Tree.init(testing.allocator);
                defer tree.deinit();
                const child = try tree.new_leaf(.{
                    .size = .{ .width = length(50.0), .height = length(50.0) },
                    .margin = lpa_rect(0, 0, 150.0, bottom_margin),
                });
                const node = try tree.new_with_children(.{
                    .display = .block,
                    .direction = direction,
                    .size = .{ .width = length(200.0), .height = length(200.0) },
                    .padding = lp_rect(0, 0, 0, padding),
                    .overflow = .{ .x = .scroll, .y = .scroll },
                }, &[_]NodeId{child});
                try tree.compute_layout(node, MAX_CONTENT);
                const layout = try tree.layout_of(node);
                const expected_end: f32 = 200.0 + (if (bottom_margin < 0.0) @as(f32, 0.0) else padding);
                try testing.expectEqual(expected_end, layout.scrollable_overflow_rect.bottom());
            }
        }
    }
}

test "negative_margins_do_not_add_padding_to_overflow_edges" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        for ([_]Direction{ .ltr, .rtl }) |direction| {
            for ([_]FlexDirection{ .row, .row_reverse, .column_reverse }) |flex_direction| {
                errdefer std.debug.print("{s} {s} {s}\n", .{ @tagName(display), @tagName(direction), @tagName(flex_direction) });
                var tree = zafi.Tree.init(testing.allocator);
                defer tree.deinit();
                const child = try tree.new_leaf(.{
                    .size = .{ .width = length(300.0), .height = length(300.0) },
                    .margin = lpa_rect(-100.0, -100.0, -100.0, -100.0),
                });
                const node = try tree.new_with_children(.{
                    .display = display,
                    .direction = direction,
                    .flex_direction = flex_direction,
                    .box_sizing = .content_box,
                    .size = .{ .width = length(80.0), .height = length(80.0) },
                    .padding = lp_rect(16.0, 4.0, 1.0, 8.0),
                    .border = lp_rect(4.0, 50.0, 1.0, 40.0),
                    .overflow = .{ .x = .hidden, .y = .hidden },
                }, &[_]NodeId{child});
                try tree.compute_layout(node, MAX_CONTENT);
                const layout = try tree.layout_of(node);
                const reversed_x = (direction == .rtl) != (display == .flex and flex_direction == .row_reverse);
                const expected_width: f32 = (if (reversed_x) @as(f32, 204.0) else 216.0) -
                    (if (display == .flex and flex_direction != .column_reverse) @as(f32, 20.0) else 0.0);
                const expected_height: f32 = if (display == .flex and flex_direction == .column_reverse) 188.0 else 201.0;
                try testing.expectEqual(expected_width, 100.0 + layout.scroll_width());
                try testing.expectEqual(expected_height, 89.0 + layout.scroll_height());
            }
        }
    }
}

fn container_with_absolute_child(
    display: Display,
    overflow: Overflow,
    direction: Direction,
    inset_left: ?f32,
    inset_right: ?f32,
) !Layout {
    var tree = zafi.Tree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.new_leaf(.{
        .position = .absolute,
        .inset = lpa_rect(inset_left, inset_right, 0, null),
        .size = .{ .width = length(CHILD), .height = length(CHILD) },
    });
    const node = try tree.new_with_children(.{
        .display = display,
        .direction = direction,
        .position = .relative,
        .size = .{ .width = length(CONTAINER), .height = length(CONTAINER) },
        .overflow = .{ .x = overflow, .y = overflow },
    }, &[_]NodeId{child});

    try tree.compute_layout(node, MAX_CONTENT);
    return try tree.layout_of(node);
}

test "wholly_unreachable_boxes_are_excluded_for_scroll_containers" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        // Child entirely before the scroll origin (x from -100 to -50)
        const layout = try container_with_absolute_child(display, .scroll, .ltr, -100.0, null);

        try testing.expectEqual(ZERO_RECT, layout.scrollable_overflow_rect.rect());
        try testing.expectEqual(@as(f32, 0.0), layout.scroll_width());
    }
}

test "wholly_unreachable_boxes_contribute_to_non_scroll_containers" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        // A box that is not a scroll container has no unreachable region of its own, so
        // start-side overflow is captured in its scrollable overflow rect.
        const layout = try container_with_absolute_child(display, .visible, .ltr, -100.0, null);

        try testing.expectEqual(@as(f32, -100.0), layout.scrollable_overflow_rect.left());
    }
}

test "partially_unreachable_boxes_are_clipped_at_the_normal_origin" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        // Child straddling the scroll origin (x from -25 to 25): the unreachable part is clipped.
        const layout = try container_with_absolute_child(display, .scroll, .ltr, -25.0, null);

        try testing.expectEqual(@as(f32, 0.0), layout.scrollable_overflow_rect.left());
        try testing.expectEqual(@as(f32, 25.0), layout.scrollable_overflow_rect.right());
        // Only the reachable extent counts towards the scroll width
        try testing.expectEqual(@as(f32, 0.0), layout.scroll_width());
    }
}

test "end_side_overflow_is_captured_and_scrollable" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        // Child extending past the end edge (x from 200 to 250)
        const layout = try container_with_absolute_child(display, .scroll, .ltr, CONTAINER, null);

        try testing.expectEqual(CONTAINER + CHILD, layout.scrollable_overflow_rect.right());
        try testing.expectEqual(CHILD, layout.scroll_width());
    }
}

test "absolute_only_containers_include_scroll_container_end_padding" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        var tree = zafi.Tree.init(testing.allocator);
        defer tree.deinit();
        const abs = try tree.new_leaf(.{
            .position = .absolute,
            .inset = lpa_rect(0, null, 0, null),
            .size = .{ .width = length(5.0), .height = length(5.0) },
        });
        const node = try tree.new_with_children(.{
            .display = display,
            .position = .relative,
            .overflow = .{ .x = .scroll, .y = .scroll },
            .padding = lp_rect(0.0, 20.0, 0.0, 30.0),
            .size = .{ .width = length(CONTAINER), .height = length(CONTAINER) },
        }, &[_]NodeId{abs});

        try tree.compute_layout(node, MAX_CONTENT);
        const layout = try tree.layout_of(node);

        try testing.expectEqual(@as(f32, 20.0), layout.scrollable_overflow_rect.right());
        try testing.expectEqual(@as(f32, 30.0), layout.scrollable_overflow_rect.bottom());
    }
}

fn nested_overflow_layout(display: Display, child_overflow: geometry.Point(Overflow)) !Layout {
    var tree = zafi.Tree.init(testing.allocator);
    defer tree.deinit();
    // Grandchild overflowing the child in the y axis (extends to y=300 in a 200-high child)
    const grandchild = try tree.new_leaf(.{
        .position = .absolute,
        .inset = lpa_rect(0, null, CONTAINER, null),
        .size = .{ .width = length(CHILD), .height = length(CHILD) },
    });
    const child = try tree.new_with_children(.{
        .display = display,
        .position = .relative,
        .size = .{ .width = length(CONTAINER), .height = length(CONTAINER) },
        .overflow = child_overflow,
    }, &[_]NodeId{grandchild});
    const node = try tree.new_with_children(.{
        .display = display,
        .size = .{ .width = length(CONTAINER), .height = length(CONTAINER) },
    }, &[_]NodeId{child});

    try tree.compute_layout(node, MAX_CONTENT);
    return try tree.layout_of(node);
}

test "scroll_container_in_one_axis_clips_both_axes" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        // `Hidden`/`Scroll` in either axis makes the child a scroll container, which clips
        // overflow in both axes: the grandchild's y overflow must not propagate.
        const layout = try nested_overflow_layout(display, .{ .x = .hidden, .y = .visible });

        try testing.expectEqual(CONTAINER, layout.scrollable_overflow_rect.bottom());
    }
}

test "clip_in_one_axis_does_not_clip_the_other" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        // `Clip` does not establish a scroll container: overflow in the other (visible) axis
        // still propagates.
        const layout = try nested_overflow_layout(display, .{ .x = .clip, .y = .visible });

        try testing.expectEqual(CONTAINER + CHILD, layout.scrollable_overflow_rect.bottom());
    }
}

test "wholly_unreachable_boxes_are_excluded_for_rtl_scroll_containers" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        // In RTL the scroll origin is the top-right corner: a child entirely past the
        // *right* edge is wholly unreachable.
        const layout = try container_with_absolute_child(display, .scroll, .rtl, null, -100.0);

        try testing.expectEqual(@as(f32, 0.0), layout.scrollable_overflow_rect.left());
        try testing.expectEqual(zafi.Point(bool){ .x = true, .y = false }, layout.scrollable_overflow_rect.is_reversed());
        try testing.expectEqual(@as(f32, 0.0), layout.scroll_width());
    }
}

test "end_side_overflow_is_captured_for_rtl_scroll_containers" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        // In RTL, overflow past the *left* edge is reachable end-side overflow.
        const layout = try container_with_absolute_child(display, .scroll, .rtl, -CHILD, null);

        try testing.expectEqual(-CHILD, layout.scrollable_overflow_rect.left());
        try testing.expectEqual(CHILD, layout.scroll_width());
    }
}

fn flex_overflow_layout(direction: Direction, flex_direction: FlexDirection, wrap: FlexWrap, absolute: bool) !Layout {
    var tree = zafi.Tree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.new_leaf(.{
        .position = if (absolute) Position.absolute else Position.relative,
        .flex_shrink = 0.0,
        .size = .{ .width = length(300.0), .height = length(300.0) },
    });
    const node = try tree.new_with_children(.{
        .display = .flex,
        .direction = direction,
        .flex_direction = flex_direction,
        .flex_wrap = wrap,
        .position = .relative,
        .overflow = .{ .x = .scroll, .y = .scroll },
        .size = .{ .width = length(CONTAINER), .height = length(CONTAINER) },
    }, &[_]NodeId{child});
    try tree.compute_layout(node, MAX_CONTENT);
    return try tree.layout_of(node);
}

test "flex_reversed_origins_include_negative_overflow" {
    for ([_]Direction{ .ltr, .rtl }) |direction| {
        for ([_]FlexDirection{ .row, .row_reverse, .column, .column_reverse }) |flex_direction| {
            for ([_]FlexWrap{ .no_wrap, .wrap_reverse }) |wrap| {
                // Exercise the same origins for in-flow and absolutely positioned flex children.
                for ([_]bool{ false, true }) |absolute| {
                    errdefer std.debug.print("{s} {s} {s} absolute={}\n", .{ @tagName(direction), @tagName(flex_direction), @tagName(wrap), absolute });
                    const layout = try flex_overflow_layout(direction, flex_direction, wrap, absolute);
                    const main_reversed = flex_direction == .row_reverse or flex_direction == .column_reverse;
                    const row_like = flex_direction == .row or flex_direction == .row_reverse;
                    const x_flag = if (row_like) main_reversed else wrap == .wrap_reverse;
                    const y_flag = if (row_like) wrap == .wrap_reverse else main_reversed;
                    const reversed = zafi.Point(bool){ .x = x_flag != direction.is_rtl(), .y = y_flag };
                    try testing.expectEqual(reversed, layout.scrollable_overflow_rect.is_reversed());
                    const overflow = layout.scrollable_overflow_rect;
                    try testing.expectEqual(@as(f32, if (reversed.x) -100.0 else 0.0), overflow.left());
                    try testing.expectEqual(@as(f32, if (reversed.y) -100.0 else 0.0), overflow.top());
                    try testing.expectEqual(@as(f32, 100.0), layout.scroll_width());
                    try testing.expectEqual(@as(f32, 100.0), layout.scroll_height());
                }
            }
        }
    }
}

test "wrap_reverse_lines_overflow_above_the_scrollport" {
    for ([_]Direction{ .ltr, .rtl }) |direction| {
        errdefer std.debug.print("{s}\n", .{@tagName(direction)});
        var tree = zafi.Tree.init(testing.allocator);
        defer tree.deinit();
        var children: [3]NodeId = undefined;
        for (&children) |*child| {
            child.* = try tree.new_leaf(.{
                .flex_shrink = 0.0,
                .size = .{ .width = length(100.0), .height = length(100.0) },
            });
        }
        const node = try tree.new_with_children(.{
            .display = .flex,
            .direction = direction,
            .flex_wrap = .wrap_reverse,
            .size = .{ .width = length(200.0), .height = length(100.0) },
            .overflow = .{ .x = .scroll, .y = .scroll },
        }, &children);
        try tree.compute_layout(node, MAX_CONTENT);
        const layout = try tree.layout_of(node);
        try testing.expectEqual(@as(f32, -100.0), (try tree.layout_of(children[2])).location.y);
        try testing.expectEqual(@as(f32, -100.0), layout.scrollable_overflow_rect.top());
        try testing.expectEqual(zafi.Point(bool){ .x = direction.is_rtl(), .y = true }, layout.scrollable_overflow_rect.is_reversed());
        try testing.expectEqual(@as(f32, 100.0), layout.scroll_height());
    }
}

test "empty_scroll_ranges_and_visible_container_origins" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        for ([_]Overflow{ .visible, .scroll }) |overflow| {
            errdefer std.debug.print("{s} {s}\n", .{ @tagName(display), @tagName(overflow) });
            var tree = zafi.Tree.init(testing.allocator);
            defer tree.deinit();
            const node = try tree.new_leaf(.{
                .display = display,
                .direction = .rtl,
                .flex_direction = .column_reverse,
                .flex_wrap = .wrap_reverse,
                .size = .{ .width = length(CONTAINER), .height = length(CONTAINER) },
                .overflow = .{ .x = overflow, .y = overflow },
            });
            try tree.compute_layout(node, MAX_CONTENT);
            const layout = try tree.layout_of(node);
            if (overflow == .visible) {
                try testing.expectEqual(zafi.Point(bool){ .x = false, .y = false }, layout.scrollable_overflow_rect.is_reversed());
            }
            try testing.expectEqual(@as(f32, 0.0), layout.scroll_width());
            try testing.expectEqual(@as(f32, 0.0), layout.scroll_height());
        }
    }
}

test "negative_overflow_is_preserved_for_visible_flex_containers" {
    var tree = zafi.Tree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.new_leaf(.{
        .flex_shrink = 0.0,
        .size = .{ .width = length(300.0), .height = length(300.0) },
    });
    const node = try tree.new_with_children(.{
        .display = .flex,
        .flex_direction = .column_reverse,
        .flex_wrap = .wrap_reverse,
        .size = .{ .width = length(CONTAINER), .height = length(CONTAINER) },
    }, &[_]NodeId{child});
    try tree.compute_layout(node, MAX_CONTENT);
    const overflow = (try tree.layout_of(node)).scrollable_overflow_rect;
    try testing.expectEqual(zafi.Point(bool){ .x = false, .y = false }, overflow.is_reversed());
    try testing.expectEqual(@as(f32, -100.0), overflow.left());
    try testing.expectEqual(@as(f32, -100.0), overflow.top());
}

test "reversed_flex_origins_clip_unreachable_absolute_overflow" {
    for ([_]FlexDirection{ .row_reverse, .column_reverse }) |flex_direction| {
        for ([_]f32{ -100.0, -25.0, 175.0, 200.0 }) |offset| {
            errdefer std.debug.print("{s} {d}\n", .{ @tagName(flex_direction), offset });
            var tree = zafi.Tree.init(testing.allocator);
            defer tree.deinit();
            const row = flex_direction == .row_reverse;
            const child = try tree.new_leaf(.{
                .position = .absolute,
                .inset = lpa_rect(if (row) offset else 0.0, null, if (row) 0.0 else offset, null),
                .size = .{ .width = length(CHILD), .height = length(CHILD) },
            });
            const node = try tree.new_with_children(.{
                .display = .flex,
                .flex_direction = flex_direction,
                .position = .relative,
                .size = .{ .width = length(CONTAINER), .height = length(CONTAINER) },
                .overflow = .{ .x = .scroll, .y = .scroll },
            }, &[_]NodeId{child});
            try tree.compute_layout(node, MAX_CONTENT);
            const layout = try tree.layout_of(node);
            const overflow = layout.scrollable_overflow_rect;
            try testing.expect(overflow.right() <= CONTAINER and overflow.bottom() <= CONTAINER);
            const expected: f32 = @max(-offset, 0.0);
            const actual: f32 = if (row) layout.scroll_width() else layout.scroll_height();
            try testing.expectEqual(expected, actual);
        }
    }
}

test "reversed_flex_scroll_ranges_include_padding_and_exclude_borders" {
    for ([_]Direction{ .ltr, .rtl }) |direction| {
        for ([_]FlexDirection{ .row, .row_reverse, .column, .column_reverse }) |flex_direction| {
            for ([_]FlexWrap{ .no_wrap, .wrap_reverse }) |wrap| {
                errdefer std.debug.print("{s} {s} {s}\n", .{ @tagName(direction), @tagName(flex_direction), @tagName(wrap) });
                var tree = zafi.Tree.init(testing.allocator);
                defer tree.deinit();
                const child = try tree.new_leaf(.{
                    .flex_shrink = 0.0,
                    .size = .{ .width = length(300.0), .height = length(300.0) },
                });
                const node = try tree.new_with_children(.{
                    .display = .flex,
                    .direction = direction,
                    .flex_direction = flex_direction,
                    .flex_wrap = wrap,
                    .size = .{ .width = length(CONTAINER), .height = length(CONTAINER) },
                    .border = lp_rect(20.0, 20.0, 20.0, 20.0),
                    .padding = lp_rect(10.0, 20.0, 30.0, 40.0),
                    .overflow = .{ .x = .scroll, .y = .scroll },
                }, &[_]NodeId{child});
                try tree.compute_layout(node, MAX_CONTENT);
                const layout = try tree.layout_of(node);
                try testing.expectEqual(@as(f32, 170.0), layout.scroll_width());
                try testing.expectEqual(@as(f32, 210.0), layout.scroll_height());
            }
        }
    }
}

// ---------------------------------------------------------------------------
// scroll_size.rs
// ---------------------------------------------------------------------------

// The maximum scroll offset is the content size less the size of the padding
// box, so it must not depend on which side a border sits on, and must agree
// across the layout algorithms.

fn scroller_with_padding(
    display: Display,
    border: geometry.Rect(LengthPercentage),
    padding: geometry.Rect(LengthPercentage),
) !Layout {
    var tree = zafi.Tree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.new_leaf(.{
        .size = .{ .width = length(100.0), .height = length(CONTENT) },
    });
    const node = try tree.new_with_children(.{
        .display = display,
        .box_sizing = .border_box,
        .size = .{ .width = length(300.0), .height = length(CONTAINER) },
        .border = border,
        .padding = padding,
        .overflow = .{ .x = .scroll, .y = .scroll },
    }, &[_]NodeId{child});

    try tree.compute_layout(node, MAX_CONTENT);
    return try tree.layout_of(node);
}

fn scroller(display: Display, border: geometry.Rect(LengthPercentage)) !Layout {
    return scroller_with_padding(display, border, edge(0.0, 0.0));
}

fn edge(top: f32, bottom: f32) geometry.Rect(LengthPercentage) {
    return lp_rect(0.0, 0.0, top, bottom);
}

// Top/bottom pair used by the padding and border loops below.
const Edges = struct { top: f32, bottom: f32 };

test "scroll_height_does_not_depend_on_which_edge_the_border_is_on" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        const top = try scroller(display, edge(BORDER, 0.0));
        const bottom = try scroller(display, edge(0.0, BORDER));

        // Rust: border-top gave {top} and border-bottom gave {bottom}
        try testing.expectEqual(top.scroll_height(), bottom.scroll_height());
    }
}

test "scroll_height_is_the_content_beyond_the_padding_box" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        for ([_]Edges{
            .{ .top = BORDER, .bottom = 0.0 },
            .{ .top = 0.0, .bottom = BORDER },
            .{ .top = BORDER, .bottom = BORDER },
            .{ .top = 0.0, .bottom = 0.0 },
        }) |pair| {
            errdefer std.debug.print("{s} with border {d}/{d}\n", .{ @tagName(display), pair.top, pair.bottom });
            const layout = try scroller(display, edge(pair.top, pair.bottom));
            const padding_box = CONTAINER - pair.top - pair.bottom;

            try testing.expectEqual(CONTENT - padding_box, layout.scroll_height());
        }
    }
}

test "scrollable_overflow_excludes_the_containers_own_border" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        for ([_]Edges{
            .{ .top = BORDER, .bottom = 0.0 },
            .{ .top = 0.0, .bottom = BORDER },
            .{ .top = BORDER, .bottom = BORDER },
            .{ .top = 0.0, .bottom = 0.0 },
        }) |pair| {
            errdefer std.debug.print("{s} with border {d}/{d}\n", .{ @tagName(display), pair.top, pair.bottom });
            const layout = try scroller(display, edge(pair.top, pair.bottom));

            try testing.expectEqual(CONTENT, layout.scrollable_overflow_rect.bottom());
        }
    }
}

test "scrollable_overflow_includes_the_containers_own_padding" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        for ([_]Edges{
            .{ .top = PADDING, .bottom = 0.0 },
            .{ .top = 0.0, .bottom = PADDING },
            .{ .top = PADDING, .bottom = PADDING },
            .{ .top = 0.0, .bottom = 0.0 },
        }) |pair| {
            errdefer std.debug.print("{s} with padding {d}/{d}\n", .{ @tagName(display), pair.top, pair.bottom });
            const layout = try scroller_with_padding(display, edge(0.0, 0.0), edge(pair.top, pair.bottom));

            try testing.expectEqual(CONTENT + pair.top + pair.bottom, layout.scrollable_overflow_rect.bottom());
        }
    }
}

test "scrollable_overflow_excludes_the_own_padding_of_a_non_scroll_container" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        for ([_]Edges{
            .{ .top = PADDING, .bottom = 0.0 },
            .{ .top = 0.0, .bottom = PADDING },
            .{ .top = PADDING, .bottom = PADDING },
            .{ .top = 0.0, .bottom = 0.0 },
        }) |pair| {
            errdefer std.debug.print("{s} with padding {d}/{d}\n", .{ @tagName(display), pair.top, pair.bottom });
            var tree = zafi.Tree.init(testing.allocator);
            defer tree.deinit();
            const child = try tree.new_leaf(.{
                .size = .{ .width = length(100.0), .height = length(CONTENT) },
            });
            const node = try tree.new_with_children(.{
                .display = display,
                .box_sizing = .border_box,
                .size = .{ .width = length(300.0), .height = length(CONTAINER) },
                .padding = edge(pair.top, pair.bottom),
            }, &[_]NodeId{child});

            try tree.compute_layout(node, MAX_CONTENT);
            const layout = try tree.layout_of(node);

            // A box that is not a scroll container does not extend its scrollable overflow
            // region by its own padding: only the content contributes.
            try testing.expectEqual(pair.top + CONTENT, layout.scrollable_overflow_rect.bottom());
        }
    }
}

fn measured_leaf(overflow: Overflow, padding: geometry.Rect(LengthPercentage)) !Layout {
    var tree = zafi.Tree.init(testing.allocator);
    defer tree.deinit();
    var context = TestNodeContext.fixed(.{ .width = 100.0, .height = CONTENT });
    const node = try tree.new_leaf_with_context(.{
        .box_sizing = .border_box,
        .size = .{ .width = length(300.0), .height = length(CONTAINER) },
        .padding = padding,
        .overflow = .{ .x = overflow, .y = overflow },
    }, &context);

    try tree.compute_layout_with_measure(node, MAX_CONTENT, zafi.testing.fixture_measure_function);
    return try tree.layout_of(node);
}

test "leaf_content_size_includes_the_containers_own_padding" {
    for ([_]Edges{
        .{ .top = PADDING, .bottom = 0.0 },
        .{ .top = 0.0, .bottom = PADDING },
        .{ .top = PADDING, .bottom = PADDING },
        .{ .top = 0.0, .bottom = 0.0 },
    }) |pair| {
        errdefer std.debug.print("Leaf with padding {d}/{d}\n", .{ pair.top, pair.bottom });
        const layout = try measured_leaf(.scroll, edge(pair.top, pair.bottom));

        try testing.expectEqual(pair.top + CONTENT + pair.bottom, layout.scrollable_overflow_rect.bottom());
    }
}

test "leaf_content_size_excludes_the_own_padding_of_a_non_scroll_container" {
    for ([_]Edges{
        .{ .top = PADDING, .bottom = 0.0 },
        .{ .top = 0.0, .bottom = PADDING },
        .{ .top = PADDING, .bottom = PADDING },
        .{ .top = 0.0, .bottom = 0.0 },
    }) |pair| {
        errdefer std.debug.print("Leaf with padding {d}/{d}\n", .{ pair.top, pair.bottom });
        const layout = try measured_leaf(.visible, edge(pair.top, pair.bottom));

        // A box that is not a scroll container does not extend its scrollable overflow
        // region by its own padding: only the content contributes.
        try testing.expectEqual(pair.top + CONTENT, layout.scrollable_overflow_rect.bottom());
    }
}

test "scroll_height_accounts_for_the_containers_own_padding" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        for ([_]Edges{
            .{ .top = PADDING, .bottom = 0.0 },
            .{ .top = 0.0, .bottom = PADDING },
            .{ .top = PADDING, .bottom = PADDING },
            .{ .top = 0.0, .bottom = 0.0 },
        }) |pair| {
            errdefer std.debug.print("{s} with padding {d}/{d}\n", .{ @tagName(display), pair.top, pair.bottom });
            const layout = try scroller_with_padding(display, edge(0.0, 0.0), edge(pair.top, pair.bottom));

            // The scrollable overflow region runs from the padding-box origin to the end of
            // the content plus the container's end-side padding.
            const expected: f32 = (pair.top + CONTENT + pair.bottom) - CONTAINER;
            try testing.expectEqual(expected, layout.scroll_height());
        }
    }
}

// Items in overflowing rows must contribute their position within the container (not just
// their size) to the container's content size.
test "grid_scrollable_overflow_includes_item_positions_in_overflowing_tracks" {
    var tree = zafi.Tree.init(testing.allocator);
    defer tree.deinit();
    const child: Style = .{ .size = .{ .width = length(100.0), .height = length(500.0) } };
    const c1 = try tree.new_leaf(child);
    const c2 = try tree.new_leaf(child);
    const node = try tree.new_with_children(.{
        .display = .grid,
        .size = .{ .width = length(300.0), .height = length(CONTAINER) },
        .overflow = .{ .x = .scroll, .y = .scroll },
    }, &[_]NodeId{ c1, c2 });

    try tree.compute_layout(node, MAX_CONTENT);
    const layout = try tree.layout_of(node);

    try testing.expectEqual(@as(f32, 1000.0), layout.scrollable_overflow_rect.bottom());
    try testing.expectEqual(@as(f32, 1000.0 - CONTAINER), layout.scroll_height());
}

test "scroll_height_agrees_with_borders_and_padding_combined" {
    for ([_]Display{ .block, .flex, .grid }) |display| {
        errdefer std.debug.print("{s}\n", .{@tagName(display)});
        const layout = try scroller_with_padding(display, edge(BORDER, BORDER), edge(PADDING, PADDING));

        const padding_box = CONTAINER - BORDER - BORDER;
        const expected: f32 = (PADDING + CONTENT + PADDING) - padding_box;
        try testing.expectEqual(expected, layout.scroll_height());
    }
}
