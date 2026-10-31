//! Shared positioning pass for out-of-flow (`position: absolute` /
//! `position: fixed`) boxes.
//!
//! Layout algorithms do not lay out their out-of-flow children directly (unless
//! they are the child's containing block). Instead they emit
//! [`OofCandidate`] records which bubble up the tree via `LayoutOutput`
//! until they reach the box's containing block, which lays the box out using
//! the routine in this module.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style/root.zig");
const alignment = @import("../style/alignment.zig");
const dimension = @import("../style/dimension.zig");
const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;
const NodeId = @import("../tree/node.zig").NodeId;
const layout = @import("../tree/layout.zig");
const math = @import("../util/math.zig");
const sizing_keyword = @import("common/sizing_keyword.zig");
const scrollable_overflow = @import("common/scrollable_overflow.zig");
const alignment_common = @import("common/alignment.zig");
const LayoutTree = @import("../tree/interfaces.zig").LayoutTree;

const Size = geometry.Size;
const Point = geometry.Point;
const Rect = geometry.Rect;

pub const OofError = error{ InvalidParentNode, InvalidChildNode, InvalidInputNode, OutOfMemory, Cycle, DuplicateChild, NodeIdExhausted, ChildIndexOutOfBounds };

/// Resolve the final static offset of an out-of-flow box from its static
/// position, given the box's final size and resolved margins.
///
/// In each axis the box's margin box is aligned within the static-position area
/// according to the recorded alignment keyword. When the alignment is `safe` and
/// the margin box overflows the area, the fallback keyword is used instead (the
/// `safe` overflow-position keyword from CSS Box Alignment). The returned offset
/// locates the box's border box and is relative to whatever the static-position
/// areas are relative to (the containing block's border box once a candidate has
/// bubbled to its containing block).
pub fn resolve_static_offset(
    static_position: Point(layout.AxisStaticPosition),
    final_size: Size(f32),
    resolved_margin: Rect(f32)) Point(f32) {
    return .{
        .x = resolve_static_offset_axis(static_position.x, final_size.width, .{ .start = resolved_margin.left, .end = resolved_margin.right }),
        .y = resolve_static_offset_axis(static_position.y, final_size.height, .{ .start = resolved_margin.top, .end = resolved_margin.bottom }),
    };
}

/// Single-axis version of `resolve_static_offset`.
fn resolve_static_offset_axis(sp: layout.AxisStaticPosition, size: f32, margin: geometry.Line(f32)) f32 {
    const margin_box_size = size + margin.start + margin.end;
    const overflows = sp.alignment.safety == .safe and margin_box_size > sp.area.end - sp.area.start;
    const keyword = if (overflows) sp.alignment.fallback else sp.alignment.keyword;
    return align_in_line(sp.area, margin_box_size, keyword) + margin.start;
}

/// Position a box of `size` within `container`, aligned to the given physical edge.
inline fn align_in_line(container: geometry.Line(f32), size: f32, edge: layout.AxisStaticEdge) f32 {
    return switch (edge) {
        .start => container.start,
        .end => container.end - size,
        .center => (container.start + container.end - size) / 2.0,
    };
}

/// The self-alignment of an out-of-flow box in one axis, relative to the
/// writing mode of its containing block (`start` is the logical start edge).
const OofAlignment = enum {
    /// `normal`: stretch-fit sizing for non-replaced, non-table boxes; start alignment
    normal,
    /// `stretch`: stretch-fit sizing; start alignment
    stretch,
    start,
    center,
    end,

    /// From an `align-self`/`justify-self` value whose `auto`, `self-start` and
    /// `self-end` have already been resolved.
    fn from_resolved(value: alignment.AlignSelf) OofAlignment {
        std.debug.assert(value.keyword != .self_start and value.keyword != .self_end);
        return switch (value.keyword) {
            .normal => .normal,
            .stretch => .stretch,
            .center => .center,
            .end, .flex_end, .self_end => .end,
            // The fallback alignment of `baseline` is `start`
            .start, .flex_start, .self_start, .baseline => .start,
        };
    }

    /// The physical edge the margin box aligns to once its size is known.
    /// `normal` and `stretch` behave as `start`.
    fn physical_edge(self: OofAlignment, reversed: bool) layout.AxisStaticEdge {
        return switch (self) {
            .center => .center,
            .end => if (reversed) .start else .end,
            .normal, .stretch, .start => if (reversed) .end else .start,
        };
    }
};

/// The inputs to the absolute positioning layout model
/// (https://www.w3.org/TR/css-position-3/#abspos-layout) in one axis. All
/// coordinates are physical and relative to the start of the containing
/// block's inset-resolution area.
const OofAxis = struct {
    /// The size of the containing block in this axis
    cb_size: f32,
    /// Resolved insets (`null` = `auto`)
    inset: geometry.Line(?f32),
    /// Resolved margins (`null` = `auto`)
    margin: geometry.Line(?f32),
    /// Static position relative to the inset-resolution area
    static_position: layout.AxisStaticPosition,
    alignment: OofAlignment,
    safety: alignment.AlignmentSafety,
    /// Whether this is the containing block's inline axis
    is_inline: bool,
    /// Whether the logical start edge is the physical end edge (RTL inline axis)
    reversed: bool,
    /// Whether the containing block is a scroll container scrolling in this axis
    is_scroll_axis: bool,

    fn start_edge(self: *const OofAxis) layout.AxisStaticEdge {
        return if (self.reversed) .end else .start;
    }
    fn end_edge(self: *const OofAxis) layout.AxisStaticEdge {
        return if (self.reversed) .start else .end;
    }

    /// The inset-modified containing block (IMCB) in this axis
    /// https://www.w3.org/TR/css-position-3/#resolving-insets
    fn inset_modified_containing_block(self: *const OofAxis) geometry.Line(f32) {
        var imcb: geometry.Line(f32) = undefined;
        var weaker_edge: layout.AxisStaticEdge = undefined;
        if (self.inset.start) |start| {
            if (self.inset.end) |end| {
                imcb = .{ .start = start, .end = self.cb_size - end };
                weaker_edge = self.end_edge();
            } else {
                // A lone auto inset resolves to zero and is the weaker inset
                imcb = .{ .start = start, .end = self.cb_size };
                weaker_edge = .end;
            }
        } else if (self.inset.end) |end| {
            imcb = .{ .start = 0, .end = self.cb_size - end };
            weaker_edge = .start;
        } else {
            // Both insets auto: derive them from the static-position rectangle and
            // the alignment within it
            const sp = self.static_position;
            imcb = switch (sp.alignment.keyword) {
                .start => .{ .start = sp.area.start, .end = self.cb_size },
                .end => .{ .start = 0, .end = sp.area.end },
                .center => blk: {
                    // Center on the static-position rectangle, bounded by the nearer
                    // containing-block edge
                    const center = (sp.area.start + sp.area.end) / 2.0;
                    const start_distance = center;
                    const end_distance = self.cb_size - center;
                    break :blk if (@abs(start_distance) <= @abs(end_distance))
                        .{ .start = 0, .end = 2.0 * start_distance }
                    else
                        .{ .start = self.cb_size - 2.0 * end_distance, .end = self.cb_size };
                },
            };
            weaker_edge = self.end_edge();
        }
        // Overconstrained: reduce the weaker inset to bring the IMCB size up to zero
        if (imcb.end < imcb.start) {
            if (weaker_edge == .start) imcb.start = imcb.end else imcb.end = imcb.start;
        }
        return imcb;
    }

    fn inset_modified_containing_block_size(self: *const OofAxis) f32 {
        const imcb = self.inset_modified_containing_block();
        return imcb.end - imcb.start;
    }

    /// The stretch-fit border-box size: the IMCB minus non-auto margins
    /// https://www.w3.org/TR/css-position-3/#abspos-auto-size
    fn stretch_fit_size(self: *const OofAxis) f32 {
        const non_auto_margin_sum = (self.margin.start orelse 0) + (self.margin.end orelse 0);
        return @max(self.inset_modified_containing_block_size() - non_auto_margin_sum, 0);
    }

    /// Whether an `auto` size in this axis is the stretch-fit size (rather than fit-content)
    fn is_stretch_sized(self: *const OofAxis, is_replaced: bool, is_table: bool) bool {
        const no_auto_inset = self.inset.start != null and self.inset.end != null;
        return no_auto_inset and switch (self.alignment) {
            .stretch => true,
            .normal => !is_replaced and !is_table,
            else => false,
        };
    }

    /// Resolve auto margins given the final size
    /// https://www.w3.org/TR/css-position-3/#abspos-margins
    fn resolve_margins(self: *const OofAxis, size: f32) geometry.Line(f32) {
        const both_insets = self.inset.start != null and self.inset.end != null;
        const imcb = self.inset_modified_containing_block();
        const free_space = imcb.end - imcb.start - size;
        if (self.margin.start != null and self.margin.end != null) return .{ .start = self.margin.start.?, .end = self.margin.end.? };
        // If either inset is auto then auto margins resolve to zero
        if (!both_insets) return .{ .start = self.margin.start orelse 0, .end = self.margin.end orelse 0 };
        if (self.margin.start) |start| return .{ .start = start, .end = free_space - start };
        if (self.margin.end) |end| return .{ .start = free_space - end, .end = end };
        // In the inline axis, negative free space is absorbed entirely by the end margin
        if (free_space < 0 and self.is_inline) {
            return if (self.reversed) .{ .start = free_space, .end = 0 } else .{ .start = 0, .end = free_space };
        }
        return .{ .start = free_space / 2.0, .end = free_space / 2.0 };
    }

    /// The physical start of the border box given its final size and margins
    /// https://www.w3.org/TR/css-position-3/#abspos-alignment
    fn position(self: *const OofAxis, size: f32, margin: geometry.Line(f32)) f32 {
        const imcb = self.inset_modified_containing_block();
        if (self.inset.start == null and self.inset.end == null) {
            // Static alignment, with `safe` overflow judged against the IMCB (Taffy 5f6ec1d)
            const sp = self.static_position;
            const margin_box_size = size + margin.start + margin.end;
            const offset = if (sp.alignment.safety == .safe and margin_box_size > imcb.end - imcb.start)
                align_in_line(imcb, margin_box_size, self.start_edge())
            else
                align_in_line(sp.area, margin_box_size, sp.alignment.keyword);
            return offset + margin.start;
        }
        // One auto inset: the margin box aligns to the stronger inset's edge
        if (self.inset.end == null) return imcb.start + margin.start;
        if (self.inset.start == null) return imcb.end - size - margin.end;

        // Auto margins have already absorbed all of the free space
        if (self.margin.start == null or self.margin.end == null) return imcb.start + margin.start;

        const margin_box_size = size + margin.start + margin.end;
        const imcb_size = imcb.end - imcb.start;
        const edge = self.alignment.physical_edge(self.reversed);
        const margin_box_start: f32 = switch (self.safety) {
            .unsafe => align_in_line(imcb, margin_box_size, edge),
            .safe => align_in_line(imcb, margin_box_size, if (margin_box_size > imcb_size) self.start_edge() else edge),
            // Default overflow alignment for absolutely positioned boxes:
            // https://www.w3.org/TR/css-align-3/#auto-safety-position
            .default => blk: {
                if (margin_box_size <= imcb_size or self.alignment == .normal) {
                    // 1. Fits within the IMCB: align as specified
                    break :blk align_in_line(imcb, margin_box_size, edge);
                }
                // The overflow limit rect: the bounding rect of the IMCB and the
                // containing block, extended to infinity in a scroll container's
                // scrollable direction
                var limit = geometry.Line(f32){ .start = @min(imcb.start, 0), .end = @max(imcb.end, self.cb_size) };
                if (self.is_scroll_axis) {
                    if (self.reversed) limit.start = -std.math.inf(f32) else limit.end = std.math.inf(f32);
                }
                if (margin_box_size <= limit.end - limit.start) {
                    // 2. Fits within the limit: cover the IMCB, aligned as specified as
                    // far as possible without overflowing the limit
                    const aligned = align_in_line(imcb, margin_box_size, edge);
                    break :blk @max(@min(aligned, limit.end - margin_box_size), limit.start);
                }
                // 3. Start-align within the limit
                break :blk align_in_line(limit, margin_box_size, self.start_edge());
            },
        };
        return margin_box_start + margin.start;
    }
};

/// Run the out-of-flow positioning pass for `node_id` after its layout
/// algorithm has produced `output`: lay out the out-of-flow candidates in
/// `output.oof_candidates` for which the node is the containing block, record
/// them as the node's hoisted children, and replace `output.oof_candidates` with
/// the unclaimed remainder (which bubble further up the tree). The scrollable
/// overflow contributed by the claimed boxes is merged into
/// `output.scrollable_overflow_rect`.
///
/// This is called once per `RunMode.perform_layout` container layout, after the
/// layout algorithm (block/flexbox/grid) has run, and *inside* the layout
/// caching wrapper so that cache hits do not re-run the pass. It is a no-op when
/// `output.oof_positioning_area` is `null` (leaf and size-only outputs).
///
/// Which candidates the node claims is determined by the node's style via
/// `Style.is_containing_block`. `position: fixed` boxes unclaimed by every
/// ancestor are claimed by the final root positioning pass in
/// `compute_root_layout`.
pub fn compute_oof_layout(comptime Tree: type, tree_ref: *Tree, node_id: NodeId, output: *layout.LayoutOutput) !void {
    const TreeApi = LayoutTree(Tree);
    const area = output.oof_positioning_area orelse return;
    // Nothing to position (the common case): skip the pass, but still clear any
    // hoisted list from an earlier layout (Taffy 393270e).
    if (output.oof_candidates.items.len == 0) {
        try TreeApi.clear_hoisted_children(tree_ref, node_id);
        return;
    }

    const node_style = TreeApi.get_style(tree_ref, node_id);
    const direction = node_style.direction;
    const claims = node_style.is_containing_block();

    const candidates = output.oof_candidates;
    output.oof_candidates = .empty;
    const reversed = output.scrollable_overflow_rect.is_reversed();
    const result = try compute_oof_layout_for_area_with_origin(Tree, tree_ref, node_id, candidates, area, direction, claims, reversed);
    // Always record the hoisted child list (even when empty) so that lists
    // recorded by previous layout runs do not persist.
    try TreeApi.clear_hoisted_children(tree_ref, node_id);
    try TreeApi.add_hoisted_children(tree_ref, node_id, result.hoisted.items);
    output.oof_candidates = result.unclaimed;
    const overflow = node_style.overflow;
    output.scrollable_overflow_rect = scrollable_overflow.finalize_scrollable_overflow(
        output.scrollable_overflow_rect.rect().@"union"(result.scrollable_overflow_rect),
        area.size,
        reversed,
        overflow.x.is_scroll_container() or overflow.y.is_scroll_container());
}

/// The result of laying out out-of-flow candidates against an explicit positioning area.
pub const OofLayoutResult = struct {
    /// Candidates claimed and laid out by this pass, in document order.
    hoisted: std.ArrayList(NodeId),
    /// Candidates not claimed by this pass, which must continue bubbling.
    unclaimed: layout.OofCandidates,
    /// Scrollable overflow contributed by the claimed candidates, relative to the
    /// positioning area's origin.
    scrollable_overflow_rect: Rect(f32),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OofLayoutResult) void {
        self.hoisted.deinit(self.allocator);
    }
};

/// Lay out out-of-flow candidates against an explicit positioning area.
///
/// Unlike `compute_oof_layout`, this function does not update the geometry
/// owner's hoisted children or merge overflow into a `LayoutOutput`. This is
/// useful when the CSS containing block does not have its own layout node and
/// another node owns the resulting geometry.
pub fn compute_oof_layout_for_area(comptime Tree: type, tree_ref: *Tree,
    geometry_owner: NodeId,
    candidates: layout.OofCandidates,
    area: layout.OofPositioningArea,
    direction: style.Direction,
    claims: style.ContainingBlockClaims) !OofLayoutResult {
    return compute_oof_layout_for_area_with_origin(Tree, tree_ref, geometry_owner, candidates, area, direction, claims, .{ .x = direction.is_rtl(), .y = false });
}

/// `compute_oof_layout_for_area` with explicit physical scroll-origin directions.
fn compute_oof_layout_for_area_with_origin(comptime Tree: type, tree_ref: *Tree,
    geometry_owner: NodeId,
    candidates: layout.OofCandidates,
    area: layout.OofPositioningArea,
    direction: style.Direction,
    claims: style.ContainingBlockClaims,
    reversed: Point(bool)) !OofLayoutResult {
    const TreeApi = LayoutTree(Tree);
    const owner_style = TreeApi.get_style(tree_ref, geometry_owner);
    const overflow = owner_style.overflow;
    const scratch = TreeApi.scratch_allocator(tree_ref);

    var hoisted = std.ArrayList(NodeId).empty;
    errdefer hoisted.deinit(scratch);
    var unclaimed: layout.OofCandidates = .empty;
    const scrollable_overflow_rect = try perform_oof_layout(
        Tree,
tree_ref,
        geometry_owner,
        candidates,
        area.size,
        area.offset,
        direction,
        claims,
        overflow,
        reversed,
        &hoisted,
        &unclaimed);
    const finalized = scrollable_overflow.finalize_scrollable_overflow(
        scrollable_overflow_rect,
        area.size,
        reversed,
        overflow.x.is_scroll_container() or overflow.y.is_scroll_container()).rect();
    return .{ .hoisted = hoisted, .unclaimed = unclaimed, .scrollable_overflow_rect = finalized, .allocator = scratch };
}

/// The result of laying out a single out-of-flow box with `layout_oof_box`.
pub const OofBoxLayout = struct {
    /// The box's final layout (its `location` is relative to the containing block's border box)
    layout: layout.Layout,
    /// Out-of-flow candidates surfaced from within the box's subtree, with anchors
    /// relative to the box's own border box
    surfaced: layout.OofCandidates,
    /// The box's `overflow` style
    overflow: Point(style.Overflow),
    /// The box's `contain` style
    contain: style.Contain,
};

/// Size and position a single out-of-flow box against its containing block, and
/// store its layout.
///
///   * `area_size`/`area_offset` describe the inset-resolution area of the
///     containing block (border box minus borders and scrollbar gutters),
///     relative to the containing block's border box.
///   * `grid_owner` is the node whose detailed layout info is consulted for grid
///     placement: if it is a grid container, the box is positioned relative to the
///     grid area determined by its grid-placement properties rather than the
///     passed area.
///   * `cache_probe`, when supplied, is set to true if the box's final layout pass
///     was served from the cache. Callers which re-record derived state (such as
///     the root's hoisted children) need this to avoid duplicating that state.
pub fn layout_oof_box(comptime Tree: type, tree_ref: *Tree,
    candidate: layout.OofCandidate,
    area_size_in: Size(f32),
    area_offset_in: Point(f32),
    direction: style.Direction,
    container_overflow: Point(style.Overflow),
    grid_owner: ?NodeId,
    cache_probe: ?*bool) !OofBoxLayout {
    const TreeApi = LayoutTree(Tree);
    const child_style = TreeApi.get_style(tree_ref, candidate.node);

    var area_size = area_size_in;
    var area_offset = area_offset_in;

    // If the containing block is a grid container then the box is positioned
    // relative to the grid area determined by its grid-placement properties
    // (which falls back to the passed area for `auto` placement).
    if (grid_owner) |owner| {
        if (TreeApi.get_detailed_layout_info(tree_ref, owner)) |info| {
            const grid = @import("grid/root.zig");
            const detailed: *const grid.DetailedGridInfo = @ptrCast(@alignCast(info));
            const area_rect = Rect(f32){
                .left = area_offset.x,
                .right = area_offset.x + area_size.width,
                .top = area_offset.y,
                .bottom = area_offset.y + area_size.height,
            };
            const grid_area = detailed.resolve_absolute_grid_area(child_style.grid_row, child_style.grid_column, direction, area_rect);
            area_size = .{ .width = grid_area.right - grid_area.left, .height = grid_area.bottom - grid_area.top };
            area_offset = .{ .x = grid_area.left, .y = grid_area.top };
        }
    }
    const area_width = area_size.width;
    const area_height = area_size.height;

    const aspect_ratio = child_style.aspect_ratio;
    const margin = resolve_margin_options(child_style.margin, area_width);
    const padding = resolve_length_rect_or_zero(child_style.padding, area_width);
    const border = resolve_length_rect_or_zero(child_style.border, area_width);
    const padding_border_sum = padding.add(border).sum_axes();
    const box_sizing_adjustment = if (child_style.box_sizing == .content_box) padding_border_sum else geometry.SIZE_F32_ZERO;

    // Resolve inset
    const left = child_style.inset.left.resolve_to_option(area_width);
    const right = child_style.inset.right.resolve_to_option(area_width);
    const top = child_style.inset.top.resolve_to_option(area_height);
    const bottom = child_style.inset.bottom.resolve_to_option(area_height);

    // Compute known dimensions from min/max/inherent size styles
    const size_style = child_style.size;
    const style_size = math.optional_size_maybe_add(resolveDimensionSize(size_style, area_size).maybe_apply_aspect_ratio(aspect_ratio), to_optional_size(box_sizing_adjustment));
    const min_size_raw = math.optional_size_maybe_add(resolveAutoSize(child_style.min_size, area_size).maybe_apply_aspect_ratio(aspect_ratio), to_optional_size(box_sizing_adjustment));
    // A box's min size is at least its padding+border sum: `or(padding_border_sum)`
    // then `.maybe_max(padding_border_sum)`.
    var min_size = Size(?f32){
        .width = @max(min_size_raw.width orelse padding_border_sum.width, padding_border_sum.width),
        .height = @max(min_size_raw.height orelse padding_border_sum.height, padding_border_sum.height),
    };
    const max_size = math.optional_size_maybe_add(resolveAutoSize(child_style.max_size, area_size).maybe_apply_aspect_ratio(aspect_ratio), to_optional_size(box_sizing_adjustment));
    var known_dimensions = math.optional_size_maybe_clamp(style_size, min_size, max_size);

    const is_replaced = child_style.is_replaced();
    const is_table = child_style.is_table();
    const item_direction = child_style.direction;
    const justify_self = alignment_common.resolve_self_relative(child_style.justify_self orelse alignment.AlignSelf.NORMAL, item_direction, direction, true);
    const align_self = alignment_common.resolve_self_relative(child_style.align_self orelse alignment.AlignSelf.NORMAL, item_direction, direction, false);
    const overflow = child_style.overflow;
    const scrollbar_width = child_style.scrollbar_width;
    const contain = child_style.contain;

    // Static positions are relative to the containing block's border box: make
    // them relative to the inset-resolution area
    const static_position = Point(layout.AxisStaticPosition){
        .x = .{
            .area = .{ .start = candidate.static_position.x.area.start - area_offset.x, .end = candidate.static_position.x.area.end - area_offset.x },
            .alignment = candidate.static_position.x.alignment,
        },
        .y = .{
            .area = .{ .start = candidate.static_position.y.area.start - area_offset.y, .end = candidate.static_position.y.area.end - area_offset.y },
            .alignment = candidate.static_position.y.alignment,
        },
    };

    const horizontal = OofAxis{
        .cb_size = area_width,
        .inset = .{ .start = left, .end = right },
        .margin = .{ .start = margin.left, .end = margin.right },
        .static_position = static_position.x,
        .alignment = OofAlignment.from_resolved(justify_self),
        .safety = justify_self.safety,
        .is_inline = true,
        .reversed = direction.is_rtl(),
        .is_scroll_axis = container_overflow.x.is_scroll_container(),
    };
    const vertical = OofAxis{
        .cb_size = area_height,
        .inset = .{ .start = top, .end = bottom },
        .margin = .{ .start = margin.top, .end = margin.bottom },
        .static_position = static_position.y,
        .alignment = OofAlignment.from_resolved(align_self),
        .safety = align_self.safety,
        .is_inline = false,
        .reversed = false,
        .is_scroll_axis = container_overflow.y.is_scroll_container(),
    };
    const stretch_fit_size = Size(f32){ .width = horizontal.stretch_fit_size(), .height = vertical.stretch_fit_size() };
    // The space available to the border box is its stretch-fit size. For a table
    // it never exceeds the containing block minus margins
    // (https://www.w3.org/TR/css-tables-3/#abspos).
    var available_size = stretch_fit_size;
    if (is_table) {
        available_size.width = @min(available_size.width, @max(area_width - (margin.left orelse 0) - (margin.right orelse 0), 0));
        available_size.height = @min(available_size.height, @max(area_height - (margin.top orelse 0) - (margin.bottom orelse 0), 0));
    }
    const oof_available_space = Size(AvailableSpace){
        .width = .{ .definite = math.f32_maybe_clamp(available_size.width, min_size.width, max_size.width) },
        .height = .{ .definite = math.f32_maybe_clamp(available_size.height, min_size.height, max_size.height) },
    };

    // Resolve any sizing keywords (min-content, max-content, fit-content,
    // fit-content(...), stretch) in the size styles. An explicitly sized axis
    // takes precedence over the automatic size below.
    if (size_style.width.is_sizing_keyword() or size_style.height.is_sizing_keyword()) {
        try sizing_keyword.resolve_absolute_sizing_keywords(
            Tree,
tree_ref,
            candidate.node,
            &known_dimensions,
            size_style,
            area_size,
            .{ .left = left, .right = right, .top = top, .bottom = bottom },
            .{ .left = margin.left, .right = margin.right, .top = margin.top, .bottom = margin.bottom },
            .content_size);
        known_dimensions = math.optional_size_maybe_clamp(known_dimensions.maybe_apply_aspect_ratio(aspect_ratio), min_size, max_size);
    }

    // Resolve automatic sizes (https://www.w3.org/TR/css-position-3/#abspos-auto-size).
    //
    // An auto size is the stretch-fit size if the self-alignment in that axis is
    // `stretch` (or `normal` for a non-replaced, non-table box) and neither inset
    // is auto; otherwise it is the fit-content size, measured below. Stretch-fit
    // sizes resolve first so a size can transfer through the aspect ratio. The
    // block axis is the ratio-dependent one, so a stretched inline size is
    // transferred rather than also stretching the block size; explicit `stretch`
    // in both axes stretches both and ignores the ratio.
    const stretch_width = known_dimensions.width == null and horizontal.is_stretch_sized(is_replaced, is_table);
    const stretch_height = known_dimensions.height == null and vertical.is_stretch_sized(is_replaced, is_table);
    const both_explicit_stretch = horizontal.alignment == .stretch and vertical.alignment == .stretch;
    const stretch_aspect_ratio: ?f32 = if (stretch_width and stretch_height and both_explicit_stretch) null else aspect_ratio;
    if (stretch_width) {
        if (is_table) {
            // A table cannot be stretched smaller than its content: stretch-fit is a minimum
            min_size.width = @max(min_size.width orelse 0, stretch_fit_size.width);
        } else {
            known_dimensions.width = stretch_fit_size.width;
            known_dimensions = math.optional_size_maybe_clamp(known_dimensions.maybe_apply_aspect_ratio(stretch_aspect_ratio), min_size, max_size);
        }
    }
    if (known_dimensions.height == null and stretch_height) {
        if (is_table) {
            min_size.height = @max(min_size.height orelse 0, stretch_fit_size.height);
        } else {
            known_dimensions.height = stretch_fit_size.height;
            known_dimensions = math.optional_size_maybe_clamp(known_dimensions.maybe_apply_aspect_ratio(stretch_aspect_ratio), min_size, max_size);
        }
    }

    var measured_size: Size(f32) = .{ .width = 0, .height = 0 };
    if (known_dimensions.width == null or known_dimensions.height == null) {
        measured_size = try TreeApi.measure_child_size_both(tree_ref, 
            candidate.node,
            known_dimensions,
            to_optional_size(area_size),
            oof_available_space,
            .content_size,
            .{ .start = false, .end = false });
    }
    const unclamped_size = Size(f32){
        .width = known_dimensions.width orelse measured_size.width,
        .height = known_dimensions.height orelse measured_size.height,
    };
    const final_size = geometry.Size(f32){
        .width = math.f32_maybe_clamp(unclamped_size.width, min_size.width, max_size.width),
        .height = math.f32_maybe_clamp(unclamped_size.height, min_size.height, max_size.height),
    };

    const layout_input = layout.LayoutInput{
        .known_dimensions = to_optional_size(final_size),
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = to_optional_size(area_size),
        .available_space = oof_available_space,
        .sizing_mode = .content_size,
        .axis = .both,
        .run_mode = .perform_layout,
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
    if (cache_probe) |probe| probe.* = (TreeApi.cache_get(tree_ref, candidate.node, &layout_input)) != null;
    var layout_output = try compute_child_layout_pass(Tree, tree_ref, candidate.node, layout_input);

    // Resolve auto margins (https://www.w3.org/TR/css-position-3/#abspos-margins)
    const horizontal_margin = horizontal.resolve_margins(final_size.width);
    const vertical_margin = vertical.resolve_margins(final_size.height);
    const resolved_margin = Rect(f32){
        .left = horizontal_margin.start,
        .right = horizontal_margin.end,
        .top = vertical_margin.start,
        .bottom = vertical_margin.end,
    };

    // Align the margin box within the IMCB (https://www.w3.org/TR/css-position-3/#abspos-alignment)
    const location = Point(f32){
        .x = horizontal.position(final_size.width, horizontal_margin) + area_offset.x,
        .y = vertical.position(final_size.height, vertical_margin) + area_offset.y,
    };

    // Note: axis intentionally switched here as scrollbars take up space in the
    // opposite axis to the axis in which scrolling is enabled.
    const scrollbar_size = Size(f32){
        .width = if (overflow.y == .scroll) scrollbar_width else 0,
        .height = if (overflow.x == .scroll) scrollbar_width else 0,
    };

    const box_layout = layout.Layout{
        .order = candidate.order,
        .size = final_size,
        .scrollable_overflow_rect = layout_output.scrollable_overflow_rect,
        .scrollbar_size = scrollbar_size,
        .location = location,
        .padding = padding,
        .border = border,
        .margin = resolved_margin,
    };
    try TreeApi.set_unrounded_layout(tree_ref, candidate.node, box_layout);

    const surfaced = layout_output.oof_candidates;
    layout_output.oof_candidates = .empty;
    return .{ .layout = box_layout, .surfaced = surfaced, .overflow = overflow, .contain = contain };
}

/// Perform final layout on the out-of-flow candidates for which the current node
/// is the containing block, and collect the remainder into `unclaimed` for
/// further bubbling.
///
///   * `node_id` is the current node. If its detailed layout info indicates that it
///     is a grid container, each claimed box is positioned relative to the grid
///     area determined by its grid-placement properties rather than the passed
///     inset-resolution area.
///   * `candidates` is the merged, document-ordered list of candidates held by the
///     current node (direct out-of-flow children plus candidates bubbled from
///     in-flow children). Anchors must be relative to the current node's border box.
///   * `area_size`/`area_offset` describe the inset-resolution area of the current
///     node (border box minus borders and scrollbar gutters).
///   * `claims` describes which out-of-flow positions the current node acts as a
///     containing block for.
///
/// Laying out a claimed box may surface further candidates from within its subtree
/// (e.g. a `position: fixed` descendant of a `position: absolute` box). These are
/// re-swept: claimed ones are appended to the work list, unclaimed ones are added
/// to `unclaimed`.
///
/// The ids of claimed boxes are appended to `hoisted` in order. Returns the
/// scrollable overflow contribution of the claimed boxes.
pub fn perform_oof_layout(comptime Tree: type, tree_ref: *Tree,
    node_id: NodeId,
    candidates: layout.OofCandidates,
    area_size: Size(f32),
    area_offset: Point(f32),
    direction: style.Direction,
    claims: style.ContainingBlockClaims,
    container_overflow: Point(style.Overflow),
    /// Physical scroll-origin directions of the containing block.
    reversed: Point(bool),
    hoisted: *std.ArrayList(NodeId),
    unclaimed: *layout.OofCandidates) !Rect(f32) {
    const TreeApi = LayoutTree(Tree);
    var absolute_overflow_rect = geometry.RECT_F32_ZERO;
    const is_scroll_container = container_overflow.x.is_scroll_container() or container_overflow.y.is_scroll_container();
    // In RTL the overflow reaches the right-edge scroll origin
    if (direction.is_rtl()) absolute_overflow_rect = absolute_overflow_rect.@"union"(.{ .left = 0, .right = @max(area_size.width, 0), .top = 0, .bottom = 0 });
    const overflow_container = scrollable_overflow.ScrollableOverflowContainer{
        .parent_is_scroll_container = is_scroll_container,
        .parent_size = area_size,
        .reversed = reversed,
        .padding = geometry.RECT_F32_ZERO,
    };

    if (candidates.items.len == 0) return absolute_overflow_rect;

    const scratch = TreeApi.scratch_allocator(tree_ref);

    // Split the candidate list into an initial work list of claimed candidates and
    // the unclaimed remainder. Further claimed candidates surfaced while laying out
    // a claimed box are appended to the work list (Blink-style re-sweep).
    var worklist = std.ArrayList(layout.OofCandidate).empty;
    defer worklist.deinit(scratch);
    try worklist.ensureTotalCapacity(scratch, candidates.items.len);
    for (candidates.items) |candidate| {
        if (claims.for_position(candidate.position)) {
            worklist.appendAssumeCapacity(candidate);
        } else {
            try unclaimed.append(scratch, candidate);
        }
    }

    var index: usize = 0;
    while (index < worklist.items.len) {
        const candidate = worklist.items[index];
        index += 1;
        try hoisted.append(scratch, candidate.node);

        const box_layout = try layout_oof_box(Tree, tree_ref, candidate, area_size, area_offset, direction, container_overflow, node_id, null);
        const location = box_layout.layout.location;
        const final_size = box_layout.layout.size;

        // Re-sweep any candidates surfaced from within the box's subtree,
        // translating their anchors so they are relative to this node's border box
        var surfaced = box_layout.surfaced;
        if (surfaced.items.len != 0) {
            translateCandidates(&surfaced, location);
            for (surfaced.items) |surfaced_candidate| {
                if (claims.for_position(surfaced_candidate.position)) {
                    try worklist.append(scratch, surfaced_candidate);
                } else {
                    try unclaimed.append(scratch, surfaced_candidate);
                }
            }
        }

        // Physical coordinates relative to the positioning area (Taffy c256056)
        const relative_location = Point(f32){ .x = location.x - area_offset.x, .y = location.y - area_offset.y };
        absolute_overflow_rect = absolute_overflow_rect.@"union"(scrollable_overflow.compute_scrollable_overflow_contribution(
            relative_location,
            final_size,
            box_layout.layout.scrollable_overflow_rect.rect(),
            box_layout.layout.border,
            box_layout.overflow,
            box_layout.contain,
            &overflow_container,
            geometry.RECT_F32_ZERO));
    }

    return absolute_overflow_rect;
}

/// Move every candidate's static-position areas by `offset`, converting them from
/// being relative to a child node's border box to being relative to the parent
/// node's border box as candidates bubble up the tree.
pub fn translateCandidates(candidates: *layout.OofCandidates, offset: Point(f32)) void {
    for (candidates.items) |*candidate| {
        candidate.static_position.x.area.start += offset.x;
        candidate.static_position.x.area.end += offset.x;
        candidate.static_position.y.area.start += offset.y;
        candidate.static_position.y.area.end += offset.y;
    }
}

/// Move every candidate in `source` into `destination`, leaving `source` empty.
///
/// `source` must not be a list whose storage is shared with `destination`; in
/// practice it is always an item-local list that is discarded afterwards.
pub fn appendCandidates(allocator: std.mem.Allocator, destination: *layout.OofCandidates, source: *layout.OofCandidates) !void {
    if (source.items.len == 0) return;
    try destination.ensureUnusedCapacity(allocator, source.items.len);
    destination.appendSliceAssumeCapacity(source.items);
    source.clearRetainingCapacity();
}

/// Compute a child layout while making sure any nested `compute_child_layout`
/// call (the algorithms re-enter through the tree) stays inside the current pass.
fn compute_child_layout_pass(comptime Tree: type, tree_ref: *Tree, node_id: NodeId, input: layout.LayoutInput) !layout.LayoutOutput {
    const TreeApi = LayoutTree(Tree);
    return TreeApi.compute_child_layout(tree_ref, node_id, input);
}

fn to_optional_size(value: Size(f32)) Size(?f32) {
    return .{ .width = value.width, .height = value.height };
}

/// Resolve a `Size<Dimension>` (an explicit `width`/`height`) against a definite basis.
fn resolveDimensionSize(value: Size(dimension.Dimension), basis: Size(f32)) Size(?f32) {
    return .{ .width = value.width.resolve(basis.width), .height = value.height.resolve(basis.height) };
}

/// Resolve a `Size<LengthPercentageAuto>` (a `min-`/`max-` size) against a definite basis.
fn resolveAutoSize(value: Size(dimension.LengthPercentageAuto), basis: Size(f32)) Size(?f32) {
    return .{ .width = value.width.resolve_to_option(basis.width), .height = value.height.resolve_to_option(basis.height) };
}

fn resolve_margin_options(value: Rect(dimension.LengthPercentageAuto), basis: ?f32) Rect(?f32) {
    return .{
        .left = value.left.resolve_to_option(basis),
        .right = value.right.resolve_to_option(basis),
        .top = value.top.resolve_to_option(basis),
        .bottom = value.bottom.resolve_to_option(basis),
    };
}

fn resolve_length_rect_or_zero(value: Rect(dimension.LengthPercentage), basis: ?f32) Rect(f32) {
    return .{
        .left = value.left.resolve_to_option(basis) orelse 0,
        .right = value.right.resolve_to_option(basis) orelse 0,
        .top = value.top.resolve_to_option(basis) orelse 0,
        .bottom = value.bottom.resolve_to_option(basis) orelse 0,
    };
}

test "static offsets honour alignment, safe fallback and margins" {
    const testing = std.testing;
    const size = Size(f32){ .width = 20, .height = 10 };
    const no_margin = Rect(f32){ .left = 0, .right = 0, .top = 0, .bottom = 0 };
    const margin = Rect(f32){ .left = 5, .right = 15, .top = 0, .bottom = 0 };
    const area = geometry.Line(f32){ .start = 10, .end = 110 };

    const start = resolve_static_offset(.{
        .x = .{ .area = area, .alignment = .from_keyword(.start) },
        .y = layout.AxisStaticPosition.from_edge(0, .start),
    }, size, no_margin);
    try testing.expectEqual(@as(f32, 10), start.x);
    const start_margin = resolve_static_offset(.{
        .x = .{ .area = area, .alignment = .from_keyword(.start) },
        .y = layout.AxisStaticPosition.from_edge(0, .start),
    }, size, margin);
    try testing.expectEqual(@as(f32, 15), start_margin.x);

    const end = resolve_static_offset(.{
        .x = .{ .area = area, .alignment = .from_keyword(.end) },
        .y = layout.AxisStaticPosition.from_edge(0, .start),
    }, size, no_margin);
    try testing.expectEqual(@as(f32, 90), end.x);

    const center = resolve_static_offset(.{
        .x = .{ .area = area, .alignment = .from_keyword(.center) },
        .y = layout.AxisStaticPosition.from_edge(0, .start),
    }, size, no_margin);
    try testing.expectEqual(@as(f32, 50), center.x);
    const center_margin = resolve_static_offset(.{
        .x = .{ .area = area, .alignment = .from_keyword(.center) },
        .y = layout.AxisStaticPosition.from_edge(0, .start),
    }, size, margin);
    try testing.expectEqual(@as(f32, 45), center_margin.x);

    // Safe alignment falls back to `start` only when the margin box overflows.
    const safe = layout.AxisStaticAlign{
        .keyword = .end,
        .safety = .safe,
        .fallback = .start,
    };
    const fits = resolve_static_offset(.{
        .x = .{ .area = area, .alignment = safe },
        .y = layout.AxisStaticPosition.from_edge(0, .start),
    }, size, no_margin);
    try testing.expectEqual(@as(f32, 90), fits.x);
    const exactly_fits = resolve_static_offset(.{
        .x = .{ .area = area, .alignment = safe },
        .y = layout.AxisStaticPosition.from_edge(0, .start),
    }, .{ .width = 100, .height = 10 }, no_margin);
    try testing.expectEqual(@as(f32, 10), exactly_fits.x);
    const overflows = resolve_static_offset(.{
        .x = .{ .area = area, .alignment = safe },
        .y = layout.AxisStaticPosition.from_edge(0, .start),
    }, .{ .width = 120, .height = 10 }, no_margin);
    try testing.expectEqual(@as(f32, 10), overflows.x);

    // Degenerate (zero-extent) areas emitted by block layout behave as anchors.
    const anchor = resolve_static_offset(.{
        .x = layout.AxisStaticPosition.from_edge(40, .start),
        .y = layout.AxisStaticPosition.from_edge(0, .start),
    }, size, no_margin);
    try testing.expectEqual(@as(f32, 40), anchor.x);
    const anchor_end = resolve_static_offset(.{
        .x = layout.AxisStaticPosition.from_edge(40, .end),
        .y = layout.AxisStaticPosition.from_edge(0, .start),
    }, size, no_margin);
    try testing.expectEqual(@as(f32, 20), anchor_end.x);
}
