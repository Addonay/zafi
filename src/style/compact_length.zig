//! Port of Taffy's `style/compact_length.rs`.
//!
//! Taffy stores its tagged values in one pointer-sized word; the port uses the
//! same packed representation: the tag lives in the top 8 bits of a `u64` and
//! the payload (an f32 bit pattern or a calc pointer) in the low 56 bits.
//!
//! Tag values are Taffy's (they are also the serde wire tags). Their low bits
//! classify the variant so that the common predicates are single mask tests:
//! bit 0 = not a calc pointer, bit 1 = keyword, bit 2 = uses a percentage,
//! bit 3 = sizing keyword.

const std = @import("std");

const serde_support = @import("../serde_support.zig");
const serde_options = serde_support.pascal_options;
const serde_serialize = serde_support.serialize;
const serde_deserialize = serde_support.deserialize;

pub const CompactLength = struct {
    bits: u64,

    /// The low 56 bits hold the payload; the top 8 bits hold the tag.
    pub const payload_mask: u64 = (1 << 56) - 1;

    pub const NON_POINTER_BIT: u8 = 0b0001;
    pub const KEYWORD_BIT: u8 = 0b0010;
    pub const PERCENTAGE_BIT: u8 = 0b0100;
    pub const SIZING_KEYWORD_BIT: u8 = 0b1000;

    inline fn init(kind: CompactLengthTag, payload: u64) CompactLength {
        return .{ .bits = (@as(u64, @backingInt(kind)) << 56) | (payload & payload_mask) };
    }

    inline fn tagBits(self: CompactLength) u8 {
        return @truncate(self.bits >> 56);
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
        std.debug.assert(address < (1 << 56));
        return init(.calc, address);
    }
    /// `fit-content(calc(...))`: a fit-content() whose limit is a calc() value.
    pub fn fit_content_calc(pointer: *const anyopaque) CompactLength {
        const address = @intFromPtr(pointer);
        std.debug.assert(address < (1 << 56));
        return init(.fit_content_calc, address);
    }

    // -- Queries ------------------------------------------------------------

    pub inline fn tag(self: CompactLength) CompactLengthTag {
        return @fromBackingInt(self.tagBits());
    }

    pub fn value(self: CompactLength) f32 {
        return @bitCast(@as(u32, @truncate(self.bits)));
    }

    pub fn is_zero(self: CompactLength) bool {
        return self.tag() == .length and self.value() == 0;
    }
    /// A plain `calc()` (not `fit-content(calc())`).
    pub inline fn is_plain_calc(self: CompactLength) bool {
        return self.tagBits() & (NON_POINTER_BIT | KEYWORD_BIT) == 0;
    }
    pub inline fn is_fit_content_calc(self: CompactLength) bool {
        return self.tagBits() & (NON_POINTER_BIT | KEYWORD_BIT) == KEYWORD_BIT;
    }
    /// Any variant holding a calc pointer.
    pub inline fn has_calc(self: CompactLength) bool {
        return self.tagBits() & NON_POINTER_BIT == 0;
    }
    pub inline fn is_length_or_percentage(self: CompactLength) bool {
        return self.tagBits() & (NON_POINTER_BIT | KEYWORD_BIT) == NON_POINTER_BIT;
    }
    pub inline fn is_length_percentage_or_calc(self: CompactLength) bool {
        return self.tagBits() & KEYWORD_BIT == 0;
    }
    pub inline fn is_auto(self: CompactLength) bool {
        return self.tag() == .auto;
    }
    pub inline fn is_content(self: CompactLength) bool {
        return self.tag() == .content;
    }
    pub inline fn is_min_content(self: CompactLength) bool {
        return self.tag() == .min_content;
    }
    pub inline fn is_max_content(self: CompactLength) bool {
        return self.tag() == .max_content;
    }
    pub inline fn is_fit_content(self: CompactLength) bool {
        return switch (self.tag()) {
            .fit_content_px, .fit_content_percent, .fit_content_calc => true,
            else => false,
        };
    }
    pub inline fn is_sizing_keyword(self: CompactLength) bool {
        const mask = NON_POINTER_BIT | KEYWORD_BIT | SIZING_KEYWORD_BIT;
        return self.tagBits() & mask == mask or self.is_fit_content_calc();
    }
    pub inline fn is_max_or_fit_content(self: CompactLength) bool {
        return self.is_max_content() or self.is_fit_content();
    }
    pub inline fn is_max_content_alike(self: CompactLength) bool {
        return self.tag() == .auto or self.is_max_content() or self.is_fit_content();
    }
    pub inline fn is_min_or_max_content(self: CompactLength) bool {
        return self.is_min_content() or self.is_max_content();
    }
    pub inline fn is_intrinsic(self: CompactLength) bool {
        return self.tag() == .auto or self.is_min_content() or self.is_max_content() or self.is_fit_content();
    }
    pub inline fn is_fr(self: CompactLength) bool {
        return self.tag() == .fr;
    }
    pub inline fn uses_percentage(self: CompactLength) bool {
        return self.tagBits() & PERCENTAGE_BIT != 0;
    }

    /// Deprecated alias of `is_plain_calc` (Taffy renamed `is_calc`).
    pub inline fn is_calc(self: CompactLength) bool {
        return self.is_plain_calc();
    }
    pub fn calc_value(self: CompactLength) ?*const anyopaque {
        if (!self.has_calc()) return null;
        return @ptrFromInt(self.bits & payload_mask);
    }
    /// Taffy's `MaybeResolve<Option<f32>>`: a length resolves as-is; a percentage
    /// or `calc()` needs a definite basis; anything else is indefinite.
    pub inline fn maybe_resolve(self: CompactLength, basis: ?f32) ?f32 {
        return self.maybe_resolve_with(basis, true);
    }

    /// `maybe_resolve`, specialised on whether the value can be `calc()`.
    ///
    /// With `with_calc == false` a calc value is treated as indefinite, so this must
    /// only be used where the caller has checked there is no calc value (see
    /// `GridItem.has_calc`). That variant is the plain three-way switch: even a
    /// cold calc arm makes LLVM materialise the `?f32` result through a stack
    /// slot (two narrow stores, one wide load: a store-forwarding stall) in the
    /// innermost layout loops.
    pub inline fn maybe_resolve_with(self: CompactLength, basis: ?f32, comptime with_calc: bool) ?f32 {
        if (with_calc) {
            if (self.tag() == .calc) return maybe_resolve_calc(self, basis);
        }
        // Merge on scalars and build the optional once (see `some_if`).
        const t = self.tag();
        const b = basis orelse 0;
        const ok = t == .length or (t == .percent and basis != null);
        const out = if (t == .percent) self.value() * b else self.value();
        return some_if(ok, out);
    }

    /// `if (ok) value else null`, written so the optional never comes from a
    /// pointer select against a `null` constant (which LLVM cannot scalarise,
    /// leaving narrow stores followed by a wide reload in hot loops).
    inline fn some_if(ok: bool, value_: f32) ?f32 {
        var result: ?f32 = value_;
        if (!ok) result = null;
        return result;
    }

    /// Resolve against a definite `basis`: lengths, percentages and (when
    /// `with_calc`) calc values resolve; any other tag yields `fallback`.
    pub inline fn resolve_or_with(self: CompactLength, basis: f32, fallback: f32, comptime with_calc: bool) f32 {
        if (with_calc) {
            if (self.tag() == .calc) return resolve_calc(self, basis);
        }
        return switch (self.tag()) {
            .length => self.value(),
            .percent => self.value() * basis,
            else => fallback,
        };
    }

    fn maybe_resolve_calc(self: CompactLength, basis: ?f32) ?f32 {
        @branchHint(.cold);
        const b = basis orelse return null;
        return @import("calc.zig").resolve(self.calc_value(), b);
    }

    fn resolve_calc(self: CompactLength, basis: f32) f32 {
        @branchHint(.cold);
        return @import("calc.zig").resolve(self.calc_value(), basis);
    }

    pub inline fn resolved_percentage_size(self: CompactLength, parent_size: f32) ?f32 {
        return switch (self.tag()) {
            .percent => self.value() * parent_size,
            .calc => @import("calc.zig").resolve(self.calc_value(), parent_size),
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
    calc = 0b0000_0100,
    fit_content_calc = 0b0000_0110,
    length = 0b0000_0001,
    percent = 0b0000_0101,
    auto = 0b0000_0011,
    fr = 0b0001_0011,
    content = 0b0010_0011,
    min_content = 0b0000_1011,
    max_content = 0b0001_1011,
    fit_content_px = 0b0010_1011,
    fit_content_keyword = 0b0011_1011,
    stretch = 0b0100_1011,
    fit_content_percent = 0b0000_1111,
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
    try testing.expectEqual(@as(u8, 59), @backingInt(CompactLength.fit_content().tag()));
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

    // calc payloads are pointers stored in the low 56 bits.
    const handle: *const anyopaque = @ptrFromInt(0x1234);
    const calc_value = CompactLength.calc(handle);
    try testing.expectEqual(CompactLengthTag.calc, calc_value.tag());
    try testing.expectEqual(handle, calc_value.calc_value().?);
    try testing.expect(calc_value.is_plain_calc() and calc_value.uses_percentage() and !calc_value.is_sizing_keyword());
    const fit_calc = CompactLength.fit_content_calc(handle);
    try testing.expect(fit_calc.is_fit_content_calc() and !fit_calc.is_plain_calc() and fit_calc.is_fit_content());
    try testing.expect(fit_calc.is_sizing_keyword() and fit_calc.is_intrinsic() and fit_calc.uses_percentage());
    try testing.expectEqual(handle, fit_calc.calc_value().?);

    // Wire values captured from Taffy c6421c1 (serde_json of each CompactLength).
    try testing.expectEqual(@as(u64, 5375000576), CompactLength.length(3.5).serialized());
    try testing.expectEqual(CompactLength.length(3.5), from_serialized(@as(u64, 5375000576)));
    try testing.expectEqual(@as(u64, 22531801088), CompactLength.percent(0.5).serialized());
    try testing.expectEqual(CompactLength.percent(0.5), from_serialized(@as(u64, 22531801088)));
    try testing.expectEqual(@as(u64, 12884901888), CompactLength.auto().serialized());
    try testing.expectEqual(CompactLength.auto(), from_serialized(@as(u64, 12884901888)));
    try testing.expectEqual(@as(u64, 82678120448), CompactLength.fr(2).serialized());
    try testing.expectEqual(CompactLength.fr(2), from_serialized(@as(u64, 82678120448)));
    try testing.expectEqual(@as(u64, 47244640256), CompactLength.min_content().serialized());
    try testing.expectEqual(CompactLength.min_content(), from_serialized(@as(u64, 47244640256)));
    try testing.expectEqual(@as(u64, 115964116992), CompactLength.max_content().serialized());
    try testing.expectEqual(CompactLength.max_content(), from_serialized(@as(u64, 115964116992)));
    try testing.expectEqual(@as(u64, 185786695680), CompactLength.fit_content_length(24).serialized());
    try testing.expectEqual(CompactLength.fit_content_length(24), from_serialized(@as(u64, 185786695680)));
    try testing.expectEqual(@as(u64, 65473085440), CompactLength.fit_content_percent(0.25).serialized());
    try testing.expectEqual(CompactLength.fit_content_percent(0.25), from_serialized(@as(u64, 65473085440)));
    try testing.expectEqual(@as(u64, 253403070464), CompactLength.fit_content().serialized());
    try testing.expectEqual(CompactLength.fit_content(), from_serialized(@as(u64, 253403070464)));
    try testing.expectEqual(@as(u64, 322122547200), CompactLength.stretch().serialized());
    try testing.expectEqual(CompactLength.stretch(), from_serialized(@as(u64, 322122547200)));
    try testing.expectEqual(@as(u64, 150323855360), CompactLength.content().serialized());
    try testing.expectEqual(CompactLength.content(), from_serialized(@as(u64, 150323855360)));
    try testing.expectEqual(CompactLength.percent(0.5), from_serialized(CompactLength.percent(0.5).serialized()));
}
