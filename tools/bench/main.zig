//! Layout benchmarks covering Taffy's benchmark categories: tree creation,
//! flexbox, grid, block, and mixed trees. Run with release optimizations:
//!
//!   zig build bench -Doptimize=ReleaseFast
//!   zig build bench -Doptimize=ReleaseFast -- --filter grid
//!
//! Each scenario builds a fresh tree, lays it out once and tears it down per
//! iteration, so the numbers are cold-cache build+layout costs. Memory is the
//! peak live bytes through a general-purpose allocator, which is what the Rust
//! mirror reports for Taffy.

const std = @import("std");
const zafi = @import("zafi");

const ScenarioFn = *const fn (allocator: std.mem.Allocator) anyerror!void;

const Scenario = struct {
    name: []const u8,
    iters: usize,
    run: ScenarioFn,
};

const scenarios = [_]Scenario{
    .{ .name = "tree_creation_10k", .iters = 20, .run = benchTreeCreation },
    .{ .name = "flex_row_1000", .iters = 20, .run = benchFlexRow },
    .{ .name = "flex_wrap_500", .iters = 20, .run = benchFlexWrap },
    .{ .name = "grid_50x50", .iters = 10, .run = benchGrid },
    .{ .name = "block_nested_50", .iters = 30, .run = benchBlockNested },
    .{ .name = "mixed_flex_grid_block", .iters = 10, .run = benchMixed },
};

/// A scenario whose state (the tree) lives across iterations.
const Stateful = struct {
    name: []const u8,
    iters: usize,
    run: *const fn (io: std.Io, allocator: std.mem.Allocator, iters: usize) anyerror!u64,
};

const stateful_scenarios = [_]Stateful{
    .{ .name = "rebuild_flex_1000", .iters = 50, .run = benchRebuild },
    .{ .name = "relayout_grid_50x50", .iters = 50, .run = benchRelayout },
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

    std.debug.print("bench|scenario|iters|ns_per_iter|peak_live_bytes|allocs_per_iter\n", .{});
    for (scenarios) |scenario| {
        if (filter) |needle| {
            if (std.mem.indexOf(u8, scenario.name, needle) == null) continue;
        }
        try measure(io, scenario);
    }
    for (stateful_scenarios) |scenario| {
        if (filter) |needle| {
            if (std.mem.indexOf(u8, scenario.name, needle) == null) continue;
        }
        var counting = CountingAllocator{ .backing = if (@import("builtin").link_libc) std.heap.c_allocator else std.heap.smp_allocator };
        const total_ns = try scenario.run(io, counting.allocator(), scenario.iters);
        if (counting.live != 0) std.debug.print("warning: {s} leaked {d} bytes\n", .{ scenario.name, counting.live });
        std.debug.print("bench|{s}|{d}|{d}|{d}|{d}\n", .{ scenario.name, scenario.iters, total_ns / scenario.iters, counting.peak, counting.allocations / (scenario.iters + 1) });
    }
}

/// Immediate-mode pattern: one long-lived tree, cleared and rebuilt every frame.
fn benchRebuild(io: std.Io, allocator: std.mem.Allocator, iters: usize) !u64 {
    var tree = zafi.Tree.init(allocator);
    defer tree.deinit();
    const children = try allocator.alloc(zafi.NodeId, 1000);
    defer allocator.free(children);
    try rebuildStep(&tree, children); // warm-up
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iters) |_| try rebuildStep(&tree, children);
    return @intCast(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds);
}

fn rebuildStep(tree: *zafi.Tree, children: []zafi.NodeId) !void {
    tree.clear();
    for (children) |*child| {
        child.* = try tree.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(10), .height = zafi.Dimension.length(10) },
            .flex_grow = 1,
            .flex_shrink = 1,
            .margin = .{
                .left = zafi.LengthPercentageAuto.length(1),
                .right = zafi.LengthPercentageAuto.length(1),
                .top = zafi.LengthPercentageAuto.zero(),
                .bottom = zafi.LengthPercentageAuto.zero(),
            },
        });
    }
    const root = try tree.new_with_children(.{
        .display = .flex,
        .size = .{ .width = zafi.Dimension.length(2000), .height = zafi.Dimension.length(100) },
    }, children);
    try tree.compute_layout(root, .{ .width = .{ .definite = 2000 }, .height = .{ .definite = 100 } });
}

/// Retained-UI pattern: one built tree; each frame one leaf changes size and
/// the tree is re-laid out.
fn benchRelayout(io: std.Io, allocator: std.mem.Allocator, iters: usize) !u64 {
    var tree = zafi.Tree.init(allocator);
    defer tree.deinit();
    const leaves = try allocator.alloc(zafi.NodeId, 2500);
    defer allocator.free(leaves);
    for (leaves) |*leaf| leaf.* = try tree.new_leaf(fixedSize(5, 5));
    const auto_track = zafi.GridTemplateComponent{ .single = zafi.TrackSizingFunction.auto };
    const columns = try allocator.alloc(zafi.GridTemplateComponent, 50);
    defer allocator.free(columns);
    @memset(columns, auto_track);
    const rows = try allocator.alloc(zafi.GridTemplateComponent, 50);
    defer allocator.free(rows);
    @memset(rows, auto_track);
    const root = try tree.new_with_children(.{
        .display = .grid,
        .grid_template_columns = columns,
        .grid_template_rows = rows,
        .size = .{ .width = zafi.Dimension.length(500), .height = zafi.Dimension.length(500) },
    }, leaves);
    var frame: usize = 0;
    try relayoutStep(&tree, root, leaves, &frame); // initial layout
    try relayoutStep(&tree, root, leaves, &frame); // warm-up
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iters) |_| try relayoutStep(&tree, root, leaves, &frame);
    return @intCast(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds);
}

fn relayoutStep(tree: *zafi.Tree, root: zafi.NodeId, leaves: []const zafi.NodeId, frame: *usize) !void {
    frame.* += 1;
    const leaf = leaves[(frame.* * 37) % leaves.len];
    const side: f32 = if (frame.* % 2 == 0) 5 else 6;
    try tree.set_style(leaf, fixedSize(side, side));
    try tree.compute_layout(root, .{ .width = .{ .definite = 500 }, .height = .{ .definite = 500 } });
}

/// Counts live and peak bytes through a backing allocator, so the reported
/// memory is the peak live working set, measured exactly as the Rust mirror's
/// counting `GlobalAlloc` measures Taffy.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,
    allocations: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    /// Atomic read-modify-writes, matching the Rust mirror's counting
    /// `GlobalAlloc`, so neither side's instrumentation is cheaper.
    fn grow(self: *CountingAllocator, old: usize, new: usize) void {
        const live = if (new >= old)
            @atomicRmw(usize, &self.live, .Add, new - old, .monotonic) + (new - old)
        else
            @atomicRmw(usize, &self.live, .Sub, old - new, .monotonic) - (old - new);
        _ = @atomicRmw(usize, &self.peak, .Max, live, .monotonic);
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret) orelse return null;
        _ = @atomicRmw(usize, &self.allocations, .Add, 1, .monotonic);
        self.grow(0, len);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret)) return false;
        self.grow(memory.len, new_len);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret) orelse return null;
        self.grow(memory.len, new_len);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret);
        self.grow(memory.len, 0);
    }
};

fn measure(io: std.Io, scenario: Scenario) !void {
    // A general-purpose allocator (like Rust's system malloc), with every tree
    // built and torn down inside the iteration, as the Rust mirror drops its tree.
    var counting = CountingAllocator{ .backing = if (@import("builtin").link_libc) std.heap.c_allocator else std.heap.smp_allocator };
    const allocator = counting.allocator();

    // Warm-up (also faults in the allocator's pages).
    try scenario.run(allocator);
    std.debug.assert(counting.live == 0);
    counting.peak = 0;
    counting.allocations = 0;

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..scenario.iters) |_| try scenario.run(allocator);
    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
    const total_ns: u64 = @intCast(elapsed.raw.nanoseconds);
    const ns_per_iter = total_ns / scenario.iters;
    if (counting.live != 0) std.debug.print("warning: {s} leaked {d} bytes\n", .{ scenario.name, counting.live });

    std.debug.print("bench|{s}|{d}|{d}|{d}|{d}\n", .{ scenario.name, scenario.iters, ns_per_iter, counting.peak, counting.allocations / scenario.iters });
}

fn fixedSize(width: f32, height: f32) zafi.Style {
    return .{ .size = .{ .width = zafi.Dimension.length(width), .height = zafi.Dimension.length(height) } };
}

fn benchTreeCreation(allocator: std.mem.Allocator) !void {
    var tree = zafi.Tree.init(allocator);
    defer tree.deinit();
    const root = try tree.new_leaf(.{});
    for (0..10_000) |_| {
        const child = try tree.new_leaf(.{});
        try tree.add_child(root, child);
    }
}

fn benchFlexRow(allocator: std.mem.Allocator) !void {
    var tree = zafi.Tree.init(allocator);
    defer tree.deinit();
    const children = try allocator.alloc(zafi.NodeId, 1000);
    defer allocator.free(children);
    for (children) |*child| {
        child.* = try tree.new_leaf(.{
            .size = .{ .width = zafi.Dimension.length(10), .height = zafi.Dimension.length(10) },
            .flex_grow = 1,
            .flex_shrink = 1,
            .margin = .{
                .left = zafi.LengthPercentageAuto.length(1),
                .right = zafi.LengthPercentageAuto.length(1),
                .top = zafi.LengthPercentageAuto.zero(),
                .bottom = zafi.LengthPercentageAuto.zero(),
            },
        });
    }
    const root = try tree.new_with_children(.{
        .display = .flex,
        .size = .{ .width = zafi.Dimension.length(2000), .height = zafi.Dimension.length(100) },
    }, children);
    try tree.compute_layout(root, .{ .width = .{ .definite = 2000 }, .height = .{ .definite = 100 } });
}

fn benchFlexWrap(allocator: std.mem.Allocator) !void {
    var tree = zafi.Tree.init(allocator);
    defer tree.deinit();
    const children = try allocator.alloc(zafi.NodeId, 500);
    defer allocator.free(children);
    for (children) |*child| {
        child.* = try tree.new_leaf(fixedSize(60, 10));
    }
    const root = try tree.new_with_children(.{
        .display = .flex,
        .flex_wrap = .wrap,
        .align_content = zafi.AlignContent.center,
        .size = .{ .width = zafi.Dimension.length(400), .height = zafi.Dimension.auto },
        .gap = .{ .width = zafi.LengthPercentage.length(5), .height = zafi.LengthPercentage.length(5) },
    }, children);
    try tree.compute_layout(root, .{ .width = .{ .definite = 400 }, .height = .max_content });
}

fn benchGrid(allocator: std.mem.Allocator) !void {
    var tree = zafi.Tree.init(allocator);
    defer tree.deinit();
    const children = try allocator.alloc(zafi.NodeId, 2500);
    defer allocator.free(children);
    for (children) |*child| {
        child.* = try tree.new_leaf(fixedSize(5, 5));
    }
    const columns = try allocator.alloc(zafi.GridTemplateComponent, 50);
    defer allocator.free(columns);
    for (columns) |*column| column.* = .{ .single = zafi.TrackSizingFunction.from_length(10) };
    const rows = try allocator.alloc(zafi.GridTemplateComponent, 50);
    defer allocator.free(rows);
    for (rows) |*row| row.* = .{ .single = zafi.TrackSizingFunction.from_length(10) };
    const root = try tree.new_with_children(.{
        .display = .grid,
        .grid_template_columns = columns,
        .grid_template_rows = rows,
        .size = .{ .width = zafi.Dimension.length(500), .height = zafi.Dimension.length(500) },
    }, children);
    try tree.compute_layout(root, .{ .width = .{ .definite = 500 }, .height = .{ .definite = 500 } });
}

fn benchBlockNested(allocator: std.mem.Allocator) !void {
    var tree = zafi.Tree.init(allocator);
    defer tree.deinit();
    const top = try tree.new_leaf(.{ .display = .block });
    var parent = top;
    for (0..50) |_| {
        const child = try tree.new_leaf(.{
            .display = .block,
            .margin = .{
                .left = zafi.LengthPercentageAuto.zero(),
                .right = zafi.LengthPercentageAuto.zero(),
                .top = zafi.LengthPercentageAuto.length(2),
                .bottom = zafi.LengthPercentageAuto.length(2),
            },
        });
        try tree.add_child(parent, child);
        parent = child;
    }
    const root = try tree.new_with_children(.{
        .display = .block,
        .size = .{ .width = zafi.Dimension.length(500), .height = zafi.Dimension.auto },
    }, &[_]zafi.NodeId{top});
    try tree.compute_layout(root, .{ .width = .{ .definite = 500 }, .height = .max_content });
}

fn benchMixed(allocator: std.mem.Allocator) !void {
    var tree = zafi.Tree.init(allocator);
    defer tree.deinit();
    const grid_children = try allocator.alloc(zafi.NodeId, 100);
    defer allocator.free(grid_children);
    for (grid_children) |*child| {
        const block_child = try tree.new_leaf(.{ .display = .block, .margin = .{
            .left = zafi.LengthPercentageAuto.length(1),
            .right = zafi.LengthPercentageAuto.length(1),
            .top = zafi.LengthPercentageAuto.length(1),
            .bottom = zafi.LengthPercentageAuto.length(1),
        } });
        child.* = try tree.new_with_children(.{ .display = .block, .size = .{
            .width = zafi.Dimension.auto,
            .height = zafi.Dimension.auto,
        } }, &[_]zafi.NodeId{block_child});
    }
    const grid = try tree.new_with_children(.{
        .display = .grid,
        .grid_template_columns = &[_]zafi.GridTemplateComponent{
            .{ .single = zafi.TrackSizingFunction.from_fr(1) },
            .{ .single = zafi.TrackSizingFunction.from_fr(1) },
            .{ .single = zafi.TrackSizingFunction.from_fr(1) },
            .{ .single = zafi.TrackSizingFunction.from_fr(1) },
        },
        .flex_grow = 1,
    }, grid_children);
    const flex_children = try allocator.alloc(zafi.NodeId, 8);
    defer allocator.free(flex_children);
    for (flex_children, 0..) |*child, i| {
        if (i == 0) {
            child.* = grid;
        } else {
            child.* = try tree.new_leaf(.{ .size = .{
                .width = zafi.Dimension.length(20),
                .height = zafi.Dimension.length(20),
            } });
        }
    }
    const root = try tree.new_with_children(.{
        .display = .flex,
        .flex_wrap = .wrap,
        .size = .{ .width = zafi.Dimension.length(800), .height = zafi.Dimension.auto },
    }, flex_children);
    try tree.compute_layout(root, .{ .width = .{ .definite = 800 }, .height = .max_content });
}
