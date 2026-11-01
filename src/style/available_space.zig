//! Direct port of Taffy's `style/available_space.rs`.

const std = @import("std");
const css = @import("../util/css.zig");
const geometry = @import("../geometry.zig");

pub const AvailableSpace = union(enum) {
    /// Taffy-compatible serde: external tagging, PascalCase variant names.
    pub const serde = .{
        .rename = .{
            .definite = "Definite",
            .min_content = "MinContent",
            .max_content = "MaxContent",
        },
    };

    definite: f32,
    min_content,
    max_content,

    pub fn from_str(input: []const u8) error{InvalidAvailableSpace}!AvailableSpace {
        return from_css(input);
    }

    pub fn is_definite(self: AvailableSpace) bool {
        return self == .definite;
    }

    pub fn into_option(self: AvailableSpace) ?f32 {
        return switch (self) {
            .definite => |value| value,
            .min_content, .max_content => null,
        };
    }

    pub fn unwrap_or(self: AvailableSpace, alternative: f32) f32 {
        return self.into_option() orelse alternative;
    }

    pub fn from_length(value: anytype) AvailableSpace {
        return .{ .definite = @floatCast(value) };
    }

    pub fn unwrap(self: AvailableSpace) f32 {
        return self.into_option() orelse @panic("Taffy AvailableSpace::unwrap called for an intrinsic constraint");
    }

    pub fn @"or"(self: AvailableSpace, alternative: AvailableSpace) AvailableSpace {
        return if (self.is_definite()) self else alternative;
    }

    pub fn or_else(self: AvailableSpace, alternative: *const fn () AvailableSpace) AvailableSpace {
        return if (self.is_definite()) self else alternative();
    }

    pub fn unwrap_or_else(self: AvailableSpace, alternative: *const fn () f32) f32 {
        return self.into_option() orelse alternative();
    }

    pub fn maybe_set(self: AvailableSpace, value: ?f32) AvailableSpace {
        return if (value) |resolved| .{ .definite = resolved } else self;
    }

    pub fn map_definite_value(self: AvailableSpace, function: *const fn (f32) f32) AvailableSpace {
        return switch (self) {
            .definite => |value| .{ .definite = function(value) },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    }

    pub fn compute_free_space(self: AvailableSpace, used_space: f32) f32 {
        return switch (self) {
            .definite => |available| available - used_space,
            .min_content => 0,
            .max_content => std.math.inf(f32),
        };
    }

    pub fn is_roughly_equal(self: AvailableSpace, other: AvailableSpace) bool {
        return switch (self) {
            .definite => |value| switch (other) {
                .definite => |other_value| @abs(value - other_value) < std.math.floatEps(f32),
                else => false,
            },
            .min_content => other == .min_content,
            .max_content => other == .max_content,
        };
    }
};

pub fn from(value: anytype) AvailableSpace {
    if (@TypeOf(value) == ?f32) return if (value) |number| .{ .definite = number } else .max_content;
    return .{ .definite = @floatCast(value) };
}

/// Taffy's `FromCss for AvailableSpace`: a non-negative number or dimension
/// (any unit), `min-content` or `max-content`.
pub fn from_css(input: []const u8) error{InvalidAvailableSpace}!AvailableSpace {
    const S = struct {
        fn parse(_: void, p: *css.Parser) css.Error!AvailableSpace {
            return switch (try p.next()) {
                .number => |n| if (n.value >= 0) .{ .definite = n.value } else error.InvalidCss,
                .dimension => |d| if (d.value >= 0) .{ .definite = d.value } else error.InvalidCss,
                .ident => |ident| if (std.mem.eql(u8, ident, "max-content"))
                    .max_content
                else if (std.mem.eql(u8, ident, "min-content"))
                    .min_content
                else
                    error.InvalidCss,
                else => error.InvalidCss,
            };
        }
    };
    return css.parse_str_entirely(input, AvailableSpace, {}, S.parse) catch error.InvalidAvailableSpace;
}

pub fn into_options(value: geometry.Size(AvailableSpace)) geometry.Size(?f32) {
    return .{ .width = value.width.into_option(), .height = value.height.into_option() };
}

test "available space distinguishes definite and intrinsic" {
    const testing = std.testing;
    try testing.expect((AvailableSpace{ .definite = 10 }).is_definite());
    try testing.expect(!(AvailableSpace{ .min_content = {} }).is_definite());
    try testing.expectEqual(@as(f32, -2), (AvailableSpace{ .definite = 10 }).compute_free_space(12));
}
