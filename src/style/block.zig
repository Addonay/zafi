//! Direct port of Taffy's `style/block.rs`.

const std = @import("std");
const css = @import("../util/css.zig");
pub const BlockParseError = error{InvalidTextAlign};

const serde_support = @import("../serde_support.zig");
const serde_options = serde_support.pascal_options;
pub const TextAlign = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    auto,
    legacy_left,
    legacy_right,
    legacy_center,

    pub fn is_legacy(self: TextAlign) bool {
        return self != .auto;
    }

    /// Taffy's keyword parser: one ident, ASCII case-insensitive.
    pub fn from_str(input: []const u8) BlockParseError!TextAlign {
        return css.keyword_enum(TextAlign, input, &.{
            .{ "auto", .auto },
            .{ "-webkit-left", .legacy_left },
            .{ "-webkit-right", .legacy_right },
            .{ "-webkit-center", .legacy_center },
        }) catch error.InvalidTextAlign;
    }
};

pub const BlockContainerStyle = struct {};
pub const BlockItemStyle = struct {};
