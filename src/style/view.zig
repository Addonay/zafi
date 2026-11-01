//! Custom style types: the Zig counterpart of Taffy's style traits
//! (`CoreStyle`, `FlexboxContainerStyle`, ..., `BlockItemStyle`).
//!
//! The layout algorithms read every style property as `s.get(.name)`. With
//! zafi's own `Style` that is a plain inlined field load. A `LayoutTree` host
//! may instead return a pointer to *its own* style type from `get_style`; the
//! algorithms then see it through `View(HostStyle)`, which resolves each
//! property, at compile time, to the first of:
//!
//!   0. a generic getter `pub fn get(self: *const HostStyle, comptime field:
//!      view.Field) view.FieldType(field)`, if the host declares one (it then
//!      answers every property; `StoredStyle` uses this),
//!   1. a method `pub fn name(self: *const HostStyle) T` (compute it on the fly
//!      from the host's own representation),
//!   2. a field `name: T` of the same type as zafi's `Style.name`,
//!   3. zafi's default (`Style{}.name`).
//!
//! So a host only declares the properties it supports, and pays nothing for the
//! rest. The derived queries (`is_block`, `is_replaced`, ...) follow the same
//! rule: a host method of that name wins, otherwise they are derived from the
//! properties exactly as `Style` derives them.

const std = @import("std");
const style = @import("root.zig");
const Style = style.Style;

pub const Field = std.meta.FieldEnum(Style);

pub fn FieldType(comptime field: Field) type {
    return @FieldType(Style, @tagName(field));
}

const defaults: Style = .{};

/// The style handle type the algorithms use for a host whose `get_style`
/// returns `*const S`.
pub fn Ref(comptime S: type) type {
    return if (S == Style) *const Style else View(S);
}

pub inline fn wrap(comptime S: type, value: *const S) Ref(S) {
    return if (comptime S == Style) value else .{ .inner = value };
}

/// Normalise a style argument: `*const Style`/`*Style`, a `View`, or a pointer
/// to a host style type.
pub inline fn of(value: anytype) RefOf(@TypeOf(value)) {
    const T = @TypeOf(value);
    if (comptime isView(T)) return value;
    return wrap(@typeInfo(T).pointer.child, value);
}

fn isView(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Host") and T == View(T.Host);
}

fn RefOf(comptime T: type) type {
    if (isView(T)) return T;
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one) @compileError("expected a style pointer or view, found " ++ @typeName(T));
    return Ref(info.pointer.child);
}

pub fn View(comptime S: type) type {
    return struct {
        inner: *const S,

        const Self = @This();
        pub const Host = S;

        pub inline fn get(self: Self, comptime field: Field) FieldType(field) {
            const name = @tagName(field);
            if (comptime @hasDecl(S, "get")) {
                return S.get(self.inner, field);
            } else if (comptime @hasDecl(S, name)) {
                return @field(S, name)(self.inner);
            } else if (comptime @hasField(S, name)) {
                if (comptime @FieldType(S, name) != FieldType(field)) {
                    @compileError(@typeName(S) ++ "." ++ name ++ " must be " ++ @typeName(FieldType(field)) ++
                        " (or declare `pub fn " ++ name ++ "(self: *const " ++ @typeName(S) ++ ")` returning it)");
                }
                return @field(self.inner, name);
            } else {
                return @field(defaults, name);
            }
        }

        inline fn override(comptime name: []const u8) bool {
            return @hasDecl(S, name) and !@hasField(Style, name);
        }

        pub inline fn box_generation_mode(self: Self) style.BoxGenerationMode {
            if (comptime override("box_generation_mode")) return S.box_generation_mode(self.inner);
            return if (self.get(.display) == .none) .none else .normal;
        }
        pub inline fn is_block(self: Self) bool {
            if (comptime override("is_block")) return S.is_block(self.inner);
            const display = self.get(.display);
            return display == .block or display == .flow_root;
        }
        pub inline fn establishes_formatting_context_from_display(self: Self) bool {
            if (comptime override("establishes_formatting_context_from_display")) return S.establishes_formatting_context_from_display(self.inner);
            return self.get(.display) == .flow_root;
        }
        pub inline fn is_containing_block(self: Self) style.ContainingBlockClaims {
            if (comptime override("is_containing_block")) return S.is_containing_block(self.inner);
            return .{ .absolute = self.get(.position).is_positioned(), .fixed = false };
        }
        pub inline fn is_table(self: Self) bool {
            if (comptime override("is_table")) return S.is_table(self.inner);
            return self.get(.item_is_table);
        }
        pub inline fn is_replaced(self: Self) bool {
            if (comptime override("is_replaced")) return S.is_replaced(self.inner);
            return self.get(.item_is_replaced);
        }
        pub inline fn is_compressible_replaced(self: Self) bool {
            if (comptime override("is_compressible_replaced")) return S.is_compressible_replaced(self.inner);
            return self.get(.item_is_replaced) or self.get(.item_is_compressible_replaced);
        }
        pub inline fn grid_template_area_row_count(self: Self) u16 {
            return if (self.get(.grid_template_areas)) |areas| areas.row_count else 0;
        }
        pub inline fn grid_template_area_column_count(self: Self) u16 {
            return if (self.get(.grid_template_areas)) |areas| areas.column_count else 0;
        }
    };
}
