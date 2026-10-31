const std = @import("std");
const z = @import("zlay");
const PoisonAllocator = struct {
    arena: std.heap.ArenaAllocator,
    fn allocator(self: *PoisonAllocator) std.mem.Allocator { return .{.ptr=self,.vtable=&.{.alloc=alloc,.resize=resize,.remap=remap,.free=free}}; }
    fn alloc(ctx:*anyopaque,len:usize,alignment:std.mem.Alignment,ra:usize) ?[*]u8 {
        const self:*PoisonAllocator=@ptrCast(@alignCast(ctx));
        return self.arena.allocator().rawAlloc(len,alignment,ra);
    }
    fn resize(_: *anyopaque, _: []u8, _:std.mem.Alignment, _:usize, _:usize) bool {return false;}
    fn remap(_: *anyopaque, _: []u8, _:std.mem.Alignment, _:usize, _:usize) ?[*]u8 {return null;}
    fn free(_: *anyopaque, memory: []u8, _:std.mem.Alignment, _:usize) void {@memset(memory,0xdd);}
};
pub fn main() !void {
    const a = std.heap.page_allocator;
    std.debug.print("sizes Style={d} NodeData={d} Cache={d} Layout={d} NodeId={d}\n", .{ @sizeOf(z.Style), @sizeOf(z.tree.taffy_tree.NodeData), @sizeOf(z.tree.cache.Cache), @sizeOf(z.Layout), @sizeOf(z.NodeId) });
    {
        var t = z.TaffyTree.init(a); defer t.deinit();
        const c = try t.new_leaf(.{});
        const p = try t.new_with_children(.{}, &.{c});
        try t.add_child(p, c);
        _ = try t.remove_child(p, c);
        std.debug.print("duplicate_remove remaining={d} child_parent={any}\n", .{try t.child_count(p), try t.parent(c)});
    }
    {
        var t = z.TaffyTree.init(a); defer t.deinit();
        const c = try t.new_leaf(.{});
        const p = try t.new_with_children(.{}, &.{c});
        const borrowed = try t.children(p);
        const err = if(t.set_children(p, borrowed)) |_| "success" else |e| @errorName(e);
        std.debug.print("aliased_set_children error={s} count={d} child_parent={any}\n", .{err,try t.child_count(p), try t.parent(c)});
    }
    {
        var t = z.TaffyTree.init(a); defer t.deinit();
        const c = try t.new_leaf(.{});
        const p = try t.new_with_children(.{}, &.{c});
        const err = if (t.replace_child_at_index(p, 0, 99999)) |_| "success" else |e| @errorName(e);
        std.debug.print("invalid_replace error={s} count={d} child_parent={any}\n", .{err, try t.child_count(p), try t.parent(c)});
        const before = t.total_node_count();
        _ = t.new_with_children(.{}, &.{99999}) catch 0;
        std.debug.print("invalid_new_with_children before={d} after={d}\n", .{before, t.total_node_count()});
    }
    {
        var t = z.TaffyTree.init(a); defer t.deinit();
        const old = try t.new_leaf(.{}); t.clear();
        const fresh = try t.new_leaf(.{});
        std.debug.print("clear_ids old={d} new={d} stale_valid={any}\n", .{old, fresh, t.style_ptr(old) != null});
    }
    {
        var t = z.TaffyTree.init(a); defer t.deinit();
        const p = try t.new_leaf(.{}); try t.add_child(p, p);
        std.debug.print("self_cycle parent={any} child_count={d}\n", .{try t.parent(p), try t.child_count(p)});
    }
    {
        var t = z.TaffyTree.init(a); defer t.deinit();
        const p = try t.new_leaf(.{}); const c = try t.new_leaf(.{});
        try t.add_child(p,c); try t.add_child(c,p);
        std.debug.print("ancestor_cycle p_parent={any} c_parent={any}\n", .{try t.parent(p), try t.parent(c)});
    }
    {
        var t = z.TaffyTree.init(a); defer t.deinit();
        const c = try t.new_leaf(.{.size=.{.width=.length(10),.height=.length(10)}});
        const p = try t.new_with_children(.{.display=.block}, &.{c});
        const space = z.Size(z.AvailableSpace){.width=.{.definite=100},.height=.max_content};
        try t.compute_layout(p,space);
        t.cache_clear(c);
        try t.set_style(c,.{.size=.{.width=.length(10),.height=.length(30)}});
        try t.compute_layout(p,space);
        std.debug.print("clear_then_mutate root_height={d} child_height={d}\n", .{(try t.layout(p)).size.height,(try t.layout(c)).size.height});
    }
    {
        var t = z.TaffyTree.init(a); defer t.deinit();
        var columns = [_]z.GridTemplateComponent{.{.single=z.TrackSizingFunction.from_length(10)}};
        const c=try t.new_leaf(.{});
        const p=try t.new_with_children(.{.display=.grid,.grid_template_columns=&columns},&.{c});
        const space=z.Size(z.AvailableSpace){.width=.max_content,.height=.max_content};
        try t.compute_layout(p,space);
        columns[0]=.{.single=z.TrackSizingFunction.from_length(80)};
        try t.compute_layout(p,space);
        const cached=(try t.layout(p)).size.width;
        t.mark_dirty(p); try t.compute_layout(p,space);
        std.debug.print("borrowed_style_mutation cached={d} dirty={d}\n", .{cached,(try t.layout(p)).size.width});
    }
    {
        var f=std.testing.FailingAllocator.init(a,.{.fail_index=1});
        var t=z.TaffyTree.init(f.allocator());
        _=t.new_leaf(.{}) catch 0;
        t.deinit();
        std.debug.print("failed_page_append allocated={d} freed={d} leaked={d}\n", .{f.allocated_bytes,f.freed_bytes,f.allocated_bytes-f.freed_bytes});
    }
    {
        var f=std.testing.FailingAllocator.init(a,.{});
        var t=z.TaffyTree.init(f.allocator()); defer t.deinit();
        const c=try t.new_leaf(.{}); const p=try t.new_leaf(.{});
        f.fail_index=f.alloc_index;
        const err=if(t.add_child(p,c)) |_| "success" else |e| @errorName(e);
        std.debug.print("failed_add error={s} count={d} child_parent={any}\n", .{err,try t.child_count(p),try t.parent(c)});
    }
    {
        var t=z.TaffyTree.init(a); defer t.deinit();
        for(0..1000) |_| { const n=try t.new_leaf(.{}); _=try t.remove(n); }
        std.debug.print("churn live={d} slots={d} pages={d}\n", .{t.total_node_count(),t.nodes.len,t.nodes.pages.items.len});
    }
    {
        var t=z.TaffyTree.init(a); defer t.deinit();
        const c=try t.new_leaf(.{}); const p=try t.new_with_children(.{},&.{c});
        try t.set_unrounded_layout(p,.{.location=.{.x=0.4,.y=0},.size=.{.width=10,.height=10}});
        try t.set_unrounded_layout(c,.{.location=.{.x=0.4,.y=0},.size=.{.width=1,.height=1}});
        try z.compute.round_layout(&t,p);
        std.debug.print("rounding parent_x={d} child_x={d} combined_x={d} expected_cumulative=1\n", .{(try t.layout(p)).location.x,(try t.layout(c)).location.x,(try t.layout(p)).location.x+(try t.layout(c)).location.x});
    }
    {
        var poison=PoisonAllocator{.arena=std.heap.ArenaAllocator.init(a)};
        defer poison.arena.deinit();
        var t=z.TaffyTree.init(poison.allocator()); defer t.deinit();
        const areas=try z.style.grid.parse_grid_template_areas(poison.allocator(),&.{"header"});
        const c=try t.new_leaf(.{});
        const p=try t.new_with_children(.{.display=.grid,.grid_template_areas=areas},&.{c});
        try t.compute_layout(p,.{.width=.{.definite=100},.height=.{.definite=100}});
        const detail:*const z.compute.grid.DetailedGridInfo=@ptrCast(@alignCast((try t.detailed_layout_info(p)).grid));
        const name=detail.columns.names_for_line(0)[0];
        std.debug.print("persistent_grid_name first_byte={x} expected=68 name_len={d}\n", .{name[0],name.len});
    }
    {
        var t=z.TaffyTree.init(a); defer t.deinit();
        const c=try t.new_leaf(.{.size=.{.width=.length(10),.height=.length(10)}});
        const p=try t.new_with_children(.{.display=.flow_root},&.{c});
        try t.compute_layout(p,.{.width=.{.definite=100},.height=.max_content});
        const flow_width=(try t.layout(p)).size.width;
        try t.set_style(p,.{.display=.block});
        try t.compute_layout(p,.{.width=.{.definite=100},.height=.max_content});
        std.debug.print("flow_root width={d} block_width={d}\n", .{flow_width,(try t.layout(p)).size.width});
        try t.set_style(p,.{.display=.grid});
        try t.compute_layout(p,.{.width=.{.definite=100},.height=.max_content});
        try t.set_style(p,.{.display=.flex});
        try t.compute_layout(p,.{.width=.{.definite=100},.height=.max_content});
        std.debug.print("grid_to_flex stale_grid_detail={any}\n", .{(try t.detailed_layout_info(p))==.grid});
    }
    {
        var t=z.TaffyTree.init(a); defer t.deinit();
        const c=try t.new_leaf(.{.display=.none,.size=.{.width=.length(10),.height=.length(30)}});
        const p=try t.new_with_children(.{.display=.block},&.{c});
        const space=z.Size(z.AvailableSpace){.width=.{.definite=100},.height=.max_content};
        try t.compute_layout(p,space);
        const dirty=try t.is_dirty(c);
        try t.set_style(c,.{.size=.{.width=.length(10),.height=.length(30)}});
        try t.compute_layout(p,space);
        std.debug.print("hidden_to_visible initially_dirty={any} parent_height={d} child_height={d}\n", .{dirty,(try t.layout(p)).size.height,(try t.layout(c)).size.height});
    }
}
