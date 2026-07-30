//! Stack-based virtual machine that executes a CodeObject's bytecode.
//! Ports pyinterp/vm.py's frame-based dispatch loop.
//!
//! `--verbose` live tracing (traceInstruction below) is not a Phase 1
//! feature -- it's the whole reason Phase 2 exists in the eyes of the
//! person who asked for it: print what the VM is doing *as it executes*,
//! flushed every instruction, not a static post-compile dump. The trace is
//! prefixed with a worker id from day one even though there's only ever
//! worker 0 until Z4 (isolated-heap workers + message passing) lands, so
//! the format doesn't need to change later.

const std = @import("std");
const Io = std.Io;
const bytecode = @import("bytecode.zig");
const CodeObject = bytecode.CodeObject;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const worker_mod = @import("worker.zig");

pub const VMError = error{
    NameError,
    NotCallable,
    ArityMismatch,
    InvalidArgument,
    IndexError,
    TypeMismatch,
    NotIterable,
};

/// stdout is the one piece of state every worker genuinely shares (there's
/// only one real terminal) -- everything else is per-worker/isolated, so
/// this is the only lock most of the VM ever touches. Held around whole
/// print/trace lines so concurrent workers' output doesn't interleave
/// mid-line.
fn builtinPrint(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    try self.out_mutex.lock(self.io);
    defer self.out_mutex.unlock(self.io);
    for (args, 0..) |a, i| {
        if (i != 0) try self.out.print(" ", .{});
        try value_mod.format(a, self.out);
    }
    try self.out.print("\n", .{});
    return .{ .none = {} };
}

fn builtinSpawn(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len == 0 or args[0] != .function) {
        return self.fail("TypeError: spawn() requires a function as its first argument", .{}, VMError.InvalidArgument);
    }
    const w = worker_mod.spawn(args[0].function, args[1..], self.out, self.out_mutex, self.io, self.verbose) catch |err| {
        return self.fail("TypeError: spawn() failed ({s}) -- args must be plain data (no functions/workers)", .{@errorName(err)}, VMError.InvalidArgument);
    };
    return .{ .worker = w };
}

fn builtinSend(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .worker) {
        return self.fail("TypeError: send() requires a worker handle and a value", .{}, VMError.InvalidArgument);
    }
    const w: *worker_mod.Worker = @ptrCast(@alignCast(args[0].worker));
    const msg = value_mod.valueToMessage(args[1]) catch {
        return self.fail("TypeError: value is not sendable across workers (no functions/workers)", .{}, VMError.InvalidArgument);
    };
    try w.mailbox.send(self.io, msg);
    return .{ .none = {} };
}

fn builtinRecv(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = args;
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    const msg = try self.mailbox.recv(self.io);
    return value_mod.messageToValue(allocator, msg);
}

fn builtinJoin(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .worker) {
        return self.fail("TypeError: join() requires a worker handle", .{}, VMError.InvalidArgument);
    }
    const w: *worker_mod.Worker = @ptrCast(@alignCast(args[0].worker));
    return worker_mod.join(allocator, w);
}

fn builtinLen(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1) return self.fail("TypeError: len() takes exactly one argument", .{}, VMError.InvalidArgument);
    return switch (args[0]) {
        .list => |l| .{ .int = @intCast(l.items.items.len) },
        .string => |s| .{ .int = @intCast(s.len) },
        else => self.fail("TypeError: object has no len()", .{}, VMError.InvalidArgument),
    };
}

/// `range(stop)` or `range(start, stop)` -- unlike real Python, this
/// materializes a full list rather than a lazy sequence (no lazy-iterator
/// abstraction in this subset yet). Fine for teaching purposes; revisit if
/// a program actually needs a huge range without paying to allocate it.
fn builtinRange(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    var start: i64 = 0;
    var stop: i64 = undefined;
    switch (args.len) {
        1 => {
            if (args[0] != .int) return self.fail("TypeError: range() arguments must be integers", .{}, VMError.InvalidArgument);
            stop = args[0].int;
        },
        2 => {
            if (args[0] != .int or args[1] != .int) return self.fail("TypeError: range() arguments must be integers", .{}, VMError.InvalidArgument);
            start = args[0].int;
            stop = args[1].int;
        },
        else => return self.fail("TypeError: range() takes 1 or 2 arguments", .{}, VMError.InvalidArgument),
    }
    var items: std.ArrayList(Value) = .empty;
    var i = start;
    while (i < stop) : (i += 1) try items.append(allocator, .{ .int = i });
    const list_obj = try allocator.create(value_mod.ListObj);
    list_obj.* = .{ .items = items };
    return .{ .list = list_obj };
}

/// `append(list, item)`, not `list.append(item)` -- there's no attribute
/// access syntax in this subset yet, so list mutation goes through plain
/// builtin functions instead of method calls.
fn builtinAppend(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .list) {
        return self.fail("TypeError: append() requires a list and a value", .{}, VMError.InvalidArgument);
    }
    try args[0].list.items.append(allocator, args[1]);
    return .{ .none = {} };
}

pub const VM = struct {
    allocator: std.mem.Allocator,
    globals: std.StringHashMap(Value),
    builtins: std.StringHashMap(Value),
    out: *Io.Writer,
    out_mutex: *Io.Mutex,
    io: Io,
    mailbox: *worker_mod.Mailbox,
    verbose: bool = false,
    worker_id: usize = 0,
    diag: []const u8 = "",

    pub fn init(
        allocator: std.mem.Allocator,
        out: *Io.Writer,
        out_mutex: *Io.Mutex,
        io: Io,
        mailbox: *worker_mod.Mailbox,
    ) !VM {
        var vm = VM{
            .allocator = allocator,
            .globals = std.StringHashMap(Value).init(allocator),
            .builtins = std.StringHashMap(Value).init(allocator),
            .out = out,
            .out_mutex = out_mutex,
            .io = io,
            .mailbox = mailbox,
        };
        try vm.builtins.put("print", .{ .builtin = builtinPrint });
        try vm.builtins.put("spawn", .{ .builtin = builtinSpawn });
        try vm.builtins.put("send", .{ .builtin = builtinSend });
        try vm.builtins.put("recv", .{ .builtin = builtinRecv });
        try vm.builtins.put("join", .{ .builtin = builtinJoin });
        try vm.builtins.put("len", .{ .builtin = builtinLen });
        try vm.builtins.put("range", .{ .builtin = builtinRange });
        try vm.builtins.put("append", .{ .builtin = builtinAppend });
        return vm;
    }

    /// Public entry point for worker.zig to call a spawned function
    /// directly (not through a whole module's bytecode).
    pub fn callFunctionPublic(self: *VM, func: *bytecode.PyFunction, args: []const Value) !Value {
        return self.callFunction(func, args);
    }

    pub fn deinit(self: *VM) void {
        self.globals.deinit();
        self.builtins.deinit();
    }

    pub fn run(self: *VM, code: *const CodeObject) !Value {
        return self.runFrame(code, &self.globals);
    }

    fn fail(self: *VM, comptime fmt: []const u8, args: anytype, err: VMError) VMError {
        self.diag = std.fmt.allocPrint(self.allocator, fmt, args) catch "";
        return err;
    }

    fn loadName(self: *VM, locals: *std.StringHashMap(Value), name: []const u8) !Value {
        if (locals.get(name)) |v| return v;
        if (self.globals.get(name)) |v| return v;
        if (self.builtins.get(name)) |v| return v;
        return self.fail("NameError: name '{s}' is not defined", .{name}, VMError.NameError);
    }

    /// Python-style negative indexing (`-1` = last element); null if the
    /// (already-normalized) index is still out of range.
    fn normalizeIndex(len: usize, idx: i64) ?usize {
        var i = idx;
        if (i < 0) i += @as(i64, @intCast(len));
        if (i < 0 or i >= @as(i64, @intCast(len))) return null;
        return @intCast(i);
    }

    fn subscriptGet(self: *VM, obj: Value, index: Value) !Value {
        if (index != .int) {
            return self.fail("TypeError: indices must be integers", .{}, VMError.TypeMismatch);
        }
        return switch (obj) {
            .list => |l| blk: {
                const idx = normalizeIndex(l.items.items.len, index.int) orelse
                    return self.fail("IndexError: list index out of range", .{}, VMError.IndexError);
                break :blk l.items.items[idx];
            },
            .string => |s| blk: {
                const idx = normalizeIndex(s.len, index.int) orelse
                    return self.fail("IndexError: string index out of range", .{}, VMError.IndexError);
                break :blk .{ .string = s[idx .. idx + 1] };
            },
            else => self.fail("TypeError: value is not subscriptable", .{}, VMError.TypeMismatch),
        };
    }

    fn subscriptSet(self: *VM, obj: Value, index: Value, value: Value) !void {
        if (obj != .list) {
            return self.fail("TypeError: value does not support item assignment", .{}, VMError.TypeMismatch);
        }
        if (index != .int) {
            return self.fail("TypeError: list indices must be integers", .{}, VMError.TypeMismatch);
        }
        const idx = normalizeIndex(obj.list.items.items.len, index.int) orelse
            return self.fail("IndexError: list assignment index out of range", .{}, VMError.IndexError);
        obj.list.items.items[idx] = value;
    }

    fn callValue(self: *VM, func: Value, args: []const Value) anyerror!Value {
        return switch (func) {
            .function => |f| self.callFunction(f, args),
            .builtin => |b| b(@ptrCast(self), self.allocator, args),
            else => self.fail("TypeError: value is not callable", .{}, VMError.NotCallable),
        };
    }

    fn callFunction(self: *VM, func: *bytecode.PyFunction, args: []const Value) anyerror!Value {
        if (args.len != func.code.params.len) {
            return self.fail(
                "TypeError: {s}() takes {d} argument(s) but {d} were given",
                .{ func.code.name, func.code.params.len, args.len },
                VMError.ArityMismatch,
            );
        }
        var locals = std.StringHashMap(Value).init(self.allocator);
        defer locals.deinit();
        for (func.code.params, 0..) |p, i| try locals.put(p, args[i]);
        return self.runFrame(func.code, &locals);
    }

    fn traceInstruction(self: *VM, code: *const CodeObject, pc: usize, instr: bytecode.Instruction, stack: []const Value) !void {
        try self.out_mutex.lock(self.io);
        defer self.out_mutex.unlock(self.io);
        try self.out.print("[worker {d}] {s:<10} pc={d:<3} {s:<20}", .{ self.worker_id, code.name, pc, @tagName(instr.opcode) });
        switch (instr.arg) {
            .none => try self.out.print("{s:<8}", .{""}),
            .index => |idx| try self.out.print("arg={d:<4}", .{idx}),
            .compare => |c| try self.out.print("arg={s:<4}", .{@tagName(c)}),
        }
        try self.out.print(" stack=[", .{});
        for (stack, 0..) |v, i| {
            if (i != 0) try self.out.print(", ", .{});
            try value_mod.format(v, self.out);
        }
        try self.out.print("]\n", .{});
        try self.out.flush(); // realtime: flush every instruction, not just when the buffer fills
    }

    fn runFrame(self: *VM, code: *const CodeObject, locals: *std.StringHashMap(Value)) anyerror!Value {
        var stack: std.ArrayList(Value) = .empty;
        defer stack.deinit(self.allocator);

        var pc: usize = 0;
        while (true) {
            const instr = code.instructions.items[pc];
            if (self.verbose) try self.traceInstruction(code, pc, instr, stack.items);

            switch (instr.opcode) {
                .load_const => {
                    try stack.append(self.allocator, code.consts.items[instr.arg.index]);
                    pc += 1;
                },
                .load_name => {
                    const v = try self.loadName(locals, code.names.items[instr.arg.index]);
                    try stack.append(self.allocator, v);
                    pc += 1;
                },
                .store_name => {
                    const v = stack.pop().?;
                    try locals.put(code.names.items[instr.arg.index], v);
                    pc += 1;
                },
                .pop_top => {
                    _ = stack.pop();
                    pc += 1;
                },
                .unary_negative => {
                    const v = stack.pop().?;
                    try stack.append(self.allocator, try value_mod.negate(v));
                    pc += 1;
                },
                .unary_not => {
                    const v = stack.pop().?;
                    try stack.append(self.allocator, .{ .boolean = !value_mod.isTruthy(v) });
                    pc += 1;
                },
                .binary_add => {
                    const right = stack.pop().?;
                    const left = stack.pop().?;
                    if (left == .string and right == .string) {
                        const s = try std.mem.concat(self.allocator, u8, &.{ left.string, right.string });
                        try stack.append(self.allocator, .{ .string = s });
                    } else {
                        try stack.append(self.allocator, try value_mod.add(left, right));
                    }
                    pc += 1;
                },
                .binary_subtract => {
                    const right = stack.pop().?;
                    const left = stack.pop().?;
                    try stack.append(self.allocator, try value_mod.sub(left, right));
                    pc += 1;
                },
                .binary_multiply => {
                    const right = stack.pop().?;
                    const left = stack.pop().?;
                    try stack.append(self.allocator, try value_mod.mul(left, right));
                    pc += 1;
                },
                .binary_true_divide => {
                    const right = stack.pop().?;
                    const left = stack.pop().?;
                    try stack.append(self.allocator, try value_mod.trueDiv(left, right));
                    pc += 1;
                },
                .binary_floor_divide => {
                    const right = stack.pop().?;
                    const left = stack.pop().?;
                    try stack.append(self.allocator, try value_mod.floorDiv(left, right));
                    pc += 1;
                },
                .binary_modulo => {
                    const right = stack.pop().?;
                    const left = stack.pop().?;
                    try stack.append(self.allocator, try value_mod.mod(left, right));
                    pc += 1;
                },
                .compare_op => {
                    const right = stack.pop().?;
                    const left = stack.pop().?;
                    const result = try value_mod.compare(instr.arg.compare, left, right);
                    try stack.append(self.allocator, .{ .boolean = result });
                    pc += 1;
                },
                .jump_forward => {
                    pc = instr.arg.index;
                },
                .pop_jump_if_false => {
                    const v = stack.pop().?;
                    if (!value_mod.isTruthy(v)) {
                        pc = instr.arg.index;
                    } else {
                        pc += 1;
                    }
                },
                .jump_if_false_or_pop => {
                    if (!value_mod.isTruthy(stack.items[stack.items.len - 1])) {
                        pc = instr.arg.index;
                    } else {
                        _ = stack.pop();
                        pc += 1;
                    }
                },
                .jump_if_true_or_pop => {
                    if (value_mod.isTruthy(stack.items[stack.items.len - 1])) {
                        pc = instr.arg.index;
                    } else {
                        _ = stack.pop();
                        pc += 1;
                    }
                },
                .call_function => {
                    const argc = instr.arg.index;
                    var args: std.ArrayList(Value) = .empty;
                    defer args.deinit(self.allocator);
                    var i: usize = 0;
                    while (i < argc) : (i += 1) {
                        try args.append(self.allocator, stack.pop().?);
                    }
                    std.mem.reverse(Value, args.items);
                    const func = stack.pop().?;
                    const result = try self.callValue(func, args.items);
                    try stack.append(self.allocator, result);
                    pc += 1;
                },
                .make_function => {
                    // The compiler already wrapped the CodeObject into a
                    // PyFunction Value at compile time (no closures in this
                    // subset, so there's nothing runtime-dependent to
                    // capture) -- this opcode exists for bytecode-dump
                    // readability/fidelity with Phase 1, not because it
                    // does more than LOAD_CONST would here.
                    try stack.append(self.allocator, code.consts.items[instr.arg.index]);
                    pc += 1;
                },
                .return_value => {
                    return stack.pop().?;
                },
                .build_list => {
                    const n = instr.arg.index;
                    var items: std.ArrayList(Value) = .empty;
                    var i: usize = 0;
                    while (i < n) : (i += 1) try items.append(self.allocator, stack.pop().?);
                    std.mem.reverse(Value, items.items);
                    const list_obj = try self.allocator.create(value_mod.ListObj);
                    list_obj.* = .{ .items = items };
                    try stack.append(self.allocator, .{ .list = list_obj });
                    pc += 1;
                },
                .binary_subscr => {
                    const index_v = stack.pop().?;
                    const obj_v = stack.pop().?;
                    try stack.append(self.allocator, try self.subscriptGet(obj_v, index_v));
                    pc += 1;
                },
                .store_subscr => {
                    const index_v = stack.pop().?;
                    const obj_v = stack.pop().?;
                    const value_v = stack.pop().?;
                    try self.subscriptSet(obj_v, index_v, value_v);
                    pc += 1;
                },
                .get_iter => {
                    const iterable = stack.pop().?;
                    if (iterable != .list) {
                        return self.fail("TypeError: value is not iterable", .{}, VMError.NotIterable);
                    }
                    const iter_obj = try self.allocator.create(value_mod.IterObj);
                    iter_obj.* = .{ .list = iterable.list };
                    try stack.append(self.allocator, .{ .iterator = iter_obj });
                    pc += 1;
                },
                .for_iter => {
                    const iter_obj = stack.items[stack.items.len - 1].iterator;
                    if (iter_obj.index < iter_obj.list.items.items.len) {
                        const item = iter_obj.list.items.items[iter_obj.index];
                        iter_obj.index += 1;
                        try stack.append(self.allocator, item);
                        pc += 1;
                    } else {
                        _ = stack.pop();
                        pc = instr.arg.index;
                    }
                },
            }
        }
    }
};

// -- tests --------------------------------------------------------------

const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const compiler_mod = @import("compiler.zig");

const TestRun = struct {
    vm: VM,
    writer: *Io.Writer,

    fn output(self: *const TestRun) []const u8 {
        return self.writer.buffered();
    }
};

/// Everything VM.init needs beyond an allocator (io/mutex/mailbox) is
/// allocated from the test's own arena so it has a stable address for the
/// whole test's lifetime -- no self-referential-struct-by-value footguns.
/// The `Io.Threaded` instance's own OS-level setup is deliberately never
/// torn down here (no `.deinit()`): acceptable for a short-lived test
/// process, not something main.zig needs to do at all since it's handed a
/// ready-made `Io` via `std.process.Init` instead of constructing one.
fn runSource(allocator: std.mem.Allocator, source: []const u8) !TestRun {
    var lex = try lexer_mod.Lexer.init(allocator, source);
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(allocator, tokens);
    const module = try parser.parseModule();
    const code = try compiler_mod.compile(allocator, module);

    const buf = try allocator.alloc(u8, 4096);
    const writer = try allocator.create(Io.Writer);
    writer.* = Io.Writer.fixed(buf);

    const threaded = try allocator.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    const io = threaded.io();

    const out_mutex = try allocator.create(Io.Mutex);
    out_mutex.* = .init;
    const mailbox = try allocator.create(worker_mod.Mailbox);
    mailbox.* = .{};

    var vm = try VM.init(allocator, writer, out_mutex, io, mailbox);
    _ = try vm.run(code);
    return .{ .vm = vm, .writer = writer };
}

test "arithmetic and variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "x = 2 + 3 * 4\ny = x - 1\n");
    try std.testing.expectEqual(@as(i64, 14), run.vm.globals.get("x").?.int);
    try std.testing.expectEqual(@as(i64, 13), run.vm.globals.get("y").?.int);
}

test "if else branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "x = 5\nif x > 10:\n    y = 1\nelse:\n    y = 2\n");
    try std.testing.expectEqual(@as(i64, 2), run.vm.globals.get("y").?.int);
}

test "while loop accumulates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "i = 0\ntotal = 0\nwhile i < 5:\n    total = total + i\n    i = i + 1\n");
    try std.testing.expectEqual(@as(i64, 10), run.vm.globals.get("total").?.int);
    try std.testing.expectEqual(@as(i64, 5), run.vm.globals.get("i").?.int);
}

test "function call and recursion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "def fact(n):\n    if n == 0:\n        return 1\n    return n * fact(n - 1)\nresult = fact(5)\n",
    );
    try std.testing.expectEqual(@as(i64, 120), run.vm.globals.get("result").?.int);
}

test "boolean short circuit and or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "a = True and 5\nb = False or 7\nc = False and 5\nd = True or 7\n");
    try std.testing.expectEqual(@as(i64, 5), run.vm.globals.get("a").?.int);
    try std.testing.expectEqual(@as(i64, 7), run.vm.globals.get("b").?.int);
    try std.testing.expectEqual(false, run.vm.globals.get("c").?.boolean);
    try std.testing.expectEqual(true, run.vm.globals.get("d").?.boolean);
}

test "augassign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "x = 1\nx += 4\nx *= 2\n");
    try std.testing.expectEqual(@as(i64, 10), run.vm.globals.get("x").?.int);
}

test "print builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "print(\"hello\", 1, True)\n");
    try std.testing.expectEqualStrings("hello 1 True\n", run.output());
}

test "fib sequence end to end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "def fib(n):\n    if n < 2:\n        return n\n    return fib(n - 1) + fib(n - 2)\n" ++
            "i = 0\nwhile i < 10:\n    print(fib(i))\n    i = i + 1\n",
    );
    try std.testing.expectEqualStrings("0\n1\n1\n2\n3\n5\n8\n13\n21\n34\n", run.output());
}

test "name error is diagnosable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = runSource(a, "print(undefined_name)\n");
    try std.testing.expectError(VMError.NameError, result);
}

test "spawn and join run a function on a real thread and return its result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "def sum_up_to(n):\n    total = 0\n    i = 0\n    while i < n:\n" ++
            "        total = total + i\n        i = i + 1\n    return total\n" ++
            "w = spawn(sum_up_to, 100)\nresult = join(w)\n",
    );
    try std.testing.expectEqual(@as(i64, 4950), run.vm.globals.get("result").?.int);
}

test "two spawned workers both complete correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "def sum_up_to(n):\n    total = 0\n    i = 0\n    while i < n:\n" ++
            "        total = total + i\n        i = i + 1\n    return total\n" ++
            "w1 = spawn(sum_up_to, 10)\nw2 = spawn(sum_up_to, 20)\n" ++
            "r1 = join(w1)\nr2 = join(w2)\n",
    );
    try std.testing.expectEqual(@as(i64, 45), run.vm.globals.get("r1").?.int);
    try std.testing.expectEqual(@as(i64, 190), run.vm.globals.get("r2").?.int);
}

test "send and recv pass a message to a worker and back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "def echo():\n    return recv()\n" ++
            "w = spawn(echo)\nsend(w, \"ping\")\nresult = join(w)\n",
    );
    try std.testing.expectEqualStrings("ping", run.vm.globals.get("result").?.string);
}

test "list literal and indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "xs = [10, 20, 30]\na = xs[0]\nb = xs[-1]\n");
    try std.testing.expectEqual(@as(i64, 10), run.vm.globals.get("a").?.int);
    try std.testing.expectEqual(@as(i64, 30), run.vm.globals.get("b").?.int);
    try std.testing.expectEqual(@as(usize, 3), run.vm.globals.get("xs").?.list.items.items.len);
}

test "subscript assignment mutates the list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "xs = [1, 2, 3]\nxs[1] = 99\n");
    const items = run.vm.globals.get("xs").?.list.items.items;
    try std.testing.expectEqual(@as(i64, 1), items[0].int);
    try std.testing.expectEqual(@as(i64, 99), items[1].int);
    try std.testing.expectEqual(@as(i64, 3), items[2].int);
}

test "index out of range is diagnosable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = runSource(a, "xs = [1, 2]\ny = xs[5]\n");
    try std.testing.expectError(VMError.IndexError, result);
}

test "for loop over a list accumulates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "total = 0\nfor x in [1, 2, 3, 4]:\n    total = total + x\n");
    try std.testing.expectEqual(@as(i64, 10), run.vm.globals.get("total").?.int);
}

test "range and append build a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "xs = []\nfor i in range(5):\n    append(xs, i * i)\n",
    );
    const items = run.vm.globals.get("xs").?.list.items.items;
    const expected = [_]i64{ 0, 1, 4, 9, 16 };
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, 0..) |e, i| try std.testing.expectEqual(e, items[i].int);
}

test "len works on lists and strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "a = len([1, 2, 3])\nb = len(\"hello\")\n");
    try std.testing.expectEqual(@as(i64, 3), run.vm.globals.get("a").?.int);
    try std.testing.expectEqual(@as(i64, 5), run.vm.globals.get("b").?.int);
}

test "spawning a non-function is a diagnosable error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = runSource(a, "w = spawn(5)\n");
    try std.testing.expectError(VMError.InvalidArgument, result);
}
