//! Direct port of Taffy's `style/alignment.rs` value vocabulary.

const std = @import("std");
const css = @import("../util/css.zig");

const serde_support = @import("../serde_support.zig");
const serde_serialize = serde_support.serialize;
const serde_deserialize = serde_support.deserialize;
pub const AlignmentParseError = error{ InvalidAlignment, InvalidSafetyCombination };

/// The overflow-position modifier. `default` (no keyword) behaves as `unsafe`,
/// except for absolutely positioned boxes, whose alignment is adjusted to
/// minimize overflow of their containing block (CSS Box Alignment §4.4.1.2).
pub const AlignmentSafety = enum { default, unsafe, safe };

pub const AlignItemsKeyword = enum {
    /// `normal`: behaves as `stretch` or `start` depending on the layout mode.
    normal,
    start,
    end,
    flex_start,
    flex_end,
    self_start,
    self_end,
    center,
    baseline,
    stretch,

    pub fn reversed(self: AlignItemsKeyword) AlignItemsKeyword {
        return switch (self) {
            .start => .end,
            .end => .start,
            .flex_start => .flex_end,
            .flex_end => .flex_start,
            else => self,
        };
    }
};

pub const AlignContentKeyword = enum {
    /// `normal`: behaves as `stretch` (or `start` where stretch does not apply).
    normal,
    start,
    end,
    flex_start,
    flex_end,
    center,
    stretch,
    space_between,
    space_evenly,
    space_around,

    pub fn reversed(self: AlignContentKeyword) AlignContentKeyword {
        return switch (self) {
            .start => .end,
            .end => .start,
            .flex_start => .flex_end,
            .flex_end => .flex_start,
            .stretch => .end,
            else => self,
        };
    }
};

pub const AlignItems = struct {
    /// Taffy-compatible serde: single PascalCase string (with `Safe` prefix).
    pub const zerdeSerialize = serde_serialize;
    pub const zerdeDeserialize = serde_deserialize;

    keyword: AlignItemsKeyword = .normal,
    safety: AlignmentSafety = .default,

    pub const normal: AlignItems = .{ .keyword = .normal };
    pub const NORMAL: AlignItems = .{ .keyword = .normal };

    pub const start: AlignItems = .{ .keyword = .start };
    pub const end: AlignItems = .{ .keyword = .end };
    pub const flex_start: AlignItems = .{ .keyword = .flex_start };
    pub const flex_end: AlignItems = .{ .keyword = .flex_end };
    pub const center: AlignItems = .{ .keyword = .center };
    pub const baseline: AlignItems = .{ .keyword = .baseline };
    pub const stretch: AlignItems = .{ .keyword = .stretch };
    pub const START: AlignItems = .{ .keyword = .start };
    pub const END: AlignItems = .{ .keyword = .end };
    pub const FLEX_START: AlignItems = .{ .keyword = .flex_start };
    pub const FLEX_END: AlignItems = .{ .keyword = .flex_end };
    pub const SELF_START: AlignItems = .{ .keyword = .self_start };
    pub const SELF_END: AlignItems = .{ .keyword = .self_end };
    pub const CENTER: AlignItems = .{ .keyword = .center };
    pub const BASELINE: AlignItems = .{ .keyword = .baseline };
    pub const STRETCH: AlignItems = .{ .keyword = .stretch };
    pub const SAFE_START: AlignItems = .{ .keyword = .start, .safety = .safe };
    pub const SAFE_END: AlignItems = .{ .keyword = .end, .safety = .safe };
    pub const SAFE_FLEX_START: AlignItems = .{ .keyword = .flex_start, .safety = .safe };
    pub const SAFE_FLEX_END: AlignItems = .{ .keyword = .flex_end, .safety = .safe };
    pub const SAFE_CENTER: AlignItems = .{ .keyword = .center, .safety = .safe };
    pub const SAFE_SELF_START: AlignItems = .{ .keyword = .self_start, .safety = .safe };
    pub const SAFE_SELF_END: AlignItems = .{ .keyword = .self_end, .safety = .safe };

    pub fn is_safe(self: AlignItems) bool {
        return self.safety == .safe;
    }
    pub fn keyword_value(self: AlignItems) AlignItemsKeyword {
        return self.keyword;
    }
    /// This alignment with the given overflow-position modifier.
    pub fn with_safety(self: AlignItems, safety: AlignmentSafety) AlignItems {
        return .{ .keyword = self.keyword, .safety = safety };
    }
    pub inline fn is_stretch_or_normal(self: AlignItems) bool {
        return self.keyword == .stretch or self.keyword == .normal;
    }

    pub fn resolve_self_relative(self: AlignItems, item_direction: anytype, container_direction: anytype, axis_is_inline: bool) AlignItems {
        const flip = axis_is_inline and item_direction != container_direction;
        const resolved: AlignItemsKeyword = switch (self.keyword) {
            .self_start => if (flip) .end else .start,
            .self_end => if (flip) .start else .end,
            else => self.keyword,
        };
        return .{ .keyword = resolved, .safety = self.safety };
    }

    pub fn from_str(input: []const u8) AlignmentParseError!AlignItems {
        return parse_align_items(input);
    }
};

pub const AlignSelf = AlignItems;
pub const JustifyItems = AlignItems;
pub const JustifySelf = AlignItems;

pub const AlignContent = struct {
    /// Taffy-compatible serde: single PascalCase string (with `Safe` prefix).
    pub const zerdeSerialize = serde_serialize;
    pub const zerdeDeserialize = serde_deserialize;

    keyword: AlignContentKeyword = .normal,
    safety: AlignmentSafety = .default,

    pub const normal: AlignContent = .{ .keyword = .normal };
    pub const NORMAL: AlignContent = .{ .keyword = .normal };

    pub const start: AlignContent = .{ .keyword = .start };
    pub const end: AlignContent = .{ .keyword = .end };
    pub const flex_start: AlignContent = .{ .keyword = .flex_start };
    pub const flex_end: AlignContent = .{ .keyword = .flex_end };
    pub const center: AlignContent = .{ .keyword = .center };
    pub const stretch: AlignContent = .{ .keyword = .stretch };
    pub const space_between: AlignContent = .{ .keyword = .space_between };
    pub const space_evenly: AlignContent = .{ .keyword = .space_evenly };
    pub const space_around: AlignContent = .{ .keyword = .space_around };
    pub const START: AlignContent = .{ .keyword = .start };
    pub const END: AlignContent = .{ .keyword = .end };
    pub const FLEX_START: AlignContent = .{ .keyword = .flex_start };
    pub const FLEX_END: AlignContent = .{ .keyword = .flex_end };
    pub const CENTER: AlignContent = .{ .keyword = .center };
    pub const STRETCH: AlignContent = .{ .keyword = .stretch };
    pub const SPACE_BETWEEN: AlignContent = .{ .keyword = .space_between };
    pub const SPACE_EVENLY: AlignContent = .{ .keyword = .space_evenly };
    pub const SPACE_AROUND: AlignContent = .{ .keyword = .space_around };
    pub const SAFE_START: AlignContent = .{ .keyword = .start, .safety = .safe };
    pub const SAFE_END: AlignContent = .{ .keyword = .end, .safety = .safe };
    pub const SAFE_FLEX_START: AlignContent = .{ .keyword = .flex_start, .safety = .safe };
    pub const SAFE_FLEX_END: AlignContent = .{ .keyword = .flex_end, .safety = .safe };
    pub const SAFE_CENTER: AlignContent = .{ .keyword = .center, .safety = .safe };

    pub fn is_safe(self: AlignContent) bool {
        return self.safety == .safe;
    }
    pub fn keyword_value(self: AlignContent) AlignContentKeyword {
        return self.keyword;
    }
    /// This alignment with the given overflow-position modifier.
    pub fn with_safety(self: AlignContent, safety: AlignmentSafety) AlignContent {
        return .{ .keyword = self.keyword, .safety = safety };
    }

    pub fn from_str(input: []const u8) AlignmentParseError!AlignContent {
        return parse_align_content(input);
    }
};

pub const JustifyContent = AlignContent;

pub fn reversed(keyword: AlignContentKeyword) AlignContentKeyword {
    return keyword.reversed();
}

/// Look `name` up in `table` (ASCII case-insensitive).
fn lookup(comptime K: type, name: []const u8, comptime table: []const struct { []const u8, K }) ?K {
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    }
    return null;
}

const items_positions = [_]struct { []const u8, AlignItemsKeyword }{
    .{ "start", .start },           .{ "end", .end },           .{ "flex-start", .flex_start },
    .{ "flex-end", .flex_end },     .{ "self-start", .self_start }, .{ "self-end", .self_end },
    .{ "center", .center },
};
const items_keywords = items_positions ++ [_]struct { []const u8, AlignItemsKeyword }{
    .{ "normal", .normal }, .{ "baseline", .baseline }, .{ "stretch", .stretch },
};
const content_positions = [_]struct { []const u8, AlignContentKeyword }{
    .{ "start", .start }, .{ "end", .end }, .{ "flex-start", .flex_start }, .{ "flex-end", .flex_end }, .{ "center", .center },
};
const content_keywords = content_positions ++ [_]struct { []const u8, AlignContentKeyword }{
    .{ "normal", .normal },               .{ "stretch", .stretch },           .{ "space-between", .space_between },
    .{ "space-evenly", .space_evenly },   .{ "space-around", .space_around },
};

/// Taffy's `FromCss for AlignItems`/`AlignContent`: a keyword, or `safe` /
/// `unsafe` followed by a position keyword.
fn parse_alignment(comptime A: type, comptime K: type, comptime positions: anytype, comptime keywords: anytype, input: []const u8) AlignmentParseError!A {
    const S = struct {
        fn parse(combo: *bool, p: *css.Parser) css.Error!A {
            const first = try p.expect_ident();
            const safety: ?AlignmentSafety = if (std.ascii.eqlIgnoreCase(first, "safe"))
                .safe
            else if (std.ascii.eqlIgnoreCase(first, "unsafe"))
                .unsafe
            else
                null;
            if (safety) |s| {
                const pos = try p.expect_ident();
                const keyword = lookup(K, pos, &positions) orelse {
                    // A known keyword that cannot take a safety modifier.
                    combo.* = lookup(K, pos, &keywords) != null;
                    return error.InvalidCss;
                };
                return .{ .keyword = keyword, .safety = s };
            }
            return .{ .keyword = lookup(K, first, &keywords) orelse return error.InvalidCss, .safety = .default };
        }
    };
    var combo = false;
    return css.parse_str_entirely(input, A, &combo, S.parse) catch
        if (combo) error.InvalidSafetyCombination else error.InvalidAlignment;
}

fn parse_align_items(input: []const u8) AlignmentParseError!AlignItems {
    return parse_alignment(AlignItems, AlignItemsKeyword, items_positions, items_keywords, input);
}

fn parse_align_content(input: []const u8) AlignmentParseError!AlignContent {
    return parse_alignment(AlignContent, AlignContentKeyword, content_positions, content_keywords, input);
}

test "alignment carries safety independently from the keyword" {
    const testing = @import("std").testing;
    const safe = AlignItems{ .keyword = .center, .safety = .safe };
    try testing.expect(safe.keyword == .center);
    try testing.expect(safe.safety == .safe);
}

test "alignment CSS parser preserves safety and rejects invalid combinations" {
    const testing = @import("std").testing;
    const safe_center = try AlignItems.from_str("safe center");
    try testing.expect(safe_center.is_safe());
    try testing.expectEqual(AlignItemsKeyword.center, safe_center.keyword);
    try testing.expectError(error.InvalidSafetyCombination, AlignItems.from_str("safe baseline"));
    const space = try AlignContent.from_str("space-between");
    try testing.expectEqual(AlignContentKeyword.space_between, space.keyword);
}
