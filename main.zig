//! CLI entry point. Z3 scope: the full pipeline runs for real now.
//!
//!     zython script.zpy                     runs it
//!     zython --dump-tokens script.zpy       + prints the token stream
//!     zython --dump-ast script.zpy          + prints the AST
//!     zython --dump-bytecode script.zpy     + prints compiled bytecode
//!     zython --verbose script.zpy           live instruction trace, flushed
//!                                            every step, as it executes
//!
//! `--dump-*` flags are additive (mirrors pyinterp's cli.py): the program
//! still runs after printing that stage.

const std = @import("std");
const Io = std.Io;
const lexer_mod = @import("lexer.zig");
const token_mod = @import("token.zig");
const parser_mod = @import("parser.zig");
const ast = @import("ast.zig");
const compiler_mod = @import("compiler.zig");
const bytecode = @import("bytecode.zig");
const value_mod = @import("value.zig");
const vm_mod = @import("vm.zig");
const worker_mod = @import("worker.zig");

fn dumpIndent(writer: anytype, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try writer.print("  ", .{});
}

fn dumpNode(node: *const ast.Node, writer: anytype, depth: usize) !void {
    try dumpIndent(writer, depth);
    switch (node.*) {
        .module => |m| {
            try writer.print("Module\n", .{});
            for (m.body) |s| try dumpNode(s, writer, depth + 1);
        },
        .function_def => |f| {
            try writer.print("FunctionDef {s}(", .{f.name});
            for (f.params, 0..) |p, i| {
                if (i != 0) try writer.print(", ", .{});
                try writer.print("{s}", .{p});
            }
            try writer.print(")\n", .{});
            for (f.body) |s| try dumpNode(s, writer, depth + 1);
        },
        .return_stmt => |r| {
            try writer.print("Return\n", .{});
            if (r.value) |v| try dumpNode(v, writer, depth + 1);
        },
        .if_stmt => |s| {
            try writer.print("If\n", .{});
            try dumpNode(s.cond, writer, depth + 1);
            for (s.body) |stmt| try dumpNode(stmt, writer, depth + 1);
            if (s.orelse_body.len > 0) {
                try dumpIndent(writer, depth);
                try writer.print("Else\n", .{});
                for (s.orelse_body) |stmt| try dumpNode(stmt, writer, depth + 1);
            }
        },
        .while_stmt => |s| {
            try writer.print("While\n", .{});
            try dumpNode(s.cond, writer, depth + 1);
            for (s.body) |stmt| try dumpNode(stmt, writer, depth + 1);
        },
        .assign => |s| {
            try writer.print("Assign\n", .{});
            try dumpNode(s.target, writer, depth + 1);
            try dumpNode(s.value, writer, depth + 1);
        },
        .aug_assign => |s| {
            try writer.print("AugAssign {s}\n", .{@tagName(s.op)});
            try dumpNode(s.target, writer, depth + 1);
            try dumpNode(s.value, writer, depth + 1);
        },
        .expr_stmt => |s| {
            try writer.print("ExprStmt\n", .{});
            try dumpNode(s.value, writer, depth + 1);
        },
        .num_int => |v| try writer.print("Int {d}\n", .{v}),
        .num_float => |v| try writer.print("Float {d}\n", .{v}),
        .str => |v| try writer.print("Str {s}\n", .{v}),
        .bool_lit => |v| try writer.print("Bool {}\n", .{v}),
        .none_lit => try writer.print("None\n", .{}),
        .name => |v| try writer.print("Name {s}\n", .{v}),
        .bin_op => |b| {
            try writer.print("BinOp {s}\n", .{@tagName(b.op)});
            try dumpNode(b.left, writer, depth + 1);
            try dumpNode(b.right, writer, depth + 1);
        },
        .unary_op => |u| {
            try writer.print("UnaryOp {s}\n", .{@tagName(u.op)});
            try dumpNode(u.operand, writer, depth + 1);
        },
        .bool_op => |b| {
            try writer.print("BoolOp {s}\n", .{@tagName(b.op)});
            for (b.values) |v| try dumpNode(v, writer, depth + 1);
        },
        .compare => |c| {
            try writer.print("Compare {s}\n", .{@tagName(c.op)});
            try dumpNode(c.left, writer, depth + 1);
            try dumpNode(c.right, writer, depth + 1);
        },
        .call => |c| {
            try writer.print("Call\n", .{});
            try dumpNode(c.func, writer, depth + 1);
            for (c.args) |a| try dumpNode(a, writer, depth + 1);
        },
        .for_stmt => |s| {
            try writer.print("For {s}\n", .{s.target});
            try dumpNode(s.iter, writer, depth + 1);
            for (s.body) |stmt| try dumpNode(stmt, writer, depth + 1);
        },
        .list_lit => |l| {
            try writer.print("ListLit\n", .{});
            for (l.elements) |e| try dumpNode(e, writer, depth + 1);
        },
        .subscript => |s| {
            try writer.print("Subscript\n", .{});
            try dumpNode(s.obj, writer, depth + 1);
            try dumpNode(s.index, writer, depth + 1);
        },
    }
}

fn dumpBytecode(code: *const bytecode.CodeObject, writer: anytype, seen: *std.AutoHashMap(usize, void)) !void {
    const key = @intFromPtr(code);
    if (seen.contains(key)) return;
    try seen.put(key, {});

    try writer.print("<CodeObject {s}(", .{code.name});
    for (code.params, 0..) |p, i| {
        if (i != 0) try writer.print(", ", .{});
        try writer.print("{s}", .{p});
    }
    try writer.print(")>\n", .{});

    for (code.instructions.items, 0..) |instr, i| {
        try writer.print("{d:4}  {s:<20}", .{ i, @tagName(instr.opcode) });
        switch (instr.arg) {
            .none => {},
            .index => |idx| switch (instr.opcode) {
                .load_const, .make_function => {
                    try writer.print("{d} (", .{idx});
                    try value_mod.format(code.consts.items[idx], writer);
                    try writer.print(")", .{});
                },
                .load_name, .store_name => try writer.print("{d} ({s})", .{ idx, code.names.items[idx] }),
                else => try writer.print("{d}", .{idx}),
            },
            .compare => |c| try writer.print("{s}", .{@tagName(c)}),
        }
        try writer.print("\n", .{});
    }
    try writer.print("\n", .{});

    for (code.consts.items) |c| {
        if (c == .function) try dumpBytecode(c.function.code, writer, seen);
    }
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);

    var dump_tokens = false;
    var dump_ast = false;
    var dump_bytecode_flag = false;
    var verbose = false;
    var path: ?[]const u8 = null;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--dump-tokens")) {
            dump_tokens = true;
        } else if (std.mem.eql(u8, a, "--dump-ast")) {
            dump_ast = true;
        } else if (std.mem.eql(u8, a, "--dump-bytecode")) {
            dump_bytecode_flag = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            std.debug.print("unknown flag: {s}\n", .{a});
            std.debug.print("usage: zython [--dump-tokens|--dump-ast|--dump-bytecode|--verbose] <script.zpy>\n", .{});
            std.process.exit(1);
        } else {
            path = a;
        }
    }

    const script_path = path orelse {
        std.debug.print("usage: zython [--dump-tokens|--dump-ast|--dump-bytecode|--verbose] <script.zpy>\n", .{});
        return;
    };

    const source = Io.Dir.cwd().readFileAlloc(io, script_path, arena, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.print("error reading '{s}': {s}\n", .{ script_path, @errorName(err) });
        std.process.exit(1);
    };

    // Process-lifetime arena, not a leak-checking allocator: the "arena per
    // VM instance" strategy from the Phase 2 plan. Tests use
    // `std.testing.allocator` wrapped in a per-test ArenaAllocator instead.
    var lex = try lexer_mod.Lexer.init(arena, source);
    const tokens = lex.tokenize() catch {
        std.debug.print("lex error: {s}\n", .{lex.diag});
        std.process.exit(1);
    };

    if (dump_tokens) {
        for (tokens) |t| {
            try out.print("{s:<12}", .{@tagName(t.type)});
            switch (t.value) {
                .int => |v| try out.print("{d}", .{v}),
                .float => |v| try out.print("{d}", .{v}),
                .text => |v| try out.print("{s}", .{v}),
                .none => {},
            }
            try out.print("  (line {d}, col {d})\n", .{ t.line, t.col });
        }
        try out.print("\n", .{});
    }

    var parser = parser_mod.Parser.init(arena, tokens);
    const module = parser.parseModule() catch {
        std.debug.print("parse error: {s}\n", .{parser.diag});
        std.process.exit(1);
    };

    if (dump_ast) {
        try dumpNode(module, out, 0);
        try out.print("\n", .{});
    }

    const code = compiler_mod.compile(arena, module) catch |err| {
        std.debug.print("compile error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    if (dump_bytecode_flag) {
        var seen = std.AutoHashMap(usize, void).init(arena);
        try dumpBytecode(code, out, &seen);
    }

    // out_mutex/mailbox are heap-allocated (not stack locals) since spawned
    // workers (see worker.zig) hold pointers to them for the whole
    // process's lifetime, not just this function's.
    const out_mutex = try arena.create(Io.Mutex);
    out_mutex.* = .init;
    const mailbox = try arena.create(worker_mod.Mailbox);
    mailbox.* = .{};

    var vm = try vm_mod.VM.init(arena, out, out_mutex, io, mailbox);
    vm.verbose = verbose;
    _ = vm.run(code) catch {
        try out.flush();
        std.debug.print("runtime error: {s}\n", .{vm.diag});
        std.process.exit(1);
    };
}

test {
    _ = @import("token.zig");
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
    _ = @import("value.zig");
    _ = @import("bytecode.zig");
    _ = @import("compiler.zig");
    _ = @import("vm.zig");
    _ = @import("worker.zig");
}
