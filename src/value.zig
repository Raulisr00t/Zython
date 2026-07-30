const std = @import("std");
const bytecode = @import("bytecode.zig");
const ast = @import("ast.zig");

pub const BuiltinFn = *const fn (vm: *anyopaque, allocator: std.mem.Allocator, args: []const Value) anyerror!Value;

pub const ListObj = struct {
    items: std.ArrayList(Value) = .empty,
};

pub const TupleObj = struct {
    items: []const Value,
};

pub const DictEntry = struct {
    key: Value,
    value: Value,
};

pub const DictObj = struct {
    entries: std.ArrayList(DictEntry) = .empty,
};

pub const IterObj = struct {
    items: []const Value,
    index: usize = 0,
};

pub const ClassObj = struct {
    name: []const u8,
    base: ?*ClassObj,
    namespace: std.StringHashMap(Value),
};

pub const InstanceObj = struct {
    class: *ClassObj,
    attrs: std.StringHashMap(Value),
};

pub const BoundMethodObj = struct {
    function: *bytecode.PyFunction,
    instance: *InstanceObj,
};

pub fn findClassAttr(class: *ClassObj, name: []const u8) ?Value {
    if (class.namespace.get(name)) |v| return v;
    if (class.base) |b| return findClassAttr(b, name);
    return null;
}

pub const ExceptionKind = enum {
    exception,
    arithmetic_error,
    zero_division_error,
    lookup_error,
    index_error,
    key_error,
    value_error,
    type_error,
    name_error,
    attribute_error,
    runtime_error,
};

pub const ExceptionObj = struct {
    kind: ExceptionKind,
    message: []const u8,
};

pub fn exceptionKindName(kind: ExceptionKind) []const u8 {
    return switch (kind) {
        .exception => "Exception",
        .arithmetic_error => "ArithmeticError",
        .zero_division_error => "ZeroDivisionError",
        .lookup_error => "LookupError",
        .index_error => "IndexError",
        .key_error => "KeyError",
        .value_error => "ValueError",
        .type_error => "TypeError",
        .name_error => "NameError",
        .attribute_error => "AttributeError",
        .runtime_error => "RuntimeError",
    };
}

fn exceptionParent(kind: ExceptionKind) ?ExceptionKind {
    return switch (kind) {
        .exception => null,
        .zero_division_error => .arithmetic_error,
        .arithmetic_error => .exception,
        .index_error, .key_error => .lookup_error,
        .lookup_error => .exception,
        .value_error, .type_error, .name_error, .attribute_error, .runtime_error => .exception,
    };
}

pub fn exceptionMatches(kind: ExceptionKind, target_name: []const u8) bool {
    var current: ?ExceptionKind = kind;
    while (current) |k| {
        if (std.mem.eql(u8, exceptionKindName(k), target_name)) return true;
        current = exceptionParent(k);
    }
    return false;
}

pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    none: void,
    string: []const u8,
    function: *bytecode.PyFunction,
    builtin: BuiltinFn,
    list: *ListObj,
    tuple: *TupleObj,
    dict: *DictObj,
    iterator: *IterObj,
    class: *ClassObj,
    instance: *InstanceObj,
    bound_method: *BoundMethodObj,
    exception: *ExceptionObj,

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
        .tuple => |t| t.items.len != 0,
        .dict => |d| d.entries.items.len != 0,
        .function, .builtin, .worker, .iterator, .class, .instance, .bound_method, .exception => true,
    };
}

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

fn bothIntegral(a: Value, b: Value) bool {
    const a_int = a == .int or a == .boolean;
    const b_int = b == .int or b == .boolean;
    return a_int and b_int;
}

pub fn add(left: Value, right: Value) ValueError!Value {
    if (left == .string and right == .string) {
        return ValueError.TypeMismatch;
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
    return .unordered;
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

pub fn valuesEqual(a: Value, b: Value) bool {
    const order = compareOrdering(a, b) catch return false;
    return order == .eq;
}

pub fn format(v: Value, writer: anytype) !void {
    return formatValue(v, writer, false);
}

fn formatValue(v: Value, writer: anytype, quoted: bool) !void {
    switch (v) {
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .boolean => |b| try writer.print("{s}", .{if (b) "True" else "False"}),
        .none => try writer.print("None", .{}),
        .string => |s| {
            if (quoted) {
                try writer.print("'{s}'", .{s});
            } else {
                try writer.print("{s}", .{s});
            }
        },
        .function => |f| try writer.print("<function {s}>", .{f.code.name}),
        .builtin => try writer.print("<builtin function>", .{}),
        .worker => |w| try writer.print("<worker at 0x{x}>", .{@intFromPtr(w)}),
        .iterator => try writer.print("<iterator>", .{}),
        .class => |c| try writer.print("<class '{s}'>", .{c.name}),
        .instance => |i| try writer.print("<{s} object at 0x{x}>", .{ i.class.name, @intFromPtr(i) }),
        .bound_method => |bm| try writer.print("<bound method {s}>", .{bm.function.code.name}),
        .exception => |e| try writer.print("{s}", .{e.message}),
        .list => |l| {
            try writer.print("[", .{});
            for (l.items.items, 0..) |item, i| {
                if (i != 0) try writer.print(", ", .{});
                try formatValue(item, writer, true);
            }
            try writer.print("]", .{});
        },
        .tuple => |t| {
            try writer.print("(", .{});
            for (t.items, 0..) |item, i| {
                if (i != 0) try writer.print(", ", .{});
                try formatValue(item, writer, true);
            }
            if (t.items.len == 1) try writer.print(",", .{});
            try writer.print(")", .{});
        },
        .dict => |d| {
            try writer.print("{{", .{});
            for (d.entries.items, 0..) |e, i| {
                if (i != 0) try writer.print(", ", .{});
                try formatValue(e.key, writer, true);
                try writer.print(": ", .{});
                try formatValue(e.value, writer, true);
            }
            try writer.print("}}", .{});
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
        .function, .builtin, .worker, .list, .tuple, .dict, .iterator, .class, .instance, .bound_method, .exception => MessageError.NotSendable,
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
