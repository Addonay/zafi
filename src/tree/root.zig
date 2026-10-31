//! Tree module root: node storage, styles, layouts, the cache and the
//! `LayoutTree` contract the compute algorithms are generic over.

pub const cache = @import("cache.zig");
pub const interfaces = @import("interfaces.zig");
pub const layout = @import("layout.zig");
pub const node = @import("node.zig");
pub const tree = @import("tree.zig");

pub const Cache = cache.Cache;
pub const ClearState = cache.ClearState;
pub const Layout = layout.Layout;
pub const LayoutInput = layout.LayoutInput;
pub const LayoutOutput = layout.LayoutOutput;
pub const NodeId = node.NodeId;
pub const NodeData = node.NodeData;
pub const NodeStore = node.NodeStore;
pub const Tree = tree.Tree;
pub const TreeConfig = tree.TreeConfig;
pub const TreeError = tree.TreeError;
pub const TreeResult = tree.TreeResult;

/// The contract a host type implements to be usable as a layout tree.
pub const LayoutTree = interfaces.LayoutTree;

/// Compute-time measure callback signature.
pub const MeasureFunc = interfaces.MeasureFunc;

test {
    _ = @import("cache.zig");
    _ = @import("interfaces.zig");
    _ = @import("layout.zig");
    _ = @import("node.zig");
    _ = @import("tree.zig");
}