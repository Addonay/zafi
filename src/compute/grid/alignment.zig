//! Direct port of Taffy's `compute/grid/alignment.rs`.
//!
//! Alignment of tracks and final positioning of items.

const std = @import("std");
const geometry = @import("../../geometry.zig");
const style = @import("../../style/root.zig");
const AvailableSpace = @import("../../style/available_space.zig").AvailableSpace;
const math = @import("../../util/math.zig");
const alignment = @import("../common/alignment.zig");
const scrollable_overflow = @import("../common/scrollable_overflow.zig");
const sizing_keyword = @import("../common/sizing_keyword.zig");
const NodeId = @import("../../tree/node.zig").NodeId;
const layout = @import("../../tree/layout.zig");
const tree_layout = layout;
const oof = @import("../oof.zig");
const grid_track = @import("types/grid_track.zig");
const LayoutTree = @import("../../tree/interfaces.zig").LayoutTree;

const GridTrack = grid_track.GridTrack;
const AlignContent = style.alignment.AlignContent;
const AlignItems = style.alignment.AlignItems;
const AlignItemsKeyword = style.alignment.AlignItemsKeyword;
const AlignSelf = style.alignment.AlignSelf;
const Overflow = style.Overflow;
const Position = style.Position;
const Direction = style.Direction;
const BoxSizing = style.BoxSizing;

/// Align the grid tracks within the grid according to the align-content (rows)
/// or justify-content (columns) property.
pub fn align_tracks(
    grid_container_content_box_size: f32,
    padding: geometry.Line(f32),
    border: geometry.Line(f32),
    tracks: []GridTrack,
    track_alignment_style: AlignContent,
    axis_is_reversed: bool) void {
    const used_size: f32 = sum_base_sizes(tracks);
    const free_space = grid_container_content_box_size - used_size;
    const origin = padding.start + border.start;

    // Count the number of non-collapsed tracks (not counting gutters)
    var num_tracks: usize = 0;
    var i: usize = 1;
    while (i < tracks.len) : (i += 2) {
        if (!tracks[i].is_collapsed) num_tracks += 1;
    }

    // Grid layout treats gaps as full tracks rather than applying them at alignment so we
    // simply pass zero here. Grid layout is never reversed.
    const gap = 0.0;
    const layout_is_reversed = false;
    var track_alignment = alignment.apply_alignment_fallback(free_space, num_tracks, track_alignment_style);
    if (axis_is_reversed) track_alignment = track_alignment.reversed();

    // If every track is collapsed then no track receives the alignment offset
    // below, but the grid's lines should still be aligned within the container.
    const empty_grid_offset = if (num_tracks == 0)
        alignment.compute_alignment_offset(free_space, num_tracks, gap, track_alignment, layout_is_reversed, true)
    else
        0.0;

    // Compute offsets. Tracks are stored in logical order; when the axis is reversed
    // (RTL) physical offsets are assigned right-to-left by iterating in reverse.
    var total_offset = origin + empty_grid_offset;
    var seen_non_collapsed_track = false;

    const position_track = struct {
        fn call(
            idx: usize,
            track: *GridTrack,
            free_space_value: f32,
            num_tracks_value: usize,
            gap_value: f32,
            alignment_keyword: style.alignment.AlignContentKeyword,
            reversed: bool,
            total_offset_ptr: *f32,
            seen_ptr: *bool) void {
            // Odd tracks are gutters (but slices are zero-indexed, so gutters have even indices)
            const is_gutter = idx % 2 == 0;
            const is_non_collapsed_track = !is_gutter and !track.is_collapsed;

            // Alignment offsets should be applied only to non-collapsed tracks.
            const is_first = is_non_collapsed_track and !seen_ptr.*;

            const offset = if (is_non_collapsed_track)
                alignment.compute_alignment_offset(free_space_value, num_tracks_value, gap_value, alignment_keyword, reversed, is_first)
            else
                0.0;

            track.offset = total_offset_ptr.* + offset;
            total_offset_ptr.* = total_offset_ptr.* + offset + track.base_size;
            if (is_non_collapsed_track) seen_ptr.* = true;
        }
    }.call;

    if (axis_is_reversed) {
        var idx = tracks.len;
        while (idx > 0) {
            idx -= 1;
            position_track(idx, &tracks[idx], free_space, num_tracks, gap, track_alignment, layout_is_reversed, &total_offset, &seen_non_collapsed_track);
        }
    } else {
        for (tracks, 0..) |*track, index| {
            position_track(index, track, free_space, num_tracks, gap, track_alignment, layout_is_reversed, &total_offset, &seen_non_collapsed_track);
        }
    }
}

fn sum_base_sizes(tracks: []const GridTrack) f32 {
    var total: f32 = 0;
    for (tracks) |track| total += track.base_size;
    return total;
}

pub const AlignAndPositionResult = struct {
    contribution: geometry.Rect(f32),
    y: f32,
    height: f32,
    /// The item's first baseline from its final layout (clamped to the border box
    /// for scroll containers), for the container's own baseline (Taffy e77a7a8).
    baseline: ?f32,
};

/// Align and size a grid item into its final position
pub fn align_and_position_item(comptime Tree: type, tree_ref: *Tree,
    node: NodeId,
    order: u32,
    grid_area: geometry.Rect(f32),
    container_alignment_styles: geometry.InBothAbsAxis(AlignItems),
    baseline_shim: f32,
    direction: Direction,
    /// The container's border plus scrollbar gutters (its padding-box frame)
    padding_box_inset: geometry.Rect(f32),
    overflow_container: *const scrollable_overflow.ScrollableOverflowContainer,
    bubbled_candidates: *tree_layout.OofCandidates) !AlignAndPositionResult {
    const TreeApi = LayoutTree(Tree);
    const grid_area_size = geometry.F32Size{ .width = grid_area.right - grid_area.left, .height = grid_area.bottom - grid_area.top };

    const item_style = TreeApi.get_style(tree_ref, node);

    const overflow = item_style.get(.overflow);
    const contain = item_style.get(.contain);
    const scrollbar_width_value = item_style.get(.scrollbar_width);
    const aspect_ratio = item_style.get(.aspect_ratio);
    // Resolve writing-mode-relative self-start/self-end keywords against the item's own direction.
    const item_direction = item_style.get(.direction);
    // `auto` (null) self-alignment takes the container's `*-items` value.
    const justify_self = resolve_self_relative(item_style.get(.justify_self) orelse container_alignment_styles.horizontal, item_direction, direction, true);
    const align_self = resolve_self_relative(item_style.get(.align_self) orelse container_alignment_styles.vertical, item_direction, direction, false);

    const position = item_style.get(.position);
    const inset_horizontal = geometry.Line(?f32){
        .start = item_style.get(.inset).left.resolve_to_option(grid_area_size.width),
        .end = item_style.get(.inset).right.resolve_to_option(grid_area_size.width),
    };
    const inset_vertical = geometry.Line(?f32){
        .start = item_style.get(.inset).top.resolve_to_option(grid_area_size.height),
        .end = item_style.get(.inset).bottom.resolve_to_option(grid_area_size.height),
    };
    const padding = resolve_length_rect_or_zero(item_style.get(.padding), grid_area_size.width);
    const border = resolve_length_rect_or_zero(item_style.get(.border), grid_area_size.width);
    const padding_border_size = padding.add(border).sum_axes();

    const box_sizing_adjustment = if (item_style.get(.box_sizing) == .content_box) padding_border_size else geometry.F32Size{ .width = 0, .height = 0 };

    const size_style = item_style.get(.size);
    const inherent_size = maybe_add_optional_size(
        geometry.optional_f32_size_maybe_apply_aspect_ratio(resolve_dimension_size(size_style, grid_area_size), aspect_ratio),
        box_sizing_adjustment);
    const min_size = maybe_apply_aspect_ratio_optional(
        maybe_max_optional_size(
            maybe_or_optional_size(
                maybe_add_optional_size(resolve_lpa_size(item_style.get(.min_size), grid_area_size), box_sizing_adjustment),
                geometry.Size(?f32){ .width = padding_border_size.width, .height = padding_border_size.height }),
            padding_border_size),
        aspect_ratio);
    const max_size = maybe_add_optional_size(
        geometry.optional_f32_size_maybe_apply_aspect_ratio(resolve_lpa_size(item_style.get(.max_size), grid_area_size), aspect_ratio),
        box_sizing_adjustment);

    // Resolve default alignment styles if they are set on neither the parent or the node itself.
    // Note: if the child has a preferred aspect ratio but neither width or height are set, then
    // the width is stretched and the height is calculated from the width.
    // `normal` behaves as `start` for items with a definite (or keyword) size and
    // for replaced elements (which are not stretched), `stretch` otherwise.
    // https://www.w3.org/TR/css-grid-1/#grid-item-sizing
    const is_replaced = item_style.is_replaced();
    const horizontal_alignment = if (justify_self.keyword == .normal)
        (if (inherent_size.width != null or size_style.width.is_sizing_keyword() or is_replaced) AlignSelf.START else AlignSelf.STRETCH)
    else
        justify_self;
    const vertical_alignment = if (align_self.keyword == .normal)
        (if (inherent_size.height != null or size_style.height.is_sizing_keyword() or aspect_ratio != null or is_replaced) AlignSelf.START else AlignSelf.STRETCH)
    else
        align_self;
    const alignment_styles = geometry.InBothAbsAxis(AlignSelf){ .horizontal = horizontal_alignment, .vertical = vertical_alignment };

    // Note: This is not a bug. It is part of the CSS spec that both horizontal and vertical
    // margins resolve against the WIDTH of the grid area.
    const margin = geometry.Rect(?f32){
        .left = item_style.get(.margin).left.resolve_to_option(grid_area_size.width),
        .right = item_style.get(.margin).right.resolve_to_option(grid_area_size.width),
        .top = item_style.get(.margin).top.resolve_to_option(grid_area_size.width),
        .bottom = item_style.get(.margin).bottom.resolve_to_option(grid_area_size.width),
    };

    const minus_h_margins = math.f32_maybe_sub(math.f32_maybe_sub(grid_area_size.width, margin.left), margin.right);
    const minus_v_margins = math.f32_maybe_sub(math.f32_maybe_sub(math.f32_maybe_sub(grid_area_size.height, margin.top), margin.bottom), baseline_shim);
    const grid_area_minus_item_margins_size = geometry.F32Size{
        .width = @max(minus_h_margins, 0),
        .height = @max(minus_v_margins, 0),
    };

    // A size that is a sizing keyword either resolves to an exact size or is resolved
    // by measuring the item under the corresponding available space constraint.
    const keyword_width: ?sizing_keyword.SizingKeywordResolution = if (inherent_size.width == null) blk: {
        break :blk sizing_keyword.resolve_sizing_keyword(size_style.width, grid_area_minus_item_margins_size.width, grid_area_size.width);
    } else null;
    const keyword_height: ?sizing_keyword.SizingKeywordResolution = if (inherent_size.height == null) blk: {
        break :blk sizing_keyword.resolve_sizing_keyword(size_style.height, grid_area_minus_item_margins_size.height, grid_area_size.height);
    } else null;

    // If both axes need to be measured then resolve them with a single measure call
    var keyword_measured_size = geometry.Size(?f32){ .width = null, .height = null };
    if (keyword_width != null and keyword_height != null) {
        if (keyword_width.? == .measure and keyword_height.? == .measure and !position.is_out_of_flow()) {
            const measured = try TreeApi.measure_child_size_both(tree_ref, 
                node,
                .{ .width = null, .height = null },
                map_optional_some(grid_area_size),
                .{ .width = keyword_width.?.measure, .height = keyword_height.?.measure },
                .inherent_size,
                .{ .start = false, .end = false });
            keyword_measured_size = .{ .width = measured.width, .height = measured.height };
        }
    }

    // If node is absolutely positioned and width is not set explicitly, then deduce it
    // from left, right and container_content_box if both are set.
    var width: ?f32 = inherent_size.width;
    if (width == null) {
        // Apply width derived from both the left and right properties of an absolutely
        // positioned element being set
        if (position.is_out_of_flow()) {
            if (inset_horizontal.start != null and inset_horizontal.end != null) {
                width = @max(grid_area_minus_item_margins_size.width - inset_horizontal.start.? - inset_horizontal.end.?, 0);
            }
        }
    }
    if (width == null) {
        if (keyword_width) |resolution| {
            width = switch (resolution) {
                .exact => |value| value,
                .measure => |available_width| keyword_measured_size.width orelse (try TreeApi.measure_child_size(tree_ref, 
                    node,
                    .{ .width = null, .height = null },
                    map_optional_some(grid_area_size),
                    .{ .width = available_width, .height = .{ .definite = grid_area_minus_item_margins_size.height } },
                    .inherent_size,
                    .horizontal,
                    .{ .start = false, .end = false })),
            };
        }
    }
    if (width == null) {
        // Apply width based on stretch alignment
        if (margin.left != null and margin.right != null and is_stretch(alignment_styles.horizontal) and !position.is_out_of_flow()) {
            width = grid_area_minus_item_margins_size.width;
        }
    }

    // Reapply aspect ratio after stretch and absolute position width adjustments
    var size = geometry.optional_f32_size_maybe_apply_aspect_ratio(.{ .width = width, .height = inherent_size.height }, aspect_ratio);
    width = size.width;
    var height = size.height;

    if (height == null) {
        if (position.is_out_of_flow()) {
            if (inset_vertical.start != null and inset_vertical.end != null) {
                height = @max(grid_area_minus_item_margins_size.height - inset_vertical.start.? - inset_vertical.end.?, 0);
            }
        }
    }
    if (height == null) {
        if (keyword_height) |resolution| {
            height = switch (resolution) {
                .exact => |value| value,
                .measure => |available_height| keyword_measured_size.height orelse (try TreeApi.measure_child_size(tree_ref, 
                    node,
                    .{ .width = width, .height = null },
                    map_optional_some(grid_area_size),
                    .{
                        .width = if (width) |w| .{ .definite = w } else .{ .definite = grid_area_minus_item_margins_size.width },
                        .height = available_height,
                    },
                    .inherent_size,
                    .vertical,
                    .{ .start = false, .end = false })),
            };
        }
    }
    if (height == null) {
        if (margin.top != null and margin.bottom != null and is_stretch(alignment_styles.vertical) and !position.is_out_of_flow()) {
            height = grid_area_minus_item_margins_size.height;
        }
    }
    // Reapply aspect ratio after stretch and absolute position height adjustments
    size = geometry.optional_f32_size_maybe_apply_aspect_ratio(.{ .width = width, .height = height }, aspect_ratio);
    width = size.width;
    height = size.height;

    // Clamp size by min and max width/height
    size = optional_size_maybe_clamp(.{ .width = width, .height = height }, min_size, max_size);
    width = size.width;
    height = size.height;

    // Layout node
    const layout_size: geometry.Size(?f32) = if (position.is_out_of_flow() and (width == null or height == null)) blk: {
        const measured = try TreeApi.measure_child_size_both(tree_ref, 
            node,
            .{ .width = width, .height = height },
            map_optional_some(grid_area_size),
            map_optional_definite(grid_area_minus_item_margins_size),
            .inherent_size,
            .{ .start = false, .end = false });
        break :blk .{ .width = measured.width, .height = measured.height };
    } else .{ .width = width, .height = height };

    var layout_output = try TreeApi.perform_child_layout(tree_ref, 
        node,
        layout_size,
        map_optional_some(grid_area_size),
        map_optional_definite(grid_area_minus_item_margins_size),
        .inherent_size,
        .{ .start = false, .end = false });

    // Resolve final size
    const resolved_final_size = layout_size.unwrap_or(layout_output.size);
    const final_size = geometry.F32Size{
        .width = math.f32_maybe_clamp(resolved_final_size.width, min_size.width, max_size.width),
        .height = math.f32_maybe_clamp(resolved_final_size.height, min_size.height, max_size.height),
    };
    width = final_size.width;
    height = final_size.height;

    const horizontal_result = align_item_within_area(
        .{ .start = grid_area.left, .end = grid_area.right },
        alignment_styles.horizontal,
        width.?,
        position,
        inset_horizontal,
        margin.horizontal_components(),
        0.0,
        direction);
    const vertical_result = align_item_within_area(
        .{ .start = grid_area.top, .end = grid_area.bottom },
        alignment_styles.vertical,
        height.?,
        position,
        inset_vertical,
        margin.vertical_components(),
        baseline_shim,
        .ltr);

    const scrollbar_size = geometry.F32Size{
        .width = if (overflow.y == .scroll) scrollbar_width_value else 0,
        .height = if (overflow.x == .scroll) scrollbar_width_value else 0,
    };

    const resolved_margin = geometry.Rect(f32){
        .left = horizontal_result.margin.start,
        .right = horizontal_result.margin.end,
        .top = vertical_result.margin.start,
        .bottom = vertical_result.margin.end,
    };

    // Bubble out-of-flow candidates from the item's subtree, translating anchors from
    // item-relative to container-relative coordinates
    var item_candidates = layout_output.oof_candidates;
    layout_output.oof_candidates = .empty;
    if (item_candidates.items.len != 0) {
        oof.translateCandidates(&item_candidates, .{ .x = horizontal_result.offset, .y = vertical_result.offset });
        try oof.appendCandidates(tree_ref.scratch_allocator(), bubbled_candidates, &item_candidates);
    }

    try TreeApi.set_unrounded_layout(tree_ref, node, .{
        .order = order,
        .location = .{ .x = horizontal_result.offset, .y = vertical_result.offset },
        .size = .{ .width = width.?, .height = height.? },
        .scrollable_overflow_rect = layout_output.scrollable_overflow_rect,
        .scrollbar_size = scrollbar_size,
        .padding = padding,
        .border = border,
        .margin = resolved_margin,
    });

    // Contributions to the container's scrollable overflow use physical
    // coordinates in its padding-box frame (Taffy c256056).
    const contribution_location = geometry.F32Point{ .x = horizontal_result.offset - padding_box_inset.left, .y = vertical_result.offset - padding_box_inset.top };
    const contribution = scrollable_overflow.compute_scrollable_overflow_contribution(
        contribution_location,
        .{ .width = width.?, .height = height.? },
        layout_output.scrollable_overflow_rect.rect(),
        border,
        overflow,
        contain,
        overflow_container,
        resolved_margin);

    const item_baseline: ?f32 = if (layout_output.baselines.first) |b|
        (if (overflow.y.is_scroll_container()) @max(@min(b, height.?), 0) else b)
    else
        null;
    // The y position recorded for the container's baseline excludes the relative
    // offset, which does not move the container's baseline (Taffy 8bb96a2).
    const y_without_relative_offset = vertical_result.offset - relative_offset(position, inset_vertical, .ltr);
    return .{ .contribution = contribution, .y = y_without_relative_offset, .height = height.?, .baseline = item_baseline };
}

fn is_stretch(value: AlignItems) bool {
    return value.keyword == .stretch and value.safety == .default;
}

/// Taffy `AlignItems::resolve_self_relative`. Local copy because the shared
/// style method cannot annotate the enum literal result under runtime flow.
fn resolve_self_relative(value: AlignItems, item_direction: Direction, container_direction: Direction, axis_is_inline: bool) AlignItems {
    const flip = axis_is_inline and item_direction != container_direction;
    const resolved: AlignItemsKeyword = switch (value.keyword) {
        .self_start => if (flip) .end else .start,
        .self_end => if (flip) .start else .end,
        else => value.keyword,
    };
    return .{ .keyword = resolved, .safety = value.safety };
}

const AlignResult = struct {
    offset: f32,
    margin: geometry.Line(f32),
};

/// Align and size a grid item along a single axis
pub fn align_item_within_area(
    grid_area: geometry.Line(f32),
    alignment_style: AlignSelf,
    resolved_size: f32,
    position: Position,
    inset: geometry.Line(?f32),
    margin: geometry.Line(?f32),
    baseline_shim: f32,
    direction: Direction) AlignResult {
    // Calculate grid area dimension in the axis
    const non_auto_margin = geometry.Line(f32){
        .start = (margin.start orelse 0) + baseline_shim,
        .end = margin.end orelse 0,
    };
    const grid_area_size = @max(grid_area.end - grid_area.start, 0);
    const free_space = @max(grid_area_size - resolved_size - non_auto_margin.sum(), 0);

    // Expand auto margins to fill available space
    const auto_margin_count: u8 = @as(u8, if (margin.start == null) 1 else 0) + @as(u8, if (margin.end == null) 1 else 0);
    const auto_margin_size: f32 = if (auto_margin_count > 0) free_space / @as(f32, @floatFromInt(auto_margin_count)) else 0;
    const resolved_margin = geometry.Line(f32){
        .start = (margin.start orelse auto_margin_size) + baseline_shim,
        .end = margin.end orelse auto_margin_size,
    };

    const overflows = resolved_size + non_auto_margin.sum() > grid_area_size;
    const alignment_keyword = alignment.resolve_self_alignment_safety(alignment_style, overflows);

    // Compute offset in the axis
    const alignment_based_offset: f32 = switch (alignment_keyword) {
        // TODO: Add support for baseline alignment. For now we treat it as "start".
        .start, .flex_start, .baseline, .stretch => if (direction.is_rtl())
            grid_area_size - resolved_size - resolved_margin.end
        else
            resolved_margin.start,
        .end, .flex_end => if (direction.is_rtl())
            resolved_margin.start
        else
            grid_area_size - resolved_size - resolved_margin.end,
        .center => (grid_area_size - resolved_size + resolved_margin.start - resolved_margin.end) / 2,
        .normal, .self_start, .self_end => unreachable,
    };

    const offset_within_area: f32 = if (position.is_out_of_flow()) blk: {
        if (inset.start != null and inset.end != null) {
            break :blk if (direction.is_rtl())
                grid_area_size - inset.end.? - resolved_size - non_auto_margin.end
            else
                inset.start.? + non_auto_margin.start;
        }
        if (inset.start) |start_value| break :blk start_value + non_auto_margin.start;
        if (inset.end) |end_value| break :blk grid_area_size - end_value - resolved_size - non_auto_margin.end;
        break :blk alignment_based_offset;
    } else alignment_based_offset;

    const start = grid_area.start + offset_within_area + relative_offset(position, inset, direction);
    return .{ .offset = start, .margin = resolved_margin };
}

/// The offset `position: relative` applies in one axis.
fn relative_offset(position: style.Position, inset: geometry.Line(?f32), direction: style.Direction) f32 {
    if (position != .relative) return 0;
    const relative_inset: ?f32 = if (direction.is_rtl())
        (if (inset.end) |pos| -pos else inset.start)
    else
        (inset.start orelse if (inset.end) |pos| -pos else null);
    return relative_inset orelse 0;
}

inline fn resolve_length_rect_or_zero(value: geometry.Rect(style.dimension.LengthPercentage), basis: ?f32) geometry.Rect(f32) {
    const resolved_basis = basis orelse 0;
    return .{
        .left = value.left.resolve(resolved_basis),
        .right = value.right.resolve(resolved_basis),
        .top = value.top.resolve(resolved_basis),
        .bottom = value.bottom.resolve(resolved_basis),
    };
}

inline fn resolve_dimension_size(value: geometry.Size(style.dimension.Dimension), basis: geometry.F32Size) geometry.Size(?f32) {
    return .{ .width = value.width.resolve(basis.width), .height = value.height.resolve(basis.height) };
}

inline fn resolve_lpa_size(value: geometry.Size(style.dimension.LengthPercentageAuto), basis: geometry.F32Size) geometry.Size(?f32) {
    return .{ .width = value.width.resolve_to_option(basis.width), .height = value.height.resolve_to_option(basis.height) };
}

fn maybe_add_optional_size(value: geometry.Size(?f32), add: geometry.F32Size) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| v + add.width else null,
        .height = if (value.height) |v| v + add.height else null,
    };
}

fn maybe_max_optional_size(value: geometry.Size(?f32), floor: geometry.F32Size) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| @max(v, floor.width) else null,
        .height = if (value.height) |v| @max(v, floor.height) else null,
    };
}

fn maybe_or_optional_size(value: geometry.Size(?f32), alternative: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = value.width orelse alternative.width, .height = value.height orelse alternative.height };
}

fn maybe_apply_aspect_ratio_optional(value: geometry.Size(?f32), aspect_ratio: ?f32) geometry.Size(?f32) {
    return geometry.optional_f32_size_maybe_apply_aspect_ratio(value, aspect_ratio);
}

fn optional_size_maybe_clamp(value: geometry.Size(?f32), minimum: geometry.Size(?f32), maximum: geometry.Size(?f32)) geometry.Size(?f32) {
    return math.optional_size_maybe_clamp(value, minimum, maximum);
}

fn map_optional_some(value: geometry.F32Size) geometry.Size(?f32) {
    return .{ .width = value.width, .height = value.height };
}

fn map_optional_definite(value: geometry.F32Size) geometry.Size(AvailableSpace) {
    return .{ .width = .{ .definite = value.width }, .height = .{ .definite = value.height } };
}

test "normal alignment does not stretch replaced grid items" {
    const testing = std.testing;
    const zafi = @import("../../root.zig");
    var t = zafi.Tree.init(testing.allocator);
    defer t.deinit();
    var context = zafi.testing.TestNodeContext.fixed(.{ .width = 20, .height = 10 });
    const item = try t.new_leaf_with_context(.{ .item_is_replaced = true }, @ptrCast(&context));
    const track = [_]zafi.GridTemplateComponent{.{ .single = zafi.TrackSizingFunction.from_length(100) }};
    const root = try t.new_with_children(.{ .display = .grid, .grid_template_columns = &track, .grid_template_rows = &track }, &.{item});
    try t.compute_layout_with_measure(root, .{ .width = .max_content, .height = .max_content }, zafi.testing.fixture_measure_function);
    const l = try t.layout_of(item);
    try testing.expectEqual(@as(f32, 20), l.size.width);
    try testing.expectEqual(@as(f32, 10), l.size.height);
}
