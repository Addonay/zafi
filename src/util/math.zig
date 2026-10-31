//! Direct-port home for Taffy's `util/math.rs`.
//!
//! Rust expresses these as trait overloads (`MaybeMath<In, Out>`); Zig uses
//! explicit free functions. The semantics follow the Rust implementations
//! exactly: in particular, a `None` left-hand side stays `None` when the
//! right-hand side is `Some` (the "unknown absorbs" rule), and one-sided
//! clamps apply the side that is present.

const geometry = @import("../geometry.zig");
const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;

pub const MaybeMath = struct {};

pub fn f32_max(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

pub fn f32_min(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

/// `Option<f32>::maybe_max(Option<f32>)`.
pub fn maybe_max(a: ?f32, b: ?f32) ?f32 {
    if (a) |left| {
        if (b) |right| return @max(left, right);
        return left;
    }
    return null;
}

/// `Option<f32>::maybe_min(Option<f32>)`.
pub fn maybe_min(a: ?f32, b: ?f32) ?f32 {
    if (a) |left| {
        if (b) |right| return @min(left, right);
        return left;
    }
    return null;
}

pub fn option_maybe_min(lhs: ?f32, rhs: ?f32) ?f32 {
    return maybe_min(lhs, rhs);
}

pub fn option_maybe_max(lhs: ?f32, rhs: ?f32) ?f32 {
    return maybe_max(lhs, rhs);
}

/// `Option<f32>::maybe_clamp(Option<f32>, Option<f32>)`.
pub fn option_maybe_clamp(value: ?f32, minimum: ?f32, maximum: ?f32) ?f32 {
    const base = value orelse return null;
    if (minimum) |min| {
        if (maximum) |max| return @max(@min(base, max), min);
        return @max(base, min);
    }
    if (maximum) |max| return @min(base, max);
    return base;
}

/// `Option<f32>::maybe_add(Option<f32>)`.
pub fn option_maybe_add(lhs: ?f32, rhs: ?f32) ?f32 {
    if (lhs) |left| {
        if (rhs) |right| return left + right;
        return left;
    }
    return null;
}

/// `Option<f32>::maybe_sub(Option<f32>)`.
pub fn option_maybe_sub(lhs: ?f32, rhs: ?f32) ?f32 {
    if (lhs) |left| {
        if (rhs) |right| return left - right;
        return left;
    }
    return null;
}

pub fn maybe_clamp(value: ?f32, minimum: ?f32, maximum: ?f32) ?f32 {
    return option_maybe_clamp(value, minimum, maximum);
}

pub fn maybe_add(lhs: ?f32, rhs: ?f32) ?f32 {
    return option_maybe_add(lhs, rhs);
}

pub fn maybe_sub(lhs: ?f32, rhs: ?f32) ?f32 {
    return option_maybe_sub(lhs, rhs);
}

/// `f32::maybe_min(Option<f32>)`.
pub fn f32_maybe_min(lhs: f32, rhs: ?f32) f32 {
    return if (rhs) |value| @min(lhs, value) else lhs;
}

/// `f32::maybe_max(Option<f32>)`.
pub fn f32_maybe_max(lhs: f32, rhs: ?f32) f32 {
    return if (rhs) |value| @max(lhs, value) else lhs;
}

/// `f32::maybe_clamp(Option<f32>, Option<f32>)`.
pub fn f32_maybe_clamp(value: f32, minimum: ?f32, maximum: ?f32) f32 {
    if (minimum) |min| {
        if (maximum) |max| return @max(@min(value, max), min);
        return @max(value, min);
    }
    if (maximum) |max| return @min(value, max);
    return value;
}

pub fn f32_maybe_add(lhs: f32, rhs: ?f32) f32 {
    return if (rhs) |value| lhs + value else lhs;
}

pub fn f32_maybe_sub(lhs: f32, rhs: ?f32) f32 {
    return if (rhs) |value| lhs - value else lhs;
}

/// `AvailableSpace::maybe_min(Option<f32>)`.
pub fn available_maybe_min(value: AvailableSpace, rhs: ?f32) AvailableSpace {
    return switch (value) {
        .definite => |number| if (rhs) |right| .{ .definite = @min(number, right) } else .{ .definite = number },
        .min_content => if (rhs) |right| .{ .definite = right } else .min_content,
        .max_content => if (rhs) |right| .{ .definite = right } else .max_content,
    };
}

/// `AvailableSpace::maybe_max(Option<f32>)`.
pub fn available_maybe_max(value: AvailableSpace, rhs: ?f32) AvailableSpace {
    return switch (value) {
        .definite => |number| if (rhs) |right| .{ .definite = @max(number, right) } else .{ .definite = number },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

/// `AvailableSpace::maybe_clamp(Option<f32>, Option<f32>)`.
pub fn available_maybe_clamp(value: AvailableSpace, minimum: ?f32, maximum: ?f32) AvailableSpace {
    return switch (value) {
        .definite => |number| .{ .definite = f32_maybe_clamp(number, minimum, maximum) },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

/// `AvailableSpace::maybe_add(Option<f32>)`.
pub fn available_maybe_add(value: AvailableSpace, rhs: ?f32) AvailableSpace {
    return switch (value) {
        .definite => |number| .{ .definite = number + (rhs orelse 0) },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

/// `AvailableSpace::maybe_sub(Option<f32>)`.
pub fn available_maybe_sub(value: AvailableSpace, rhs: ?f32) AvailableSpace {
    return switch (value) {
        .definite => |number| .{ .definite = number - (rhs orelse 0) },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

pub fn optional_size_maybe_min(value: geometry.Size(?f32), rhs: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = maybe_min(value.width, rhs.width), .height = maybe_min(value.height, rhs.height) };
}

pub fn optional_size_maybe_max(value: geometry.Size(?f32), rhs: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = maybe_max(value.width, rhs.width), .height = maybe_max(value.height, rhs.height) };
}

pub fn optional_size_maybe_clamp(value: geometry.Size(?f32), minimum: geometry.Size(?f32), maximum: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = option_maybe_clamp(value.width, minimum.width, maximum.width), .height = option_maybe_clamp(value.height, minimum.height, maximum.height) };
}

pub fn optional_size_maybe_add(value: geometry.Size(?f32), rhs: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = option_maybe_add(value.width, rhs.width), .height = option_maybe_add(value.height, rhs.height) };
}

pub fn optional_size_maybe_sub(value: geometry.Size(?f32), rhs: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = option_maybe_sub(value.width, rhs.width), .height = option_maybe_sub(value.height, rhs.height) };
}

test "MaybeMath overloads preserve optional and intrinsic constraints" {
    const testing = @import("std").testing;
    // Rust: None.maybe_max(Some(5)) == None; Some(3).maybe_min(None) == Some(3).
    try testing.expectEqual(@as(?f32, 3), maybe_min(3, null));
    try testing.expectEqual(@as(?f32, null), maybe_max(null, 5));
    try testing.expectEqual(@as(?f32, 5), maybe_max(3, 5));
    // One-sided clamps apply the present side.
    try testing.expectEqual(@as(?f32, 4), option_maybe_clamp(5, null, 4));
    try testing.expectEqual(@as(?f32, 6), option_maybe_clamp(5, 6, null));
    try testing.expectEqual(@as(?f32, 6), option_maybe_clamp(5, 6, 4)); // min wins when max < min
    const size = optional_size_maybe_add(.{ .width = 3, .height = null }, .{ .width = 2, .height = 4 });
    try testing.expectEqual(@as(?f32, 5), size.width);
    try testing.expect(size.height == null);
    const intrinsic = available_maybe_sub(.max_content, 10);
    try testing.expect(intrinsic == .max_content);
}
