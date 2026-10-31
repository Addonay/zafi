//! A bump allocator with stack marks, used for layout-pass temporaries.
//!
//! Allocation bumps through a list of retained chunks. `mark()` records the
//! current top and `release(mark)` pops everything allocated since, so a
//! caller that knows a subtree's temporaries are dead (e.g. a child layout
//! that returned no out-of-flow candidates) can reclaim them immediately.
//! Peak memory is then the deepest live working set rather than everything a
//! layout pass ever allocated, while allocation stays a pointer bump and the
//! chunks are kept across passes. Freeing or resizing the most recent
//! allocation is also reclaimed in place (LIFO), like `std.heap.ArenaAllocator`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const ScratchStack = struct {
    backing: Allocator,
    chunks: std.ArrayListUnmanaged([]u8) = .empty,
    /// Index of the chunk currently being bumped (`chunks.items.len` when none).
    chunk: usize = 0,
    /// Bytes used in the current chunk.
    offset: usize = 0,

    const min_chunk_size = 16 * 1024;

    pub const Mark = struct { chunk: usize, offset: usize };

    pub fn init(backing: Allocator) ScratchStack {
        return .{ .backing = backing };
    }

    pub fn deinit(self: *ScratchStack) void {
        for (self.chunks.items) |c| self.backing.free(c);
        self.chunks.deinit(self.backing);
        self.* = .{ .backing = self.backing };
    }

    /// Pop everything (keeping the chunks for reuse).
    pub fn reset(self: *ScratchStack) void {
        self.chunk = 0;
        self.offset = 0;
    }

    pub fn mark(self: *const ScratchStack) Mark {
        return .{ .chunk = self.chunk, .offset = self.offset };
    }

    /// Pop everything allocated since `m`. Memory allocated after the mark
    /// must no longer be referenced.
    pub fn release(self: *ScratchStack, m: Mark) void {
        std.debug.assert(m.chunk < self.chunk or (m.chunk == self.chunk and m.offset <= self.offset));
        // Debug builds poison released memory so a stale reference reads garbage
        // (and trips assertions) instead of silently reading reused data.
        if (@import("builtin").mode == .debug and m.chunk < self.chunks.items.len) {
            if (m.chunk == self.chunk) {
                @memset(self.chunks.items[m.chunk][m.offset..self.offset], 0xAA);
            } else {
                @memset(self.chunks.items[m.chunk][m.offset..], 0xAA);
                for (self.chunks.items[m.chunk + 1 .. self.chunk]) |c| @memset(c, 0xAA);
                if (self.chunk < self.chunks.items.len) @memset(self.chunks.items[self.chunk][0..self.offset], 0xAA);
            }
        }
        self.chunk = m.chunk;
        self.offset = m.offset;
    }

    /// Bytes held from the backing allocator.
    pub fn capacity(self: *const ScratchStack) usize {
        var total: usize = 0;
        for (self.chunks.items) |c| total += c.len;
        return total;
    }

    pub fn allocator(self: *ScratchStack) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Bump `len` bytes in chunk `index` from `offset`, if they fit.
    inline fn bumpIn(self: *ScratchStack, index: usize, offset: usize, len: usize, alignment: Alignment) ?[*]u8 {
        const c = self.chunks.items[index];
        const base = @intFromPtr(c.ptr);
        const start = alignment.forward(base + offset) - base;
        if (start + len > c.len) return null;
        self.chunk = index;
        self.offset = start + len;
        return c.ptr + start;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *ScratchStack = @ptrCast(@alignCast(ctx));
        if (self.chunk < self.chunks.items.len) {
            if (self.bumpIn(self.chunk, self.offset, len, alignment)) |p| return p;
            // Move on to the next retained chunk if it is big enough.
            if (self.chunk + 1 < self.chunks.items.len) {
                if (self.bumpIn(self.chunk + 1, 0, len, alignment)) |p| return p;
            }
        }
        // Nothing fits. Every chunk after the current one is free (stack
        // discipline), so replace them all with one chunk big enough for this
        // request and at least their combined size: capacity converges on the
        // peak working set instead of growing by doubling.
        const at = if (self.chunk < self.chunks.items.len) self.chunk + 1 else self.chunks.items.len;
        var freed: usize = 0;
        for (self.chunks.items[at..]) |c| freed += c.len;
        const size = @max(min_chunk_size, freed, len + alignment.toByteUnits());
        const new_chunk = self.backing.alloc(u8, size) catch return null;
        for (self.chunks.items[at..]) |c| self.backing.free(c);
        self.chunks.shrinkRetainingCapacity(at);
        self.chunks.append(self.backing, new_chunk) catch {
            self.backing.free(new_chunk);
            return null;
        };
        return self.bumpIn(at, 0, len, alignment);
    }

    /// Whether `memory` is the most recent allocation in the current chunk.
    inline fn isTop(self: *const ScratchStack, memory: []u8) bool {
        if (self.chunk >= self.chunks.items.len) return false;
        const c = self.chunks.items[self.chunk];
        return @intFromPtr(memory.ptr) + memory.len == @intFromPtr(c.ptr) + self.offset;
    }

    fn resize(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        const self: *ScratchStack = @ptrCast(@alignCast(ctx));
        if (!self.isTop(memory)) return new_len <= memory.len;
        const c = self.chunks.items[self.chunk];
        const start = @intFromPtr(memory.ptr) - @intFromPtr(c.ptr);
        if (start + new_len > c.len) return false;
        self.offset = start + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const self: *ScratchStack = @ptrCast(@alignCast(ctx));
        if (self.isTop(memory)) self.offset -= memory.len;
    }
};

test "scratch stack bumps, pops LIFO frees and releases to marks" {
    const testing = std.testing;
    var stack = ScratchStack.init(testing.allocator);
    defer stack.deinit();
    const a = stack.allocator();

    const x = try a.alloc(u32, 10);
    const m = stack.mark();
    const y = try a.alloc(u8, 100);
    a.free(y); // LIFO free reclaims in place
    try testing.expectEqual(m, stack.mark());
    _ = try a.alloc(u64, 4);
    stack.release(m);
    try testing.expectEqual(m, stack.mark());
    // A large allocation spills into a new chunk; releasing returns to the first.
    const big = try a.alloc(u8, 64 * 1024);
    @memset(big, 1);
    stack.release(m);
    try testing.expectEqual(m, stack.mark());
    // Growing the top allocation in place
    var list = std.ArrayList(u32).empty;
    for (0..1000) |i| try list.append(a, @intCast(i));
    try testing.expectEqual(@as(u32, 999), list.items[999]);
    x[0] = 7;
    try testing.expectEqual(@as(u32, 7), x[0]);
    stack.reset();
    try testing.expectEqual(@as(usize, 0), stack.mark().offset);
}
