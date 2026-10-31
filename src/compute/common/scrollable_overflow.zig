//! Direct port of Taffy's `compute/common/scrollable_overflow.rs`.

const geometry = @import("../../geometry.zig");
const style = @import("../../style/root.zig");

/// Determine the rectangle a node contributes to its parent's scrollable
/// overflow. `location` is measured from the parent's scroll origin. A
/// scroll container clips descendant overflow, while visible overflow
/// propagates the child's computed overflow rectangle.
pub fn compute_scrollable_overflow_contribution(
    location: geometry.Point(f32),
    size: geometry.Size(f32),
    scrollable_overflow_rect: geometry.Rect(f32),
    overflow: geometry.Point(style.Overflow),
    contain: style.Contain,
    parent_is_scroll_container: bool,
) geometry.Rect(f32) {
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
    if (end_extent.width <= 0 or end_extent.height <= 0) return .{ .left = 0, .right = 0, .top = 0, .bottom = 0 };
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
    if (parent_is_scroll_container and (contribution.right <= 0 or contribution.bottom <= 0)) {
        return .{ .left = 0, .right = 0, .top = 0, .bottom = 0 };
    }
    return contribution;
}

test "scrollable overflow clips unreachable descendants" {
    const testing = @import("std").testing;
    const result = compute_scrollable_overflow_contribution(.{ .x = -20, .y = 0 }, .{ .width = 10, .height = 10 }, .{ .left = 0, .right = 10, .top = 0, .bottom = 10 }, .{ .x = .visible, .y = .visible }, .{}, true);
    try testing.expectEqual(@as(f32, 0), result.left);
    try testing.expectEqual(@as(f32, 0), result.right);
}
