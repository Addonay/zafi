//! Taffy `compute/mod.rs` module root.
//!
//! Dispatch mirrors Taffy's `TaffyView::compute_child_layout`: hidden mode
//! short-circuits, `display: none` hides, containers dispatch by display, and
//! childless nodes go through the compute-time measure callback. Child
//! requests made by the algorithms go through `compute_cached_layout`.

const std = @import("std");

pub const block = @import("block.zig");
pub const common = @import("common/root.zig");
pub const flexbox = @import("flexbox.zig");
pub const float = @import("float.zig");
pub const grid = @import("grid/root.zig");
pub const leaf = @import("leaf.zig");
pub const oof = @import("oof.zig");

const geometry = @import("../geometry.zig");
const math = @import("../util/math.zig");
const style = @import("../style/root.zig");
const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;
const tree = @import("../tree/tree.zig");
const NodeId = @import("../tree/node.zig").NodeId;
const layout = @import("../tree/layout.zig");
const interfaces = @import("../tree/interfaces.zig");
const LayoutTree = interfaces.LayoutTree;

pub const ComputeError = error{ InvalidParentNode, InvalidChildNode, InvalidInputNode, ChildIndexOutOfBounds, InvalidLayoutMode, OutOfMemory, Cycle, DuplicateChild, NodeIdExhausted };

/// Check the cache for a matching entry, otherwise compute and store.
/// This is Taffy's `compute_cached_layout`; it does not write node layouts.
pub fn compute_cached_layout(comptime Tree: type, tree_ref: *Tree, node_id: NodeId, input: layout.LayoutInput) ComputeError!layout.LayoutOutput {
    return cachedDispatch(Tree, tree_ref, node_id, input, null);
}

/// `compute_cached_layout` with an inherited block formatting context, matching
/// Taffy's `LayoutBlockContainer::compute_block_child_layout`.
///
/// The context only changes *which* block-context instance the node lays its
/// children out in; every other part of the dispatch (including the out-of-flow
/// positioning pass) is shared with the `null` path. Routing it through the same
/// dispatcher is what guarantees a block child that acts as a containing block
/// still lays out its out-of-flow descendants.
pub fn cached_layout_with_block_ctx(comptime Tree: type, tree_ref: *Tree,
    node_id: NodeId,
    input: layout.LayoutInput,
    block_ctx: ?*block.BlockContext) ComputeError!layout.LayoutOutput {
    return cachedDispatch(Tree, tree_ref, node_id, input, block_ctx);
}

fn cachedDispatch(comptime Tree: type, tree_ref: *Tree,
    node_id: NodeId,
    input: layout.LayoutInput,
    block_ctx: ?*block.BlockContext) ComputeError!layout.LayoutOutput {
    const Api = LayoutTree(Tree);
    // A block child sharing its parent's float context reads and places floats
    // the cache key does not capture: serve it from the cache only when neither
    // the cached result nor the current context involve floats. (Taffy serves
    // such results unconditionally, so a parent's height can lose a float that
    // a cached child placed.)
    const floats_before = if (block_ctx) |ctx| ctx.has_floats() else false;
    const may_use_cache = if (block_ctx == null) true else !floats_before and !Api.cache_float_coupled(tree_ref, node_id);
    if (may_use_cache) {
        if (Api.cache_get(tree_ref, node_id, &input)) |cached| return cached;
    }
    const float_mark = if (block_ctx) |ctx| ctx.float_mark() else undefined;
    // A child layout's scratch temporaries are dead once it returns, unless it
    // hands out-of-flow candidates (scratch lists) to its parent: reclaim them
    // like a stack so peak scratch memory is the deepest live set.
    const scratch_mark = LayoutTree(Tree).scratch_mark(tree_ref);
    const output = try compute_child_layout_with_block_ctx(Tree, tree_ref, node_id, input, block_ctx);
    if (output.oof_candidates.items.len == 0) LayoutTree(Tree).scratch_release(tree_ref, scratch_mark);
    // The output's candidate list lives in pass scratch memory; the host's
    // cache_store must copy it if it caches the result, so a later cache hit
    // can surface the same candidates (Tree does; see Tree.cache_store).
    if (block_ctx) |ctx| {
        const after = ctx.float_mark();
        const placed_floats = after.left != float_mark.left or after.right != float_mark.right;
        Api.set_cache_float_coupled(tree_ref, node_id, floats_before or placed_floats);
    }
    try Api.cache_store(tree_ref, node_id, &input, output);
    return output;
}

/// The shared leaf rule: resolve edge values, apply the size keywords, and
/// either call the host's measure callback or fall back to the intrinsic size.
///
/// Hosts call this from their `compute_leaf_layout` implementation. `context`
/// and `measure` are the host's to supply; both may be null.
pub fn leaf_layout_with_measure(
    node_id: NodeId,
    input: layout.LayoutInput,
    node_style: *const style.Style,
    context: ?*anyopaque,
    measure: ?interfaces.MeasureFunc,
) ComputeError!layout.LayoutOutput {
    if (measure) |callback| {
        return callback(context, input, node_id, node_style);
    }
    return leaf.compute_leaf_layout(input, node_style, null, null);
}

/// Dispatch by `Style.display`, matching `(display, has_children)` in Taffy.
pub fn compute_child_layout(comptime Tree: type, tree_ref: *Tree, node_id: NodeId, input: layout.LayoutInput) ComputeError!layout.LayoutOutput {
    return compute_child_layout_with_block_ctx(Tree, tree_ref, node_id, input, null);
}

/// `compute_child_layout` with an inherited block formatting context.
pub fn compute_child_layout_with_block_ctx(comptime Tree: type, tree_ref: *Tree,
    node_id: NodeId,
    input: layout.LayoutInput,
    block_ctx: ?*block.BlockContext) ComputeError!layout.LayoutOutput {
    const TreeApi = LayoutTree(Tree);
    if (input.run_mode == .perform_hidden_layout) {
        // Rounding reaches out-of-flow boxes only through their containing block's
        // hoisted list, and a box in a hidden subtree is in no such list: reset its
        // final layout so it does not keep one from an earlier visible pass (Taffy dd94ef7).
        try TreeApi.set_final_layout(tree_ref, node_id, layout.Layout.with_order(0));
        return compute_hidden_layout(Tree, tree_ref, node_id);
    }

    const node_style = TreeApi.get_style(tree_ref, node_id);
    if (node_style.display == .none) return compute_hidden_layout(Tree, tree_ref, node_id);

    // Detailed algorithm output describes the node's *completed* layout. A full
    // pass which does not produce a grid result must drop any previous grid
    // detail rather than leave consumers reading obsolete track data.
    if (input.run_mode == .perform_layout and node_style.display != .grid) {
        try TreeApi.clear_detailed_layout_info(tree_ref, node_id);
    }

    if (try TreeApi.child_count(tree_ref, node_id) == 0) {
        return TreeApi.compute_leaf_layout(tree_ref, node_id, input);
    }

    var output = switch (node_style.display) {
        .flex => flexbox.compute_flexbox_layout(Tree, tree_ref, node_id, input),
        .grid => grid.compute_grid_layout(Tree, tree_ref, node_id, input),
        // `flow_root` establishes its own formatting context, so it never inherits one.
        .block => block.compute_block_layout(Tree, tree_ref, node_id, input, block_ctx),
        .flow_root => block.compute_block_layout(Tree, tree_ref, node_id, input, null),
        .none => unreachable, // handled above
    } catch |err| return err;

    // Lay out any out-of-flow candidates for which this node is the containing
    // block; the rest bubble up via `output.oof_candidates`. This runs inside the
    // cache-miss wrapper so cached outputs already contain the processed list.
    // Only full layout passes run it: measure passes must not write hoisted box
    // layouts (which would not be rewritten if the final layout pass is a hit).
    if (input.run_mode == .perform_layout) {
        try oof.compute_oof_layout(Tree, tree_ref, node_id, &output);
    }
    return output;
}

/// Compute layout for the root node, mirroring Taffy's `compute_root_layout`.
///
/// This is the scratch epoch boundary: a top-level root layout invalidates all
/// of the tree's `scratch_allocator()` temporaries (root passes only re-enter
/// through child computes, so nested calls keep the outer epoch alive). It is
/// called by `Tree.compute_layout`/`compute_layout_with_measure`, but is
/// also part of the public surface, so the reset lives here rather than in the
/// method wrapper to cover direct callers too.
///
/// # Root positioning
///
/// The root's containing block is the initial containing block (ICB), which has
/// the dimensions of the viewport (`available_space`) and is anchored at the
/// canvas origin. The root's `position` and `inset` styles resolve against it:
///
///   * An out-of-flow (`absolute`/`fixed`) root is laid out by the same routine
///     used for every other out-of-flow box (insets, shrink-to-fit sizing, auto
///     margins), with its static position at the ICB origin. This requires a
///     definite `available_space` in both axes; otherwise there is no ICB to
///     resolve against and the root is laid out as if it were in flow.
///   * A `position: relative` root is laid out in flow and then offset by its
///     insets.
///   * A `position: static` root is laid out in flow at the ICB origin.
pub fn compute_root_layout(comptime Tree: type, tree_ref: *Tree, root: NodeId, available_space: geometry.Size(AvailableSpace)) ComputeError!layout.LayoutOutput {
    const TreeApi = LayoutTree(Tree);
    TreeApi.begin_layout_pass(tree_ref);
    defer TreeApi.end_layout_pass(tree_ref);

    const root_style = TreeApi.get_style(tree_ref, root);
    const direction = root_style.direction;
    const position = root_style.position;

    const icb_size = geometry.Size(?f32){
        .width = available_space.width.into_option(),
        .height = available_space.height.into_option(),
    };

    // When the root's layout is served from the cache its layout algorithm does
    // not run, so the hoisted children it recorded on a previous run (including
    // those added by the root positioning pass below) are still in place and must
    // not be re-added.
    var root_is_cached = false;

    var root_layout: layout.Layout = undefined;
    var candidates: layout.OofCandidates = .empty;

    if (position.is_out_of_flow() and icb_size.width != null and icb_size.height != null) {
        // The static position of the root places its margin box at the origin of the ICB
        const area_size = geometry.Size(f32){ .width = icb_size.width.?, .height = icb_size.height.? };
        const start: f32 = if (direction.is_rtl()) area_size.width else 0;
        const candidate = layout.OofCandidate{
            .node = root,
            .order = 0,
            .position = position,
            .static_position = .{
                .x = .{
                    .area = .{ .start = start, .end = start },
                    .alignment = layout.AxisStaticAlign.from_keyword(if (direction.is_rtl()) layout.AxisStaticEdge.end else layout.AxisStaticEdge.start),
                },
                .y = layout.AxisStaticPosition.from_edge(0, .start),
            },
        };
        const box_layout = try oof.layout_oof_box(Tree, tree_ref, candidate, area_size, .{ .x = 0, .y = 0 }, direction,
            // The initial containing block is not a scroll container
            .{ .x = .visible, .y = .visible },
            null, &root_is_cached);
        root_layout = box_layout.layout;
        candidates = box_layout.surfaced;
    } else {
        const in_flow = try compute_in_flow_root_layout(Tree, tree_ref, root, available_space, &root_is_cached);
        candidates = in_flow.output.oof_candidates;
        root_layout = in_flow.layout;
    }

    // Final positioning pass for out-of-flow boxes with no nearer containing
    // block: the initial containing block is the containing block for
    // `position: fixed` boxes and for `position: absolute` boxes with no
    // positioned ancestor.
    if (candidates.items.len != 0) {
        const overflow = TreeApi.get_style(tree_ref, root).overflow;

        // The initial containing block has the dimensions of the viewport (the
        // available_space space) and is anchored at the canvas origin. In an axis where
        // the available_space space is indefinite, fall back to the root's padding box.
        const area_inset = root_layout.border.add(geometry.Rect(f32){
            .left = 0,
            .right = root_layout.scrollbar_size.width,
            .top = 0,
            .bottom = root_layout.scrollbar_size.height,
        });
        const root_padding_box_size = root_layout.size.sub(geometry.Size(f32){
            .width = area_inset.horizontal_axis_sum(),
            .height = area_inset.vertical_axis_sum(),
        });
        const area_width: f32 = if (icb_size.width) |width| @max(width - root_layout.scrollbar_size.width, 0) else root_padding_box_size.width;
        const area_x: f32 = if (icb_size.width != null) -root_layout.location.x else area_inset.left;
        const area_height: f32 = if (icb_size.height) |height| @max(height - root_layout.scrollbar_size.height, 0) else root_padding_box_size.height;
        const area_y: f32 = if (icb_size.height != null) -root_layout.location.y else area_inset.top;

        const scratch = tree_ref.scratch_allocator();
        var hoisted = std.ArrayList(NodeId).empty;
        defer hoisted.deinit(scratch);
        var unclaimed: layout.OofCandidates = .empty;
        // The root's own `Layout.scrollable_overflow_rect` is not recomputed from
        // the hoisted boxes: Taffy's root pass likewise records only the root
        // algorithm's overflow, and consumers read a hoisted box's own rect via
        // its layout.
        _ = try oof.perform_oof_layout(
            Tree,
            tree_ref,
            root,
            candidates,
            .{ .width = area_width, .height = area_height },
            .{ .x = area_x, .y = area_y },
            direction,
            .all,
            overflow,
            .{ .x = direction.is_rtl(), .y = false },
            &hoisted,
            &unclaimed);
        std.debug.assert(unclaimed.items.len == 0);
        if (!root_is_cached) try tree_ref.add_hoisted_children(root, hoisted.items);
    }

    return .{ .size = root_layout.size, .scrollable_overflow_rect = root_layout.scrollable_overflow_rect };
}

/// The result of laying out an in-flow root node.
const InFlowRootLayout = struct {
    /// The root's stored layout.
    layout: layout.Layout,
    /// The layout output, whose `oof_candidates` still holds out-of-flow boxes
    /// bubbled up from the root's subtree.
    output: layout.LayoutOutput,
};

/// Lay out an in-flow (or `position: relative`) root node against the available_space
/// space, store its layout and return it. Out-of-flow candidates bubbled up from
/// its subtree are left in `output.oof_candidates` for the caller to consume.
fn compute_in_flow_root_layout(comptime Tree: type, tree_ref: *Tree,
    root: NodeId,
    available_space: geometry.Size(AvailableSpace),
    root_is_cached: *bool) ComputeError!InFlowRootLayout {
    const TreeApi = LayoutTree(Tree);
    var known_dimensions = geometry.Size(?f32){ .width = null, .height = null };

    const root_style = TreeApi.get_style(tree_ref, root);

    // The available space passed to the root excludes the root's margins
    const root_available_space = blk: {
        const m = common.resolve_rect_or_zero(root_style.margin, available_space.width.into_option());
        break :blk geometry.Size(AvailableSpace){
            .width = math.available_maybe_max(math.available_maybe_sub(available_space.width, m.left + m.right), 0),
            .height = math.available_maybe_max(math.available_maybe_sub(available_space.height, m.top + m.bottom), 0),
        };
    };

    // Block roots pre-resolve styled sizes and available_space-space width into known
    // dimensions before dispatching, exactly like Taffy.
    if (root_style.is_block()) {
        const parent_size = geometry.Size(?f32){ .width = available_space.width.into_option(), .height = available_space.height.into_option() };
        const aspect_ratio = root_style.aspect_ratio;
        const padding = common.resolve_length_rect(root_style.padding, parent_size.width);
        const border = common.resolve_length_rect(root_style.border, parent_size.width);
        const padding_border_size = geometry.Size(f32){ .width = padding.left + padding.right + border.left + border.right, .height = padding.top + padding.bottom + border.top + border.bottom };
        const box_sizing_adjustment = if (root_style.box_sizing == .content_box) padding_border_size else geometry.Size(f32){ .width = 0, .height = 0 };

        const min_size = addSize(applyAspectRatio(resolveAutoSize(root_style.min_size, parent_size), aspect_ratio), box_sizing_adjustment);
        const max_size = addSize(resolveAutoSize(root_style.max_size, parent_size), box_sizing_adjustment);
        const clamped_style_size = clampSize(addSize(applyAspectRatio(resolveDimensionSize(root_style.size, parent_size), aspect_ratio), box_sizing_adjustment), min_size, max_size);
        const min_max_definite_size = geometry.Size(?f32){
            .width = if (min_size.width) |min| if (max_size.width) |max| if (max <= min) min else null else null else null,
            .height = if (min_size.height) |min| if (max_size.height) |max| if (max <= min) min else null else null else null,
        };
        // Block-level boxes stretch to fill definite available_space space.
        const available_space_based_size = geometry.Size(?f32){
            .width = root_available_space.width.into_option(),
            .height = null,
        };
        known_dimensions = orSize(orSize(orSize(known_dimensions, min_max_definite_size), clamped_style_size), available_space_based_size);
        known_dimensions = maybeMaxSize(known_dimensions, padding_border_size);
    }

    const input = layout.LayoutInput{
        .run_mode = .perform_layout,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .known_dimensions = known_dimensions,
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = icbFor(available_space),
        .available_space = root_available_space,
        .vertical_margins_are_collapsible = .{ .start = false, .end = false },
    };
    root_is_cached.* = LayoutTree(Tree).cache_get(tree_ref, root, &input) != null;

    const output = try compute_cached_layout(Tree, tree_ref, root, input);

    const style_ref = TreeApi.get_style(tree_ref, root);
    const available_width = available_space.width.into_option();
    const padding = common.resolve_length_rect(style_ref.padding, available_width);
    const border = common.resolve_length_rect(style_ref.border, available_width);
    const margin = common.resolve_rect_or_zero(style_ref.margin, available_width);
    const scrollbar_size = geometry.Size(f32){
        .width = if (style_ref.overflow.y == .scroll) style_ref.scrollbar_width else 0,
        .height = if (style_ref.overflow.x == .scroll) style_ref.scrollbar_width else 0,
    };
    const is_rtl = style_ref.direction.is_rtl();

    // The root's margin box is placed at the origin of the initial containing block
    var location = geometry.Point(f32){
        .x = switch (is_rtl) {
            true => if (available_width) |width| width - output.size.width - margin.right else margin.left,
            false => margin.left,
        },
        .y = margin.top,
    };

    // A relatively positioned root is offset by its insets, resolved against the initial containing block
    if (style_ref.position == .relative) {
        const icb = icbFor(available_space);
        const left = style_ref.inset.left.resolve_to_option(icb.width);
        const right = style_ref.inset.right.resolve_to_option(icb.width);
        const top = style_ref.inset.top.resolve_to_option(icb.height);
        const bottom = style_ref.inset.bottom.resolve_to_option(icb.height);
        location.x += if (is_rtl)
            (if (right) |value| -value else left orelse 0)
        else
            (left orelse (if (right) |value| -value else 0));
        location.y += top orelse (if (bottom) |value| -value else 0);
    }

    const stored = layout.Layout{
        .order = 0,
        .location = location,
        .size = output.size,
        .scrollable_overflow_rect = output.scrollable_overflow_rect,
        .scrollbar_size = scrollbar_size,
        .padding = padding,
        .border = border,
        .margin = margin,
    };
    try LayoutTree(Tree).set_unrounded_layout(tree_ref, root, stored);
    try LayoutTree(Tree).set_final_layout(tree_ref, root, stored);
    return .{ .layout = stored, .output = output };
}

fn icbFor(available_space: geometry.Size(AvailableSpace)) geometry.Size(?f32) {
    return .{ .width = available_space.width.into_option(), .height = available_space.height.into_option() };
}

pub fn compute_hidden_layout(comptime Tree: type, tree_ref: *Tree, node_id: NodeId) ComputeError!layout.LayoutOutput {
    const TreeApi = LayoutTree(Tree);
    try TreeApi.cache_clear(tree_ref, node_id);
    try TreeApi.set_unrounded_layout(tree_ref, node_id, .with_order(0));
    try TreeApi.set_final_layout(tree_ref, node_id, .with_order(0));
    for (try TreeApi.child_ids(tree_ref, node_id)) |child_id| {
        _ = try compute_hidden_layout(Tree, tree_ref, child_id);
    }
    return layout.LayoutOutput.hidden;
}

fn taffyRound(value: f32) f32 {
    // Taffy's `util/sys.rs::round`: ties go toward +infinity, unlike Zig @round.
    return @floor(value + 0.5);
}

pub fn round_layout(comptime Tree: type, tree_ref: *Tree, node_id: NodeId) !void {
    try round_layout_inner(Tree, tree_ref, node_id, 0, 0);
}

pub fn round_layout_inner(comptime Tree: type, tree_ref: *Tree, node_id: NodeId, cumulative_x: f32, cumulative_y: f32) !void {
    const TreeApi = LayoutTree(Tree);
    const unrounded = try TreeApi.unrounded_layout(tree_ref, node_id);
    // Round a node's location as `round(abs) - round(parent_abs)` rather than
    // `round(relative)`, matching how sizes are already rounded. Children of a
    // parent at a fractional offset then tile exactly without 1px gaps/overlaps.
    const parent_x = cumulative_x;
    const parent_y = cumulative_y;
    const absolute_x = cumulative_x + unrounded.location.x;
    const absolute_y = cumulative_y + unrounded.location.y;
    var rounded = unrounded;
    rounded.location.x = taffyRound(absolute_x) - taffyRound(parent_x);
    rounded.location.y = taffyRound(absolute_y) - taffyRound(parent_y);
    rounded.size.width = taffyRound(absolute_x + unrounded.size.width) - taffyRound(absolute_x);
    rounded.size.height = taffyRound(absolute_y + unrounded.size.height) - taffyRound(absolute_y);
    rounded.border.left = taffyRound(absolute_x + unrounded.border.left) - taffyRound(absolute_x);
    rounded.border.right = taffyRound(absolute_x + unrounded.size.width) - taffyRound(absolute_x + unrounded.size.width - unrounded.border.right);
    rounded.border.top = taffyRound(absolute_y + unrounded.border.top) - taffyRound(absolute_y);
    rounded.border.bottom = taffyRound(absolute_y + unrounded.size.height) - taffyRound(absolute_y + unrounded.size.height - unrounded.border.bottom);
    rounded.padding.left = taffyRound(absolute_x + unrounded.padding.left) - taffyRound(absolute_x);
    rounded.padding.right = taffyRound(absolute_x + unrounded.size.width) - taffyRound(absolute_x + unrounded.size.width - unrounded.padding.right);
    rounded.padding.top = taffyRound(absolute_y + unrounded.padding.top) - taffyRound(absolute_y);
    rounded.padding.bottom = taffyRound(absolute_y + unrounded.size.height) - taffyRound(absolute_y + unrounded.size.height - unrounded.padding.bottom);
    {
        // Round each edge in absolute coordinates; a zero result keeps its edge's
        // sign so left/top stay -0.0 (re-packing restores right/bottom reversal).
        const r = unrounded.scrollable_overflow_rect.rect();
        const roundEdge = struct {
            fn call(offset: f32, edge: f32) f32 {
                const value = taffyRound(offset + edge) - taffyRound(offset);
                return if (value == 0) std.math.copysign(value, edge) else value;
            }
        }.call;
        rounded.scrollable_overflow_rect = layout.ScrollableOverflow.new(.{
            .left = roundEdge(absolute_x, r.left),
            .right = roundEdge(absolute_x, r.right),
            .top = roundEdge(absolute_y, r.top),
            .bottom = roundEdge(absolute_y, r.bottom),
        }, unrounded.scrollable_overflow_rect.is_reversed());
    }
    rounded.scrollbar_size.width = taffyRound(unrounded.scrollbar_size.width);
    rounded.scrollbar_size.height = taffyRound(unrounded.scrollbar_size.height);
    try TreeApi.set_final_layout(tree_ref, node_id, rounded);
    // Recurse into in-flow children. Out-of-flow (absolute/fixed) children are
    // skipped here: they are instead visited via their containing block's hoisted
    // child list below, which ensures each node is visited exactly once and that
    // its cumulative offset is accumulated relative to its containing block (which
    // its `location` is relative to).
    for (try TreeApi.child_ids(tree_ref, node_id)) |child_id| {
        if (TreeApi.is_out_of_flow(tree_ref, child_id)) continue;
        try round_layout_inner(Tree, tree_ref, child_id, absolute_x, absolute_y);
    }
    // Recurse into out-of-flow boxes for which this node is the containing block
    const hoisted_count = try TreeApi.hoisted_child_count(tree_ref, node_id);
    for (0..hoisted_count) |index| {
        try round_layout_inner(Tree, tree_ref, try TreeApi.get_hoisted_child_id(tree_ref, node_id, index), absolute_x, absolute_y);
    }
}

fn resolveDimensionSize(value: geometry.Size(style.dimension.Dimension), parent: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = value.width.resolve(parent.width), .height = value.height.resolve(parent.height) };
}

fn resolveAutoSize(value: geometry.Size(style.dimension.LengthPercentageAuto), parent: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = value.width.resolve_to_option(parent.width), .height = value.height.resolve_to_option(parent.height) };
}

fn applyAspectRatio(value: geometry.Size(?f32), ratio: ?f32) geometry.Size(?f32) {
    if (ratio) |r| {
        if (value.width) |width| {
            if (value.height == null) return .{ .width = width, .height = width / r };
        }
        if (value.height) |height| {
            if (value.width == null) return .{ .width = height * r, .height = height };
        }
    }
    return value;
}

fn addSize(value: geometry.Size(?f32), add: geometry.Size(f32)) geometry.Size(?f32) {
    return .{ .width = if (value.width) |v| v + add.width else null, .height = if (value.height) |v| v + add.height else null };
}

fn orSize(a: geometry.Size(?f32), b: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{ .width = a.width orelse b.width, .height = a.height orelse b.height };
}

fn clampSize(value: geometry.Size(?f32), min: geometry.Size(?f32), max: geometry.Size(?f32)) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| @max(@min(v, max.width orelse std.math.inf(f32)), min.width orelse -std.math.inf(f32)) else null,
        .height = if (value.height) |v| @max(@min(v, max.height orelse std.math.inf(f32)), min.height orelse -std.math.inf(f32)) else null,
    };
}

fn maybeMaxSize(value: geometry.Size(?f32), floor: geometry.Size(f32)) geometry.Size(?f32) {
    return .{
        .width = if (value.width) |v| @max(v, floor.width) else null,
        .height = if (value.height) |v| @max(v, floor.height) else null,
    };
}

test {
    _ = geometry.Size(f32);
    _ = style.Style{};
}

test "root dispatcher executes the first flex layout path" {
    const testing = @import("std").testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const child_a = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(10) } });
    const child_b = try tree_ref.new_leaf(.{ .size = .{ .width = .length(30), .height = .length(10) } });
    const root = try tree_ref.new_with_children(.{}, &[_]NodeId{ child_a, child_b });
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
    try testing.expectEqual(@as(f32, 20), (try tree_ref.layout_of(child_a)).size.width);
    try testing.expectEqual(@as(f32, 20), (try tree_ref.layout_of(child_b)).location.x);
}

test "root dispatcher executes the first grid layout path" {
    const testing = @import("std").testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const child = try tree_ref.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const columns = [_]style.grid.GridTemplateComponent{
        .{ .single = style.grid.TrackSizingFunction.from_length(40) },
        .{ .single = style.grid.TrackSizingFunction.from_fr(1) },
    };
    const rows = [_]style.grid.GridTemplateComponent{.{ .single = style.grid.TrackSizingFunction.from_length(20) }};
    const root = try tree_ref.new_with_children(.{ .display = .grid, .grid_template_columns = &columns, .grid_template_rows = &rows }, &[_]NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 50 } });
    try testing.expectEqual(@as(f32, 10), (try tree_ref.layout_of(child)).size.width);
}

test "display none recursively hides descendants" {
    const testing = @import("std").testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const grandchild = try tree_ref.new_leaf(.{ .size = .{ .width = .length(20), .height = .length(20) } });
    const child = try tree_ref.new_with_children(.{}, &[_]NodeId{grandchild});
    const root = try tree_ref.new_with_children(.{ .display = .none, .size = .{ .width = .length(50), .height = .length(50) } }, &[_]NodeId{child});
    try tree_ref.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(root)).size.width);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(child)).size.width);
    try testing.expectEqual(@as(f32, 0), (try tree_ref.layout_of(grandchild)).size.width);
}

test "LayoutInput.HIDDEN produces hidden layout for a visible tree" {
    const testing = @import("std").testing;
    var tree_ref = tree.Tree.init(testing.allocator);
    defer tree_ref.deinit();
    const leaf_node = try tree_ref.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(11) } });
    const hidden = try compute_child_layout(tree.Tree, &tree_ref, leaf_node, layout.LayoutInput.HIDDEN);
    try testing.expectEqual(@as(f32, 0), hidden.size.width);
    try testing.expectEqual(@as(f32, 0), hidden.size.height);
}

test {
    _ = @import("block.zig");
    _ = @import("common/root.zig");
    _ = @import("flexbox.zig");
    _ = @import("float.zig");
    _ = @import("grid/root.zig");
    _ = @import("leaf.zig");
}

test "cached child layouts still surface their out-of-flow candidates" {
    const testing = std.testing;
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();
    // root (containing block) -> [sibling S, A (static block) -> B (absolute, bottom: 0)]
    const b = try t.new_leaf(.{
        .position = .absolute,
        .size = .{ .width = style.dimension.Dimension.length(10), .height = style.dimension.Dimension.length(10) },
        .inset = .{ .left = .length(0), .right = .auto(), .top = .auto(), .bottom = .length(0) },
    });
    const a = try t.new_with_children(.{ .display = .block }, &.{b});
    const s = try t.new_leaf(.{ .size = .{ .width = style.dimension.Dimension.length(10), .height = style.dimension.Dimension.length(10) } });
    const root = try t.new_with_children(.{ .display = .block, .position = .relative }, &.{ s, a });
    try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .max_content });
    try testing.expectEqual(@as(f32, 0), (try t.layout_of(b)).location.y); // root is 10 tall

    // Grow the sibling: root re-lays out, A is a cache hit, B must follow the new bottom edge.
    try t.set_style(s, .{ .size = .{ .width = style.dimension.Dimension.length(10), .height = style.dimension.Dimension.length(50) } });
    try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .max_content });
    try testing.expectEqual(@as(f32, 50), (try t.layout_of(root)).size.height);
    try testing.expectEqual(@as(f32, 40), (try t.layout_of(b)).location.y);
}

test "allocation failures never leave a stale layout behind (cache invalidation invariant)" {
    const testing = std.testing;
    var fail_index: usize = 0;
    var completed = false;
    while (fail_index < 200 and !completed) : (fail_index += 1) {
        var failing = FailOnce{ .backing = testing.allocator, .fail_at = fail_index };
        var t = tree.Tree.init(failing.allocator());
        defer t.deinit();
        // relative root -> static block A (height 10) -> absolute descendant
        const abs = t.new_leaf(.{ .position = .absolute, .size = .{ .width = style.dimension.Dimension.length(5), .height = style.dimension.Dimension.length(5) } }) catch continue;
        const a = t.new_with_children(.{ .display = .block, .size = .{ .width = style.dimension.Dimension.auto, .height = style.dimension.Dimension.length(10) } }, &.{abs}) catch continue;
        const root = t.new_with_children(.{ .display = .block, .position = .relative }, &.{a}) catch continue;
        t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .max_content }) catch continue;
        t.set_style(a, .{ .display = .block, .size = .{ .width = style.dimension.Dimension.auto, .height = style.dimension.Dimension.length(50) } }) catch continue;
        t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .max_content }) catch continue;
        // Whatever failed earlier, a layout that reports success must be correct.
        try testing.expectEqual(@as(f32, 50), (try t.layout_of(root)).size.height);
        if (!failing.failed) completed = true;
    }
    try testing.expect(completed);
}

/// Fails exactly one allocation (the `fail_at`-th), so code paths that swallow
/// an allocation failure keep running and expose any inconsistent state.
const FailOnce = struct {
    backing: std.mem.Allocator,
    fail_at: usize,
    count: usize = 0,
    failed: bool = false,

    fn allocator(self: *FailOnce) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        defer self.count += 1;
        if (self.count == self.fail_at) {
            self.failed = true;
            return null;
        }
        return self.backing.rawAlloc(len, alignment, ret);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret);
    }
};

test "a cached block child does not lose the floats it placed (Taffy has this bug too)" {
    const testing = std.testing;
    var t = tree.Tree.init(testing.allocator);
    defer t.deinit();
    const D = style.dimension.Dimension;
    const float_box = try t.new_leaf(.{ .display = .block, .float = .left, .size = .{ .width = D.length(20), .height = D.length(40) } });
    const wrapper = try t.new_with_children(.{ .display = .block }, &.{float_box});
    const sibling = try t.new_leaf(.{ .display = .block, .size = .{ .width = D.length(10), .height = D.length(20) } });
    const root = try t.new_with_children(.{ .display = .block, .size = .{ .width = D.length(100), .height = .auto } }, &.{ wrapper, sibling });
    const space = geometry.Size(AvailableSpace){ .width = .max_content, .height = .max_content };
    try t.compute_layout(root, space);
    try testing.expectEqual(@as(f32, 40), (try t.layout_of(root)).size.height);
    // Edit only the sibling: the wrapper must not be served stale from the cache.
    try t.set_style(sibling, .{ .display = .block, .size = .{ .width = D.length(11), .height = D.length(20) } });
    try t.compute_layout(root, space);
    try testing.expectEqual(@as(f32, 40), (try t.layout_of(root)).size.height);
}
