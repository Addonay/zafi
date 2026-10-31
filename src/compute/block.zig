//! Direct port of Taffy's `compute/block.rs`.
//!
//! Computes the CSS block layout algorithm in the case that the block container being laid out
//! contains only block-level boxes. The file keeps Taffy's phase order, helper names and
//! formulas so it can be compared against the Rust implementation section by section.

const std = @import("std");

const geometry = @import("../geometry.zig");
const style = @import("../style/root.zig");
const NodeId = @import("../tree/node.zig").NodeId;
const layout = @import("../tree/layout.zig");
const float = @import("float.zig");
const sizing_keyword = @import("common/sizing_keyword.zig");
const alignment = @import("common/alignment.zig");
const scrollable_overflow = @import("common/scrollable_overflow.zig");
const oof = @import("oof.zig");
const compute = @import("root.zig");
const math = @import("../util/math.zig");
const LayoutTree = @import("../tree/interfaces.zig").LayoutTree;
const tree = @import("../tree/tree.zig");

pub const ContentSlot = float.ContentSlot;
pub const BfcSlot = float.BfcSlot;
pub const FIT_TOLERANCE = float.FIT_TOLERANCE;

const SIZE_NONE: geometry.Size(?f32) = .{ .width = null, .height = null };
const RECT_ZERO: geometry.Rect(f32) = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 };

/// Context for positioning Block and Float boxes within a Block Formatting Context
/// The block-axis offset `align-content` applies to a block container's in-flow
/// content given the free space between its content box and that content. The
/// whole stack of in-flow content is one alignment subject, so the distribution
/// keywords use their single-subject fallbacks. Also useful to hosts laying out
/// inline formatting contexts (line boxes) outside zafi.
pub fn compute_block_align_content_offset(align_content: style.alignment.AlignContent, free_space: f32) f32 {
    const keyword = alignment.apply_alignment_fallback(free_space, 1, align_content);
    return alignment.compute_alignment_offset(free_space, 1, 0.0, keyword, false, true);
}

pub const BlockFormattingContext = struct {
    /// The float positioning context that handles positioning floats within this Block Formatting Context
    float_context: float.FloatContext,

    /// Create a new `BlockFormattingContext`.
    pub fn new(allocator: std.mem.Allocator) BlockFormattingContext {
        return .{ .float_context = float.FloatContext.init(allocator) };
    }

    pub fn deinit(self: *BlockFormattingContext) void {
        self.float_context.deinit();
    }

    /// Create an initial `BlockContext` for this `BlockFormattingContext`
    pub fn root_block_context(self: *BlockFormattingContext) BlockContext {
        return .{
            .bfc = self,
            .y_offset = 0,
            .insets = .{ 0, 0 },
            .content_box_insets = .{ 0, 0 },
            .float_content_contribution = -std.math.inf(f32),
            .is_root = true,
            .adjoining_floats = .{ false, false },
            .top_adjoining_floats_state = null,
        };
    }
};

/// Context for each individual Block within a Block Formatting Context
///
/// Contains a mutable reference to the BlockFormattingContext + block-specific data
pub const BlockContext = struct {
    /// A mutable reference to the root BlockFormattingContext that this BlockContext belongs to
    bfc: *BlockFormattingContext,
    /// The y-offset of the border-top of the block node, relative to the border-top of the
    /// root node of the Block Formatting Context it belongs to.
    y_offset: f32 = 0,
    /// The x-inset of the border-box in from each side of the block node, relative to the root
    /// node of the Block Formatting Context it belongs to.
    insets: [2]f32 = .{ 0, 0 },
    /// The x-insets of the content box
    content_box_insets: [2]f32 = .{ 0, 0 },
    /// The height that floats take up in the element (`f32::NEG_INFINITY` if the element's
    /// subtree does not contain any floats)
    float_content_contribution: f32 = -std.math.inf(f32),
    /// Whether the node is the root of the Block Formatting Context it belongs to.
    is_root: bool = false,
    /// Whether a float has been placed (on each side) whose position adjoins the current
    /// margin-collapse strut of this block (i.e. whose final position can still be moved by
    /// margins that collapse into that strut). Such floats force clearance on cleared elements
    /// whose margins adjoin the same strut.
    adjoining_floats: [2]bool = .{ false, false },
    /// The value of `adjoining_floats` frozen at the first point at which in-flow content was
    /// committed within this block (resolving the position of the block's top margin strut).
    /// `None` if no in-flow content has been committed yet.
    top_adjoining_floats_state: ?[2]bool = null,

    /// Create a sub-`BlockContext` for a child block node
    pub fn sub_context(self: *BlockContext, additional_y_offset: f32, insets: [2]f32) BlockContext {
        const new_insets = [2]f32{ self.insets[0] + insets[0], self.insets[1] + insets[1] };
        return .{
            .bfc = self.bfc,
            .y_offset = self.y_offset + additional_y_offset,
            .insets = new_insets,
            .content_box_insets = new_insets,
            .float_content_contribution = -std.math.inf(f32),
            .is_root = false,
            // Floats adjoining the parent's current strut also adjoin this block's top strut
            // (if this block's top margin collapses with its first child's, which is checked separately)
            .adjoining_floats = self.adjoining_floats,
            .top_adjoining_floats_state = null,
        };
    }

    /// Returns whether this block is the root block of it's Block Formatting Context
    pub fn is_bfc_root(self: BlockContext) bool {
        return self.is_root;
    }

    /// Set the width of the overall Block Formatting Context. This is used to resolve positions
    /// that are relative to the right of the context such as right-floated boxes.
    pub fn set_width(self: *BlockContext, available_width: f32) void {
        self.bfc.float_context.set_width(available_width);
    }

    /// Set the x-axis content-box insets of the `BlockContext`. These are the difference between
    /// the border-box and the content-box of the box (padding + border + scrollbar_gutter).
    pub fn apply_content_box_inset(self: *BlockContext, content_box_x_insets: [2]f32) void {
        self.content_box_insets[0] = self.insets[0] + content_box_x_insets[0];
        self.content_box_insets[1] = self.insets[1] + content_box_x_insets[1];
    }

    /// Whether the float context contains any floats
    pub fn has_floats(self: BlockContext) bool {
        return self.bfc.float_context.has_floats();
    }

    /// Whether the float context contains any floats that extend to or below min_y
    pub fn has_active_floats(self: BlockContext, min_y: f32) bool {
        return self.bfc.float_context.has_active_floats(min_y + self.y_offset);
    }

    /// Position a floated box with the context
    pub fn place_floated_box(
        self: *BlockContext,
        floated_box: geometry.Size(f32),
        min_y: f32,
        direction: style.float.FloatDirection,
        clear: style.float.Clear,
        adjoins_unresolved_strut: bool) geometry.Point(f32) {
        if (adjoins_unresolved_strut) {
            self.adjoining_floats[@backingInt(direction)] = true;
        }
        var pos = self.bfc.float_context.place_floated_box(
            floated_box,
            min_y + self.y_offset,
            self.content_box_insets,
            direction,
            clear);
        pos.y -= self.y_offset;
        pos.x -= self.insets[0];

        self.float_content_contribution = @max(self.float_content_contribution, pos.y + floated_box.height);

        return pos;
    }

    /// Search a space suitable for laying out non-floated content into
    pub fn find_content_slot(self: BlockContext, min_y: f32, clear: style.float.Clear, after: ?usize) ContentSlot {
        var slot =
            self.bfc.float_context.find_content_slot(min_y + self.y_offset, self.content_box_insets, clear, after);
        slot.y -= self.y_offset;
        slot.x -= self.insets[0];
        return slot;
    }

    /// Search for a space suitable for laying out a box that establishes an independent
    /// formatting context (whose border box must not overlap floats)
    pub fn find_bfc_slot(self: BlockContext, min_y: f32, margins: [2]f32, direction: style.Direction, clear: style.float.Clear, after: ?usize) BfcSlot {
        var slot = self.bfc.float_context.find_bfc_slot(
            min_y + self.y_offset,
            self.content_box_insets,
            margins,
            direction,
            clear,
            after);
        slot.y -= self.y_offset;
        slot.x -= self.insets[0];
        return slot;
    }

    /// Get the bottom of lowest relevant float for the specific clear property
    pub fn cleared_threshold(self: BlockContext, clear: style.float.Clear) ?f32 {
        return if (self.bfc.float_context.cleared_threshold(clear)) |threshold| threshold - self.y_offset else null;
    }

    /// Whether a float that is adjoining the current margin-collapse strut has been placed
    /// on the side(s) relevant to the passed clear property
    pub fn has_adjoining_float(self: BlockContext, clear: style.float.Clear) bool {
        return switch (clear) {
            .left => self.adjoining_floats[0],
            .right => self.adjoining_floats[1],
            .both => self.adjoining_floats[0] or self.adjoining_floats[1],
            .none => false,
        };
    }

    /// Merge adjoining float flags propagated from a child block into this block's flags
    fn merge_adjoining_floats(self: *BlockContext, flags: [2]bool) void {
        self.adjoining_floats[0] = self.adjoining_floats[0] or flags[0];
        self.adjoining_floats[1] = self.adjoining_floats[1] or flags[1];
    }

    /// Record that in-flow content has been committed within this block, resolving the position of
    /// the current margin-collapse strut. Floats placed before this point no longer adjoin the
    /// current strut. The flags for the block's top strut are frozen at the first commit.
    fn commit_strut(self: *BlockContext) void {
        if (self.top_adjoining_floats_state == null) {
            self.top_adjoining_floats_state = self.adjoining_floats;
        }
        self.adjoining_floats = .{ false, false };
    }

    /// The adjoining float flags for this block's top margin strut: floats placed while the
    /// position of the block's top strut was still unresolved
    fn top_adjoining_floats(self: BlockContext) [2]bool {
        return self.top_adjoining_floats_state orelse self.adjoining_floats;
    }

    /// Update the height that descendant floats consume within a particular child
    /// `child_contribution` is relative to this block's border-top.
    pub fn add_child_floated_content_height_contribution(self: *BlockContext, child_contribution: f32) void {
        self.float_content_contribution = @max(self.float_content_contribution, child_contribution);
    }

    /// Returns the height that descendant floats consume
    pub fn floated_content_height_contribution(self: BlockContext) f32 {
        return self.float_content_contribution;
    }
};

/// Per-child data that is accumulated and modified over the course of the layout algorithm
const BlockItem = struct {
    /// The identifier for the associated node
    node_id: NodeId,

    /// The "source order" of the item. This is the index of the item within the children iterator,
    /// and controls the order in which the nodes are placed
    order: u32,

    /// Items that are tables don't have stretch sizing applied to them
    is_table: bool,

    /// Items that are replaced elements resolve an auto width to their intrinsic size
    /// rather than being stretch-sized
    /// <https://www.w3.org/TR/CSS22/visudet.html#block-replaced-width>
    is_compressible_replaced: bool,

    /// Whether the child is a non-independent block or inline node
    is_in_same_bfc: bool,

    /// Whether the child has no children of its own. Childless children never need the block
    /// formatting context threaded through their layout, so the parent can dispatch them
    /// straight to the generic (cached) child-layout path.
    is_leaf: bool,

    /// The `float` style of the node
    float: style.float.Float,
    /// The `clear` style of the node
    clear: style.float.Clear,

    /// The size style of this item. Used to detect and resolve sizing keywords.
    size_style: geometry.Size(style.dimension.Dimension),

    /// The base size of this item
    size: geometry.Size(?f32),
    /// The minimum allowable size of this item
    min_size: geometry.Size(?f32),
    /// The maximum allowable size of this item
    max_size: geometry.Size(?f32),

    /// The overflow style of the item
    overflow: geometry.Point(style.Overflow),
    /// The contain style of the item
    contain: style.Contain,
    /// The width of the item's scrollbars (if it has scrollbars)
    scrollbar_width: f32,

    /// The position style of the item
    position: style.Position,
    /// The `direction` style of the item (resolves `self-start`/`self-end`)
    direction: style.Direction,
    /// `align-self` (`null` = auto); derives out-of-flow static positions
    align_self: ?style.alignment.AlignSelf,
    /// `justify-self` (`null` = auto: the container's `justify-items`)
    justify_self: ?style.alignment.AlignSelf,
    /// The final offset of this item
    inset: geometry.Rect(style.dimension.LengthPercentageAuto),
    /// The margin of this item
    margin: geometry.Rect(style.dimension.LengthPercentageAuto),
    /// The padding of this item
    padding: geometry.Rect(f32),
    /// The border of this item
    border: geometry.Rect(f32),
    /// The sum of padding and border for this item
    padding_border_sum: geometry.Size(f32),

    /// The computed border box size of this item
    computed_size: geometry.Size(f32) = .{ .width = 0, .height = 0 },
    /// The computed "static position" of this item.
    static_position: geometry.Point(f32) = .{ .x = 0, .y = 0 },
    /// Whether margins can be collapsed through this item
    can_be_collapsed_through: bool = false,

    /// Pending layout for in-flow non-floated items. Held back from `set_unrounded_layout` so the
    /// post-loop `align-content` pass in `compute_inner` can shift `location.y` before commit.
    final_layout: ?layout.Layout = null,

    /// Out-of-flow candidates bubbled out of this (in-flow) item's subtree. Anchors are relative
    /// to the item's border box until they are translated at merge time.
    oof_candidates: layout.OofCandidates = .empty,
};

/// The visible children of a block container, plus flags recording which optional later passes
/// (absolute layout, hidden layout) have any work to do.
const ItemList = struct {
    list: std.ArrayList(BlockItem),
    /// Whether any child has `display: none`.
    has_hidden: bool = false,
};

/// Computes the layout of a block container according to the block layout algorithm
pub const BlockError = error{ InvalidParentNode, InvalidChildNode, InvalidInputNode, ChildIndexOutOfBounds, InvalidLayoutMode, OutOfMemory, Cycle, DuplicateChild, NodeIdExhausted };

pub fn compute_block_layout(comptime Tree: type, tree_ref: *Tree,
    node_id: NodeId,
    inputs: layout.LayoutInput,
    block_ctx: ?*BlockContext) BlockError!layout.LayoutOutput {
    const TreeApi = LayoutTree(Tree);
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;
    const run_mode = inputs.run_mode;
    const style_value = TreeApi.get_style(tree_ref, node_id);

    // Pull these out earlier to avoid borrowing issues
    const overflow = style_value.overflow;
    const is_scroll_container = overflow.x.is_scroll_container() or overflow.y.is_scroll_container();
    const contain = style_value.contain;
    // css-align-3 §5.1.1: a non-`normal` `align-content` makes a block container establish an
    // independent formatting context. Layout and paint containment also establish one.
    const establishes_new_bfc =
        is_scroll_container or style_value.align_content.keyword != .normal or contain.establishes_independent_formatting_context();
    const aspect_ratio = style_value.aspect_ratio;
    const padding = resolveOrZeroRect(style_value.padding, parent_size.width);
    const border = resolveOrZeroRect(style_value.border, parent_size.width);
    const padding_border_size = padding.add(border).sum_axes();
    const box_sizing_adjustment =
        if (style_value.box_sizing == .content_box) padding_border_size else geometry.Size(f32){ .width = 0, .height = 0 };

    const min_size = maybeAddSize(geometry.optional_f32_size_maybe_apply_aspect_ratio(resolveAutoSize(style_value.min_size, parent_size), aspect_ratio), box_sizing_adjustment);
    const max_size = maybeAddSize(geometry.optional_f32_size_maybe_apply_aspect_ratio(resolveAutoSize(style_value.max_size, parent_size), aspect_ratio), box_sizing_adjustment);
    const clamped_style_size = if (inputs.sizing_mode == .inherent_size)
        math.optional_size_maybe_clamp(
            maybeAddSize(geometry.optional_f32_size_maybe_apply_aspect_ratio(resolveDimensionSize(style_value.size, parent_size), aspect_ratio), box_sizing_adjustment),
            min_size,
            max_size)
    else
        SIZE_NONE;

    // If both min and max in a given axis are set and max <= min then this determines the size in that axis
    const min_max_definite_size = geometry.Size(?f32){
        .width = if (min_size.width) |min| (if (max_size.width) |max| (if (max <= min) min else null) else null) else null,
        .height = if (min_size.height) |min| (if (max_size.height) |max| (if (max <= min) min else null) else null) else null,
    };

    const styled_based_known_dimensions = maybeMaxSizeF32(
        optionalSizeOr(optionalSizeOr(optionalSizeOr(known_dimensions, min_max_definite_size), clamped_style_size), SIZE_NONE),
        padding_border_size);

    // Short-circuit layout if the container's size is fully determined by the container's size and
    // the run mode is ComputeSize (and thus the container's size is all that we're interested in)
    if (run_mode == .compute_size) {
        if (styled_based_known_dimensions.width != null and styled_based_known_dimensions.height != null) {
            return layout.LayoutOutput.from_outer_size(.{ .width = styled_based_known_dimensions.width.?, .height = styled_based_known_dimensions.height.? });
        }
        if (inputs.axis == .horizontal) {
            if (styled_based_known_dimensions.width) |width| {
                return layout.LayoutOutput.from_outer_size(.{ .width = width, .height = 0 });
            }
        }
    }

    var forwarded_inputs = inputs;
    forwarded_inputs.known_dimensions = styled_based_known_dimensions;

    // Unwrap the block formatting context if one was passed, or else create a new one
    var output: layout.LayoutOutput = undefined;
    if (block_ctx != null and !establishes_new_bfc) {
        output = try compute_inner(Tree, tree_ref, node_id, forwarded_inputs, block_ctx.?);
    } else {
        var root_bfc = BlockFormattingContext.new(tree_ref.allocator);
        defer root_bfc.deinit();
        var root_ctx = root_bfc.root_block_context();
        output = try compute_inner(Tree, tree_ref, node_id, forwarded_inputs, &root_ctx);
    }

    // Layout containment suppresses the box's baseline for baseline-alignment purposes
    if (contain.suppresses_baseline()) {
        output.baselines = layout.Baselines.none;
    }

    return output;
}

/// Compute a child's size or layout, passing an inherited block formatting context through the
/// dispatch so that `.block` children share their parent's floats and margin-collapse state.
///
/// This mirrors `TaffyView::compute_child_layout` with the `block_ctx` parameter.
/// Taffy `LayoutBlockContainer::compute_block_child_layout`: lay out a block
/// child with an inherited block formatting context.
///
/// This is a thin wrapper over the shared cached dispatcher rather than a second
/// dispatch path. Sharing the dispatcher is what keeps the out-of-flow
/// positioning pass running for a block child that acts as a containing block
/// for its out-of-flow descendants.
pub fn compute_block_child_layout(comptime Tree: type, tree_ref: *Tree,
    node_id: NodeId,
    inputs: layout.LayoutInput,
    block_ctx: ?*BlockContext) BlockError!layout.LayoutOutput {
    return compute.cached_layout_with_block_ctx(Tree, tree_ref, node_id, inputs, block_ctx);
}

/// Computes the layout of a block container according to the block layout algorithm
fn compute_inner(comptime Tree: type, tree_ref: *Tree,
    node_id: NodeId,
    inputs: layout.LayoutInput,
    block_ctx: *BlockContext) BlockError!layout.LayoutOutput {
    const TreeApi = LayoutTree(Tree);
    const known_dimensions = inputs.known_dimensions;
    const parent_size = inputs.parent_size;
    const available_space = inputs.available_space;
    const run_mode = inputs.run_mode;
    const vertical_margins_are_collapsible = inputs.vertical_margins_are_collapsible;

    const style_value = TreeApi.get_style(tree_ref, node_id);
    const raw_padding = style_value.padding;
    const raw_border = style_value.border;
    const raw_margin = style_value.margin;
    const aspect_ratio = style_value.aspect_ratio;
    const padding = resolveOrZeroRect(raw_padding, parent_size.width);
    const border = resolveOrZeroRect(raw_border, parent_size.width);
    const direction = style_value.direction;

    // Scrollbar gutters are reserved when the `overflow` property is set to `Overflow::Scroll`.
    // However, the axis are switched (transposed) because a node that scrolls vertically needs
    // *horizontal* space to be reserved for a scrollbar
    const scrollbar_gutter = blk: {
        const offsets = geometry.Point(f32){
            .x = if (style_value.overflow.y == .scroll) style_value.scrollbar_width else 0,
            .y = if (style_value.overflow.x == .scroll) style_value.scrollbar_width else 0,
        };
        break :blk switch (direction) {
            .ltr => geometry.Rect(f32){ .top = 0, .left = 0, .right = offsets.x, .bottom = offsets.y },
            .rtl => geometry.Rect(f32){ .top = 0, .left = offsets.x, .right = 0, .bottom = offsets.y },
        };
    };
    const padding_border = padding.add(border);
    const padding_border_size = padding_border.sum_axes();
    const content_box_inset = padding_border.add(scrollbar_gutter);

    // Apply content box inset
    block_ctx.apply_content_box_inset(.{ content_box_inset.left, content_box_inset.right });

    const box_sizing_adjustment =
        if (style_value.box_sizing == .content_box) padding_border_size else geometry.Size(f32){ .width = 0, .height = 0 };
    const size = maybeAddSize(geometry.optional_f32_size_maybe_apply_aspect_ratio(resolveDimensionSize(style_value.size, parent_size), aspect_ratio), box_sizing_adjustment);
    const min_size = maybeAddSize(geometry.optional_f32_size_maybe_apply_aspect_ratio(resolveAutoSize(style_value.min_size, parent_size), aspect_ratio), box_sizing_adjustment);
    const max_size = maybeAddSize(geometry.optional_f32_size_maybe_apply_aspect_ratio(resolveAutoSize(style_value.max_size, parent_size), aspect_ratio), box_sizing_adjustment);

    // css-sizing-4: a definite size in one axis transfers through `aspect-ratio`
    // to make the other definite.
    const known_dimensions_final = blk: {
        const derived = math.optional_size_maybe_clamp(geometry.optional_f32_size_maybe_apply_aspect_ratio(known_dimensions, aspect_ratio), min_size, max_size);
        break :blk geometry.Size(?f32){
            .width = known_dimensions.width orelse derived.width,
            .height = known_dimensions.height orelse derived.height,
        };
    };
    const percentage_basis_dimensions = geometry.Size(?f32){
        .width = known_dimensions_final.width,
        .height = if (inputs.known_dimensions_are_definite.height) known_dimensions_final.height else null,
    };
    const container_content_box_size = maybeSubSize(percentage_basis_dimensions, content_box_inset.sum_axes());

    const overflow = style_value.overflow;
    const is_scroll_container = overflow.x.is_scroll_container() or overflow.y.is_scroll_container();
    const establishes_new_bfc = is_scroll_container or style_value.align_content.keyword != .normal or style_value.contain.establishes_independent_formatting_context() or style_value.establishes_formatting_context_from_display();

    // Determine margin collapsing behaviour
    const own_margins_collapse_with_children = geometry.Line(bool){
        .start = vertical_margins_are_collapsible.start and !establishes_new_bfc and !style_value.position.is_out_of_flow() and padding.top == 0.0 and border.top == 0.0,
        .end = vertical_margins_are_collapsible.end and !establishes_new_bfc and !style_value.position.is_out_of_flow() and padding.bottom == 0.0 and border.bottom == 0.0 and size.height == null,
    };
    const has_styles_preventing_being_collapsed_through = !style_value.is_block() or block_ctx.is_bfc_root() or establishes_new_bfc or style_value.position.is_out_of_flow() or padding.top > 0.0 or padding.bottom > 0.0 or border.top > 0.0 or border.bottom > 0.0;

    const text_align = style_value.text_align;
    const align_content = style_value.align_content;
    const justify_items = style_value.justify_items;

    // 1. Generate items
    //
    // Typical containers have only a handful of children, so the item list lives on the stack
    // (`BufferFirstAllocator`) and only spills to the tree allocator for large child lists. The
    // buffer must outlive the recursive child layout below, hence its declaration here rather
    // than inside `generate_item_list`.
    var item_buffer: [8]BlockItem = undefined;
    var item_allocator_buffer = std.heap.BufferFirstAllocator.init(std.mem.sliceAsBytes(item_buffer[0..]), tree_ref.allocator);
    const items_allocator = item_allocator_buffer.allocator();
    var items = try generate_item_list(Tree, tree_ref, node_id, container_content_box_size, items_allocator);
    defer items.list.deinit(items_allocator);

    // 2. Compute container width
    const container_outer_width = known_dimensions_final.width orelse blk: {
        const available_width = math.available_maybe_sub(available_space.width, content_box_inset.horizontal_axis_sum());
        const intrinsic_width = try determine_content_based_container_width(Tree, tree_ref, items.list.items, available_width) + content_box_inset.horizontal_axis_sum();
        break :blk @max(math.f32_maybe_clamp(intrinsic_width, min_size.width, max_size.width), padding_border_size.width);
    };

    // Short-circuit if computing size and both dimensions known
    if (run_mode == .compute_size) {
        if (known_dimensions_final.height) |container_outer_height| {
            return layout.LayoutOutput.from_outer_size(.{ .width = container_outer_width, .height = container_outer_height });
        }
    }

    // We can also short-circuit if the width is known and only the width has been requested.
    if (run_mode == .compute_size and inputs.axis == .horizontal) {
        return layout.LayoutOutput.from_outer_size(.{ .width = container_outer_width, .height = 0.0 });
    }

    // Under `SizingMode.ContentSize` the container's own `height`/`min-height` are
    // ignored, so they cannot serve as the percentage basis for children either
    // (https://drafts.csswg.org/css-flexbox/#min-size-auto: the content size
    // suggestion must not be influenced by the item's specified height).
    const container_percentage_resolution_height: ?f32 = if (percentage_basis_dimensions.height) |height|
        height
    else if (inputs.sizing_mode == .inherent_size)
        math.maybe_max(size.height, min_size.height)
    else
        null;

    // 3. Perform final item layout and return content height
    const percentage_resolution_width = parent_size.width orelse container_outer_width;
    const resolved_padding = resolveOrZeroRect(raw_padding, percentage_resolution_width);
    const resolved_border = resolveOrZeroRect(raw_border, percentage_resolution_width);
    const resolved_content_box_inset = resolved_padding.add(resolved_border).add(scrollbar_gutter);
    // Child layouts are only committed to the tree (and read back by the `align-content` pass)
    // during a final layout pass. In a `ComputeSize` pass without an `align-content` shift they
    // are dead stores, so skip building them.
    const store_layouts = run_mode != .compute_size or align_content.keyword != .normal;
    var inflow_result = try perform_final_layout_on_in_flow_children(
        Tree,
tree_ref,
        run_mode,
        items.list.items,
        container_outer_width,
        container_percentage_resolution_height,
        content_box_inset,
        resolved_content_box_inset,
        resolved_border,
        text_align,
        justify_items,
        direction,
        own_margins_collapse_with_children,
        is_scroll_container,
        store_layouts,
        block_ctx);

    // Root BFCs contain floats
    var intrinsic_outer_height = inflow_result.intrinsic_outer_height;
    if (block_ctx.is_bfc_root() or establishes_new_bfc) {
        intrinsic_outer_height = @max(intrinsic_outer_height, block_ctx.floated_content_height_contribution());
    }

    var container_outer_height = known_dimensions_final.height orelse math.f32_maybe_clamp(intrinsic_outer_height, min_size.height, max_size.height);
    container_outer_height = @max(container_outer_height, padding_border_size.height);
    const final_outer_size = geometry.Size(f32){ .width = container_outer_width, .height = container_outer_height };

    // CSS2 §8.3.1: the bottom margin of a block with `height: auto` collapses with its last
    // in-flow child's bottom margin only if the box's `min-height` is less than the box's
    // used height.
    const height_constrained_by_min_height = if (min_size.height) |h| (h > 0.0 and h >= container_outer_height) else false;
    const own_bottom_margin_collapses_with_children =
        own_margins_collapse_with_children.end and !height_constrained_by_min_height;

    // Apply `align-content` to in-flow non-floated items if requested.
    if (align_content.keyword != .normal) {
        const align_content_value = align_content;
        const container_inner_height = container_outer_height - resolved_content_box_inset.vertical_axis_sum();
        const inflow_content_height = intrinsic_outer_height - resolved_content_box_inset.vertical_axis_sum();
        const free_space = container_inner_height - inflow_content_height;
        const group_offset = compute_block_align_content_offset(align_content_value, free_space);
        if (inflow_result.first_baseline) |baseline| {
            inflow_result.first_baseline = baseline + group_offset;
        }
        for (items.list.items) |*item| {
            if (item.final_layout) |*item_layout| {
                item_layout.location.y += group_offset;
            }
            // The static positions of out-of-flow children move with the in-flow content
            if (item.position.is_out_of_flow()) item.static_position.y += group_offset;
        }
        var any_in_flow = false;
        for (items.list.items) |item| {
            if (item.final_layout != null) {
                any_in_flow = true;
                break;
            }
        }
        if (any_in_flow) {

            {
                inflow_result.inflow_overflow_rect = RECT_ZERO;
                for (items.list.items) |item| {
                    if (item.final_layout) |item_layout| {
                        const contribution_location = if (direction.is_rtl())
                            geometry.Point(f32){
                                .x = container_outer_width - (item_layout.location.x + item_layout.size.width) - resolved_border.right,
                                .y = item_layout.location.y - resolved_border.top,
                            }
                        else
                            geometry.Point(f32){
                                .x = item_layout.location.x - resolved_border.left,
                                .y = item_layout.location.y - resolved_border.top,
                            };
                        inflow_result.inflow_overflow_rect = inflow_result.inflow_overflow_rect.@"union"(scrollable_overflow.compute_scrollable_overflow_contribution(
                            contribution_location,
                            item_layout.size,
                            item_layout.scrollable_overflow_rect,
                            item.overflow,
                            item.contain,
                            is_scroll_container));
                    }
                }
            }
        }
    }

    // Determine whether this node can be collapsed through
    var all_in_flow_children_can_be_collapsed_through = true;
    for (items.list.items) |item| {
        if (style.float.is_floated(item.float)) continue;
        if (item.position.is_out_of_flow() or item.can_be_collapsed_through) continue;
        all_in_flow_children_can_be_collapsed_through = false;
        break;
    }
    // CSS2 §8.3.1: a box's top and bottom margins collapse through it only if its
    // *used* height is zero, so `height`/`min-height`/`max-height` are judged by the
    // height they resolve to (e.g. `height: 1px; max-height: 0` collapses,
    // `min-height: 1%` under an auto-height parent collapses) rather than by their
    // computed values.
    const can_be_collapsed_through = !has_styles_preventing_being_collapsed_through and
        container_outer_height == 0.0 and
        all_in_flow_children_can_be_collapsed_through;

    var output = layout.LayoutOutput{
        .size = final_outer_size,
        .scrollable_overflow_rect = RECT_ZERO,
        .baselines = layout.Baselines.from_first(inflow_result.first_baseline),
        .top_margin = if (own_margins_collapse_with_children.start)
            inflow_result.first_child_top_margin_set
        else
            layout.CollapsibleMarginSet.from_margin(resolveAutoOrZeroRect(raw_margin, parent_size.width).top),
        .bottom_margin = if (own_bottom_margin_collapses_with_children)
            inflow_result.last_child_bottom_margin_set
        else
            layout.CollapsibleMarginSet.from_margin(resolveAutoOrZeroRect(raw_margin, parent_size.width).bottom),
        .margins_can_collapse_through = can_be_collapsed_through,
    };

    // Short-circuit if computing size.
    //
    // Note: it is important that we return the margin-collapsing related outputs here as parent
    // block containers rely on the `top_margin`/`bottom_margin` of their children to compute
    // their own intrinsic height.
    if (run_mode == .compute_size) {
        return output;
    }

    // Commit deferred child layouts to the tree.
    for (items.list.items) |item| {
        if (item.final_layout) |item_layout| {
            try TreeApi.set_unrounded_layout(tree_ref, item.node_id, item_layout);
        }
    }

    // 4. Collect out-of-flow candidates in document order (direct out-of-flow
    // children plus candidates bubbled from in-flow children's subtrees). These
    // are laid out by the out-of-flow positioning pass (`oof.compute_oof_layout`),
    // which runs after this algorithm.
    const scratch = TreeApi.scratch_allocator(tree_ref);
    var oof_candidates: layout.OofCandidates = .empty;
    for (items.list.items) |*item| {
        if (item.position.is_out_of_flow()) {
            try oof_candidates.append(scratch, .{
                .node = item.node_id,
                .order = item.order,
                .position = item.position,
                // The static-position rectangle of an out-of-flow child of a block
                // container spans the content box inline and is a zero-height line
                // at the child's hypothetical position in the block axis; its
                // self-alignment aligns it within that rectangle.
                // https://www.w3.org/TR/css-position-3/#staticpos-rect
                .static_position = .{
                    .x = layout.AxisStaticPosition.from_alignment(
                        alignment.resolve_self_relative(item.justify_self orelse justify_items, item.direction, direction, true),
                        .{ .start = resolved_content_box_inset.left, .end = container_outer_width - resolved_content_box_inset.right },
                        direction.is_rtl()),
                    .y = layout.AxisStaticPosition.from_alignment(
                        alignment.resolve_self_relative(item.align_self orelse style.alignment.AlignSelf.NORMAL, item.direction, direction, false),
                        .{ .start = item.static_position.y, .end = item.static_position.y },
                        false),
                },
            });
        } else if (item.oof_candidates.items.len != 0) {
            // Translate anchors from item-relative to container-relative coordinates
            if (item.final_layout) |item_layout| oof.translateCandidates(&item.oof_candidates, item_layout.location);
            try oof.appendCandidates(scratch, &oof_candidates, &item.oof_candidates);
        }
    }
    const absolute_position_inset = resolved_border.add(scrollbar_gutter);
    output.oof_candidates = oof_candidates;
    output.oof_positioning_area = .{
        .size = final_outer_size.sub(absolute_position_inset.sum_axes()),
        .offset = .{ .x = absolute_position_inset.left, .y = absolute_position_inset.top },
    };

    {
        // A scroll container's own padding at the end of the content is part of its scrollable
        // overflow region, so it is included in the in-flow overflow rect. Boxes that are not
        // scroll containers do not extend their overflow region by their own padding.
        if (is_scroll_container) {
            if (direction.is_rtl()) {
                inflow_result.inflow_overflow_rect.right += resolved_padding.left;
            } else {
                inflow_result.inflow_overflow_rect.right += resolved_padding.right;
            }
            inflow_result.inflow_overflow_rect.bottom += resolved_padding.bottom;
        }
        // The absolute overflow contribution is merged in by the out-of-flow
        // positioning pass, which owns the out-of-flow boxes' geometry.
        output.scrollable_overflow_rect = inflow_result.inflow_overflow_rect;
    }

    // 5. Perform hidden layout on hidden children
    if (items.has_hidden) {
        const children = try TreeApi.child_ids(tree_ref, node_id);
        for (children, 0..) |child, order| {
            const child_style = TreeApi.get_style(tree_ref, child);
            if (child_style.box_generation_mode() == .none) {
                try TreeApi.set_unrounded_layout(tree_ref, child, layout.Layout.with_order(@intCast(order)));
                _ = try TreeApi.perform_child_layout(tree_ref, child, SIZE_NONE, SIZE_NONE, .{ .width = .max_content, .height = .max_content }, .inherent_size, geometry.Line(bool){ .start = false, .end = false });
            }
        }
    }

    return output;
}

/// Create a list of `BlockItem` structs where each item represents a child of the current node
fn generate_item_list(comptime Tree: type, tree_ref: *Tree,
    node: NodeId,
    node_inner_size: geometry.Size(?f32),
    allocator: std.mem.Allocator) BlockError!ItemList {
    const TreeApi = LayoutTree(Tree);
    var item_list = ItemList{ .list = .empty };
    errdefer item_list.list.deinit(allocator);
    var visible_order: u32 = 0;
    for (try TreeApi.child_ids(tree_ref, node), 0..) |child_node_id, child_index| {
        _ = child_index;
        const child_style = TreeApi.get_style(tree_ref, child_node_id);
        const child_count_value = try TreeApi.child_count(tree_ref, child_node_id);
        if (child_style.box_generation_mode() == .none) {
            item_list.has_hidden = true;
            continue;
        }
        const order: u32 = visible_order;
        visible_order += 1;
        const aspect_ratio = child_style.aspect_ratio;
        // Percentage padding and border resolve against the container's inline size
        // (its width) on all four sides.
        const padding = resolveOrZeroRect(child_style.padding, node_inner_size.width);
        const border = resolveOrZeroRect(child_style.border, node_inner_size.width);
        const pb_sum = padding.add(border).sum_axes();
        const box_sizing_adjustment =
            if (child_style.box_sizing == .content_box) pb_sum else geometry.Size(f32){ .width = 0, .height = 0 };

        const position = child_style.position;
        const overflow = child_style.overflow;

        const float_value = child_style.float;
        const is_not_floated = float_value == .none;

        const is_block = child_style.is_block();
        const is_table = child_style.is_table();
        const is_compressible_replaced = child_style.is_compressible_replaced();
        const is_scroll_container = overflow.x.is_scroll_container() or overflow.y.is_scroll_container();
        const contain = child_style.contain;

        const is_in_same_bfc: bool = is_block and
            !is_table and
            !position.is_out_of_flow() and
            is_not_floated and
            !is_scroll_container and
            !contain.establishes_independent_formatting_context() and
            !child_style.establishes_formatting_context_from_display() and
            // A non-normal align-content establishes an independent formatting context
            child_style.align_content.keyword == .normal;

        try item_list.list.append(allocator, .{
            .node_id = child_node_id,
            .order = order,
            .is_table = is_table,
            .is_compressible_replaced = is_compressible_replaced,
            .is_in_same_bfc = is_in_same_bfc,
            .is_leaf = child_count_value == 0,
            .float = float_value,
            .clear = child_style.clear,
            .size_style = child_style.size,
            .size = maybeAddSize(geometry.optional_f32_size_maybe_apply_aspect_ratio(resolveDimensionSize(child_style.size, node_inner_size), aspect_ratio), box_sizing_adjustment),
            .min_size = maybeAddSize(geometry.optional_f32_size_maybe_apply_aspect_ratio(resolveAutoSize(child_style.min_size, node_inner_size), aspect_ratio), box_sizing_adjustment),
            .max_size = maybeAddSize(geometry.optional_f32_size_maybe_apply_aspect_ratio(resolveAutoSize(child_style.max_size, node_inner_size), aspect_ratio), box_sizing_adjustment),
            .overflow = overflow,
            .contain = contain,
            .scrollbar_width = child_style.scrollbar_width,
            .position = position,
            .direction = child_style.direction,
            .align_self = child_style.align_self,
            .justify_self = child_style.justify_self,
            .inset = child_style.inset,
            .margin = child_style.margin,
            .padding = padding,
            .border = border,
            .padding_border_sum = pb_sum,
            .computed_size = .{ .width = 0, .height = 0 },
            .static_position = .{ .x = 0, .y = 0 },
            .can_be_collapsed_through = false,
            .final_layout = null,
        });
    }
    return item_list;
}

/// Resolve the `stretch` sizing keyword for an item's height style. In the block axis the
/// intrinsic sizing keywords are all equal to the content size, which is what an auto height
/// already resolves to, so only `stretch` requires explicit resolution.
fn resolve_stretch_height(height_style: style.dimension.Dimension, container_inner_height: ?f32, item_y_margin_sum: f32) ?f32 {
    const stretch_size = if (container_inner_height) |height| height - item_y_margin_sum else null;
    return switch (sizing_keyword.resolve_sizing_keyword(height_style, stretch_size, container_inner_height) orelse return null) {
        .exact => |height| height,
        .measure => null,
    };
}

/// Compute the content-based width in the case that the width of the container is not known
fn determine_content_based_container_width(comptime Tree: type, tree_ref: *Tree,
    items: []const BlockItem,
    available_width: @import("../style/available_space.zig").AvailableSpace) BlockError!f32 {
    const TreeApi = LayoutTree(Tree);
    const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;
    const available_space = geometry.Size(AvailableSpace){ .width = available_width, .height = .min_content };

    var max_child_width: f32 = 0.0;
    var float_contribution = float.FloatIntrinsicWidthCalculator.new(available_width);
    for (items) |item| {
        if (item.position.is_out_of_flow()) continue;
        const known_dimensions = math.optional_size_maybe_clamp(item.size, item.min_size, item.max_size);

        const margin_basis = available_space.width.into_option();
        const item_x_margin_sum = (resolveLengthPercentageAuto(item.margin.left, margin_basis) orelse 0) + (resolveLengthPercentageAuto(item.margin.right, margin_basis) orelse 0);
        const width = known_dimensions.width orelse blk: {
            const resolved_keyword = sizing_keyword.resolve_sizing_keyword(item.size_style.width, null, null);
            const item_available_width = if (resolved_keyword) |resolution| switch (resolution) {
                .measure => |measure| measure,
                .exact => |exact| AvailableSpace{ .definite = exact },
            } else math.available_maybe_sub(available_space.width, item_x_margin_sum);
            break :blk try TreeApi.measure_child_size(tree_ref, 
                item.node_id,
                known_dimensions,
                SIZE_NONE,
                geometry.Size(AvailableSpace){ .width = item_available_width, .height = available_space.height },
                .inherent_size,
                .horizontal,
                // Must match the value passed when laying the item out (see `Cache.mode`).
                .{ .start = item.is_in_same_bfc, .end = item.is_in_same_bfc });
        };

        const width_with_margins = math.f32_max(width, item.padding_border_sum.width) + item_x_margin_sum;

        if (style.float.float_direction(item.float)) |direction| {
            float_contribution.add_float(width_with_margins, direction, item.clear);
            continue;
        }

        max_child_width = math.f32_max(max_child_width, width_with_margins);
    }

    max_child_width = @max(max_child_width, float_contribution.result());

    return max_child_width;
}

const InFlowResult = struct {
    inflow_overflow_rect: geometry.Rect(f32),
    intrinsic_outer_height: f32,
    first_child_top_margin_set: layout.CollapsibleMarginSet,
    last_child_bottom_margin_set: layout.CollapsibleMarginSet,
    first_baseline: ?f32,
};

/// Compute each child's final size and position
fn perform_final_layout_on_in_flow_children(comptime Tree: type, tree_ref: *Tree,
    run_mode: layout.RunMode,
    items: []BlockItem,
    container_outer_width: f32,
    container_percentage_resolution_height_in: ?f32,
    content_box_inset: geometry.Rect(f32),
    resolved_content_box_inset: geometry.Rect(f32),
    resolved_border: geometry.Rect(f32),
    text_align: style.block.TextAlign,
    justify_items: style.alignment.AlignItems,
    direction: style.Direction,
    own_margins_collapse_with_children: geometry.Line(bool),
    is_scroll_container: bool,
    store_layouts: bool,
    block_ctx: *BlockContext) BlockError!InFlowResult {
    const TreeApi = LayoutTree(Tree);
    // Resolve container_inner_width for sizing child nodes using initial content_box_inset
    const container_inner_width = @max(0.0, container_outer_width - resolved_content_box_inset.horizontal_axis_sum());
    const container_percentage_resolution_height = math.maybe_sub(container_percentage_resolution_height_in, resolved_content_box_inset.vertical_axis_sum());
    const parent_size = geometry.Size(?f32){ .width = container_inner_width, .height = container_percentage_resolution_height };
    // Vertical available_space space in block flow is indefinite, NOT a min-content constraint:
    // MaxContent is taffy's representation of "indefinite".
    const available_space = geometry.Size(@import("../style/available_space.zig").AvailableSpace){ .width = .{ .definite = container_inner_width }, .height = .max_content };

    if (block_ctx.is_bfc_root()) {
        block_ctx.set_width(container_outer_width);
        block_ctx.apply_content_box_inset(.{ resolved_content_box_inset.left, resolved_content_box_inset.right });
    }

    // If this block's top margin does not collapse with its children's then the position of its
    // top margin strut is resolved relative to it, and floats adjoining ancestor struts do not
    // adjoin this block's strut.
    if (!own_margins_collapse_with_children.start) {
        block_ctx.commit_strut();
    }

    var inflow_overflow_rect = RECT_ZERO;
    var committed_y_offset = resolved_content_box_inset.top;
    var y_offset_for_absolute = resolved_content_box_inset.top;
    var first_child_top_margin_set = layout.CollapsibleMarginSet.zero;
    var active_collapsible_margin_set = layout.CollapsibleMarginSet.zero;
    var is_collapsing_with_first_margin_set = true;
    var first_baseline: ?f32 = null;
    // Whether the active margin set contains the margins of a self-collapsing element with
    // clearance.
    var active_margin_set_has_clearance = false;

    var has_active_floats = block_ctx.has_active_floats(committed_y_offset);

    for (items) |*item| {
        if (item.position.is_out_of_flow()) {
            const x = switch (direction) {
                .ltr => resolved_content_box_inset.left,
                .rtl => container_outer_width - resolved_content_box_inset.right,
            };
            item.static_position = geometry.Point(f32){ .x = x, .y = y_offset_for_absolute };
            continue;
        }

        const item_margin = resolveAutoRect(item.margin, container_inner_width);
        const item_non_auto_margin = geometry.Rect(f32){
            .left = item_margin.left orelse 0,
            .right = item_margin.right orelse 0,
            .top = item_margin.top orelse 0,
            .bottom = item_margin.bottom orelse 0,
        };
        const item_non_auto_x_margin_sum = item_non_auto_margin.horizontal_axis_sum();

        const scrollbar_size = geometry.Size(f32){
            .width = if (item.overflow.y == .scroll) item.scrollbar_width else 0.0,
            .height = if (item.overflow.x == .scroll) item.scrollbar_width else 0.0,
        };

        // Handle floated boxes
        if (style.float.float_direction(item.float)) |float_direction| {
            has_active_floats = true;

            // A float with `width: auto` is shrink-to-fit (fit-content) sized: the available_space
            // space clamped between its min-content and max-content sizes.
            const available_width = @max(0.0, container_inner_width - item_non_auto_x_margin_sum);
            var item_known_width: ?f32 = null;
            var item_available_width: @import("../style/available_space.zig").AvailableSpace = undefined;
            if (sizing_keyword.resolve_sizing_keyword(item.size_style.width, available_width, container_inner_width)) |resolution| {
                switch (resolution) {
                    .measure => |measure| {
                        item_known_width = null;
                        item_available_width = measure;
                    },
                    .exact => |exact| {
                        item_known_width = exact;
                        item_available_width = .{ .definite = exact };
                    },
                }
            } else {
                item_known_width = null;
                item_available_width = .{ .definite = available_width };
            }
            const item_known_height = resolve_stretch_height(
                item.size_style.height,
                container_percentage_resolution_height,
                item_non_auto_margin.vertical_axis_sum());
            var item_layout = try TreeApi.perform_child_layout(tree_ref, 
                item.node_id,
                geometry.Size(?f32){ .width = item_known_width, .height = item_known_height },
                parent_size,
                geometry.Size(@import("../style/available_space.zig").AvailableSpace){ .width = item_available_width, .height = .max_content },
                .inherent_size,
                // A float establishes a new block formatting context: its margins do not
                // collapse with the margins of its children
                .{ .start = false, .end = false });
            item.oof_candidates = item_layout.oof_candidates;
            item_layout.oof_candidates = .empty;
            const margin_box = item_layout.size.add(item_non_auto_margin.sum_axes());

            // Floats that occur between collapsing margins are positioned as if they had an
            // otherwise empty anonymous block parent taking part in the flow.
            const adjoins_unresolved_strut =
                is_collapsing_with_first_margin_set and own_margins_collapse_with_children.start;
            const y_offset_for_float = if (adjoins_unresolved_strut)
                committed_y_offset
            else
                committed_y_offset + active_collapsible_margin_set.resolve();

            var location = block_ctx.place_floated_box(
                margin_box,
                y_offset_for_float,
                float_direction,
                item.clear,
                adjoins_unresolved_strut);

            // Convert the margin-box location returned by float placement into a border-box
            // location for the output Layout
            location.y += item_non_auto_margin.top;
            location.x += item_non_auto_margin.left;

            item.final_layout = if (store_layouts) layout.Layout{
                .order = item.order,
                .size = item_layout.size,
                .scrollable_overflow_rect = item_layout.scrollable_overflow_rect,
                .scrollbar_size = scrollbar_size,
                .location = location,
                .padding = item.padding,
                .border = item.border,
                .margin = item_non_auto_margin,
            } else null;

            {
                const contribution_location = if (direction.is_rtl())
                    geometry.Point(f32){
                        .x = container_outer_width - (location.x + item_layout.size.width) - resolved_border.right,
                        .y = location.y - resolved_border.top,
                    }
                else
                    geometry.Point(f32){ .x = location.x - resolved_border.left, .y = location.y - resolved_border.top };
                inflow_overflow_rect = inflow_overflow_rect.@"union"(scrollable_overflow.compute_scrollable_overflow_contribution(
                    contribution_location,
                    item_layout.size,
                    item_layout.scrollable_overflow_rect,
                    item.overflow,
                    item.contain,
                    is_scroll_container));
            }

            continue;
        }

        // Handle non-floated boxes

        var y_margin_offset: f32 = 0.0;
        var item_avoids_floats = false;
        var item_pushed_below_float = false;

        var stretch_width: f32 = 0;
        var float_avoiding_position = geometry.Point(f32){ .x = 0, .y = 0 };
        var float_avoiding_width: f32 = 0;

        if (item.is_in_same_bfc) {
            stretch_width = @max(0.0, container_inner_width - item_non_auto_x_margin_sum);
            float_avoiding_position = .{ .x = 0.0, .y = 0.0 };
            float_avoiding_width = 0.0;
        } else {
            // Set y_margin_offset (different bfc child)
            if (!is_collapsing_with_first_margin_set or !own_margins_collapse_with_children.start) {
                y_margin_offset = active_collapsible_margin_set.collapse_with_margin(item_non_auto_margin.top).resolve();
            }
            const min_y = committed_y_offset + y_margin_offset;

            // In addition to the running flag, check the float context directly: floats placed
            // by the subtree of a preceding in-flow sibling (in the same BFC) are not reflected
            // in the flag
            if (has_active_floats or block_ctx.has_active_floats(min_y)) {
                const x_margins = [2]f32{ item_non_auto_margin.left, item_non_auto_margin.right };
                // An auto width resolves to at least the negation of the margin sum
                // (so that the margin box width is non-negative, per CSS2 §10.3.3)
                const min_auto_width = -item_non_auto_x_margin_sum;

                // Find the highest slot (at or below `min_y`) with enough horizontal space
                // for the item's border box, which must not overlap any float
                var slot_segment: ?usize = null;
                const slot = while (true) {
                    const candidate = block_ctx.find_bfc_slot(min_y, x_margins, direction, item.clear, slot_segment);
                    const segment_id = candidate.segment_id orelse break candidate;
                    const raw_width = item.size.width orelse @max(@max(candidate.stretch_width, min_auto_width), 0.0);
                    const width = math.f32_maybe_clamp(raw_width, item.min_size.width, item.max_size.width);
                    if (width <= candidate.border_width + FIT_TOLERANCE) break candidate;
                    slot_segment = segment_id;
                };

                // If the item had to move down to avoid floats then it "separates from the
                // float": similarly to clearance, its top margin no longer collapses with
                // the parent's margins.
                if (slot.y > min_y) {
                    item_pushed_below_float = true;
                }

                has_active_floats = slot.segment_id != null;
                item_avoids_floats = true;
                stretch_width = @max(@max(slot.stretch_width, min_auto_width), 0.0);
                float_avoiding_position = geometry.Point(f32){ .x = slot.x, .y = slot.y };
                float_avoiding_width = slot.border_width;
            } else {
                stretch_width = @max(0.0, container_inner_width - item_non_auto_x_margin_sum);
                float_avoiding_position = geometry.Point(f32){ .x = resolved_content_box_inset.left, .y = min_y };
                float_avoiding_width = container_inner_width;
            }
        }

        // `justify-self` on an in-flow block-level box (css-align-3 §6.1.1). `auto`
        // takes the container's `justify-items`; `normal` lays the box out by the
        // default block rules. `stretch` does too: those rules already stretch an
        // auto-width box, so it only differs from `normal` for tables and replaced
        // boxes, which would otherwise resolve their own width.
        const justify_self = alignment.resolve_self_relative(item.justify_self orelse justify_items, item.direction, direction, true);
        const is_stretch = justify_self.keyword == .stretch;
        const non_stretch_justify_self: ?style.alignment.AlignItems = switch (justify_self.keyword) {
            .normal, .stretch => null,
            else => justify_self,
        };

        // Unless stretched, tables and compressible replaced elements resolve their own width
        // <https://www.w3.org/TR/CSS22/visudet.html#block-replaced-width>
        const known_dimensions = if ((item.is_table or item.is_compressible_replaced) and !is_stretch)
            SIZE_NONE
        else blk: {
            // The automatic width of a block-level box whose `justify-self` is neither
            // `normal` nor `stretch` is `fit-content` rather than stretch
            const width_style = if (non_stretch_justify_self != null and item.size_style.width.is_auto())
                style.dimension.Dimension.fit_content
            else
                item.size_style.width;
            // Items with a sizing keyword width resolve their width either directly or by
            // measuring the item under the corresponding available_space space constraint. `auto`
            // (the common case) and an already-known width resolve without consulting the
            // sizing keywords.
            var keyword_width: ?f32 = null;
            if (item.size.width == null and !width_style.is_auto()) {
                if (sizing_keyword.resolve_sizing_keyword(width_style, stretch_width, container_inner_width)) |resolution| {
                    keyword_width = switch (resolution) {
                        .exact => |width| width,
                        .measure => |item_available_width| try TreeApi.measure_child_size(tree_ref, 
                            item.node_id,
                            SIZE_NONE,
                            parent_size,
                            geometry.Size(@import("../style/available_space.zig").AvailableSpace){ .width = item_available_width, .height = .max_content },
                            .inherent_size,
                            .horizontal,
                            // Must match the value passed when laying the item out (see `Cache.mode`).
                            .{ .start = item.is_in_same_bfc, .end = item.is_in_same_bfc }),
                    };
                }
            }

            const keyword_height = if (item.size.height == null and !item.size_style.height.is_auto())
                resolve_stretch_height(
                    item.size_style.height,
                    container_percentage_resolution_height,
                    item_non_auto_margin.vertical_axis_sum())
            else
                null;

            const width = math.f32_maybe_clamp(
                (item.size.width orelse keyword_width) orelse stretch_width,
                item.min_size.width,
                item.max_size.width);
            const height = math.option_maybe_clamp(item.size.height orelse keyword_height, item.min_size.height, item.max_size.height);
            break :blk geometry.Size(?f32){ .width = width, .height = height };
        };

        const child_inputs = layout.LayoutInput{
            .run_mode = run_mode,
            .sizing_mode = .inherent_size,
            .axis = .both,
            .known_dimensions = known_dimensions,
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = geometry.Size(@import("../style/available_space.zig").AvailableSpace){ .width = .{ .definite = stretch_width }, .height = available_space.height },
            .vertical_margins_are_collapsible = if (item.is_in_same_bfc) geometry.Line(bool){ .start = true, .end = true } else geometry.Line(bool){ .start = false, .end = false },
        };

        const clear_threshold = block_ctx.cleared_threshold(item.clear);
        const clear_pos = clear_threshold orelse -std.math.inf(f32);

        // The height consumed by floats within a same-BFC child, relative to the
        // child's border-top; added to the parent's once the child's position is known.
        var child_float_contribution = -std.math.inf(f32);

        var item_layout: layout.LayoutOutput = undefined;
        if (item.is_in_same_bfc) {
            // Childless children cannot interact with the block formatting context, so they
            // bypass the context-threading dispatch and go straight to the generic cached path.
            if (item.is_leaf) {
                item_layout = try TreeApi.compute_child_layout(tree_ref, item.node_id, child_inputs);
            } else {
                // Replaced elements may not have a known width (they are sized by their
                // measure function rather than stretch-sized). The width is never smaller than
                // the item's padding and border, which the content box inset of the child is
                // built from.
                const width = @max(known_dimensions.width orelse stretch_width, item.padding_border_sum.width);

                // TODO: account for auto margins
                const inset_left = item_non_auto_margin.left + content_box_inset.left;
                const inset_right = container_outer_width - width - inset_left;
                const insets = [2]f32{ inset_left, inset_right };

                // Compute child layout. The child's position is estimated from its top
                // margin collapsed with the preceding margins (its own collapsed-through
                // margins are not yet known).
                const estimated_y = committed_y_offset + active_collapsible_margin_set.collapse_with_margin(item_non_auto_margin.top).resolve();
                var child_block_ctx = block_ctx.sub_context(@max(estimated_y, clear_pos), insets);
                const child_output = try compute_block_child_layout(Tree, tree_ref, item.node_id, child_inputs, &child_block_ctx);

                // Extract float contribution from child block context
                {
                    child_float_contribution = child_block_ctx.floated_content_height_contribution();
                    const child_top_adjoining_floats = child_block_ctx.top_adjoining_floats();
                    // Floats placed while the position of the child's top margin strut was unresolved
                    // also adjoin this block's current strut
                    block_ctx.merge_adjoining_floats(child_top_adjoining_floats);
                }

                item_layout = child_output;
            }
        } else {
            item_layout = try TreeApi.compute_child_layout(tree_ref, item.node_id, child_inputs);
        }
        // Out-of-flow candidates from this item's subtree bubble up to this container,
        // with anchors relative to the item's border box until they are translated at
        // merge time.
        item.oof_candidates = item_layout.oof_candidates;
        item_layout.oof_candidates = .empty;
        const final_size = item_layout.size;

        const top_margin_set = item_layout.top_margin.collapse_with_margin(item_margin.top orelse 0.0);
        const bottom_margin_set = item_layout.bottom_margin.collapse_with_margin(item_margin.bottom orelse 0.0);

        // Expand auto margins to fill available_space space
        // Note: Vertical auto-margins for relatively positioned block items simply resolve to 0.
        // See: https://www.w3.org/TR/CSS21/visudet.html#abs-non-replaced-width
        const free_x_space = math.f32_max(0.0, stretch_width - final_size.width);
        const x_axis_auto_margin_size = blk: {
            const auto_margin_count: u8 = @as(u8, if (item_margin.left == null) 1 else 0) + @as(u8, if (item_margin.right == null) 1 else 0);
            if (auto_margin_count > 0) {
                break :blk free_x_space / @as(f32, @floatFromInt(auto_margin_count));
            }
            break :blk 0.0;
        };
        const resolved_margin = geometry.Rect(f32){
            .left = item_margin.left orelse x_axis_auto_margin_size,
            .right = item_margin.right orelse x_axis_auto_margin_size,
            // The item's own vertical margins (its collapsed margin sets are only used for
            // placing it in the flow). `Layout::margin` reports the item's own margins.
            .top = item_margin.top orelse 0.0,
            .bottom = item_margin.bottom orelse 0.0,
        };

        // Resolve item inset (the overwhelmingly common case is `inset: auto` on every
        // side, which resolves to a zero offset). Only `position: relative` applies an
        // inset as a positional correction factor; out-of-flow items have their insets
        // resolved against their containing block by the out-of-flow positioning pass.
        var inset_offset = geometry.Point(f32){ .x = 0, .y = 0 };
        if (item.position.applies_relative_inset() and !isAutoInsetRect(item.inset)) {
            const inset_percentage_basis = geometry.Size(?f32){ .width = container_inner_width, .height = container_percentage_resolution_height };
            const inset = geometry.Rect(?f32){
                .left = resolveLengthPercentageAuto(item.inset.left, inset_percentage_basis.width),
                .right = resolveLengthPercentageAuto(item.inset.right, inset_percentage_basis.width),
                .top = resolveLengthPercentageAuto(item.inset.top, inset_percentage_basis.height),
                .bottom = resolveLengthPercentageAuto(item.inset.bottom, inset_percentage_basis.height),
            };
            inset_offset = geometry.Point(f32){
                .x = if (direction.is_rtl())
                    (if (inset.right) |x| -x else inset.left orelse 0.0)
                else
                    (inset.left orelse (if (inset.right) |x| -x else 0.0)),
                .y = (inset.top orelse (if (inset.bottom) |x| -x else 0.0)),
            };
        }

        // Set y_margin_offset (same bfc child)
        if (item.is_in_same_bfc and (!is_collapsing_with_first_margin_set or !own_margins_collapse_with_children.start)) {
            y_margin_offset = active_collapsible_margin_set.collapse_with_set(top_margin_set).resolve();
        }

        // Compute clearance (CSS2.2 9.5.2). Clearance is introduced if the hypothetical position
        // of the item's top border edge (the position it would have with normal margin
        // collapsing) is not past the bottom of the relevant floats.
        var has_clearance = false;
        if (item.is_in_same_bfc) {
            if (clear_threshold) |threshold| {
                const hypothetical_y =
                    committed_y_offset + active_collapsible_margin_set.collapse_with_set(top_margin_set).resolve();
                // Clearance is forced (regardless of the hypothetical position) if a relevant
                // float is adjoining the margin-collapse strut that the item's top margin would
                // collapse into.
                const forced_clearance = block_ctx.has_adjoining_float(item.clear);
                if (forced_clearance or hypothetical_y < threshold) {
                    has_clearance = true;
                    // Clearance stops the item's top margin collapsing with preceding margins.
                    const escaped_margin =
                        if (is_collapsing_with_first_margin_set and own_margins_collapse_with_children.start)
                            active_collapsible_margin_set.resolve()
                        else
                            0.0;
                    y_margin_offset = threshold - committed_y_offset - escaped_margin;
                }
            }
        }

        item.computed_size = item_layout.size;
        item.can_be_collapsed_through = item_layout.margins_can_collapse_through and !has_clearance;
        item.static_position = if (item.is_in_same_bfc) blk: {
            const uncleared_y = committed_y_offset + active_collapsible_margin_set.resolve();
            break :blk geometry.Point(f32){
                .x = switch (direction) {
                    .ltr => resolved_content_box_inset.left,
                    .rtl => container_outer_width - resolved_content_box_inset.right - final_size.width,
                },
                .y = @max(uncleared_y, clear_pos),
            };
        } else geometry.Point(f32){
            .x = switch (direction) {
                .ltr => float_avoiding_position.x,
                .rtl => float_avoiding_position.x + float_avoiding_width - final_size.width,
            },
            .y = float_avoiding_position.y,
        };

        var location = if (item.is_in_same_bfc)
            geometry.Point(f32){
                .x = switch (direction) {
                    .ltr => resolved_content_box_inset.left + inset_offset.x + resolved_margin.left,
                    .rtl => container_outer_width - resolved_content_box_inset.right - final_size.width - resolved_margin.right + inset_offset.x,
                },
                .y = committed_y_offset + y_margin_offset + inset_offset.y,
            }
        else blk: {
            // When the item avoids floats, its non-auto margins are already accounted for in the
            // slot's border-box position/width (margins may overlap floats), so only the auto
            // portion of the resolved margin is added here.
            const extra_margin_left = if (item_avoids_floats) resolved_margin.left - item_non_auto_margin.left else resolved_margin.left;
            const extra_margin_right = if (item_avoids_floats) resolved_margin.right - item_non_auto_margin.right else resolved_margin.right;

            break :blk geometry.Point(f32){
                .x = switch (direction) {
                    .ltr => float_avoiding_position.x + extra_margin_left + inset_offset.x,
                    .rtl => float_avoiding_position.x + float_avoiding_width - final_size.width - extra_margin_right + inset_offset.x,
                },
                .y = float_avoiding_position.y + inset_offset.y,
            };
        };

        // Floats within the child are positioned relative to its border-top, so the
        // child's (margin-collapsed) position, not its relative offset, is added.
        if (item.is_in_same_bfc) {
            block_ctx.add_child_floated_content_height_contribution(location.y - inset_offset.y + child_float_contribution);
        }

        // Apply alignment. `justify-self` aligns the margin box within its alignment
        // container and takes precedence over legacy `text-align`, but auto margins
        // (which have already absorbed the free space) take precedence over it.
        const has_auto_x_margin = item_margin.left == null or item_margin.right == null;
        const item_outer_width = item_layout.size.width + resolved_margin.horizontal_axis_sum();
        if (non_stretch_justify_self != null and !has_auto_x_margin) {
            const js = non_stretch_justify_self.?;
            // The alignment container is the containing block, except that a
            // BFC-establishing box next to a float aligns within the space the float
            // leaves (that slot is already inset by the item's margins).
            const container_start = if (item_avoids_floats) float_avoiding_position.x - resolved_margin.left else resolved_content_box_inset.left;
            const justify_free_space = if (item_avoids_floats) float_avoiding_width - item_layout.size.width else container_inner_width - item_outer_width;
            const keyword: style.alignment.AlignItemsKeyword = if (js.safety == .safe and justify_free_space < 0) .start else js.keyword;
            const offset: f32 = switch (keyword) {
                .center => justify_free_space / 2.0,
                .end, .flex_end, .self_end => if (!direction.is_rtl()) justify_free_space else 0,
                else => if (direction.is_rtl()) justify_free_space else 0,
            };
            location.x = container_start + resolved_margin.left + inset_offset.x + offset;
        } else if (non_stretch_justify_self == null and item_outer_width < container_inner_width) {
            const align_free_space = container_inner_width - item_outer_width;
            switch (text_align) {
                .auto => {},
                .legacy_left => if (direction == .rtl) {
                    location.x -= align_free_space;
                },
                .legacy_right => if (direction == .ltr) {
                    location.x += align_free_space;
                },
                .legacy_center => if (direction == .ltr) {
                    location.x += align_free_space / 2.0;
                } else {
                    location.x -= align_free_space / 2.0;
                },
            }
        }

        // A block container's first baseline is the first baseline of its first in-flow child
        // that has one.
        if (first_baseline == null) {
            const child_baseline: ?f32 = if (item.overflow.y.is_scroll_container()) blk: {
                const value = item_layout.baselines.first orelse item_layout.size.height;
                break :blk @max(@min(value, item_layout.size.height), 0.0);
            } else item_layout.baselines.first;
            first_baseline = if (child_baseline) |baseline| location.y + baseline else null;
        }

        // Used auto margins include float-avoidance offsets, unlike the alignment
        // margins above.
        var used_margin = resolved_margin;
        if (item_avoids_floats) {
            if (item_margin.left == null) used_margin.left += float_avoiding_position.x - resolved_content_box_inset.left;
            if (item_margin.right == null) used_margin.right += container_outer_width - resolved_content_box_inset.right - float_avoiding_position.x - float_avoiding_width;
        }

        // Defer `set_unrounded_layout` to the post-loop pass in `compute_inner` so that
        // `align-content` can shift `location.y` before the layout is committed to the tree.
        item.final_layout = if (store_layouts) layout.Layout{
            .order = item.order,
            .size = item_layout.size,
            .scrollable_overflow_rect = item_layout.scrollable_overflow_rect,
            .scrollbar_size = scrollbar_size,
            .location = location,
            .padding = item.padding,
            .border = item.border,
            .margin = used_margin,
        } else null;

        {
            const contribution_location = if (direction.is_rtl())
                geometry.Point(f32){
                    .x = container_outer_width - (location.x + final_size.width) - resolved_border.right,
                    .y = location.y - resolved_border.top,
                }
            else
                geometry.Point(f32){ .x = location.x - resolved_border.left, .y = location.y - resolved_border.top };
            inflow_overflow_rect = inflow_overflow_rect.@"union"(scrollable_overflow.compute_scrollable_overflow_contribution(
                contribution_location,
                final_size,
                item_layout.scrollable_overflow_rect,
                item.overflow,
                item.contain,
                is_scroll_container));
        }

        // Update first_child_top_margin_set
        //
        // The top margin of an item with clearance does not collapse with the container's top
        // margin, so clearance terminates collapsing without contributing the item's own margins.
        if (is_collapsing_with_first_margin_set and item_pushed_below_float) {
            // The item's top margin "separated from the float" and must not propagate to the parent
            is_collapsing_with_first_margin_set = false;
        }
        if (is_collapsing_with_first_margin_set and has_clearance) {
            is_collapsing_with_first_margin_set = false;
        } else if (is_collapsing_with_first_margin_set) {
            if (item.can_be_collapsed_through) {
                first_child_top_margin_set = first_child_top_margin_set
                    .collapse_with_set(top_margin_set)
                    .collapse_with_set(bottom_margin_set);
            } else {
                first_child_top_margin_set = first_child_top_margin_set.collapse_with_set(top_margin_set);
                is_collapsing_with_first_margin_set = false;
            }
        }

        // Update active_collapsible_margin_set
        if (item.can_be_collapsed_through) {
            active_collapsible_margin_set = active_collapsible_margin_set
                .collapse_with_set(top_margin_set)
                .collapse_with_set(bottom_margin_set);
            y_offset_for_absolute = committed_y_offset + item_layout.size.height + y_margin_offset;
        } else {
            committed_y_offset = location.y - inset_offset.y + item_layout.size.height;
            // A self-collapsing item with clearance is not collapsed through, but its top and
            // bottom margins still collapse with each other and with the margins of following
            // siblings.
            if (has_clearance and item_layout.margins_can_collapse_through) {
                committed_y_offset -= top_margin_set.resolve();
                active_collapsible_margin_set = top_margin_set.collapse_with_set(bottom_margin_set);
                active_margin_set_has_clearance = true;
            } else {
                active_collapsible_margin_set = bottom_margin_set;
                active_margin_set_has_clearance = false;
            }
            y_offset_for_absolute = committed_y_offset + active_collapsible_margin_set.resolve();
            // Committing in-flow content resolves the position of the current margin-collapse
            // strut, so floats placed before this point no longer force clearance
            block_ctx.commit_strut();
        }
    }

    // The margins of a self-collapsing element with clearance do not collapse with the bottom
    // margin of the parent block: they extend the parent's content height instead of escaping it
    const last_child_bottom_margin_set =
        if (active_margin_set_has_clearance) layout.CollapsibleMarginSet.zero else active_collapsible_margin_set;
    const bottom_y_margin_offset = if (active_margin_set_has_clearance)
        active_collapsible_margin_set.resolve()
    else if (own_margins_collapse_with_children.end)
        0.0
    else
        last_child_bottom_margin_set.resolve();

    committed_y_offset += resolved_content_box_inset.bottom + bottom_y_margin_offset;
    const content_height = math.f32_max(0.0, committed_y_offset);
    return .{
        .inflow_overflow_rect = inflow_overflow_rect,
        .intrinsic_outer_height = content_height,
        .first_child_top_margin_set = first_child_top_margin_set,
        .last_child_bottom_margin_set = last_child_bottom_margin_set,
        .first_baseline = first_baseline,
    };
}

fn asMeasureResolution(resolution: ?sizing_keyword.SizingKeywordResolution) ?@import("../style/available_space.zig").AvailableSpace {
    if (resolution) |value| {
        switch (value) {
            .measure => |space| return space,
            .exact => {},
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Small resolution helpers (Zig spellings of Taffy's `MaybeResolve`/`ResolveOrZero`)
// ---------------------------------------------------------------------------

/// `LengthPercentage::maybe_resolve`: lengths resolve even against an indefinite
/// basis; percentages require a definite basis.
fn resolveLengthPercentage(value: style.dimension.LengthPercentage, basis: ?f32) ?f32 {
    return switch (value.value.tag()) {
        .length => value.value.value(),
        .percent => if (basis) |b| value.value.value() * b else null,
        else => null,
    };
}

/// `LengthPercentageAuto::maybe_resolve`: `auto` stays `None`, lengths resolve
/// even against an indefinite basis; percentages require a definite basis.
fn resolveLengthPercentageAuto(value: style.dimension.LengthPercentageAuto, basis: ?f32) ?f32 {
    return switch (value.value.tag()) {
        .auto => null,
        .length => value.value.value(),
        .percent => if (basis) |b| value.value.value() * b else null,
        else => null,
    };
}

/// Whether every side of a length-percentage rect is the zero length. The common
/// styles (`padding: 0`, `border: 0`) short-circuit the per-side resolution below.
fn isZeroLengthRect(value: geometry.Rect(style.dimension.LengthPercentage)) bool {
    return value.left.value.is_zero() and value.right.value.is_zero() and value.top.value.is_zero() and value.bottom.value.is_zero();
}

/// Whether every side of a length-percentage-auto rect is the zero length
/// (`auto` margins are not zero and take the slow path).
fn isZeroAutoRect(value: geometry.Rect(style.dimension.LengthPercentageAuto)) bool {
    return value.left.value.is_zero() and value.right.value.is_zero() and value.top.value.is_zero() and value.bottom.value.is_zero();
}

fn resolveOrZeroRect(value: geometry.Rect(style.dimension.LengthPercentage), basis: ?f32) geometry.Rect(f32) {
    if (isZeroLengthRect(value)) return RECT_ZERO;
    return .{
        .left = resolveLengthPercentage(value.left, basis) orelse 0,
        .right = resolveLengthPercentage(value.right, basis) orelse 0,
        .top = resolveLengthPercentage(value.top, basis) orelse 0,
        .bottom = resolveLengthPercentage(value.bottom, basis) orelse 0,
    };
}

fn resolveAutoOrZeroRect(value: geometry.Rect(style.dimension.LengthPercentageAuto), basis: ?f32) geometry.Rect(f32) {
    if (isZeroAutoRect(value)) return RECT_ZERO;
    return .{
        .left = resolveLengthPercentageAuto(value.left, basis) orelse 0,
        .right = resolveLengthPercentageAuto(value.right, basis) orelse 0,
        .top = resolveLengthPercentageAuto(value.top, basis) orelse 0,
        .bottom = resolveLengthPercentageAuto(value.bottom, basis) orelse 0,
    };
}

fn resolveAutoRect(value: geometry.Rect(style.dimension.LengthPercentageAuto), basis: ?f32) geometry.Rect(?f32) {
    if (isZeroAutoRect(value)) return .{ .left = 0, .right = 0, .top = 0, .bottom = 0 };
    return .{
        .left = resolveLengthPercentageAuto(value.left, basis),
        .right = resolveLengthPercentageAuto(value.right, basis),
        .top = resolveLengthPercentageAuto(value.top, basis),
        .bottom = resolveLengthPercentageAuto(value.bottom, basis),
    };
}

fn resolveDimensionSize(value: geometry.Size(style.dimension.Dimension), parent: geometry.Size(?f32)) geometry.Size(?f32) {
    if (value.width.is_auto() and value.height.is_auto()) return SIZE_NONE;
    return .{ .width = value.width.resolve(parent.width), .height = value.height.resolve(parent.height) };
}

fn resolveAutoSize(value: geometry.Size(style.dimension.LengthPercentageAuto), parent: geometry.Size(?f32)) geometry.Size(?f32) {
    if (value.width.is_auto() and value.height.is_auto()) return SIZE_NONE;
    return .{ .width = resolveLengthPercentageAuto(value.width, parent.width), .height = resolveLengthPercentageAuto(value.height, parent.height) };
}

/// Whether the rect has no authored inset (`inset: auto` on every side).
fn isAutoInsetRect(value: geometry.Rect(style.dimension.LengthPercentageAuto)) bool {
    return value.left.value.is_auto() and value.right.value.is_auto() and value.top.value.is_auto() and value.bottom.value.is_auto();
}

fn maybeAddSize(value: geometry.Size(?f32), add: geometry.Size(f32)) geometry.Size(?f32) {
    // `border-box` sizing (the initial value) passes a zero adjustment, which is by far
    // the common case: skip the per-axis `maybe_add` work entirely.
    if (add.width == 0 and add.height == 0) return value;
    return .{
        .width = if (value.width) |v| v + add.width else null,
        .height = if (value.height) |v| v + add.height else null,
    };
}

fn maybeMaxSizeF32(value: geometry.Size(?f32), floor: geometry.Size(f32)) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| @max(v, floor.width) else null,
        .height = if (value.height) |v| @max(v, floor.height) else null,
    };
}

fn maybeSubSize(value: geometry.Size(?f32), sub: geometry.Size(f32)) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| v - sub.width else null,
        .height = if (value.height) |v| v - sub.height else null,
    };
}

fn optionalSizeOr(value: geometry.Size(?f32), alternative: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = value.width orelse alternative.width, .height = value.height orelse alternative.height };
}

fn f32MaybeSub(lhs: f32, rhs: ?f32) f32 {
    return if (rhs) |value| lhs - value else lhs;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "block flow collapses adjacent vertical margins" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const first = try tree_ref.new_leaf(.{
        .display = .block,
        .size = .{ .width = .length(20), .height = .length(10) },
        .margin = .{ .left = .zero(), .right = .zero(), .top = .zero(), .bottom = .length(20) },
    });
    const second = try tree_ref.new_leaf(.{
        .display = .block,
        .size = .{ .width = .length(20), .height = .length(10) },
        .margin = .{ .left = .zero(), .right = .zero(), .top = .length(10), .bottom = .zero() },
    });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .auto } }, &[_]NodeId{ first, second });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .max_content });
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(first)).location.y);
    try testing.expectEqual(@as(f32, 10), (try tree_ref.layout_of(first)).size.height);
    try testing.expectEqual(@as(f32, 30), (try tree_ref.layout_of(second)).location.y);
}

test "block parent and first child margins collapse" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{
        .display = .block,
        .size = .{ .width = .length(20), .height = .length(10) },
        .margin = .{ .left = .zero(), .right = .zero(), .top = .length(15), .bottom = .zero() },
    });
    const parent = try tree_ref.new_with_children(.{ .display = .block }, &[_]NodeId{child});
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .length(100) } }, &[_]NodeId{parent});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    // The child's top margin escapes the parent, so the parent's margin box is pushed down by
    // 15px while the child sits at y=0 inside the parent.
    try testing.expectEqual(@as(f32, 15), (try tree_ref.layout_of(parent)).location.y);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(child)).location.y);
    try testing.expectEqual(@as(f32, 10), (try tree_ref.layout_of(parent)).size.height);
}

test "block child layout receives resolved width for percentage descendants" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const grandchild = try tree_ref.new_leaf(.{ .display = .block, .size = .{ .width = .percent(1), .height = .length(10) } });
    const child = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .percent(0.5), .height = .auto }, .margin = .{ .left = .zero(), .right = .zero(), .top = .zero(), .bottom = .zero() } }, &[_]NodeId{grandchild});
    const root = try tree_ref.new_with_children(.{ .display = .block }, &[_]NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 80 }, .height = .{ .definite = 30 } });
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(grandchild)).size.width);
}

test "block flow places floated children through the float context" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const floated = try tree_ref.new_leaf(.{ .display = .block, .float = .left, .size = .{ .width = .length(30), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .length(40) } }, &[_]NodeId{floated});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 40 } });
    const result = try tree_ref.layout_of(floated);
    try testing.expectEqual(@as(f32, 0), result.location.x);
    try testing.expectEqual(@as(f32, 30), result.size.width);
}

test "block in-flow content in the same bfc overlaps floats" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const floated = try tree_ref.new_leaf(.{ .display = .block, .float = .left, .size = .{ .width = .length(60), .height = .length(20) } });
    const content = try tree_ref.new_leaf(.{ .display = .block, .size = .{ .width = .auto, .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .length(40) } }, &[_]NodeId{ floated, content });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 40 } });
    const result = try tree_ref.layout_of(content);
    // A block in the same formatting context straddles the float: its border box is
    // stretch-sized to the container width (only its line boxes shorten).
    try testing.expectEqual(@as(f32, 0), result.location.x);
    try testing.expectEqual(@as(f32, 100), result.size.width);
}

test "block bfc content avoids floats" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const floated = try tree_ref.new_leaf(.{ .display = .block, .float = .left, .size = .{ .width = .length(60), .height = .length(20) } });
    const content = try tree_ref.new_with_children(.{ .display = .block, .overflow = .{ .x = .hidden, .y = .hidden }, .size = .{ .width = .auto, .height = .length(10) } }, &[_]NodeId{});
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .length(40) } }, &[_]NodeId{ floated, content });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 40 } });
    const result = try tree_ref.layout_of(content);
    try testing.expectEqual(@as(f32, 60), result.location.x);
    try testing.expectEqual(@as(f32, 40), result.size.width);
}

test "block floats honor horizontal content-box insets" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const floated = try tree_ref.new_leaf(.{ .display = .block, .float = .left, .size = .{ .width = .length(20), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .block, .padding = .{ .left = .length(10), .right = .zero(), .top = .zero(), .bottom = .zero() }, .size = .{ .width = .length(100), .height = .length(30) } }, &[_]NodeId{floated});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 30 } });
    try testing.expectEqual(@as(f32, 10), (try tree_ref.layout_of(floated)).location.x);
}

test "block establishes a new bfc for overflow scroll children" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const floated = try tree_ref.new_leaf(.{ .display = .block, .float = .left, .size = .{ .width = .length(40), .height = .length(40) } });
    const scroller = try tree_ref.new_with_children(.{ .display = .block, .overflow = .{ .x = .scroll, .y = .scroll } }, &[_]NodeId{floated});
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .length(100) } }, &[_]NodeId{scroller});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    // The scroll container contains its float, giving it height 40 rather than 0.
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(scroller)).size.height);
}

test "block absolute child fills inset area" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const absolute = try tree_ref.new_leaf(.{
        .display = .block,
        .position = .absolute,
        .inset = .{ .left = .length(10), .right = .length(20), .top = .length(5), .bottom = .length(15) },
    });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .length(100) } }, &[_]NodeId{absolute});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    const result = try tree_ref.layout_of(absolute);
    try testing.expectEqual(@as(f32, 10), result.location.x);
    try testing.expectEqual(@as(f32, 5), result.location.y);
    try testing.expectEqual(@as(f32, 70), result.size.width);
    try testing.expectEqual(@as(f32, 80), result.size.height);
}

test "block margins collapse through zero-height children" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const spacer = try tree_ref.new_leaf(.{
        .display = .block,
        .margin = .{ .left = .zero(), .right = .zero(), .top = .length(5), .bottom = .length(7) },
    });
    const sibling = try tree_ref.new_leaf(.{ .display = .block, .size = .{ .width = .length(10), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .auto } }, &[_]NodeId{ spacer, sibling });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .max_content });
    // The spacer's top (5) and bottom (7) margins collapse into a single 7px strut that
    // pushes the following sibling down.
    try testing.expectEqual(@as(f32, 5), (try tree_ref.layout_of(spacer)).location.y);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(spacer)).size.height);
    try testing.expectEqual(@as(f32, 7), (try tree_ref.layout_of(sibling)).location.y);
}

test "block clearance pushes cleared elements below floats" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const floated = try tree_ref.new_leaf(.{ .display = .block, .float = .left, .size = .{ .width = .length(40), .height = .length(30) } });
    const cleared = try tree_ref.new_leaf(.{ .display = .block, .clear = .left, .size = .{ .width = .length(10), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .length(100) } }, &[_]NodeId{ floated, cleared });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 30), (try tree_ref.layout_of(cleared)).location.y);
}

test "block absolute auto margins center the box" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const absolute = try tree_ref.new_leaf(.{
        .display = .block,
        .position = .absolute,
        .size = .{ .width = .length(20), .height = .length(10) },
        .inset = .{ .left = .length(0), .right = .length(0), .top = .auto(), .bottom = .auto() },
        .margin = .{ .left = .auto(), .right = .auto(), .top = .zero(), .bottom = .zero() },
    });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .length(100) } }, &[_]NodeId{absolute});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 40), (try tree_ref.layout_of(absolute)).location.x);
}

test "block skips display none children" {
    const testing = std.testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const hidden = try tree_ref.new_leaf(.{ .display = .none, .size = .{ .width = .length(50), .height = .length(50) } });
    const visible = try tree_ref.new_leaf(.{ .display = .block, .size = .{ .width = .length(10), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{ .display = .block, .size = .{ .width = .length(100), .height = .auto } }, &[_]NodeId{ hidden, visible });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    const hidden_layout = try tree_ref.layout_of(hidden);
    try testing.expectEqual(@as(f32, 0), hidden_layout.size.width);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(visible)).location.y);
}
