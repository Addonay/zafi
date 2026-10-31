//! Temporary allocation-counting probe. Not part of the library.
//!
//! Implements the `std.mem.Allocator` interface so every allocation the layout
//! pass performs is tallied, then runs the benchmark scenarios and prints
//! counts.

const std = @import("std");
const zlay = @import("zlay");

const page = std.heap.page_allocator;

/// A `std.mem.Allocator` that tallies every call before forwarding to the
/// page allocator. Zig 0.17 allocators are vtables, so the state pointer is
/// carried in `ptr`.
const Counting = struct {
    allocs: usize = 0,
    bytes: usize = 0,
    resizes: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        self.bytes += len;
        return page.vtable.alloc(page.ptr, len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        if (new_len > buf.len) self.bytes += new_len - buf.len;
        return page.vtable.resize(page.ptr, buf, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        if (new_len > buf.len) self.bytes += new_len - buf.len;
        return page.vtable.remap(page.ptr, buf, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        page.vtable.free(page.ptr, buf, alignment, ret_addr);
    }
    fn reset(self: *Counting) void {
        self.allocs = 0;
        self.bytes = 0;
        self.resizes = 0;
    }
};

fn fixedSize(w: f32, h: f32) zlay.Style {
    return .{ .size = .{ .width = zlay.Dimension.length(w), .height = zlay.Dimension.length(h) } };
}

fn report(name: []const u8, base: *Counting) void {
    std.debug.print("{s: <14} allocs={d:>9} resizes={d:>7} bytes={d:>12}\n", .{
        name, base.allocs, base.resizes, base.bytes,
    });
}

fn runBlockNested(base: *Counting) !void {
    const allocator = base.allocator();
    var tree = zlay.Tree.init(allocator);
    var parent = try tree.new_leaf(.{ .display = .block });
    for (0..50) |_| {
        const child = try tree.new_leaf(.{
            .display = .block,
            .margin = .{
                .left = zlay.LengthPercentageAuto.zero(),
                .right = zlay.LengthPercentageAuto.zero(),
                .top = zlay.LengthPercentageAuto.length(2),
                .bottom = zlay.LengthPercentageAuto.length(2),
            },
        });
        try tree.add_child(parent, child);
        parent = child;
    }
    const root = try tree.new_with_children(.{
        .display = .block,
        .size = .{ .width = zlay.Dimension.length(500), .height = zlay.Dimension.auto },
    }, &[_]zlay.NodeId{parent});

    base.reset();
    try tree.compute_layout(root, .{ .width = .{ .definite = 500 }, .height = .{ .max_content = {} } });
    report("block_nested50", base);
}

fn runMixed(base: *Counting) !void {
    const allocator = base.allocator();
    var tree = zlay.Tree.init(allocator);
    const grid_children = try allocator.alloc(zlay.NodeId, 100);
    for (grid_children) |*child| {
        const block_child = try tree.new_leaf(.{ .display = .block, .margin = .{
            .left = zlay.LengthPercentageAuto.length(1),
            .right = zlay.LengthPercentageAuto.length(1),
            .top = zlay.LengthPercentageAuto.length(1),
            .bottom = zlay.LengthPercentageAuto.length(1),
        } });
        child.* = try tree.new_with_children(.{ .display = .block, .size = .{
            .width = zlay.Dimension.auto,
            .height = zlay.Dimension.auto,
        } }, &[_]zlay.NodeId{block_child});
    }
    const grid = try tree.new_with_children(.{
        .display = .grid,
        .grid_template_columns = &[_]zlay.GridTemplateComponent{
            .{ .single = zlay.TrackSizingFunction.from_fr(1) },
            .{ .single = zlay.TrackSizingFunction.from_fr(1) },
            .{ .single = zlay.TrackSizingFunction.from_fr(1) },
            .{ .single = zlay.TrackSizingFunction.from_fr(1) },
        },
        .flex_grow = 1,
    }, grid_children);
    const flex_children = try allocator.alloc(zlay.NodeId, 8);
    for (flex_children, 0..) |*child, i| {
        child.* = if (i == 0) grid else try tree.new_leaf(.{ .display = .block, .size = .{
            .width = zlay.Dimension.length(10),
            .height = zlay.Dimension.length(10),
        } });
    }
    const root = try tree.new_with_children(.{
        .display = .flex,
        .flex_direction = .row,
        .size = .{ .width = zlay.Dimension.length(500), .height = zlay.Dimension.length(500) },
    }, flex_children);

    base.reset();
    try tree.compute_layout(root, .{ .width = .{ .definite = 500 }, .height = .{ .definite = 500 } });
    report("mixed", base);
}

fn runFlexRow(base: *Counting) !void {
    const allocator = base.allocator();
    var tree = zlay.Tree.init(allocator);
    const children = try allocator.alloc(zlay.NodeId, 1000);
    for (children, 0..) |*child, i| {
        child.* = try tree.new_leaf(.{
            .display = .flex,
            .size = .{ .width = zlay.Dimension.length(10), .height = zlay.Dimension.length(10) },
            .flex_grow = @floatFromInt(i % 3 + 1),
        });
    }
    const root = try tree.new_with_children(.{
        .display = .flex,
        .flex_direction = .row,
        .size = .{ .width = zlay.Dimension.length(1000), .height = zlay.Dimension.length(100) },
    }, children);

    base.reset();
    try tree.compute_layout(root, .{ .width = .{ .definite = 1000 }, .height = .{ .definite = 100 } });
    report("flex_row_1000", base);
}

fn runGrid(base: *Counting) !void {
    const allocator = base.allocator();
    var tree = zlay.Tree.init(allocator);
    const children = try allocator.alloc(zlay.NodeId, 2500);
    for (children) |*child| child.* = try tree.new_leaf(fixedSize(5, 5));
    const columns = try allocator.alloc(zlay.GridTemplateComponent, 50);
    for (columns) |*column| column.* = .{ .single = zlay.TrackSizingFunction.from_length(10) };
    const rows = try allocator.alloc(zlay.GridTemplateComponent, 50);
    for (rows) |*row| row.* = .{ .single = zlay.TrackSizingFunction.from_length(10) };
    const root = try tree.new_with_children(.{
        .display = .grid,
        .grid_template_columns = columns,
        .grid_template_rows = rows,
        .size = .{ .width = zlay.Dimension.length(500), .height = zlay.Dimension.length(500) },
    }, children);

    base.reset();
    try tree.compute_layout(root, .{ .width = .{ .definite = 500 }, .height = .{ .definite = 500 } });
    report("grid_50x50", base);
}

pub fn main() !void {
    var base = Counting{};
    try runBlockNested(&base);
    try runFlexRow(&base);
    try runMixed(&base);
    try runGrid(&base);
}