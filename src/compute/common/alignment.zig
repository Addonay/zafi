//! Direct port of Taffy's `compute/common/alignment.rs`.

const alignment = @import("../../style/alignment.zig");

/// Resolve the safe/unsafe overflow-position fallback for self-level
/// alignment, matching Taffy's `resolve_self_alignment_safety`.
pub fn resolve_self_alignment_safety(self_alignment: alignment.AlignItems, overflows: bool) alignment.AlignItemsKeyword {
    if (self_alignment.safety == .safe and overflows) return .start;
    return self_alignment.keyword;
}

/// Resolve the distribution fallbacks from CSS Box Alignment §5.3. This is
/// intentionally separate from offset calculation because Flexbox and Grid
/// call it with different item/line counts.
pub fn apply_alignment_fallback(free_space: f32, item_count: usize, alignment_value: alignment.AlignContent) alignment.AlignContentKeyword {
    var keyword = alignment_value.keyword;
    var is_safe = alignment_value.safety == .safe;
    if (item_count <= 1 or free_space <= 0) switch (keyword) {
        // Stretch falls back to flex-start keeping its own safety, so overflowing
        // lines are not forced to `start` (Taffy 1009534).
        .stretch => keyword = .flex_start,
        .space_between => {
            keyword = .flex_start;
            is_safe = true;
        },
        .space_around, .space_evenly => {
            keyword = .center;
            is_safe = true;
        },
        else => {},
    };
    if (free_space <= 0 and is_safe) keyword = .start;
    return keyword;
}

/// Compute the offset before the first item or between subsequent items.
/// Grid callers pass a zero gap, matching the Rust implementation's note.
pub fn compute_alignment_offset(
    free_space: f32,
    item_count: usize,
    gap: f32,
    keyword: alignment.AlignContentKeyword,
    layout_is_reversed: bool,
    is_first: bool,
) f32 {
    if (is_first) return switch (keyword) {
        .start => 0,
        .flex_start => if (layout_is_reversed) free_space else 0,
        .end => free_space,
        .flex_end => if (layout_is_reversed) 0 else free_space,
        .center => free_space / 2,
        .normal, .stretch, .space_between => 0,
        .space_around => if (free_space >= 0) (free_space / @as(f32, @floatFromInt(item_count))) / 2 else free_space / 2,
        .space_evenly => if (free_space >= 0) free_space / @as(f32, @floatFromInt(item_count + 1)) else free_space / 2,
    };

    const positive_free = @max(0, free_space);
    return gap + switch (keyword) {
        .start, .flex_start, .end, .flex_end, .center, .normal, .stretch => 0,
        .space_between => positive_free / @as(f32, @floatFromInt(item_count - 1)),
        .space_around => positive_free / @as(f32, @floatFromInt(item_count)),
        .space_evenly => positive_free / @as(f32, @floatFromInt(item_count + 1)),
    };
}

pub fn fallback_position(value: ?alignment.AlignContent) alignment.AlignContentKeyword {
    return (value orelse alignment.AlignContent.start).keyword;
}

/// Resolve a self-relative alignment keyword (`self-start`/`self-end`) against the
/// item's own direction relative to the container's.
///
/// `axis_is_inline` selects the main (inline) axis, where a direction difference
/// flips the meaning; on the block axis the container's direction governs and the
/// item's own direction is irrelevant. Mirrors Taffy's
/// `AlignSelf::resolve_self_relative`.
pub fn resolve_self_relative(
    alignment_value: alignment.AlignItems,
    item_direction: @import("../../style/root.zig").Direction,
    container_direction: @import("../../style/root.zig").Direction,
    axis_is_inline: bool,
) alignment.AlignItems {
    const flip = axis_is_inline and item_direction != container_direction;
    const resolved: alignment.AlignItemsKeyword = switch (alignment_value.keyword) {
        .self_start => if (flip) alignment.AlignItemsKeyword.end else alignment.AlignItemsKeyword.start,
        .self_end => if (flip) alignment.AlignItemsKeyword.start else alignment.AlignItemsKeyword.end,
        else => alignment_value.keyword,
    };
    return .{ .keyword = resolved, .safety = alignment_value.safety };
}
