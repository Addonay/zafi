//! Rust mirror of `tools/bench/main.zig`: the same scenarios, iteration
//! counts and build+layout-per-iteration structure, so the two harnesses can
//! be compared directly by `tools/bench/compare.py`.
//!
//! Output: `bench|<scenario>|<iters>|<ns_per_iter>|<peak_live_bytes>`.
//! Peak live bytes come from a counting global allocator (the tree is dropped
//! inside each iteration, so this approximates a working-set peak; the Zig
//! side reports arena capacity instead).
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use taffy::prelude::*;
use taffy::style::Style;

// ---------------------------------------------------------------------------
// Counting allocator
// ---------------------------------------------------------------------------

struct CountingAllocator;

static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = System.alloc(layout);
        if !ptr.is_null() {
            let live = LIVE.fetch_add(layout.size(), Ordering::Relaxed) + layout.size();
            PEAK.fetch_max(live, Ordering::Relaxed);
        }
        ptr
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let ptr = System.alloc_zeroed(layout);
        if !ptr.is_null() {
            let live = LIVE.fetch_add(layout.size(), Ordering::Relaxed) + layout.size();
            PEAK.fetch_max(live, Ordering::Relaxed);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        System.dealloc(ptr, layout);
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let new_ptr = System.realloc(ptr, layout, new_size);
        if !new_ptr.is_null() {
            if new_size >= layout.size() {
                let delta = new_size - layout.size();
                let live = LIVE.fetch_add(delta, Ordering::Relaxed) + delta;
                PEAK.fetch_max(live, Ordering::Relaxed);
            } else {
                LIVE.fetch_sub(layout.size() - new_size, Ordering::Relaxed);
            }
        }
        new_ptr
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

// ---------------------------------------------------------------------------
// Scenarios (must match tools/bench/main.zig)
// ---------------------------------------------------------------------------

fn fixed(w: f32, h: f32) -> Style<String> {
    Style {
        size: Size { width: Dimension::length(w), height: Dimension::length(h) },
        ..Default::default()
    }
}

fn tree_creation() {
    let mut tree: TaffyTree<String> = TaffyTree::new();
    let root = tree.new_leaf(Style::default()).unwrap();
    for _ in 0..10_000 {
        let child = tree.new_leaf(Style::default()).unwrap();
        tree.add_child(root, child).unwrap();
    }
}

fn flex_row() {
    let mut tree: TaffyTree<String> = TaffyTree::new();
    let mut children = Vec::with_capacity(1000);
    for _ in 0..1000 {
        children.push(
            tree.new_leaf(Style {
                size: Size { width: Dimension::length(10.0), height: Dimension::length(10.0) },
                flex_grow: 1.0,
                flex_shrink: 1.0,
                margin: Rect {
                    left: LengthPercentageAuto::length(1.0),
                    right: LengthPercentageAuto::length(1.0),
                    top: LengthPercentageAuto::length(0.0),
                    bottom: LengthPercentageAuto::length(0.0),
                },
                ..Default::default()
            })
            .unwrap(),
        );
    }
    let root = tree
        .new_with_children(
            Style {
                display: Display::Flex,
                size: Size { width: Dimension::length(2000.0), height: Dimension::length(100.0) },
                ..Default::default()
            },
            &children,
        )
        .unwrap();
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(2000.0), height: AvailableSpace::Definite(100.0) })
        .unwrap();
}

fn flex_wrap() {
    let mut tree: TaffyTree<String> = TaffyTree::new();
    let mut children = Vec::with_capacity(500);
    for _ in 0..500 {
        children.push(tree.new_leaf(fixed(60.0, 10.0)).unwrap());
    }
    let root = tree
        .new_with_children(
            Style {
                display: Display::Flex,
                flex_wrap: FlexWrap::Wrap,
                align_content: AlignContent::CENTER,
                size: Size { width: Dimension::length(400.0), height: Dimension::auto() },
                gap: Size { width: LengthPercentage::length(5.0), height: LengthPercentage::length(5.0) },
                ..Default::default()
            },
            &children,
        )
        .unwrap();
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(400.0), height: AvailableSpace::MaxContent })
        .unwrap();
}

fn grid() {
    let mut tree: TaffyTree<String> = TaffyTree::new();
    let mut children = Vec::with_capacity(2500);
    for _ in 0..2500 {
        children.push(tree.new_leaf(fixed(5.0, 5.0)).unwrap());
    }
    let columns = vec![GridTemplateComponent::Single(TrackSizingFunction::from_length(10.0)); 50];
    let rows = vec![GridTemplateComponent::Single(TrackSizingFunction::from_length(10.0)); 50];
    let root = tree
        .new_with_children(
            Style {
                display: Display::Grid,
                grid_template_columns: columns,
                grid_template_rows: rows,
                size: Size { width: Dimension::length(500.0), height: Dimension::length(500.0) },
                ..Default::default()
            },
            &children,
        )
        .unwrap();
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(500.0), height: AvailableSpace::Definite(500.0) })
        .unwrap();
}

fn block_nested() {
    let mut tree: TaffyTree<String> = TaffyTree::new();
    let mut parent = tree.new_leaf(Style { display: Display::Block, ..Default::default() }).unwrap();
    for _ in 0..50 {
        let child = tree
            .new_leaf(Style {
                display: Display::Block,
                margin: Rect {
                    left: LengthPercentageAuto::length(0.0),
                    right: LengthPercentageAuto::length(0.0),
                    top: LengthPercentageAuto::length(2.0),
                    bottom: LengthPercentageAuto::length(2.0),
                },
                ..Default::default()
            })
            .unwrap();
        tree.add_child(parent, child).unwrap();
        parent = child;
    }
    let root = tree
        .new_with_children(
            Style {
                display: Display::Block,
                size: Size { width: Dimension::length(500.0), height: Dimension::auto() },
                ..Default::default()
            },
            &[parent],
        )
        .unwrap();
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(500.0), height: AvailableSpace::MaxContent })
        .unwrap();
}

fn mixed() {
    let mut tree: TaffyTree<String> = TaffyTree::new();
    let mut grid_children = Vec::with_capacity(100);
    for _ in 0..100 {
        let block_child = tree
            .new_leaf(Style {
                display: Display::Block,
                margin: Rect {
                    left: LengthPercentageAuto::length(1.0),
                    right: LengthPercentageAuto::length(1.0),
                    top: LengthPercentageAuto::length(1.0),
                    bottom: LengthPercentageAuto::length(1.0),
                },
                ..Default::default()
            })
            .unwrap();
        grid_children.push(
            tree.new_with_children(
                Style {
                    display: Display::Block,
                    size: Size { width: Dimension::auto(), height: Dimension::auto() },
                    ..Default::default()
                },
                &[block_child],
            )
            .unwrap(),
        );
    }
    let grid = tree
        .new_with_children(
            Style {
                display: Display::Grid,
                grid_template_columns: vec![GridTemplateComponent::Single(TrackSizingFunction::from_fr(1.0)); 4],
                flex_grow: 1.0,
                ..Default::default()
            },
            &grid_children,
        )
        .unwrap();
    let mut flex_children = Vec::with_capacity(8);
    flex_children.push(grid);
    for _ in 1..8 {
        flex_children.push(tree.new_leaf(fixed(20.0, 20.0)).unwrap());
    }
    let root = tree
        .new_with_children(
            Style {
                display: Display::Flex,
                flex_wrap: FlexWrap::Wrap,
                size: Size { width: Dimension::length(800.0), height: Dimension::auto() },
                ..Default::default()
            },
            &flex_children,
        )
        .unwrap();
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(800.0), height: AvailableSpace::MaxContent })
        .unwrap();
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

fn measure(name: &str, iters: usize, filter: Option<&str>, func: fn()) {
    if let Some(needle) = filter {
        if !name.contains(needle) {
            return;
        }
    }
    func(); // warm-up

    let baseline = LIVE.load(Ordering::Relaxed);
    let mut peak_bytes = 0usize;
    let start = Instant::now();
    for _ in 0..iters {
        PEAK.store(baseline, Ordering::Relaxed);
        func();
        let peak = PEAK.load(Ordering::Relaxed);
        peak_bytes = peak_bytes.max(peak.saturating_sub(baseline));
    }
    let elapsed = start.elapsed();
    println!("bench|{}|{}|{}|{}", name, iters, elapsed.as_nanos() as usize / iters, peak_bytes);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut filter: Option<&str> = None;
    let mut index = 0;
    while index < args.len() {
        if args[index] == "--filter" && index + 1 < args.len() {
            filter = Some(&args[index + 1]);
            index += 2;
        } else {
            index += 1;
        }
    }

    measure("tree_creation_10k", 20, filter, tree_creation);
    measure("flex_row_1000", 20, filter, flex_row);
    measure("flex_wrap_500", 20, filter, flex_wrap);
    measure("grid_50x50", 10, filter, grid);
    measure("block_nested_50", 30, filter, block_nested);
    measure("mixed_flex_grid_block", 10, filter, mixed);
}
