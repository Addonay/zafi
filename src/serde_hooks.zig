//! Taffy-compatible serde support using the `serde` Zig framework
//! (https://github.com/OrlovEvgeny/serde.zig, pinned in build.zig.zon).
//!
//! The wire format matches Taffy 0.14 with the `serde` feature enabled, which
//! was captured from the pinned Rust crate:
//!
//! * `CompactLength` (and the `LengthPercentage`, `LengthPercentageAuto`,
//!   `Dimension`, `MinTrackSizingFunction`, `MaxTrackSizingFunction` wrappers)
//!   serialize as the u64 wire bits `(tag << 32) | f32_bits`. Deserialization
//!   validates the tag set for each wrapper exactly as Rust does.
//! * Enums use PascalCase variant names (`"Flex"`, `"RowDense"`, ...).
//! * `AlignItems`/`AlignContent` serialize as a single string: the PascalCase
//!   keyword, prefixed with `Safe` when the safety flag is `safe`.
//! * `GridPlacement` uses external tagging (`"Auto"`, `{"Line":2}`,
//!   `{"NamedLine":["foo",-1]}`).
//! * `Contain` serializes as its u8 bit set.
//!
//! Every type above whose *in-memory* shape already matches the wire shape is
//! left to plain reflection plus `rename` / `rename_all`: the enums, `Style`
//! itself, and the externally-tagged `GridPlacement` / `RepetitionCount`
//! unions. Only the entries dispatched from `serialize`/`deserialize` below
//! need code, and each one mirrors a hand-written `impl Serialize` /
//! `impl Deserialize` in the Rust source rather than working around this
//! framework.

const std = @import("std");
const serde = @import("serde");

const compact_length = @import("style/compact_length.zig");
const dimension = @import("style/dimension.zig");
const alignment = @import("style/alignment.zig");
const grid = @import("style/grid.zig");
const style = @import("style/root.zig");

pub const pascal_options = .{ .rename_all = serde.NamingConvention.pascal_case };

// ---------------------------------------------------------------------------
// Entry points used as `zerdeSerialize` / `zerdeDeserialize` declarations
// ---------------------------------------------------------------------------

pub fn serialize(value: anytype, serializer: anytype) !void {
    // The framework may hand hooks a pointer to the field value.
    if (comptime @typeInfo(@TypeOf(value)) == .pointer and @typeInfo(@TypeOf(value)).pointer.size == .one) {
        return serialize(value.*, serializer);
    }
    const T = @TypeOf(value);
    if (comptime T == compact_length.CompactLength) return serializeCompactLength(value, serializer);
    if (comptime T == dimension.LengthPercentage) return serializeCompactLength(value.value, serializer);
    if (comptime T == dimension.LengthPercentageAuto) return serializeCompactLength(value.value, serializer);
    if (comptime T == dimension.Dimension) return serializeCompactLength(value.value, serializer);
    if (comptime T == grid.MinTrackSizingFunction) return serializeCompactLength(value.value, serializer);
    if (comptime T == grid.MaxTrackSizingFunction) return serializeCompactLength(value.value, serializer);
    if (comptime T == style.Contain) return serializer.serializeInt(@as(u8, @bitCast(value)));
    if (comptime T == alignment.AlignItems) return serializeAlignment(value, serializer);
    if (comptime T == alignment.AlignContent) return serializeAlignment(value, serializer);
    @compileError("serde_hooks has no serializer for " ++ @typeName(T));
}

pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, deserializer: anytype) @TypeOf(deserializer.*).Error!T {
    if (comptime T == compact_length.CompactLength) return deserializeCompactLength(deserializer);
    if (comptime T == dimension.LengthPercentage) {
        const inner = try deserializeCompactLength(deserializer);
        if (!isLengthPercentageTag(inner.tag())) return deserializer.raiseError(error.InvalidTag);
        return .{ .value = inner };
    }
    if (comptime T == dimension.LengthPercentageAuto) {
        const inner = try deserializeCompactLength(deserializer);
        if (!isLengthPercentageAutoTag(inner.tag())) return deserializer.raiseError(error.InvalidTag);
        return .{ .value = inner };
    }
    if (comptime T == dimension.Dimension) {
        const inner = try deserializeCompactLength(deserializer);
        if (!isDimensionTag(inner.tag())) return deserializer.raiseError(error.InvalidTag);
        return .{ .value = inner };
    }
    if (comptime T == grid.MinTrackSizingFunction) {
        const inner = try deserializeCompactLength(deserializer);
        if (!isMinTrackTag(inner.tag())) return deserializer.raiseError(error.InvalidTag);
        return .{ .value = inner };
    }
    if (comptime T == grid.MaxTrackSizingFunction) {
        const inner = try deserializeCompactLength(deserializer);
        if (!isMaxTrackTag(inner.tag())) return deserializer.raiseError(error.InvalidTag);
        return .{ .value = inner };
    }
    if (comptime T == style.Contain) {
        const bits = try deserializer.deserializeInt(u8);
        return @bitCast(bits);
    }
    if (comptime T == alignment.AlignItems) return deserializeAlignment(T, allocator, deserializer);
    if (comptime T == alignment.AlignContent) return deserializeAlignment(T, allocator, deserializer);
    @compileError("serde_hooks has no deserializer for " ++ @typeName(T));
}

// ---------------------------------------------------------------------------
// CompactLength
// ---------------------------------------------------------------------------

fn serializeCompactLength(value: compact_length.CompactLength, serializer: anytype) !void {
    // Note: Rust's serde refuses to serialize calc values. The serde.zig JSON
    // serializer has a fixed two-error set (`OutOfMemory`, `WriteFailed`), so
    // a custom error cannot be propagated here; calc instead serializes as its
    // raw bits (`0`), which deserialization rejects as an invalid tag. This is
    // the one known serde wire divergence and is documented in docs/report.md on the dev branch.
    if (value.is_calc()) {
        try serializer.serializeInt(@as(u64, 0));
        return;
    }
    try serializer.serializeInt(value.serialized());
}

fn deserializeCompactLength(deserializer: anytype) !compact_length.CompactLength {
    const bits = try deserializer.deserializeInt(u64);
    const tag: u8 = @intCast(bits >> 32);
    if (!isBaseCompactTag(tag)) return deserializer.raiseError(error.InvalidTag);
    return compact_length.from_serialized(bits);
}

/// Tags Rust accepts when deserializing a bare `CompactLength`
/// (everything except the calc tag and unknown bit patterns).
fn isBaseCompactTag(tag: u8) bool {
    return tag == @backingInt(compact_length.CompactLengthTag.length) or
        tag == @backingInt(compact_length.CompactLengthTag.percent) or
        tag == @backingInt(compact_length.CompactLengthTag.auto) or
        tag == @backingInt(compact_length.CompactLengthTag.min_content) or
        tag == @backingInt(compact_length.CompactLengthTag.max_content) or
        tag == @backingInt(compact_length.CompactLengthTag.fit_content_keyword) or
        tag == @backingInt(compact_length.CompactLengthTag.fit_content_px) or
        tag == @backingInt(compact_length.CompactLengthTag.fit_content_percent) or
        tag == @backingInt(compact_length.CompactLengthTag.stretch) or
        tag == @backingInt(compact_length.CompactLengthTag.content) or
        tag == @backingInt(compact_length.CompactLengthTag.fr);
}

fn isLengthPercentageTag(tag: compact_length.CompactLengthTag) bool {
    return tag == .length or tag == .percent;
}

fn isLengthPercentageAutoTag(tag: compact_length.CompactLengthTag) bool {
    return tag == .length or tag == .percent or tag == .auto;
}

/// Rust's `Dimension` deserializer accepts these tags (notably excluding fr).
fn isDimensionTag(tag: compact_length.CompactLengthTag) bool {
    return switch (tag) {
        .length, .percent, .auto, .min_content, .max_content, .fit_content_keyword, .fit_content_px, .fit_content_percent, .stretch, .content => true,
        else => false,
    };
}

fn isMinTrackTag(tag: compact_length.CompactLengthTag) bool {
    return switch (tag) {
        .length, .percent, .auto, .min_content, .max_content, .fit_content_px, .fit_content_percent => true,
        else => false,
    };
}

fn isMaxTrackTag(tag: compact_length.CompactLengthTag) bool {
    return switch (tag) {
        .length, .percent, .auto, .min_content, .max_content, .fit_content_px, .fit_content_percent, .fr => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// AlignItems / AlignContent
// ---------------------------------------------------------------------------

fn serializeAlignment(value: anytype, serializer: anytype) !void {
    var buffer: [32]u8 = undefined;
    const name = alignmentWireName(@TypeOf(value), value.keyword, value.safety, &buffer);
    try serializer.serializeString(name);
}

fn alignmentWireName(comptime T: type, keyword: anytype, safety: alignment.AlignmentSafety, buffer: []u8) []const u8 {
    const base = if (comptime T == alignment.AlignItems)
        alignItemsKeywordName(keyword)
    else if (comptime T == alignment.AlignContent)
        alignContentKeywordName(keyword)
    else
        @compileError("alignmentWireName: unsupported type " ++ @typeName(T));
    if (safety == .safe) return std.fmt.bufPrint(buffer, "Safe{s}", .{base}) catch unreachable;
    return base;
}

fn alignItemsKeywordName(keyword: alignment.AlignItemsKeyword) []const u8 {
    return switch (keyword) {
        .start => "Start",
        .end => "End",
        .flex_start => "FlexStart",
        .flex_end => "FlexEnd",
        .self_start => "SelfStart",
        .self_end => "SelfEnd",
        .center => "Center",
        .baseline => "Baseline",
        .stretch => "Stretch",
    };
}

fn alignContentKeywordName(keyword: alignment.AlignContentKeyword) []const u8 {
    return switch (keyword) {
        .start => "Start",
        .end => "End",
        .flex_start => "FlexStart",
        .flex_end => "FlexEnd",
        .center => "Center",
        .stretch => "Stretch",
        .space_between => "SpaceBetween",
        .space_evenly => "SpaceEvenly",
        .space_around => "SpaceAround",
    };
}

fn deserializeAlignment(comptime T: type, allocator: std.mem.Allocator, deserializer: anytype) @TypeOf(deserializer.*).Error!T {
    const text = try deserializer.deserializeString(allocator);
    defer serde.core.releaseString(deserializer, allocator, text);

    var safety: alignment.AlignmentSafety = .unsafe;
    var body = text;
    if (std.mem.startsWith(u8, body, "Safe")) {
        safety = .safe;
        body = body["Safe".len..];
        if (body.len == 0) return deserializer.raiseError(error.InvalidAlignment);
    }
    if (comptime T == alignment.AlignItems) {
        return .{ .keyword = parseAlignItemsKeyword(body) orelse return deserializer.raiseError(error.InvalidAlignment), .safety = safety };
    } else if (comptime T == alignment.AlignContent) {
        return .{ .keyword = parseAlignContentKeyword(body) orelse return deserializer.raiseError(error.InvalidAlignment), .safety = safety };
    }
    @compileError("deserializeAlignment: unsupported type " ++ @typeName(T));
}

fn parseAlignItemsKeyword(name: []const u8) ?alignment.AlignItemsKeyword {
    inline for (.{
        .{ "Start", alignment.AlignItemsKeyword.start },
        .{ "End", alignment.AlignItemsKeyword.end },
        .{ "FlexStart", alignment.AlignItemsKeyword.flex_start },
        .{ "FlexEnd", alignment.AlignItemsKeyword.flex_end },
        .{ "SelfStart", alignment.AlignItemsKeyword.self_start },
        .{ "SelfEnd", alignment.AlignItemsKeyword.self_end },
        .{ "Center", alignment.AlignItemsKeyword.center },
        .{ "Baseline", alignment.AlignItemsKeyword.baseline },
        .{ "Stretch", alignment.AlignItemsKeyword.stretch },
    }) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn parseAlignContentKeyword(name: []const u8) ?alignment.AlignContentKeyword {
    inline for (.{
        .{ "Start", alignment.AlignContentKeyword.start },
        .{ "End", alignment.AlignContentKeyword.end },
        .{ "FlexStart", alignment.AlignContentKeyword.flex_start },
        .{ "FlexEnd", alignment.AlignContentKeyword.flex_end },
        .{ "Center", alignment.AlignContentKeyword.center },
        .{ "Stretch", alignment.AlignContentKeyword.stretch },
        .{ "SpaceBetween", alignment.AlignContentKeyword.space_between },
        .{ "SpaceEvenly", alignment.AlignContentKeyword.space_evenly },
        .{ "SpaceAround", alignment.AlignContentKeyword.space_around },
    }) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Named grid lines
//
// Upstream models these as *tuple variants* of `GridPlacement`/`RepetitionCount`
// (`NamedLine(S, i16)`), which Rust's derive renders as a two-element array.
// serde.zig renders a struct as an object, so these two payload types keep a
// hook. Everything else about the unions is handled by reflection: the union
// serializer dispatches each payload through the same
// custom-serializer-first path, so these hooks compose with serde.zig's native
// external tagging.
// ---------------------------------------------------------------------------

pub fn serializeNamedLine(value: grid.NamedLine, serializer: anytype) !void {
    var array = try serializer.beginArray();
    try array.serializeString(value.name);
    try array.serializeInt(value.index);
    try array.end();
}

pub fn serializeNamedSpan(value: grid.NamedSpan, serializer: anytype) !void {
    var array = try serializer.beginArray();
    try array.serializeString(value.name);
    try array.serializeInt(value.count);
    try array.end();
}

fn deserializeNamedPair(comptime T: type, comptime Second: type, allocator: std.mem.Allocator, deserializer: anytype) !T {
    var sequence = try deserializer.deserializeSeqAccess();
    const name = (try sequence.nextElement([]const u8, allocator)) orelse return deserializer.raiseError(error.InvalidLength);
    const second = (try sequence.nextElement(Second, allocator)) orelse return deserializer.raiseError(error.InvalidLength);
    // Consume the closing bracket; reject any extra elements.
    if (try sequence.nextElement(serde.core.Value, allocator) != null) return deserializer.raiseError(error.UnexpectedToken);
    return switch (comptime T) {
        grid.NamedLine => .{ .name = name, .index = second },
        grid.NamedSpan => .{ .name = name, .count = second },
        else => @compileError("deserializeNamedPair: unsupported type " ++ @typeName(T)),
    };
}

// The framework passes the target type as the first argument, so these take
// `comptime T` even though each one only ever serves one type.
pub fn deserializeNamedLine(comptime T: type, allocator: std.mem.Allocator, deserializer: anytype) !T {
    return deserializeNamedPair(T, i16, allocator, deserializer);
}

pub fn deserializeNamedSpan(comptime T: type, allocator: std.mem.Allocator, deserializer: anytype) !T {
    return deserializeNamedPair(T, u16, allocator, deserializer);
}
