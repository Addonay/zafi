//! Comptime tree interface, matching Taffy's `tree/traits.rs`.
//!
//! Taffy's layout algorithms are generic over a tree type, so a host can run
//! them against its own node store and style types. This module provides the
//! same capability for Zig: `LayoutTree` is the contract a host type must
//! satisfy, and the algorithms are generic over it.
//!
//! Nothing here is a runtime function table. A missing or wrong implementation
//! is a compile error at the call site, not a `null` callback that panics
//! during layout.
//!
//! # Implementing a custom tree
//!
//! A host type supplies these methods (names are the convention; see
//! `LayoutTree` for the full list):
//!
//! ```zig
//! const MyTree = struct {
//!     nodes: std.ArrayList(MyNode),
//!
//!     pub fn child_count(self: *const MyTree, id: NodeId) Error!usize { ... }
//!     pub fn child_at(self: *const MyTree, id: NodeId, index: usize) Error!NodeId { ... }
//!     pub fn child_ids(self: *const MyTree, id: NodeId) Error![]const NodeId { ... }
//!
//!     pub fn get_style(self: *const MyTree, id: NodeId) *const Style { ... }
//!     pub fn calc(self: *const MyTree, value: ?*const anyopaque, basis: f32) Error!f32 { ... }
//!
//!     pub fn compute_child_layout(self: *MyTree, id: NodeId, input: LayoutInput) Error!LayoutOutput { ... }
//!     pub fn cache_get(self: *MyTree, id: NodeId, input: *const LayoutInput) Error!?LayoutOutput { ... }
//!     pub fn cache_store(self: *MyTree, id: NodeId, input: *const LayoutInput, out: LayoutOutput) Error!void { ... }
//!
//!     Caching contract: `out.oof_candidates` lives in pass-scoped scratch memory.
//!     If `cache_store` caches a `perform_layout` result it must keep its own
//!     copy of those candidates, and `cache_get` must return them again (as a
//!     fresh scratch-allocated list) on a hit: they are how absolutely
//!     positioned descendants reach a containing block further up the tree.
//!     `Cache` stores sizes and metadata only; see `Tree.cache_store`.
//!
//!     pub fn set_unrounded_layout(self: *MyTree, id: NodeId, value: Layout) Error!void { ... }
//!     pub fn unrounded_layout(self: *const MyTree, id: NodeId) Error!Layout { ... }
//!     pub fn set_final_layout(self: *MyTree, id: NodeId, value: Layout) Error!void { ... }
//!
//!     pub fn scratch_allocator(self: *MyTree) std.mem.Allocator { ... }
//!
//!     pub fn is_out_of_flow(self: *const MyTree, id: NodeId) bool { ... }
//!     pub fn clear_hoisted_children(self: *MyTree, id: NodeId) Error!void { ... }
//!     pub fn add_hoisted_children(self: *MyTree, id: NodeId, hoisted: []const NodeId) Error!void { ... }
//!     pub fn hoisted_child_count(self: *const MyTree, id: NodeId) Error!usize { ... }
//!     pub fn get_hoisted_child_id(self: *const MyTree, id: NodeId, index: usize) Error!NodeId { ... }
//!     pub fn get_detailed_layout_info(self: *const MyTree, id: NodeId) ?*const anyopaque { ... }
//! };
//! ```
//!
//! Then `zafi.compute_block_layout(MyTree, my_tree, root, input, null)` and the
//! other entry points accept it directly.
//!
//! Names ending in `_impl` are also accepted, which is convenient when the host
//! type already has a conflicting `child_count` (or similar) member. A host that
//! implements neither form fails to compile with a message naming the missing
//! method.
//!
//! # Scope
//!
//! `LayoutTree` covers traversal, style access, cache access, layout read/write,
//! `calc()` resolution and the out-of-flow containing-block bookkeeping. Node
//! context is deliberately absent: it is passed to the host's own measure
//! callback rather than being an algorithm input.

const std = @import("std");
const geometry = @import("../geometry.zig");
const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;
const style = @import("../style/root.zig");
const layout = @import("layout.zig");
const node = @import("node.zig");

pub const NodeId = node.NodeId;

/// Compute-time measure callback, matching Taffy's
/// `FnMut(LayoutInput, NodeId, Option<&mut NodeContext>, &Style) -> LayoutOutput`.
///
/// The context pointer is host-owned and opaque to the algorithms; the tree
/// decides how to obtain it (see `Tree.compute_layout_with_measure`).
pub const MeasureFunc = *const fn (
    context: ?*anyopaque,
    inputs: layout.LayoutInput,
    node_id: NodeId,
    style: *const style.Style,
) layout.LayoutOutput;

/// Fail the build, naming the method, when a host type is missing part of the
/// contract. Without this a host that forgot a method would only fail at the
/// (deeply nested) call site that uses it.
fn require_method(comptime Self: type, comptime base: []const u8) void {
    if (@hasDecl(Self, base)) return;
    if (@hasDecl(Self, base ++ "_impl")) return;
    @compileError("LayoutTree: " ++ @typeName(Self) ++ " must implement `" ++ base ++ "` (or `" ++ base ++ "_impl" ++ "`)");
}

/// Downward traversal plus the host operations the algorithms need.
///
/// Every method is part of the contract; there are no runtime defaults, so a
/// host that cannot support one cannot satisfy the interface at all. That is
/// deliberate: Taffy's traits have defaults only where the default is always
/// correct, and silently defaulting here would hide a host that cannot support
/// grid detail output or out-of-flow positioning.
pub fn LayoutTree(comptime Self: type) type {
    return struct {
        /// This tree type. Present so a host can name it in error sets and
        /// diagnostics without a second type parameter.
        pub const Tree = Self;

        /// The error set the algorithms raise when the tree itself does not
        /// narrow it. A tree whose operations are infallible returns
        /// `LayoutError`; a tree with its own failures returns an explicit set
        /// (usually `Tree.Error`).
        pub const LayoutError = error{
            InvalidParentNode,
            InvalidChildNode,
            InvalidInputNode,
            ChildIndexOutOfBounds,
            InvalidLayoutMode,
            OutOfMemory,
            Cycle,
            DuplicateChild,
            NodeIdExhausted,
        };

        /// The error set this interface's operations produce.
        pub const Error = if (@hasDecl(Self, "Error")) Self.Error else LayoutError;

        // -- Traversal ------------------------------------------------------

        /// Number of children of `node_id`.
        pub inline fn child_count(tree: *const Self, node_id: NodeId) Error!usize {
            comptime require_method(Self, "child_count");
            if (comptime @hasDecl(Self, "child_count")) return tree.child_count(node_id);
            return tree.child_count_impl(node_id);
        }

        /// The `index`-th child of `node_id`.
        pub inline fn child_at(tree: *const Self, node_id: NodeId, index: usize) Error!NodeId {
            comptime require_method(Self, "child_at");
            if (comptime @hasDecl(Self, "child_at")) return tree.child_at(node_id, index);
            return tree.child_at_impl(node_id, index);
        }

        /// The children of `node_id` as a slice.
        ///
        /// A tree whose children are not contiguously stored builds a slice here.
        /// Taffy's equivalent is an iterator; the algorithms here only walk the
        /// list once per pass, so the difference is not observable.
        pub inline fn child_ids(tree: *const Self, node_id: NodeId) Error![]const NodeId {
            comptime require_method(Self, "child_ids");
            if (comptime @hasDecl(Self, "child_ids")) return tree.child_ids(node_id);
            return tree.child_ids_impl(node_id);
        }

        /// Allocator for layout-pass temporaries.
        ///
        /// The algorithms allocate per-pass working memory (item lists, resolved
        /// placements, occupancy matrices) here. Anything obtained from it is
        /// valid only until the next top-level layout pass: the dispatcher resets
        /// the allocator when a pass starts outside every other pass. Nothing
        /// allocated from it may be stored in the tree or in a `LayoutOutput` that
        /// the tree keeps.
        ///
        /// A host without a scratch allocator can return a long-lived arena and
        /// reset it in `begin_layout_pass`; a host that does not care about
        /// allocation churn can return its general allocator.
        /// Optional: hosts with a stack-like scratch allocator can let the
        /// caching wrapper reclaim a finished child layout's temporaries early.
        pub const ScratchMark = if (@hasDecl(Self, "scratch_mark")) @typeInfo(@TypeOf(Self.scratch_mark)).@"fn".return_type.? else void;

        pub const scratch_mark = if (@hasDecl(Self, "scratch_mark")) scratchMarkImpl else scratchMarkNoop;
        pub const scratch_release = if (@hasDecl(Self, "scratch_release")) scratchReleaseImpl else scratchReleaseNoop;
        inline fn scratchMarkImpl(tree: *Self) ScratchMark {
            return tree.scratch_mark();
        }
        inline fn scratchMarkNoop(_: *Self) void {}
        inline fn scratchReleaseImpl(tree: *Self, mark: ScratchMark) void {
            tree.scratch_release(mark);
        }
        inline fn scratchReleaseNoop(_: *Self, _: void) void {}

        pub inline fn scratch_allocator(tree: *Self) std.mem.Allocator {
            comptime require_method(Self, "scratch_allocator");
            if (comptime @hasDecl(Self, "scratch_allocator")) return tree.scratch_allocator();
            return tree.scratch_allocator_impl();
        }

        /// Called when a top-level layout pass begins (a pass that is not nested
        /// inside another pass). The host resets its scratch allocator here.
        ///
        /// Required rather than defaulted: forgetting it means the scratch
        /// arena grows without bound across passes, which looks like a slow
        /// leak rather than a missing method.
        pub inline fn begin_layout_pass(tree: *Self) void {
            comptime require_method(Self, "begin_layout_pass");
            if (comptime @hasDecl(Self, "begin_layout_pass")) return tree.begin_layout_pass();
            return tree.begin_layout_pass_impl();
        }

        /// Called when a top-level layout pass ends. Paired with
        /// `begin_layout_pass`; a host that only resets memory can leave this
        /// empty, but must still declare it.
        pub inline fn end_layout_pass(tree: *Self) void {
            comptime require_method(Self, "end_layout_pass");
            if (comptime @hasDecl(Self, "end_layout_pass")) return tree.end_layout_pass();
            return tree.end_layout_pass_impl();
        }

        // -- Styles ---------------------------------------------------------

        /// The style of `node_id`. Must stay valid for the duration of the
        /// layout pass.
        ///
        /// Non-optional, matching Taffy's `get_*_style`, which assumes the id is
        /// live: the algorithms only ever ask about ids they walked to.
        pub inline fn get_style(tree: *const Self, node_id: NodeId) *const style.Style {
            comptime require_method(Self, "get_style");
            if (comptime @hasDecl(Self, "get_style")) return tree.get_style(node_id);
            return tree.get_style_impl(node_id);
        }

        /// Resolve a `calc()` length against `basis`, or return null when this host
        /// has no expression engine.
        ///
        /// Null rather than an error tag on purpose: the algorithms' error set
        /// is fixed, so a host-specific error could not travel through them
        /// anyway. Declining explicitly is also better than Taffy's
        /// `DefaultCheapStr` behaviour of resolving to zero, which makes an
        /// unevaluated expression indistinguishable from a real zero.
        pub fn calc(tree: *const Self, value: ?*const anyopaque, basis: f32) ?f32 {
            comptime require_method(Self, "calc");
            if (comptime @hasDecl(Self, "calc")) return tree.calc(value, basis);
            return tree.calc_impl(value, basis);
        }

        // -- Layout ---------------------------------------------------------

        /// Lay out `node_id` under `input`, consulting and updating the cache.
        pub inline fn compute_child_layout(tree: *Self, node_id: NodeId, input: layout.LayoutInput) Error!layout.LayoutOutput {
            comptime require_method(Self, "compute_child_layout");
            if (comptime @hasDecl(Self, "compute_child_layout")) return tree.compute_child_layout(node_id, input);
            return tree.compute_child_layout_impl(node_id, input);
        }

        /// Read the cached output for `input`, if any. A miss is not an error, and
        /// neither is an unknown id, so this cannot fail.
        pub inline fn cache_get(tree: *Self, node_id: NodeId, input: *const layout.LayoutInput) ?layout.LayoutOutput {
            comptime require_method(Self, "cache_get");
            if (comptime @hasDecl(Self, "cache_get")) return tree.cache_get(node_id, input);
            return tree.cache_get_impl(node_id, input);
        }

        /// Store `output` as the cached result for `input`.
        pub inline fn cache_store(tree: *Self, node_id: NodeId, input: *const layout.LayoutInput, output: layout.LayoutOutput) Error!void {
            comptime require_method(Self, "cache_store");
            if (comptime @hasDecl(Self, "cache_store")) return tree.cache_store(node_id, input, output);
            return tree.cache_store_impl(node_id, input, output);
        }

        /// Record algorithm-produced detailed output for `node_id`.
        ///
        /// `info` is host-allocated and `deinit_fn` releases it, so the host
        /// stays responsible for the representation; `clear_detailed_layout_info`
        /// and `deinit` must route through the same destructor.
        pub inline fn set_detailed_layout_info(tree: *Self, node_id: NodeId, info: *const anyopaque, deinit_fn: *const fn (*const anyopaque, std.mem.Allocator) void) Error!void {
            comptime require_method(Self, "set_detailed_layout_info");
            if (comptime @hasDecl(Self, "set_detailed_layout_info")) return tree.set_detailed_layout_info(node_id, info, deinit_fn);
            return tree.set_detailed_layout_info_impl(node_id, info, deinit_fn);
        }

        /// Drop `node_id`'s cached entries and invalidate its ancestors.
        ///
        /// The algorithms call this when a node becomes hidden, so its stale
        /// layout cannot be served to a parent that is still visible.
        pub inline fn cache_clear(tree: *Self, node_id: NodeId) Error!void {
            comptime require_method(Self, "cache_clear");
            if (comptime @hasDecl(Self, "cache_clear")) return tree.cache_clear(node_id);
            return tree.cache_clear_impl(node_id);
        }


        /// Write the unrounded layout the algorithms computed for `node_id`.
        pub inline fn set_unrounded_layout(tree: *Self, node_id: NodeId, value: layout.Layout) Error!void {
            comptime require_method(Self, "set_unrounded_layout");
            if (comptime @hasDecl(Self, "set_unrounded_layout")) return tree.set_unrounded_layout(node_id, value);
            return tree.set_unrounded_layout_impl(node_id, value);
        }

        /// Read a node's unrounded layout (used by rounding and debug printing).
        pub fn unrounded_layout(tree: *const Self, node_id: NodeId) Error!layout.Layout {
            comptime require_method(Self, "unrounded_layout");
            if (comptime @hasDecl(Self, "unrounded_layout")) return tree.unrounded_layout(node_id);
            return tree.unrounded_layout_impl(node_id);
        }

        /// Write the rounded layout of `node_id`.
        pub inline fn set_final_layout(tree: *Self, node_id: NodeId, value: layout.Layout) Error!void {
            comptime require_method(Self, "set_final_layout");
            if (comptime @hasDecl(Self, "set_final_layout")) return tree.set_final_layout(node_id, value);
            return tree.set_final_layout_impl(node_id, value);
        }

        // -- Out-of-flow containing blocks ----------------------------------

        /// Whether `node_id` is an out-of-flow (`absolute`/`fixed`) box
        /// generating content. `round_layout` skips these as ordinary children
        /// and visits them via the containing block's hoisted list instead.
        pub inline fn is_out_of_flow(tree: *const Self, node_id: NodeId) bool {
            comptime require_method(Self, "is_out_of_flow");
            if (comptime @hasDecl(Self, "is_out_of_flow")) return tree.is_out_of_flow(node_id);
            return tree.is_out_of_flow_impl(node_id);
        }

        /// Drop the recorded out-of-flow child list of `node_id`.
        pub inline fn clear_hoisted_children(tree: *Self, node_id: NodeId) Error!void {
            comptime require_method(Self, "clear_hoisted_children");
            if (comptime @hasDecl(Self, "clear_hoisted_children")) return tree.clear_hoisted_children(node_id);
            return tree.clear_hoisted_children_impl(node_id);
        }

        /// Append to the recorded out-of-flow child list of `node_id`.
        pub inline fn add_hoisted_children(tree: *Self, node_id: NodeId, hoisted: []const NodeId) Error!void {
            comptime require_method(Self, "add_hoisted_children");
            if (comptime @hasDecl(Self, "add_hoisted_children")) return tree.add_hoisted_children(node_id, hoisted);
            return tree.add_hoisted_children_impl(node_id, hoisted);
        }

        /// Number of out-of-flow boxes whose containing block is `node_id`.
        pub inline fn hoisted_child_count(tree: *const Self, node_id: NodeId) Error!usize {
            comptime require_method(Self, "hoisted_child_count");
            if (comptime @hasDecl(Self, "hoisted_child_count")) return tree.hoisted_child_count(node_id);
            return tree.hoisted_child_count_impl(node_id);
        }

        /// The `index`-th out-of-flow box whose containing block is `node_id`.
        pub inline fn get_hoisted_child_id(tree: *const Self, node_id: NodeId, index: usize) Error!NodeId {
            comptime require_method(Self, "get_hoisted_child_id");
            if (comptime @hasDecl(Self, "get_hoisted_child_id")) return tree.get_hoisted_child_id(node_id, index);
            return tree.get_hoisted_child_id_impl(node_id, index);
        }

        /// Read the detailed layout information recorded for `node_id`.
        ///
        /// The out-of-flow positioning pass consults this to place boxes in grid
        /// areas. A host with no detailed output returns null and its
        /// out-of-flow boxes are positioned against the grid's padding box.
        pub inline fn get_detailed_layout_info(tree: *const Self, node_id: NodeId) ?*const anyopaque {
            comptime require_method(Self, "get_detailed_layout_info");
            if (comptime @hasDecl(Self, "get_detailed_layout_info")) return tree.get_detailed_layout_info(node_id);
            return tree.get_detailed_layout_info_impl(node_id);
        }

        /// Drop the detailed layout information recorded for `node_id`.
        ///
        /// A completed pass that does not produce a grid result must call this,
        /// otherwise a consumer reading the previous pass's track data would be
        /// reading obsolete geometry.
        pub inline fn clear_detailed_layout_info(tree: *Self, node_id: NodeId) Error!void {
            comptime require_method(Self, "clear_detailed_layout_info");
            if (comptime @hasDecl(Self, "clear_detailed_layout_info")) return tree.clear_detailed_layout_info(node_id);
            return tree.clear_detailed_layout_info_impl(node_id);
        }

        /// Lay out `node_id`, which has no children.
        ///
        /// The measure callback is host state, so the host owns this step: the
        /// algorithms call it whenever they reach a childless node. A host with
        /// no measure callback forwards to
        /// `compute.leaf_layout_with_measure(..., null)`.
        pub inline fn compute_leaf_layout(tree: *Self, node_id: NodeId, input: layout.LayoutInput) Error!layout.LayoutOutput {
            comptime require_method(Self, "compute_leaf_layout");
            if (comptime @hasDecl(Self, "compute_leaf_layout")) return tree.compute_leaf_layout(node_id, input);
            return tree.compute_leaf_layout_impl(node_id, input);
        }

        // -- Derived helpers ------------------------------------------------

        /// Measure one absolute axis (`RunMode.compute_size`).
        pub fn measure_child_size(
            tree: *Self,
            node_id: NodeId,
            known_dimensions: geometry.Size(?f32),
            parent_size: geometry.Size(?f32),
            available_space: geometry.Size(AvailableSpace),
            sizing_mode: layout.SizingMode,
            axis: geometry.AbsoluteAxis,
            vertical_margins_are_collapsible: geometry.Line(bool),
        ) Error!f32 {
            const output = try tree.compute_child_layout(node_id, .{
                .run_mode = .compute_size,
                .sizing_mode = sizing_mode,
                .axis = layout.requested_axis_from_absolute(axis),
                .known_dimensions = known_dimensions,
                .known_dimensions_are_definite = .{ .width = true, .height = true },
                .parent_size = parent_size,
                .available_space = available_space,
                .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
            });
            return output.size.get_abs(axis);
        }

        /// Measure both axes in one call (`RunMode.compute_size`).
        pub fn measure_child_size_both(
            tree: *Self,
            node_id: NodeId,
            known_dimensions: geometry.Size(?f32),
            parent_size: geometry.Size(?f32),
            available_space: geometry.Size(AvailableSpace),
            sizing_mode: layout.SizingMode,
            vertical_margins_are_collapsible: geometry.Line(bool),
        ) Error!geometry.Size(f32) {
            const output = try tree.compute_child_layout(node_id, .{
                .run_mode = .compute_size,
                .sizing_mode = sizing_mode,
                .axis = .both,
                .known_dimensions = known_dimensions,
                .known_dimensions_are_definite = .{ .width = true, .height = true },
                .parent_size = parent_size,
                .available_space = available_space,
                .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
            });
            return output.size;
        }

        /// Lay out `node_id` fully (`RunMode.perform_layout`).
        pub fn perform_child_layout(
            tree: *Self,
            node_id: NodeId,
            known_dimensions: geometry.Size(?f32),
            parent_size: geometry.Size(?f32),
            available_space: geometry.Size(AvailableSpace),
            sizing_mode: layout.SizingMode,
            vertical_margins_are_collapsible: geometry.Line(bool),
        ) Error!layout.LayoutOutput {
            return tree.compute_child_layout(node_id, .{
                .run_mode = .perform_layout,
                .sizing_mode = sizing_mode,
                .axis = .both,
                .known_dimensions = known_dimensions,
                .known_dimensions_are_definite = .{ .width = true, .height = true },
                .parent_size = parent_size,
                .available_space = available_space,
                .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
            });
        }
    };
}
