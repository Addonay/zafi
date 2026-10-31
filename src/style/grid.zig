//! CSS Grid style values from Taffy's `style/grid.rs`.
//!
//! This pass preserves Taffy's split between minimum and maximum track
//! sizing functions. It is important that `1fr` is legal only on the maximum
//! side; representing every track as a single undifferentiated enum loses the
//! distinction used by the track-sizing algorithm.

const geometry = @import("../geometry.zig");
const dimension = @import("dimension.zig");
const compact_length = @import("compact_length.zig");
const std = @import("std");

const serde_support = @import("../serde_support.zig");
const serde_options = serde_support.pascal_options;
const serde_serialize = serde_support.serialize;
const serde_deserialize = serde_support.deserialize;
pub const GridStyleParseError = error{ InvalidGridValue, InvalidGridNumber, InvalidGridSyntax };

fn parse_grid_number(input: []const u8) GridStyleParseError!f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, input, " \t\r\n")) catch error.InvalidGridNumber;
}

fn parse_grid_length_percentage(input: []const u8) GridStyleParseError!dimension.LengthPercentage {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.endsWith(u8, value, "%")) return dimension.LengthPercentage.percent((try parse_grid_number(value[0 .. value.len - 1])) / 100);
    if (std.mem.endsWith(u8, value, "px")) return dimension.LengthPercentage.length(try parse_grid_number(value[0 .. value.len - 2]));
    return error.InvalidGridValue;
}

pub const GridTemplateArea = struct {
    name: []const u8,
    row_start: u16,
    row_end: u16,
    column_start: u16,
    column_end: u16,
};

pub const GridTemplateAreas = struct {
    areas: []const GridTemplateArea,
    row_count: u16,
    column_count: u16,

    pub fn area_row_count(self: GridTemplateAreas) u16 {
        return self.row_count;
    }
    pub fn area_column_count(self: GridTemplateAreas) u16 {
        return self.column_count;
    }

    /// Return the named area record, if the template contains that name.
    /// Taffy's identifiers are cheap-clone strings; this borrowed slice has
    /// the same lifetime boundary as the owning style in the Zig tree.
    pub fn area_named(self: GridTemplateAreas, name: []const u8) ?GridTemplateArea {
        for (self.areas) |area| if (std.mem.eql(u8, area.name, name)) return area;
        return null;
    }

    pub fn is_empty(self: GridTemplateAreas) bool {
        return self.areas.len == 0 and (self.row_count == 0 or self.column_count == 0);
    }
};

pub const GridTemplateAreaParseError = error{ EmptyTemplate, NonRectangular, InvalidAreaShape };

const AreaBounds = struct {
    name: []const u8,
    row_start: u16,
    row_end: u16,
    column_start: u16,
    column_end: u16,
};

fn area_token_at(rows: []const []const u8, row: usize, column: usize) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, rows[row], " \t");
    var index: usize = 0;
    while (tokens.next()) |token| : (index += 1) if (index == column) return token;
    return null;
}

/// Parse the row strings used by CSS `grid-template-areas`. Names are borrowed
/// from the supplied row storage; the returned area records own only their
/// array allocation, matching Taffy's cheap-clone identifier boundary.
pub fn parse_grid_template_areas(allocator: std.mem.Allocator, rows: []const []const u8) (GridTemplateAreaParseError || std.mem.Allocator.Error)!GridTemplateAreas {
    if (rows.len == 0) return error.EmptyTemplate;
    var column_count: ?usize = null;
    var bounds = std.ArrayList(AreaBounds).empty;
    defer bounds.deinit(allocator);
    for (rows, 0..) |row, row_index| {
        var tokens = std.mem.tokenizeAny(u8, row, " \t");
        var columns: usize = 0;
        while (tokens.next()) |token| {
            if (token.len == 0) return error.InvalidAreaShape;
            if (token[0] != '.') {
                var found: ?usize = null;
                for (bounds.items, 0..) |area, index| if (std.mem.eql(u8, area.name, token)) {
                    found = index;
                    break;
                };
                if (found) |index| {
                    bounds.items[index].row_start = @min(bounds.items[index].row_start, @as(u16, @intCast(row_index)));
                    bounds.items[index].row_end = @max(bounds.items[index].row_end, @as(u16, @intCast(row_index + 1)));
                    bounds.items[index].column_start = @min(bounds.items[index].column_start, @as(u16, @intCast(columns)));
                    bounds.items[index].column_end = @max(bounds.items[index].column_end, @as(u16, @intCast(columns + 1)));
                } else {
                    try bounds.append(allocator, .{ .name = token, .row_start = @intCast(row_index), .row_end = @intCast(row_index + 1), .column_start = @intCast(columns), .column_end = @intCast(columns + 1) });
                }
            }
            columns += 1;
        }
        if (columns == 0) return error.InvalidAreaShape;
        if (column_count) |expected| if (expected != columns) return error.NonRectangular else {} else column_count = columns;
    }
    for (bounds.items) |area| {
        for (area.row_start..area.row_end) |row| for (area.column_start..area.column_end) |column| {
            const token = area_token_at(rows, row, column) orelse return error.InvalidAreaShape;
            if (!std.mem.eql(u8, token, area.name)) return error.InvalidAreaShape;
        };
    }
    var result = try allocator.alloc(GridTemplateArea, bounds.items.len);
    for (bounds.items, 0..) |area, index| result[index] = .{ .name = area.name, .row_start = area.row_start, .row_end = area.row_end, .column_start = area.column_start, .column_end = area.column_end };
    return .{ .areas = result, .row_count = @intCast(rows.len), .column_count = @intCast(column_count.?) };
}

pub const NamedGridLine = struct {
    name: []const u8,
    index: i16,

    pub fn new(name: []const u8, index: i16) NamedGridLine {
        return .{ .name = name, .index = index };
    }
};

/// Axis used when looking up implicit names generated by a template area.
pub const GridAreaAxis = enum { row, column };

/// Which edge of a named area is being resolved.
pub const GridAreaEnd = enum { start, end };

/// Names attached to one template line; the outer slice is ordered by line.
pub const GridTemplateLineNames = []const []const u8;

pub const GridLine = i16;

pub const GridAutoFlow = enum {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    row,
    column,
    row_dense,
    column_dense,

    pub fn from_str(input: []const u8) !GridAutoFlow {
        const value = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "row")) return .row;
        if (std.ascii.eqlIgnoreCase(value, "column")) return .column;
        if (std.ascii.eqlIgnoreCase(value, "row dense")) return .row_dense;
        if (std.ascii.eqlIgnoreCase(value, "column dense")) return .column_dense;
        return error.InvalidGridAutoFlow;
    }
};

pub fn grid_auto_flow_is_dense(flow: GridAutoFlow) bool {
    return is_dense(flow);
}
pub fn grid_auto_flow_primary_axis(flow: GridAutoFlow) geometry.AbsoluteAxis {
    return primary_axis(flow);
}

pub fn is_dense(flow: GridAutoFlow) bool {
    return flow == .row_dense or flow == .column_dense;
}

pub fn primary_axis(flow: GridAutoFlow) geometry.AbsoluteAxis {
    return if (flow == .column or flow == .column_dense) .vertical else .horizontal;
}

/// Public CSS grid line placement, including named-line forms. Names remain
/// borrowed slices during this pass; the high-level tree owns the source
/// style, exactly as a borrowed Rust style does.
/// Named grid line placement payload: serialized as `["name", index]`
/// (Rust's tuple variant `NamedLine(S, i16)`).
///
/// The only reason this needs a hook is the tuple shape: serde.zig renders a
/// struct as a JSON object, so `{"name":...,"index":...}` is the only other
/// option it can produce.
pub const NamedLine = struct {
    name: []const u8,
    index: i16,

    pub const zerdeSerialize = serde_support.serializeNamedLine;
    pub const zerdeDeserialize = serde_support.deserializeNamedLine;
};

/// Named span placement payload: serialized as `["name", count]`
/// (Rust's tuple variant `NamedSpan(S, u16)`).
pub const NamedSpan = struct {
    name: []const u8,
    count: u16,

    pub const zerdeSerialize = serde_support.serializeNamedSpan;
    pub const zerdeDeserialize = serde_support.deserializeNamedSpan;
};

/// Taffy derives serde here: external tagging over a union with one void
/// variant, which serde.zig handles natively (a void variant serializes as its
/// bare name, a payload variant as a single-key object). Only the renames are
/// needed, so no custom hooks.
pub const GridPlacement = union(enum) {
    // `.tag` is omitted because external tagging is serde.zig's default; naming
    // it would mean importing serde.zig here for one enum value.
    pub const serde = .{
        .rename = .{
            .auto = "Auto",
            .line = "Line",
            .named_line = "NamedLine",
            .span = "Span",
            .named_span = "NamedSpan",
        },
    };

    auto,
    line: i16,
    named_line: NamedLine,
    span: u16,
    named_span: NamedSpan,

    pub fn from_line_index(index: i16) GridPlacement {
        // Zero is preserved at the style boundary. Taffy treats it as auto
        // only when converting CSS grid-line coordinates for placement.
        return .{ .line = index };
    }
    pub fn from_span(count: u16) GridPlacement {
        return .{ .span = count };
    }
    pub fn from_named_line(name: []const u8, index: i16) GridPlacement {
        return .{ .named_line = .{ .name = name, .index = index } };
    }
    pub fn from_named_span(name: []const u8, count: u16) GridPlacement {
        return .{ .named_span = .{ .name = name, .count = count } };
    }
    pub fn is_auto(self: GridPlacement) bool {
        return self == .auto;
    }
    pub fn is_span(self: GridPlacement) bool {
        return self == .span or self == .named_span;
    }
    pub fn is_named(self: GridPlacement) bool {
        return self == .named_line or self == .named_span;
    }
    pub fn line_index(self: GridPlacement) ?i16 {
        return switch (self) {
            .line => |value| value,
            .named_line => |value| value.index,
            else => null,
        };
    }
    pub fn span_value(self: GridPlacement) ?u16 {
        return switch (self) {
            .span => |value| value,
            .named_span => |value| value.count,
            else => null,
        };
    }
    pub fn indefinite_span(self: GridPlacement) u16 {
        return switch (self) {
            .span => |value| @max(@as(u16, 1), value),
            .named_span => |value| @max(@as(u16, 1), value.count),
            else => 1,
        };
    }
    pub fn into_origin_zero_ignoring_named(self: GridPlacement, explicit_track_count: u16) GridPlacement {
        return into_origin_zero_placement_ignoring_named(self, explicit_track_count);
    }
    pub fn is_definite(self: GridPlacement) bool {
        return switch (self) {
            .line => |value| value != 0,
            .named_line => true,
            else => false,
        };
    }
};

pub const OriginZeroLine = i16;
pub const OriginZeroGridPlacement = GridPlacement;

/// The non-named form used after named-line resolution. Keeping this as a
/// separate union mirrors Taffy's `GenericGridPlacement<GridLine>` and makes
/// accidental use of a still-unresolved name visible at the type boundary.
pub const NonNamedGridPlacement = union(enum) {
    auto,
    line: i16,
    span: u16,

    pub fn is_definite(self: NonNamedGridPlacement) bool {
        return switch (self) {
            .line => |value| value != 0,
            else => false,
        };
    }
};

pub const GenericGridPlacement = NonNamedGridPlacement;

pub fn placement_line(index: i16) GridPlacement {
    return .{ .line = index };
}

pub fn placement_span(count: u16) GridPlacement {
    return .{ .span = count };
}

pub fn placement_is_auto(value: GridPlacement) bool {
    return value == .auto;
}

pub fn saturating_i16(value: i32) i16 {
    return @intCast(@max(@as(i32, -32768), @min(@as(i32, 32767), value)));
}
pub fn saturating_u16(value: i32) u16 {
    return @intCast(@max(@as(i32, 0), @min(@as(i32, 65535), value)));
}

pub fn grid_placement_from_str(input: []const u8) !GridPlacement {
    // Port of Taffy's `FromCss for GridPlacement`: tokens may appear in any
    // order, with at most one each of `span`, an integer, and an identifier.
    var span = false;
    var number: ?i32 = null;
    var ident: ?[]const u8 = null;

    var tokens = std.mem.tokenizeAny(u8, std.mem.trim(u8, input, " \t\r\n"), " \t\r\n");
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "auto")) {
            if (span or number != null or ident != null) return error.InvalidGridPlacement;
            if (tokens.next() != null) return error.InvalidGridPlacement;
            return .auto;
        } else if (std.ascii.eqlIgnoreCase(token, "span")) {
            if (span) return error.InvalidGridPlacement;
            span = true;
        } else if (std.fmt.parseInt(i32, token, 10)) |value| {
            if (value == 0 or number != null) return error.InvalidGridPlacement;
            number = value;
        } else |_| {
            if (ident != null) return error.InvalidGridPlacement;
            ident = token;
        }
    }

    if (span) {
        if (number) |value| {
            if (ident) |name| return .{ .named_span = .{ .name = name, .count = saturating_u16(value) } };
            return .{ .span = saturating_u16(value) };
        }
        if (ident) |name| return .{ .named_span = .{ .name = name, .count = 0 } };
        return .{ .span = 0 };
    }
    if (number) |value| {
        if (ident) |name| return .{ .named_line = .{ .name = name, .index = saturating_i16(value) } };
        return .{ .line = saturating_i16(value) };
    }
    if (ident) |name| return .{ .named_line = .{ .name = name, .index = 0 } };
    return error.InvalidGridPlacement;
}

pub fn into_origin_zero_placement_ignoring_named(value: GridPlacement, explicit_track_count: u16) OriginZeroGridPlacement {
    return switch (value) {
        .auto => .auto,
        .span => |span_value| .{ .span = @min(@as(u16, 10_000), @max(@as(u16, 1), span_value)) },
        .line => |line_value| if (line_value == 0) .auto else .{ .line = normalize_grid_line(line_value, explicit_track_count) },
        .named_line, .named_span => .auto,
    };
}

fn normalize_grid_line(line_value: i16, explicit_track_count: u16) i16 {
    const raw: i32 = if (line_value > 0) @as(i32, line_value) - 1 else @as(i32, explicit_track_count) + 1 + line_value;
    // Negative CSS line numbers count from the explicit-grid end line, which
    // is one line beyond the explicit track count. For example -1 is the
    // final explicit line and -5 is line zero in a four-track grid.
    return @intCast(@max(@as(i32, -10_000), @min(@as(i32, 10_000), raw)));
}

pub fn line_into_origin_zero(value: geometry.Line(GridPlacement), explicit_track_count: u16) geometry.Line(OriginZeroGridPlacement) {
    return .{
        .start = into_origin_zero_placement_ignoring_named(value.start, explicit_track_count),
        .end = into_origin_zero_placement_ignoring_named(value.end, explicit_track_count),
    };
}

pub fn line_indefinite_span(value: geometry.Line(GridPlacement)) u16 {
    return switch (value.start) {
        .span => |span_value| @max(@as(u16, 1), span_value),
        .named_span => |span_value| @max(@as(u16, 1), span_value.count),
        else => switch (value.end) {
            .span => |span_value| @max(@as(u16, 1), span_value),
            .named_span => |span_value| @max(@as(u16, 1), span_value.count),
            else => 1,
        },
    };
}

pub fn line_is_definite(value: geometry.Line(GridPlacement)) bool {
    return switch (value.start) {
        .line => |line_value| line_value != 0,
        .named_line => true,
        else => switch (value.end) {
            .line => |line_value| line_value != 0,
            .named_line => true,
            else => false,
        },
    };
}

/// Resolve an OriginZero placement once one or both axes are definite. These
/// are the CSS Grid conflict-resolution cases used by placement and absolute
/// positioning; keeping them here avoids duplicating span arithmetic in the
/// compute modules.
pub fn line_resolve_definite_grid_lines(value: geometry.Line(GridPlacement), explicit_track_count: u16) geometry.Line(i16) {
    return origin_zero_line_resolve_definite_grid_lines(line_into_origin_zero(value, explicit_track_count));
}

/// `NonNamedGridPlacement::into_origin_zero_placement`: CSS line numbers become
/// OriginZero lines (clamped to the limited grid); zero lines fall back to auto;
/// spans are clamped to `1.std.MAX_GRID_TRACKS`.
pub fn into_origin_zero_placement(value: GridPlacement, explicit_track_count: u16) GridPlacement {
    return switch (value) {
        .auto => .auto,
        .span => |span| .{ .span = @min(@as(u16, 10_000), @max(@as(u16, 1), span)) },
        .line => |line| if (line == 0) .auto else .{ .line = normalize_grid_line(line, explicit_track_count) },
        .named_line, .named_span => .auto,
    };
}

/// `Line<OriginZeroGridPlacement>::is_definite`: definite if either edge is a line.
pub fn origin_zero_line_is_definite(value: geometry.Line(GridPlacement)) bool {
    return value.start == .line or value.end == .line;
}

/// `Line<OriginZeroGridPlacement>::resolve_definite_grid_lines`.
pub fn origin_zero_line_resolve_definite_grid_lines(value: geometry.Line(GridPlacement)) geometry.Line(i16) {
    const start_line = placement_line_number(value.start);
    const end_line = placement_line_number(value.end);
    if (start_line) |start| {
        if (end_line) |end| {
            if (start == end) return .{ .start = start, .end = start + 1 };
            return .{ .start = @min(start, end), .end = @max(start, end) };
        }
        return .{ .start = start, .end = start + @as(i16, @intCast(placement_span_number(value.end))) };
    }
    if (end_line) |end| {
        return .{ .start = end - @as(i16, @intCast(placement_span_number(value.start))), .end = end };
    }
    @panic("resolve_definite_grid_tracks should only be called on definite grid tracks");
}

/// `Line<OriginZeroGridPlacement>::resolve_absolutely_positioned_grid_tracks`.
pub fn origin_zero_line_resolve_absolutely_positioned_grid_tracks(value: geometry.Line(GridPlacement)) geometry.Line(?i16) {
    const start_line = placement_line_number(value.start);
    const end_line = placement_line_number(value.end);
    if (start_line) |start| {
        if (end_line) |end| {
            if (start == end) return .{ .start = start, .end = start + 1 };
            return .{ .start = @min(start, end), .end = @max(start, end) };
        }
        if (value.end == .auto) return .{ .start = start, .end = null };
        return .{ .start = start, .end = start + @as(i16, @intCast(placement_span_number(value.end))) };
    }
    if (end_line) |end| {
        if (value.start == .auto) return .{ .start = null, .end = end };
        return .{ .start = end - @as(i16, @intCast(placement_span_number(value.start))), .end = end };
    }
    return .{ .start = null, .end = null };
}

/// `Line<OriginZeroGridPlacement>::resolve_indefinite_grid_tracks`.
pub fn origin_zero_line_resolve_indefinite_grid_tracks(value: geometry.Line(GridPlacement), start: i16) geometry.Line(i16) {
    return .{ .start = start, .end = start + @as(i16, @intCast(origin_zero_line_indefinite_span(value))) };
}

/// `Line<OriginZeroGridPlacement>::indefinite_span`.
pub fn origin_zero_line_indefinite_span(value: geometry.Line(GridPlacement)) u16 {
    const start_is_line = value.start == .line;
    const end_is_line = value.end == .line;
    if (start_is_line and end_is_line) @panic("indefinite_span should only be called on indefinite grid tracks");
    if (value.start == .span) return placement_span_number(value.start);
    if (value.end == .span) return placement_span_number(value.end);
    return 1;
}

pub fn line_resolve_absolutely_positioned_grid_tracks(value: geometry.Line(GridPlacement), explicit_track_count: u16) geometry.Line(?i16) {
    const normalized = line_into_origin_zero(value, explicit_track_count);
    const start = placement_line_number(normalized.start);
    const end = placement_line_number(normalized.end);
    if (start) |start_line| {
        if (end) |end_line| return if (start_line == end_line) .{ .start = start_line, .end = start_line + 1 } else .{ .start = @min(start_line, end_line), .end = @max(start_line, end_line) };
        return .{ .start = start_line, .end = if (normalized.end == .auto) null else start_line + @as(i16, @intCast(placement_span_number(normalized.end))) };
    }
    if (end) |end_line| return .{ .start = if (normalized.start == .auto) null else end_line - @as(i16, @intCast(placement_span_number(normalized.start))), .end = end_line };
    return .{ .start = null, .end = null };
}

pub fn line_resolve_indefinite_grid_tracks(value: geometry.Line(GridPlacement), start: i16) geometry.Line(i16) {
    const span = placement_span_number(value.start);
    return .{ .start = start, .end = start + @as(i16, @intCast(span)) };
}

fn placement_line_number(value: GridPlacement) ?i16 {
    return switch (value) {
        .line => |line| line,
        else => null,
    };
}
fn placement_span_number(value: GridPlacement) u16 {
    return switch (value) {
        .span => |span| @max(@as(u16, 1), span),
        else => 1,
    };
}

pub const MinTrackSizingFunction = struct {
    /// Taffy-compatible serde: u64 wire bits with tag validation.
    pub const zerdeSerialize = serde_serialize;
    pub const zerdeDeserialize = serde_deserialize;

    value: compact_length.CompactLength,

    pub const zero: MinTrackSizingFunction = .{ .value = compact_length.CompactLength.length(0) };
    pub const auto: MinTrackSizingFunction = .{ .value = compact_length.CompactLength.auto() };
    pub const min_content: MinTrackSizingFunction = .{ .value = compact_length.CompactLength.min_content() };
    pub const max_content: MinTrackSizingFunction = .{ .value = compact_length.CompactLength.max_content() };

    pub fn length(value: f32) MinTrackSizingFunction {
        return .{ .value = compact_length.CompactLength.length(value) };
    }
    pub fn percent(value: f32) MinTrackSizingFunction {
        return .{ .value = compact_length.CompactLength.percent(value) };
    }
    pub fn calc(value: *const anyopaque) MinTrackSizingFunction {
        return .{ .value = compact_length.CompactLength.calc(value) };
    }
    pub fn from_length_percentage(value: dimension.LengthPercentage) MinTrackSizingFunction {
        return .{ .value = value.value };
    }
    pub fn from_length_percentage_auto(value: dimension.LengthPercentageAuto) MinTrackSizingFunction {
        return switch (value.value.tag()) {
            .auto => .auto,
            .length => length(value.value.value()),
            .percent => percent(value.value.value()),
            else => .auto,
        };
    }
    pub fn from_str(input: []const u8) GridStyleParseError!MinTrackSizingFunction {
        const value = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(value, "min-content")) return .min_content;
        if (std.ascii.eqlIgnoreCase(value, "max-content")) return .max_content;
        const length_percentage = try parse_grid_length_percentage(value);
        return .{ .value = length_percentage.value };
    }
    pub fn is_intrinsic(self: MinTrackSizingFunction) bool {
        return self.value.tag() == .auto or self.value.tag() == .min_content or self.value.tag() == .max_content;
    }
    pub fn is_min_or_max_content(self: MinTrackSizingFunction) bool {
        // Taffy: matches MIN_CONTENT | MAX_CONTENT tags only (auto is excluded).
        return self.is_min_content() or self.is_max_content();
    }
    pub fn is_fr(self: MinTrackSizingFunction) bool {
        _ = self;
        return false;
    }
    pub fn is_auto(self: MinTrackSizingFunction) bool {
        return self.value.tag() == .auto;
    }
    pub fn is_min_content(self: MinTrackSizingFunction) bool {
        return self.value.tag() == .min_content;
    }
    pub fn is_max_content(self: MinTrackSizingFunction) bool {
        return self.value.tag() == .max_content;
    }
    pub fn is_max_content_alike(self: MinTrackSizingFunction) bool {
        return self.is_max_content() or self.is_auto();
    }

    /// Taffy's `MinTrackSizingFunction::from(MaxTrackSizingFunction)`:
    /// `fr` and `fit-content()` map to `auto`; everything else is copied.
    pub fn from_max(input: MaxTrackSizingFunction) MinTrackSizingFunction {
        if (input.is_fr() or input.is_fit_content()) return .auto;
        return .{ .value = input.value };
    }
    pub fn uses_percentage(self: MinTrackSizingFunction) bool {
        return self.value.tag() == .percent;
    }

    pub fn definite_value(self: MinTrackSizingFunction, parent_size: ?f32) ?f32 {
        return switch (self.value.tag()) {
            .length => self.value.value(),
            .percent => if (parent_size) |basis| basis * self.value.value() else null,
            // Tree's default calc resolver returns 0 and still requires a
            // definite parent size to be considered definite.
            .calc => if (parent_size != null) 0 else null,
            else => null,
        };
    }

    pub fn into_raw(self: MinTrackSizingFunction) compact_length.CompactLength {
        return self.value;
    }
    pub fn has_definite_value(self: MinTrackSizingFunction, parent_size: ?f32) bool {
        return self.definite_value(parent_size) != null;
    }
    pub fn resolved_percentage_size(self: MinTrackSizingFunction, parent_size: f32) ?f32 {
        return self.value.resolved_percentage_size(parent_size);
    }
    pub fn expand(self: MinTrackSizingFunction) ExpandedMinTrackSizingFunction {
        return switch (self.value.tag()) {
            .auto => .auto,
            .length => .{ .length = self.value.value() },
            .percent => .{ .percent = self.value.value() },
            .min_content => .min_content,
            .max_content => .max_content,
            else => .auto,
        };
    }
};

pub const ExpandedMinTrackSizingFunction = union(enum) {
    auto,
    length: f32,
    percent: f32,
    min_content,
    max_content,
};

pub const MaxTrackSizingFunction = struct {
    /// Taffy-compatible serde: u64 wire bits with tag validation.
    pub const zerdeSerialize = serde_serialize;
    pub const zerdeDeserialize = serde_deserialize;

    value: compact_length.CompactLength,

    pub const zero: MaxTrackSizingFunction = .{ .value = compact_length.CompactLength.length(0) };
    pub const auto: MaxTrackSizingFunction = .{ .value = compact_length.CompactLength.auto() };
    pub const min_content: MaxTrackSizingFunction = .{ .value = compact_length.CompactLength.min_content() };
    pub const max_content: MaxTrackSizingFunction = .{ .value = compact_length.CompactLength.max_content() };

    pub fn length(value: f32) MaxTrackSizingFunction {
        return .{ .value = compact_length.CompactLength.length(value) };
    }
    pub fn percent(value: f32) MaxTrackSizingFunction {
        return .{ .value = compact_length.CompactLength.percent(value) };
    }
    pub fn fr(value: f32) MaxTrackSizingFunction {
        return .{ .value = compact_length.CompactLength.fr(value) };
    }
    pub fn fit_content_length(value: f32) MaxTrackSizingFunction {
        return .{ .value = compact_length.CompactLength.fit_content_length(value) };
    }
    pub fn fit_content_percent(value: f32) MaxTrackSizingFunction {
        return .{ .value = compact_length.CompactLength.fit_content_percent(value) };
    }
    pub fn fit_content(value: dimension.LengthPercentage) MaxTrackSizingFunction {
        return switch (value.value.tag()) {
            .length => fit_content_length(value.value.value()),
            .percent => fit_content_percent(value.value.value()),
            else => .auto,
        };
    }
    pub fn from_length_percentage(value: dimension.LengthPercentage) MaxTrackSizingFunction {
        return .{ .value = value.value };
    }
    pub fn from_length_percentage_auto(value: dimension.LengthPercentageAuto) MaxTrackSizingFunction {
        return switch (value.value.tag()) {
            .auto => .auto,
            .length => length(value.value.value()),
            .percent => percent(value.value.value()),
            else => .auto,
        };
    }
    pub fn from_dimension(value: dimension.Dimension) MaxTrackSizingFunction {
        return switch (value.value.tag()) {
            .length => length(value.value.value()),
            .percent => percent(value.value.value()),
            .min_content => .min_content,
            .max_content => .max_content,
            .fit_content_px => fit_content_length(value.value.value()),
            .fit_content_percent => fit_content_percent(value.value.value()),
            .auto => .auto,
            else => .auto,
        };
    }
    pub fn from_min(value: MinTrackSizingFunction) MaxTrackSizingFunction {
        return .{ .value = value.value };
    }
    pub fn from_str(input: []const u8) GridStyleParseError!MaxTrackSizingFunction {
        const value = std.mem.trim(u8, input, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(value, "min-content")) return .min_content;
        if (std.ascii.eqlIgnoreCase(value, "max-content")) return .max_content;
        if (std.mem.endsWith(u8, value, "fr")) {
            const fraction = try parse_grid_number(value[0 .. value.len - 2]);
            if (fraction < 0) return error.InvalidGridValue;
            return fr(fraction);
        }
        if (std.mem.startsWith(u8, value, "fit-content(") and std.mem.endsWith(u8, value, ")")) {
            const inner = value[12 .. value.len - 1];
            const length_percentage = try parse_grid_length_percentage(inner);
            return fit_content(length_percentage);
        }
        const length_percentage = try parse_grid_length_percentage(value);
        return .{ .value = length_percentage.value };
    }
    pub fn is_intrinsic(self: MaxTrackSizingFunction) bool {
        return self.value.tag() == .auto or self.value.tag() == .min_content or self.value.tag() == .max_content or self.is_fit_content();
    }
    pub fn is_max_content_alike(self: MaxTrackSizingFunction) bool {
        // Taffy: matches AUTO | MAX_CONTENT | FIT_CONTENT tags (min-content excluded).
        return self.value.is_max_content_alike();
    }
    pub fn is_fr(self: MaxTrackSizingFunction) bool {
        return self.value.tag() == .fr;
    }
    pub fn is_auto(self: MaxTrackSizingFunction) bool {
        return self.value.tag() == .auto;
    }
    pub fn is_min_content(self: MaxTrackSizingFunction) bool {
        return self.value.tag() == .min_content;
    }
    pub fn is_max_content(self: MaxTrackSizingFunction) bool {
        return self.value.tag() == .max_content;
    }
    pub fn is_fit_content(self: MaxTrackSizingFunction) bool {
        return self.value.tag() == .fit_content_px or self.value.tag() == .fit_content_percent;
    }
    pub fn is_max_or_fit_content(self: MaxTrackSizingFunction) bool {
        return self.is_max_content() or self.is_fit_content();
    }
    pub fn uses_percentage(self: MaxTrackSizingFunction) bool {
        return self.value.tag() == .percent or self.value.tag() == .fit_content_percent;
    }

    pub fn definite_value(self: MaxTrackSizingFunction, parent_size: ?f32) ?f32 {
        return switch (self.value.tag()) {
            .length => self.value.value(),
            .percent => if (parent_size) |basis| basis * self.value.value() else null,
            .calc => if (parent_size != null) 0 else null,
            else => null,
        };
    }

    pub fn definite_limit(self: MaxTrackSizingFunction, parent_size: ?f32) ?f32 {
        return self.definite_value(parent_size);
    }

    pub fn into_raw(self: MaxTrackSizingFunction) compact_length.CompactLength {
        return self.value;
    }
    pub fn has_definite_value(self: MaxTrackSizingFunction, parent_size: ?f32) bool {
        return self.definite_value(parent_size) != null;
    }
    pub fn resolved_percentage_size(self: MaxTrackSizingFunction, parent_size: f32) ?f32 {
        return self.value.resolved_percentage_size(parent_size);
    }
    pub fn calc(value: *const anyopaque) MaxTrackSizingFunction {
        return .{ .value = compact_length.CompactLength.calc(value) };
    }
    pub fn expand(self: MaxTrackSizingFunction) ExpandedMaxTrackSizingFunction {
        return switch (self.value.tag()) {
            .auto => .auto,
            .length => .{ .length = self.value.value() },
            .percent => .{ .percent = self.value.value() },
            .min_content => .min_content,
            .max_content => .max_content,
            .fr => .{ .fr = self.value.value() },
            .fit_content_px => .{ .fit_content_length = self.value.value() },
            .fit_content_percent => .{ .fit_content_percent = self.value.value() },
            else => .auto,
        };
    }
};

pub const ExpandedMaxTrackSizingFunction = union(enum) {
    auto,
    length: f32,
    percent: f32,
    min_content,
    max_content,
    fr: f32,
    fit_content_length: f32,
    fit_content_percent: f32,
};

pub const TrackSizingFunction = struct {
    min: MinTrackSizingFunction,
    max: MaxTrackSizingFunction,

    pub const zero: TrackSizingFunction = .{ .min = .zero, .max = .zero };
    pub const auto: TrackSizingFunction = .{ .min = .auto, .max = .auto };
    pub const min_content: TrackSizingFunction = .{ .min = .min_content, .max = .min_content };
    pub const max_content: TrackSizingFunction = .{ .min = .max_content, .max = .max_content };

    pub fn min_sizing_function(self: TrackSizingFunction) MinTrackSizingFunction {
        return self.min;
    }
    pub fn max_sizing_function(self: TrackSizingFunction) MaxTrackSizingFunction {
        return self.max;
    }
    pub fn from_min_max(minimum: MinTrackSizingFunction, maximum: MaxTrackSizingFunction) TrackSizingFunction {
        return .{ .min = minimum, .max = maximum };
    }
    pub fn has_fixed_component(self: TrackSizingFunction) bool {
        // Taffy: `self.min.0.is_length_or_percentage() || self.max.0.is_length_or_percentage()`
        return self.min.value.is_length_or_percentage() or self.max.value.is_length_or_percentage();
    }

    pub fn from_length(value: f32) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.length(value), .max = MaxTrackSizingFunction.length(value) };
    }
    pub fn from_percent(value: f32) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.percent(value), .max = MaxTrackSizingFunction.percent(value) };
    }
    pub fn from_fr(value: f32) TrackSizingFunction {
        return .{ .min = .auto, .max = MaxTrackSizingFunction.fr(value) };
    }

    pub fn from_length_percentage(value: dimension.LengthPercentage) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.from_length_percentage(value), .max = MaxTrackSizingFunction.from_length_percentage(value) };
    }
    pub fn from_length_percentage_auto(value: dimension.LengthPercentageAuto) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.from_length_percentage_auto(value), .max = MaxTrackSizingFunction.from_length_percentage_auto(value) };
    }

    pub fn fit_content(value: dimension.LengthPercentage) TrackSizingFunction {
        return .{ .min = .auto, .max = if (value.value.tag() == .length) .{ .value = compact_length.CompactLength.fit_content_length(value.value.numericValue()) } else .{ .value = compact_length.CompactLength.fit_content_percent(value.value.numericValue()) } };
    }

    pub fn from_dimension(value: dimension.Dimension) TrackSizingFunction {
        return switch (value.value.tag()) {
            .length => from_length(value.value.value()),
            .percent => from_percent(value.value.value()),
            .fr => from_fr(value.value.value()),
            .min_content => .min_content,
            .max_content => .max_content,
            .auto => .auto,
            else => .auto,
        };
    }

    /// Taffy's `TrackSizingFunction::from(MaxTrackSizingFunction)`.
    pub fn from_max(maximum: MaxTrackSizingFunction) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.from_max(maximum), .max = maximum };
    }

    pub fn from_str(input: []const u8) GridStyleParseError!TrackSizingFunction {
        const value = std.mem.trim(u8, input, " \t\r\n");
        if (std.mem.startsWith(u8, value, "minmax(") and std.mem.endsWith(u8, value, ")")) {
            const inner = value[7 .. value.len - 1];
            const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return error.InvalidGridSyntax;
            const minimum = try MinTrackSizingFunction.from_str(inner[0..comma]);
            const maximum = try MaxTrackSizingFunction.from_str(inner[comma + 1 ..]);
            return .{ .min = minimum, .max = maximum };
        }
        const maximum = try MaxTrackSizingFunction.from_str(value);
        return .{ .min = MinTrackSizingFunction.from_max(maximum), .max = maximum };
    }
};

pub const RepetitionCount = union(enum) {
    count: u16,
    auto_fit,
    auto_fill,

    /// Taffy derives serde here; external tagging with two void variants is
    /// native serde.zig, so only the renames are needed.
    pub const serde = .{
        .rename = .{
            .count = "Count",
            .auto_fit = "AutoFit",
            .auto_fill = "AutoFill",
        },
    };
};

pub const InvalidStringRepetitionValue = error{InvalidRepetitionValue};

pub fn repetition_count_parse(input: []const u8) InvalidStringRepetitionValue!RepetitionCount {
    return repetition_count_from_str(input);
}

pub fn repetition_count_from_u16(value: u16) RepetitionCount {
    return .{ .count = value };
}
pub fn repetition_count_is_auto(value: RepetitionCount) bool {
    return value == .auto_fit or value == .auto_fill;
}
pub fn repetition_count_from_str(value: []const u8) InvalidStringRepetitionValue!RepetitionCount {
    if (std.ascii.eqlIgnoreCase(value, "auto-fit")) return .auto_fit;
    if (std.ascii.eqlIgnoreCase(value, "auto-fill")) return .auto_fill;
    return .{ .count = std.fmt.parseInt(u16, value, 10) catch return error.InvalidRepetitionValue };
}

pub fn repetition_count_from_css(value: []const u8) InvalidStringRepetitionValue!RepetitionCount {
    const source = std.mem.trim(u8, value, " \t\r\n");
    return repetition_count_from_str(source);
}

pub const GridTemplateRepetition = struct {
    count: RepetitionCount,
    tracks: []const TrackSizingFunction,
    line_names: []const GridTemplateLineNames = &.{},

    /// The number of *repeated tracks* (per repetition), matching Taffy's
    /// `GenericRepetition::track_count`. The repetition count is applied
    /// separately by the callers.
    pub fn track_count(self: GridTemplateRepetition) u16 {
        return @intCast(@min(self.tracks.len, @as(usize, 65_535)));
    }

    /// The total number of tracks produced by all repetitions
    /// (`count * track_count()`), saturating like Taffy's folding arithmetic.
    pub fn total_track_count(self: GridTemplateRepetition) u16 {
        return switch (self.count) {
            .count => |count| @intCast(@min(@as(u32, count) * @as(u32, self.track_count()), @as(u32, 65_535))),
            .auto_fit, .auto_fill => self.track_count(),
        };
    }

    pub fn count_value(self: GridTemplateRepetition) RepetitionCount {
        return self.count;
    }

    pub fn tracks_value(self: GridTemplateRepetition) []const TrackSizingFunction {
        return self.tracks;
    }

    pub fn line_names_value(self: GridTemplateRepetition) []const GridTemplateLineNames {
        return self.line_names;
    }
};

pub const GenericGridTemplateComponent = union(enum) {
    /// Taffy-compatible serde: PascalCase variant names.
    pub const serde = serde_options;

    single: TrackSizingFunction,
    repeat: GridTemplateRepetition,
};

pub fn grid_template_component_is_auto_repetition(value: GridTemplateComponent) bool {
    return is_auto_repetition(value);
}

pub const GridTemplateComponent = GenericGridTemplateComponent;

fn skip_css_space(input: []const u8, index: *usize) void {
    while (index.* < input.len and (input[index.*] == ' ' or input[index.*] == '\t' or input[index.*] == '\r' or input[index.*] == '\n')) : (index.* += 1) {}
}

fn next_css_component(input: []const u8, index: *usize) ?[]const u8 {
    skip_css_space(input, index);
    if (index.* >= input.len) return null;
    const start = index.*;
    var depth: usize = 0;
    while (index.* < input.len) : (index.* += 1) {
        switch (input[index.*]) {
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ' ', '\t', '\r', '\n' => if (depth == 0) break,
            else => {},
        }
    }
    return input[start..index.*];
}

fn parse_line_name_group(input: []const u8, index: *usize) GridStyleParseError!GridTemplateLineNames {
    if (index.* >= input.len or input[index.*] != '[') return error.InvalidGridSyntax;
    const start = index.* + 1;
    var end = start;
    while (end < input.len and input[end] != ']') : (end += 1) {}
    if (end >= input.len) return error.InvalidGridSyntax;
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(std.heap.page_allocator);
    var tokens = std.mem.tokenizeAny(u8, input[start..end], " \t\r\n");
    while (tokens.next()) |name| names.append(std.heap.page_allocator, name) catch return error.InvalidGridSyntax;
    const owned = std.heap.page_allocator.alloc([]const u8, names.items.len) catch return error.InvalidGridSyntax;
    @memcpy(owned, names.items);
    index.* = end + 1;
    return owned;
}

pub fn grid_template_component_from_str(input: []const u8) GridStyleParseError!GridTemplateComponent {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.startsWith(u8, value, "repeat(") and std.mem.endsWith(u8, value, ")")) {
        const inner = value[7 .. value.len - 1];
        const comma = std.mem.indexOfScalar(u8, inner, ',') orelse return error.InvalidGridSyntax;
        const count = repetition_count_from_str(std.mem.trim(u8, inner[0..comma], " \t\r\n")) catch return error.InvalidGridValue;
        const parsed = try GridTemplateTracks.from_str(inner[comma + 1 ..]);
        return .{ .repeat = .{ .count = count, .tracks = parsed.tracks, .line_names = parsed.line_names } };
    }
    return .{ .single = try TrackSizingFunction.from_str(value) };
}

pub const GridTemplateTracks = struct {
    tracks: []const TrackSizingFunction = &.{},
    line_names: []const GridTemplateLineNames = &.{},

    pub fn is_empty(self: GridTemplateTracks) bool {
        return self.tracks.len == 0;
    }

    pub fn from_str(input: []const u8) GridStyleParseError!GridTemplateTracks {
        var tracks = std.ArrayList(TrackSizingFunction).empty;
        defer tracks.deinit(std.heap.page_allocator);
        var line_names = std.ArrayList(GridTemplateLineNames).empty;
        defer line_names.deinit(std.heap.page_allocator);
        line_names.append(std.heap.page_allocator, &.{}) catch return error.InvalidGridSyntax;
        var index: usize = 0;
        while (true) {
            skip_css_space(input, &index);
            if (index < input.len and input[index] == '[') {
                const parsed_names = try parse_line_name_group(input, &index);
                line_names.items[line_names.items.len - 1] = parsed_names;
                skip_css_space(input, &index);
            }
            if (index >= input.len) break;
            const token = next_css_component(input, &index) orelse return error.InvalidGridSyntax;
            const track = try TrackSizingFunction.from_str(token);
            tracks.append(std.heap.page_allocator, track) catch return error.InvalidGridSyntax;
            line_names.append(std.heap.page_allocator, &.{}) catch return error.InvalidGridSyntax;
        }
        if (tracks.items.len == 0) return error.InvalidGridSyntax;
        const owned = std.heap.page_allocator.alloc(TrackSizingFunction, tracks.items.len) catch return error.InvalidGridSyntax;
        @memcpy(owned, tracks.items);
        const owned_names = std.heap.page_allocator.alloc(GridTemplateLineNames, line_names.items.len) catch return error.InvalidGridSyntax;
        @memcpy(owned_names, line_names.items);
        return .{ .tracks = owned, .line_names = owned_names };
    }
};

/// Component-valued template track list, mirroring Taffy's
/// `GridTemplateTracks<S, GridTemplateComponent<S>>`. Unlike
/// `GridTemplateTracks`, entries may be `repeat(...)` repetitions and line
/// names may be attached inside repetitions.
pub const GridTemplateComponents = struct {
    tracks: []const GridTemplateComponent = &.{},
    line_names: []const GridTemplateLineNames = &.{},

    pub fn is_empty(self: GridTemplateComponents) bool {
        return self.tracks.len == 0;
    }

    pub fn from_str(input: []const u8) GridStyleParseError!GridTemplateComponents {
        var tracks = std.ArrayList(GridTemplateComponent).empty;
        defer tracks.deinit(std.heap.page_allocator);
        var line_names = std.ArrayList(GridTemplateLineNames).empty;
        defer line_names.deinit(std.heap.page_allocator);
        line_names.append(std.heap.page_allocator, &.{}) catch return error.InvalidGridSyntax;
        var index: usize = 0;
        while (true) {
            skip_css_space(input, &index);
            if (index < input.len and input[index] == '[') {
                const parsed_names = try parse_line_name_group(input, &index);
                line_names.items[line_names.items.len - 1] = parsed_names;
                skip_css_space(input, &index);
            }
            if (index >= input.len) break;
            const token = next_css_component(input, &index) orelse return error.InvalidGridSyntax;
            const track = try grid_template_component_from_str(token);
            tracks.append(std.heap.page_allocator, track) catch return error.InvalidGridSyntax;
            line_names.append(std.heap.page_allocator, &.{}) catch return error.InvalidGridSyntax;
        }
        if (tracks.items.len == 0) return error.InvalidGridSyntax;
        const owned = std.heap.page_allocator.alloc(GridTemplateComponent, tracks.items.len) catch return error.InvalidGridSyntax;
        @memcpy(owned, tracks.items);
        const owned_names = std.heap.page_allocator.alloc(GridTemplateLineNames, line_names.items.len) catch return error.InvalidGridSyntax;
        @memcpy(owned_names, line_names.items);
        return .{ .tracks = owned, .line_names = owned_names };
    }
};

pub const GridAutoTracks = []const TrackSizingFunction;

pub fn grid_auto_tracks_from_str(input: []const u8) GridStyleParseError![]const TrackSizingFunction {
    return (try GridTemplateTracks.from_str(input)).tracks;
}

pub fn is_auto_repetition(value: GridTemplateComponent) bool {
    return switch (value) {
        .single => false,
        .repeat => |repetition| repetition.count == .auto_fit or repetition.count == .auto_fill,
    };
}

pub fn grid_template_component_auto() GridTemplateComponent {
    return .{ .single = TrackSizingFunction.auto };
}
pub fn grid_template_component_zero() GridTemplateComponent {
    return .{ .single = TrackSizingFunction.zero };
}
pub fn grid_template_component_min_content() GridTemplateComponent {
    return .{ .single = TrackSizingFunction.min_content };
}
pub fn grid_template_component_max_content() GridTemplateComponent {
    return .{ .single = TrackSizingFunction.max_content };
}
pub fn grid_template_component_from_length(value: f32) GridTemplateComponent {
    return .{ .single = TrackSizingFunction.from_length(value) };
}
pub fn grid_template_component_from_percent(value: f32) GridTemplateComponent {
    return .{ .single = TrackSizingFunction.from_percent(value) };
}
pub fn grid_template_component_from_fr(value: f32) GridTemplateComponent {
    return .{ .single = TrackSizingFunction.from_fr(value) };
}

pub fn as_component_ref(value: GridTemplateComponent) GenericGridTemplateComponent {
    return value;
}

pub fn grid_row_default() geometry.Line(GridPlacement) {
    return .{ .start = .auto, .end = .auto };
}

test "grid placement resolves definite lines and spans" {
    const testing = std.testing;
    const definite = line_resolve_definite_grid_lines(.{ .start = .{ .line = 2 }, .end = .{ .line = 4 } }, 4);
    try testing.expectEqual(@as(i16, 1), definite.start);
    try testing.expectEqual(@as(i16, 3), definite.end);
    const spanning = line_resolve_definite_grid_lines(.{ .start = .{ .line = 2 }, .end = .{ .span = 3 } }, 4);
    try testing.expectEqual(@as(i16, 1), spanning.start);
    try testing.expectEqual(@as(i16, 4), spanning.end);
    const repetition = GridTemplateRepetition{ .count = .auto_fill, .tracks = &[_]TrackSizingFunction{TrackSizingFunction.from_fr(1)} };
    try testing.expectEqual(@as(u16, 1), repetition.track_count());
    try testing.expect(MinTrackSizingFunction.auto.is_intrinsic());
}

test "grid template areas parse rectangular named regions" {
    const testing = std.testing;
    const rows = [_][]const u8{ "header header", "main sidebar" };
    const parsed = try parse_grid_template_areas(testing.allocator, &rows);
    defer testing.allocator.free(parsed.areas);
    try testing.expectEqual(@as(u16, 2), parsed.row_count);
    try testing.expectEqual(@as(u16, 2), parsed.column_count);
    try testing.expectEqual(@as(usize, 3), parsed.areas.len);
}

test "grid sizing functions parse CSS spellings and preserve tags" {
    const testing = std.testing;
    const fraction = try MaxTrackSizingFunction.from_str("1fr");
    try testing.expect(fraction.is_fr());
    const fit = try MaxTrackSizingFunction.from_str("fit-content(25%)");
    try testing.expect(fit.is_fit_content());
    const minmax_value = try TrackSizingFunction.from_str("minmax(min-content, 2fr)");
    try testing.expect(minmax_value.min.is_min_content());
    try testing.expect(minmax_value.max.is_fr());
    const repeat_value = try grid_template_component_from_str("repeat(auto-fit, 12px)");
    switch (repeat_value) {
        .repeat => |repeat| {
            try testing.expect(repeat.count == .auto_fit);
            try testing.expectEqual(@as(usize, 1), repeat.tracks.len);
        },
        else => try testing.expect(false),
    }
    try testing.expectError(error.InvalidGridValue, MinTrackSizingFunction.from_str("1fr"));
}
