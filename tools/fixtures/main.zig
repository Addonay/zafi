//! Taffy XML fixture runner for the Zig port.
//!
//! Walks `.references/taffy/tests/xml/**` (path baked in via `build_options`),
//! builds each `<test>` tree with the port, computes layout and compares the
//! recursive expectation tree within Taffy's 0.1px tolerance. This is the
//! parity gate described in `docs/port.md` and `docs/report.md`.
//!
//! Usage (through the package build):
//!   zig build fixtures                          # all groups
//!   zig build fixtures -- --group flex          # one group
//!   zig build fixtures -- --filter align_items  # name substring
//!   zig build fixtures -- --limit 50 --verbose
//!   zig build fixtures -- --list-failures       # names only
//!
//! # The `position` attribute default
//!
//! Taffy's own runner reads a missing `position` attribute as
//! `Position::default()`. That default is revision-dependent, and the port
//! tracks the current one (`static`, matching CSS), so the runner does the
//! same.
//!
//! Fixture corpora generated *before* Taffy made `static` the default omit the
//! attribute on nodes that were `relative` at the time. Running such a corpus
//! against the current default therefore builds a different tree than the
//! corpus describes. `--default-position` selects the default explicitly for
//! those historical baselines; every fixture in the current corpus sets
//! `position` explicitly, so the flag does not affect it.

const std = @import("std");
const zafi = @import("zafi");
const xml = @import("xml.zig");
const build_options = @import("build_options");

const Style = zafi.Style;
const grid = zafi.style.grid;

const ExpectedNode = struct {
    node_id: zafi.NodeId,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    scroll_width: ?f32,
    scroll_height: ?f32,
    resolved_rows: ?[]const u8,
    resolved_columns: ?[]const u8,
    children: []ExpectedNode,
};

const Options = struct {
    group: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    limit: usize = std.math.maxInt(usize),
    max_failures: usize = 40,
    verbose: bool = false,
    list_failures: bool = false,
    report: bool = false,
    /// The `position` used when a fixture omits the attribute. Defaults to the
    /// port's `Style.position` default (and Taffy's `Position::default()`);
    /// override only for historical fixture corpora generated when Taffy's default
    /// was `relative`.
    default_position: zafi.Position = .static,
};

const GroupStats = struct {
    name: []const u8,
    files: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
};

const Runner = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    groups: std.ArrayList(GroupStats) = .empty,
    total_files: usize = 0,
    total_passed: usize = 0,
    total_failed: usize = 0,
    printed_failures: usize = 0,

    fn processGroup(self: *Runner, base: []const u8, group_name: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, base, .{ .iterate = true }) catch |err| {
            std.debug.print("error: cannot open {s}: {s}\n", .{ base, @errorName(err) });
            return err;
        };
        defer dir.close(self.io);

        var stats = GroupStats{ .name = try self.gpa.dupe(u8, group_name) };
        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".xml")) continue;
            if (self.options.filter) |filter| {
                if (std.mem.indexOf(u8, entry.name, filter) == null) continue;
            }
            if (stats.files >= self.options.limit) break;
            stats.files += 1;
            self.total_files += 1;

            const raw = dir.readFileAlloc(self.io, entry.name, self.gpa, .unlimited) catch |err| {
                stats.failed += 1;
                self.total_failed += 1;
                self.recordFailure(group_name, entry.name, try std.fmt.allocPrint(self.gpa, "read error: {s}", .{@errorName(err)}));
                continue;
            };
            defer self.gpa.free(raw);

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            if (self.runOne(arena.allocator(), raw)) |failure_message| {
                stats.failed += 1;
                self.total_failed += 1;
                self.recordFailure(group_name, entry.name, failure_message);
            } else {
                stats.passed += 1;
                self.total_passed += 1;
            }
        }
        try self.groups.append(self.gpa, stats);
    }

    fn recordFailure(self: *Runner, group: []const u8, name: []const u8, message: []const u8) void {
        if (self.options.list_failures) {
            std.debug.print("FAIL {s}/{s}\n", .{ group, name });
            return;
        }
        if (self.printed_failures < self.options.max_failures) {
            self.printed_failures += 1;
            std.debug.print("FAIL {s}/{s}: {s}\n", .{ group, name, message });
        }
    }

    /// Returns null on success or an allocated failure description.
    fn runOne(self: *Runner, alloc: std.mem.Allocator, raw: []const u8) ?[]const u8 {
        const doc = xml.parse(alloc, raw) catch |err| {
            return std.fmt.allocPrint(alloc, "xml parse error: {s}", .{@errorName(err)}) catch "xml parse error";
        };
        const viewport = doc.firstChild("viewport") orelse return "missing <viewport>";
        const input = doc.firstChild("input") orelse return "missing <input>";
        const expectations = doc.firstChild("expectations") orelse return "missing <expectations>";
        const input_root = input.firstElementChild() orelse return "empty <input>";
        const expected_root = expectations.firstElementChild() orelse return "empty <expectations>";

        const use_rounding = parseUseRounding(doc.attribute("use-rounding")) catch return "invalid use-rounding";

        var tree = zafi.Tree.init(self.gpa);
        defer tree.deinit();

        const expected_tree = self.buildTree(alloc, &tree, input_root, expected_root, null, self.options.default_position) catch |err| {
            return std.fmt.allocPrint(alloc, "tree build error: {s}", .{@errorName(err)}) catch "tree build error";
        };

        const available = zafi.Size(zafi.AvailableSpace){
            .width = parseAvailableSpace(viewport.attribute("width")) catch return "invalid viewport width",
            .height = parseAvailableSpace(viewport.attribute("height")) catch return "invalid viewport height",
        };
        tree.use_rounding = use_rounding;
        const evictions_before = zafi.tree.cache.mode_change_evictions;
        tree.compute_layout_with_measure(expected_tree.node_id, available, zafi.testing.fixture_measure_function) catch |err| {
            return std.fmt.allocPrint(alloc, "compute error: {s}", .{@errorName(err)}) catch "compute error";
        };

        // Taffy's runner asserts this too: a single pass over fresh caches must
        // lay every node out with one sizing mode / margin collapsibility.
        if (zafi.tree.cache.mode_change_evictions != evictions_before)
            return "cache mode changed during a layout pass over fresh caches";

        var details = std.ArrayList(u8).empty;
        const failure_count = compareNode(alloc, &tree, expected_tree.node_id, expected_tree, use_rounding, "", &details, 0);
        if (failure_count > 0) return details.items;
        return null;
    }

    fn buildTree(
        self: *Runner,
        alloc: std.mem.Allocator,
        tree: *zafi.Tree,
        input: *const xml.Element,
        expected: *const xml.Element,
        parent: ?zafi.NodeId,
        default_position: zafi.Position,
    ) !*ExpectedNode {
        const style = try buildStyle(input, default_position);
        var node_id: zafi.NodeId = undefined;
        if (input.children.len > 0) {
            node_id = try tree.new_leaf(style);
        } else {
            const raw_text = input.text;
            if (raw_text.len > 0) {
                const context = try alloc.create(zafi.testing.TestNodeContext);
                const writing_mode: zafi.testing.WritingMode = if (input.attribute("writing-mode")) |mode|
                    (if (std.mem.startsWith(u8, mode, "vertical")) .vertical else .horizontal)
                else
                    .horizontal;
                context.* = zafi.testing.TestNodeContext.ahem_text(std.mem.trim(u8, raw_text, " \t\r\n"), writing_mode);
                node_id = try tree.new_leaf_with_context(style, @ptrCast(context));
            } else {
                node_id = try tree.new_leaf(style);
            }
        }
        if (parent) |p| try tree.add_child(p, node_id);

        const expected_node = try alloc.create(ExpectedNode);
        expected_node.* = .{
            .node_id = node_id,
            .x = try parseExpected(expected.attribute("x")),
            .y = try parseExpected(expected.attribute("y")),
            .width = try parseExpected(expected.attribute("width")),
            .height = try parseExpected(expected.attribute("height")),
            .scroll_width = if (expected.attribute("scroll_width")) |value| try std.fmt.parseFloat(f32, value) else null,
            .scroll_height = if (expected.attribute("scroll_height")) |value| try std.fmt.parseFloat(f32, value) else null,
            .resolved_rows = expected.attribute("resolved-rows"),
            .resolved_columns = expected.attribute("resolved-columns"),
            .children = &.{},
        };
        if (input.children.len != expected.children.len) return error.ChildCountMismatch;
        var children = std.ArrayList(ExpectedNode).empty;
        for (input.children, 0..) |_, index| {
            const built = try self.buildTree(alloc, tree, &input.children[index], &expected.children[index], node_id, default_position);
            try children.append(alloc, built.*);
        }
        expected_node.children = try alloc.dupe(ExpectedNode, children.items);
        return expected_node;
    }
};

fn parseExpected(raw: ?[]const u8) !f32 {
    const value = raw orelse return error.MissingExpectedAttribute;
    return try std.fmt.parseFloat(f32, value);
}

fn parseUseRounding(raw: ?[]const u8) !bool {
    const value = raw orelse return true;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidUseRounding;
}

fn parseAvailableSpace(raw: ?[]const u8) !zafi.AvailableSpace {
    const value = raw orelse return .max_content;
    return zafi.AvailableSpace.from_str(value);
}

fn parseAttr(comptime T: type, node: *const xml.Element, name: []const u8) !?T {
    const raw = node.attribute(name) orelse return null;
    return try parseValue(T, raw);
}

fn parseValue(comptime T: type, raw: []const u8) !T {
    switch (@typeInfo(T)) {
        .float => return try std.fmt.parseFloat(T, raw),
        .int => return try std.fmt.parseInt(T, raw, 10),
        .@"enum" => {
            if (comptime @hasDecl(T, "from_str")) return try T.from_str(raw);
            return std.meta.stringToEnum(T, raw) orelse error.InvalidEnumValue;
        },
        .@"struct", .@"union" => {
            if (comptime @hasDecl(T, "from_str")) return try T.from_str(raw);
            @compileError("fixture runner: no parser for " ++ @typeName(T));
        },
        else => @compileError("fixture runner: unsupported attribute type " ++ @typeName(T)),
    }
}

fn attrOr(comptime T: type, node: *const xml.Element, name: []const u8, fallback: T) !T {
    return (try parseAttr(T, node, name)) orelse fallback;
}

fn parsePlacement(node: *const xml.Element, name: []const u8) !grid.GridPlacement {
    const raw = node.attribute(name) orelse return .auto;
    return try grid.grid_placement_from_str(raw);
}

fn buildStyle(node: *const xml.Element, default_position: zafi.Position) !Style {
    var style = Style{};

    style.display = try attrOr(zafi.Display, node, "display", .flex);
    style.direction = try attrOr(zafi.Direction, node, "direction", .ltr);
    style.box_sizing = try attrOr(zafi.BoxSizing, node, "box-sizing", .border_box);
    style.overflow.x = try attrOr(zafi.Overflow, node, "overflow-x", .visible);
    style.overflow.y = try attrOr(zafi.Overflow, node, "overflow-y", .visible);
    style.scrollbar_width = try attrOr(f32, node, "scrollbar-width", 0);
    style.contain = try attrOr(zafi.Contain, node, "contain", .{});
    style.float = try attrOr(zafi.style.float.Float, node, "float", .none);
    style.clear = try attrOr(zafi.style.float.Clear, node, "clear", .none);
    style.position = try attrOr(zafi.Position, node, "position", default_position);

    style.size = .{
        .width = try attrOr(zafi.Dimension, node, "width", zafi.Dimension.auto),
        .height = try attrOr(zafi.Dimension, node, "height", zafi.Dimension.auto),
    };
    style.min_size = .{
        .width = try attrOr(zafi.LengthPercentageAuto, node, "min-width", zafi.LengthPercentageAuto.auto()),
        .height = try attrOr(zafi.LengthPercentageAuto, node, "min-height", zafi.LengthPercentageAuto.auto()),
    };
    style.max_size = .{
        .width = try attrOr(zafi.LengthPercentageAuto, node, "max-width", zafi.LengthPercentageAuto.auto()),
        .height = try attrOr(zafi.LengthPercentageAuto, node, "max-height", zafi.LengthPercentageAuto.auto()),
    };
    style.inset = .{
        .top = try attrOr(zafi.LengthPercentageAuto, node, "top", zafi.LengthPercentageAuto.auto()),
        .left = try attrOr(zafi.LengthPercentageAuto, node, "left", zafi.LengthPercentageAuto.auto()),
        .bottom = try attrOr(zafi.LengthPercentageAuto, node, "bottom", zafi.LengthPercentageAuto.auto()),
        .right = try attrOr(zafi.LengthPercentageAuto, node, "right", zafi.LengthPercentageAuto.auto()),
    };
    style.margin = .{
        .top = try attrOr(zafi.LengthPercentageAuto, node, "margin-top", zafi.LengthPercentageAuto.zero()),
        .left = try attrOr(zafi.LengthPercentageAuto, node, "margin-left", zafi.LengthPercentageAuto.zero()),
        .bottom = try attrOr(zafi.LengthPercentageAuto, node, "margin-bottom", zafi.LengthPercentageAuto.zero()),
        .right = try attrOr(zafi.LengthPercentageAuto, node, "margin-right", zafi.LengthPercentageAuto.zero()),
    };
    style.padding = .{
        .top = try attrOr(zafi.LengthPercentage, node, "padding-top", zafi.LengthPercentage.zero()),
        .left = try attrOr(zafi.LengthPercentage, node, "padding-left", zafi.LengthPercentage.zero()),
        .bottom = try attrOr(zafi.LengthPercentage, node, "padding-bottom", zafi.LengthPercentage.zero()),
        .right = try attrOr(zafi.LengthPercentage, node, "padding-right", zafi.LengthPercentage.zero()),
    };
    style.border = .{
        .top = try attrOr(zafi.LengthPercentage, node, "border-top", zafi.LengthPercentage.zero()),
        .left = try attrOr(zafi.LengthPercentage, node, "border-left", zafi.LengthPercentage.zero()),
        .bottom = try attrOr(zafi.LengthPercentage, node, "border-bottom", zafi.LengthPercentage.zero()),
        .right = try attrOr(zafi.LengthPercentage, node, "border-right", zafi.LengthPercentage.zero()),
    };
    style.gap = .{
        .width = try attrOr(zafi.LengthPercentage, node, "column-gap", zafi.LengthPercentage.zero()),
        .height = try attrOr(zafi.LengthPercentage, node, "row-gap", zafi.LengthPercentage.zero()),
    };

    style.aspect_ratio = try parseAttr(f32, node, "aspect-ratio");
    style.align_items = try parseAttr(zafi.AlignItems, node, "align-items");
    style.align_self = try parseAttr(zafi.AlignSelf, node, "align-self");
    style.justify_items = try parseAttr(zafi.JustifyItems, node, "justify-items");
    style.justify_self = try parseAttr(zafi.JustifySelf, node, "justify-self");
    style.align_content = try parseAttr(zafi.AlignContent, node, "align-content");
    style.justify_content = try parseAttr(zafi.JustifyContent, node, "justify-content");

    style.text_align = try attrOr(zafi.style.block.TextAlign, node, "text-align", .auto);
    style.flex_direction = try attrOr(zafi.style.flex.FlexDirection, node, "flex-direction", .row);
    style.flex_wrap = try attrOr(zafi.style.flex.FlexWrap, node, "flex-wrap", .no_wrap);
    style.flex_line_count = try attrOr(u16, node, "flex-line-count", 1);
    style.flex_grow = try attrOr(f32, node, "flex-grow", 0);
    style.flex_shrink = try attrOr(f32, node, "flex-shrink", 1);
    style.flex_basis = try attrOr(zafi.Dimension, node, "flex-basis", zafi.Dimension.auto);

    style.grid_auto_flow = try attrOr(grid.GridAutoFlow, node, "grid-auto-flow", .row);
    if (node.attribute("grid-template-rows")) |raw| {
        const parsed = try grid.GridTemplateComponents.from_str(raw);
        style.grid_template_rows = parsed.tracks;
        style.grid_template_row_names = parsed.line_names;
    }
    if (node.attribute("grid-template-columns")) |raw| {
        const parsed = try grid.GridTemplateComponents.from_str(raw);
        style.grid_template_columns = parsed.tracks;
        style.grid_template_column_names = parsed.line_names;
    }
    if (node.attribute("grid-auto-rows")) |raw| style.grid_auto_rows = try grid.grid_auto_tracks_from_str(raw);
    if (node.attribute("grid-auto-columns")) |raw| style.grid_auto_columns = try grid.grid_auto_tracks_from_str(raw);
    style.grid_row = .{ .start = try parsePlacement(node, "grid-row-start"), .end = try parsePlacement(node, "grid-row-end") };
    style.grid_column = .{ .start = try parsePlacement(node, "grid-column-start"), .end = try parsePlacement(node, "grid-column-end") };

    return style;
}

const tolerance: f32 = 0.1;

fn nearlyEqual(a: f32, b: f32) bool {
    return @abs(a - b) < tolerance;
}

const TrackListToken = union(enum) {
    names: []const []const u8,
    size: f32,
};

/// Parse a resolved track list (`[foo bar] 10px 20.5px` or `none`) into
/// tokens, porting `tests/xml.rs::parse_track_list`.
fn parseTrackList(alloc: std.mem.Allocator, input_raw: []const u8) ![]TrackListToken {
    const input = std.mem.trim(u8, input_raw, " \t\r\n");
    var tokens = std.ArrayList(TrackListToken).empty;
    if (std.mem.eql(u8, input, "none")) return &.{};
    var index: usize = 0;
    while (index < input.len) {
        while (index < input.len and std.ascii.isWhitespace(input[index])) index += 1;
        if (index >= input.len) break;
        if (input[index] == '[') {
            const end = std.mem.indexOfScalarPos(u8, input, index, ']') orelse return error.InvalidTrackList;
            const inner = input[index + 1 .. end];
            var names = std.ArrayList([]const u8).empty;
            var name_iter = std.mem.tokenizeAny(u8, inner, " \t\r\n");
            while (name_iter.next()) |name| try names.append(alloc, name);
            try tokens.append(alloc, .{ .names = names.items });
            index = end + 1;
        } else {
            const end = blk: {
                var cursor = index;
                while (cursor < input.len and input[cursor] != ' ') cursor += 1;
                break :blk cursor;
            };
            const raw = input[index..end];
            const number = std.mem.trim(u8, raw, " \t\r\n");
            const without_px = if (std.mem.endsWith(u8, number, "px")) number[0 .. number.len - 2] else number;
            try tokens.append(alloc, .{ .size = std.fmt.parseFloat(f32, without_px) catch return error.InvalidTrackList });
            index = end;
        }
    }
    return tokens.items;
}

fn trackListsMatch(alloc: std.mem.Allocator, expected: []const u8, actual: []const u8) bool {
    const expected_tokens = parseTrackList(alloc, expected) catch return false;
    const actual_tokens = parseTrackList(alloc, actual) catch return false;
    if (expected_tokens.len != actual_tokens.len) return false;
    for (expected_tokens, actual_tokens) |expected_token, actual_token| {
        switch (expected_token) {
            .names => |expected_names| switch (actual_token) {
                .names => |actual_names| {
                    if (expected_names.len != actual_names.len) return false;
                    for (expected_names, actual_names) |a, b| {
                        if (!std.mem.eql(u8, a, b)) return false;
                    }
                },
                .size => return false,
            },
            .size => |expected_size| switch (actual_token) {
                .size => |actual_size| {
                    if (!nearlyEqual(expected_size, actual_size)) return false;
                },
                .names => return false,
            },
        }
    }
    return true;
}

fn appendMessage(alloc: std.mem.Allocator, details: *std.ArrayList(u8), comptime format: []const u8, args: anytype) void {
    const message = std.fmt.allocPrint(alloc, format, args) catch return;
    details.appendSlice(alloc, message) catch {};
}

fn compareNode(
    alloc: std.mem.Allocator,
    tree: *zafi.Tree,
    node_id: zafi.NodeId,
    expected: *const ExpectedNode,
    use_rounding: bool,
    path: []const u8,
    details: *std.ArrayList(u8),
    depth: usize,
) usize {
    if (depth > 64) return 0;
    var failures: usize = 0;
    const actual = (if (use_rounding) tree.layout_of(node_id) else tree.unrounded_layout(node_id)) catch {
        appendMessage(alloc, details, "{s}: zafi lookup failed\n", .{path});
        return 1;
    };
    if (!nearlyEqual(actual.location.x, expected.x) or
        !nearlyEqual(actual.location.y, expected.y) or
        !nearlyEqual(actual.size.width, expected.width) or
        !nearlyEqual(actual.size.height, expected.height))
    {
        failures += 1;
        if (failures <= 8) {
            appendMessage(alloc, details, "{s}: expected (x={d:.2} y={d:.2} w={d:.2} h={d:.2}) got (x={d:.2} y={d:.2} w={d:.2} h={d:.2})\n", .{
                path, expected.x, expected.y, expected.width, expected.height, actual.location.x, actual.location.y, actual.size.width, actual.size.height,
            });
        }
    }
    if (expected.scroll_width != null and expected.scroll_height != null) {
        const actual_scroll = zafi.Size(f32){ .width = actual.scroll_width(), .height = actual.scroll_height() };
        if (!nearlyEqual(actual_scroll.width, expected.scroll_width.?) or !nearlyEqual(actual_scroll.height, expected.scroll_height.?)) {
            failures += 1;
            if (failures <= 8) {
                appendMessage(alloc, details, "{s}: expected scroll ({d:.2},{d:.2}) got ({d:.2},{d:.2})\n", .{
                    path, expected.scroll_width.?, expected.scroll_height.?, actual_scroll.width, actual_scroll.height,
                });
            }
        }
    }

    // Resolved track lists are asserted only when both the expectation and the
    // computed detailed info are available, mirroring Taffy's `tests/xml.rs`.
    const detailed = tree.detailed_layout_info(node_id) catch .none;
    const actual_grid: ?*const zafi.compute.grid.DetailedGridInfo = switch (detailed) {
        .none => null,
        .grid => |pointer| @ptrCast(@alignCast(pointer)),
    };
    if (expected.resolved_rows != null and actual_grid != null) {
        const actual_rows = actual_grid.?.grid_template_rows();
        if (!trackListsMatch(alloc, expected.resolved_rows.?, actual_rows)) {
            failures += 1;
            if (failures <= 8) {
                appendMessage(alloc, details, "{s}: expected rows [{s}] got [{s}]\n", .{ path, expected.resolved_rows.?, actual_rows });
            }
        }
    }
    if (expected.resolved_columns != null and actual_grid != null) {
        const actual_columns = actual_grid.?.grid_template_columns();
        if (!trackListsMatch(alloc, expected.resolved_columns.?, actual_columns)) {
            failures += 1;
            if (failures <= 8) {
                appendMessage(alloc, details, "{s}: expected columns [{s}] got [{s}]\n", .{ path, expected.resolved_columns.?, actual_columns });
            }
        }
    }

    const child_ids = tree.children(node_id) catch &.{};
    if (child_ids.len != expected.children.len) {
        appendMessage(alloc, details, "{s}: child count expected {d} got {d}\n", .{ path, expected.children.len, child_ids.len });
        return failures + 1;
    }
    for (child_ids, 0..) |child_id, index| {
        const child_path = std.fmt.allocPrint(alloc, "{s}/{d}", .{ path, index }) catch path;
        failures += compareNode(alloc, tree, child_id, &expected.children[index], use_rounding, child_path, details, depth + 1);
    }
    return failures;
}

fn parseArgs(args: []const [:0]const u8) !Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--group")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.group = args[index];
        } else if (std.mem.eql(u8, arg, "--filter")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.filter = args[index];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.limit = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--max-failures")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.max_failures = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "--list-failures")) {
            options.list_failures = true;
        } else if (std.mem.eql(u8, arg, "--report")) {
            options.report = true;
        } else if (std.mem.eql(u8, arg, "--default-position")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.default_position = zafi.Position.from_str(args[index]) catch return error.InvalidPosition;
        }
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = parseArgs(args) catch |err| {
        std.debug.print("argument error: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };

    var runner = Runner{ .io = io, .gpa = arena, .options = options };

    const base = build_options.fixtures_dir;
    if (options.group) |group| {
        const path = try std.fs.path.join(arena, &.{ base, group });
        runner.processGroup(path, group) catch std.process.exit(2);
    } else {
        var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch |err| {
            std.debug.print("error: cannot open fixtures dir {s}: {s}\n", .{ base, @errorName(err) });
            std.process.exit(2);
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const path = try std.fs.path.join(arena, &.{ base, entry.name });
            runner.processGroup(path, entry.name) catch std.process.exit(2);
        }
    }

    std.debug.print("\n=== fixture results ===\n", .{});
    for (runner.groups.items) |group| {
        std.debug.print("{s:20} {d:5} files  {d:5} passed  {d:5} failed\n", .{ group.name, group.files, group.passed, group.failed });
    }
    std.debug.print("total: {d} files, {d} passed, {d} failed\n", .{ runner.total_files, runner.total_passed, runner.total_failed });
    if (!options.list_failures and runner.total_failed > runner.printed_failures) {
        std.debug.print("({d} failures not printed; use --list-failures for all names)\n", .{runner.total_failed - runner.printed_failures});
    }

    if (runner.total_failed > 0 and !options.report) std.process.exit(1);
}
