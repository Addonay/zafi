//! Differential parity oracle: runs the same scenarios against pinned Taffy.
//!
//! Companion to `tools/parity/zig/main.zig`; `tools/parity/run.py` diffs the
//! outputs. Output format: `scenario|label|x|y|w|h` (unrounded layout).
use taffy::prelude::*;
use taffy::{AvailableSpace, Direction, FlexWrap, GridTemplateComponent, GridTemplateRepetition, RepetitionCount, TaffyTree};

fn def(v: f32) -> AvailableSpace {
    AvailableSpace::Definite(v)
}

fn emit(name: &str, t: &TaffyTree<()>, nodes: &[(&str, NodeId)]) {
    for (label, id) in nodes {
        let l = t.unrounded_layout(*id);
        println!(
            "{}|{}|{:.3}|{:.3}|{:.3}|{:.3}",
            name, label, l.location.x, l.location.y, l.size.width, l.size.height
        );
    }
}

fn main() {
    // 1. flex container align-items: center
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let child = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(20.0), height: Dimension::length(20.0) },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Flex,
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(100.0) },
                    align_items: AlignItems::CENTER,
                    ..Default::default()
                },
                &[child],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(100.0) }).unwrap();
        emit("flex_align_items_center", &t, &[("root", root), ("child", child)]);
    }

    // 2. flex default align-items: stretch on an auto-cross child
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let child = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(20.0), height: Dimension::auto() },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Flex,
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(100.0) },
                    ..Default::default()
                },
                &[child],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(100.0) }).unwrap();
        emit("flex_stretch_default", &t, &[("root", root), ("child", child)]);
    }

    // 3. wrapped flex container with auto height
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let s = Style {
            size: Size { width: Dimension::length(60.0), height: Dimension::length(10.0) },
            ..Default::default()
        };
        let a = t.new_leaf(s.clone()).unwrap();
        let b = t.new_leaf(s.clone()).unwrap();
        let c = t.new_leaf(s.clone()).unwrap();
        let d = t.new_leaf(s).unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Flex,
                    flex_wrap: FlexWrap::Wrap,
                    size: Size { width: Dimension::length(100.0), height: Dimension::auto() },
                    ..Default::default()
                },
                &[a, b, c, d],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: AvailableSpace::MaxContent }).unwrap();
        emit("flex_wrap_auto_height", &t, &[("root", root)]);
    }

    // 4. RTL flex row
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(20.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let b = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(30.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Flex,
                    direction: Direction::Rtl,
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(20.0) },
                    ..Default::default()
                },
                &[a, b],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(20.0) }).unwrap();
        emit("flex_rtl_row", &t, &[("a", a), ("b", b)]);
    }

    // 5. flex gap
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(20.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let b = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(30.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Flex,
                    gap: Size { width: LengthPercentage::length(10.0), height: LengthPercentage::length(10.0) },
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(20.0) },
                    ..Default::default()
                },
                &[a, b],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(20.0) }).unwrap();
        emit("flex_gap_row", &t, &[("a", a), ("b", b)]);
    }

    // 6. flex-basis on an exactly-fitting line
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(10.0), height: Dimension::length(10.0) },
                flex_basis: Dimension::length(40.0),
                flex_grow: 0.0,
                flex_shrink: 0.0,
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Flex,
                    size: Size { width: Dimension::length(40.0), height: Dimension::length(20.0) },
                    ..Default::default()
                },
                &[a],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(40.0), height: def(20.0) }).unwrap();
        emit("flex_basis_exact", &t, &[("a", a)]);
    }

    // 7. align-self overrides container flex-start
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let child = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(20.0), height: Dimension::length(20.0) },
                align_self: Some(AlignSelf::CENTER),
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Flex,
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(100.0) },
                    align_items: AlignItems::FLEX_START,
                    ..Default::default()
                },
                &[child],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(100.0) }).unwrap();
        emit("flex_align_self_center", &t, &[("child", child)]);
    }

    // 8. flex-grow distribution
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(20.0), height: Dimension::length(10.0) },
                flex_grow: 1.0,
                ..Default::default()
            })
            .unwrap();
        let b = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(30.0), height: Dimension::length(10.0) },
                flex_grow: 2.0,
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Flex,
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(20.0) },
                    ..Default::default()
                },
                &[a, b],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(20.0) }).unwrap();
        emit("flex_grow", &t, &[("a", a), ("b", b)]);
    }

    // 9. grid fr tracks with gap
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(10.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let b = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(10.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Grid,
                    grid_template_columns: vec![
                        GridTemplateComponent::Single(TrackSizingFunction::from_fr(1.0)),
                        GridTemplateComponent::Single(TrackSizingFunction::from_fr(1.0)),
                    ],
                    gap: Size { width: LengthPercentage::length(10.0), height: LengthPercentage::length(10.0) },
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(50.0) },
                    ..Default::default()
                },
                &[a, b],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(50.0) }).unwrap();
        emit("grid_fr_gap", &t, &[("a", a), ("b", b)]);
    }

    // 10. grid fixed + fr with gap
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(10.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let b = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(10.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Grid,
                    grid_template_columns: vec![
                        GridTemplateComponent::Single(TrackSizingFunction::from_length(20.0)),
                        GridTemplateComponent::Single(TrackSizingFunction::from_fr(1.0)),
                    ],
                    gap: Size { width: LengthPercentage::length(10.0), height: LengthPercentage::length(10.0) },
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(50.0) },
                    ..Default::default()
                },
                &[a, b],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(50.0) }).unwrap();
        emit("grid_fixed_gap", &t, &[("a", a), ("b", b)]);
    }

    // 11. grid repeat(auto-fill, minmax(100px, 1fr))
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(10.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Grid,
                    grid_template_columns: vec![GridTemplateComponent::Repeat(GridTemplateRepetition {
                        count: RepetitionCount::AutoFill,
                        tracks: vec![TrackSizingFunction {
                            min: MinTrackSizingFunction::length(100.0),
                            max: MaxTrackSizingFunction::from_fr(1.0),
                        }],
                        line_names: vec![],
                    })],
                    size: Size { width: Dimension::length(250.0), height: Dimension::length(50.0) },
                    ..Default::default()
                },
                &[a],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(250.0), height: def(50.0) }).unwrap();
        emit("grid_autofill_minmax", &t, &[("a", a)]);
    }

    // 12. grid auto track sized by content
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(50.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let b = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(10.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Grid,
                    grid_template_columns: vec![
                        GridTemplateComponent::Single(TrackSizingFunction::AUTO),
                        GridTemplateComponent::Single(TrackSizingFunction::from_fr(1.0)),
                    ],
                    size: Size { width: Dimension::length(300.0), height: Dimension::length(50.0) },
                    ..Default::default()
                },
                &[a, b],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(300.0), height: def(50.0) }).unwrap();
        emit("grid_auto_content", &t, &[("a", a), ("b", b)]);
    }

    // 13. block sibling margin collapse
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                display: Display::Block,
                size: Size { width: Dimension::auto(), height: Dimension::length(10.0) },
                margin: Rect {
                    left: LengthPercentageAuto::length(0.0),
                    right: LengthPercentageAuto::length(0.0),
                    top: LengthPercentageAuto::length(0.0),
                    bottom: LengthPercentageAuto::length(20.0),
                },
                ..Default::default()
            })
            .unwrap();
        let b = t
            .new_leaf(Style {
                display: Display::Block,
                size: Size { width: Dimension::auto(), height: Dimension::length(10.0) },
                margin: Rect {
                    left: LengthPercentageAuto::length(0.0),
                    right: LengthPercentageAuto::length(0.0),
                    top: LengthPercentageAuto::length(30.0),
                    bottom: LengthPercentageAuto::length(0.0),
                },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Block,
                    size: Size { width: Dimension::length(100.0), height: Dimension::auto() },
                    ..Default::default()
                },
                &[a, b],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: AvailableSpace::MaxContent }).unwrap();
        emit("block_sibling_margins", &t, &[("root", root), ("a", a), ("b", b)]);
    }

    // 14. block parent/child margin collapse
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let child = t
            .new_leaf(Style {
                display: Display::Block,
                size: Size { width: Dimension::auto(), height: Dimension::length(20.0) },
                margin: Rect {
                    left: LengthPercentageAuto::length(0.0),
                    right: LengthPercentageAuto::length(0.0),
                    top: LengthPercentageAuto::length(10.0),
                    bottom: LengthPercentageAuto::length(10.0),
                },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Block,
                    size: Size { width: Dimension::length(100.0), height: Dimension::auto() },
                    ..Default::default()
                },
                &[child],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: AvailableSpace::MaxContent }).unwrap();
        emit("block_parent_child_margins", &t, &[("root", root), ("child", child)]);
    }

    // 15. min overrides max
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let root = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(20.0), height: Dimension::length(20.0) },
                min_size: Size { width: LengthPercentageAuto::length(100.0), height: LengthPercentageAuto::auto() },
                max_size: Size { width: LengthPercentageAuto::length(10.0), height: LengthPercentageAuto::auto() },
                ..Default::default()
            })
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(100.0) }).unwrap();
        emit("min_over_max", &t, &[("root", root)]);
    }

    // 16. absolute child with left+right insets and a percentage grandchild
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let gc = t
            .new_leaf(Style {
                display: Display::Block,
                size: Size { width: Dimension::percent(0.5), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let abs = t
            .new_with_children(
                Style {
                    display: Display::Block,
                    position: Position::Absolute,
                    inset: Rect {
                        left: LengthPercentageAuto::length(10.0),
                        right: LengthPercentageAuto::length(10.0),
                        top: LengthPercentageAuto::length(10.0),
                        bottom: LengthPercentageAuto::auto(),
                    },
                    ..Default::default()
                },
                &[gc],
            )
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Block,
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(100.0) },
                    ..Default::default()
                },
                &[abs],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(100.0) }).unwrap();
        emit("absolute_lr", &t, &[("abs", abs), ("gc", gc)]);
    }

    // 17. grid 1fr sanity without gap
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(10.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Grid,
                    grid_template_columns: vec![GridTemplateComponent::Single(TrackSizingFunction::from_fr(1.0))],
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(50.0) },
                    ..Default::default()
                },
                &[a],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(50.0) }).unwrap();
        emit("grid_1fr", &t, &[("a", a)]);
    }

    // 18. grid fr tracks with gap, stretched items reveal actual track widths
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t.new_leaf(Style::default()).unwrap();
        let b = t.new_leaf(Style::default()).unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Grid,
                    grid_template_columns: vec![
                        GridTemplateComponent::Single(TrackSizingFunction::from_fr(1.0)),
                        GridTemplateComponent::Single(TrackSizingFunction::from_fr(1.0)),
                    ],
                    gap: Size { width: LengthPercentage::length(10.0), height: LengthPercentage::length(10.0) },
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(50.0) },
                    ..Default::default()
                },
                &[a, b],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(50.0) }).unwrap();
        emit("grid_fr_gap_stretch", &t, &[("a", a), ("b", b)]);
    }

    // 19. flex align-content: center on a wrapped container
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let s = Style {
            size: Size { width: Dimension::length(60.0), height: Dimension::length(10.0) },
            ..Default::default()
        };
        let a = t.new_leaf(s.clone()).unwrap();
        let b = t.new_leaf(s.clone()).unwrap();
        let c = t.new_leaf(s.clone()).unwrap();
        let d = t.new_leaf(s).unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Flex,
                    flex_wrap: FlexWrap::Wrap,
                    align_content: AlignContent::CENTER,
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(100.0) },
                    ..Default::default()
                },
                &[a, b, c, d],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(100.0) }).unwrap();
        emit("flex_align_content_center", &t, &[("a", a), ("b", b)]);
    }

    // 20. flex justify-content: center
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t
            .new_leaf(Style {
                size: Size { width: Dimension::length(20.0), height: Dimension::length(10.0) },
                ..Default::default()
            })
            .unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Flex,
                    justify_content: JustifyContent::CENTER,
                    size: Size { width: Dimension::length(100.0), height: Dimension::length(20.0) },
                    ..Default::default()
                },
                &[a],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(100.0), height: def(20.0) }).unwrap();
        emit("flex_justify_center", &t, &[("a", a)]);
    }

    // 21. auto-fill minmax with stretched items reveals the generated track count
    {
        let mut t: TaffyTree<()> = TaffyTree::new();
        let a = t.new_leaf(Style::default()).unwrap();
        let b = t.new_leaf(Style::default()).unwrap();
        let root = t
            .new_with_children(
                Style {
                    display: Display::Grid,
                    grid_template_columns: vec![GridTemplateComponent::Repeat(GridTemplateRepetition {
                        count: RepetitionCount::AutoFill,
                        tracks: vec![TrackSizingFunction {
                            min: MinTrackSizingFunction::length(100.0),
                            max: MaxTrackSizingFunction::from_fr(1.0),
                        }],
                        line_names: vec![],
                    })],
                    size: Size { width: Dimension::length(250.0), height: Dimension::length(50.0) },
                    ..Default::default()
                },
                &[a, b],
            )
            .unwrap();
        t.compute_layout(root, Size { width: def(250.0), height: def(50.0) }).unwrap();
        emit("grid_autofill_minmax_stretch", &t, &[("a", a), ("b", b)]);
    }
}
