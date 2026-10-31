//! Direct port of Taffy's `style_helpers.rs` constructors.

const dimension = @import("style/dimension.zig");
const grid = @import("style/grid.zig");
const std = @import("std");

pub fn length(value: f32) dimension.Dimension {
    return dimension.Dimension.length(value);
}

pub fn percent(value: f32) dimension.Dimension {
    return dimension.Dimension.percent(value);
}

pub fn auto() dimension.Dimension {
    return .auto;
}

pub fn min_content() dimension.Dimension {
    return .min_content;
}

pub fn max_content() dimension.Dimension {
    return .max_content;
}

pub fn zero() dimension.Dimension {
    return dimension.Dimension.length(0);
}

pub fn fr(value: f32) grid.TrackSizingFunction {
    return .{ .min = .zero, .max = grid.MaxTrackSizingFunction.fr(value) };
}

pub fn flex(value: f32) grid.TrackSizingFunction {
    return fr(value);
}

pub fn fit_content(value: dimension.LengthPercentage) grid.TrackSizingFunction {
    return grid.TrackSizingFunction.fit_content(value);
}

pub fn repeat(count: u16, tracks: []const grid.TrackSizingFunction) grid.GridTemplateComponent {
    return .{ .repeat = .{ .count = .{ .count = count }, .tracks = tracks } };
}

pub fn span(count: u16) grid.GridPlacement {
    return .{ .span = count };
}

pub fn line(index: i16) grid.GridPlacement {
    return .{ .line = index };
}

pub fn from_line_index(index: i16) grid.GridPlacement {
    return grid.GridPlacement.from_line_index(index);
}
pub fn from_span(count: u16) grid.GridPlacement {
    return grid.GridPlacement.from_span(count);
}
pub fn from_length(value: f32) dimension.Dimension {
    return length(value);
}
pub fn from_percent(value: f32) dimension.Dimension {
    return percent(value);
}
pub fn from_fr(value: f32) grid.TrackSizingFunction {
    return fr(value);
}

/// `repeat(count, 1fr)`, returned by value so nothing is allocated:
/// `const t = evenly_sized_tracks(3); style.grid_template_columns = &t;`
pub fn evenly_sized_tracks(count: u16) [1]grid.GridTemplateComponent {
    return .{.{ .repeat = .{ .count = .{ .count = count }, .tracks = &one_fr_track } }};
}
const one_fr_track = [_]grid.TrackSizingFunction{fr(1)};

pub fn minmax(minimum: grid.MinTrackSizingFunction, maximum: grid.MaxTrackSizingFunction) grid.TrackSizingFunction {
    return .{ .min = minimum, .max = maximum };
}
