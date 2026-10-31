//! Direct port of Taffy's `tree/layout.rs` data contracts.

const std = @import("std");
const geometry = @import("../geometry.zig");
const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;
const alignment = @import("../style/alignment.zig");
const style = @import("../style/root.zig");
const node = @import("node.zig");

pub const RunMode = enum { perform_layout, compute_size, perform_hidden_layout };
pub const SizingMode = enum { content_size, inherent_size };
pub const RequestedAxis = enum { horizontal, vertical, both };

pub fn requested_axis_from_absolute(axis: geometry.AbsoluteAxis) RequestedAxis {
    return if (axis == .horizontal) .horizontal else .vertical;
}

pub fn requested_axis_into_absolute(axis: RequestedAxis) ?geometry.AbsoluteAxis {
    return switch (axis) {
        .horizontal => .horizontal,
        .vertical => .vertical,
        .both => null,
    };
}

pub const CollapsibleMarginSet = struct {
    positive: f32 = 0,
    negative: f32 = 0,

    pub const zero: CollapsibleMarginSet = .{};
    pub const ZERO: CollapsibleMarginSet = zero;

    pub fn from_margin(value: f32) CollapsibleMarginSet {
        return if (value >= 0) .{ .positive = value } else .{ .negative = value };
    }

    pub fn collapse_with_margin(self: CollapsibleMarginSet, value: f32) CollapsibleMarginSet {
        var result = self;
        if (value >= 0) result.positive = @max(result.positive, value) else result.negative = @min(result.negative, value);
        return result;
    }

    pub fn collapse_with_set(self: CollapsibleMarginSet, other: CollapsibleMarginSet) CollapsibleMarginSet {
        return .{ .positive = @max(self.positive, other.positive), .negative = @min(self.negative, other.negative) };
    }

    pub fn resolve(self: CollapsibleMarginSet) f32 {
        return self.positive + self.negative;
    }
};

pub const Baselines = struct {
    first: ?f32 = null,
    last: ?f32 = null,

    pub const none: Baselines = .{};
    pub const NONE: Baselines = none;

    pub fn from_first(first: ?f32) Baselines {
        return .{ .first = first };
    }
};

pub const LayoutInput = struct {
    run_mode: RunMode,
    sizing_mode: SizingMode,
    axis: RequestedAxis,
    known_dimensions: geometry.Size(?f32),
    known_dimensions_are_definite: geometry.Size(bool),
    parent_size: geometry.Size(?f32),
    available_space: geometry.Size(AvailableSpace),
    vertical_margins_are_collapsible: geometry.Line(bool),

    pub const HIDDEN: LayoutInput = .{
        .run_mode = .perform_hidden_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = .{ .width = null, .height = null },
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = .{ .width = null, .height = null },
        .available_space = .{ .width = .max_content, .height = .max_content },
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
};

/// The physical alignment of an out-of-flow box's margin box within its static-position
/// area (per-axis).
///
/// The static position of an out-of-flow box may depend on alignment properties
/// (`justify-content`/`align-self` in flexbox, `justify-self`/`align-self` in grid) which cannot
/// be fully resolved until the box's final size is known. To defer that resolution, the static
/// position is recorded as an *area* plus the physical alignment keyword to apply to the box's
/// margin box within that area.
pub const AxisStaticEdge = enum {
    /// Align the start (left/top) edge of the box's margin box to the start of the area.
    start,
    /// Center the box within the area.
    center,
    /// Align the end (right/bottom) edge of the box's margin box to the end of the area.
    end,
};

/// The alignment to apply to an out-of-flow box's margin box within its static-position area in
/// a single axis.
///
/// Keywords are physical: container-specific semantics (`justify-content`/`align-self`
/// resolution, flex-direction/wrap-reverse reversal, RTL flipping, `self-start`/`self-end`) are
/// resolved by the emitting layout algorithm.
pub const AxisStaticAlign = struct {
    /// The physical alignment keyword.
    keyword: AxisStaticEdge,
    /// The `safe` overflow-position keyword from CSS Box Alignment: when `Safe`, `fallback` is
    /// used instead if the box's margin box overflows the area.
    safety: alignment.AlignmentSafety,
    /// The physical keyword to fall back to when `safety` is `Safe` and the box's margin box
    /// overflows the area.
    fallback: AxisStaticEdge,

    /// Create an `AxisStaticAlign` from a keyword with no safe fallback.
    pub fn from_keyword(keyword: AxisStaticEdge) AxisStaticAlign {
        return .{ .keyword = keyword, .safety = .default, .fallback = keyword };
    }
};

/// The static position of an out-of-flow box in a single axis: the alignment container
/// (start/end coordinates) plus the alignment to apply to the box's margin box within it.
///
/// Area coordinates are initially relative to the border box of the node which produced the
/// candidate and are translated by each node's location as the candidate bubbles up the tree, so
/// they are always relative to the border box of the node currently holding the candidate.
///
/// Emitters which have no alignment area in an axis (e.g. block layout, where the static
/// position is a point) emit a degenerate area (`start == end`).
pub const AxisStaticPosition = struct {
    /// The alignment container in this axis.
    area: geometry.Line(f32),
    /// The alignment to apply to the box's margin box within `area`.
    alignment: AxisStaticAlign,

    /// Create an `AxisStaticPosition` with a degenerate (zero-extent) area at `anchor` and no
    /// safe fallback.
    pub fn from_edge(anchor: f32, edge: AxisStaticEdge) AxisStaticPosition {
        return .{ .area = .{ .start = anchor, .end = anchor }, .alignment = AxisStaticAlign.from_keyword(edge) };
    }

    /// A static position aligned within `area` by an already-resolved
    /// self-alignment (`auto` replaced by the container's `*-items` value,
    /// `self-start`/`self-end` resolved). `axis_is_rtl` flips `start`/`end` for
    /// the inline axis of an RTL static-position containing block.
    pub fn from_alignment(value: alignment.AlignItems, area: geometry.Line(f32), axis_is_rtl: bool) AxisStaticPosition {
        std.debug.assert(value.keyword != .self_start and value.keyword != .self_end);
        const edge_for = struct {
            // Normal and Stretch (and anything not end/center) fall back to start
            fn call(keyword: alignment.AlignItemsKeyword, is_rtl: bool) AxisStaticEdge {
                const start_position = !(keyword == .end or keyword == .flex_end) != is_rtl;
                return if (keyword == .center) .center else if (start_position) .start else .end;
            }
        }.call;
        const fallback: alignment.AlignItemsKeyword = if (value.safety == .safe) .start else value.keyword;
        return .{
            .area = area,
            .alignment = .{ .keyword = edge_for(value.keyword, axis_is_rtl), .safety = value.safety, .fallback = edge_for(fallback, axis_is_rtl) },
        };
    }
};

/// A record of an out-of-flow (`position: absolute` or `position: fixed`) box which has not yet
/// been laid out because its containing block is an ancestor of its parent.
///
/// Candidates are produced by the layout algorithm of the box's parent (which computes the static
/// position) and bubble up through `LayoutOutput` until they reach a node which acts as the box's
/// containing block, which lays the box out.
pub const OofCandidate = struct {
    /// The id of the out-of-flow node.
    node: node.NodeId,
    /// The `order` value that the node's layout should be assigned (its child index within its parent).
    order: u32,
    /// The position style of the node (`absolute` or `fixed`).
    position: style.Position,
    /// The static position of the box in each axis.
    static_position: geometry.Point(AxisStaticPosition),
};

/// A list of `OofCandidate`s.
///
/// The backing storage is allocated by the caller (normally from the tree's layout-pass scratch
/// arena) and is therefore valid only until the end of the current top-level layout pass. An
/// empty list performs no allocation. Values stored in a node's persistent layout cache always
/// have an empty candidate list, so no pass-scoped pointer can outlive its pass.
pub const OofCandidates = std.ArrayListUnmanaged(OofCandidate);

/// The area of a container against which the insets of its out-of-flow (absolute/fixed) boxes are
/// resolved: the container's border box minus its borders and scrollbar gutters.
///
/// Container layout algorithms record this on `LayoutOutput` (for `RunMode.perform_layout` runs)
/// so that the out-of-flow positioning pass (`compute_oof_layout`) can run after the algorithm has
/// finished. When the container is a grid, per-box grid areas are resolved within this area by the
/// positioning pass itself (from the container's detailed grid info).
pub const OofPositioningArea = struct {
    /// The size of the area.
    size: geometry.Size(f32),
    /// The offset of the area from the container's border box origin.
    offset: geometry.Point(f32),
};

pub const LayoutOutput = struct {
    size: geometry.Size(f32),
    scrollable_overflow_rect: ScrollableOverflow = .ZERO,
    baselines: Baselines = .none,
    top_margin: CollapsibleMarginSet = .zero,
    bottom_margin: CollapsibleMarginSet = .zero,
    margins_can_collapse_through: bool = false,
    /// Out-of-flow (absolute/fixed) descendants of this node for which this node is *not* the
    /// containing block. These bubble up the tree until they reach their containing block, which
    /// lays them out. Empty (allocation-free) when there are no such descendants (the common
    /// case).
    ///
    /// Candidates are only produced by `RunMode.perform_layout` passes. Container layout
    /// algorithms place the *full* document-ordered candidate list here (direct out-of-flow
    /// children plus candidates bubbled from in-flow children); the out-of-flow positioning pass
    /// then lays out those for which the node is the containing block and replaces this list with
    /// the unclaimed remainder.
    ///
    /// The backing storage is pass-scoped (layout scratch). A `LayoutOutput` that is stored in a
    /// node's persistent cache always has this list emptied first.
    oof_candidates: OofCandidates = .empty,
    /// The node's inset-resolution area for out-of-flow boxes. Set by container layout algorithms
    /// for `RunMode.perform_layout` runs; `null` for leaves and size-only runs (in which case the
    /// out-of-flow positioning pass is a no-op).
    oof_positioning_area: ?OofPositioningArea = null,

    pub fn from_outer_size(size: geometry.Size(f32)) LayoutOutput {
        return .{ .size = size };
    }

    pub const hidden: LayoutOutput = .{ .size = .{ .width = 0, .height = 0 } };
    pub const HIDDEN: LayoutOutput = hidden;

    pub const default: LayoutOutput = hidden;

    pub fn from_sizes_and_baselines(size: geometry.Size(f32), baselines: Baselines) LayoutOutput {
        return .{ .size = size, .baselines = baselines };
    }

    pub fn from_sizes(size: geometry.Size(f32)) LayoutOutput {
        return LayoutOutput.from_outer_size(size);
    }
};

pub const Layout = struct {
    order: u32 = 0,
    location: geometry.Point(f32) = .{ .x = 0, .y = 0 },
    size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    content_size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    scrollable_overflow_rect: ScrollableOverflow = .ZERO,
    scrollbar_size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    border: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    padding: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
    margin: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },

    pub fn with_order(order: u32) Layout {
        return .{ .order = order };
    }

    pub fn new() Layout {
        return .{};
    }

    pub fn content_box_width(self: Layout) f32 {
        return self.size.width - self.padding.left - self.padding.right - self.border.left - self.border.right;
    }

    pub fn content_box_height(self: Layout) f32 {
        return self.size.height - self.padding.top - self.padding.bottom - self.border.top - self.border.bottom;
    }

    pub fn content_box_size(self: Layout) geometry.Size(f32) {
        return .{ .width = self.content_box_width(), .height = self.content_box_height() };
    }

    pub fn content_box_x(self: Layout) f32 {
        return self.location.x + self.border.left + self.padding.left;
    }

    pub fn content_box_y(self: Layout) f32 {
        return self.location.y + self.border.top + self.padding.top;
    }

    /// The magnitude of the reachable horizontal scroll range. A reversed axis
    /// scrolls over `-scroll_width()..0`.
    pub fn scroll_width(self: Layout) f32 {
        if (self.scrollable_overflow_rect.is_reversed().x) return -self.scrollable_overflow_rect.left();
        return @max(0, self.scrollable_overflow_rect.right() + @min(self.scrollbar_size.width, self.size.width) - self.size.width + self.border.left + self.border.right);
    }

    /// The magnitude of the reachable vertical scroll range. A reversed axis
    /// scrolls over `-scroll_height()..0`.
    pub fn scroll_height(self: Layout) f32 {
        if (self.scrollable_overflow_rect.is_reversed().y) return -self.scrollable_overflow_rect.top();
        return @max(0, self.scrollable_overflow_rect.bottom() + @min(self.scrollbar_size.height, self.size.height) - self.size.height + self.border.top + self.border.bottom);
    }
};

/// Scrollable overflow plus the physical directions in which scrolling starts
/// at the end edge (Taffy's packed `ScrollableOverflow`).
///
/// The rectangle uses physical x/y coordinates relative to the client area's
/// top-left edge. To get border-box coordinates add `border.left`/`border.top`,
/// plus the horizontal scrollbar gutter in RTL (the vertical scrollbar is on the
/// left); RTL does not mirror these coordinates. A scroll container clips
/// unreachable overflow: on normal axes the start is zero, on reversed axes the
/// end is at most the client extent. Non-scroll containers keep all overflow
/// (for propagation and hit testing) and have no flags.
///
/// Rectangles contain the origin (left/top <= 0, right/bottom >= 0), and the
/// sign bits of the stored right/bottom encode reversal (even for zero
/// extents), so the struct stays 16 bytes. Use `rect()` before doing geometry.
pub const ScrollableOverflow = struct {
    packed_rect: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },

    pub const ZERO: ScrollableOverflow = .{};

    /// Pack an origin-containing rectangle and its scroll-origin directions.
    pub fn new(r: geometry.Rect(f32), reversed: geometry.Point(bool)) ScrollableOverflow {
        std.debug.assert(r.left <= 0 and r.top <= 0 and r.right >= 0 and r.bottom >= 0);
        return .{ .packed_rect = .{
            .left = r.left,
            .top = r.top,
            .right = std.math.copysign(r.right, @as(f32, if (reversed.x) -1 else 1)),
            .bottom = std.math.copysign(r.bottom, @as(f32, if (reversed.y) -1 else 1)),
        } };
    }

    /// The physical overflow rectangle with the packed signs restored.
    pub inline fn rect(self: ScrollableOverflow) geometry.Rect(f32) {
        return .{ .left = self.packed_rect.left, .right = @abs(self.packed_rect.right), .top = self.packed_rect.top, .bottom = @abs(self.packed_rect.bottom) };
    }
    pub inline fn left(self: ScrollableOverflow) f32 {
        return self.packed_rect.left;
    }
    pub inline fn right(self: ScrollableOverflow) f32 {
        return @abs(self.packed_rect.right);
    }
    pub inline fn top(self: ScrollableOverflow) f32 {
        return self.packed_rect.top;
    }
    pub inline fn bottom(self: ScrollableOverflow) f32 {
        return @abs(self.packed_rect.bottom);
    }
    /// Whether the physical x/y scroll origins are at the right/bottom edges.
    pub inline fn is_reversed(self: ScrollableOverflow) geometry.Point(bool) {
        return .{ .x = std.math.signbit(self.packed_rect.right), .y = std.math.signbit(self.packed_rect.bottom) };
    }
    /// Swap the physical axes, preserving origin directions and signed zeroes.
    pub fn transpose(self: ScrollableOverflow) ScrollableOverflow {
        return .{ .packed_rect = self.packed_rect.transpose() };
    }
    /// Bitwise equality (distinguishes signed zeroes, i.e. reversal flags).
    pub fn eql(self: ScrollableOverflow, other: ScrollableOverflow) bool {
        const a: [4]u32 = @bitCast([4]f32{ self.packed_rect.left, self.packed_rect.right, self.packed_rect.top, self.packed_rect.bottom });
        const b: [4]u32 = @bitCast([4]f32{ other.packed_rect.left, other.packed_rect.right, other.packed_rect.top, other.packed_rect.bottom });
        return std.mem.eql(u32, &a, &b);
    }
};

pub const DetailedLayoutInfo = union(enum) { none, grid: *const anyopaque };

test "collapsible margins follow positive plus most negative" {
    const testing = @import("std").testing;
    var margins = CollapsibleMarginSet.from_margin(10);
    margins = margins.collapse_with_margin(4);
    margins = margins.collapse_with_margin(-3);
    try testing.expectEqual(@as(f32, 7), margins.resolve());
}

test "layout contracts expose hidden input and scroll extents" {
    const testing = @import("std").testing;
    try testing.expectEqual(RunMode.perform_hidden_layout, LayoutInput.HIDDEN.run_mode);
    var layout = Layout{ .size = .{ .width = 100, .height = 80 }, .scrollable_overflow_rect = ScrollableOverflow.new(.{ .left = 0, .right = 140, .top = 0, .bottom = 100 }, .{ .x = false, .y = false }) };
    layout.scrollbar_size = .{ .width = 10, .height = 10 };
    try testing.expectEqual(@as(f32, 50), layout.scroll_width());
    try testing.expectEqual(@as(f32, 30), layout.scroll_height());
}
