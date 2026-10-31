//! `calc()` resolution.
//!
//! `calc()` values are opaque host handles stored in `CompactLength`. The style
//! types resolve them through the resolver active on this thread, which every
//! layout algorithm entry point binds to the host tree's `LayoutTree.calc` hook
//! (see `compute/common/calc_scope.zig`). With no resolver, or a hook that
//! returns null, a calc value resolves to 0, which is Taffy's default.

pub const Resolver = struct {
    ctx: *const anyopaque,
    func: *const fn (ctx: *const anyopaque, value: *const anyopaque, basis: f32) f32,
};

/// The resolver for the layout pass running on this thread, if any.
pub threadlocal var current: ?Resolver = null;

/// Resolve a calc handle against `basis`.
pub inline fn resolve(value: ?*const anyopaque, basis: f32) f32 {
    const handle = value orelse return 0;
    const r = current orelse return 0;
    return r.func(r.ctx, handle, basis);
}
