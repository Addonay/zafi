//! Allocator-backed high-level tree corresponding to Taffy's
//! `tree/tree.rs`.
//!
//! # Storage and identity
//!
//! Nodes live in one contiguous slot array, so a `*NodeData` obtained from
//! `raw_node()` is valid only until the next node is created. Identity is
//! *separate* from address: [`NodeId`] is a generational handle (`tree/node.zig`), so an id
//! retained across `remove`/`clear` fails every lookup instead of silently
//! aliasing a recycled node.
//!
//! # Mutation contract
//!
//! The tree maintains a single-parent acyclic forest. Every mutation validates
//! the whole request *before* touching the graph, so a rejected request leaves
//! the tree exactly as it was:
//!
//!   * `error.Cycle` — the request would attach a node beneath itself or beneath
//!     one of its own descendants.
//!   * `error.DuplicateChild` — the same id appears more than once in one list.
//!   * `error.InvalidChildNode` / `error.InvalidParentNode` — the id is not a
//!     live node of this tree.
//!   * `error.ChildIndexOutOfBounds` — the index is past the child list.
//!   * `error.OutOfMemory` — no partial mutation is left behind; nodes created
//!     by `new_with_children` are rolled back when their child list is rejected.
//!
//! Attaching a node that is already a child of the same parent is a **move**
//! (the node keeps a single edge and ends up at the requested position), not a
//! second edge. Attaching a node that currently has a different parent reparents
//! it. `set_children` is alias-safe: passing `tree.children(parent)` back into
//! `set_children` works because the input is snapshotted before the destination
//! array is touched.
//!
//! # Invalidation
//!
//! The per-node algorithm cache is the single source of truth for dirtiness, as
//! in Taffy, with one extra invariant this port maintains explicitly:
//!
//! > if a node's cache is empty then every ancestor's cache is empty
//!
//! `mark_dirty` relies on it to stop early. Internal eviction (`evict_cache`,
//! used when a node is removed or hidden) is only ever reached from paths that
//! also invalidate the ancestors, so it preserves the invariant. The public
//! `cacheClear` invalidates the whole ancestor chain.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style/root.zig");
const layout = @import("layout.zig");
const cache = @import("cache.zig");
const node = @import("node.zig");
const interfaces = @import("interfaces.zig");
const compute = @import("../compute/root.zig");
const print = @import("../util/print.zig");

pub const NodeId = node.NodeId;
pub const node_id = node.node_id;
pub const node_id_from = node.node_id_from;

pub const TreeError = error{
    InvalidParentNode,
    InvalidChildNode,
    InvalidInputNode,
    ChildIndexOutOfBounds,
    /// The requested layout run mode / sizing mode combination is not one the
    /// dispatcher can serve.
    InvalidLayoutMode,
    /// The mutation would make a node its own ancestor.
    Cycle,
    /// The same child id appeared more than once in one child list.
    DuplicateChild,
    /// The 24-bit node index space or a slot's generation counter was exhausted.
    NodeIdExhausted,
    OutOfMemory,
};
pub const Error = TreeError;

pub const TreeConfig = struct {
    use_rounding: bool = true,
    /// Number of node slots to pre-allocate in `with_capacity`.
    initial_capacity: usize = 0,

    pub fn default() TreeConfig {
        return .{};
    }
};
pub fn TreeResult(comptime T: type) type {
    return TreeError!T;
}

pub const NodeData = struct {
    /// Generation counter of the slot currently holding this node. `NodeId`s
    /// carry the generation they were created with; a mismatch means the id is
    /// stale.
    generation: u40 = 0,
    /// Stamp used by child-list validation to detect duplicates in O(n) without
    /// allocating (compared against `Tree.visit_epoch`; never wraps).
    visit_mark: u64 = 0,
    /// Compact storage: grid-only properties live out of line (see
    /// `style.StoredStyle`).
    style: style.StoredStyle,
    unrounded_layout: layout.Layout = .{},
    final_layout: layout.Layout = .{},
    children: std.ArrayList(NodeId),
    parent: ?NodeId = null,
    cache: cache.Cache = .{},
    /// Rarely used per-node data, allocated on first use (see `NodeExtra`).
    extra: ?*NodeExtra = null,
    alive: bool = true,
    /// The cached layout depends on an inherited float context (see
    /// `LayoutTree.cache_float_coupled`).
    cache_float_coupled: bool = false,
    /// Per-node measure context (Taffy's `NodeContext`). `has_context` mirrors
    /// Taffy's flag so a null context can still be a stored context.
    has_context: bool = false,
    context: ?*anyopaque = null,
    /// Free everything the node owns (its slot stays allocated).
    fn deinit(self: *NodeData, allocator: std.mem.Allocator) void {
        self.style.deinit(allocator);
        if (self.extra) |extra| {
            extra.deinit(allocator);
            allocator.destroy(extra);
            self.extra = null;
        }
        self.children.deinit(allocator);
        self.children = .empty;
    }

    fn extraOrCreate(self: *NodeData, allocator: std.mem.Allocator) error{OutOfMemory}!*NodeExtra {
        if (self.extra) |extra| return extra;
        const extra = try allocator.create(NodeExtra);
        extra.* = .{};
        self.extra = extra;
        return extra;
    }

    inline fn oofCandidates(self: *const NodeData) []const layout.OofCandidate {
        return if (self.extra) |extra| extra.cached_oof_candidates else &.{};
    }
    inline fn hoistedChildren(self: *const NodeData) []const NodeId {
        return if (self.extra) |extra| extra.hoisted_children.items else &.{};
    }
    inline fn detailedInfo(self: *const NodeData) layout.DetailedLayoutInfo {
        return if (self.extra) |extra| extra.detailed_layout_info else .none;
    }
};

/// Per-node data most nodes never use, kept out of `NodeData` (about 70 bytes
/// per node): only nodes that cache out-of-flow descendants, contain
/// absolutely positioned boxes, or carry grid layout details allocate one.
pub const NodeExtra = struct {
    /// The out-of-flow candidates of the cached final layout, owned by the
    /// tree. A cache hit must surface them again: they are how absolutely
    /// positioned descendants reach a containing block further up.
    cached_oof_candidates: []layout.OofCandidate = &.{},
    /// Out-of-flow (`absolute`/`fixed`) boxes whose containing block is this
    /// node, as recorded by the out-of-flow positioning pass. Laid out by this
    /// node rather than by their parent, so their `Layout.location` is relative
    /// to this node.
    hoisted_children: std.ArrayListUnmanaged(NodeId) = .empty,
    detailed_layout_info: layout.DetailedLayoutInfo = .none,
    /// Destructor for `detailed_layout_info`, supplied by the algorithm that
    /// produced it (the tree layer cannot know concrete detail types).
    detailed_info_deinit: ?*const fn (*const anyopaque, std.mem.Allocator) void = null,

    fn deinit(self: *NodeExtra, allocator: std.mem.Allocator) void {
        self.freeDetailedInfo(allocator);
        allocator.free(self.cached_oof_candidates);
        self.cached_oof_candidates = &.{};
        self.hoisted_children.deinit(allocator);
    }

    fn freeDetailedInfo(self: *NodeExtra, allocator: std.mem.Allocator) void {
        if (self.detailed_layout_info != .none) {
            if (self.detailed_info_deinit) |deinit_fn| deinit_fn(self.detailed_layout_info.grid, allocator);
            self.detailed_layout_info = .none;
            self.detailed_info_deinit = null;
        }
    }
};

fn freeDetailedInfo(node_data: *NodeData, allocator: std.mem.Allocator) void {
    if (node_data.extra) |extra| extra.freeDetailedInfo(allocator);
}

/// Generational node storage: one contiguous slot array.
///
/// Growth goes through the allocator's `remap` (C `realloc`), which large
/// general-purpose allocators serve by remapping pages instead of copying,
/// exactly like Taffy's `Vec`. One large block also lets glibc's adaptive
/// thresholds keep the memory mapped across tree lifetimes; many medium pages
/// made glibc return the whole heap at every teardown and fault it back in on
/// the next tree (2x slower tree creation than Taffy).
///
/// `NodeData` pointers are therefore invalidated by node creation. Nothing in
/// the tree or the layout algorithms holds one across `new_leaf` (layout never
/// creates nodes, and the measure callback cannot mutate the tree).
///
/// Slots are recycled through a LIFO free list and every reuse bumps the slot's
/// generation, so removed nodes do not accumulate storage forever and stale ids
/// can never resolve to a recycled node.
pub const NodeStore = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayListUnmanaged(NodeData) = .empty,
    /// Number of slots ever allocated; ids index into `0..len`.
    len: u32 = 0,
    /// Free slot indices, most recently released first.
    free: std.ArrayListUnmanaged(u32) = .empty,
    /// Number of slots currently holding a live node.
    live_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) NodeStore {
        return .{ .allocator = allocator };
    }

    /// Reserve room for `count` slots.
    pub fn reserve(self: *NodeStore, count: u32) !void {
        try self.slots.ensureTotalCapacity(self.allocator, count);
    }

    /// Release capacity beyond the allocated slots.
    pub fn trim(self: *NodeStore) void {
        self.slots.shrinkAndFree(self.allocator, self.slots.items.len);
    }

    /// Take a slot for a new node, recycling a free one when available.
    fn acquire(self: *NodeStore) !u32 {
        if (self.free.pop()) |index| return index;
        if (self.len > node.max_index) return error.NodeIdExhausted;
        const index = self.len;
        // Grow by 1.5x: large blocks grow by remapping (no copy), so the
        // smaller factor costs little time and wastes less memory than
        // doubling (Rust's `Vec`).
        if (self.slots.items.len == self.slots.capacity) {
            try self.slots.ensureTotalCapacityPrecise(self.allocator, @max(8, self.slots.capacity + self.slots.capacity / 2));
        }
        // New slot memory is undefined; start it at generation 0 so the first
        // `NodeId` minted for it is well defined.
        self.slots.items.len += 1;
        self.len = index + 1;
        self.at(index).generation = 0;
        return index;
    }

    /// Return a slot to the free list, bumping its generation so ids minted for
    /// the previous occupant stop resolving.
    fn release(self: *NodeStore, index: u32) !void {
        const slot = self.at(index);
        slot.generation +%= 1;
        self.live_count -= 1;
        // A slot whose generation wrapped is retired (never reused). If the
        // free list cannot grow, the slot is simply not recycled.
        if (slot.generation == 0) return;
        self.free.append(self.allocator, index) catch {};
    }

    /// In-place leaf construction: write the new node directly into its slot
    /// instead of building a ~1.2 KB temporary and copying it.
    pub fn appendLeaf(self: *NodeStore, value: style.Style) !NodeId {
        const index = try self.acquire();
        const node_data = self.at(index);
        // Written in place (no 500-byte temporaries); on failure nothing is
        // allocated and the slot goes back to the free list.
        node_data.style.initInPlace(self.allocator, &value) catch |err| {
            // Leave a dead, safely deinit-able slot (a fresh slot's memory is
            // undefined) and offer it for reuse.
            node_data.children = .empty;
            node_data.extra = null;
            node_data.alive = false;
            self.free.append(self.allocator, index) catch {};
            return err;
        };
        // Reset every owned field while preserving the slot's generation counter,
        // which is bumped by `release` when the slot is recycled.
        node_data.unrounded_layout = .{};
        node_data.final_layout = .{};
        node_data.children = .empty;
        node_data.parent = null;
        node_data.cache = .{};
        node_data.cache_float_coupled = false;
        node_data.alive = true;
        node_data.has_context = false;
        node_data.context = null;
        node_data.extra = null;
        node_data.visit_mark = 0;
        self.live_count += 1;
        return node.fromParts(index, node_data.generation) orelse error.NodeIdExhausted;
    }

    /// Mutable access to an allocated slot. The slot must be `< len`.
    pub inline fn at(self: *NodeStore, index: u32) *NodeData {
        return &self.slots.items[index];
    }

    pub inline fn atConst(self: *const NodeStore, index: u32) *const NodeData {
        return &self.slots.items[index];
    }

    pub fn deinit(self: *NodeStore) void {
        self.slots.deinit(self.allocator);
        self.free.deinit(self.allocator);
        self.len = 0;
        self.live_count = 0;
    }
};

const ScratchStack = @import("../util/scratch_stack.zig").ScratchStack;

pub const Tree = struct {
    allocator: std.mem.Allocator,
    nodes: NodeStore,
    use_rounding: bool = true,
    /// Measure callback active for the current compute run. `compute_layout`
    /// uses Taffy's default (zero-size) measure; `compute_layout_with_measure`
    /// installs the caller's callback for the duration of the run.
    measure_function: ?interfaces.MeasureFunc = null,
    /// Host `calc()` resolver; see `set_calc_resolver`.
    calc_resolver: ?CalcResolver = null,
    /// Per-tree stack allocator for layout-pass temporaries (line lists,
    /// placement scratch, track arrays, occupancy intervals, ...). Allocations
    /// made from `scratch_allocator()` are owned by the tree and valid until the
    /// next top-level layout pass (or `reset_scratch`/`clear`), unless the
    /// caching wrapper releases a child layout's temporaries early (see
    /// `scratch_mark`). Chunks are retained across passes.
    scratch: ScratchStack,
    /// Per-tree arena for mutation-time working memory (input snapshots,
    /// validation sets). Reset at the start of each public mutation entry point
    /// and retained between them, so the steady-state cost of validation is zero
    /// allocations. Kept separate from `scratch` so a layout pass cannot
    /// invalidate a snapshot a mutation is still reading.
    mutation_arena: std.heap.ArenaAllocator,
    /// Epoch for `NodeData.visit_mark` (child-list duplicate detection).
    visit_epoch: u64 = 0,
    /// True while a layout pass is active. The scratch arena is reset only
    /// when a pass starts outside every other pass, so re-entrant child
    /// computes (the algorithms call back through `compute_child_layout`)
    /// cannot invalidate temporaries the outer pass is still using.
    in_layout_pass: bool = false,
    /// Re-entrancy guard for the measure callback. Rust's exclusive borrow of
    /// the tree makes mutation-from-measure unrepresentable; Zig does not, so
    /// the tree refuses it explicitly rather than corrupting the active pass.
    in_measure_callback: bool = false,

    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{
            .allocator = allocator,
            .nodes = NodeStore.init(allocator),
            .scratch = ScratchStack.init(allocator),
            .mutation_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn new(allocator: std.mem.Allocator) Tree {
        return init(allocator);
    }

    pub fn init_with_config(allocator: std.mem.Allocator, config: TreeConfig) Tree {
        var result = init(allocator);
        result.use_rounding = config.use_rounding;
        if (config.initial_capacity > 0) result.nodes.reserve(@intCast(config.initial_capacity)) catch @panic("Taffy tree allocation failed");
        return result;
    }

    pub fn new_with_config(allocator: std.mem.Allocator, config: TreeConfig) Tree {
        return init_with_config(allocator, config);
    }

    pub fn with_capacity(allocator: std.mem.Allocator, capacity: usize) Tree {
        return init_with_config(allocator, .{ .initial_capacity = capacity });
    }

    pub fn enable_rounding(self: *Tree) void {
        self.use_rounding = true;
    }
    pub fn disable_rounding(self: *Tree) void {
        self.use_rounding = false;
    }

    pub fn deinit(self: *Tree) void {
        var index: u32 = 0;
        while (index < self.nodes.len) : (index += 1) self.nodes.at(index).deinit(self.allocator);
        self.nodes.deinit();
        self.scratch.deinit();
        self.mutation_arena.deinit();
        self.in_layout_pass = false;
    }

    /// Allocator for layout-pass temporaries. Memory is owned by the tree and
    /// invalidated by the next top-level layout pass, `reset_scratch`, `clear`
    /// or `deinit`. Never store an escaping pointer/reference in it.
    /// The current top of the scratch stack (see `scratch_release`).
    pub fn scratch_mark(self: *Tree) ScratchStack.Mark {
        return self.scratch.mark();
    }

    /// Pop every scratch allocation made since `mark`; nothing allocated
    /// after it may be referenced afterwards.
    pub fn scratch_release(self: *Tree, mark: ScratchStack.Mark) void {
        self.scratch.release(mark);
    }

    pub fn scratch_allocator(self: *Tree) std.mem.Allocator {
        return self.scratch.allocator();
    }

    /// Invalidate every `scratch_allocator()` allocation, retaining the arena's
    /// capacity for the next pass. Called automatically when a top-level
    /// layout pass begins; only needed manually when driving the compute
    /// functions directly without `compute_layout`/`compute_child_layout`.
    pub fn reset_scratch(self: *Tree) void {
        self.scratch.reset();
    }

    /// Number of live nodes, in O(1).
    pub fn total_node_count(self: *const Tree) usize {
        return self.nodes.live_count;
    }

    /// Number of node slots ever allocated, including recycled ones.
    pub fn slot_count(self: *const Tree) usize {
        return self.nodes.len;
    }

    /// Release memory held for removed nodes (their child lists) and spare
    /// slot capacity. Useful after a burst of churn; layout never shrinks.
    pub fn trim(self: *Tree) void {
        var index: u32 = 0;
        while (index < self.nodes.len) : (index += 1) {
            const slot = self.nodes.at(index);
            if (slot.alive) continue;
            slot.children.clearAndFree(self.allocator);
        }
        self.nodes.trim();
    }

    /// Drop all nodes, retaining the allocator-backed capacity. Every live id
    /// stops resolving: each slot's generation is bumped, so a widget that kept
    /// an old id cannot edit or remove an unrelated node created afterwards.
    pub fn clear(self: *Tree) void {
        var index: u32 = 0;
        while (index < self.nodes.len) : (index += 1) {
            const slot = self.nodes.at(index);
            if (!slot.alive) continue;
            slot.deinit(self.allocator);
            slot.alive = false;
            slot.generation +%= 1;
            // On allocation failure the slot is just not recycled.
            self.nodes.free.append(self.allocator, index) catch {};
            self.nodes.live_count -= 1;
        }
        self.reset_scratch();
    }

    pub fn new_leaf(self: *Tree, value: style.Style) !NodeId {
        return try self.nodes.appendLeaf(value);
    }

    /// Create a measured leaf, corresponding to Taffy's
    /// `new_leaf_with_context` API. The context is opaque to the tree and is
    /// passed back to the measure callback installed at compute time.
    pub fn new_leaf_with_context(self: *Tree, value: style.Style, context: ?*anyopaque) !NodeId {
        const id = try self.new_leaf(value);
        const node_data = self.nodes.at(node.indexOf(id));
        node_data.context = context;
        node_data.has_context = context != null;
        return id;
    }

    pub fn new_with_children(self: *Tree, value: style.Style, child_list: []const NodeId) !NodeId {
        const id = try self.new_leaf(value);
        errdefer _ = self.remove(id) catch {};
        try self.set_children(id, child_list);
        return id;
    }

    // ---------------------------------------------------------------------
    // Mutations
    // ---------------------------------------------------------------------

    /// Validate a requested child list without touching the graph.
    fn validateChildList(self: *Tree, parent_id: NodeId, child_list: []const NodeId) ![]const NodeId {
        const parent_node = self.get_node(parent_id) orelse return error.InvalidParentNode;
        if (child_list.len == 0) return child_list;

        // A root parent's only ancestor is itself, so no child (other than the
        // parent itself) can close a cycle: skip the ancestor walks entirely.
        const parent_is_root = parent_node.parent == null;
        // Duplicates are found by stamping each child with a fresh epoch: O(n),
        // no allocation (replaces a per-call hash set).
        self.visit_epoch += 1;
        const epoch = self.visit_epoch;
        for (child_list) |child_id| {
            const child = self.get_node_mut(child_id) orelse return error.InvalidChildNode;
            if (child_id == parent_id) return error.Cycle;
            if (child.visit_mark == epoch) return error.DuplicateChild;
            child.visit_mark = epoch;
            // A childless node cannot be an ancestor of anything but itself.
            if (!parent_is_root and child.children.items.len != 0 and self.isAncestor(child_id, parent_id)) return error.Cycle;
        }
        return child_list;
    }

    /// Whether `candidate` is `node` or one of its ancestors.
    fn isAncestor(self: *Tree, candidate: NodeId, descendant: NodeId) bool {
        var current: ?NodeId = descendant;
        var guard: usize = 0;
        while (current) |current_id| : (guard += 1) {
            if (current_id == candidate) return true;
            if (guard > self.nodes.len) return true; // defensive: cannot happen in an acyclic tree
            const node_data = self.get_node(current_id) orelse return false;
            current = node_data.parent;
        }
        return false;
    }

    /// Snapshot `child_list` when it aliases `parent_node`'s own child array, so
    /// that clearing the destination cannot destroy the input we are about to
    /// read. The returned slice is owned by the mutation arena.
    fn snapshotIfAliased(self: *Tree, parent_node: *NodeData, child_list: []const NodeId) ![]const NodeId {
        const destination = parent_node.children.items;
        if (destination.len == 0 or child_list.len == 0) return child_list;
        const lo = @intFromPtr(destination.ptr);
        const hi = lo + destination.len * @sizeOf(NodeId);
        const clo = @intFromPtr(child_list.ptr);
        const chi = clo + child_list.len * @sizeOf(NodeId);
        if (chi <= lo or clo >= hi) return child_list;
        const allocator = self.mutationArenaAllocator();
        return try allocator.dupe(NodeId, child_list);
    }

    fn mutationArenaAllocator(self: *Tree) std.mem.Allocator {
        return self.mutation_arena.allocator();
    }

    fn beginMutation(self: *Tree) void {
        _ = self.mutation_arena.reset(.retain_capacity);
    }

    pub fn set_children(self: *Tree, parent_id: NodeId, child_list: []const NodeId) !void {
        self.beginMutation();
        // Phase 1: validate everything, including graph rules. A rejected request
        // must leave the tree untouched, not half-detached.
        _ = try self.validateChildList(parent_id, child_list);
        const parent_node = self.get_node_mut(parent_id) orelse return error.InvalidParentNode;
        // Phase 2: the input may alias the destination array.
        const source = try self.snapshotIfAliased(parent_node, child_list);
        // Phase 3: reserve the destination before any edge is torn down, so an
        // allocation failure cannot leave a partially rebuilt child list.
        try parent_node.children.ensureTotalCapacity(self.allocator, source.len);

        // Phase 4: commit.
        for (parent_node.children.items) |old_child| {
            if (self.get_node_mut(old_child)) |old| old.parent = null;
        }
        parent_node.children.clearRetainingCapacity();
        for (source) |child_id| {
            const child = self.get_node_mut(child_id) orelse unreachable; // validated in phase 1
            try self.detach_from_parent(child_id, child.parent, parent_id);
            child.parent = parent_id;
            parent_node.children.appendAssumeCapacity(child_id);
        }
        self.mark_dirty(parent_id);
    }

    pub fn add_child(self: *Tree, parent_id: NodeId, child: NodeId) !void {
        self.beginMutation();
        _ = try self.validateChildList(parent_id, &.{child});
        const parent_node = self.get_node_mut(parent_id) orelse return error.InvalidParentNode;
        const child_node = self.get_node_mut(child) orelse return error.InvalidChildNode;
        // Reserve first so a failure leaves the graph untouched. Re-adding an
        // existing child moves it to the end rather than creating a second edge.
        try parent_node.children.ensureTotalCapacity(self.allocator, parent_node.children.items.len + 1);
        try self.detach_from_parent(child, child_node.parent, parent_id);
        parent_node.children.appendAssumeCapacity(child);
        child_node.parent = parent_id;
        self.mark_dirty(parent_id);
    }

    pub fn insert_child_at_index(self: *Tree, parent_id: NodeId, index: usize, child: NodeId) !void {
        self.beginMutation();
        _ = try self.validateChildList(parent_id, &.{child});
        const parent_node = self.get_node_mut(parent_id) orelse return error.InvalidParentNode;
        const child_node = self.get_node_mut(child) orelse return error.InvalidChildNode;
        // Moving within the same parent shifts the target index down by one when
        // the node currently sits before it.
        var target = index;
        if (child_node.parent == parent_id) {
            var current_index: usize = 0;
            while (current_index < parent_node.children.items.len) : (current_index += 1) {
                if (parent_node.children.items[current_index] == child) break;
            }
            if (current_index < target) target -= 1;
        }
        if (index > parent_node.children.items.len) return error.ChildIndexOutOfBounds;
        try parent_node.children.ensureTotalCapacity(self.allocator, parent_node.children.items.len + 1);
        try self.detach_from_parent(child, child_node.parent, parent_id);
        parent_node.children.insertAssumeCapacity(target, child);
        child_node.parent = parent_id;
        self.mark_dirty(parent_id);
    }

    pub fn remove_child(self: *Tree, parent_id: NodeId, child: NodeId) !NodeId {
        const parent_node = self.get_node_mut(parent_id) orelse return error.InvalidParentNode;
        for (parent_node.children.items, 0..) |child_id, index| {
            if (child_id == child) {
                _ = parent_node.children.orderedRemove(index);
                if (self.get_node_mut(child)) |child_node| child_node.parent = null;
                self.mark_dirty(parent_id);
                return child;
            }
        }
        return error.InvalidChildNode;
    }

    pub fn remove_child_at_index(self: *Tree, parent_id: NodeId, index: usize) !NodeId {
        const child = try self.child_at(parent_id, index);
        return self.remove_child(parent_id, child);
    }

    pub fn remove_children_range(self: *Tree, parent_id: NodeId, start: usize, end: usize) !void {
        if (start > end) return error.ChildIndexOutOfBounds;
        const parent_node = self.get_node_mut(parent_id) orelse return error.InvalidParentNode;
        if (end > parent_node.children.items.len) return error.ChildIndexOutOfBounds;
        var index = end;
        while (index > start) {
            index -= 1;
            const child = parent_node.children.orderedRemove(index);
            if (self.get_node_mut(child)) |child_node| child_node.parent = null;
        }
        self.mark_dirty(parent_id);
    }

    pub fn replace_child_at_index(self: *Tree, parent_id: NodeId, index: usize, child: NodeId) !NodeId {
        self.beginMutation();
        _ = try self.validateChildList(parent_id, &.{child});
        const parent_node = self.get_node_mut(parent_id) orelse return error.InvalidParentNode;
        if (index >= parent_node.children.items.len) return error.ChildIndexOutOfBounds;
        const child_node = self.get_node_mut(child) orelse return error.InvalidChildNode;
        const old_child = parent_node.children.items[index];
        // Replacing a child with itself changes nothing.
        if (old_child == child) return old_child;
        var target = index;
        if (child_node.parent == parent_id) {
            // A sibling moves into the slot: drop its old edge, which shifts the
            // slot down when it sat before it.
            const from = std.mem.indexOfScalar(NodeId, parent_node.children.items, child).?;
            _ = parent_node.children.orderedRemove(from);
            if (from < target) target -= 1;
        } else {
            try self.detach_from_parent(child, child_node.parent, parent_id);
        }
        parent_node.children.items[target] = child;
        child_node.parent = parent_id;
        if (self.get_node_mut(old_child)) |old| old.parent = null;
        self.mark_dirty(parent_id);
        return old_child;
    }

    pub fn child_count(self: *const Tree, parent_id: NodeId) !usize {
        return (self.get_node(parent_id) orelse return error.InvalidParentNode).children.items.len;
    }

    pub fn child_at(self: *const Tree, parent_id: NodeId, index: usize) !NodeId {
        const child_list = (self.get_node(parent_id) orelse return error.InvalidParentNode).children.items;
        if (index >= child_list.len) return error.ChildIndexOutOfBounds;
        return child_list[index];
    }

    pub fn child_at_index(self: *const Tree, parent_id: NodeId, index: usize) !NodeId {
        return self.child_at(parent_id, index);
    }

    pub fn child_ids(self: *const Tree, parent_id: NodeId) ![]const NodeId {
        return self.children(parent_id);
    }

    pub fn get_child_id(self: *const Tree, parent_id: NodeId, index: usize) !NodeId {
        return self.child_at(parent_id, index);
    }

    /// Borrowed child list. The slice points into the tree and is invalidated by
    /// any mutation of this node's children. Use `childrenOwned` when the slice
    /// must outlive the call, or pass it straight back to `setChildren`, which is
    /// alias-safe.
    pub fn children(self: *const Tree, parent_id: NodeId) ![]const NodeId {
        return (self.get_node(parent_id) orelse return error.InvalidParentNode).children.items;
    }

    /// Owned copy of the child list, allocated from `allocator`.
    pub fn childrenOwned(self: *const Tree, parent_id: NodeId, allocator: std.mem.Allocator) ![]NodeId {
        const child_list = try self.children(parent_id);
        return try allocator.dupe(NodeId, child_list);
    }

    pub fn parent(self: *const Tree, child_id: NodeId) !?NodeId {
        return (self.get_node(child_id) orelse return error.InvalidInputNode).parent;
    }

    /// Out-of-flow (`absolute`/`fixed`) boxes whose containing block is `node`,
    /// as recorded by the last layout. Their `Layout.location` is relative to
    /// `node`, not to their parent.
    pub fn hoisted_children(self: *const Tree, id: NodeId) ![]const NodeId {
        return (self.get_node(id) orelse return error.InvalidParentNode).hoistedChildren();
    }

    // ---------------------------------------------------------------------
    // Styles and layouts
    // ---------------------------------------------------------------------

    pub fn style_of(self: *const Tree, id: NodeId) !style.Style {
        return (self.get_node(id) orelse return error.InvalidInputNode).style.toStyle();
    }

    /// One style property of `id`, without materialising the whole `Style`.
    pub fn style_get(self: *const Tree, id: NodeId, comptime field: style.view.Field) !style.view.FieldType(field) {
        return (self.get_node(id) orelse return error.InvalidInputNode).style.get(field);
    }

    pub fn set_style(self: *Tree, id: NodeId, value: style.Style) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        try node_data.style.set(self.allocator, &value);
        self.mark_dirty(id);
    }

    /// Typed, invalidating style edit.
    ///
    /// Prefer this over reading a mutable `Style` through `node()`: the tree
    /// copies the `Style` record but *not* the arrays it references, so editing
    /// a caller-owned track list in place silently changes the effective style
    /// without telling the tree. `editStyle` performs the edit through the tree
    /// and always invalidates the affected cache entries.
    pub fn edit_style(self: *Tree, id: NodeId, comptime edit_fn: fn (*style.Style) void) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        var value = node_data.style.toStyle();
        edit_fn(&value);
        try node_data.style.set(self.allocator, &value);
        self.mark_dirty(id);
    }

    /// The final layout of `id`: the rounded one when rounding is enabled (the
    /// default) and the unrounded one otherwise.
    pub fn layout_of(self: *const Tree, id: NodeId) !layout.Layout {
        const node_data = self.get_node(id) orelse return error.InvalidInputNode;
        return if (self.use_rounding) node_data.final_layout else node_data.unrounded_layout;
    }

    /// Detailed algorithm output recorded by the most recent *complete* layout of
    /// `id` (currently grid track/item information).
    ///
    /// The value is cleared whenever a full layout pass produces something other
    /// than a grid result, so it never describes a stale geometry. It is
    /// preserved (not cleared) by measure-only passes, which do not rewrite the
    /// node's completed layout.
    pub fn detailed_layout_info(self: *const Tree, id: NodeId) !layout.DetailedLayoutInfo {
        return (self.get_node(id) orelse return error.InvalidInputNode).detailedInfo();
    }

    /// Clear any recorded detailed layout information for `id`.
    pub fn clear_detailed_layout_info(self: *Tree, id: NodeId) void {
        if (self.get_node_mut(id)) |node_data| freeDetailedInfo(node_data, self.allocator);
    }

    /// Store algorithm-produced detailed information for a node, freeing any
    /// previous value with the destructor supplied by its producer.
    /// The `LayoutTree` hook name for `set_detailed_grid_info`.
    pub fn set_detailed_layout_info(self: *Tree, id: NodeId, info: *const anyopaque, deinit_fn: *const fn (*const anyopaque, std.mem.Allocator) void) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        const extra = try node_data.extraOrCreate(self.allocator);
        extra.freeDetailedInfo(self.allocator);
        extra.detailed_layout_info = .{ .grid = info };
        extra.detailed_info_deinit = deinit_fn;
    }

    pub fn unrounded_layout(self: *const Tree, id: NodeId) !layout.Layout {
        return (self.get_node(id) orelse return error.InvalidInputNode).unrounded_layout;
    }

    pub fn set_unrounded_layout(self: *Tree, id: NodeId, value: layout.Layout) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        node_data.unrounded_layout = value;
    }

    pub fn set_final_layout(self: *Tree, id: NodeId, value: layout.Layout) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        node_data.final_layout = value;
    }

    // ---------------------------------------------------------------------
    // Cache and invalidation
    // ---------------------------------------------------------------------

    pub fn cache_get(self: *Tree, id: NodeId, input: *const layout.LayoutInput) ?layout.LayoutOutput {
        const node_data = self.get_node_mut(id) orelse return null;
        var output = node_data.cache.get(input.*) orelse return null;
        if (input.run_mode == .perform_layout and node_data.oofCandidates().len != 0) {
            // Hand out a pass-scoped copy: callers translate the list in place.
            var candidates: layout.OofCandidates = .empty;
            candidates.appendSlice(self.scratch_allocator(), node_data.oofCandidates()) catch return null;
            output.oof_candidates = candidates;
        }
        return output;
    }

    pub fn cache_float_coupled(self: *Tree, id: NodeId) bool {
        const node_data = self.get_node(id) orelse return true;
        return node_data.cache_float_coupled;
    }

    pub fn set_cache_float_coupled(self: *Tree, id: NodeId, value: bool) void {
        if (self.get_node_mut(id)) |node_data| node_data.cache_float_coupled = value;
    }

    /// Fails with `OutOfMemory` (failing the layout) when the final layout's
    /// out-of-flow candidates cannot be copied: silently leaving the node
    /// uncached would let its ancestors cache, breaking "an empty cache implies
    /// empty ancestor caches" and so later invalidation.
    pub fn cache_store(self: *Tree, id: NodeId, input: *const layout.LayoutInput, output: layout.LayoutOutput) error{OutOfMemory}!void {
        const node_data = self.get_node_mut(id) orelse return;
        if (input.run_mode == .perform_layout) {
            // Keep the final layout's candidates alongside it, or fail the layout.
            const candidates = output.oof_candidates.items;
            if (candidates.len == 0) {
                if (node_data.extra) |extra| {
                    self.allocator.free(extra.cached_oof_candidates);
                    extra.cached_oof_candidates = &.{};
                }
            } else {
                const extra = node_data.extraOrCreate(self.allocator) catch |err| {
                    _ = node_data.cache.clear();
                    return err;
                };
                const owned = self.allocator.dupe(layout.OofCandidate, candidates) catch |err| {
                    _ = node_data.cache.clear();
                    return err;
                };
                self.allocator.free(extra.cached_oof_candidates);
                extra.cached_oof_candidates = owned;
            }
        }
        node_data.cache.store(input.*, output);
    }

    /// Clear this node's cached layout **and** invalidate every ancestor.
    ///
    /// Use this (or `mark_dirty`) to force recomputation. The internal
    /// `evict_cache` drops only the node's own entries and relies on the
    /// "empty cache implies empty ancestors" invariant; exposing that here would
    /// leave ancestors serving stale layouts.
    pub fn cache_clear(self: *Tree, id: NodeId) void {
        self.mark_dirty(id);
    }

    /// Invalidate every node's cached layout.
    pub fn mark_all_dirty(self: *Tree) void {
        var index: u32 = 0;
        while (index < self.nodes.len) : (index += 1) {
            const node_data = self.nodes.at(index);
            if (node_data.alive) _ = node_data.cache.clear();
        }
    }

    /// Invalidate `id` and every ancestor up to the root.
    pub fn mark_dirty(self: *Tree, id: NodeId) void {
        var current: ?NodeId = id;
        while (current) |current_id| {
            const node_data = self.get_node_mut(current_id) orelse break;
            // Walk all the way up (O(depth)). Stopping at the first empty cache
            // (Taffy) assumes an empty cache implies empty ancestor caches,
            // which hidden subtrees break: hidden layout clears descendants'
            // caches while the `display: none` node itself stays cached, so a
            // node moved into, or restyled within, a hidden subtree kept a
            // stale layout.
            _ = node_data.cache.clear();
            current = node_data.parent;
        }
    }

    /// Taffy reports a node as dirty when its cache is empty; the algorithm
    /// cache is the single source of truth (mutations clear it).
    pub fn is_dirty(self: *const Tree, id: NodeId) !bool {
        return (self.get_node(id) orelse return error.InvalidInputNode).cache.is_empty();
    }

    pub fn dirty(self: *const Tree, id: NodeId) !bool {
        return self.is_dirty(id);
    }

    // ---------------------------------------------------------------------
    // Context
    // ---------------------------------------------------------------------

    pub fn set_node_context(self: *Tree, id: NodeId, context: ?*anyopaque) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        node_data.context = context;
        node_data.has_context = context != null;
        self.mark_dirty(id);
    }

    pub fn get_node_context(self: *const Tree, id: NodeId) ?*anyopaque {
        const node_data = self.get_node(id) orelse return null;
        return if (node_data.has_context) node_data.context else null;
    }

    /// Mutable context pointer.
    ///
    /// Editing the context through this pointer does **not** invalidate layout.
    /// Content the measure callback derives from the context must be reported via
    /// `set_node_context`, `edit_node_context` or `mark_dirty`.
    pub fn get_node_context_mut(self: *Tree, id: NodeId) ?*anyopaque {
        const node_data = self.get_node_mut(id) orelse return null;
        return if (node_data.has_context) node_data.context else null;
    }

    /// The contexts of `N` distinct nodes at once (Taffy's
    /// `get_disjoint_node_context_mut`). Null if any id is invalid, carries no
    /// context, or appears twice.
    pub fn get_disjoint_node_context_mut(self: *Tree, comptime N: usize, ids: [N]NodeId) ?[N]*anyopaque {
        var result: [N]*anyopaque = undefined;
        for (ids, 0..) |id, i| {
            for (ids[0..i]) |earlier| if (earlier == id) return null;
            result[i] = self.get_node_context_mut(id) orelse return null;
        }
        return result;
    }

    /// Typed, invalidating context edit. See `get_node_context_mut`.
    pub fn edit_node_context(self: *Tree, id: NodeId, comptime edit_fn: fn (*anyopaque) void) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        if (!node_data.has_context) return error.InvalidInputNode;
        if (node_data.context) |context| edit_fn(context);
        self.mark_dirty(id);
    }

    // ---------------------------------------------------------------------
    // Layout
    // ---------------------------------------------------------------------

    pub fn get_debug_label(self: *const Tree, id: NodeId) []const u8 {
        _ = self;
        _ = id;
        return "node";
    }

    pub fn get_core_container_style(self: *const Tree, id: NodeId) !style.Style {
        return self.style_of(id);
    }
    pub fn get_block_container_style(self: *const Tree, id: NodeId) !style.Style {
        return self.style_of(id);
    }
    pub fn get_block_child_style(self: *const Tree, id: NodeId) !style.Style {
        return self.style_of(id);
    }
    pub fn get_flexbox_container_style(self: *const Tree, id: NodeId) !style.Style {
        return self.style_of(id);
    }
    pub fn get_flexbox_child_style(self: *const Tree, id: NodeId) !style.Style {
        return self.style_of(id);
    }
    pub fn get_grid_container_style(self: *const Tree, id: NodeId) !style.Style {
        return self.style_of(id);
    }
    pub fn get_grid_child_style(self: *const Tree, id: NodeId) !style.Style {
        return self.style_of(id);
    }

    /// A host `calc()` resolver: `func(ctx, handle, basis)` returns the value of
    /// the calc expression `handle` (the pointer given to `Dimension.calc` and
    /// friends) against `basis`, the size percentages resolve against.
    pub const CalcResolver = struct {
        ctx: ?*anyopaque = null,
        func: *const fn (ctx: ?*anyopaque, handle: *const anyopaque, basis: f32) f32,
    };

    /// Install (or with `null`, remove) the resolver for `calc()` values.
    pub fn set_calc_resolver(self: *Tree, resolver: ?CalcResolver) void {
        self.calc_resolver = resolver;
        // Calc results feed every cache entry; recompute everything.
        self.mark_all_dirty();
    }

    /// Resolve a `calc()` value: the host resolver when set, otherwise zero
    /// (Taffy's default tree behaviour).
    pub fn resolve_calc_value(self: *const Tree, value: ?*const anyopaque, basis: f32) f32 {
        const handle = value orelse return 0;
        const r = self.calc_resolver orelse return 0;
        return r.func(r.ctx, handle, basis);
    }

    /// The `LayoutTree` hook: resolve a `calc()` length against `basis`.
    pub fn calc(self: *const Tree, value: ?*const anyopaque, basis: f32) ?f32 {
        return self.resolve_calc_value(value, basis);
    }

    /// The `LayoutTree` hook: a pointer to `id`'s style, valid for the pass.
    ///
    /// Non-optional: the algorithms only ask about ids they walked to.
    /// The algorithms read it through `style.view.View(style.StoredStyle)`.
    pub fn get_style(self: *const Tree, id: NodeId) *const style.StoredStyle {
        const node_data = self.get_node(id) orelse @panic("get_style: invalid or stale NodeId");
        return &node_data.style;
    }

    /// Drop the recorded out-of-flow child list. Called once per `perform_layout`
    /// pass before the node re-records it, so a previous run's list cannot
    /// persist.
    pub fn clear_hoisted_children(self: *Tree, id: NodeId) !void {
        if (self.get_node_mut(id)) |node_data| {
            if (node_data.extra) |extra| extra.hoisted_children.clearRetainingCapacity();
        }
    }

    /// Append to the recorded out-of-flow child list, in document order.
    pub fn add_hoisted_children(self: *Tree, id: NodeId, hoisted: []const NodeId) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        if (hoisted.len == 0) return;
        const extra = try node_data.extraOrCreate(self.allocator);
        try extra.hoisted_children.appendSlice(self.allocator, hoisted);
    }

    /// Whether `id` is an out-of-flow (`absolute`/`fixed`) box generating content.
    pub fn is_out_of_flow(self: *const Tree, id: NodeId) bool {
        const node_data = self.get_node(id) orelse return false;
        return node_data.style.get(.position).is_out_of_flow() and node_data.style.get(.display) != .none;
    }

    pub fn hoisted_child_count(self: *const Tree, id: NodeId) !usize {
        return (self.get_node(id) orelse return error.InvalidParentNode).hoistedChildren().len;
    }

    pub fn get_hoisted_child_id(self: *const Tree, id: NodeId, index: usize) !NodeId {
        return (self.get_node(id) orelse return error.InvalidParentNode).hoistedChildren()[index];
    }

    /// Read back the detailed layout information recorded for `id`, if any.
    pub fn get_detailed_layout_info(self: *const Tree, id: NodeId) ?*const anyopaque {
        const node_data = self.get_node(id) orelse return null;
        return switch (node_data.detailedInfo()) {
            .grid => |info| info,
            .none => null,
        };
    }

    /// Reset the scratch arena, but only for a pass that is not nested inside
    /// another one. Child computes re-enter `compute_child_layout` while a pass
    /// is active and must keep the enclosing pass's allocations alive.
    pub fn begin_layout_pass(self: *Tree) void {
        if (self.in_layout_pass) return;
        self.reset_scratch();
        self.in_layout_pass = true;
    }

    pub fn end_layout_pass(self: *Tree) void {
        if (!self.in_layout_pass) return;
        self.in_layout_pass = false;
    }

    /// Lay out a childless node, invoking the installed measure callback if the
    /// caller supplied one via `compute_layout_with_measure`.
    pub fn compute_leaf_layout(self: *Tree, id: NodeId, input: layout.LayoutInput) !layout.LayoutOutput {
        const node_data = self.get_node(id) orelse return error.InvalidInputNode;
        const measure = self.measure_function;
        // Rust's exclusive borrow of the tree makes mutation-from-measure
        // unrepresentable; Zig does not, so refuse it rather than corrupt the
        // pass in progress.
        if (measure != null) {
            if (self.in_measure_callback) return error.InvalidInputNode;
            self.in_measure_callback = true;
            defer self.in_measure_callback = false;
        }
        const context = if (node_data.has_context) node_data.context else null;
        // `MeasureFunc` receives a full `Style`: materialise one for measured
        // leaves only.
        if (measure != null) {
            const full = node_data.style.toStyle();
            return compute.leaf_layout_with_measure(id, input, &full, context, measure);
        }
        return compute.leaf_layout_with_measure(id, input, &node_data.style, context, null);
    }

    pub fn compute_child_layout(self: *Tree, id: NodeId, input: layout.LayoutInput) !layout.LayoutOutput {
        return compute.compute_cached_layout(Tree, self, id, input);
    }

    pub fn compute_layout(self: *Tree, id: NodeId, available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace)) !void {
        try self.compute_layout_impl(id, available_space);
    }

    pub fn compute_layout_with_measure(self: *Tree, id: NodeId, available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace), measure_function: interfaces.MeasureFunc) !void {
        const previous = self.measure_function;
        const previous_measure_guard = self.in_measure_callback;
        self.measure_function = measure_function;
        defer self.measure_function = previous;
        defer self.in_measure_callback = previous_measure_guard;
        try self.compute_layout_impl(id, available_space);
    }

    fn compute_layout_impl(self: *Tree, id: NodeId, available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace)) !void {
        _ = try compute.compute_root_layout(Tree, self, id, available_space);
        if (self.use_rounding) try compute.round_layout(Tree, self, id);
    }

    /// Taffy `LayoutPartialTreeExt::measure_child_size`: compute a child's size
    /// on one axis with `RunMode.compute_size`.
    pub fn measure_child_size(
        self: *Tree,
        child_id: NodeId,
        known_dimensions: geometry.Size(?f32),
        parent_size: geometry.Size(?f32),
        available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace),
        sizing_mode: layout.SizingMode,
        axis: geometry.AbsoluteAxis,
        vertical_margins_are_collapsible: geometry.Line(bool),
    ) !f32 {
        const output = try self.compute_child_layout(child_id, .{
            .known_dimensions = known_dimensions,
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = available_space,
            .sizing_mode = sizing_mode,
            .axis = if (axis == .horizontal) .horizontal else .vertical,
            .run_mode = .compute_size,
            .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
        });
        return output.size.get_abs(axis);
    }

    /// Taffy `LayoutPartialTreeExt::measure_child_size_both`.
    pub fn measure_child_size_both(
        self: *Tree,
        child_id: NodeId,
        known_dimensions: geometry.Size(?f32),
        parent_size: geometry.Size(?f32),
        available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace),
        sizing_mode: layout.SizingMode,
        vertical_margins_are_collapsible: geometry.Line(bool),
    ) !geometry.Size(f32) {
        const output = try self.compute_child_layout(child_id, .{
            .known_dimensions = known_dimensions,
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = available_space,
            .sizing_mode = sizing_mode,
            .axis = .both,
            .run_mode = .compute_size,
            .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
        });
        return output.size;
    }

    /// Taffy `LayoutPartialTreeExt::perform_child_layout`.
    pub fn perform_child_layout(
        self: *Tree,
        child_id: NodeId,
        known_dimensions: geometry.Size(?f32),
        parent_size: geometry.Size(?f32),
        available_space: geometry.Size(@import("../style/available_space.zig").AvailableSpace),
        sizing_mode: layout.SizingMode,
        vertical_margins_are_collapsible: geometry.Line(bool),
    ) !layout.LayoutOutput {
        return self.compute_child_layout(child_id, .{
            .known_dimensions = known_dimensions,
            .known_dimensions_are_definite = .{ .width = true, .height = true },
            .parent_size = parent_size,
            .available_space = available_space,
            .sizing_mode = sizing_mode,
            .axis = .both,
            .run_mode = .perform_layout,
            .vertical_margins_are_collapsible = vertical_margins_are_collapsible,
        });
    }

    /// Detach `id` from its parent and recycle its slot.
    ///
    /// The node's own descendants stay alive and become roots. The slot (and its
    /// generation) is recycled, so ids handed out afterwards never collide with
    /// `id`, and the slot's child-list capacity is released rather than retained.
    pub fn remove(self: *Tree, id: NodeId) !NodeId {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        const old_parent = node_data.parent;
        if (old_parent) |parent_id| {
            if (self.get_node_mut(parent_id)) |parent_node| {
                var index: usize = 0;
                while (index < parent_node.children.items.len) : (index += 1) {
                    if (parent_node.children.items[index] == id) {
                        _ = parent_node.children.orderedRemove(index);
                        break;
                    }
                }
                self.mark_dirty(parent_id);
            }
        }
        for (node_data.children.items) |child_id| {
            if (self.get_node_mut(child_id)) |child| child.parent = null;
        }
        node_data.parent = null;
        // Children, style, cached out-of-flow candidates, hoisted children and
        // detailed info (the candidates used to leak here).
        node_data.deinit(self.allocator);
        node_data.alive = false;
        _ = node_data.cache.clear();
        try self.nodes.release(node.indexOf(id));
        return id;
    }

    /// Remove the live node with the highest slot index. Node ids themselves are
    /// intentionally not reused; the slot is recycled with a new generation.
    pub fn remove_last_node(self: *Tree) !NodeId {
        var index = self.nodes.len;
        while (index > 0) {
            index -= 1;
            const slot = self.nodes.atConst(index);
            if (!slot.alive) continue;
            const id = node.fromParts(index, slot.generation) orelse continue;
            return self.remove(id);
        }
        return error.InvalidInputNode;
    }

    /// Depth-first debug dump. Delegates to the single writer-based traversal in
    /// `util/print.zig` so there is one implementation of the format.
    pub fn print_tree(self: *const Tree, root: NodeId) void {
        print.print_tree(self, root);
    }

    // ---------------------------------------------------------------------
    // Raw node access
    // ---------------------------------------------------------------------

    /// Advanced mutable access to a node's raw storage.
    ///
    /// This is the escape hatch the layout algorithms use: it exposes style,
    /// cache, graph and layout fields *without* invalidation, so edits made
    /// through it can leave ancestors serving stale layouts. Application code
    /// should use `style_of`/`style_get` for reading, `set_style`/`edit_style`
    /// for style changes, and the dedicated mutation methods for the graph.
    pub fn raw_node(self: *Tree, id: NodeId) ?*NodeData {
        return self.get_node_mut(id);
    }

    /// Immutable node access used by the grid-estimation and diagnostic
    /// stages. Taffy exposes this through `Tree`/`PrintTree` trait methods;
    /// Zig keeps the const boundary explicit instead of returning a mutable
    /// pointer from a const tree.
    pub fn raw_node_const(self: *const Tree, id: NodeId) ?*const NodeData {
        return self.get_node(id);
    }

    /// Remove `child_id`'s edge from `old_parent`, including when the old parent
    /// is the new one (a move within the same parent re-inserts it).
    fn detach_from_parent(self: *Tree, child_id: NodeId, old_parent: ?NodeId, new_parent: NodeId) !void {
        _ = new_parent;
        const old_parent_id = old_parent orelse return;
        const old_parent_node = self.get_node_mut(old_parent_id) orelse return error.InvalidParentNode;
        var index: usize = 0;
        while (index < old_parent_node.children.items.len) : (index += 1) {
            if (old_parent_node.children.items[index] == child_id) {
                _ = old_parent_node.children.orderedRemove(index);
                self.mark_dirty(old_parent_id);
                return;
            }
        }
    }

    /// Resolve a `NodeId` to its slot, rejecting stale and out-of-range ids.
    fn get_node(self: *const Tree, id: NodeId) ?*const NodeData {
        const index = node.indexOf(id);
        if (index >= self.nodes.len) return null;
        const node_data = self.nodes.atConst(index);
        if (!node_data.alive) return null;
        if (node_data.generation != node.generationOf(id)) return null;
        return node_data;
    }

    fn get_node_mut(self: *Tree, id: NodeId) ?*NodeData {
        const index = node.indexOf(id);
        if (index >= self.nodes.len) return null;
        const node_data = self.nodes.at(index);
        if (!node_data.alive) return null;
        if (node_data.generation != node.generationOf(id)) return null;
        return node_data;
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "taffy tree creates children and propagates dirty state" {
    const testing = std.testing;
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.new_leaf(.{});
    const root = try tree.new_with_children(.{}, &[_]NodeId{child});
    try testing.expectEqual(@as(usize, 1), try tree.child_count(root));
    try testing.expectEqual(child, try tree.child_at(root, 0));
    try tree.set_style(child, .{ .flex_grow = 1 });
    try testing.expect(try tree.is_dirty(root));
}

test "taffy tree reparents children across mutation APIs" {
    const testing = std.testing;
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.new_leaf(.{});
    const first_parent = try tree.new_leaf(.{});
    const second_parent = try tree.new_leaf(.{});
    try tree.add_child(first_parent, child);
    try testing.expectEqual(@as(usize, 1), try tree.child_count(first_parent));
    try tree.insert_child_at_index(second_parent, 0, child);
    try testing.expectEqual(@as(usize, 0), try tree.child_count(first_parent));
    try testing.expectEqual(second_parent, (try tree.parent(child)).?);
    _ = try tree.remove_child(second_parent, child);
    try testing.expect((try tree.parent(child)) == null);
}

test "taffy set_children reparent refreshes both parents" {
    // A[X 10x10], B[] under a block root. Moving X to B via set_children
    // must invalidate A's cached layout too — otherwise A keeps its stale
    // 10px height after recompute.
    const testing = std.testing;
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    const x = try tree.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const a = try tree.new_with_children(.{ .display = .block }, &[_]NodeId{x});
    const b = try tree.new_with_children(.{ .display = .block }, &[_]NodeId{});
    const root = try tree.new_with_children(.{ .display = .block }, &[_]NodeId{ a, b });
    try tree.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 10), (try tree.layout_of(a)).size.height);

    try tree.set_children(b, &[_]NodeId{x});
    try testing.expect(try tree.is_dirty(a));
    try tree.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 0), (try tree.layout_of(a)).size.height);
    try testing.expectEqual(@as(f32, 10), (try tree.layout_of(b)).size.height);
    try testing.expectEqual(b, (try tree.parent(x)).?);
}

test "taffy set_children validates before mutating" {
    // A rejected child ID must leave the tree untouched — no partial
    // detach/attach. A[X]; set_children(B, [X, BAD]) errors and A still
    // owns X, B stays empty.
    const testing = std.testing;
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    const x = try tree.new_leaf(.{});
    const a = try tree.new_with_children(.{}, &[_]NodeId{x});
    const b = try tree.new_with_children(.{}, &[_]NodeId{});
    try testing.expectError(error.InvalidChildNode, tree.set_children(b, &[_]NodeId{ x, 9999 }));
    try testing.expectEqual(@as(usize, 1), try tree.child_count(a));
    try testing.expectEqual(@as(usize, 0), try tree.child_count(b));
    try testing.expectEqual(a, (try tree.parent(x)).?);
}

test "child-list validation rejects duplicates and cycles without mutating" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.new_leaf(.{});
    const b = try t.new_leaf(.{});
    const c = try t.new_leaf(.{});

    // Duplicates in one list, for a root parent and a non-root parent.
    const root = try t.new_leaf(.{});
    try testing.expectError(error.DuplicateChild, t.set_children(root, &.{ a, b, a }));
    try testing.expectEqual(@as(usize, 0), (try t.children(root)).len);
    try t.set_children(root, &.{ a, b });
    try testing.expectError(error.DuplicateChild, t.set_children(a, &.{ c, c }));

    // A child may not be its own parent or an ancestor of its new parent.
    try testing.expectError(error.Cycle, t.add_child(a, a));
    try t.add_child(a, c); // root -> a -> c
    try testing.expectError(error.Cycle, t.add_child(c, root));
    try testing.expectError(error.Cycle, t.add_child(c, a));
    try testing.expectError(error.Cycle, t.set_children(c, &.{ b, root }));
    try testing.expectEqual(@as(usize, 2), (try t.children(root)).len);

    // Repeated validations reuse the stamps correctly.
    for (0..3) |_| try t.set_children(root, &.{ b, a });
    try testing.expectEqual(b, (try t.children(root))[0]);
}

test "calc() values resolve through the tree's calc resolver in flex, grid and block" {
    const testing = std.testing;
    const Dimension = style.dimension.Dimension;
    const LengthPercentage = style.dimension.LengthPercentage;
    // An expression handle: `calc(<percent>% + <px>px)`.
    const Expr = struct { percent: f32, px: f32 };
    const Resolve = struct {
        fn f(_: ?*anyopaque, handle: *const anyopaque, basis: f32) f32 {
            const expr: *const Expr = @ptrCast(@alignCast(handle));
            return basis * expr.percent / 100 + expr.px;
        }
    };
    const half_plus_ten: Expr = .{ .percent = 50, .px = 10 };
    const ten: Expr = .{ .percent = 0, .px = 10 };

    inline for (.{ style.Display.flex, style.Display.grid, style.Display.block }) |display| {
        var tree = Tree.init(testing.allocator);
        defer tree.deinit();
        const child = try tree.new_leaf(.{
            .size = .{ .width = Dimension.calc(&half_plus_ten), .height = Dimension.length(20) },
            .margin = .{ .left = style.dimension.LengthPercentageAuto.calc(&ten), .right = .zero(), .top = .zero(), .bottom = .zero() },
        });
        // The container's calc padding resolves against the outer root's width.
        const container = try tree.new_with_children(.{
            .display = display,
            .size = .{ .width = Dimension.length(200), .height = Dimension.length(100) },
            .padding = .{ .left = LengthPercentage.calc(&ten), .right = .zero(), .top = .zero(), .bottom = .zero() },
        }, &[_]NodeId{child});
        const root = try tree.new_with_children(.{
            .display = .block,
            .size = .{ .width = Dimension.length(400), .height = Dimension.length(400) },
        }, &[_]NodeId{container});

        // Without a resolver, calc resolves to zero (Taffy's default tree).
        try tree.compute_layout(root, .{ .width = .max_content, .height = .max_content });
        try testing.expectEqual(@as(f32, 0), (try tree.layout_of(child)).size.width);

        tree.set_calc_resolver(.{ .func = Resolve.f });
        try tree.compute_layout(root, .{ .width = .max_content, .height = .max_content });
        const l = try tree.layout_of(child);
        // Child width: 50% of the container's 190px content box + 10px.
        try testing.expectEqual(@as(f32, 105), l.size.width);
        // Padding 10 + margin 10.
        try testing.expectEqual(@as(f32, 20), l.location.x);
        // The resolver is scoped to the layout call.
        try testing.expect(@import("../style/calc.zig").current == null);
    }
}

test "an item whose only calc() value is its padding still resolves it (calc-specialised paths)" {
    const testing = std.testing;
    const Dimension = style.dimension.Dimension;
    const LengthPercentage = style.dimension.LengthPercentage;
    const Expr = struct { px: f32 };
    const Resolve = struct {
        fn f(_: ?*anyopaque, handle: *const anyopaque, _: f32) f32 {
            const expr: *const Expr = @ptrCast(@alignCast(handle));
            return expr.px;
        }
    };
    const seven: Expr = .{ .px = 7 };
    inline for (.{ style.Display.flex, style.Display.grid, style.Display.block }) |display| {
        var tree = Tree.init(testing.allocator);
        defer tree.deinit();
        tree.set_calc_resolver(.{ .func = Resolve.f });
        const child = try tree.new_leaf(.{
            .size = .{ .width = Dimension.length(20), .height = Dimension.length(20) },
            .padding = .{ .left = LengthPercentage.calc(&seven), .right = .zero(), .top = .zero(), .bottom = .zero() },
        });
        const container = try tree.new_with_children(.{
            .display = display,
            .size = .{ .width = Dimension.length(200), .height = Dimension.length(100) },
        }, &[_]NodeId{child});
        try tree.compute_layout(container, .{ .width = .max_content, .height = .max_content });
        const l = try tree.layout_of(child);
        try testing.expectEqual(@as(f32, 7), l.padding.left);
    }
}

test "trim keeps live nodes; remove frees everything a node owns" {
    const testing = std.testing;
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    const columns = [_]style.grid.GridTemplateComponent{ .{ .single = .auto }, .{ .single = .auto } };
    // A grid style (stored out of line) and an absolutely positioned child (so
    // the container caches out-of-flow candidates).
    const abs = try tree.new_leaf(.{ .position = .absolute, .size = .{ .width = .length(5), .height = .length(5) } });
    const a = try tree.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) }, .grid_row = .{ .start = .{ .line = 1 }, .end = .auto } });
    const inner = try tree.new_with_children(.{ .display = .grid, .grid_template_columns = &columns }, &[_]NodeId{ a, abs });
    const root = try tree.new_with_children(.{ .display = .block }, &[_]NodeId{inner});
    try tree.compute_layout(root, .{ .width = .max_content, .height = .max_content });

    // Removing nodes that own out-of-line data must not leak (testing allocator).
    _ = try tree.remove(abs);
    _ = try tree.remove(a);
    tree.trim();
    // Live nodes survive trim.
    try testing.expectEqual(style.Display.grid, try tree.style_get(inner, .display));
    try testing.expectEqual(@as(usize, 2), (try tree.style_of(inner)).grid_template_columns.len);
    try tree.compute_layout(root, .{ .width = .max_content, .height = .max_content });
    // Recycled slots start clean.
    const b = try tree.new_leaf(.{});
    try testing.expectEqual(@as(usize, 0), (try tree.style_of(b)).grid_template_columns.len);
}

test "get_disjoint_node_context_mut" {
    const testing = std.testing;
    var tree = Tree.init(testing.allocator);
    defer tree.deinit();
    var x: u32 = 1;
    var y: u32 = 2;
    const a = try tree.new_leaf_with_context(.{}, &x);
    const b = try tree.new_leaf_with_context(.{}, &y);
    const c = try tree.new_leaf(.{});
    const both = tree.get_disjoint_node_context_mut(2, .{ a, b }).?;
    try testing.expectEqual(@as(*anyopaque, &x), both[0]);
    try testing.expectEqual(@as(*anyopaque, &y), both[1]);
    try testing.expect(tree.get_disjoint_node_context_mut(2, .{ a, a }) == null);
    try testing.expect(tree.get_disjoint_node_context_mut(2, .{ a, c }) == null);
}

// Regression tests from the 0.4.0 review.
test "review: add_child twice duplicates edge" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const p = try t.new_leaf(.{});
    const c = try t.new_leaf(.{});
    try t.add_child(p, c);
    try t.add_child(p, c);
    try testing.expectEqual(@as(usize, 1), try t.child_count(p));
}

test "review: insert_child_at_index same parent duplicates edge" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.new_leaf(.{});
    const b = try t.new_leaf(.{});
    const p = try t.new_with_children(.{}, &.{ a, b });
    try t.insert_child_at_index(p, 0, b);
    try testing.expectEqual(@as(usize, 2), try t.child_count(p));
}

test "review: replace_child_at_index with itself orphans it" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.new_leaf(.{});
    const p = try t.new_with_children(.{}, &.{a});
    _ = try t.replace_child_at_index(p, 0, a);
    try testing.expectEqual(p, (try t.parent(a)).?);
}

test "review: replace_child_at_index with sibling duplicates" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.new_leaf(.{});
    const b = try t.new_leaf(.{});
    const p = try t.new_with_children(.{}, &.{ a, b });
    _ = try t.replace_child_at_index(p, 0, b);
    try testing.expectEqual(@as(usize, 1), try t.child_count(p));
}

test "review: clear then deinit" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.new_leaf(.{});
    _ = try t.new_with_children(.{}, &.{a});
    t.clear();
}

test "review: clear then trim" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.new_leaf(.{});
    _ = try t.new_with_children(.{}, &.{a});
    t.clear();
    t.trim();
}

test "review: remove leaks cached oof candidates on slot reuse" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const abs = try t.new_leaf(.{  .size = .{ .width = .length(10), .height = .length(10) } });
    const mid = try t.new_with_children(.{ .display = .flex }, &.{abs});
    const root = try t.new_with_children(.{ .display = .flex, .position = .relative }, &.{mid});
    try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    _ = try t.remove(mid);
    _ = try t.new_leaf(.{});
}
test "review: negative percent padding basis trips ScrollableOverflow assert" {
    const testing = std.testing;
    const LP = style.dimension.LengthPercentage;
    const LPA = style.dimension.LengthPercentageAuto;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const leaf_id = try t.new_leaf(.{ .padding = .{ .left = LP.percent(0.5), .right = .zero(), .top = .zero(), .bottom = .zero() } });
    const flex = try t.new_with_children(.{ .display = .flex, .flex_direction = .column, .margin = .{ .left = LPA.length(30), .right = .zero(), .top = .zero(), .bottom = .zero() }, .padding = .{ .left = LP.length(4), .right = .zero(), .top = .zero(), .bottom = .zero() } }, &.{leaf_id});
    const root = try t.new_with_children(.{ .display = .block, .size = .{ .width = .length(10), .height = .length(10) } }, &.{flex});
    try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
}
test "review: second compute_layout with no changes alters layout" {
    const testing = std.testing;
    const LP = style.dimension.LengthPercentage;
    const LPA = style.dimension.LengthPercentageAuto;
    const Dim = style.dimension.Dimension;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const item = try t.new_leaf(.{
        .display = .block,
        .size = .{ .width = Dim.percent(0.98), .height = Dim.length(52) },
        
    });
    const flex = try t.new_with_children(.{
        .display = .flex,
        .flex_direction = .column,
        .float = .right,
        .size = .{ .width = Dim.percent(0.45), .height = Dim.percent(0.23) },
        
        .padding = .{ .left = .zero(), .right = LP.length(11), .top = .zero(), .bottom = .zero() },
    }, &.{item});
    const abs = try t.new_with_children(.{
        .display = .block,
        .position = .absolute,
        .margin = .{ .left = LPA.length(0), .right = LPA.length(2), .top = LPA.percent(0.29), .bottom = LPA.percent(0.28) },
        
        
    }, &.{flex});
    const root = try t.new_with_children(.{
        .display = .block,
        
    }, &.{abs});
    const avail: geometry.Size(@import("../style/available_space.zig").AvailableSpace) = .{ .width = .{ .definite = 300 }, .height = .{ .definite = 300 } };
    try t.compute_layout(root, avail);
    const first = try t.layout_of(item);
    try t.compute_layout(root, avail);
    const second = try t.layout_of(item);
    t.mark_all_dirty();
    try t.compute_layout(root, avail);
    const third = try t.layout_of(item);
    try testing.expectEqual(first.size.height, second.size.height);
    try testing.expectEqual(third.size.height, second.size.height);
}
test "review: node moved into a display:none subtree keeps its stale visible layout" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const x = try t.new_leaf(.{ .size = .{ .width = .length(10), .height = .length(10) } });
    const a = try t.new_leaf(.{ .display = .block });
    const h = try t.new_with_children(.{ .display = .none }, &.{a});
    const root = try t.new_with_children(.{ .display = .block }, &.{ h, x });
    try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 10), (try t.layout_of(x)).size.width);
    try t.add_child(a, x); // x is now inside the hidden subtree
    try t.compute_layout(root, .{ .width = .{ .definite = 100 }, .height = .{ .definite = 100 } });
    try testing.expectEqual(@as(f32, 0), (try t.layout_of(x)).size.width);
}
test "review: print_tree panics on a non-last child that has children" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const g = try t.new_leaf(.{});
    const a = try t.new_with_children(.{}, &.{g});
    const b = try t.new_leaf(.{});
    const mid = try t.new_with_children(.{}, &.{ a, b });
    const root = try t.new_with_children(.{}, &.{mid});
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try @import("../util/print.zig").write_tree(&writer, &t, root);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "│   ") != null);
}

// ---- Upstream Taffy issue regressions (triage batch B) ----

const upstream_avail = struct {
    const AS = @import("../style/available_space.zig").AvailableSpace;
    fn definite(w: f32, h: f32) geometry.Size(AS) {
        return .{ .width = .{ .definite = w }, .height = .{ .definite = h } };
    }
    const max_content: geometry.Size(AS) = .{ .width = .max_content, .height = .max_content };
};

test "taffy#954: a grid scroll container's scrollable overflow includes its (empty) tracks" {
    const testing = std.testing;
    const grid = style.grid;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const child = try t.new_leaf(.{ .size = .{ .width = .length(50), .height = .length(50) } });
    const cols = try grid.GridTemplateComponents.from_str(testing.allocator, "300px");
    defer cols.deinit(testing.allocator);
    const rows = try grid.GridTemplateComponents.from_str(testing.allocator, "500px");
    defer rows.deinit(testing.allocator);
    const P = style.dimension.LengthPercentage.length(10);
    var s: style.Style = .{
        .display = .grid,
        .size = .{ .width = .length(100), .height = .length(100) },
        .padding = .{ .left = P, .right = P, .top = P, .bottom = P },
        .grid_template_rows = rows.tracks,
        .grid_template_columns = cols.tracks,
        .overflow = .{ .x = .scroll, .y = .scroll },
    };
    const g = try t.new_with_children(s, &.{child});
    // padding 10 + track + padding 10, minus the 100px client box
    try t.compute_layout(g, upstream_avail.max_content);
    try testing.expectEqual(@as(f32, 220), (try t.layout_of(g)).scroll_width());
    try testing.expectEqual(@as(f32, 420), (try t.layout_of(g)).scroll_height());
    s.direction = .rtl;
    try t.set_style(g, s);
    try t.compute_layout(g, upstream_avail.max_content);
    try testing.expectEqual(@as(f32, 220), (try t.layout_of(g)).scroll_width());
    try testing.expectEqual(@as(f32, 420), (try t.layout_of(g)).scroll_height());
}

test "taffy#884: a max-width-clamped grid under a max-content constraint sizes its columns to the clamped width" {
    const testing = std.testing;
    const T = @import("../test.zig");
    // ten 4-character words: max-content 400px, wraps to two lines at 200px
    const text = "HHHH\xE2\x80\x8BHHHH\xE2\x80\x8BHHHH\xE2\x80\x8BHHHH\xE2\x80\x8BHHHH\xE2\x80\x8BHHHH\xE2\x80\x8BHHHH\xE2\x80\x8BHHHH\xE2\x80\x8BHHHH\xE2\x80\x8BHHHH";
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var c1 = T.TestNodeContext.ahem_text(text, .horizontal);
    var c2 = T.TestNodeContext.ahem_text(text, .horizontal);
    const a = try t.new_leaf_with_context(.{}, &c1);
    const b = try t.new_leaf_with_context(.{}, &c2);
    const rows = try style.grid.GridTemplateComponents.from_str(testing.allocator, "1fr");
    defer rows.deinit(testing.allocator);
    const root = try t.new_with_children(.{ .display = .grid, .grid_template_rows = rows.tracks, .max_size = .{ .width = .length(200), .height = .auto() } }, &.{ a, b });
    try t.compute_layout_with_measure(root, upstream_avail.max_content, T.fixture_measure_function);
    try testing.expectEqual(@as(f32, 200), (try t.layout_of(root)).size.width);
    try testing.expectEqual(@as(f32, 40), (try t.layout_of(root)).size.height);
    try testing.expectEqual(@as(f32, 200), (try t.layout_of(a)).size.width);
    try testing.expectEqual(@as(f32, 20), (try t.layout_of(a)).size.height);
    try testing.expectEqual(@as(f32, 20), (try t.layout_of(b)).location.y);
}

test "taffy#847: an in-flow flex root's children resolve inline percentages against its min-width-clamped width" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const child = try t.new_leaf(.{ .size = .{ .width = .length(500), .height = .length(500) } });
    const container = try t.new_with_children(.{ .min_size = .{ .width = .percent(1), .height = .percent(1) } }, &.{child});
    const root = try t.new_with_children(.{ .min_size = .{ .width = .percent(1), .height = .percent(1) } }, &.{container});
    try t.compute_layout(root, upstream_avail.definite(1000, 1000));
    try testing.expectEqual(@as(f32, 1000), (try t.layout_of(root)).size.width);
    try testing.expectEqual(@as(f32, 1000), (try t.layout_of(container)).size.width);
    try testing.expectEqual(@as(f32, 1000), (try t.layout_of(container)).size.height);
}

test "taffy#804: a flex item's auto cross size follows its aspect ratio from the flexed main size" {
    const testing = std.testing;
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    var kids: [8]NodeId = undefined;
    for (&kids) |*k| k.* = try t.new_leaf(.{
        .min_size = .{ .width = .length(64), .height = .length(64) },
        .max_size = .{ .width = .length(128), .height = .length(128) },
        .flex_grow = 1,
        .flex_shrink = 0,
        .aspect_ratio = 1,
    });
    const c = try t.new_with_children(.{
        .display = .flex,
        .justify_content = style.alignment.JustifyContent.center,
        .align_items = style.alignment.AlignItems.center,
        .gap = .{ .width = .length(8), .height = .length(8) },
        .size = .{ .width = .length(2048), .height = .length(512) },
    }, &kids);
    try t.compute_layout(c, upstream_avail.max_content);
    for (kids) |k| {
        const l = try t.layout_of(k);
        try testing.expectEqual(@as(f32, 128), l.size.width);
        try testing.expectEqual(@as(f32, 128), l.size.height);
        try testing.expectEqual(@as(f32, 192), l.location.y);
    }
    // Without a min size the transferred height was 0.
    try t.set_style(kids[0], .{ .max_size = .{ .width = .length(128), .height = .auto() }, .flex_grow = 1, .aspect_ratio = 2 });
    try t.compute_layout(c, upstream_avail.max_content);
    try testing.expectEqual(@as(f32, 64), (try t.layout_of(kids[0])).size.height);
}

test "taffy#950/#923/#830/#803/#733: already handled" {
    const testing = std.testing;
    const T = @import("../test.zig");
    const LPA = style.dimension.LengthPercentageAuto;
    const LP = style.dimension.LengthPercentage;
    { // #950: a percentage height under a flexed item with an indefinite basis behaves as auto
        var t = Tree.init(testing.allocator);
        defer t.deinit();
        const inner = try t.new_leaf(.{ .display = .block, .size = .{ .width = .auto, .height = .percent(1) } });
        const mid = try t.new_with_children(.{ .display = .block, .flex_grow = 1 }, &.{inner});
        const outer = try t.new_with_children(.{ .display = .flex, .flex_direction = .column, .size = .{ .width = .length(200), .height = .auto }, .min_size = .{ .width = .auto(), .height = .length(200) } }, &.{mid});
        try t.compute_layout(outer, upstream_avail.definite(800, 600));
        try testing.expectEqual(@as(f32, 200), (try t.layout_of(mid)).size.height);
        try testing.expectEqual(@as(f32, 0), (try t.layout_of(inner)).size.height);
    }
    { // #923: nested absolutely positioned boxes centred with auto margins
        var t = Tree.init(testing.allocator);
        defer t.deinit();
        const A = LPA.auto();
        const inner = try t.new_leaf(.{ .display = .block, .box_sizing = .content_box, .position = .absolute, .inset = .{ .left = .length(0), .right = .length(0), .top = .length(0), .bottom = .length(0) }, .size = .{ .width = .length(40), .height = .length(30) }, .margin = .{ .left = A, .right = A, .top = A, .bottom = A }, .border = .{ .left = LP.length(2), .right = LP.length(2), .top = LP.length(2), .bottom = LP.length(2) } });
        const outer = try t.new_with_children(.{ .display = .block, .box_sizing = .content_box, .position = .absolute, .inset = .{ .left = .length(0), .right = .length(0), .top = .length(20), .bottom = A }, .size = .{ .width = .length(120), .height = .length(80) }, .margin = .{ .left = A, .right = A, .top = .zero(), .bottom = .zero() }, .border = .{ .left = LP.length(3), .right = LP.length(3), .top = LP.length(3), .bottom = LP.length(3) }, .padding = .{ .left = LP.length(10), .right = LP.length(10), .top = LP.length(10), .bottom = LP.length(10) } }, &.{inner});
        const root = try t.new_with_children(.{ .display = .block, .box_sizing = .content_box, .position = .relative, .size = .{ .width = .length(300), .height = .length(200) }, .border = .{ .left = LP.length(5), .right = LP.length(5), .top = LP.length(5), .bottom = LP.length(5) }, .padding = .{ .left = LP.length(15), .right = LP.length(15), .top = LP.length(15), .bottom = LP.length(15) } }, &.{outer});
        try t.compute_layout(root, upstream_avail.definite(800, 600));
        try testing.expectEqual(@as(f32, 97), (try t.layout_of(outer)).location.x);
        try testing.expectEqual(@as(f32, 25), (try t.layout_of(outer)).location.y);
        try testing.expectEqual(@as(f32, 51), (try t.layout_of(inner)).location.x);
        try testing.expectEqual(@as(f32, 36), (try t.layout_of(inner)).location.y);
    }
    { // #830: a flex container shrinks after all its children are removed
        var t = Tree.init(testing.allocator);
        defer t.deinit();
        const k1 = try t.new_leaf(.{ .size = .{ .width = .length(50), .height = .length(40) } });
        const k2 = try t.new_leaf(.{ .size = .{ .width = .length(50), .height = .length(40) } });
        const col = try t.new_with_children(.{ .display = .flex, .flex_direction = .column, .size = .{ .width = .percent(1), .height = .auto } }, &.{ k1, k2 });
        const root = try t.new_with_children(.{ .display = .block }, &.{col});
        try t.compute_layout(root, upstream_avail.definite(300, 300));
        try testing.expectEqual(@as(f32, 80), (try t.layout_of(col)).size.height);
        _ = try t.remove_child(col, k1);
        _ = try t.remove_child(col, k2);
        try t.compute_layout(root, upstream_avail.definite(300, 300));
        try testing.expectEqual(@as(f32, 0), (try t.layout_of(col)).size.height);
    }
    { // #803: rounding keeps an end-justified child inside its parent's border
        var t = Tree.init(testing.allocator);
        defer t.deinit();
        const leaf = try t.new_leaf(.{ .size = .{ .width = .length(1), .height = .length(1) } });
        const B = LP.length(1);
        const flex = try t.new_with_children(.{ .justify_content = style.alignment.JustifyContent.end, .border = .{ .left = B, .right = B, .top = B, .bottom = B }, .grid_row = .{ .start = .{ .line = 1 }, .end = .{ .span = 4 } }, .grid_column = .{ .start = .{ .line = 2 }, .end = .{ .span = 1 } } }, &.{leaf});
        const tracks = try style.grid.GridTemplateComponents.from_str(testing.allocator, "repeat(12, 1fr)");
        defer tracks.deinit(testing.allocator);
        const g = try t.new_with_children(.{ .display = .grid, .size = .{ .width = .percent(1), .height = .percent(1) }, .grid_template_rows = tracks.tracks, .grid_template_columns = tracks.tracks }, &.{flex});
        try t.compute_layout(g, upstream_avail.definite(127, 29));
        const fl = try t.layout_of(flex);
        try testing.expectEqual(fl.size.width - 2, (try t.layout_of(leaf)).location.x);
    }
    { // #733: an image in nested flex containers keeps its natural size
        var t = Tree.init(testing.allocator);
        defer t.deinit();
        var ctx = T.TestNodeContext.aspect_ratio(440, 291.0 / 440.0);
        const img = try t.new_leaf_with_context(.{ .display = .flex }, &ctx);
        const div = try t.new_with_children(.{ .display = .flex }, &.{img});
        const body = try t.new_with_children(.{ .display = .flex }, &.{div});
        const html = try t.new_with_children(.{ .display = .block }, &.{body});
        try t.compute_layout_with_measure(html, upstream_avail.definite(1280, 720), T.fixture_measure_function);
        try testing.expectEqual(@as(f32, 1280), (try t.layout_of(body)).size.width);
        try testing.expectEqual(@as(f32, 291), (try t.layout_of(body)).size.height);
        try testing.expectEqual(@as(f32, 440), (try t.layout_of(img)).size.width);
        try testing.expectEqual(@as(f32, 291), (try t.layout_of(img)).size.height);
    }
}

fn upstreamNanTree(comptime field: []const u8, value: anytype, disp: style.Display, avail: geometry.Size(@import("../style/available_space.zig").AvailableSpace)) !void {
    const T = @import("../test.zig");
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    var s: style.Style = .{ .display = disp, .flex_wrap = .wrap };
    @field(s, field) = value;
    var ctx = T.TestNodeContext.fixed(.{ .width = 30, .height = 12 });
    var actx = T.TestNodeContext.aspect_ratio(40, 0.5);
    const a = try t.new_leaf_with_context(s, &ctx);
    const b = try t.new_leaf_with_context(s, &actx);
    var bs = s;
    bs.display = .block;
    const c = try t.new_with_children(bs, &.{ a, b });
    var abs = s;
    abs.position = .absolute;
    const d = try t.new_leaf(abs);
    var fs = s;
    fs.display = .flex;
    const e = try t.new_with_children(fs, &.{try t.new_leaf(s)});
    var gs = s;
    gs.display = .grid;
    const f = try t.new_with_children(gs, &.{try t.new_leaf(s)});
    var fl = s;
    fl.display = .block;
    fl.float = .left;
    const h = try t.new_leaf(fl);
    const root = try t.new_with_children(s, &.{ c, d, e, f, h });
    try t.compute_layout_with_measure(root, avail, T.fixture_measure_function);
    t.mark_all_dirty();
    try t.compute_layout_with_measure(root, avail, T.fixture_measure_function);
}

test "taffy#231: NaN and infinite style values and available space never crash" {
    const LP = style.dimension.LengthPercentage;
    const LPA = style.dimension.LengthPercentageAuto;
    const Dim = style.dimension.Dimension;
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const AS = @import("../style/available_space.zig").AvailableSpace;
    const avails = [_]geometry.Size(AS){ upstream_avail.max_content, upstream_avail.definite(300, 300), .{ .width = .min_content, .height = .min_content }, upstream_avail.definite(nan, nan), upstream_avail.definite(inf, inf) };
    for ([_]style.Display{ .flex, .grid, .block }) |disp| for (avails) |av| for ([_]f32{ nan, inf, -inf }) |v| {
        const Rp = geometry.Rect(LP){ .left = LP.length(v), .right = LP.length(v), .top = LP.length(v), .bottom = LP.length(v) };
        const Ra = geometry.Rect(LPA){ .left = LPA.length(v), .right = LPA.length(v), .top = LPA.length(v), .bottom = LPA.length(v) };
        try upstreamNanTree("size", geometry.Size(Dim){ .width = .length(v), .height = .length(v) }, disp, av);
        try upstreamNanTree("size", geometry.Size(Dim){ .width = .percent(v), .height = .percent(v) }, disp, av);
        try upstreamNanTree("min_size", geometry.Size(LPA){ .width = .length(v), .height = .length(v) }, disp, av);
        try upstreamNanTree("max_size", geometry.Size(LPA){ .width = .length(v), .height = .length(v) }, disp, av);
        try upstreamNanTree("margin", Ra, disp, av);
        try upstreamNanTree("inset", Ra, disp, av);
        try upstreamNanTree("padding", Rp, disp, av);
        try upstreamNanTree("border", Rp, disp, av);
        try upstreamNanTree("gap", geometry.Size(LP){ .width = .length(v), .height = .length(v) }, disp, av);
        try upstreamNanTree("flex_grow", v, disp, av);
        try upstreamNanTree("flex_shrink", v, disp, av);
        try upstreamNanTree("flex_basis", Dim.length(v), disp, av);
        try upstreamNanTree("aspect_ratio", @as(?f32, v), disp, av);
        try upstreamNanTree("scrollbar_width", v, disp, av);
        const tr = [_]style.grid.TrackSizingFunction{style.grid.TrackSizingFunction.from_length(v)};
        try upstreamNanTree("grid_auto_rows", @as([]const style.grid.TrackSizingFunction, &tr), disp, av);
        try upstreamNanTree("grid_auto_columns", @as([]const style.grid.TrackSizingFunction, &tr), disp, av);
    };
}


// ---------------------------------------------------------------- triage ----
const TLP = style.dimension.LengthPercentage;
const TLPA = style.dimension.LengthPercentageAuto;
const TDim = style.dimension.Dimension;
const t_max: geometry.Size(@import("../style/available_space.zig").AvailableSpace) = .{ .width = .max_content, .height = .max_content };

test "triage 1354a: swapping relative/absolute does not overflow the stack" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    const abs = try t.new_leaf(.{ .position = .absolute });
    const rel = try t.new_with_children(.{ .position = .relative }, &.{abs});
    const root = try t.new_with_children(.{}, &.{rel});
    try t.compute_layout(root, t_max);
    _ = try t.remove_child(rel, abs);
    _ = try t.remove_child(root, rel);
    try t.add_child(root, abs);
    try t.add_child(abs, rel);
    try t.compute_layout(root, t_max);
    try std.testing.expectEqual(@as(usize, 0), (try t.hoisted_children(rel)).len);
}

fn t1354Build(t: *Tree, box_in_first: bool) ![4]NodeId {
    const rel = struct {
        fn f(top: f32) style.Style {
            return .{ .position = .relative, .margin = .{ .left = TLPA.zero(), .right = TLPA.zero(), .top = TLPA.length(top), .bottom = TLPA.zero() } };
        }
    }.f;
    const boxed = try t.new_leaf(.{ .position = .absolute, .size = .{ .width = .auto, .height = TDim.length(1.5) } });
    const first = try t.new_with_children(rel(0.25), if (box_in_first) &.{boxed} else &.{});
    const second = try t.new_with_children(rel(0.5), if (box_in_first) &.{} else &.{boxed});
    const root = try t.new_with_children(.{ .display = .block }, &.{ first, second });
    try t.compute_layout(root, t_max);
    return .{ root, first, second, boxed };
}

test "triage 1354b: moved abspos box is rounded from its new containing block" {
    var edited = Tree.init(std.testing.allocator);
    defer edited.deinit();
    const ids = try t1354Build(&edited, false);
    _ = try edited.remove_child(ids[2], ids[3]);
    try edited.add_child(ids[1], ids[3]);
    try edited.compute_layout(ids[0], t_max);
    var fresh = Tree.init(std.testing.allocator);
    defer fresh.deinit();
    const fids = try t1354Build(&fresh, true);
    try std.testing.expectEqual((try fresh.unrounded_layout(fids[3])).location, (try edited.unrounded_layout(ids[3])).location);
    try std.testing.expectEqual(@as(f32, 2), (try fresh.layout_of(fids[3])).size.height);
    try std.testing.expectEqual(@as(f32, 2), (try edited.layout_of(ids[3])).size.height);
}

test "triage 1354c: becoming display:none drops stale abspos rounding" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    const ids = try t1354Build(&t, false);
    var s = try t.style_of(ids[2]);
    s.display = .none;
    try t.set_style(ids[2], s);
    try t.compute_layout(ids[0], t_max);
    try std.testing.expectEqual(@as(usize, 0), (try t.hoisted_children(ids[2])).len);
    try std.testing.expectEqual(@as(f32, 0), (try t.layout_of(ids[3])).size.height);
}

test "triage 1357: abspos box inside a display:none subtree gets a zeroed final layout" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    const abs = try t.new_leaf(.{ .position = .absolute, .size = .{ .width = TDim.length(10), .height = TDim.length(10) } });
    const inner_abs = try t.new_leaf(.{ .position = .absolute, .size = .{ .width = TDim.length(5), .height = TDim.length(5) } });
    const rel = try t.new_with_children(.{ .position = .relative, .size = .{ .width = TDim.length(50), .height = TDim.length(50) } }, &.{abs});
    const static_wrap = try t.new_with_children(.{ .size = .{ .width = TDim.length(20), .height = TDim.length(20) } }, &.{inner_abs});
    const hider = try t.new_with_children(.{ .display = .block }, &.{ rel, static_wrap });
    const root = try t.new_with_children(.{ .position = .relative, .display = .block }, &.{hider});
    try t.compute_layout(root, t_max);
    try std.testing.expectEqual(@as(f32, 10), (try t.layout_of(abs)).size.width);
    try std.testing.expectEqual(@as(f32, 5), (try t.layout_of(inner_abs)).size.width);
    var s = try t.style_of(hider);
    s.display = .none;
    try t.set_style(hider, s);
    try t.compute_layout(root, t_max);
    try std.testing.expectEqual(@as(f32, 0), (try t.layout_of(abs)).size.width);
    try std.testing.expectEqual(@as(f32, 0), (try t.layout_of(inner_abs)).size.width);
    try std.testing.expectEqual(@as(usize, 0), (try t.hoisted_children(root)).len);
}

test "triage 1100: add_child to a second parent detaches from the first" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    const n1 = try t.new_leaf(.{});
    const n2 = try t.new_leaf(.{});
    const n3 = try t.new_leaf(.{});
    try t.add_child(n1, n2);
    try t.add_child(n3, n2);
    try std.testing.expectEqual(@as(usize, 0), try t.child_count(n1));
    try std.testing.expectEqual(n3, (try t.parent(n2)).?);
    _ = try t.remove(n1);
    _ = try t.remove(n2);
    _ = try t.remove(n3);
    const m1 = try t.new_leaf(.{});
    const m2 = try t.new_leaf(.{});
    const m3 = try t.new_leaf(.{});
    try t.add_child(m1, m2);
    try t.insert_child_at_index(m3, 0, m2);
    try std.testing.expectEqual(@as(usize, 0), try t.child_count(m1));
    _ = try t.remove(m1);
    _ = try t.remove(m2);
    _ = try t.remove(m3);
}

fn wrapper400(t: *Tree, kids: []const NodeId) !NodeId {
    return t.new_with_children(.{ .display = .block, .position = .relative, .size = .{ .width = TDim.length(400), .height = TDim.length(300) } }, kids);
}

test "triage 1299.1: fit-content flex row with inflexible small basis" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    const c = try t.new_leaf(.{ .display = .block, .size = .{ .width = TDim.length(20), .height = TDim.length(10) } });
    const b = try t.new_with_children(.{ .display = .block, .flex_grow = 0, .flex_shrink = 0, .flex_basis = TDim.length(4) }, &.{c});
    const a = try t.new_with_children(.{ .display = .flex }, &.{b});
    const col = try t.new_with_children(.{ .display = .flex, .flex_direction = .column, .align_items = .FLEX_START }, &.{a});
    const root = try wrapper400(&t, &.{col});
    try t.compute_layout(root, t_max);
    try std.testing.expectEqual(@as(f32, 20), (try t.layout_of(a)).size.width);
    try std.testing.expectEqual(@as(f32, 20), (try t.layout_of(b)).size.width);
}

test "triage 1299.2: intrinsic column height with flex-basis 0 item" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    const b = try t.new_leaf(.{ .display = .block, .flex_grow = 1, .flex_shrink = 1, .flex_basis = TDim.length(0), .size = .{ .width = .auto, .height = TDim.length(67) }, .padding = .{ .left = TLP.zero(), .right = TLP.zero(), .top = TLP.length(14), .bottom = TLP.zero() } });
    const a = try t.new_with_children(.{ .display = .flex, .flex_direction = .column, .size = .{ .width = TDim.length(100), .height = .auto } }, &.{b});
    const root = try wrapper400(&t, &.{a});
    try t.compute_layout(root, t_max);
    try std.testing.expectEqual(@as(f32, 14), (try t.layout_of(a)).size.height);
    try std.testing.expectEqual(@as(f32, 14), (try t.layout_of(b)).size.height);
}

test "triage 1299.3: percent height inside auto-height abspos behaves as auto" {
    const Case = struct { display: style.Display, row: bool = false, bottom: ?f32 = null, want: f32 };
    const cases = [_]Case{
        .{ .display = .flex, .want = 16 },
        .{ .display = .block, .want = 16 },
        .{ .display = .flex, .row = true, .want = 16 },
        // top+bottom insets make the height definite (300 - 0 - 100 = 200): 50% = 100
        .{ .display = .flex, .bottom = 100, .want = 100 },
        .{ .display = .block, .bottom = 100, .want = 100 },
    };
    for (cases) |c| {
        var t = Tree.init(std.testing.allocator);
        defer t.deinit();
        const inner = try t.new_leaf(.{ .display = .block, .size = .{ .width = TDim.length(20), .height = TDim.length(16) } });
        const b = try t.new_with_children(.{ .display = .block, .align_self = if (c.row) .FLEX_START else null, .size = .{ .width = .auto, .height = TDim.percent(0.5) } }, &.{inner});
        const a = try t.new_with_children(.{ .display = c.display, .flex_direction = if (c.row) .row else .column, .position = .absolute, .inset = .{ .left = TLPA.length(0), .top = TLPA.length(0), .right = TLPA.auto(), .bottom = if (c.bottom) |v| TLPA.length(v) else TLPA.auto() }, .size = .{ .width = TDim.length(100), .height = .auto } }, &.{b});
        const root = try wrapper400(&t, &.{a});
        try t.compute_layout(root, t_max);
        try std.testing.expectEqual(c.want, (try t.layout_of(b)).size.height);
    }
}

fn wordsSize(context: ?*anyopaque, known: geometry.Size(?f32), avail: geometry.Size(@import("../style/available_space.zig").AvailableSpace)) geometry.Size(f32) {
    _ = context;
    const w: f32 = known.width orelse switch (avail.width) {
        .min_content => 45,
        .max_content => 495,
        .definite => |v| std.math.clamp(@floor(v / 45) * 45, 45, 495),
    };
    const per_line = @max(1, @floor(w / 45));
    return .{ .width = w, .height = known.height orelse @ceil(11 / per_line) * 16 };
}
fn wordsMeasure(context: ?*anyopaque, inputs: layout.LayoutInput, id: NodeId, s: *const style.Style) layout.LayoutOutput {
    _ = id;
    if (context == null) return @import("../compute/leaf.zig").compute_leaf_layout(inputs, s, null, null);
    return @import("../compute/leaf.zig").compute_leaf_layout(inputs, s, context, wordsSize);
}

test "triage 1299.4: auto-width abspos column measures wrapping content at final width" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    var dummy: u8 = 0;
    const spacer = try t.new_leaf(.{ .display = .block, .size = .{ .width = TDim.length(160), .height = TDim.length(0) } });
    const b = try t.new_leaf_with_context(.{ .display = .block }, @ptrCast(&dummy));
    const a = try t.new_with_children(.{ .display = .flex, .flex_direction = .column, .position = .absolute, .inset = .{ .left = TLPA.length(0), .top = TLPA.length(0), .right = TLPA.auto(), .bottom = TLPA.auto() } }, &.{ spacer, b });
    const rel = try t.new_with_children(.{ .display = .block, .position = .relative, .size = .{ .width = TDim.length(0), .height = TDim.length(100) } }, &.{a});
    const root = try wrapper400(&t, &.{rel});
    try t.compute_layout_with_measure(root, t_max, wordsMeasure);
    try std.testing.expectEqual(@as(f32, 160), (try t.layout_of(a)).size.width);
    try std.testing.expectEqual(@as(f32, 64), (try t.layout_of(a)).size.height);
    try std.testing.expectEqual(@as(f32, 64), (try t.layout_of(b)).size.height);
}

test "triage 1299.5: cross-axis auto margin zeroed when overflowing" {
    // flex column 56px wide, 136px item: [direction, left auto, right auto, expected x]
    const Case = struct { dir: style.Direction, l: bool, r: bool, x: f32 };
    const cases = [_]Case{
        .{ .dir = .ltr, .l = true, .r = false, .x = 0 },
        .{ .dir = .ltr, .l = false, .r = true, .x = 0 },
        .{ .dir = .ltr, .l = true, .r = true, .x = 0 },
        .{ .dir = .rtl, .l = true, .r = false, .x = -80 },
        .{ .dir = .rtl, .l = false, .r = true, .x = -80 },
        .{ .dir = .rtl, .l = true, .r = true, .x = -80 },
    };
    for (cases) |c| {
        var t = Tree.init(std.testing.allocator);
        defer t.deinit();
        const b = try t.new_leaf(.{ .display = .block, .size = .{ .width = TDim.length(136), .height = TDim.length(10) }, .margin = .{ .left = if (c.l) TLPA.auto() else TLPA.zero(), .right = if (c.r) TLPA.auto() else TLPA.zero(), .top = TLPA.zero(), .bottom = TLPA.zero() } });
        const a = try t.new_with_children(.{ .display = .flex, .direction = c.dir, .flex_direction = .column, .align_items = .FLEX_END, .size = .{ .width = TDim.length(56), .height = .auto } }, &.{b});
        const root = try wrapper400(&t, &.{a});
        try t.compute_layout(root, t_max);
        try std.testing.expectEqual(c.x, (try t.layout_of(b)).location.x);
    }
    // Row: the top (block-start) auto margin is zeroed.
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    const b = try t.new_leaf(.{ .display = .block, .size = .{ .width = TDim.length(10), .height = TDim.length(136) }, .margin = .{ .left = TLPA.zero(), .right = TLPA.zero(), .top = TLPA.auto(), .bottom = TLPA.auto() } });
    const a = try t.new_with_children(.{ .display = .flex, .size = .{ .width = .auto, .height = TDim.length(56) } }, &.{b});
    const root = try wrapper400(&t, &.{a});
    try t.compute_layout(root, t_max);
    try std.testing.expectEqual(@as(f32, 0), (try t.layout_of(b)).location.y);
}

test "triage 1299.6: percent max-width in fit-content column" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    const p17 = TLP.length(17);
    const first = try t.new_leaf(.{ .display = .block, .box_sizing = .content_box, .size = .{ .width = TDim.length(142), .height = TDim.length(10) } });
    const a = try t.new_with_children(.{ .display = .flex, .box_sizing = .content_box, .max_size = .{ .width = TLPA.percent(0.25), .height = TLPA.auto() }, .size = .{ .width = .auto, .height = TDim.length(16) } }, &.{});
    const c = try t.new_with_children(.{ .display = .flex, .box_sizing = .content_box, .flex_direction = .column, .position = .absolute, .max_size = .{ .width = TLPA.length(200), .height = TLPA.auto() }, .padding = .{ .left = p17, .right = p17, .top = p17, .bottom = p17 } }, &.{ first, a });
    const root = try wrapper400(&t, &.{c});
    try t.compute_layout(root, t_max);
    try std.testing.expectEqual(@as(f32, 176), (try t.layout_of(c)).size.width);
    try std.testing.expectEqual(@as(f32, 35.5), (try t.unrounded_layout(a)).size.width);
}

test "triage 1296: auto-width row with flex-basis 0 item in align-items:start column" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    var boxes: [9]NodeId = undefined;
    for (&boxes) |*bx| bx.* = try t.new_leaf(.{ .size = .{ .width = TDim.length(60), .height = TDim.length(16) }, .flex_shrink = 0 });
    const grows = try t.new_with_children(.{ .flex_wrap = .wrap, .flex_grow = 1, .flex_shrink = 0, .flex_basis = TDim.length(0) }, &boxes);
    const fixed = try t.new_leaf(.{ .size = .{ .width = TDim.length(30), .height = TDim.length(16) }, .flex_shrink = 0 });
    const row = try t.new_with_children(.{}, &.{ grows, fixed });
    const column = try t.new_with_children(.{ .flex_direction = .column, .align_items = .START, .size = .{ .width = TDim.length(316), .height = .auto } }, &.{row});
    try t.compute_layout(column, t_max);
    try std.testing.expectEqual(@as(f32, 316), (try t.layout_of(row)).size.width);
    try std.testing.expectEqual(@as(f32, 48), (try t.layout_of(row)).size.height);
    try std.testing.expectEqual(@as(f32, 286), (try t.layout_of(grows)).size.width);
    try std.testing.expectEqual(@as(f32, 48), (try t.layout_of(grows)).size.height);
}

test "triage 1295: auto-width grid in align-items:start column" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    var boxes: [9]NodeId = undefined;
    for (&boxes) |*bx| bx.* = try t.new_leaf(.{ .size = .{ .width = TDim.length(60), .height = TDim.length(16) }, .flex_shrink = 0 });
    const wrap = try t.new_with_children(.{ .flex_wrap = .wrap }, &boxes);
    const cols = [_]style.grid.GridTemplateComponent{.{ .single = style.grid.TrackSizingFunction.from_fr(1) }};
    const grid = try t.new_with_children(.{ .display = .grid, .grid_template_columns = &cols }, &.{wrap});
    const column = try t.new_with_children(.{ .flex_direction = .column, .align_items = .START, .size = .{ .width = TDim.length(316), .height = .auto } }, &.{grid});
    try t.compute_layout(column, t_max);
    try std.testing.expectEqual(@as(f32, 316), (try t.layout_of(grid)).size.width);
    try std.testing.expectEqual(@as(f32, 32), (try t.layout_of(grid)).size.height);
}

test "triage 1240: overflowing grid item with auto margins" {
    for ([_]style.Direction{ .ltr, .rtl }) |dir| {
        var t = Tree.init(std.testing.allocator);
        defer t.deinit();
        t.disable_rounding();
        const item = try t.new_leaf(.{ .size = .{ .width = TDim.length(600), .height = TDim.length(20) }, .margin = .{ .left = TLPA.auto(), .right = TLPA.auto(), .top = TLPA.zero(), .bottom = TLPA.zero() }, .justify_self = .CENTER });
        const cols = [_]style.grid.GridTemplateComponent{.{ .single = style.grid.TrackSizingFunction.from_length(300) }};
        const root = try t.new_with_children(.{ .display = .grid, .direction = dir, .size = .{ .width = TDim.length(300), .height = .auto }, .grid_template_columns = &cols }, &.{item});
        try t.compute_layout(root, t_max);
        try std.testing.expectEqual(@as(f32, if (dir == .ltr) 0 else -300), (try t.layout_of(item)).location.x);
    }
}

test "triage 1239: f32 precision in grid distribution" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    t.disable_rounding();
    const G = style.grid;
    const item = try t.new_leaf(.{});
    const second = try t.new_leaf(.{});
    const cols = [_]G.GridTemplateComponent{
        .{ .single = G.TrackSizingFunction.from_min_max(G.MinTrackSizingFunction.length(173.68802), G.MaxTrackSizingFunction.from_length_percentage(TLP.length(993.3))) },
        .{ .single = G.TrackSizingFunction.from_min_max(G.MinTrackSizingFunction.length(0), G.MaxTrackSizingFunction.from_length_percentage(TLP.length(3000))) },
    };
    const root = try t.new_with_children(.{ .display = .grid, .size = .{ .width = TDim.length(2000), .height = .auto }, .grid_template_columns = &cols }, &.{ item, second });
    try t.compute_layout(root, t_max);
    const w1 = (try t.layout_of(item)).size.width;
    const w2 = (try t.layout_of(second)).size.width;
    try std.testing.expectApproxEqAbs(@as(f32, 993.3), w1, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1006.7), w2, 0.01);
}

fn size1238(context: ?*anyopaque, known: geometry.Size(?f32), avail: geometry.Size(@import("../style/available_space.zig").AvailableSpace)) geometry.Size(f32) {
    _ = context;
    const w: f32 = known.width orelse switch (avail.width) {
        .min_content => 100,
        .max_content => 600,
        .definite => |v| std.math.clamp(v, 100, 600),
    };
    return .{ .width = w, .height = known.height orelse @ceil(600 / w) * 10 };
}
fn measure1238(context: ?*anyopaque, inputs: layout.LayoutInput, id: NodeId, s: *const style.Style) layout.LayoutOutput {
    _ = id;
    return @import("../compute/leaf.zig").compute_leaf_layout(inputs, s, context, size1238);
}

test "triage 1238: non-stretched auto-width grid item gets fit-content width" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    t.disable_rounding();
    const leaf = try t.new_leaf(.{});
    const fr1 = [_]style.grid.GridTemplateComponent{.{ .single = style.grid.TrackSizingFunction.from_fr(1) }};
    const item = try t.new_with_children(.{ .display = .grid, .grid_template_columns = &fr1, .justify_self = .CENTER }, &.{leaf});
    const cols = [_]style.grid.GridTemplateComponent{.{ .single = style.grid.TrackSizingFunction.from_length(300) }};
    const root = try t.new_with_children(.{ .display = .grid, .size = .{ .width = TDim.length(300), .height = .auto }, .grid_template_columns = &cols }, &.{item});
    try t.compute_layout_with_measure(root, t_max, measure1238);
    try std.testing.expectEqual(@as(f32, 300), (try t.layout_of(item)).size.width);
    try std.testing.expectEqual(@as(f32, 0), (try t.layout_of(item)).location.x);
    try std.testing.expectEqual(@as(f32, 20), (try t.layout_of(item)).size.height);
    try std.testing.expectEqual(@as(f32, 20), (try t.layout_of(root)).size.height);
}

test "triage 1211: float placed beside a shorter float keeps its lower part" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    const f1 = try t.new_leaf(.{ .display = .block, .float = .left, .size = .{ .width = TDim.length(100), .height = TDim.length(20) } });
    const f2 = try t.new_leaf(.{ .display = .block, .float = .right, .size = .{ .width = TDim.length(50), .height = TDim.length(40) } });
    const spacer = try t.new_leaf(.{ .display = .block, .size = .{ .width = .auto, .height = TDim.length(25) } });
    const last = try t.new_leaf(.{ .display = .flow_root, .size = .{ .width = .auto, .height = TDim.length(10) } });
    const root = try t.new_with_children(.{ .display = .flow_root, .size = .{ .width = TDim.length(300), .height = .auto } }, &.{ f1, f2, spacer, last });
    try t.compute_layout(root, t_max);
    try std.testing.expectEqual(@as(f32, 25), (try t.layout_of(last)).location.y);
    try std.testing.expectEqual(@as(f32, 250), (try t.layout_of(last)).size.width);
    try std.testing.expectEqual(@as(f32, 250), (try t.layout_of(f2)).location.x);
}

test "triage 1299.2b: without padding the column collapses to 0" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    const b = try t.new_leaf(.{ .display = .block, .flex_grow = 1, .flex_shrink = 1, .flex_basis = TDim.length(0), .size = .{ .width = .auto, .height = TDim.length(67) } });
    const a = try t.new_with_children(.{ .display = .flex, .flex_direction = .column, .size = .{ .width = TDim.length(100), .height = .auto } }, &.{b});
    const root = try wrapper400(&t, &.{a});
    try t.compute_layout(root, t_max);
    try std.testing.expectEqual(@as(f32, 0), (try t.layout_of(a)).size.height);
    try std.testing.expectEqual(@as(f32, 0), (try t.layout_of(b)).size.height);
}

fn size1238Unbreakable(context: ?*anyopaque, known: geometry.Size(?f32), avail: geometry.Size(@import("../style/available_space.zig").AvailableSpace)) geometry.Size(f32) {
    _ = context;
    const w: f32 = known.width orelse switch (avail.width) {
        .min_content => 400,
        .max_content => 600,
        .definite => |v| std.math.clamp(v, 400, 600),
    };
    return .{ .width = w, .height = known.height orelse @ceil(600 / w) * 10 };
}
fn measure1238Unbreakable(context: ?*anyopaque, inputs: layout.LayoutInput, id: NodeId, s: *const style.Style) layout.LayoutOutput {
    _ = id;
    return @import("../compute/leaf.zig").compute_leaf_layout(inputs, s, context, size1238Unbreakable);
}

test "triage 1238b: a fit-content grid item keeps its min-content floor" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    t.disable_rounding();
    const leaf = try t.new_leaf(.{});
    const fr1 = [_]style.grid.GridTemplateComponent{.{ .single = style.grid.TrackSizingFunction.from_fr(1) }};
    const item = try t.new_with_children(.{ .display = .grid, .grid_template_columns = &fr1, .justify_self = .START }, &.{leaf});
    const cols = [_]style.grid.GridTemplateComponent{.{ .single = style.grid.TrackSizingFunction.from_length(300) }};
    const root = try t.new_with_children(.{ .display = .grid, .size = .{ .width = TDim.length(300), .height = .auto }, .grid_template_columns = &cols }, &.{item});
    try t.compute_layout_with_measure(root, t_max, measure1238Unbreakable);
    try std.testing.expectEqual(@as(f32, 400), (try t.layout_of(item)).size.width);
    try std.testing.expectEqual(@as(f32, 20), (try t.layout_of(item)).size.height);
}

test "triage 1296b: a fit-content row narrower than its space keeps its max-content width" {
    var t = Tree.init(std.testing.allocator);
    defer t.deinit();
    var boxes: [2]NodeId = undefined;
    for (&boxes) |*bx| bx.* = try t.new_leaf(.{ .size = .{ .width = TDim.length(60), .height = TDim.length(16) }, .flex_shrink = 0 });
    const grows = try t.new_with_children(.{ .flex_wrap = .wrap, .flex_grow = 1, .flex_shrink = 0, .flex_basis = TDim.length(0) }, &boxes);
    const fixed = try t.new_leaf(.{ .size = .{ .width = TDim.length(30), .height = TDim.length(16) }, .flex_shrink = 0 });
    const row = try t.new_with_children(.{}, &.{ grows, fixed });
    const column = try t.new_with_children(.{ .flex_direction = .column, .align_items = .START, .size = .{ .width = TDim.length(316), .height = .auto } }, &.{row});
    try t.compute_layout(column, t_max);
    try std.testing.expectEqual(@as(f32, 150), (try t.layout_of(row)).size.width);
    try std.testing.expectEqual(@as(f32, 16), (try t.layout_of(row)).size.height);
}
