//! CSS Flexbox layout algorithm.
//!
//! Direct port of Taffy's `compute/flexbox.rs` (v0.14.0-7, commit 1b918ba) with
//! the default feature set: `flexbox`, `flexbox_balance`, and `content_size`.
//! Phase order, helper names, constants and formulas follow the Rust source
//! exactly; the `flexbox_balance` dynamic program (including the
//! divide-and-conquer optimization) is ported rather than approximated.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style/root.zig");
const dimension = @import("../style/dimension.zig");
const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;
const flex = @import("../style/flex.zig");
const NodeId = @import("../tree/node.zig").NodeId;
const layout = @import("../tree/layout.zig");
const math = @import("../util/math.zig");
const alignment = @import("common/alignment.zig");
const alignment_common = alignment;
const scrollable_overflow = @import("common/scrollable_overflow.zig");
const sizing_keyword = @import("common/sizing_keyword.zig");
const oof = @import("oof.zig");
const LayoutTree = @import("../tree/interfaces.zig").LayoutTree;
const tree = @import("../tree/tree.zig");

const Size = geometry.Size;
const F32Size = geometry.F32Size;
const Rect = geometry.Rect;
const Point = geometry.Point;
const LengthPercentage = dimension.LengthPercentage;
const LengthPercentageAuto = dimension.LengthPercentageAuto;
const Dimension = dimension.Dimension;

const LINE_FALSE = geometry.Line(bool){ .start = false, .end = false };
const SIZE_NONE: Size(?f32) = .{ .width = null, .height = null };

/// The intermediate results of a flexbox calculation for a single item
pub const FlexItem = struct {
    /// The identifier for the associated node
    node: NodeId,

    /// The order of the node relative to it's siblings
    order: u32,

    /// The base size of this item
    size: Size(?f32),
    /// The raw size style of this item. Used to detect and resolve sizing
    /// keywords (`min-content`, `max-content`, `fit-content`, `fit-content(...)`, and `stretch`)
    size_style: Size(Dimension),
    /// The minimum allowable size of this item
    min_size: Size(?f32),
    /// The maximum allowable size of this item
    max_size: Size(?f32),
    /// The aspect ratio of this item
    aspect_ratio: ?f32,
    /// The cross-alignment of this item
    align_self: style.alignment.AlignSelf,

    /// The overflow style of the item
    overflow: Point(style.Overflow),
    /// The contain style of the item
    contain: style.Contain,
    /// The width of the scrollbars (if it has any)
    scrollbar_width: f32,
    /// The flex shrink style of the item
    flex_shrink: f32,
    /// The flex grow style of the item
    flex_grow: f32,
    /// Whether the item's used flex basis is definite (rather than derived from the item's content)
    flex_basis_is_definite: bool,

    /// The minimum size of the item. This differs from min_size above because it also
    /// takes into account content based automatic minimum sizes
    resolved_minimum_main_size: f32,

    /// The `position: relative` offset of this item, resolved to (width, height) in the
    /// container's coordinate space (zero for non-relative items)
    relative_inset: F32Size,
    /// The margin of this item
    margin: Rect(f32),
    /// Whether each margin is an auto margin or not
    margin_is_auto: Rect(bool),
    /// The padding of this item
    padding: Rect(f32),
    /// The border of this item
    border: Rect(f32),

    /// The default size of this item
    flex_basis: f32,
    /// The default size of this item, minus padding and border
    inner_flex_basis: f32,
    /// The amount by which this item has deviated from its target size
    violation: f32,
    /// Is the size of this item locked
    frozen: bool,

    /// Either the max- or min- content flex fraction
    /// See https://www.w3.org/TR/css-flexbox-1/#intrinsic-main-sizes
    content_flex_fraction: f32,

    /// The proposed inner size of this item
    hypothetical_inner_size: Size(f32),
    /// The proposed outer size of this item
    hypothetical_outer_size: Size(f32),
    /// The size that this item wants to be
    target_size: Size(f32),
    /// The size that this item wants to be, plus any padding and border
    outer_target_size: Size(f32),

    /// The position of the bottom edge of this item
    baseline: f32,

    /// A temporary value for the main offset
    ///
    /// Offset is the relative position from the item's natural flow position based on
    /// relative position values, alignment, and justification. Does not include margin/padding/border.
    offset_main: f32,
    /// A temporary value for the cross offset
    ///
    /// Offset is the relative position from the item's natural flow position based on
    /// relative position values, alignment, and justification. Does not include margin/padding/border.
    offset_cross: f32,

    /// Out-of-flow candidates bubbled out of this item's subtree, with anchors
    /// already translated to be relative to the container's border box.
    oof_candidates: layout.OofCandidates,

    /// Returns true if the item is a <https://www.w3.org/TR/css-overflow-3/#scroll-container>
    pub fn is_scroll_container(self: FlexItem) bool {
        return self.overflow.x.is_scroll_container() or self.overflow.y.is_scroll_container();
    }

    /// Returns true if the item participates in baseline alignment: it has `align-self: baseline`
    /// and neither of its cross-axis margins are `auto`.
    /// See <https://www.w3.org/TR/css-flexbox-1/#baseline-participation>
    pub fn participates_in_baseline_alignment(self: FlexItem, dir: flex.FlexDirection) bool {
        return is_baseline_alignment(self.align_self) and
            !self.margin_is_auto.cross_start(dir) and
            !self.margin_is_auto.cross_end(dir);
    }
};

/// A line of [`FlexItem`] used for intermediate computation
pub const FlexLine = struct {
    /// The slice of items to iterate over during computation of this line
    items: []FlexItem,
    /// The dimensions of the cross-axis
    cross_size: f32,
    /// The relative offset of the cross-axis
    offset_cross: f32,
};

/// Values that can be cached during the flexbox algorithm
pub const AlgoConstants = struct {
    /// The direction of the current segment being laid out
    dir: flex.FlexDirection,
    /// The layout direction of the current segment being laid out
    layout_direction: style.Direction,
    /// Is this segment a row
    is_row: bool,
    /// Is this segment a column
    is_column: bool,
    /// Is wrapping enabled (in either direction)
    is_wrap: bool,
    /// Is the wrap direction inverted
    is_wrap_reverse: bool,
    /// Are items balanced across lines (`flex-wrap: balance`)?
    is_balance: bool,
    /// The requested minimum number of lines (`flex-line-count`). `Some` for every
    /// multi-line container, `None` for `nowrap`.
    line_count: ?u16,

    /// The item's min_size style
    min_size: Size(?f32),
    /// The item's max_size style
    max_size: Size(?f32),
    /// The margin of this section
    margin: Rect(f32),
    /// The border of this section
    border: Rect(f32),
    /// The space between the content box and the border box.
    /// This consists of padding + border + scrollbar_gutter.
    content_box_inset: Rect(f32),
    /// The size reserved for scrollbar gutters in each axis
    scrollbar_gutter: Point(f32),
    /// Whether the node being laid out is a scroll container
    is_scroll_container: bool,
    /// The gap of this section
    gap: Size(f32),
    /// The align_items property of this node
    align_items: style.alignment.AlignItems,
    /// The align_content property of this node
    align_content: style.alignment.AlignContent,
    /// The justify_content property of this node
    justify_content: ?style.alignment.JustifyContent,

    /// The border-box size of the node being laid out (if known)
    node_outer_size: Size(?f32),
    /// The content-box size of the node being laid out (if known)
    node_inner_size: Size(?f32),
    /// Whether the known main size of the node (if any) is definite. This is `false` when a parent
    /// imposes a main size on this node that is derived from the node's own content, in which case
    /// it is indefinite for the purposes of resolving percentage sizes of items and collecting items
    /// into flex lines. See <https://www.w3.org/TR/css-flexbox-1/#definite-sizes>.
    known_main_size_is_definite: bool,
    /// Whether the node has a known main size which is definite (as of the start of layout,
    /// before the main size is determined from the node's contents)
    has_definite_main_size: bool,
    /// Whether the node has a known cross size which is definite
    has_definite_cross_size: bool,
    /// Whether the cross-axis space that non-stretched items are fit-content sized into is
    /// definite (either the node's cross size is definite, or the cross-axis available space is).
    cross_axis_available_space_is_definite: bool,

    /// The size of the virtual container containing the flex items.
    container_size: Size(f32),
    /// The size of the internal container
    inner_container_size: Size(f32),

    /// When a multi-line container requests a minimum number of lines (`flex-line-count`),
    /// definite cross-axis available space for measuring items is divided between the requested
    /// number of lines (after subtracting the cross-axis gaps between them).
    /// See <https://github.com/w3c/csswg-drafts/issues/13414>
    pub inline fn divided_cross_space(self: AlgoConstants, cross_available_space: f32) f32 {
        if (self.line_count) |line_count| {
            if (line_count > 1) {
                const count: f32 = @floatFromInt(line_count);
                return (cross_available_space - (count - 1.0) * self.gap.cross(self.dir)) / count;
            }
        }
        return cross_available_space;
    }
};

/// Computes the layout of a box according to the flexbox algorithm
pub fn compute_flexbox_layout(comptime Tree: type, tree_ref: *Tree, node_id: NodeId, inputs: layout.LayoutInput) !layout.LayoutOutput {
    const TreeApi = LayoutTree(Tree);
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;
    const node_style = TreeApi.get_style(tree_ref, node_id);

    // Pull these out earlier to avoid borrowing issues
    const contain = node_style.contain;
    const aspect_ratio = node_style.aspect_ratio;
    const padding = resolve_length_rect(node_style.padding, parent_size.width);
    const border = resolve_length_rect(node_style.border, parent_size.width);
    const padding_border_sum = padding.sum_axes().add(border.sum_axes());
    const box_sizing_adjustment = if (node_style.box_sizing == .content_box) padding_border_sum else geometry.SIZE_F32_ZERO;

    const min_size = size_maybe_add(
        resolve_auto_size(node_style.min_size, parent_size).maybe_apply_aspect_ratio(aspect_ratio),
        box_sizing_adjustment);
    const max_size = size_maybe_add(
        resolve_auto_size(node_style.max_size, parent_size).maybe_apply_aspect_ratio(aspect_ratio),
        box_sizing_adjustment);
    const clamped_style_size = if (inputs.sizing_mode == .inherent_size)
        math.optional_size_maybe_clamp(
            size_maybe_add(
                resolve_dimension_size(node_style.size, parent_size).maybe_apply_aspect_ratio(aspect_ratio),
                box_sizing_adjustment),
            min_size,
            max_size)
    else
        geometry.SIZE_OPTIONAL_F32_NONE;

    // If both min and max in a given axis are set and max <= min then this determines the size in that axis
    const min_max_definite_size = Size(?f32){
        .width = if (min_size.width) |min| (if (max_size.width) |max| (if (max <= min) min else null) else null) else null,
        .height = if (min_size.height) |min| (if (max_size.height) |max| (if (max <= min) min else null) else null) else null,
    };

    // The size of the container should be floored by the padding and border
    const styled_based_known_dimensions = optional_size_or(
        known_dimensions,
        math.optional_size_maybe_max(optional_size_or(min_max_definite_size, clamped_style_size), to_optional_size(padding_border_sum)));

    // Short-circuit layout if the container's size is fully determined by the container's size and the run mode
    // is ComputeSize (and thus the container's size is all that we're interested in)
    if (inputs.run_mode == .compute_size) {
        if (styled_based_known_dimensions.width) |width| {
            if (styled_based_known_dimensions.height) |height| {
                return layout.LayoutOutput.from_outer_size(.{ .width = width, .height = height });
            }
        }

        // We can also short-circuit if the width is known and only the width has been requested.
        if (inputs.axis == .horizontal) {
            if (styled_based_known_dimensions.width) |width| {
                return layout.LayoutOutput.from_outer_size(.{ .width = width, .height = 0.0 });
            }
        }
    }

    // Short-circuit layout if the container's size is fully determined by the container's size and the run mode
    // is ComputeSize (and thus the container's size is all that we're interested in)
    if (inputs.run_mode == .compute_size) {
        if (styled_based_known_dimensions.width) |width| {
            if (styled_based_known_dimensions.height) |height| {
                return layout.LayoutOutput.from_outer_size(.{ .width = width, .height = height });
            }
        }
    }

    // Normalize the definiteness flags: they only apply to dimensions which were passed in as known
    // by the parent. Dimensions resolved from the node's own style are always definite.
    const known_dimensions_are_definite = inputs.known_dimensions_are_definite.zip_map(known_dimensions, bool, normalize_definiteness);

    var output = try compute_preliminary(
        Tree,
        tree_ref,
        node_id,
        layout.LayoutInput{
            .known_dimensions = styled_based_known_dimensions,
            .known_dimensions_are_definite = known_dimensions_are_definite,
            .run_mode = inputs.run_mode,
            .sizing_mode = inputs.sizing_mode,
            .axis = inputs.axis,
            .parent_size = inputs.parent_size,
            .available_space = inputs.available_space,
            .vertical_margins_are_collapsible = inputs.vertical_margins_are_collapsible,
        });

    // Layout containment suppresses the box's baseline for baseline-alignment purposes
    if (contain.suppresses_baseline()) {
        output.baselines = layout.Baselines.NONE;
    }

    return output;
}

/// Compute a preliminary size for an item
fn compute_preliminary(comptime Tree: type, tree_ref: *Tree, node_id: NodeId, inputs: layout.LayoutInput) !layout.LayoutOutput {
    const TreeApi = LayoutTree(Tree);
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;
    const node_style = TreeApi.get_style(tree_ref, node_id);

    // Define some general constants we will need for the remainder of the algorithm.
    var constants = try compute_constants(
        Tree,
tree_ref,
        node_style,
        known_dimensions,
        inputs.known_dimensions_are_definite,
        parent_size,
        inputs.available_space);

    // 9. Flex Layout Algorithm

    // 9.1. Initial Setup

    // 1. Generate anonymous flex items as described in §4 Flex Items.
    var has_hidden_children = false;
    var flex_items = try generate_anonymous_flex_items(Tree, tree_ref, node_id, &constants, &has_hidden_children);
    defer flex_items.deinit(TreeApi.scratch_allocator(tree_ref));

    // 9.2. Line Length Determination

    // 2. Determine the available main and cross space for the flex items
    const available_space = determine_available_space(known_dimensions, inputs.available_space, &constants);

    // 3. Determine the flex base size and hypothetical main size of each item.
    try determine_flex_base_size(Tree, tree_ref, &constants, available_space, flex_items.items);

    // 4. Determine the main size of the flex container
    // This has already been done as part of compute_constants. The inner size is exposed as constants.node_inner_size.

    // 9.3. Main Size Determination

    // 5. Collect flex items into flex lines.
    const scratch = TreeApi.scratch_allocator(tree_ref);
    var flex_lines = if (constants.is_balance)
        try collect_balanced_flex_lines(scratch, &constants, available_space, flex_items.items)
    else
        try collect_flex_lines(scratch, &constants, available_space, flex_items.items);
    defer scratch.free(flex_lines);

    // If container size is undefined, determine the container's main size
    // and then re-resolve gaps based on newly determined size
    if (constants.node_inner_size.main(constants.dir)) |inner_main_size| {
        const outer_main_size = inner_main_size + constants.content_box_inset.main_axis_sum(constants.dir);
        constants.inner_container_size.set_main(constants.dir, inner_main_size);
        constants.container_size.set_main(constants.dir, outer_main_size);
    } else {
        // Sets constants.container_size and constants.outer_container_size
        try determine_container_main_size(Tree, tree_ref, available_space, flex_lines, &constants);
        constants.node_inner_size.set_main(constants.dir, constants.inner_container_size.main(constants.dir));
        constants.node_outer_size.set_main(constants.dir, constants.container_size.main(constants.dir));

        // Re-resolve percentage gaps
        const inner_container_size = constants.inner_container_size.main(constants.dir);
        const new_gap = node_style.gap.main(constants.dir).resolve_to_option(inner_container_size) orelse 0.0;
        constants.gap.set_main(constants.dir, new_gap);
    }

    // 6. Resolve the flexible lengths of all the flex items to find their used main size.
    for (flex_lines) |*line| {
        resolve_flexible_lengths(line, &constants);
    }

    // 9.4. Cross Size Determination

    // 7. Determine the hypothetical cross size of each item.
    for (flex_lines) |*line| {
        try determine_hypothetical_cross_size(Tree, tree_ref, line, &constants, available_space);
    }

    // Calculate child baselines. This function is internally smart and only computes child baselines
    // if they are necessary.
    try calculate_children_base_lines(Tree, tree_ref, known_dimensions, available_space, flex_lines, &constants);

    // 8. Calculate the cross size of each flex line.
    calculate_cross_size(flex_lines, known_dimensions, &constants);

    // 9. Handle 'align-content: stretch'.
    handle_align_content_stretch(flex_lines, known_dimensions, &constants);

    // 10. Collapse visibility:collapse items. If any flex items have visibility: collapse,
    //     note the cross size of the line they're in as the item's strut size, and restart
    //     layout from the beginning.
    //
    //     In this second layout round, when collecting items into lines, treat the collapsed
    //     items as having zero main size. For the rest of the algorithm following that step,
    //     ignore the collapsed items entirely (as if they were display:none) except that after
    //     calculating the cross size of the lines, if any line's cross size is less than the
    //     largest strut size among all the collapsed items in the line, set its cross size to
    //     that strut size.
    //
    //     Skip this step in the second layout round.

    // TODO implement once (if ever) we support visibility:collapse

    // 11. Determine the used cross size of each flex item.
    try determine_used_cross_size(Tree, tree_ref, flex_lines, &constants);

    // 9.5. Main-Axis Alignment

    // 12. Distribute any remaining free space.
    distribute_remaining_free_space(flex_lines, &constants);

    // 9.6. Cross-Axis Alignment

    // 13. Resolve cross-axis auto margins (also includes 14).
    resolve_cross_axis_auto_margins(flex_lines, &constants);

    // 15. Determine the flex container's used cross size.
    const total_line_cross_size = determine_container_cross_size(flex_lines, known_dimensions, &constants);

    // We have the container size.
    // If our caller does not care about performing layout we are done now.
    if (inputs.run_mode == .compute_size) {
        return layout.LayoutOutput.from_outer_size(constants.container_size);
    }

    // 16. Align all flex lines per align-content.
    align_flex_lines_per_align_content(flex_lines, &constants, total_line_cross_size);

    // Do a final layout pass and gather the resulting layouts
    const inflow_overflow_rect = try final_layout_pass(Tree, tree_ref, flex_lines, &constants);

    // Collect out-of-flow candidates in document order (direct out-of-flow children
    // interleaved with candidates bubbled from in-flow children's subtrees). These are
    // laid out by the out-of-flow positioning pass (`oof.compute_oof_layout`), which runs
    // after this algorithm.
    var candidates: layout.OofCandidates = .empty;
    try collect_oof_candidates(Tree, tree_ref, node_id, &constants, flex_lines, &candidates);

    const absolute_position_inset = constants.border.add(Rect(f32){
        .left = if (constants.layout_direction.is_rtl()) constants.scrollbar_gutter.x else 0.0,
        .right = if (constants.layout_direction.is_rtl()) 0.0 else constants.scrollbar_gutter.x,
        .top = 0.0,
        .bottom = constants.scrollbar_gutter.y,
    });

    if (has_hidden_children) {
        const len = try TreeApi.child_count(tree_ref, node_id);
        var hidden_order: usize = 0;
        while (hidden_order < len) : (hidden_order += 1) {
            const child = try TreeApi.child_at(tree_ref, node_id, hidden_order);
            const hidden_style = TreeApi.get_style(tree_ref, child);
            if (hidden_style.box_generation_mode() == .none) {
                try TreeApi.set_unrounded_layout(tree_ref, child, layout.Layout.with_order(@intCast(hidden_order)));
                _ = try TreeApi.perform_child_layout(tree_ref, 
                    child,
                    SIZE_NONE,
                    SIZE_NONE,
                    .{ .width = .max_content, .height = .max_content },
                    .content_size,
                    LINE_FALSE);
            }
        }
    }

    // 8.5. Flex Container Baselines: calculate the flex container's first baseline
    // See https://www.w3.org/TR/css-flexbox-1/#flex-baselines
    // The baselines are generated from the startmost flex line, where "startmost" refers to the
    // line's visual position: for wrap-reverse containers the cross axis is flipped, so the
    // startmost line is the last line in flex-line order rather than the first.
    const first_line: ?*FlexLine = if (constants.is_wrap_reverse)
        (if (flex_lines.len > 0) &flex_lines[flex_lines.len - 1] else null)
    else
        (if (flex_lines.len > 0) &flex_lines[0] else null);
    const first_vertical_baseline: ?f32 = if (first_line) |line| blk: {
        if (constants.is_column) {
            // For column containers the baseline is generated from the startmost item in the line,
            // which for reverse-direction containers is the last item in flex order.
            const item: ?*const FlexItem = if (constants.dir.is_reverse())
                (if (line.items.len > 0) &line.items[line.items.len - 1] else null)
            else
                (if (line.items.len > 0) &line.items[0] else null);
            break :blk if (item) |child| child.baseline else null;
        } else {
            var found: ?*const FlexItem = null;
            for (line.items) |*item| {
                if (item.participates_in_baseline_alignment(constants.dir)) {
                    found = item;
                    break;
                }
            }
            if (found == null and line.items.len > 0) found = &line.items[0];
            break :blk if (found) |child| child.baseline else null;
        }
    } else null;

    return .{
        .size = constants.container_size,
        .scrollable_overflow_rect = inflow_overflow_rect,
        .baselines = layout.Baselines.from_first(first_vertical_baseline),
        .oof_candidates = candidates,
        .oof_positioning_area = .{
            .size = constants.container_size.sub(absolute_position_inset.sum_axes()),
            .offset = .{ .x = absolute_position_inset.left, .y = absolute_position_inset.top },
        },
    };
}

/// Emit out-of-flow (`position: absolute` / `position: fixed`) children as
/// candidates for the out-of-flow positioning pass, in document order.
///
/// Direct out-of-flow children and candidates bubbled out of in-flow children's
/// subtrees are interleaved by child index, which keeps the containing block's
/// hoisted-children list in document order.
fn collect_oof_candidates(comptime Tree: type, tree_ref: *Tree,
    node: NodeId,
    constants: *const AlgoConstants,
    flex_lines: []FlexLine,
    candidates: *layout.OofCandidates) !void {
    const TreeApi = LayoutTree(Tree);
    const scratch = TreeApi.scratch_allocator(tree_ref);

    const dir = constants.dir;
    const container_size = constants.container_size;
    const content_box_inset = constants.content_box_inset;

    const main_axis_is_horizontal = constants.is_row;
    const cross_axis_is_horizontal = !constants.is_row;
    const main_is_rtl = main_axis_is_horizontal and constants.layout_direction.is_rtl();
    const cross_is_rtl = cross_axis_is_horizontal and constants.layout_direction.is_rtl();
    const main_axis_flex_start_reversed = dir.is_reverse() != main_is_rtl;
    const cross_axis_flex_start_reversed = constants.is_wrap_reverse != cross_is_rtl;

    // The static-position area in each axis is the container's content box
    const main_area = geometry.Line(f32){
        .start = content_box_inset.main_start(dir),
        .end = container_size.main(dir) - content_box_inset.main_end(dir),
    };
    const cross_area = geometry.Line(f32){
        .start = content_box_inset.cross_start(dir),
        .end = container_size.cross(dir) - content_box_inset.cross_end(dir),
    };

    // Flex lines are contiguous slices of the items in document order (reversal is
    // applied to positions, not storage), so a single monotonically advancing cursor
    // visits every in-flow item exactly once, in child-index order.
    var line_index: usize = 0;
    var item_index: usize = 0;
    while (line_index < flex_lines.len and flex_lines[line_index].items.len == 0) line_index += 1;

    const child_count = try TreeApi.child_count(tree_ref, node);
    var order: usize = 0;
    while (order < child_count) : (order += 1) {
        const child = try TreeApi.child_at(tree_ref, node, order);
        const child_style = TreeApi.get_style(tree_ref, child);
        const position = child_style.position;

        if (child_style.box_generation_mode() == .none) continue;
        // In-flow item: merge the candidates bubbled out of its subtree
        if (!position.is_out_of_flow()) {
            if (line_index < flex_lines.len) {
                const line = &flex_lines[line_index];
                if (item_index < line.items.len and line.items[item_index].order == @as(u32, @intCast(order))) {
                    try oof.appendCandidates(scratch, candidates, &line.items[item_index].oof_candidates);
                    item_index += 1;
                    if (item_index >= line.items.len) {
                        line_index += 1;
                        item_index = 0;
                        while (line_index < flex_lines.len and flex_lines[line_index].items.len == 0) line_index += 1;
                    }
                }
            }
            continue;
        }

        const align_self = resolve_self_relative(
            child_style.align_self orelse constants.align_items,
            child_style.direction,
            constants.layout_direction,
            constants.is_column);

        // Main-axis static position (justify-content).
        //
        // Stretch is an invalid value for justify_content in the flexbox algorithm, so we
        // treat it as if it wasn't set (and thus we default to FlexStart behaviour).
        //
        // The `safe` overflow-position keyword is intentionally NOT applied here, even when
        // the abs-positioned item would overflow the main axis: Chrome does not apply safe
        // fallback to `justify-content` on absolutely-positioned flex items (only the
        // cross-axis `align-self` does so). Matching the layout authority over a strict
        // spec read keeps gentest fixtures green; reconsider if Chromium changes behavior.
        //
        // `start`/`end` are writing-mode relative (they flip for RTL but not for
        // reversed flex-directions), whereas `flex-start`/`flex-end` and the
        // distributed keywords' fallbacks are flex-relative.
        const main_keyword = (constants.justify_content orelse style.alignment.JustifyContent.FLEX_START).keyword_value();
        const main_start_position = switch (main_keyword) {
            .start => !main_is_rtl,
            .end => main_is_rtl,
            else => true,
        };
        const main_edge: layout.AxisStaticEdge = switch (main_keyword) {
            .space_between, .stretch, .flex_start => if (!main_axis_flex_start_reversed) .start else .end,
            .flex_end => if (main_axis_flex_start_reversed) .start else .end,
            .start, .end => if (main_start_position) .start else .end,
            .space_evenly, .space_around, .center => .center,
        };

        // Cross-axis static position (align-self).
        //
        // `start`/`end` (and `baseline`, whose static-position fallback is `start`) are
        // writing-mode relative: they flip for RTL but not for `wrap-reverse`.
        // `flex-start`/`flex-end` and the `stretch` fallback are flex-relative.
        const cross = layout.AxisStaticAlign{
            .keyword = crossEdgeFor(align_self.keyword, cross_axis_flex_start_reversed, cross_is_rtl),
            .safety = align_self.safety,
            .fallback = crossEdgeFor(alignment_common.resolve_self_alignment_safety(align_self, true), cross_axis_flex_start_reversed, cross_is_rtl),
        };
        const main = layout.AxisStaticAlign.from_keyword(main_edge);

        const static_position = if (constants.is_row)
            Point(layout.AxisStaticPosition){
                .x = .{ .area = main_area, .alignment = main },
                .y = .{ .area = cross_area, .alignment = cross },
            }
        else
            Point(layout.AxisStaticPosition){
                .x = .{ .area = cross_area, .alignment = cross },
                .y = .{ .area = main_area, .alignment = main },
            };
        try candidates.append(scratch, .{
            .node = child,
            .order = @intCast(order),
            .position = position,
            .static_position = static_position,
        });
    }
}

/// Resolve a resolved `align-self` keyword to the physical edge used for an
/// out-of-flow box's static position, honouring flex-relative vs writing-mode
/// relative alignment and `wrap-reverse`.
fn crossEdgeFor(keyword: style.alignment.AlignItemsKeyword, cross_axis_flex_start_reversed: bool, cross_is_rtl: bool) layout.AxisStaticEdge {
    const start_position = switch (keyword) {
        .start, .baseline => !cross_is_rtl,
        .end => cross_is_rtl,
        else => true,
    };
    return switch (keyword) {
        // Stretch alignment does not apply to absolutely positioned items
        // See "Example 3" at https://www.w3.org/TR/css-flexbox-1/#abspos-items
        .start, .end, .baseline => if (start_position) .start else .end,
        .stretch, .flex_start => if (!cross_axis_flex_start_reversed) .start else .end,
        .flex_end => if (cross_axis_flex_start_reversed) .start else .end,
        .center => .center,
        // SelfStart/SelfEnd are resolved to Start/End against the item's own
        // direction where `align_self` is read.
        .self_start, .self_end => unreachable,
    };
}

/// Compute constants that can be reused during the flexbox algorithm.
inline fn compute_constants(comptime Tree: type, tree_ref: *Tree,
    node_style: *const style.Style,
    known_dimensions: Size(?f32),
    known_dimensions_are_definite: Size(bool),
    parent_size: Size(?f32),
    available_space: Size(AvailableSpace)) !AlgoConstants {
    _ = tree_ref;
    const dir = node_style.flex_direction;
    const is_row = dir.is_row();
    const is_column = dir.is_column();
    const flex_wrap = node_style.flex_wrap;
    const is_wrap = flex_wrap.is_multi_line();
    const is_wrap_reverse = flex_wrap.is_reverse();
    const is_balance = flex_wrap.is_balance();
    const line_count: ?u16 = if (is_wrap) @max(node_style.flex_line_count, 1) else null;

    const aspect_ratio = node_style.aspect_ratio;
    const margin = resolve_auto_rect(node_style.margin, parent_size.width);
    const padding = resolve_length_rect(node_style.padding, parent_size.width);
    const border = resolve_length_rect(node_style.border, parent_size.width);
    const padding_border_sum = padding.sum_axes().add(border.sum_axes());
    const box_sizing_adjustment = if (node_style.box_sizing == .content_box) padding_border_sum else geometry.SIZE_F32_ZERO;

    const align_items = node_style.align_items orelse style.alignment.AlignItems.STRETCH;
    const align_content = node_style.align_content orelse style.alignment.AlignContent.STRETCH;
    const justify_content = node_style.justify_content;
    const layout_direction = node_style.direction;

    // Scrollbar gutters are reserved when the `overflow` property is set to `Overflow::Scroll`.
    // However, the axis are switched (transposed) because a node that scrolls vertically needs
    // *horizontal* space to be reserved for a scrollbar
    const transposed_overflow = node_style.overflow.transpose();
    const scrollbar_gutter = Point(f32){
        .x = if (transposed_overflow.x == .scroll) node_style.scrollbar_width else 0.0,
        .y = if (transposed_overflow.y == .scroll) node_style.scrollbar_width else 0.0,
    };
    const is_scroll_container = node_style.overflow.x.is_scroll_container() or node_style.overflow.y.is_scroll_container();
    var content_box_inset = padding.add(border);
    content_box_inset.bottom += scrollbar_gutter.y;

    switch (layout_direction) {
        .ltr => content_box_inset.right += scrollbar_gutter.x,
        .rtl => content_box_inset.left += scrollbar_gutter.x,
    }

    const node_outer_size = known_dimensions;
    const node_inner_size = math.optional_size_maybe_sub(node_outer_size, to_optional_size(content_box_inset.sum_axes()));
    const known_main_size_is_definite = known_dimensions_are_definite.main(dir);
    const has_definite_main_size = known_main_size_is_definite and known_dimensions.main(dir) != null;
    const has_definite_cross_size = known_dimensions_are_definite.cross(dir) and known_dimensions.cross(dir) != null;
    const cross_axis_available_space_is_definite = has_definite_cross_size or available_space.cross(dir).is_definite();
    const gap = Size(f32){
        .width = node_style.gap.width.resolve(node_inner_size.width orelse 0),
        .height = node_style.gap.height.resolve(node_inner_size.height orelse 0),
    };

    const container_size = geometry.SIZE_F32_ZERO;
    const inner_container_size = geometry.SIZE_F32_ZERO;

    return AlgoConstants{
        .dir = dir,
        .layout_direction = layout_direction,
        .is_row = is_row,
        .is_column = is_column,
        .is_wrap = is_wrap,
        .is_wrap_reverse = is_wrap_reverse,
        .is_balance = is_balance,
        .line_count = line_count,
        .min_size = size_maybe_add(
            resolve_auto_size(node_style.min_size, parent_size).maybe_apply_aspect_ratio(aspect_ratio),
            box_sizing_adjustment),
        .max_size = size_maybe_add(
            resolve_auto_size(node_style.max_size, parent_size).maybe_apply_aspect_ratio(aspect_ratio),
            box_sizing_adjustment),
        .margin = margin,
        .border = border,
        .gap = gap,
        .content_box_inset = content_box_inset,
        .scrollbar_gutter = scrollbar_gutter,
        .is_scroll_container = is_scroll_container,
        .align_items = align_items,
        .align_content = align_content,
        .justify_content = justify_content,
        .node_outer_size = node_outer_size,
        .node_inner_size = node_inner_size,
        .known_main_size_is_definite = known_main_size_is_definite,
        .has_definite_main_size = has_definite_main_size,
        .has_definite_cross_size = has_definite_cross_size,
        .cross_axis_available_space_is_definite = cross_axis_available_space_is_definite,
        .container_size = container_size,
        .inner_container_size = inner_container_size,
    };
}

/// Resolve a `position: relative` item's inset to a single offset in the container's flex
/// axes, accounting for flex direction and writing direction. Every input is fixed before
/// items are generated, so this is resolved once at item-generation time rather than being
/// recomputed per item in `calculate_flex_item`.
fn resolve_relative_inset(inset: Rect(?f32), constants: *const AlgoConstants) F32Size {
    const direction = constants.dir;
    const is_rtl_row = direction.is_row() and constants.layout_direction.is_rtl();
    const is_rtl_column = direction.is_column() and constants.layout_direction.is_rtl();
    const main: f32 = if (is_rtl_row)
        (inset.main_end(direction) orelse (if (inset.main_start(direction)) |pos| -pos else null)) orelse 0.0
    else
        (inset.main_start(direction) orelse (if (inset.main_end(direction)) |pos| -pos else null)) orelse 0.0;
    const cross: f32 = if (is_rtl_column)
        ((if (inset.cross_end(direction)) |pos| -pos else null) orelse inset.cross_start(direction)) orelse 0.0
    else
        (inset.cross_start(direction) orelse (if (inset.cross_end(direction)) |pos| -pos else null)) orelse 0.0;
    var out = geometry.SIZE_F32_ZERO;
    out.set_main(direction, main);
    out.set_cross(direction, cross);
    return out;
}

/// Generate anonymous flex items.
///
/// # [9.1. Initial Setup](https://www.w3.org/TR/css-flexbox-1/#box-manip)
///
/// - [**Generate anonymous flex items**](https://www.w3.org/TR/css-flexbox-1/#algo-anon-box) as described in [§4 Flex Items](https://www.w3.org/TR/css-flexbox-1/#flex-items).
inline fn generate_anonymous_flex_items(comptime Tree: type, tree_ref: *Tree, node_id: NodeId, constants: *const AlgoConstants, has_hidden_children: *bool) !std.ArrayList(FlexItem) {
    const TreeApi = LayoutTree(Tree);
    // Percentage sizes of items resolve against the container's inner size, but only if that size
    // is definite. A known main size which is derived from the container's own content is treated
    // as indefinite here.
    const percent_resolution_size = if (constants.known_main_size_is_definite)
        constants.node_inner_size
    else
        constants.node_inner_size.with_main(constants.dir, null);

    const allocator = TreeApi.scratch_allocator(tree_ref);
    var items = std.ArrayList(FlexItem).empty;
    errdefer items.deinit(allocator);
    // Every in-flow child produces one flex item; reserve once so the list
    // never has to grow (and copy) through the scratch arena.
    try items.ensureTotalCapacity(allocator, try TreeApi.child_count(tree_ref, node_id));

    const child_ids = try TreeApi.child_ids(tree_ref, node_id);
    for (child_ids, 0..) |child, index| {
        const child_style = TreeApi.get_style(tree_ref, child);
        // The hidden post-pass (below) visits every `display: none` child,
        // including absolutely positioned ones, so record the flag before the
        // absolute check.
        if (child_style.box_generation_mode() == .none) {
            has_hidden_children.* = true;
            continue;
        }
        if (child_style.position.is_out_of_flow()) continue;

        const aspect_ratio = child_style.aspect_ratio;
        const padding = resolve_length_rect(child_style.padding, constants.node_inner_size.width);
        const border = resolve_length_rect(child_style.border, constants.node_inner_size.width);
        const pb_sum = padding.sum_axes().add(border.sum_axes());
        const box_sizing_adjustment = if (child_style.box_sizing == .content_box) pb_sum else geometry.SIZE_F32_ZERO;

        try items.append(allocator, FlexItem{
            .node = child,
            .order = @intCast(index),
            .size = size_maybe_add(
                resolve_dimension_size(child_style.size, percent_resolution_size).maybe_apply_aspect_ratio(aspect_ratio),
                box_sizing_adjustment),
            .size_style = child_style.size,
            .min_size = size_maybe_add(
                resolve_auto_size(child_style.min_size, percent_resolution_size),
                box_sizing_adjustment),
            .max_size = size_maybe_add(
                resolve_auto_size(child_style.max_size, percent_resolution_size),
                box_sizing_adjustment),
            .aspect_ratio = aspect_ratio,

            .relative_inset = if (child_style.position == .relative)
                resolve_relative_inset(
                    resolve_auto_rect_size_to_option(child_style.inset, constants.node_inner_size),
                    constants)
            else
                geometry.SIZE_F32_ZERO,
            .margin = resolve_auto_rect(child_style.margin, constants.node_inner_size.width),
            .margin_is_auto = auto_rect(child_style.margin),
            .padding = padding,
            .border = border,
            .align_self = resolve_self_relative(
                child_style.align_self orelse constants.align_items,
                child_style.direction,
                constants.layout_direction,
                constants.is_column),
            .overflow = child_style.overflow,
            .contain = child_style.contain,
            .scrollbar_width = child_style.scrollbar_width,
            .flex_grow = child_style.flex_grow,
            .flex_shrink = child_style.flex_shrink,
            .flex_basis_is_definite = false,
            .flex_basis = 0.0,
            .inner_flex_basis = 0.0,
            .violation = 0.0,
            .frozen = false,

            .resolved_minimum_main_size = 0.0,
            .hypothetical_inner_size = geometry.SIZE_F32_ZERO,
            .hypothetical_outer_size = geometry.SIZE_F32_ZERO,
            .target_size = geometry.SIZE_F32_ZERO,
            .outer_target_size = geometry.SIZE_F32_ZERO,
            .content_flex_fraction = 0.0,

            .baseline = 0.0,

            .offset_main = 0.0,
            .offset_cross = 0.0,

            .oof_candidates = .empty,
        });
    }
    return items;
}

/// Determine the available main and cross space for the flex items.
///
/// # [9.2. Line Length Determination](https://www.w3.org/TR/css-flexbox-1/#line-sizing)
///
/// - [**Determine the available main and cross space for the flex items**](https://www.w3.org/TR/css-flexbox-1/#algo-available).
///
/// For each dimension, if that dimension of the flex container's content box is a definite size, use that;
/// if that dimension of the flex container is being sized under a min or max-content constraint, the available space in that dimension is that constraint;
/// otherwise, subtract the flex container's margin, border, and padding from the space available to the flex container in that dimension and use that value.
/// **This might result in an infinite value**.
inline fn determine_available_space(
    known_dimensions: Size(?f32),
    outer_available_space: Size(AvailableSpace),
    constants: *const AlgoConstants) Size(AvailableSpace) {
    // Note: min/max/preferred size styles have already been applied to known_dimensions in the `compute` function above
    const width: AvailableSpace = if (known_dimensions.width) |node_width|
        .{ .definite = @max(node_width - constants.content_box_inset.horizontal_axis_sum(), 0.0) }
    else
        math.available_maybe_max(
            math.available_maybe_sub(
                math.available_maybe_sub(outer_available_space.width, constants.margin.horizontal_axis_sum()),
                constants.content_box_inset.horizontal_axis_sum()),
            0.0);

    const height: AvailableSpace = if (known_dimensions.height) |node_height|
        .{ .definite = @max(node_height - constants.content_box_inset.vertical_axis_sum(), 0.0) }
    else
        math.available_maybe_max(
            math.available_maybe_sub(
                math.available_maybe_sub(outer_available_space.height, constants.margin.vertical_axis_sum()),
                constants.content_box_inset.vertical_axis_sum()),
            0.0);

    return .{ .width = width, .height = height };
}

/// Determine the flex base size and hypothetical main size of each item.
///
/// # [9.2. Line Length Determination](https://www.w3.org/TR/css-flexbox-1/#line-sizing)
///
/// - [**Determine the flex base size and hypothetical main size of each item:**](https://www.w3.org/TR/css-flexbox-1/#algo-main-item)
///
///     - A. If the item has a definite used flex basis, that's the flex base size.
///
///     - B. If the flex item has an intrinsic aspect ratio, a used flex basis of content, and a definite cross size,
///       then the flex base size is calculated from its inner cross size and the flex item's intrinsic aspect ratio.
///
///     - C. If the used flex basis is content or depends on its available space, and the flex container is being sized
///       under a min-content or max-content constraint (e.g. when performing automatic table layout [CSS21]), size
///       the item under that constraint. The flex base size is the item's resulting main size.
///
///     - E. Otherwise, size the item into the available space using its used flex basis in place of its main size,
///       treating a value of content as max-content. If a cross size is needed to determine the main size and the
///       flex item's cross size is auto and not definite, in this calculation use fit-content as the flex item's
///       cross size. The flex base size is the item's resulting main size.
///
///   When determining the flex base size, the item's min and max main sizes are ignored (no clamping occurs).
///   Furthermore, the sizing calculations that floor the content box size at zero when applying box-sizing are also ignored.
///   (For example, an item with a specified size of zero, positive padding, and box-sizing: border-box will have an
///   outer flex base size of zero—and hence a negative inner flex base size.)
inline fn determine_flex_base_size(comptime Tree: type, tree_ref: *Tree,
    constants: *const AlgoConstants,
    available_space: Size(AvailableSpace),
    flex_items: []FlexItem) !void {
    const TreeApi = LayoutTree(Tree);
    const dir = constants.dir;

    for (flex_items) |*child| {
        const child_style = TreeApi.get_style(tree_ref, child.node);

        // Parent size for child sizing
        const cross_axis_parent_size = constants.node_inner_size.cross(dir);
        const child_parent_size = geometry.optional_f32_size_from_cross(dir, cross_axis_parent_size);

        // Available space for child sizing
        // Min/max sizes transferred through the aspect ratio are taken into account here
        // https://github.com/w3c/csswg-drafts/issues/10997
        const cross_axis_margin_sum = constants.margin.cross_axis_sum(dir);
        const transferred_min_size = child.min_size.maybe_apply_aspect_ratio(child.aspect_ratio);
        const transferred_max_size = child.max_size.maybe_apply_aspect_ratio(child.aspect_ratio);
        const child_min_cross = math.option_maybe_add(transferred_min_size.cross(dir), cross_axis_margin_sum);
        const child_max_cross = math.option_maybe_add(transferred_max_size.cross(dir), cross_axis_margin_sum);

        // Clamp available space by min- and max- size
        const cross_axis_available_space: AvailableSpace = switch (available_space.cross(dir)) {
            .definite => |val| .{ .definite = math.f32_maybe_clamp(
                constants.divided_cross_space(cross_axis_parent_size orelse val),
                child_min_cross,
                child_max_cross) },
            .min_content => if (child_min_cross) |min| AvailableSpace{ .definite = min } else .min_content,
            .max_content => if (child_max_cross) |max| AvailableSpace{ .definite = max } else .max_content,
        };

        // Known dimensions for child sizing
        var child_cross_size_is_definite = child.size.cross(dir) != null;
        var child_known_dimensions: Size(?f32) = child.size.with_main(dir, null);
        {
            // Clamp the definite cross size by the cross min/max sizes so that sizes
            // transferred through an intrinsic aspect ratio (e.g. for replaced elements)
            // are based on the used cross size.
            child_known_dimensions.set_cross(
                dir,
                math.option_maybe_clamp(
                    child_known_dimensions.cross(dir),
                    transferred_min_size.cross(dir),
                    transferred_max_size.cross(dir)));
            if (is_stretch_alignment(child.align_self) and
                !child.margin_is_auto.cross_start(constants.dir) and
                !child.margin_is_auto.cross_end(constants.dir) and
                child_known_dimensions.cross(dir) == null)
            {
                child_known_dimensions.set_cross(
                    dir,
                    math.maybe_max(
                        math.option_maybe_sub(
                            cross_axis_available_space.into_option(),
                            child.margin.cross_axis_sum(dir)),
                        0.0));
                // The cross size of a stretched item is definite if the container has a definite
                // cross size (https://www.w3.org/TR/css-flexbox-1/#definite-sizes)
                child_cross_size_is_definite =
                    !constants.is_wrap and constants.has_definite_cross_size and cross_axis_parent_size != null;
            }
        }

        // Percentage padding and border resolve against the container's inline size (its
        // width), whichever axis is the main axis.
        const container_width = constants.node_inner_size.width;
        const box_sizing_adjustment = if (child_style.box_sizing == .content_box) blk: {
            const padding = resolve_length_rect(child_style.padding, container_width);
            const border = resolve_length_rect(child_style.border, container_width);
            break :blk padding.sum_axes().add(border.sum_axes()).main(dir);
        } else 0.0;
        // Percentage flex basis values resolve against the container's inner main size, but only
        // if that size is definite. A known main size which is derived from the container's own
        // content is treated as indefinite here.
        const percent_resolution_main_size =
            if (constants.known_main_size_is_definite) constants.node_inner_size.main(dir) else null;
        const flex_basis_style = child_style.flex_basis;
        const resolved_flex_basis = math.maybe_add(
            flex_basis_style.resolve(percent_resolution_main_size),
            box_sizing_adjustment);

        child.flex_basis = flex_basis: {
            // A. If the item has a definite used flex basis, that's the flex base size.

            // B. If the flex item has an intrinsic aspect ratio, a used flex basis of content,
            //    and a definite cross size, then the flex base size is calculated from its inner
            //    cross size and the flex item's intrinsic aspect ratio.

            // Note: `child.size` has already been resolved against aspect_ratio in generate_anonymous_flex_items
            // So B will just work here by using main_size without special handling for aspect_ratio
            const main_size = child.size.main(dir);
            const main_stretch_size = math.maybe_max(
                math.option_maybe_sub(percent_resolution_main_size, child.margin.main_axis_sum(dir)),
                0.0);

            // A flex basis that is a sizing keyword (min-content, max-content, fit-content,
            // fit-content(...), stretch) is used in place of the main size property: `stretch`
            // resolves to an exact (definite) size while the other keywords determine the
            // available space constraint the item is measured under. A keyword that cannot be
            // resolved in the current context behaves as `content`.
            const keyword_main_available_space: ?AvailableSpace = if (flex_basis_style.is_content())
                // A flex basis of `content` indicates an automatic size based on the item's
                // content: the item is measured (ignoring its main size property) under the
                // default constraint below
                null
            else if (flex_basis_style.is_sizing_keyword()) blk: {
                const resolution = sizing_keyword.resolve_sizing_keyword(flex_basis_style, main_stretch_size, percent_resolution_main_size);
                if (resolution) |resolved| switch (resolved) {
                    .exact => |size| {
                        child.flex_basis_is_definite = true;
                        break :flex_basis size;
                    },
                    .measure => |available| break :blk available,
                };
                break :blk null;
            } else blk: {
                if (resolved_flex_basis orelse main_size) |basis| {
                    child.flex_basis_is_definite = true;
                    break :flex_basis basis;
                }

                // A main size that is a sizing keyword either resolves to an exact size or
                // determines the available space constraint the item is measured under
                const resolution = sizing_keyword.resolve_sizing_keyword(
                    child.size_style.main(dir),
                    main_stretch_size,
                    percent_resolution_main_size);
                if (resolution) |resolved| switch (resolved) {
                    .exact => |size| {
                        child.flex_basis_is_definite = true;
                        break :flex_basis size;
                    },
                    .measure => |available| break :blk available,
                };
                break :blk null;
            };

            // C. If the used flex basis is content or depends on its available space,
            //    and the flex container is being sized under a min-content or max-content
            //    constraint (e.g. when performing automatic table layout [CSS21]),
            //    size the item under that constraint. The flex base size is the item's
            //    resulting main size.

            // This is covered by the implementation of E below, which passes the available_space constraint
            // through to the child size computation.

            // D. Otherwise, if the used flex basis is content or depends on its
            //    available space, the available main size is infinite, and the flex item's
            //    inline axis is parallel to the main axis, lay the item out using the rules
            //    for a box in an orthogonal flow [CSS3-WRITING-MODES]. The flex base size
            //    is the item's max-content main size.

            // TODO if/when vertical writing modes are supported

            // If the item has an aspect ratio and a definite cross size then the flex base size
            // is calculated by transferring that cross size through the aspect ratio (case B
            // above), and is therefore definite.
            if (child_cross_size_is_definite) {
                if (child.aspect_ratio) |ratio| {
                    if (child_known_dimensions.cross(dir)) |cross| {
                        child.flex_basis_is_definite = true;
                        break :flex_basis if (dir.is_row()) cross * ratio else cross / ratio;
                    }
                }
            }

            // E. Otherwise, size the item into the available space using its used flex basis
            //    in place of its main size, treating a value of content as max-content.
            //    If a cross size is needed to determine the main size (e.g. when the
            //    flex item's main size is in its block axis) and the flex item's cross size
            //    is auto and not definite, in this calculation use fit-content as the
            //    flex item's cross size. The flex base size is the item's resulting main size.

            const main_space: AvailableSpace = keyword_main_available_space orelse
                // Map AvailableSpace::Definite to AvailableSpace::MaxContent
                (if (available_space.main(dir) == .min_content) AvailableSpace.min_content else AvailableSpace.max_content);

            var child_available_space = Size(AvailableSpace){ .width = .max_content, .height = .max_content };
            child_available_space.set_main(dir, main_space);
            child_available_space.set_cross(dir, cross_axis_available_space);

            break :flex_basis try TreeApi.measure_child_size(tree_ref, 
                child.node,
                child_known_dimensions,
                child_parent_size,
                child_available_space,
                .content_size,
                dir.main_axis(),
                LINE_FALSE);
        };

        // Floor flex-basis by the padding_border_sum (floors inner_flex_basis at zero)
        // This seems to be in violation of the spec which explicitly states that the content box should not be floored at zero
        // (like it usually is) when calculating the flex-basis. But including this matches both Chrome and Firefox's behaviour.
        //
        // TODO: resolve spec violation
        // Spec: https://www.w3.org/TR/css-flexbox-1/#intrinsic-item-contributions
        // Spec: https://www.w3.org/TR/css-flexbox-1/#change-2016-max-contribution
        const padding_border_sum = child.padding.main_axis_sum(constants.dir) + child.border.main_axis_sum(constants.dir);
        child.flex_basis = @max(child.flex_basis, padding_border_sum);

        // The hypothetical main size is the item's flex base size clamped according to its
        // used min and max main sizes (and flooring the content box size at zero).

        child.inner_flex_basis =
            child.flex_basis - child.padding.main_axis_sum(constants.dir) - child.border.main_axis_sum(constants.dir);

        const padding_border_axes_sums = to_optional_size(child.padding.add(child.border).sum_axes());

        // Note that it is important that the `parent_size` parameter in the main axis is not set for this
        // function call as it used for resolving percentages, and percentage size in an axis should not contribute
        // to a min-content contribution in that same axis. However the `parent_size` and `available_space` *should*
        // be set to their usual values in the cross axis so that wrapping content can wrap correctly.
        //
        // See https://drafts.csswg.org/css-sizing-3/#min-percentage-contribution
        const style_min_main_size = child.min_size.@"or"((Point(?f32){
            .x = child.overflow.x.maybe_into_automatic_min_size(),
            .y = child.overflow.y.maybe_into_automatic_min_size(),
        }).to_size()).main(dir);

        child.resolved_minimum_main_size = style_min_main_size orelse blk: {
            const min_content_main_size = blk2: {
                var child_available_space = Size(AvailableSpace){ .width = .min_content, .height = .max_content };
                child_available_space.set_cross(dir, cross_axis_available_space);

                break :blk2 try TreeApi.measure_child_size(tree_ref, 
                    child.node,
                    child_known_dimensions,
                    child_parent_size,
                    child_available_space,
                    .content_size,
                    dir.main_axis(),
                    LINE_FALSE);
            };

            // 4.5. Automatic Minimum Size of Flex Items
            // https://www.w3.org/TR/css-flexbox-1/#min-size-auto
            const clamped_min_content_size =
                math.f32_maybe_min(math.f32_maybe_min(min_content_main_size, child.size.main(dir)), transferred_max_size.main(dir));
            break :blk math.f32_maybe_max(clamped_min_content_size, padding_border_axes_sums.main(dir));
        };

        // Sizes transferred through the aspect ratio clamp the hypothetical main size,
        // but do not participate in resolving flexible lengths or clamping the final size.
        // https://github.com/w3c/csswg-drafts/issues/10997
        const hypothetical_inner_min_main = math.f32_maybe_max(
            math.f32_maybe_max(child.resolved_minimum_main_size, transferred_min_size.main(constants.dir)),
            padding_border_axes_sums.main(constants.dir));
        const hypothetical_inner_size =
            math.f32_maybe_clamp(child.flex_basis, hypothetical_inner_min_main, transferred_max_size.main(constants.dir));
        const hypothetical_outer_size = hypothetical_inner_size + child.margin.main_axis_sum(constants.dir);

        child.hypothetical_inner_size.set_main(constants.dir, hypothetical_inner_size);
        child.hypothetical_outer_size.set_main(constants.dir, hypothetical_outer_size);
    }
}

/// Collect flex items into flex lines.
///
/// # [9.3. Main Size Determination](https://www.w3.org/TR/css-flexbox-1/#main-sizing)
///
/// - [**Collect flex items into flex lines**](https://www.w3.org/TR/css-flexbox-1/#algo-line-break):
///
///     - If the flex container is single-line, collect all the flex items into a single flex line.
///
///     - Otherwise, starting from the first uncollected item, collect consecutive items one by one until the first time that the next collected item would not fit into the flex container's inner main size
///       (or until a forced break is encountered, see [§10 Fragmenting Flex Layout](https://www.w3.org/TR/css-flexbox-1/#pagination)).
///       If the very first uncollected item wouldn't fit, collect just it into the line.
///
///       For this step, the size of a flex item is its outer hypothetical main size. (**Note: This can be negative**.)
///
///       Repeat until all flex items have been collected into flex lines.
///
///       **Note that the "collect as many" line will collect zero-sized flex items onto the end of the previous line even if the last non-zero item exactly "filled up" the line**.
inline fn collect_flex_lines(
    allocator: std.mem.Allocator,
    constants: *const AlgoConstants,
    available_space: Size(AvailableSpace),
    flex_items: []FlexItem) ![]FlexLine {
    // Wrapping into multiple lines requires a definite main size. If the container's known main size
    // is derived from its own content (and is thus indefinite) then all items are collected into a
    // single flex line, matching how the container was sized under a min/max-content constraint.
    if (!constants.is_wrap or !constants.known_main_size_is_definite) {
        const lines = try allocator.alloc(FlexLine, 1);
        lines[0] = .{ .items = flex_items, .cross_size = 0.0, .offset_cross = 0.0 };
        return lines;
    }

    const main_axis_available_space: AvailableSpace = if (constants.max_size.main(constants.dir)) |max_size| blk: {
        const available = available_space.main(constants.dir).into_option() orelse max_size;
        // If the container's main size is not definite then it is at most the max main size,
        // so the max size (and not the available space) is the limit that items wrap against.
        const limited = if (constants.has_definite_main_size) available else @min(available, max_size);
        break :blk .{ .definite = math.f32_maybe_max(limited, constants.min_size.main(constants.dir)) };
    } else if (!constants.dir.is_row() and !constants.has_definite_main_size and available_space.main(constants.dir).is_definite())
        // A column container's automatic main size is content-based, so definite available space
        // handed down by an ancestor does not constrain where its lines wrap. Automatic widths
        // resolve against available space, so rows do wrap against it.
        AvailableSpace.max_content
    else
        available_space.main(constants.dir);

    switch (main_axis_available_space) {
        // If we're sizing under a max-content constraint then the flex items will never wrap
        // (at least for now - future extensions to the CSS spec may add provisions for forced wrap points)
        .max_content => {
            const lines = try allocator.alloc(FlexLine, 1);
            lines[0] = .{ .items = flex_items, .cross_size = 0.0, .offset_cross = 0.0 };
            return lines;
        },
        // If flex-wrap is Wrap and we're sizing under a min-content constraint, then we take every possible wrapping opportunity
        // and place each item in it's own line
        .min_content => {
            const lines = try allocator.alloc(FlexLine, flex_items.len);
            for (flex_items, 0..) |_, index| {
                lines[index] = .{ .items = flex_items[index .. index + 1], .cross_size = 0.0, .offset_cross = 0.0 };
            }
            return lines;
        },
        .definite => |main_axis_space| {
            var lines = std.ArrayList(FlexLine).empty;
            errdefer lines.deinit(allocator);
            var remaining = flex_items;
            const main_axis_gap = constants.gap.main(constants.dir);

            while (remaining.len > 0) {
                // Find index of the first item in the next line
                // (or the last item if all remaining items are in the current line)
                var line_length: f32 = 0.0;
                var index: usize = remaining.len;
                for (remaining, 0..) |child, idx| {
                    // Gaps only occur between items (not before the first one or after the last one)
                    // So first item in the line does not contribute a gap to the line length
                    const gap_contribution: f32 = if (idx == 0) 0.0 else main_axis_gap;
                    line_length += child.hypothetical_outer_size.main(constants.dir) + gap_contribution;
                    if (line_length > main_axis_space and idx != 0) {
                        index = idx;
                        break;
                    }
                }

                const line_items = remaining[0..index];
                try lines.append(allocator, .{ .items = line_items, .cross_size = 0.0, .offset_cross = 0.0 });
                remaining = remaining[index..];
            }
            return lines.toOwnedSlice(allocator);
        },
    }
}

/// Collect flex items into balanced flex lines (`flex-wrap: balance`), such that the largest
/// line is as small as possible.
///
/// See <https://drafts.csswg.org/css-flexbox-2/#balance-values>
fn collect_balanced_flex_lines(
    allocator: std.mem.Allocator,
    constants: *const AlgoConstants,
    available_space: Size(AvailableSpace),
    flex_items: []FlexItem) ![]FlexLine {
    if (flex_items.len == 0) {
        return allocator.alloc(FlexLine, 0);
    }

    // If the container's known main size is derived from its own content (and is thus indefinite)
    // then items are balanced without a size limit, matching how the container was sized under a
    // min/max-content constraint.
    const main_axis_available_space: AvailableSpace = if (constants.known_main_size_is_definite) blk: {
        if (constants.max_size.main(constants.dir)) |max_size| {
            const available = available_space.main(constants.dir).into_option() orelse max_size;
            // If the container's main size is not definite then it is at most the max main size,
            // so the max size (and not the available space) is the limit that items wrap against.
            const limited = if (constants.has_definite_main_size) available else @min(available, max_size);
            break :blk .{ .definite = math.f32_maybe_max(limited, constants.min_size.main(constants.dir)) };
        }
        // A column container's automatic main size is content-based, so definite available space
        // handed down by an ancestor does not constrain where its lines wrap. Automatic widths
        // resolve against available space, so rows do wrap against it.
        if (!constants.dir.is_row() and !constants.has_definite_main_size and available_space.main(constants.dir).is_definite()) {
            break :blk AvailableSpace.max_content;
        }
        break :blk available_space.main(constants.dir);
    } else AvailableSpace.max_content;

    // If we're sizing under a min-content constraint then we take every possible wrapping
    // opportunity and place each item in its own line, the same as greedy wrapping (the
    // min-content main size of a multi-line container is the size of its largest item)
    if (main_axis_available_space == .min_content) {
        const lines = try allocator.alloc(FlexLine, flex_items.len);
        for (flex_items, 0..) |_, index| {
            lines[index] = .{ .items = flex_items[index .. index + 1], .cross_size = 0.0, .offset_cross = 0.0 };
        }
        return lines;
    }

    const line_break_size = main_axis_available_space.into_option() orelse std.math.inf(f32);
    const min_line_count: usize = constants.line_count orelse 1;

    var item_sizes = try allocator.alloc(f32, flex_items.len);
    defer allocator.free(item_sizes);
    for (flex_items, 0..) |item, index| {
        item_sizes[index] = item.hypothetical_outer_size.main(constants.dir);
    }
    const item_counts = try balance.balanced_line_item_counts(
        allocator,
        item_sizes,
        line_break_size,
        constants.gap.main(constants.dir),
        min_line_count);
    defer allocator.free(item_counts);

    var lines = try allocator.alloc(FlexLine, item_counts.len);
    var remaining = flex_items;
    for (item_counts, 0..) |count, index| {
        const line_items = remaining[0..count];
        lines[index] = .{ .items = line_items, .cross_size = 0.0, .offset_cross = 0.0 };
        remaining = remaining[count..];
    }
    std.debug.assert(remaining.len == 0);
    return lines;
}

/// Compute whether each of an item's known dimensions should be treated as definite when performing
/// layout on the item. An item's post-flexing main size is only treated as definite if the container
/// has a definite main size or the item's used flex basis is definite.
/// See <https://www.w3.org/TR/css-flexbox-1/#definite-sizes>
inline fn item_known_dimension_definiteness(constants: *const AlgoConstants, item: *const FlexItem) Size(bool) {
    const dir = constants.dir;
    const main_is_definite = constants.has_definite_main_size or item.flex_basis_is_definite;

    // An item's cross size is definite if it is stretched (it stretches to the flex line, whose
    // size is known by the time the item's final layout is performed), or if its cross size style
    // resolved to a definite size. Additionally, a non-stretched item's cross *width* is fit-content
    // sized, and a size resolved by fit-content sizing against definite available space is itself
    // definite (<https://www.w3.org/TR/css-sizing-3/#definite>). The same does not apply to cross
    // heights, which are content-based and therefore indefinite when not stretched.

    const has_cross_auto_margins = item.margin_is_auto.cross_start(dir) or item.margin_is_auto.cross_end(dir);
    const cross_size = item.size_style.cross(dir);
    const is_stretched = !has_cross_auto_margins and
        (cross_size.is_stretch() or (is_stretch_alignment(item.align_self) and cross_size.is_auto()));
    const cross_is_definite = is_stretched or
        item.size.cross(dir) != null or
        (!dir.is_row() and constants.cross_axis_available_space_is_definite);

    var result = Size(bool){ .width = true, .height = true };
    result.set_main(dir, main_is_definite);
    result.set_cross(dir, cross_is_definite);
    return result;
}

/// Determine the container's main size (if not already known)
fn determine_container_main_size(comptime Tree: type, tree_ref: *Tree,
    available_space: Size(AvailableSpace),
    lines: []FlexLine,
    constants: *AlgoConstants) !void {
    const TreeApi = LayoutTree(Tree);
    const dir = constants.dir;
    const main_content_box_inset = constants.content_box_inset.main_axis_sum(constants.dir);

    const outer_main_size: f32 = constants.node_outer_size.main(constants.dir) orelse blk: {
        switch (available_space.main(dir)) {
            .definite => |main_axis_available_space| {
                const main_axis_gap = constants.gap.main(constants.dir);
                var longest_line_length: f32 = 0.0;
                for (lines) |*line| {
                    const line_main_axis_gap = sum_axis_gaps(main_axis_gap, line.items.len);
                    var total_target_size: f32 = 0.0;
                    for (line.items) |*item| total_target_size += item_main_length(item, constants);
                    longest_line_length = @max(longest_line_length, total_target_size + line_main_axis_gap);
                }
                const size = longest_line_length + main_content_box_inset;

                // A balanced container can produce multiple lines that all fit within the
                // available space (via `flex-line-count`), in which case fit-content sizing
                // uses its max-content size: the longest line when items are balanced across
                // the minimum line count without a size limit.
                if (constants.is_balance) {
                    const min_line_count = constants.line_count orelse 1;
                    var item_count: usize = 0;
                    for (lines) |line| item_count += line.items.len;
                    if (item_count == 0) break :blk size;
                    const scratch = TreeApi.scratch_allocator(tree_ref);
                    var item_lengths = try scratch.alloc(f32, item_count);
                    defer scratch.free(item_lengths);
                    var length_index: usize = 0;
                    for (lines) |line| {
                        for (line.items) |*item| {
                            item_lengths[length_index] = item_main_length(item, constants);
                            length_index += 1;
                        }
                    }
                    const item_counts = try balance.balanced_line_item_counts(
                        scratch,
                        item_lengths,
                        std.math.inf(f32),
                        main_axis_gap,
                        @max(min_line_count, 1));
                    defer scratch.free(item_counts);
                    var widest_line_length: f32 = 0.0;
                    var index: usize = 0;
                    for (item_counts) |count| {
                        var line_length: f32 = 0.0;
                        for (item_lengths[index .. index + count]) |length| line_length += length;
                        line_length += sum_axis_gaps(main_axis_gap, count);
                        widest_line_length = @max(widest_line_length, line_length);
                        index += count;
                    }
                    const max_content_size = widest_line_length + main_content_box_inset;
                    break :blk math.f32_max(size, math.f32_min(max_content_size, main_axis_available_space));
                }

                if (lines.len > 1) {
                    break :blk math.f32_max(size, main_axis_available_space);
                }
                break :blk size;
            },
            .min_content => {
                if (constants.is_wrap) {
                    var longest_line_length: f32 = 0.0;
                    for (lines) |*line| {
                        const line_main_axis_gap = sum_axis_gaps(constants.gap.main(constants.dir), line.items.len);
                        var total_target_size: f32 = 0.0;
                        for (line.items) |*item| total_target_size += item_main_length(item, constants);
                        longest_line_length = @max(longest_line_length, total_target_size + line_main_axis_gap);
                    }
                    break :blk longest_line_length + main_content_box_inset;
                } else {
                    break :blk try container_max_content_size(Tree, tree_ref, available_space, lines, constants);
                }
            },
            .max_content => break :blk try container_max_content_size(Tree, tree_ref, available_space, lines, constants),
        }
    };

    const clamped_outer_main_size = @max(
        math.f32_maybe_clamp(outer_main_size, constants.min_size.main(constants.dir), constants.max_size.main(constants.dir)),
        main_content_box_inset - constants.scrollbar_gutter.main(constants.dir));

    // let outer_main_size = inner_main_size + constants.padding_border.main_axis_sum(constants.dir);
    const inner_main_size = math.f32_max(clamped_outer_main_size - main_content_box_inset, 0.0);
    constants.container_size.set_main(constants.dir, clamped_outer_main_size);
    constants.inner_container_size.set_main(constants.dir, inner_main_size);
    constants.node_inner_size.set_main(constants.dir, inner_main_size);
}

/// The spec formula used for the MinContent/MaxContent branch of
/// `determine_container_main_size`: the flex container's max-content size is the largest
/// sum of the items' max-content contributions within a single line.
fn container_max_content_size(comptime Tree: type, tree_ref: *Tree, available_space: Size(AvailableSpace), lines: []FlexLine, constants: *AlgoConstants) !f32 {
    const TreeApi = LayoutTree(Tree);
    const dir = constants.dir;
    const main_content_box_inset = constants.content_box_inset.main_axis_sum(constants.dir);

    // Define a base main_size variable. This is mutated once for iteration over the outer
    // loop over the flex lines as:
    //   "The flex container's max-content size is the largest sum of the afore-calculated sizes of all items within a single line."
    var main_size: f32 = 0.0;

    for (lines) |*line| {
        for (line.items) |*item| {
            const style_min = item.min_size.main(constants.dir);
            const style_preferred = item.size.main(constants.dir);
            const style_max = item.max_size.main(constants.dir);

            // The spec seems a bit unclear on this point (my initial reading was that the `.maybe_max(style_preferred)` should
            // not be included here), however this matches both Chrome and Firefox as of 9th March 2023.
            //
            // Spec: https://www.w3.org/TR/css-flexbox-1/#intrinsic-item-contributions
            // Spec modification: https://www.w3.org/TR/css-flexbox-1/#change-2016-max-contribution
            // Issue: https://github.com/w3c/csswg-drafts/issues/1435
            // Gentest: padding_border_overrides_size_flex_basis_0.html
            // For column containers the flex base size alone is the clamping basis (as the
            // spec says): a column item's `height` must not inflate the container's
            // max-content size beyond the item's flex-basis.
            // Gentest: blockflex_min_content_ignores_own_height_as_percentage_basis.html
            const clamping_basis: ?f32 = if (constants.is_row)
                math.maybe_max(item.flex_basis, style_preferred)
            else
                item.flex_basis;
            const flex_basis_min: ?f32 = if (item.flex_shrink == 0.0) clamping_basis else null;
            const flex_basis_max: ?f32 = if (item.flex_grow == 0.0) clamping_basis else null;

            const min_main_size = @max(
                math.option_maybe_max(style_min, flex_basis_min) orelse flex_basis_min orelse item.resolved_minimum_main_size,
                item.resolved_minimum_main_size);
            const max_main_size =
                math.option_maybe_min(style_max, flex_basis_max) orelse flex_basis_max orelse std.math.inf(f32);

            const content_contribution = content_contribution: {
                if (style_preferred) |pref| {
                    if (max_main_size <= min_main_size or max_main_size <= pref) {
                        break :content_contribution @max(@min(pref, max_main_size), min_main_size) + item.margin.main_axis_sum(constants.dir);
                    }
                }
                if (max_main_size <= min_main_size) {
                    break :content_contribution min_main_size + item.margin.main_axis_sum(constants.dir);
                }
                if (item.is_scroll_container()) {
                    break :content_contribution item.flex_basis + item.margin.main_axis_sum(constants.dir);
                }
                if (style_preferred) |pref| {
                    // If the item has a definite preferred main size then that is its content
                    // contribution (an inherent-size measure of the item would return it), floored
                    // by the item's main-axis padding+border, so measuring the item can be skipped.
                    // Min/max clamping is applied in the same way as for measured contributions.
                    const item_pb_main = item.padding.main_axis_sum(constants.dir) +
                        item.border.main_axis_sum(constants.dir);
                    const inner_main_size = @max(pref, item_pb_main);
                    if (constants.is_row) {
                        break :content_contribution math.f32_maybe_clamp(
                            inner_main_size + item.margin.main_axis_sum(constants.dir),
                            style_min,
                            style_max);
                    } else {
                        break :content_contribution math.f32_maybe_clamp(
                            @max(inner_main_size, item.flex_basis) + item.margin.main_axis_sum(constants.dir),
                            style_min,
                            style_max);
                    }
                }

                // Parent size for child sizing
                const cross_axis_parent_size = constants.node_inner_size.cross(dir);

                // Available space for child sizing
                const cross_axis_margin_sum = constants.margin.cross_axis_sum(dir);
                const child_min_cross = math.option_maybe_add(item.min_size.cross(dir), cross_axis_margin_sum);
                const child_max_cross = math.option_maybe_add(item.max_size.cross(dir), cross_axis_margin_sum);
                const cross_axis_available_space: AvailableSpace = switch (available_space.cross(dir)) {
                    .definite => |val| .{ .definite = constants.divided_cross_space(cross_axis_parent_size orelse val) },
                    .min_content => .min_content,
                    .max_content => .max_content,
                };
                const clamped_cross = math.available_maybe_clamp(cross_axis_available_space, child_min_cross, child_max_cross);

                var child_available_space = available_space;
                child_available_space.set_cross(dir, clamped_cross);

                // Known dimensions for child sizing
                var child_known_dimensions = item.size.with_main(dir, null);
                {
                    // Clamp the definite cross size by the cross min/max sizes, as
                    // `determine_flex_base_size` does: an item measured wider than its
                    // max-width wraps onto fewer lines and under-reports its height.
                    const transferred_min_size = item.min_size.maybe_apply_aspect_ratio(item.aspect_ratio);
                    const transferred_max_size = item.max_size.maybe_apply_aspect_ratio(item.aspect_ratio);
                    child_known_dimensions.set_cross(
                        dir,
                        math.option_maybe_clamp(
                            child_known_dimensions.cross(dir),
                            transferred_min_size.cross(dir),
                            transferred_max_size.cross(dir)));
                }
                if (is_stretch_alignment(item.align_self) and child_known_dimensions.cross(dir) == null) {
                    child_known_dimensions.set_cross(
                        dir,
                        math.maybe_max(
                            math.option_maybe_sub(clamped_cross.into_option(), item.margin.cross_axis_sum(dir)),
                            0.0));
                }

                // Either the min- or max- content size depending on which constraint we are sizing under.
                // TODO: Optimise by using already computed values where available
                const measured_main_size = try TreeApi.measure_child_size(tree_ref, 
                    item.node,
                    child_known_dimensions,
                    constants.node_inner_size,
                    child_available_space,
                    .content_size,
                    dir.main_axis(),
                    LINE_FALSE);

                // A known cross size is transferred through the item's aspect-ratio
                // and floors the measured content size
                const transferred_main_size: ?f32 = if (item.aspect_ratio) |ratio|
                    (if (child_known_dimensions.cross(dir)) |cross| (if (constants.is_row) cross * ratio else cross / ratio) else null)
                else
                    null;

                const inner_main_size = math.f32_maybe_max(measured_main_size, transferred_main_size);

                // This is somewhat bizarre in that it's asymmetrical depending whether the flex container is a column or a row.
                //
                // I *think* this might relate to https://drafts.csswg.org/css-flexbox-1/#algo-main-container:
                //
                //    "The automatic block size of a block-level flex container is its max-content size."
                //
                // Which could suggest that flex-basis defining a vertical size does not shrink because it is in the block axis, and the automatic size
                // in the block axis is a MAX content size. Whereas a flex-basis defining a horizontal size does shrink because the automatic size in
                // inline axis is MIN content size (although I don't have a reference for that).
                //
                // Ultimately, this was not found by reading the spec, but by trial and error fixing tests to align with Webkit/Firefox output.
                // (see the `flex_basis_unconstraint_row` and `flex_basis_uncontraint_column` generated tests which demonstrate this)
                if (constants.is_row) {
                    break :content_contribution math.f32_maybe_clamp(
                        inner_main_size + item.margin.main_axis_sum(constants.dir),
                        style_min,
                        style_max);
                } else {
                    break :content_contribution math.f32_maybe_clamp(
                        @max(inner_main_size, item.flex_basis) + item.margin.main_axis_sum(constants.dir),
                        style_min,
                        style_max);
                }
            };

            item.content_flex_fraction = blk: {
                const diff = content_contribution - item.flex_basis;
                if (diff > 0.0) {
                    break :blk diff / math.f32_max(1.0, item.flex_grow);
                } else if (diff < 0.0) {
                    const scaled_shrink_factor = math.f32_max(1.0, item.flex_shrink) * item.inner_flex_basis;
                    break :blk diff / scaled_shrink_factor;
                } else {
                    // We are assuming that diff is 0.0 here and that we haven't accidentally introduced a NaN
                    break :blk 0.0;
                }
            };
        }

        // TODO Spec says to scale everything by the line's max flex fraction. But neither Chrome nor firefox implement this
        // so we don't either.

        // Add each item's flex base size to the product of:
        //   - its flex grow factor (or scaled flex shrink factor, if the chosen max-content flex fraction was negative)
        //   - the chosen max-content flex fraction
        // then clamp that result by the max main size floored by the min main size.
        //
        // The flex container's max-content size is the largest sum of the afore-calculated sizes of all items within a single line.
        var item_main_size_sum: f32 = 0.0;
        for (line.items) |*item| {
            const flex_fraction = item.content_flex_fraction;
            // let flex_fraction = line_flex_fraction;

            const flex_contribution: f32 = if (item.content_flex_fraction > 0.0)
                math.f32_max(1.0, item.flex_grow) * flex_fraction
            else if (item.content_flex_fraction < 0.0) blk: {
                const scaled_shrink_factor = math.f32_max(1.0, item.flex_shrink) * item.inner_flex_basis;
                if (scaled_shrink_factor == 0.0) break :blk 0.0;
                break :blk scaled_shrink_factor * flex_fraction;
            } else 0.0;
            const size = item.flex_basis + flex_contribution;
            item.outer_target_size.set_main(constants.dir, size);
            item.target_size.set_main(constants.dir, size);
            item_main_size_sum += size;
        }

        const gap_sum = sum_axis_gaps(constants.gap.main(constants.dir), line.items.len);
        main_size = math.f32_max(main_size, item_main_size_sum + gap_sum);
    }

    return main_size + main_content_box_inset;
}

fn item_main_length(child: *const FlexItem, constants: *const AlgoConstants) f32 {
    const padding_border_sum = (child.padding.main_axis_sum(constants.dir) + child.border.main_axis_sum(constants.dir));
    const basis = math.f32_maybe_max(child.flex_basis, child.min_size.main(constants.dir));
    return @max(basis + child.margin.main_axis_sum(constants.dir), padding_border_sum);
}

/// Resolve the flexible lengths of the items within a flex line.
/// Sets the `main` component of each item's `target_size` and `outer_target_size`
///
/// # [9.7. Resolving Flexible Lengths](https://www.w3.org/TR/css-flexbox-1/#resolve-flexible-lengths)
inline fn resolve_flexible_lengths(line: *FlexLine, constants: *const AlgoConstants) void {
    const total_main_axis_gap = sum_axis_gaps(constants.gap.main(constants.dir), line.items.len);

    // 1. Determine the used flex factor. Sum the outer hypothetical main sizes of all
    //    items on the line. If the sum is less than the flex container's inner main size,
    //    use the flex grow factor for the rest of this algorithm; otherwise, use the
    //    flex shrink factor.

    var total_hypothetical_outer_main_size: f32 = 0.0;
    for (line.items) |*child| total_hypothetical_outer_main_size += child.hypothetical_outer_size.main(constants.dir);
    const used_flex_factor: f32 = total_main_axis_gap + total_hypothetical_outer_main_size;
    const growing = used_flex_factor < (constants.node_inner_size.main(constants.dir) orelse 0.0);
    const shrinking = used_flex_factor > (constants.node_inner_size.main(constants.dir) orelse 0.0);
    const exactly_sized = !growing and !shrinking;

    // 2. Size inflexible items. Freeze, setting its target main size to its hypothetical main size
    //    - Any item that has a flex factor of zero
    //    - If using the flex grow factor: any item that has a flex base size
    //      greater than its hypothetical main size
    //    - If using the flex shrink factor: any item that has a flex base size
    //      smaller than its hypothetical main size

    for (line.items) |*child| {
        const inner_target_size = child.hypothetical_inner_size.main(constants.dir);
        child.target_size.set_main(constants.dir, inner_target_size);

        if (exactly_sized or
            (child.flex_grow == 0.0 and child.flex_shrink == 0.0) or
            (growing and child.flex_basis > child.hypothetical_inner_size.main(constants.dir)) or
            (shrinking and child.flex_basis < child.hypothetical_inner_size.main(constants.dir)))
        {
            child.frozen = true;
            const outer_target_size = inner_target_size + child.margin.main_axis_sum(constants.dir);
            child.outer_target_size.set_main(constants.dir, outer_target_size);
        }
    }

    if (exactly_sized) {
        return;
    }

    // 3. Calculate initial free space. Sum the outer sizes of all items on the line,
    //    and subtract this from the flex container's inner main size. For frozen items,
    //    use their outer target main size; for other items, use their outer flex base size.

    const initial_used_space: f32 = total_main_axis_gap + blk: {
        var sum: f32 = 0.0;
        for (line.items) |*child| {
            if (child.frozen) {
                sum += child.outer_target_size.main(constants.dir);
            } else {
                sum += child.flex_basis + child.margin.main_axis_sum(constants.dir);
            }
        }
        break :blk sum;
    };

    const initial_free_space = math.maybe_sub(constants.node_inner_size.main(constants.dir), initial_used_space) orelse 0.0;

    // 4. Loop

    while (true) {
        // a. Check for flexible items. If all the flex items on the line are frozen,
        //    free space has been distributed; exit this loop.

        var all_frozen = true;
        for (line.items) |*child| {
            if (!child.frozen) {
                all_frozen = false;
                break;
            }
        }
        if (all_frozen) break;

        // b. Calculate the remaining free space as for initial free space, above.
        //    If the sum of the unfrozen flex items' flex factors is less than one,
        //    multiply the initial free space by this sum. If the magnitude of this
        //    value is less than the magnitude of the remaining free space, use this
        //    as the remaining free space.

        const used_space: f32 = total_main_axis_gap + blk: {
            var sum: f32 = 0.0;
            for (line.items) |*child| {
                if (child.frozen) {
                    sum += child.outer_target_size.main(constants.dir);
                } else {
                    sum += child.flex_basis + child.margin.main_axis_sum(constants.dir);
                }
            }
            break :blk sum;
        };

        var sum_flex_grow: f32 = 0.0;
        var sum_flex_shrink: f32 = 0.0;
        for (line.items) |*child| {
            if (!child.frozen) {
                sum_flex_grow += child.flex_grow;
                sum_flex_shrink += child.flex_shrink;
            }
        }

        const free_space: f32 = if (growing and sum_flex_grow < 1.0)
            math.f32_maybe_min(
                initial_free_space * sum_flex_grow - total_main_axis_gap,
                math.maybe_sub(constants.node_inner_size.main(constants.dir), used_space))
        else if (shrinking and sum_flex_shrink < 1.0)
            math.f32_maybe_max(
                initial_free_space * sum_flex_shrink - total_main_axis_gap,
                math.maybe_sub(constants.node_inner_size.main(constants.dir), used_space))
        else
            math.maybe_sub(constants.node_inner_size.main(constants.dir), used_space) orelse (used_flex_factor - used_space);

        // c. Distribute free space proportional to the flex factors.
        //    - If the remaining free space is zero
        //        Do Nothing
        //    - If using the flex grow factor
        //        Find the ratio of the item's flex grow factor to the sum of the
        //        flex grow factors of all unfrozen items on the line. Set the item's
        //        target main size to its flex base size plus a fraction of the remaining
        //        free space proportional to the ratio.
        //    - If using the flex shrink factor
        //        For every unfrozen item on the line, multiply its flex shrink factor by
        //        its inner flex base size, and note this as its scaled flex shrink factor.
        //        Find the ratio of the item's scaled flex shrink factor to the sum of the
        //        scaled flex shrink factors of all unfrozen items on the line. Set the item's
        //        target main size to its flex base size minus a fraction of the absolute value
        //        of the remaining free space proportional to the ratio. Note this may result
        //        in a negative inner main size; it will be corrected in the next step.
        //    - Otherwise
        //        Do Nothing

        if (std.math.isNormal(free_space)) {
            if (growing and sum_flex_grow > 0.0) {
                for (line.items) |*child| {
                    if (!child.frozen) {
                        child.target_size.set_main(constants.dir, child.flex_basis + free_space * (child.flex_grow / sum_flex_grow));
                    }
                }
            } else if (shrinking and sum_flex_shrink > 0.0) {
                var sum_scaled_shrink_factor: f32 = 0.0;
                for (line.items) |*child| {
                    if (!child.frozen) sum_scaled_shrink_factor += child.inner_flex_basis * child.flex_shrink;
                }

                if (sum_scaled_shrink_factor > 0.0) {
                    for (line.items) |*child| {
                        if (!child.frozen) {
                            const scaled_shrink_factor = child.inner_flex_basis * child.flex_shrink;
                            child.target_size.set_main(
                                constants.dir,
                                child.flex_basis + free_space * (scaled_shrink_factor / sum_scaled_shrink_factor));
                        }
                    }
                }
            }
        }

        // d. Fix min/max violations. Clamp each non-frozen item's target main size by its
        //    used min and max main sizes and floor its content-box size at zero. If the
        //    item's target main size was made smaller by this, it's a max violation.
        //    If the item's target main size was made larger by this, it's a min violation.

        var total_violation: f32 = 0.0;
        for (line.items) |*child| {
            if (child.frozen) continue;
            const resolved_min_main: ?f32 = child.resolved_minimum_main_size;
            const max_main = child.max_size.main(constants.dir);
            const clamped = @max(math.f32_maybe_clamp(child.target_size.main(constants.dir), resolved_min_main, max_main), 0.0);
            child.violation = clamped - child.target_size.main(constants.dir);
            child.target_size.set_main(constants.dir, clamped);
            child.outer_target_size.set_main(
                constants.dir,
                child.target_size.main(constants.dir) + child.margin.main_axis_sum(constants.dir));

            total_violation += child.violation;
        }

        // e. Freeze over-flexed items. The total violation is the sum of the adjustments
        //    from the previous step ∑(clamped size - unclamped size). If the total violation is:
        //    - Zero
        //        Freeze all items.
        //    - Positive
        //        Freeze all the items with min violations.
        //    - Negative
        //        Freeze all the items with max violations.

        for (line.items) |*child| {
            if (child.frozen) continue;
            if (total_violation > 0.0) {
                child.frozen = child.violation > 0.0;
            } else if (total_violation < 0.0) {
                child.frozen = child.violation < 0.0;
            } else {
                child.frozen = true;
            }
        }

        // f. Return to the start of this loop.
    }
}

/// Determine the hypothetical cross size of each item.
///
/// # [9.4. Cross Size Determination](https://www.w3.org/TR/css-flexbox-1/#cross-sizing)
///
/// - [**Determine the hypothetical cross size of each item**](https://www.w3.org/TR/css-flexbox-1/#algo-cross-item)
///   by performing layout with the used main size and the available space, treating auto as fit-content.
inline fn determine_hypothetical_cross_size(comptime Tree: type, tree_ref: *Tree,
    line: *FlexLine,
    constants: *const AlgoConstants,
    available_space: Size(AvailableSpace)) !void {
    const TreeApi = LayoutTree(Tree);
    for (line.items) |*child| {
        const padding_border_sum = child.padding.cross_axis_sum(constants.dir) + child.border.cross_axis_sum(constants.dir);

        const child_known_main: AvailableSpace = .{ .definite = constants.container_size.main(constants.dir) };

        // Sizes transferred through the aspect ratio clamp the hypothetical cross size
        // https://github.com/w3c/csswg-drafts/issues/10997
        const transferred_min_cross = child.min_size.maybe_apply_aspect_ratio(child.aspect_ratio).cross(constants.dir);
        const transferred_max_cross = child.max_size.maybe_apply_aspect_ratio(child.aspect_ratio).cross(constants.dir);

        const child_cross = math.maybe_max(
            math.option_maybe_clamp(child.size.cross(constants.dir), transferred_min_cross, transferred_max_cross),
            padding_border_sum);

        const child_available_cross_base: AvailableSpace = switch (available_space.cross(constants.dir)) {
            .definite => |val| .{ .definite = constants.divided_cross_space(val) },
            .min_content => .min_content,
            .max_content => .max_content,
        };
        var child_available_cross = math.available_maybe_max(
            math.available_maybe_clamp(child_available_cross_base, transferred_min_cross, transferred_max_cross),
            padding_border_sum);

        // A cross size that is a sizing keyword (min-content, max-content, fit-content,
        // fit-content(...)) determines the available space constraint the item is measured under.
        // The `stretch` keyword is not resolved here: it stretches to the flex line, which is
        // handled in `determine_used_cross_size`
        const cross_stretch_size = math.maybe_max(
            math.option_maybe_sub(
                if (constants.node_inner_size.cross(constants.dir)) |val| constants.divided_cross_space(val) else null,
                child.margin.cross_axis_sum(constants.dir)),
            0.0);
        if (sizing_keyword.resolve_sizing_keyword(
            child.size_style.cross(constants.dir),
            cross_stretch_size,
            constants.node_inner_size.cross(constants.dir))) |resolution| switch (resolution) {
            .measure => |available| child_available_cross = available,
            .exact => {},
        };

        const child_inner_cross = child_cross orelse blk: {
            const input = layout.LayoutInput{
                .run_mode = .compute_size,
                .sizing_mode = .content_size,
                .axis = layout.requested_axis_from_absolute(constants.dir.cross_axis()),
                .known_dimensions = Size(?f32){
                    .width = if (constants.is_row) child.target_size.width else child_cross,
                    .height = if (constants.is_row) child_cross else child.target_size.height,
                },
                .known_dimensions_are_definite = item_known_dimension_definiteness(constants, child),
                .parent_size = constants.node_inner_size,
                .available_space = Size(AvailableSpace){
                    .width = if (constants.is_row) child_known_main else child_available_cross,
                    .height = if (constants.is_row) child_available_cross else child_known_main,
                },
                .vertical_margins_are_collapsible = LINE_FALSE,
            };
            const measured = try TreeApi.compute_child_layout(tree_ref, child.node, input);
            break :blk @max(
                math.f32_maybe_clamp(
                    measured.size.get_abs(constants.dir.cross_axis()),
                    transferred_min_cross,
                    transferred_max_cross),
                padding_border_sum);
        };
        const child_outer_cross = child_inner_cross + child.margin.cross_axis_sum(constants.dir);

        child.hypothetical_inner_size.set_cross(constants.dir, child_inner_cross);
        child.hypothetical_outer_size.set_cross(constants.dir, child_outer_cross);
    }
}

/// Calculate the base lines of the children.
inline fn calculate_children_base_lines(comptime Tree: type, tree_ref: *Tree,
    node_size: Size(?f32),
    available_space: Size(AvailableSpace),
    flex_lines: []FlexLine,
    constants: *const AlgoConstants) !void {
    const TreeApi = LayoutTree(Tree);
    // Only compute baselines for flex rows because we only support baseline alignment in the cross axis
    // where that axis is also the inline axis
    // TODO: this may need revisiting if/when we support vertical writing modes
    if (!constants.is_row) {
        return;
    }

    for (flex_lines) |*line| {
        // If a flex line has one or zero items participating in baseline alignment then baseline alignment is a no-op so we skip
        var line_baseline_child_count: usize = 0;
        for (line.items) |*child| {
            if (child.participates_in_baseline_alignment(constants.dir)) line_baseline_child_count += 1;
        }
        if (line_baseline_child_count <= 1) {
            continue;
        }

        for (line.items) |*child| {
            // Only calculate baselines for children participating in baseline alignment
            if (!child.participates_in_baseline_alignment(constants.dir)) {
                continue;
            }

            const measured_size_and_baselines = try TreeApi.compute_child_layout(tree_ref, 
                child.node,
                layout.LayoutInput{
                    .run_mode = .perform_layout,
                    .sizing_mode = .content_size,
                    .axis = .both,
                    .known_dimensions = Size(?f32){
                        .width = if (constants.is_row) child.target_size.width else child.hypothetical_inner_size.width,
                        .height = if (constants.is_row) child.hypothetical_inner_size.height else child.target_size.height,
                    },
                    .known_dimensions_are_definite = item_known_dimension_definiteness(constants, child),
                    .parent_size = constants.node_inner_size,
                    .available_space = Size(AvailableSpace){
                        .width = if (constants.is_row)
                            .{ .definite = constants.container_size.width }
                        else
                            available_space.width.maybe_set(node_size.width),
                        .height = if (constants.is_row)
                            available_space.height.maybe_set(node_size.height)
                        else
                            .{ .definite = constants.container_size.height },
                    },
                    .vertical_margins_are_collapsible = LINE_FALSE,
                });

            const baseline = measured_size_and_baselines.baselines.first;
            const height = measured_size_and_baselines.size.height;

            // Scroll containers' baselines are determined from their content as if scrolled to the
            // initial position, but are additionally clamped to their border box.
            // See https://github.com/w3c/csswg-drafts/issues/7660
            const resolved_baseline = if (child.overflow.y.is_scroll_container())
                @max(@min(baseline orelse height, height), 0.0)
            else
                baseline orelse height;

            child.baseline = resolved_baseline + child.margin.top;
        }
    }
}

/// Calculate the cross size of each flex line.
///
/// # [9.4. Cross Size Determination](https://www.w3.org/TR/css-flexbox-1/#cross-sizing)
///
/// - [**Calculate the cross size of each flex line**](https://www.w3.org/TR/css-flexbox-1/#algo-cross-line).
inline fn calculate_cross_size(flex_lines: []FlexLine, node_size: Size(?f32), constants: *const AlgoConstants) void {
    // If the flex container is single-line and has a definite cross size,
    // the cross size of the flex line is the flex container's inner cross size.
    if (!constants.is_wrap and node_size.cross(constants.dir) != null) {
        const cross_axis_padding_border = constants.content_box_inset.cross_axis_sum(constants.dir);
        const cross_min_size = constants.min_size.cross(constants.dir);
        const cross_max_size = constants.max_size.cross(constants.dir);
        flex_lines[0].cross_size =
            math.maybe_max(
                math.option_maybe_sub(
                    math.option_maybe_clamp(node_size.cross(constants.dir), cross_min_size, cross_max_size),
                    cross_axis_padding_border),
                0.0) orelse 0.0;
    } else {
        // Otherwise, for each flex line:
        //
        //    1. Collect all the flex items whose inline-axis is parallel to the main-axis, whose
        //       align-self is baseline, and whose cross-axis margins are both non-auto. Find the
        //       largest of the distances between each item's baseline and its hypothetical outer
        //       cross-start edge, and the largest of the distances between each item's baseline
        //       and its hypothetical outer cross-end edge, and sum these two values.

        //    2. Among all the items not collected by the previous step, find the largest
        //       outer hypothetical cross size.

        //    3. The used cross-size of the flex line is the largest of the numbers found in the
        //       previous two steps and zero.
        for (flex_lines) |*line| {
            var max_baseline: f32 = 0.0;
            for (line.items) |*child| max_baseline = @max(max_baseline, child.baseline);
            var line_cross_size: f32 = 0.0;
            for (line.items) |*child| {
                const contribution = if (child.participates_in_baseline_alignment(constants.dir))
                    max_baseline - child.baseline + child.hypothetical_outer_size.cross(constants.dir)
                else
                    child.hypothetical_outer_size.cross(constants.dir);
                line_cross_size = @max(line_cross_size, contribution);
            }
            line.cross_size = line_cross_size;
        }

        // If the flex container is single-line, then clamp the line's cross-size to be within the container's computed min and max cross sizes.
        // Note that if CSS 2.1's definition of min/max-width/height applied more generally, this behavior would fall out automatically.
        if (!constants.is_wrap) {
            const cross_axis_padding_border = constants.content_box_inset.cross_axis_sum(constants.dir);
            const cross_min_size = constants.min_size.cross(constants.dir);
            const cross_max_size = constants.max_size.cross(constants.dir);
            flex_lines[0].cross_size = math.f32_maybe_clamp(
                flex_lines[0].cross_size,
                math.option_maybe_sub(cross_min_size, cross_axis_padding_border),
                math.option_maybe_sub(cross_max_size, cross_axis_padding_border));
        }
    }
}

/// Handle 'align-content: stretch'.
///
/// # [9.4. Cross Size Determination](https://www.w3.org/TR/css-flexbox-1/#cross-sizing)
///
/// - [**Handle 'align-content: stretch'**](https://www.w3.org/TR/css-flexbox-1/#algo-line-stretch). If the flex container has a definite cross size, align-content is stretch,
///   and the sum of the flex lines' cross sizes is less than the flex container's inner cross size,
///   increase the cross size of each flex line by equal amounts such that the sum of their cross sizes exactly equals the flex container's inner cross size.
inline fn handle_align_content_stretch(flex_lines: []FlexLine, node_size: Size(?f32), constants: *const AlgoConstants) void {
    if (is_stretch_content(constants.align_content)) {
        const cross_axis_padding_border = constants.content_box_inset.cross_axis_sum(constants.dir);
        const cross_min_size = constants.min_size.cross(constants.dir);
        const cross_max_size = constants.max_size.cross(constants.dir);
        const container_min_inner_cross =
            math.maybe_max(
                math.option_maybe_sub(
                    math.option_maybe_clamp(
                        node_size.cross(constants.dir) orelse cross_min_size,
                        cross_min_size,
                        cross_max_size),
                    cross_axis_padding_border),
                0.0) orelse 0.0;

        const total_cross_axis_gap = sum_axis_gaps(constants.gap.cross(constants.dir), flex_lines.len);
        var lines_total_cross: f32 = total_cross_axis_gap;
        for (flex_lines) |line| lines_total_cross += line.cross_size;

        if (lines_total_cross < container_min_inner_cross and flex_lines.len > 0) {
            const remaining = container_min_inner_cross - lines_total_cross;
            const addition = remaining / @as(f32, @floatFromInt(flex_lines.len));
            for (flex_lines) |*line| line.cross_size += addition;
        }
    }
}

/// Determine the used cross size of each flex item.
///
/// # [9.4. Cross Size Determination](https://www.w3.org/TR/css-flexbox-1/#cross-sizing)
///
/// - [**Determine the used cross size of each flex item**](https://www.w3.org/TR/css-flexbox-1/#algo-stretch). If a flex item has align-self: stretch, its computed cross size property is auto,
///   and neither of its cross-axis margins are auto, the used outer cross size is the used cross size of its flex line, clamped according to the item's used min and max cross sizes.
///   Otherwise, the used cross size is the item's hypothetical cross size.
///
///   If the flex item has align-self: stretch, redo layout for its contents, treating this used size as its definite cross size so that percentage-sized children can be resolved.
///
///   **Note that this step does not affect the main size of the flex item, even if it has an intrinsic aspect ratio**.
inline fn determine_used_cross_size(comptime Tree: type, tree_ref: *Tree,
    flex_lines: []FlexLine,
    constants: *const AlgoConstants) !void {
    const TreeApi = LayoutTree(Tree);
    for (flex_lines) |*line| {
        const line_cross_size = line.cross_size;

        for (line.items) |*child| {
            const child_style = TreeApi.get_style(tree_ref, child.node);
            // A cross size of `stretch` stretches to the flex line like align-self: stretch
            // (but regardless of the alignment style)
            const cross_is_stretch = child.size_style.cross(constants.dir).is_stretch();
            const should_stretch = !child.margin_is_auto.cross_start(constants.dir) and
                !child.margin_is_auto.cross_end(constants.dir) and
                (cross_is_stretch or
                    (is_stretch_alignment(child.align_self) and child_style.size.cross(constants.dir).is_auto()));
            child.target_size.set_cross(
                constants.dir,
                if (should_stretch) blk: {
                    // For some reason this particular usage of max_width is an exception to the rule that max_width's transfer
                    // using the aspect_ratio (if set). Both Chrome and Firefox agree on this. And reading the spec, it seems like
                    // a reasonable interpretation. Although it seems to me that the spec *should* apply aspect_ratio here.
                    // Percentage padding and border resolve against the container's inline
                    // size (its width) on all four sides, not against its height for the
                    // top/bottom sides.
                    const padding = resolve_length_rect(child_style.padding, constants.node_inner_size.width);
                    const border = resolve_length_rect(child_style.border, constants.node_inner_size.width);
                    const pb_sum = padding.sum_axes().add(border.sum_axes());
                    const box_sizing_adjustment = if (child_style.box_sizing == .content_box) pb_sum else geometry.SIZE_F32_ZERO;

                    const max_size_ignoring_aspect_ratio = size_maybe_add(
                        resolve_auto_size(child_style.max_size, constants.node_inner_size),
                        box_sizing_adjustment);

                    break :blk math.f32_maybe_clamp(
                        @max(line_cross_size - child.margin.cross_axis_sum(constants.dir), 0.0),
                        child.min_size.cross(constants.dir),
                        max_size_ignoring_aspect_ratio.cross(constants.dir));
                } else child.hypothetical_inner_size.cross(constants.dir));

            child.outer_target_size.set_cross(
                constants.dir,
                child.target_size.cross(constants.dir) + child.margin.cross_axis_sum(constants.dir));
        }
    }
}

/// Distribute any remaining free space.
///
/// # [9.5. Main-Axis Alignment](https://www.w3.org/TR/css-flexbox-1/#main-alignment)
///
/// - [**Distribute any remaining free space**](https://www.w3.org/TR/css-flexbox-1/#algo-main-align). For each flex line:
///
///   1. If the remaining free space is positive and at least one main-axis margin on this line is `auto`, distribute the free space equally among these margins.
///      Otherwise, set all `auto` margins to zero.
///
///   2. Align the items along the main-axis per `justify-content`.
inline fn distribute_remaining_free_space(flex_lines: []FlexLine, constants: *const AlgoConstants) void {
    for (flex_lines) |*line| {
        const total_main_axis_gap = sum_axis_gaps(constants.gap.main(constants.dir), line.items.len);
        var used_space: f32 = total_main_axis_gap;
        for (line.items) |*child| used_space += child.outer_target_size.main(constants.dir);
        var free_space = constants.inner_container_size.main(constants.dir) - used_space;
        var num_auto_margins: usize = 0;

        for (line.items) |*child| {
            if (child.margin_is_auto.main_start(constants.dir)) {
                num_auto_margins += 1;
            }
            if (child.margin_is_auto.main_end(constants.dir)) {
                num_auto_margins += 1;
            }
        }

        if (free_space > 0.0 and num_auto_margins > 0) {
            const margin = free_space / @as(f32, @floatFromInt(num_auto_margins));

            for (line.items) |*child| {
                if (child.margin_is_auto.main_start(constants.dir)) {
                    if (constants.is_row) {
                        child.margin.left = margin;
                    } else {
                        child.margin.top = margin;
                    }
                }
                if (child.margin_is_auto.main_end(constants.dir)) {
                    if (constants.is_row) {
                        child.margin.right = margin;
                    } else {
                        child.margin.bottom = margin;
                    }
                }
            }

            // The auto margins have absorbed all of the free space, leaving none for `justify-content`
            free_space = 0.0;
        }

        const num_items = line.items.len;
        const layout_reverse = constants.dir.is_reverse();
        const gap = constants.gap.main(constants.dir);
        const raw_justify_content_mode = constants.justify_content orelse style.alignment.JustifyContent.FLEX_START;
        const justify_content_mode = alignment.apply_alignment_fallback(free_space, num_items, raw_justify_content_mode);

        if (layout_reverse) {
            var i: usize = 0;
            var index = line.items.len;
            while (index > 0) {
                index -= 1;
                line.items[index].offset_main =
                    alignment.compute_alignment_offset(free_space, num_items, gap, justify_content_mode, layout_reverse, i == 0);
                i += 1;
            }
        } else {
            for (line.items, 0..) |*child, i| {
                child.offset_main =
                    alignment.compute_alignment_offset(free_space, num_items, gap, justify_content_mode, layout_reverse, i == 0);
            }
        }
    }
}

/// Resolve cross-axis `auto` margins.
///
/// # [9.6. Cross-Axis Alignment](https://www.w3.org/TR/css-flexbox-1/#cross-alignment)
///
/// - [**Resolve cross-axis `auto` margins**](https://www.w3.org/TR/css-flexbox-1/#algo-cross-margins).
///   If a flex item has auto cross-axis margins:
///
///   - If its outer cross size (treating those auto margins as zero) is less than the cross size of its flex line,
///     distribute the difference in those sizes equally to the auto margins.
///
///   - Otherwise, if the block-start or inline-start margin (whichever is in the cross axis) is auto, set it to zero.
///     Set the opposite margin so that the outer cross size of the item equals the cross size of its flex line.
inline fn resolve_cross_axis_auto_margins(flex_lines: []FlexLine, constants: *const AlgoConstants) void {
    for (flex_lines) |*line| {
        const line_cross_size = line.cross_size;
        var max_baseline: f32 = 0.0;
        for (line.items) |*child| max_baseline = @max(max_baseline, child.baseline);
        var max_baseline_to_bottom_distance: f32 = 0.0;
        for (line.items) |*child| {
            if (child.participates_in_baseline_alignment(constants.dir)) {
                max_baseline_to_bottom_distance = @max(
                    max_baseline_to_bottom_distance,
                    child.outer_target_size.cross(constants.dir) - child.baseline);
            }
        }

        for (line.items) |*child| {
            const free_space = line_cross_size - child.outer_target_size.cross(constants.dir);

            if (child.margin_is_auto.cross_start(constants.dir) and child.margin_is_auto.cross_end(constants.dir)) {
                if (constants.is_row) {
                    child.margin.top = free_space / 2.0;
                    child.margin.bottom = free_space / 2.0;
                } else {
                    child.margin.left = free_space / 2.0;
                    child.margin.right = free_space / 2.0;
                }
            } else if (child.margin_is_auto.cross_start(constants.dir)) {
                if (constants.is_row) {
                    child.margin.top = free_space;
                } else {
                    child.margin.left = free_space;
                }
            } else if (child.margin_is_auto.cross_end(constants.dir)) {
                if (constants.is_row) {
                    child.margin.bottom = free_space;
                } else {
                    child.margin.right = free_space;
                }
            } else {
                // 14. Align all flex items along the cross-axis.
                child.offset_cross = align_flex_items_along_cross_axis(
                    child,
                    free_space,
                    max_baseline,
                    max_baseline_to_bottom_distance,
                    constants);
            }
        }
    }
}

/// Align all flex items along the cross-axis.
///
/// # [9.6. Cross-Axis Alignment](https://www.w3.org/TR/css-flexbox-1/#cross-alignment)
///
/// - [**Align all flex items along the cross-axis**](https://www.w3.org/TR/css-flexbox-1/#algo-cross-align) per `align-self`,
///   if neither of the item's cross-axis margins are `auto`.
inline fn align_flex_items_along_cross_axis(
    child: *const FlexItem,
    free_space: f32,
    max_baseline: f32,
    max_baseline_to_bottom_distance: f32,
    constants: *const AlgoConstants) f32 {
    const cross_axis_should_reverse = constants.is_column and constants.layout_direction == .rtl;

    // If align-self uses a "safe" overflow-position keyword and the item would overflow its
    // line cross size, fall back to logical Start to avoid data loss. See CSS Box Alignment 3
    // §4.3 <https://www.w3.org/TR/css-align-3/#overflow-values>. Otherwise, drop the safety
    // field so the match below operates on a bare keyword and stays exhaustive.
    const align_keyword = if (child.align_self.is_safe() and free_space < 0.0)
        style.alignment.AlignItemsKeyword.start
    else
        child.align_self.keyword;

    const wrap_xor_cross_reverse = constants.is_wrap_reverse != cross_axis_should_reverse;

    return switch (align_keyword) {
        .start => if (cross_axis_should_reverse) free_space else 0.0,
        .flex_start => if (wrap_xor_cross_reverse) free_space else 0.0,
        .end => if (cross_axis_should_reverse) 0.0 else free_space,
        .flex_end => if (wrap_xor_cross_reverse) 0.0 else free_space,
        .center => free_space / 2.0,
        .baseline => if (constants.is_row) blk: {
            if (constants.is_wrap_reverse) {
                // In a wrap-reverse container the cross axis is flipped, so the baseline-aligned
                // group of items is aligned to the cross-start edge, which is the bottom of the line.
                const line_cross_size = free_space + child.outer_target_size.cross(constants.dir);
                break :blk line_cross_size - max_baseline_to_bottom_distance - child.baseline;
            }
            break :blk max_baseline - child.baseline;
        } else blk: {
            // Until we support vertical writing modes, baseline alignment only makes sense if
            // the constants.direction is row, so we treat it as flex-start alignment in columns.
            const baseline_column_should_reverse = cross_axis_should_reverse and !constants.is_wrap;
            break :blk if (constants.is_wrap_reverse != baseline_column_should_reverse) free_space else 0.0;
        },
        .stretch => if (wrap_xor_cross_reverse) free_space else 0.0,
        // SelfStart/SelfEnd are resolved to Start/End against the item's own direction when
        // flex items are generated.
        .self_start, .self_end => unreachable,
    };
}

/// Determine the flex container's used cross size.
///
/// # [9.6. Cross-Axis Alignment](https://www.w3.org/TR/css-flexbox-1/#cross-alignment)
///
/// - [**Determine the flex container's used cross size**](https://www.w3.org/TR/css-flexbox-1/#algo-cross-container):
///
///     - If the cross size property is a definite size, use that, clamped by the used min and max cross sizes of the flex container.
///
///     - Otherwise, use the sum of the flex lines' cross sizes, clamped by the used min and max cross sizes of the flex container.
inline fn determine_container_cross_size(
    flex_lines: []const FlexLine,
    node_size: Size(?f32),
    constants: *AlgoConstants) f32 {
    const total_cross_axis_gap = sum_axis_gaps(constants.gap.cross(constants.dir), flex_lines.len);
    var total_line_cross_size: f32 = 0.0;
    for (flex_lines) |line| total_line_cross_size += line.cross_size;

    const padding_border_sum = constants.content_box_inset.cross_axis_sum(constants.dir);
    const cross_scrollbar_gutter = constants.scrollbar_gutter.cross(constants.dir);
    const min_cross_size = constants.min_size.cross(constants.dir);
    const max_cross_size = constants.max_size.cross(constants.dir);
    const outer_container_size = @max(
        math.f32_maybe_clamp(
            node_size.cross(constants.dir) orelse (total_line_cross_size + total_cross_axis_gap + padding_border_sum),
            min_cross_size,
            max_cross_size),
        padding_border_sum - cross_scrollbar_gutter);
    const inner_container_size = math.f32_max(outer_container_size - padding_border_sum, 0.0);

    constants.container_size.set_cross(constants.dir, outer_container_size);
    constants.inner_container_size.set_cross(constants.dir, inner_container_size);

    return total_line_cross_size;
}

/// Align all flex lines per `align-content`.
///
/// # [9.6. Cross-Axis Alignment](https://www.w3.org/TR/css-flexbox-1/#cross-alignment)
///
/// - [**Align all flex lines**](https://www.w3.org/TR/css-flexbox-1/#algo-line-align) per `align-content`.
inline fn align_flex_lines_per_align_content(flex_lines: []FlexLine, constants: *const AlgoConstants, total_cross_size: f32) void {
    const num_lines = flex_lines.len;
    const gap = constants.gap.cross(constants.dir);
    const total_cross_axis_gap = sum_axis_gaps(gap, num_lines);
    const free_space = constants.inner_container_size.cross(constants.dir) - total_cross_size - total_cross_axis_gap;

    const align_content_mode = alignment.apply_alignment_fallback(free_space, num_lines, constants.align_content);

    if (constants.is_wrap_reverse) {
        var i: usize = 0;
        var index = flex_lines.len;
        while (index > 0) {
            index -= 1;
            flex_lines[index].offset_cross =
                alignment.compute_alignment_offset(free_space, num_lines, gap, align_content_mode, constants.is_wrap_reverse, i == 0);
            i += 1;
        }
    } else {
        for (flex_lines, 0..) |*line, i| {
            line.offset_cross =
                alignment.compute_alignment_offset(free_space, num_lines, gap, align_content_mode, constants.is_wrap_reverse, i == 0);
        }
    }
}

/// Calculates the layout for a flex-item
fn calculate_flex_item(comptime Tree: type, tree_ref: *Tree,
    item: *FlexItem,
    total_offset_main: *f32,
    total_offset_cross: f32,
    line_offset_cross: f32,
    total_overflow_rect: *Rect(f32),
    border: Rect(f32),
    constants: *const AlgoConstants) !void {
    const TreeApi = LayoutTree(Tree);
    const container_size = constants.container_size;
    const node_inner_size = constants.node_inner_size;
    const direction = constants.dir;
    const layout_direction = constants.layout_direction;
    const item_definiteness = item_known_dimension_definiteness(constants, item);
    var layout_output = try TreeApi.compute_child_layout(tree_ref, 
        item.node,
        layout.LayoutInput{
            .run_mode = .perform_layout,
            .sizing_mode = .content_size,
            .axis = .both,
            .known_dimensions = Size(?f32){ .width = item.target_size.width, .height = item.target_size.height },
            .known_dimensions_are_definite = item_definiteness,
            .parent_size = node_inner_size,
            .available_space = Size(AvailableSpace){
                .width = .{ .definite = container_size.width },
                .height = .{ .definite = container_size.height },
            },
            .vertical_margins_are_collapsible = LINE_FALSE,
        });
    const size = layout_output.size;

    const is_rtl_row = direction.is_row() and layout_direction.is_rtl();
    const is_rtl_column = direction.is_column() and layout_direction.is_rtl();
    const main_relative_inset: f32 = item.relative_inset.main(direction);
    const cross_relative_inset: f32 = item.relative_inset.cross(direction);
    const effective_line_offset_cross = if (is_rtl_column) 0.0 else line_offset_cross;

    const offset_main = if (is_rtl_row)
        total_offset_main.* - item.offset_main - item.margin.main_end(direction) - main_relative_inset - size.width
    else
        total_offset_main.* + item.offset_main + item.margin.main_start(direction) + main_relative_inset;

    const offset_cross = total_offset_cross +
        item.offset_cross +
        effective_line_offset_cross +
        item.margin.cross_start(direction) +
        cross_relative_inset;

    if (direction.is_row()) {
        const baseline_offset_cross =
            total_offset_cross + item.offset_cross + effective_line_offset_cross + item.margin.cross_start(direction);
        // Scroll containers' baselines are determined from their content as if scrolled to the initial
        // position, but are additionally clamped to their border box.
        // See https://github.com/w3c/csswg-drafts/issues/7660
        const inner_baseline = blk: {
            const baseline = layout_output.baselines.first orelse size.height;
            if (item.overflow.y.is_scroll_container()) {
                break :blk @max(@min(baseline, size.height), 0.0);
            }
            break :blk baseline;
        };
        item.baseline = baseline_offset_cross + inner_baseline;
    } else {
        const baseline_offset_main = total_offset_main.* + item.offset_main + item.margin.main_start(direction);
        const inner_baseline = layout_output.baselines.first orelse size.height;
        item.baseline = baseline_offset_main + inner_baseline;
    }

    const location = if (direction.is_row())
        Point(f32){ .x = offset_main, .y = offset_cross }
    else
        Point(f32){ .x = offset_cross, .y = offset_main };
    const scrollbar_size = Size(f32){
        .width = if (item.overflow.y == .scroll) item.scrollbar_width else 0.0,
        .height = if (item.overflow.x == .scroll) item.scrollbar_width else 0.0,
    };

    try TreeApi.set_unrounded_layout(tree_ref, item.node, layout.Layout{
        .order = item.order,
        .size = size,
        .scrollable_overflow_rect = layout_output.scrollable_overflow_rect,
        .scrollbar_size = scrollbar_size,
        .location = location,
        .padding = item.padding,
        .border = item.border,
        .margin = item.margin,
    });
    // Taffy mirrors the unrounded layout into the final layout here so the item is
    // readable before the rounding pass rewrites it.
    try TreeApi.set_final_layout(tree_ref, item.node, (try TreeApi.unrounded_layout(tree_ref, item.node)));

    // Keep out-of-flow candidates from the item's subtree, translating anchors from
    // item-relative to container-relative coordinates
    item.oof_candidates = layout_output.oof_candidates;
    layout_output.oof_candidates = .empty;
    if (item.oof_candidates.items.len != 0) {
        oof.translateCandidates(&item.oof_candidates, location);
    }

    if (is_rtl_row) {
        total_offset_main.* -= item.offset_main + item.margin.main_axis_sum(direction) + size.main(direction);
    } else {
        total_offset_main.* += item.offset_main + item.margin.main_axis_sum(direction) + size.main(direction);
    }

    {
        const contribution_location = if (layout_direction.is_rtl())
            Point(f32){ .x = container_size.width - (location.x + size.width) - border.right, .y = location.y - border.top }
        else
            Point(f32){ .x = location.x - border.left, .y = location.y - border.top };
        total_overflow_rect.* = geometry.rect_union(total_overflow_rect.*, scrollable_overflow.compute_scrollable_overflow_contribution(
            contribution_location,
            size,
            layout_output.scrollable_overflow_rect,
            item.overflow,
            item.contain,
            constants.is_scroll_container));
    }
}

/// Calculates the layout line
fn calculate_layout_line(comptime Tree: type, tree_ref: *Tree,
    line: *FlexLine,
    total_offset_cross: *f32,
    overflow_rect: *Rect(f32),
    border: Rect(f32),
    constants: *const AlgoConstants) !void {
    const container_size = constants.container_size;
    const padding_border = constants.content_box_inset;
    const direction = constants.dir;
    const layout_direction = constants.layout_direction;
    var total_offset_main: f32 = if (layout_direction.is_rtl() and direction.is_row())
        container_size.width - padding_border.main_end(direction)
    else
        padding_border.main_start(direction);
    const line_offset_cross = line.offset_cross;

    const is_rtl_column = layout_direction.is_rtl() and direction.is_column();
    if (is_rtl_column) {
        total_offset_cross.* -= line_offset_cross + line.cross_size;
    }

    if (direction.is_reverse()) {
        var index = line.items.len;
        while (index > 0) {
            index -= 1;
            try calculate_flex_item(
                Tree,
tree_ref,
                &line.items[index],
                &total_offset_main,
                total_offset_cross.*,
                line_offset_cross,
                overflow_rect,
                border,
                constants);
        }
    } else {
        for (line.items) |*item| {
            try calculate_flex_item(
                Tree,
tree_ref,
                item,
                &total_offset_main,
                total_offset_cross.*,
                line_offset_cross,
                overflow_rect,
                border,
                constants);
        }
    }

    if (!is_rtl_column) {
        total_offset_cross.* += line_offset_cross + line.cross_size;
    }
}

/// Do a final layout pass and collect the resulting layouts.
inline fn final_layout_pass(comptime Tree: type, tree_ref: *Tree,
    flex_lines: []FlexLine,
    constants: *const AlgoConstants) !Rect(f32) {
    var total_offset_cross: f32 = if (constants.is_column and constants.layout_direction.is_rtl())
        constants.container_size.width - constants.content_box_inset.cross_end(constants.dir)
    else
        constants.content_box_inset.cross_start(constants.dir);

    var overflow_rect = geometry.RECT_F32_ZERO;

    if (constants.is_wrap_reverse) {
        var index = flex_lines.len;
        while (index > 0) {
            index -= 1;
            try calculate_layout_line(
                Tree,
tree_ref,
                &flex_lines[index],
                &total_offset_cross,
                &overflow_rect,
                constants.border,
                constants);
        }
    } else {
        for (flex_lines) |*line| {
            try calculate_layout_line(
                Tree,
tree_ref,
                line,
                &total_offset_cross,
                &overflow_rect,
                constants.border,
                constants);
        }
    }

    // A scroll container's own padding at the end of the content is part of its scrollable
    // overflow region, so it is included in the overflow rect. Boxes that are not scroll
    // containers do not extend their overflow region by their own padding.
    if (constants.is_scroll_container) {
        overflow_rect.right += if (constants.layout_direction.is_rtl())
            constants.content_box_inset.left - constants.border.left - constants.scrollbar_gutter.x
        else
            constants.content_box_inset.right - constants.border.right - constants.scrollbar_gutter.x;
        overflow_rect.bottom += constants.content_box_inset.bottom - constants.border.bottom - constants.scrollbar_gutter.y;
    }

    return overflow_rect;
}

/// Resolve the sizing keywords (`min-content`, `max-content`, `fit-content`, `fit-content(...)`,
/// and `stretch`) on the size styles of an absolutely positioned item, filling in the
/// corresponding `known_dimensions` axes.
fn resolve_absolute_sizing_keywords(comptime Tree: type, tree_ref: *Tree,
    node_id: NodeId,
    known_dimensions: *Size(?f32),
    size_style: Size(Dimension),
    area_size: Size(f32),
    inset: Rect(?f32),
    margin: Rect(?f32),
    sizing_mode: layout.SizingMode) !void {
    const TreeApi = LayoutTree(Tree);
    const stretch_size = Size(f32){
        .width = @max(
            area_size.width - (inset.left orelse 0.0) - (inset.right orelse 0.0) - (margin.left orelse 0.0) - (margin.right orelse 0.0),
            0.0),
        .height = @max(
            area_size.height - (inset.top orelse 0.0) - (inset.bottom orelse 0.0) - (margin.top orelse 0.0) - (margin.bottom orelse 0.0),
            0.0),
    };

    const keyword_width: ?sizing_keyword.SizingKeywordResolution = if (known_dimensions.width == null)
        sizing_keyword.resolve_sizing_keyword(size_style.width, stretch_size.width, area_size.width)
    else
        null;
    const keyword_height: ?sizing_keyword.SizingKeywordResolution = if (known_dimensions.height == null)
        sizing_keyword.resolve_sizing_keyword(size_style.height, stretch_size.height, area_size.height)
    else
        null;

    const width_is_measure = if (keyword_width) |kw| switch (kw) {
        .measure => true,
        .exact => false,
    } else false;
    const height_is_measure = if (keyword_height) |kw| switch (kw) {
        .measure => true,
        .exact => false,
    } else false;

    if (width_is_measure and height_is_measure) {
        // If both axes need to be measured then resolve them with a single measure call
        const available_width = switch (keyword_width.?) {
            .measure => |available| available,
            .exact => unreachable,
        };
        const available_height = switch (keyword_height.?) {
            .measure => |available| available,
            .exact => unreachable,
        };
        const measured_size = try TreeApi.measure_child_size_both(tree_ref, 
            node_id,
            SIZE_NONE,
            to_optional_size(area_size),
            .{ .width = available_width, .height = available_height },
            sizing_mode,
            LINE_FALSE);
        known_dimensions.* = to_optional_size(measured_size);
    } else {
        if (keyword_width) |resolution| {
            known_dimensions.width = switch (resolution) {
                .exact => |width| width,
                .measure => |available_width| try TreeApi.measure_child_size(tree_ref, 
                    node_id,
                    known_dimensions.*,
                    to_optional_size(area_size),
                    .{ .width = available_width, .height = .{ .definite = stretch_size.height } },
                    sizing_mode,
                    .horizontal,
                    LINE_FALSE),
            };
        }
        if (keyword_height) |resolution| {
            const width_space: AvailableSpace = if (known_dimensions.width) |width| .{ .definite = width } else .{ .definite = stretch_size.width };
            known_dimensions.height = switch (resolution) {
                .exact => |height| height,
                .measure => |available_height| try TreeApi.measure_child_size(tree_ref, 
                    node_id,
                    known_dimensions.*,
                    to_optional_size(area_size),
                    .{ .width = width_space, .height = available_height },
                    sizing_mode,
                    .vertical,
                    LINE_FALSE),
            };
        }
    }
}


inline fn sum_axis_gaps(gap: f32, num_items: usize) f32 {
    // Gaps only exist between items, so...
    if (num_items <= 1) {
        // ...if there are less than 2 items then there are no gaps
        return 0.0;
    }
    // ...otherwise there are (num_items - 1) gaps
    return gap * @as(f32, @floatFromInt(num_items - 1));
}

/// Balanced line breaking for `flex-wrap: balance`.
///
/// Implements the balancing algorithm from the CSS Flexbox Level 2 draft
/// (<https://drafts.csswg.org/css-flexbox-2/#balancing>). Items are divided into exactly
/// `line_count` contiguous sequences (lines), where `line_count` is the number of lines that
/// greedy line breaking would produce (with item sizes floored at zero), raised to the minimum
/// flex line count (`flex-line-count`, clamped to the number of items), such that:
///
/// - every line holds at least one item;
/// - no line's size exceeds the container's inner main size, unless the line holds a single
///   (overflowing) item;
/// - a zero-sized item is assigned to the end of the preceding line rather than the beginning
///   of a line, unless no valid division can glue it there;
/// - calling the difference between a line's size and the container's inner main size the
///   line's *error*, the sum of the squared errors of all lines is minimized;
/// - ties are broken by assigning the most items to the first line, then the most items to the
///   second line, and so on.
///
/// The minimization is a dynamic program over (line count, first item of suffix) accelerated
/// with the divide-and-conquer optimization, running in `O(line_count * item_count *
/// log(item_count))` time; the naive `O(line_count * item_count²)` dynamic program is kept as
/// a test oracle.
const balance = struct {
    /// Score assigned to divisions that violate the line size constraint
    const INFEASIBLE: f64 = std.math.inf(f64);

    /// Convert an item size in pixels to an `f64`, flooring negative sizes at zero. (An
    /// infinite size is clamped to the largest finite `f32` so that sums stay meaningful.)
    fn to_size(value: f32) f64 {
        const value_f64: f64 = @floatCast(value);
        if (value_f64 < 0.0) return 0.0;
        if (value_f64 > @as(f64, std.math.floatMax(f32))) return @as(f64, std.math.floatMax(f32));
        return value_f64;
    }

    /// Line sizing shared by the scoring and readback phases
    const LineSizes = struct {
        /// Per item, the prefix sum of the item sizes through it (each item also contributes
        /// one trailing gap, so the size of the line holding items `start..=end` is
        /// `sums[end].sum - sums[start - 1].sum - gap_between_items`), paired with whether the
        /// item's (floored) size is zero
        sums: []const SumEntry,
        /// The size of the gap between adjacent items on a line
        gap_between_items: f64,
        /// The container's inner main size, which lines may not exceed (unless they hold a
        /// single item)
        limit: f64,

        const SumEntry = struct {
            sum: f64,
            is_zero: bool,
        };

        /// The total number of items
        fn item_count(self: LineSizes) usize {
            return self.sums.len;
        }

        /// Whether the item at `index` has a (floored) size of zero
        fn is_zero_item(self: LineSizes, index: usize) bool {
            return self.sums[index].is_zero;
        }

        /// The size of the line holding items `start..=end`
        fn line_size(self: LineSizes, start: usize, end: usize) f64 {
            const start_sum = if (start == 0) 0.0 else self.sums[start - 1].sum;
            return self.sums[end].sum - start_sum - self.gap_between_items;
        }

        /// The squared size of the line holding items `start..=end`, or `INFEASIBLE` for a
        /// line of more than one item exceeding the limit
        fn line_cost(self: LineSizes, start: usize, end: usize) f64 {
            const size = self.line_size(start, end);
            if (end > start and size > self.limit) {
                return INFEASIBLE;
            }
            return size * size;
        }

        /// For every suffix of the items, the number of lines that greedy line breaking
        /// produces for it: each line collects consecutive items until the next item no longer
        /// fits, and if even the first item of a line doesn't fit, that line takes just the one
        /// (overflowing) item. (The entry for the empty suffix is zero.)
        ///
        /// This is also the *fewest* lines each suffix can validly be divided into, and a
        /// suffix can validly be divided into any number of lines from that count up to its
        /// item count.
        fn suffix_greedy_line_counts(self: LineSizes, allocator: std.mem.Allocator) ![]u32 {
            const count = self.item_count();
            const counts = try allocator.alloc(u32, count + 1);
            @memset(counts, 0);
            // The (exclusive) end of the greedy first line of the suffix, which only moves
            // down as the suffix grows leftwards since lines starting earlier are larger
            var line_end = count;
            var start = count;
            while (start > 0) {
                start -= 1;
                while (line_end > start + 1 and self.line_size(start, line_end - 1) > self.limit) {
                    line_end -= 1;
                }
                counts[start] = 1 + counts[line_end];
            }
            return counts;
        }

        /// For every `start`, the largest `end` such that the line holding items `start..=end`
        /// does not exceed the limit (or `start` itself if even that one item overflows)
        fn fit_ends(self: LineSizes, allocator: std.mem.Allocator) ![]u32 {
            const count = self.item_count();
            const fit_ends_result = try allocator.alloc(u32, count);
            // Lines starting later are smaller, so the fit end only moves up
            var fit_end: usize = 0;
            for (0..count) |start| {
                if (fit_end < start) {
                    fit_end = start;
                }
                while (fit_end + 1 < count and self.line_size(start, fit_end + 1) <= self.limit) {
                    fit_end += 1;
                }
                fit_ends_result[start] = @intCast(fit_end);
            }
            return fit_ends_result;
        }
    };

    /// One row of the balancing dynamic program: divisions of item suffixes into exactly
    /// `lines` lines
    const Row = struct {
        /// The line sizing for the items being divided
        sizes: *const LineSizes,
        /// See [`LineSizes::fit_ends`]
        fit_ends: []const u32,
        /// The previous row: `prev[start]` is the minimum score of any valid division of items
        /// `start..` into exactly `lines - 1` lines ([`INFEASIBLE`] if there is none)
        prev: []const f64,
        /// The line ends that precede a non-zero item, in ascending order and capped to
        /// `max_end`. Line ends preceding a *zero* item are constrained by the
        /// zero-sized-item rule and handled separately.
        nonzero_ends: []const u32,
        /// The largest possible end of the first line: the remaining `lines - 1` lines need
        /// one item each
        max_end: usize,
    };

    /// Compute `cur[start]` and `opts[start]` for `start` in `start_lo..=start_hi`, where
    /// `cur[start]` is the minimum over valid ends `end` of
    /// `row.sizes.line_cost(start, end) + row.prev[end + 1]` and `opts[start]` is the largest
    /// `end` achieving that minimum. Ends preceding a non-zero item are minimized over
    /// `row.nonzero_ends[col_lo..col_hi]`; the (at most one) end preceding a zero item allowed
    /// by the zero-sized-item rule is merged in afterwards.
    ///
    /// Uses the divide-and-conquer dynamic programming optimization.
    fn fill_row(
        row: Row,
        cur: []f64,
        opts: []u32,
        start_lo: usize,
        start_hi: usize,
        col_lo: usize,
        col_hi: usize) void {
        if (start_lo > start_hi) {
            return;
        }
        const start = start_lo + (start_hi - start_lo) / 2;

        // Minimize over the in-range ends preceding a non-zero item, starting from `start`
        // (the line must hold at least one item)
        var first_col = col_lo;
        while (first_col < col_hi and row.nonzero_ends[first_col] < start) : (first_col += 1) {}
        var min_cost = INFEASIBLE;
        var min_col: ?usize = null;
        var col = first_col;
        while (col < col_hi) : (col += 1) {
            const end: usize = row.nonzero_ends[col];
            const line_cost = row.sizes.line_cost(start, end);
            if (line_cost == INFEASIBLE) {
                // Every longer line also exceeds the limit
                break;
            }
            const cost = line_cost + row.prev[end + 1];
            // `<=` keeps the *largest* minimizing end, assigning the most items to the
            // earliest lines as the tie-break requires
            if (cost <= min_cost) {
                min_cost = cost;
                min_col = col;
            }
        }

        // Merge the single end preceding a zero item that the zero-sized-item rule allows
        var min_end: ?usize = if (min_col) |c| row.nonzero_ends[c] else null;
        const zero_end = @min(@as(usize, row.fit_ends[start]), row.max_end);
        if (row.sizes.is_zero_item(zero_end + 1)) {
            const cost = row.sizes.line_cost(start, zero_end) + row.prev[zero_end + 1];
            if (cost < min_cost or (cost == min_cost and (min_end == null or min_end.? < zero_end))) {
                min_cost = cost;
                min_end = zero_end;
            }
        }

        // Infeasible states are excluded from the range by the caller, and every feasible
        // state has a valid transition (see `LineSizes::suffix_greedy_line_counts`)
        std.debug.assert(std.math.isFinite(min_cost));
        cur[start] = min_cost;
        opts[start] = @intCast(min_end orelse start);

        // The zero-rule end is excluded from the narrowing: only the non-zero ends' minima
        // are monotone
        if (start > start_lo) {
            const new_col_hi = if (min_col) |c| c + 1 else col_hi;
            fill_row(row, cur, opts, start_lo, start - 1, col_lo, new_col_hi);
        }
        if (start < start_hi) {
            const new_col_lo = min_col orelse first_col;
            fill_row(row, cur, opts, start + 1, start_hi, new_col_lo, col_hi);
        }
    }

    /// Determine the number of items on each line that balances items across lines, such that
    /// the largest line is as small as possible, with a minimum of `min_line_count` lines
    /// (or one line per item if there are fewer items).
    ///
    /// `item_sizes` must be non-empty. The returned line item counts are all non-zero and sum to
    /// the number of items.
    ///
    /// Runs in `O(line_count * item_count * log(item_count))` time using
    /// `O(line_count * item_count)` transient memory.
    pub fn balanced_line_item_counts(
        allocator: std.mem.Allocator,
        item_sizes: []const f32,
        line_limit: f32,
        gap_between_items: f32,
        min_line_count: usize) ![]usize {
        const item_count = item_sizes.len;
        std.debug.assert(item_count > 0);
        const gap = to_size(gap_between_items);
        const limit: f64 = @floatCast(line_limit);

        const sums = try allocator.alloc(LineSizes.SumEntry, item_count);
        defer allocator.free(sums);
        var sum: f64 = 0.0;
        for (item_sizes, 0..) |size, index| {
            const sized = to_size(size);
            sum += sized + gap;
            sums[index] = .{ .sum = sum, .is_zero = sized == 0.0 };
        }
        const sizes = LineSizes{ .sums = sums, .gap_between_items = gap, .limit = limit };

        // `suffix_greedy[start]` is the number of lines greedy line breaking produces for items
        // `start..`, which is also the *fewest* lines the suffix can validly be divided into
        const suffix_greedy = try sizes.suffix_greedy_line_counts(allocator);
        defer allocator.free(suffix_greedy);
        const line_count = @max(@as(usize, suffix_greedy[0]), std.math.clamp(min_line_count, 1, item_count));

        if (line_count == item_count) {
            // One item per line is the only division (this covers `flex-line-count` of at least
            // the item count as well as every item overflowing a line of its own)
            const counts = try allocator.alloc(usize, item_count);
            @memset(counts, 1);
            return counts;
        }

        const fit_ends = try sizes.fit_ends(allocator);
        defer allocator.free(fit_ends);
        const nonzero_ends_alloc = try allocator.alloc(u32, item_count - 1);
        defer allocator.free(nonzero_ends_alloc);
        var nonzero_ends_len: usize = 0;
        for (0..item_count - 1) |end| {
            if (!sizes.is_zero_item(end + 1)) {
                nonzero_ends_alloc[nonzero_ends_len] = @intCast(end);
                nonzero_ends_len += 1;
            }
        }
        const nonzero_ends = nonzero_ends_alloc[0..nonzero_ends_len];

        // `prev[start]` is the minimum total score of any valid division of items `start..`
        // into exactly `lines - 1` lines ([`INFEASIBLE`] if there is none), and `cur` is the
        // row being computed for `lines` lines: a division into `lines` lines is a first line
        // `start..=end` plus a division of `end + 1..` into `lines - 1` lines.
        // `opts[(lines - 2) * item_count + start]` records the largest `end` achieving
        // `cur[start]`, from which the chosen division is read back.
        const prev = try allocator.alloc(f64, item_count);
        defer allocator.free(prev);
        const cur = try allocator.alloc(f64, item_count);
        defer allocator.free(cur);
        for (0..item_count) |start| {
            prev[start] = sizes.line_cost(start, item_count - 1);
        }
        @memset(cur, INFEASIBLE);
        const opts = try allocator.alloc(u32, (line_count - 1) * item_count);
        defer allocator.free(opts);
        @memset(opts, 0);

        var prev_slice: []f64 = prev;
        var cur_slice: []f64 = cur;
        var lines: usize = 2;
        while (lines <= line_count) : (lines += 1) {
            // The remaining `lines - 1` lines need one item each, bounding this line's end
            const max_end = item_count - lines;
            // Starts whose suffix doesn't fit in `lines` lines even with greedy breaking are
            // infeasible; they form a prefix (a longer suffix never needs fewer lines), and
            // excluding them keeps every state `fill_row` solves feasible
            var first_start: usize = 0;
            while (first_start < max_end and @as(usize, suffix_greedy[first_start]) > lines) {
                cur_slice[first_start] = INFEASIBLE;
                first_start += 1;
            }
            var col_hi: usize = 0;
            while (col_hi < nonzero_ends.len and @as(usize, nonzero_ends[col_hi]) <= max_end) : (col_hi += 1) {}
            const row = Row{
                .sizes = &sizes,
                .fit_ends = fit_ends,
                .prev = prev_slice,
                .nonzero_ends = nonzero_ends,
                .max_end = max_end,
            };
            const opts_row = opts[(lines - 2) * item_count .. (lines - 1) * item_count];
            fill_row(row, cur_slice, opts_row, first_start, max_end, 0, col_hi);
            std.mem.swap([]f64, &prev_slice, &cur_slice);
        }

        // Read the division back out front to back
        std.debug.assert(std.math.isFinite(prev_slice[0]));
        const counts = try allocator.alloc(usize, line_count);
        var start: usize = 0;
        var output_index: usize = 0;
        lines = line_count;
        while (lines >= 2) : (lines -= 1) {
            const end: usize = opts[(lines - 2) * item_count + start];
            counts[output_index] = end - start + 1;
            output_index += 1;
            start = end + 1;
        }
        counts[output_index] = item_count - start;
        return counts;
    }
};

// ---------------------------------------------------------------------------
// Resolution helpers
// ---------------------------------------------------------------------------

/// `LengthPercentage::maybe_resolve`: lengths resolve without a basis, only
/// percentages require one. (The shared `dimension.zig` helpers treat a null
/// basis as unresolvable for every variant; Taffy only does that for
/// percentages. Keeping the Taffy semantics local avoids depending on the
/// shared-file fix.)
inline fn resolve_length_value(value: LengthPercentage, basis: ?f32) ?f32 {
    return switch (value.value.tag()) {
        .length => value.value.value(),
        .percent => if (basis) |resolved_basis| value.value.value() * resolved_basis else null,
        else => null,
    };
}

/// `LengthPercentageAuto::maybe_resolve` (see above).
inline fn resolve_auto_value(value: LengthPercentageAuto, basis: ?f32) ?f32 {
    return switch (value.value.tag()) {
        .auto => null,
        .length => value.value.value(),
        .percent => if (basis) |resolved_basis| value.value.value() * resolved_basis else null,
        else => null,
    };
}

/// `Dimension::maybe_resolve` (see above). Sizing keywords stay `None`.
inline fn resolve_dimension_value(value: Dimension, basis: ?f32) ?f32 {
    return switch (value.value.tag()) {
        .length => value.value.value(),
        .percent => if (basis) |resolved_basis| value.value.value() * resolved_basis else null,
        else => null,
    };
}

/// `AlignItems` value equality for the `BASELINE` constant (keyword + safety).
inline fn is_baseline_alignment(value: style.alignment.AlignItems) bool {
    return value.keyword == .baseline and value.safety == .unsafe;
}

/// `AlignItems` value equality for the `STRETCH` constant (keyword + safety).
inline fn is_stretch_alignment(value: style.alignment.AlignItems) bool {
    return value.keyword == .stretch and value.safety == .unsafe;
}

/// `AlignContent` value equality for the `STRETCH` constant (keyword + safety).
inline fn is_stretch_content(value: style.alignment.AlignContent) bool {
    return value.keyword == .stretch and value.safety == .unsafe;
}

/// `AlignSelf.resolve_self_relative` implemented locally with an explicit result
/// type (`src/style/alignment.zig`'s version fails to compile under Zig 0.17's
/// enum-literal rules when reached at runtime; this is the same logic).
const resolve_self_relative = alignment_common.resolve_self_relative;
/// `Size<f32>` -> `Size<?f32>` (Rust's `.map(Some)`).
inline fn to_optional_size(value: Size(f32)) Size(?f32) {
    return .{ .width = value.width, .height = value.height };
}

/// Normalize the definiteness flags: they only apply to dimensions which were passed in as
/// known by the parent. Dimensions resolved from the node's own style are always definite.
inline fn normalize_definiteness(is_definite: bool, known_dimension: ?f32) bool {
    return is_definite or known_dimension == null;
}

/// `Size<Option<f32>>.maybe_add(Size<f32>)` (each field's `Option<f32>.maybe_add(f32)`).
inline fn size_maybe_add(value: Size(?f32), rhs: Size(f32)) Size(?f32) {
    return .{ .width = math.maybe_add(value.width, rhs.width), .height = math.maybe_add(value.height, rhs.height) };
}

/// `Size<Option<f32>>.or(other)`.
inline fn optional_size_or(a: Size(?f32), b: Size(?f32)) Size(?f32) {
    return .{ .width = a.width orelse b.width, .height = a.height orelse b.height };
}

/// `Size<Option<f32>>.or(other)` where `other` is non-optional.
inline fn optional_size_maybe_or(a: Size(?f32), b: Size(?f32)) Size(?f32) {
    return optional_size_or(a, b);
}

/// `Rect<LengthPercentage>` resolved against a scalar basis (all four edges use it).
inline fn resolve_length_rect(value: Rect(LengthPercentage), basis: ?f32) Rect(f32) {
    return .{
        .left = resolve_length_value(value.left, basis) orelse 0,
        .right = resolve_length_value(value.right, basis) orelse 0,
        .top = resolve_length_value(value.top, basis) orelse 0,
        .bottom = resolve_length_value(value.bottom, basis) orelse 0,
    };
}

/// `Rect<LengthPercentage>` resolved against a `Size` context (horizontal edges use width,
/// vertical edges use height).
inline fn resolve_length_rect_size(value: Rect(LengthPercentage), size: Size(?f32)) Rect(f32) {
    return .{
        .left = resolve_length_value(value.left, size.width) orelse 0,
        .right = resolve_length_value(value.right, size.width) orelse 0,
        .top = resolve_length_value(value.top, size.height) orelse 0,
        .bottom = resolve_length_value(value.bottom, size.height) orelse 0,
    };
}

/// `Rect<LengthPercentageAuto>::resolve_or_zero` against a scalar basis.
inline fn resolve_auto_rect(value: Rect(LengthPercentageAuto), basis: ?f32) Rect(f32) {
    return .{
        .left = resolve_auto_value(value.left, basis) orelse 0,
        .right = resolve_auto_value(value.right, basis) orelse 0,
        .top = resolve_auto_value(value.top, basis) orelse 0,
        .bottom = resolve_auto_value(value.bottom, basis) orelse 0,
    };
}

/// `Rect<LengthPercentageAuto>::resolve_or_zero` against a `Size` context.
inline fn resolve_auto_size_size(value: Rect(LengthPercentageAuto), size: Size(?f32)) Rect(f32) {
    return .{
        .left = resolve_auto_value(value.left, size.width) orelse 0,
        .right = resolve_auto_value(value.right, size.width) orelse 0,
        .top = resolve_auto_value(value.top, size.height) orelse 0,
        .bottom = resolve_auto_value(value.bottom, size.height) orelse 0,
    };
}

/// `Rect<LengthPercentageAuto>::maybe_resolve` against a scalar basis, keeping `auto` as `None`.
inline fn resolve_auto_rect_to_option(value: Rect(LengthPercentageAuto), basis: ?f32) Rect(?f32) {
    return .{
        .left = resolve_auto_value(value.left, basis),
        .right = resolve_auto_value(value.right, basis),
        .top = resolve_auto_value(value.top, basis),
        .bottom = resolve_auto_value(value.bottom, basis),
    };
}

/// `Rect<LengthPercentageAuto>::maybe_resolve` against a `Size` context, keeping `auto` as `None`.
inline fn resolve_auto_rect_size_to_option(value: Rect(LengthPercentageAuto), size: Size(?f32)) Rect(?f32) {
    return .{
        .left = resolve_auto_value(value.left, size.width),
        .right = resolve_auto_value(value.right, size.width),
        .top = resolve_auto_value(value.top, size.height),
        .bottom = resolve_auto_value(value.bottom, size.height),
    };
}

/// `Rect<LengthPercentageAuto>.map(LengthPercentageAuto::is_auto)`.
inline fn auto_rect(value: Rect(LengthPercentageAuto)) Rect(bool) {
    return .{
        .left = value.left.is_auto(),
        .right = value.right.is_auto(),
        .top = value.top.is_auto(),
        .bottom = value.bottom.is_auto(),
    };
}

/// `Size<Dimension>.maybe_resolve(Size<Option<f32>>)`.
inline fn resolve_dimension_size(value: Size(Dimension), parent: Size(?f32)) Size(?f32) {
    return .{
        .width = resolve_dimension_value(value.width, parent.width),
        .height = resolve_dimension_value(value.height, parent.height),
    };
}

/// `Size<LengthPercentageAuto>.maybe_resolve(Size<Option<f32>>)`.
inline fn resolve_auto_size(value: Size(LengthPercentageAuto), parent: Size(?f32)) Size(?f32) {
    return .{
        .width = resolve_auto_value(value.width, parent.width),
        .height = resolve_auto_value(value.height, parent.height),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "flex records hold a basis and violation" {
    const testing = std.testing;
    var item = FlexItem{
        .node = 1,
        .order = 0,
        .size = SIZE_NONE,
        .size_style = .{ .width = Dimension.auto, .height = Dimension.auto },
        .min_size = SIZE_NONE,
        .max_size = SIZE_NONE,
        .aspect_ratio = null,
        .align_self = style.alignment.AlignSelf.STRETCH,
        .overflow = .{ .x = .visible, .y = .visible },
        .contain = .{},
        .scrollbar_width = 0,
        .flex_shrink = 1,
        .flex_grow = 0,
        .flex_basis_is_definite = false,
        .resolved_minimum_main_size = 0,
        .margin = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        .margin_is_auto = .{ .left = false, .right = false, .top = false, .bottom = false },
        .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        .border = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        .flex_basis = 20,
        .inner_flex_basis = 0,
        .violation = 0,
        .frozen = false,
        .content_flex_fraction = 0,
        .hypothetical_inner_size = geometry.SIZE_F32_ZERO,
        .hypothetical_outer_size = geometry.SIZE_F32_ZERO,
        .target_size = geometry.SIZE_F32_ZERO,
        .outer_target_size = geometry.SIZE_F32_ZERO,
        .baseline = 0,
        .offset_main = 0,
        .offset_cross = 0,
        .relative_inset = geometry.SIZE_F32_ZERO,
        .oof_candidates = .empty,
    };
    item.violation = 3;
    try testing.expectEqual(@as(f32, 20), item.flex_basis);
    try testing.expectEqual(@as(f32, 3), item.violation);
}

test "flex wrap creates independent cross-axis lines" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const child_style = style.Style{ .size = .{ .width = .length(30), .height = .length(10) } };
    const first = try tree_ref.new_leaf(child_style);
    const second = try tree_ref.new_leaf(child_style);
    const root = try tree_ref.new_with_children(.{ .flex_wrap = .wrap, .size = .{ .width = .length(50), .height = .length(40) } }, &[_]NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 50 }, .height = .{ .definite = 40 } });
    const first_layout = try tree_ref.layout_of(first);
    const second_layout = try tree_ref.layout_of(second);
    try testing.expectEqual(@as(f32, 0), first_layout.location.y);
    try testing.expectEqual(@as(f32, 20), second_layout.location.y);
}

test "flex child layout receives used size for percentage descendants" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const grandchild = try tree_ref.new_leaf(.{ .size = .{ .width = .percent(1), .height = .length(10) } });
    const child = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .percent(0.5), .height = .length(20) } }, &[_]NodeId{grandchild});
    const root = try tree_ref.new_with_children(.{ .size = .{ .width = .length(80), .height = .length(30) } }, &[_]NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 80 }, .height = .{ .definite = 30 } });
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(grandchild)).size.width);
}

test "flex positions absolute children against the container" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const absolute = try tree_ref.new_leaf(.{
        .position = .absolute,
        .inset = .{ .left = .length(10), .right = .auto(), .top = .length(5), .bottom = .auto() },
        .size = .{ .width = .length(20), .height = .length(10) },
    });
    const root = try tree_ref.new_with_children(.{}, &[_]NodeId{absolute});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
    const result = try tree_ref.layout_of(absolute);
    try testing.expectEqual(@as(f32, 10), result.location.x);
    try testing.expectEqual(@as(f32, 5), result.location.y);
    try testing.expectEqual(@as(f32, 20), result.size.width);
}

test "flex reverse direction and auto margins use main-axis free space" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const first = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(10) } });
    const second = try tree_ref.new_leaf(.{ .size = .{ .width = .length(30), .height = .length(10) } });
    const reverse_root = try tree_ref.new_with_children(.{ .flex_direction = .row_reverse, .size = .{ .width = .length(100), .height = .length(20) } }, &[_]NodeId{ first, second });
    try tree_ref.compute_layout(reverse_root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 80), (try tree_ref.layout_of(first)).location.x);
    try testing.expectEqual(@as(f32, 50), (try tree_ref.layout_of(second)).location.x);

    var auto_tree = tree.Tree.init(testing.allocator);
    defer auto_tree.deinit();
    const auto_child = try auto_tree.new_leaf(.{
        .size = .{ .width = .length(20), .height = .length(10) },
        .margin = .{ .left = .auto(), .right = .zero(), .top = .zero(), .bottom = .zero() },
    });
    const auto_root = try auto_tree.new_with_children(.{ .size = .{ .width = .length(100), .height = .length(20) } }, &[_]NodeId{auto_child});
    try auto_tree.compute_layout(auto_root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 80), (try auto_tree.layout_of(auto_child)).location.x);
}

test "flex distributed justification expands inter-item gaps" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const item_style = style.Style{ .size = .{ .width = .length(10), .height = .length(10) } };
    const a = try tree_ref.new_leaf(item_style);
    const b = try tree_ref.new_leaf(item_style);
    const c = try tree_ref.new_leaf(item_style);
    const root = try tree_ref.new_with_children(.{ .justify_content = .space_between, .size = .{ .width = .length(100), .height = .length(20) } }, &[_]NodeId{ a, b, c });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(a)).location.x);
    try testing.expectEqual(@as(f32, 45), (try tree_ref.layout_of(b)).location.x);
    try testing.expectEqual(@as(f32, 90), (try tree_ref.layout_of(c)).location.x);
}

test "flexing freezes max violations and redistributes remaining space" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const first = try tree_ref.new_leaf(.{ .flex_basis = .length(20), .flex_grow = 1, .size = .{ .width = .auto, .height = .length(10) } });
    const second = try tree_ref.new_leaf(.{ .flex_basis = .length(20), .flex_grow = 1, .max_size = .{ .width = .length(30), .height = .auto() }, .size = .{ .width = .auto, .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .size = .{ .width = .length(100), .height = .length(20) } }, &[_]NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 20 } });
    try testing.expectEqual(@as(f32, 70), (try tree_ref.layout_of(first)).size.width);
    try testing.expectEqual(@as(f32, 30), (try tree_ref.layout_of(second)).size.width);
}

test "flex wrap-reverse stacks lines from the cross-axis end" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const child_style = style.Style{ .size = .{ .width = .length(30), .height = .length(10) } };
    const first = try tree_ref.new_leaf(child_style);
    const second = try tree_ref.new_leaf(child_style);
    const root = try tree_ref.new_with_children(.{ .flex_wrap = .wrap_reverse, .size = .{ .width = .length(50), .height = .length(40) } }, &[_]NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 50 }, .height = .{ .definite = 40 } });
    try testing.expectEqual(@as(f32, 30), (try tree_ref.layout_of(first)).location.y);
    try testing.expectEqual(@as(f32, 10), (try tree_ref.layout_of(second)).location.y);
}

/// The naive `O(line_count * item_count²)` dynamic program from the spec, used as a
/// test oracle for the divide-and-conquer optimized implementation. Direct port of
/// Taffy's `balance::tests::naive_line_item_counts`.
fn greedy_line_count(sizes: balance.LineSizes) usize {
    const count = sizes.item_count();
    var line_count: usize = 1;
    var index: usize = 0;
    while (index < count) {
        var next = index;
        while (next < count and sizes.line_size(index, next) <= sizes.limit) {
            next += 1;
        }
        if (next == index) {
            next = index + 1;
        }
        index = next;
        if (index < count) {
            line_count += 1;
        }
    }
    return line_count;
}

/// The zero-sized-item rule, brute force: a line `start..=end` (of a division of
/// `start..` into `lines` lines) may only end before a zero-sized item if no division
/// that extends the line through the item exists — every extension either exceeds the
/// limit or leaves the remaining items without a valid division into the remaining
/// lines. (`min_errors` rows below `lines` must already be computed.)
fn zero_boundary_valid(sizes: balance.LineSizes, min_errors: []const f64, lines: usize, start: usize, end: usize) bool {
    const count = sizes.item_count();
    if (!sizes.is_zero_item(end + 1)) {
        return true;
    }
    var glued_end = end + 1;
    while (glued_end + lines <= count) : (glued_end += 1) {
        if (sizes.line_size(start, glued_end) > sizes.limit) {
            break;
        }
        if (std.math.isFinite(min_errors[(lines - 2) * count + glued_end + 1])) {
            return false;
        }
    }
    return true;
}

fn naive_line_item_counts(
    allocator: std.mem.Allocator,
    item_sizes: []const f32,
    line_limit: f32,
    gap_between_items: f32,
    min_line_count: usize) ![]usize {
    const item_count = item_sizes.len;
    const gap = balance.to_size(gap_between_items);
    const limit: f64 = @floatCast(line_limit);

    const sums = try allocator.alloc(balance.LineSizes.SumEntry, item_count);
    defer allocator.free(sums);
    var sum: f64 = 0.0;
    for (item_sizes, 0..) |size, index| {
        const sized = balance.to_size(size);
        sum += sized + gap;
        sums[index] = .{ .sum = sum, .is_zero = sized == 0.0 };
    }
    const sizes = balance.LineSizes{ .sums = sums, .gap_between_items = gap, .limit = limit };

    const line_count = @max(greedy_line_count(sizes), std.math.clamp(min_line_count, 1, item_count));

    // `min_errors[(lines - 1) * item_count + start]` is the minimum total score of any
    // valid division of items `start..` into exactly `lines` lines
    const min_errors = try allocator.alloc(f64, line_count * item_count);
    defer allocator.free(min_errors);
    var write: usize = 0;
    for (0..item_count) |start| {
        min_errors[write] = sizes.line_cost(start, item_count - 1);
        write += 1;
    }
    for (2..line_count + 1) |lines| {
        const row = (lines - 1) * item_count;
        for (0..item_count) |start| {
            var min_error = balance.INFEASIBLE;
            var end = start;
            while (end + lines <= item_count) {
                const line_cost = sizes.line_cost(start, end);
                if (line_cost == balance.INFEASIBLE) {
                    break;
                }
                if (zero_boundary_valid(sizes, min_errors, lines, start, end)) {
                    const candidate_error = line_cost + min_errors[row - item_count + end + 1];
                    if (candidate_error < min_error) {
                        min_error = candidate_error;
                    }
                }
                end += 1;
            }
            min_errors[write] = min_error;
            write += 1;
        }
    }

    // For each line, the *largest* end whose error plus the minimum remaining error
    // adds up to the (feasible) minimum is chosen
    std.debug.assert(std.math.isFinite(min_errors[(line_count - 1) * item_count]));
    const item_counts = try allocator.alloc(usize, line_count);
    var start: usize = 0;
    var output_index: usize = 0;
    var lines_after = line_count;
    while (lines_after > 0) {
        lines_after -= 1;
        const target = min_errors[lines_after * item_count + start];
        var end = item_count - 1 - lines_after;
        while (true) {
            if (sizes.line_cost(start, end) != balance.INFEASIBLE and
                (lines_after == 0 or zero_boundary_valid(sizes, min_errors, lines_after + 1, start, end)))
            {
                const remaining_error =
                    if (lines_after == 0) 0.0 else min_errors[(lines_after - 1) * item_count + end + 1];
                if (sizes.line_cost(start, end) + remaining_error == target) {
                    break;
                }
            }
            std.debug.assert(end > start);
            end -= 1;
        }
        item_counts[output_index] = end - start + 1;
        output_index += 1;
        start = end + 1;
    }
    std.debug.assert(start == item_count);
    return item_counts;
}

fn xorshift(state: *u64, bound: u32) u32 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return @as(u32, @truncate(state.* >> 32)) % bound;
}

test "balance dynamic program matches the naive DP" {
    const testing = std.testing;
    const allocator = testing.allocator;
    // A simple xorshift PRNG so the test is deterministic and dependency-free
    var state: u64 = 0x243F6A8885A308D3;

    var case: usize = 0;
    while (case < 5000) : (case += 1) {
        // Mostly small item counts (quantized sizes maximize ties, exercising the
        // tie-break rules), with some larger ones exercising the recursion
        const item_count: usize = if (case % 20 == 0) xorshift(&state, 60) + 1 else xorshift(&state, 15) + 1;
        const item_sizes = try allocator.alloc(f32, item_count);
        defer allocator.free(item_sizes);
        for (item_sizes) |*size| {
            size.* = switch (xorshift(&state, 8)) {
                // Frequent zero items exercise the zero-sized-item rule
                0, 1 => 0.0,
                2 => -10.0,
                else => @as(f32, @floatFromInt(xorshift(&state, 8))) * 25.0,
            };
        }
        const line_limit: f32 = switch (xorshift(&state, 5)) {
            0 => std.math.inf(f32),
            else => @as(f32, @floatFromInt(xorshift(&state, 10))) * 30.0,
        };
        const gap_between_items: f32 = @as(f32, @floatFromInt(xorshift(&state, 4))) * 5.0;
        const min_line_count: usize = xorshift(&state, @intCast(item_count + 2));

        const expected = try naive_line_item_counts(allocator, item_sizes, line_limit, gap_between_items, min_line_count);
        defer allocator.free(expected);
        const actual = try balance.balanced_line_item_counts(allocator, item_sizes, line_limit, gap_between_items, min_line_count);
        defer allocator.free(actual);
        testing.expectEqualSlices(usize, expected, actual) catch |err| {
            std.debug.print(
                "case {d}: item_sizes={any} line_limit={d} gap={d} min_line_count={d}\n",
                .{ case, item_sizes, line_limit, gap_between_items, min_line_count });
            return err;
        };
    }
}

test "balance zero sized item rule matches the reference oracle" {
    const testing = std.testing;
    const allocator = testing.allocator;
    // [70, 0] / [20] has line sizes 80 / 20 (score 6800), while [70] / [0, 20]
    // would have line sizes 70 / 30 (score 5800)
    {
        const counts = try balance.balanced_line_item_counts(allocator, &[_]f32{ 70.0, 0.0, 20.0 }, 100.0, 10.0, 1);
        defer allocator.free(counts);
        try testing.expectEqualSlices(usize, &[_]usize{ 2, 1 }, counts);
    }
    // The zero item is not glued to a single overflowing item's line
    {
        const counts = try balance.balanced_line_item_counts(allocator, &[_]f32{ 150.0, 0.0, 30.0 }, 100.0, 0.0, 1);
        defer allocator.free(counts);
        try testing.expectEqualSlices(usize, &[_]usize{ 1, 2 }, counts);
    }
    // Zero items are glued as far as the requested line count allows
    {
        const counts = try balance.balanced_line_item_counts(allocator, &[_]f32{ 70.0, 0.0, 0.0 }, 100.0, 0.0, 2);
        defer allocator.free(counts);
        try testing.expectEqualSlices(usize, &[_]usize{ 2, 1 }, counts);
    }
}

test "flex-wrap balance splits items across lines" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const item_style = style.Style{ .size = .{ .width = .length(30), .height = .length(10) } };
    const a = try tree_ref.new_leaf(item_style);
    const b = try tree_ref.new_leaf(item_style);
    const c = try tree_ref.new_leaf(item_style);
    const root = try tree_ref.new_with_children(.{
        .flex_wrap = .balance,
        .size = .{ .width = .length(60), .height = .length(40) },
    }, &[_]NodeId{ a, b, c });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 60 }, .height = .{ .definite = 40 } });
    // Ties are broken by assigning the most items to the first line: [a, b] / [c],
    // and align-content: stretch spreads the two lines over the 40px cross size.
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(a)).location.y);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(b)).location.y);
    try testing.expectEqual(@as(f32, 20), (try tree_ref.layout_of(c)).location.y);
}
