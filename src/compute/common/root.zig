//! Taffy `compute/common/mod.rs` module root.

const geometry = @import("../../geometry.zig");
const dimension = @import("../../style/dimension.zig");

pub const alignment = @import("alignment.zig");
pub const scrollable_overflow = @import("scrollable_overflow.zig");
pub const sizing_keyword = @import("sizing_keyword.zig");

/// Resolve a `Rect<LengthPercentage>` against an optional basis. Percentages
/// against an indefinite basis resolve to zero, matching `ResolveOrZero`.
pub fn resolve_length_rect(value: geometry.Rect(dimension.LengthPercentage), basis: ?f32) geometry.Rect(f32) {
    const resolved_basis = basis orelse 0;
    return .{
        .left = value.left.resolve(resolved_basis),
        .right = value.right.resolve(resolved_basis),
        .top = value.top.resolve(resolved_basis),
        .bottom = value.bottom.resolve(resolved_basis),
    };
}

/// Resolve a `Rect<LengthPercentageAuto>` against an optional basis. Both
/// percentages against an indefinite basis and `auto` resolve to zero.
pub fn resolve_rect_or_zero(value: geometry.Rect(dimension.LengthPercentageAuto), basis: ?f32) geometry.Rect(f32) {
    return .{
        .left = value.left.resolve_to_option(basis) orelse 0,
        .right = value.right.resolve_to_option(basis) orelse 0,
        .top = value.top.resolve_to_option(basis) orelse 0,
        .bottom = value.bottom.resolve_to_option(basis) orelse 0,
    };
}

test {
    _ = @import("alignment.zig");
    _ = @import("scrollable_overflow.zig");
    _ = @import("sizing_keyword.zig");
}
