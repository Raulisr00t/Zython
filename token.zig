const std = @import("std");

pub const TokenType = enum {
    number,
    string,
    name,

    // keywords
    kw_def,
    kw_return,
    kw_if,
    kw_elif,
    kw_else,
    kw_while,
    kw_true,
    kw_false,
    kw_none,
    kw_and,
    kw_or,
    kw_not,
    kw_for,
    kw_in,
    kw_class,
    kw_try,
    kw_except,
    kw_finally,
    kw_raise,
    kw_as,

    // operators / punctuation
    plus,
    minus,
    star,
    slash,
    doubleslash,
    percent,
    eq,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    eqeq,
    noteq,
    lt,
    gt,
    le,
    ge,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    colon,
    comma,
    dot,

    // structure
    newline,
    indent,
    dedent,
    endmarker,
};

/// keyword text -> TokenType, checked after scanning a NAME-shaped lexeme.
pub const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "def", .kw_def },
    .{ "return", .kw_return },
    .{ "if", .kw_if },
    .{ "elif", .kw_elif },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "True", .kw_true },
    .{ "False", .kw_false },
    .{ "None", .kw_none },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "not", .kw_not },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "class", .kw_class },
    .{ "try", .kw_try },
    .{ "except", .kw_except },
    .{ "finally", .kw_finally },
    .{ "raise", .kw_raise },
    .{ "as", .kw_as },
});

/// Mirrors Python's `Token.value: object`: NUMBER carries an int or float,
/// STRING carries the decoded (escapes-resolved) text, everything else
/// carries its lexeme (mostly useful for error messages/debugging).
pub const TokenValue = union(enum) {
    none: void,
    int: i64,
    float: f64,
    text: []const u8,
};

pub const Token = struct {
    type: TokenType,
    value: TokenValue,
    line: usize,
    col: usize,
};
