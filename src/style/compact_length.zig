//! Port of Taffy's `style/compact_length.rs`.
//!
//! Taffy stores its tagged values in one pointer-sized word; the port uses the
//! same packed representation: the tag lives in the top 6 bits of a `u64` and
//! the payload (an f32 bit pattern or a calc pointer) in the low 58 bits.

const std = @import("std");

const serde_support = @import("../serde_support.zig");
const serde_options = serde_support.pascal_options;
const serde_serialize = serde_support.serialize;
const serde_deserialize = serde_support.deserialize;

pub const CompactLength = struct {
    bits: u64,

    /// The low 58 bits hold the payload; the top 6 bits hold the tag.
    pub const payload_mask: u64 = (1 << 58) - 1;

    fn init(kind: CompactLengthTag, payload: u64) CompactLength {
        return .{ .bits = (@as(u64, @backingInt(kind)) << 58) | (payload & payload_mask) };
    }

    fn initValue(kind: CompactLengthTag, number: f32) CompactLength {
        return init(kind, @as(u64, @as(u32, @bitCast(number))));
    }

    /// Taffy-compatible serde: u64 wire bits with tag validation.
    pub const serde = serde_options;
    pub const zerdeSerialize = serde_serialize;
    pub const zerdeDeserialize = serde_deserialize;

    // -- Constructors (Taffy's associated functions) ------------------------

    pub fn auto() CompactLength {
        return init(.auto, 0);
    }
    pub fn length(number: f32) CompactLength {
        return initValue(.length, number);
    }
    pub fn percent(number: f32) CompactLength {
        return initValue(.percent, number);
    }
    pub fn fr(number: f32) CompactLength {
        return initValue(.fr, number);
    }
    pub fn min_content() CompactLength {
        return init(.min_content, 0);
    }
    pub fn max_content() CompactLength {
        return init(.max_content, 0);
    }
    pub fn fit_content() CompactLength {
        return init(.fit_content_keyword, 0);
    }
    pub fn fit_content_length(number: f32) CompactLength {
        return initValue(.fit_content_px, number);
    }
    pub fn fit_content_percent(number: f32) CompactLength {
        return initValue(.fit_content_percent, number);
    }
    pub fn stretch() CompactLength {
        return init(.stretch, 0);
    }
    pub fn content() CompactLength {
        return init(.content, 0);
    }
    pub fn calc(pointer: *const anyopaque) CompactLength {
        const address = @intFromPtr(pointer);
        std.debug.assert(address < (1 << 58));
        return init(.calc, address);
    }

    // -- Queries ------------------------------------------------------------

    pub fn tag(self: CompactLength) CompactLengthTag {
        return @fromBackingInt(@intCast(@as(u8, @truncate(self.bits >> 58))));
    }

    pub fn value(self: CompactLength) f32 {
        return @bitCast(@as(u32, @truncate(self.bits)));
    }

    pub fn is_zero(self: CompactLength) bool {
        return self.tag() == .length and self.value() == 0;
    }
    pub fn is_length_or_percentage(self: CompactLength) bool {
        return self.tag() == .length or self.tag() == .percent;
    }
    pub fn is_auto(self: CompactLength) bool {
        return self.tag() == .auto;
    }
    pub fn is_content(self: CompactLength) bool {
        return self.tag() == .content;
    }
    pub fn is_min_content(self: CompactLength) bool {
        return self.tag() == .min_content;
    }
    pub fn is_max_content(self: CompactLength) bool {
        return self.tag() == .max_content;
    }
    pub fn is_fit_content(self: CompactLength) bool {
        return self.tag() == .fit_content_px or self.tag() == .fit_content_percent;
    }
    pub fn is_sizing_keyword(self: CompactLength) bool {
        return self.is_min_content() or self.is_max_content() or self.tag() == .fit_content_keyword or self.is_fit_content() or self.tag() == .stretch;
    }
    pub fn is_max_or_fit_content(self: CompactLength) bool {
        return self.is_max_content() or self.is_fit_content();
    }
    pub fn is_max_content_alike(self: CompactLength) bool {
        return self.tag() == .auto or self.is_max_content() or self.is_fit_content();
    }
    pub fn is_min_or_max_content(self: CompactLength) bool {
        return self.is_min_content() or self.is_max_content();
    }
    pub fn is_intrinsic(self: CompactLength) bool {
        return self.tag() == .auto or self.is_min_content() or self.is_max_content() or self.is_fit_content();
    }
    pub fn is_fr(self: CompactLength) bool {
        return self.tag() == .fr;
    }
    pub fn uses_percentage(self: CompactLength) bool {
        const tag_value = self.tag();
        return tag_value == .percent or tag_value == .fit_content_percent or tag_value == .calc;
    }

    pub fn is_calc(self: CompactLength) bool {
        return self.tag() == .calc;
    }
    pub fn calc_value(self: CompactLength) ?*const anyopaque {
        if (self.tag() != .calc) return null;
        return @ptrFromInt(self.bits & payload_mask);
    }
    pub fn resolved_percentage_size(self: CompactLength, parent_size: f32) ?f32 {
        return switch (self.tag()) {
            .percent => self.value() * parent_size,
            // Tree's default resolver returns 0 for calc values.
            .calc => 0,
            else => null,
        };
    }

    pub fn serialized(self: CompactLength) u64 {
        const tag_value: u64 = @backingInt(self.tag());
        const value_bits: u64 = switch (self.tag()) {
            .length, .percent, .fr, .fit_content_px, .fit_content_percent => @as(u64, @as(u32, @bitCast(self.value()))),
            else => 0,
        };
        // Taffy's 64-bit representation serializes as `(tag << 32) | bits`.
        // Keeping this exact wire layout makes semantic values round-trip
        // against the Rust implementation.
        return (tag_value << 32) | value_bits;
    }
};

/// Taffy's inner compact representation is an implementation detail; keeping
/// the alias makes the type-level name available to ports that inspect it.
pub const CompactLengthInner = CompactLength;

pub const CompactLengthTag = enum(u8) {
    calc,
    length = 0b0000_0001,
    percent = 0b0000_0010,
    auto = 0b0000_0011,
    fr = 0b0000_0100,
    min_content = 0b0000_0111,
    max_content = 0b0000_1111,
    fit_content_px = 0b0001_0111,
    fit_content_percent = 0b0001_1111,
    fit_content_keyword = 0b0010_0111,
    stretch = 0b0010_1111,
    content = 0b0011_0111,
};

pub fn f32_to_bits(value: f32) u32 {
    return @bitCast(value);
}
pub fn f32_from_bits(value: u32) f32 {
    return @bitCast(value);
}

pub fn from_serialized(serialized: u64) CompactLength {
    const tag_value: u8 = @intCast(serialized >> 32);
    const value: f32 = f32_from_bits(@intCast(serialized & 0xffff_ffff));
    return switch (tag_value) {
        @backingInt(CompactLengthTag.length) => CompactLength.length(value),
        @backingInt(CompactLengthTag.percent) => CompactLength.percent(value),
        @backingInt(CompactLengthTag.fr) => CompactLength.fr(value),
        @backingInt(CompactLengthTag.fit_content_px) => CompactLength.fit_content_length(value),
        @backingInt(CompactLengthTag.fit_content_percent) => CompactLength.fit_content_percent(value),
        @backingInt(CompactLengthTag.auto) => CompactLength.auto(),
        @backingInt(CompactLengthTag.min_content) => CompactLength.min_content(),
        @backingInt(CompactLengthTag.max_content) => CompactLength.max_content(),
        @backingInt(CompactLengthTag.fit_content_keyword) => CompactLength.fit_content(),
        @backingInt(CompactLengthTag.stretch) => CompactLength.stretch(),
        @backingInt(CompactLengthTag.content) => CompactLength.content(),
        else => @panic("invalid serialized Taffy compact length"),
    };
}

pub fn compact_length_from_length(value: anytype) CompactLength {
    return CompactLength.length(@floatCast(value));
}
pub fn compact_length_from_percent(value: anytype) CompactLength {
    return CompactLength.percent(@floatCast(value));
}
pub fn compact_length_from_fr(value: anytype) CompactLength {
    return CompactLength.fr(@floatCast(value));
}
pub fn compact_length_auto() CompactLength {
    return CompactLength.auto();
}
pub fn compact_length_min_content() CompactLength {
    return CompactLength.min_content();
}
pub fn compact_length_max_content() CompactLength {
    return CompactLength.max_content();
}
pub fn compact_length_fit_content_px(value: f32) CompactLength {
    return CompactLength.fit_content_length(value);
}
pub fn compact_length_fit_content_percent(value: f32) CompactLength {
    return CompactLength.fit_content_percent(value);
}
pub fn compact_length_fit_content_keyword() CompactLength {
    return CompactLength.fit_content();
}
pub fn compact_length_stretch() CompactLength {
    return CompactLength.stretch();
}
pub fn compact_length_content() CompactLength {
    return CompactLength.content();
}
pub fn compact_length_calc(value: *const anyopaque) CompactLength {
    return CompactLength.calc(value);
}

// Module-level spellings mirror Taffy's associated constructors. They avoid
// colliding with Zig union tag names while keeping call sites source-shaped.
pub fn from_length(value: anytype) CompactLength {
    return compact_length_from_length(value);
}
pub fn from_percent(value: anytype) CompactLength {
    return compact_length_from_percent(value);
}
pub fn from_fr(value: anytype) CompactLength {
    return compact_length_from_fr(value);
}
pub fn length(value: f32) CompactLength {
    return CompactLength.length(value);
}
pub fn percent(value: f32) CompactLength {
    return CompactLength.percent(value);
}
pub fn calc(value: *const anyopaque) CompactLength {
    return CompactLength.calc(value);
}
pub fn auto() CompactLength {
    return CompactLength.auto();
}
pub fn fr(value: f32) CompactLength {
    return CompactLength.fr(value);
}
pub fn min_content() CompactLength {
    return CompactLength.min_content();
}
pub fn max_content() CompactLength {
    return CompactLength.max_content();
}
pub fn fit_content_px(value: f32) CompactLength {
    return CompactLength.fit_content_length(value);
}
pub fn fit_content_percent(value: f32) CompactLength {
    return CompactLength.fit_content_percent(value);
}
pub fn fit_content_keyword() CompactLength {
    return CompactLength.fit_content();
}
pub fn stretch() CompactLength {
    return CompactLength.stretch();
}
pub fn content() CompactLength {
    return CompactLength.content();
}

pub fn from_tag(tag: CompactLengthTag) CompactLength {
    return switch (tag) {
        .calc => @panic("calc compact length requires an opaque pointer"),
        .length => CompactLength.length(0),
        .percent => CompactLength.percent(0),
        .auto => CompactLength.auto(),
        .fr => CompactLength.fr(0),
        .min_content => CompactLength.min_content(),
        .max_content => CompactLength.max_content(),
        .fit_content_px => CompactLength.fit_content_length(0),
        .fit_content_percent => CompactLength.fit_content_percent(0),
        .fit_content_keyword => CompactLength.fit_content(),
        .stretch => CompactLength.stretch(),
        .content => CompactLength.content(),
    };
}

pub fn from_val(value: f32, tag: CompactLengthTag) CompactLength {
    return switch (tag) {
        .length => CompactLength.length(value),
        .percent => CompactLength.percent(value),
        .fr => CompactLength.fr(value),
        .fit_content_px => CompactLength.fit_content_length(value),
        .fit_content_percent => CompactLength.fit_content_percent(value),
        else => from_tag(tag),
    };
}

pub fn from_ptr(pointer: *const anyopaque, tag: CompactLengthTag) CompactLength {
    if (tag == .calc) return CompactLength.calc(pointer);
    return from_tag(tag);
}

pub fn ptr(value: CompactLength) ?*const anyopaque {
    return value.calc_value();
}
pub fn calc_tag(value: CompactLength) CompactLengthTag {
    return value.tag();
}
pub fn serialize(value: CompactLength) u64 {
    return value.serialized();
}
pub fn deserialize(value: u64) CompactLength {
    return from_serialized(value);
}

pub fn compact_length_fit_content(value: anytype) CompactLength {
    return switch (value.value.tag()) {
        .length => CompactLength.fit_content_length(value.value.value()),
        .percent => CompactLength.fit_content_percent(value.value.value()),
        else => @panic("Taffy fit-content requires a length or percentage"),
    };
}

pub fn fit_content(value: anytype) CompactLength {
    return compact_length_fit_content(value);
}

pub fn tag_ptr(value: CompactLength) ?*const anyopaque {
    return value.calc_value();
}

pub fn isAuto(value: CompactLength) bool {
    return value.tag() == .auto;
}

pub fn isDefinite(value: CompactLength) bool {
    return value.is_length_or_percentage();
}

pub fn numericValue(value: CompactLength) f32 {
    return switch (value.tag()) {
        .length, .percent, .fit_content_px, .fit_content_percent, .fr => value.value(),
        else => 0,
    };
}

pub fn isCalc(value: CompactLength) bool {
    return value.is_calc();
}

test "compact length tags and serialized bits match Taffy wire values" {
    const testing = @import("std").testing;
    const length_value = CompactLength.length(12.5);
    try testing.expectEqual(@as(u8, 1), @backingInt(length_value.tag()));
    try testing.expectEqual(length_value, from_serialized(length_value.serialized()));
    try testing.expectEqual(@as(u8, 39), @backingInt(CompactLength.fit_content().tag()));
    const auto_value = CompactLength.auto();
    try testing.expectEqual(auto_value, from_serialized(auto_value.serialized()));

    // Every constructor packs and recovers its tag and payload.
    try testing.expectEqual(CompactLengthTag.auto, CompactLength.auto().tag());
    try testing.expectEqual(CompactLengthTag.min_content, CompactLength.min_content().tag());
    try testing.expectEqual(CompactLengthTag.max_content, CompactLength.max_content().tag());
    try testing.expectEqual(CompactLengthTag.fit_content_keyword, CompactLength.fit_content().tag());
    try testing.expectEqual(CompactLengthTag.stretch, CompactLength.stretch().tag());
    try testing.expectEqual(CompactLengthTag.content, CompactLength.content().tag());
    try testing.expectEqual(@as(f32, 0.25), CompactLength.fit_content_percent(0.25).value());
    try testing.expectEqual(@as(f32, 24), CompactLength.fit_content_length(24).value());
    try testing.expectEqual(@as(f32, 2), CompactLength.fr(2).value());
    try testing.expectEqual(@as(f32, 0.5), CompactLength.percent(0.5).value());

    // calc payloads are pointers stored in the low 58 bits.
    const handle: *const anyopaque = @ptrFromInt(0x1234);
    const calc_value = CompactLength.calc(handle);
    try testing.expectEqual(CompactLengthTag.calc, calc_value.tag());
    try testing.expectEqual(handle, calc_value.calc_value().?);

    // Wire values captured from pinned Taffy 0.14.
    try testing.expectEqual(@as(u64, 5375000576), CompactLength.length(3.5).serialized());
    try testing.expectEqual(@as(u64, 9646899200), CompactLength.percent(0.5).serialized());
    try testing.expectEqual(@as(u64, 12884901888), CompactLength.auto().serialized());
    try testing.expectEqual(CompactLength.percent(0.5), from_serialized(CompactLength.percent(0.5).serialized()));
}
