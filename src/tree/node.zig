//! Generational node identity, matching Taffy's `slotmap::DefaultKey`-backed
//! `NodeId`.
//!
//! A `NodeId` packs a slot index and a generation counter into a single `u64`,
//! using the same 24-bit index / 40-bit generation split as `slotmap`:
//!
//! ```text
//!  63                    24 23                    0
//! ┌────────────────────────┬────────────────────────┐
//! │      generation        │         index          │
//! └────────────────────────┴────────────────────────┘
//! ```
//!
//! The generation is bumped every time a slot is recycled, so an id held across
//! a `remove`/`clear` never resolves to a different node: stale ids fail every
//! lookup instead of silently aliasing a new node. Node indices are dense into
//! one slot array (see `tree_mod.NodeStore`): identity comes from the id, never
//! from a `NodeData` address.

/// Slot index bit width (2^24 = 16,777,216 slots).
pub const index_bits: u6 = 24;
pub const generation_bits: u6 = 40;
pub const max_index: u32 = (@as(u32, 1) << index_bits) - 1;

/// Stable generational handle into a `Tree`.
pub const NodeId = u64;

/// Largest representable generation counter.
pub const max_generation: u64 = (@as(u64, 1) << generation_bits) - 1;

/// Slot index of `id`.
pub inline fn indexOf(id: NodeId) u32 {
    return @truncate(id & max_index);
}

/// Generation counter of `id`.
pub inline fn generationOf(id: NodeId) u40 {
    return @truncate(id >> index_bits);
}

/// Build a `NodeId` from a slot index and generation counter.
///
/// Returns null when `generation` exceeds `max_generation` (only reachable
/// after 2^40 reuses of a single slot), which the tree surfaces as
/// `error.NodeIdExhausted` rather than silently aliasing an older node.
pub inline fn fromParts(index: u32, generation: u40) ?NodeId {
    if (index > max_index) return null;
    if (@as(u64, generation) > max_generation) return null;
    return (@as(u64, generation) << index_bits) | @as(u64, index);
}

/// Convenience constructor for call sites which know the index fits.
pub inline fn node_id(value: u32) NodeId {
    return @as(NodeId, value);
}

/// Convenience constructor mirroring Taffy's `NodeId::from(raw)` conversions.
pub inline fn node_id_from(value: anytype) NodeId {
    return @intCast(value);
}

test "node ids carry a slot index and generation" {
    const testing = @import("std").testing;
    const id = fromParts(1234, 7).?;
    try testing.expectEqual(@as(u32, 1234), indexOf(id));
    try testing.expectEqual(@as(u40, 7), generationOf(id));
    try testing.expectEqual(@as(NodeId, 1234), node_id(1234));
    try testing.expect(fromParts(max_index + 1, 0) == null);
}
