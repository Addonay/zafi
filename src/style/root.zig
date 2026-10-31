//! Taffy `style/mod.rs` module root.

const geometry = @import("../geometry.zig");
const std = @import("std");

const serde_support = @import("../serde_support.zig");
const serde_options = serde_support.pascal_options;
const serde_serialize = serde_support.serialize;
const serde_deserialize = serde_support.deserialize;

pub const alignment = @import("alignment.zig");
pub const available_space = @import("available_space.zig");
pub const block = @import("block.zig");
pub const compact_length = @import("compact_length.zig");
pub const dimension = @import("dimension.zig");
pub const flex = @import("flex.zig");
pub const float = @import("float.zig");
pub const grid = @import("grid.zig");

pub const Display = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    flex,
    grid,
    block,
    flow_root,
    none,

    pub fn from_str(input: []const u8) error{InvalidDisplay}!Display {
        const source = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(source, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(source, "flex")) return .flex;
        if (std.ascii.eqlIgnoreCase(source, "grid")) return .grid;
        if (std.ascii.eqlIgnoreCase(source, "block")) return .block;
        if (std.ascii.eqlIgnoreCase(source, "flow-root")) return .flow_root;
        return error.InvalidDisplay;
    }
};
pub const BoxGenerationMode = enum { normal, none };

/// WARNING: this enum follows the behaviour of CSS's `position` property,
/// which can be unintuitive.
///
/// `Position.static` is the default value, matching CSS. (Taffy made
/// `Position.relative` the default for backwards compatibility before CSS
/// semantics were implemented; Zafi tracks current Taffy, so `static` is the
/// default here too.)
pub const Position = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    /// Laid out in normal flow. `inset` has no effect and the box does not act
    /// as a containing block for out-of-flow descendants.
    static,
    /// Laid out in normal flow, then the `inset` offset is applied as a
    /// correction factor. Offsets do not affect the position of any other item.
    /// Acts as a containing block for out-of-flow descendants.
    relative,
    /// Taken out of normal flow and positioned relative to its containing block
    /// (the closest positioned ancestor, otherwise the initial containing
    /// block). No space is created for it in flow and its size is not altered by
    /// its siblings.
    ///
    /// To opt out of layout entirely use `Display.none` instead.
    absolute,
    /// Taken out of normal flow and positioned relative to the initial
    /// containing block (the viewport), regardless of ancestors.
    fixed,
    /// Laid out in normal flow exactly like `static`: `inset` is *not* applied as
    /// an offset, because in CSS sticky insets are scroll thresholds which
    /// Taffy has no knowledge of. Applying the sticky offset is the caller's job
    /// once it knows the scroll position. Acts as a containing block for
    /// out-of-flow descendants.
    sticky,

    pub fn from_str(input: []const u8) error{InvalidPosition}!Position {
        const source = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(source, "static")) return .static;
        if (std.ascii.eqlIgnoreCase(source, "relative")) return .relative;
        if (std.ascii.eqlIgnoreCase(source, "absolute")) return .absolute;
        if (std.ascii.eqlIgnoreCase(source, "fixed")) return .fixed;
        if (std.ascii.eqlIgnoreCase(source, "sticky")) return .sticky;
        return error.InvalidPosition;
    }

    /// Whether this position takes the item out of normal flow.
    pub fn is_out_of_flow(self: Position) bool {
        return self == .absolute or self == .fixed;
    }

    /// Whether this position causes the item to act as a containing block for
    /// out-of-flow descendants (any value other than `static`).
    pub fn is_positioned(self: Position) bool {
        return self != .static;
    }

    /// Whether `inset` is applied as a positional offset for this position.
    /// Only `relative` applies insets; `static`/`sticky` ignore them and the
    /// out-of-flow positions resolve them against their containing block.
    pub fn applies_relative_inset(self: Position) bool {
        return self == .relative;
    }
};

/// Which out-of-flow positions a node establishes a containing block for.
///
/// This is the single policy point for containing-block establishment: it
/// decides both which out-of-flow boxes a node claims and lays out, and (for
/// grid containers) whether the static position of an out-of-flow child is
/// derived from its grid area. The default matches plain CSS positioning: a
/// node is the containing block for `absolute` boxes when its own `position` is
/// not `static`, and never for `fixed` boxes (which are claimed by the root).
pub const ContainingBlockClaims = struct {
    /// Whether the node is the containing block for `position: absolute` boxes.
    absolute: bool,
    /// Whether the node is the containing block for `position: fixed` boxes.
    fixed: bool,

    pub const none = ContainingBlockClaims{ .absolute = false, .fixed = false };
    pub const all = ContainingBlockClaims{ .absolute = true, .fixed = true };

    /// Whether the node is the containing block for a box with `position`.
    pub fn for_position(self: ContainingBlockClaims, value: Position) bool {
        return switch (value) {
            .absolute => self.absolute,
            .fixed => self.fixed,
            else => false,
        };
    }
};
pub const BoxSizing = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    border_box,
    content_box,

    pub fn from_str(input: []const u8) error{InvalidBoxSizing}!BoxSizing {
        const source = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(source, "border-box")) return .border_box;
        if (std.ascii.eqlIgnoreCase(source, "content-box")) return .content_box;
        return error.InvalidBoxSizing;
    }
};
pub const Overflow = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    visible,
    clip,
    hidden,
    scroll,

    pub fn from_str(input: []const u8) error{InvalidOverflow}!Overflow {
        const source = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(source, "visible")) return .visible;
        if (std.ascii.eqlIgnoreCase(source, "hidden")) return .hidden;
        if (std.ascii.eqlIgnoreCase(source, "clip")) return .clip;
        if (std.ascii.eqlIgnoreCase(source, "scroll")) return .scroll;
        return error.InvalidOverflow;
    }

    pub fn is_scroll_container(self: Overflow) bool {
        return self == .hidden or self == .scroll;
    }

    pub fn maybe_into_automatic_min_size(self: Overflow) ?f32 {
        return if (self.is_scroll_container()) 0 else null;
    }
};
pub const Direction = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    ltr,
    rtl,

    pub fn is_rtl(self: Direction) bool {
        return self == .rtl;
    }

    pub fn from_str(input: []const u8) error{InvalidDirection}!Direction {
        const source = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(source, "ltr")) return .ltr;
        if (std.ascii.eqlIgnoreCase(source, "rtl")) return .rtl;
        return error.InvalidDirection;
    }
};
pub const Contain = packed struct(u8) {
    /// Taffy-compatible serde: u8 bit set.
    pub const zerdeSerialize = serde_serialize;
    pub const zerdeDeserialize = serde_deserialize;

    layout: bool = false,
    paint: bool = false,
    _reserved: u6 = 0,

    pub const NONE: Contain = .{};
    pub const DEFAULT: Contain = NONE;
    pub const LAYOUT: Contain = .{ .layout = true };
    pub const PAINT: Contain = .{ .paint = true };
    pub const CONTENT: Contain = .{ .layout = true, .paint = true };

    pub fn from_str(input: []const u8) error{InvalidContain}!Contain {
        var result = Contain.NONE;
        var seen: u8 = 0;
        var token_count: usize = 0;
        var saw_content = false;
        var tokens = std.mem.tokenizeAny(u8, std.mem.trim(u8, input, " \t\r\n"), " \t\r\n");
        while (tokens.next()) |token| {
            token_count += 1;
            if (std.ascii.eqlIgnoreCase(token, "none")) {
                if (token_count != 1 or tokens.next() != null) return error.InvalidContain;
                return result;
            } else if (std.ascii.eqlIgnoreCase(token, "content")) {
                if (saw_content) return error.InvalidContain;
                result = Contain.CONTENT;
                saw_content = true;
                seen |= 1;
            } else if (std.ascii.eqlIgnoreCase(token, "layout")) {
                if ((seen & 1) != 0) return error.InvalidContain;
                result.layout = true;
                seen |= 1;
            } else if (std.ascii.eqlIgnoreCase(token, "paint")) {
                if ((seen & 2) != 0) return error.InvalidContain;
                result.paint = true;
                seen |= 2;
            } else if (std.ascii.eqlIgnoreCase(token, "style")) {
                if ((seen & 4) != 0) return error.InvalidContain;
                seen |= 4;
            } else return error.InvalidContain;
        }
        if (token_count == 0) return error.InvalidContain;
        if (saw_content and token_count > 1) return error.InvalidContain;
        return result;
    }

    pub fn suppresses_baseline(self: Contain) bool {
        return self.layout;
    }

    pub fn establishes_independent_formatting_context(self: Contain) bool {
        return self.layout or self.paint;
    }

    pub fn contains_scrollable_overflow(self: Contain) bool {
        return self.layout or self.paint;
    }

    pub fn contains(self: Contain, other: Contain) bool {
        return (self.layout or !other.layout) and (self.paint or !other.paint);
    }
    pub fn intersects(self: Contain, other: Contain) bool {
        return (self.layout and other.layout) or (self.paint and other.paint);
    }
    pub fn @"union"(self: Contain, other: Contain) Contain {
        return .{ .layout = self.layout or other.layout, .paint = self.paint or other.paint };
    }
};

/// Rust trait names retained as explicit Zig interface records. A view wraps
/// a concrete `Style` and exposes the same accessor boundary as Taffy's trait;
/// custom trees can provide their own records without depending on the
/// high-level `Tree` storage.
pub const CheapCloneStr = []const u8;
pub const CoreStyle = struct {
    value: Style,

    pub fn init(value: Style) CoreStyle {
        return .{ .value = value };
    }
    pub fn box_generation_mode(self: CoreStyle) BoxGenerationMode {
        return self.value.box_generation_mode();
    }
    pub fn is_block(self: CoreStyle) bool {
        return self.value.is_block();
    }
    pub fn is_compressible_replaced(self: CoreStyle) bool {
        return self.value.is_compressible_replaced();
    }
    pub fn is_replaced(self: CoreStyle) bool {
        return self.value.is_replaced();
    }
    pub fn box_sizing(self: CoreStyle) BoxSizing {
        return self.value.box_sizing_value();
    }
    pub fn direction(self: CoreStyle) Direction {
        return self.value.direction_value();
    }
    pub fn overflow(self: CoreStyle) geometry.Point(Overflow) {
        return self.value.overflow_value();
    }
    pub fn scrollbar_width(self: CoreStyle) f32 {
        return self.value.scrollbar_width_value();
    }
    pub fn position(self: CoreStyle) Position {
        return self.value.position_value();
    }
    pub fn inset(self: CoreStyle) geometry.Rect(dimension.LengthPercentageAuto) {
        return self.value.inset_value();
    }
    pub fn size(self: CoreStyle) geometry.Size(dimension.Dimension) {
        return self.value.size_value();
    }
    pub fn min_size(self: CoreStyle) geometry.Size(dimension.LengthPercentageAuto) {
        return self.value.min_size_value();
    }
    pub fn max_size(self: CoreStyle) geometry.Size(dimension.LengthPercentageAuto) {
        return self.value.max_size_value();
    }
    pub fn aspect_ratio(self: CoreStyle) ?f32 {
        return self.value.aspect_ratio_value();
    }
    pub fn margin(self: CoreStyle) geometry.Rect(dimension.LengthPercentageAuto) {
        return self.value.margin_value();
    }
    pub fn padding(self: CoreStyle) geometry.Rect(dimension.LengthPercentage) {
        return self.value.padding_value();
    }
    pub fn border(self: CoreStyle) geometry.Rect(dimension.LengthPercentage) {
        return self.value.border_value();
    }
    pub fn contain(self: CoreStyle) Contain {
        return self.value.contain_value();
    }
};

pub const FlexboxContainerStyle = struct {
    value: Style,
    pub fn init(value: Style) FlexboxContainerStyle {
        return .{ .value = value };
    }
    pub fn flex_direction(self: FlexboxContainerStyle) flex.FlexDirection {
        return self.value.flex_direction_value();
    }
    pub fn flex_wrap(self: FlexboxContainerStyle) flex.FlexWrap {
        return self.value.flex_wrap_value();
    }
    pub fn flex_line_count(self: FlexboxContainerStyle) u16 {
        return self.value.flex_line_count;
    }
    pub fn gap(self: FlexboxContainerStyle) geometry.Size(dimension.LengthPercentage) {
        return self.value.gap;
    }
    pub fn align_content(self: FlexboxContainerStyle) alignment.AlignContent {
        return self.value.align_content;
    }
    pub fn align_items(self: FlexboxContainerStyle) alignment.AlignItems {
        return self.value.align_items;
    }
    pub fn justify_content(self: FlexboxContainerStyle) alignment.JustifyContent {
        return self.value.justify_content;
    }
};

pub const FlexboxItemStyle = struct {
    value: Style,
    pub fn init(value: Style) FlexboxItemStyle {
        return .{ .value = value };
    }
    pub fn flex_basis(self: FlexboxItemStyle) dimension.Dimension {
        return self.value.flex_basis_value();
    }
    pub fn flex_grow(self: FlexboxItemStyle) f32 {
        return self.value.flex_grow_value();
    }
    pub fn flex_shrink(self: FlexboxItemStyle) f32 {
        return self.value.flex_shrink_value();
    }
    pub fn align_self(self: FlexboxItemStyle) ?alignment.AlignSelf {
        return self.value.align_self;
    }
};

pub const GridContainerStyle = struct {
    value: Style,
    pub fn init(value: Style) GridContainerStyle {
        return .{ .value = value };
    }
    pub fn grid_template_rows(self: GridContainerStyle) []const grid.GridTemplateComponent {
        return self.value.grid_template_rows;
    }
    pub fn grid_template_columns(self: GridContainerStyle) []const grid.GridTemplateComponent {
        return self.value.grid_template_columns;
    }
    pub fn grid_auto_rows(self: GridContainerStyle) []const grid.TrackSizingFunction {
        return self.value.grid_auto_rows;
    }
    pub fn grid_auto_columns(self: GridContainerStyle) []const grid.TrackSizingFunction {
        return self.value.grid_auto_columns;
    }
    pub fn grid_template_areas(self: GridContainerStyle) ?grid.GridTemplateAreas {
        return self.value.grid_template_areas;
    }
    pub fn grid_template_area_row_count(self: GridContainerStyle) u16 {
        return self.value.grid_template_area_row_count();
    }
    pub fn grid_template_area_column_count(self: GridContainerStyle) u16 {
        return self.value.grid_template_area_column_count();
    }
    pub fn grid_template_column_names(self: GridContainerStyle) []const grid.GridTemplateLineNames {
        return self.value.grid_template_column_names;
    }
    pub fn grid_template_row_names(self: GridContainerStyle) []const grid.GridTemplateLineNames {
        return self.value.grid_template_row_names;
    }
    pub fn grid_auto_flow(self: GridContainerStyle) grid.GridAutoFlow {
        return self.value.grid_auto_flow;
    }
    pub fn gap(self: GridContainerStyle) geometry.Size(dimension.LengthPercentage) {
        return self.value.gap;
    }
    pub fn align_content(self: GridContainerStyle) alignment.AlignContent {
        return self.value.align_content;
    }
    pub fn justify_content(self: GridContainerStyle) alignment.JustifyContent {
        return self.value.justify_content;
    }
    pub fn align_items(self: GridContainerStyle) alignment.AlignItems {
        return self.value.align_items;
    }
    pub fn justify_items(self: GridContainerStyle) alignment.JustifyItems {
        return self.value.justify_items;
    }
    pub fn grid_align_content(self: GridContainerStyle, axis: geometry.AbstractAxis) alignment.AlignContent {
        const value = if (axis == .inline_axis) self.value.justify_content else self.value.align_content;
        return if (value.keyword == .normal) .STRETCH else value;
    }
};

pub const GridItemStyle = struct {
    value: Style,
    pub fn init(value: Style) GridItemStyle {
        return .{ .value = value };
    }
    pub fn grid_row(self: GridItemStyle) geometry.Line(grid.GridPlacement) {
        return self.value.grid_row;
    }
    pub fn grid_column(self: GridItemStyle) geometry.Line(grid.GridPlacement) {
        return self.value.grid_column;
    }
    pub fn align_self(self: GridItemStyle) ?alignment.AlignSelf {
        return self.value.align_self;
    }
    pub fn justify_self(self: GridItemStyle) ?alignment.JustifySelf {
        return self.value.justify_self;
    }
    pub fn grid_placement(self: GridItemStyle, axis: geometry.AbsoluteAxis) geometry.Line(grid.GridPlacement) {
        return if (axis == .horizontal) self.value.grid_column else self.value.grid_row;
    }
};

pub const BlockContainerStyle = struct {
    value: Style,
    pub fn init(value: Style) BlockContainerStyle {
        return .{ .value = value };
    }
    pub fn text_align(self: BlockContainerStyle) block.TextAlign {
        return self.value.text_align;
    }
    pub fn align_content(self: BlockContainerStyle) alignment.AlignContent {
        return self.value.align_content;
    }
};

pub const BlockItemStyle = struct {
    value: Style,
    pub fn init(value: Style) BlockItemStyle {
        return .{ .value = value };
    }
    pub fn is_table(self: BlockItemStyle) bool {
        return self.value.item_is_table;
    }
    pub fn float(self: BlockItemStyle) @import("float.zig").Float {
        return self.value.float;
    }
    pub fn clear(self: BlockItemStyle) @import("float.zig").Clear {
        return self.value.clear;
    }
};

pub const Style = struct {
    /// Mirrors Rust's `dummy: PhantomData<S>` field, which serde emits as
    /// `"dummy": null`; keeping it preserves Taffy's wire field order.
    dummy: void = {},
    display: Display = .flex,
    item_is_table: bool = false,
    /// A replaced element (image, video, canvas, ...).
    item_is_replaced: bool = false,
    /// A compressible non-replaced element with an intrinsic size (form controls:
    /// `input`, `select`, `textarea`, ...). Resolves `auto` width to its intrinsic
    /// size like a replaced element, but still stretches between abspos insets.
    item_is_compressible_replaced: bool = false,
    box_sizing: BoxSizing = .border_box,
    direction: Direction = .ltr,
    overflow: geometry.Point(Overflow) = .{ .x = .visible, .y = .visible },
    scrollbar_width: f32 = 0,
    contain: Contain = .{},
    float: float.Float = .none,
    clear: float.Clear = .none,
    position: Position = .static,
    inset: geometry.Rect(dimension.LengthPercentageAuto) = .{ .left = dimension.LengthPercentageAuto.auto(), .right = dimension.LengthPercentageAuto.auto(), .top = dimension.LengthPercentageAuto.auto(), .bottom = dimension.LengthPercentageAuto.auto() },
    size: geometry.Size(dimension.Dimension) = .{ .width = .auto, .height = .auto },
    min_size: geometry.Size(dimension.LengthPercentageAuto) = .{ .width = dimension.LengthPercentageAuto.auto(), .height = dimension.LengthPercentageAuto.auto() },
    max_size: geometry.Size(dimension.LengthPercentageAuto) = .{ .width = dimension.LengthPercentageAuto.auto(), .height = dimension.LengthPercentageAuto.auto() },
    aspect_ratio: ?f32 = null,
    // Taffy's initial margin is zero; `auto` is an authored margin value, not
    // the default. Keeping this distinction is essential for Grid/Flex
    // stretch alignment and block margin collapsing.
    margin: geometry.Rect(dimension.LengthPercentageAuto) = .{ .left = dimension.LengthPercentageAuto.zero(), .right = dimension.LengthPercentageAuto.zero(), .top = dimension.LengthPercentageAuto.zero(), .bottom = dimension.LengthPercentageAuto.zero() },
    padding: geometry.Rect(dimension.LengthPercentage) = .{ .left = dimension.LengthPercentage.zero(), .right = dimension.LengthPercentage.zero(), .top = dimension.LengthPercentage.zero(), .bottom = dimension.LengthPercentage.zero() },
    border: geometry.Rect(dimension.LengthPercentage) = .{ .left = dimension.LengthPercentage.zero(), .right = dimension.LengthPercentage.zero(), .top = dimension.LengthPercentage.zero(), .bottom = dimension.LengthPercentage.zero() },
    align_items: alignment.AlignItems = .NORMAL,
    /// `null` is `auto`: use the container's `align-items`.
    align_self: ?alignment.AlignSelf = null,
    justify_items: alignment.JustifyItems = .NORMAL,
    /// `null` is `auto`: use the container's `justify-items`.
    justify_self: ?alignment.JustifySelf = null,
    align_content: alignment.AlignContent = .NORMAL,
    justify_content: alignment.JustifyContent = .NORMAL,
    gap: geometry.Size(dimension.LengthPercentage) = .{ .width = dimension.LengthPercentage.zero(), .height = dimension.LengthPercentage.zero() },
    text_align: block.TextAlign = .auto,
    flex_direction: flex.FlexDirection = .row,
    flex_wrap: flex.FlexWrap = .no_wrap,
    flex_line_count: u16 = 1,
    flex_basis: dimension.Dimension = .auto,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    grid_template_rows: []const grid.GridTemplateComponent = &.{},
    grid_template_columns: []const grid.GridTemplateComponent = &.{},
    grid_auto_rows: []const grid.TrackSizingFunction = &.{},
    grid_auto_columns: []const grid.TrackSizingFunction = &.{},
    grid_auto_flow: grid.GridAutoFlow = .row,
    grid_template_areas: ?grid.GridTemplateAreas = null,
    grid_template_column_names: []const grid.GridTemplateLineNames = &.{},
    grid_template_row_names: []const grid.GridTemplateLineNames = &.{},
    grid_row: geometry.Line(grid.GridPlacement) = .{ .start = .auto, .end = .auto },
    grid_column: geometry.Line(grid.GridPlacement) = .{ .start = .auto, .end = .auto },

    /// These accessors mirror Taffy's `CoreStyle` trait. They are methods on
    /// the concrete Zig style because Zig has no trait implementation syntax.
    pub fn box_generation_mode(self: Style) BoxGenerationMode {
        return if (self.display == .none) .none else .normal;
    }

    pub fn is_block(self: Style) bool {
        return self.display == .block or self.display == .flow_root;
    }

    /// Whether the box establishes an independent formatting context purely
    /// because of its `display` value. `flow_root` is a Zafi extension (CSS
    /// `display: flow-root`) rather than a Taffy concept.
    pub fn establishes_formatting_context_from_display(self: Style) bool {
        return self.display == .flow_root;
    }

    /// Which out-of-flow (`absolute`/`fixed`) descendants this node establishes
    /// the containing block for. See `ContainingBlockClaims`.
    pub fn is_containing_block(self: Style) ContainingBlockClaims {
        return .{ .absolute = self.position.is_positioned(), .fixed = false };
    }

    pub fn is_table(self: Style) bool {
        return self.item_is_table;
    }
    pub fn float_value(self: Style) float.Float {
        return self.float;
    }
    pub fn clear_value(self: Style) float.Clear {
        return self.clear;
    }
    pub fn flex_line_count_value(self: Style) u16 {
        return self.flex_line_count;
    }
    pub fn justify_items_value(self: Style) ?alignment.JustifyItems {
        return self.justify_items;
    }
    pub fn grid_template_areas_value(self: Style) ?grid.GridTemplateAreas {
        return self.grid_template_areas;
    }
    pub fn grid_template_area_row_count(self: Style) u16 {
        return if (self.grid_template_areas) |areas| areas.row_count else 0;
    }
    pub fn grid_template_area_column_count(self: Style) u16 {
        return if (self.grid_template_areas) |areas| areas.column_count else 0;
    }
    pub fn grid_template_column_names_value(self: Style) []const grid.GridTemplateLineNames {
        return self.grid_template_column_names;
    }
    pub fn grid_template_row_names_value(self: Style) []const grid.GridTemplateLineNames {
        return self.grid_template_row_names;
    }
    pub fn justify_self_value(self: Style) ?alignment.JustifySelf {
        return self.justify_self;
    }

    /// A replaced element or form control (https://drafts.csswg.org/css-sizing-3/#compressible).
    pub fn is_compressible_replaced(self: Style) bool {
        return self.item_is_replaced or self.item_is_compressible_replaced;
    }
    /// A replaced element proper: unlike form controls, an `auto`-sized replaced
    /// element is not stretched between its insets under `normal` alignment.
    pub fn is_replaced(self: Style) bool {
        return self.item_is_replaced;
    }

    pub fn box_sizing_value(self: Style) BoxSizing {
        return self.box_sizing;
    }

    pub fn direction_value(self: Style) Direction {
        return self.direction;
    }

    pub fn overflow_value(self: Style) geometry.Point(Overflow) {
        return self.overflow;
    }

    pub fn scrollbar_width_value(self: Style) f32 {
        return self.scrollbar_width;
    }

    pub fn position_value(self: Style) Position {
        return self.position;
    }

    pub fn inset_value(self: Style) geometry.Rect(dimension.LengthPercentageAuto) {
        return self.inset;
    }

    pub fn size_value(self: Style) geometry.Size(dimension.Dimension) {
        return self.size;
    }

    pub fn min_size_value(self: Style) geometry.Size(dimension.LengthPercentageAuto) {
        return self.min_size;
    }

    pub fn max_size_value(self: Style) geometry.Size(dimension.LengthPercentageAuto) {
        return self.max_size;
    }

    pub fn aspect_ratio_value(self: Style) ?f32 {
        return self.aspect_ratio;
    }

    pub fn margin_value(self: Style) geometry.Rect(dimension.LengthPercentageAuto) {
        return self.margin;
    }

    pub fn padding_value(self: Style) geometry.Rect(dimension.LengthPercentage) {
        return self.padding;
    }

    pub fn border_value(self: Style) geometry.Rect(dimension.LengthPercentage) {
        return self.border;
    }

    pub fn contain_value(self: Style) Contain {
        return self.contain;
    }

    pub fn flex_direction_value(self: Style) flex.FlexDirection {
        return self.flex_direction;
    }

    pub fn flex_wrap_value(self: Style) flex.FlexWrap {
        return self.flex_wrap;
    }

    pub fn flex_basis_value(self: Style) dimension.Dimension {
        return self.flex_basis;
    }

    pub fn flex_grow_value(self: Style) f32 {
        return self.flex_grow;
    }

    pub fn flex_shrink_value(self: Style) f32 {
        return self.flex_shrink;
    }

    pub fn grid_template_rows_value(self: Style) []const grid.GridTemplateComponent {
        return self.grid_template_rows;
    }

    pub fn grid_template_columns_value(self: Style) []const grid.GridTemplateComponent {
        return self.grid_template_columns;
    }

    pub fn grid_auto_rows_value(self: Style) []const grid.TrackSizingFunction {
        return self.grid_auto_rows;
    }

    pub fn grid_auto_columns_value(self: Style) []const grid.TrackSizingFunction {
        return self.grid_auto_columns;
    }

    pub fn grid_auto_flow_value(self: Style) grid.GridAutoFlow {
        return self.grid_auto_flow;
    }

    pub fn grid_row_value(self: Style) geometry.Line(grid.GridPlacement) {
        return self.grid_row;
    }

    pub fn grid_column_value(self: Style) geometry.Line(grid.GridPlacement) {
        return self.grid_column;
    }
};

/// Concrete equivalents of the accessor methods supplied by Taffy's
/// `CoreStyle`, `FlexboxContainerStyle`, `FlexboxItemStyle`,
/// `GridContainerStyle`, and `GridItemStyle` traits.
pub fn box_generation_mode(value: Style) BoxGenerationMode {
    return if (value.display == .none) .none else .normal;
}
pub fn is_block(value: Style) bool {
    return value.is_block();
}
pub fn is_containing_block(value: Style) ContainingBlockClaims {
    return value.is_containing_block();
}
pub fn is_compressible_replaced(value: Style) bool {
    return value.is_compressible_replaced();
}
pub fn box_sizing(value: Style) BoxSizing {
    return value.box_sizing;
}
pub fn direction(value: Style) Direction {
    return value.direction;
}
pub fn overflow(value: Style) geometry.Point(Overflow) {
    return value.overflow;
}
pub fn scrollbar_width(value: Style) f32 {
    return value.scrollbar_width;
}
pub fn position(value: Style) Position {
    return value.position;
}
pub fn inset(value: Style) geometry.Rect(dimension.LengthPercentageAuto) {
    return value.inset;
}
pub fn size(value: Style) geometry.Size(dimension.Dimension) {
    return value.size;
}
pub fn min_size(value: Style) geometry.Size(dimension.LengthPercentageAuto) {
    return value.min_size;
}
pub fn max_size(value: Style) geometry.Size(dimension.LengthPercentageAuto) {
    return value.max_size;
}
pub fn aspect_ratio(value: Style) ?f32 {
    return value.aspect_ratio;
}
pub fn margin(value: Style) geometry.Rect(dimension.LengthPercentageAuto) {
    return value.margin;
}
pub fn padding(value: Style) geometry.Rect(dimension.LengthPercentage) {
    return value.padding;
}
pub fn border(value: Style) geometry.Rect(dimension.LengthPercentage) {
    return value.border;
}
pub fn contain(value: Style) Contain {
    return value.contain;
}
pub fn gap(value: Style) geometry.Size(dimension.LengthPercentage) {
    return value.gap;
}
pub fn align_items(value: Style) ?alignment.AlignItems {
    return value.align_items;
}
pub fn align_self(value: Style) ?alignment.AlignSelf {
    return value.align_self;
}
pub fn align_content(value: Style) ?alignment.AlignContent {
    return value.align_content;
}
pub fn justify_content(value: Style) ?alignment.JustifyContent {
    return value.justify_content;
}
pub fn flex_direction(value: Style) flex.FlexDirection {
    return value.flex_direction;
}
pub fn flex_wrap(value: Style) flex.FlexWrap {
    return value.flex_wrap;
}
pub fn flex_basis(value: Style) dimension.Dimension {
    return value.flex_basis;
}
pub fn flex_grow(value: Style) f32 {
    return value.flex_grow;
}
pub fn flex_shrink(value: Style) f32 {
    return value.flex_shrink;
}
pub fn grid_template_rows(value: Style) []const grid.GridTemplateComponent {
    return value.grid_template_rows;
}
pub fn grid_template_columns(value: Style) []const grid.GridTemplateComponent {
    return value.grid_template_columns;
}
pub fn grid_auto_rows(value: Style) []const grid.TrackSizingFunction {
    return value.grid_auto_rows;
}
pub fn grid_auto_columns(value: Style) []const grid.TrackSizingFunction {
    return value.grid_auto_columns;
}
pub fn grid_auto_flow(value: Style) grid.GridAutoFlow {
    return value.grid_auto_flow;
}
pub fn grid_row(value: Style) geometry.Line(grid.GridPlacement) {
    return value.grid_row;
}
pub fn grid_column(value: Style) geometry.Line(grid.GridPlacement) {
    return value.grid_column;
}
pub fn text_align(value: Style) block.TextAlign {
    return value.text_align;
}

pub fn is_table(value: Style) bool {
    return value.item_is_table;
}
pub fn float_value(value: Style) float.Float {
    return value.float;
}
pub fn clear(value: Style) float.Clear {
    return value.clear;
}
pub fn flex_line_count(value: Style) u16 {
    return value.flex_line_count;
}
pub fn justify_items(value: Style) ?alignment.JustifyItems {
    return value.justify_items;
}
pub fn grid_template_areas(value: Style) ?grid.GridTemplateAreas {
    return value.grid_template_areas;
}
pub fn grid_template_area_row_count(value: Style) u16 {
    return value.grid_template_area_row_count();
}
pub fn grid_template_area_column_count(value: Style) u16 {
    return value.grid_template_area_column_count();
}
pub fn grid_template_column_names(value: Style) []const grid.GridTemplateLineNames {
    return value.grid_template_column_names;
}
pub fn grid_template_row_names(value: Style) []const grid.GridTemplateLineNames {
    return value.grid_template_row_names;
}
pub fn justify_self(value: Style) ?alignment.JustifySelf {
    return value.justify_self;
}

test "style default is Taffy's row flex default" {
    const testing = @import("std").testing;
    const style = Style{};
    try testing.expect(style.display == .flex);
    try testing.expect(style.flex_direction == .row);
    try testing.expect(style.flex_shrink == 1);
    try testing.expectEqual(@as(?f32, 0), style.margin.left.resolve(100));
    try testing.expect((try Contain.from_str("layout paint")).contains(Contain.LAYOUT));
    try testing.expectError(error.InvalidContain, Contain.from_str("none layout"));
}

test {
    _ = @import("alignment.zig");
    _ = @import("available_space.zig");
    _ = @import("block.zig");
    _ = @import("compact_length.zig");
    _ = @import("dimension.zig");
    _ = @import("flex.zig");
    _ = @import("float.zig");
    _ = @import("grid.zig");
}
