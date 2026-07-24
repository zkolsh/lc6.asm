const std = @import("std");
const isa = @import("isa.zig");
const lex = @import("tokenizer.zig");

const Tokenizer = lex.Tokenizer;

pub const ParseError = error {
    InvalidEnumeration,
    NoMatch,
    NumericOverflow,
    UnexpectedToken,
} || lex.LexerError;

pub fn Immediate(comptime T: type) type {
    return union(enum) {
        static: T,
        dynamic: []const u8,
    };
}

pub const RType = struct {
    funct: isa.RType,
    rs: isa.Register,
    rt: isa.Register,
    rd: isa.Register,
    aux: Immediate(u6),
};

pub const IType = struct {
    opcode: isa.InstructionName,
    rs: isa.Register,
    rt: isa.Register,
    imm: Immediate(u17),
};

pub const LType = struct {
    opcode: isa.InstructionName,
    rs: isa.Register,
    rt: isa.Register,
    imm: Immediate(u16),
};

pub const JType = struct {
    opcode: isa.InstructionName,
    imm: Immediate(u27),
};

const Instruction = union(enum) {
    rtype: RType,
    itype: IType,
    ltype: LType,
    jtype: JType,
};

const Padding = struct {
    size: usize,
    alignment: usize,
};

const Directive = union(enum) {
    section: []const u8,
    bytes: []const u8,
    shorts: []const u16,
    words: []const u32,
    asciiz: []const u8,
    nascii: []const u8,
    padding: Padding,
    ptr: []const u8,
};

pub const Statement = struct {
    label: []const u8,
    value: union(enum) {
        section: []const u8,
        bytes: []const u8,
        shorts: []const u16,
        words: []const u32,
        asciiz: []const u8,
        nascii: []const u8,
        padding: Padding,
        ptr: []const u8,
        rtype: RType,
        itype: IType,
        ltype: LType,
        jtype: JType,
    }
};

pub const Parser = struct {
    lexer: Tokenizer,
    arena: std.heap.ArenaAllocator,

    const Token = lex.Tokenizer.Token;

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Parser {
        return .{
            .lexer = try Tokenizer.init(io, allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
        self.lexer.deinit();
    }

    pub inline fn expect(self: *Parser, kind: Token.Kind) ParseError![]const u8 {
        const token = try self.lexer.next();
        if (token.kind == kind) {
            return token.data;
        } else {
            return ParseError.UnexpectedToken;
        }
    }

    pub inline fn expectWord(self: *Parser, kind: Token.Kind) ParseError![]const u8 {
        const token = try self.lexer.nextWord();
        if (token.kind == kind) {
            return token.data;
        } else {
            return ParseError.UnexpectedToken;
        }
    }

    pub inline fn expectOneOf(self: *Parser, comptime kinds: anytype) ParseError!Token {
        const token = try self.lexer.next();
        inline for (kinds) |kind| {
            if (token.kind == kind) {
                return token;
            }
        }

        return ParseError.NoMatch;
    }

    pub fn statementEnd(self: *Parser) ParseError!bool {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        try self.lexer.skipWhitespace();
        const token = self.lexer.next() catch |err| switch (err) {
            lex.LexerError.UnexpectedEOF => return true,
            else => return err,
        };

        if (token.kind == .newline or token.kind == .semicolon or token.kind == .eof) {
            return true;
        } else {
            self.lexer.restore(mark);
            return false;
        }
    }

    pub fn skipToStatementEnd(self: *Parser) ParseError!void {
        while (self.lexer.frameHead != null) {
            try self.lexer.skipWhitespace();
            const token = self.lexer.next() catch |err| switch (err) {
                lex.LexerError.UnexpectedEOF => return err,
                else => {
                    if (self.lexer.frameHead) |head| {
                        head.pos += 1;
                    }

                    continue;
                },
            };

            switch (token.kind) {
                .newline, .semicolon => break,
                else => continue,
            }
        }
    }

    pub inline fn commaSep(self: *Parser) ParseError!void {
        _ = try self.expectWord(.comma);
        try self.lexer.skipWhitespace();
    }

    fn parseRawInteger(_: *Parser, comptime T: type, comptime base: u8, string: []const u8) ParseError!T {
        if (string.len == 0) {
            return ParseError.NoMatch;
        }

        var n: T = 0;
        for (string) |char| {
            const digit = std.fmt.charToDigit(char, base) catch return ParseError.InvalidCharacter;
            if (digit >= base) {
                return ParseError.NumericOverflow;
            }
            
            n = std.math.mul(T, n, base) catch {
                return ParseError.NumericOverflow;
            };

            n = std.math.add(T, n, @intCast(digit)) catch {
                return ParseError.NumericOverflow;
            };
        }

        return n;
    }

    pub fn parseInteger(self: *Parser, comptime T: type) ParseError!T {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const signToken: Token = self.lexer.next() catch blk: {
            self.lexer.restore(mark);
            break :blk .{.kind = .string, .data = ""};
        };

        var negative = false;
        switch (signToken.kind) {
            .plus => negative = false,
            .minus => negative = true,
            else => self.lexer.restore(mark),
        }

        const number = try self.expect(.number);
        const base = if (number.len <= 3 or number[0] != '0') 0 else number[1];
        const x: T = blk: switch (base) {
            'b', 'B' => break :blk try self.parseRawInteger(T,  2, number[2..]),
            'o', 'O' => break :blk try self.parseRawInteger(T,  8, number[2..]),
            'x', 'X' => break :blk try self.parseRawInteger(T, 16, number[2..]),
            else     => break :blk try self.parseRawInteger(T, 10, number),
        };

        if (negative) {
            return -%x;
        } else {
            return x;
        }
    }

    pub fn parseImmediate(self: *Parser, comptime T: type) ParseError!Immediate(T) {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const token = try self.expectOneOf(.{.number, .identifier, .char, .minus, .plus});
        switch (token.kind) {
            .number, .minus, .plus => {
                self.lexer.restore(mark);
                return .{.static = try self.parseInteger(T)};
            },
            .char => return .{.static = @intCast(token.data[0])},
            .identifier => return .{.dynamic = token.data},
            else => unreachable,
        }
    }

    pub fn parseRegisterName(self: *Parser) ParseError!isa.Register {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        _ = try self.expect(.dollar);
        const name = try self.expectOneOf(.{.number, .identifier});
        switch (name.kind) {
            .number => return @enumFromInt(self.parseRawInteger(u5, 10, name.data)
                catch return ParseError.InvalidEnumeration),
            .identifier => return std.meta.stringToEnum(isa.Register, name.data)
                orelse return ParseError.InvalidEnumeration,
            else => unreachable,
        }
    }

    pub fn parseLabel(self: *Parser) ParseError![]const u8 {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const name = try self.expectWord(.identifier);
        _ = try self.expect(.colon);

        return name;
    }

    pub fn parseStatement(self: *Parser) ParseError!Statement {
        var start = self.lexer.bookmark();
        errdefer self.lexer.restore(start);

        var statement: Statement = undefined;
        statement.label = self.parseLabel() catch &[_]u8{};

        const token = try self.lexer.nextWord();
        start = self.lexer.bookmark();
        switch (token.kind) {
            .identifier => {
                const instr = try self.parseInstruction(token);
                switch (instr) {
                    .rtype => |x| statement.value = .{.rtype = x},
                    .itype => |x| statement.value = .{.itype = x},
                    .ltype => |x| statement.value = .{.ltype = x},
                    .jtype => |x| statement.value = .{.jtype = x},
                }
            },

            .dot => {
                const dir = try self.parseDirective();
                switch (dir) {
                    .section => |x| statement.value = .{.section = x},
                    .bytes   => |x| statement.value = .{.bytes = x},
                    .shorts  => |x| statement.value = .{.shorts = x},
                    .words   => |x| statement.value = .{.words = x},
                    .asciiz  => |x| statement.value = .{.asciiz = x},
                    .nascii  => |x| statement.value = .{.nascii = x},
                    .padding => |x| statement.value = .{.padding = x},
                    .ptr     => |x| statement.value = .{.ptr = x},
                }
            },

            .newline => unreachable,
            else => {
                return ParseError.NoMatch;
            },
        }

        if (try self.statementEnd()) {
            return statement;
        } else {
            return ParseError.UnexpectedToken;
        }
    }

    fn parseInstruction(self: *Parser, token: Token) ParseError!Instruction {
        if (token.kind != .identifier) return ParseError.NoMatch;
        try self.lexer.skipWhitespace();
        
        const regular = std.meta.stringToEnum(isa.InstructionName, token.data);
        if (regular) |mnemo| switch (mnemo) {
            .rtype => return ParseError.NoMatch,
            .addi  => return .{.itype = try self.parseI(mnemo)},
            .j     => return .{.jtype = try self.parseJ(mnemo)},
            .jal   => return .{.jtype = try self.parseJ(mnemo)},
            .andi  => return .{.ltype = try self.parseLALU(mnemo)},
            .andih => return .{.ltype = try self.parseLALU(mnemo)},
            .ori   => return .{.ltype = try self.parseLALU(mnemo)},
            .orih  => return .{.ltype = try self.parseLALU(mnemo)},
            .xori  => return .{.ltype = try self.parseLALU(mnemo)},
            .xorih => return .{.ltype = try self.parseLALU(mnemo)},
            .lui   => return .{.ltype = try self.parseLUI(mnemo)},
            .lw    => return .{.ltype = try self.parseLMem(mnemo)},
            .sw    => return .{.ltype = try self.parseLMem(mnemo)},
            .sh    => return .{.ltype = try self.parseLMem(mnemo)},
            .sb    => return .{.ltype = try self.parseLMem(mnemo)},
            .lh    => return .{.ltype = try self.parseLMem(mnemo)},
            .lhu   => return .{.ltype = try self.parseLMem(mnemo)},
            .lb    => return .{.ltype = try self.parseLMem(mnemo)},
            .lbu   => return .{.ltype = try self.parseLMem(mnemo)},
            .beq   => return .{.itype = try self.parseBranch(mnemo)},
            .bne   => return .{.itype = try self.parseBranch(mnemo)},
            .blt   => return .{.itype = try self.parseBranch(mnemo)},
            .bgt   => return .{.itype = try self.parseBranch(mnemo)},
            .ble   => return .{.itype = try self.parseBranch(mnemo)},
            .bge   => return .{.itype = try self.parseBranch(mnemo)},
            .slti  => return .{.itype = try self.parseI(mnemo)},
            .sltiu => return .{.itype = try self.parseI(mnemo)},
        };

        const rtype = std.meta.stringToEnum(isa.RType, token.data);
        if (rtype) |mnemo| switch (mnemo) {
            .sll    => return .{.rtype = try self.parseRShift(mnemo)},
            .srl    => return .{.rtype = try self.parseRShift(mnemo)},
            .sra    => return .{.rtype = try self.parseSRA(mnemo)},
            .sllr   => return .{.rtype = try self.parseRShiftV(mnemo)},
            .srlr   => return .{.rtype = try self.parseRShiftV(mnemo)},
            .srar   => return .{.rtype = try self.parseRShiftV(mnemo)},
            .cfs    => return .{.rtype = try self.parseRAux(mnemo)},
            .cts    => return .{.rtype = try self.parseRAux(mnemo)},
            .@"and" => return .{.rtype = try self.parseR3(mnemo)},
            .@"or"  => return .{.rtype = try self.parseR3(mnemo)},
            .xor    => return .{.rtype = try self.parseR3(mnemo)},
            .nor    => return .{.rtype = try self.parseR3(mnemo)},
            .slt    => return .{.rtype = try self.parseR3(mnemo)},
            .sltu   => return .{.rtype = try self.parseR3(mnemo)},
            .jr     => return .{.rtype = try self.parseRJ(mnemo)},
            .jalr   => return .{.rtype = try self.parseRJ(mnemo)},
            .lhx    => return .{.rtype = try self.parseRMemX(mnemo)},
            .lhux   => return .{.rtype = try self.parseRMemX(mnemo)},
            .lbx    => return .{.rtype = try self.parseRMemX(mnemo)},
            .lbux   => return .{.rtype = try self.parseRMemX(mnemo)},
            .lwx    => return .{.rtype = try self.parseRMemX(mnemo)},
            .mul    => return .{.rtype = try self.parseR3(mnemo)},
            .mulh   => return .{.rtype = try self.parseR3(mnemo)},
            .mulhu  => return .{.rtype = try self.parseR3(mnemo)},
            .div    => return .{.rtype = try self.parseR3(mnemo)},
            .divu   => return .{.rtype = try self.parseR3(mnemo)},
            .rest   => return .{.rtype = try self.parseR3(mnemo)},
            .restu  => return .{.rtype = try self.parseR3(mnemo)},
            .add    => return .{.rtype = try self.parseR3(mnemo)},
            .sub    => return .{.rtype = try self.parseR3(mnemo)},
            .trap   => return .{.rtype = try self.parseTRAP(mnemo)},
            .rft    => return .{.rtype = .{
                .funct = .rft,
                .rs = .zero,
                .rt = .zero,
                .rd = .zero,
                .aux = .{.static = 0},
            }},
        };

        return ParseError.NoMatch;
    }

    fn parseJ(self: *Parser, mnemo: isa.InstructionName) ParseError!JType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const imm = try self.parseImmediate(u27);
        return .{
            .opcode = mnemo,
            .imm = imm,
        };
    }

    fn parseI(self: *Parser, mnemo: isa.InstructionName) ParseError!IType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rt = try self.parseRegisterName();
        try self.commaSep();
        const rs = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(u17);
        return .{
            .opcode = mnemo,
            .rt = rt,
            .rs = rs,
            .imm = imm,
        };
    }

    fn parseBranch(self: *Parser, mnemo: isa.InstructionName) ParseError!IType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rs = try self.parseRegisterName();
        try self.commaSep();
        const rt = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(u17);
        return .{
            .opcode = mnemo,
            .rt = rt,
            .rs = rs,
            .imm = imm,
        };
    }

    fn parseLALU(self: *Parser, mnemo: isa.InstructionName) ParseError!LType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rt = try self.parseRegisterName();
        try self.commaSep();
        const rs = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(u16);
        return .{
            .opcode = mnemo,
            .rt = rt,
            .rs = rs,
            .imm = imm,
        };
    }

    fn parseLMem(self: *Parser, mnemo: isa.InstructionName) ParseError!LType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rt = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(u16);

        _ = try self.expectWord(.lparen);
        try self.lexer.skipWhitespace();
        const rs = try self.parseRegisterName();
        _ = try self.expectWord(.rparen);

        return .{
            .opcode = mnemo,
            .rt = rt,
            .rs = rs,
            .imm = imm,
        };
    }

    fn parseLUI(self: *Parser, mnemo: isa.InstructionName) ParseError!LType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rt = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(u16);
        return .{
            .opcode = mnemo,
            .rt = rt,
            .rs = rt,
            .imm = imm,
        };
    }

    fn parseRShift(self: *Parser, mnemo: isa.RType) ParseError!RType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);
        
        const rd = try self.parseRegisterName();
        try self.commaSep();
        const rt = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(u6);

        return .{
            .funct = mnemo,
            .rs = .zero,
            .rd = rd,
            .rt = rt,
            .aux = imm,
        };
    }

    fn parseSRA(self: *Parser, mnemo: isa.RType) ParseError!RType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rd = try self.parseRegisterName();
        try self.commaSep();
        const rs = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(u6);

        return .{
            .funct = mnemo,
            .rs = rs,
            .rd = rd,
            .rt = .zero,
            .aux = imm,
        };
    }

    fn parseRShiftV(self: *Parser, mnemo: isa.RType) ParseError!RType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rd = try self.parseRegisterName();
        try self.commaSep();
        const rt = try self.parseRegisterName();
        try self.commaSep();
        const rs = try self.parseRegisterName();

        return .{
            .funct = mnemo,
            .rs = rs,
            .rd = rd,
            .rt = rt,
            .aux = .{.static = 0},
        };
    }

    fn parseRAux(self: *Parser, mnemo: isa.RType) ParseError!RType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);
        _ = mnemo; @panic("UNIMPLEMENTED");
    }

    fn parseR3(self: *Parser, mnemo: isa.RType) ParseError!RType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rd = try self.parseRegisterName();
        try self.commaSep();
        const rs = try self.parseRegisterName();
        try self.commaSep();
        const rt = try self.parseRegisterName();

        return .{
            .funct = mnemo,
            .rs = rs,
            .rd = rd,
            .rt = rt,
            .aux = .{.static = 0},
        };
    }

    fn parseRJ(self: *Parser, mnemo: isa.RType) ParseError!RType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);
        
        const rs = try self.parseRegisterName();

        return .{
            .funct = mnemo,
            .rs = rs,
            .rd = .zero,
            .rt = .zero,
            .aux = .{.static = 0},
        };
    }

    fn parseRMemX(self: *Parser, mnemo: isa.RType) ParseError!RType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rt = try self.parseRegisterName();
        try self.commaSep();
        const rs = try self.parseRegisterName();
        try self.commaSep();
        const rd = try self.parseRegisterName();

        return .{
            .funct = mnemo,
            .rs = rs,
            .rd = rd,
            .rt = rt,
            .aux = .{.static = 0},
        };
    }

    fn parseTRAP(self: *Parser, mnemo: isa.RType) ParseError!RType {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);
        _ = mnemo; @panic("UNIMPLEMENTED");
    }

    fn parseDirective(self: *Parser) ParseError!Directive {
        const token = try self.expect(.identifier);
        const directive = std.meta.stringToEnum(isa.DataDirective, token)
            orelse return ParseError.NoMatch;

        try self.lexer.skipWhitespace();
        switch (directive) {
            .asciiz  => return .{.asciiz = try self.parseString()},
            .byte    => return .{.bytes = try self.parseBytes()},
            .nascii  => return .{.asciiz = try self.parseString()},
            .pad     => return .{.padding = try self.parsePadding()},
            .ptr     => return .{.ptr = try self.parseSymbolLabel()},
            .section => return .{.section = try self.parseSectionLabel()},
            .short   => return .{.shorts = try self.parseIntegerList(u16)},
            .word    => return .{.words = try self.parseIntegerList(u32)},
        }
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        var string = std.ArrayList(u8).empty;
        errdefer string.deinit(self.arena.allocator());

        while (self.lexer.frameHead != null) {
            try self.lexer.skipWhitespace();

            const segment = self.expect(.string) catch break;
            try string.appendSlice(self.arena.allocator(), segment);
        }

        if (string.items.len == 0) {
            return ParseError.NoMatch;
        } else {
            return string.items;
        }
    }

    fn parseIntegerList(self: *Parser, comptime T: type) ParseError![]const T {
        var numbers = std.ArrayList(T).empty;
        errdefer numbers.deinit(self.arena.allocator());

        while (self.lexer.frameHead != null) {
            const mark = self.lexer.bookmark();
            try self.lexer.skipWhitespace();

            const x = self.parseInteger(T) catch {
                self.lexer.restore(mark);
                break;
            };

            try numbers.append(self.arena.allocator(), x);
        }

        if (numbers.items.len == 0) {
            return ParseError.NoMatch;
        } else {
            return numbers.items;
        }
    }

    fn parseByte(self: *Parser) ParseError!u8 {
        try self.lexer.skipWhitespace();
        return self.parseInteger(u8)
            catch (try self.expect(.char))[0];
    }

    fn parseBytes(self: *Parser) ParseError![]const u8 {
        var bytes = std.ArrayList(u8).empty;
        errdefer bytes.deinit(self.arena.allocator());

        while (self.lexer.frameHead != null) {
            const mark = self.lexer.bookmark();
            try self.lexer.skipWhitespace();

            const x = self.parseByte() catch {
                self.lexer.restore(mark);
                break;
            };

            try bytes.append(self.arena.allocator(), x);
        }

        if (bytes.items.len == 0) {
            return ParseError.NoMatch;
        } else {
            return bytes.items;
        }
    }

    fn parsePaddingAlignment(self: *Parser) ParseError!usize {
        const mark = self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        _ = try self.expectWord(.lparen);
        const a = try self.parseInteger(usize);
        _ = try self.expect(.rparen);
        return a;
    }

    fn parsePadding(self: *Parser) ParseError!Padding {
        const numbers = try self.parseIntegerList(usize);
        const alignment = self.parsePaddingAlignment() catch 1;

        var padding: usize = 0;
        for (numbers) |x| {
            padding += x;
        }

        return .{
            .size = padding,
            .alignment = alignment,
        };
    }

    fn parseSymbolLabel(self: *Parser) ParseError![]const u8 {
        return try self.expect(.identifier);
    }

    fn parseSectionLabel(self: *Parser) ParseError![]const u8 {
        const token = try self.expectOneOf(.{.identifier, .string}); // maybe do validation here later
        return token.data;
    }
};

fn makeParser(src: []const u8) !Parser {
    var parser = try Parser.init(std.testing.io, std.testing.allocator);
    try parser.lexer.pushFrame(src, "<makeParser>");
    return parser;
}

test "parseInteger decimal" {
    var p = try makeParser("123");
    defer p.deinit();

    try std.testing.expectEqual(@as(i32, 123), try p.parseInteger(i32));
}

test "parseInteger negative" {
    var p = try makeParser("-42");
    defer p.deinit();

    try std.testing.expectEqual(@as(i32, -42), try p.parseInteger(i32));
}

test "parseInteger hexadecimal" {
    var p = try makeParser("0xFF");
    defer p.deinit();

    try std.testing.expectEqual(@as(u16, 255), try p.parseInteger(u16));
}

test "parseInteger binary" {
    var p = try makeParser("0b101101");
    defer p.deinit();

    try std.testing.expectEqual(@as(u8, 45), try p.parseInteger(u8));
}

test "parseInteger octal" {
    var p = try makeParser("0o77");
    defer p.deinit();

    try std.testing.expectEqual(@as(u8, 63), try p.parseInteger(u8));
}

test "parseInteger overflow" {
    var p = try makeParser("300");
    defer p.deinit();

    try std.testing.expectError(
        ParseError.NumericOverflow,
        p.parseInteger(u8),
    );
}

test "parseImmediate constant" {
    var p = try makeParser("42");
    defer p.deinit();

    const imm = try p.parseImmediate(u16);

    switch (imm) {
        .static => |v| try std.testing.expectEqual(@as(u16, 42), v),
        else => try std.testing.expect(false),
    }
}

test "parseImmediate symbol" {
    var p = try makeParser("loop");
    defer p.deinit();

    const imm = try p.parseImmediate(u16);

    switch (imm) {
        .dynamic => |name|
            try std.testing.expectEqualStrings("loop", name),
        else => try std.testing.expect(false),
    }
}

test "parseRegisterName numeric" {
    var p = try makeParser("$10");
    defer p.deinit();

    try std.testing.expectEqual(@as(isa.Register, .t0), try p.parseRegisterName());
}

test "parseRegisterName symbolic" {
    var p = try makeParser("$sp");
    defer p.deinit();

    try std.testing.expectEqual(@as(isa.Register, .sp), try p.parseRegisterName());
}

test "parseRegisterName invalid" {
    var p = try makeParser("$foobar");
    defer p.deinit();

    try std.testing.expectError(
        ParseError.InvalidEnumeration,
        p.parseRegisterName(),
    );
}

test "parseLabel" {
    var p = try makeParser("main:");
    defer p.deinit();

    const label = try p.parseLabel();

    try std.testing.expectEqualStrings("main", label);
}

test "parseStatement add" {
    var p = try makeParser(
        "add $t0, $t1, $t2\n",
    );
    defer p.deinit();

    const stmt = try p.parseStatement();
    const imm: Immediate(u6) = .{.static = 0};

    switch (stmt.value) {
        .rtype => |r| {
            try std.testing.expectEqual(isa.RType.add, r.funct);
            try std.testing.expectEqual(isa.Register.t0, r.rd);
            try std.testing.expectEqual(isa.Register.t1, r.rs);
            try std.testing.expectEqual(isa.Register.t2, r.rt);
            try std.testing.expectEqual(imm, r.aux);
        },
        else => try std.testing.expect(false),
    }
}

test "parseStatement addi" {
    var p = try makeParser(
        "addi $t0, $t1, 123\n",
    );
    defer p.deinit();

    const stmt = try p.parseStatement();

    switch (stmt.value) {
        .itype => |i| {
            try std.testing.expectEqual(isa.InstructionName.addi, i.opcode);
            try std.testing.expectEqual(isa.Register.t0, i.rt);
            try std.testing.expectEqual(isa.Register.t1, i.rs);

            switch (i.imm) {
                .static => |v|
                    try std.testing.expectEqual(@as(u17, 123), v),
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }
}

test "parseStatement jump label" {
    var p = try makeParser(
        "j loop\n",
    );
    defer p.deinit();

    const stmt = try p.parseStatement();

    switch (stmt.value) {
        .jtype => |j| {
            try std.testing.expectEqual(isa.InstructionName.j, j.opcode);

            switch (j.imm) {
                .dynamic => |name|
                    try std.testing.expectEqualStrings("loop", name),
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }
}

test "parseStatement lw" {
    var p = try makeParser(
        "lw $t0, 16($sp)\n",
    );
    defer p.deinit();

    const stmt = try p.parseStatement();

    switch (stmt.value) {
        .ltype => |l| {
            try std.testing.expectEqual(isa.InstructionName.lw, l.opcode);
            try std.testing.expectEqual(isa.Register.t0, l.rt);
            try std.testing.expectEqual(isa.Register.sp, l.rs);

            switch (l.imm) {
                .static => |v|
                    try std.testing.expectEqual(@as(u16, 16), v),
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }
}

test "parseStatement with label" {
    var p = try makeParser(
        "loop: add $t0, $t1, $t2\n",
    );
    defer p.deinit();

    const stmt = try p.parseStatement();

    try std.testing.expectEqualStrings("loop", stmt.label);

    switch (stmt.value) {
        .rtype => |r|
            try std.testing.expectEqual(isa.RType.add, r.funct),
        else => try std.testing.expect(false),
    }
}
