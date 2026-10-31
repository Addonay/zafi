//! Direct port of Taffy's `compute/common/scrollable_overflow.rs`.

const geometry = @import("../../geometry.zig");
const style = @import("../../style/root.zig");
const layout = @import("../../tree/layout.zig");

/// Container geometry shared by its children's scrollable overflow contributions.
pub const ScrollableOverflowContainer = struct {
    /// Whether the parent clips unreachable overflow and includes end padding.
    parent_is_scroll_container: bool,
    /// The extent of the parent's padding-box frame, excluding scrollbar gutters.
    parent_size: geometry.Size(f32),
    /// The scroll origin in each physical axis (true = at the end edge).
    reversed: geometry.Point(bool),
    /// The parent's resolved padding.
    padding: geometry.Rect(f32),
};

/// The rectangle a node contributes to its parent's scrollable overflow.
///
/// `location`, the child's overflow and the result use physical axes in the
/// parent's padding-box frame. Child overflow is relative to its inner border
/// edge, so the child's `border` is added first. A scroll container clips its
/// descendants' overflow; visible overflow propagates. In a scroll-container
/// parent, end padding extends the in-flow child's margin edge (not its
/// propagated overflow); `margin` should carry only negative margins, and the
/// union with the border/overflow contribution keeps them from shrinking it.
pub fn compute_scrollable_overflow_contribution(
    location: geometry.Point(f32),
    size: geometry.Size(f32),
    child_overflow: geometry.Rect(f32),
    border: geometry.Rect(f32),
    overflow: geometry.Point(style.Overflow),
    contain: style.Contain,
    container: *const ScrollableOverflowContainer,
    margin: geometry.Rect(f32),
) geometry.Rect(f32) {
    const ZERO = geometry.Rect(f32){ .left = 0, .right = 0, .top = 0, .bottom = 0 };
    const scrollable_overflow_rect = geometry.Rect(f32){
        .left = child_overflow.left + border.left,
        .right = child_overflow.right + border.left,
        .top = child_overflow.top + border.top,
        .bottom = child_overflow.bottom + border.top,
    };
    const is_scroll_container = overflow.x.is_scroll_container() or overflow.y.is_scroll_container();
    const overflow_is_contained = contain.contains_scrollable_overflow();
    const propagates = geometry.Point(bool){
        .x = !is_scroll_container and !overflow_is_contained and overflow.x == .visible,
        .y = !is_scroll_container and !overflow_is_contained and overflow.y == .visible,
    };
    const end_extent = geometry.Size(f32){
        .width = if (propagates.x) @max(size.width, scrollable_overflow_rect.right) else size.width,
        .height = if (propagates.y) @max(size.height, scrollable_overflow_rect.bottom) else size.height,
    };
    if (end_extent.width <= 0 or end_extent.height <= 0) return ZERO;
    const start_extent = geometry.Point(f32){
        .x = if (propagates.x) @min(0, scrollable_overflow_rect.left) else 0,
        .y = if (propagates.y) @min(0, scrollable_overflow_rect.top) else 0,
    };
    const contribution = geometry.Rect(f32){
        .left = location.x + start_extent.x,
        .right = location.x + end_extent.width,
        .top = location.y + start_extent.y,
        .bottom = location.y + end_extent.height,
    };
    if (!container.parent_is_scroll_container) return contribution;

    const reversed = container.reversed;
    const is_wholly_unreachable =
        (if (reversed.x) contribution.left >= container.parent_size.width else contribution.right <= 0) or
        (if (reversed.y) contribution.top >= container.parent_size.height else contribution.bottom <= 0);
    if (is_wholly_unreachable) return ZERO;

    var padded = contribution;
    const padding = container.padding;
    if (reversed.x) {
        padded.left = @min(padded.left, location.x - @max(0, padding.left + margin.left));
    } else {
        padded.right = @max(padded.right, location.x + size.width + @max(0, padding.right + margin.right));
    }
    if (reversed.y) {
        padded.top = @min(padded.top, location.y - @max(0, padding.top + margin.top));
    } else {
        padded.bottom = @max(padded.bottom, location.y + size.height + @max(0, padding.bottom + margin.bottom));
    }
    return padded;
}

/// Pack an algorithm's physical accumulator at its output boundary, clipping
/// unreachable overflow only for scroll containers (non-scroll containers keep
/// everything and carry no reversal flags).
pub fn finalize_scrollable_overflow(rect_in: geometry.Rect(f32), size_in: geometry.Size(f32), reversed_in: geometry.Point(bool), is_scroll_container: bool) layout.ScrollableOverflow {
    var r = rect_in;
    const size = geometry.Size(f32){ .width = @max(size_in.width, 0), .height = @max(size_in.height, 0) };
    var reversed = geometry.Point(bool){ .x = false, .y = false };
    if (is_scroll_container) {
        reversed = reversed_in;
        if (reversed.x) r.right = @min(r.right, size.width) else r.left = 0;
        if (reversed.y) r.bottom = @min(r.bottom, size.height) else r.top = 0;
    }
    return layout.ScrollableOverflow.new(r, reversed);
}

test "scrollable overflow clips unreachable descendants" {
    const testing = @import("std").testing;
    const result = compute_scrollable_overflow_contribution(.{ .x = -20, .y = 0 }, .{ .width = 10, .height = 10 }, .{ .left = 0, .right = 10, .top = 0, .bottom = 10 }, .{ .left = 0, .right = 0, .top = 0, .bottom = 0 }, .{ .x = .visible, .y = .visible }, .{}, &.{ .parent_is_scroll_container = true, .parent_size = .{ .width = 100, .height = 100 }, .reversed = .{ .x = false, .y = false }, .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 } }, .{ .left = 0, .right = 0, .top = 0, .bottom = 0 });
    try testing.expectEqual(@as(f32, 0), result.left);
    try testing.expectEqual(@as(f32, 0), result.right);
}
