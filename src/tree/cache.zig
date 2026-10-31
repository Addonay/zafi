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
    parent_size: u64,
    known_dimensions_are_definite: geometry.Size(bool),

    pub fn eql(self: CacheKey, other: CacheKey) bool {
        return self.kd_available_space == other.kd_available_space and self.parent_size == other.parent_size and self.known_dimensions_are_definite.width == other.known_dimensions_are_definite.width and self.known_dimensions_are_definite.height == other.known_dimensions_are_definite.height;
    }

    pub fn parent_size_value(self: CacheKey) u64 {
        return self.parent_size & ~(@as(u64, 1) << 63 | @as(u64, 1) << 31);
    }
    pub fn x_axis_parent_size(self: CacheKey) u64 {
        return self.parent_size & ((@as(u64, 0xffff_ffff) << 32) & ~(@as(u64, 1) << 63 | @as(u64, 1) << 31));
    }
    pub fn requested_axis_bits(self: CacheKey) u64 {
        return self.parent_size & (@as(u64, 1) << 63 | @as(u64, 1) << 31);
    }
    pub fn size_is_valid_for(self: CacheKey, other: CacheKey) bool {
        const both = (@as(u64, 1) << 63) | (@as(u64, 1) << 31);
        const axis = self.requested_axis_bits();
        return axis == both or axis == other.requested_axis_bits();
    }
};

pub const CacheEntry = struct {
    key: CacheKey,
    output: layout.LayoutOutput,
};

/// Measurement entries store only the size, exactly like Taffy: cache hits are
/// reconstructed with `LayoutOutput.from_outer_size`, which resets margin and
/// overflow metadata.
pub const MeasureEntry = struct {
    key: CacheKey,
    size: geometry.Size(f32),
};

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
    const axis_bits: u64 = switch (input.axis) {
        .horizontal => @as(u64, 1) << 63,
        .vertical => @as(u64, 1) << 31,
        .both => (@as(u64, 1) << 63) | (@as(u64, 1) << 31),
    };
    return .{
        .kd_available_space = size_mixed_cache_key(input.known_dimensions, input.available_space),
        .parent_size = (size_option_cache_key(input.parent_size) & ~((@as(u64, 1) << 63) | (@as(u64, 1) << 31))) | axis_bits,
        .known_dimensions_are_definite = .{
            // Taffy normalizes to `is_definite || known_dimensions.is_none()`:
            // an absent known dimension counts as definite.
            .width = input.known_dimensions_are_definite.width or input.known_dimensions.width == null,
            .height = input.known_dimensions_are_definite.height or input.known_dimensions.height == null,
        },
    };
}

pub const Cache = struct {
    final_layout_entry: ?CacheEntry = null,
    measure_entries: [max_entries]?MeasureEntry = std.mem.zeroes([max_entries]?MeasureEntry),
    recently_used_entries: u16 = 0,
    next_measure_entry: u8 = 0,
    /// Taffy's `is_empty` flag: lets `clear` report `already_empty` without
    /// scanning the entries, which is what makes dirty propagation stop early
    /// instead of re-clearing every ancestor on every mutation.
    empty: bool = true,

    pub fn clear(self: *Cache) ClearState {
        if (self.empty) return .already_empty;
        self.clearUnchecked();
        return .cleared;
    }

    fn clearUnchecked(self: *Cache) void {
        self.empty = true;
        self.final_layout_entry = null;
        self.measure_entries = std.mem.zeroes([max_entries]?MeasureEntry);
        self.recently_used_entries = 0;
        self.next_measure_entry = 0;
    }

    pub fn clear_state(self: *Cache) ClearState {
        return self.clear();
    }

    pub fn is_empty(self: *const Cache) bool {
        return self.empty;
    }

    pub fn get(self: *Cache, input: layout.LayoutInput) ?layout.LayoutOutput {
        if (input.run_mode == .perform_hidden_layout) return null;
        const key = cache_key(input);
        switch (input.run_mode) {
            .perform_layout => if (self.final_layout_entry) |entry| {
                if (entry.key.eql(key)) return entry.output;
            },
            .compute_size => for (self.measure_entries, 0..) |entry, index| if (entry) |cached| {
                if (cached.key.kd_available_space == key.kd_available_space and
                    cached.key.known_dimensions_are_definite.width == key.known_dimensions_are_definite.width and
                    cached.key.known_dimensions_are_definite.height == key.known_dimensions_are_definite.height and
                    cached.key.x_axis_parent_size() == key.x_axis_parent_size() and
                    cached.key.size_is_valid_for(key))
                {
                    self.recently_used_entries |= @as(u16, 1) << @intCast(index);
                    return layout.LayoutOutput.from_outer_size(cached.size);
                }
            },
            .perform_hidden_layout => {},
        }
        return null;
    }

    pub fn store(self: *Cache, input: layout.LayoutInput, output: layout.LayoutOutput) void {
        if (input.run_mode == .perform_hidden_layout) return;
        const key = cache_key(input);
        switch (input.run_mode) {
            .perform_layout => {
                self.empty = false;
                self.final_layout_entry = .{ .key = key, .output = output };
            },
            .compute_size => {
                // Measure entries only store the size; results carrying
                // margin-collapse metadata cannot be reconstructed from it.
                if (output.margins_can_collapse_through or !margin_is_zero(output.top_margin) or !margin_is_zero(output.bottom_margin)) return;
                self.empty = false;
                const entry = MeasureEntry{ .key = key, .size = output.size };
                for (0..max_entries) |index| {
                    if (self.measure_entries[index]) |*existing| {
                        if (existing.key.eql(key)) {
                            existing.* = entry;
                            self.recently_used_entries |= @as(u16, 1) << @intCast(index);
                            return;
                        }
                    }
                }
                while ((self.recently_used_entries & (@as(u16, 1) << @intCast(self.next_measure_entry))) != 0) {
                    self.recently_used_entries &= ~(@as(u16, 1) << @intCast(self.next_measure_entry));
                    self.next_measure_entry = (self.next_measure_entry + 1) % @as(u8, max_entries);
                }
                self.measure_entries[self.next_measure_entry] = entry;
                self.recently_used_entries |= @as(u16, 1) << @intCast(self.next_measure_entry);
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
