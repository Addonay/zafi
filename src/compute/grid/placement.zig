//! Direct port of Taffy's `compute/grid/placement.rs`.
//!
//! Implements placing items in the grid and resolving the implicit grid:
//! <https://www.w3.org/TR/css-grid-1/#placement>

const std = @import("std");
const geometry = @import("../../geometry.zig");
const style = @import("../../style/root.zig");
const grid = @import("../../style/grid.zig");
const NodeId = @import("../../tree/node.zig").NodeId;
const LayoutTree = @import("../../tree/interfaces.zig").LayoutTree;
const tree = @import("../../tree/tree.zig");
const coordinates = @import("types/coordinates.zig");
const cell_occupancy = @import("types/cell_occupancy.zig");
const grid_item = @import("types/grid_item.zig");
const named = @import("types/named.zig");

const OriginZeroLine = coordinates.OriginZeroLine;
const GridItem = grid_item.GridItem;
const InFlowChild = grid_item.InFlowChild;
const GridPlacement = grid.GridPlacement;
const CellOccupancyState = cell_occupancy.CellOccupancyState;
const CellOccupancyMatrix = cell_occupancy.CellOccupancyMatrix;
const NamedLineResolver = named.NamedLineResolver;

const MIN_OZ_LINE: i16 = -10_000;
const MAX_OZ_LINE: i16 = 10_000;

/// Advances the cursor by one track.
inline fn advance_position(position: OriginZeroLine) OriginZeroLine {
    return .{ .value = position.value +| 1 };
}

/// Resolves an indefinite span starting at `position`.
inline fn resolve_indefinite_grid_span(position: OriginZeroLine, span: u16) geometry.Line(OriginZeroLine) {
    const position_i32: i32 = position.value;
    const span_i32: i32 = span;
    const line = struct {
        fn clamp(value: i32) OriginZeroLine {
            return .{ .value = @intCast(std.math.clamp(value, @as(i32, std.math.minInt(i16)), @as(i32, std.math.maxInt(i16)))) };
        }
    }.clamp;
    return .{ .start = line(position_i32), .end = line(position_i32 + span_i32) };
}

/// An item's placement in both axes, named lines resolved, in origin-zero coordinates.
pub const AxisPlacement = geometry.InBothAbsAxis(geometry.Line(GridPlacement));

fn placement_get(placement: AxisPlacement, axis: geometry.AbsoluteAxis) geometry.Line(GridPlacement) {
    return if (axis == .horizontal) placement.horizontal else placement.vertical;
}

/// `Line<OriginZeroGridPlacement>::is_definite` — definite if either edge is a line.
fn placement_definite(placement: geometry.Line(GridPlacement)) bool {
    return grid.origin_zero_line_is_definite(placement);
}

/// 8.5. Grid Item Placement Algorithm
/// Place items into the grid, generating new rows/column into the implicit grid as required.
pub fn place_grid_items(
    comptime Tree: type,
    allocator: std.mem.Allocator,
    cell_occupancy_matrix: *CellOccupancyMatrix,
    items: *std.ArrayList(GridItem),
    /// In-flow children paired with their index in the container's *full* child list,
    /// so `GridItem.source_order` is the document child index.
    in_flow_children: []const InFlowChild,
    tree_ref: *Tree,
    grid_auto_flow: grid.GridAutoFlow,
    align_items: style.alignment.AlignItems,
    justify_items: style.alignment.AlignItems,
    /// Each child's resolved placement (from `resolve_child_placement`), computed
    /// once before the grid size estimate (Taffy 4f18a82).
    placements: []const AxisPlacement,
) !void {
    const TreeApi = LayoutTree(Tree);
    const primary_axis = grid.primary_axis(grid_auto_flow);
    const secondary_axis = primary_axis.other_axis();
    std.debug.assert(placements.len == in_flow_children.len);

    // Resolve every child's placement and style pointer once. The three
    // placement passes below are pure with respect to occupancy, and the
    // literal port re-resolved (a map lookup plus a ~700-byte style copy) per
    // child per pass. Style pointers are stable for the pass: layout never
    // creates nodes.
    const child_count = in_flow_children.len;
    // Every child produces exactly one grid item; reserving once avoids the
    // ArrayList doubling copies of the 424-byte GridItem struct.
    try items.ensureTotalCapacity(allocator, child_count);
    const styles = try allocator.alloc(TreeApi.StyleRef, child_count);
    defer allocator.free(styles);
    for (in_flow_children, 0..) |entry, child_index| {
        const child_id = entry.node;
        const node_style = TreeApi.get_style(tree_ref, child_id);
        styles[child_index] = node_style;
    }

    // 1. Place children with definite positions
    for (in_flow_children, 0..) |entry, child_index| {
        const child_style = styles[child_index];
        const placement = placements[child_index];
        if (!placement_definite(placement.horizontal) or !placement_definite(placement.vertical)) continue;
        const spans = place_definite_grid_item(placement, primary_axis);
        try record_grid_placement(
            cell_occupancy_matrix,
            items,
            allocator,
            entry.node,
            entry.source_order,
            child_style,
            align_items,
            justify_items,
            primary_axis,
            spans.primary,
            spans.secondary,
            .definitely_placed,
        );
    }

    // 2. Place remaining children with definite secondary axis positions
    for (in_flow_children, 0..) |entry, child_index| {
        const child_style = styles[child_index];
        const placement = placements[child_index];
        if (!placement_definite(placement_get(placement, secondary_axis)) or placement_definite(placement_get(placement, primary_axis))) continue;
        const spans = place_definite_secondary_axis_item(cell_occupancy_matrix, placement, grid_auto_flow);
        try record_grid_placement(
            cell_occupancy_matrix,
            items,
            allocator,
            entry.node,
            entry.source_order,
            child_style,
            align_items,
            justify_items,
            primary_axis,
            spans.primary,
            spans.secondary,
            .auto_placed,
        );
    }

    // 3. Determine the number of columns in the implicit grid: handled by the
    // grid size estimate and `expand_to_fit_range` during recording.

    // 4. Position the remaining grid items
    const primary_axis_grid_start_line = cell_occupancy_matrix.track_counts(primary_axis).implicit_start_line();
    const secondary_axis_grid_start_line = cell_occupancy_matrix.track_counts(secondary_axis).implicit_start_line();
    const grid_start_position = .{ primary_axis_grid_start_line, secondary_axis_grid_start_line };
    var grid_position = grid_start_position;
    for (in_flow_children, 0..) |entry, child_index| {
        const child_style = styles[child_index];
        const placement = placements[child_index];
        if (placement_definite(placement_get(placement, secondary_axis))) continue;
        const spans = place_indefinitely_positioned_item(cell_occupancy_matrix, placement, grid_auto_flow, grid_position);
        try record_grid_placement(
            cell_occupancy_matrix,
            items,
            allocator,
            entry.node,
            entry.source_order,
            child_style,
            align_items,
            justify_items,
            primary_axis,
            spans.primary,
            spans.secondary,
            .auto_placed,
        );

        // If using the "dense" placement algorithm then reset the grid position back to
        // grid_start_position ready for the next item; otherwise set it to the position
        // of the current item so that the next item is placed after it.
        grid_position = if (grid.is_dense(grid_auto_flow))
            grid_start_position
        else
            .{ spans.primary.end, spans.secondary.start };
    }
}

pub fn resolve_child_placement(
    named_line_resolver: *const NamedLineResolver,
    child_style: anytype,
    explicit_col_count: u16,
    explicit_row_count: u16,
) AxisPlacement {
    const resolved_h = named_line_resolver.resolve_column_names(child_style.get(.grid_column));
    const resolved_v = named_line_resolver.resolve_row_names(child_style.get(.grid_row));
    return .{
        .horizontal = .{
            .start = grid.into_origin_zero_placement(resolved_h.start, explicit_col_count),
            .end = grid.into_origin_zero_placement(resolved_h.end, explicit_col_count),
        },
        .vertical = .{
            .start = grid.into_origin_zero_placement(resolved_v.start, explicit_row_count),
            .end = grid.into_origin_zero_placement(resolved_v.end, explicit_row_count),
        },
    };
}

const GridItemSpans = struct {
    primary: geometry.Line(OriginZeroLine),
    secondary: geometry.Line(OriginZeroLine),
};

/// Place a single definitely placed item into the grid
fn place_definite_grid_item(placement: AxisPlacement, primary_axis: geometry.AbsoluteAxis) GridItemSpans {
    const primary_span = grid.origin_zero_line_resolve_definite_grid_lines(placement_get(placement, primary_axis));
    const secondary_span = grid.origin_zero_line_resolve_definite_grid_lines(placement_get(placement, primary_axis.other_axis()));
    return .{
        .primary = .{ .start = .{ .value = primary_span.start }, .end = .{ .value = primary_span.end } },
        .secondary = .{ .start = .{ .value = secondary_span.start }, .end = .{ .value = secondary_span.end } },
    };
}

/// Step 2. Place remaining children with definite secondary axis positions
fn place_definite_secondary_axis_item(matrix: *const CellOccupancyMatrix, placement: AxisPlacement, auto_flow: grid.GridAutoFlow) GridItemSpans {
    const primary_axis = grid.primary_axis(auto_flow);
    const secondary_axis = primary_axis.other_axis();
    const primary_axis_grid_start_line = matrix.track_counts(primary_axis).implicit_start_line();

    const secondary_axis_lines = grid.origin_zero_line_resolve_definite_grid_lines(placement_get(placement, secondary_axis));
    const secondary_axis_placement = geometry.Line(OriginZeroLine){
        .start = .{ .value = secondary_axis_lines.start },
        .end = .{ .value = secondary_axis_lines.end },
    };
    const starting_position = if (grid.is_dense(auto_flow))
        primary_axis_grid_start_line
    else
        matrix.auto_placement_cursor(primary_axis, secondary_axis_placement.start) orelse primary_axis_grid_start_line;
    const primary_axis_span = grid.origin_zero_line_indefinite_span(placement_get(placement, primary_axis));

    var position = starting_position;
    while (true) {
        const primary_axis_placement = resolve_indefinite_grid_span(position, primary_axis_span);

        if (matrix.line_area_collision_jump(primary_axis, primary_axis_placement, secondary_axis_placement)) |next_position| {
            position = next_position;
        } else {
            return .{ .primary = primary_axis_placement, .secondary = secondary_axis_placement };
        }
    }
}

/// Step 4. Position the remaining grid items.
fn place_indefinitely_positioned_item(
    matrix: *const CellOccupancyMatrix,
    placement: AxisPlacement,
    auto_flow: grid.GridAutoFlow,
    grid_position: struct { OriginZeroLine, OriginZeroLine },
) GridItemSpans {
    const primary_axis = grid.primary_axis(auto_flow);
    const secondary_axis = primary_axis.other_axis();

    const primary_placement_style = placement_get(placement, primary_axis);
    const secondary_placement_style = placement_get(placement, secondary_axis);

    const secondary_span_count = grid.origin_zero_line_indefinite_span(secondary_placement_style);
    const has_definite_primary_axis_position = placement_definite(primary_placement_style);
    const primary_axis_grid_start_line = matrix.track_counts(primary_axis).implicit_start_line();
    const primary_axis_grid_end_line = matrix.track_counts(primary_axis).implicit_end_line();
    const secondary_axis_grid_start_line = matrix.track_counts(secondary_axis).implicit_start_line();

    var primary_idx = grid_position[0];
    var secondary_idx = grid_position[1];

    if (has_definite_primary_axis_position) {
        const primary_axis_lines = grid.origin_zero_line_resolve_definite_grid_lines(primary_placement_style);
        const primary_span = geometry.Line(OriginZeroLine){
            .start = .{ .value = primary_axis_lines.start },
            .end = .{ .value = primary_axis_lines.end },
        };

        // Compute secondary axis starting position for search
        secondary_idx = if (grid.is_dense(auto_flow))
            secondary_axis_grid_start_line
        else if (primary_span.start.value < primary_idx.value)
            advance_position(secondary_idx)
        else
            secondary_idx;

        // Item has fixed primary axis position: increment the secondary axis position
        // until we find a space that the item fits in
        while (true) {
            const secondary_span = resolve_indefinite_grid_span(secondary_idx, secondary_span_count);

            // If area is occupied, jump the index past the collision and try again
            if (matrix.line_area_collision_jump(secondary_axis, secondary_span, primary_span)) |next_position| {
                secondary_idx = next_position;
                continue;
            }

            // Once we find a free space, return that position
            return .{ .primary = primary_span, .secondary = secondary_span };
        }
    } else {
        const primary_span_count = grid.origin_zero_line_indefinite_span(primary_placement_style);

        // Whether the item spans every track in the primary axis. Such an item can only be
        // placed at the primary axis grid start, in a stripe of entirely unoccupied tracks.
        const spans_all_primary_tracks = @as(usize, primary_span_count) >= matrix.track_counts(primary_axis).len();

        // Item does not have any fixed axis, so we search along the primary axis until we hit
        // the end of the already existent tracks, and then we reset the primary axis back to
        // zero and increment the secondary axis index.
        while (true) {
            const primary_span = resolve_indefinite_grid_span(primary_idx, primary_span_count);
            const secondary_span = resolve_indefinite_grid_span(secondary_idx, secondary_span_count);

            // If the primary index is out of bounds, then increment the secondary index and
            // reset the primary index back to the start of the grid
            const primary_out_of_bounds = primary_span.end.value > primary_axis_grid_end_line.value;
            if (primary_out_of_bounds) {
                if (primary_idx.value == primary_axis_grid_start_line.value) {
                    return .{ .primary = primary_span, .secondary = secondary_span };
                }
                secondary_idx = advance_position(secondary_idx);
                primary_idx = primary_axis_grid_start_line;
                continue;
            }

            // If the item spans every primary axis track, it fits if and only if all of the
            // secondary axis tracks it spans are entirely unoccupied.
            if (spans_all_primary_tracks) {
                if (matrix.occupied_track_jump(secondary_axis, secondary_span)) |next_position| {
                    secondary_idx = next_position;
                    primary_idx = primary_axis_grid_start_line;
                    continue;
                }
                return .{ .primary = primary_span, .secondary = secondary_span };
            }

            // If area is occupied, jump the primary index past the collision and try again
            if (matrix.line_area_collision_jump(primary_axis, primary_span, secondary_span)) |next_position| {
                primary_idx = next_position;
                continue;
            }

            // Once we find a free space that's in bounds, return that position
            return .{ .primary = primary_span, .secondary = secondary_span };
        }
    }
}

/// Clamp a placement into the limited grid, preserving a span of at least 1 track.
fn clamp_span_to_limited_grid(span: geometry.Line(OriginZeroLine)) geometry.Line(OriginZeroLine) {
    const start = std.math.clamp(span.start.value, MIN_OZ_LINE, MAX_OZ_LINE - 1);
    const end = std.math.clamp(span.end.value, start + 1, MAX_OZ_LINE);
    return .{ .start = .{ .value = start }, .end = .{ .value = end } };
}

/// Record the grid item in both the CellOccupancyMatrix and the GridItems list
/// once a definite placement has been determined.
fn record_grid_placement(
    matrix: *CellOccupancyMatrix,
    items: *std.ArrayList(GridItem),
    allocator: std.mem.Allocator,
    node: NodeId,
    source_order: u16,
    item_style: anytype,
    parent_align_items: style.alignment.AlignItems,
    parent_justify_items: style.alignment.AlignItems,
    primary_axis: geometry.AbsoluteAxis,
    primary_span_unclamped: geometry.Line(OriginZeroLine),
    secondary_span_unclamped: geometry.Line(OriginZeroLine),
    placement_type: CellOccupancyState,
) !void {
    // Clamp placements into the limited grid to prevent arithmetic overflow when
    // growing the implicit grid (https://www.w3.org/TR/css-grid-1/#overlarge-grids)
    const primary_span = clamp_span_to_limited_grid(primary_span_unclamped);
    const secondary_span = clamp_span_to_limited_grid(secondary_span_unclamped);

    // Mark area of grid as occupied
    matrix.mark_area_as(primary_axis, primary_span, secondary_span, placement_type);

    // Create grid item
    const col_span = if (primary_axis == .horizontal) primary_span else secondary_span;
    const row_span = if (primary_axis == .horizontal) secondary_span else primary_span;
    // Construct the (large) item directly in its slot rather than on the stack.
    const slot = try items.addOne(allocator);
    slot.* = GridItem.new_with_placement_style_and_order(
        node,
        col_span,
        row_span,
        item_style,
        parent_align_items,
        parent_justify_items,
        source_order,
    );
}

test "placement algorithm handles definite and auto placement" {
    const testing = @import("std").testing;
    var grid_tree = tree.Tree.init(testing.allocator);
    defer grid_tree.deinit();

    const columns = [_]grid.GridTemplateComponent{
        .{ .single = grid.TrackSizingFunction.from_length(40) },
        .{ .single = grid.TrackSizingFunction.from_length(40) },
    };
    const rows = [_]grid.GridTemplateComponent{
        .{ .single = grid.TrackSizingFunction.from_length(40) },
        .{ .single = grid.TrackSizingFunction.from_length(40) },
    };
    const root = try grid_tree.new_leaf(.{ .display = .grid, .grid_template_columns = &columns, .grid_template_rows = &rows });
    const a = try grid_tree.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const b = try grid_tree.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) }, .grid_column = .{ .start = .{ .line = 2 }, .end = .auto } });
    const c = try grid_tree.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    _ = root;
    const in_flow = [_]InFlowChild{ .{ .node = a, .source_order = 0 }, .{ .node = b, .source_order = 1 }, .{ .node = c, .source_order = 2 } };

    const resolver_style = style.Style{ .display = .grid, .grid_template_columns = &columns, .grid_template_rows = &rows };
    var resolver = try NamedLineResolver.init(testing.allocator, &resolver_style, 0, 0);
    defer resolver.deinit();
    resolver.set_explicit_column_count(2);
    resolver.set_explicit_row_count(2);
    var placements: [3]AxisPlacement = undefined;
    for (in_flow, &placements) |entry, *item_placement| item_placement.* = resolve_child_placement(&resolver, grid_tree.get_style(entry.node), 2, 2);

    const estimate = @import("implicit_grid.zig").compute_grid_size_estimate(2, 2, &placements);
    var matrix = CellOccupancyMatrix.with_track_counts_using_allocator(testing.allocator, estimate.columns, estimate.rows);
    defer matrix.deinit();
    var items = std.ArrayList(GridItem).empty;
    defer items.deinit(testing.allocator);

    try place_grid_items(tree.Tree, testing.allocator, &matrix, &items, &in_flow, &grid_tree, .row, .stretch, .stretch, &placements);
    try testing.expectEqual(@as(usize, 3), items.items.len);
    // Item 1 is definite in column 2, so items are placed: a (0,0), b (1,0), c (0,1)
    try testing.expectEqual(@as(i16, 0), items.items[0].column.start.value);
    try testing.expectEqual(@as(i16, 1), items.items[1].column.start.value);
    try testing.expectEqual(@as(i16, 1), items.items[2].row.start.value);
}
