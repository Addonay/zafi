//! Taffy-compatible serde tests. Compiled only with `-Dserde=true`.
//!
//! Expected values were captured from the pinned Rust crate with the `serde`
//! feature enabled (see `audit/serde_format_rust.txt`): CompactLength wire
//! numbers, PascalCase enum names, alignment strings and grid placement
//! shapes.

const std = @import("std");
const serde = @import("serde");
const json = serde.json;

const Style = @import("style/root.zig").Style;
const Display = @import("style/root.zig").Display;
const Position = @import("style/root.zig").Position;
const BoxSizing = @import("style/root.zig").BoxSizing;
const Direction = @import("style/root.zig").Direction;
const Overflow = @import("style/root.zig").Overflow;
const Contain = @import("style/root.zig").Contain;
const dimension = @import("style/dimension.zig");
const Dimension = dimension.Dimension;
const LengthPercentage = dimension.LengthPercentage;
const LengthPercentageAuto = dimension.LengthPercentageAuto;
const alignment = @import("style/alignment.zig");
const grid = @import("style/grid.zig");
const flex = @import("style/flex.zig");
const float = @import("style/float.zig");
const block = @import("style/block.zig");

fn toJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return json.toSlice(allocator, value);
}

test "compact length wrappers serialize to Taffy wire numbers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Values captured from the Rust oracle.
    try expectSerialized(allocator, LengthPercentage.length(3.5), "5375000576");
    try expectSerialized(allocator, LengthPercentage.percent(0.25), "9638510592");
    try expectSerialized(allocator, LengthPercentageAuto.auto(), "12884901888");
    try expectSerialized(allocator, Dimension.from_length(1.0), "5360320512");
    try expectSerialized(allocator, Dimension.fit_content_px(9.0), "99875815424");
    try expectSerialized(allocator, grid.MinTrackSizingFunction.length(10.0), "5387583488");
    try expectSerialized(allocator, grid.MaxTrackSizingFunction.fr(1.0), "18245222400");
}

fn expectSerialized(allocator: std.mem.Allocator, value: anytype, expected: []const u8) !void {
    const serialized = try toJson(allocator, value);
    defer allocator.free(serialized);
    try std.testing.expectEqualStrings(expected, serialized);
}

test "compact length deserialization validates tags like Taffy" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Auto is valid for LengthPercentageAuto but rejected for LengthPercentage.
    const auto_bits = try toJson(allocator, LengthPercentageAuto.auto());
    _ = try json.fromSlice(LengthPercentageAuto, allocator, auto_bits);

    const result = json.fromSlice(LengthPercentage, allocator, auto_bits);
    try testing.expectError(error.WrongType, result);

    // Invalid tag bits (calc = 0) are rejected for every wrapper.
    const invalid = "0";
    try testing.expectError(error.WrongType, json.fromSlice(LengthPercentage, allocator, invalid));
    try testing.expectError(error.WrongType, json.fromSlice(Dimension, allocator, invalid));

    // Calc cannot be serialized faithfully: the serde.zig serializer cannot
    // carry a custom error, so it emits raw bits (0) which deserialization
    // rejects. Rust returns an error here instead (documented divergence).
    const calc = LengthPercentage.calc(@ptrFromInt(8));
    const calc_json = try toJson(allocator, calc);
    try testing.expectEqualStrings("0", calc_json);
    try testing.expectError(error.WrongType, json.fromSlice(LengthPercentage, allocator, calc_json));
}

test "style default serialization matches Taffy field shape" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const serialized = try toJson(allocator, Style{});
    defer allocator.free(serialized);

    // Spot-check the Taffy field set, order and values captured from Rust at the
    // revision named in tools/pin.env.
    try testing.expect(std.mem.startsWith(u8, serialized, "{\"dummy\":null,\"display\":\"Flex\","));
    try testing.expect(std.mem.indexOf(u8, serialized, "\"box_sizing\":\"BorderBox\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"direction\":\"Ltr\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"overflow\":{\"x\":\"Visible\",\"y\":\"Visible\"}") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"contain\":0") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"position\":\"Static\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"size\":{\"width\":12884901888,\"height\":12884901888}") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"margin\":{\"left\":4294967296,") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"aspect_ratio\":null") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"text_align\":\"Auto\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"flex_wrap\":\"NoWrap\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"grid_template_rows\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"grid_auto_flow\":\"Row\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"grid_row\":{\"start\":\"Auto\",\"end\":\"Auto\"}") != null);
    try testing.expect(std.mem.endsWith(u8, serialized, "\"grid_column\":{\"start\":\"Auto\",\"end\":\"Auto\"}}"));
}

test "style round-trips through JSON with Taffy enum spellings" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var original = Style{};
    original.display = .grid;
    original.position = .absolute;
    original.box_sizing = .content_box;
    original.direction = .rtl;
    original.overflow = .{ .x = .scroll, .y = .hidden };
    original.contain = Contain.LAYOUT.@"union"(Contain.PAINT);
    original.size.width = Dimension.percent(0.5);
    original.size.height = Dimension.length(12.5);
    original.margin.left = LengthPercentageAuto.auto();
    original.margin.right = LengthPercentageAuto.length(7.0);
    original.padding.left = LengthPercentage.length(3.5);
    original.gap.width = LengthPercentage.percent(0.25);
    original.aspect_ratio = 2.0;
    original.align_items = alignment.AlignItems.SAFE_CENTER;
    original.align_self = alignment.AlignSelf.SAFE_FLEX_END;
    original.align_content = alignment.AlignContent.SPACE_BETWEEN;
    original.justify_content = alignment.JustifyContent.SPACE_EVENLY;
    original.justify_items = alignment.JustifyItems.SELF_START;
    original.justify_self = alignment.JustifySelf.SAFE_CENTER;
    original.text_align = .legacy_center;
    original.flex_direction = .column_reverse;
    original.flex_wrap = .wrap_reverse;
    original.float = .left;
    original.clear = .both;
    original.grid_auto_flow = .column_dense;

    const serialized = try toJson(allocator, original);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"display\":\"Grid\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"box_sizing\":\"ContentBox\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"overflow\":{\"x\":\"Scroll\",\"y\":\"Hidden\"}") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"align_items\":\"SafeCenter\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"justify_self\":\"SafeCenter\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"text_align\":\"LegacyCenter\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"flex_wrap\":\"WrapReverse\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"grid_auto_flow\":\"ColumnDense\"") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "\"contain\":3") != null);

    const parsed = try json.fromSlice(Style, allocator, serialized);
    try testing.expectEqual(Display.grid, parsed.display);
    try testing.expectEqual(Position.absolute, parsed.position);
    try testing.expectEqual(BoxSizing.content_box, parsed.box_sizing);
    try testing.expectEqual(Direction.rtl, parsed.direction);
    try testing.expectEqual(Overflow.scroll, parsed.overflow.x);
    try testing.expectEqual(Overflow.hidden, parsed.overflow.y);
    try testing.expectEqual(@as(u8, 3), @as(u8, @bitCast(parsed.contain)));
    try testing.expectEqual(@as(f32, 0.5), parsed.size.width.value.value());
    try testing.expectEqual(@as(f32, 12.5), parsed.size.height.value.value());
    try testing.expect(parsed.margin.left.is_auto());
    try testing.expectEqual(@as(f32, 7.0), parsed.margin.right.value.value());
    try testing.expectEqual(@as(f32, 3.5), parsed.padding.left.value.value());
    try testing.expectEqual(@as(?f32, 2.0), parsed.aspect_ratio);
    try testing.expectEqual(alignment.AlignItemsKeyword.center, parsed.align_items.?.keyword);
    try testing.expectEqual(alignment.AlignmentSafety.safe, parsed.align_items.?.safety);
    try testing.expectEqual(alignment.AlignItemsKeyword.self_start, parsed.justify_items.?.keyword);
    try testing.expectEqual(block.TextAlign.legacy_center, parsed.text_align);
    try testing.expectEqual(flex.FlexDirection.column_reverse, parsed.flex_direction);
    try testing.expectEqual(flex.FlexWrap.wrap_reverse, parsed.flex_wrap);
    try testing.expectEqual(float.Float.left, parsed.float);
    try testing.expectEqual(float.Clear.both, parsed.clear);
    try testing.expectEqual(grid.GridAutoFlow.column_dense, parsed.grid_auto_flow);
}

test "style deserializes Taffy's Rust-generated wire format" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Captured from the tracked Rust crate (`serde_json::to_string`) with the
    // same style as the round-trip test below, at the revision named in
    // tools/pin.env. `position` serializes as `Static` there because that is
    // upstream's default; regenerate if the pin moves.
    const rust_json =
        \\{"dummy":null,"display":"Flex","item_is_table":false,"item_is_replaced":false,"box_sizing":"BorderBox","direction":"Ltr","overflow":{"x":"Visible","y":"Visible"},"scrollbar_width":0.0,"contain":0,"float":"None","clear":"None","position":"Static","inset":{"left":12884901888,"right":12884901888,"top":12884901888,"bottom":12884901888},"size":{"width":9646899200,"height":5390204928},"min_size":{"width":12884901888,"height":12884901888},"max_size":{"width":12884901888,"height":12884901888},"aspect_ratio":2.0,"margin":{"left":12884901888,"right":5383389184,"top":4294967296,"bottom":4294967296},"padding":{"left":5375000576,"right":4294967296,"top":4294967296,"bottom":4294967296},"border":{"left":4294967296,"right":4294967296,"top":4294967296,"bottom":4294967296},"align_items":null,"align_self":null,"justify_items":null,"justify_self":null,"align_content":null,"justify_content":null,"gap":{"width":9638510592,"height":4294967296},"text_align":"Auto","flex_direction":"Row","flex_wrap":"NoWrap","flex_line_count":1,"flex_basis":12884901888,"flex_grow":0.0,"flex_shrink":1.0,"grid_template_rows":[],"grid_template_columns":[],"grid_auto_rows":[],"grid_auto_columns":[],"grid_auto_flow":"Row","grid_template_areas":null,"grid_template_column_names":[],"grid_template_row_names":[],"grid_row":{"start":"Auto","end":"Auto"},"grid_column":{"start":"Auto","end":"Auto"}}
    ;
    const parsed = try json.fromSlice(Style, allocator, rust_json);
    try testing.expectEqual(Display.flex, parsed.display);
    try testing.expectEqual(Position.static, parsed.position);
    try testing.expectEqual(dimension.Dimension.percent(0.5).value.value(), parsed.size.width.value.value());
    try testing.expectEqual(@as(f32, 12.5), parsed.size.height.value.value());
    try testing.expect(parsed.margin.left.is_auto());
    try testing.expectEqual(@as(f32, 7.0), parsed.margin.right.value.value());
    try testing.expectEqual(@as(f32, 3.5), parsed.padding.left.value.value());
    try testing.expectEqual(@as(f32, 0.25), parsed.gap.width.value.value());
    try testing.expectEqual(@as(?f32, 2.0), parsed.aspect_ratio);
}

test "every Position variant uses Taffy's wire name and round-trips" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Captured from the tracked Rust crate: serde renames each variant to its
    // PascalCase spelling, and all five round-trip.
    const cases = [_]struct { value: Position, wire: []const u8 }{
        .{ .value = .static, .wire = "\"Static\"" },
        .{ .value = .relative, .wire = "\"Relative\"" },
        .{ .value = .absolute, .wire = "\"Absolute\"" },
        .{ .value = .fixed, .wire = "\"Fixed\"" },
        .{ .value = .sticky, .wire = "\"Sticky\"" },
    };
    for (cases) |case| {
        const serialized = try toJson(allocator, case.value);
        try testing.expectEqualStrings(case.wire, serialized);
        const parsed = try json.fromSlice(Position, allocator, serialized);
        try testing.expectEqual(case.value, parsed);
    }

    // An unknown variant is rejected rather than silently defaulting.
    try testing.expectError(error.UnexpectedToken, json.fromSlice(Position, allocator, "\"Stickyy\""));
}

test "alignment wire names and rejection match Taffy" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const center = try toJson(allocator, alignment.AlignItems.CENTER);
    try testing.expectEqualStrings("\"Center\"", center);
    const safe_center = try toJson(allocator, alignment.AlignItems.SAFE_CENTER);
    try testing.expectEqualStrings("\"SafeCenter\"", safe_center);
    const self_end = try toJson(allocator, alignment.AlignItems.SELF_END);
    try testing.expectEqualStrings("\"SelfEnd\"", self_end);
    const space_around = try toJson(allocator, alignment.AlignContent.SPACE_AROUND);
    try testing.expectEqualStrings("\"SpaceAround\"", space_around);

    const parsed = try json.fromSlice(alignment.AlignItems, allocator, "\"SafeSelfEnd\"");
    try testing.expectEqual(alignment.AlignItemsKeyword.self_end, parsed.keyword);
    try testing.expectEqual(alignment.AlignmentSafety.safe, parsed.safety);

    // Rust accepts only exact PascalCase names.
    try testing.expectError(error.WrongType, json.fromSlice(alignment.AlignItems, allocator, "\"center\""));
    try testing.expectError(error.WrongType, json.fromSlice(alignment.AlignItems, allocator, "\"safe center\""));
}

test "grid placement serialization matches Taffy external tagging" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const auto = try toJson(allocator, @as(grid.GridPlacement, .auto));
    defer allocator.free(auto);
    try testing.expectEqualStrings("\"Auto\"", auto);

    const line = try toJson(allocator, grid.GridPlacement.from_line_index(2));
    defer allocator.free(line);
    try testing.expectEqualStrings("{\"Line\":2}", line);

    const span = try toJson(allocator, grid.GridPlacement.from_span(3));
    defer allocator.free(span);
    try testing.expectEqualStrings("{\"Span\":3}", span);

    const named_line = try toJson(allocator, grid.GridPlacement.from_named_line("foo", -1));
    defer allocator.free(named_line);
    try testing.expectEqualStrings("{\"NamedLine\":[\"foo\",-1]}", named_line);

    const named_span = try toJson(allocator, grid.GridPlacement.from_named_span("bar", 2));
    defer allocator.free(named_span);
    try testing.expectEqualStrings("{\"NamedSpan\":[\"bar\",2]}", named_span);
}

test "grid placement round-trips through JSON" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    inline for (.{
        @as(grid.GridPlacement, .auto),
        grid.GridPlacement.from_line_index(-3),
        grid.GridPlacement.from_span(4),
        grid.GridPlacement.from_named_line("content", 2),
        grid.GridPlacement.from_named_span("main", 1),
    }) |placement| {
        const serialized = try toJson(allocator, placement);
        const parsed = try json.fromSlice(grid.GridPlacement, allocator, serialized);
        try testing.expectEqual(std.meta.activeTag(placement), std.meta.activeTag(parsed));
        switch (placement) {
            .auto => {},
            .line => |value| try testing.expectEqual(value, parsed.line),
            .span => |value| try testing.expectEqual(value, parsed.span),
            .named_line => |value| {
                try testing.expectEqualStrings(value.name, parsed.named_line.name);
                try testing.expectEqual(value.index, parsed.named_line.index);
            },
            .named_span => |value| {
                try testing.expectEqualStrings(value.name, parsed.named_span.name);
                try testing.expectEqual(value.count, parsed.named_span.count);
            },
        }
    }
}

test "grid tracks and repetitions match Taffy shapes" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const component = grid.GridTemplateComponent{ .repeat = .{
        .count = .auto_fill,
        .tracks = &[_]grid.TrackSizingFunction{.{ .min = grid.MinTrackSizingFunction.length(50.0), .max = grid.MaxTrackSizingFunction.length(50.0) }},
        .line_names = &[_]grid.GridTemplateLineNames{ &[_][]const u8{"a"}, &.{} },
    } };
    const serialized = try toJson(allocator, component);
    try testing.expectEqualStrings(
        "{\"Repeat\":{\"count\":\"AutoFill\",\"tracks\":[{\"min\":5406982144,\"max\":5406982144}],\"line_names\":[[\"a\"],[]]}}",
        serialized,
    );

    const parsed = try json.fromSlice(grid.GridTemplateComponent, allocator, serialized);
    try testing.expect(parsed == .repeat);
    try testing.expectEqual(@as(grid.RepetitionCount, .auto_fill), parsed.repeat.count);
    try testing.expectEqual(@as(usize, 1), parsed.repeat.tracks.len);
}

test "contain serializes as its u8 bit set" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const none = try toJson(allocator, Contain.NONE);
    try testing.expectEqualStrings("0", none);
    const content = try toJson(allocator, Contain.CONTENT);
    try testing.expectEqualStrings("3", content);

    const parsed = try json.fromSlice(Contain, allocator, "3");
    try testing.expect(parsed.layout and parsed.paint);
}
