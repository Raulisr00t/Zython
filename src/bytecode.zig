const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const ast = @import("ast.zig");

pub const Opcode = enum {
    load_const,
    load_name,
    store_name,
    pop_top,

    unary_negative,
    unary_not,

    binary_add,
    binary_subtract,
    binary_multiply,
    binary_true_divide,
    binary_floor_divide,
    binary_modulo,

    compare_op,

    jump_forward,
    pop_jump_if_false,
    jump_if_false_or_pop,
    jump_if_true_or_pop,

    call_function,
    make_function,
    return_value,

    build_list,
    build_tuple,
    build_dict,
    binary_subscr,
    store_subscr,

    get_iter,
    for_iter,

    load_attr,
    store_attr,
    make_class,

    setup_try,
    pop_block,
    match_exc,
    store_exc,
    clear_exc,
    raise_exc,
    reraise,
};

pub const InstrArg = union(enum) {
    none: void,
    index: usize,
    compare: ast.CompareOpKind,
};

pub const Instruction = struct {
    opcode: Opcode,
    arg: InstrArg = .{ .none = {} },
    line: usize = 0,
};

pub const PyFunction = struct {
    code: *const CodeObject,
};

pub const CodeObject = struct {
    name: []const u8,
    params: []const []const u8 = &.{},
    consts: std.ArrayList(Value) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    instructions: std.ArrayList(Instruction) = .empty,

    pub fn addConst(self: *CodeObject, allocator: std.mem.Allocator, v: Value) !usize {
        for (self.consts.items, 0..) |existing, i| {
            if (valueEql(existing, v)) return i;
        }
        try self.consts.append(allocator, v);
        return self.consts.items.len - 1;
    }

    pub fn addConstNoDedup(self: *CodeObject, allocator: std.mem.Allocator, v: Value) !usize {
        try self.consts.append(allocator, v);
        return self.consts.items.len - 1;
    }

    pub fn addName(self: *CodeObject, allocator: std.mem.Allocator, name: []const u8) !usize {
        for (self.names.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, name)) return i;
        }
        try self.names.append(allocator, name);
        return self.names.items.len - 1;
    }

    pub fn emit(self: *CodeObject, allocator: std.mem.Allocator, opcode: Opcode, arg: InstrArg) !usize {
        try self.instructions.append(allocator, .{ .opcode = opcode, .arg = arg });
        return self.instructions.items.len - 1;
    }

    pub fn here(self: *const CodeObject) usize {
        return self.instructions.items.len;
    }
};

fn valueEql(a: Value, b: Value) bool {
    return switch (a) {
        .int => |x| b == .int and b.int == x,
        .float => |x| b == .float and b.float == x,
        .boolean => |x| b == .boolean and b.boolean == x,
        .none => b == .none,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .function, .builtin, .worker, .list, .tuple, .dict, .iterator, .class, .instance, .bound_method, .exception => false,
    };
}
