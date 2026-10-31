const std=@import("std");
const z=@import("zlay");
pub fn main(init:std.process.Init) !void {
    var tree=z.TaffyTree.init(std.heap.c_allocator); defer tree.deinit();
    var children:[1000]z.NodeId=undefined;
    for(&children) |*c| c.*=try tree.new_leaf(.{.size=.{.width=.length(10),.height=.length(10)},.flex_grow=1});
    const style=z.Style{.size=.{.width=.percent(1),.height=.length(100)}};
    const root=try tree.new_with_children(style,&children);
    var space=z.Size(z.AvailableSpace){.width=.{.definite=2000},.height=.{.definite=100}};
    try tree.compute_layout(root,space);
    for(0..4) |phase| {
        const iters:usize=if(phase==0) 10000 else 200;
        const start=std.Io.Clock.Timestamp.now(init.io,.awake);
        for(0..iters) |i| {
            if(phase==1) tree.mark_dirty(root);
            if(phase==2) try tree.set_style(children[500],.{.size=.{.width=.length(if(i%2==0) 11 else 10),.height=.length(10)},.flex_grow=1});
            if(phase==3) space.width=.{.definite=if(i%2==0) 2100 else 2000};
            try tree.compute_layout(root,space);
        }
        const elapsed=start.durationTo(std.Io.Clock.Timestamp.now(init.io,.awake));
        const names=[_] []const u8{"cached","root_dirty","one_child_dirty","resize"};
        std.debug.print("lifecycle|{s}|{d}|{d}|width={d}\n",.{names[phase],iters,@divTrunc(elapsed.raw.nanoseconds,iters),(try tree.layout(root)).size.width});
    }
}
