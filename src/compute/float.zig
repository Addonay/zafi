//! Direct port of Taffy's `compute/float.rs`.
//!
//! Computes the position of floats in a block formatting context. The precise
//! rules implemented here are documented in the Rust source header (CSS2
//! §9.5.1 rules 1-9). The segment model, fitter, and slot search mirror the
//! Rust implementation one function at a time.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style = @import("../style/root.zig");
const AvailableSpace = @import("../style/available_space.zig").AvailableSpace;

/// Tolerance used when checking whether a box fits in a horizontal space, to absorb `f32`
/// rounding errors (e.g. percentage widths and margins that sum to exactly 100% may otherwise
/// exceed the container width and spuriously wrap)
pub const FIT_TOLERANCE: f32 = 0.001;

/// An empty "slot" that avoids floats that is suitable for non-floated content
/// to be laid out into
pub const ContentSlot = struct {
    /// The id of the segment that the slot starts in
    segment_id: ?usize = null,
    /// The x position of the start of the slot
    x: f32 = 0,
    /// The y position of the start of the slot
    y: f32 = 0,
    /// The width of the slot
    width: f32 = 0,
    /// The height of the slot
    height: f32 = std.math.inf(f32),
};

/// An empty "slot" that avoids floats that is suitable for a box that establishes
/// an independent formatting context (and therefore must not overlap floats) to be
/// laid out into. Unlike [`ContentSlot`], this accounts for the box's own margins,
/// which are resolved against the containing block's edges (not float edges) and
/// may therefore overlap floats.
pub const BfcSlot = struct {
    /// The id of the segment that the slot starts in
    segment_id: ?usize = null,
    /// The x position of the start of the slot (border box edge)
    x: f32 = 0,
    /// The y position of the start of the slot
    y: f32 = 0,
    /// The space available_space for the box's border box: the space between float edges
    /// and the margin-inset containing block edges. The box fits in the slot if its
    /// border box width does not exceed this.
    border_width: f32 = 0,
    /// The width that an auto width resolves to (before applying min/max constraints and
    /// the negative-margin lower bound). This differs from `border_width` in that the
    /// trailing margin is subtracted (except for any part of it that overlaps a float).
    stretch_width: f32 = 0,
};

/// A floated box
pub const PlacedFloatedBox = struct {
    /// The caller-defined id that the box was placed with
    id: u64 = 0,
    /// The width of the box
    width: f32 = 0,
    /// The height of the box
    height: f32 = 0,
    /// Horizontal distance from the edge of the container that the box is floated towards
    /// (distance from the left for left floats, from the right for right floats)
    x_inset: f32 = 0,
    /// Vertical distance from top edge of the container
    y: f32 = 0,
};

/// A non-overlapping horizontal segment of the Block Formatting Context container
pub const Segment = struct {
    /// The vertical start and end points of the segment
    y_start: f32 = 0,
    y_end: f32 = 0,
    /// Left inset in slot 0. Right inset in slot 1.
    insets: [2]f32 = .{ 0, 0 },
    /// Whether a float actually occupies the left (slot 0) / right (slot 1) inset.
    /// The insets of a segment created for a float are seeded with the float's containing
    /// block insets on both sides, so a non-zero inset alone does not imply a float.
    has_float: [2]bool = .{ false, false },

    /// Whether the segment can fit the passed floated box (in the horizontal axis)
    ///
    /// See [`float_fits_horizontally`] for the details of the fit rules.
    pub fn fits_float_width(self: Segment, floated_box: geometry.Size(f32), direction: style.float.FloatDirection, bfc_width: f32, cb_insets: [2]f32) bool {
        return float_fits_horizontally(floated_box.width, direction, bfc_width, self.insets, cb_insets);
    }
};

/// A closed-open range indicating which segment the last placed float was placed in.
pub const SegmentRange = struct { start: usize = 0, end: usize = 0 };

/// Whether a floated box of the given width fits horizontally given the float insets
/// (`float_insets`) and containing block insets (`cb_insets`) that apply to it.
///
/// A float is normally placed at the further-in of the float edge and the containing block
/// edge on the side it is floated towards (its "lead" side). From that position it must:
///
///   - not overlap any float on the opposite ("trail") side (CSS2 §9.5.1 rule 3), and
///   - not extend past the containing block's trail edge if there is a float on its lead
///     side (CSS2 §9.5.1 rule 7: a float may only stick out of its containing block if it
///     is already as far towards its float direction as possible).
///
/// Note that a float which is not constrained by other floats *may* overflow its
/// containing block's trail edge (rules 1 and 7).
fn float_fits_horizontally(width: f32, direction: style.float.FloatDirection, bfc_width: f32, float_insets: [2]f32, cb_insets: [2]f32) bool {
    const lead = @backingInt(direction);
    const trail = 1 - lead;
    const x_inset = @max(float_insets[lead], cb_insets[lead]);
    const fits_opposite_floats = float_insets[trail] == 0.0 or x_inset + width <= bfc_width - float_insets[trail] + FIT_TOLERANCE;
    const fits_containing_block = float_insets[lead] == 0.0 or x_inset + width <= bfc_width - cb_insets[trail] + FIT_TOLERANCE;
    return fits_opposite_floats and fits_containing_block;
}

/// Helper type for placing a single floated box
///
/// Given a pinned starting y position, this type helps determine if there is any x position
/// such that there is sufficient horizontal space for the box across its entire height.
const FloatFitter = struct {
    /// The overall width of the Block Formatting Context
    bfc_width: f32,
    /// The total height of the set of segments currently being considered
    slot_height: f64,
    /// The union of the float insets of the set of segments currently being considered
    float_insets: [2]f32 = .{ 0, 0 },
    /// The insets of the box's containing block from the edges of the Block Formatting Context
    cb_insets: [2]f32,

    /// Create a new `FloatFitter`
    fn new(bfc_width: f32, slot_height: f32, cb_insets: [2]f32) FloatFitter {
        return .{ .bfc_width = bfc_width, .slot_height = @floatCast(slot_height), .cb_insets = cb_insets };
    }

    // Horizontal fitting

    /// Union the insets of another segment. This is a "max" of the insets on each side.
    fn union_insets(self: *FloatFitter, insets: [2]f32) void {
        self.float_insets[0] = @max(self.float_insets[0], insets[0]);
        self.float_insets[1] = @max(self.float_insets[1], insets[1]);
    }

    /// The inset from the edge of the BFC (on the side the box is floated towards) that the
    /// box would be placed at given the currently accounted for insets
    fn placed_inset(self: *const FloatFitter, direction: style.float.FloatDirection) f32 {
        const lead = @backingInt(direction);
        return @max(self.float_insets[lead], self.cb_insets[lead]);
    }

    /// Given the currently accounted for insets, check whether there is an x position
    /// such that the box fits horizontally.
    fn fits_horiontally(self: *const FloatFitter, width: f32, direction: style.float.FloatDirection) bool {
        return float_fits_horizontally(width, direction, self.bfc_width, self.float_insets, self.cb_insets);
    }

    // Vertical fitting

    /// Add the height of another segment.
    fn add_height(self: *FloatFitter, height: f32) void {
        self.slot_height += @as(f64, height);
    }

    /// Given the currently accounted for height, check whether the box fits vertically
    fn fits_vertically(self: *const FloatFitter, height: f32) bool {
        return self.slot_height >= @as(f64, height);
    }
};

/// A context for placing floated boxes
pub const FloatContext = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    /// The available_space space constraint that applies to the root Block Formatting Context
    /// for which this `FloatContext` manages floats.
    available_width: f32 = 0,
    /// Whether the float context contains any floats
    has_any_float: bool = false,
    /// A list of left-floated boxes within the context
    left_boxes: std.ArrayList(PlacedFloatedBox) = .empty,
    /// A list of right-floated boxes within the context
    right_boxes: std.ArrayList(PlacedFloatedBox) = .empty,
    /// A list of non-overlapping horizontal "segments" within the context.
    /// Each segment has the same available_space width for it's entire height.
    segments: std.ArrayList(Segment) = .empty,
    /// A closed-open range indicating which segment the last placed float
    /// was placed (on each side).
    last_placed_floats: [2]SegmentRange = .{ .{}, .{} },
    /// The bottom (y + height) of the lowest float placed on each side, including
    /// zero-sized floats (which occupy no segment). Left in slot 0, right in slot 1.
    clear_bottoms: [2]?f32 = .{ null, null },
    /// The topmost y position allowed for a new float (CSS2 float rule 5), including
    /// the tops of zero-sized floats (which occupy no segment)
    float_ceiling: ?f32 = null,

    /// Create a new empty `FloatContext`
    pub fn new() FloatContext {
        return .{};
    }

    pub fn init(allocator: std.mem.Allocator) FloatContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FloatContext) void {
        self.left_boxes.deinit(self.allocator);
        self.right_boxes.deinit(self.allocator);
        self.segments.deinit(self.allocator);
    }

    /// Whether the float context contains any floats
    pub fn has_floats(self: *const FloatContext) bool {
        return self.has_any_float;
    }

    /// Whether the float context contains any floats that extend to or below min_y
    pub fn has_active_floats(self: *const FloatContext, min_y: f32) bool {
        if (!self.has_any_float) return false;
        const last_end = if (self.segments.items.len > 0) self.segments.items[self.segments.items.len - 1].y_end else 0.0;
        return last_end > min_y;
    }

    /// Set the width of the `FloatContext`
    pub fn set_width(self: *FloatContext, available_width: f32) void {
        self.available_width = available_width;
    }

    /// Returns a slice of placed left floats
    pub fn left_floats(self: *const FloatContext) []const PlacedFloatedBox {
        return self.left_boxes.items;
    }

    /// Returns a slice of placed right floats
    pub fn right_floats(self: *const FloatContext) []const PlacedFloatedBox {
        return self.right_boxes.items;
    }

    /// Divide a segment into two segments so that a new float can be placed and have its
    /// vertical start and end at exact segment boundaries
    fn subdivide_segment(self: *FloatContext, idx: usize, divide_at_y: f32) void {
        const old_start = self.segments.items[idx].y_start;
        const old_end = self.segments.items[idx].y_end;
        const old_insets = self.segments.items[idx].insets;
        const old_has_float = self.segments.items[idx].has_float;
        std.debug.assert(old_start <= divide_at_y and divide_at_y < old_end and old_start != divide_at_y);
        self.segments.items[idx].y_end = divide_at_y;
        self.segments.insert(self.allocator, idx + 1, .{
            .y_start = divide_at_y,
            .y_end = old_end,
            .insets = old_insets,
            .has_float = old_has_float,
        }) catch @panic("Taffy float segment allocation failed");
    }

    /// Update the last placed float start and end values
    fn update_last_placed_float(self: *FloatContext, direction: style.float.FloatDirection, placement: SegmentRange) void {
        const slot = @backingInt(direction);
        self.last_placed_floats[slot].start = @max(self.last_placed_floats[slot].start, placement.start);
        self.last_placed_floats[slot].end = @max(self.last_placed_floats[slot].end, placement.end);
    }

    /// The (x, y) coordinates of a box previously placed in the context on the `direction` side
    pub fn placed_position(self: *const FloatContext, placed: PlacedFloatedBox, direction: style.float.FloatDirection) geometry.Point(f32) {
        return switch (direction) {
            .left => .{ .x = placed.x_inset, .y = placed.y },
            .right => .{ .x = self.available_width - placed.x_inset - placed.width, .y = placed.y },
        };
    }

    /// Position a floated box with the context, returning the (x, y) coordinates.
    /// `id` is stored with the placed box and is not otherwise interpreted.
    pub fn place_floated_box(
        self: *FloatContext,
        id: u64,
        floated_box: geometry.Size(f32),
        min_y: f32,
        containing_block_insets: [2]f32,
        direction: style.float.FloatDirection,
        clear: style.float.Clear,
    ) geometry.Point(f32) {
        self.has_any_float = true;

        const placed_floated_box =
            self.place_floated_box_inner(id, floated_box, min_y, containing_block_insets, direction, clear);

        const slot = @backingInt(direction);
        const bottom = placed_floated_box.y + placed_floated_box.height;
        self.clear_bottoms[slot] = if (self.clear_bottoms[slot]) |old| @max(old, bottom) else bottom;
        const y = placed_floated_box.y;
        self.float_ceiling = if (self.float_ceiling) |ceiling| @max(ceiling, y) else y;

        const pos = self.placed_position(placed_floated_box, direction);
        switch (direction) {
            .left => self.left_boxes.append(self.allocator, placed_floated_box) catch @panic("Taffy float allocation failed"),
            .right => self.right_boxes.append(self.allocator, placed_floated_box) catch @panic("Taffy float allocation failed"),
        }
        return pos;
    }

    const Placement = struct { start: ?usize, end: ?usize, placed_inset: f32 };

    /// Inner implementation of float placement, split into a separate function so that it can early-return
    fn place_floated_box_inner(
        self: *FloatContext,
        id: u64,
        floated_box: geometry.Size(f32),
        min_y: f32,
        containing_block_insets: [2]f32,
        direction: style.float.FloatDirection,
        clear: style.float.Clear,
    ) PlacedFloatedBox {
        const slot = @backingInt(direction);

        // Floats (including zero-sized floats) that occupy no segment still constrain the
        // position of later boxes: rule 5 (a float may not be higher than the top of any
        // earlier float) and `clear` (which clears past the bottom of floats on the
        // relevant side, regardless of their width)
        const effective_min_y = @max(
            @max(min_y, self.float_ceiling orelse -std.math.inf(f32)),
            self.cleared_threshold(clear) orelse -std.math.inf(f32),
        );

        // Ensure that float:
        //    - Starts at or after the last placed float in either direction (CSS2 float rule 5:
        //      "The outer top of a floating box may not be higher than the outer top of any block
        //      or floated box generated by an element earlier in the source document")
        //    - Respects "clear"
        const float_start = @max(self.last_placed_floats[0].start, self.last_placed_floats[1].start);
        const hwm: usize = switch (clear) {
            .left => blk: {
                const left_end = self.last_placed_floats[0].end;
                break :blk @max(float_start, left_end + 1);
            },
            .right => blk: {
                const right_end = self.last_placed_floats[1].end;
                break :blk @max(float_start, right_end + 1);
            },
            .both => @max(self.last_placed_floats[0].end, self.last_placed_floats[1].end) + 1,
            .none => float_start,
        };

        // Ensure that float is placed in a segment at or below "min_y"
        // (ensuring that it is placed at or below min_y within its segment happens below)
        const start_idx_opt: ?usize = blk: {
            if (hwm >= self.segments.items.len) break :blk null;
            for (self.segments.items[hwm..], hwm..) |segment, idx| {
                if (segment.y_end > effective_min_y) break :blk idx;
            }
            break :blk null;
        };

        var start_idx = start_idx_opt orelse self.segments.items.len;
        var start_y = effective_min_y;
        var end_idx = start_idx;

        // Loop over remaining segments, trying to place the float in a position
        // that has space to accommodate it.
        const placement: Placement = outer: while (true) {
            // Start segment does not exist:
            //
            // This means no existing segment can accommodate the float so we must create a new
            // segment below all existing segments. A new segment will always have space for
            // the float, so we can exit the loop at this point.
            if (start_idx >= self.segments.items.len) {
                break :outer .{ .start = null, .end = null, .placed_inset = containing_block_insets[slot] };
            }
            const start_segment = self.segments.items[start_idx];

            // Candidate start segment doesn't have (horizontal) space for the float:
            // => retry with the next segment
            if (!start_segment.fits_float_width(floated_box, direction, self.available_width, containing_block_insets)) {
                start_idx += 1;
                end_idx = @max(end_idx, start_idx);
                continue :outer;
            }

            start_y = @max(start_y, start_segment.y_start);
            const available_height = start_segment.y_end - start_y;
            var fitter = FloatFitter.new(self.available_width, available_height, containing_block_insets);
            fitter.union_insets(start_segment.insets);

            // Pinning the start segment, loop over segments starting with the start segment
            // to find the end segment:
            //   - The selected segment range must have enough height to contain the float
            //   - All of the segments in the range must have enough horizontal width to contain the float
            while (true) {
                // End segment does not exist:
                //
                // This means no existing segment can accommodate the float so we must create a new
                // segment below all existing segments
                if (end_idx >= self.segments.items.len) {
                    const inset = fitter.placed_inset(direction);
                    break :outer .{ .start = start_idx, .end = null, .placed_inset = inset };
                }
                const end_segment = self.segments.items[end_idx];

                // Check horizontal fit
                //
                // If it does not fit horizontally then it will never fit in this position, so
                // continue the outer loop to find and check a new position
                fitter.union_insets(end_segment.insets);
                if (!fitter.fits_horiontally(floated_box.width, direction)) {
                    start_idx += 1;
                    end_idx = @max(end_idx, start_idx);
                    continue :outer;
                }

                // Check vertical fit
                //
                // If it does not (yet) fit vertically then continue the inner loop to add another
                // segment to the range of segments we are placing the float in
                if (end_idx != start_idx) {
                    fitter.add_height(end_segment.y_end - end_segment.y_start);
                }
                if (!fitter.fits_vertically(floated_box.height)) {
                    end_idx += 1;
                    continue;
                }

                const inset = fitter.placed_inset(direction);
                break :outer .{ .start = start_idx, .end = end_idx, .placed_inset = inset };
            }
        };

        // Short-circuit for zero-height boxes. Zero-width boxes are still recorded in segments:
        // their edge acts as an obstacle that boxes establishing an independent formatting
        // context may not be placed to the outside of (e.g. via a negative margin).
        if (floated_box.height == 0.0) {
            return PlacedFloatedBox{
                .id = id,
                .width = floated_box.width,
                .height = floated_box.height,
                .y = start_y,
                .x_inset = placement.placed_inset,
            };
        }

        // Handle case where floated box is placed after all existing segments
        if (placement.start == null) {
            // Before the first float, the context is float-free all the way up: the first float
            // gets an empty segment above it like any other float placed below all segments, so
            // that content positioned above it (e.g. by a negative margin) is not moved down to
            // it. The first float itself may be above the top of the block formatting context
            // (`y < 0`): its containing block (CSS2 float rule 4) may be pulled up by a negative
            // margin.
            const last_y_end = if (self.segments.items.len > 0) self.segments.items[self.segments.items.len - 1].y_end else -std.math.inf(f32);
            if (start_y > last_y_end) {
                self.segments.append(self.allocator, .{ .y_start = last_y_end, .y_end = start_y, .insets = .{ 0.0, 0.0 }, .has_float = .{ false, false } }) catch @panic("Taffy float segment allocation failed");
            }

            const new_start_y = @max(last_y_end, start_y);

            var insets = containing_block_insets;
            insets[slot] += floated_box.width;
            var has_float = [2]bool{ false, false };
            has_float[slot] = true;
            self.segments.append(self.allocator, .{ .y_start = new_start_y, .y_end = new_start_y + floated_box.height, .insets = insets, .has_float = has_float }) catch @panic("Taffy float segment allocation failed");

            // Update last_placed_float
            const new_start_idx = self.segments.items.len - 1;
            const new_end_idx = new_start_idx + 1;
            self.update_last_placed_float(direction, .{ .start = new_start_idx, .end = new_end_idx });

            return PlacedFloatedBox{
                .id = id,
                .width = floated_box.width,
                .height = floated_box.height,
                .y = new_start_y,
                .x_inset = containing_block_insets[slot],
            };
        }

        // Else unwrap the index of the segment that the start of the floating box is placed in
        var resolved_start_idx = placement.start.?;

        // If the floated box doesn't start at the exact same y-offset as the segment it starts in, then
        // subdivide that segment into two segments at the y-offset that the floated box starts at, and increment
        // `start_idx` so that the floating box is placed in the second of the two segments.
        if (start_y != self.segments.items[resolved_start_idx].y_start) {
            self.subdivide_segment(resolved_start_idx, start_y);
            resolved_start_idx += 1;
            if (placement.end != null) end_idx += 1;
        }

        const end_idx_final: usize = if (placement.end == null) blk: {
            // The float extends below all existing segments: add a segment for the part of it
            // below the last segment (its insets are set along with the other segments below)
            const last_y_end = self.segments.items[self.segments.items.len - 1].y_end;
            const end_y = start_y + floated_box.height;
            if (end_y > last_y_end) {
                self.segments.append(self.allocator, .{ .y_start = last_y_end, .y_end = end_y, .insets = containing_block_insets, .has_float = .{ false, false } }) catch @panic("Taffy float segment allocation failed");
            }
            break :blk self.segments.items.len - 1;
        } else blk: {
            var e = end_idx;
            const end_y = start_y + floated_box.height;

            // Due to floating point imprecision, `end_y` may coincide with (or fall before)
            // the start of the end segment even though the sum of the candidate segment
            // heights was computed as sufficient. In that case the float effectively ends at
            // the boundary of the previous segment, so walk back to the segment that actually
            // contains `end_y`.
            while (e > resolved_start_idx and end_y <= self.segments.items[e].y_start) {
                e -= 1;
            }

            // Only subdivide if `end_y` falls strictly within the segment. If it lands on
            // (or, due to floating point imprecision, beyond) a segment boundary then no
            // subdivision is needed.
            if (self.segments.items[e].y_start < end_y and end_y < self.segments.items[e].y_end) {
                self.subdivide_segment(e, end_y);
            }

            break :blk e;
        };

        // Update inset for the range of segments that the float is placed in
        const placed_inset_plus_width = placement.placed_inset + floated_box.width;
        var segment_index = resolved_start_idx;
        while (segment_index <= end_idx_final) : (segment_index += 1) {
            self.segments.items[segment_index].insets[slot] = placed_inset_plus_width;
            self.segments.items[segment_index].has_float[slot] = true;
        }

        // Update last_placed_float
        self.update_last_placed_float(direction, .{ .start = resolved_start_idx, .end = end_idx_final + 1 });

        return PlacedFloatedBox{ .id = id, .width = floated_box.width, .height = floated_box.height, .y = start_y, .x_inset = placement.placed_inset };
    }

    /// Get the end segment of the last float on side(s) specified by the clear parameter (if any)
    ///
    /// Returns `None` if no float has been placed on the relevant side(s)
    fn cleared_segment(self: *const FloatContext, clear: style.float.Clear) ?usize {
        const left_end = self.last_placed_floats[0].end;
        const right_end = self.last_placed_floats[1].end;
        return switch (clear) {
            .left => if (left_end > 0) left_end else null,
            .right => if (right_end > 0) right_end else null,
            .both => if (left_end > 0 or right_end > 0) @max(left_end, right_end) else null,
            .none => null,
        };
    }

    /// Get the bottom of lowest relevant float for the specific clear property
    pub fn cleared_threshold(self: *const FloatContext, clear: style.float.Clear) ?f32 {
        return switch (clear) {
            .left => self.clear_bottoms[0],
            .right => self.clear_bottoms[1],
            .both => if (self.clear_bottoms[0]) |left|
                (if (self.clear_bottoms[1]) |right| @max(left, right) else left)
            else
                self.clear_bottoms[1],
            .none => null,
        };
    }

    /// Search for a space suitable for laying out non-floated content into
    pub fn find_content_slot(
        self: *const FloatContext,
        min_y: f32,
        containing_block_insets: [2]f32,
        clear: style.float.Clear,
        after: ?usize,
    ) ContentSlot {
        if (!self.has_active_floats(min_y)) {
            return ContentSlot{
                .segment_id = null,
                .x = containing_block_insets[0],
                .y = min_y,
                .width = self.available_width - containing_block_insets[0] - containing_block_insets[1],
                .height = std.math.inf(f32),
            };
        }

        // Clearance clears past the bottom of floats on the relevant side, including
        // zero-sized floats which occupy no segment
        const clamped_min_y = @max(min_y, self.cleared_threshold(clear) orelse -std.math.inf(f32));

        // The min starting segment index
        const at_least = if (after) |idx| idx + 1 else 0;
        const hwm = @max(at_least, if (self.cleared_segment(clear)) |idx| idx + 1 else 0);

        const start_idx: usize = blk: {
            if (hwm >= self.segments.items.len) break :blk self.segments.items.len;
            for (self.segments.items[hwm..], hwm..) |segment, idx| {
                if (segment.y_end > clamped_min_y) break :blk idx;
            }
            break :blk self.segments.items.len;
        };

        if (start_idx < self.segments.items.len) {
            const segment = self.segments.items[start_idx];
            const inset_left = @max(segment.insets[0], containing_block_insets[0]);
            const inset_right = @max(segment.insets[1], containing_block_insets[1]);
            return ContentSlot{
                .segment_id = start_idx,
                .x = inset_left,
                .y = @max(segment.y_start, clamped_min_y),
                .width = self.available_width - inset_left - inset_right,
                .height = std.math.inf(f32),
            };
        }
        return ContentSlot{
            .segment_id = null,
            .x = containing_block_insets[0],
            .y = clamped_min_y,
            .width = self.available_width - containing_block_insets[0] - containing_block_insets[1],
            .height = std.math.inf(f32),
        };
    }

    /// Search for a space suitable for laying out a box that establishes an independent
    /// formatting context (whose border box must not overlap floats).
    ///
    /// See the Rust source for the full description of how margins interact with floats.
    pub fn find_bfc_slot(
        self: *const FloatContext,
        min_y: f32,
        containing_block_insets: [2]f32,
        margins: [2]f32,
        direction: style.Direction,
        clear: style.float.Clear,
        after: ?usize,
    ) BfcSlot {
        const margin_insets = [2]f32{ containing_block_insets[0] + margins[0], containing_block_insets[1] + margins[1] };
        const no_float_width = self.available_width - margin_insets[0] - margin_insets[1];
        const no_float_slot = BfcSlot{
            .segment_id = null,
            .x = margin_insets[0],
            .y = min_y,
            .border_width = no_float_width,
            .stretch_width = no_float_width,
        };

        if (!self.has_active_floats(min_y)) {
            return no_float_slot;
        }

        // Clearance clears past the bottom of floats on the relevant side, including
        // zero-sized floats which occupy no segment
        const clamped_min_y = @max(min_y, self.cleared_threshold(clear) orelse -std.math.inf(f32));

        // The min starting segment index
        const at_least = if (after) |idx| idx + 1 else 0;
        const hwm = @max(at_least, if (self.cleared_segment(clear)) |idx| idx + 1 else 0);

        const start_idx: usize = blk: {
            if (hwm >= self.segments.items.len) break :blk self.segments.items.len;
            for (self.segments.items[hwm..], hwm..) |segment, idx| {
                if (segment.y_end > clamped_min_y) break :blk idx;
            }
            break :blk self.segments.items.len;
        };

        if (start_idx < self.segments.items.len) {
            const segment = self.segments.items[start_idx];
            const lead: usize = switch (direction) {
                .ltr => 0,
                .rtl => 1,
            };
            const trail = 1 - lead;
            const has_lead_float = segment.has_float[lead];
            const has_trail_float = segment.has_float[trail];
            var fit_insets = [2]f32{ 0.0, 0.0 };
            var stretch_insets = [2]f32{ 0.0, 0.0 };
            fit_insets[lead] = if (has_lead_float) @max(segment.insets[lead], margin_insets[lead]) else margin_insets[lead];
            stretch_insets[lead] = fit_insets[lead];
            fit_insets[trail] = if (has_trail_float)
                @max(segment.insets[trail], containing_block_insets[trail])
            else
                // A positive trailing margin may overflow the containing block edge (it does
                // not affect fit), but a negative one widens the space for the border box
                @min(margin_insets[trail], containing_block_insets[trail]);
            stretch_insets[trail] = if (has_trail_float)
                @max(segment.insets[trail], margin_insets[trail])
            else
                margin_insets[trail];
            return BfcSlot{
                .segment_id = start_idx,
                .x = fit_insets[0],
                .y = @max(segment.y_start, clamped_min_y),
                .border_width = self.available_width - fit_insets[0] - fit_insets[1],
                .stretch_width = self.available_width - stretch_insets[0] - stretch_insets[1],
            };
        }
        // Below all floats
        const last_y_end = if (self.segments.items.len > 0) self.segments.items[self.segments.items.len - 1].y_end else clamped_min_y;
        return BfcSlot{
            .segment_id = null,
            .x = no_float_slot.x,
            .y = @max(last_y_end, clamped_min_y),
            .border_width = no_float_width,
            .stretch_width = no_float_width,
        };
    }
};

/// Context for computing the intrinsic width contribution of a set of floats
pub const FloatIntrinsicWidthCalculator = struct {
    /// The available_space width of the container
    available_width: AvailableSpace,
    /// The running sums of the widths of adjacent uncleared floats on each side (left, right)
    side_sums: [2]f32 = .{ 0, 0 },
    /// The running total intrinsic width contribution
    contribution: f32 = 0,
    /// The widest single float (the floats' min-content contribution)
    widest: f32 = 0,

    /// Create a new `FloatIntrinsicWidthCalculator`
    pub fn new(available_width: AvailableSpace) FloatIntrinsicWidthCalculator {
        return .{ .available_width = available_width };
    }

    /// Add a float to the computation
    pub fn add_float(self: *FloatIntrinsicWidthCalculator, width: f32, direction: style.float.FloatDirection, clear: style.float.Clear) void {
        switch (self.available_width) {
            // Definite available_space width means the container is being fit-content sized
            // (e.g. it is itself a float being shrink-to-fit sized). The floats' max-content
            // contribution (widths summed) is clamped by the available_space width in `result`.
            .definite, .max_content => {
                // A float that clears a side is placed below the floats on that side, so its
                // width does not accumulate with theirs.
                if (clear == .left or clear == .both) self.side_sums[0] = 0.0;
                if (clear == .right or clear == .both) self.side_sums[1] = 0.0;
                self.side_sums[@backingInt(direction)] += width;
                self.contribution = @max(self.contribution, self.side_sums[0] + self.side_sums[1]);
            },
            .min_content => self.contribution = @max(self.contribution, width),
        }
        self.widest = @max(self.widest, width);
    }

    /// Get the computed float contribution to intrinsic width
    pub fn result(self: *const FloatIntrinsicWidthCalculator) f32 {
        return switch (self.available_width) {
            // Fit-content sizing: clamp the max-content contribution between the available_space
            // width and the min-content contribution (floats narrow by wrapping onto new
            // bands, but never below the widest single float).
            .definite => |available_width| @max(@min(self.contribution, available_width), self.widest),
            else => self.contribution,
        };
    }
};

test "float placement preserves clearance and side edges" {
    const testing = @import("std").testing;
    var context = FloatContext.init(testing.allocator);
    defer context.deinit();
    context.set_width(100);
    const left = context.place_floated_box(1, .{ .width = 40, .height = 20 }, 0, .{ 0, 0 }, .left, .none);
    try testing.expectEqual(@as(f32, 0), left.x);
    const right = context.place_floated_box(2, .{ .width = 40, .height = 20 }, 0, .{ 0, 0 }, .right, .none);
    try testing.expectEqual(@as(f32, 60), right.x);
    const slot = context.find_content_slot(0, .{ 0, 0 }, .none, null);
    try testing.expectEqual(@as(f32, 20), slot.width);
    try testing.expect(context.cleared_threshold(.both) != null);
    try testing.expectEqual(@as(?f32, 20), context.cleared_threshold(.both));
    // A second left float cannot fit beside the first at the same y, so it wraps below.
    const wrapped = context.place_floated_box(3, .{ .width = 70, .height = 10 }, 0, .{ 0, 0 }, .left, .none);
    try testing.expectEqual(@as(f32, 20), wrapped.y);
}

test "float zero-height boxes still constrain clearance" {
    const testing = @import("std").testing;
    var context = FloatContext.init(testing.allocator);
    defer context.deinit();
    context.set_width(100);
    _ = context.place_floated_box(0, .{ .width = 20, .height = 0 }, 5, .{ 0, 0 }, .left, .none);
    try testing.expect(!context.has_active_floats(5));
    try testing.expectEqual(@as(?f32, 5), context.cleared_threshold(.left));
}

test "find_bfc_slot accounts for margins against float edges" {
    const testing = @import("std").testing;
    var context = FloatContext.init(testing.allocator);
    defer context.deinit();
    context.set_width(100);
    _ = context.place_floated_box(0, .{ .width = 30, .height = 50 }, 0, .{ 0, 0 }, .left, .none);
    const slot = context.find_bfc_slot(0, .{ 0, 0 }, .{ 5, 5 }, .ltr, .none, null);
    try testing.expectEqual(@as(f32, 30), slot.x);
    // The trailing margin may overflow the containing block edge when fitting, but is
    // subtracted from the stretch width.
    try testing.expectEqual(@as(f32, 70), slot.border_width);
    try testing.expectEqual(@as(f32, 65), slot.stretch_width);
}
