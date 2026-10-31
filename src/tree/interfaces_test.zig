//! Differential test for the `LayoutTree` contract.
//!
//! `src/tree/tree.zig` is the only real implementor of `LayoutTree`, which
//! leaves the interface unproven: it could be too strict, too loose, or
//! accidentally coupled to `Tree`'s internals and nothing would notice. This
//! file closes that gap by implementing the contract a second time, from
//! scratch, on a host with a completely different node store — arena-allocated
//! nodes and plain slices instead of the generational slot map — and asserting
//! that it produces identical layouts to `Tree` for the same input.
//!
//! That is a much stronger claim than "it compiles": if any algorithm reached
//! for a `Tree`-specific method (`raw_node`, `style_of`), or if the interface
//! let a required operation default silently, the two runs would diverge or
//! fail to build.
//!
//! The scenarios cover each dispatch arm plus the out-of-flow bookkeeping:
//! flex, grid, block, and an `absolute` child that exercises the
//! hoisted-children path and the final positioning pass.

const std = @import("std");
const testing = std.testing;

const geometry = @import("../geometry.zig");
const style = @import("../style/root.zig");
const available_space = @import("../style/available_space.zig");
const cache = @import("cache.zig");
const interfaces = @import("interfaces.zig");
const layout = @import("layout.zig");
const compute = @import("../compute/root.zig");
const tree = @import("tree.zig");

const NodeId = @import("node.zig").NodeId;
const AvailableSpace = available_space.AvailableSpace;
const Layout = layout.Layout;
const LayoutInput = layout.LayoutInput;
const LayoutOutput = layout.LayoutOutput;
const Grid = style.grid;
const HostError = CustomTree.Error;

// ---------------------------------------------------------------------------
// CustomTree: an independent `LayoutTree` implementor
// ---------------------------------------------------------------------------

const CustomNode = struct {
    style: style.Style,
    children: std.ArrayListUnmanaged(NodeId) = .empty,
    hoisted: std.ArrayListUnmanaged(NodeId) = .empty,
    unrounded: Layout = .{},
    final: Layout = .{},
    /// Grid detail output, stored opaquely exactly as a host must: the host
    /// stores the pointer and the destructor the producer supplied.
    detailed: ?*const anyopaque = null,
    detailed_deinit: ?*const fn (*const anyopaque, std.mem.Allocator) void = null,
    cache: cache.Cache = .{},
    /// Candidates of the cached final layout (arena-owned; see cache_store).
    cached_oof_candidates: []const layout.OofCandidate = &.{},
};

/// A host tree with a deliberately different storage strategy from `Tree`:
///
///   * nodes are arena-allocated, so `get_style` pointers stay valid for the
///     whole pass without the host having to reserve capacity;
///   * ids are plain `u32` indices, not generational handles;
///   * child and hoisted lists are ordinary slices.
const CustomTree = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(*CustomNode) = .empty,
    scratch: std.heap.ArenaAllocator,
    in_pass: bool = false,

    /// The algorithms' error set. It cannot be widened per-host: the compute
    /// entry points are typed against it.
    pub const Error = compute.ComputeError;

    pub fn init(allocator: std.mem.Allocator) CustomTree {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *CustomTree) void {
        // The child and hoisted lists come from the long-lived allocator, not
        // the arena, so they need freeing explicitly. Detailed grid output was
        // handed to us with a destructor, so it goes back the same way.
        for (self.nodes.items) |node| {
            node.children.deinit(self.allocator);
            node.hoisted.deinit(self.allocator);
            if (node.detailed) |info| {
                if (node.detailed_deinit) |release| release(info, self.allocator);
            }
        }
        self.scratch.deinit();
        self.arena.deinit();
        self.nodes.deinit(self.allocator);
    }

    pub fn newLeaf(self: *CustomTree, node_style: style.Style) Error!NodeId {
        const node = try self.arena.allocator().create(CustomNode);
        node.* = .{ .style = node_style };
        try self.nodes.append(self.allocator, node);
        return @intCast(self.nodes.items.len - 1);
    }

    pub fn addChild(self: *CustomTree, parent: NodeId, child: NodeId) Error!void {
        try self.at(parent).children.append(self.allocator, child);
    }

    pub fn setChildren(self: *CustomTree, parent: NodeId, children: []const NodeId) Error!void {
        const node = self.at(parent);
        node.children.clearRetainingCapacity();
        try node.children.appendSlice(self.allocator, children);
    }

    fn at(self: *CustomTree, id: NodeId) *CustomNode {
        return self.nodes.items[id];
    }

    fn atConst(self: *const CustomTree, id: NodeId) *const CustomNode {
        return self.nodes.items[id];
    }

    // -- LayoutTree ------------------------------------------------------

    pub fn child_count(self: *const CustomTree, id: NodeId) Error!usize {
        return self.atConst(id).children.items.len;
    }

    pub fn child_at(self: *const CustomTree, id: NodeId, index: usize) Error!NodeId {
        const children = self.atConst(id).children.items;
        if (index >= children.len) return error.ChildIndexOutOfBounds;
        return children[index];
    }

    pub fn child_ids(self: *const CustomTree, id: NodeId) Error![]const NodeId {
        return self.atConst(id).children.items;
    }

    pub fn scratch_allocator(self: *CustomTree) std.mem.Allocator {
        return self.scratch.allocator();
    }

    pub fn begin_layout_pass(self: *CustomTree) void {
        if (self.in_pass) return;
        _ = self.scratch.reset(.retain_capacity);
        self.in_pass = true;
    }

    pub fn end_layout_pass(self: *CustomTree) void {
        if (!self.in_pass) return;
        self.in_pass = false;
    }

    pub fn get_style(self: *const CustomTree, id: NodeId) *const style.Style {
        return &self.atConst(id).style;
    }

    /// This host has no expression engine, so it fails loudly rather than
    /// inventing a plausible number.
    pub fn calc(self: *const CustomTree, value: ?*const anyopaque, basis: f32) ?f32 {
        _ = self;
        _ = value;
        _ = basis;
        return null;
    }

    pub fn compute_child_layout(self: *CustomTree, id: NodeId, input: LayoutInput) Error!LayoutOutput {
        return compute.compute_cached_layout(CustomTree, self, id, input);
    }

    pub fn compute_leaf_layout(self: *CustomTree, id: NodeId, input: LayoutInput) Error!LayoutOutput {
        // No measure callback on this host, so the leaf reduces to its
        // intrinsic size.
        return compute.leaf_layout_with_measure(id, input, self.get_style(id), null, null);
    }

    pub fn cache_get(self: *CustomTree, id: NodeId, input: *const LayoutInput) ?LayoutOutput {
        const node_data = self.at(id);
        var output = node_data.cache.get(input.*) orelse return null;
        if (input.run_mode == .perform_layout and node_data.cached_oof_candidates.len != 0) {
            var candidates: layout.OofCandidates = .empty;
            candidates.appendSlice(self.scratch_allocator(), node_data.cached_oof_candidates) catch return null;
            output.oof_candidates = candidates;
        }
        return output;
    }

    pub fn cache_store(self: *CustomTree, id: NodeId, input: *const LayoutInput, output: LayoutOutput) Error!void {
        const node_data = self.at(id);
        if (input.run_mode == .perform_layout) {
            node_data.cached_oof_candidates = try self.arena.allocator().dupe(layout.OofCandidate, output.oof_candidates.items);
        }
        node_data.cache.store(input.*, output);
    }

    pub fn cache_clear(self: *CustomTree, id: NodeId) Error!void {
        _ = self.at(id).cache.clear();
    }

    pub fn set_unrounded_layout(self: *CustomTree, id: NodeId, value: Layout) Error!void {
        self.at(id).unrounded = value;
    }

    pub fn unrounded_layout(self: *const CustomTree, id: NodeId) Error!Layout {
        return self.atConst(id).unrounded;
    }

    pub fn set_final_layout(self: *CustomTree, id: NodeId, value: Layout) Error!void {
        self.at(id).final = value;
    }

    pub fn is_out_of_flow(self: *const CustomTree, id: NodeId) bool {
        const node_style = self.atConst(id).style;
        return node_style.position.is_out_of_flow() and node_style.display != .none;
    }

    pub fn clear_hoisted_children(self: *CustomTree, id: NodeId) Error!void {
        self.at(id).hoisted.clearRetainingCapacity();
    }

    pub fn add_hoisted_children(self: *CustomTree, id: NodeId, hoisted: []const NodeId) Error!void {
        try self.at(id).hoisted.appendSlice(self.allocator, hoisted);
    }

    pub fn hoisted_child_count(self: *const CustomTree, id: NodeId) Error!usize {
        return self.atConst(id).hoisted.items.len;
    }

    pub fn get_hoisted_child_id(self: *const CustomTree, id: NodeId, index: usize) Error!NodeId {
        const hoisted = self.atConst(id).hoisted.items;
        if (index >= hoisted.len) return error.ChildIndexOutOfBounds;
        return hoisted[index];
    }

    pub fn get_detailed_layout_info(self: *const CustomTree, id: NodeId) ?*const anyopaque {
        return self.atConst(id).detailed;
    }

    pub fn clear_detailed_layout_info(self: *CustomTree, id: NodeId) Error!void {
        const node = self.at(id);
        if (node.detailed) |existing| {
            if (node.detailed_deinit) |release| release(existing, self.allocator);
        }
        node.detailed = null;
        node.detailed_deinit = null;
    }

    pub fn set_detailed_layout_info(self: *CustomTree, id: NodeId, info: *const anyopaque, deinit_fn: *const fn (*const anyopaque, std.mem.Allocator) void) Error!void {
        const node = self.at(id);
        if (node.detailed) |existing| {
            if (node.detailed_deinit) |release| release(existing, self.allocator);
        }
        node.detailed = info;
        node.detailed_deinit = deinit_fn;
    }

    /// Top-level entry, mirroring `Tree.compute_layout`.
    pub fn compute_layout(self: *CustomTree, id: NodeId, space: geometry.Size(AvailableSpace)) Error!void {
        _ = try compute.compute_root_layout(CustomTree, self, id, space);
        try compute.round_layout(CustomTree, self, id);
    }
};

/// One handle so a single builder can drive either host.
const Host = union(enum) {
    port: *tree.Tree,
    custom: *CustomTree,

    fn leaf(self: Host, node_style: style.Style) HostError!NodeId {
        return switch (self) {
            .port => |t| t.new_leaf(node_style),
            .custom => |t| t.newLeaf(node_style),
        };
    }

    fn children(self: Host, parent: NodeId, child_ids: []const NodeId) HostError!void {
        switch (self) {
            .port => |t| try t.set_children(parent, child_ids),
            .custom => |t| try t.setChildren(parent, child_ids),
        }
    }
};

// ---------------------------------------------------------------------------
// Scenarios
//
// Ids are returned positionally so the two hosts index identically. Slice-typed
// style fields point at arrays that outlive the layout call by construction:
// the arrays are declared `const` at file scope.
// ---------------------------------------------------------------------------

const flex_columns = [_]Grid.GridTemplateComponent{
    .{ .single = Grid.TrackSizingFunction.from_length(100) },
    .{ .single = Grid.TrackSizingFunction.from_fr(1) },
};

const flex_rows = [_]Grid.GridTemplateComponent{
    .{ .single = Grid.TrackSizingFunction.from_length(40) },
    .{ .single = .{ .min = .auto, .max = .auto } },
};

const grid_column_names = [_]Grid.GridTemplateLineNames{&.{"left"}, &.{"right"}};
const grid_body_line = [_][]const u8{"body"};

const Built = struct {
    root: NodeId,
    /// Ids in creation order. Inline rather than heap-allocated so the values
    /// outlive the builder without the test having to own an allocator.
    ids: [5]NodeId = undefined,
    count: usize,
};

/// Flex: grow, fixed and shrink items plus a gap, so base size, grow and shrink
/// resolution all run.
fn buildFlex(host: Host) HostError!Built {
    const grow = try host.leaf(.{
        .display = .flex,
        .size = .{ .width = .length(50), .height = .auto },
        .flex_grow = 1,
    });
    const fixed = try host.leaf(.{
        .display = .flex,
        .size = .{ .width = .length(80), .height = .length(20) },
    });
    const shrink = try host.leaf(.{
        .display = .flex,
        .size = .{ .width = .length(200), .height = .auto },
        .flex_shrink = 1,
        .padding = .{
            .left = .length(5),
            .right = .length(5),
            .top = .length(3),
            .bottom = .length(3),
        },
    });
    const root = try host.leaf(.{
        .display = .flex,
        .flex_direction = .row,
        .size = .{ .width = .length(400), .height = .length(100) },
        .gap = .{ .width = .length(10), .height = .length(10) },
    });
    try host.children(root, &.{ grow, fixed, shrink });
    return .{ .root = root, .ids = .{ grow, fixed, shrink, root, undefined }, .count = 4 };
}

/// Grid: fixed + fr columns over a fixed and an auto row, with explicit,
/// line-named and auto placement.
fn buildGrid(host: Host) HostError!Built {
    const a = try host.leaf(.{
        .display = .grid,
        .grid_column = .{ .start = Grid.GridPlacement.from_line_index(1), .end = Grid.GridPlacement.auto },
        .grid_row = .{ .start = Grid.GridPlacement.from_line_index(1), .end = Grid.GridPlacement.auto },
        .padding = .{ .left = .length(4), .right = .length(4), .top = .length(2), .bottom = .length(2) },
    });
    const b = try host.leaf(.{
        .display = .grid,
        .grid_column = .{ .start = .{ .line = 2 }, .end = .{ .line = 3 } },
        .aspect_ratio = 2,
    });
    const c = try host.leaf(.{
        .display = .grid,
        .grid_column = .{ .start = Grid.GridPlacement.from_named_line("body", -1), .end = Grid.GridPlacement.auto },
        .grid_row = .{ .start = Grid.GridPlacement.auto, .end = Grid.GridPlacement.auto },
    });
    const root = try host.leaf(.{
        .display = .grid,
        .grid_template_columns = &flex_columns,
        .grid_template_rows = &flex_rows,
        .grid_template_column_names = &grid_column_names,
        .grid_auto_flow = .column,
        .padding = .{ .left = .length(3), .right = .length(3), .top = .length(6), .bottom = .length(6) },
    });
    _ = &grid_body_line;
    try host.children(root, &.{ a, b, c });
    return .{ .root = root, .ids = .{ a, b, c, root, undefined }, .count = 4 };
}

/// Block: nested blocks with collapsing margins, plus an `absolute` child
/// pinned to the padding box so out-of-flow hoisting and the final positioning
/// pass also run against the custom host.
fn buildBlock(host: Host) HostError!Built {
    const leaf = try host.leaf(.{
        .display = .block,
        .size = .{ .width = .length(30), .height = .length(12) },
    });
    const abs = try host.leaf(.{
        .display = .block,
        .position = .absolute,
        .inset = .{
            .left = .length(5),
            .top = .percent(0.25),
            .right = .length(5),
            .bottom = .length(5),
        },
        .size = .{ .width = .length(40), .height = .length(10) },
    });
    const inner = try host.leaf(.{
        .display = .block,
        .margin = .{ .left = .length(0), .right = .length(0), .top = .length(8), .bottom = .length(8) },
        .padding = .{ .left = .length(2), .right = .length(2), .top = .length(0), .bottom = .length(0) },
    });
    const middle = try host.leaf(.{
        .display = .block,
        .margin = .{ .left = .length(0), .right = .length(0), .top = .length(4), .bottom = .length(0) },
    });
    const root = try host.leaf(.{
        .display = .block,
        .size = .{ .width = .length(300), .height = .length(200) },
        .padding = .{ .left = .length(10), .right = .length(0), .top = .length(10), .bottom = .length(0) },
        .border = .{ .left = .length(2), .right = .length(0), .top = .length(1), .bottom = .length(1) },
    });
    try host.children(inner, &.{ leaf, abs });
    try host.children(middle, &.{inner});
    // `inner` is `position: static`, so it does not establish a containing
    // block: the `absolute` child hoists past it and lands on the root, which
    // is what exercises the final positioning pass.
    try host.children(root, &.{middle});
    return .{ .root = root, .ids = .{ leaf, abs, inner, middle, root }, .count = 5 };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "custom LayoutTree host lays out flex, grid and block identically to Tree" {
    var port = tree.Tree.init(testing.allocator);
    defer port.deinit();
    var custom = CustomTree.init(testing.allocator);
    defer custom.deinit();

    // Flex.
    {
        const a = try buildFlex(.{ .port = &port });
        const b = try buildFlex(.{ .custom = &custom });
        const space: geometry.Size(AvailableSpace) = .{ .width = .{ .definite = 400 }, .height = .{ .definite = 100 } };
        try expectIdentical(&port, &custom, a, b, space);
    }

    // Grid.
    {
        const a = try buildGrid(.{ .port = &port });
        const b = try buildGrid(.{ .custom = &custom });
        const space: geometry.Size(AvailableSpace) = .{ .width = .{ .definite = 300 }, .height = .{ .max_content = {} } };
        try expectIdentical(&port, &custom, a, b, space);
    }

    // Block + out-of-flow.
    {
        const a = try buildBlock(.{ .port = &port });
        const b = try buildBlock(.{ .custom = &custom });
        const space: geometry.Size(AvailableSpace) = .{ .width = .{ .definite = 300 }, .height = .{ .definite = 200 } };
        try expectIdentical(&port, &custom, a, b, space);
    }
}

test "custom host records out-of-flow hoisting the same way Tree does" {
    var port = tree.Tree.init(testing.allocator);
    defer port.deinit();
    var custom = CustomTree.init(testing.allocator);
    defer custom.deinit();

    const a = try buildBlock(.{ .port = &port });
    const b = try buildBlock(.{ .custom = &custom });
    const space: geometry.Size(AvailableSpace) = .{ .width = .{ .definite = 300 }, .height = .{ .definite = 200 } };
    try port.compute_layout(a.root, space);
    try custom.compute_layout(b.root, space);

    // The root is the nearest containing block for the `absolute` child, so the
    // hoisted list must be identical between the hosts.
    const port_hoisted = try port.hoisted_child_count(a.root);
    const custom_hoisted = try custom.hoisted_child_count(b.root);
    try testing.expectEqual(@as(usize, 1), custom_hoisted);
    try testing.expectEqual(port_hoisted, custom_hoisted);

    // The static `inner` must not have claimed it.
    try testing.expectEqual(@as(usize, 0), try custom.hoisted_child_count(b.ids[2]));

    for (0..port_hoisted) |index| {
        const port_id = try port.get_hoisted_child_id(a.root, index);
        const custom_id = try custom.get_hoisted_child_id(b.root, index);
        try expectLayoutEqual(try port.layout_of(port_id), custom.atConst(custom_id).final);
    }
}

test "custom host satisfies LayoutTree and declines calc explicitly" {
    var custom = CustomTree.init(testing.allocator);
    defer custom.deinit();

    // The interface is satisfiable by a type that shares nothing with `Tree`.
    comptime {
        _ = interfaces.LayoutTree(CustomTree);
    }

    const node = try custom.newLeaf(.{ .display = .block });
    try testing.expectEqual(@as(?f32, null), custom.calc(null, 100));
    try testing.expectEqual(@as(f32, 0), (try custom.unrounded_layout(node)).size.height);
    try testing.expectEqual(@as(usize, 0), try custom.child_count(node));
}

// ---------------------------------------------------------------------------
// Comparison helpers
// ---------------------------------------------------------------------------

fn expectIdentical(
    port: *tree.Tree,
    custom: *CustomTree,
    a: Built,
    b: Built,
    space: geometry.Size(AvailableSpace),
) !void {
    try port.compute_layout(a.root, space);
    try custom.compute_layout(b.root, space);

    // Root plus every node created for the scenario, compared pairwise.
    for (a.ids[0..a.count], b.ids[0..b.count]) |port_id, custom_id| {
        try expectLayoutEqual(try port.layout_of(port_id), custom.atConst(custom_id).final);
    }
}

fn expectLayoutEqual(expected: Layout, actual: Layout) !void {
    try testing.expectEqual(expected.location.x, actual.location.x);
    try testing.expectEqual(expected.location.y, actual.location.y);
    try testing.expectEqual(expected.size.width, actual.size.width);
    try testing.expectEqual(expected.size.height, actual.size.height);
    try testing.expectEqual(expected.margin, actual.margin);
    try testing.expectEqual(expected.padding, actual.padding);
    try testing.expectEqual(expected.border, actual.border);
}