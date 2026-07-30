//! AST node definitions. Ports pyinterp/ast_nodes.py for the same initial
//! subset (literals, arithmetic/comparison/boolean expressions, assignment,
//! if/elif/else, while, function def/return) -- lists/dicts/for/class/try
//! land later (mirrors pyinterp/tests/test_parser.py's own history).
//!
//! `Node` is a tagged union; child nodes are `*const Node` (arena-allocated
//! by the parser, never individually freed -- see parser.zig).

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
    orelse_body: []const *Node, // elif is desugared into a nested If in here, same as Phase 1
};

pub const While = struct {
    cond: *Node,
    body: []const *Node,
};

pub const Assign = struct {
    target: *Node, // .name in this subset (Subscript/Attribute targets land with M4/M5)
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

pub const Subscript = struct {
    obj: *Node,
    index: *Node,
};

pub const For = struct {
    target: []const u8,
    iter: *Node,
    body: []const *Node,
};

pub const Node = union(enum) {
    // statements
    module: Module,
    function_def: FunctionDef,
    return_stmt: Return,
    if_stmt: If,
    while_stmt: While,
    for_stmt: For,
    assign: Assign,
    aug_assign: AugAssign,
    expr_stmt: ExprStmt,

    // expressions
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
    subscript: Subscript,
};
