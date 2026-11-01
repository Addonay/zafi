//! Direct port of Taffy's `compute/common/sizing_keyword.rs`.

const AvailableSpace = @import("../../style/available_space.zig").AvailableSpace;
const dimension = @import("../../style/dimension.zig");
const geometry = @import("../../geometry.zig");
const NodeId = @import("../../tree/node.zig").NodeId;
const layout = @import("../../tree/layout.zig");
const LayoutTree = @import("../../tree/interfaces.zig").LayoutTree;

pub const SizingKeywordResolution = union(enum) {
    measure: AvailableSpace,
    exact: f32,
};

/// Resolve one sizing keyword. A non-keyword returns `null`, and a keyword
/// whose required basis is indefinite also returns `null`, which means the
/// caller treats it as `auto`, matching Taffy's behavior.
pub fn resolve_sizing_keyword(value: dimension.Dimension, stretch_size: ?f32, percent_basis: ?f32) ?SizingKeywordResolution {
    return switch (value.value.tag()) {
        .min_content => .{ .measure = .min_content },
        .max_content => .{ .measure = .max_content },
        .fit_content_px => .{ .measure = .{ .definite = value.value.value() } },
        .fit_content_percent => if (percent_basis) |basis| .{ .measure = .{ .definite = basis * value.value.value() } } else null,
        .fit_content_keyword => if (stretch_size) |size| .{ .measure = .{ .definite = size } } else null,
        // fit-content(calc()): the limit resolves through the host's calc resolver.
        .fit_content_calc => if (percent_basis) |basis| .{ .measure = .{ .definite = @import("../../style/calc.zig").resolve(value.value.calc_value(), basis) } } else null,
        .stretch => if (stretch_size) |size| .{ .exact = size } else null,
        else => null,
    };
}

pub fn is_intrinsic(value: dimension.Dimension) bool {
    return switch (value.value.tag()) {
        .min_content, .max_content, .fit_content_keyword, .fit_content_px, .fit_content_percent, .fit_content_calc, .stretch, .content => true,
        else => false,
    };
}

/// Resolve the sizing keywords (`min-content`, `max-content`, `fit-content`,
/// `fit-content(...)`, and `stretch`) on the size styles of an absolutely
/// positioned item, filling in the corresponding `known_dimensions` axes.
///
///   - `area_size` is the size of the item's containing block (which insets and
///     percentages resolve against).
///   - The stretch size in each axis is the containing block minus the item's
///     insets and margins in that axis.
///
/// Measurement-backed keywords call back into the tree's measure path, so a
/// measured item (text, replaced content) is sized against the keyword's
/// available_space space rather than against the definite containing-block size.
pub fn resolve_absolute_sizing_keywords(comptime Tree: type, tree_ref: *Tree,
    node: NodeId,
    known_dimensions: *geometry.Size(?f32),
    size_style: geometry.Size(dimension.Dimension),
    area_size: geometry.Size(f32),
    inset: geometry.Rect(?f32),
    margin: geometry.Rect(?f32),
    sizing_mode: layout.SizingMode) !void {
    const stretch_width = @max(area_size.width - (inset.left orelse 0) - (inset.right orelse 0) - (margin.left orelse 0) - (margin.right orelse 0), 0);
    const stretch_height = @max(area_size.height - (inset.top orelse 0) - (inset.bottom orelse 0) - (margin.top orelse 0) - (margin.bottom orelse 0), 0);

    const keyword_width: ?SizingKeywordResolution = if (known_dimensions.width == null)
        resolve_sizing_keyword(size_style.width, stretch_width, area_size.width)
    else
        null;
    const keyword_height: ?SizingKeywordResolution = if (known_dimensions.height == null)
        resolve_sizing_keyword(size_style.height, stretch_height, area_size.height)
    else
        null;

    const to_optional = geometry.Size(?f32){ .width = area_size.width, .height = area_size.height };
    const line_false = geometry.Line(bool){ .start = false, .end = false };

    // If both axes need to be measured then resolve them with a single measure call
    if (keyword_width) |width_resolution| {
        if (keyword_height) |height_resolution| {
            switch (width_resolution) {
                .measure => |available_width| switch (height_resolution) {
                    .measure => |available_height| {
                        const measured_size = try LayoutTree(Tree).measure_child_size_both(tree_ref,
                            node,
                            .{ .width = null, .height = null },
                            to_optional,
                            .{ .width = available_width, .height = available_height },
                            sizing_mode,
                            line_false);
                        known_dimensions.* = .{ .width = measured_size.width, .height = measured_size.height };
                        return;
                    },
                    // Only the width is measurement-backed: fall through to the
                    // per-axis path below so the height keyword is still applied.
                    .exact => {},
                },
                .exact => {},
            }
        }
    }

    const TreeApi = LayoutTree(Tree);
    if (keyword_width) |resolution| {
        known_dimensions.width = switch (resolution) {
            .exact => |width| width,
            .measure => |available_width| try TreeApi.measure_child_size(tree_ref,
                node,
                known_dimensions.*,
                to_optional,
                .{ .width = available_width, .height = .{ .definite = stretch_height } },
                sizing_mode,
                .horizontal,
                line_false),
        };
    }
    if (keyword_height) |resolution| {
        known_dimensions.height = switch (resolution) {
            .exact => |height| height,
            .measure => |available_height| try TreeApi.measure_child_size(tree_ref, 
                node,
                known_dimensions.*,
                to_optional,
                .{
                    .width = if (known_dimensions.width) |width| .{ .definite = width } else .{ .definite = stretch_width },
                    .height = available_height,
                },
                sizing_mode,
                .vertical,
                line_false),
        };
    }
}
