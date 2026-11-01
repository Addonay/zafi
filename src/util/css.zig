//! A small CSS tokenizer and parser: the subset of Rust's `cssparser` that
//! Taffy's `FromCss` implementations use, with the same semantics, so zafi's
//! `from_str` parsers can be line-for-line ports of Taffy's.
//!
//! - `Parser.next` skips whitespace and comments. A block-opening token
//!   (`fn(`, `(`, `[`, `{`) not entered with `parse_nested_block` is skipped
//!   whole by the following `next`.
//! - `parse_nested_block` parses a block's contents, which must be consumed
//!   entirely. Blocks left open at the end of the input are closed implicitly.
//! - Numbers follow cssparser's arithmetic exactly (f64, then f32), including
//!   `int_value` (integers only: no fraction or exponent; saturated to i32) and
//!   percentages as `unit_value` (value / 100).
//! - Names are borrowed from the input; escapes (`\`) are not decoded and
//!   tokenize as a delimiter.
//!
//! Nothing here allocates.

const std = @import("std");

pub const Error = error{InvalidCss};

pub const BlockKind = enum { paren, square, curly };

pub const Token = union(enum) {
    ident: []const u8,
    function: []const u8,
    at_keyword: []const u8,
    hash: []const u8,
    string: []const u8,
    number: Numeric,
    percentage: Percentage,
    dimension: Dimension,
    open: BlockKind,
    close: BlockKind,
    comma,
    colon,
    semicolon,
    delim: u8,

    pub const Numeric = struct { value: f32, int_value: ?i32 };
    pub const Percentage = struct { unit_value: f32, int_value: ?i32 };
    pub const Dimension = struct { value: f32, int_value: ?i32, unit: []const u8 };

    fn opensBlock(self: Token) ?BlockKind {
        return switch (self) {
            .function => .paren,
            .open => |kind| kind,
            else => null,
        };
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}
fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}
fn isNameChar(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c) or c == '-';
}

const Tokenizer = struct {
    input: []const u8,
    pos: usize,

    fn at(self: Tokenizer, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.input.len) self.input[i] else null;
    }

    /// Skip whitespace and comments.
    fn skipTrivia(self: *Tokenizer) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (isWhitespace(c)) {
                self.pos += 1;
            } else if (c == '/' and self.at(1) == '*') {
                if (std.mem.indexOfPos(u8, self.input, self.pos + 2, "*/")) |end| {
                    self.pos = end + 2;
                } else {
                    self.pos = self.input.len;
                }
            } else break;
        }
    }

    fn startsIdent(self: Tokenizer) bool {
        const c = self.at(0) orelse return false;
        if (isNameStart(c)) return true;
        if (c == '-') {
            const n = self.at(1) orelse return false;
            return isNameStart(n) or n == '-';
        }
        return false;
    }

    fn startsNumber(self: Tokenizer) bool {
        const c = self.at(0) orelse return false;
        if (std.ascii.isDigit(c)) return true;
        if (c == '.') return if (self.at(1)) |n| std.ascii.isDigit(n) else false;
        if (c == '+' or c == '-') {
            const n = self.at(1) orelse return false;
            if (std.ascii.isDigit(n)) return true;
            return n == '.' and if (self.at(2)) |m| std.ascii.isDigit(m) else false;
        }
        return false;
    }

    fn consumeName(self: *Tokenizer) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len and isNameChar(self.input[self.pos])) self.pos += 1;
        return self.input[start..self.pos];
    }

    fn digit(self: Tokenizer) ?u8 {
        const c = self.at(0) orelse return null;
        return if (std.ascii.isDigit(c)) c - '0' else null;
    }

    /// cssparser's `consume_numeric`.
    fn consumeNumeric(self: *Tokenizer) Token {
        var sign: f64 = 1;
        if (self.at(0) == '-' or self.at(0) == '+') {
            if (self.at(0) == '-') sign = -1;
            self.pos += 1;
        }
        var integral: f64 = 0;
        while (self.digit()) |d| : (self.pos += 1) integral = integral * 10 + @as(f64, @floatFromInt(d));
        var is_integer = true;
        var fractional: f64 = 0;
        if (self.at(0) == '.' and if (self.at(1)) |n| std.ascii.isDigit(n) else false) {
            is_integer = false;
            self.pos += 1;
            var factor: f64 = 0.1;
            while (self.digit()) |d| : (self.pos += 1) {
                fractional += @as(f64, @floatFromInt(d)) * factor;
                factor *= 0.1;
            }
        }
        var value = sign * (integral + fractional);
        if ((self.at(0) == 'e' or self.at(0) == 'E') and blk: {
            const n = self.at(1) orelse break :blk false;
            if (std.ascii.isDigit(n)) break :blk true;
            break :blk (n == '+' or n == '-') and if (self.at(2)) |m| std.ascii.isDigit(m) else false;
        }) {
            is_integer = false;
            self.pos += 1;
            var exp_sign: f64 = 1;
            if (self.at(0) == '-' or self.at(0) == '+') {
                if (self.at(0) == '-') exp_sign = -1;
                self.pos += 1;
            }
            var exponent: f64 = 0;
            while (self.digit()) |d| : (self.pos += 1) exponent = exponent * 10 + @as(f64, @floatFromInt(d));
            value *= std.math.pow(f64, 10, exp_sign * exponent);
        }
        const int_value: ?i32 = if (!is_integer) null else if (value >= std.math.maxInt(i32))
            std.math.maxInt(i32)
        else if (value <= std.math.minInt(i32))
            std.math.minInt(i32)
        else
            @intFromFloat(value);

        if (self.at(0) == '%') {
            self.pos += 1;
            return .{ .percentage = .{ .unit_value = @floatCast(value / 100), .int_value = int_value } };
        }
        const value32: f32 = @floatCast(value);
        if (self.startsIdent()) return .{ .dimension = .{ .value = value32, .int_value = int_value, .unit = self.consumeName() } };
        return .{ .number = .{ .value = value32, .int_value = int_value } };
    }

    /// The next token; whitespace and comments must already be skipped.
    fn next(self: *Tokenizer) ?Token {
        const c = self.at(0) orelse return null;
        if (self.startsNumber()) return self.consumeNumeric();
        if (self.startsIdent()) {
            const name = self.consumeName();
            if (self.at(0) == '(') {
                self.pos += 1;
                return .{ .function = name };
            }
            return .{ .ident = name };
        }
        self.pos += 1;
        return switch (c) {
            '(' => .{ .open = .paren },
            '[' => .{ .open = .square },
            '{' => .{ .open = .curly },
            ')' => .{ .close = .paren },
            ']' => .{ .close = .square },
            '}' => .{ .close = .curly },
            ',' => .comma,
            ':' => .colon,
            ';' => .semicolon,
            '@' => if (self.startsIdent()) .{ .at_keyword = self.consumeName() } else .{ .delim = c },
            '#' => if (self.pos < self.input.len and isNameChar(self.input[self.pos])) .{ .hash = self.consumeName() } else .{ .delim = c },
            '"', '\'' => blk: {
                const start = self.pos;
                while (self.pos < self.input.len and self.input[self.pos] != c and self.input[self.pos] != '\n') self.pos += 1;
                const s = self.input[start..self.pos];
                if (self.pos < self.input.len and self.input[self.pos] == c) self.pos += 1;
                break :blk .{ .string = s };
            },
            else => .{ .delim = c },
        };
    }

    /// Skip to just after the close of a `kind` block whose opener was consumed.
    /// Returns the position of the closing character (the content end).
    fn skipBlock(self: *Tokenizer, kind: BlockKind) usize {
        while (true) {
            self.skipTrivia();
            const before = self.pos;
            const token = self.next() orelse return self.input.len;
            switch (token) {
                .close => |k| if (k == kind) return before,
                else => if (token.opensBlock()) |inner| {
                    _ = self.skipBlock(inner);
                },
            }
        }
    }
};

pub const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    /// Set right after `next` returned a block-opening token.
    pending_block: ?BlockKind = null,

    pub const State = struct { pos: usize, pending_block: ?BlockKind };

    pub fn init(input: []const u8) Parser {
        return .{ .input = input };
    }

    pub fn state(self: Parser) State {
        return .{ .pos = self.pos, .pending_block = self.pending_block };
    }
    pub fn reset(self: *Parser, s: State) void {
        self.pos = s.pos;
        self.pending_block = s.pending_block;
    }

    fn tokenizer(self: Parser) Tokenizer {
        return .{ .input = self.input, .pos = self.pos };
    }

    fn skipPending(self: *Parser) void {
        if (self.pending_block) |kind| {
            var t = self.tokenizer();
            _ = t.skipBlock(kind);
            self.pos = t.pos;
            self.pending_block = null;
        }
    }

    pub fn next(self: *Parser) Error!Token {
        self.skipPending();
        var t = self.tokenizer();
        t.skipTrivia();
        const token = t.next() orelse return error.InvalidCss;
        self.pos = t.pos;
        self.pending_block = token.opensBlock();
        return token;
    }

    pub fn is_exhausted(self: *Parser) bool {
        const s = self.state();
        defer self.reset(s);
        self.skipPending();
        var t = self.tokenizer();
        t.skipTrivia();
        return t.pos >= self.input.len;
    }

    pub fn expect_exhausted(self: *Parser) Error!void {
        if (!self.is_exhausted()) return error.InvalidCss;
    }

    /// Parse the contents of the block whose opener `next` just returned.
    /// `parse` receives a parser over the contents and must consume them all.
    pub fn parse_nested_block(self: *Parser, comptime T: type, context: anytype, comptime parse: anytype) !T {
        const kind = self.pending_block orelse return error.InvalidCss;
        self.pending_block = null;
        var t = self.tokenizer();
        const content_end = t.skipBlock(kind);
        var inner = Parser.init(self.input[0..content_end]);
        inner.pos = self.pos;
        self.pos = t.pos;
        return parse_entirely_with(&inner, T, context, parse);
    }

    pub fn expect_ident(self: *Parser) Error![]const u8 {
        return switch (try self.next()) {
            .ident => |name| name,
            else => error.InvalidCss,
        };
    }

    pub fn expect_comma(self: *Parser) Error!void {
        if (try self.next() != .comma) return error.InvalidCss;
    }

    /// A function token named `name` (ASCII case-insensitive, like cssparser).
    pub fn expect_function_matching(self: *Parser, name: []const u8) Error!void {
        switch (try self.next()) {
            .function => |f| if (!std.ascii.eqlIgnoreCase(f, name)) return error.InvalidCss,
            else => return error.InvalidCss,
        }
    }

    pub fn expect_square_bracket_block(self: *Parser) Error!void {
        switch (try self.next()) {
            .open => |kind| if (kind != .square) return error.InvalidCss,
            else => return error.InvalidCss,
        }
    }
};

/// Run `parse(context, parser)` and require that it consumed everything.
pub fn parse_entirely_with(parser: *Parser, comptime T: type, context: anytype, comptime parse: anytype) !T {
    const value = try parse(context, parser);
    try parser.expect_exhausted();
    return value;
}

/// `cssparser`'s `parse_entirely` over a whole string (Taffy's
/// `parse_css_str_entirely`).
pub fn parse_str_entirely(input: []const u8, comptime T: type, context: anytype, comptime parse: anytype) !T {
    var parser = Parser.init(input);
    return parse_entirely_with(&parser, T, context, parse);
}

/// ASCII case-insensitive keyword lookup for keyword enums (Taffy's
/// `impl_parse_for_keyword_enum!`): the input must be exactly one ident.
pub fn keyword_enum(comptime T: type, input: []const u8, comptime table: []const struct { []const u8, T }) Error!T {
    const S = struct {
        fn parse(_: void, p: *Parser) Error!T {
            const ident = try p.expect_ident();
            inline for (table) |entry| {
                if (std.ascii.eqlIgnoreCase(ident, entry[0])) return entry[1];
            }
            return error.InvalidCss;
        }
    };
    return parse_str_entirely(input, T, {}, S.parse);
}

test "numbers follow cssparser's arithmetic" {
    const testing = std.testing;
    var p = Parser.init(" 10px 50% -3 1.5e2 .5 1e2 99999999999 +2 1. ");
    try testing.expectEqualDeep(Token{ .dimension = .{ .value = 10, .int_value = 10, .unit = "px" } }, try p.next());
    try testing.expectEqualDeep(Token{ .percentage = .{ .unit_value = 0.5, .int_value = 50 } }, try p.next());
    try testing.expectEqualDeep(Token{ .number = .{ .value = -3, .int_value = -3 } }, try p.next());
    try testing.expectEqualDeep(Token{ .number = .{ .value = 150, .int_value = null } }, try p.next());
    try testing.expectEqualDeep(Token{ .number = .{ .value = 0.5, .int_value = null } }, try p.next());
    try testing.expectEqualDeep(Token{ .number = .{ .value = 100, .int_value = null } }, try p.next());
    try testing.expectEqualDeep(Token{ .number = .{ .value = @floatCast(@as(f64, 99999999999)), .int_value = std.math.maxInt(i32) } }, try p.next());
    try testing.expectEqualDeep(Token{ .number = .{ .value = 2, .int_value = 2 } }, try p.next());
    try testing.expectEqualDeep(Token{ .number = .{ .value = 1, .int_value = 1 } }, try p.next());
    try testing.expectEqualDeep(Token{ .delim = '.' }, try p.next());
    try testing.expect(p.is_exhausted());
}

test "blocks: skipped when not entered, nested contents must be consumed, implicit close at EOF" {
    const testing = std.testing;
    var p = Parser.init("f(a [b] c) /* x */ g(1");
    try testing.expectEqualDeep(Token{ .function = "f" }, try p.next());
    try testing.expectEqualDeep(Token{ .function = "g" }, try p.next());
    const S = struct {
        fn one(_: void, q: *Parser) Error!f32 {
            return switch (try q.next()) {
                .number => |n| n.value,
                else => error.InvalidCss,
            };
        }
    };
    try testing.expectEqual(@as(f32, 1), try p.parse_nested_block(f32, {}, S.one));
    try testing.expect(p.is_exhausted());

    var q = Parser.init("f(1 2)");
    _ = try q.next();
    try testing.expectError(error.InvalidCss, q.parse_nested_block(f32, {}, S.one));
}
