//! Direct port of Taffy's `style/flex.rs` enums and axis predicates.

const geometry = @import("../geometry.zig");
const std = @import("std");
const css = @import("../util/css.zig");
pub const FlexParseError = error{InvalidFlexValue};

const serde_support = @import("../serde_support.zig");
const serde_options = serde_support.pascal_options;
pub const FlexDirection = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    row,
    column,
    row_reverse,
    column_reverse,

    pub fn is_row(self: FlexDirection) bool {
        return self == .row or self == .row_reverse;
    }
    pub fn is_column(self: FlexDirection) bool {
        return self == .column or self == .column_reverse;
    }
    pub fn is_reverse(self: FlexDirection) bool {
        return self == .row_reverse or self == .column_reverse;
    }
    /// Is the main axis the (single) axis that a size was requested for? `requested` is the
    /// requested axis, or `null` when both axes were requested.
    pub fn main_axis_is_requested_axis(self: FlexDirection, requested: ?geometry.AbsoluteAxis) bool {
        const axis = requested orelse return false;
        return switch (axis) {
            .horizontal => self.is_row(),
            .vertical => self.is_column(),
        };
    }
    pub fn main_axis(self: FlexDirection) geometry.AbsoluteAxis {
        return if (self.is_row()) .horizontal else .vertical;
    }
    pub fn cross_axis(self: FlexDirection) geometry.AbsoluteAxis {
        return self.main_axis().other_axis();
    }

    /// Taffy's keyword parser: one ident, ASCII case-insensitive.
    pub fn from_str(input: []const u8) FlexParseError!FlexDirection {
        return css.keyword_enum(FlexDirection, input, &.{
            .{ "row", .row },
            .{ "column", .column },
            .{ "row-reverse", .row_reverse },
            .{ "column-reverse", .column_reverse },
        }) catch error.InvalidFlexValue;
    }
};
pub const FlexWrap = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    no_wrap,
    wrap,
    wrap_reverse,
    balance,
    balance_reverse,

    pub fn is_multi_line(self: FlexWrap) bool {
        return self != .no_wrap;
    }
    pub fn is_reverse(self: FlexWrap) bool {
        return self == .wrap_reverse or self == .balance_reverse;
    }
    pub fn is_balance(self: FlexWrap) bool {
        return self == .balance or self == .balance_reverse;
    }

    /// Taffy's `FromCss for FlexWrap` (with `flexbox_balance`): `nowrap`, or
    /// a combination of at most one of `wrap` / `wrap-reverse` with `balance`.
    pub fn from_str(input: []const u8) FlexParseError!FlexWrap {
        const S = struct {
            fn parse(_: void, p: *css.Parser) css.Error!FlexWrap {
                var wrap: ?FlexWrap = null;
                var balance = false;
                var is_first = true;
                while (true) {
                    const ident = if (is_first) try p.expect_ident() else blk: {
                        const saved = p.state();
                        break :blk p.expect_ident() catch {
                            p.reset(saved);
                            break;
                        };
                    };
                    const valid = if (std.ascii.eqlIgnoreCase(ident, "nowrap")) {
                        if (is_first) return .no_wrap;
                        return error.InvalidCss;
                    } else if (std.ascii.eqlIgnoreCase(ident, "wrap")) set: {
                        defer wrap = .wrap;
                        break :set wrap == null;
                    } else if (std.ascii.eqlIgnoreCase(ident, "wrap-reverse")) set: {
                        defer wrap = .wrap_reverse;
                        break :set wrap == null;
                    } else if (std.ascii.eqlIgnoreCase(ident, "balance")) set: {
                        defer balance = true;
                        break :set !balance;
                    } else false;
                    if (!valid) return error.InvalidCss;
                    is_first = false;
                }
                if (balance) return if (wrap == .wrap_reverse) .balance_reverse else .balance;
                return wrap orelse .no_wrap;
            }
        };
        return css.parse_str_entirely(input, FlexWrap, {}, S.parse) catch error.InvalidFlexValue;
    }
};

pub fn is_row(direction: FlexDirection) bool {
    return direction == .row or direction == .row_reverse;
}

pub fn is_reverse(direction: FlexDirection) bool {
    return direction == .row_reverse or direction == .column_reverse;
}

pub fn is_multi_line(wrap: FlexWrap) bool {
    return wrap != .no_wrap;
}

pub fn is_reverse_wrap(wrap: FlexWrap) bool {
    return wrap == .wrap_reverse or wrap == .balance_reverse;
}

pub fn is_balance(wrap: FlexWrap) bool {
    return wrap == .balance or wrap == .balance_reverse;
}

pub fn flex_direction_is_row(direction: FlexDirection) bool {
    return direction.is_row();
}
pub fn flex_direction_is_column(direction: FlexDirection) bool {
    return direction.is_column();
}
pub fn flex_direction_is_reverse(direction: FlexDirection) bool {
    return direction.is_reverse();
}

test "flex-wrap parses the compound balance spellings" {
    const testing = std.testing;
    try testing.expectEqual(FlexWrap.no_wrap, try FlexWrap.from_str("nowrap"));
    try testing.expectEqual(FlexWrap.wrap, try FlexWrap.from_str("wrap"));
    try testing.expectEqual(FlexWrap.wrap_reverse, try FlexWrap.from_str("wrap-reverse"));
    try testing.expectEqual(FlexWrap.balance, try FlexWrap.from_str("balance"));
    try testing.expectEqual(FlexWrap.balance_reverse, try FlexWrap.from_str("wrap-reverse balance"));
    try testing.expectEqual(FlexWrap.balance, try FlexWrap.from_str("balance wrap"));
    try testing.expectError(error.InvalidFlexValue, FlexWrap.from_str("wrap wrap"));
    try testing.expectError(error.InvalidFlexValue, FlexWrap.from_str(""));
}
