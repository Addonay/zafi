//! Sparse cell occupancy from Taffy's `compute/grid/types/cell_occupancy.rs`.
//!
//! The Rust implementation uses `SmallVec` interval runs rather than a dense
//! matrix. The Zig port keeps that same representation: each row and column
//! owns a sorted, disjoint list of occupied OriginZero-coordinate intervals.
//! Painting an area therefore overwrites existing states exactly like the
//! dense CSS-grid placement matrix while avoiding a grid-cell allocation.

const std = @import("std");
const geometry = @import("../../../geometry.zig");
const coordinates = @import("coordinates.zig");
const grid_track_counts = @import("grid_track_counts.zig");

const IntervalRange = struct { start: i16, end: i16 };

pub const CellOccupancy = struct {
    occupied: bool = false,
};

pub const CellOccupancyState = enum {
    unoccupied,
    definitely_placed,
    auto_placed,
};

const OccupiedInterval = struct {
    start: i16,
    end: i16,
    state: CellOccupancyState,

    fn overlaps(self: OccupiedInterval, range: IntervalRange) bool {
        return self.start < range.end and self.end > range.start;
    }
};

const TrackIntervals = struct {
    intervals: std.ArrayList(OccupiedInterval) = .empty,
    /// The furthest end line of an auto-placed item starting in this
    /// secondary-axis track (Taffy's sparse auto-placement cursor).
    auto_placement_cursor: ?i16 = null,

    fn deinit(self: *TrackIntervals, allocator: std.mem.Allocator) void {
        self.intervals.deinit(allocator);
    }

    fn is_empty(self: *const TrackIntervals) bool {
        return self.intervals.items.len == 0;
    }

    fn state_at(self: *const TrackIntervals, coordinate: i16) CellOccupancyState {
        for (self.intervals.items) |interval| {
            if (interval.start <= coordinate and coordinate < interval.end) return interval.state;
        }
        return .unoccupied;
    }

    /// Paint a half-open interval and merge touching intervals of equal state.
    ///
    /// This is the hot path of grid placement. The Rust source rebuilds a
    /// `SmallVec` per paint; in the port that becomes thousands of
    /// allocations per layout, so this implementation rewrites the interval
    /// list in place instead: head entries stay in front, tail entries are
    /// moved backwards, and the painted interval is inserted between them.
    fn paint(self: *TrackIntervals, allocator: std.mem.Allocator, range: IntervalRange, state: CellOccupancyState) void {
        if (range.start >= range.end) return;
        const count = self.intervals.items.len;

        // Worst case: one interval contains the whole painted range and is
        // split into a head part, the new interval, and a tail part, so up to
        // two slots more than the current count are needed.
        if (count + 2 > self.intervals.capacity) {
            self.intervals.ensureTotalCapacity(allocator, count + 2) catch @panic("Taffy occupancy allocation failed");
        }
        // Expose the extra slots while keeping `count` as the logical length
        // for all reads; the final length is set once entries are in place.
        self.intervals.items.len = count + 2;
        const original = self.intervals.items;

        // First interval not wholly before the range, and the first interval
        // whose end extends past the range end. Intervals are sorted and
        // disjoint, so both scans are monotonic.
        var first_overlap: usize = 0;
        while (first_overlap < count and original[first_overlap].end <= range.start) : (first_overlap += 1) {}
        var first_after: usize = first_overlap;
        while (first_after < count and original[first_after].end <= range.end) : (first_after += 1) {}

        const has_head_part = first_overlap < count and original[first_overlap].start < range.start;
        const has_tail_part = first_after < count and original[first_after].start < range.end;
        const head_count = first_overlap + @as(usize, @intFromBool(has_head_part));
        const tail_count = count - first_after;

        // Move tail entries to their final positions, backwards so overlapping
        // moves cannot clobber unread sources (destination >= source always).
        var tail_index = tail_count;
        while (tail_index > 0) {
            tail_index -= 1;
            var entry = original[first_after + tail_index];
            if (tail_index == 0 and has_tail_part) entry.start = range.end;
            original[head_count + 1 + tail_index] = entry;
        }
        // Head entries stay put; trim the one crossing the range start.
        if (has_head_part) original[first_overlap].end = range.start;

        if (head_count > 0 and original[head_count - 1].state == state and original[head_count - 1].end == range.start) {
            // Merge with a touching equal-state head and close the gap the
            // inserted interval would have occupied.
            original[head_count - 1].end = range.end;
            std.mem.copyForwards(OccupiedInterval, original[head_count .. head_count + tail_count], original[head_count + 1 .. head_count + 1 + tail_count]);
            self.intervals.items.len = head_count + tail_count;
        } else {
            original[head_count] = .{ .start = range.start, .end = range.end, .state = state };
            self.intervals.items.len = head_count + 1 + tail_count;
        }
    }

    fn collision_extent(self: *const TrackIntervals, range: IntervalRange) ?i16 {
        var index = self.intervals.items.len;
        while (index > 0) {
            index -= 1;
            const interval = self.intervals.items[index];
            // Intervals are sorted and disjoint: stop once they lie left of the range
            if (interval.end <= range.start) return null;
            if (interval.overlaps(range)) return interval.end - 1;
        }
        return null;
    }
};

pub const CellOccupancyMatrix = struct {
    columns: grid_track_counts.TrackCounts,
    rows: grid_track_counts.TrackCounts,
    row_intervals: std.ArrayList(TrackIntervals),
    column_intervals: std.ArrayList(TrackIntervals),
    allocator: std.mem.Allocator,


    pub fn with_track_counts_using_allocator(allocator: std.mem.Allocator, columns: grid_track_counts.TrackCounts, rows: grid_track_counts.TrackCounts) CellOccupancyMatrix {
        var row_intervals = std.ArrayList(TrackIntervals).empty;
        var column_intervals = std.ArrayList(TrackIntervals).empty;
        for (0..rows.len()) |_| row_intervals.append(allocator, .{}) catch @panic("Taffy occupancy allocation failed");
        for (0..columns.len()) |_| column_intervals.append(allocator, .{}) catch @panic("Taffy occupancy allocation failed");
        return .{
            .columns = columns,
            .rows = rows,
            .row_intervals = row_intervals,
            .column_intervals = column_intervals,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CellOccupancyMatrix) void {
        for (self.row_intervals.items) |*track| track.deinit(self.allocator);
        for (self.column_intervals.items) |*track| track.deinit(self.allocator);
        self.row_intervals.deinit(self.allocator);
        self.column_intervals.deinit(self.allocator);
    }

    /// Compatibility constructor for the early first-pass callers. New code
    /// should pass TrackCounts so negative and positive implicit tracks remain
    /// visible to placement.

    fn track_lists(self: *const CellOccupancyMatrix, axis: geometry.AbsoluteAxis) []const TrackIntervals {
        return switch (axis) {
            .horizontal => self.column_intervals.items,
            .vertical => self.row_intervals.items,
        };
    }

    fn expand_to_fit_range(self: *CellOccupancyMatrix, row_span: geometry.Line(coordinates.OriginZeroLine), col_span: geometry.Line(coordinates.OriginZeroLine)) void {
        const req_negative_rows: u16 = if (row_span.start.value < -@as(i16, @intCast(self.rows.negative_implicit)))
            @intCast(-@as(i32, row_span.start.value) - self.rows.negative_implicit)
        else
            0;
        const req_positive_rows: u16 = if (row_span.end.value > self.rows.implicit_end_line().value)
            @intCast(@as(i32, row_span.end.value) - self.rows.implicit_end_line().value)
        else
            0;
        const req_negative_cols: u16 = if (col_span.start.value < -@as(i16, @intCast(self.columns.negative_implicit)))
            @intCast(-@as(i32, col_span.start.value) - self.columns.negative_implicit)
        else
            0;
        const req_positive_cols: u16 = if (col_span.end.value > self.columns.implicit_end_line().value)
            @intCast(@as(i32, col_span.end.value) - self.columns.implicit_end_line().value)
        else
            0;

        if (req_negative_rows > 0) {
            var replacement = std.ArrayList(TrackIntervals).empty;
            for (0..req_negative_rows) |_| replacement.append(self.allocator, .{}) catch @panic("Taffy occupancy allocation failed");
            replacement.appendSlice(self.allocator, self.row_intervals.items) catch @panic("Taffy occupancy allocation failed");
            self.row_intervals.deinit(self.allocator);
            self.row_intervals = replacement;
        }
        for (0..req_positive_rows) |_| self.row_intervals.append(self.allocator, .{}) catch @panic("Taffy occupancy allocation failed");
        if (req_negative_cols > 0) {
            var replacement = std.ArrayList(TrackIntervals).empty;
            for (0..req_negative_cols) |_| replacement.append(self.allocator, .{}) catch @panic("Taffy occupancy allocation failed");
            replacement.appendSlice(self.allocator, self.column_intervals.items) catch @panic("Taffy occupancy allocation failed");
            self.column_intervals.deinit(self.allocator);
            self.column_intervals = replacement;
        }
        for (0..req_positive_cols) |_| self.column_intervals.append(self.allocator, .{}) catch @panic("Taffy occupancy allocation failed");

        self.rows.negative_implicit += req_negative_rows;
        self.rows.positive_implicit += req_positive_rows;
        self.columns.negative_implicit += req_negative_cols;
        self.columns.positive_implicit += req_positive_cols;
    }

    pub fn mark_area_as(self: *CellOccupancyMatrix, primary_axis: geometry.AbsoluteAxis, primary_span: geometry.Line(coordinates.OriginZeroLine), secondary_span: geometry.Line(coordinates.OriginZeroLine), value: CellOccupancyState) void {
        const row_span = if (primary_axis == .horizontal) secondary_span else primary_span;
        const col_span = if (primary_axis == .horizontal) primary_span else secondary_span;
        self.expand_to_fit_range(row_span, col_span);

        if (value == .auto_placed and primary_span.start.value < primary_span.end.value and secondary_span.start.value < secondary_span.end.value) {
            self.advance_auto_placement_cursor(primary_axis, secondary_span.start, primary_span.end);
        }

        const row_range = self.rows.oz_line_range_to_track_range(row_span);
        const col_range = self.columns.oz_line_range_to_track_range(col_span);
        const row_start: usize = @intCast(@max(@as(i16, 0), row_range.start));
        const row_end: usize = @intCast(@min(@as(i16, @intCast(self.row_intervals.items.len)), row_range.end));
        const col_start: usize = @intCast(@max(@as(i16, 0), col_range.start));
        const col_end: usize = @intCast(@min(@as(i16, @intCast(self.column_intervals.items.len)), col_range.end));
        for (self.row_intervals.items[row_start..row_end]) |*track| track.paint(self.allocator, .{ .start = col_span.start.value, .end = col_span.end.value }, value);
        for (self.column_intervals.items[col_start..col_end]) |*track| track.paint(self.allocator, .{ .start = row_span.start.value, .end = row_span.end.value }, value);
    }

    pub fn line_area_is_unoccupied(self: *const CellOccupancyMatrix, primary_axis: geometry.AbsoluteAxis, primary_span: geometry.Line(coordinates.OriginZeroLine), secondary_span: geometry.Line(coordinates.OriginZeroLine)) bool {
        return self.line_area_collision_jump(primary_axis, primary_span, secondary_span) == null;
    }

    pub fn line_area_collision_jump(self: *const CellOccupancyMatrix, primary_axis: geometry.AbsoluteAxis, primary_span: geometry.Line(coordinates.OriginZeroLine), secondary_span: geometry.Line(coordinates.OriginZeroLine)) ?coordinates.OriginZeroLine {
        const lists = self.track_lists(primary_axis.other_axis());
        const secondary_counts = self.track_counts(primary_axis.other_axis());
        const secondary_range = secondary_counts.oz_line_range_to_track_range(secondary_span);
        const start = @max(@as(i16, 0), secondary_range.start);
        const end = @min(@as(i16, @intCast(lists.len)), secondary_range.end);
        var extent: ?i16 = null;
        if (start < end) for (lists[@intCast(start)..@intCast(end)]) |*track| {
            if (track.collision_extent(.{ .start = primary_span.start.value, .end = primary_span.end.value })) |cell| {
                extent = if (extent) |best| @max(best, cell) else cell;
            }
        };
        return if (extent) |cell| .{ .value = cell + 1 } else null;
    }

    pub fn occupied_track_jump(self: *const CellOccupancyMatrix, axis: geometry.AbsoluteAxis, span: geometry.Line(coordinates.OriginZeroLine)) ?coordinates.OriginZeroLine {
        const counts = self.track_counts(axis);
        const lists = self.track_lists(axis);
        const range = counts.oz_line_range_to_track_range(span);
        var index = @min(@as(i16, @intCast(lists.len)), range.end);
        const start = @max(@as(i16, 0), range.start);
        while (index > start) {
            index -= 1;
            if (!lists[@intCast(index)].is_empty()) return .{ .value = counts.track_to_prev_oz_line(@intCast(index)).value + 1 };
        }
        return null;
    }

    pub fn row_is_occupied(self: *const CellOccupancyMatrix, row: usize) bool {
        return row < self.row_intervals.items.len and !self.row_intervals.items[row].is_empty();
    }

    pub fn column_is_occupied(self: *const CellOccupancyMatrix, column: usize) bool {
        return column < self.column_intervals.items.len and !self.column_intervals.items[column].is_empty();
    }

    pub fn track_counts(self: *const CellOccupancyMatrix, axis: geometry.AbsoluteAxis) *const grid_track_counts.TrackCounts {
        return switch (axis) {
            .horizontal => &self.columns,
            .vertical => &self.rows,
        };
    }

    /// The sparse placement cursor for items starting in the given secondary-axis track.
    pub fn auto_placement_cursor(self: *const CellOccupancyMatrix, axis: geometry.AbsoluteAxis, start_at: coordinates.OriginZeroLine) ?coordinates.OriginZeroLine {
        const counts = self.track_counts(axis.other_axis());
        const index = counts.oz_line_to_next_track(start_at);
        const lists = self.track_lists(axis.other_axis());
        if (index < 0 or index >= lists.len) return null;
        return if (lists[@intCast(index)].auto_placement_cursor) |value| .{ .value = value } else null;
    }

    /// Advance the sparse placement cursor to at least `primary_end`. The
    /// secondary-axis track must already exist.
    fn advance_auto_placement_cursor(self: *CellOccupancyMatrix, primary_axis: geometry.AbsoluteAxis, secondary_start: coordinates.OriginZeroLine, primary_end: coordinates.OriginZeroLine) void {
        const index: usize = @intCast(self.track_counts(primary_axis.other_axis()).oz_line_to_next_track(secondary_start));
        const tracks = switch (primary_axis) {
            .horizontal => self.row_intervals.items,
            .vertical => self.column_intervals.items,
        };
        const cursor = &tracks[index].auto_placement_cursor;
        cursor.* = if (cursor.*) |current| @max(current, primary_end.value) else primary_end.value;
    }
};

test "cell occupancy overwrites and jumps over occupied intervals" {
    const testing = std.testing;
    var matrix = CellOccupancyMatrix.with_track_counts_using_allocator(testing.allocator, grid_track_counts.TrackCounts.from_raw(0, 3, 0), grid_track_counts.TrackCounts.from_raw(0, 3, 0));
    defer matrix.deinit();
    const line = geometry.Line(coordinates.OriginZeroLine){ .start = .{ .value = 0 }, .end = .{ .value = 1 } };
    matrix.mark_area_as(.horizontal, line, .{ .start = .{ .value = 0 }, .end = .{ .value = 2 } }, .auto_placed);
    try testing.expect(!matrix.line_area_is_unoccupied(.horizontal, line, .{ .start = .{ .value = 1 }, .end = .{ .value = 2 } }));
    try testing.expectEqual(@as(?i16, 1), matrix.line_area_collision_jump(.horizontal, line, .{ .start = .{ .value = 0 }, .end = .{ .value = 2 } }).?.value);
    matrix.mark_area_as(.horizontal, .{ .start = .{ .value = 0 }, .end = .{ .value = 1 } }, .{ .start = .{ .value = 0 }, .end = .{ .value = 2 } }, .definitely_placed);
    try testing.expect(matrix.row_is_occupied(0));
}

fn testLine(start: i16, end: i16) geometry.Line(coordinates.OriginZeroLine) {
    return .{ .start = .{ .value = start }, .end = .{ .value = end } };
}

fn testCursor(matrix: *const CellOccupancyMatrix, axis: geometry.AbsoluteAxis, start: i16) ?i16 {
    return if (matrix.auto_placement_cursor(axis, .{ .value = start })) |line| line.value else null;
}

test "auto-placed item only advances the cursor in its first secondary track (Taffy 16d3443)" {
    const testing = std.testing;
    for ([_]geometry.AbsoluteAxis{ .horizontal, .vertical }) |axis| {
        var matrix = CellOccupancyMatrix.with_track_counts_using_allocator(testing.allocator, grid_track_counts.TrackCounts.from_raw(0, 4, 0), grid_track_counts.TrackCounts.from_raw(0, 4, 0));
        defer matrix.deinit();
        matrix.mark_area_as(axis, testLine(1, 3), testLine(1, 4), .auto_placed);
        try testing.expectEqual(@as(?i16, 3), testCursor(&matrix, axis, 1));
        try testing.expectEqual(@as(?i16, null), testCursor(&matrix, axis, 2));
        try testing.expectEqual(@as(?i16, null), testCursor(&matrix, axis, 3));
        try testing.expect(!matrix.line_area_is_unoccupied(axis, testLine(1, 3), testLine(2, 4)));
    }
}

test "placement cursors survive interval merging and grid expansion (Taffy 16d3443)" {
    const testing = std.testing;
    for ([_]geometry.AbsoluteAxis{ .horizontal, .vertical }) |axis| {
        var matrix = CellOccupancyMatrix.with_track_counts_using_allocator(testing.allocator, grid_track_counts.TrackCounts.from_raw(0, 4, 0), grid_track_counts.TrackCounts.from_raw(0, 4, 0));
        defer matrix.deinit();
        matrix.mark_area_as(axis, testLine(2, 4), testLine(1, 2), .auto_placed);
        matrix.mark_area_as(axis, testLine(4, 8), testLine(0, 2), .auto_placed);
        matrix.mark_area_as(axis, testLine(8, 10), testLine(1, 2), .definitely_placed);
        matrix.mark_area_as(axis, testLine(-3, -1), testLine(-2, -1), .auto_placed);
        matrix.mark_area_as(axis, testLine(12, 14), testLine(7, 8), .auto_placed);
        matrix.mark_area_as(axis, testLine(0, 1), testLine(1, 2), .auto_placed);
        try testing.expectEqual(@as(?i16, 4), testCursor(&matrix, axis, 1));
        try testing.expectEqual(@as(?i16, 8), testCursor(&matrix, axis, 0));
        try testing.expectEqual(@as(?i16, -1), testCursor(&matrix, axis, -2));
        try testing.expectEqual(@as(?i16, 14), testCursor(&matrix, axis, 7));
    }
}
