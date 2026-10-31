//! CSS Grid container algorithm, ported from Taffy's `compute/grid/mod.rs`.
//!
//! This module is a partial implementation of the CSS Grid Level 1 specification
//! <https://www.w3.org/TR/css-grid-1>.
//!
//! The algorithm consists of these phases:
//!   - Resolving the explicit grid
//!   - Placing items (which also resolves the implicit grid)
//!   - Track (row/column) sizing
//!   - Alignment & final item placement

const std = @import("std");
const geometry = @import("../../geometry.zig");
const style = @import("../../style/root.zig");
const grid = @import("../../style/grid.zig");
const AvailableSpace = @import("../../style/available_space.zig").AvailableSpace;
const math = @import("../../util/math.zig");
const NodeId = @import("../../tree/node.zig").NodeId;
const tree = @import("../../tree/tree.zig");
const layout = @import("../../tree/layout.zig");
const oof = @import("../oof.zig");
const common = @import("../common/root.zig");

const grid_item = @import("types/grid_item.zig");
const grid_track = @import("types/grid_track.zig");
const coordinates = @import("types/coordinates.zig");
const grid_track_counts = @import("types/grid_track_counts.zig");
const named = @import("types/named.zig");
const cell_occupancy = @import("types/cell_occupancy.zig");
const LayoutTree = @import("../../tree/interfaces.zig").LayoutTree;

pub const explicit_grid = @import("explicit_grid.zig");
pub const implicit_grid = @import("implicit_grid.zig");
pub const placement = @import("placement.zig");
pub const track_sizing = @import("track_sizing.zig");
pub const alignment = @import("alignment.zig");

pub const types = @import("types/root.zig");
pub const util = @import("util/root.zig");

pub const GridTrack = grid_track.GridTrack;
pub const GridItem = grid_item.GridItem;
pub const InFlowChild = grid_item.InFlowChild;
const TrackSizeEstimateFn = grid_item.TrackSizeEstimateFn;
pub const TrackCounts = grid_track_counts.TrackCounts;
pub const CellOccupancyMatrix = cell_occupancy.CellOccupancyMatrix;
pub const NamedLineResolver = named.NamedLineResolver;
pub const OriginZeroLine = coordinates.OriginZeroLine;
pub const MAX_GRID_TRACKS: u16 = explicit_grid.MAX_GRID_TRACKS;

pub const DetailedGridTracksInfo = struct {
    sizes: []const f32 = &.{},
    positions: []const geometry.Line(f32) = &.{},
    negative_implicit_tracks: u16 = 0,
    explicit_tracks: u16 = 0,
    positive_implicit_tracks: u16 = 0,
    empty_axis_line: ?f32 = null,
    line_names: []const []const []const u8 = &.{},

    pub fn names_for_line(self: DetailedGridTracksInfo, index: usize) []const []const u8 {
        if (index < self.negative_implicit_tracks) return &.{};
        const stored_index = index - self.negative_implicit_tracks;
        return if (stored_index < self.line_names.len) self.line_names[stored_index] else &.{};
    }

    pub fn iter_line_names(self: DetailedGridTracksInfo, index: usize) []const []const u8 {
        return self.names_for_line(index);
    }

    pub fn positions_from_grid_track_layout(allocator: std.mem.Allocator, tracks: []const GridTrack) ![]geometry.Line(f32) {
        var positions = std.ArrayList(geometry.Line(f32)).empty;
        for (tracks) |track| {
            // Collapsed auto-fit tracks still appear in the resolved list as
            // zero-sized tracks, so they are not filtered out here.
            if (track.kind == .track) {
                try positions.append(allocator, .{ .start = track.offset, .end = track.offset + track.base_size });
            }
        }
        return positions.toOwnedSlice(allocator);
    }

    pub fn from_grid_tracks_and_track_count(allocator: std.mem.Allocator, counts: TrackCounts, tracks: []const GridTrack, line_names: []const []const []const u8) !DetailedGridTracksInfo {
        const positions = try positions_from_grid_track_layout(allocator, tracks);
        var sizes = try allocator.alloc(f32, positions.len);
        for (positions, 0..) |position, index| sizes[index] = position.end - position.start;
        return .{
            .sizes = sizes,
            .positions = positions,
            .negative_implicit_tracks = counts.negative_implicit,
            .explicit_tracks = counts.explicit,
            .positive_implicit_tracks = counts.positive_implicit,
            .empty_axis_line = if (positions.len == 0 and tracks.len > 0) tracks[0].offset else null,
            .line_names = line_names,
        };
    }

    /// `line_names` resolves named placements for this axis; pass null to leave
    /// named placements unresolved (treated as `auto`).
    pub fn resolve_absolute_grid_axis(self: DetailedGridTracksInfo, placement_value: geometry.Line(grid.GridPlacement), padding_start: f32, padding_end: f32, is_reversed: bool, axis: geometry.AbsoluteAxis, line_names: ?*const named.OwnedLineIndex) geometry.Line(f32) {
        const counts = grid_track_counts.TrackCounts.from_raw(self.negative_implicit_tracks, self.explicit_tracks, self.positive_implicit_tracks);
        const min_line = -@as(i16, @intCast(self.negative_implicit_tracks));
        const max_line = @as(i16, @intCast(self.explicit_tracks + self.positive_implicit_tracks));

        // Resolve to (sorted) origin-zero lines first, then treat lines that fall
        // outside the grid as `auto`. A placement whose lines end up swapped (e.g.
        // `grid-column: 3 / 1`, or a non-existent named line which resolves past
        // the end of the explicit grid) is normalized before the out-of-grid
        // check, so `foo / 3` on a 2-column grid resolves to the area between line
        // 3 and the end padding edge.
        const resolved_placement = if (line_names) |index| index.resolve_line_names(placement_value, axis) else placement_value;
        const oz = grid.line_into_origin_zero(resolved_placement, self.explicit_tracks);
        const abs = grid.origin_zero_line_resolve_absolutely_positioned_grid_tracks(oz);
        const start_line: ?i16 = if (abs.start) |value| if (value >= min_line and value <= max_line) value else null else null;
        const end_line: ?i16 = if (abs.end) |value| if (value >= min_line and value <= max_line) value else null else null;
        const start_index: ?usize = if (start_line) |line| (coordinates.OriginZeroLine{ .value = line }).try_into_track_vec_index(counts) else null;
        const end_index: ?usize = if (end_line) |line| (coordinates.OriginZeroLine{ .value = line }).try_into_track_vec_index(counts) else null;
        // Track-vector indices count grid *lines*, so each index maps to a track by
        // halving it (gutter positions sit between tracks).
        const start_track: ?usize = if (start_index) |value| value / 2 else null;
        const end_track: ?usize = if (end_index) |value| value / 2 else null;

        const start_position = if (start_track) |line_index|
            (if (line_index < self.positions.len)
                (if (is_reversed) self.positions[line_index].end else self.positions[line_index].start)
            else if (self.positions.len > 0)
                (if (is_reversed) self.positions[self.positions.len - 1].start else self.positions[self.positions.len - 1].end)
            else
                (self.empty_axis_line orelse (if (is_reversed) padding_end else padding_start)))
        else if (is_reversed) padding_end else padding_start;

        const end_position = if (end_track) |line_index| blk: {
            if (line_index == 0) {
                break :blk if (self.positions.len > 0)
                    (if (is_reversed) self.positions[0].end else self.positions[0].start)
                else
                    (self.empty_axis_line orelse (if (is_reversed) padding_start else padding_end));
            }
            const prev = line_index - 1;
            break :blk if (prev < self.positions.len)
                (if (is_reversed) self.positions[prev].start else self.positions[prev].end)
            else if (self.positions.len > 0)
                (if (is_reversed) self.positions[0].end else self.positions[0].start)
            else
                (self.empty_axis_line orelse (if (is_reversed) padding_start else padding_end));
        } else if (is_reversed) padding_start else padding_end;

        return .{ .start = @min(start_position, end_position), .end = @max(start_position, end_position) };
    }

    pub fn write_track_list(self: DetailedGridTracksInfo, writer: anytype) !void {
        if (self.positions.len == 0) return writer.writeAll("none");
        for (self.positions, 0..) |position, index| {
            const names = self.names_for_line(index);
            if (names.len > 0) {
                try writer.writeAll("[");
                for (names, 0..) |name, name_index| {
                    if (name_index > 0) try writer.writeAll(" ");
                    try writer.writeAll(name);
                }
                try writer.writeAll("] ");
            }
            var number_buffer: [64]u8 = undefined;
            const size_text = std.fmt.bufPrint(&number_buffer, "{d}px", .{position.end - position.start}) catch "0px";
            try writer.writeAll(size_text);
            if (index + 1 < self.positions.len) try writer.writeAll(" ");
        }
        const trailing = self.names_for_line(self.positions.len);
        if (trailing.len > 0) {
            try writer.writeAll(" [");
            for (trailing, 0..) |name, index| {
                if (index > 0) try writer.writeAll(" ");
                try writer.writeAll(name);
            }
            try writer.writeAll("]");
        }
    }

    pub fn to_track_list_string(self: DetailedGridTracksInfo) []const u8 {
        var output = std.ArrayList(u8).empty;
        var sink = ArrayListSink{ .list = &output, .allocator = std.heap.page_allocator };
        self.write_track_list(&sink) catch @panic("Taffy detailed grid string allocation failed");
        return output.toOwnedSlice(std.heap.page_allocator) catch @panic("Taffy detailed grid string allocation failed");
    }
};

const ArrayListSink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: *ArrayListSink, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

pub const DetailedGridItemsInfo = struct {
    row_start: u16 = 1,
    row_end: u16 = 2,
    column_start: u16 = 1,
    column_end: u16 = 2,
};
pub const DetailedGridInfo = struct {
    /// Owns all detail allocations; freed by `deinitDetailedGridInfo`.
    arena: std.heap.ArenaAllocator,
    rows: DetailedGridTracksInfo = .{},
    columns: DetailedGridTracksInfo = .{},
    items: []const DetailedGridItemsInfo = &.{},
    /// Deep copy of the container's line-name maps, used by
    /// `resolve_absolute_grid_area` to resolve named placements for out-of-flow
    /// boxes after the layout pass's scratch arena is gone.
    line_names: ?named.OwnedLineIndex = null,

    pub fn write_grid_template_rows(self: DetailedGridInfo, writer: anytype) !void {
        return self.rows.write_track_list(writer);
    }
    pub fn write_grid_template_columns(self: DetailedGridInfo, writer: anytype) !void {
        return self.columns.write_track_list(writer);
    }
    pub fn grid_template_rows(self: DetailedGridInfo) []const u8 {
        return self.rows.to_track_list_string();
    }
    pub fn grid_template_columns(self: DetailedGridInfo) []const u8 {
        return self.columns.to_track_list_string();
    }

    pub fn item_grid_area(self: DetailedGridInfo, index: usize) ?struct { location: geometry.Point(f32), size: geometry.Size(f32) } {
        const item = if (index < self.items.len) self.items[index] else return null;
        const column_start = if (item.column_start > 0 and item.column_start - 1 < self.columns.positions.len) self.columns.positions[item.column_start - 1] else return null;
        const column_end = if (item.column_end > 1 and item.column_end - 2 < self.columns.positions.len) self.columns.positions[item.column_end - 2] else return null;
        const row_start = if (item.row_start > 0 and item.row_start - 1 < self.rows.positions.len) self.rows.positions[item.row_start - 1] else return null;
        const row_end = if (item.row_end > 1 and item.row_end - 2 < self.rows.positions.len) self.rows.positions[item.row_end - 2] else return null;
        return .{
            .location = .{ .x = @min(column_start.start, column_end.start), .y = row_start.start },
            .size = .{ .width = @max(column_start.end, column_end.end) - @min(column_start.start, column_end.start), .height = row_end.end - row_start.start },
        };
    }

    pub fn resolve_absolute_grid_area(self: DetailedGridInfo, grid_row: geometry.Line(grid.GridPlacement), grid_column: geometry.Line(grid.GridPlacement), direction: style.Direction, padding_box: geometry.Rect(f32)) geometry.Rect(f32) {
        const index: ?*const named.OwnedLineIndex = if (self.line_names) |value| &value else null;
        const columns = self.columns.resolve_absolute_grid_axis(grid_column, padding_box.left, padding_box.right, direction == .rtl, .horizontal, index);
        const rows = self.rows.resolve_absolute_grid_axis(grid_row, padding_box.top, padding_box.bottom, false, .vertical, index);
        return .{ .left = columns.start, .right = columns.end, .top = rows.start, .bottom = rows.end };
    }
};

/// Free a `DetailedGridInfo` allocated by `compute_grid_layout`.
pub fn deinitDetailedGridInfo(pointer: *const anyopaque, allocator: std.mem.Allocator) void {
    const info: *DetailedGridInfo = @ptrCast(@alignCast(@constCast(pointer)));
    info.arena.deinit();
    allocator.destroy(info);
}

/// Track size estimate functions matching Taffy's closures passed to
/// `track_sizing_algorithm`.
// Track-size estimate functions, matching Taffy's closures passed to
// `track_sizing_algorithm`. They are generic over the tree type so they can be
// used with any `LayoutTree` implementation; see `estimate_fns`.
fn estimate_track_max_definite(comptime Tree: type) TrackSizeEstimateFn(Tree) {
    return struct {
        fn call(track: GridTrack, parent_size: ?f32, _: *Tree) ?f32 {
            return track.max_track_sizing_function.definite_value(parent_size);
        }
    }.call;
}

fn estimate_track_base_size(comptime Tree: type) TrackSizeEstimateFn(Tree) {
    return struct {
        fn call(track: GridTrack, _: ?f32, _: *Tree) ?f32 {
            return track.base_size;
        }
    }.call;
}

fn column_has_items(context: ?*const anyopaque, index: usize) bool {
    const matrix: *const CellOccupancyMatrix = @ptrCast(@alignCast(context orelse return false));
    return matrix.column_is_occupied(index);
}

fn row_has_items(context: ?*const anyopaque, index: usize) bool {
    const matrix: *const CellOccupancyMatrix = @ptrCast(@alignCast(context orelse return false));
    return matrix.row_is_occupied(index);
}

/// Grid layout algorithm entry point.
pub fn compute_grid_layout(comptime Tree: type, tree_ref: *Tree, node_id: NodeId, inputs: layout.LayoutInput) !layout.LayoutOutput {
    const TreeApi = LayoutTree(Tree);
    const node_style = TreeApi.get_style(tree_ref, node_id);
    const direction = node_style.direction;
    const contain = node_style.contain;

    // 1. Compute "available grid space"
    // https://www.w3.org/TR/css-grid-1/#available-grid-space
    const aspect_ratio = node_style.aspect_ratio;
    const padding = resolve_rect_or_zero_length_percentage(node_style.padding, inputs.parent_size.width);
    const border = resolve_rect_or_zero_length_percentage(node_style.border, inputs.parent_size.width);
    const padding_border = add_rects(padding, border);
    const padding_border_size = padding_border.sum_axes();
    const box_sizing_adjustment = if (node_style.box_sizing == .content_box) padding_border_size else geometry.F32Size{ .width = 0, .height = 0 };

    const min_size = maybe_add_size(
        geometry.optional_f32_size_maybe_apply_aspect_ratio(resolve_lpa_size(node_style.min_size, inputs.parent_size), aspect_ratio),
        box_sizing_adjustment);
    const max_size = maybe_add_size(
        geometry.optional_f32_size_maybe_apply_aspect_ratio(resolve_lpa_size(node_style.max_size, inputs.parent_size), aspect_ratio),
        box_sizing_adjustment);
    const preferred_size = if (inputs.sizing_mode == .inherent_size)
        maybe_add_size(
            geometry.optional_f32_size_maybe_apply_aspect_ratio(resolve_dimension_size(node_style.size, inputs.parent_size), aspect_ratio),
            box_sizing_adjustment)
    else
        geometry.Size(?f32){ .width = null, .height = null };

    // Scrollbar gutters are reserved when the `overflow` property is set to
    // `Overflow::Scroll`. The axes are transposed because a node that scrolls
    // vertically needs *horizontal* space to be reserved for a scrollbar.
    const scrollbar_gutter = geometry.F32Point{
        .x = if (node_style.overflow.y == .scroll) node_style.scrollbar_width else 0,
        .y = if (node_style.overflow.x == .scroll) node_style.scrollbar_width else 0,
    };
    const is_scroll_container = node_style.overflow.x.is_scroll_container() or node_style.overflow.y.is_scroll_container();
    var content_box_inset = padding_border;
    content_box_inset.bottom += scrollbar_gutter.y;
    if (direction == .ltr) {
        content_box_inset.right += scrollbar_gutter.x;
    } else {
        content_box_inset.left += scrollbar_gutter.x;
    }

    const align_content = node_style.align_content orelse style.alignment.AlignContent.STRETCH;
    const justify_content = node_style.justify_content orelse style.alignment.AlignContent.STRETCH;
    const align_items = node_style.align_items;
    const justify_items = node_style.justify_items;

    // Note: we avoid accessing the grid rows/columns methods more than once as this can
    // cause an expensive-ish computation

    // constrained_available_space = known_dimensions.or(preferred_size)
    //     .map(Definite).unwrap_or(available_space).maybe_clamp(min, max).maybe_max(padding_border_size)
    const known_or_preferred = geometry.Size(?f32){
        .width = inputs.known_dimensions.width orelse preferred_size.width,
        .height = inputs.known_dimensions.height orelse preferred_size.height,
    };
    const definite_or_available = geometry.Size(AvailableSpace){
        .width = if (known_or_preferred.width) |width| .{ .definite = width } else inputs.available_space.width,
        .height = if (known_or_preferred.height) |height| .{ .definite = height } else inputs.available_space.height,
    };
    const constrained_available_space = geometry.Size(AvailableSpace){
        .width = math.available_maybe_max(math.available_maybe_clamp(definite_or_available.width, min_size.width, max_size.width), padding_border_size.width),
        .height = math.available_maybe_max(math.available_maybe_clamp(definite_or_available.height, min_size.height, max_size.height), padding_border_size.height),
    };

    const available_grid_space = geometry.Size(AvailableSpace){
        .width = map_definite_value(constrained_available_space.width, content_box_inset.horizontal_axis_sum()),
        .height = map_definite_value(constrained_available_space.height, content_box_inset.vertical_axis_sum()),
    };

    const outer_node_size = maybe_max_size(
        maybe_clamp_size(known_or_preferred, min_size, max_size),
        padding_border_size);

    // The track sizing algorithm operates on the grid container's content box, so the
    // min/max sizes (which are border-box sizes) need converting to content-box sizes.
    const inner_min_size = maybe_sub_size(min_size, content_box_inset.sum_axes());
    const inner_max_size = maybe_sub_size(max_size, content_box_inset.sum_axes());
    var inner_node_size = geometry.Size(?f32){
        .width = if (outer_node_size.width) |width| width - content_box_inset.left - content_box_inset.right else null,
        .height = if (outer_node_size.height) |height| height - content_box_inset.top - content_box_inset.bottom else null,
    };

    // Short-circuit layout if the container's size is fully determined and the run
    // mode is ComputeSize (and thus the container's size is all that we're interested in)
    if (inputs.run_mode == .compute_size) {
        if (outer_node_size.width != null and outer_node_size.height != null) {
            return layout.LayoutOutput.from_outer_size(.{ .width = outer_node_size.width.?, .height = outer_node_size.height.? });
        }
        // We can also short-circuit if the width is known and only the width has been requested.
        if (inputs.axis == .horizontal) {
            if (outer_node_size.width) |width| {
                return layout.LayoutOutput.from_outer_size(.{ .width = width, .height = 0 });
            }
        }
    }

    // All per-pass temporaries come from the tree scratch arena: they are
    // invalidated wholesale by the next top-level layout pass, and none of
    // them (unlike `DetailedGridInfo`) escape this function.
    const scratch = TreeApi.scratch_allocator(tree_ref);

    // Absolutely positioned children do not take part in grid placement and do not
    // create implicit tracks, so they are excluded from the grid size estimate.
    //
    // Each entry keeps the child's index in the *full* child list, not its index within
    // this filtered list: `source_order` must be the document child index so the
    // out-of-flow interleaving below can match items against children.
    var in_flow_children = std.ArrayList(InFlowChild).empty;
    defer in_flow_children.deinit(scratch);
    try in_flow_children.ensureTotalCapacity(scratch, try TreeApi.child_count(tree_ref, node_id));
    for (try TreeApi.child_ids(tree_ref, node_id), 0..) |child_id, child_index| {
        const child_style = TreeApi.get_style(tree_ref, child_id);
        if (child_style.box_generation_mode() != .none and !child_style.position.is_out_of_flow()) {
            try in_flow_children.append(scratch, .{ .node = child_id, .source_order = @intCast(child_index) });
        }
    }

    // 2. Resolve the explicit grid

    // This is very similar to inner_node_size except if inner_node_size is not definite
    // but the node has a min- or max- size style then that will be used in its place.
    const auto_fit_container_size = maybe_sub_size(
        maybe_max_size(
            maybe_clamp_size(or_size(or_size(outer_node_size, max_size), min_size), min_size, max_size),
            padding_border_size),
        content_box_inset.sum_axes());

    // If the grid container has a definite size or max size in the relevant axis, the
    // number of repetitions is the largest possible positive integer that does not
    // cause the grid to overflow the content box of its grid container. Otherwise, if
    // the container has a definite min size, the number of repetitions is the smallest
    // positive integer that fulfils that minimum requirement. Otherwise, the specified
    // track list repeats only once.
    const auto_fit_strategy = geometry.InBothAbsAxis(explicit_grid.AutoRepeatStrategy){
        .horizontal = if ((or_size(outer_node_size, max_size)).width != null) .max_repetitions_that_do_not_overflow else .min_repetitions_that_do_overflow,
        .vertical = if ((or_size(outer_node_size, max_size)).height != null) .max_repetitions_that_do_not_overflow else .min_repetitions_that_do_overflow,
    };

    const explicit_cols = explicit_grid.compute_explicit_grid_size_in_axis(node_style, auto_fit_container_size.width, auto_fit_strategy.horizontal, .horizontal);
    const explicit_rows = explicit_grid.compute_explicit_grid_size_in_axis(node_style, auto_fit_container_size.height, auto_fit_strategy.vertical, .vertical);

    var name_resolver = try NamedLineResolver.init(tree_ref.allocator, node_style, explicit_cols.auto_repetitions, explicit_rows.auto_repetitions);
    defer name_resolver.deinit();

    // Clamp the explicit grid to MAX_GRID_TRACKS tracks in each axis
    const explicit_col_count = @min(@max(explicit_cols.track_count, name_resolver.area_column_count()), MAX_GRID_TRACKS);
    const explicit_row_count = @min(@max(explicit_rows.track_count, name_resolver.area_row_count()), MAX_GRID_TRACKS);
    name_resolver.set_explicit_column_count(explicit_col_count);
    name_resolver.set_explicit_row_count(explicit_row_count);

    // 3. Implicit Grid: Estimate Track Counts
    var in_flow_child_ids = std.ArrayList(NodeId).empty;
    defer in_flow_child_ids.deinit(scratch);
    try in_flow_child_ids.ensureTotalCapacity(scratch, in_flow_children.items.len);
    for (in_flow_children.items) |entry| try in_flow_child_ids.append(scratch, entry.node);

    const estimate = implicit_grid.compute_grid_size_estimate(Tree, explicit_col_count, explicit_row_count, in_flow_child_ids.items, tree_ref);

    // 4. Grid Item Placement
    var items = std.ArrayList(GridItem).empty;
    defer items.deinit(scratch);
    var cell_occupancy_matrix = CellOccupancyMatrix.with_track_counts_using_allocator(scratch, estimate.columns, estimate.rows);
    defer cell_occupancy_matrix.deinit();

    try placement.place_grid_items(
        Tree,
        scratch,
        &cell_occupancy_matrix,
        &items,
        in_flow_children.items,
        tree_ref,
        node_style.grid_auto_flow,
        align_items orelse style.alignment.AlignItems.STRETCH,
        justify_items orelse style.alignment.AlignItems.STRETCH,
        &name_resolver);

    // Extract track counts from previous step (auto-placement can expand the number of tracks)
    const final_col_counts = cell_occupancy_matrix.track_counts(.horizontal);
    const final_row_counts = cell_occupancy_matrix.track_counts(.vertical);
    const final_col_counts_value = final_col_counts.*;
    const final_row_counts_value = final_row_counts.*;

    // 5. Initialize Tracks
    var columns = std.ArrayList(GridTrack).empty;
    defer columns.deinit(scratch);
    var rows = std.ArrayList(GridTrack).empty;
    defer rows.deinit(scratch);
    try explicit_grid.initialize_grid_tracks(&columns, scratch, final_col_counts_value, node_style, .horizontal, explicit_cols.auto_repetitions, &cell_occupancy_matrix, column_has_items);
    try explicit_grid.initialize_grid_tracks(&rows, scratch, final_row_counts_value, node_style, .vertical, explicit_rows.auto_repetitions, &cell_occupancy_matrix, row_has_items);

    // 6. Track Sizing

    // Convert grid placements in origin-zero coordinates to indexes into the
    // GridTrack vectors, and record which items cross flexible or intrinsic tracks.
    track_sizing.resolve_item_track_indexes(items.items, final_col_counts_value, final_row_counts_value);
    track_sizing.determine_if_item_crosses_flexible_or_intrinsic_tracks(items.items, columns.items, rows.items);

    // Determine if the grid has any baseline aligned items
    var has_baseline_aligned_item = false;
    for (items.items) |item| {
        if (item.participates_in_baseline_alignment()) {
            has_baseline_aligned_item = true;
            break;
        }
    }

    // Run track sizing algorithm for Inline axis
    track_sizing.track_sizing_algorithm(
        Tree,
        tree_ref,
        .inline_axis,
        inner_min_size.get(.inline_axis),
        inner_max_size.get(.inline_axis),
        justify_content,
        align_content,
        available_grid_space,
        inner_node_size,
        columns.items,
        rows.items,
        items.items,
        estimate_track_max_definite(Tree),
        has_baseline_aligned_item);
    var initial_column_sum: f32 = 0;
    for (columns.items) |track| initial_column_sum += track.base_size;
    if (inner_node_size.width == null) inner_node_size.width = initial_column_sum;

    // If only the container's width has been requested then row sizing can be
    // skipped entirely (avoiding measuring every item's height): column sizing
    // is not re-run when only computing the container's size.
    if (inputs.run_mode == .compute_size and inputs.axis == .horizontal) {
        const width = maybe_clamp_and_max(
            initial_column_sum + content_box_inset.horizontal_axis_sum(),
            min_size.width,
            max_size.width,
            padding_border_size.width);
        return layout.LayoutOutput.from_outer_size(.{ .width = width, .height = 0 });
    }

    for (items.items) |*item| item.grid_area_size_cache = null;

    // Run track sizing algorithm for Block axis
    track_sizing.track_sizing_algorithm(
        Tree,
        tree_ref,
        .block,
        inner_min_size.get(.block),
        inner_max_size.get(.block),
        align_content,
        justify_content,
        available_grid_space,
        inner_node_size,
        rows.items,
        columns.items,
        items.items,
        estimate_track_base_size(Tree),
        false, // TODO: Support baseline alignment in the vertical axis
    );
    var initial_row_sum: f32 = 0;
    for (rows.items) |track| initial_row_sum += track.base_size;

    // 6. Compute container size
    const resolved_style_size = geometry.Size(?f32){
        .width = inputs.known_dimensions.width orelse preferred_size.width,
        .height = inputs.known_dimensions.height orelse preferred_size.height,
    };
    var container_border_box = geometry.F32Size{
        .width = maybe_clamp_and_max(
            resolved_style_size.width orelse (initial_column_sum + content_box_inset.horizontal_axis_sum()),
            min_size.width,
            max_size.width,
            padding_border_size.width),
        .height = maybe_clamp_and_max(
            resolved_style_size.height orelse (initial_row_sum + content_box_inset.vertical_axis_sum()),
            min_size.height,
            max_size.height,
            padding_border_size.height),
    };
    var container_content_box = geometry.F32Size{
        .width = math.f32_max(0, container_border_box.width - content_box_inset.horizontal_axis_sum()),
        .height = math.f32_max(0, container_border_box.height - content_box_inset.vertical_axis_sum()),
    };

    // If only the container's size has been requested
    if (inputs.run_mode == .compute_size) {
        return layout.LayoutOutput.from_outer_size(container_border_box);
    }

    // The container's size is now determined, so percentages resolve against its
    // content box when re-running track sizing. This may be a no-op if the size was
    // known upfront (it then already equals `inner_node_size`).
    inner_node_size = .{ .width = container_content_box.width, .height = container_content_box.height };

    // Column sizing must be re-run (once) if:
    //   - The grid container's width is indefinite and there are any columns with
    //     percentage track sizing functions
    //   - Any grid item crossing an intrinsically sized track's min content contribution
    //     width has changed
    var rerun_column_sizing = false;
    var intrinsic_column_contribution_changed = false;

    var has_percentage_column = false;
    for (columns.items) |track| {
        if (track.uses_percentage()) {
            has_percentage_column = true;
            break;
        }
    }
    var has_percentage_row = false;
    for (rows.items) |track| {
        if (track.uses_percentage()) {
            has_percentage_row = true;
            break;
        }
    }
    const parent_width_indefinite = outer_node_size.width == null;
    rerun_column_sizing = parent_width_indefinite and has_percentage_column;

    if (!rerun_column_sizing) {
        for (items.items) |*item| {
            if (!item.crosses_intrinsic_column) continue;
            const grid_area_size = item.grid_area_size(Tree, .inline_axis, columns.items, rows.items, inner_node_size, estimate_track_base_size(Tree), tree_ref);
            const available_space = grid_area_size.with(.inline_axis, null);
            const new_min_content_contribution = item.min_content_contribution(Tree, .inline_axis, tree_ref, grid_area_size, available_space);

            const has_changed = @as(?f32, new_min_content_contribution) != item.min_content_contribution_cache.width;

            item.grid_area_size_cache = grid_area_size;
            item.min_content_contribution_cache.width = new_min_content_contribution;
            item.max_content_contribution_cache.width = null;
            item.minimum_contribution_cache.width = null;

            // Every item must be visited (no early exit): this loop updates each item's caches.
            if (has_changed) intrinsic_column_contribution_changed = true;
        }
        rerun_column_sizing = intrinsic_column_contribution_changed;
    } else {
        // Clear intrinsic width caches
        for (items.items) |*item| {
            item.grid_area_size_cache = null;
            item.min_content_contribution_cache.width = null;
            item.max_content_contribution_cache.width = null;
            item.minimum_contribution_cache.width = null;
        }
    }

    // Row sizing must be re-run (once) if:
    //   - The grid container's height is indefinite and there are any rows with
    //     percentage track sizing functions
    //   - Column sizing was re-run and any grid item crossing an intrinsically sized
    //     track's min content contribution height has changed
    const parent_height_indefinite = outer_node_size.height == null;
    var rerun_row_sizing = parent_height_indefinite and has_percentage_row;
    var intrinsic_row_contribution_changed = false;

    if (rerun_row_sizing) {
        // Clear intrinsic height caches
        for (items.items) |*item| {
            item.grid_area_size_cache = null;
            item.min_content_contribution_cache.height = null;
            item.max_content_contribution_cache.height = null;
            item.minimum_contribution_cache.height = null;
        }
    }

    if (rerun_column_sizing) {
        // Re-run track sizing algorithm for Inline axis
        track_sizing.track_sizing_algorithm(
            Tree,
            tree_ref,
            .inline_axis,
            inner_min_size.get(.inline_axis),
            inner_max_size.get(.inline_axis),
            justify_content,
            align_content,
            available_grid_space,
            inner_node_size,
            columns.items,
            rows.items,
            items.items,
            estimate_track_base_size(Tree),
            has_baseline_aligned_item);

        // The column widths may have changed, so the items' intrinsic height
        // contributions need recomputing (unless row sizing is re-run anyway, in
        // which case the caches have already been cleared).
        if (!rerun_row_sizing) {
            for (items.items) |*item| {
                if (!item.crosses_intrinsic_row) continue;
                const grid_area_size = item.grid_area_size(Tree, .block, rows.items, columns.items, inner_node_size, estimate_track_base_size(Tree), tree_ref);
                const available_space = grid_area_size.with(.block, null);
                const new_min_content_contribution = item.min_content_contribution(Tree, .block, tree_ref, grid_area_size, available_space);

                const has_changed = @as(?f32, new_min_content_contribution) != item.min_content_contribution_cache.height;

                item.grid_area_size_cache = grid_area_size;
                item.min_content_contribution_cache.height = new_min_content_contribution;
                item.max_content_contribution_cache.height = null;
                item.minimum_contribution_cache.height = null;

                // Every item must be visited (no early exit): this loop updates each item's caches.
                if (has_changed) intrinsic_row_contribution_changed = true;
            }
            rerun_row_sizing = intrinsic_row_contribution_changed;
        }
    }

    if (rerun_row_sizing) {
        // Re-run track sizing algorithm for Block axis
        track_sizing.track_sizing_algorithm(
            Tree,
            tree_ref,
            .block,
            inner_min_size.get(.block),
            inner_max_size.get(.block),
            align_content,
            justify_content,
            available_grid_space,
            inner_node_size,
            rows.items,
            columns.items,
            items.items,
            estimate_track_base_size(Tree),
            false, // TODO: Support baseline alignment in the vertical axis
        );
    }

    if ((intrinsic_column_contribution_changed and !has_percentage_column) or
        (intrinsic_row_contribution_changed and !has_percentage_row))
    {
        var final_column_sum: f32 = 0;
        for (columns.items) |track| final_column_sum += track.base_size;
        var final_row_sum: f32 = 0;
        for (rows.items) |track| final_row_sum += track.base_size;

        if (intrinsic_column_contribution_changed and !has_percentage_column) {
            container_border_box.width = maybe_clamp_and_max(
                resolved_style_size.width orelse (final_column_sum + content_box_inset.horizontal_axis_sum()),
                min_size.width,
                max_size.width,
                padding_border_size.width);
            container_content_box.width = math.f32_max(0, container_border_box.width - content_box_inset.horizontal_axis_sum());
        }

        if (intrinsic_row_contribution_changed and !has_percentage_row) {
            container_border_box.height = maybe_clamp_and_max(
                resolved_style_size.height orelse (final_row_sum + content_box_inset.vertical_axis_sum()),
                min_size.height,
                max_size.height,
                padding_border_size.height);
            container_content_box.height = math.f32_max(0, container_border_box.height - content_box_inset.vertical_axis_sum());
        }
    }

    // If only the container's size has been requested
    if (inputs.run_mode == .compute_size) {
        return layout.LayoutOutput.from_outer_size(container_border_box);
    }

    // 8. Track Alignment

    // Align columns
    const inline_size_without_scrollbar = math.f32_max(container_border_box.width - padding_border_size.width, 0);
    const inline_scrollbar_gutter_for_alignment = math.f32_min(scrollbar_gutter.x, inline_size_without_scrollbar);
    alignment.align_tracks(
        container_content_box.width,
        .{
            .start = padding.left + (if (direction.is_rtl()) inline_scrollbar_gutter_for_alignment else 0),
            .end = padding.right + (if (direction.is_rtl()) 0 else inline_scrollbar_gutter_for_alignment),
        },
        .{ .start = border.left, .end = border.right },
        columns.items,
        justify_content,
        direction.is_rtl());
    // Align rows
    alignment.align_tracks(
        container_content_box.height,
        .{ .start = padding.top, .end = padding.bottom },
        .{ .start = border.top, .end = border.bottom },
        rows.items,
        align_content,
        false);

    // 9. Size, Align, and Position Grid Items

    var item_overflow_rect = geometry.Rect(f32){ .left = 0, .right = 0, .top = 0, .bottom = 0 };

    const container_alignment_styles = geometry.InBothAbsAxis(?style.alignment.AlignItems){
        .horizontal = justify_items,
        .vertical = align_items,
    };

    // Position in-flow children (stored in items vector). Items are not sorted
    // back into source order: each item carries its original child index and
    // uses it as `Layout.order`, which avoids two full sorts of 424-byte
    // structs per layout.
    for (items.items, 0..) |*item, index| {
        _ = index;
        // Tracks are stored in logical order. In RTL the physical offsets are assigned
        // right-to-left, so an item's physical left edge is derived from its logical end
        // line and its physical right edge from its logical start line.
        const grid_area = geometry.Rect(f32){
            .top = rows.items[@as(usize, item.row_indexes.start) + 1].offset,
            .bottom = rows.items[item.row_indexes.end].offset,
            .left = if (direction.is_rtl())
                columns.items[@as(usize, item.column_indexes.end) - 1].offset
            else
                columns.items[@as(usize, item.column_indexes.start) + 1].offset,
            .right = if (direction.is_rtl())
                columns.items[item.column_indexes.start].offset
            else
                columns.items[item.column_indexes.end].offset,
        };
        const result = try alignment.align_and_position_item(
            Tree,
            tree_ref,
            item.node,
            item.source_order,
            grid_area,
            container_alignment_styles,
            item.baseline_shim,
            direction,
            container_border_box.width,
            border,
            is_scroll_container,
            &item.oof_candidates);
        item.y_position = result.y;
        item.height = result.height;
        item_overflow_rect = item_overflow_rect.@"union"(result.contribution);
    }

    // Detailed grid information (`detailed_layout_info` feature, default-on in
    // Taffy): resolved track lists and 1-indexed item areas.
    {
        const allocator = tree_ref.allocator;
        const detailed = try allocator.create(DetailedGridInfo);
        errdefer allocator.destroy(detailed);
        detailed.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        const detail_alloc = detailed.arena.allocator();
        const row_line_names = try name_resolver.detailed_line_names(detail_alloc, .vertical);
        const column_line_names = try name_resolver.detailed_line_names(detail_alloc, .horizontal);
        const item_infos = try detail_alloc.alloc(DetailedGridItemsInfo, items.items.len);
        // `DetailedGridInfo.items` is indexed by the item's position in document
        // order among the grid's in-flow items, which is the order `items` is built
        // in (`source_order` is the full child index and may have gaps).
        for (items.items, 0..) |item, item_index| {
            item_infos[item_index] = .{
                .row_start = @intCast(item.row_indexes.start / 2 + 1),
                .row_end = @intCast(item.row_indexes.end / 2 + 1),
                .column_start = @intCast(item.column_indexes.start / 2 + 1),
                .column_end = @intCast(item.column_indexes.end / 2 + 1),
            };
        }
        detailed.rows = try DetailedGridTracksInfo.from_grid_tracks_and_track_count(detail_alloc, final_row_counts_value, rows.items, row_line_names);
        detailed.columns = try DetailedGridTracksInfo.from_grid_tracks_and_track_count(detail_alloc, final_col_counts_value, columns.items, column_line_names);
        detailed.items = item_infos;
        // The out-of-flow positioning pass runs after this algorithm and needs to
        // resolve named grid placements for out-of-flow boxes whose containing
        // block is this grid. That pass reads the *detailed* info, which outlives
        // the scratch arena this resolver lives in, so the line-name maps are
        // deep-copied into the detail arena first.
        detailed.line_names = try name_resolver.toOwnedIndex(detail_alloc);
        try LayoutTree(Tree).set_detailed_layout_info(tree_ref, node_id, @ptrCast(detailed), deinitDetailedGridInfo);
    }

    // Position hidden children and emit out-of-flow children as candidates for the
    // out-of-flow positioning pass (`oof.compute_oof_layout`), which lays out those for
    // which this grid is the containing block after this algorithm has run (resolving
    // their grid areas from the detailed grid info recorded above).
    //
    // Candidates are collected in document order: direct out-of-flow children interleaved
    // with candidates bubbled from in-flow children's subtrees (`items` is in child-index
    // order).
    var oof_candidates: layout.OofCandidates = .empty;
    var order: u32 = @intCast(items.items.len);
    var in_flow_index: usize = 0;
    const containing_block_claims = node_style.is_containing_block();
    const child_count = try TreeApi.child_count(tree_ref, node_id);
    for (0..child_count) |index| {
        if (in_flow_index < items.items.len and items.items[in_flow_index].source_order == index) {
            try oof.appendCandidates(scratch, &oof_candidates, &items.items[in_flow_index].oof_candidates);
            in_flow_index += 1;
            continue;
        }

        const child = try TreeApi.child_at(tree_ref, node_id, index);
        const child_style = TreeApi.get_style(tree_ref, child);

        // Position hidden child
        if (child_style.box_generation_mode() == .none) {
            try TreeApi.set_unrounded_layout(tree_ref, child, layout.Layout.with_order(order));
            _ = try TreeApi.perform_child_layout(tree_ref, 
                child,
                .{ .width = null, .height = null },
                .{ .width = null, .height = null },
                .{ .width = .max_content, .height = .max_content },
                .inherent_size,
                .{ .start = false, .end = false });
            order += 1;
            continue;
        }

        if (!child_style.position.is_out_of_flow()) continue;

        const position = child_style.position;
        // `self-start`/`self-end` resolve against the *item's own* direction relative
        // to the container's, so they must be resolved before the static position is
        // derived from them.
        const item_direction = child_style.direction;
        const x_alignment = (if (child_style.justify_self) |value|
            common.alignment.resolve_self_relative(value, item_direction, direction, true)
        else if (container_alignment_styles.horizontal) |value|
            common.alignment.resolve_self_relative(value, item_direction, direction, true)
        else
            style.alignment.AlignItems.START);
        const y_alignment = (if (child_style.align_self) |value|
            common.alignment.resolve_self_relative(value, item_direction, direction, false)
        else if (container_alignment_styles.vertical) |value|
            common.alignment.resolve_self_relative(value, item_direction, direction, false)
        else
            style.alignment.AlignItems.START);

        // The static-position rectangle: the grid area determined by the grid-placement
        // properties when this grid is the child's containing block, and otherwise the
        // grid's content box, as if the child were the sole grid item in a grid area
        // coinciding with the grid's content edges (grid placement does not apply when the
        // grid is not the containing block.
        // https://www.w3.org/TR/css-grid-1/#static-position
        const area = if (containing_block_claims.for_position(position))
            resolve_static_position_grid_area(
                child_style,
                &name_resolver,
                final_row_counts_value,
                final_col_counts_value,
                rows.items,
                columns.items,
                direction,
                border,
                scrollbar_gutter,
                container_border_box)
        else
            geometry.Rect(f32){
                .left = border.left + padding.left + if (direction.is_rtl()) scrollbar_gutter.x else 0.0,
                .right = container_border_box.width - border.right - padding.right - if (direction.is_rtl()) 0.0 else scrollbar_gutter.x,
                .top = border.top + padding.top,
                .bottom = container_border_box.height - border.bottom - padding.bottom - scrollbar_gutter.y,
            };

        try oof_candidates.append(scratch, .{
            .node = child,
            .order = order,
            .position = position,
            .static_position = .{
                .x = static_position_for_axis(x_alignment, .{ .start = area.left, .end = area.right }, direction.is_rtl()),
                .y = static_position_for_axis(y_alignment, .{ .start = area.top, .end = area.bottom }, false),
            },
        });

        order += 1;
    }

    const absolute_position_inset = border.add(geometry.Rect(f32){
        .left = if (direction.is_rtl()) scrollbar_gutter.x else 0.0,
        .right = if (direction.is_rtl()) 0.0 else scrollbar_gutter.x,
        .top = 0.0,
        .bottom = scrollbar_gutter.y,
    });
    const oof_positioning_area = layout.OofPositioningArea{
        .size = container_border_box.sub(absolute_position_inset.sum_axes()),
        .offset = .{ .x = absolute_position_inset.left, .y = absolute_position_inset.top },
    };

    // If there are no in-flow items then return the container size and the overflow
    // (no baseline)
    if (items.items.len == 0) {
        var overflow_rect = item_overflow_rect;
        if (is_scroll_container) {
            overflow_rect.right += if (direction.is_rtl()) padding.left else padding.right;
            overflow_rect.bottom += padding.bottom;
        }
        return layout.LayoutOutput{
            .size = container_border_box,
            .scrollable_overflow_rect = overflow_rect,
            .oof_candidates = oof_candidates,
            .oof_positioning_area = oof_positioning_area,
        };
    }

    // Determine the grid container baseline(s) (currently we only compute the first baseline).
    // Layout containment suppresses the box's baseline for baseline-alignment purposes.
    const grid_container_baseline: ?f32 = if (contain.suppresses_baseline()) null else blk: {
        // Select the first row (smallest row start) and then, in source order,
        // the first item participating in baseline alignment (or the first item
        // of that row). A min-scan replaces the port's full sort by row start.
        var first_row: u16 = std.math.maxInt(u16);
        for (items.items) |item| first_row = @min(first_row, item.row_indexes.start);

        var first_of_row: ?GridItem = null;
        var participant: ?GridItem = null;
        for (items.items) |item| {
            if (item.row_indexes.start != first_row) continue;
            if (first_of_row == null or item.source_order < first_of_row.?.source_order) first_of_row = item;
            if (item.participates_in_baseline_alignment()) {
                if (participant == null or item.source_order < participant.?.source_order) participant = item;
            }
        }
        const selected = participant orelse first_of_row orelse break :blk null;
        break :blk selected.y_position + (selected.baseline orelse selected.height);
    };

    // A scroll container's own padding at the end of the content is part of its
    // scrollable overflow region. The out-of-flow contribution is merged in by the
    // out-of-flow positioning pass, which owns the out-of-flow boxes' geometry.
    var scrollable_overflow_rect = item_overflow_rect;
    if (is_scroll_container) {
        scrollable_overflow_rect.right += if (direction.is_rtl()) padding.left else padding.right;
        scrollable_overflow_rect.bottom += padding.bottom;
    }

    return layout.LayoutOutput{
        .size = container_border_box,
        .scrollable_overflow_rect = scrollable_overflow_rect,
        .baselines = layout.Baselines.from_first(grid_container_baseline),
        .oof_candidates = oof_candidates,
        .oof_positioning_area = oof_positioning_area,
    };
}

/// Resolve the static-position rectangle (the grid area determined by the grid-placement
/// properties) for an out-of-flow child of a positioned grid container.
///
/// Content alignment (align-content/justify-content) may distribute free space before,
/// between, or after tracks. Grid lines used by absolutely positioned items resolve to the
/// edges of the tracks adjacent to the line rather than to the raw gutter offset:
///   - As a start edge, a line resolves to the start of the track that follows it
///   - As an end edge, a line resolves to the end of the track that precedes it
fn resolve_static_position_grid_area(
    child_style: *const style.Style,
    name_resolver: *const NamedLineResolver,
    final_row_counts: TrackCounts,
    final_col_counts: TrackCounts,
    rows: []const GridTrack,
    columns: []const GridTrack,
    direction: style.Direction,
    border: geometry.Rect(f32),
    scrollbar_gutter: geometry.Point(f32),
    container_border_box: geometry.Size(f32)) geometry.Rect(f32) {
    // Convert grid-col-{start/end} into Option's of indexes into the columns vector
    // The Option is None if the style property is Auto and an unresolvable Span
    const resolved_cols = name_resolver.resolve_column_names(child_style.grid_column);
    const col_oz = resolve_line_origin_zero(resolved_cols, final_col_counts.explicit);
    const col_abs = grid.origin_zero_line_resolve_absolutely_positioned_grid_tracks(col_oz);
    const maybe_col_indexes = geometry.Line(?usize){
        .start = if (col_abs.start) |line| (coordinates.OriginZeroLine{ .value = line }).try_into_track_vec_index(final_col_counts) else null,
        .end = if (col_abs.end) |line| (coordinates.OriginZeroLine{ .value = line }).try_into_track_vec_index(final_col_counts) else null,
    };
    // Convert grid-row-{start/end} into Option's of indexes into the row vector
    const resolved_rows = name_resolver.resolve_row_names(child_style.grid_row);
    const row_oz = resolve_line_origin_zero(resolved_rows, final_row_counts.explicit);
    const row_abs = grid.origin_zero_line_resolve_absolutely_positioned_grid_tracks(row_oz);
    const maybe_row_indexes = geometry.Line(?usize){
        .start = if (row_abs.start) |line| (coordinates.OriginZeroLine{ .value = line }).try_into_track_vec_index(final_row_counts) else null,
        .end = if (row_abs.end) |line| (coordinates.OriginZeroLine{ .value = line }).try_into_track_vec_index(final_row_counts) else null,
    };

    // In RTL the item's physical left edge derives from its logical end line and its
    // physical right edge from its logical start line.
    const grid_area_left: f32 = if (direction.is_rtl())
        (if (maybe_col_indexes.end) |col_index| rtl_line_as_end_edge(columns, col_index) else border.left + scrollbar_gutter.x)
    else
        (if (maybe_col_indexes.start) |col_index| line_as_start_edge(columns, col_index) else border.left);
    const grid_area_right: f32 = if (direction.is_rtl())
        (if (maybe_col_indexes.start) |col_index| rtl_line_as_start_edge(columns, col_index) else container_border_box.width - border.right)
    else
        (if (maybe_col_indexes.end) |col_index| line_as_end_edge(columns, col_index) else container_border_box.width - border.right - scrollbar_gutter.x);

    return geometry.Rect(f32){
        .top = if (maybe_row_indexes.start) |row_index| line_as_start_edge(rows, row_index) else border.top,
        .bottom = if (maybe_row_indexes.end) |row_index| line_as_end_edge(rows, row_index) else container_border_box.height - border.bottom - scrollbar_gutter.y,
        .left = grid_area_left,
        .right = grid_area_right,
    };
}

/// Compute the static position for a single axis of an out-of-flow grid child.
fn static_position_for_axis(
    self_alignment: style.alignment.AlignSelf,
    area: geometry.Line(f32),
    axis_is_rtl: bool) layout.AxisStaticPosition {
    const edge_for = struct {
        fn call(keyword: style.alignment.AlignItemsKeyword, is_rtl: bool) layout.AxisStaticEdge {
            // Stretch does not apply to absolutely positioned items and falls
            // back to start-alignment for static-position purposes
            const start_position = !(keyword == .end or keyword == .flex_end) != is_rtl;
            return switch (keyword) {
                .center => .center,
                else => if (start_position) .start else .end,
            };
        }
    }.call;
    return .{
        .area = area,
        .alignment = .{
            .keyword = edge_for(self_alignment.keyword, axis_is_rtl),
            .safety = self_alignment.safety,
            .fallback = edge_for(common.alignment.resolve_self_alignment_safety(self_alignment, true), axis_is_rtl),
        },
    };
}

/// Resolve the named/span placement to origin-zero coordinates for `explicit` tracks.
fn resolve_line_origin_zero(value: geometry.Line(grid.GridPlacement), explicit: u16) geometry.Line(grid.GridPlacement) {
    return .{
        .start = grid.into_origin_zero_placement(value.start, explicit),
        .end = grid.into_origin_zero_placement(value.end, explicit),
    };
}

fn line_as_start_edge(tracks: []const GridTrack, index: usize) f32 {
    if (index + 1 < tracks.len) return tracks[index + 1].offset;
    return tracks[index].offset;
}

fn line_as_end_edge(tracks: []const GridTrack, index: usize) f32 {
    if (index == 0) {
        if (tracks.len > 1) return tracks[1].offset;
        return tracks[0].offset;
    }
    return tracks[index].offset;
}

fn rtl_line_as_start_edge(tracks: []const GridTrack, index: usize) f32 {
    if (tracks.len > index + 1) {
        // The gutter's offset is the physical right edge of the track that follows the line
        return tracks[index].offset;
    } else if (index == 0) {
        return tracks[0].offset;
    } else {
        return tracks[index - 1].offset;
    }
}

fn rtl_line_as_end_edge(tracks: []const GridTrack, index: usize) f32 {
    if (index == 0) return tracks[0].offset;
    return tracks[index - 1].offset;
}

fn map_definite_value(value: AvailableSpace, subtract: f32) AvailableSpace {
    return switch (value) {
        .definite => |space| .{ .definite = space - subtract },
        else => value,
    };
}

fn resolve_rect_or_zero_length_percentage(value: geometry.Rect(style.dimension.LengthPercentage), basis: ?f32) geometry.Rect(f32) {
    const resolved_basis = basis orelse 0;
    return .{
        .left = value.left.resolve(resolved_basis),
        .right = value.right.resolve(resolved_basis),
        .top = value.top.resolve(resolved_basis),
        .bottom = value.bottom.resolve(resolved_basis),
    };
}

fn add_rects(a: geometry.Rect(f32), b: geometry.Rect(f32)) geometry.Rect(f32) {
    return .{ .left = a.left + b.left, .right = a.right + b.right, .top = a.top + b.top, .bottom = a.bottom + b.bottom };
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
        else => null,
    };
}

fn resolve_lpa_size(value: geometry.Size(style.dimension.LengthPercentageAuto), basis: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = resolve_lpa(value.width, basis.width), .height = resolve_lpa(value.height, basis.height) };
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

fn maybe_clamp_size(value: geometry.Size(?f32), minimum: geometry.Size(?f32), maximum: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{
        .width = math.option_maybe_clamp(value.width, minimum.width, maximum.width),
        .height = math.option_maybe_clamp(value.height, minimum.height, maximum.height),
    };
}

fn or_size(value: geometry.Size(?f32), alternative: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = value.width orelse alternative.width, .height = value.height orelse alternative.height };
}

fn maybe_clamp_and_max(value: f32, minimum: ?f32, maximum: ?f32, floor: f32) f32 {
    return @max(math.f32_maybe_clamp(value, minimum, maximum), floor);
}

test {
    _ = @import("alignment.zig");
    _ = @import("explicit_grid.zig");
    _ = @import("implicit_grid.zig");
    _ = @import("placement.zig");
    _ = @import("track_sizing.zig");
    _ = @import("types/root.zig");
}

test "grid track alignment distributes inline free space" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(10) } });
    const columns = [_]grid.GridTemplateComponent{.{ .single = grid.TrackSizingFunction.from_length(20) }};
    const rows = [_]grid.GridTemplateComponent{.{ .single = grid.TrackSizingFunction.from_length(10) }};
    const root = try tree_ref.new_with_children(.{
        .display = .grid,
        .size = .{ .width = .length(100), .height = .length(50) },
        .grid_template_columns = &columns,
        .grid_template_rows = &rows,
        .justify_content = style.alignment.AlignContent.center,
    }, &[_]NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(child)).location.x);
}

test "grid auto rows size implicit tracks from grid-auto-rows" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const first = try tree_ref.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const second = try tree_ref.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const auto_rows = [_]grid.TrackSizingFunction{grid.TrackSizingFunction.from_length(20)};
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_auto_rows = &auto_rows }, &[_]NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 40 } });
    try testing.expectEqual(@as(f32, 20), (try tree_ref.layout_of(second)).location.y);
}

test "grid absolute children use their resolved grid area" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{
        .position = .absolute,
        .inset = .{ .left = .length(5), .right = .auto(), .top = .length(7), .bottom = .auto() },
        .size = .{ .width = .length(20), .height = .length(10) },
        .grid_column = .{ .start = .{ .line = 1 }, .end = .{ .line = 3 } },
        .grid_row = .{ .start = .{ .line = 1 }, .end = .{ .line = 2 } },
    });
    const columns = [_]grid.GridTemplateComponent{
        .{ .single = grid.TrackSizingFunction.from_length(40) },
        .{ .single = grid.TrackSizingFunction.from_length(40) },
    };
    const rows = [_]grid.GridTemplateComponent{.{ .single = grid.TrackSizingFunction.from_length(30) }};
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_template_columns = &columns, .grid_template_rows = &rows }, &[_]NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 80 }, .height = .{ .definite = 30 } });
    const result = try tree_ref.layout_of(child);
    try testing.expectEqual(@as(f32, 5), result.location.x);
    try testing.expectEqual(@as(f32, 7), result.location.y);
}

test "grid preserves a negative implicit column during placement" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{
        .size = .{ .width = .length(10), .height = .length(10) },
        .grid_column = .{ .start = .{ .line = -4 }, .end = .auto },
        .grid_row = .{ .start = .{ .line = 1 }, .end = .auto },
    });
    const columns = [_]grid.GridTemplateComponent{
        .{ .single = grid.TrackSizingFunction.from_length(20) },
        .{ .single = grid.TrackSizingFunction.from_length(20) },
    };
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_template_columns = &columns }, &[_]NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 10), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(child)).location.x);
}

test "grid child layout receives resolved area for percentage descendants" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const grandchild = try tree_ref.new_leaf(.{ .size = .{ .width = .percent(1), .height = .length(10) } });
    const child = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .percent(0.5), .height = .length(20) } }, &[_]NodeId{grandchild});
    const columns = [_]grid.GridTemplateComponent{.{ .single = grid.TrackSizingFunction.from_length(80) }};
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_template_columns = &columns }, &[_]NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 80 }, .height = .{ .definite = 30 } });
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(grandchild)).size.width);
}

test "detailed grid tracks resolve absolute grid areas" {
    const testing = std.testing;
    var tracks = [_]GridTrack{
        GridTrack.gutter(.zero()),
        GridTrack.new(.length(20), .length(20)),
        GridTrack.gutter(.zero()),
        GridTrack.new(.length(30), .length(30)),
        GridTrack.gutter(.zero()),
    };
    tracks[1].offset = 0;
    tracks[1].base_size = 20;
    tracks[3].offset = 20;
    tracks[3].base_size = 30;
    const info = try DetailedGridTracksInfo.from_grid_tracks_and_track_count(
        testing.allocator,
        TrackCounts.from_raw(0, 2, 0),
        &tracks,
        &[_][]const []const u8{ &.{}, &.{}, &.{} });
    defer testing.allocator.free(info.positions);
    defer testing.allocator.free(info.sizes);
    const area = info.resolve_absolute_grid_axis(.{ .start = .{ .line = 1 }, .end = .{ .line = 3 } }, 0, 50, false, .horizontal, null);
    try testing.expectEqual(@as(f32, 0), area.start);
    try testing.expectEqual(@as(f32, 50), area.end);
}

test "grid excludes display-none children from placement" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const hidden = try tree_ref.new_leaf(.{ .display = .none, .size = .{ .width = .length(90), .height = .length(10) } });
    const visible = try tree_ref.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .grid }, &[_]NodeId{ hidden, visible });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(visible)).location.x);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(hidden)).size.width);
}

test "grid gap offsets the second column" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const first = try tree_ref.new_leaf(.{ .size = .{ .width = .length(40), .height = .length(10) } });
    const second = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(10) } });
    const columns = [_]grid.GridTemplateComponent{
        .{ .single = grid.TrackSizingFunction.from_length(40) },
        .{ .single = grid.TrackSizingFunction.from_length(20) },
    };
    const root = try tree_ref.new_with_children(.{
        .display = .grid,
        .grid_template_columns = &columns,
        .gap = .{ .width = style.dimension.LengthPercentage.length(10), .height = style.dimension.LengthPercentage.length(0) },
    }, &[_]NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(first)).location.x);
    try testing.expectEqual(@as(f32, 50), (try tree_ref.layout_of(second)).location.x);
}

test "grid fr track subtracts container padding" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{});
    const columns = [_]grid.GridTemplateComponent{
        .{ .single = grid.TrackSizingFunction.from_fr(1) },
    };
    const root = try tree_ref.new_with_children(.{
        .display = .grid,
        .size = .{ .width = .length(100), .height = .length(20) },
        .padding = .{
            .left = style.dimension.LengthPercentage.length(10),
            .right = style.dimension.LengthPercentage.length(10),
            .top = style.dimension.LengthPercentage.length(0),
            .bottom = style.dimension.LengthPercentage.length(0),
        },
        .grid_template_columns = &columns,
    }, &[_]NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 80), (try tree_ref.layout_of(child)).size.width);
}
