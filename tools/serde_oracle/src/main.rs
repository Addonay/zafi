use taffy::prelude::*;
use taffy::geometry::Point;
use taffy::style::{
    AlignContent, AlignItems, BoxSizing, Clear, Contain, Direction, Float, GridAutoFlow, GridPlacement,
    GridTemplateComponent, Overflow, RepetitionCount, TextAlign,
};
use taffy::{CompactLength, Dimension, LengthPercentage, LengthPercentageAuto, MaxTrackSizingFunction, MinTrackSizingFunction};

fn emit<T: serde::Serialize>(key: &str, value: &T) {
    println!("{key}={}", serde_json::to_string(value).unwrap());
}

fn main() {
    emit("STYLE_DEFAULT", &Style::<String>::default());

    let dims = Style::<String> {
        position: Position::Static,
        size: Size { width: Dimension::percent(0.5), height: Dimension::length(12.5) },
        aspect_ratio: Some(2.0),
        margin: Rect {
            left: LengthPercentageAuto::auto(),
            right: LengthPercentageAuto::length(7.0),
            top: LengthPercentageAuto::length(0.0),
            bottom: LengthPercentageAuto::length(0.0),
        },
        padding: Rect {
            left: LengthPercentage::length(3.5),
            right: LengthPercentage::length(0.0),
            top: LengthPercentage::length(0.0),
            bottom: LengthPercentage::length(0.0),
        },
        gap: Size { width: LengthPercentage::percent(0.25), height: LengthPercentage::length(0.0) },
        ..Default::default()
    };
    emit("STYLE_DIMS", &dims);

    let enums = Style::<String> {
        display: Display::Grid,
        box_sizing: BoxSizing::ContentBox,
        direction: Direction::Rtl,
        overflow: Point { x: Overflow::Scroll, y: Overflow::Hidden },
        contain: Contain::LAYOUT | Contain::PAINT,
        float: Float::Left,
        clear: Clear::Both,
        position: Position::Absolute,
        align_items: AlignItems::CENTER,
        align_self: Some(AlignItems::FLEX_END),
        justify_items: AlignItems::SELF_START,
        justify_self: Some(AlignItems::SAFE_CENTER),
        align_content: AlignContent::SPACE_BETWEEN,
        justify_content: AlignContent::SPACE_EVENLY,
        text_align: TextAlign::LegacyCenter,
        flex_direction: FlexDirection::ColumnReverse,
        flex_wrap: FlexWrap::WrapReverse,
        grid_auto_flow: GridAutoFlow::ColumnDense,
        ..Default::default()
    };
    emit("STYLE_ENUMS", &enums);

    emit("COMPACT_LP_LENGTH_3_5", &LengthPercentage::length(3.5));
    emit("COMPACT_LP_PERCENT_0_25", &LengthPercentage::percent(0.25));
    emit("COMPACT_LPA_AUTO", &LengthPercentageAuto::auto());
    emit("COMPACT_DIM_LENGTH_1", &Dimension::length(1.0));
    emit("COMPACT_DIM_FIT_PX_9", &CompactLength::fit_content_px(9.0));
    emit("COMPACT_MIN_TRACK_LENGTH_10", &MinTrackSizingFunction::length(10.0));
    emit("COMPACT_MAX_TRACK_FR_1", &MaxTrackSizingFunction::fr(1.0));
    emit("REPETITION_COUNT_3", &RepetitionCount::Count(3));
    emit("REPETITION_AUTO_FILL", &RepetitionCount::AutoFill);
    emit("GRID_COMPONENT_SINGLE", &GridTemplateComponent::<String>::Single(TrackSizingFunction::AUTO));
    emit(
        "GRID_COMPONENT_REPEAT",
        &GridTemplateComponent::<String>::Repeat(taffy::GridTemplateRepetition {
            count: RepetitionCount::AutoFill,
            tracks: vec![TrackSizingFunction::from_length(50.0)],
            line_names: vec![vec!["a".to_string()], vec![]],
        }),
    );
    emit("PLACEMENT_AUTO", &GridPlacement::<String>::Auto);
    emit("PLACEMENT_LINE_2", &GridPlacement::<String>::from_line_index(2));
    emit("PLACEMENT_SPAN_3", &GridPlacement::<String>::Span(3));
    emit("PLACEMENT_NAMED_LINE", &GridPlacement::<String>::NamedLine("foo".to_string(), -1));
    emit("PLACEMENT_NAMED_SPAN", &GridPlacement::<String>::NamedSpan("bar".to_string(), 2));
    emit("LINE_PLACEMENT", &Line { start: GridPlacement::<String>::from_line_index(1), end: GridPlacement::<String>::Auto });
    emit("ALIGN_ITEMS_CENTER", &AlignItems::CENTER);
    emit("ALIGN_ITEMS_SAFE_CENTER", &AlignItems::SAFE_CENTER);
    emit("ALIGN_ITEMS_SELF_END", &AlignItems::SELF_END);
    emit("ALIGN_ITEMS_NORMAL", &AlignItems::NORMAL);
    emit("ALIGN_ITEMS_UNSAFE_END", &AlignItems::END.with_safety(taffy::AlignmentSafety::Unsafe));
    emit("ALIGN_CONTENT_SPACE_AROUND", &AlignContent::SPACE_AROUND);
    emit("ALIGN_CONTENT_NORMAL", &AlignContent::NORMAL);
    emit("TEXT_ALIGN_LEGACY_CENTER", &TextAlign::LegacyCenter);
    emit("CONTAIN_LAYOUT", &Contain::LAYOUT);
}
