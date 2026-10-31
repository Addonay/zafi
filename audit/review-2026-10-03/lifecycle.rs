use taffy::prelude::*;
use std::time::Instant;
fn main() {
    let mut tree:TaffyTree<String>=TaffyTree::new();
    let mut children=Vec::new();
    for _ in 0..1000 {children.push(tree.new_leaf(Style{size:Size{width:Dimension::length(10.),height:Dimension::length(10.)},flex_grow:1.,..Default::default()}).unwrap());}
    let root=tree.new_with_children(Style{size:Size{width:Dimension::percent(1.),height:Dimension::length(100.)},..Default::default()},&children).unwrap();
    let mut space=Size{width:AvailableSpace::Definite(2000.),height:AvailableSpace::Definite(100.)};
    tree.compute_layout(root,space).unwrap();
    for phase in 0..4 {
        let iters=if phase==0 {10000} else {200};
        let start=Instant::now();
        for i in 0..iters {
            if phase==1 {tree.mark_dirty(root).unwrap();}
            if phase==2 {tree.set_style(children[500],Style{size:Size{width:Dimension::length(if i%2==0 {11.} else {10.}),height:Dimension::length(10.)},flex_grow:1.,..Default::default()}).unwrap();}
            if phase==3 {space.width=AvailableSpace::Definite(if i%2==0 {2100.} else {2000.});}
            tree.compute_layout(root,space).unwrap();
        }
        println!("lifecycle|{}|{}|{}|width={}",["cached","root_dirty","one_child_dirty","resize"][phase],iters,start.elapsed().as_nanos()/iters,tree.layout(root).unwrap().size.width);
    }
}
