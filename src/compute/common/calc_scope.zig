//! Binds a host tree's `LayoutTree.calc` hook as the thread's active calc
//! resolver for the duration of a layout algorithm call.

const calc = @import("../../style/calc.zig");
const LayoutTree = @import("../../tree/interfaces.zig").LayoutTree;

/// Install `tree`'s calc hook; returns the previous resolver for `restore`.
pub inline fn bind(comptime Tree: type, tree: *const Tree) ?calc.Resolver {
    const previous = calc.current;
    calc.current = .{ .ctx = @ptrCast(tree), .func = Adapter(Tree).resolve };
    return previous;
}

pub inline fn restore(previous: ?calc.Resolver) void {
    calc.current = previous;
}

fn Adapter(comptime Tree: type) type {
    return struct {
        fn resolve(ctx: *const anyopaque, value: *const anyopaque, basis: f32) f32 {
            const tree: *const Tree = @ptrCast(@alignCast(ctx));
            return LayoutTree(Tree).calc(tree, value, basis) orelse 0;
        }
    };
}
