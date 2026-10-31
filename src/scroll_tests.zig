//! Port of Taffy's hand-written scroll tests (`tests/hand_written/scrollable_overflow.rs`
//! and `tests/hand_written/scroll_size.rs`). These cover scrollable-overflow behaviour that
//! the generated XML fixtures do not (reversed scroll origins, end padding, clipping).

const std = @import("std");
const zafi = @import("root.zig");
