const std = @import("std");

pub const BinOpKind = enum { add, sub, mul, div, floordiv, mod };
pub const UnaryOpKind = enum { neg, not_ };
pub const BoolOpKind = enum { and_, or_ };
pub const CompareOpKind = enum { eq, ne, lt, gt, le, ge };

pub const Module = struct {
    body: []const *Node,
};

pub const FunctionDef = struct {
    name: []const u8,
    params: []const []const u8,
    body: []const *Node,
};

pub const Return = struct {
    value: ?*Node,
};

pub const If = struct {
    cond: *Node,
    body: []const *Node,
    orelse_body: []const *Node,
};

pub const While = struct {
    cond: *Node,
    body: []const *Node,
};

pub const Assign = struct {
    target: *Node,
    value: *Node,
};

pub const AugAssign = struct {
    target: *Node,
    op: BinOpKind,
    value: *Node,
};

pub const ExprStmt = struct {
    value: *Node,
};

pub const BinOp = struct {
    left: *Node,
    op: BinOpKind,
    right: *Node,
};

pub const UnaryOp = struct {
    op: UnaryOpKind,
    operand: *Node,
};

pub const BoolOp = struct {
    op: BoolOpKind,
    values: []const *Node,
};

pub const Compare = struct {
    left: *Node,
    op: CompareOpKind,
    right: *Node,
};

pub const Call = struct {
    func: *Node,
    args: []const *Node,
};

pub const ListLit = struct {
    elements: []const *Node,
};

pub const TupleLit = struct {
    elements: []const *Node,
};

pub const DictLit = struct {
    keys: []const *Node,
    values: []const *Node,
};

pub const Subscript = struct {
    obj: *Node,
    index: *Node,
};

pub const For = struct {
    target: []const u8,
    iter: *Node,
    body: []const *Node,
};

pub const Attribute = struct {
    obj: *Node,
    attr: []const u8,
};

pub const ClassDef = struct {
    name: []const u8,
    base: ?[]const u8,
    body: []const *Node,
};

pub const ExceptHandler = struct {
    exc_type: ?[]const u8,
    name: ?[]const u8,
    body: []const *Node,
};

pub const Try = struct {
    body: []const *Node,
    handlers: []const ExceptHandler,
    finally_body: []const *Node,
};

pub const Raise = struct {
    exc: ?*Node,
};

pub const Node = union(enum) {

    module: Module,
    function_def: FunctionDef,
    return_stmt: Return,
    if_stmt: If,
    while_stmt: While,
    for_stmt: For,
    class_def: ClassDef,
    try_stmt: Try,
    raise_stmt: Raise,
    assign: Assign,
    aug_assign: AugAssign,
    expr_stmt: ExprStmt,

    num_int: i64,
    num_float: f64,
    str: []const u8,
    bool_lit: bool,
    none_lit: void,
    name: []const u8,
    bin_op: BinOp,
    unary_op: UnaryOp,
    bool_op: BoolOp,
    compare: Compare,
    call: Call,
    list_lit: ListLit,
    tuple_lit: TupleLit,
    dict_lit: DictLit,
    subscript: Subscript,
    attribute: Attribute,
};
