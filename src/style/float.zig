//! Direct port of Taffy's `style/float.rs`.

const std = @import("std");
const css = @import("../util/css.zig");
pub const FloatParseError = error{InvalidFloatValue};

const serde_support = @import("../serde_support.zig");
const serde_options = serde_support.pascal_options;
pub const Float = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    left,
    right,
    none,

    /// Taffy's keyword parser: one ident, ASCII case-insensitive.
    pub fn from_str(input: []const u8) FloatParseError!Float {
        return css.keyword_enum(Float, input, &.{
            .{ "left", .left },
            .{ "right", .right },
            .{ "none", .none },
        }) catch error.InvalidFloatValue;
    }
};

pub const Clear = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    left,
    right,
    both,
    none,

    /// Taffy's keyword parser: one ident, ASCII case-insensitive.
    pub fn from_str(input: []const u8) FloatParseError!Clear {
        return css.keyword_enum(Clear, input, &.{
            .{ "left", .left },
            .{ "right", .right },
            .{ "both", .both },
            .{ "none", .none },
        }) catch error.InvalidFloatValue;
    }
};
pub const FloatDirection = enum { left, right };

pub fn is_floated(value: Float) bool {
    return value == .left or value == .right;
}

pub fn float_direction(value: Float) ?FloatDirection {
    return switch (value) {
        .left => .left,
        .right => .right,
        .none => null,
    };
}
