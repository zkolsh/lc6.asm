const std = @import("std");
const isa = @import("isa.zig");
const lex = @import("tokenizer.zig");

const Tokenizer = lex.Tokenizer;

pub const ParseError = error {
    InvalidEnumeration,
    InvalidInstruction,
    NoMatch,
    NumericOverflow,
    UnexpectedToken,
} || lex.LexerError;

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
        const mark = try self.lexer.bookmark();
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

    pub fn skipToStatementStart(self: *Parser) ParseError!void {
        while (self.lexer.frameHead != null) {
            const mark = try self.lexer.bookmark();

            _ = self.expectOneOf(.{.whitespace, .newline}) catch |err| switch (err) {
                ParseError.NoMatch => {
                    self.lexer.restore(mark);
                    return;
                },

                else => return err,
            };
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
        const mark = try self.lexer.bookmark();
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

    pub fn tryParseLabelOffset(self: *Parser) ParseError!i32 {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        _ = try self.expectOneOf(.{.plus, .minus});
        self.lexer.restore(mark);

        return try self.parseInteger(i32);
    }

    pub fn parseImmediate(self: *Parser, kind: isa.ImmediateKind) ParseError!isa.Immediate(u25) {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const token = try self.expectOneOf(.{.number, .identifier, .char, .minus, .plus, .dot});
        switch (token.kind) {
            .number, .minus, .plus => {
                self.lexer.restore(mark);
                const integer = switch (kind) {
                    .elimm => try self.parseInteger(u25),
                    .vlimm => try self.parseInteger(u24),
                    .llimm => try self.parseInteger(u20),
                    .limm  => try self.parseInteger(u19),
                    .imm   => try self.parseInteger(u17),
                    .simm  => try self.parseInteger(u16),
                    .aux   => try self.parseInteger(u5),
                };
                return .{.static = std.math.cast(u25, integer)
                    orelse return ParseError.NumericOverflow};
            },
            .char => return .{.static = @intCast(token.data[0])},
            .identifier => {
                return .{.dynamic = .{
                    .label = token.data,
                    .offset = self.tryParseLabelOffset() catch 0,
                }};
            },
            .dot => {
                const kindStr = try self.expect(.identifier);
                const ptrKind = std.meta.stringToEnum(isa.DataDirective, kindStr) orelse return ParseError.InvalidEnumeration;
                if (ptrKind != .lo16 and ptrKind != .hi16) return ParseError.InvalidEnumeration;

                const label = try self.expectWord(.identifier);
                return .{.pointer = .{
                    .high = ptrKind == .hi16,
                    .label = label,
                }};
            },
            else => unreachable,
        }
    }

    pub fn parseRegisterName(self: *Parser) ParseError!isa.Register {
        const mark = try self.lexer.bookmark();
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

    pub fn parseSpecialRegisterName(self: *Parser) ParseError!isa.SpecialRegister {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        _ = try self.expect(.dollar);
        const name = try self.expectOneOf(.{.number, .identifier});
        switch (name.kind) {
            .number => return @enumFromInt(self.parseRawInteger(u5, 10, name.data)
                catch return ParseError.InvalidEnumeration),
            .identifier => return std.meta.stringToEnum(isa.SpecialRegister, name.data)
                orelse return ParseError.InvalidEnumeration,
            else => unreachable,
        }
    }

    pub fn parseLabel(self: *Parser) ParseError![]const u8 {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const name = try self.expectWord(.identifier);
        _ = try self.expect(.colon);

        return name;
    }

    pub fn parseStatement(self: *Parser) ParseError!isa.Statement {
        var start = try self.lexer.bookmark();
        errdefer self.lexer.restore(start);

        var statement: isa.Statement = undefined;
        statement.label = self.parseLabel() catch &[_]u8{};

        const token = try self.lexer.nextWord();
        start = try self.lexer.bookmark();
        switch (token.kind) {
            .identifier => {
                const instr = try self.parseInstruction(token);
                switch (instr) {
                    .rtype => |x| statement.value = .{.rtype = x},
                    .itype => |x| statement.value = .{.itype = x},
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
                    .lo16    => |x| statement.value = .{.lo16 = x},
                    .hi16    => |x| statement.value = .{.hi16 = x},
                }
            },

            .newline => unreachable,
            else => {
                return ParseError.NoMatch;
            },
        }

        const end = self.statementEnd() catch return ParseError.UnexpectedToken;
        if (end) {
            return statement;
        } else {
            return ParseError.UnexpectedToken;
        }
    }

    fn parseInstruction(self: *Parser, token: Token) ParseError!isa.Instruction {
        if (token.kind != .identifier) return ParseError.NoMatch;
        try self.lexer.skipWhitespace();

        const r = std.meta.stringToEnum(isa.RTypeMnemo, token.data);
        const i = std.meta.stringToEnum(isa.ITypeMnemo, token.data);
        const j = std.meta.stringToEnum(isa.JTypeMnemo, token.data);

        if (r) |mnemo| switch (mnemo) {
            .sll    => return .{.rtype = try self.parseRShift(mnemo)},
            .rlc    => return .{.rtype = try self.parseRShift(mnemo)},
            .srl    => return .{.rtype = try self.parseRShift(mnemo)},
            .sra    => return .{.rtype = try self.parseRShift(mnemo)},
            .sllr   => return .{.rtype = try self.parseRShiftV(mnemo)},
            .rlcr   => return .{.rtype = try self.parseRShiftV(mnemo)},
            .srlr   => return .{.rtype = try self.parseRShiftV(mnemo)},
            .srar   => return .{.rtype = try self.parseRShiftV(mnemo)},
            .@"and" => return .{.rtype = try self.parseR3(mnemo)},
            .@"or"  => return .{.rtype = try self.parseR3(mnemo)},
            .nor    => return .{.rtype = try self.parseR3(mnemo)},
            .xor    => return .{.rtype = try self.parseR3(mnemo)},
            .add    => return .{.rtype = try self.parseR3(mnemo)},
            .sub    => return .{.rtype = try self.parseR3(mnemo)},
            .slt    => return .{.rtype = try self.parseR3(mnemo)},
            .sltu   => return .{.rtype = try self.parseR3(mnemo)},
            .lhx    => return .{.rtype = try self.parseR3(mnemo)},
            .lhux   => return .{.rtype = try self.parseR3(mnemo)},
            .lbx    => return .{.rtype = try self.parseR3(mnemo)},
            .lbux   => return .{.rtype = try self.parseR3(mnemo)},
            .lwx    => return .{.rtype = try self.parseR3(mnemo)},
            .swx    => return .{.rtype = try self.parseR3(mnemo)},
            .shx    => return .{.rtype = try self.parseR3(mnemo)},
            .sbx    => return .{.rtype = try self.parseR3(mnemo)},
            .mul    => return .{.rtype = try self.parseR3(mnemo)},
            .mulh   => return .{.rtype = try self.parseR3(mnemo)},
            .mulhu  => return .{.rtype = try self.parseR3(mnemo)},
            .mulhsu => return .{.rtype = try self.parseR3(mnemo)},
            .div    => return .{.rtype = try self.parseR3(mnemo)},
            .divu   => return .{.rtype = try self.parseR3(mnemo)},
            .rest   => return .{.rtype = try self.parseR3(mnemo)},
            .restu  => return .{.rtype = try self.parseR3(mnemo)},
            .cfs    => return .{.rtype = try self.parseRAux(mnemo)},
            .cts    => return .{.rtype = try self.parseRAux(mnemo)},
            .trap   => return .{.rtype = try self.parseTRAP(mnemo)},
            .rft    => return .{.rtype = .{
                .funct = .rft,
                .rs = .zero,
                .rt = .zero,
                .rd = .zero,
                .aux = .{.static = 0},
            }},
        };

        if (i) |mnemo| switch (mnemo) {
            .jr    => return .{.itype = try self.parseJR(mnemo)},
            .jalr  => return .{.itype = try self.parseJR(mnemo)},
            .jalrx => return .{.itype = try self.parseJALRX(mnemo)},
            .addi  => return .{.itype = try self.parseIALU(mnemo)},
            .andi  => return .{.itype = try self.parseIALU(mnemo)},
            .lci   => return .{.itype = try self.parseIALU(mnemo)},
            .ani   => return .{.itype = try self.parseIALU(mnemo)},
            .anh   => return .{.itype = try self.parseIALU(mnemo)},
            .ori   => return .{.itype = try self.parseIALU(mnemo)},
            .orh   => return .{.itype = try self.parseIALU(mnemo)},
            .xori  => return .{.itype = try self.parseIALU(mnemo)},
            .xorh => return .{.itype = try self.parseIALU(mnemo)},
            .lw    => return .{.itype = try self.parseIMem(mnemo)},
            .sw    => return .{.itype = try self.parseIMem(mnemo)},
            .sh    => return .{.itype = try self.parseIMem(mnemo)},
            .sb    => return .{.itype = try self.parseIMem(mnemo)},
            .lh    => return .{.itype = try self.parseIMem(mnemo)},
            .lhu   => return .{.itype = try self.parseIMem(mnemo)},
            .lb    => return .{.itype = try self.parseIMem(mnemo)},
            .lbu   => return .{.itype = try self.parseIMem(mnemo)},
            .beq   => return .{.itype = try self.parseBranch(mnemo)},
            .bne   => return .{.itype = try self.parseBranch(mnemo)},
            .blt   => return .{.itype = try self.parseBranch(mnemo)},
            .bge   => return .{.itype = try self.parseBranch(mnemo)},
            .bltu  => return .{.itype = try self.parseBranch(mnemo)},
            .bgeu  => return .{.itype = try self.parseBranch(mnemo)},
            .slti  => return .{.itype = try self.parseI(mnemo)},
            .sltiu => return .{.itype = try self.parseI(mnemo)},
        };

        if (j) |mnemo| switch (mnemo) {
            .j    => return .{.jtype = try self.parseJ(mnemo)},
            .jal  => return .{.jtype = try self.parseJ(mnemo)},
            .jalx => return .{.jtype = try self.parseJALX(mnemo)},
        };

        return ParseError.InvalidInstruction;
    }

    fn parseJ(self: *Parser, mnemo: isa.JTypeMnemo) ParseError!isa.JType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const imm = try self.parseImmediate(isa.JType.getInfo(mnemo).immtype.?);
        return .{
            .opcode = mnemo,
            .imm = imm,
            .linkRegister = .zero,
        };
    }

    fn parseJALX(self: *Parser, mnemo: isa.JTypeMnemo) ParseError!isa.JType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const lr = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(isa.JType.getInfo(mnemo).immtype.?);

        switch (lr) {
            .lr0, .lr1, .lr2, .lr3 => {},
            else => return ParseError.InvalidEnumeration,
        }

        return .{
            .opcode = mnemo,
            .imm = imm,
            .linkRegister = lr,
        };
    }

    fn parseI(self: *Parser, mnemo: isa.ITypeMnemo) ParseError!isa.IType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rt = try self.parseRegisterName();
        try self.commaSep();
        const rs = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(isa.IType.getInfo(mnemo).immtype.?);
        return .{
            .opcode = mnemo,
            .rt = rt,
            .rs = rs,
            .imm = imm,
            .linkRegister = .zero,
        };
    }

    fn parseIALU(self: *Parser, mnemo: isa.ITypeMnemo) ParseError!isa.IType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rt = try self.parseRegisterName();
        try self.commaSep();
        const rs = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(isa.IType.getInfo(mnemo).immtype.?);
        return .{
            .opcode = mnemo,
            .rt = rt,
            .rs = rs,
            .imm = imm,
            .linkRegister = .zero,
        };
    }

    fn parseIMem(self: *Parser, mnemo: isa.ITypeMnemo) ParseError!isa.IType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rt = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(isa.IType.getInfo(mnemo).immtype.?);

        _ = try self.expectWord(.lparen);
        try self.lexer.skipWhitespace();
        const rs = try self.parseRegisterName();
        _ = try self.expectWord(.rparen);

        return .{
            .opcode = mnemo,
            .rt = rt,
            .rs = rs,
            .imm = imm,
            .linkRegister = .zero,
        };
    }

    fn parseBranch(self: *Parser, mnemo: isa.ITypeMnemo) ParseError!isa.IType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rs = try self.parseRegisterName();
        try self.commaSep();
        const rt = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(isa.IType.getInfo(mnemo).immtype.?);
        return .{
            .opcode = mnemo,
            .rt = rt,
            .rs = rs,
            .imm = imm,
            .linkRegister = .zero,
        };
    }

    fn parseJR(self: *Parser, mnemo: isa.ITypeMnemo) ParseError!isa.IType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);
        
        const rs = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(isa.IType.getInfo(mnemo).immtype.?);

        return .{
            .opcode = mnemo,
            .rt = .zero,
            .rs = rs,
            .imm = imm,
            .linkRegister = .zero,
        };
    }

    fn parseJALRX(self: *Parser, mnemo: isa.ITypeMnemo) ParseError!isa.IType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rs = try self.parseRegisterName();
        try self.commaSep();
        const lr = try self.parseRegisterName();
        try self.commaSep();
        const imm = try self.parseImmediate(isa.IType.getInfo(mnemo).immtype.?);

        switch (lr) {
            .lr0, .lr1, .lr2, .lr3 => {},
            else => return ParseError.InvalidEnumeration,
        }

        return .{
            .opcode = mnemo,
            .rt = .zero,
            .rs = rs,
            .imm = imm,
            .linkRegister = lr,
        };
    }

    fn parseRShift(self: *Parser, mnemo: isa.RTypeMnemo) ParseError!isa.RType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);
        
        const rd = try self.parseRegisterName();
        try self.commaSep();
        const rt = try self.parseRegisterName();
        try self.commaSep();
        const evilImmediate = try self.parseImmediate(.aux);
        const imm: isa.Immediate(u5) = switch (evilImmediate) {
            .dynamic => |x| .{.dynamic = x},
            .static  => |x| .{.static = std.math.cast(u5, x)
                orelse return ParseError.NumericOverflow},
            .pointer  => |x| .{.dynamic = .{.label = x.label, .offset = 0}},
        };

        return .{
            .funct = mnemo,
            .rs = .zero,
            .rd = rd,
            .rt = rt,
            .aux = imm,
        };
    }

    fn parseRShiftV(self: *Parser, mnemo: isa.RTypeMnemo) ParseError!isa.RType {
        const mark = try self.lexer.bookmark();
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

    fn parseRAux(self: *Parser, mnemo: isa.RTypeMnemo) ParseError!isa.RType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const rs = try self.parseRegisterName();
        try self.commaSep();
        const aux = try self.parseSpecialRegisterName();

        return .{
            .funct = mnemo,
            .rs = rs,
            .rd = .zero,
            .rt = .zero,
            .aux = .{.static = @intFromEnum(aux)},
        };
    }

    fn parseR3(self: *Parser, mnemo: isa.RTypeMnemo) ParseError!isa.RType {
        const mark = try self.lexer.bookmark();
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

    fn parseTRAP(self: *Parser, mnemo: isa.RTypeMnemo) ParseError!isa.RType {
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        const evilImmediate = try self.parseImmediate(.aux);
        const imm: isa.Immediate(u5) = switch (evilImmediate) {
            .dynamic => |x| .{.dynamic = x},
            .static  => |x| .{.static = std.math.cast(u5, x)
                orelse return ParseError.NumericOverflow},
            .pointer  => |x| .{.dynamic = .{.label = x.label, .offset = 0}},
        };

        return .{
            .funct = mnemo,
            .rs = .zero,
            .rd = .zero,
            .rt = .zero,
            .aux = imm,
        };
    }

    fn parseDirective(self: *Parser) ParseError!isa.Directive {
        const token = try self.expect(.identifier);
        const directive = std.meta.stringToEnum(isa.DataDirective, token)
            orelse return ParseError.NoMatch;

        try self.lexer.skipWhitespace();
        switch (directive) {
            .asciiz  => return .{.asciiz = try self.parseString()},
            .byte    => return .{.bytes = try self.parseBytes()},
            .nascii  => return .{.nascii = try self.parseString()},
            .pad     => return .{.padding = try self.parsePadding()},
            .ptr     => return .{.ptr = try self.parseSymbolLabel()},
            .section => return .{.section = try self.parseSectionLabel()},
            .short   => return .{.shorts = try self.parseIntegerList(u16)},
            .word    => return .{.words = try self.parseIntegerList(u32)},
            .lo16    => return .{.lo16 = try self.parseSymbolLabel()},
            .hi16    => return .{.hi16 = try self.parseSymbolLabel()},
        }
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        var string = std.ArrayList(u8).empty;
        errdefer string.deinit(self.arena.allocator());

        while (self.lexer.frameHead != null) {
            const mark = try self.lexer.bookmark();
            try self.lexer.skipWhitespace();

            const segment = self.expect(.string) catch {
                self.lexer.restore(mark);
                break;
            };

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
            const mark = try self.lexer.bookmark();
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
            const mark = try self.lexer.bookmark();
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
        const mark = try self.lexer.bookmark();
        errdefer self.lexer.restore(mark);

        _ = try self.expectWord(.lparen);
        const a = try self.parseInteger(usize);
        _ = try self.expect(.rparen);
        return a;
    }

    fn parsePadding(self: *Parser) ParseError!isa.Padding {
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

    const imm = try p.parseImmediate(.imm);

    switch (imm) {
        .static => |v| try std.testing.expectEqual(@as(u16, 42), v),
        else => try std.testing.expect(false),
    }
}

test "parseImmediate symbol" {
    var p = try makeParser("loop");
    defer p.deinit();

    const imm = try p.parseImmediate(.imm);

    switch (imm) {
        .dynamic => |name|
            try std.testing.expectEqualStrings("loop", name.label),
        else => try std.testing.expect(false),
    }
}

test "parseRegisterName numeric" {
    var p = try makeParser("$10");
    defer p.deinit();

    try std.testing.expectEqual(@as(isa.Register, .a2), try p.parseRegisterName());
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
    const imm: isa.Immediate(u5) = .{.static = 0};

    switch (stmt.value) {
        .rtype => |r| {
            try std.testing.expectEqual(isa.RTypeMnemo.add, r.funct);
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
            try std.testing.expectEqual(isa.ITypeMnemo.addi, i.opcode);
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
            try std.testing.expectEqual(isa.JTypeMnemo.j, j.opcode);

            switch (j.imm) {
                .dynamic => |name|
                    try std.testing.expectEqualStrings("loop", name.label),
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
            try std.testing.expectEqual(isa.RTypeMnemo.add, r.funct),
        else => try std.testing.expect(false),
    }
}

test "parseInteger bases uppercase and explicit sign" {
    var hex = try makeParser("0X1A");
    defer hex.deinit();
    try std.testing.expectEqual(@as(u32, 26), try hex.parseInteger(u32));

    var bin = try makeParser("0B1010");
    defer bin.deinit();
    try std.testing.expectEqual(@as(u32, 10), try bin.parseInteger(u32));

    var octal = try makeParser("0O12");
    defer octal.deinit();
    try std.testing.expectEqual(@as(u32, 10), try octal.parseInteger(u32));

    var plus = try makeParser("+42");
    defer plus.deinit();
    try std.testing.expectEqual(@as(i32, 42), try plus.parseInteger(i32));
    
    var minus = try makeParser("-42");
    defer minus.deinit();
    try std.testing.expectEqual(@as(i32, -42), try minus.parseInteger(i32));
}

test "parseImmediate formats" {
    var charP = try makeParser("'A'");
    defer charP.deinit();
    const charImm = try charP.parseImmediate(.imm);
    switch (charImm) {
        .static => |v| try std.testing.expectEqual(@as(u25, 'A'), v),
        else => try std.testing.expect(false),
    }

    var labelShiftP = try makeParser("target+8");
    defer labelShiftP.deinit();
    const labelShiftImm = try labelShiftP.parseImmediate(.imm);
    switch (labelShiftImm) {
        .dynamic => |dyn| {
            try std.testing.expectEqualStrings("target", dyn.label);
            try std.testing.expectEqual(@as(i32, 8), dyn.offset);
        },
        else => try std.testing.expect(false),
    }

    var labelNegativeP = try makeParser("target-4");
    defer labelNegativeP.deinit();
    const labelNegativeImm = try labelNegativeP.parseImmediate(.imm);
    switch (labelNegativeImm) {
        .dynamic => |dyn| {
            try std.testing.expectEqualStrings("target", dyn.label);
            try std.testing.expectEqual(@as(i32, -4), dyn.offset);
        },
        else => try std.testing.expect(false),
    }

    var ptrloP = try makeParser(".lo16 symbol");
    defer ptrloP.deinit();
    const ptrloImm = try ptrloP.parseImmediate(.imm);
    switch (ptrloImm) {
        .pointer => |ptr| {
            try std.testing.expectEqual(false, ptr.high);
            try std.testing.expectEqualStrings("symbol", ptr.label);
        },
        else => try std.testing.expect(false),
    }

    var ptrhiP = try makeParser(".hi16 symbol");
    defer ptrhiP.deinit();
    const ptrhiImm = try ptrhiP.parseImmediate(.imm);
    switch (ptrhiImm) {
        .pointer => |ptr| {
            try std.testing.expectEqual(true, ptr.high);
            try std.testing.expectEqualStrings("symbol", ptr.label);
        },
        else => try std.testing.expect(false),
    }

    var invalidP = try makeParser(".asciiz symbol");
    defer invalidP.deinit();
    try std.testing.expectError(ParseError.InvalidEnumeration, invalidP.parseImmediate(.imm));
}

test "parseSpecialRegisterName" {
    var psw = try makeParser("$psw");
    defer psw.deinit();
    try std.testing.expectEqual(isa.SpecialRegister.psw, try psw.parseSpecialRegisterName());

    var num = try makeParser("$0");
    defer num.deinit();
    try std.testing.expectEqual(isa.SpecialRegister.psw, try num.parseSpecialRegisterName());

    var pir = try makeParser("$pir");
    defer pir.deinit();
    try std.testing.expectEqual(isa.SpecialRegister.pir, try pir.parseSpecialRegisterName());

    var invalid = try makeParser("$t0");
    defer invalid.deinit();
    try std.testing.expectError(ParseError.InvalidEnumeration, invalid.parseSpecialRegisterName());
}

test "parseStatement RType" {
    // RShift
    var p1 = try makeParser("sll $t0, $t1, 5\n");
    defer p1.deinit();
    const s1 = try p1.parseStatement();
    switch (s1.value) {
        .rtype => |r| {
            try std.testing.expectEqual(isa.RTypeMnemo.sll, r.funct);
            try std.testing.expectEqual(isa.Register.t0, r.rd);
            try std.testing.expectEqual(isa.Register.t1, r.rt);
            try std.testing.expectEqual(isa.Register.zero, r.rs);
            try std.testing.expectEqual(isa.Immediate(u5){ .static = 5 }, r.aux);
        },
        else => try std.testing.expect(false),
    }

    var p1_err = try makeParser("sll $t0, $t1, 64\n");
    defer p1_err.deinit();
    try std.testing.expectError(ParseError.NumericOverflow, p1_err.parseStatement());

    // RShiftV
    var p2 = try makeParser("sllr $t0, $t1, $t2\n");
    defer p2.deinit();
    const s2 = try p2.parseStatement();
    switch (s2.value) {
        .rtype => |r| {
            try std.testing.expectEqual(isa.RTypeMnemo.sllr, r.funct);
            try std.testing.expectEqual(isa.Register.t0, r.rd);
            try std.testing.expectEqual(isa.Register.t1, r.rt);
            try std.testing.expectEqual(isa.Register.t2, r.rs);
        },
        else => try std.testing.expect(false),
    }

    // RAux
    var p3 = try makeParser("cfs $a0, $psw\n");
    defer p3.deinit();
    const s3 = try p3.parseStatement();
    switch (s3.value) {
        .rtype => |r| {
            try std.testing.expectEqual(isa.RTypeMnemo.cfs, r.funct);
            try std.testing.expectEqual(isa.Register.a0, r.rs);
            try std.testing.expectEqual(isa.Register.zero, r.rd);
            try std.testing.expectEqual(isa.Register.zero, r.rt);
            try std.testing.expectEqual(isa.Immediate(u5){ .static = @intFromEnum(isa.SpecialRegister.psw) }, r.aux);
        },
        else => try std.testing.expect(false),
    }

    var p3_cts = try makeParser("cts $a1, $ecr\n");
    defer p3_cts.deinit();
    const s3_cts = try p3_cts.parseStatement();
    switch (s3_cts.value) {
        .rtype => |r| {
            try std.testing.expectEqual(isa.RTypeMnemo.cts, r.funct);
            try std.testing.expectEqual(isa.Register.a1, r.rs);
            try std.testing.expectEqual(isa.Immediate(u5){ .static = @intFromEnum(isa.SpecialRegister.ecr) }, r.aux);
        },
        else => try std.testing.expect(false),
    }

    // TRAP
    var p4 = try makeParser("trap 12\n");
    defer p4.deinit();
    const s4 = try p4.parseStatement();
    switch (s4.value) {
        .rtype => |r| {
            try std.testing.expectEqual(isa.RTypeMnemo.trap, r.funct);
            try std.testing.expectEqual(isa.Immediate(u5){ .static = 12 }, r.aux);
        },
        else => try std.testing.expect(false),
    }

    // RFT
    var p5 = try makeParser("rft\n");
    defer p5.deinit();
    const s5 = try p5.parseStatement();
    switch (s5.value) {
        .rtype => |r| {
            try std.testing.expectEqual(isa.RTypeMnemo.rft, r.funct);
            try std.testing.expectEqual(isa.Register.zero, r.rs);
            try std.testing.expectEqual(isa.Register.zero, r.rd);
            try std.testing.expectEqual(isa.Register.zero, r.rt);
            try std.testing.expectEqual(isa.Immediate(u5){ .static = 0 }, r.aux);
        },
        else => try std.testing.expect(false),
    }
}

test "parseStatement IType" {
    // IMem
    var imemP = try makeParser("lw $a0, 16($sp)\n");
    defer imemP.deinit();
    const imemS = try imemP.parseStatement();
    switch (imemS.value) {
        .itype => |i| {
            try std.testing.expectEqual(isa.ITypeMnemo.lw, i.opcode);
            try std.testing.expectEqual(isa.Register.a0, i.rt);
            try std.testing.expectEqual(isa.Register.sp, i.rs);
            try std.testing.expectEqual(isa.Immediate(u25){ .static = 16 }, i.imm);
        },
        else => try std.testing.expect(false),
    }

    var isymP = try makeParser("sw $t0, data_label($gp)\n");
    defer isymP.deinit();
    const isymS = try isymP.parseStatement();
    switch (isymS.value) {
        .itype => |i| {
            try std.testing.expectEqual(isa.ITypeMnemo.sw, i.opcode);
            try std.testing.expectEqual(isa.Register.t0, i.rt);
            try std.testing.expectEqual(isa.Register.gp, i.rs);
            switch (i.imm) {
                .dynamic => |dyn| try std.testing.expectEqualStrings("data_label", dyn.label),
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }

    // Branch
    var branchP = try makeParser("beq $t0, $t1, target_label\n");
    defer branchP.deinit();
    const branchS = try branchP.parseStatement();
    switch (branchS.value) {
        .itype => |i| {
            try std.testing.expectEqual(isa.ITypeMnemo.beq, i.opcode);
            try std.testing.expectEqual(isa.Register.t0, i.rs);
            try std.testing.expectEqual(isa.Register.t1, i.rt);
            switch (i.imm) {
                .dynamic => |dyn| try std.testing.expectEqualStrings("target_label", dyn.label),
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }

    // JR
    var jrP = try makeParser("jr $ra, 0\n");
    defer jrP.deinit();
    const jrS = try jrP.parseStatement();
    switch (jrS.value) {
        .itype => |i| {
            try std.testing.expectEqual(isa.ITypeMnemo.jr, i.opcode);
            try std.testing.expectEqual(isa.Register.ra, i.rs);
            try std.testing.expectEqual(isa.Register.zero, i.rt);
            try std.testing.expectEqual(isa.Immediate(u25){ .static = 0 }, i.imm);
        },
        else => try std.testing.expect(false),
    }

    // individuals
    var jalrxP = try makeParser("jalrx $t0, $lr2, 4\n");
    defer jalrxP.deinit();
    const jalrxS = try jalrxP.parseStatement();
    switch (jalrxS.value) {
        .itype => |i| {
            try std.testing.expectEqual(isa.ITypeMnemo.jalrx, i.opcode);
            try std.testing.expectEqual(isa.Register.t0, i.rs);
            try std.testing.expectEqual(isa.Register.lr2, i.linkRegister);
            try std.testing.expectEqual(isa.Immediate(u25){ .static = 4 }, i.imm);
        },
        else => try std.testing.expect(false),
    }

    var jalrxBadP = try makeParser("jalrx $t0, $t1, 4\n");
    defer jalrxBadP.deinit();
    try std.testing.expectError(ParseError.InvalidEnumeration, jalrxBadP.parseStatement());

    // I
    var sltiP = try makeParser("slti $t0, $a0, 100\n");
    defer sltiP.deinit();
    const sltiS = try sltiP.parseStatement();
    switch (sltiS.value) {
        .itype => |i| {
            try std.testing.expectEqual(isa.ITypeMnemo.slti, i.opcode);
            try std.testing.expectEqual(isa.Register.t0, i.rt);
            try std.testing.expectEqual(isa.Register.a0, i.rs);
            try std.testing.expectEqual(isa.Immediate(u25){ .static = 100 }, i.imm);
        },
        else => try std.testing.expect(false),
    }
}

test "parseStatement JType" {
    var jalxP = try makeParser("jalx $lr1, func\n");
    defer jalxP.deinit();
    const jalxS = try jalxP.parseStatement();
    switch (jalxS.value) {
        .jtype => |j| {
            try std.testing.expectEqual(isa.JTypeMnemo.jalx, j.opcode);
            try std.testing.expectEqual(isa.Register.lr1, j.linkRegister);
            switch (j.imm) {
                .dynamic => |dyn| try std.testing.expectEqualStrings("func", dyn.label),
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }

    var jalxBadP = try makeParser("jalx $s0, func\n");
    defer jalxBadP.deinit();
    try std.testing.expectError(ParseError.InvalidEnumeration, jalxBadP.parseStatement());
}

test "parseStatement data directives" {
    var sec1P = try makeParser(".section text\n");
    defer sec1P.deinit();
    const sec1S = try sec1P.parseStatement();
    switch (sec1S.value) {
        .section => |sec| try std.testing.expectEqualStrings("text", sec),
        else => try std.testing.expect(false),
    }

    var sec2P = try makeParser(".section \".data\"\n");
    defer sec2P.deinit();
    const sec2S = try sec2P.parseStatement();
    switch (sec2S.value) {
        .section => |sec| try std.testing.expectEqualStrings(".data", sec),
        else => try std.testing.expect(false),
    }

    var asciizP = try makeParser(".asciiz \"hello \" \"world\"\n");
    defer asciizP.deinit();
    const asciizS = try asciizP.parseStatement();
    switch (asciizS.value) {
        .asciiz => |str| try std.testing.expectEqualStrings("hello world", str),
        else => try std.testing.expect(false),
    }

    var nasciiP = try makeParser(".nascii \"foo\"\n");
    defer nasciiP.deinit();
    const nasciiS = try nasciiP.parseStatement();
    switch (nasciiS.value) {
        .nascii => |str| try std.testing.expectEqualStrings("foo", str),
        else => try std.testing.expect(false),
    }

    var byteP = try makeParser(".byte 1 2 'a' 'b' 0xFF\n");
    defer byteP.deinit();
    const byteS = try byteP.parseStatement();
    switch (byteS.value) {
        .bytes => |b| try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 'a', 'b', 255 }, b),
        else => try std.testing.expect(false),
    }

    var shortP = try makeParser(".short 10 20 0x1234\n");
    defer shortP.deinit();
    const shortS = try shortP.parseStatement();
    switch (shortS.value) {
        .shorts => |sh| try std.testing.expectEqualSlices(u16, &[_]u16{ 10, 20, 0x1234 }, sh),
        else => try std.testing.expect(false),
    }

    var wordP = try makeParser(".word 100 200 0xdeadbeef\n");
    defer wordP.deinit();
    const wordS = try wordP.parseStatement();
    switch (wordS.value) {
        .words => |w| try std.testing.expectEqualSlices(u32, &[_]u32{ 100, 200, 0xdeadbeef }, w),
        else => try std.testing.expect(false),
    }

    var pad1P = try makeParser(".pad 16\n");
    defer pad1P.deinit();
    const pad1S = try pad1P.parseStatement();
    switch (pad1S.value) {
        .padding => |pad| {
            try std.testing.expectEqual(@as(usize, 16), pad.size);
            try std.testing.expectEqual(@as(usize, 1), pad.alignment);
        },
        else => try std.testing.expect(false),
    }

    var pad2P = try makeParser(".pad 8 4 (16)\n");
    defer pad2P.deinit();
    const pad2S = try pad2P.parseStatement();
    switch (pad2S.value) {
        .padding => |pad| {
            try std.testing.expectEqual(@as(usize, 12), pad.size);
            try std.testing.expectEqual(@as(usize, 16), pad.alignment);
        },
        else => try std.testing.expect(false),
    }

    var ptrP = try makeParser(".ptr my_symbol\n");
    defer ptrP.deinit();
    const ptrS = try ptrP.parseStatement();
    switch (ptrS.value) {
        .ptr => |sym| try std.testing.expectEqualStrings("my_symbol", sym),
        else => try std.testing.expect(false),
    }

    var ptrloP = try makeParser(".lo16 my_symbol\n");
    defer ptrloP.deinit();
    const ptrloS = try ptrloP.parseStatement();
    switch (ptrloS.value) {
        .lo16 => |sym| try std.testing.expectEqualStrings("my_symbol", sym),
        else => try std.testing.expect(false),
    }

    var ptrhiP = try makeParser(".hi16 my_symbol\n");
    defer ptrhiP.deinit();
    const ptrhiS = try ptrhiP.parseStatement();
    switch (ptrhiS.value) {
        .hi16 => |sym| try std.testing.expectEqualStrings("my_symbol", sym),
        else => try std.testing.expect(false),
    }
}

test "statementEnd and semicolon terminator" {
    var p = try makeParser("add $t0, $t1, $t2; sub $t0, $t1, $t2\n");
    defer p.deinit();

    const s1 = try p.parseStatement();
    switch (s1.value) {
        .rtype => |r| try std.testing.expectEqual(isa.RTypeMnemo.add, r.funct),
        else => try std.testing.expect(false),
    }

    const s2 = try p.parseStatement();
    switch (s2.value) {
        .rtype => |r| try std.testing.expectEqual(isa.RTypeMnemo.sub, r.funct),
        else => try std.testing.expect(false),
    }
}

test "intentional syntax errors" {
    var missingComma = try makeParser("add $t0 $t1, $t2\n");
    defer missingComma.deinit();
    try std.testing.expectError(ParseError.UnexpectedToken, missingComma.parseStatement());

    var invalidInstr = try makeParser("bogus $t0, $t1, $t2\n");
    defer invalidInstr.deinit();
    try std.testing.expectError(ParseError.InvalidInstruction, invalidInstr.parseStatement());

    var missingParen = try makeParser("lw $t0, 4 $t1\n");
    defer missingParen.deinit();
    try std.testing.expectError(ParseError.UnexpectedToken, missingParen.parseStatement());

    var invalidDirective = try makeParser(".unknown_directive 123\n");
    defer invalidDirective.deinit();
    try std.testing.expectError(ParseError.NoMatch, invalidDirective.parseStatement());

    var noString = try makeParser(".asciiz\n");
    defer noString.deinit();
    try std.testing.expectError(ParseError.NoMatch, noString.parseStatement());

    var noBytes = try makeParser(".byte\n");
    defer noBytes.deinit();
    try std.testing.expectError(ParseError.NoMatch, noBytes.parseStatement());

    var badRegister = try makeParser("add $t0, $bogus, $t2\n");
    defer badRegister.deinit();
    try std.testing.expectError(ParseError.InvalidEnumeration, badRegister.parseStatement());

    var noDollar = try makeParser("add t0, $t1, $t2\n");
    defer noDollar.deinit();
    try std.testing.expectError(ParseError.UnexpectedToken, noDollar.parseStatement());

    var trailing = try makeParser("j loop extra_token\n");
    defer trailing.deinit();
    try std.testing.expectError(ParseError.UnexpectedToken, trailing.parseStatement());
}

test "skipToStatementStart and skipToStatementEnd" {
    var p = try makeParser("   \n\n  add $t0, $t1, $t2 bad stuff here ; sub $t0, $t1, $t2\n");
    defer p.deinit();

    try p.skipToStatementStart();
    const token = try p.lexer.next();
    try std.testing.expectEqualStrings("add", token.data);

    try p.skipToStatementEnd();
    try p.skipToStatementStart();
    const next_stmt = try p.parseStatement();
    switch (next_stmt.value) {
        .rtype => |r| try std.testing.expectEqual(isa.RTypeMnemo.sub, r.funct),
        else => try std.testing.expect(false),
    }
}

test "hello world integration parse" {
    const code =
        \\.section ".data"
        \\msg: .nascii "waaa"
        \\.section ".text"
        \\start:
        \\xor $zero, $zero, $zero
        \\lw $a0, msg($zero)
        \\orh $t0, $zero, 0xFFFF
        \\ori $t0, $t0, 0xFF00
        \\xor $a1, $a1, $a1
        \\loop:
        \\bge $a1, $a0, bye
        \\addi $t1, $a1, 4
        \\lb $t2, msg($t1)
        \\sb $t2, 0($t0)
        \\addi $a1, $a1, 1
        \\j loop
        \\bye:
        \\j bye
        \\
    ;

    var p = try makeParser(code);
    defer p.deinit();

    var count: usize = 0;
    while (p.lexer.frameHead != null) {
        try p.skipToStatementStart();
        const stmt = p.parseStatement() catch |err| {
            if (err == ParseError.UnexpectedEOF) break;
            if (p.lexer.frameHead == null) break;
            try p.skipToStatementEnd();
            continue;
        };
        count += 1;
        _ = stmt;
    }

    try std.testing.expectEqual(@as(usize, 15), count);
}
