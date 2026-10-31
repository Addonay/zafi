//! Direct semantic port of Taffy's `style/dimension.rs`.

const AvailableSpace = @import("available_space.zig").AvailableSpace;
const compact_length = @import("compact_length.zig");
const std = @import("std");

const serde_support = @import("../serde_support.zig");
const serde_serialize = serde_support.serialize;
const serde_deserialize = serde_support.deserialize;
pub const DimensionParseError = error{ InvalidDimension, InvalidNumber };

fn parse_numeric(input: []const u8) DimensionParseError!f32 {
    return std.fmt.parseFloat(f32, input) catch error.InvalidNumber;
}

fn trim_dimension_input(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

pub const LengthPercentage = struct {
    /// Taffy-compatible serde: u64 wire bits with wrapper-specific tag validation.
    pub const zerdeSerialize = serde_serialize;
    pub const zerdeDeserialize = serde_deserialize;

    value: compact_length.CompactLength,

    pub fn from_length(value: anytype) LengthPercentage {
        return .{ .value = compact_length.compact_length_from_length(value) };
    }
    pub fn from_percent(value: anytype) LengthPercentage {
        return .{ .value = compact_length.compact_length_from_percent(value) };
    }

    pub fn from_str(input: []const u8) DimensionParseError!LengthPercentage {
        const source = trim_dimension_input(input);
        if (std.mem.endsWith(u8, source, "%")) return LengthPercentage.percent((parse_numeric(source[0 .. source.len - 1]) catch return error.InvalidNumber) / 100.0);
        if (std.mem.endsWith(u8, source, "px")) return LengthPercentage.length(parse_numeric(source[0 .. source.len - 2]) catch return error.InvalidNumber);
        return error.InvalidDimension;
    }

    pub fn length(value: f32) LengthPercentage {
        return .{ .value = compact_length.CompactLength.length(value) };
    }

    pub fn percent(value: f32) LengthPercentage {
        return .{ .value = compact_length.CompactLength.percent(value) };
    }

    pub fn calc(pointer: *const anyopaque) LengthPercentage {
        return .{ .value = compact_length.CompactLength.calc(pointer) };
    }

    pub fn resolve(self: LengthPercentage, basis: f32) f32 {
        return switch (self.value.tag()) {
            .length => self.value.value(),
            .percent => self.value.value() * basis,
            // Tree's default calc resolver returns 0; other non-definite
            // values resolve to zero through `ResolveOrZero`.
            .calc => 0,
            else => 0,
        };
    }

    pub fn resolve_to_option(self: LengthPercentage, basis: ?f32) ?f32 {
        return switch (self.value.tag()) {
            .length => self.value.value(),
            .percent => if (basis) |b| self.value.value() * b else null,
            .calc => 0,
            else => null,
        };
    }

    pub fn zero() LengthPercentage {
        return .{ .value = compact_length.CompactLength.length(0) };
    }
    pub fn into_raw(self: LengthPercentage) compact_length.CompactLength {
        return self.value;
    }
    pub fn expand(self: LengthPercentage) ExpandedLengthPercentage {
        return switch (self.value.tag()) {
            .length => .{ .length = self.value.value() },
            .percent => .{ .percent = self.value.value() },
            else => unreachable,
        };
    }
};

pub const ExpandedLengthPercentage = union(enum) { length: f32, percent: f32 };

pub const LengthPercentageAuto = struct {
    /// Taffy-compatible serde: u64 wire bits with wrapper-specific tag validation.
    pub const zerdeSerialize = serde_serialize;
    pub const zerdeDeserialize = serde_deserialize;

    value: compact_length.CompactLength,

    pub fn from_length(value: anytype) LengthPercentageAuto {
        return .{ .value = compact_length.compact_length_from_length(value) };
    }
    pub fn from_percent(value: anytype) LengthPercentageAuto {
        return .{ .value = compact_length.compact_length_from_percent(value) };
    }

    pub fn from_str(input: []const u8) DimensionParseError!LengthPercentageAuto {
        const source = trim_dimension_input(input);
        if (std.ascii.eqlIgnoreCase(source, "auto")) return .auto();
        if (std.mem.endsWith(u8, source, "%")) return LengthPercentageAuto.percent((parse_numeric(source[0 .. source.len - 1]) catch return error.InvalidNumber) / 100.0);
        if (std.mem.endsWith(u8, source, "px")) return .length(parse_numeric(source[0 .. source.len - 2]) catch return error.InvalidNumber);
        return error.InvalidDimension;
    }

    pub fn auto() LengthPercentageAuto {
        return .{ .value = compact_length.CompactLength.auto() };
    }

    pub fn length(value: f32) LengthPercentageAuto {
        return .{ .value = compact_length.CompactLength.length(value) };
    }

    pub fn percent(value: f32) LengthPercentageAuto {
        return .{ .value = compact_length.CompactLength.percent(value) };
    }

    pub fn calc(pointer: *const anyopaque) LengthPercentageAuto {
        return .{ .value = compact_length.CompactLength.calc(pointer) };
    }

    pub fn resolve(self: LengthPercentageAuto, basis: f32) ?f32 {
        return switch (self.value.tag()) {
            .auto => null,
            .length => self.value.value(),
            .percent => self.value.value() * basis,
            .calc => 0,
            else => 0,
        };
    }

    pub fn resolve_to_option(self: LengthPercentageAuto, basis: ?f32) ?f32 {
        return switch (self.value.tag()) {
            .auto => null,
            .length => self.value.value(),
            .percent => if (basis) |b| self.value.value() * b else null,
            .calc => 0,
            else => null,
        };
    }

    pub fn zero() LengthPercentageAuto {
        return .{ .value = compact_length.CompactLength.length(0) };
    }
    pub fn is_auto(self: LengthPercentageAuto) bool {
        return self.value.tag() == .auto;
    }
    pub fn into_raw(self: LengthPercentageAuto) compact_length.CompactLength {
        return self.value;
    }
    pub fn expand(self: LengthPercentageAuto) ExpandedLengthPercentageAuto {
        return switch (self.value.tag()) {
            .auto => .auto,
            .length => .{ .length = self.value.value() },
            .percent => .{ .percent = self.value.value() },
            else => unreachable,
        };
    }
};

pub const ExpandedLengthPercentageAuto = union(enum) { auto, length: f32, percent: f32 };

pub const Dimension = struct {
    /// Taffy-compatible serde: u64 wire bits with wrapper-specific tag validation.
    pub const zerdeSerialize = serde_serialize;
    pub const zerdeDeserialize = serde_deserialize;

    value: compact_length.CompactLength,

    pub const auto: Dimension = .{ .value = compact_length.CompactLength.auto() };
    pub const min_content: Dimension = .{ .value = compact_length.CompactLength.min_content() };
    pub const max_content: Dimension = .{ .value = compact_length.CompactLength.max_content() };
    pub const fit_content: Dimension = .{ .value = compact_length.CompactLength.fit_content() };
    pub const stretch: Dimension = .{ .value = compact_length.CompactLength.stretch() };
    pub const content: Dimension = .{ .value = compact_length.CompactLength.content() };

    pub fn length(value: f32) Dimension {
        return .{ .value = compact_length.CompactLength.length(value) };
    }

    pub fn from_length(value: anytype) Dimension {
        return .{ .value = compact_length.compact_length_from_length(value) };
    }
    pub fn from_percent(value: anytype) Dimension {
        return .{ .value = compact_length.compact_length_from_percent(value) };
    }

    pub fn from_str(input: []const u8) DimensionParseError!Dimension {
        const source = trim_dimension_input(input);
        if (std.ascii.eqlIgnoreCase(source, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(source, "min-content")) return .min_content;
        if (std.ascii.eqlIgnoreCase(source, "max-content")) return .max_content;
        if (std.ascii.eqlIgnoreCase(source, "fit-content")) return .fit_content;
        if (std.ascii.eqlIgnoreCase(source, "stretch")) return .stretch;
        if (std.ascii.eqlIgnoreCase(source, "content")) return .content;
        if (std.mem.endsWith(u8, source, "%")) return .percent((parse_numeric(source[0 .. source.len - 1]) catch return error.InvalidNumber) / 100.0);
        if (std.mem.endsWith(u8, source, "px")) return .length(parse_numeric(source[0 .. source.len - 2]) catch return error.InvalidNumber);
        if (std.mem.startsWith(u8, source, "fit-content(") and std.mem.endsWith(u8, source, ")")) {
            const inner = source[12 .. source.len - 1];
            if (std.mem.endsWith(u8, inner, "%")) return .fit_content_percent((parse_numeric(inner[0 .. inner.len - 1]) catch return error.InvalidNumber) / 100.0);
            if (std.mem.endsWith(u8, inner, "px")) return .fit_content_length(parse_numeric(inner[0 .. inner.len - 2]) catch return error.InvalidNumber);
        }
        return error.InvalidDimension;
    }
    pub fn calc(value: *const anyopaque) Dimension {
        return .{ .value = compact_length.CompactLength.calc(value) };
    }
    pub fn from_raw(value: compact_length.CompactLength) Dimension {
        return .{ .value = value };
    }

    pub fn percent(value: f32) Dimension {
        return .{ .value = compact_length.CompactLength.percent(value) };
    }

    pub fn fit_content_length(value: f32) Dimension {
        return .{ .value = compact_length.CompactLength.fit_content_length(value) };
    }

    pub fn fit_content_px(value: f32) Dimension {
        return fit_content_length(value);
    }

    pub fn fit_content_percent(value: f32) Dimension {
        return .{ .value = compact_length.CompactLength.fit_content_percent(value) };
    }

    /// `fit-content(calc(...))`.
    pub fn fit_content_calc(handle: *const anyopaque) Dimension {
        return .{ .value = compact_length.CompactLength.fit_content_calc(handle) };
    }
    pub fn is_fit_content_calc(self: Dimension) bool {
        return self.value.is_fit_content_calc();
    }

    pub fn resolve(self: Dimension, basis: ?f32) ?f32 {
        return switch (self.value.tag()) {
            .length => self.value.value(),
            .percent => if (basis) |b| self.value.value() * b else null,
            .calc => 0,
            else => null,
        };
    }

    pub fn resolve_to_option(self: Dimension, basis: ?f32) ?f32 {
        return self.resolve(basis);
    }

    pub fn is_definite(self: Dimension) bool {
        return self.value.is_length_or_percentage();
    }

    pub fn into_option(self: Dimension) ?f32 {
        return switch (self.value.tag()) {
            .length => self.value.value(),
            else => null,
        };
    }

    pub fn is_auto(self: Dimension) bool {
        return self.value.tag() == .auto;
    }
    pub fn is_sizing_keyword(self: Dimension) bool {
        return !self.is_definite() and !self.is_auto();
    }
    pub fn is_stretch(self: Dimension) bool {
        return self.value.tag() == .stretch;
    }
    pub fn is_content(self: Dimension) bool {
        return self.value.tag() == .content;
    }
    pub fn tag(self: Dimension) compact_length.CompactLengthTag {
        return self.value.tag();
    }
    pub fn numeric_value(self: Dimension) f32 {
        return self.value.numericValue();
    }

    pub fn calc_handle(self: Dimension) ?*const anyopaque {
        return self.value.calc_value();
    }
    pub fn into_raw(self: Dimension) compact_length.CompactLength {
        return self.value;
    }
    pub fn expand(self: Dimension) ExpandedDimension {
        return switch (self.value.tag()) {
            .auto => .auto,
            .length => .{ .length = self.value.value() },
            .percent => .{ .percent = self.value.value() },
            .min_content => .min_content,
            .max_content => .max_content,
            .fit_content_keyword => .fit_content,
            .fit_content_px => .{ .fit_content_length = self.value.value() },
            .fit_content_percent => .{ .fit_content_percent = self.value.value() },
            .stretch => .stretch,
            .content => .content,
            .calc => .calc,
            .fit_content_calc => .fit_content_calc,
            else => .auto,
        };
    }
};

pub const ExpandedDimension = union(enum) {
    auto,
    length: f32,
    percent: f32,
    min_content,
    max_content,
    fit_content,
    fit_content_length: f32,
    fit_content_percent: f32,
    stretch,
    content,
    calc,
    fit_content_calc,
};

pub fn dimensionToAvailable(value: Dimension) AvailableSpace {
    return switch (value.value.tag()) {
        .min_content => .min_content,
        .max_content => .max_content,
        else => .max_content,
    };
}

pub fn dimension_value(value: Dimension) compact_length.CompactLength {
    return value.value;
}

pub fn clamp_resolved_size(value: f32, minimum: LengthPercentageAuto, maximum: LengthPercentageAuto, basis: f32) f32 {
    const min_value = minimum.resolve(basis) orelse 0;
    // An auto max is unbounded (infinity), never the value itself: using
    // the value here would swallow the min clamp whenever max is unset.
    const max_value = maximum.resolve(basis) orelse std.math.inf(f32);
    return @min(max_value, @max(min_value, value));
}

pub fn dimension_auto() Dimension {
    return Dimension.auto;
}
pub fn from(value: compact_length.CompactLength) Dimension {
    return Dimension.from_raw(value);
}
pub fn dimension_raw_value(value: Dimension) compact_length.CompactLength {
    return value.value;
}
pub fn min_content() Dimension {
    return Dimension.min_content;
}
pub fn max_content() Dimension {
    return Dimension.max_content;
}
pub fn fit_content() Dimension {
    return Dimension.fit_content;
}
pub fn stretch() Dimension {
    return Dimension.stretch;
}
pub fn content() Dimension {
    return Dimension.content;
}
pub fn dimension_min_content() Dimension {
    return Dimension.min_content;
}
pub fn dimension_max_content() Dimension {
    return Dimension.max_content;
}
pub fn dimension_fit_content() Dimension {
    return Dimension.fit_content;
}
pub fn dimension_stretch() Dimension {
    return Dimension.stretch;
}
pub fn dimension_content() Dimension {
    return Dimension.content;
}

pub fn rect_dimension_from_length(left: f32, right: f32, top: f32, bottom: f32) @import("../geometry.zig").Rect(Dimension) {
    return .{ .left = Dimension.length(left), .right = Dimension.length(right), .top = Dimension.length(top), .bottom = Dimension.length(bottom) };
}

pub fn rect_dimension_from_percent(left: f32, right: f32, top: f32, bottom: f32) @import("../geometry.zig").Rect(Dimension) {
    return .{ .left = Dimension.percent(left), .right = Dimension.percent(right), .top = Dimension.percent(top), .bottom = Dimension.percent(bottom) };
}

pub fn dimension_from_expanded(value: ExpandedDimension) Dimension {
    return switch (value) {
        .auto => Dimension.auto,
        .length => |number| Dimension.length(number),
        .percent => |number| Dimension.percent(number),
        .min_content => Dimension.min_content,
        .max_content => Dimension.max_content,
        .fit_content => Dimension.fit_content,
        .fit_content_length => |number| Dimension.fit_content_length(number),
        .fit_content_percent => |number| Dimension.fit_content_percent(number),
        .stretch => Dimension.stretch,
        .content => Dimension.content,
        .calc, .fit_content_calc => @panic("calc dimension conversion requires an opaque handle"),
    };
}

test "dimension keeps keyword values distinct" {
    const testing = @import("std").testing;
    // The packed representation must stay pointer-sized.
    try testing.expectEqual(@as(usize, 8), @sizeOf(compact_length.CompactLength));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Dimension));
    try testing.expectEqual(@as(usize, 8), @sizeOf(LengthPercentage));
    try testing.expectEqual(@as(usize, 8), @sizeOf(LengthPercentageAuto));
    try testing.expect(Dimension.auto.value.tag() == .auto);
    try testing.expect((Dimension.length(20)).is_definite());
    try testing.expect((Dimension.percent(0.5)).resolve(null) == null);
    try testing.expect(Dimension.percent(0.5).into_option() == null);
    try testing.expectEqual(@as(?f32, 12), Dimension.length(12).into_option());
}

test "calc values resolve to zero through the default resolver" {
    const testing = @import("std").testing;
    const handle: *const anyopaque = @ptrFromInt(8);
    try testing.expectEqual(@as(?f32, 0), Dimension.calc(handle).resolve(100));
    try testing.expectEqual(@as(?f32, 0), Dimension.calc(handle).resolve(null));
    try testing.expectEqual(@as(f32, 0), LengthPercentage.calc(handle).resolve(100));
    try testing.expectEqual(@as(?f32, 0), LengthPercentage.calc(handle).resolve_to_option(null));
    try testing.expectEqual(@as(?f32, 0), LengthPercentageAuto.calc(handle).resolve_to_option(null));
    try testing.expectEqual(@as(?f32, 0), LengthPercentageAuto.calc(handle).resolve(20));
}

test "dimension CSS spellings preserve percentage and fit-content values" {
    const testing = @import("std").testing;
    const percent = try Dimension.from_str("50%");
    try testing.expectEqual(@as(f32, 0.5), percent.value.value());
    const fit = try Dimension.from_str("fit-content(24px)");
    try testing.expectEqual(@as(f32, 24), fit.value.value());
    try testing.expect((try LengthPercentageAuto.from_str("auto")).is_auto());
}
