//! Audit-only matched cold lifecycle harness: fresh libc allocation, layout,
//! and teardown. The block root uses the top of the chain. Memory output is
//! zero because allocations are not instrumented in the timing path.
//! Build with -O ReleaseFast (or ReleaseSafe) and -lc.

const std = @import("std");
const zlay = @import("zlay");

const ScenarioFn = *const fn (allocator: std.mem.Allocator) anyerror!void;

const Scenario = struct {
    name: []const u8,
    iters: usize,
    run: ScenarioFn,
};

const scenarios = [_]Scenario{
    .{ .name = "tree_creation_10k", .iters = 100, .run = benchTreeCreation },
    .{ .name = "flex_row_1000", .iters = 100, .run = benchFlexRow },
    .{ .name = "flex_wrap_500", .iters = 100, .run = benchFlexWrap },
    .{ .name = "grid_50x50", .iters = 100, .run = benchGrid },
    .{ .name = "block_nested_50", .iters = 1000, .run = benchBlockNested },
    .{ .name = "mixed_flex_grid_block", .iters = 100, .run = benchMixed },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var filter: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--filter")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            filter = args[index];
        }
    }

    std.debug.print("bench|scenario|iters|ns_per_iter|arena_capacity_bytes\n", .{});
    for (scenarios) |scenario| {
        if (filter) |needle| {
            if (std.mem.indexOf(u8, scenario.name, needle) == null) continue;
        }
        try measure(io, scenario);
    }
}

fn measure(io: std.Io, scenario: Scenario) !void {
    const allocator = std.heap.c_allocator;

    // One untimed warm-up. Each invocation frees its tree and input arrays.
    try scenario.run(allocator);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..scenario.iters) |_| {
        try scenario.run(allocator);
    }
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    const total_ns: u64 = @intCast(elapsed.raw.nanoseconds);
    const ns_per_iter = total_ns / scenario.iters;

    std.debug.print("bench|{s}|{d}|{d}|{d}\n", .{ scenario.name, scenario.iters, ns_per_iter, 0 });
}

fn fixedSize(width: f32, height: f32) zlay.Style {
    return .{ .size = .{ .width = zlay.Dimension.length(width), .height = zlay.Dimension.length(height) } };
}

fn benchTreeCreation(allocator: std.mem.Allocator) !void {
    var tree = zlay.TaffyTree.init(allocator);
    defer tree.deinit();
    const root = try tree.new_leaf(.{});
    for (0..10_000) |_| {
        const child = try tree.new_leaf(.{});
        try tree.add_child(root, child);
    }
}

fn benchFlexRow(allocator: std.mem.Allocator) !void {
    var tree = zlay.TaffyTree.init(allocator);
    defer tree.deinit();
    const children = try allocator.alloc(zlay.NodeId, 1000);
    defer allocator.free(children);
    for (children) |*child| {
        child.* = try tree.new_leaf(.{
            .size = .{ .width = zlay.Dimension.length(10), .height = zlay.Dimension.length(10) },
            .flex_grow = 1,
            .flex_shrink = 1,
            .margin = .{
                .left = zlay.LengthPercentageAuto.length(1),
                .right = zlay.LengthPercentageAuto.length(1),
                .top = zlay.LengthPercentageAuto.zero(),
                .bottom = zlay.LengthPercentageAuto.zero(),
            },
        });
    }
    const root = try tree.new_with_children(.{
        .display = .flex,
        .size = .{ .width = zlay.Dimension.length(2000), .height = zlay.Dimension.length(100) },
    }, children);
    try tree.compute_layout(root, .{ .width = .{ .definite = 2000 }, .height = .{ .definite = 100 } });
}

fn benchFlexWrap(allocator: std.mem.Allocator) !void {
    var tree = zlay.TaffyTree.init(allocator);
    defer tree.deinit();
    const children = try allocator.alloc(zlay.NodeId, 500);
    defer allocator.free(children);
    for (children) |*child| {
        child.* = try tree.new_leaf(fixedSize(60, 10));
    }
    const root = try tree.new_with_children(.{
        .display = .flex,
        .flex_wrap = .wrap,
        .align_content = zlay.AlignContent.center,
        .size = .{ .width = zlay.Dimension.length(400), .height = zlay.Dimension.auto },
        .gap = .{ .width = zlay.LengthPercentage.length(5), .height = zlay.LengthPercentage.length(5) },
    }, children);
    try tree.compute_layout(root, .{ .width = .{ .definite = 400 }, .height = .max_content });
}

fn benchGrid(allocator: std.mem.Allocator) !void {
    var tree = zlay.TaffyTree.init(allocator);
    defer tree.deinit();
    const children = try allocator.alloc(zlay.NodeId, 2500);
    defer allocator.free(children);
    for (children) |*child| {
        child.* = try tree.new_leaf(fixedSize(5, 5));
    }
    const columns = try allocator.alloc(zlay.GridTemplateComponent, 50);
    defer allocator.free(columns);
    for (columns) |*column| column.* = .{ .single = zlay.TrackSizingFunction.from_length(10) };
    const rows = try allocator.alloc(zlay.GridTemplateComponent, 50);
    defer allocator.free(rows);
    for (rows) |*row| row.* = .{ .single = zlay.TrackSizingFunction.from_length(10) };
    const root = try tree.new_with_children(.{
        .display = .grid,
        .grid_template_columns = columns,
        .grid_template_rows = rows,
        .size = .{ .width = zlay.Dimension.length(500), .height = zlay.Dimension.length(500) },
    }, children);
    try tree.compute_layout(root, .{ .width = .{ .definite = 500 }, .height = .{ .definite = 500 } });
}

fn benchBlockNested(allocator: std.mem.Allocator) !void {
    var tree = zlay.TaffyTree.init(allocator);
    defer tree.deinit();
    var parent = try tree.new_leaf(.{ .display = .block });
    const chain_top = parent;
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
    }, &[_]zlay.NodeId{chain_top});
    try tree.compute_layout(root, .{ .width = .{ .definite = 500 }, .height = .max_content });
}

fn benchMixed(allocator: std.mem.Allocator) !void {
    var tree = zlay.TaffyTree.init(allocator);
    defer tree.deinit();
    const grid_children = try allocator.alloc(zlay.NodeId, 100);
    defer allocator.free(grid_children);
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
    defer allocator.free(flex_children);
    for (flex_children, 0..) |*child, i| {
        if (i == 0) {
            child.* = grid;
        } else {
            child.* = try tree.new_leaf(.{ .size = .{
                .width = zlay.Dimension.length(20),
                .height = zlay.Dimension.length(20),
            } });
        }
    }
    const root = try tree.new_with_children(.{
        .display = .flex,
        .flex_wrap = .wrap,
        .size = .{ .width = zlay.Dimension.length(800), .height = zlay.Dimension.auto },
    }, flex_children);
    try tree.compute_layout(root, .{ .width = .{ .definite = 800 }, .height = .max_content });
}
