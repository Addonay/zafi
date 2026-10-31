//! Allocator-backed high-level tree corresponding to Taffy's
//! `tree/tree.rs`.
//!
//! # Storage and identity
//!
//! Nodes live in paged, never-relocated storage, so a `*NodeData` obtained from
//! `raw_node()` stays valid for the tree's lifetime. Identity is *separate* from
//! address: [`NodeId`] is a generational handle (`tree/node.zig`), so an id
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
    style: style.Style,
    unrounded_layout: layout.Layout = .{},
    final_layout: layout.Layout = .{},
    children: std.ArrayList(NodeId),
    parent: ?NodeId = null,
    cache: cache.Cache = .{},
    alive: bool = true,
    /// Per-node measure context (Taffy's `NodeContext`). `has_context` mirrors
    /// Taffy's flag so a null context can still be a stored context.
    has_context: bool = false,
    context: ?*anyopaque = null,
    /// Out-of-flow (`absolute`/`fixed`) boxes whose containing block is this
    /// node, as recorded by the out-of-flow positioning pass. Laid out by this
    /// node rather than by their parent, so their `Layout.location` is relative
    /// to this node.
    hoisted_children: std.ArrayListUnmanaged(NodeId) = .empty,
    detailed_layout_info: layout.DetailedLayoutInfo = .none,
    /// Destructor for `detailed_layout_info`, supplied by the algorithm that
    /// produced it (the tree layer cannot know concrete detail types).
    detailed_info_deinit: ?*const fn (*const anyopaque, std.mem.Allocator) void = null,

    fn deinit(self: *NodeData, allocator: std.mem.Allocator) void {
        freeDetailedInfo(self, allocator);
        self.hoisted_children.deinit(allocator);
        self.children.deinit(allocator);
    }
};

fn freeDetailedInfo(node_data: *NodeData, allocator: std.mem.Allocator) void {
    if (node_data.detailed_layout_info != .none) {
        if (node_data.detailed_info_deinit) |deinit_fn| {
            deinit_fn(node_data.detailed_layout_info.grid, allocator);
        }
        node_data.detailed_layout_info = .none;
        node_data.detailed_info_deinit = null;
    }
}

/// Paged, generational node storage.
///
/// Taffy's slotmap inserts into immovable blocks; the Zig port previously used
/// one `ArrayList(NodeData)` whose doubling growth memcpy'd the entire tree on
/// every capacity increase (`NodeData` is ~1.3 KB). Pages are allocated once and
/// never moved, so node insertion is O(1) with no large copies.
///
/// Slots are recycled through a LIFO free list and every reuse bumps the slot's
/// generation, so removed nodes do not accumulate storage forever and stale ids
/// can never resolve to a recycled node.
pub const NodeStore = struct {
    /// Slots in the first page. Small trees (the overwhelmingly common case for a
    /// retained tree plus a handful of edits) avoid paying for a full page.
    pub const first_page_size: usize = 8;
    /// Pages double from `first_page_size` up to this many slots, then stay
    /// fixed. Small trees stay small, and full pages are large enough
    /// (> 128 KiB) that general-purpose allocators serve them from mmap and
    /// adapt to them, instead of trimming and re-faulting mid-sized heap chunks
    /// on every tree teardown.
    pub const page_size: usize = 128;
    const doubling_pages = std.math.log2_int(usize, page_size / first_page_size);
    /// Slots before the first fixed-size page: 8 + 16 + ... + page_size/2.
    const doubling_slots = page_size - first_page_size;

    allocator: std.mem.Allocator,
    pages: std.ArrayListUnmanaged([]NodeData) = .empty,
    /// Number of slots ever allocated; ids index into `0..len`.
    len: u32 = 0,
    /// Free slot indices, most recently released first.
    free: std.ArrayListUnmanaged(u32) = .empty,
    /// Number of slots currently holding a live node.
    live_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) NodeStore {
        return .{ .allocator = allocator };
    }

    fn pageCount(count: u32) usize {
        return if (count == 0) 0 else pageIndex(count - 1) + 1;
    }

    inline fn pageIndex(index: u32) usize {
        if (index < doubling_slots) return 31 - @clz((index >> 3) + 1);
        return doubling_pages + (index - doubling_slots) / page_size;
    }

    inline fn pageOffset(index: u32) usize {
        if (index < doubling_slots) {
            const k: u5 = @intCast(31 - @clz((index >> 3) + 1));
            return index - ((@as(u32, 1) << k) - 1) * first_page_size;
        }
        return (index - doubling_slots) % page_size;
    }

    fn pageSlots(page: usize) usize {
        return if (page < doubling_pages) first_page_size << @intCast(page) else page_size;
    }

    pub fn ensurePages(self: *NodeStore, count: u32) !void {
        const required = pageCount(count);
        while (self.pages.items.len < required) {
            const size: usize = pageSlots(self.pages.items.len);
            const page = try self.allocator.alloc(NodeData, size);
            // The page is owned by `pages` only once the append succeeds; an
            // allocation failure must not strand it.
            errdefer self.allocator.free(page);
            try self.pages.append(self.allocator, page);
        }
    }

    /// Reserve room for `count` slots, releasing the backing pages.
    pub fn trim(self: *NodeStore) void {
        var index: usize = 0;
        while (index < self.pages.items.len) : (index += 1) self.allocator.free(self.pages.items[index]);
        self.pages.clearRetainingCapacity();
    }

    /// Take a slot for a new node, recycling a free one when available.
    fn acquire(self: *NodeStore) !u32 {
        if (self.free.pop()) |index| return index;
        if (self.len > node.max_index) return error.NodeIdExhausted;
        const index = self.len;
        try self.ensurePages(index + 1);
        self.len = index + 1;
        // Freshly allocated page memory is undefined; start the slot at
        // generation 0 so the first `NodeId` minted for it is well defined.
        self.at(index).generation = 0;
        return index;
    }

    /// Return a slot to the free list, bumping its generation so ids minted for
    /// the previous occupant stop resolving.
    fn release(self: *NodeStore, index: u32) !void {
        const slot = self.at(index);
        slot.generation +%= 1;
        if (slot.generation == 0) return error.NodeIdExhausted;
        try self.free.append(self.allocator, index);
        self.live_count -= 1;
    }

    /// In-place leaf construction: write the new node directly into its page
    /// slot instead of building a ~1.3 KB temporary and copying it.
    pub fn appendLeaf(self: *NodeStore, value: style.Style) !NodeId {
        const index = try self.acquire();
        const node_data = self.at(index);
        // Reset every owned field while preserving the slot's generation counter,
        // which is bumped by `release` when the slot is recycled.
        node_data.style = value;
        node_data.unrounded_layout = .{};
        node_data.final_layout = .{};
        node_data.children = .empty;
        node_data.parent = null;
        node_data.cache = .{};
        node_data.alive = true;
        node_data.has_context = false;
        node_data.context = null;
        node_data.hoisted_children = .empty;
        node_data.detailed_layout_info = .none;
        node_data.detailed_info_deinit = null;
        node_data.visit_mark = 0;
        self.live_count += 1;
        return node.fromParts(index, node_data.generation) orelse error.NodeIdExhausted;
    }

    /// Mutable access to an allocated slot. The slot must be `< len`.
    pub fn at(self: *NodeStore, index: u32) *NodeData {
        return &self.pages.items[pageIndex(index)][pageOffset(index)];
    }

    pub fn atConst(self: *const NodeStore, index: u32) *const NodeData {
        return &self.pages.items[pageIndex(index)][pageOffset(index)];
    }

    pub fn deinit(self: *NodeStore) void {
        self.trim();
        self.pages.deinit(self.allocator);
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
        if (config.initial_capacity > 0) result.nodes.ensurePages(@intCast(config.initial_capacity)) catch @panic("Taffy tree allocation failed");
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

    /// Release page capacity not backed by a live node. Useful after a burst of
    /// churn; layout itself never shrinks.
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
            self.nodes.free.append(self.allocator, index) catch @panic("Taffy tree mutation arena exhausted");
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
        try self.detach_from_parent(child, child_node.parent, parent_id);
        // Re-adding an existing child moves it to the end rather than creating a
        // second edge.
        try parent_node.children.ensureTotalCapacity(self.allocator, parent_node.children.items.len + 1);
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
        if (target > parent_node.children.items.len) return error.ChildIndexOutOfBounds;
        try self.detach_from_parent(child, child_node.parent, parent_id);
        try parent_node.children.insert(self.allocator, target, child);
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
        try self.detach_from_parent(child, child_node.parent, parent_id);
        parent_node.children.items[index] = child;
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
        return (self.get_node(id) orelse return error.InvalidParentNode).hoisted_children.items;
    }

    // ---------------------------------------------------------------------
    // Styles and layouts
    // ---------------------------------------------------------------------

    pub fn style_of(self: *const Tree, id: NodeId) !style.Style {
        return (self.get_node(id) orelse return error.InvalidInputNode).style;
    }

    /// Borrowed style pointer: no ~512-byte `Style` copy per call. Pointers
    /// are stable because nodes live in paged storage and are never moved.
    ///
    /// The `Style` record itself is owned by the tree, but the slices and strings
    /// it references (`grid_template_columns`, `grid_template_areas`, ...) are
    /// *borrowed from the caller* and must outlive the tree's use of them. See
    /// `editStyle` for a mutation path that keeps invalidation correct.
    pub fn style_ptr(self: *const Tree, id: NodeId) ?*const style.Style {
        return &(self.get_node(id) orelse return null).style;
    }

    pub fn set_style(self: *Tree, id: NodeId, value: style.Style) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        node_data.style = value;
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
        edit_fn(&node_data.style);
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
        return (self.get_node(id) orelse return error.InvalidInputNode).detailed_layout_info;
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
        freeDetailedInfo(node_data, self.allocator);
        node_data.detailed_layout_info = .{ .grid = info };
        node_data.detailed_info_deinit = deinit_fn;
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
        return node_data.cache.get(input.*);
    }

    pub fn cache_store(self: *Tree, id: NodeId, input: *const layout.LayoutInput, output: layout.LayoutOutput) void {
        if (self.get_node_mut(id)) |node_data| node_data.cache.store(input.*, output);
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

    /// Invalidate `id` and every ancestor up to the root.
    pub fn mark_dirty(self: *Tree, id: NodeId) void {
        var current: ?NodeId = id;
        while (current) |current_id| {
            const node_data = self.get_node_mut(current_id) orelse break;
            // Stop as soon as an ancestor is already dirty: its cache is empty,
            // so every ancestor above it was cleared before.
            switch (node_data.cache.clear()) {
                .already_empty => break,
                .cleared => {},
            }
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

    /// Default `calc()` resolver. Taffy's high-level trees also resolve calc to
    /// zero unless a measure/resolver hook is supplied; see
    /// `compute_layout_with_measure` and `Style.calc`.
    pub fn resolve_calc_value(self: *const Tree, _: ?*const anyopaque, _: f32) f32 {
        _ = self;
        return 0;
    }

    /// The `LayoutTree` hook: resolve a `calc()` length against `basis`.
    ///
    /// Zero, matching `resolve_calc_value` and Taffy's default tree. A host with
    /// a real expression engine overrides this.
    pub fn calc(self: *const Tree, value: ?*const anyopaque, basis: f32) ?f32 {
        return self.resolve_calc_value(value, basis);
    }

    /// The `LayoutTree` hook: a pointer to `id`'s style, valid for the pass.
    ///
    /// Non-optional: the algorithms only ask about ids they walked to. `style_ptr`
    /// is the checked form for callers that may hold a stale id.
    pub fn get_style(self: *const Tree, id: NodeId) *const style.Style {
        const node_data = self.get_node(id) orelse @panic("get_style: invalid or stale NodeId");
        return &node_data.style;
    }

    /// The style of an out-of-flow box being positioned by its containing block.
    pub fn oof_item_style(self: *const Tree, id: NodeId) ?*const style.Style {
        return self.style_ptr(id);
    }

    /// Drop the recorded out-of-flow child list. Called once per `perform_layout`
    /// pass before the node re-records it, so a previous run's list cannot
    /// persist.
    pub fn clear_hoisted_children(self: *Tree, id: NodeId) !void {
        if (self.get_node_mut(id)) |node_data| node_data.hoisted_children.clearRetainingCapacity();
    }

    /// Append to the recorded out-of-flow child list, in document order.
    pub fn add_hoisted_children(self: *Tree, id: NodeId, hoisted: []const NodeId) !void {
        const node_data = self.get_node_mut(id) orelse return error.InvalidInputNode;
        try node_data.hoisted_children.appendSlice(self.allocator, hoisted);
    }

    /// Whether `id` is an out-of-flow (`absolute`/`fixed`) box generating content.
    pub fn is_out_of_flow(self: *const Tree, id: NodeId) bool {
        const node_data = self.get_node(id) orelse return false;
        return node_data.style.position.is_out_of_flow() and node_data.style.display != .none;
    }

    pub fn hoisted_child_count(self: *const Tree, id: NodeId) !usize {
        return (self.get_node(id) orelse return error.InvalidParentNode).hoisted_children.items.len;
    }

    pub fn get_hoisted_child_id(self: *const Tree, id: NodeId, index: usize) !NodeId {
        return (self.get_node(id) orelse return error.InvalidParentNode).hoisted_children.items[index];
    }

    /// Read back the detailed layout information recorded for `id`, if any.
    pub fn get_detailed_layout_info(self: *const Tree, id: NodeId) ?*const anyopaque {
        const node_data = self.get_node(id) orelse return null;
        return switch (node_data.detailed_layout_info) {
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
        return compute.leaf_layout_with_measure(
            id,
            input,
            &node_data.style,
            if (node_data.has_context) node_data.context else null,
            measure,
        );
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
        var owned_children = node_data.children;
        node_data.children = .empty;
        owned_children.deinit(self.allocator);
        node_data.parent = null;
        freeDetailedInfo(node_data, self.allocator);
        node_data.hoisted_children.deinit(self.allocator);
        node_data.hoisted_children = .empty;
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
    /// should use `style_ptr`/`style_of` for reading, `set_style`/`edit_style`
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

    fn detach_from_parent(self: *Tree, child_id: NodeId, old_parent: ?NodeId, new_parent: NodeId) !void {
        const old_parent_id = old_parent orelse return;
        if (old_parent_id == new_parent) return;
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
