//! Direct port of Taffy's `compute/grid/track_sizing.rs`.
//!
//! Implements the track sizing algorithm:
//! <https://www.w3.org/TR/css-grid-1/#layout-algorithm>

const std = @import("std");
const geometry = @import("../../geometry.zig");
const style = @import("../../style/root.zig");
const AvailableSpace = @import("../../style/available_space.zig").AvailableSpace;
const math = @import("../../util/math.zig");
const layout = @import("../../tree/layout.zig");
const coordinates = @import("types/coordinates.zig");
const grid_track = @import("types/grid_track.zig");
const grid_item = @import("types/grid_item.zig");
const grid_track_counts = @import("types/grid_track_counts.zig");
const LayoutTree = @import("../../tree/interfaces.zig").LayoutTree;

const GridTrack = grid_track.GridTrack;
const GridItem = grid_item.GridItem;
const TrackCounts = grid_track_counts.TrackCounts;
const AlignContent = style.alignment.AlignContent;
const AbstractAxis = geometry.AbstractAxis;
const TrackSizeEstimateFn = grid_item.TrackSizeEstimateFn;

/// Takes an axis, and a list of grid items sorted firstly by whether they cross
/// a flex track in the specified axis (items that don't cross a flex track
/// first) and then by the number of tracks they cross (ascending order).
const ItemBatcher = struct {
    /// The axis in which the ItemBatcher is operating
    axis: AbstractAxis,
    /// The starting index of the current batch
    index_offset: usize = 0,
    /// The span of the items in the current batch
    current_span: u16 = 1,
    /// Whether the current batch of items cross a flexible track
    current_is_flex: bool = false,

    inline fn new(axis: AbstractAxis) ItemBatcher {
        return .{ .axis = axis };
    }

    /// Manual version of `Iterator::next` which passes `items` in as a parameter.
    const BatchResult = struct { batch: []GridItem, is_flex: bool };

    inline fn next(self: *ItemBatcher, items: []GridItem) ?BatchResult {
        if (self.current_is_flex or self.index_offset >= items.len) return null;

        const item = items[self.index_offset];
        self.current_span = item.span(self.axis);
        self.current_is_flex = item.crosses_flexible_track(self.axis);

        const next_index_offset = if (self.current_is_flex) items.len else blk: {
            var position = items.len;
            for (items, 0..) |candidate, index| {
                if (candidate.crosses_flexible_track(self.axis) or candidate.span(self.axis) > self.current_span) {
                    position = index;
                    break;
                }
            }
            break :blk position;
        };

        const batch = items[self.index_offset..next_index_offset];
        self.index_offset = next_index_offset;
        return .{ .batch = batch, .is_flex = self.current_is_flex };
    }
};

/// Captures the variables used to compute the intrinsic sizes of children.
/// Generic over the tree type so it works with any `LayoutTree` implementation.
fn IntrinsicSizeMeasurer(comptime Tree: type) type {
    return struct {
    /// This type. Declared inside the struct body so the methods below can name
    /// their own receiver.
    const Self = @This();

    tree_ref: *Tree,
    other_axis_tracks: []const GridTrack,
    get_track_size_estimate: TrackSizeEstimateFn(Tree),
    axis: AbstractAxis,
    inner_node_size: geometry.Size(?f32),

    inline fn gridAreaSize(self: *Self, item: *GridItem, axis_tracks: []const GridTrack) geometry.Size(?f32) {
        return item.grid_area_size_cached(
            Tree,
            self.axis,
            axis_tracks,
            self.other_axis_tracks,
            self.inner_node_size,
            self.get_track_size_estimate,
            self.tree_ref,
        );
    }

    inline fn marginsAxisSums(self: *Self, item: *const GridItem, percentage_basis: ?f32) geometry.F32Size {
        return item.margins_axis_sums_with_baseline_shims(Tree, percentage_basis, self.tree_ref);
    }

    inline fn minContentContribution(self: *Self, item: *GridItem, axis_tracks: []const GridTrack) f32 {
        const grid_area_size = self.gridAreaSize(item, axis_tracks);
        const available_space = grid_area_size.with(self.axis, null);
        const margin_axis_sums = self.marginsAxisSums(item, available_space.width);
        const contribution = item.min_content_contribution_cached(Tree, self.axis, self.tree_ref, grid_area_size, available_space);
        return contribution + margin_axis_sums.get(self.axis);
    }

    inline fn maxContentContribution(self: *Self, item: *GridItem, axis_tracks: []const GridTrack) f32 {
        const grid_area_size = self.gridAreaSize(item, axis_tracks);
        const available_space = grid_area_size.with(self.axis, null);
        const margin_axis_sums = self.marginsAxisSums(item, available_space.width);
        const contribution = item.max_content_contribution_cached(Tree, self.axis, self.tree_ref, grid_area_size, available_space);
        return contribution + margin_axis_sums.get(self.axis);
    }

    inline fn minimumContribution(self: *Self, item: *GridItem, axis_tracks: []const GridTrack) f32 {
        const grid_area_size = self.gridAreaSize(item, axis_tracks);
        const available_space = grid_area_size.with(self.axis, null);
        const margin_axis_sums = self.marginsAxisSums(item, available_space.width);
        const contribution = item.minimum_contribution_cached(Tree, self.tree_ref, self.axis, axis_tracks, grid_area_size, self.inner_node_size);
        return contribution + margin_axis_sums.get(self.axis);
    }
    };
}

fn cmpByCrossFlexThenSpanThenStart(axis: AbstractAxis, item_a: GridItem, item_b: GridItem) bool {
    const a_flex = item_a.crosses_flexible_track(axis);
    const b_flex = item_b.crosses_flexible_track(axis);
    if (!a_flex and b_flex) return true;
    if (a_flex and !b_flex) return false;

    const placement_a = item_a.placement(axis);
    const placement_b = item_b.placement(axis);
    const span_a = coordinates.line_origin_zero_span(placement_a);
    const span_b = coordinates.line_origin_zero_span(placement_b);
    if (span_a < span_b) return true;
    if (span_a > span_b) return false;
    return placement_a.start.value < placement_b.start.value;
}

/// When applying the track sizing algorithm and estimating the size in the other
/// axis for content sizing items we should take into account align-content/justify-content
/// if both the grid container and all items in the other axis have definite sizes.
pub fn compute_alignment_gutter_adjustment(comptime Tree: type, alignment: AlignContent,
    axis_inner_node_size: ?f32,
    tree_ref: *Tree,
    get_track_size_estimate: TrackSizeEstimateFn(Tree),
    tracks: []const GridTrack,
) f32 {
    if (tracks.len <= 1) return 0;

    // As items never cross the outermost gutters in a grid, we can simplify our
    // calculations by treating Start and End the same.
    const outer_gutter_weight: u32 = switch (alignment.keyword) {
        .start, .flex_start, .end, .flex_end, .center => 1,
        .normal, .stretch, .space_between => 0,
        .space_around, .space_evenly => 1,
    };

    const inner_gutter_weight: u32 = switch (alignment.keyword) {
        .flex_start, .start, .flex_end, .end, .center, .normal, .stretch => 0,
        .space_between => 1,
        .space_around => 2,
        .space_evenly => 1,
    };

    if (inner_gutter_weight == 0) return 0;

    if (axis_inner_node_size) |axis_size| {
        var track_size_sum: f32 = 0;
        for (tracks) |track| {
            const estimate = get_track_size_estimate(track, axis_size, tree_ref) orelse return 0;
            track_size_sum += estimate;
        }
        const free_space = math.f32_max(0, axis_size - track_size_sum);

        const weighted_track_count = (((tracks.len -% 3) / 2) * inner_gutter_weight) + (2 * outer_gutter_weight);

        return (free_space / @as(f32, @floatFromInt(weighted_track_count))) * @as(f32, @floatFromInt(inner_gutter_weight));
    }

    return 0;
}

/// Convert origin-zero coordinates track placement into grid track vector indexes
pub fn resolve_item_track_indexes(items: []GridItem, column_counts: TrackCounts, row_counts: TrackCounts) void {
    for (items) |*item| {
        item.column_indexes = .{
            .start = @intCast(item.column.start.into_track_vec_index(column_counts)),
            .end = @intCast(item.column.end.into_track_vec_index(column_counts)),
        };
        item.row_indexes = .{
            .start = @intCast(item.row.start.into_track_vec_index(row_counts)),
            .end = @intCast(item.row.end.into_track_vec_index(row_counts)),
        };
    }
}

/// Determine (in each axis) whether the item crosses any flexible or intrinsic tracks
pub fn determine_if_item_crosses_flexible_or_intrinsic_tracks(items: []GridItem, columns: []const GridTrack, rows: []const GridTrack) void {
    for (items) |*item| {
        item.crosses_flexible_column = any_spanned(item.*, .inline_axis, columns, is_flexible_track);
        item.crosses_intrinsic_column = any_spanned(item.*, .inline_axis, columns, has_intrinsic_sizing_function);
        item.crosses_flexible_row = any_spanned(item.*, .block, rows, is_flexible_track);
        item.crosses_intrinsic_row = any_spanned(item.*, .block, rows, has_intrinsic_sizing_function);
    }
}

fn is_flexible_track(track: GridTrack) bool {
    return track.is_flexible();
}

fn has_intrinsic_sizing_function(track: GridTrack) bool {
    return track.has_intrinsic_sizing_function();
}

fn any_spanned(item: GridItem, axis: AbstractAxis, tracks: []const GridTrack, predicate: *const fn (GridTrack) bool) bool {
    return item.spans_track_matching(axis, tracks, predicate);
}

/// Track sizing algorithm
/// Note: Gutters are treated as empty fixed-size tracks for the purpose of the algorithm.
pub fn track_sizing_algorithm(comptime Tree: type, tree_ref: *Tree,
    axis: AbstractAxis,
    axis_min_size: ?f32,
    axis_max_size: ?f32,
    axis_alignment: AlignContent,
    other_axis_alignment: AlignContent,
    available_grid_space: geometry.Size(AvailableSpace),
    inner_node_size: geometry.Size(?f32),
    axis_tracks: []GridTrack,
    other_axis_tracks: []GridTrack,
    items: []GridItem,
    get_track_size_estimate: TrackSizeEstimateFn(Tree),
    has_baseline_aligned_item: bool,
) void {
    const TreeApi = LayoutTree(Tree);

    // 11.4 Initialise Track sizes
    const percentage_basis = inner_node_size.get(axis) orelse axis_min_size;
    initialize_track_sizes(axis_tracks, percentage_basis);

    // One scratch allocation pair for the item sorts in this pass.
    const sort_scratch = SortScratch.init(TreeApi.scratch_allocator(tree_ref), items.len);

    // 11.5.1 Shim item baselines
    if (has_baseline_aligned_item) {
        resolve_item_baselines(Tree, tree_ref, axis, items, inner_node_size, sort_scratch);
    }

    // If all tracks have a fixed min track sizing function and base_size = growth_limit,
    // then the track sizes are already final and we can skip the rest of this function.
    var all_final = true;
    for (axis_tracks) |track| {
        if (track.base_size != track.growth_limit or track.min_track_sizing_function.definite_value(percentage_basis) == null) {
            all_final = false;
            break;
        }
    }
    if (all_final) return;

    // Pre-computations for 11.5 Resolve Intrinsic Track Sizes
    const gutter_alignment_adjustment = compute_alignment_gutter_adjustment(
        Tree,
        other_axis_alignment,
        inner_node_size.get(axis.other()),
        tree_ref,
        get_track_size_estimate,
        other_axis_tracks,
    );
    if (other_axis_tracks.len > 3) {
        var i: usize = 2;
        while (i < other_axis_tracks.len) : (i += 2) {
            other_axis_tracks[i].content_alignment_adjustment = gutter_alignment_adjustment;
        }
    }

    // 11.5 Resolve Intrinsic Track Sizes
    resolve_intrinsic_track_sizes(
        Tree,
        tree_ref,
        axis,
        axis_tracks,
        other_axis_tracks,
        items,
        available_grid_space.get(axis),
        inner_node_size,
        get_track_size_estimate,
        sort_scratch,
    );

    // 11.6. Maximise Tracks
    maximise_tracks(axis_tracks, inner_node_size.get(axis), available_grid_space.get(axis));

    // For the purpose of the final two expansion steps, we only want to expand into
    // space generated by the grid container's size, not just any available space.
    const axis_available_space_for_expansion: AvailableSpace = if (inner_node_size.get(axis)) |available_space|
        .{ .definite = available_space }
    else switch (available_grid_space.get(axis)) {
        // Flexible rows still expand under a block-axis min-content constraint (Taffy e2fbe56)
        .min_content => if (axis == .inline_axis) .min_content else .max_content,
        .max_content, .definite => .max_content,
    };

    // 11.7. Expand Flexible Tracks
    expand_flexible_tracks(
        Tree,
        tree_ref,
        axis,
        axis_tracks,
        other_axis_tracks,
        items,
        axis_min_size,
        axis_max_size,
        axis_available_space_for_expansion,
        inner_node_size,
        get_track_size_estimate,
    );

    // 11.8. Stretch auto Tracks
    if (axis_alignment.keyword == .stretch) {
        stretch_auto_tracks(axis_tracks, axis_min_size, axis_available_space_for_expansion);
    }
}

/// Whether it is a minimum or maximum size's space being distributed.
const IntrinsicContributionType = enum { minimum, maximum };

const THRESHOLD_BASE: f32 = 0.000001;
const THRESHOLD_LIMITS: f32 = 0.01;

inline fn flush_planned_base_size_increases(tracks: []GridTrack) void {
    for (tracks) |*track| {
        track.base_size += track.base_size_planned_increase;
        track.base_size_planned_increase = 0;
    }
}

inline fn flush_planned_growth_limit_increases(tracks: []GridTrack, set_infinitely_growable: bool) void {
    for (tracks) |*track| {
        if (track.growth_limit_planned_increase > 0) {
            track.growth_limit = if (track.growth_limit == std.math.inf(f32))
                track.base_size + track.growth_limit_planned_increase
            else
                track.growth_limit + track.growth_limit_planned_increase;
            track.infinitely_growable = set_infinitely_growable;
        } else {
            track.infinitely_growable = false;
        }
        track.growth_limit_planned_increase = 0;
    }
}

/// Which of the two item orderings a sort call wants.
const SortKind = enum {
    /// By start position on the other axis, matching `lessThanByOtherAxisStart`.
    other_axis_start,
    /// By (cross-flex, span, start), matching `cmpByCrossFlexThenSpanThenStart`.
    cross_flex_span_start,
};

/// The item's sort key, packed so that comparing `u64`s reproduces the
/// corresponding comparator exactly. The components are compared as unsigned,
/// which preserves the signed ordering of the underlying `i16`/`u16` values
/// under two's complement.
fn itemKey(comptime kind: SortKind, axis: AbstractAxis, item: GridItem) u64 {
    return switch (kind) {
        .other_axis_start => @as(u64, @as(u16, @bitCast(item.placement(axis).start.value))),
        .cross_flex_span_start => blk: {
            const placement = item.placement(axis);
            const span = coordinates.line_origin_zero_span(placement);
            // Items that do not cross a flexible track sort first, so the flag
            // occupies the high bit.
            const flex: u64 = if (item.crosses_flexible_track(axis)) 1 else 0;
            break :blk (flex << 48) | @as(u64, span);
        },
    };
}

/// Sort grid items by a compact key, then permute once.
///
/// Sorting `[]GridItem` directly is expensive whichever algorithm is used: the
/// struct is 312 bytes, so `std.mem.sort` (WikiSort, a `[512]T` scratch cache
/// plus an 8-element sorting network) and `std.mem.sortUnstable` (pdqsort) both
/// spend their time moving whole items. On the mixed scenario a direct sort
/// measured at ~8% of total time, and switching to pdqsort made it *worse*.
///
/// Instead each item is reduced to one `u64` key, the 12-byte entries are
/// sorted, and the items are then permuted out of place through one reusable
/// scratch buffer. Permuting by cycling through `entries` instead was tried and
/// is markedly slower: the swaps jump around a 312-byte array, so the extra item
/// buffer is what makes this variant cheap.
const ItemSortEntry = struct {
    key: u64,
    index: u32,
};

fn lessThanEntry(_: void, a: ItemSortEntry, b: ItemSortEntry) bool {
    if (a.key != b.key) return a.key < b.key;
    // Ties keep their existing relative order, so the outcome is identical to
    // sorting the items with a stable sort -- which is what upstream's
    // `sort_by_key` does.
    return a.index < b.index;
}

/// Reusable scratch for the item sorts, sized once per `track_sizing_algorithm`
/// call and shared by both sorts in that call. The layout arena does not
/// reclaim on free, so allocating per sort call would grow the arena once per
/// call rather than once per pass.
const SortScratch = struct {
    entries: []ItemSortEntry,
    reordered: []GridItem,

    fn init(allocator: std.mem.Allocator, n: usize) SortScratch {
        return .{
            .entries = allocator.alloc(ItemSortEntry, n) catch &.{},
            .reordered = allocator.alloc(GridItem, n) catch &.{},
        };
    }

    fn fits(self: SortScratch, n: usize) bool {
        return self.entries.len >= n and self.reordered.len >= n;
    }
};

fn sortItemsByKey(items: []GridItem, scratch: SortScratch, axis: AbstractAxis, comptime kind: SortKind) void {
    if (items.len < 2) return;
    if (!scratch.fits(items.len)) {
        // No scratch available: the direct sort needs none, so use it.
        std.mem.sort(GridItem, items, axis, switch (kind) {
            .other_axis_start => lessThanByOtherAxisStart,
            .cross_flex_span_start => cmpByCrossFlexThenSpanThenStart,
        });
        return;
    }
    const entries = scratch.entries[0..items.len];
    const reordered = scratch.reordered[0..items.len];

    for (items, 0..) |item, i| entries[i] = .{ .key = itemKey(kind, axis, item), .index = @intCast(i) };
    std.mem.sort(ItemSortEntry, entries, {}, lessThanEntry);
    for (entries, 0..) |entry, i| reordered[i] = items[entry.index];
    @memcpy(items, reordered);
}

fn sortItemsByOtherAxisStart(items: []GridItem, axis: AbstractAxis, scratch: SortScratch) void {
    sortItemsByKey(items, scratch, axis, .other_axis_start);
}

/// Order items for intrinsic track sizing: items that cross a flexible track
/// form one batch at the end; the rest only need ordering by span if any of
/// them spans more than one track (Taffy 2c81b8e: order within a batch does not
/// affect the result). The common all-span-1, no-flex grid is left untouched.
fn sortItemsByCrossFlexSpanStart(items: []GridItem, axis: AbstractAxis, scratch: SortScratch) void {
    var needs_sort = false;
    var seen_flex = false;
    var flex_out_of_place = false;
    for (items) |item| {
        if (item.crosses_flexible_track(axis)) {
            seen_flex = true;
        } else {
            if (seen_flex) flex_out_of_place = true;
            if (coordinates.line_origin_zero_span(item.placement(axis)) > 1) needs_sort = true;
        }
    }
    if (!needs_sort and !flex_out_of_place) return;
    sortItemsByKey(items, scratch, axis, .cross_flex_span_start);
}

/// 11.4 Initialise Track sizes: initialize each track's base size and growth limit.
inline fn initialize_track_sizes(axis_tracks: []GridTrack, axis_inner_node_size: ?f32) void {
    for (axis_tracks) |*track| {
        // If the track's min track sizing function is fixed: resolve to an absolute length
        // and use that as the initial base size; if intrinsic: use zero.
        track.base_size = track.min_track_sizing_function.definite_value(axis_inner_node_size) orelse 0;

        // If the track's max track sizing function is fixed: resolve and use as the initial
        // growth limit; if intrinsic or flexible: use infinity.
        track.growth_limit = track.max_track_sizing_function.definite_value(axis_inner_node_size) orelse std.math.inf(f32);

        // In all cases, if the growth limit is less than the base size, increase it.
        if (track.growth_limit < track.base_size) track.growth_limit = track.base_size;
    }
}

/// 11.5.1 Shim baseline-aligned items so their intrinsic size contributions
/// reflect their baseline alignment.
fn resolve_item_baselines(comptime Tree: type, tree_ref: *Tree, axis: AbstractAxis, items: []GridItem, inner_node_size: geometry.Size(?f32), sort_scratch: SortScratch) void {
    const TreeApi = LayoutTree(Tree);
    // Sort items by track in the other axis start position so that we can iterate
    // items in groups which are in the same track in the other axis.
    const other_axis = axis.other();
    sortItemsByOtherAxisStart(items, other_axis, sort_scratch);

    var row_start: usize = 0;
    while (row_start < items.len) {
        const current_row = items[row_start].placement(other_axis).start.value;
        var row_end = row_start + 1;
        while (row_end < items.len and items[row_end].placement(other_axis).start.value == current_row) : (row_end += 1) {}
        const row_items = items[row_start..row_end];

        // If a row has one or zero items participating in baseline alignment then
        // baseline alignment is a no-op for those items.
        var row_baseline_item_count: usize = 0;
        for (row_items) |item| {
            if (item.participates_in_baseline_alignment()) row_baseline_item_count += 1;
        }
        if (row_baseline_item_count <= 1) {
            row_start = row_end;
            continue;
        }

        // Compute the baselines of all items in the row participating in baseline alignment
        for (row_items) |*item| {
            if (!item.participates_in_baseline_alignment()) continue;

            const measured = TreeApi.perform_child_layout(tree_ref,
                item.node,
                .{ .width = null, .height = null },
                inner_node_size,
                .{ .width = .min_content, .height = .min_content },
                .inherent_size,
                .{ .start = false, .end = false },
            ) catch @panic("Taffy grid baseline layout failed");

            const baseline = measured.baselines.first;
            const height = measured.size.height;

            // Scroll containers' baselines are clamped to their border box.
            const adjusted_baseline = if (item.overflow.y.is_scroll_container())
                @min(@max(baseline orelse height, 0), height)
            else
                baseline orelse height;

            // The baseline is measured from the border box (Taffy e77a7a8)
            item.baseline = adjusted_baseline;
        }

        // Items are aligned by the distance from the top of their margin box to their baseline
        const margin_box_baseline = struct {
            fn call(baseline_item: GridItem, width_basis: ?f32) f32 {
                const top_margin = if (width_basis) |basis| (baseline_item.margin.top.resolve(basis) orelse 0) else 0;
                return (baseline_item.baseline orelse 0) + top_margin;
            }
        }.call;

        // Compute the max baseline of all items in the row participating in baseline alignment
        var row_max_baseline: f32 = 0;
        for (row_items) |item| {
            if (!item.participates_in_baseline_alignment()) continue;
            row_max_baseline = @max(row_max_baseline, margin_box_baseline(item, inner_node_size.width));
        }

        // Compute the baseline shim for each item in the row participating in baseline alignment
        for (row_items) |*item| {
            if (item.participates_in_baseline_alignment()) {
                item.baseline_shim = row_max_baseline - margin_box_baseline(item.*, inner_node_size.width);
                item.known_dimensions_cache = null;
            }
        }

        row_start = row_end;
    }
}

fn lessThanByOtherAxisStart(axis: AbstractAxis, item_a: GridItem, item_b: GridItem) bool {
    return item_a.placement(axis).start.value < item_b.placement(axis).start.value;
}

/// 11.5 Resolve Intrinsic Track Sizes
fn resolve_intrinsic_track_sizes(comptime Tree: type, tree_ref: *Tree,
    axis: AbstractAxis,
    axis_tracks: []GridTrack,
    other_axis_tracks: []const GridTrack,
    items: []GridItem,
    axis_available_grid_space: AvailableSpace,
    inner_node_size: geometry.Size(?f32),
    get_track_size_estimate: TrackSizeEstimateFn(Tree),
    sort_scratch: SortScratch,
) void {

    // Step 1 shim baseline-aligned items already done in `resolve_item_baselines`.

    // The track sizing algorithm requires us to iterate through the items in ascending
    // order of the number of tracks they span. Pre-sort them into this order.
    sortItemsByCrossFlexSpanStart(items, axis, sort_scratch);

    const axis_inner_node_size = inner_node_size.get(axis);
    var item_sizer = IntrinsicSizeMeasurer(Tree){
        .tree_ref = tree_ref,
        .other_axis_tracks = other_axis_tracks,
        .get_track_size_estimate = get_track_size_estimate,
        .axis = axis,
        .inner_node_size = inner_node_size,
    };

    var batcher = ItemBatcher.new(axis);
    while (batcher.next(items)) |batch_result| {
        const batch = batch_result.batch;
        const is_flex = batch_result.is_flex;

        // 2. Size tracks to fit non-spanning items
        const batch_span = coordinates.line_origin_zero_span(batch[0].placement(axis));
        if (!is_flex and batch_span == 1) {
            for (batch) |*item| {
                const track_index = @as(usize, item.placement_indexes(axis).start) + 1;
                const track = &axis_tracks[track_index];

                // Handle base sizes
                const new_base_size: f32 = if (track.min_track_sizing_function.value.is_min_content())
                    math.f32_max(track.base_size, item_sizer.minContentContribution(item, axis_tracks))
                else if (track.min_track_sizing_function.value.is_max_content())
                    math.f32_max(track.base_size, item_sizer.maxContentContribution(item, axis_tracks))
                // If the container size is indefinite and has not yet been resolved then
                // percentage sized tracks are treated as auto (Taffy 8409f3f).
                else if (track.min_track_sizing_function.behaves_as_auto(axis_inner_node_size)) blk: {
                    const space = switch (axis_available_grid_space) {
                        // QUIRK: only apply the limited min-content contribution rule
                        // if the item is not a scroll container.
                        .min_content, .max_content => if (!item.overflow.get(axis).is_scroll_container()) blk2: {
                            const axis_minimum_size = item_sizer.minimumContribution(item, axis_tracks);
                            const axis_min_content_size = item_sizer.minContentContribution(item, axis_tracks);
                            const limit = track.max_track_sizing_function.definite_limit(axis_inner_node_size);
                            break :blk2 math.f32_max(math.f32_maybe_min(axis_min_content_size, limit), axis_minimum_size);
                        } else item_sizer.minimumContribution(item, axis_tracks),
                        .definite => item_sizer.minimumContribution(item, axis_tracks),
                    };
                    break :blk math.f32_max(track.base_size, space);
                }
                // Not an intrinsic track sizing function
                else track.base_size;
                axis_tracks[track_index].base_size = new_base_size;

                // Handle growth limits
                //
                // Contributions call into the child, so they are only computed when
                // used. The min-content contribution is computed for every item in an
                // intrinsic track (even where only the max-content contribution sets
                // the growth limit): the re-run check compares each such item's
                // min-content contribution against the one cached here.
                const track_now = &axis_tracks[track_index];
                const max_track_sizing_function = track_now.max_track_sizing_function;
                const fit_content_limit = track_now.fit_content_limit(axis_inner_node_size);
                const min_content_contribution: ?f32 = if (track_now.has_intrinsic_sizing_function())
                    item_sizer.minContentContribution(item, axis_tracks)
                else
                    null;
                const planned_increase: ?f32 = if (max_track_sizing_function.is_fit_content()) pi: {
                    // Always grow to at least the *fit-content limited* max-content contribution
                    const max_content_contribution = math.f32_min(item_sizer.maxContentContribution(item, axis_tracks), fit_content_limit);
                    // ...and, if the item is not a scroll container, its min-content contribution
                    if (min_content_contribution) |min_c| {
                        if (!item.overflow.get(axis).is_scroll_container())
                            break :pi math.f32_max(min_c, max_content_contribution);
                    }
                    break :pi max_content_contribution;
                } else if (max_track_sizing_function.is_max_content_alike() or
                    (max_track_sizing_function.uses_percentage() and axis_inner_node_size == null))
                    // If the container size is indefinite then percentage sized tracks
                    // should be treated as auto.
                    item_sizer.maxContentContribution(item, axis_tracks)
                else if (max_track_sizing_function.is_intrinsic())
                    min_content_contribution
                else
                    null;
                if (planned_increase) |increase| {
                    const track_mut = &axis_tracks[track_index];
                    track_mut.growth_limit_planned_increase = math.f32_max(track_mut.growth_limit_planned_increase, increase);
                }
            }

            for (axis_tracks) |*track| {
                if (track.growth_limit_planned_increase > 0) {
                    track.growth_limit = if (track.growth_limit == std.math.inf(f32))
                        track.growth_limit_planned_increase
                    else
                        math.f32_max(track.growth_limit, track.growth_limit_planned_increase);
                }
                track.infinitely_growable = false;
                track.growth_limit_planned_increase = 0;
                if (track.growth_limit < track.base_size) {
                    track.growth_limit = track.base_size;
                }
            }
            continue;
        }

        // 1. For intrinsic minimums
        for (batch) |*item| {
            if (!item.crosses_intrinsic_track(axis)) continue;

            // QUIRK: limited min-content contributions only apply to non-scroll-containers.
            const space = switch (axis_available_grid_space) {
                .min_content, .max_content => if (!item.overflow.get(axis).is_scroll_container()) blk: {
                    const axis_minimum_size = item_sizer.minimumContribution(item, axis_tracks);
                    const axis_min_content_size = item_sizer.minContentContribution(item, axis_tracks);
                    const limit = item.spanned_track_limit(axis, axis_tracks, axis_inner_node_size);
                    const limited_min_content = math.f32_max(math.f32_maybe_min(axis_min_content_size, limit), axis_minimum_size);

                    // For items crossing flexible tracks, scale the content-derived
                    // contribution by the crossed flex factor sum, clamped at one.
                    if (is_flex) {
                        const range = item.track_range_excluding_lines(axis);
                        const spanned_tracks = axis_tracks[range.start..range.end];
                        var inflexible_sizes: f32 = 0;
                        for (spanned_tracks) |track| {
                            if (!track.is_flexible()) inflexible_sizes += track.base_size;
                        }
                        const scale = math.f32_min(crossed_flex_factor_sum(spanned_tracks), 1.0);
                        const excess = math.f32_max(limited_min_content - inflexible_sizes, 0.0);
                        break :blk math.f32_max(axis_minimum_size, inflexible_sizes + excess * scale);
                    }
                    break :blk limited_min_content;
                } else item_sizer.minimumContribution(item, axis_tracks),
                .definite => item_sizer.minimumContribution(item, axis_tracks),
            };

            const range = item.track_range_excluding_lines(axis);
            if (space > 0 and range.start < range.end and range.end <= axis_tracks.len) {
                const tracks = axis_tracks[range.start..range.end];
                if (item.overflow.get(axis).is_scroll_container()) {
                    distribute_item_space_to_base_size(is_flex, space, tracks, pred_intrinsic_min, limit_fit_content_limited, .minimum, axis_inner_node_size);
                } else {
                    distribute_item_space_to_base_size(is_flex, space, tracks, pred_intrinsic_min, limit_growth_limit, .minimum, axis_inner_node_size);
                }
            }
        }
        flush_planned_base_size_increases(axis_tracks);

        // 2. For content-based minimums
        for (batch) |*item| {
            if (!spansTrackMatchingInner(item.*, axis, axis_tracks, pred_min_or_max_content, axis_inner_node_size)) continue;
            const space = item_sizer.minContentContribution(item, axis_tracks);
            const range = item.track_range_excluding_lines(axis);
            if (space > 0 and range.start < range.end and range.end <= axis_tracks.len) {
                const tracks = axis_tracks[range.start..range.end];
                if (item.overflow.get(axis).is_scroll_container()) {
                    distribute_item_space_to_base_size(is_flex, space, tracks, pred_min_or_max_content, limit_fit_content_limited, .minimum, axis_inner_node_size);
                } else {
                    distribute_item_space_to_base_size(is_flex, space, tracks, pred_min_or_max_content, limit_growth_limit, .minimum, axis_inner_node_size);
                }
            }
        }
        flush_planned_base_size_increases(axis_tracks);

        // 3. For max-content minimums (only under a max-content constraint)
        if (axis_available_grid_space == .max_content) {
            for (batch) |*item| {
                if (!spansTrackMatchingInner(item.*, axis, axis_tracks, pred_auto_min_not_min_content_max, axis_inner_node_size)) continue;
                const axis_max_content_size = item_sizer.maxContentContribution(item, axis_tracks);
                const limit = item.spanned_track_limit(axis, axis_tracks, axis_inner_node_size);
                var space = math.f32_maybe_min(axis_max_content_size, limit);

                // As above: scale the space beyond the spanned inflexible tracks by the
                // crossed flex factor sum, clamped at one.
                if (is_flex) {
                    const range = item.track_range_excluding_lines(axis);
                    const spanned_tracks = axis_tracks[range.start..range.end];
                    var inflexible_sizes: f32 = 0;
                    for (spanned_tracks) |track| {
                        if (!track.is_flexible()) inflexible_sizes += track.base_size;
                    }
                    const scale = math.f32_min(crossed_flex_factor_sum(spanned_tracks), 1.0);
                    space = inflexible_sizes + math.f32_max(space - inflexible_sizes, 0.0) * scale;
                }
                const range = item.track_range_excluding_lines(axis);
                if (space > 0 and range.start < range.end and range.end <= axis_tracks.len) {
                    const tracks = axis_tracks[range.start..range.end];
                    if (spansTrackMatchingInner(item.*, axis, axis_tracks, pred_max_content_min, axis_inner_node_size)) {
                        distribute_item_space_to_base_size(is_flex, space, tracks, pred_max_content_min, limit_infinity, .maximum, axis_inner_node_size);
                    } else {
                        distribute_item_space_to_base_size(is_flex, space, tracks, pred_auto_min_not_min_content_max, limit_fit_content_limited, .maximum, axis_inner_node_size);
                    }
                }
            }
            flush_planned_base_size_increases(axis_tracks);
        }

        // In all cases, continue to increase the base size of tracks with a min track
        // sizing function of max-content by distributing extra space as needed to
        // account for these items' max-content contributions.
        for (batch) |*item| {
            if (!spansTrackMatchingInner(item.*, axis, axis_tracks, pred_max_content_min, axis_inner_node_size)) continue;
            const axis_max_content_size = item_sizer.maxContentContribution(item, axis_tracks);
            const space = axis_max_content_size;
            const range = item.track_range_excluding_lines(axis);
            if (space > 0 and range.start < range.end and range.end <= axis_tracks.len) {
                const tracks = axis_tracks[range.start..range.end];
                distribute_item_space_to_base_size(is_flex, space, tracks, pred_max_content_min, limit_growth_limit, .maximum, axis_inner_node_size);
            }
        }
        flush_planned_base_size_increases(axis_tracks);

        // 4. If at this point any track's growth limit is now less than its base
        // size, increase its growth limit to match its base size.
        for (axis_tracks) |*track| {
            if (track.growth_limit < track.base_size) track.growth_limit = track.base_size;
        }

        // If a track is a flexible track, then it has a flexible max track sizing
        // function. It cannot also have an intrinsic max track sizing function, so
        // steps 5 and 6 do not apply.
        if (!is_flex) {
            // 5. For intrinsic maximums
            for (batch) |*item| {
                if (!spansTrackMatchingInner(item.*, axis, axis_tracks, pred_intrinsic_max, axis_inner_node_size)) continue;
                const axis_min_content_size = item_sizer.minContentContribution(item, axis_tracks);
                const space = axis_min_content_size;
                const range = item.track_range_excluding_lines(axis);
                if (space > 0 and range.start < range.end and range.end <= axis_tracks.len) {
                    const tracks = axis_tracks[range.start..range.end];
                    distribute_item_space_to_growth_limit(space, tracks, pred_intrinsic_max, axis_inner_node_size);
                }
            }
            // Mark any tracks whose growth limit changed from infinite to finite in this
            // step as infinitely growable for the next step.
            flush_planned_growth_limit_increases(axis_tracks, true);

            // 6. For max-content maximums
            for (batch) |*item| {
                if (!spansTrackMatchingInner(item.*, axis, axis_tracks, pred_max_content_max, axis_inner_node_size)) continue;
                const axis_max_content_size = item_sizer.maxContentContribution(item, axis_tracks);
                const space = axis_max_content_size;
                const range = item.track_range_excluding_lines(axis);
                if (space > 0 and range.start < range.end and range.end <= axis_tracks.len) {
                    const tracks = axis_tracks[range.start..range.end];
                    distribute_item_space_to_growth_limit(space, tracks, pred_max_content_max, axis_inner_node_size);
                }
            }
            // Mark any tracks whose growth limit changed from infinite to finite in this
            // step as infinitely growable for the next step.
            flush_planned_growth_limit_increases(axis_tracks, false);
        }
    }

    // Step 5. If any track still has an infinite growth limit (because, for example,
    // it had no items placed in it or it is a flexible track), set its growth limit
    // to its base size.
    for (axis_tracks) |*track| {
        if (track.growth_limit == std.math.inf(f32)) track.growth_limit = track.base_size;
    }
}

/// The sum of the flex factors of the flexible tracks in an item's spanned track range
inline fn crossed_flex_factor_sum(tracks: []const GridTrack) f32 {
    var total: f32 = 0;
    for (tracks) |track| {
        if (track.is_flexible()) total += track.flex_factor();
    }
    return total;
}

/// Whether any track spanned by the item satisfies `predicate`, taking the
/// axis inner node size as predicate context.
fn spansTrackMatchingInner(item: GridItem, axis: AbstractAxis, axis_tracks: []const GridTrack, predicate: TrackPredicate, axis_inner_node_size: ?f32) bool {
    const range = item.track_range_excluding_lines(axis);
    if (range.end > axis_tracks.len or range.start >= range.end) return false;
    for (axis_tracks[range.start..range.end]) |track| {
        if (predicate(track, axis_inner_node_size)) return true;
    }
    return false;
}

const TrackPredicate = *const fn (GridTrack, ?f32) bool;
const TrackPropertyFn = *const fn (GridTrack, ?f32) f32;

fn pred_intrinsic_min(track: GridTrack, inner: ?f32) bool {
    return track.min_track_sizing_function.definite_value(inner) == null;
}
fn pred_min_or_max_content(track: GridTrack, inner: ?f32) bool {
    _ = inner;
    return track.min_track_sizing_function.is_min_or_max_content();
}
fn pred_auto_min_not_min_content_max(track: GridTrack, inner: ?f32) bool {
    _ = inner;
    return track.min_track_sizing_function.is_auto() and !track.max_track_sizing_function.is_min_content();
}
fn pred_max_content_min(track: GridTrack, inner: ?f32) bool {
    _ = inner;
    return track.min_track_sizing_function.is_max_content();
}
fn pred_intrinsic_max(track: GridTrack, inner: ?f32) bool {
    return track.max_track_sizing_function.definite_value(inner) == null;
}
fn pred_max_content_max(track: GridTrack, inner: ?f32) bool {
    return track.max_track_sizing_function.is_max_content_alike() or
        (track.max_track_sizing_function.uses_percentage() and inner == null);
}
fn pred_always(_: GridTrack, _: ?f32) bool {
    return true;
}
fn pred_max_intrinsic(track: GridTrack, inner: ?f32) bool {
    _ = inner;
    return track.max_track_sizing_function.is_intrinsic();
}
fn pred_max_max_or_fit_content(track: GridTrack, inner: ?f32) bool {
    _ = inner;
    return track.max_track_sizing_function.is_max_or_fit_content();
}

fn limit_growth_limit(track: GridTrack, inner: ?f32) f32 {
    _ = inner;
    return track.growth_limit;
}
fn limit_fit_content_limited(track: GridTrack, inner: ?f32) f32 {
    return track.fit_content_limited_growth_limit(inner);
}
/// The raw `fit_content()` argument limit (Taffy's `track.fit_content_limit`),
/// used when distributing space beyond limits.
fn limit_fit_content(track: GridTrack, inner: ?f32) f32 {
    return track.fit_content_limit(inner);
}
fn limit_infinity(track: GridTrack, inner: ?f32) f32 {
    _ = track;
    _ = inner;
    return std.math.inf(f32);
}
fn prop_base(track: GridTrack, inner: ?f32) f32 {
    _ = inner;
    return track.base_size;
}
fn pred_growth_limit_growable(track: GridTrack, _: ?f32) bool {
    return track.infinitely_growable or track.growth_limit == std.math.inf(f32);
}

fn prop_base_or_growth(track: GridTrack, inner: ?f32) f32 {
    _ = inner;
    return if (track.growth_limit == std.math.inf(f32)) track.base_size else track.growth_limit;
}
fn prop_flex_factor(track: GridTrack, inner: ?f32) f32 {
    _ = inner;
    return track.flex_factor();
}
fn prop_one(track: GridTrack, inner: ?f32) f32 {
    _ = track;
    _ = inner;
    return 1.0;
}

/// 11.5.1. Distributing Extra Space Across Spanned Tracks
/// <https://www.w3.org/TR/css-grid-1/#extra-space>
inline fn distribute_item_space_to_base_size(
    is_flex: bool,
    space: f32,
    tracks: []GridTrack,
    track_is_affected: TrackPredicate,
    track_limit: TrackPropertyFn,
    intrinsic_contribution_type: IntrinsicContributionType,
    axis_inner_node_size: ?f32,
) void {
    if (is_flex) {
        // If the sum of the flex factors of the affected tracks is greater than zero,
        // distribute space according to the ratios of the tracks' flex factors.
        var flex_factor_sum: f32 = 0;
        for (tracks) |track| {
            if (track.is_flexible() and track_is_affected(track, axis_inner_node_size)) flex_factor_sum += track.flex_factor();
        }
        if (flex_factor_sum > 0) {
            distribute_item_space_to_base_size_inner(space, tracks, is_flex, track_is_affected, prop_flex_factor, track_limit, intrinsic_contribution_type, axis_inner_node_size);
        } else {
            distribute_item_space_to_base_size_inner(space, tracks, is_flex, track_is_affected, prop_one, track_limit, intrinsic_contribution_type, axis_inner_node_size);
        }
    } else {
        distribute_item_space_to_base_size_inner(space, tracks, is_flex, track_is_affected, prop_one, track_limit, intrinsic_contribution_type, axis_inner_node_size);
    }
}

fn distribute_item_space_to_base_size_inner(
    space: f32,
    tracks: []GridTrack,
    is_flex: bool,
    track_is_affected: TrackPredicate,
    track_distribution_proportion: TrackPropertyFn,
    track_limit: TrackPropertyFn,
    intrinsic_contribution_type: IntrinsicContributionType,
    axis_inner_node_size: ?f32,
) void {
    // Skip if there is no space to distribute or no affected tracks
    var any_affected = false;
    for (tracks) |track| {
        if (trackAffected(track, is_flex, track_is_affected, axis_inner_node_size)) {
            any_affected = true;
            break;
        }
    }
    if (space == 0 or !any_affected) return;

    // 1. Find the space to distribute
    var track_sizes: f32 = 0;
    for (tracks) |track| track_sizes += track.base_size;
    var extra_space = math.f32_max(0, space - track_sizes);

    // 2. Distribute space up to limits
    extra_space = distribute_space_up_to_limits(extra_space, tracks, is_flex, track_is_affected, null, track_distribution_proportion, prop_base, track_limit, axis_inner_node_size);

    // 3. Distribute remaining span beyond limits (if any)
    if (extra_space > THRESHOLD_BASE) {
        // When accommodating minimum/min-content contributions: any affected track that
        // happens to also have an intrinsic max track sizing function.
        // When accommodating max-content contributions: any affected track that happens
        // to also have a max-content max track sizing function.
        const beyond_filter: TrackPredicate = switch (intrinsic_contribution_type) {
            .minimum => pred_max_intrinsic,
            .maximum => pred_max_max_or_fit_content,
        };

        // If there are no such tracks then use all affected tracks.
        var number_of_tracks: usize = 0;
        for (tracks) |track| {
            if (trackAffected(track, is_flex, track_is_affected, axis_inner_node_size) and beyond_filter(track, axis_inner_node_size)) number_of_tracks += 1;
        }
        const final_filter: ?TrackPredicate = if (number_of_tracks == 0) null else beyond_filter;

        _ = distribute_space_up_to_limits(extra_space, tracks, is_flex, track_is_affected, final_filter, track_distribution_proportion, prop_base, limit_fit_content, axis_inner_node_size);
    }

    // 4. For each affected track, if the item-incurred increase is larger than the
    // planned increase, set the planned increase to that value.
    for (tracks) |*track| {
        if (track.item_incurred_increase > track.base_size_planned_increase) {
            track.base_size_planned_increase = track.item_incurred_increase;
        }
        track.item_incurred_increase = 0;
    }
}

/// 11.5.1. Distributing Extra Space Across Spanned Tracks (growth limits)
fn distribute_item_space_to_growth_limit(
    space: f32,
    tracks: []GridTrack,
    track_is_affected: TrackPredicate,
    axis_inner_node_size: ?f32,
) void {
    // Skip this distribution if there is either no space or no affected tracks
    var any_affected = false;
    for (tracks) |track| {
        if (track_is_affected(track, axis_inner_node_size)) {
            any_affected = true;
            break;
        }
    }
    if (space == 0 or !any_affected) return;

    // 1. Find the space to distribute
    var track_sizes: f32 = 0;
    for (tracks) |track| {
        track_sizes += if (track.growth_limit == std.math.inf(f32)) track.base_size else track.growth_limit;
    }
    const extra_space = math.f32_max(0, space - track_sizes);

    // 2. Distribute space up to limits. For growth limits the limit is the growth
    // limit itself unless the track is infinitely growable (or its growth limit is
    // still infinite), in which case it is the track's fit-content() argument if it
    // has one, or infinity. Tracks that aren't growable have an affected size equal
    // to their limit, so they receive nothing in this step.
    const remaining = distribute_space_up_to_limits(extra_space, tracks, false, track_is_affected, pred_growth_limit_growable, prop_one, prop_base_or_growth, limit_fit_content, axis_inner_node_size);

    // 3. Distribute space beyond limits: if space remains after all tracks are
    // frozen, continue distributing to all affected tracks.
    if (remaining > 0) {
        _ = distribute_space_up_to_limits(remaining, tracks, false, track_is_affected, null, prop_one, prop_base_or_growth, limit_fit_content, axis_inner_node_size);
    }

    // 4. Apply item-incurred increases to the planned growth limit increases
    for (tracks) |*track| {
        if (track.item_incurred_increase > track.growth_limit_planned_increase) {
            track.growth_limit_planned_increase = track.item_incurred_increase;
        }
        track.item_incurred_increase = 0;
    }
}

/// 11.6 Maximise Tracks: distribute free space (if any) to tracks with FINITE
/// growth limits, up to their limits.
inline fn maximise_tracks(
    axis_tracks: []GridTrack,
    axis_inner_node_size: ?f32,
    axis_available_grid_space: AvailableSpace,
) void {
    var used_space: f32 = 0;
    for (axis_tracks) |track| used_space += track.base_size;
    const free_space = axis_available_grid_space.compute_free_space(used_space);
    if (free_space == std.math.inf(f32)) {
        for (axis_tracks) |*track| track.base_size = track.growth_limit;
    } else if (free_space > 0) {
        _ = distribute_space_up_to_limits(free_space, axis_tracks, false, pred_always, null, prop_one, prop_base, limit_fit_content_limited, axis_inner_node_size);
        for (axis_tracks) |*track| {
            track.base_size += track.item_incurred_increase;
            track.item_incurred_increase = 0;
        }
    }
}

/// 11.7. Expand Flexible Tracks
fn expand_flexible_tracks(comptime Tree: type, tree_ref: *Tree,
    axis: AbstractAxis,
    axis_tracks: []GridTrack,
    other_axis_tracks: []const GridTrack,
    items: []GridItem,
    axis_min_size: ?f32,
    axis_max_size: ?f32,
    axis_available_space_for_expansion: AvailableSpace,
    inner_node_size: geometry.Size(?f32),
    get_track_size_estimate: TrackSizeEstimateFn(Tree),
) void {
    var item_sizer = IntrinsicSizeMeasurer(Tree){
        .tree_ref = tree_ref,
        .other_axis_tracks = other_axis_tracks,
        .get_track_size_estimate = get_track_size_estimate,
        .axis = axis,
        .inner_node_size = inner_node_size,
    };

    // First, find the grid's used flex fraction:
    const flex_fraction: f32 = switch (axis_available_space_for_expansion) {
        // If the free space is zero the used flex fraction is zero. Otherwise, if
        // the free space is a definite length the used flex fraction is the result
        // of finding the size of an fr using all of the grid tracks.
        .definite => |available_space| blk: {
            var used_space: f32 = 0;
            for (axis_tracks) |track| used_space += track.base_size;
            const free_space = available_space - used_space;
            if (free_space <= 0) break :blk 0;
            break :blk find_size_of_fr(axis_tracks, available_space);
        },
        // If sizing the grid container under a min-content constraint the used flex fraction is zero.
        .min_content => 0,
        // Otherwise, if the free space is an indefinite length, the used flex fraction
        // is the maximum of:
        .max_content => blk: {
            var max_track_fraction: f32 = 0;
            for (axis_tracks) |track| {
                if (track.max_track_sizing_function.is_fr()) {
                    const flex_factor = track.flex_factor();
                    const value = if (flex_factor > 1) track.base_size / flex_factor else track.base_size;
                    max_track_fraction = @max(max_track_fraction, value);
                }
            }

            var max_item_fraction: f32 = 0;
            for (items) |*item| {
                if (!item.crosses_flexible_track(axis)) continue;
                const max_content_contribution = item_sizer.maxContentContribution(item, axis_tracks);
                const range = item.track_range_excluding_lines(axis);
                if (range.end > axis_tracks.len or range.start >= range.end) continue;
                max_item_fraction = @max(max_item_fraction, find_size_of_fr(axis_tracks[range.start..range.end], max_content_contribution));
            }
            const fraction = @max(max_track_fraction, max_item_fraction);

            // If using this flex fraction would cause the grid to be smaller than the
            // grid container's min-size (or larger than its max-size), then redo this
            // step treating the free space as definite and the available grid space as
            // equal to the grid container's inner size.
            var hypothetical_grid_size: f32 = 0;
            for (axis_tracks) |track| {
                if (track.max_track_sizing_function.is_fr()) {
                    const track_flex_factor = track.max_track_sizing_function.value.value();
                    hypothetical_grid_size += math.f32_max(track.base_size, track_flex_factor * fraction);
                } else {
                    hypothetical_grid_size += track.base_size;
                }
            }
            const min_size = axis_min_size orelse 0;
            const max_size = axis_max_size orelse std.math.inf(f32);
            if (hypothetical_grid_size < min_size) {
                break :blk find_size_of_fr(axis_tracks, min_size);
            } else if (hypothetical_grid_size > max_size) {
                break :blk find_size_of_fr(axis_tracks, max_size);
            }
            break :blk fraction;
        },
    };

    // For each flexible track, if the product of the used flex fraction and the
    // track's flex factor is greater than the track's base size, set its base size.
    for (axis_tracks) |*track| {
        if (!track.max_track_sizing_function.is_fr()) continue;
        const track_flex_factor = track.max_track_sizing_function.value.value();
        track.base_size = math.f32_max(track.base_size, track_flex_factor * flex_fraction);
    }
}

/// 11.7.1. Find the Size of an fr: finds the largest size that an fr unit can be
/// without exceeding the target size.
fn find_size_of_fr(tracks: []const GridTrack, space_to_fill: f32) f32 {
    // Handle the trivial case where there is no space to fill
    if (space_to_fill == 0) return 0;

    var hypothetical_fr_size = std.math.inf(f32);
    const max_iterations = tracks.len + 1;
    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        var used_space: f32 = 0;
        var naive_flex_factor_sum: f32 = 0;
        for (tracks) |track| {
            // Tracks for which flex_factor * hypothetical_fr_size < track.base_size
            // are treated as inflexible
            if (track.max_track_sizing_function.is_fr() and
                track.max_track_sizing_function.value.value() * hypothetical_fr_size >= track.base_size)
            {
                naive_flex_factor_sum += track.max_track_sizing_function.value.value();
            } else {
                used_space += track.base_size;
            }
        }
        const leftover_space = space_to_fill - used_space;
        const flex_factor = math.f32_max(naive_flex_factor_sum, 1.0);

        const previous_iter_hypothetical_fr_size = hypothetical_fr_size;
        hypothetical_fr_size = leftover_space / flex_factor;

        var hypothetical_fr_size_is_valid = true;
        for (tracks) |track| {
            if (track.max_track_sizing_function.is_fr()) {
                const flex_factor_track = track.max_track_sizing_function.value.value();
                if (!(flex_factor_track * hypothetical_fr_size >= track.base_size or
                    flex_factor_track * previous_iter_hypothetical_fr_size < track.base_size))
                {
                    hypothetical_fr_size_is_valid = false;
                    break;
                }
            }
        }
        if (hypothetical_fr_size_is_valid) break;
    }

    return hypothetical_fr_size;
}

/// 11.8. Stretch auto Tracks: expands tracks that have an auto max track sizing
/// function by dividing remaining positive, definite free space equally amongst them.
inline fn stretch_auto_tracks(
    axis_tracks: []GridTrack,
    axis_min_size: ?f32,
    axis_available_space_for_expansion: AvailableSpace,
) void {
    var num_auto_tracks: usize = 0;
    for (axis_tracks) |track| {
        if (track.max_track_sizing_function.is_auto()) num_auto_tracks += 1;
    }
    if (num_auto_tracks > 0) {
        var used_space: f32 = 0;
        for (axis_tracks) |track| used_space += track.base_size;

        // If the free space is indefinite, but the grid container has a definite
        // min-width/height use that size to calculate the free space instead.
        const free_space = if (axis_available_space_for_expansion.is_definite())
            axis_available_space_for_expansion.compute_free_space(used_space)
        else
            (axis_min_size orelse 0) - used_space;
        if (free_space > 0) {
            const extra_space_per_auto_track = free_space / @as(f32, @floatFromInt(num_auto_tracks));
            for (axis_tracks) |*track| {
                if (track.max_track_sizing_function.is_auto()) track.base_size += extra_space_per_auto_track;
            }
        }
    }
}

/// Helper function for distributing space to tracks evenly. Used by both
/// `distribute_item_space_to_base_size` and the maximise tracks step.
fn distribute_space_up_to_limits(
    space_to_distribute: f32,
    tracks: []GridTrack,
    is_flex: bool,
    track_is_affected: TrackPredicate,
    extra_filter: ?TrackPredicate,
    track_distribution_proportion: TrackPropertyFn,
    track_affected_property: TrackPropertyFn,
    track_limit: TrackPropertyFn,
    axis_inner_node_size: ?f32,
) f32 {
    const max_iterations = tracks.len + 1;
    var remaining = space_to_distribute;

    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        if (remaining <= THRESHOLD_LIMITS) break;

        var proportion_sum: f32 = 0;
        for (tracks) |track| {
            if (!trackAffectedFiltered(track, is_flex, track_is_affected, extra_filter, axis_inner_node_size)) continue;
            if (track_affected_property(track, axis_inner_node_size) + track.item_incurred_increase < track_limit(track, axis_inner_node_size)) {
                proportion_sum += track_distribution_proportion(track, axis_inner_node_size);
            }
        }
        if (proportion_sum == 0) break;

        // Compute item-incurred increase for this iteration
        var min_increase_limit = std.math.inf(f32);
        for (tracks) |track| {
            if (!trackAffectedFiltered(track, is_flex, track_is_affected, extra_filter, axis_inner_node_size)) continue;
            if (track_affected_property(track, axis_inner_node_size) + track.item_incurred_increase < track_limit(track, axis_inner_node_size)) {
                const value = (track_limit(track, axis_inner_node_size) - track_affected_property(track, axis_inner_node_size) - track.item_incurred_increase) /
                    track_distribution_proportion(track, axis_inner_node_size);
                min_increase_limit = @min(min_increase_limit, value);
            }
        }
        const iteration_item_incurred_increase = math.f32_min(min_increase_limit, remaining / proportion_sum);

        for (tracks) |*track| {
            if (!trackAffectedFiltered(track.*, is_flex, track_is_affected, extra_filter, axis_inner_node_size)) continue;
            const increase = iteration_item_incurred_increase * track_distribution_proportion(track.*, axis_inner_node_size);
            if (increase > 0 and
                track_affected_property(track.*, axis_inner_node_size) + track.item_incurred_increase + increase <= track_limit(track.*, axis_inner_node_size) + THRESHOLD_LIMITS)
            {
                track.item_incurred_increase += increase;
                remaining -= increase;
            }
        }
    }

    return remaining;
}

inline fn trackAffected(track: GridTrack, is_flex: bool, predicate: TrackPredicate, axis_inner_node_size: ?f32) bool {
    return (!is_flex or track.is_flexible()) and predicate(track, axis_inner_node_size);
}

inline fn trackAffectedFiltered(track: GridTrack, is_flex: bool, predicate: TrackPredicate, extra_filter: ?TrackPredicate, axis_inner_node_size: ?f32) bool {
    if (!trackAffected(track, is_flex, predicate, axis_inner_node_size)) return false;
    if (extra_filter) |filter| return filter(track, axis_inner_node_size);
    return true;
}

test "find size of fr handles base-size floored flex tracks" {
    const testing = @import("std").testing;
    var tracks = [_]GridTrack{
        GridTrack.new(.length(30), .fr(1)),
        GridTrack.new(.length(10), .fr(2)),
    };
    tracks[0].base_size = 30;
    tracks[1].base_size = 10;
    const fraction = find_size_of_fr(&tracks, 100);
    // naive flex factor sum is 3, so the fr size is 100/3
    try testing.expect(@abs(fraction - 100.0 / 3.0) < 0.0001);
}

test "stretch auto tracks distributes remaining space" {
    const testing = @import("std").testing;
    var tracks = [_]GridTrack{
        GridTrack.new(.length(20), .length(20)),
        GridTrack.new(.auto, .auto),
    };
    tracks[0].base_size = 20;
    tracks[1].base_size = 0;
    stretch_auto_tracks(&tracks, null, .{ .definite = 100 });
    try testing.expectEqual(@as(f32, 80), tracks[1].base_size);
}
