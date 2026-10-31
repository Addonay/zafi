//! Direct port of Taffy's `compute/grid/implicit_grid.rs`.
//!
//! This module is not required for spec compliance, but is used as a
//! performance optimisation to reduce the number of allocations required when
//! creating a grid, and forms a necessary step in the auto-placement algorithm.

const std = @import("std");
const geometry = @import("../../geometry.zig");
const style = @import("../../style/root.zig");
const grid = @import("../../style/grid.zig");
const NodeId = @import("../../tree/node.zig").NodeId;
const LayoutTree = @import("../../tree/interfaces.zig").LayoutTree;
const coordinates = @import("types/coordinates.zig");
const grid_track_counts = @import("types/grid_track_counts.zig");

const OriginZeroLine = coordinates.OriginZeroLine;
const MAX_OZ_LINE: i16 = 10_000;
const MIN_OZ_LINE: i16 = -10_000;

pub const GridSizeEstimate = struct {
    columns: grid_track_counts.TrackCounts,
    rows: grid_track_counts.TrackCounts,
};

/// Estimate the number of rows and columns in the grid.
///
/// The estimates for the explicit and negative implicit track counts are exact.
/// However, the estimate for the positive implicit track count is a lower
/// bound as auto-placement can affect this in ways which are impossible to
/// predict until the auto-placement algorithm is run.
pub fn compute_grid_size_estimate(comptime Tree: type,
    explicit_col_count: u16,
    explicit_row_count: u16,
    child_ids: []const NodeId,
    tree_ref: *const Tree,
) GridSizeEstimate {
    const known = get_known_child_positions(Tree, child_ids, tree_ref, explicit_col_count, explicit_row_count);

    var negative_implicit_inline_tracks = known.col_min.implied_negative_implicit_tracks();
    const explicit_inline_tracks = explicit_col_count;
    var positive_implicit_inline_tracks = known.col_max.implied_positive_implicit_tracks(explicit_col_count);
    var negative_implicit_block_tracks = known.row_min.implied_negative_implicit_tracks();
    const explicit_block_tracks = explicit_row_count;
    var positive_implicit_block_tracks = known.row_max.implied_positive_implicit_tracks(explicit_row_count);

    // In each axis, adjust the positive track estimate if any items have a span
    // that does not fit within the total number of tracks in the estimate
    const tot_inline_tracks = negative_implicit_inline_tracks + explicit_inline_tracks + positive_implicit_inline_tracks;
    if (tot_inline_tracks < known.col_max_span) {
        positive_implicit_inline_tracks = known.col_max_span - explicit_inline_tracks - negative_implicit_inline_tracks;
    }

    const tot_block_tracks = negative_implicit_block_tracks + explicit_block_tracks + positive_implicit_block_tracks;
    if (tot_block_tracks < known.row_max_span) {
        positive_implicit_block_tracks = known.row_max_span - explicit_block_tracks - negative_implicit_block_tracks;
    }

    _ = &negative_implicit_inline_tracks;
    _ = &negative_implicit_block_tracks;

    return .{
        .columns = grid_track_counts.TrackCounts.from_raw(negative_implicit_inline_tracks, explicit_inline_tracks, positive_implicit_inline_tracks),
        .rows = grid_track_counts.TrackCounts.from_raw(negative_implicit_block_tracks, explicit_block_tracks, positive_implicit_block_tracks),
    };
}

const KnownChildPositions = struct {
    col_min: OriginZeroLine,
    col_max: OriginZeroLine,
    col_max_span: u16,
    row_min: OriginZeroLine,
    row_max: OriginZeroLine,
    row_max_span: u16,
};

/// Iterate over children, producing an estimate of the min and max grid lines
/// (in origin-zero coordinates) along with the span of each item (in tracks).
fn get_known_child_positions(comptime Tree: type,
    child_ids: []const NodeId,
    tree_ref: *const Tree,
    explicit_col_count: u16,
    explicit_row_count: u16,
) KnownChildPositions {
    const TreeApi = LayoutTree(Tree);
    var col_min = OriginZeroLine{ .value = 0 };
    var col_max = OriginZeroLine{ .value = 0 };
    var col_max_span: u16 = 0;
    var row_min = OriginZeroLine{ .value = 0 };
    var row_max = OriginZeroLine{ .value = 0 };
    var row_max_span: u16 = 0;

    for (child_ids) |child_id| {
        const child_style = TreeApi.get_style(tree_ref, child_id);
        const col_line = child_style.grid_column;
        const row_line = child_style.grid_row;

        const child_col = child_min_line_max_line_span(col_line, explicit_col_count);
        const child_row = child_min_line_max_line_span(row_line, explicit_row_count);

        col_min = .{ .value = @min(col_min.value, child_col.min.value) };
        col_max = .{ .value = @max(col_max.value, child_col.max.value) };
        col_max_span = @max(col_max_span, child_col.span);
        row_min = .{ .value = @min(row_min.value, child_row.min.value) };
        row_max = .{ .value = @max(row_max.value, child_row.max.value) };
        row_max_span = @max(row_max_span, child_row.span);
    }

    return .{
        .col_min = col_min,
        .col_max = col_max,
        .col_max_span = col_max_span,
        .row_min = row_min,
        .row_max = row_max,
        .row_max_span = row_max_span,
    };
}

const ChildMinMaxLineSpan = struct {
    min: OriginZeroLine,
    max: OriginZeroLine,
    span: u16,
};

/// Conservative estimate of the greatest and smallest grid lines used by a
/// single grid item. Values are returned in origin-zero coordinates.
fn child_min_line_max_line_span(line: geometry.Line(grid.GridPlacement), explicit_track_count: u16) ChildMinMaxLineSpan {
    // Convert line into origin-zero coordinates before attempting to analyze.
    // Named lines are ignored here as they are accounted for separately.
    const oz_line = grid.line_into_origin_zero(line, explicit_track_count);
    const start = oz_line.start;
    const end = oz_line.end;

    const start_is_line = start == .line;
    const end_is_line = end == .line;

    const min: i32 = if (start_is_line and end_is_line)
        (if (start.line == end.line) @as(i32, start.line) else @min(start.line, end.line))
    else if (start_is_line and (end == .auto or end == .span))
        start.line
    else if (end_is_line and start == .auto)
        @as(i32, end.line) - 1
    else if (end_is_line and start == .span)
        @as(i32, end.line) - @as(i32, start.span)
    else
        0;

    const max: i32 = if (start_is_line and end_is_line)
        (if (start.line == end.line) @as(i32, start.line) + 1 else @max(start.line, end.line))
    else if (start_is_line and end == .auto)
        @as(i32, start.line) + 1
    else if (start_is_line and end == .span)
        @as(i32, start.line) + @as(i32, end.span)
    else if (end_is_line)
        end.line
    else
        0;

    const span: u16 = if ((start == .auto or start == .span) and (end == .auto or end == .span))
        grid.origin_zero_line_indefinite_span(oz_line)
    else
        1;

    const clamped_min = clamp_i32_to_i16(@max(min, MIN_OZ_LINE));
    const clamped_max = clamp_i32_to_i16(@min(max, MAX_OZ_LINE));
    return .{ .min = .{ .value = clamped_min }, .max = .{ .value = clamped_max }, .span = span };
}

fn clamp_i32_to_i16(value: i32) i16 {
    return @intCast(@max(@as(i32, std.math.minInt(i16)), @min(@as(i32, std.math.maxInt(i16)), value)));
}

test "child min max line span handles spans and negatives" {
    const testing = @import("std").testing;
    // (line 5, span 6) with 6 explicit tracks
    const result = child_min_line_max_line_span(.{ .start = .{ .line = 5 }, .end = .{ .span = 6 } }, 6);
    try testing.expectEqual(@as(i16, 4), result.min.value);
    try testing.expectEqual(@as(i16, 10), result.max.value);
    try testing.expectEqual(@as(u16, 1), result.span);

    const negative = child_min_line_max_line_span(.{ .start = .{ .line = -5 }, .end = .{ .span = 3 } }, 6);
    try testing.expectEqual(@as(i16, 2), negative.min.value);
    try testing.expectEqual(@as(i16, 5), negative.max.value);
    try testing.expectEqual(@as(u16, 1), negative.span);
}
