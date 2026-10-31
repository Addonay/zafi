//! Taffy `src/test.rs` porting workspace.
//!
//! Taffy's shared measurement utilities used by hand-written and fixture tests.

pub const fixture_tolerance: f32 = 0.1;

const geometry = @import("geometry.zig");
const AvailableSpace = @import("style/available_space.zig").AvailableSpace;
const style = @import("style/root.zig");
const layout = @import("tree/layout.zig");
const node = @import("tree/node.zig");
const leaf = @import("compute/leaf.zig");
const std = @import("std");

const LayoutInput = layout.LayoutInput;
const LayoutOutput = layout.LayoutOutput;
const NodeId = node.NodeId;
const Style = style.Style;
const compute_leaf_layout = leaf.compute_leaf_layout;

pub fn roughly_equal(expected: f32, actual: f32) bool {
    return @abs(expected - actual) < fixture_tolerance;
}

pub const WritingMode = enum { horizontal, vertical };
pub const AspectRatioMeasureData = struct {
    width: f32,
    height_ratio: f32,

    pub fn measure(self: AspectRatioMeasureData, known: geometry.Size(?f32)) geometry.Size(f32) {
        const width = known.width orelse self.width;
        const height = known.height orelse width * self.height_ratio;
        return .{ .width = width, .height = height };
    }
};

pub const AhemTextMeasureData = struct {
    text: []const u8,
    writing_mode: WritingMode = .horizontal,

    pub fn measure(self: AhemTextMeasureData, known: geometry.Size(?f32), space: geometry.Size(AvailableSpace)) geometry.Size(f32) {
        const inline_axis = if (self.writing_mode == .horizontal) geometry.AbsoluteAxis.horizontal else geometry.AbsoluteAxis.vertical;
        const block_axis = inline_axis.other_axis();
        // Taffy's Ahem fixture font measures one ASCII codepoint as a 10px
        // advance and splits text on U+200B (ZWS) wrapping opportunities.
        // This mirrors `AhemTextMeasureData::measure` in `src/test.rs` exactly,
        // including the per-line wrap accumulation below.
        const zws = "\xE2\x80\x8B";
        var min_line_length: usize = 0;
        var max_line_length: usize = 0;
        var start: usize = 0;
        while (true) {
            const rest = self.text[start..];
            const delimiter = std.mem.indexOf(u8, rest, zws);
            const line = if (delimiter) |offset| rest[0..offset] else rest;
            min_line_length = @max(min_line_length, line.len);
            max_line_length += line.len;
            if (delimiter) |offset| start += offset + zws.len else break;
        }
        const inline_known = known.get_abs(inline_axis);
        const inline_space = switch (space.get_abs(inline_axis)) {
            .min_content => @as(f32, @floatFromInt(min_line_length)) * 10,
            .max_content => @as(f32, @floatFromInt(max_line_length)) * 10,
            .definite => |value| @min(value, @as(f32, @floatFromInt(max_line_length)) * 10),
        };
        const inline_size = @max(inline_known orelse inline_space, @as(f32, @floatFromInt(min_line_length)) * 10);
        const block_size = known.get_abs(block_axis) orelse blk: {
            const inline_line_length_float = @floor(inline_size / 10);
            const inline_line_length: usize = if (inline_line_length_float <= 0) 0 else @intFromFloat(inline_line_length_float);
            var line_count: usize = 1;
            var current_line_length: usize = 0;
            var line_start: usize = 0;
            while (true) {
                const rest = self.text[line_start..];
                const delimiter = std.mem.indexOf(u8, rest, zws);
                const line = if (delimiter) |offset| rest[0..offset] else rest;
                if (current_line_length + line.len > inline_line_length) {
                    if (current_line_length > 0) line_count += 1;
                    current_line_length = line.len;
                } else {
                    current_line_length += line.len;
                }
                if (delimiter) |offset| line_start += offset + zws.len else break;
            }
            break :blk @as(f32, @floatFromInt(line_count)) * 10;
        };
        return if (self.writing_mode == .horizontal) .{ .width = inline_size, .height = block_size } else .{ .width = block_size, .height = inline_size };
    }
};

pub const TestMeasureData = union(enum) {
    zero,
    fixed: geometry.Size(f32),
    aspect_ratio: AspectRatioMeasureData,
    ahem_text: AhemTextMeasureData,
};

pub const TestNodeContext = struct {
    count: usize = 0,
    measure_data: TestMeasureData = .zero,

    pub fn new(measure_data: TestMeasureData) TestNodeContext {
        return .{ .measure_data = measure_data };
    }
    pub fn zero() TestNodeContext {
        return new(.zero);
    }
    pub fn fixed(size: geometry.Size(f32)) TestNodeContext {
        return new(.{ .fixed = size });
    }
    pub fn aspect_ratio(width: f32, height_ratio: f32) TestNodeContext {
        return new(.{ .aspect_ratio = .{ .width = width, .height_ratio = height_ratio } });
    }
    pub fn ahem_text(text: []const u8, writing_mode: WritingMode) TestNodeContext {
        return new(.{ .ahem_text = .{ .text = text, .writing_mode = writing_mode } });
    }
};

/// Taffy `src/test.rs` measure function: returns a size directly.
pub fn test_measure_function(context_pointer: ?*anyopaque, known_dimensions: geometry.Size(?f32), available_space: geometry.Size(AvailableSpace)) geometry.Size(f32) {
    if (known_dimensions.width != null and known_dimensions.height != null) return .{ .width = known_dimensions.width.?, .height = known_dimensions.height.? };
    const context = if (context_pointer) |pointer| @as(*TestNodeContext, @ptrCast(@alignCast(pointer))) else return .{ .width = known_dimensions.width orelse 0, .height = known_dimensions.height orelse 0 };
    context.count += 1;
    const measured = switch (context.measure_data) {
        .zero => geometry.F32Size{ .width = 0, .height = 0 },
        .fixed => |size| size,
        .aspect_ratio => |data| data.measure(known_dimensions),
        .ahem_text => |data| data.measure(known_dimensions, available_space),
    };
    return .{ .width = known_dimensions.width orelse measured.width, .height = known_dimensions.height orelse measured.height };
}

/// The `tests/common` measure callback used by Taffy's XML fixtures: route
/// through `compute_leaf_layout` so padding, aspect ratio, content-size rects
/// and the sizing-mode rules are applied exactly like production leaves.
pub fn fixture_measure_function(context_pointer: ?*anyopaque, inputs: LayoutInput, node_id: NodeId, node_style: *const Style) LayoutOutput {
    _ = node_id;
    return compute_leaf_layout(inputs, node_style, context_pointer, test_measure_function);
}

test "shared test measurement contexts preserve intrinsic and known dimensions" {
    const testing = std.testing;
    var context = TestNodeContext.fixed(.{ .width = 30, .height = 12 });
    const context_ptr: *anyopaque = @ptrCast(&context);
    const measured = test_measure_function(context_ptr, .{ .width = null, .height = null }, .{ .width = .max_content, .height = .max_content });
    try testing.expectEqual(@as(f32, 30), measured.width);
    try testing.expectEqual(@as(f32, 12), measured.height);
    try testing.expectEqual(@as(usize, 1), context.count);
    const known = test_measure_function(context_ptr, .{ .width = 7, .height = 8 }, .{ .width = .max_content, .height = .max_content });
    try testing.expectEqual(@as(f32, 7), known.width);
    try testing.expectEqual(@as(f32, 8), known.height);
    try testing.expectEqual(@as(usize, 1), context.count);
}
