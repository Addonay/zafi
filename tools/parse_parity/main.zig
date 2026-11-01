//! CSS parser parity: zafi's `from_str` parsers against Taffy's.
//!
//! Reads `tools/parse_oracle/expected.txt` (`Type<TAB>input<TAB>result`, where
//! result is Taffy's serde JSON for the parsed value or `ERR`; regenerate with
//! the Rust oracle in `tools/parse_oracle`) and parses every input with zafi.
//! A case passes when zafi's Taffy-compatible JSON (or `ERR`) is identical.
//!
//! Every case also runs under a failing allocator, at each allocation index:
//! an allocation failure must surface as `error.OutOfMemory` and nothing may
//! leak, on success and on every error path.
//!
//!   cd tools && zig build parse-parity [-- --verbose]

const std = @import("std");
const zafi = @import("zafi");
const json = @import("serde").json;
const grid = zafi.style.grid;

const Outcome = union(enum) { ok: []const u8, err };

fn emit(gpa: std.mem.Allocator, value: anytype) ![]const u8 {
    return json.toSlice(gpa, value);
}

/// Parse `input` as `ty` with `alloc`, serializing a success with `gpa`.
/// Parser allocations come from `alloc`; the caller checks it for leaks.
fn run(ty: []const u8, input: []const u8, alloc: std.mem.Allocator, gpa: std.mem.Allocator) !Outcome {
    const S = struct {
        fn simple(comptime T: type, in: []const u8, g: std.mem.Allocator) !Outcome {
            const value = T.from_str(in) catch |e| return if (e == error.OutOfMemory) e else .err;
            return .{ .ok = try emit(g, value) };
        }
    };
    const eq = std.mem.eql;
    if (eq(u8, ty, "Display")) return S.simple(zafi.Display, input, gpa);
    if (eq(u8, ty, "Position")) return S.simple(zafi.Position, input, gpa);
    if (eq(u8, ty, "BoxSizing")) return S.simple(zafi.BoxSizing, input, gpa);
    if (eq(u8, ty, "Overflow")) return S.simple(zafi.Overflow, input, gpa);
    if (eq(u8, ty, "Direction")) return S.simple(zafi.style.Direction, input, gpa);
    if (eq(u8, ty, "Contain")) return S.simple(zafi.Contain, input, gpa);
    if (eq(u8, ty, "FlexWrap")) return S.simple(zafi.FlexWrap, input, gpa);
    if (eq(u8, ty, "FlexDirection")) return S.simple(zafi.FlexDirection, input, gpa);
    if (eq(u8, ty, "TextAlign")) return S.simple(zafi.TextAlign, input, gpa);
    if (eq(u8, ty, "Float")) return S.simple(zafi.Float, input, gpa);
    if (eq(u8, ty, "Clear")) return S.simple(zafi.Clear, input, gpa);
    if (eq(u8, ty, "AlignItems")) return S.simple(zafi.AlignItems, input, gpa);
    if (eq(u8, ty, "AlignContent")) return S.simple(zafi.AlignContent, input, gpa);
    if (eq(u8, ty, "LengthPercentage")) return S.simple(zafi.LengthPercentage, input, gpa);
    if (eq(u8, ty, "LengthPercentageAuto")) return S.simple(zafi.LengthPercentageAuto, input, gpa);
    if (eq(u8, ty, "Dimension")) return S.simple(zafi.Dimension, input, gpa);
    if (eq(u8, ty, "AvailableSpace")) return S.simple(zafi.AvailableSpace, input, gpa);
    if (eq(u8, ty, "GridAutoFlow")) return S.simple(zafi.GridAutoFlow, input, gpa);
    if (eq(u8, ty, "GridPlacement")) return S.simple(zafi.GridPlacement, input, gpa);
    if (eq(u8, ty, "MinTrackSizingFunction")) return S.simple(zafi.MinTrackSizingFunction, input, gpa);
    if (eq(u8, ty, "MaxTrackSizingFunction")) return S.simple(zafi.MaxTrackSizingFunction, input, gpa);
    if (eq(u8, ty, "TrackSizingFunction")) return S.simple(zafi.TrackSizingFunction, input, gpa);
    if (eq(u8, ty, "RepetitionCount")) return S.simple(zafi.RepetitionCount, input, gpa);
    if (eq(u8, ty, "GridTemplateComponent")) {
        var value = grid.GridTemplateComponent.from_str(alloc, input) catch |e| return if (e == error.OutOfMemory) e else .err;
        defer value.deinit(alloc);
        return .{ .ok = try emit(gpa, value) };
    }
    if (eq(u8, ty, "GridTemplateTracks")) {
        var value = grid.GridTemplateTracks.from_str(alloc, input) catch |e| return if (e == error.OutOfMemory) e else .err;
        defer value.deinit(alloc);
        return .{ .ok = try emit(gpa, value) };
    }
    if (eq(u8, ty, "GridTemplateComponents")) {
        var value = grid.GridTemplateComponents.from_str(alloc, input) catch |e| return if (e == error.OutOfMemory) e else .err;
        defer value.deinit(alloc);
        return .{ .ok = try emit(gpa, value) };
    }
    if (eq(u8, ty, "GridAutoTracks")) {
        const value = grid.grid_auto_tracks_from_str(alloc, input) catch |e| return if (e == error.OutOfMemory) e else .err;
        defer alloc.free(value);
        return .{ .ok = try emit(gpa, value) };
    }
    std.debug.panic("unknown type {s}", .{ty});
}

/// JSON equality with numbers compared by value (serde_json prints `1.0`
/// where serde.zig prints `1`; both read back as the same f32).
fn sameJson(arena: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (std.mem.eql(u8, a, "ERR") or std.mem.eql(u8, b, "ERR")) return false;
    const va = std.json.parseFromSliceLeaky(std.json.Value, arena, a, .{}) catch return false;
    const vb = std.json.parseFromSliceLeaky(std.json.Value, arena, b, .{}) catch return false;
    return sameValue(va, vb);
}

fn number(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn sameValue(a: std.json.Value, b: std.json.Value) bool {
    if (number(a)) |x| return if (number(b)) |y| x == y else false;
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .number_string => |x| b == .number_string and std.mem.eql(u8, x, b.number_string),
        .array => |x| b == .array and x.items.len == b.array.items.len and for (x.items, b.array.items) |l, r| {
            if (!sameValue(l, r)) break false;
        } else true,
        .object => |x| b == .object and x.count() == b.object.count() and blk: {
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!sameValue(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Counts live bytes so leaks are attributable to one case.
const Counting = struct {
    child: std.mem.Allocator,
    live: isize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.live += @intCast(len);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, a, n, ra)) return false;
        self.live += @as(isize, @intCast(n)) - @as(isize, @intCast(m.len));
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(m, a, n, ra) orelse return null;
        self.live += @as(isize, @intCast(n)) - @as(isize, @intCast(m.len));
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.live -= @intCast(m.len);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(arena);
    var verbose = false;
    var path: []const u8 = "tools/parse_oracle/expected.txt";
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) verbose = true else path = arg;
    }
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);

    var total: usize = 0;
    var failed: usize = 0;
    var mem_failed: usize = 0;
    var per_type = std.StringArrayHashMapUnmanaged([2]usize).empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const ty = cols.next().?;
        const input = cols.next().?;
        const expected = cols.rest();
        total += 1;
        const entry = try per_type.getOrPut(arena, ty);
        if (!entry.found_existing) entry.value_ptr.* = .{ 0, 0 };
        entry.value_ptr[0] += 1;

        var counting: Counting = .{ .child = gpa };
        const outcome = try run(ty, input, counting.allocator(), gpa);
        const got: []const u8 = switch (outcome) {
            .ok => |s| s,
            .err => "ERR",
        };
        if (!sameJson(arena, got, expected)) {
            failed += 1;
            entry.value_ptr[1] += 1;
            if (verbose) std.debug.print("MISMATCH {s} '{s}': taffy {s}, zafi {s}\n", .{ ty, input, expected, got });
        }
        if (counting.live != 0) {
            mem_failed += 1;
            if (verbose) std.debug.print("LEAK {s} '{s}': {d} bytes\n", .{ ty, input, counting.live });
        }

        // Allocation failure at every index must give OutOfMemory and leak nothing.
        var fail_index: usize = 0;
        while (fail_index < 64) : (fail_index += 1) {
            var c2: Counting = .{ .child = gpa };
            var failing = std.testing.FailingAllocator.init(c2.allocator(), .{ .fail_index = fail_index });
            const result = run(ty, input, failing.allocator(), gpa);
            if (c2.live != 0) {
                mem_failed += 1;
                if (verbose) std.debug.print("LEAK(oom@{d}) {s} '{s}': {d} bytes\n", .{ fail_index, ty, input, c2.live });
                break;
            }
            if (!failing.has_induced_failure) break; // ran to completion without hitting the failure
            if (result) |_| {
                mem_failed += 1;
                if (verbose) std.debug.print("SWALLOWED OOM @{d} {s} '{s}'\n", .{ fail_index, ty, input });
                break;
            } else |e| if (e != error.OutOfMemory) return e;
        }
    }
    std.debug.print("\n=== parse parity vs Taffy ===\n", .{});
    var it = per_type.iterator();
    while (it.next()) |e| {
        if (e.value_ptr[1] != 0) std.debug.print("{s:24} {d:5} cases {d:5} mismatches\n", .{ e.key_ptr.*, e.value_ptr[0], e.value_ptr[1] });
    }
    std.debug.print("total: {d} cases, {d} mismatches, {d} memory failures (leak / swallowed OOM)\n", .{ total, failed, mem_failed });
    if (failed != 0 or mem_failed != 0) std.process.exit(1);
}
