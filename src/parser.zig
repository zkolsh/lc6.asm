const std = @import("std");
const isa = @import("isa.zig");

pub const ParseError = error {
    InvalidCharacter,
    InvalidEnumeration,
    NoMatch,
    NumericOverflow,
    UnexpectedEOF,
    UnexpectedToken,
    UnexpectedWhitespace,
    UnterminatedString,
};

fn isIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub const Parser = struct {
    input: []const u8,
    pos: usize = 0,

    pub fn eof(self: *Parser) bool {
        return self.pos >= self.input.len;
    }

    pub fn peek(self: *Parser) ?u8 {
        if (self.eof()) return null;
        return self.input[self.pos];
    }

    pub fn char(self: *Parser, expected: u8) ParseError!void {
        if (self.eof()) return ParseError.UnexpectedEOF;
        if (self.input[self.pos] != expected) return ParseError.NoMatch;
        self.pos += 1;
    }

    pub fn takeWhile(self: *Parser, comptime pred: fn (u8) bool) []const u8 {
        const start = self.pos;

        while (self.pos < self.input.len) {
            if (!pred(self.input[self.pos])) {
                break;
            }

            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    pub fn newline(self: *Parser) ParseError!void {
        const start = self.pos;
        errdefer self.pos = start;
        _ = self.tabulation();
        if (self.eof()) return;
        if (self.peek() == '/') {
            try self.char('/');
            try self.char('/');
            while (!self.eof()) {
                if (self.input[self.pos] == '\n') break;
                self.pos += 1;
            }
        }
        self.char('\r') catch {};
        try self.char('\n');
    }

    pub fn isNewline(self: *Parser) bool {
        const start = self.pos;
        defer self.pos = start;
        self.newline() catch return false;
        return true;
    }

    pub fn tabulation(self: *Parser) u32 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] != ' ' and self.input[self.pos] != '\t') {
                break;
            }

            self.pos += 1;
        }

        return @truncate(self.pos - start);
    }

    pub fn tabulation1(self: *Parser) ParseError!u32 {
        const start = self.pos;
        errdefer self.pos = start;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] != ' ' and self.input[self.pos] != '\t') {
                break;
            }

            self.pos += 1;
        }

        if (self.pos - start == 0) return ParseError.NoMatch;
        return @truncate(self.pos - start);
    }

    pub fn whitespace(self: *Parser) u32 {
        return @truncate(self.takeWhile(std.ascii.isWhitespace).len);
    }

    pub fn whitespace1(self: *Parser) ParseError!u32 {
        const ws = self.whitespace();
        if (ws == 0) return ParseError.NoMatch;
        return ws;
    }

    pub fn alphabetic(self: *Parser) []const u8 {
        const xs = self.takeWhile(std.ascii.isAlphabetic);
        return xs;
    }

    pub fn alphabetic1(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        const xs = self.takeWhile(std.ascii.isAlphabetic);
        errdefer self.pos = start;
        if (xs.len == 0) return ParseError.UnexpectedToken;
        return xs;
    }

    pub fn alphanumeric(self: *Parser) []const u8 {
        const xs = self.takeWhile(std.ascii.isAlphanumeric);
        return xs;
    }

    pub fn alphanumeric1(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        const xs = self.takeWhile(std.ascii.isAlphanumeric);
        errdefer self.pos = start;
        if (xs.len == 0) return ParseError.UnexpectedToken;
        return xs;
    }

    pub fn identifier(self: *Parser) []const u8 {
        const xs = self.takeWhile(isIdentifierChar);
        return xs;
    }

    pub fn identifier1(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        const xs = self.takeWhile(isIdentifierChar);
        errdefer self.pos = start;
        if (xs.len == 0) return ParseError.UnexpectedToken;
        if (!std.ascii.isAlphabetic(xs[0])) return ParseError.NoMatch;
        return xs;
    }

    fn parseRawInteger(self: *Parser, comptime T: type, comptime base: u8) ParseError!T {
        const start = self.pos;
        var n: T = 0;

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            const digit = std.fmt.charToDigit(c, base) catch break;
            
            n = std.math.mul(T, n, base) catch return ParseError.NumericOverflow;
            n = std.math.add(T, n, @intCast(digit)) catch return ParseError.NumericOverflow;
            
            self.pos += 1;
        }

        if (self.pos == start) {
            return ParseError.NoMatch;
        }

        return n;
    }

    pub fn parseInteger(self: *Parser, comptime T: type) ParseError!T {
        const start = self.pos;
        errdefer self.pos = start;

        var negative = false;
        if (self.peek()) |c| {
            if (c == '-') {
                negative = true;
                self.pos += 1;
            } else if (c == '+') {
                self.pos += 1;
            }
        }

        const x: T = blk: {
            if (self.peek() == '0') {
                self.pos += 1;
                if (self.peek() == 'x') {
                    self.pos += 1;
                    break :blk try self.parseRawInteger(T, 16);
                } else if (self.peek() == 'b') {
                    self.pos += 1;
                    break :blk try self.parseRawInteger(T, 2);
                } else {
                    self.pos -= 1;
                    break :blk try self.parseRawInteger(T, 10);
                }
            }

            break :blk try self.parseRawInteger(T, 10);
        };

        if (negative) {
            return std.math.negate(x) catch return ParseError.NumericOverflow;
        } else {
            return x;
        }
    }

    pub fn parseSectionLabel(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        errdefer self.pos = start;

        try self.char('.');
        const name = try self.identifier1();
        try self.newline();
        return name;
    }

    pub fn parseLabel(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        errdefer self.pos = start;

        const name = try self.identifier1();
        try self.char(':');
        return name;
    }

    pub fn parseRegisterName(self: *Parser) ParseError!isa.Register {
        const start = self.pos;
        errdefer self.pos = start;

        try self.char('$');
        const reg = try self.alphanumeric1();
        return std.meta.stringToEnum(isa.Register, reg) orelse {
            return ParseError.InvalidEnumeration;
        };
    }

    pub fn parseDataDirective(self: *Parser) ParseError!isa.DataDirective {
        const start = self.pos;
        errdefer self.pos = start;

        try self.char('.');
        const dir = try self.identifier1();
        return std.meta.stringToEnum(isa.DataDirective, dir) orelse {
            return ParseError.InvalidEnumeration;
        };
    }

    pub fn parseStringLiteral(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        errdefer self.pos = start;

        try self.char('"');
        while (self.peek()) |c| {
            self.pos += 1;

            if (c == '\\') {
                self.newline() catch {};
                continue;
            } else if (c == '\n') {
                return ParseError.UnterminatedString;
            }

            if (c == '"') {
                return self.input[start + 1..self.pos - 1];
            }
        }

        return ParseError.UnexpectedEOF;
    }
};

test "binary" {
    const input = "0b0001001110101";
    var parser = Parser{.input = input, .pos = 0};
    const res: u32 = try Parser.parseInteger(&parser, u32);
    try std.testing.expectEqual(0b0001001110101, res);
}

test "hex" {
    const input = "0xCAFEbabe";
    var parser = Parser{.input = input, .pos = 0};
    const res: u32 = try Parser.parseInteger(&parser, u32);
    try std.testing.expectEqual(0xCAFEbabe, res);
}

test "decimal" {
    const input = "-17623";
    var parser = Parser{.input = input, .pos = 0};
    const res: i32 = try Parser.parseInteger(&parser, i32);
    try std.testing.expectEqual(-17623, res);
}

test "integer" {
    const input = "0xdeadbeef";
    var parser = Parser{.input = input, .pos = 0};
    const res: u32 = try Parser.parseInteger(&parser, u32);
    try std.testing.expectEqual(0xdeadbeef, res);
}

test "register" {
    const input = "$t0";
    var parser = Parser{.input = input, .pos = 0};
    const res = try Parser.parseRegisterName(&parser);
    try std.testing.expectEqual(isa.Register.t0, res);
}

test "string literal" {
    const input = "\"wawa\"";
    var parser = Parser{.input = input, .pos = 0};
    const res = try Parser.parseStringLiteral(&parser);
    try std.testing.expectEqualStrings("wawa", res);
}

test "integer backtracking" {
    const input = "0 q"; 
    var parser = Parser{ .input = input };
    const res = try parser.parseInteger(u32);
    try std.testing.expectEqual(@as(u32, 0), res);
    try std.testing.expectEqual(@as(u8, ' '), parser.peek().?);
}

test "whitespace" {
    const input = "   \t  $t0";
    var parser = Parser{ .input = input };
    _ = parser.whitespace();
    const reg = try parser.parseRegisterName();
    try std.testing.expectEqual(isa.Register.t0, reg);
}
