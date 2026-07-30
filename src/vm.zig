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
    KeyError,
    AttributeError,
    ZeroDivisionError,
    PyException,
};

fn errKind(err: VMError) value_mod.ExceptionKind {
    return switch (err) {
        VMError.NameError => .name_error,
        VMError.NotCallable, VMError.ArityMismatch, VMError.InvalidArgument, VMError.TypeMismatch, VMError.NotIterable => .type_error,
        VMError.IndexError => .index_error,
        VMError.KeyError => .key_error,
        VMError.AttributeError => .attribute_error,
        VMError.ZeroDivisionError => .zero_division_error,
        VMError.PyException => .exception,
    };
}

fn makeExceptionCtor(comptime kind: value_mod.ExceptionKind) value_mod.BuiltinFn {
    return struct {
        fn call(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
            _ = vm_ptr;
            const msg = if (args.len > 0 and args[0] == .string) args[0].string else "";
            const exc = try allocator.create(value_mod.ExceptionObj);
            exc.* = .{ .kind = kind, .message = msg };
            return .{ .exception = exc };
        }
    }.call;
}

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
        return self.fail("spawn() requires a function as its first argument", .{}, VMError.InvalidArgument);
    }
    const w = worker_mod.spawn(args[0].function, args[1..], self.out, self.out_mutex, self.io, self.verbose) catch |err| {
        return self.fail("spawn() failed ({s}) -- args must be plain data (no functions/workers)", .{@errorName(err)}, VMError.InvalidArgument);
    };
    return .{ .worker = w };
}

fn builtinSend(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .worker) {
        return self.fail("send() requires a worker handle and a value", .{}, VMError.InvalidArgument);
    }
    const w: *worker_mod.Worker = @ptrCast(@alignCast(args[0].worker));
    const msg = value_mod.valueToMessage(args[1]) catch {
        return self.fail("value is not sendable across workers (no functions/workers)", .{}, VMError.InvalidArgument);
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
        return self.fail("join() requires a worker handle", .{}, VMError.InvalidArgument);
    }
    const w: *worker_mod.Worker = @ptrCast(@alignCast(args[0].worker));
    return worker_mod.join(allocator, w);
}

fn builtinLen(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1) return self.fail("len() takes exactly one argument", .{}, VMError.InvalidArgument);
    return switch (args[0]) {
        .list => |l| .{ .int = @intCast(l.items.items.len) },
        .tuple => |t| .{ .int = @intCast(t.items.len) },
        .dict => |d| .{ .int = @intCast(d.entries.items.len) },
        .string => |s| .{ .int = @intCast(s.len) },
        else => self.fail("object has no len()", .{}, VMError.InvalidArgument),
    };
}

fn builtinRange(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    var start: i64 = 0;
    var stop: i64 = undefined;
    switch (args.len) {
        1 => {
            if (args[0] != .int) return self.fail("range() arguments must be integers", .{}, VMError.InvalidArgument);
            stop = args[0].int;
        },
        2 => {
            if (args[0] != .int or args[1] != .int) return self.fail("range() arguments must be integers", .{}, VMError.InvalidArgument);
            start = args[0].int;
            stop = args[1].int;
        },
        else => return self.fail("range() takes 1 or 2 arguments", .{}, VMError.InvalidArgument),
    }
    var items: std.ArrayList(Value) = .empty;
    var i = start;
    while (i < stop) : (i += 1) try items.append(allocator, .{ .int = i });
    const list_obj = try allocator.create(value_mod.ListObj);
    list_obj.* = .{ .items = items };
    return .{ .list = list_obj };
}

fn builtinAppend(vm_ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const self: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .list) {
        return self.fail("append() requires a list and a value", .{}, VMError.InvalidArgument);
    }
    try args[0].list.items.append(allocator, args[1]);
    return .{ .none = {} };
}

const TryBlock = struct {
    handler_pc: usize,
    stack_depth: usize,
};

const StepOutcome = union(enum) {
    next: usize,
    returned: Value,
};

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
    pending_exception: ?Value = null,

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
        try vm.builtins.put("Exception", .{ .builtin = makeExceptionCtor(.exception) });
        try vm.builtins.put("ArithmeticError", .{ .builtin = makeExceptionCtor(.arithmetic_error) });
        try vm.builtins.put("ZeroDivisionError", .{ .builtin = makeExceptionCtor(.zero_division_error) });
        try vm.builtins.put("LookupError", .{ .builtin = makeExceptionCtor(.lookup_error) });
        try vm.builtins.put("IndexError", .{ .builtin = makeExceptionCtor(.index_error) });
        try vm.builtins.put("KeyError", .{ .builtin = makeExceptionCtor(.key_error) });
        try vm.builtins.put("ValueError", .{ .builtin = makeExceptionCtor(.value_error) });
        try vm.builtins.put("TypeError", .{ .builtin = makeExceptionCtor(.type_error) });
        try vm.builtins.put("NameError", .{ .builtin = makeExceptionCtor(.name_error) });
        try vm.builtins.put("AttributeError", .{ .builtin = makeExceptionCtor(.attribute_error) });
        try vm.builtins.put("RuntimeError", .{ .builtin = makeExceptionCtor(.runtime_error) });
        return vm;
    }

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
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch "";
        const kind = errKind(err);
        self.diag = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ value_mod.exceptionKindName(kind), msg }) catch msg;
        if (self.allocator.create(value_mod.ExceptionObj)) |exc| {
            exc.* = .{ .kind = kind, .message = msg };
            self.pending_exception = .{ .exception = exc };
        } else |_| {}
        return err;
    }

    fn valueErrToVMError(self: *VM, err: value_mod.ValueError) VMError {
        return switch (err) {
            value_mod.ValueError.TypeMismatch => self.fail("unsupported operand type(s)", .{}, VMError.TypeMismatch),
            value_mod.ValueError.DivisionByZero => self.fail("division by zero", .{}, VMError.ZeroDivisionError),
        };
    }

    fn loadName(self: *VM, locals: *std.StringHashMap(Value), name: []const u8) !Value {
        if (locals.get(name)) |v| return v;
        if (self.globals.get(name)) |v| return v;
        if (self.builtins.get(name)) |v| return v;
        return self.fail("name '{s}' is not defined", .{name}, VMError.NameError);
    }

    fn normalizeIndex(len: usize, idx: i64) ?usize {
        var i = idx;
        if (i < 0) i += @as(i64, @intCast(len));
        if (i < 0 or i >= @as(i64, @intCast(len))) return null;
        return @intCast(i);
    }

    fn subscriptGet(self: *VM, obj: Value, index: Value) !Value {
        switch (obj) {
            .list => |l| {
                if (index != .int) return self.fail("indices must be integers", .{}, VMError.TypeMismatch);
                const idx = normalizeIndex(l.items.items.len, index.int) orelse
                    return self.fail("list index out of range", .{}, VMError.IndexError);
                return l.items.items[idx];
            },
            .tuple => |t| {
                if (index != .int) return self.fail("indices must be integers", .{}, VMError.TypeMismatch);
                const idx = normalizeIndex(t.items.len, index.int) orelse
                    return self.fail("tuple index out of range", .{}, VMError.IndexError);
                return t.items[idx];
            },
            .string => |s| {
                if (index != .int) return self.fail("indices must be integers", .{}, VMError.TypeMismatch);
                const idx = normalizeIndex(s.len, index.int) orelse
                    return self.fail("string index out of range", .{}, VMError.IndexError);
                return .{ .string = s[idx .. idx + 1] };
            },
            .dict => |d| {
                for (d.entries.items) |entry| {
                    if (value_mod.valuesEqual(entry.key, index)) return entry.value;
                }
                return self.fail("key not found", .{}, VMError.KeyError);
            },
            else => return self.fail("value is not subscriptable", .{}, VMError.TypeMismatch),
        }
    }

    fn subscriptSet(self: *VM, obj: Value, index: Value, value: Value) !void {
        switch (obj) {
            .list => |l| {
                if (index != .int) return self.fail("list indices must be integers", .{}, VMError.TypeMismatch);
                const idx = normalizeIndex(l.items.items.len, index.int) orelse
                    return self.fail("list assignment index out of range", .{}, VMError.IndexError);
                l.items.items[idx] = value;
            },
            .dict => |d| {
                for (d.entries.items) |*entry| {
                    if (value_mod.valuesEqual(entry.key, index)) {
                        entry.value = value;
                        return;
                    }
                }
                try d.entries.append(self.allocator, .{ .key = index, .value = value });
            },
            .tuple => return self.fail("'tuple' object does not support item assignment", .{}, VMError.TypeMismatch),
            else => return self.fail("value does not support item assignment", .{}, VMError.TypeMismatch),
        }
    }

    fn attrGet(self: *VM, obj: Value, name: []const u8) anyerror!Value {
        switch (obj) {
            .instance => |inst| {
                if (inst.attrs.get(name)) |v| return v;
                if (value_mod.findClassAttr(inst.class, name)) |v| {
                    if (v == .function) {
                        const bm = try self.allocator.create(value_mod.BoundMethodObj);
                        bm.* = .{ .function = v.function, .instance = inst };
                        return .{ .bound_method = bm };
                    }
                    return v;
                }
                return self.fail("'{s}' object has no attribute '{s}'", .{ inst.class.name, name }, VMError.AttributeError);
            },
            .class => |c| {
                if (value_mod.findClassAttr(c, name)) |v| return v;
                return self.fail("type object '{s}' has no attribute '{s}'", .{ c.name, name }, VMError.AttributeError);
            },
            .exception => |e| {
                if (std.mem.eql(u8, name, "args") or std.mem.eql(u8, name, "message")) {
                    return .{ .string = e.message };
                }
                return self.fail("exception has no attribute '{s}'", .{name}, VMError.AttributeError);
            },
            else => return self.fail("value has no attribute '{s}'", .{name}, VMError.AttributeError),
        }
    }

    fn attrSet(self: *VM, obj: Value, name: []const u8, value: Value) anyerror!void {
        switch (obj) {
            .instance => |inst| try inst.attrs.put(name, value),
            .class => |c| try c.namespace.put(name, value),
            else => return self.fail("value does not support attribute assignment", .{}, VMError.AttributeError),
        }
    }

    fn instantiate(self: *VM, class: *value_mod.ClassObj, args: []const Value) anyerror!Value {
        const inst = try self.allocator.create(value_mod.InstanceObj);
        inst.* = .{ .class = class, .attrs = std.StringHashMap(Value).init(self.allocator) };
        if (value_mod.findClassAttr(class, "__init__")) |init_v| {
            if (init_v == .function) {
                const full_args = try self.allocator.alloc(Value, args.len + 1);
                full_args[0] = .{ .instance = inst };
                @memcpy(full_args[1..], args);
                _ = try self.callFunction(init_v.function, full_args);
            }
        } else if (args.len > 0) {
            return self.fail("{s}() takes no arguments", .{class.name}, VMError.ArityMismatch);
        }
        return .{ .instance = inst };
    }

    fn callValue(self: *VM, func: Value, args: []const Value) anyerror!Value {
        return switch (func) {
            .function => |f| self.callFunction(f, args),
            .builtin => |b| b(@ptrCast(self), self.allocator, args),
            .bound_method => |bm| blk: {
                const full_args = try self.allocator.alloc(Value, args.len + 1);
                full_args[0] = .{ .instance = bm.instance };
                @memcpy(full_args[1..], args);
                break :blk self.callFunction(bm.function, full_args);
            },
            .class => |c| self.instantiate(c, args),
            else => self.fail("value is not callable", .{}, VMError.NotCallable),
        };
    }

    fn callFunction(self: *VM, func: *bytecode.PyFunction, args: []const Value) anyerror!Value {
        if (args.len != func.code.params.len) {
            return self.fail(
                "{s}() takes {d} argument(s) but {d} were given",
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
        try self.out.flush();
    }

    fn runFrame(self: *VM, code: *const CodeObject, locals: *std.StringHashMap(Value)) anyerror!Value {
        var stack: std.ArrayList(Value) = .empty;
        defer stack.deinit(self.allocator);
        var block_stack: std.ArrayList(TryBlock) = .empty;
        defer block_stack.deinit(self.allocator);
        var current_exception: ?Value = null;

        var pc: usize = 0;
        while (true) {
            const instr = code.instructions.items[pc];
            if (self.verbose) try self.traceInstruction(code, pc, instr, stack.items);

            const outcome = self.executeInstruction(code, &stack, locals, &block_stack, &current_exception, pc, instr) catch |err| {
                if (block_stack.items.len == 0 or self.pending_exception == null) return err;
                const block = block_stack.pop().?;
                stack.shrinkRetainingCapacity(block.stack_depth);
                current_exception = self.pending_exception;
                self.pending_exception = null;
                pc = block.handler_pc;
                continue;
            };
            switch (outcome) {
                .next => |next_pc| pc = next_pc,
                .returned => |v| return v,
            }
        }
    }

    fn executeInstruction(
        self: *VM,
        code: *const CodeObject,
        stack: *std.ArrayList(Value),
        locals: *std.StringHashMap(Value),
        block_stack: *std.ArrayList(TryBlock),
        current_exception: *?Value,
        pc: usize,
        instr: bytecode.Instruction,
    ) anyerror!StepOutcome {
        const names = code.names.items;
        switch (instr.opcode) {
            .load_const => {
                try stack.append(self.allocator, code.consts.items[instr.arg.index]);
                return .{ .next = pc + 1 };
            },
            .load_name => {
                const v = try self.loadName(locals, names[instr.arg.index]);
                try stack.append(self.allocator, v);
                return .{ .next = pc + 1 };
            },
            .store_name => {
                const v = stack.pop().?;
                try locals.put(names[instr.arg.index], v);
                return .{ .next = pc + 1 };
            },
            .pop_top => {
                _ = stack.pop();
                return .{ .next = pc + 1 };
            },
            .unary_negative => {
                const v = stack.pop().?;
                const result = value_mod.negate(v) catch |err| return self.valueErrToVMError(err);
                try stack.append(self.allocator, result);
                return .{ .next = pc + 1 };
            },
            .unary_not => {
                const v = stack.pop().?;
                try stack.append(self.allocator, .{ .boolean = !value_mod.isTruthy(v) });
                return .{ .next = pc + 1 };
            },
            .binary_add => {
                const right = stack.pop().?;
                const left = stack.pop().?;
                if (left == .string and right == .string) {
                    const s = try std.mem.concat(self.allocator, u8, &.{ left.string, right.string });
                    try stack.append(self.allocator, .{ .string = s });
                } else {
                    const result = value_mod.add(left, right) catch |err| return self.valueErrToVMError(err);
                    try stack.append(self.allocator, result);
                }
                return .{ .next = pc + 1 };
            },
            .binary_subtract => {
                const right = stack.pop().?;
                const left = stack.pop().?;
                const result = value_mod.sub(left, right) catch |err| return self.valueErrToVMError(err);
                try stack.append(self.allocator, result);
                return .{ .next = pc + 1 };
            },
            .binary_multiply => {
                const right = stack.pop().?;
                const left = stack.pop().?;
                const result = value_mod.mul(left, right) catch |err| return self.valueErrToVMError(err);
                try stack.append(self.allocator, result);
                return .{ .next = pc + 1 };
            },
            .binary_true_divide => {
                const right = stack.pop().?;
                const left = stack.pop().?;
                const result = value_mod.trueDiv(left, right) catch |err| return self.valueErrToVMError(err);
                try stack.append(self.allocator, result);
                return .{ .next = pc + 1 };
            },
            .binary_floor_divide => {
                const right = stack.pop().?;
                const left = stack.pop().?;
                const result = value_mod.floorDiv(left, right) catch |err| return self.valueErrToVMError(err);
                try stack.append(self.allocator, result);
                return .{ .next = pc + 1 };
            },
            .binary_modulo => {
                const right = stack.pop().?;
                const left = stack.pop().?;
                const result = value_mod.mod(left, right) catch |err| return self.valueErrToVMError(err);
                try stack.append(self.allocator, result);
                return .{ .next = pc + 1 };
            },
            .compare_op => {
                const right = stack.pop().?;
                const left = stack.pop().?;
                const result = value_mod.compare(instr.arg.compare, left, right) catch |err| return self.valueErrToVMError(err);
                try stack.append(self.allocator, .{ .boolean = result });
                return .{ .next = pc + 1 };
            },
            .jump_forward => return .{ .next = instr.arg.index },
            .pop_jump_if_false => {
                const v = stack.pop().?;
                return .{ .next = if (!value_mod.isTruthy(v)) instr.arg.index else pc + 1 };
            },
            .jump_if_false_or_pop => {
                if (!value_mod.isTruthy(stack.items[stack.items.len - 1])) {
                    return .{ .next = instr.arg.index };
                }
                _ = stack.pop();
                return .{ .next = pc + 1 };
            },
            .jump_if_true_or_pop => {
                if (value_mod.isTruthy(stack.items[stack.items.len - 1])) {
                    return .{ .next = instr.arg.index };
                }
                _ = stack.pop();
                return .{ .next = pc + 1 };
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
                return .{ .next = pc + 1 };
            },
            .make_function => {
                try stack.append(self.allocator, code.consts.items[instr.arg.index]);
                return .{ .next = pc + 1 };
            },
            .return_value => return .{ .returned = stack.pop().? },
            .build_list => {
                const n = instr.arg.index;
                var items: std.ArrayList(Value) = .empty;
                var i: usize = 0;
                while (i < n) : (i += 1) try items.append(self.allocator, stack.pop().?);
                std.mem.reverse(Value, items.items);
                const list_obj = try self.allocator.create(value_mod.ListObj);
                list_obj.* = .{ .items = items };
                try stack.append(self.allocator, .{ .list = list_obj });
                return .{ .next = pc + 1 };
            },
            .build_tuple => {
                const n = instr.arg.index;
                var items: std.ArrayList(Value) = .empty;
                var i: usize = 0;
                while (i < n) : (i += 1) try items.append(self.allocator, stack.pop().?);
                std.mem.reverse(Value, items.items);
                const tuple_obj = try self.allocator.create(value_mod.TupleObj);
                tuple_obj.* = .{ .items = try items.toOwnedSlice(self.allocator) };
                try stack.append(self.allocator, .{ .tuple = tuple_obj });
                return .{ .next = pc + 1 };
            },
            .build_dict => {
                const n = instr.arg.index;
                var flat: std.ArrayList(Value) = .empty;
                var i: usize = 0;
                while (i < 2 * n) : (i += 1) try flat.append(self.allocator, stack.pop().?);
                std.mem.reverse(Value, flat.items);
                const dict_obj = try self.allocator.create(value_mod.DictObj);
                dict_obj.* = .{};
                var j: usize = 0;
                while (j < flat.items.len) : (j += 2) {
                    try dict_obj.entries.append(self.allocator, .{ .key = flat.items[j], .value = flat.items[j + 1] });
                }
                try stack.append(self.allocator, .{ .dict = dict_obj });
                return .{ .next = pc + 1 };
            },
            .binary_subscr => {
                const index_v = stack.pop().?;
                const obj_v = stack.pop().?;
                try stack.append(self.allocator, try self.subscriptGet(obj_v, index_v));
                return .{ .next = pc + 1 };
            },
            .store_subscr => {
                const index_v = stack.pop().?;
                const obj_v = stack.pop().?;
                const value_v = stack.pop().?;
                try self.subscriptSet(obj_v, index_v, value_v);
                return .{ .next = pc + 1 };
            },
            .get_iter => {
                const iterable = stack.pop().?;
                const items: []const Value = switch (iterable) {
                    .list => |l| l.items.items,
                    .tuple => |t| t.items,
                    .dict => |d| blk: {
                        const keys = try self.allocator.alloc(Value, d.entries.items.len);
                        for (d.entries.items, 0..) |e, i| keys[i] = e.key;
                        break :blk keys;
                    },
                    else => return self.fail("value is not iterable", .{}, VMError.NotIterable),
                };
                const iter_obj = try self.allocator.create(value_mod.IterObj);
                iter_obj.* = .{ .items = items };
                try stack.append(self.allocator, .{ .iterator = iter_obj });
                return .{ .next = pc + 1 };
            },
            .for_iter => {
                const iter_obj = stack.items[stack.items.len - 1].iterator;
                if (iter_obj.index < iter_obj.items.len) {
                    const item = iter_obj.items[iter_obj.index];
                    iter_obj.index += 1;
                    try stack.append(self.allocator, item);
                    return .{ .next = pc + 1 };
                }
                _ = stack.pop();
                return .{ .next = instr.arg.index };
            },
            .load_attr => {
                const obj_v = stack.pop().?;
                const result = try self.attrGet(obj_v, names[instr.arg.index]);
                try stack.append(self.allocator, result);
                return .{ .next = pc + 1 };
            },
            .store_attr => {
                const obj_v = stack.pop().?;
                const value_v = stack.pop().?;
                try self.attrSet(obj_v, names[instr.arg.index], value_v);
                return .{ .next = pc + 1 };
            },
            .make_class => {
                const base_v = stack.pop().?;
                const base: ?*value_mod.ClassObj = if (base_v == .class) base_v.class else null;
                const body_code = code.consts.items[instr.arg.index].function.code;
                var namespace = std.StringHashMap(Value).init(self.allocator);
                _ = try self.runFrame(body_code, &namespace);
                const class_obj = try self.allocator.create(value_mod.ClassObj);
                class_obj.* = .{ .name = body_code.name, .base = base, .namespace = namespace };
                try stack.append(self.allocator, .{ .class = class_obj });
                return .{ .next = pc + 1 };
            },
            .setup_try => {
                try block_stack.append(self.allocator, .{ .handler_pc = instr.arg.index, .stack_depth = stack.items.len });
                return .{ .next = pc + 1 };
            },
            .pop_block => {
                _ = block_stack.pop();
                return .{ .next = pc + 1 };
            },
            .match_exc => {
                const matched = blk: {
                    if (instr.arg == .none) break :blk true;
                    const exc_v = current_exception.* orelse break :blk false;
                    break :blk value_mod.exceptionMatches(exc_v.exception.kind, names[instr.arg.index]);
                };
                try stack.append(self.allocator, .{ .boolean = matched });
                return .{ .next = pc + 1 };
            },
            .store_exc => {
                if (current_exception.*) |exc_v| {
                    try locals.put(names[instr.arg.index], exc_v);
                }
                return .{ .next = pc + 1 };
            },
            .clear_exc => {
                current_exception.* = null;
                return .{ .next = pc + 1 };
            },
            .raise_exc => {
                const v = stack.pop().?;
                const exc: *value_mod.ExceptionObj = switch (v) {
                    .exception => |e| e,
                    else => blk: {
                        const e = try self.allocator.create(value_mod.ExceptionObj);
                        e.* = .{ .kind = .exception, .message = "exceptions must derive from BaseException" };
                        break :blk e;
                    },
                };
                self.pending_exception = .{ .exception = exc };
                return VMError.PyException;
            },
            .reraise => {
                if (current_exception.*) |exc_v| {
                    self.pending_exception = exc_v;
                    return VMError.PyException;
                }
                const e = try self.allocator.create(value_mod.ExceptionObj);
                e.* = .{ .kind = .runtime_error, .message = "No active exception to re-raise" };
                self.pending_exception = .{ .exception = e };
                return VMError.PyException;
            },
        }
    }
};

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

test "tuple literal and indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "t = (1, 2, 3)\na = t[0]\nb = t[-1]\nn = len(t)\n");
    try std.testing.expectEqual(@as(i64, 1), run.vm.globals.get("a").?.int);
    try std.testing.expectEqual(@as(i64, 3), run.vm.globals.get("b").?.int);
    try std.testing.expectEqual(@as(i64, 3), run.vm.globals.get("n").?.int);
}

test "tuple assignment raises a type error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = runSource(a, "t = (1, 2)\nt[0] = 5\n");
    try std.testing.expectError(VMError.TypeMismatch, result);
}

test "dict literal, indexing, and assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "d = {\"a\": 1, \"b\": 2}\nx = d[\"a\"]\nd[\"c\"] = 3\nn = len(d)\n",
    );
    try std.testing.expectEqual(@as(i64, 1), run.vm.globals.get("x").?.int);
    try std.testing.expectEqual(@as(i64, 3), run.vm.globals.get("n").?.int);
    const d = run.vm.globals.get("d").?.dict;
    try std.testing.expectEqual(@as(i64, 3), d.entries.items[2].value.int);
}

test "dict overwrites an existing key instead of duplicating it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "d = {\"a\": 1}\nd[\"a\"] = 99\nn = len(d)\n");
    try std.testing.expectEqual(@as(i64, 1), run.vm.globals.get("n").?.int);
    try std.testing.expectEqual(@as(i64, 99), run.vm.globals.get("d").?.dict.entries.items[0].value.int);
}

test "missing dict key is a diagnosable error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = runSource(a, "d = {\"a\": 1}\nx = d[\"missing\"]\n");
    try std.testing.expectError(VMError.KeyError, result);
}

test "for loop over a dict iterates its keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "d = {\"a\": 1, \"b\": 2, \"c\": 3}\ntotal = 0\nfor k in d:\n    total = total + d[k]\n",
    );
    try std.testing.expectEqual(@as(i64, 6), run.vm.globals.get("total").?.int);
}

test "spawning a non-function is a diagnosable error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = runSource(a, "w = spawn(5)\n");
    try std.testing.expectError(VMError.InvalidArgument, result);
}

test "class instance attributes and method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "class Point:\n    def __init__(self, x, y):\n        self.x = x\n        self.y = y\n" ++
            "    def sum(self):\n        return self.x + self.y\n" ++
            "p = Point(3, 4)\nresult = p.sum()\n",
    );
    const p = run.vm.globals.get("p").?.instance;
    try std.testing.expectEqual(@as(i64, 3), p.attrs.get("x").?.int);
    try std.testing.expectEqual(@as(i64, 4), p.attrs.get("y").?.int);
    try std.testing.expectEqual(@as(i64, 7), run.vm.globals.get("result").?.int);
}

test "class level attribute shared across instances" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "class Dog:\n    species = 'Canine'\n    def __init__(self, name):\n        self.name = name\n" ++
            "a = Dog('Rex')\nb = Dog('Fido')\ns1 = a.species\ns2 = b.species\n",
    );
    try std.testing.expectEqualStrings("Canine", run.vm.globals.get("s1").?.string);
    try std.testing.expectEqualStrings("Canine", run.vm.globals.get("s2").?.string);
}

test "inheritance method override and explicit base init call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "class Animal:\n    def __init__(self, name):\n        self.name = name\n        self.kind = 'animal'\n" ++
            "    def speak(self):\n        return self.name\n" ++
            "class Dog(Animal):\n    def __init__(self, name, breed):\n        Animal.__init__(self, name)\n        self.breed = breed\n" ++
            "    def speak(self):\n        return self.breed\n" ++
            "class Cat(Animal):\n    x = 1\n" ++
            "d = Dog('Rex', 'Labrador')\nc = Cat('Tom')\nr1 = d.speak()\nr2 = c.speak()\n",
    );
    try std.testing.expectEqualStrings("Labrador", run.vm.globals.get("r1").?.string);
    try std.testing.expectEqualStrings("Tom", run.vm.globals.get("r2").?.string);
    const d = run.vm.globals.get("d").?.instance;
    try std.testing.expectEqualStrings("animal", d.attrs.get("kind").?.string);
    try std.testing.expectEqualStrings("Labrador", d.attrs.get("breed").?.string);
}

test "missing attribute is a diagnosable error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = runSource(a, "class Foo:\n    x = 1\nf = Foo()\ny = f.missing\n");
    try std.testing.expectError(VMError.AttributeError, result);
}

test "try except catches matching type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "result = 'not set'\ntry:\n    x = 1 / 0\nexcept ZeroDivisionError:\n    result = 'caught'\n",
    );
    try std.testing.expectEqualStrings("caught", run.vm.globals.get("result").?.string);
}

test "try except wrong type propagates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = runSource(a, "try:\n    x = 1 / 0\nexcept ValueError:\n    x = 0\n");
    try std.testing.expectError(VMError.PyException, result);
}

test "try multiple handlers first match wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "result = None\ntry:\n    raise TypeError('bad')\nexcept ValueError:\n    result = 'value'\n" ++
            "except TypeError:\n    result = 'type'\nexcept Exception:\n    result = 'generic'\n",
    );
    try std.testing.expectEqualStrings("type", run.vm.globals.get("result").?.string);
}

test "except as binds exception instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "msg = None\ntry:\n    raise ValueError('bad value')\nexcept ValueError as e:\n    msg = e\n",
    );
    try std.testing.expectEqualStrings("bad value", run.vm.globals.get("msg").?.exception.message);
}

test "finally runs on success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "log = []\ntry:\n    append(log, 'body')\nfinally:\n    append(log, 'finally')\n");
    const items = run.vm.globals.get("log").?.list.items.items;
    try std.testing.expectEqualStrings("body", items[0].string);
    try std.testing.expectEqualStrings("finally", items[1].string);
}

test "finally runs after handled exception" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "log = []\ntry:\n    append(log, 'body')\n    raise ValueError('x')\n" ++
            "except ValueError:\n    append(log, 'except')\nfinally:\n    append(log, 'finally')\n",
    );
    const items = run.vm.globals.get("log").?.list.items.items;
    try std.testing.expectEqualStrings("body", items[0].string);
    try std.testing.expectEqualStrings("except", items[1].string);
    try std.testing.expectEqualStrings("finally", items[2].string);
}

test "bare raise reraises inside except" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = runSource(a, "try:\n    raise ValueError('x')\nexcept ValueError:\n    raise\n");
    try std.testing.expectError(VMError.PyException, result);
}

test "exception from called function caught by caller" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "def boom():\n    return 1 / 0\nresult = None\ntry:\n    boom()\nexcept ZeroDivisionError:\n    result = 'caught'\n",
    );
    try std.testing.expectEqualStrings("caught", run.vm.globals.get("result").?.string);
}

test "nested try inner reraise caught by outer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "log = []\ntry:\n    try:\n        raise ValueError('inner')\n    except ValueError:\n" ++
            "        append(log, 'inner')\n        raise\nexcept ValueError:\n    append(log, 'outer')\n",
    );
    const items = run.vm.globals.get("log").?.list.items.items;
    try std.testing.expectEqualStrings("inner", items[0].string);
    try std.testing.expectEqualStrings("outer", items[1].string);
}

test "bare except catches anything" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(a, "caught = False\ntry:\n    raise TypeError('x')\nexcept:\n    caught = True\n");
    try std.testing.expectEqual(true, run.vm.globals.get("caught").?.boolean);
}

test "arithmetic error catches zero division error via parent kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var run = try runSource(
        a,
        "caught = False\ntry:\n    x = 1 / 0\nexcept ArithmeticError:\n    caught = True\n",
    );
    try std.testing.expectEqual(true, run.vm.globals.get("caught").?.boolean);
}
