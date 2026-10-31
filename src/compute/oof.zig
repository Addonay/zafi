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
        .x = resolveAxis(static_position.x, final_size.width, resolved_margin.left, resolved_margin.right),
        .y = resolveAxis(static_position.y, final_size.height, resolved_margin.top, resolved_margin.bottom),
    };
}

fn resolveAxis(sp: layout.AxisStaticPosition, size: f32, margin_start: f32, margin_end: f32) f32 {
    const overflows = sp.alignment.safety == .safe and size + margin_start + margin_end > sp.area.end - sp.area.start;
    const keyword = if (overflows) sp.alignment.fallback else sp.alignment.keyword;
    return switch (keyword) {
        .start => sp.area.start + margin_start,
        .end => sp.area.end - size - margin_end,
        .center => (sp.area.start + sp.area.end) / 2.0 - size / 2.0 + (margin_start - margin_end) / 2.0,
    };
}

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

    const node_style = TreeApi.get_style(tree_ref, node_id);
    const direction = node_style.direction;
    const claims = node_style.is_containing_block();

    const candidates = output.oof_candidates;
    output.oof_candidates = .empty;
    const result = try compute_oof_layout_for_area(Tree, tree_ref, node_id, candidates, area, direction, claims);
    // Always record the hoisted child list (even when empty) so that lists
    // recorded by previous layout runs do not persist.
    try TreeApi.clear_hoisted_children(tree_ref, node_id);
    try TreeApi.add_hoisted_children(tree_ref, node_id, result.hoisted.items);
    output.oof_candidates = result.unclaimed;
    output.scrollable_overflow_rect = output.scrollable_overflow_rect.@"union"(result.scrollable_overflow_rect);
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
    const TreeApi = LayoutTree(Tree);
    const owner_style = TreeApi.get_style(tree_ref, geometry_owner);
    const is_scroll_container = owner_style.overflow.x.is_scroll_container() or owner_style.overflow.y.is_scroll_container();
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
        is_scroll_container,
        &hoisted,
        &unclaimed);
    return .{ .hoisted = hoisted, .unclaimed = unclaimed, .scrollable_overflow_rect = scrollable_overflow_rect, .allocator = scratch };
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
    const min_size = Size(?f32){
        .width = @max(min_size_raw.width orelse padding_border_sum.width, padding_border_sum.width),
        .height = @max(min_size_raw.height orelse padding_border_sum.height, padding_border_sum.height),
    };
    const max_size = math.optional_size_maybe_add(resolveAutoSize(child_style.max_size, area_size).maybe_apply_aspect_ratio(aspect_ratio), to_optional_size(box_sizing_adjustment));
    var known_dimensions = math.optional_size_maybe_clamp(style_size, min_size, max_size);

    const is_replaced = child_style.is_compressible_replaced();
    const overflow = child_style.overflow;
    const scrollbar_width = child_style.scrollbar_width;
    const contain = child_style.contain;

    // Resolve any sizing keywords (min-content, max-content, fit-content,
    // fit-content(...), stretch) in the size styles. An explicitly sized axis
    // takes precedence over the inset-derived size below.
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

    // Fill in width from left/right and reapply aspect ratio if:
    //   - Width is not already known
    //   - Item has both left and right inset properties set
    //   - Item is not a replaced element (an `auto` size of an absolutely
    //     positioned replaced element resolves to its intrinsic size rather than
    //     being stretched between the insets:
    //     https://www.w3.org/TR/CSS22/visudet.html#abs-replaced-width)
    if (!is_replaced and known_dimensions.width == null and left != null and right != null) {
        const new_width_raw = math.f32_maybe_sub(area_width, margin.left) - (margin.right orelse 0) - left.? - right.?;
        known_dimensions.width = @max(new_width_raw, 0);
        known_dimensions = math.optional_size_maybe_clamp(known_dimensions.maybe_apply_aspect_ratio(aspect_ratio), min_size, max_size);
    }

    // Fill in height from top/bottom and reapply aspect ratio if:
    //   - Height is not already known
    //   - Item has both top and bottom inset properties set
    //   - Item is not a replaced element
    //     (https://www.w3.org/TR/CSS22/visudet.html#abs-replaced-height)
    if (!is_replaced and known_dimensions.height == null and top != null and bottom != null) {
        const new_height_raw = math.f32_maybe_sub(area_height, margin.top) - (margin.bottom orelse 0) - top.? - bottom.?;
        known_dimensions.height = @max(new_height_raw, 0);
        known_dimensions = math.optional_size_maybe_clamp(known_dimensions.maybe_apply_aspect_ratio(aspect_ratio), min_size, max_size);
    }

    // The space available to the box's border box: the containing block minus
    // the box's insets and margins (`auto` ones count as zero), clamped by its
    // min/max sizes.
    const oof_available_space = Size(AvailableSpace){
        .width = .{ .definite = math.f32_maybe_clamp(@max(area_width - (left orelse 0) - (right orelse 0) - (margin.left orelse 0) - (margin.right orelse 0), 0), min_size.width, max_size.width) },
        .height = .{ .definite = math.f32_maybe_clamp(@max(area_height - (top orelse 0) - (bottom orelse 0) - (margin.top orelse 0) - (margin.bottom orelse 0), 0), min_size.height, max_size.height) },
    };

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

    const non_auto_margin = Rect(?f32){
        .left = if (left != null) (margin.left orelse 0) else null,
        .right = if (right != null) (margin.right orelse 0) else null,
        .top = if (top != null) (margin.top orelse 0) else null,
        .bottom = if (bottom != null) (margin.bottom orelse 0) else null,
    };

    // Expand auto margins to fill available space
    // https://www.w3.org/TR/CSS21/visudet.html#abs-non-replaced-width
    const auto_margin: Rect(f32) = blk: {
        // Auto margins only absorb free space in an axis where both insets are
        // non-auto. Otherwise they resolve to 0.
        const free_space = Size(f32){
            .width = if (left != null and right != null)
                area_size.width - left.? - right.? - final_size.width - (non_auto_margin.left orelse 0) - (non_auto_margin.right orelse 0)
            else
                0,
            .height = if (top != null and bottom != null)
                area_size.height - top.? - bottom.? - final_size.height - (non_auto_margin.top orelse 0) - (non_auto_margin.bottom orelse 0)
            else
                0,
        };

        const auto_margin_count_width: u32 = @as(u32, @intFromBool(margin.left == null)) + @as(u32, @intFromBool(margin.right == null));
        const auto_margin_count_height: u32 = @as(u32, @intFromBool(margin.top == null)) + @as(u32, @intFromBool(margin.bottom == null));
        const auto_margin_size = Size(f32){
            // If all three of 'left', 'width', and 'right' are 'auto': First set any
            // 'auto' values for 'margin-left' and 'margin-right' to 0. ...
            // If none of the three is 'auto': If both 'margin-left' and 'margin-right'
            // are 'auto', solve the equation under the extra constraint that the two
            // margins get equal values, unless this would make them negative, ...
            .width = if (auto_margin_count_width == 2 and free_space.width <= 0)
                0
            else if (auto_margin_count_width > 0)
                free_space.width / @as(f32, @floatFromInt(auto_margin_count_width))
            else
                0,
            .height = if (auto_margin_count_height == 2 and free_space.height <= 0)
                0
            else if (auto_margin_count_height > 0)
                free_space.height / @as(f32, @floatFromInt(auto_margin_count_height))
            else
                0,
        };

        break :blk Rect(f32){
            .left = if (margin.left != null) 0 else auto_margin_size.width,
            .right = if (margin.right != null) 0 else auto_margin_size.width,
            .top = if (margin.top != null) 0 else auto_margin_size.height,
            .bottom = if (margin.bottom != null) 0 else auto_margin_size.height,
        };
    };

    const resolved_margin = Rect(f32){
        .left = margin.left orelse auto_margin.left,
        .right = margin.right orelse auto_margin.right,
        .top = margin.top orelse auto_margin.top,
        .bottom = margin.bottom orelse auto_margin.bottom,
    };

    const static_offset = resolve_static_offset(candidate.static_position, final_size, resolved_margin);

    const x_offset: f32 = if (left != null and right != null)
        (if (direction.is_rtl()) area_size.width - final_size.width - right.? - resolved_margin.right else left.? + resolved_margin.left)
    else if (left != null)
        left.? + resolved_margin.left
    else if (right != null)
        area_size.width - final_size.width - right.? - resolved_margin.right
    else
        static_offset.x - area_offset.x;

    const y_offset: ?f32 = if (top != null)
        top.? + resolved_margin.top
    else if (bottom != null)
        area_size.height - final_size.height - bottom.? - resolved_margin.bottom
    else
        null;
    const location = Point(f32){
        .x = x_offset + area_offset.x,
        .y = if (y_offset) |value| value + area_offset.y else static_offset.y,
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
    is_scroll_container: bool,
    hoisted: *std.ArrayList(NodeId),
    unclaimed: *layout.OofCandidates) !Rect(f32) {
    const TreeApi = LayoutTree(Tree);
    var absolute_overflow_rect = geometry.RECT_F32_ZERO;

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

        const box_layout = try layout_oof_box(Tree, tree_ref, candidate, area_size, area_offset, direction, node_id, null);
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

        // Location is measured from the scroll origin (the inline-start edge: right side in RTL)
        const relative_location = if (direction.is_rtl())
            Point(f32){
                .x = area_size.width - (location.x - area_offset.x) - final_size.width,
                .y = location.y - area_offset.y,
            }
        else
            Point(f32){ .x = location.x - area_offset.x, .y = location.y - area_offset.y };
        absolute_overflow_rect = absolute_overflow_rect.@"union"(scrollable_overflow.compute_scrollable_overflow_contribution(
            relative_location,
            final_size,
            box_layout.layout.scrollable_overflow_rect,
            box_layout.overflow,
            box_layout.contain,
            is_scroll_container));
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
