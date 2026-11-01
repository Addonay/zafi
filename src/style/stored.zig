//! Compact style storage for `zafi.Tree`.
//!
//! `Style` is a 512-byte value, and about half of it is grid-only properties
//! (template tracks, areas, line names, placements) that most nodes never set.
//! `StoredStyle` keeps every other property inline and moves the grid ones to
//! a separate allocation that exists only when one of them differs from its
//! default, which makes every node ~250 bytes smaller.
//!
//! The layout algorithms read it through `view.View(StoredStyle)` via the
//! generic `get`, which is an inlined field load for the inline properties
//! and a null check plus a load for the grid ones.
//!
//! Both field sets are derived from `Style` at compile time, so a property
//! added to `Style` is stored automatically.

const std = @import("std");
const Style = @import("root.zig").Style;
const view = @import("view.zig");

const style_info = @typeInfo(Style).@"struct";

fn isGridField(comptime name: []const u8) bool {
    return std.mem.startsWith(u8, name, "grid_");
}

/// A struct with `Style`'s fields (and defaults) for which `isGridField` is `grid`.
fn Subset(comptime grid: bool) type {
    comptime var count: usize = 0;
    for (style_info.field_names) |name| {
        if (isGridField(name) == grid) count += 1;
    }
    comptime var names: [count][]const u8 = undefined;
    comptime var types: [count]type = undefined;
    comptime var attrs: [count]std.lang.Type.Struct.FieldAttributes = undefined;
    comptime var i: usize = 0;
    for (style_info.field_names, style_info.field_types, style_info.field_attrs) |name, T, attr| {
        if (isGridField(name) != grid) continue;
        names[i] = name;
        types[i] = T;
        attrs[i] = attr;
        i += 1;
    }
    const final_names = names;
    const final_types = types;
    const final_attrs = attrs;
    return @Struct(.auto, null, &final_names, &final_types, &final_attrs);
}

pub const Core = Subset(false);
pub const Grid = Subset(true);

const default_grid: Grid = .{};

/// Whether every grid property of `value` has its default. Explicit, cheap
/// checks (lengths, tags) because this runs for every node created; the
/// comptime block below fails the build if a grid property is added to
/// `Style` without being checked here.
inline fn gridIsDefault(v: *const Style) bool {
    return v.grid_template_rows.len == 0 and v.grid_template_columns.len == 0 and
        v.grid_auto_rows.len == 0 and v.grid_auto_columns.len == 0 and
        v.grid_auto_flow == .row and v.grid_template_areas == null and
        v.grid_template_column_names.len == 0 and v.grid_template_row_names.len == 0 and
        v.grid_row.start == .auto and v.grid_row.end == .auto and
        v.grid_column.start == .auto and v.grid_column.end == .auto;
}

comptime {
    const checked = [_][]const u8{
        "grid_template_rows",         "grid_template_columns",    "grid_auto_rows", "grid_auto_columns",
        "grid_auto_flow",             "grid_template_areas",      "grid_template_column_names",
        "grid_template_row_names",    "grid_row",                 "grid_column",
    };
    const names = @typeInfo(Grid).@"struct".field_names;
    if (names.len != checked.len) @compileError("update stored.gridIsDefault for the new grid properties");
    for (names) |name| {
        for (checked) |c| {
            if (std.mem.eql(u8, name, c)) break;
        } else @compileError("stored.gridIsDefault does not check " ++ name);
    }
}

/// `isGridField` per `view.Field`, computed once.
const is_grid_field = blk: {
    const fields = @typeInfo(view.Field).@"enum".field_names;
    var flags: [fields.len]bool = undefined;
    for (fields, 0..) |name, i| flags[i] = isGridField(name);
    break :blk flags;
};

pub const StoredStyle = struct {
    core: Core = .{},
    /// Owned by the tree; null when every grid property has its default.
    grid: ?*Grid = null,

    /// The generic property getter `view.View` uses for host style types.
    pub inline fn get(self: *const StoredStyle, comptime field: view.Field) view.FieldType(field) {
        const name = @tagName(field);
        if (comptime is_grid_field[@intFromEnum(field)]) {
            const g = self.grid orelse return @field(default_grid, name);
            return @field(g, name);
        }
        return @field(self.core, name);
    }

    /// A stored copy of `value`; grid properties are allocated only if set.
    pub fn init(allocator: std.mem.Allocator, value: Style) std.mem.Allocator.Error!StoredStyle {
        var result: StoredStyle = .{};
        try result.set(allocator, &value);
        return result;
    }

    /// Store `value` into `self`, whose previous contents are ignored (a
    /// fresh slot). On failure `self.grid` is null and nothing is allocated.
    pub inline fn initInPlace(noalias self: *StoredStyle, allocator: std.mem.Allocator, noalias value: *const Style) std.mem.Allocator.Error!void {
        self.grid = null;
        return self.set(allocator, value);
    }

    /// Replace the stored style with `value`, reusing the grid allocation.
    /// On failure the stored style is unchanged.
    pub inline fn set(noalias self: *StoredStyle, allocator: std.mem.Allocator, noalias value: *const Style) std.mem.Allocator.Error!void {
        if (gridIsDefault(value)) {
            if (self.grid) |g| {
                @branchHint(.unlikely);
                allocator.destroy(g);
                self.grid = null;
            }
        } else {
            @branchHint(.unlikely);
            const g = self.grid orelse try allocator.create(Grid);
            inline for (@typeInfo(Grid).@"struct".field_names) |name| @field(g, name) = @field(value, name);
            self.grid = g;
        }
        inline for (@typeInfo(Core).@"struct".field_names) |name| @field(self.core, name) = @field(value, name);
    }

    /// The full `Style` this stores.
    pub fn toStyle(self: *const StoredStyle) Style {
        var result: Style = .{};
        inline for (@typeInfo(Core).@"struct".field_names) |name| @field(result, name) = @field(self.core, name);
        const g = self.grid orelse &default_grid;
        inline for (@typeInfo(Grid).@"struct".field_names) |name| @field(result, name) = @field(g, name);
        return result;
    }

    pub fn deinit(self: *StoredStyle, allocator: std.mem.Allocator) void {
        if (self.grid) |g| allocator.destroy(g);
        self.grid = null;
    }
};

test "StoredStyle round-trips a Style and allocates only for grid properties" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const dimension = @import("dimension.zig");
    const plain: Style = .{ .display = .block, .size = .{ .width = dimension.Dimension.length(10), .height = .auto }, .flex_grow = 2 };
    var stored = try StoredStyle.init(allocator, plain);
    defer stored.deinit(allocator);
    try testing.expect(stored.grid == null);
    try testing.expectEqualDeep(plain, stored.toStyle());
    try testing.expectEqual(@as(f32, 2), stored.get(.flex_grow));
    try testing.expectEqual(@import("grid.zig").GridAutoFlow.row, stored.get(.grid_auto_flow));

    var with_grid = plain;
    with_grid.grid_auto_flow = .column_dense;
    with_grid.grid_row = .{ .start = .{ .line = 2 }, .end = .{ .span = 3 } };
    try stored.set(allocator, &with_grid);
    try testing.expect(stored.grid != null);
    try testing.expectEqualDeep(with_grid, stored.toStyle());
    try testing.expectEqual(@import("grid.zig").GridAutoFlow.column_dense, stored.get(.grid_auto_flow));

    try stored.set(allocator, &plain);
    try testing.expect(stored.grid == null);
    try testing.expect(@sizeOf(StoredStyle) + 128 < @sizeOf(Style));
}
