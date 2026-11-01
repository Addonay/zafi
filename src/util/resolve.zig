//! Direct-port home for Taffy's `util/resolve.rs`.

const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;
const dimension = @import("../style/dimension.zig");

pub const MaybeResolve = struct {};
pub const ResolveOrZero = struct {};

pub inline fn maybe_resolve(value: anytype, context: ?f32) ?f32 {
    return switch (@TypeOf(value)) {
        dimension.LengthPercentage => maybe_resolve_length(value, context),
        dimension.LengthPercentageAuto => maybe_resolve_auto(value, context),
        dimension.Dimension => maybe_resolve_dimension(value, context),
        else => @panic("unsupported Taffy MaybeResolve value"),
    };
}

pub inline fn resolve_or_zero(value: anytype, context: ?f32) f32 {
    return maybe_resolve(value, context) orelse 0;
}

pub inline fn resolve(value: dimension.LengthPercentage, basis: f32) f32 {
    return value.resolve(basis);
}

pub inline fn resolve_length(value: dimension.LengthPercentage, _: ?f32) ?f32 {
    return switch (value.value.tag()) {
        .length => value.value.value(),
        else => null,
    };
}

pub inline fn resolve_percent(value: dimension.LengthPercentage, context: ?f32) ?f32 {
    return switch (value.value.tag()) {
        .percent => if (context) |basis| value.value.value() * basis else null,
        else => null,
    };
}

pub inline fn maybe_resolve_percent(value: dimension.LengthPercentage, context: ?f32) ?f32 {
    return resolve_percent(value, context);
}
pub inline fn resolve_or_zero_percent(value: dimension.LengthPercentage, context: ?f32) f32 {
    return resolve_percent(value, context) orelse 0;
}

pub inline fn resolve_auto(value: dimension.LengthPercentageAuto, basis: f32) ?f32 {
    return value.resolve(basis);
}

pub inline fn resolve_dimension(value: dimension.Dimension, basis: ?f32) ?f32 {
    return value.resolve(basis);
}

pub fn available_or(value: AvailableSpace, fallback: f32) f32 {
    return value.unwrap_or(fallback);
}

// Taffy's `MaybeResolve`: lengths resolve as-is; percentages and `calc()`
// need a definite context (calc goes through the host resolver bound for the
// layout pass, see `style/calc.zig`); everything else is indefinite.

pub inline fn maybe_resolve_length(value: dimension.LengthPercentage, context: ?f32) ?f32 {
    return value.value.maybe_resolve(context);
}

pub inline fn maybe_resolve_auto(value: dimension.LengthPercentageAuto, context: ?f32) ?f32 {
    return value.value.maybe_resolve(context);
}

pub inline fn maybe_resolve_dimension(value: dimension.Dimension, context: ?f32) ?f32 {
    return value.value.maybe_resolve(context);
}

pub inline fn resolve_or_zero_length(value: dimension.LengthPercentage, context: ?f32) f32 {
    return maybe_resolve_length(value, context) orelse 0;
}
pub inline fn resolve_or_zero_auto(value: dimension.LengthPercentageAuto, context: ?f32) f32 {
    return maybe_resolve_auto(value, context) orelse 0;
}
pub inline fn resolve_or_zero_dimension(value: dimension.Dimension, context: ?f32) f32 {
    return maybe_resolve_dimension(value, context) orelse 0;
}

pub inline fn resolve_rect_or_zero(value: anytype, context: ?f32, comptime T: type) @import("../geometry.zig").Rect(T) {
    return .{
        .left = resolve_or_zero_value(value.left, context),
        .right = resolve_or_zero_value(value.right, context),
        .top = resolve_or_zero_value(value.top, context),
        .bottom = resolve_or_zero_value(value.bottom, context),
    };
}

inline fn resolve_or_zero_value(value: anytype, context: ?f32) f32 {
    return switch (@TypeOf(value)) {
        dimension.LengthPercentage => resolve_or_zero_length(value, context),
        dimension.LengthPercentageAuto => resolve_or_zero_auto(value, context),
        dimension.Dimension => resolve_or_zero_dimension(value, context),
        else => @panic("unsupported Taffy resolve_or_zero value"),
    };
}
