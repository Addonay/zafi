//! Computes size using styles and measure functions.
//!
//! Direct port of Taffy's `src/compute/leaf.rs`. Keep the order of operations
//! visible: resolve edge values, select sizing mode, reserve scroll gutters,
//! build available_space-space constraints, invoke the measure callback, then clamp
//! and apply aspect ratio. Do not move style resolution into the caller: the
//! same leaf function is used by flex, grid, block and absolute layout.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style/root.zig");
const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;
const layout = @import("../tree/layout.zig");
const math = @import("../util/math.zig");

/// Rust's measure closure `FnOnce(Size<Option<f32>>, Size<AvailableSpace>) -> Size<f32>`
/// expressed as a context pointer plus function pointer.
pub const SizeMeasureFunc = *const fn (
    context: ?*anyopaque,
    known_dimensions: geometry.Size(?f32),
    available_space: geometry.Size(AvailableSpace),
) geometry.Size(f32);

const F32Size = geometry.Size(f32);
const OptionalSize = geometry.Size(?f32);

/// Compute a leaf's output from a Taffy-style input and a size callback.
pub fn compute_leaf_layout(
    inputs: layout.LayoutInput,
    node_style: *const style.Style,
    context: ?*anyopaque,
    measure_function: ?SizeMeasureFunc,
) layout.LayoutOutput {
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;

    // Both horizontal and vertical percentage padding/borders resolve against
    // the container's inline size (i.e. width), per CSS.
    const margin = resolveOrZero(node_style.margin, parent_size.width);
    const padding = resolveLengthEdges(node_style.padding, parent_size.width);
    const border = resolveLengthEdges(node_style.border, parent_size.width);
    const padding_border = addRect(padding, border);
    const pb_sum = F32Size{ .width = padding_border.horizontal_axis_sum(), .height = padding_border.vertical_axis_sum() };
    const box_sizing_adjustment = if (node_style.box_sizing == .content_box) pb_sum else F32Size{ .width = 0, .height = 0 };

    // Resolve preferred/min/max sizes. In ContentSize mode size styles are ignored.
    var node_size: OptionalSize = undefined;
    var node_min_size: OptionalSize = undefined;
    var node_max_size: OptionalSize = undefined;
    var aspect_ratio: ?f32 = null;
    switch (inputs.sizing_mode) {
        .content_size => {
            node_size = known_dimensions;
            node_min_size = .{ .width = null, .height = null };
            node_max_size = .{ .width = null, .height = null };
        },
        .inherent_size => {
            aspect_ratio = node_style.aspect_ratio;
            const style_size = addSize(applyAspectRatio(resolveDimensionSize(node_style.size, parent_size), aspect_ratio), box_sizing_adjustment);
            const style_min_size = addSize(applyAspectRatio(resolveAutoSize(node_style.min_size, parent_size), aspect_ratio), box_sizing_adjustment);
            const style_max_size = addSize(resolveAutoSize(node_style.max_size, parent_size), box_sizing_adjustment);
            node_size = optionalOr(known_dimensions, style_size);
            node_min_size = style_min_size;
            node_max_size = style_max_size;
        },
    }

    // Scrollbar gutters reserve transposed space: a vertical scrollbar needs
    // horizontal room, and vice versa.
    const scrollbar_gutter = geometry.Point(f32){
        .x = if (node_style.overflow.y == .scroll) node_style.scrollbar_width else 0,
        .y = if (node_style.overflow.x == .scroll) node_style.scrollbar_width else 0,
    };
    var content_box_inset = padding_border;
    content_box_inset.right += scrollbar_gutter.x;
    content_box_inset.bottom += scrollbar_gutter.y;

    const has_styles_preventing_being_collapsed_through = !node_style.is_block() or
        node_style.overflow.x.is_scroll_container() or
        node_style.overflow.y.is_scroll_container() or
        node_style.position.is_out_of_flow() or
        node_style.contain.establishes_independent_formatting_context() or
        padding.top > 0 or
        padding.bottom > 0 or
        border.top > 0 or
        border.bottom > 0 or
        (node_size.height orelse 0) > 0 or
        (node_min_size.height orelse 0) > 0;

    // Return early if both width and height are known.
    if (inputs.run_mode == .compute_size and has_styles_preventing_being_collapsed_through) {
        if (node_size.width) |width| {
            if (node_size.height) |height| {
                const size = math.optional_size_maybe_max(
                    math.optional_size_maybe_clamp(.{ .width = width, .height = height }, node_min_size, node_max_size),
                    .{ .width = pb_sum.width, .height = pb_sum.height },
                );
                return layout.LayoutOutput.from_sizes(.{ .width = size.width.?, .height = size.height.? });
            }
        }
    }

    const content_inset_sum = F32Size{ .width = content_box_inset.horizontal_axis_sum(), .height = content_box_inset.vertical_axis_sum() };
    const margin_sum = F32Size{ .width = margin.horizontal_axis_sum(), .height = margin.vertical_axis_sum() };
    const available_space = geometry.Size(AvailableSpace){
        .width = availableForAxis(known_dimensions.width, node_size.width, inputs.available_space.width, node_min_size.width, node_max_size.width, margin_sum.width, content_inset_sum.width),
        .height = availableForAxis(known_dimensions.height, node_size.height, inputs.available_space.height, node_min_size.height, node_max_size.height, margin_sum.height, content_inset_sum.height),
    };

    const measure_known = if (inputs.run_mode == .compute_size) known_dimensions else OptionalSize{ .width = null, .height = null };
    const measured_size = if (measure_function) |function|
        function(context, measure_known, available_space)
    else
        F32Size{ .width = 0, .height = 0 };

    var base_size: OptionalSize = optionalOr(known_dimensions, node_size);
    if (base_size.width == null) base_size.width = measured_size.width + content_box_inset.horizontal_axis_sum();
    if (base_size.height == null) base_size.height = measured_size.height + content_box_inset.vertical_axis_sum();
    const clamped_size = math.optional_size_maybe_clamp(base_size, node_min_size, node_max_size);
    const size = F32Size{
        .width = clamped_size.width.?,
        .height = math.f32_max(clamped_size.height.?, if (aspect_ratio) |ratio| clamped_size.width.? / ratio else 0),
    };
    const maxed = math.optional_size_maybe_max(.{ .width = size.width, .height = size.height }, .{ .width = pb_sum.width, .height = pb_sum.height });
    const maxed_size = F32Size{ .width = maxed.width.?, .height = maxed.height.? };

    const is_scroll_container = node_style.overflow.x.is_scroll_container() or node_style.overflow.y.is_scroll_container();
    const is_rtl = node_style.direction == .rtl;
    const start_padding = if (is_rtl) padding.right else padding.left;
    const end_padding = if (is_rtl) padding.left else padding.right;
    const scrollable_overflow_rect = geometry.Rect(f32){
        .left = 0,
        .right = start_padding + measured_size.width + (if (is_scroll_container) end_padding else 0),
        .top = 0,
        .bottom = padding.top + measured_size.height + (if (is_scroll_container) padding.bottom else 0),
    };

    return .{
        .size = maxed_size,
        .scrollable_overflow_rect = scrollable_overflow_rect,
        .baselines = .none,
        .top_margin = .zero,
        .bottom_margin = .zero,
        .margins_can_collapse_through = !has_styles_preventing_being_collapsed_through and maxed_size.height == 0 and measured_size.height == 0,
    };
}

fn availableForAxis(known: ?f32, styled: ?f32, space: AvailableSpace, minimum: ?f32, maximum: ?f32, margin_sum: f32, inset_sum: f32) AvailableSpace {
    var result: AvailableSpace = if (known) |value| .{ .definite = value } else space;
    result = math.available_maybe_sub(result, margin_sum);
    if (known) |value| result = .{ .definite = value };
    if (styled) |value| result = .{ .definite = value };
    return mapDefinite(result, minimum, maximum, inset_sum);
}

fn mapDefinite(space: AvailableSpace, minimum: ?f32, maximum: ?f32, inset_sum: f32) AvailableSpace {
    return switch (space) {
        .definite => |value| .{ .definite = math.f32_maybe_clamp(value, minimum, maximum) - inset_sum },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

fn resolveLengthEdges(value: geometry.Rect(style.dimension.LengthPercentage), basis: ?f32) geometry.Rect(f32) {
    const resolved_basis = basis orelse 0;
    return .{ .left = value.left.resolve(resolved_basis), .right = value.right.resolve(resolved_basis), .top = value.top.resolve(resolved_basis), .bottom = value.bottom.resolve(resolved_basis) };
}

fn resolveAutoEdges(value: geometry.Rect(style.dimension.LengthPercentageAuto), basis: ?f32) geometry.Rect(?f32) {
    return .{ .left = value.left.resolve_to_option(basis), .right = value.right.resolve_to_option(basis), .top = value.top.resolve_to_option(basis), .bottom = value.bottom.resolve_to_option(basis) };
}

fn resolveDimensionSize(value: geometry.Size(style.dimension.Dimension), parent: geometry.Size(?f32)) OptionalSize {
    return .{ .width = value.width.resolve(parent.width), .height = value.height.resolve(parent.height) };
}

fn resolveAutoSize(value: geometry.Size(style.dimension.LengthPercentageAuto), parent: geometry.Size(?f32)) OptionalSize {
    return .{ .width = value.width.resolve_to_option(parent.width), .height = value.height.resolve_to_option(parent.height) };
}

fn resolveOrZero(value: geometry.Rect(style.dimension.LengthPercentageAuto), basis: ?f32) geometry.Rect(f32) {
    return .{
        .left = value.left.resolve_to_option(basis) orelse 0,
        .right = value.right.resolve_to_option(basis) orelse 0,
        .top = value.top.resolve_to_option(basis) orelse 0,
        .bottom = value.bottom.resolve_to_option(basis) orelse 0,
    };
}

fn optionalOr(a: OptionalSize, b: OptionalSize) OptionalSize {
    return .{ .width = a.width orelse b.width, .height = a.height orelse b.height };
}

fn addSize(value: OptionalSize, add: F32Size) OptionalSize {
    return .{ .width = if (value.width) |v| v + add.width else null, .height = if (value.height) |v| v + add.height else null };
}

fn applyAspectRatio(value: OptionalSize, ratio: ?f32) OptionalSize {
    if (ratio) |r| {
        if (value.width) |width| {
            if (value.height == null) return .{ .width = width, .height = width / r };
        }
        if (value.height) |height| {
            if (value.width == null) return .{ .width = height * r, .height = height };
        }
    }
    return value;
}

fn addRect(a: geometry.Rect(f32), b: geometry.Rect(f32)) geometry.Rect(f32) {
    return .{ .left = a.left + b.left, .right = a.right + b.right, .top = a.top + b.top, .bottom = a.bottom + b.bottom };
}

test "leaf sizing resolves known and measured axes" {
    const testing = std.testing;
    const input = layout.LayoutInput{
        .run_mode = .perform_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = .{ .width = null, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = 100, .height = 100 },
        .available_space = .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } },
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
    const node_style = style.Style{ .size = .{ .width = style.dimension.Dimension.length(30), .height = style.dimension.Dimension.length(20) } };
    const result = compute_leaf_layout(input, &node_style, null, null);
    try testing.expectEqual(@as(f32, 30), result.size.width);
    try testing.expectEqual(@as(f32, 20), result.size.height);
}

test "leaf min overrides max and respects padding floor" {
    const testing = std.testing;
    const input = layout.LayoutInput{
        .run_mode = .perform_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = .{ .width = null, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = 100, .height = 100 },
        .available_space = .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } },
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
    const node_style = style.Style{
        .size = .{ .width = style.dimension.Dimension.length(20), .height = style.dimension.Dimension.length(20) },
        .min_size = .{ .width = style.dimension.LengthPercentageAuto.length(100), .height = style.dimension.LengthPercentageAuto.auto() },
        .max_size = .{ .width = style.dimension.LengthPercentageAuto.length(10), .height = style.dimension.LengthPercentageAuto.auto() },
    };
    const result = compute_leaf_layout(input, &node_style, null, null);
    try testing.expectEqual(@as(f32, 100), result.size.width);
}

test "zero-height block leaves expose collapsible margins" {
    const testing = std.testing;
    const input = layout.LayoutInput{
        .run_mode = .perform_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = .{ .width = null, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = 100, .height = 100 },
        .available_space = .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } },
        .vertical_margins_are_collapsible = .{ .start = true, .end = true },
    };
    const node_style = style.Style{
        .display = .block,
        .margin = .{ .left = style.dimension.LengthPercentageAuto.zero(), .right = style.dimension.LengthPercentageAuto.zero(), .top = style.dimension.LengthPercentageAuto.length(5), .bottom = style.dimension.LengthPercentageAuto.length(7) },
    };
    const result = compute_leaf_layout(input, &node_style, null, null);
    try testing.expect(result.margins_can_collapse_through);
    try testing.expectEqual(@as(f32, 0), result.top_margin.resolve());
    try testing.expectEqual(@as(f32, 0), result.bottom_margin.resolve());
}
