//! Recursive-descent parser: token list -> AST (ast.zig). Ports
//! pyinterp/parser.py's precedence-climbing expression parser for the same
//! initial subset (see ast.zig for what's in/out of scope right now).
//!
//! Grammar (subset, precedence low -> high):
//!
//!     module      := stmt* ENDMARKER
//!     stmt        := funcdef | if_stmt | while_stmt | for_stmt
//!                  | (return_stmt | assign_stmt | expr_stmt) NEWLINE
//!     block       := NEWLINE INDENT stmt+ DEDENT
//!
//!     funcdef     := 'def' NAME '(' [NAME (',' NAME)*] ')' ':' block
//!     if_stmt     := 'if' expr ':' block ('elif' expr ':' block)* ['else' ':' block]
//!     while_stmt  := 'while' expr ':' block
//!     for_stmt    := 'for' NAME 'in' expr ':' block
//!     return_stmt := 'return' [expr]
//!     assign_stmt := (NAME | postfix '[' expr ']') ('=' | '+=' | '-=' | '*=' | '/=') expr
//!     expr_stmt   := expr
//!
//!     expr        := or_test
//!     or_test     := and_test ('or' and_test)*
//!     and_test    := not_test ('and' not_test)*
//!     not_test    := 'not' not_test | comparison
//!     comparison  := arith (('==' | '!=' | '<' | '>' | '<=' | '>=') arith)?
//!     arith       := term (('+' | '-') term)*
//!     term        := factor (('*' | '/' | '//' | '%') factor)*
//!     factor      := '-' factor | postfix
//!     postfix     := atom ('(' [expr (',' expr)*] ')' | '[' expr ']')*
//!     atom        := NUMBER | STRING | 'True' | 'False' | 'None' | NAME | '(' expr ')'
//!                  | '[' [expr (',' expr)*] ']'

const std = @import("std");
const token_mod = @import("token.zig");
const Token = token_mod.Token;
const TokenType = token_mod.TokenType;
const ast = @import("ast.zig");

pub const ParseError = error{
    UnexpectedToken,
    InvalidAssignTarget,
};

fn augAssignOp(t: TokenType) ?ast.BinOpKind {
    return switch (t) {
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        else => null,
    };
}

fn compareOp(t: TokenType) ?ast.CompareOpKind {
    return switch (t) {
        .eqeq => .eq,
        .noteq => .ne,
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .ge => .ge,
        else => null,
    };
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    pos: usize = 0,
    diag: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) Parser {
        return .{ .allocator = allocator, .tokens = tokens };
    }

    // -- token stream helpers ---------------------------------------------
    fn peek(self: *Parser, offset: usize) Token {
        const i = @min(self.pos + offset, self.tokens.len - 1);
        return self.tokens[i];
    }

    fn at(self: *Parser, t: TokenType) bool {
        return self.peek(0).type == t;
    }

    fn atAny(self: *Parser, types: []const TokenType) bool {
        const cur = self.peek(0).type;
        for (types) |t| if (cur == t) return true;
        return false;
    }

    fn advance(self: *Parser) Token {
        const tok = self.tokens[self.pos];
        if (self.pos < self.tokens.len - 1) self.pos += 1;
        return tok;
    }

    fn expect(self: *Parser, t: TokenType) !Token {
        const tok = self.peek(0);
        if (tok.type != t) {
            return self.fail(
                "Expected {s} but got {s} at line {d}",
                .{ @tagName(t), @tagName(tok.type), tok.line },
                ParseError.UnexpectedToken,
            );
        }
        return self.advance();
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype, err: ParseError) ParseError {
        self.diag = std.fmt.allocPrint(self.allocator, fmt, args) catch "";
        return err;
    }

    fn newNode(self: *Parser, node: ast.Node) !*ast.Node {
        const ptr = try self.allocator.create(ast.Node);
        ptr.* = node;
        return ptr;
    }

    // -- entry point --------------------------------------------------
    pub fn parseModule(self: *Parser) !*ast.Node {
        var body: std.ArrayList(*ast.Node) = .empty;
        while (!self.at(.endmarker)) {
            try body.append(self.allocator, try self.parseStmt());
        }
        return self.newNode(.{ .module = .{ .body = try body.toOwnedSlice(self.allocator) } });
    }

    // -- statements ---------------------------------------------------
    fn parseBlock(self: *Parser) ![]const *ast.Node {
        _ = try self.expect(.newline);
        _ = try self.expect(.indent);
        var stmts: std.ArrayList(*ast.Node) = .empty;
        while (!self.at(.dedent)) {
            try stmts.append(self.allocator, try self.parseStmt());
        }
        _ = try self.expect(.dedent);
        return stmts.toOwnedSlice(self.allocator);
    }

    fn parseStmt(self: *Parser) anyerror!*ast.Node {
        if (self.at(.kw_def)) return self.parseFuncDef();
        if (self.at(.kw_if)) return self.parseIf();
        if (self.at(.kw_while)) return self.parseWhile();
        if (self.at(.kw_for)) return self.parseFor();

        if (self.at(.kw_return)) {
            _ = self.advance();
            var value: ?*ast.Node = null;
            if (!self.at(.newline)) value = try self.parseExpr();
            _ = try self.expect(.newline);
            return self.newNode(.{ .return_stmt = .{ .value = value } });
        }

        const expr = try self.parseExpr();
        if (self.at(.eq)) {
            _ = self.advance();
            try self.validateAssignTarget(expr);
            const value = try self.parseExpr();
            _ = try self.expect(.newline);
            return self.newNode(.{ .assign = .{ .target = expr, .value = value } });
        }
        if (augAssignOp(self.peek(0).type)) |op| {
            _ = self.advance();
            try self.validateAssignTarget(expr);
            const value = try self.parseExpr();
            _ = try self.expect(.newline);
            return self.newNode(.{ .aug_assign = .{ .target = expr, .op = op, .value = value } });
        }
        _ = try self.expect(.newline);
        return self.newNode(.{ .expr_stmt = .{ .value = expr } });
    }

    fn validateAssignTarget(self: *Parser, node: *ast.Node) !void {
        if (node.* != .name and node.* != .subscript) {
            return self.fail("Cannot assign to this expression", .{}, ParseError.InvalidAssignTarget);
        }
    }

    fn parseFor(self: *Parser) !*ast.Node {
        _ = try self.expect(.kw_for);
        const target = (try self.expect(.name)).value.text;
        _ = try self.expect(.kw_in);
        const iter = try self.parseExpr();
        _ = try self.expect(.colon);
        const body = try self.parseBlock();
        return self.newNode(.{ .for_stmt = .{ .target = target, .iter = iter, .body = body } });
    }

    fn parseFuncDef(self: *Parser) !*ast.Node {
        _ = try self.expect(.kw_def);
        const name = (try self.expect(.name)).value.text;
        _ = try self.expect(.lparen);
        var params: std.ArrayList([]const u8) = .empty;
        if (!self.at(.rparen)) {
            try params.append(self.allocator, (try self.expect(.name)).value.text);
            while (self.at(.comma)) {
                _ = self.advance();
                try params.append(self.allocator, (try self.expect(.name)).value.text);
            }
        }
        _ = try self.expect(.rparen);
        _ = try self.expect(.colon);
        const body = try self.parseBlock();
        return self.newNode(.{ .function_def = .{
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .body = body,
        } });
    }

    fn parseIf(self: *Parser) anyerror!*ast.Node {
        _ = try self.expect(.kw_if);
        return self.parseIfBody();
    }

    fn parseElif(self: *Parser) anyerror!*ast.Node {
        _ = try self.expect(.kw_elif);
        return self.parseIfBody();
    }

    /// Shared by `if` and `elif` -- only the leading keyword differs.
    /// `elif` chains desugar into nested `If`s in `orelse_body`, same as
    /// Phase 1 (see pyinterp/parser.py's `_parse_if`/`_parse_elif`).
    fn parseIfBody(self: *Parser) !*ast.Node {
        const cond = try self.parseExpr();
        _ = try self.expect(.colon);
        const body = try self.parseBlock();

        var orelse_body: []const *ast.Node = &.{};
        if (self.at(.kw_elif)) {
            var arr: std.ArrayList(*ast.Node) = .empty;
            try arr.append(self.allocator, try self.parseElif());
            orelse_body = try arr.toOwnedSlice(self.allocator);
        } else if (self.at(.kw_else)) {
            _ = self.advance();
            _ = try self.expect(.colon);
            orelse_body = try self.parseBlock();
        }
        return self.newNode(.{ .if_stmt = .{ .cond = cond, .body = body, .orelse_body = orelse_body } });
    }

    fn parseWhile(self: *Parser) !*ast.Node {
        _ = try self.expect(.kw_while);
        const cond = try self.parseExpr();
        _ = try self.expect(.colon);
        const body = try self.parseBlock();
        return self.newNode(.{ .while_stmt = .{ .cond = cond, .body = body } });
    }

    // -- expressions (precedence climbing) -----------------------------
    fn parseExpr(self: *Parser) anyerror!*ast.Node {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) anyerror!*ast.Node {
        var left = try self.parseAnd();
        if (self.at(.kw_or)) {
            var values: std.ArrayList(*ast.Node) = .empty;
            try values.append(self.allocator, left);
            while (self.at(.kw_or)) {
                _ = self.advance();
                try values.append(self.allocator, try self.parseAnd());
            }
            left = try self.newNode(.{ .bool_op = .{ .op = .or_, .values = try values.toOwnedSlice(self.allocator) } });
        }
        return left;
    }

    fn parseAnd(self: *Parser) anyerror!*ast.Node {
        var left = try self.parseNot();
        if (self.at(.kw_and)) {
            var values: std.ArrayList(*ast.Node) = .empty;
            try values.append(self.allocator, left);
            while (self.at(.kw_and)) {
                _ = self.advance();
                try values.append(self.allocator, try self.parseNot());
            }
            left = try self.newNode(.{ .bool_op = .{ .op = .and_, .values = try values.toOwnedSlice(self.allocator) } });
        }
        return left;
    }

    fn parseNot(self: *Parser) anyerror!*ast.Node {
        if (self.at(.kw_not)) {
            _ = self.advance();
            const operand = try self.parseNot();
            return self.newNode(.{ .unary_op = .{ .op = .not_, .operand = operand } });
        }
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) anyerror!*ast.Node {
        const left = try self.parseArith();
        if (compareOp(self.peek(0).type)) |op| {
            _ = self.advance();
            const right = try self.parseArith();
            return self.newNode(.{ .compare = .{ .left = left, .op = op, .right = right } });
        }
        return left;
    }

    fn parseArith(self: *Parser) anyerror!*ast.Node {
        var left = try self.parseTerm();
        while (self.at(.plus) or self.at(.minus)) {
            const op: ast.BinOpKind = if (self.at(.plus)) .add else .sub;
            _ = self.advance();
            const right = try self.parseTerm();
            left = try self.newNode(.{ .bin_op = .{ .left = left, .op = op, .right = right } });
        }
        return left;
    }

    fn parseTerm(self: *Parser) anyerror!*ast.Node {
        var left = try self.parseFactor();
        while (self.atAny(&.{ .star, .slash, .doubleslash, .percent })) {
            const t = self.advance().type;
            const op: ast.BinOpKind = switch (t) {
                .star => .mul,
                .slash => .div,
                .doubleslash => .floordiv,
                .percent => .mod,
                else => unreachable,
            };
            const right = try self.parseFactor();
            left = try self.newNode(.{ .bin_op = .{ .left = left, .op = op, .right = right } });
        }
        return left;
    }

    fn parseFactor(self: *Parser) anyerror!*ast.Node {
        if (self.at(.minus)) {
            _ = self.advance();
            const operand = try self.parseFactor();
            return self.newNode(.{ .unary_op = .{ .op = .neg, .operand = operand } });
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) anyerror!*ast.Node {
        var node = try self.parseAtom();
        while (true) {
            if (self.at(.lparen)) {
                _ = self.advance();
                var args: std.ArrayList(*ast.Node) = .empty;
                if (!self.at(.rparen)) {
                    try args.append(self.allocator, try self.parseExpr());
                    while (self.at(.comma)) {
                        _ = self.advance();
                        try args.append(self.allocator, try self.parseExpr());
                    }
                }
                _ = try self.expect(.rparen);
                node = try self.newNode(.{ .call = .{ .func = node, .args = try args.toOwnedSlice(self.allocator) } });
            } else if (self.at(.lbracket)) {
                _ = self.advance();
                const index = try self.parseExpr();
                _ = try self.expect(.rbracket);
                node = try self.newNode(.{ .subscript = .{ .obj = node, .index = index } });
            } else {
                break;
            }
        }
        return node;
    }

    fn parseAtom(self: *Parser) anyerror!*ast.Node {
        const tok = self.peek(0);
        switch (tok.type) {
            .number => {
                _ = self.advance();
                return switch (tok.value) {
                    .int => |v| self.newNode(.{ .num_int = v }),
                    .float => |v| self.newNode(.{ .num_float = v }),
                    else => unreachable,
                };
            },
            .string => {
                _ = self.advance();
                return self.newNode(.{ .str = tok.value.text });
            },
            .kw_true => {
                _ = self.advance();
                return self.newNode(.{ .bool_lit = true });
            },
            .kw_false => {
                _ = self.advance();
                return self.newNode(.{ .bool_lit = false });
            },
            .kw_none => {
                _ = self.advance();
                return self.newNode(.{ .none_lit = {} });
            },
            .name => {
                _ = self.advance();
                return self.newNode(.{ .name = tok.value.text });
            },
            .lparen => {
                _ = self.advance();
                const node = try self.parseExpr();
                _ = try self.expect(.rparen);
                return node;
            },
            .lbracket => {
                _ = self.advance();
                var elements: std.ArrayList(*ast.Node) = .empty;
                if (!self.at(.rbracket)) {
                    try elements.append(self.allocator, try self.parseExpr());
                    while (self.at(.comma)) {
                        _ = self.advance();
                        if (self.at(.rbracket)) break; // trailing comma
                        try elements.append(self.allocator, try self.parseExpr());
                    }
                }
                _ = try self.expect(.rbracket);
                return self.newNode(.{ .list_lit = .{ .elements = try elements.toOwnedSlice(self.allocator) } });
            },
            else => return self.fail(
                "Unexpected token {s} at line {d}",
                .{ @tagName(tok.type), tok.line },
                ParseError.UnexpectedToken,
            ),
        }
    }
};

// -- tests --------------------------------------------------------------

const lexer_mod = @import("lexer.zig");

fn parseSource(allocator: std.mem.Allocator, source: []const u8) !*ast.Node {
    var lex = try lexer_mod.Lexer.init(allocator, source);
    const tokens = try lex.tokenize();
    var parser = Parser.init(allocator, tokens);
    return parser.parseModule();
}

test "assignment and expr stmt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try parseSource(a, "x = 1 + 2\nprint(x)\n");
    const body = module.module.body;
    try std.testing.expectEqual(@as(usize, 2), body.len);

    try std.testing.expect(body[0].* == .assign);
    try std.testing.expectEqualStrings("x", body[0].assign.target.name);
    try std.testing.expect(body[0].assign.value.* == .bin_op);

    try std.testing.expect(body[1].* == .expr_stmt);
    const call = body[1].expr_stmt.value;
    try std.testing.expect(call.* == .call);
    try std.testing.expectEqualStrings("print", call.call.func.name);
}

test "if elif else desugars to nested if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try parseSource(a, "if a:\n    x = 1\nelif b:\n    x = 2\nelse:\n    x = 3\n");
    const top = module.module.body[0];
    try std.testing.expect(top.* == .if_stmt);
    try std.testing.expectEqual(@as(usize, 1), top.if_stmt.orelse_body.len);

    const nested = top.if_stmt.orelse_body[0];
    try std.testing.expect(nested.* == .if_stmt);
    try std.testing.expectEqual(@as(usize, 1), nested.if_stmt.orelse_body.len);
    try std.testing.expect(nested.if_stmt.orelse_body[0].* == .assign);
}

test "while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try parseSource(a, "while x < 10:\n    x = x + 1\n");
    const node = module.module.body[0];
    try std.testing.expect(node.* == .while_stmt);
    try std.testing.expect(node.while_stmt.cond.* == .compare);
    try std.testing.expectEqual(ast.CompareOpKind.lt, node.while_stmt.cond.compare.op);
}

test "function def and return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try parseSource(a, "def add(a, b):\n    return a + b\n");
    const fn_node = module.module.body[0];
    try std.testing.expect(fn_node.* == .function_def);
    try std.testing.expectEqualStrings("add", fn_node.function_def.name);
    try std.testing.expectEqual(@as(usize, 2), fn_node.function_def.params.len);

    const ret = fn_node.function_def.body[0];
    try std.testing.expect(ret.* == .return_stmt);
    try std.testing.expect(ret.return_stmt.value.?.* == .bin_op);
}

test "operator precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try parseSource(a, "x = 1 + 2 * 3\n");
    const value = module.module.body[0].assign.value;
    try std.testing.expectEqual(ast.BinOpKind.add, value.bin_op.op);
    try std.testing.expect(value.bin_op.right.* == .bin_op);
    try std.testing.expectEqual(ast.BinOpKind.mul, value.bin_op.right.bin_op.op);
}

test "boolop and or not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try parseSource(a, "x = a and not b or c\n");
    const value = module.module.body[0].assign.value;
    try std.testing.expect(value.* == .bool_op);
    try std.testing.expectEqual(ast.BoolOpKind.or_, value.bool_op.op);
}

test "augassign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try parseSource(a, "x += 1\n");
    const node = module.module.body[0];
    try std.testing.expect(node.* == .aug_assign);
    try std.testing.expectEqualStrings("x", node.aug_assign.target.name);
    try std.testing.expectEqual(ast.BinOpKind.add, node.aug_assign.op);
}

test "invalid assignment target raises" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = parseSource(a, "1 + 2 = 3\n");
    try std.testing.expectError(ParseError.InvalidAssignTarget, result);
}

test "list literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try parseSource(a, "xs = [1, 2, 3]\n");
    const value = module.module.body[0].assign.value;
    try std.testing.expect(value.* == .list_lit);
    try std.testing.expectEqual(@as(usize, 3), value.list_lit.elements.len);
    try std.testing.expectEqual(@as(i64, 2), value.list_lit.elements[1].num_int);
}

test "subscript load and store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try parseSource(a, "a = xs[0]\nxs[1] = 5\n");
    const load = module.module.body[0].assign.value;
    try std.testing.expect(load.* == .subscript);
    try std.testing.expectEqualStrings("xs", load.subscript.obj.name);
    try std.testing.expectEqual(@as(i64, 0), load.subscript.index.num_int);

    const store = module.module.body[1];
    try std.testing.expect(store.* == .assign);
    try std.testing.expect(store.assign.target.* == .subscript);
}

test "for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try parseSource(a, "for x in xs:\n    print(x)\n");
    const node = module.module.body[0];
    try std.testing.expect(node.* == .for_stmt);
    try std.testing.expectEqualStrings("x", node.for_stmt.target);
    try std.testing.expectEqualStrings("xs", node.for_stmt.iter.name);
}
