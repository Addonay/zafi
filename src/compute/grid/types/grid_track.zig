//! Direct-port home for `compute/grid/types/grid_track.rs`.

pub const GridTrack = struct {
    kind: GridTrackKind = .track,
    is_collapsed: bool = false,
    min_track_sizing_function: @import("../../../style/grid.zig").MinTrackSizingFunction = .auto,
    max_track_sizing_function: @import("../../../style/grid.zig").MaxTrackSizingFunction = .auto,
    offset: f32 = 0,
    base_size: f32 = 0,
    growth_limit: f32 = 0,
    content_alignment_adjustment: f32 = 0,
    item_incurred_increase: f32 = 0,
    base_size_planned_increase: f32 = 0,
    growth_limit_planned_increase: f32 = 0,
    infinitely_growable: bool = false,

    pub fn new(minimum: @import("../../../style/grid.zig").MinTrackSizingFunction, maximum: @import("../../../style/grid.zig").MaxTrackSizingFunction) GridTrack {
        return .{ .min_track_sizing_function = minimum, .max_track_sizing_function = maximum };
    }
    pub fn new_with_kind(kind: GridTrackKind, minimum: @import("../../../style/grid.zig").MinTrackSizingFunction, maximum: @import("../../../style/grid.zig").MaxTrackSizingFunction) GridTrack {
        return .{ .kind = kind, .min_track_sizing_function = minimum, .max_track_sizing_function = maximum };
    }
    pub fn gutter(size: @import("../../../style/dimension.zig").LengthPercentage) GridTrack {
        return .{ .kind = .gutter, .min_track_sizing_function = .{ .value = size.value }, .max_track_sizing_function = .{ .value = size.value } };
    }
    pub fn collapse(self: *GridTrack) void {
        self.is_collapsed = true;
        self.min_track_sizing_function = .zero;
        self.max_track_sizing_function = .zero;
        self.base_size = 0;
        self.growth_limit = 0;
    }
    pub fn is_track(self: GridTrack) bool {
        return self.kind == .track;
    }
    pub fn is_gutter(self: GridTrack) bool {
        return self.kind == .gutter;
    }
    pub fn is_flexible(self: GridTrack) bool {
        return self.max_track_sizing_function.is_fr();
    }
    pub fn uses_percentage(self: GridTrack) bool {
        return self.min_track_sizing_function.uses_percentage() or self.max_track_sizing_function.uses_percentage();
    }
    pub fn has_intrinsic_sizing_function(self: GridTrack) bool {
        return self.min_track_sizing_function.is_intrinsic() or self.max_track_sizing_function.is_intrinsic();
    }
    pub fn has_intrinsic_sizing(self: GridTrack) bool {
        return self.has_intrinsic_sizing_function();
    }
    pub fn fit_content_limit(self: GridTrack, available_space: ?f32) f32 {
        return switch (self.max_track_sizing_function.value.tag()) {
            .fit_content_px => self.max_track_sizing_function.value.value(),
            .fit_content_percent => if (available_space) |space| space * self.max_track_sizing_function.value.value() else std.math.inf(f32),
            else => std.math.inf(f32),
        };
    }

    pub fn fit_content_limited_growth_limit(self: GridTrack, available_space: ?f32) f32 {
        return @min(self.growth_limit, self.fit_content_limit(available_space));
    }

    pub fn flex_factor(self: GridTrack) f32 {
        const compact_length = @import("../../../style/compact_length.zig");
        return if (self.is_flexible()) compact_length.numericValue(self.max_track_sizing_function.value) else 0;
    }
};

pub const GridTrackKind = enum { track, gutter };

const std = @import("std");
