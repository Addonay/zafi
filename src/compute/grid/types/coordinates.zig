//! Grid line coordinates from Taffy's `compute/grid/types/coordinates.rs`.
//!
//! Taffy has two separate coordinate spaces here. CSS grid-line numbers are
//! one-based and may be negative; OriginZero lines are normalized around the
//! explicit-grid start. Keeping both representations is important because
//! negative implicit tracks are created during placement.

const geometry = @import("../../../geometry.zig");
const grid_track_counts = @import("grid_track_counts.zig");

pub const OriginZeroLine = struct {
    value: i16,

    pub fn add(self: OriginZeroLine, other: OriginZeroLine) OriginZeroLine {
        return .{ .value = self.value + other.value };
    }
    pub fn add_u16(self: OriginZeroLine, amount: u16) OriginZeroLine {
        return .{ .value = self.value + @as(i16, @intCast(amount)) };
    }
    pub fn sub(self: OriginZeroLine, other: OriginZeroLine) OriginZeroLine {
        return .{ .value = self.value - other.value };
    }
    pub fn sub_u16(self: OriginZeroLine, amount: u16) OriginZeroLine {
        return .{ .value = self.value - @as(i16, @intCast(amount)) };
    }
    pub fn into_track_vec_index(self: OriginZeroLine, counts: grid_track_counts.TrackCounts) usize {
        return origin_zero_line_into_track_vec_index_with_counts(self, counts);
    }
    pub fn try_into_track_vec_index(self: OriginZeroLine, counts: grid_track_counts.TrackCounts) ?usize {
        return origin_zero_line_try_into_track_vec_index_with_counts(self, counts);
    }
    pub fn implied_negative_implicit_tracks(self: OriginZeroLine) u16 {
        return origin_zero_line_implied_negative_implicit_tracks(self);
    }
    pub fn implied_positive_implicit_tracks(self: OriginZeroLine, explicit_count: u16) u16 {
        return origin_zero_line_implied_positive_implicit_tracks(self, explicit_count);
    }
};

pub const GridLine = struct {
    value: i16,

    pub fn from_i16(value: i16) GridLine {
        return .{ .value = value };
    }
    pub fn as_i16(self: GridLine) i16 {
        return self.value;
    }
    pub fn into_origin_zero_line(self: GridLine, explicit_track_count: u16) OriginZeroLine {
        return grid_line_into_origin_zero_line(self, explicit_track_count);
    }
};
pub const GridCoordinate = i16;

pub const GridCoordinatePair = struct { row: i16, column: i16 };

pub const MAX_GRID_TRACKS: u16 = 10_000;
pub const MIN_OZ_LINE: i16 = -10_000;
pub const MAX_OZ_LINE: i16 = 10_000;

pub fn grid_line_from_i16(value: i16) GridLine {
    return .{ .value = value };
}
pub fn from(value: i16) GridLine {
    return grid_line_from_i16(value);
}
pub fn grid_line_from(value: i16) GridLine {
    return grid_line_from_i16(value);
}
pub fn grid_line_as_i16(value: GridLine) i16 {
    return value.value;
}
pub fn as_i16(value: GridLine) i16 {
    return grid_line_as_i16(value);
}
pub fn grid_line_as_i16_method(value: GridLine) i16 {
    return grid_line_as_i16(value);
}
pub fn origin_zero_line_add(value: OriginZeroLine, amount: i16) OriginZeroLine {
    return .{ .value = value.value + amount };
}
pub fn origin_zero_line_add_line(value: OriginZeroLine, amount: OriginZeroLine) OriginZeroLine {
    return .{ .value = value.value + amount.value };
}
pub fn add(lhs: OriginZeroLine, rhs: OriginZeroLine) OriginZeroLine {
    return origin_zero_line_add_line(lhs, rhs);
}
pub fn origin_zero_line_sub(value: OriginZeroLine, amount: i16) OriginZeroLine {
    return .{ .value = value.value - amount };
}
pub fn origin_zero_line_sub_line(value: OriginZeroLine, amount: OriginZeroLine) OriginZeroLine {
    return .{ .value = value.value - amount.value };
}
pub fn sub(lhs: OriginZeroLine, rhs: OriginZeroLine) OriginZeroLine {
    return origin_zero_line_sub_line(lhs, rhs);
}
pub fn add_assign(value: *OriginZeroLine, amount: u16) void {
    value.value += @intCast(amount);
}

pub fn grid_line_into_origin_zero_line(value: GridLine, explicit_track_count: u16) OriginZeroLine {
    const explicit_line_count: i32 = @as(i32, explicit_track_count) + 1;
    const normalized: i32 = if (value.value > 0) @as(i32, value.value) - 1 else @as(i32, value.value) + explicit_line_count;
    return .{ .value = @intCast(@max(@as(i32, MIN_OZ_LINE), @min(@as(i32, MAX_OZ_LINE), normalized))) };
}
pub fn into_origin_zero_line(value: GridLine, explicit_track_count: u16) OriginZeroLine {
    return grid_line_into_origin_zero_line(value, explicit_track_count);
}

pub fn origin_zero_line_into_track_vec_index(value: OriginZeroLine, negative_implicit: u16, explicit: u16, positive_implicit: u16) usize {
    const index: i32 = @as(i32, value.value) + negative_implicit;
    const total: i32 = @as(i32, negative_implicit) + explicit + positive_implicit;
    if (index < 0 or index > total) @panic("OriginZero grid line outside implicit grid");
    return @intCast(index * 2);
}

pub fn origin_zero_line_try_into_track_vec_index(value: OriginZeroLine, negative_implicit: u16, explicit: u16, positive_implicit: u16) ?usize {
    const index: i32 = @as(i32, value.value) + negative_implicit;
    const total: i32 = @as(i32, negative_implicit) + explicit + positive_implicit;
    if (index < 0 or index > total) return null;
    return @intCast(index * 2);
}

pub fn into_track_vec_index(value: OriginZeroLine, counts: grid_track_counts.TrackCounts) usize {
    return origin_zero_line_into_track_vec_index(value, counts.negative_implicit, counts.explicit, counts.positive_implicit);
}
pub fn try_into_track_vec_index(value: OriginZeroLine, counts: grid_track_counts.TrackCounts) ?usize {
    return origin_zero_line_try_into_track_vec_index(value, counts.negative_implicit, counts.explicit, counts.positive_implicit);
}
pub fn implied_negative_implicit_tracks(value: OriginZeroLine) u16 {
    return origin_zero_line_implied_negative_implicit_tracks(value);
}
pub fn implied_positive_implicit_tracks(value: OriginZeroLine, explicit_track_count: u16) u16 {
    return origin_zero_line_implied_positive_implicit_tracks(value, explicit_track_count);
}
pub fn span(value: geometry.Line(OriginZeroLine)) u16 {
    return line_origin_zero_span(value);
}

pub fn origin_zero_line_into_track_vec_index_unchecked(value: OriginZeroLine, negative_implicit: u16) usize {
    return @intCast((@as(i32, value.value) + negative_implicit) * 2);
}

pub fn origin_zero_line_implied_negative_implicit_tracks(value: OriginZeroLine) u16 {
    return if (value.value < 0) @intCast(-@as(i32, value.value)) else 0;
}

pub fn origin_zero_line_implied_positive_implicit_tracks(value: OriginZeroLine, explicit_track_count: u16) u16 {
    return if (value.value > @as(i16, @intCast(explicit_track_count)))
        @intCast(@as(i32, value.value) - explicit_track_count)
    else
        0;
}

pub fn line_origin_zero_span(value: geometry.Line(OriginZeroLine)) u16 {
    return if (value.end.value > value.start.value)
        @intCast(@as(i32, value.end.value) - value.start.value)
    else
        0;
}

pub fn origin_zero_line_into_track_vec_index_with_counts(value: OriginZeroLine, counts: grid_track_counts.TrackCounts) usize {
    return origin_zero_line_into_track_vec_index(value, counts.negative_implicit, counts.explicit, counts.positive_implicit);
}

pub fn origin_zero_line_try_into_track_vec_index_with_counts(value: OriginZeroLine, counts: grid_track_counts.TrackCounts) ?usize {
    return origin_zero_line_try_into_track_vec_index(value, counts.negative_implicit, counts.explicit, counts.positive_implicit);
}
