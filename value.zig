const std = @import("std");
const bytecode = @import("bytecode.zig");
const ast = @import("ast.zig");

pub const BuiltinFn = *const fn (vm: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value;

pub const ListObj = struct {
    items: std.ArrayList(Value) = .empty,
};

/// Internal-only: what GET_ITER/FOR_ITER push/mutate on the value stack.
/// Never directly producible by interpreted syntax.
pub const IterObj = struct {
    list: *ListObj,
    index: usize = 0,
};

pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    none: void,
    string: []const u8,
    function: *bytecode.PyFunction,
    builtin: BuiltinFn,
    list: *ListObj,
    iterator: *IterObj,
    worker: *anyopaque,
};

pub fn isTruthy(v: Value) bool {
    return switch (v) {
        .int => |i| i != 0,
        .float => |f| f != 0.0,
        .boolean => |b| b,
        .none => false,
        .string => |s| s.len != 0,
        .list => |l| l.items.items.len != 0,
        .function, .builtin, .worker, .iterator => true,
    };
}

/// Numeric value as f64 for a value that participates in arithmetic, or
/// null if it isn't numeric (bools count as ints, same as Python).
fn asFloat(v: Value) ?f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        .boolean => |b| if (b) @as(f64, 1) else @as(f64, 0),
        else => null,
    };
}

fn asInt(v: Value) ?i64 {
    return switch (v) {
        .int => |i| i,
        .boolean => |b| if (b) @as(i64, 1) else @as(i64, 0),
        else => null,
    };
}

pub const ValueError = error{
    TypeMismatch,
    DivisionByZero,
};

/// true if both operands are int-or-bool (so the op should stay integral);
/// false if either is a float (so the op should promote to float).
fn bothIntegral(a: Value, b: Value) bool {
    const a_int = a == .int or a == .boolean;
    const b_int = b == .int or b == .boolean;
    return a_int and b_int;
}

pub fn add(left: Value, right: Value) ValueError!Value {
    if (left == .string and right == .string) {
        return ValueError.TypeMismatch; // string concat needs an allocator -- compiler.zig/vm.zig handles it directly
    }
    if (bothIntegral(left, right)) {
        return .{ .int = asInt(left).? +% asInt(right).? };
    }
    const a = asFloat(left) orelse return ValueError.TypeMismatch;
    const b = asFloat(right) orelse return ValueError.TypeMismatch;
    return .{ .float = a + b };
}

pub fn sub(left: Value, right: Value) ValueError!Value {
    if (bothIntegral(left, right)) {
        return .{ .int = asInt(left).? -% asInt(right).? };
    }
    const a = asFloat(left) orelse return ValueError.TypeMismatch;
    const b = asFloat(right) orelse return ValueError.TypeMismatch;
    return .{ .float = a - b };
}

pub fn mul(left: Value, right: Value) ValueError!Value {
    if (bothIntegral(left, right)) {
        return .{ .int = asInt(left).? *% asInt(right).? };
    }
    const a = asFloat(left) orelse return ValueError.TypeMismatch;
    const b = asFloat(right) orelse return ValueError.TypeMismatch;
    return .{ .float = a * b };
}

/// True division always yields a float, matching Python's `/`.
pub fn trueDiv(left: Value, right: Value) ValueError!Value {
    const a = asFloat(left) orelse return ValueError.TypeMismatch;
    const b = asFloat(right) orelse return ValueError.TypeMismatch;
    if (b == 0) return ValueError.DivisionByZero;
    return .{ .float = a / b };
}

pub fn floorDiv(left: Value, right: Value) ValueError!Value {
    if (bothIntegral(left, right)) {
        const b = asInt(right).?;
        if (b == 0) return ValueError.DivisionByZero;
        return .{ .int = @divFloor(asInt(left).?, b) };
    }
    const a = asFloat(left) orelse return ValueError.TypeMismatch;
    const b = asFloat(right) orelse return ValueError.TypeMismatch;
    if (b == 0) return ValueError.DivisionByZero;
    return .{ .float = @floor(a / b) };
}

pub fn mod(left: Value, right: Value) ValueError!Value {
    if (bothIntegral(left, right)) {
        const b = asInt(right).?;
        if (b == 0) return ValueError.DivisionByZero;
        return .{ .int = @mod(asInt(left).?, b) };
    }
    const a = asFloat(left) orelse return ValueError.TypeMismatch;
    const b = asFloat(right) orelse return ValueError.TypeMismatch;
    if (b == 0) return ValueError.DivisionByZero;
    return .{ .float = @mod(a, b) };
}

pub fn negate(v: Value) ValueError!Value {
    return switch (v) {
        .int => |i| .{ .int = -i },
        .float => |f| .{ .float = -f },
        .boolean => |b| .{ .int = if (b) -1 else 0 },
        else => ValueError.TypeMismatch,
    };
}

const Ordering = enum { lt, eq, gt, unordered };

fn compareOrdering(left: Value, right: Value) ValueError!Ordering {
    if (left == .string and right == .string) {
        const order = std.mem.order(u8, left.string, right.string);
        return switch (order) {
            .lt => .lt,
            .eq => .eq,
            .gt => .gt,
        };
    }
    const a = asFloat(left) orelse return ValueError.TypeMismatch;
    const b = asFloat(right) orelse return ValueError.TypeMismatch;
    if (a < b) return .lt;
    if (a > b) return .gt;
    if (a == b) return .eq;
    return .unordered; // NaN
}

pub fn compare(op: ast.CompareOpKind, left: Value, right: Value) ValueError!bool {
    const order = try compareOrdering(left, right);
    return switch (op) {
        .eq => order == .eq,
        .ne => order != .eq,
        .lt => order == .lt,
        .gt => order == .gt,
        .le => order == .lt or order == .eq,
        .ge => order == .gt or order == .eq,
    };
}

pub fn format(v: Value, writer: anytype) !void {
    switch (v) {
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .boolean => |b| try writer.print("{s}", .{if (b) "True" else "False"}),
        .none => try writer.print("None", .{}),
        .string => |s| try writer.print("{s}", .{s}),
        .function => |f| try writer.print("<function {s}>", .{f.code.name}),
        .builtin => try writer.print("<builtin function>", .{}),
        .worker => |w| try writer.print("<worker at 0x{x}>", .{@intFromPtr(w)}),
        .iterator => try writer.print("<iterator>", .{}),
        .list => |l| {
            try writer.print("[", .{});
            for (l.items.items, 0..) |item, i| {
                if (i != 0) try writer.print(", ", .{});
                try format(item, writer);
            }
            try writer.print("]", .{});
        },
    }
}

pub const Message = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    none: void,
    string: []u8,
};

pub const MessageError = error{NotSendable};

pub fn valueToMessage(v: Value) (MessageError || std.mem.Allocator.Error)!Message {
    return switch (v) {
        .int => |x| .{ .int = x },
        .float => |x| .{ .float = x },
        .boolean => |x| .{ .boolean = x },
        .none => .{ .none = {} },
        .string => |s| .{ .string = try std.heap.smp_allocator.dupe(u8, s) },
        .function, .builtin, .worker, .list, .iterator => MessageError.NotSendable,
    };
}

pub fn messageToValue(allocator: std.mem.Allocator, msg: Message) !Value {
    return switch (msg) {
        .int => |x| .{ .int = x },
        .float => |x| .{ .float = x },
        .boolean => |x| .{ .boolean = x },
        .none => .{ .none = {} },
        .string => |s| blk: {
            const copy = try allocator.dupe(u8, s);
            std.heap.smp_allocator.free(s);
            break :blk .{ .string = copy };
        },
    };
}
