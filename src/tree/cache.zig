//! Direct port of Taffy's `tree/cache.rs` cache storage.

const layout = @import("layout.zig");
const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;
const geometry = @import("../geometry.zig");
const std = @import("std");

/// Taffy keeps one final-layout entry and a small ring of measurement entries.
/// This first dynamic tree uses one ring, but the packed key below preserves
/// the important cache semantics: intrinsic constraints, parent width, and
/// requested-axis bits do not alias.
pub const max_entries: usize = 9;

pub const ClearState = enum { already_empty, cleared };

pub const CacheKey = struct {
    kd_available_space: u64,
    /// Both parent-size components as full f32 bits. Taffy borrows the f32
    /// sign bits here to encode the requested axis, which makes a negative
    /// parent size (possible when padding exceeds a known size) alias its
    /// positive counterpart; zafi keeps the axis separately.
    parent_size: u64,
    axis: AxisBits,
    known_dimensions_are_definite: geometry.Size(bool),

    pub fn eql(self: CacheKey, other: CacheKey) bool {
        return self.kd_available_space == other.kd_available_space and self.parent_size == other.parent_size and self.axis == other.axis and self.known_dimensions_are_definite.width == other.known_dimensions_are_definite.width and self.known_dimensions_are_definite.height == other.known_dimensions_are_definite.height;
    }

    /// Whether a size computed for `self`'s requested axis serves `other`'s.
    pub fn size_is_valid_for(self: CacheKey, other: CacheKey) bool {
        return axisServes(self.axis, other.axis);
    }
};

/// The requested axis of a cached computation: bit 0 horizontal, bit 1 vertical.
pub const AxisBits = u2;
const axis_both: AxisBits = 3;

inline fn axisServes(cached: AxisBits, requested: AxisBits) bool {
    return cached == axis_both or cached == requested;
}

/// Taffy's `CacheMode`: the layout inputs that affect a node's layout but are
/// not part of the `CacheKey` (sizing mode and vertical margin
/// collapsibility). A cache records the single mode all of its entries were
/// computed with; `get` misses for any other mode and `store` drops the
/// existing entries when the mode changes.
pub const CacheMode = packed struct(u8) {
    inherent_size: bool = false,
    collapsible_start_margin: bool = false,
    collapsible_end_margin: bool = false,
    _pad: u5 = 0,

    pub const initial: CacheMode = .{};

    pub inline fn from(input: layout.LayoutInput) CacheMode {
        return .{
            .inherent_size = input.sizing_mode == .inherent_size,
            .collapsible_start_margin = input.vertical_margins_are_collapsible.start,
            .collapsible_end_margin = input.vertical_margins_are_collapsible.end,
        };
    }

    pub inline fn eql(self: CacheMode, other: CacheMode) bool {
        return @as(u8, @bitCast(self)) == @as(u8, @bitCast(other));
    }
};

/// Debug-only count of stores into a non-empty cache under a different mode
/// (Taffy's `cache_mode_change_evictions`). A layout pass over a tree whose
/// caches started out empty must never evict.
pub threadlocal var mode_change_evictions: usize = 0;

fn margin_is_zero(value: layout.CollapsibleMarginSet) bool {
    return value.positive == 0 and value.negative == 0;
}

fn option_cache_key(input: ?f32) u32 {
    return if (input) |value| @bitCast(value) else @bitCast(std.math.inf(f32));
}

fn size_option_cache_key(input: geometry.Size(?f32)) u64 {
    return (@as(u64, option_cache_key(input.width)) << 32) | option_cache_key(input.height);
}

fn available_space_cache_key(input: AvailableSpace) u32 {
    return switch (input) {
        .definite => |value| @bitCast(-value),
        .min_content => @bitCast(-std.math.inf(f32)),
        .max_content => @bitCast(std.math.inf(f32)),
    };
}

fn size_available_space_cache_key(input: geometry.Size(AvailableSpace)) u64 {
    return (@as(u64, available_space_cache_key(input.width)) << 32) | available_space_cache_key(input.height);
}

fn mixed_cache_key(known_dimension: ?f32, available_space: AvailableSpace) u32 {
    return if (known_dimension) |value| @bitCast(value) else available_space_cache_key(available_space);
}

fn size_mixed_cache_key(known_dimensions: geometry.Size(?f32), available_space: geometry.Size(AvailableSpace)) u64 {
    return (@as(u64, mixed_cache_key(known_dimensions.width, available_space.width)) << 32) | mixed_cache_key(known_dimensions.height, available_space.height);
}

pub fn cache_key(input: layout.LayoutInput) CacheKey {
    return .{
        .kd_available_space = size_mixed_cache_key(input.known_dimensions, input.available_space),
        .parent_size = size_option_cache_key(input.parent_size),
        .axis = switch (input.axis) {
            .horizontal => 1,
            .vertical => 2,
            .both => axis_both,
        },
        .known_dimensions_are_definite = .{
            // Taffy normalizes to `is_definite || known_dimensions.is_none()`:
            // an absent known dimension counts as definite.
            .width = input.known_dimensions_are_definite.width or input.known_dimensions.width == null,
            .height = input.known_dimensions_are_definite.height or input.known_dimensions.height == null,
        },
    };
}

/// The key without the definiteness and axis flags, which live in
/// `Cache.flags` (4 bits per entry) so each key is 16 bytes.
const PackedKey = struct {
    kd_available_space: u64,
    parent_size: u64,

    inline fn from(key: CacheKey) PackedKey {
        return .{ .kd_available_space = key.kd_available_space, .parent_size = key.parent_size };
    }
    inline fn eql(self: PackedKey, other: PackedKey) bool {
        return self.kd_available_space == other.kd_available_space and self.parent_size == other.parent_size;
    }
};

/// Per-entry flags: bits 0-1 `known_dimensions_are_definite`, bits 2-3 axis.
inline fn entryFlags(key: CacheKey) u4 {
    return @as(u4, definiteBits(key)) | (@as(u4, key.axis) << 2);
}

inline fn definiteBits(key: CacheKey) u2 {
    return @as(u2, @intFromBool(key.known_dimensions_are_definite.width)) | (@as(u2, @intFromBool(key.known_dimensions_are_definite.height)) << 1);
}

/// A cached final layout: `LayoutOutput` without its out-of-flow candidate
/// list, which lives in the per-pass scratch arena and is never cached.
const CachedOutput = struct {
    size: geometry.Size(f32),
    scrollable_overflow_rect: layout.ScrollableOverflow,
    baselines: layout.Baselines,
    top_margin: layout.CollapsibleMarginSet,
    bottom_margin: layout.CollapsibleMarginSet,
    margins_can_collapse_through: bool,
    oof_positioning_area: ?layout.OofPositioningArea,

    inline fn from(output: layout.LayoutOutput) CachedOutput {
        return .{
            .size = output.size,
            .scrollable_overflow_rect = output.scrollable_overflow_rect,
            .baselines = output.baselines,
            .top_margin = output.top_margin,
            .bottom_margin = output.bottom_margin,
            .margins_can_collapse_through = output.margins_can_collapse_through,
            .oof_positioning_area = output.oof_positioning_area,
        };
    }
    inline fn expand(self: CachedOutput) layout.LayoutOutput {
        return .{
            .size = self.size,
            .scrollable_overflow_rect = self.scrollable_overflow_rect,
            .baselines = self.baselines,
            .top_margin = self.top_margin,
            .bottom_margin = self.bottom_margin,
            .margins_can_collapse_through = self.margins_can_collapse_through,
            .oof_positioning_area = self.oof_positioning_area,
        };
    }
};

/// Index of the final-layout entry in `valid`/`definite` (after the measure ring).
const final_slot = max_entries;

/// Taffy's layout cache: one final-layout entry plus a ring of measurement
/// entries (sizes only, rebuilt with `LayoutOutput.from_outer_size` on a hit).
///
/// Stored compactly (struct-of-arrays, 16-byte keys, a validity bitmask
/// instead of optionals): ~45% smaller than an array of optional entries,
/// which matters because every node carries one.
pub const Cache = struct {
    measure_keys: [max_entries]PackedKey = undefined,
    measure_sizes: [max_entries]geometry.Size(f32) = undefined,
    final_key: PackedKey = undefined,
    final_output: CachedOutput = undefined,
    /// Bit `i < max_entries`: measure entry `i` is valid; bit `final_slot`: the final entry is.
    valid: u16 = 0,
    /// Four flag bits per entry (same indexing as `valid`): see `entryFlags`.
    flags: u64 = 0,
    recently_used_entries: u16 = 0,
    next_measure_entry: u8 = 0,
    /// Taffy's `is_empty` flag: lets `clear` report `already_empty` without
    /// scanning, which is what makes dirty propagation stop early.
    empty: bool = true,
    /// The mode all entries were computed with (see `CacheMode`).
    mode: CacheMode = .initial,

    pub fn clear(self: *Cache) ClearState {
        if (self.empty) return .already_empty;
        self.clearUnchecked();
        return .cleared;
    }

    fn clearUnchecked(self: *Cache) void {
        self.empty = true;
        self.valid = 0;
        self.recently_used_entries = 0;
        self.next_measure_entry = 0;
    }

    pub fn clear_state(self: *Cache) ClearState {
        return self.clear();
    }

    pub fn is_empty(self: *const Cache) bool {
        return self.empty;
    }

    inline fn flagsAt(self: *const Cache, index: usize) u4 {
        return @truncate(self.flags >> @intCast(index * 4));
    }
    inline fn setFlags(self: *Cache, index: usize, bits: u4) void {
        const shift: u6 = @intCast(index * 4);
        self.flags = (self.flags & ~(@as(u64, 0xf) << shift)) | (@as(u64, bits) << shift);
    }
    inline fn isValid(self: *const Cache, index: usize) bool {
        return self.valid & (@as(u16, 1) << @intCast(index)) != 0;
    }

    pub fn get(self: *Cache, input: layout.LayoutInput) ?layout.LayoutOutput {
        if (input.run_mode == .perform_hidden_layout) return null;
        if (!self.mode.eql(CacheMode.from(input))) return null;
        const full = cache_key(input);
        const key = PackedKey.from(full);
        const flags = entryFlags(full);
        const definite = definiteBits(full);
        switch (input.run_mode) {
            .perform_layout => if (self.isValid(final_slot) and
                self.final_key.eql(key) and
                self.flagsAt(final_slot) == flags)
            {
                return self.final_output.expand();
            },
            .compute_size => for (0..max_entries) |index| {
                if (!self.isValid(index)) continue;
                const entry = self.flagsAt(index);
                // The full parent size must match (Taffy compares only its
                // width, which reuses sizes that depend on the parent's height).
                if (self.measure_keys[index].eql(key) and
                    @as(u2, @truncate(entry)) == definite and
                    axisServes(@truncate(entry >> 2), full.axis))
                {
                    self.recently_used_entries |= @as(u16, 1) << @intCast(index);
                    return layout.LayoutOutput.from_outer_size(self.measure_sizes[index]);
                }
            },
            .perform_hidden_layout => {},
        }
        return null;
    }

    pub fn store(self: *Cache, input: layout.LayoutInput, output: layout.LayoutOutput) void {
        if (input.run_mode == .perform_hidden_layout) return;
        const mode = CacheMode.from(input);
        if (!self.mode.eql(mode)) {
            if (std.debug.runtime_safety and !self.empty) mode_change_evictions += 1;
            _ = self.clear();
            self.mode = mode;
        }
        const full = cache_key(input);
        const key = PackedKey.from(full);
        const flags = entryFlags(full);
        switch (input.run_mode) {
            .perform_layout => {
                self.empty = false;
                self.final_key = key;
                self.final_output = CachedOutput.from(output);
                self.setFlags(final_slot, flags);
                self.valid |= @as(u16, 1) << final_slot;
            },
            .compute_size => {
                // Measure entries only store the size; results carrying
                // margin-collapse metadata cannot be reconstructed from it.
                if (output.margins_can_collapse_through or !margin_is_zero(output.top_margin) or !margin_is_zero(output.bottom_margin)) return;
                self.empty = false;
                for (0..max_entries) |index| {
                    if (self.isValid(index) and
                        self.measure_keys[index].eql(key) and
                        self.flagsAt(index) == flags)
                    {
                        self.measure_sizes[index] = output.size;
                        self.recently_used_entries |= @as(u16, 1) << @intCast(index);
                        return;
                    }
                }
                while ((self.recently_used_entries & (@as(u16, 1) << @intCast(self.next_measure_entry))) != 0) {
                    self.recently_used_entries &= ~(@as(u16, 1) << @intCast(self.next_measure_entry));
                    self.next_measure_entry = (self.next_measure_entry + 1) % @as(u8, max_entries);
                }
                const slot: usize = self.next_measure_entry;
                self.measure_keys[slot] = key;
                self.measure_sizes[slot] = output.size;
                self.setFlags(slot, flags);
                self.valid |= @as(u16, 1) << @intCast(slot);
                self.recently_used_entries |= @as(u16, 1) << @intCast(slot);
                self.next_measure_entry = (self.next_measure_entry + 1) % @as(u8, max_entries);
            },
            .perform_hidden_layout => {},
        }
    }
};

fn input_equal(a: layout.LayoutInput, b: layout.LayoutInput) bool {
    return a.run_mode == b.run_mode and a.sizing_mode == b.sizing_mode and a.axis == b.axis and
        a.known_dimensions.width == b.known_dimensions.width and a.known_dimensions.height == b.known_dimensions.height and
        a.known_dimensions_are_definite.width == b.known_dimensions_are_definite.width and
        a.known_dimensions_are_definite.height == b.known_dimensions_are_definite.height and
        a.parent_size.width == b.parent_size.width and a.parent_size.height == b.parent_size.height and
        available_equal(a.available_space.width, b.available_space.width) and
        available_equal(a.available_space.height, b.available_space.height);
}

fn available_equal(a: AvailableSpace, b: AvailableSpace) bool {
    return switch (a) {
        .definite => |value| switch (b) {
            .definite => |other| value == other,
            else => false,
        },
        .min_content => b == .min_content,
        .max_content => b == .max_content,
    };
}

test "cache keys distinguish intrinsic space and requested axes" {
    const testing = std.testing;
    const base = layout.LayoutInput{
        .run_mode = .compute_size,
        .sizing_mode = .inherent_size,
        .axis = .horizontal,
        .known_dimensions = .{ .width = null, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = 100, .height = 40 },
        .available_space = .{ .width = .max_content, .height = .min_content },
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
    var cache = Cache{};
    cache.store(base, layout.LayoutOutput.from_sizes(.{ .width = 11, .height = 12 }));
    try testing.expect(cache.get(base) != null);
    var vertical = base;
    vertical.axis = .vertical;
    try testing.expect(cache.get(vertical) == null);
    var definite = base;
    definite.available_space.width = .{ .definite = 100 };
    try testing.expect(cache.get(definite) == null);

    var final_input = base;
    final_input.run_mode = .perform_layout;
    cache.store(final_input, layout.LayoutOutput.from_outer_size(.{ .width = 21, .height = 22 }));
    try testing.expect(cache.get(final_input) != null);
    try testing.expect(cache.get(base) != null);

    var metadata = layout.LayoutOutput.from_outer_size(.{ .width = 1, .height = 1 });
    metadata.top_margin = layout.CollapsibleMarginSet.from_margin(3);
    cache.store(base, metadata);
    try testing.expectEqual(@as(f32, 11), cache.get(base).?.size.width);
}

test "negative and positive parent sizes do not share a cache entry" {
    const testing = std.testing;
    // Taffy encodes the requested axis in the parent size's f32 sign bits, so
    // a parent width of -50 and 50 produced the same key.
    var input = layout.LayoutInput{
        .run_mode = .compute_size,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = .{ .width = null, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = 50, .height = 40 },
        .available_space = .{ .width = .{ .definite = 50 }, .height = .max_content },
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
    var cache = Cache{};
    cache.store(input, layout.LayoutOutput.from_outer_size(.{ .width = 25, .height = 10 }));
    input.parent_size.width = -50;
    try testing.expect(cache.get(input) == null);
    input.run_mode = .perform_layout;
    input.parent_size.width = 50;
    cache.store(input, layout.LayoutOutput.from_outer_size(.{ .width = 25, .height = 10 }));
    input.parent_size.height = -40;
    try testing.expect(cache.get(input) == null);
    try testing.expect(@sizeOf(Cache) <= 336);
}
