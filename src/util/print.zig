//! Writer-based tree printer, ported from Taffy's `util/print.rs`.
//!
//! There is a single traversal here; `Tree.print_tree` delegates to it so
//! the debug format (including hierarchy indentation and cycle/depth guarding)
//! has exactly one implementation.

const tree = @import("../tree/tree.zig");
const node = @import("../tree/node.zig");
const std = @import("std");

/// Maximum depth printed before the traversal stops descending. A valid tree is
/// acyclic by construction, but the guard keeps a debug dump bounded if a caller
/// reaches this through the low-level node accessors.
pub const max_print_depth: usize = 256;

pub fn format_node(writer: anytype, node_id: tree.NodeId, layout: anytype) !void {
    try writer.print("{d}: x={d} y={d} w={d} h={d}", .{ node.indexOf(node_id), layout.location.x, layout.location.y, layout.size.width, layout.size.height });
}

pub fn write_tree(writer: anytype, tree_ref: *const tree.Tree, root: tree.NodeId) !void {
    try writer.writeAll("TREE\n");
    try write_node(writer, tree_ref, root, "", false, 0);
}

pub fn write_node(writer: anytype, tree_ref: *const tree.Tree, node_id: tree.NodeId, prefix: []const u8, has_sibling: bool, depth: usize) !void {
    if (depth > max_print_depth) return;
    const node_layout = tree_ref.layout_of(node_id) catch return;
    const label = if (has_sibling) "├── " else "└── ";
    try writer.print("{s}{s}{d}: x={d} y={d} w={d} h={d}\n", .{ prefix, label, node.indexOf(node_id), node_layout.location.x, node_layout.location.y, node_layout.size.width, node_layout.size.height });
    const child_ids = tree_ref.children(node_id) catch return;
    // The child's own prefix extends the parent's with the connector segment, so
    // nested levels indent under their parent instead of staying flush left.
    const child_prefix = extendPrefix(prefix, has_sibling) orelse prefix;
    for (child_ids, 0..) |child_id, index| {
        try write_node(writer, tree_ref, child_id, child_prefix, index + 1 < child_ids.len, depth + 1);
    }
}

/// Deepest prefix the fixed buffer below can hold; beyond `max_print_depth` the
/// traversal stops descending, so the prefix can never exceed it.
const max_prefix_len: usize = max_print_depth * 4 + 4;

fn extendPrefix(prefix: []const u8, has_sibling: bool) ?[]const u8 {
    // A single shared buffer is enough: the recursive caller consumes the value
    // before descending further, and each level's own buffer is a distinct
    // frame-local slice.
    var storage: [max_prefix_len]u8 = undefined;
    const needed = prefix.len + 4;
    if (needed > storage.len) return null;
    @memcpy(storage[0..prefix.len], prefix);
    @memcpy(storage[prefix.len..needed], if (has_sibling) "│   " else "    ");
    return storage[0..needed];
}

pub fn print_tree(tree_ref: *const tree.Tree, root: tree.NodeId) void {
    std.debug.print("TREE\n", .{});
    print_node_debug(tree_ref, root, "", false, 0);
}

fn print_node_debug(tree_ref: *const tree.Tree, node_id: tree.NodeId, prefix: []const u8, has_sibling: bool, depth: usize) void {
    if (depth > max_print_depth) return;
    const node_layout = tree_ref.layout_of(node_id) catch return;
    std.debug.print("{s}{s}{d}: x={d} y={d} w={d} h={d}\n", .{ prefix, if (has_sibling) "├── " else "└── ", node.indexOf(node_id), node_layout.location.x, node_layout.location.y, node_layout.size.width, node_layout.size.height });
    const child_ids = tree_ref.children(node_id) catch return;
    var child_storage: [max_prefix_len]u8 = undefined;
    const child_prefix = blk: {
        const needed = prefix.len + 4;
        if (needed > child_storage.len) break :blk prefix;
        @memcpy(child_storage[0..prefix.len], prefix);
        @memcpy(child_storage[prefix.len..needed], if (has_sibling) "│   " else "    ");
        break :blk child_storage[0..needed];
    };
    for (child_ids, 0..) |child_id, index| print_node_debug(tree_ref, child_id, child_prefix, index + 1 < child_ids.len, depth + 1);
}
