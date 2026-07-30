const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const Opcode = bytecode.Opcode;
const CodeObject = bytecode.CodeObject;

pub const CompileError = error{
    UnsupportedNode,
    InvalidAssignTarget,
};

fn binOpToOpcode(op: ast.BinOpKind) Opcode {
    return switch (op) {
        .add => .binary_add,
        .sub => .binary_subtract,
        .mul => .binary_multiply,
        .div => .binary_true_divide,
        .floordiv => .binary_floor_divide,
        .mod => .binary_modulo,
    };
}

pub const Compiler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{ .allocator = allocator };
    }

    pub fn compileModule(self: *Compiler, module: *const ast.Node) !*CodeObject {
        const code = try self.allocator.create(CodeObject);
        code.* = .{ .name = "<module>" };
        try self.compileStmts(code, module.module.body);
        const none_idx = try code.addConst(self.allocator, .{ .none = {} });
        _ = try code.emit(self.allocator, .load_const, .{ .index = none_idx });
        _ = try code.emit(self.allocator, .return_value, .{ .none = {} });
        return code;
    }

    fn patchJump(self: *Compiler, code: *CodeObject, idx: usize, target: usize) void {
        _ = self;
        code.instructions.items[idx].arg = .{ .index = target };
    }

    fn compileStmts(self: *Compiler, code: *CodeObject, stmts: []const *ast.Node) anyerror!void {
        for (stmts) |s| try self.compileStmt(code, s);
    }

    fn compileStmt(self: *Compiler, code: *CodeObject, node: *const ast.Node) anyerror!void {
        switch (node.*) {
            .function_def => |f| try self.compileFunctionDef(code, f),
            .return_stmt => |r| try self.compileReturn(code, r),
            .if_stmt => |s| try self.compileIf(code, s),
            .while_stmt => |s| try self.compileWhile(code, s),
            .assign => |s| try self.compileAssign(code, s),
            .aug_assign => |s| try self.compileAugAssign(code, s),
            .for_stmt => |s| try self.compileFor(code, s),
            .expr_stmt => |s| {
                try self.compileExpr(code, s.value);
                _ = try code.emit(self.allocator, .pop_top, .{ .none = {} });
            },
            else => return CompileError.UnsupportedNode,
        }
    }

    fn compileFor(self: *Compiler, code: *CodeObject, s: ast.For) !void {
        try self.compileExpr(code, s.iter);
        _ = try code.emit(self.allocator, .get_iter, .{ .none = {} });
        const loop_start = code.here();
        const for_iter_idx = try code.emit(self.allocator, .for_iter, .{ .none = {} });
        const name_idx = try code.addName(self.allocator, s.target);
        _ = try code.emit(self.allocator, .store_name, .{ .index = name_idx });
        try self.compileStmts(code, s.body);
        _ = try code.emit(self.allocator, .jump_forward, .{ .index = loop_start });
        self.patchJump(code, for_iter_idx, code.here());
    }

    fn compileFunctionDef(self: *Compiler, code: *CodeObject, f: ast.FunctionDef) !void {
        const func_code = try self.allocator.create(CodeObject);
        func_code.* = .{ .name = f.name, .params = f.params };
        try self.compileStmts(func_code, f.body);
        const none_idx = try func_code.addConst(self.allocator, .{ .none = {} });
        _ = try func_code.emit(self.allocator, .load_const, .{ .index = none_idx });
        _ = try func_code.emit(self.allocator, .return_value, .{ .none = {} });

        const pyfunc = try self.allocator.create(bytecode.PyFunction);
        pyfunc.* = .{ .code = func_code };
        const const_idx = try code.addConstNoDedup(self.allocator, .{ .function = pyfunc });
        _ = try code.emit(self.allocator, .make_function, .{ .index = const_idx });
        const name_idx = try code.addName(self.allocator, f.name);
        _ = try code.emit(self.allocator, .store_name, .{ .index = name_idx });
    }

    fn compileReturn(self: *Compiler, code: *CodeObject, r: ast.Return) !void {
        if (r.value) |v| {
            try self.compileExpr(code, v);
        } else {
            const idx = try code.addConst(self.allocator, .{ .none = {} });
            _ = try code.emit(self.allocator, .load_const, .{ .index = idx });
        }
        _ = try code.emit(self.allocator, .return_value, .{ .none = {} });
    }

    fn compileIf(self: *Compiler, code: *CodeObject, s: ast.If) !void {
        try self.compileExpr(code, s.cond);
        const jump_to_else = try code.emit(self.allocator, .pop_jump_if_false, .{ .none = {} });
        try self.compileStmts(code, s.body);
        if (s.orelse_body.len > 0) {
            const jump_to_end = try code.emit(self.allocator, .jump_forward, .{ .none = {} });
            self.patchJump(code, jump_to_else, code.here());
            try self.compileStmts(code, s.orelse_body);
            self.patchJump(code, jump_to_end, code.here());
        } else {
            self.patchJump(code, jump_to_else, code.here());
        }
    }

    fn compileWhile(self: *Compiler, code: *CodeObject, s: ast.While) !void {
        const loop_start = code.here();
        try self.compileExpr(code, s.cond);
        const jump_to_end = try code.emit(self.allocator, .pop_jump_if_false, .{ .none = {} });
        try self.compileStmts(code, s.body);
        _ = try code.emit(self.allocator, .jump_forward, .{ .index = loop_start });
        self.patchJump(code, jump_to_end, code.here());
    }

    fn assignTargetName(node: *const ast.Node) !([]const u8) {
        // AugAssign to a subscript (`xs[i] += 1`) isn't supported yet, same
        // scope cut Phase 1 made -- see pyinterp/compiler.py.
        if (node.* != .name) return CompileError.InvalidAssignTarget;
        return node.name;
    }

    /// Emits STORE_* for `target`, assuming the value to store is already
    /// on top of the stack (mirrors pyinterp/compiler.py's `_compile_store`).
    fn compileStore(self: *Compiler, code: *CodeObject, target: *const ast.Node) anyerror!void {
        switch (target.*) {
            .name => |n| {
                const name_idx = try code.addName(self.allocator, n);
                _ = try code.emit(self.allocator, .store_name, .{ .index = name_idx });
            },
            .subscript => |s| {
                try self.compileExpr(code, s.obj);
                try self.compileExpr(code, s.index);
                _ = try code.emit(self.allocator, .store_subscr, .{ .none = {} });
            },
            else => return CompileError.InvalidAssignTarget,
        }
    }

    fn compileAssign(self: *Compiler, code: *CodeObject, s: ast.Assign) !void {
        try self.compileExpr(code, s.value);
        try self.compileStore(code, s.target);
    }

    fn compileAugAssign(self: *Compiler, code: *CodeObject, s: ast.AugAssign) !void {
        const name_idx = try code.addName(self.allocator, try assignTargetName(s.target));
        _ = try code.emit(self.allocator, .load_name, .{ .index = name_idx });
        try self.compileExpr(code, s.value);
        _ = try code.emit(self.allocator, binOpToOpcode(s.op), .{ .none = {} });
        _ = try code.emit(self.allocator, .store_name, .{ .index = name_idx });
    }

    fn compileExpr(self: *Compiler, code: *CodeObject, node: *const ast.Node) anyerror!void {
        switch (node.*) {
            .num_int => |v| {
                const idx = try code.addConst(self.allocator, .{ .int = v });
                _ = try code.emit(self.allocator, .load_const, .{ .index = idx });
            },
            .num_float => |v| {
                const idx = try code.addConst(self.allocator, .{ .float = v });
                _ = try code.emit(self.allocator, .load_const, .{ .index = idx });
            },
            .str => |v| {
                const idx = try code.addConst(self.allocator, .{ .string = v });
                _ = try code.emit(self.allocator, .load_const, .{ .index = idx });
            },
            .bool_lit => |v| {
                const idx = try code.addConst(self.allocator, .{ .boolean = v });
                _ = try code.emit(self.allocator, .load_const, .{ .index = idx });
            },
            .none_lit => {
                const idx = try code.addConst(self.allocator, .{ .none = {} });
                _ = try code.emit(self.allocator, .load_const, .{ .index = idx });
            },
            .name => |v| {
                const idx = try code.addName(self.allocator, v);
                _ = try code.emit(self.allocator, .load_name, .{ .index = idx });
            },
            .bin_op => |b| {
                try self.compileExpr(code, b.left);
                try self.compileExpr(code, b.right);
                _ = try code.emit(self.allocator, binOpToOpcode(b.op), .{ .none = {} });
            },
            .unary_op => |u| {
                try self.compileExpr(code, u.operand);
                const op: Opcode = if (u.op == .neg) .unary_negative else .unary_not;
                _ = try code.emit(self.allocator, op, .{ .none = {} });
            },
            .compare => |c| {
                try self.compileExpr(code, c.left);
                try self.compileExpr(code, c.right);
                _ = try code.emit(self.allocator, .compare_op, .{ .compare = c.op });
            },
            .bool_op => |b| {
                const jump_op: Opcode = if (b.op == .and_) .jump_if_false_or_pop else .jump_if_true_or_pop;
                var end_jumps: std.ArrayList(usize) = .empty;
                defer end_jumps.deinit(self.allocator);
                for (b.values[0 .. b.values.len - 1]) |v| {
                    try self.compileExpr(code, v);
                    try end_jumps.append(self.allocator, try code.emit(self.allocator, jump_op, .{ .none = {} }));
                }
                try self.compileExpr(code, b.values[b.values.len - 1]);
                const end = code.here();
                for (end_jumps.items) |idx| self.patchJump(code, idx, end);
            },
            .call => |c| {
                try self.compileExpr(code, c.func);
                for (c.args) |a| try self.compileExpr(code, a);
                _ = try code.emit(self.allocator, .call_function, .{ .index = c.args.len });
            },
            .list_lit => |l| {
                for (l.elements) |e| try self.compileExpr(code, e);
                _ = try code.emit(self.allocator, .build_list, .{ .index = l.elements.len });
            },
            .subscript => |s| {
                try self.compileExpr(code, s.obj);
                try self.compileExpr(code, s.index);
                _ = try code.emit(self.allocator, .binary_subscr, .{ .none = {} });
            },
            else => return CompileError.UnsupportedNode,
        }
    }
};

pub fn compile(allocator: std.mem.Allocator, module: *const ast.Node) !*CodeObject {
    var compiler = Compiler.init(allocator);
    return compiler.compileModule(module);
}

// -- tests --------------------------------------------------------------

const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");

fn compileSource(allocator: std.mem.Allocator, source: []const u8) !*CodeObject {
    var lex = try lexer_mod.Lexer.init(allocator, source);
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(allocator, tokens);
    const module = try parser.parseModule();
    return compile(allocator, module);
}

test "simple arithmetic bytecode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const code = try compileSource(a, "x = 1 + 2\n");
    const ops = code.instructions.items;
    const expected = [_]Opcode{ .load_const, .load_const, .binary_add, .store_name, .load_const, .return_value };
    try std.testing.expectEqual(expected.len, ops.len);
    for (expected, 0..) |op, i| try std.testing.expectEqual(op, ops[i].opcode);
    try std.testing.expectEqual(@as(i64, 1), code.consts.items[0].int);
    try std.testing.expectEqual(@as(i64, 2), code.consts.items[1].int);
    try std.testing.expectEqualStrings("x", code.names.items[0]);
}

test "jump targets are in bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const code = try compileSource(a, "if x:\n    y = 1\nelse:\n    y = 2\n");
    for (code.instructions.items) |instr| {
        if (instr.opcode == .jump_forward or instr.opcode == .pop_jump_if_false) {
            try std.testing.expect(instr.arg.index <= code.instructions.items.len);
        }
    }
}

test "while loop jumps backward" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const code = try compileSource(a, "while x:\n    x = 0\n");
    var found = false;
    for (code.instructions.items, 0..) |instr, i| {
        if (instr.opcode == .jump_forward) {
            found = true;
            try std.testing.expect(instr.arg.index < i);
        }
    }
    try std.testing.expect(found);
}

test "function def produces nested code object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const code = try compileSource(a, "def f(a):\n    return a\n");
    var make_function_idx: ?usize = null;
    for (code.instructions.items) |instr| {
        if (instr.opcode == .make_function) make_function_idx = instr.arg.index;
    }
    try std.testing.expect(make_function_idx != null);
    const func = code.consts.items[make_function_idx.?].function;
    try std.testing.expectEqualStrings("f", func.code.name);
    try std.testing.expectEqual(@as(usize, 1), func.code.params.len);
}
