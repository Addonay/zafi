//! Direct port of Taffy's `compute/grid/types/grid_item.rs`.
//!
//! A `GridItem` captures the parts of a grid child's style that the track
//! sizing algorithm needs, plus the per-run intrinsic contribution caches.
//! The intrinsic contribution methods call back into the layout tree_ref through
//! the same measure APIs used by Taffy's `LayoutPartialTreeExt`.

const std = @import("std");
const calc_resolver = @import("../../../style/calc.zig");
const geometry = @import("../../../geometry.zig");
const style = @import("../../../style/root.zig");
const AvailableSpace = @import("../../../style/available_space.zig").AvailableSpace;
const math = @import("../../../util/math.zig");
const sizing_keyword = @import("../../common/sizing_keyword.zig");
const NodeId = @import("../../../tree/node.zig").NodeId;
const layout = @import("../../../tree/layout.zig");
const tree_layout = layout;
const coordinates = @import("coordinates.zig");
const grid_track = @import("grid_track.zig");
const LayoutTree = @import("../../../tree/interfaces.zig").LayoutTree;

pub const OriginZeroLine = coordinates.OriginZeroLine;
pub const GridTrack = grid_track.GridTrack;

/// A function that computes an estimate of an other-axis track's size.
/// Mirrors Taffy's `EstimateFunction: Fn(&GridTrack, Option<f32>, &Tree) -> Option<f32>`.
///
/// Parameterised by the tree type so the same estimate function can be used with
/// any `LayoutTree` implementation.
pub fn TrackSizeEstimateFn(comptime Tree: type) type {
    return *const fn (GridTrack, ?f32, *Tree) ?f32;
}

pub const TrackRange = struct { start: usize, end: usize };

/// An in-flow grid child together with its index in the container's full child list.
///
/// `source_order` is the document child index (not the index within the filtered
/// in-flow list), so `GridItem.source_order` can be matched against `child_count`
/// iterations when interleaving out-of-flow candidates in document order.
pub const InFlowChild = struct {
    node: NodeId,
    source_order: u16,
};

/// The known_dimensions computed for a grid item for a given grid area size.
pub const KnownDimensionsCacheEntry = struct {
    grid_area_size: geometry.Size(?f32),
    known_dimensions: geometry.Size(?f32),
};

pub const GridItem = struct {
    /// The id of the node that this item represents
    node: NodeId,

    /// The order of the item in the children array. Track sizing sorts items;
    /// this field allows sorting back to original order for final positioning.
    source_order: u16,

    /// The item's definite row-start and row-end in origin-zero coordinates
    row: geometry.Line(OriginZeroLine),
    /// The item's definite column-start and column-end in origin-zero coordinates
    column: geometry.Line(OriginZeroLine),

    /// Is it a compressible replaced element (replaced element or form control)?
    is_compressible_replaced: bool,
    /// Is it a replaced element proper? `normal` alignment does not stretch it.
    is_replaced: bool,
    /// The item's overflow style
    overflow: geometry.Point(style.Overflow),
    /// The item's box_sizing style
    box_sizing: style.BoxSizing,
    /// The item's size style
    size: geometry.Size(style.dimension.Dimension),
    /// The item's min_size style
    min_size: geometry.Size(style.dimension.LengthPercentageAuto),
    /// The item's max_size style
    max_size: geometry.Size(style.dimension.LengthPercentageAuto),
    /// The item's aspect_ratio style
    aspect_ratio: ?f32,
    /// The item's padding style
    padding: geometry.Rect(style.dimension.LengthPercentage),
    /// The item's border style
    border: geometry.Rect(style.dimension.LengthPercentage),
    /// The item's margin style
    margin: geometry.Rect(style.dimension.LengthPercentageAuto),
    /// The item's align_self property, or the parent's align_items property if not set
    align_self: style.alignment.AlignSelf,
    /// The item's justify_self property, or the parent's justify_items property if not set
    justify_self: style.alignment.JustifySelf,
    /// The item's first baseline (horizontal)
    baseline: ?f32 = null,
    /// Shim for baseline alignment that acts like an extra top margin
    baseline_shim: f32 = 0,

    /// The item's definite row-start and row-end as indexes into the GridTrackVec
    row_indexes: geometry.Line(u16),
    /// The item's definite column-start and column-end as indexes into the GridTrackVec
    column_indexes: geometry.Line(u16),

    /// Whether the item crosses a flexible row
    crosses_flexible_row: bool = false,
    /// Whether the item crosses a flexible column
    crosses_flexible_column: bool = false,
    /// Whether the item crosses an intrinsic row
    crosses_intrinsic_row: bool = false,
    /// Whether the item crosses an intrinsic column
    crosses_intrinsic_column: bool = false,

    // Caches for intrinsic size computation. These caches are only valid for
    // a single run of the track-sizing algorithm.
    grid_area_size_cache: ?geometry.Size(?f32) = null,
    /// The known_dimensions passed to the child when computing its intrinsic
    /// contributions, with the grid area size they were computed for. Must be
    /// cleared whenever `baseline_shim` changes.
    known_dimensions_cache: ?KnownDimensionsCacheEntry = null,
    min_content_contribution_cache: geometry.Size(?f32) = .{ .width = null, .height = null },
    minimum_contribution_cache: geometry.Size(?f32) = .{ .width = null, .height = null },
    max_content_contribution_cache: geometry.Size(?f32) = .{ .width = null, .height = null },

    /// Final y position. Used to compute baseline alignment for the container.
    y_position: f32 = 0,
    /// Final height. Used to compute baseline alignment for the container.
    height: f32 = 0,

    /// Out-of-flow candidates bubbled out of this item's subtree (anchors relative
    /// to the container's border box).
    oof_candidates: tree_layout.OofCandidates = .empty,

    pub fn new_with_placement_style_and_order(
        node: NodeId,
        col_span: geometry.Line(OriginZeroLine),
        row_span: geometry.Line(OriginZeroLine),
        item_style: *const style.Style,
        parent_align_items: style.alignment.AlignItems,
        parent_justify_items: style.alignment.AlignItems,
        source_order: u16) GridItem {
        return .{
            .node = node,
            .source_order = source_order,
            .row = row_span,
            .column = col_span,
            .is_compressible_replaced = item_style.is_compressible_replaced(),
            .is_replaced = item_style.is_replaced(),
            .overflow = item_style.overflow,
            .box_sizing = item_style.box_sizing,
            .size = item_style.size,
            .min_size = item_style.min_size,
            .max_size = item_style.max_size,
            .aspect_ratio = item_style.aspect_ratio,
            .padding = item_style.padding,
            .border = item_style.border,
            .margin = item_style.margin,
            .align_self = item_style.align_self orelse parent_align_items,
            .justify_self = item_style.justify_self orelse parent_justify_items,
            .row_indexes = .{ .start = 0, .end = 0 }, // Properly initialised later
            .column_indexes = .{ .start = 0, .end = 0 }, // Properly initialised later
        };
    }

    /// Whether the item has an auto margin in the block axis
    pub fn has_auto_block_margin(self: GridItem) bool {
        return self.margin.top.is_auto() or self.margin.bottom.is_auto();
    }

    /// Whether the item's block size depends on the size of its row(s), creating a cyclic
    /// dependency with baseline alignment.
    pub fn has_cyclic_block_size_dependency(self: GridItem) bool {
        return self.size.height.into_raw().uses_percentage() and (self.crosses_intrinsic_row or self.crosses_flexible_row);
    }

    /// Returns true if the item participates in baseline alignment.
    pub fn participates_in_baseline_alignment(self: GridItem) bool {
        return self.align_self.keyword == .baseline and !self.has_auto_block_margin() and !self.has_cyclic_block_size_dependency();
    }

    /// This item's placement in the specified axis in OriginZero coordinates
    pub fn placement(self: GridItem, axis: geometry.AbstractAxis) geometry.Line(OriginZeroLine) {
        return if (axis == .block) self.row else self.column;
    }

    /// This item's placement in the specified axis as GridTrackVec indices
    pub fn placement_indexes(self: GridItem, axis: geometry.AbstractAxis) geometry.Line(u16) {
        return if (axis == .block) self.row_indexes else self.column_indexes;
    }

    /// A range indexing into the GridTrackVec in the specified axis covering
    /// all the tracks that this item spans, excluding the bounding lines.
    pub fn track_range_excluding_lines(self: GridItem, axis: geometry.AbstractAxis) TrackRange {
        const indexes = self.placement_indexes(axis);
        return .{ .start = @as(usize, indexes.start) + 1, .end = @as(usize, indexes.end) };
    }

    /// Whether any track spanned by this item in the specified axis satisfies `predicate`
    pub fn spans_track_matching(self: GridItem, axis: geometry.AbstractAxis, axis_tracks: []const GridTrack, predicate: *const fn (GridTrack) bool) bool {
        const range = self.track_range_excluding_lines(axis);
        if (range.end > axis_tracks.len or range.start >= range.end) return false;
        for (axis_tracks[range.start..range.end]) |track| {
            if (predicate(track)) return true;
        }
        return false;
    }

    /// The number of tracks that this item spans in the specified axis
    pub fn span(self: GridItem, axis: geometry.AbstractAxis) u16 {
        const placement_value = self.placement(axis);
        return coordinates.line_origin_zero_span(placement_value);
    }

    /// Whether the item crosses a flexible track in the specified axis
    pub fn crosses_flexible_track(self: GridItem, axis: geometry.AbstractAxis) bool {
        return if (axis == .inline_axis) self.crosses_flexible_column else self.crosses_flexible_row;
    }

    /// Whether the item crosses an intrinsic track in the specified axis
    pub fn crosses_intrinsic_track(self: GridItem, axis: geometry.AbstractAxis) bool {
        return if (axis == .inline_axis) self.crosses_intrinsic_column else self.crosses_intrinsic_row;
    }

    /// The upper limit used to calculate an item's limited min-/max-content
    /// contribution: the sum of the fixed max track sizing functions of the
    /// spanned tracks, or null if any spanned track is not fixed.
    pub fn spanned_track_limit(self: GridItem, axis: geometry.AbstractAxis, axis_tracks: []const GridTrack, axis_parent_size: ?f32) ?f32 {
        const range = self.track_range_excluding_lines(axis);
        if (range.end > axis_tracks.len or range.start >= range.end) return null;
        const spanned_tracks = axis_tracks[range.start..range.end];
        var limit: f32 = 0;
        for (spanned_tracks) |track| {
            const value = track.max_track_sizing_function.definite_limit(axis_parent_size) orelse return null;
            limit += value;
        }
        return limit;
    }

    /// Similar to `spanned_track_limit`, but excludes FitContent arguments.
    pub fn spanned_fixed_track_limit(self: GridItem, axis: geometry.AbstractAxis, axis_tracks: []const GridTrack, axis_parent_size: ?f32) ?f32 {
        const range = self.track_range_excluding_lines(axis);
        if (range.end > axis_tracks.len or range.start >= range.end) return null;
        const spanned_tracks = axis_tracks[range.start..range.end];
        var limit: f32 = 0;
        for (spanned_tracks) |track| {
            const value = track.max_track_sizing_function.definite_value(axis_parent_size) orelse return null;
            limit += value;
        }
        return limit;
    }

    /// Compute the known_dimensions to be passed to the child sizing functions,
    /// applying stretch alignment so percentage sizes further down the tree_ref
    /// resolve properly.
    fn known_dimensions(self: *const GridItem, comptime Tree: type, tree_ref: *Tree, area_size: geometry.Size(?f32)) geometry.Size(?f32) {
        const margins = self.margins_axis_sums_with_baseline_shims(Tree, area_size.width, tree_ref);

        const aspect_ratio = self.aspect_ratio;
        const padding = resolve_rect_length_percentage_or_zero(Tree, self.padding, area_size.width, tree_ref);
        const border = resolve_rect_length_percentage_or_zero(Tree, self.border, area_size.width, tree_ref);
        const padding_border_size = padding.add(border).sum_axes();
        const box_sizing_adjustment = if (self.box_sizing == .content_box) padding_border_size else geometry.F32Size{ .width = 0, .height = 0 };
        const inherent_size = maybe_add_size(
            geometry.optional_f32_size_maybe_apply_aspect_ratio(resolve_dimension_size(self.size, area_size), aspect_ratio),
            box_sizing_adjustment);
        const raw_min_size = maybe_add_size(
            geometry.optional_f32_size_maybe_apply_aspect_ratio(resolve_lpa_size(self.min_size, area_size), aspect_ratio),
            box_sizing_adjustment);
        // The size of the item is floored by its padding and border
        const min_size = geometry.Size(?f32){
            .width = @max(raw_min_size.width orelse padding_border_size.width, padding_border_size.width),
            .height = @max(raw_min_size.height orelse padding_border_size.height, padding_border_size.height),
        };
        const max_size = maybe_add_size(
            geometry.optional_f32_size_maybe_apply_aspect_ratio(resolve_lpa_size(self.max_size, area_size), aspect_ratio),
            box_sizing_adjustment);

        const grid_area_minus_item_margins_size = maybe_max_size(
            maybe_sub_size(area_size, geometry.F32Size{ .width = margins.width, .height = margins.height }),
            geometry.F32Size{ .width = 0, .height = 0 });

        // If node is absolutely positioned and width is not set explicitly, then deduce it
        // from left, right and container_content_box if both are set.
        var width = inherent_size.width;
        if (width == null) {
            // A width that is a sizing keyword is not auto, so it does not stretch. The stretch
            // keyword resolves to an exact width; the others resolve during content measurement.
            if (self.size.width.is_sizing_keyword()) {
                if (sizing_keyword.resolve_sizing_keyword(self.size.width, grid_area_minus_item_margins_size.width, area_size.width)) |resolution| {
                    if (resolution == .exact) width = resolution.exact;
                }
            } else if (!self.margin.left.is_auto() and !self.margin.right.is_auto() and align_is_stretch(self.justify_self, self.is_replaced)) {
                width = grid_area_minus_item_margins_size.width;
            }
        }
        // Reapply aspect ratio after stretch and absolute position width adjustments
        var size = geometry.optional_f32_size_maybe_apply_aspect_ratio(.{ .width = width, .height = inherent_size.height }, aspect_ratio);

        var height = size.height;
        if (height == null) {
            if (self.size.height.is_sizing_keyword()) {
                if (sizing_keyword.resolve_sizing_keyword(self.size.height, grid_area_minus_item_margins_size.height, area_size.height)) |resolution| {
                    if (resolution == .exact) height = resolution.exact;
                }
            } else if (!self.margin.top.is_auto() and !self.margin.bottom.is_auto() and align_is_stretch(self.align_self, self.is_replaced)) {
                height = grid_area_minus_item_margins_size.height;
            }
        }
        // Reapply aspect ratio after stretch and absolute position height adjustments
        size = geometry.optional_f32_size_maybe_apply_aspect_ratio(.{ .width = width, .height = height }, aspect_ratio);

        // Clamp size by min and max width/height
        return optional_size_maybe_clamp(size, min_size, max_size);
    }

    /// `known_dimensions` for the given grid area size, from the cache when the
    /// area size matches. Min- and max-content contributions share it.
    inline fn known_dimensions_cached(self: *GridItem, comptime Tree: type, tree_ref: *Tree, area_size: geometry.Size(?f32)) geometry.Size(?f32) {
        if (self.known_dimensions_cache) |entry| {
            if (entry.grid_area_size.width == area_size.width and entry.grid_area_size.height == area_size.height)
                return entry.known_dimensions;
        }
        const known = self.known_dimensions(Tree, tree_ref, area_size);
        self.known_dimensions_cache = .{ .grid_area_size = area_size, .known_dimensions = known };
        return known;
    }

    /// Returns the grid area's size in the specified axis when every spanned
    /// track has a definite fixed size.
    pub fn grid_area_size(self: *const GridItem, comptime Tree: type,
        axis: geometry.AbstractAxis,
        axis_tracks: []const GridTrack,
        other_axis_tracks: []const GridTrack,
        available_space: geometry.Size(?f32),
        get_track_size_estimate: TrackSizeEstimateFn(Tree),
        tree_ref: *Tree) geometry.Size(?f32) {
        var size = geometry.Size(?f32){ .width = null, .height = null };
        const axis_range = self.track_range_excluding_lines(axis);
        if (axis_range.end <= axis_tracks.len and axis_range.start < axis_range.end) {
            var total: f32 = 0;
            var definite = true;
            for (axis_tracks[axis_range.start..axis_range.end]) |track| {
                const min_size = track.min_track_sizing_function.definite_value(available_space.get(axis));
                const max_size = track.max_track_sizing_function.definite_value(available_space.get(axis));
                if (min_size != null and max_size != null and min_size.? == max_size.?) {
                    total += track.base_size;
                } else {
                    definite = false;
                    break;
                }
            }
            if (definite) size.set(axis, total);
        }

        const other_range = self.track_range_excluding_lines(axis.other());
        if (other_range.end <= other_axis_tracks.len and other_range.start < other_range.end) {
            var total: f32 = 0;
            var definite = true;
            for (other_axis_tracks[other_range.start..other_range.end]) |track| {
                if (get_track_size_estimate(track, available_space.get(axis.other()), tree_ref)) |track_size| {
                    total += track_size + track.content_alignment_adjustment;
                } else {
                    definite = false;
                    break;
                }
            }
            if (definite) size.set(axis.other(), total);
        }
        return size;
    }

    /// Retrieve the grid area size from the cache or compute it using the passed parameters
    pub fn grid_area_size_cached(self: *GridItem, comptime Tree: type,
        axis: geometry.AbstractAxis,
        axis_tracks: []const GridTrack,
        other_axis_tracks: []const GridTrack,
        available_space: geometry.Size(?f32),
        get_track_size_estimate: TrackSizeEstimateFn(Tree),
        tree_ref: *Tree) geometry.Size(?f32) {
        if (self.grid_area_size_cache) |cached| return cached;
        const result = self.grid_area_size(Tree, axis, axis_tracks, other_axis_tracks, available_space, get_track_size_estimate, tree_ref);
        self.grid_area_size_cache = result;
        return result;
    }

    /// Compute the item's resolved margins for size contributions. Horizontal percentage
    /// margins always resolve to zero if the container size is indefinite.
    pub fn margins_axis_sums_with_baseline_shims(self: *const GridItem, comptime Tree: type, inner_node_width: ?f32, tree_ref: *Tree) geometry.F32Size {
        const left = self.margin.left.resolve(0) orelse 0;
        const right = self.margin.right.resolve(0) orelse 0;
        const top = if (inner_node_width) |basis| (self.margin.top.resolve(basis) orelse 0) else (self.margin.top.resolve(0) orelse 0);
        const bottom = if (inner_node_width) |basis| (self.margin.bottom.resolve(basis) orelse 0) else (self.margin.bottom.resolve(0) orelse 0);
        _ = tree_ref;
        return .{
            .width = left + right,
            .height = top + bottom + self.baseline_shim,
        };
    }

    /// Compute the item's min content contribution from the provided parameters
    pub fn min_content_contribution(self: *GridItem, comptime Tree: type,
        axis: geometry.AbstractAxis,
        tree_ref: *Tree,
        grid_area_size_value: geometry.Size(?f32),
        available_space: geometry.Size(?f32)) f32 {
        const known = self.known_dimensions_cached(Tree, tree_ref, grid_area_size_value);
        // A size already known in the measured axis is the contribution: no need to call into the child.
        if (known.get(axis)) |size| return size;
        return LayoutTree(Tree).measure_child_size(
            tree_ref,
            self.node,
            known,
            grid_area_size_value,
            self.keyword_adjusted_available_space(Tree, grid_area_size_value, map_available_space(self.available_space_minus_margins(grid_area_size_value, available_space), .min_content), tree_ref),
            .inherent_size,
            axis.as_abs_naive(),
            .{ .start = false, .end = false }) catch @panic("zafi: grid item min content measurement failed");
    }

    /// Retrieve the item's min content contribution from the cache or compute it
    pub fn min_content_contribution_cached(self: *GridItem, comptime Tree: type,
        axis: geometry.AbstractAxis,
        tree_ref: *Tree,
        grid_area_size_value: geometry.Size(?f32),
        available_space: geometry.Size(?f32)) f32 {
        if (self.min_content_contribution_cache.get(axis)) |cached| return cached;
        const size = self.min_content_contribution(Tree, axis, tree_ref, grid_area_size_value, available_space);
        self.min_content_contribution_cache.set(axis, size);
        return size;
    }

    /// Compute the item's max content contribution from the provided parameters
    pub fn max_content_contribution(self: *GridItem, comptime Tree: type,
        axis: geometry.AbstractAxis,
        tree_ref: *Tree,
        grid_area_size_value: geometry.Size(?f32),
        available_space: geometry.Size(?f32)) f32 {
        const known = self.known_dimensions_cached(Tree, tree_ref, grid_area_size_value);
        // A size already known in the measured axis is the contribution: no need to call into the child.
        if (known.get(axis)) |size| return size;
        return LayoutTree(Tree).measure_child_size(
            tree_ref,
            self.node,
            known,
            grid_area_size_value,
            self.keyword_adjusted_available_space(Tree, grid_area_size_value, map_available_space(self.available_space_minus_margins(grid_area_size_value, available_space), .max_content), tree_ref),
            .inherent_size,
            axis.as_abs_naive(),
            .{ .start = false, .end = false }) catch @panic("zafi: grid item max content measurement failed");
    }

    /// Retrieve the item's max content contribution from the cache or compute it
    pub fn max_content_contribution_cached(self: *GridItem, comptime Tree: type,
        axis: geometry.AbstractAxis,
        tree_ref: *Tree,
        grid_area_size_value: geometry.Size(?f32),
        available_space: geometry.Size(?f32)) f32 {
        if (self.max_content_contribution_cache.get(axis)) |cached| return cached;
        const size = self.max_content_contribution(Tree, axis, tree_ref, grid_area_size_value, available_space);
        self.max_content_contribution_cache.set(axis, size);
        return size;
    }

    /// Subtract the item's margins (and baseline shim) from the definite axes of
    /// the space available to its margin box. As in final layout, margins resolve
    /// against the grid area's width and `auto` margins count as zero.
    inline fn available_space_minus_margins(self: *const GridItem, area_size: geometry.Size(?f32), available_space: geometry.Size(?f32)) geometry.Size(?f32) {
        if (available_space.width == null and available_space.height == null) return available_space;
        const basis = area_size.width orelse 0;
        const left = self.margin.left.resolve(basis) orelse 0;
        const right = self.margin.right.resolve(basis) orelse 0;
        const top = self.margin.top.resolve(basis) orelse 0;
        const bottom = self.margin.bottom.resolve(basis) orelse 0;
        return .{
            .width = if (available_space.width) |w| @max(w - left - right, 0) else null,
            .height = if (available_space.height) |h| @max(h - top - bottom - self.baseline_shim, 0) else null,
        };
    }

    /// Override the available_space space in each axis whose size style is a sizing
    /// keyword that measures the item under a specific available_space space constraint.
    fn keyword_adjusted_available_space(self: *const GridItem, comptime Tree: type,
        grid_area_size_value: geometry.Size(?f32),
        available_space: geometry.Size(AvailableSpace),
        tree_ref: *Tree) geometry.Size(AvailableSpace) {
        if (!self.size.width.is_sizing_keyword() and !self.size.height.is_sizing_keyword()) return available_space;
        const margins = self.margins_axis_sums_with_baseline_shims(Tree, grid_area_size_value.width, tree_ref);
        var adjusted = available_space;
        const axes = [_]geometry.AbstractAxis{ .inline_axis, .block };
        for (axes) |axis| {
            const size_style = self.size.get(axis);
            if (!size_style.is_sizing_keyword()) continue;
            const area = grid_area_size_value.get(axis);
            const stretch_size: ?f32 = if (area) |value| @max(value - margins.get(axis), 0) else null;
            if (sizing_keyword.resolve_sizing_keyword(size_style, stretch_size, area)) |resolution| {
                if (resolution == .measure) adjusted.set(axis, resolution.measure);
            }
        }
        return adjusted;
    }

    /// The minimum contribution of an item is the smallest outer size it can have.
    pub fn minimum_contribution(self: *GridItem, comptime Tree: type,
        tree_ref: *Tree,
        axis: geometry.AbstractAxis,
        axis_tracks: []const GridTrack,
        grid_area_size_value: geometry.Size(?f32),
        inner_node_size: geometry.Size(?f32)) f32 {
        const padding = resolve_rect_length_percentage_or_zero(Tree, self.padding, grid_area_size_value.width, tree_ref);
        const border = resolve_rect_length_percentage_or_zero(Tree, self.border, grid_area_size_value.width, tree_ref);
        const padding_border_size = padding.add(border).sum_axes();
        const box_sizing_adjustment = if (self.box_sizing == .content_box) padding_border_size else geometry.F32Size{ .width = 0, .height = 0 };
        const resolved_size = maybe_add_size(
            geometry.optional_f32_size_maybe_apply_aspect_ratio(resolve_dimension_size(self.size, grid_area_size_value), self.aspect_ratio),
            box_sizing_adjustment);

        // A definite preferred size is the minimum contribution, clamped by the
        // item's min/max sizes (Taffy 9fb6fc2). A replaced element's percentage
        // max size resolves against zero when the basis is indefinite (0daade2).
        if (resolved_size.get(axis)) |size| {
            const min_style = self.min_size.get(axis);
            const max_style = self.max_size.get(axis);
            if (min_style.is_auto() and max_style.is_auto()) return size;
            const basis = grid_area_size_value.get(axis);
            const max_size_basis: ?f32 = if (self.is_replaced) (basis orelse 0) else basis;
            const adjustment = box_sizing_adjustment.get(axis);
            const min_value = math.option_maybe_add(resolve_lpa(min_style, basis), adjustment);
            const max_value = math.option_maybe_add(resolve_lpa(max_style, max_size_basis), adjustment);
            return math.f32_maybe_clamp(size, min_value, max_value);
        }

        // A sizing-keyword preferred size (other than stretch) contributes its
        // min-content contribution (c8b7261).
        const size_style = self.size.get(axis);
        if (size_style.is_sizing_keyword() and !size_style.is_stretch()) {
            return self.min_content_contribution_cached(Tree, axis, tree_ref, grid_area_size_value, grid_area_size_value);
        }

        // Cyclic percentage minimum sizes resolve against zero (4142c9d).
        const zero_basis_area = geometry.Size(?f32){ .width = grid_area_size_value.width orelse 0, .height = grid_area_size_value.height orelse 0 };
        const resolved_min = maybe_add_size(
            geometry.optional_f32_size_maybe_apply_aspect_ratio(resolve_lpa_size(self.min_size, zero_basis_area), self.aspect_ratio),
            box_sizing_adjustment);
        if (resolved_min.get(axis)) |value| return value;
        if (self.overflow.get(axis).maybe_into_automatic_min_size()) |value| return value;

        // Automatic minimum size. See https://www.w3.org/TR/css-grid-1/#min-size-auto
        const item_range = self.track_range_excluding_lines(axis);
        const item_axis_tracks = if (item_range.end <= axis_tracks.len) axis_tracks[item_range.start..item_range.end] else axis_tracks[0..0];

        // It spans at least one track whose min track sizing function behaves as
        // auto (indefinite percentages do, 8409f3f)...
        var spans_auto_min_track = false;
        for (item_axis_tracks) |track| {
            if (track.min_track_sizing_function.behaves_as_auto(inner_node_size.get(axis))) {
                spans_auto_min_track = true;
                break;
            }
        }
        // ...and if it spans more than one track, none of them is flexible.
        const use_content_based_minimum = spans_auto_min_track and (item_axis_tracks.len == 1 or blk: {
            for (item_axis_tracks) |track| {
                if (track.max_track_sizing_function.is_fr()) break :blk false;
            }
            break :blk true;
        });
        if (!use_content_based_minimum) return 0;

        var minimum = self.min_content_contribution_cached(Tree, axis, tree_ref, grid_area_size_value, grid_area_size_value);

        // If the item is a compressible replaced element, cap the size suggestion
        // by any definite preferred or maximum size in the relevant axis.
        if (self.is_compressible_replaced) {
            minimum = math.f32_maybe_min(minimum, self.size.get(axis).resolve(0));
            minimum = math.f32_maybe_min(minimum, self.max_size.get(axis).resolve(0));
        }

        // Clamp by the sum of the spanned tracks' fixed max sizing functions, minus
        // the item's margins but floored at its padding + border (654d6d7).
        const limit = self.spanned_fixed_track_limit(axis, axis_tracks, inner_node_size.get(axis));
        const margins = self.margins_axis_sums_with_baseline_shims(Tree, grid_area_size_value.width, tree_ref);
        return math.f32_maybe_min(minimum, if (limit) |l| @max(l - margins.get(axis), padding_border_size.get(axis)) else null);
    }

    /// Retrieve the item's minimum contribution from the cache or compute it
    pub fn minimum_contribution_cached(self: *GridItem, comptime Tree: type,
        tree_ref: *Tree,
        axis: geometry.AbstractAxis,
        axis_tracks: []const GridTrack,
        grid_area_size_value: geometry.Size(?f32),
        inner_node_size: geometry.Size(?f32)) f32 {
        if (self.minimum_contribution_cache.get(axis)) |cached| return cached;
        const size = self.minimum_contribution(Tree, tree_ref, axis, axis_tracks, grid_area_size_value, inner_node_size);
        self.minimum_contribution_cache.set(axis, size);
        return size;
    }
};

/// `stretch`, or `normal` (which stretches non-replaced grid items).
fn align_is_stretch(alignment_value: style.alignment.AlignItems, is_replaced: bool) bool {
    return switch (alignment_value.keyword) {
        .stretch => true,
        .normal => !is_replaced,
        else => false,
    };
}

fn resolve_dimension_size(value: geometry.Size(style.dimension.Dimension), basis: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = value.width.resolve(basis.width), .height = value.height.resolve(basis.height) };
}

fn resolve_lpa(value: style.dimension.LengthPercentageAuto, basis: ?f32) ?f32 {
    // Taffy `MaybeResolve<Option<f32>> for LengthPercentageAuto`: lengths always
    // resolve, percentages require a definite basis, auto resolves to null.
    return switch (value.value.tag()) {
        .auto => null,
        .length => value.value.value(),
        .percent => if (basis) |b| b * value.value.value() else null,
        .calc => if (basis) |b| calc_resolver.resolve(value.value.calc_value(), b) else null,
        else => null,
    };
}

fn resolve_lpa_size(value: geometry.Size(style.dimension.LengthPercentageAuto), basis: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = resolve_lpa(value.width, basis.width), .height = resolve_lpa(value.height, basis.height) };
}

fn resolve_rect_length_percentage_or_zero(comptime Tree: type, value: geometry.Rect(style.dimension.LengthPercentage), basis: ?f32, tree_ref: *Tree) geometry.Rect(f32) {
    _ = tree_ref;
    const resolved_basis = basis orelse 0;
    return .{
        .left = value.left.resolve(resolved_basis),
        .right = value.right.resolve(resolved_basis),
        .top = value.top.resolve(resolved_basis),
        .bottom = value.bottom.resolve(resolved_basis),
    };
}

fn maybe_add_size(value: geometry.Size(?f32), add: geometry.F32Size) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| v + add.width else null,
        .height = if (value.height) |v| v + add.height else null,
    };
}

fn maybe_sub_size(value: geometry.Size(?f32), sub: geometry.F32Size) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| v - sub.width else null,
        .height = if (value.height) |v| v - sub.height else null,
    };
}

fn maybe_max_size(value: geometry.Size(?f32), floor: geometry.F32Size) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| @max(v, floor.width) else null,
        .height = if (value.height) |v| @max(v, floor.height) else null,
    };
}

fn optional_size_maybe_clamp(value: geometry.Size(?f32), minimum: geometry.Size(?f32), maximum: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{
        .width = math.option_maybe_clamp(value.width, minimum.width, maximum.width),
        .height = math.option_maybe_clamp(value.height, minimum.height, maximum.height),
    };
}

/// Map `Size<Option<f32>>` to `Size<AvailableSpace>`, using `intrinsic` when the
/// side is indefinite (Taffy: `available_space.map(|opt| match opt { Some(size) =>
/// AvailableSpace::Definite(size), None => AvailableSpace::MinContent/MaxContent })`).
fn map_available_space(value: geometry.Size(?f32), intrinsic: AvailableSpace) geometry.Size(AvailableSpace) {
    return .{
        .width = if (value.width) |size| .{ .definite = size } else intrinsic,
        .height = if (value.height) |size| .{ .definite = size } else intrinsic,
    };
}

test "grid item retains placement and contribution caches" {
    const testing = @import("std").testing;
    var item = GridItem.new_with_placement_style_and_order(
        7,
        .{ .start = .{ .value = 1 }, .end = .{ .value = 3 } },
        .{ .start = .{ .value = 0 }, .end = .{ .value = 2 } },
        &.{},
        style.alignment.AlignItems.start,
        style.alignment.AlignItems.stretch,
        2);
    try testing.expectEqual(@as(u16, 2), item.span(.inline_axis));
    try testing.expectEqual(@as(u16, 2), item.span(.block));
    try testing.expect(!item.has_auto_block_margin());
    try testing.expect(!item.participates_in_baseline_alignment());
    item.column_indexes = .{ .start = 1, .end = 3 };
    try testing.expectEqual(@as(usize, 2), item.track_range_excluding_lines(.inline_axis).start);
    try testing.expectEqual(@as(usize, 3), item.track_range_excluding_lines(.inline_axis).end);
}
