//! Standalone Zig port of Taffy's `src/lib.rs`.
//!
//! The source layout intentionally mirrors the Rust crate. The port keeps
//! is a literal porting workspace: comments and port-status notes stay next to the code
//! they describe, and no renderer/core types are imported here. Compilation
//! and idiomatic Zig refactoring happen only after the source topology and
//! behavior have been accounted for.

pub const geometry = @import("geometry.zig");
pub const prelude = @import("prelude.zig");
pub const style = @import("style/root.zig");
pub const style_helpers = @import("style_helpers.zig");
pub const tree = @import("tree/root.zig");
pub const compute = @import("compute/root.zig");
pub const util = @import("util/root.zig");
pub const testing = @import("test.zig");

pub const Size = geometry.Size;
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Line = geometry.Line;
pub const MinMax = geometry.MinMax;
pub const Style = style.Style;
pub const Display = style.Display;
pub const BoxSizing = style.BoxSizing;
pub const BoxGenerationMode = style.BoxGenerationMode;
pub const Position = style.Position;
pub const Overflow = style.Overflow;
pub const Direction = style.Direction;
pub const Contain = style.Contain;
pub const CoreStyle = style.CoreStyle;
pub const FlexboxContainerStyle = style.FlexboxContainerStyle;
pub const FlexboxItemStyle = style.FlexboxItemStyle;
pub const GridContainerStyle = style.GridContainerStyle;
pub const GridItemStyle = style.GridItemStyle;
pub const BlockContainerStyle = style.BlockContainerStyle;
pub const BlockItemStyle = style.BlockItemStyle;
pub const AlignContent = style.alignment.AlignContent;
pub const AlignContentKeyword = style.alignment.AlignContentKeyword;
pub const AlignItems = style.alignment.AlignItems;
pub const AlignItemsKeyword = style.alignment.AlignItemsKeyword;
pub const AlignSelf = style.alignment.AlignSelf;
pub const AlignmentSafety = style.alignment.AlignmentSafety;
pub const JustifyContent = style.alignment.JustifyContent;
pub const JustifyItems = style.alignment.JustifyItems;
pub const JustifySelf = style.alignment.JustifySelf;
pub const CompactLength = style.compact_length.CompactLength;
pub const FlexDirection = style.flex.FlexDirection;
pub const FlexWrap = style.flex.FlexWrap;
pub const GridAutoFlow = style.grid.GridAutoFlow;
pub const GridPlacement = style.grid.GridPlacement;
pub const GridTemplateComponent = style.grid.GridTemplateComponent;
pub const GridTemplateRepetition = style.grid.GridTemplateRepetition;
pub const MaxTrackSizingFunction = style.grid.MaxTrackSizingFunction;
pub const MinTrackSizingFunction = style.grid.MinTrackSizingFunction;
pub const RepetitionCount = style.grid.RepetitionCount;
pub const TrackSizingFunction = style.grid.TrackSizingFunction;
pub const Dimension = style.dimension.Dimension;
pub const LengthPercentage = style.dimension.LengthPercentage;
pub const LengthPercentageAuto = style.dimension.LengthPercentageAuto;
pub const AvailableSpace = style.available_space.AvailableSpace;
pub const Layout = tree.Layout;
pub const LayoutInput = tree.LayoutInput;
pub const LayoutOutput = tree.LayoutOutput;
pub const NodeId = tree.NodeId;
pub const Tree = tree.Tree;
pub const TreeConfig = tree.TreeConfig;
pub const Baselines = tree.layout.Baselines;
pub const CollapsibleMarginSet = tree.layout.CollapsibleMarginSet;
pub const RunMode = tree.layout.RunMode;
pub const SizingMode = tree.layout.SizingMode;
pub const RequestedAxis = tree.layout.RequestedAxis;
pub const DetailedLayoutInfo = tree.layout.DetailedLayoutInfo;
pub const Cache = tree.cache.Cache;
pub const ClearState = tree.cache.ClearState;
pub const TreeError = tree.TreeError;
pub const TreeResult = tree.TreeResult;
pub const MaybeMath = util.math.MaybeMath;
pub const GridTemplateTracks = style.grid.GridTemplateTracks;
pub const GridTemplateComponents = style.grid.GridTemplateComponents;
pub const GridAutoTracks = style.grid.GridAutoTracks;
pub const GridTemplateAreas = style.grid.GridTemplateAreas;
pub const GridTemplateLineNames = style.grid.GridTemplateLineNames;
pub const TextAlign = style.block.TextAlign;
pub const Float = style.float.Float;
pub const Clear = style.float.Clear;

pub const compute_leaf_layout = compute.leaf.compute_leaf_layout;
pub const compute_flexbox_layout = compute.flexbox.compute_flexbox_layout;
pub const compute_grid_layout = compute.grid.compute_grid_layout;
pub const compute_block_layout = compute.block.compute_block_layout;
pub const compute_block_align_content_offset = compute.block.compute_block_align_content_offset;
pub const compute_cached_layout = compute.compute_cached_layout;
pub const compute_hidden_layout = compute.compute_hidden_layout;
pub const compute_root_layout = compute.compute_root_layout;
pub const round_layout = compute.round_layout;


test {
    _ = @import("geometry.zig");
    _ = @import("style/root.zig");
    _ = @import("tree/root.zig");
    _ = @import("tree/interfaces_test.zig");
    _ = @import("compute/root.zig");
    _ = @import("util/root.zig");
    _ = @import("test.zig");
    _ = @import("scroll_tests.zig");
    // Taffy-compatible serde tests are compiled only when the optional
    // dependency is enabled (`zig build test -Dserde=true`).
    if (@import("serde_support.zig").enabled) _ = @import("serde_tests.zig");
}
