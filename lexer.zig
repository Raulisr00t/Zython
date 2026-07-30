const std = @import("std");
const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const TokenValue = token.TokenValue;

pub const LexError = error{
    UnterminatedString,
    UnindentMismatch,
    UnexpectedCharacter,
    NumberLiteralOutOfRange,
};

const MultiOp = struct { text: []const u8, type: TokenType };
const multi_ops = [_]MultiOp{
    .{ .text = "//", .type = .doubleslash },
    .{ .text = "==", .type = .eqeq },
    .{ .text = "!=", .type = .noteq },
    .{ .text = "<=", .type = .le },
    .{ .text = ">=", .type = .ge },
    .{ .text = "+=", .type = .plus_eq },
    .{ .text = "-=", .type = .minus_eq },
    .{ .text = "*=", .type = .star_eq },
    .{ .text = "/=", .type = .slash_eq },
};

fn simpleOp(ch: u8) ?TokenType {
    return switch (ch) {
        '+' => .plus,
        '-' => .minus,
        '*' => .star,
        '%' => .percent,
        '(' => .lparen,
        ')' => .rparen,
        '[' => .lbracket,
        ']' => .rbracket,
        '{' => .lbrace,
        '}' => .rbrace,
        ':' => .colon,
        ',' => .comma,
        '.' => .dot,
        else => null,
    };
}

fn singleFallbackOp(ch: u8) ?TokenType {
    return switch (ch) {
        '/' => .slash,
        '=' => .eq,
        '<' => .lt,
        '>' => .gt,
        else => null,
    };
}

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8, // owned, normalized (\r\n and \r -> \n, trailing \n guaranteed)
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,
    indent_stack: std.ArrayList(usize) = .empty,
    paren_depth: usize = 0,
    at_line_start: bool = true,
    tokens: std.ArrayList(Token) = .empty,
    diag: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Lexer {
        var normalized: std.ArrayList(u8) = .empty;
        errdefer normalized.deinit(allocator);
        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            if (c == '\r') {
                try normalized.append(allocator, '\n');
                if (i + 1 < source.len and source[i + 1] == '\n') i += 1;
            } else {
                try normalized.append(allocator, c);
            }
        }
        if (normalized.items.len == 0 or normalized.items[normalized.items.len - 1] != '\n') {
            try normalized.append(allocator, '\n');
        }

        var lexer = Lexer{
            .allocator = allocator,
            .source = try normalized.toOwnedSlice(allocator),
        };
        try lexer.indent_stack.append(allocator, 0);
        return lexer;
    }

    pub fn deinit(self: *Lexer) void {
        self.allocator.free(self.source);
        self.indent_stack.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
        if (self.diag.len != 0) self.allocator.free(self.diag);
    }

    // -- low level cursor helpers -----------------------------------------
    fn peek(self: *Lexer, offset: usize) u8 {
        const i = self.pos + offset;
        if (i >= self.source.len) return 0;
        return self.source[i];
    }

    fn advance(self: *Lexer) u8 {
        const ch = self.source[self.pos];
        self.pos += 1;
        if (ch == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return ch;
    }

    fn emit(self: *Lexer, typ: TokenType, value: TokenValue, line: usize, col: usize) !void {
        try self.tokens.append(self.allocator, .{ .type = typ, .value = value, .line = line, .col = col });
    }

    fn fail(self: *Lexer, comptime fmt: []const u8, args: anytype, err: LexError) LexError {
        self.diag = std.fmt.allocPrint(self.allocator, fmt, args) catch "";
        return err;
    }

    // -- main entry point ----------------------------------------------
    /// Returns a slice owned by `allocator` (the same one passed to init) --
    /// the caller is responsible for freeing it, same as `lexer.deinit()`
    /// is separately responsible for the lexer's other internal buffers.
    pub fn tokenize(self: *Lexer) ![]Token {
        while (self.pos < self.source.len) {
            if (self.at_line_start and self.paren_depth == 0) {
                if (!try self.handleIndentation()) continue;
            }
            self.skipIntraLineWhitespace();
            const ch = self.peek(0);
            if (self.pos >= self.source.len) break;
            if (ch == '#') {
                self.skipComment();
                continue;
            }
            if (ch == '\n') {
                const line = self.line;
                _ = self.advance();
                if (self.paren_depth == 0) {
                    try self.emit(.newline, .{ .none = {} }, line, self.col);
                    self.at_line_start = true;
                }
                continue;
            }
            if (std.ascii.isDigit(ch)) {
                try self.readNumber();
                continue;
            }
            if (ch == '"' or ch == '\'') {
                try self.readString();
                continue;
            }
            if (std.ascii.isAlphabetic(ch) or ch == '_') {
                try self.readName();
                continue;
            }
            try self.readOperator();
        }

        const line = self.line;
        const col = self.col;
        while (self.indent_stack.items.len > 1) {
            _ = self.indent_stack.pop();
            try self.emit(.dedent, .{ .none = {} }, line, col);
        }
        try self.emit(.endmarker, .{ .none = {} }, line, col);
        return self.tokens.toOwnedSlice(self.allocator);
    }

    // -- indentation handling --------------------------------------------
    /// At the start of a logical line: measure indentation, emit
    /// INDENT/DEDENT as needed. Returns false if the line was blank or a
    /// comment-only line (caller should loop and try the next line).
    fn handleIndentation(self: *Lexer) !bool {
        var indent: usize = 0;
        while (self.peek(0) == ' ' or self.peek(0) == '\t') {
            indent += if (self.peek(0) == ' ') @as(usize, 1) else 8; // tabs treated as width-8
            _ = self.advance();
        }

        const nxt = self.peek(0);
        if (nxt == '\n' or nxt == '#' or self.pos >= self.source.len) {
            if (nxt == '#') self.skipComment();
            if (self.peek(0) == '\n') _ = self.advance();
            return false;
        }

        self.at_line_start = false;
        const current = self.indent_stack.items[self.indent_stack.items.len - 1];
        if (indent > current) {
            try self.indent_stack.append(self.allocator, indent);
            try self.emit(.indent, .{ .int = @intCast(indent) }, self.line, 1);
        } else {
            while (indent < self.indent_stack.items[self.indent_stack.items.len - 1]) {
                _ = self.indent_stack.pop();
                try self.emit(.dedent, .{ .none = {} }, self.line, 1);
            }
            if (indent != self.indent_stack.items[self.indent_stack.items.len - 1]) {
                return self.fail(
                    "Unindent does not match any outer indentation level (line {d})",
                    .{self.line},
                    LexError.UnindentMismatch,
                );
            }
        }
        return true;
    }

    fn skipIntraLineWhitespace(self: *Lexer) void {
        while (self.peek(0) == ' ' or self.peek(0) == '\t') _ = self.advance();
    }

    fn skipComment(self: *Lexer) void {
        while (self.peek(0) != '\n' and self.pos < self.source.len) _ = self.advance();
    }

    // -- token readers ----------------------------------------------------
    fn readNumber(self: *Lexer) !void {
        const line = self.line;
        const col = self.col;
        const start = self.pos;
        var is_float = false;
        while (std.ascii.isDigit(self.peek(0))) _ = self.advance();
        if (self.peek(0) == '.' and std.ascii.isDigit(self.peek(1))) {
            is_float = true;
            _ = self.advance();
            while (std.ascii.isDigit(self.peek(0))) _ = self.advance();
        }
        const text = self.source[start..self.pos];
        if (is_float) {
            // The grammar (digits, optional '.', digits) guarantees this parses;
            // only a truly pathological input could fail here.
            const value = std.fmt.parseFloat(f64, text) catch {
                return self.fail("Invalid number literal '{s}' (line {d})", .{ text, line }, LexError.NumberLiteralOutOfRange);
            };
            try self.emit(.number, .{ .float = value }, line, col);
        } else {
            // Unlike Python's arbitrary-precision ints, i64 can overflow on a
            // long-enough digit run -- report it instead of crashing.
            const value = std.fmt.parseInt(i64, text, 10) catch {
                return self.fail("Number literal '{s}' out of range (line {d})", .{ text, line }, LexError.NumberLiteralOutOfRange);
            };
            try self.emit(.number, .{ .int = value }, line, col);
        }
    }

    fn readString(self: *Lexer) !void {
        const line = self.line;
        const col = self.col;
        const quote = self.advance();
        var chars: std.ArrayList(u8) = .empty;
        defer chars.deinit(self.allocator);
        while (true) {
            const ch = self.peek(0);
            if (self.pos >= self.source.len) {
                return self.fail("Unterminated string literal (line {d})", .{line}, LexError.UnterminatedString);
            }
            if (ch == quote) {
                _ = self.advance();
                break;
            }
            if (ch == '\\') {
                _ = self.advance();
                const esc = self.advance();
                const decoded: u8 = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    '\\' => '\\',
                    '\'' => '\'',
                    '"' => '"',
                    else => esc,
                };
                try chars.append(self.allocator, decoded);
                continue;
            }
            try chars.append(self.allocator, self.advance());
        }
        const text = try chars.toOwnedSlice(self.allocator);
        try self.emit(.string, .{ .text = text }, line, col);
    }

    fn readName(self: *Lexer) !void {
        const line = self.line;
        const col = self.col;
        const start = self.pos;
        while (std.ascii.isAlphanumeric(self.peek(0)) or self.peek(0) == '_') _ = self.advance();
        const text = self.source[start..self.pos];
        if (token.keywords.get(text)) |kw| {
            try self.emit(kw, .{ .text = text }, line, col);
        } else {
            try self.emit(.name, .{ .text = text }, line, col);
        }
    }

    fn readOperator(self: *Lexer) !void {
        const line = self.line;
        const col = self.col;
        const a = self.peek(0);
        const b = self.peek(1);
        for (multi_ops) |op| {
            if (op.text.len == 2 and op.text[0] == a and op.text[1] == b) {
                _ = self.advance();
                _ = self.advance();
                try self.emit(op.type, .{ .text = op.text }, line, col);
                return;
            }
        }
        const ch = self.advance();
        if (ch == '(' or ch == '[' or ch == '{') {
            self.paren_depth += 1;
        } else if (ch == ')' or ch == ']' or ch == '}') {
            self.paren_depth -|= 1; // saturating: never go below 0
        }
        if (simpleOp(ch)) |typ| {
            try self.emit(typ, .{ .text = self.source[self.pos - 1 .. self.pos] }, line, col);
        } else if (singleFallbackOp(ch)) |typ| {
            try self.emit(typ, .{ .text = self.source[self.pos - 1 .. self.pos] }, line, col);
        } else {
            return self.fail("Unexpected character '{c}' (line {d})", .{ ch, line }, LexError.UnexpectedCharacter);
        }
    }
};

// -- tests --------------------------------------------------------------

fn tokenizeForTest(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var lexer = try Lexer.init(allocator, source);
    defer lexer.deinit();
    return lexer.tokenize();
}

test "simple assignment" {
    const allocator = std.testing.allocator;
    const tokens = try tokenizeForTest(allocator, "x = 1\n");
    defer allocator.free(tokens);

    const expected = [_]TokenType{ .name, .eq, .number, .newline, .endmarker };
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, 0..) |t, i| try std.testing.expectEqual(t, tokens[i].type);
}

test "numbers int and float" {
    const allocator = std.testing.allocator;
    const tokens = try tokenizeForTest(allocator, "1 + 2.5\n");
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(i64, 1), tokens[0].value.int);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), tokens[2].value.float, 0.0001);
}

test "string with escapes" {
    const allocator = std.testing.allocator;
    const tokens = try tokenizeForTest(allocator, "\"hi\\n\"\n");
    defer allocator.free(tokens);
    defer allocator.free(tokens[0].value.text);

    try std.testing.expectEqual(TokenType.string, tokens[0].type);
    try std.testing.expectEqualStrings("hi\n", tokens[0].value.text);
}

test "keywords recognized" {
    const allocator = std.testing.allocator;
    const tokens = try tokenizeForTest(allocator, "if True and not False:\n    x = 1\n");
    defer allocator.free(tokens);

    var saw = [_]bool{false} ** 4;
    for (tokens) |t| {
        if (t.type == .kw_if) saw[0] = true;
        if (t.type == .kw_true) saw[1] = true;
        if (t.type == .kw_and) saw[2] = true;
        if (t.type == .kw_not) saw[3] = true;
    }
    for (saw) |s| try std.testing.expect(s);
}

test "indent and dedent" {
    const allocator = std.testing.allocator;
    const tokens = try tokenizeForTest(allocator, "if True:\n    x = 1\ny = 2\n");
    defer allocator.free(tokens);

    var saw_indent = false;
    var saw_dedent = false;
    for (tokens) |t| {
        if (t.type == .indent) saw_indent = true;
        if (t.type == .dedent) saw_dedent = true;
    }
    try std.testing.expect(saw_indent);
    try std.testing.expect(saw_dedent);
}

test "comments and blank lines ignored" {
    const allocator = std.testing.allocator;
    const tokens = try tokenizeForTest(allocator, "# a comment\n\nx = 1  # trailing\n");
    defer allocator.free(tokens);

    const expected = [_]TokenType{ .name, .eq, .number, .newline, .endmarker };
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, 0..) |t, i| try std.testing.expectEqual(t, tokens[i].type);
}

test "multi-char operators" {
    const allocator = std.testing.allocator;
    const tokens = try tokenizeForTest(allocator, "a == b != c <= d >= e // f\n");
    defer allocator.free(tokens);

    var saw = [_]bool{false} ** 5;
    for (tokens) |t| {
        if (t.type == .eqeq) saw[0] = true;
        if (t.type == .noteq) saw[1] = true;
        if (t.type == .le) saw[2] = true;
        if (t.type == .ge) saw[3] = true;
        if (t.type == .doubleslash) saw[4] = true;
    }
    for (saw) |s| try std.testing.expect(s);
}

test "unterminated string reports diag" {
    const allocator = std.testing.allocator;
    var lexer = try Lexer.init(allocator, "\"unterminated\n");
    defer lexer.deinit();
    const result = lexer.tokenize();
    try std.testing.expectError(LexError.UnterminatedString, result);
    try std.testing.expect(lexer.diag.len > 0);
}

test "bracket depth suppresses newline tokens" {
    const allocator = std.testing.allocator;
    const tokens = try tokenizeForTest(allocator, "x = [1,\n2,\n3]\n");
    defer allocator.free(tokens);

    var newline_count: usize = 0;
    for (tokens) |t| {
        if (t.type == .newline) newline_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), newline_count);
}
