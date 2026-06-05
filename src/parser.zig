const std = @import("std");
const isa = @import("isa.zig");

pub const ParseError = error {
    ArityMismatch,
    BuiltinPreprocessorOverride,
    InvalidCharacter,
    InvalidEnumeration,
    InvalidPreprocessorDirective,
    MacroRedefined,
    NoMatch,
    NumericOverflow,
    StrayPreprocessorTerminator,
    UnexpectedEOF,
    UnexpectedToken,
    UnexpectedWhitespace,
    UnknownMacro,
    UnterminatedPreprocessorDirective,
    UnterminatedScope,
    UnterminatedString,
};

const Macro = struct {
    name: []u8,
    args: std.ArrayList([]u8),
    body: []u8,
    filename: []const u8,

    pub fn init(filename: []const u8) !Macro {
        return .{
            .name = &[_]u8{},
            .args = std.ArrayList([]u8).empty,
            .body = &[_]u8{},
            .filename = filename,
        };
    }

    pub fn deinit(self: *Macro, allocator: std.mem.Allocator) void {
        for (self.args.items) |x| {
            allocator.free(x);
        }

        self.args.deinit(allocator);
        allocator.free(self.body);
        allocator.free(self.name);
    }
};

const Frame = struct {
    input: []const u8,
    pos: usize = 0,
    filename: []const u8,
};

fn isIdentifierChar(c: u8) bool {
    return (std.ascii.isAlphanumeric(c) or c == '_' or c == '\'');
}

pub const Parser = struct {
    input: []const u8 = &[_]u8{},
    pos: usize = 0,

    currentFilename: []const u8 = &[_]u8{},

    frames: std.ArrayList(Frame),
    macros: std.StringHashMap(Macro),
    substitutions: std.ArrayList(std.ArrayList(u8)),

    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Parser {
        return .{
            .allocator =  allocator,
            .io = io,
            .frames = try std.ArrayList(Frame).initCapacity(allocator, 1),
            .macros = std.StringHashMap(Macro).init(allocator),
            .substitutions = try std.ArrayList(std.ArrayList(u8)).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *Parser) void {
        var it = self.macros.iterator();
        while (it.next()) |x| {
            x.value_ptr.deinit(self.allocator);
        }

        for (self.substitutions.items) |*sub| {
            sub.deinit(self.allocator);
        }

        self.substitutions.deinit(self.allocator);
        self.macros.deinit();
        self.frames.deinit(self.allocator);
    }

    pub const Location = struct {
        filename: []const u8,
        line: usize,
        column: usize,
        start: usize,
        end: usize,
    };

    pub fn getLocationInfo(input: []const u8, pos_: usize, filename: []const u8) Location {
        const pos = @min(pos_, input.len);

        var line: usize = 1;
        var column: usize = 1;
        var start: usize = 0;

        for (input[0..pos], 0..) |c, i| {
            if (c == '\n') {
                line += 1;
                column = 1;
                start = i + 1;
            } else {
                column += 1;
            }
        }

        var end = pos;
        while (end < input.len and input[end] != '\n' and input[end] != '\r')
            : (end += 1) {}

        return .{
            .filename = filename,
            .line = line,
            .column = column,
            .start = start,
            .end = end,
        };
    }

    pub fn getLocation(self: *const Parser) Location {
        return getLocationInfo(self.input, self.pos, self.currentFilename);
    }

    pub fn pushFrame(self: *Parser, frameData: []const u8, filename: []const u8) !void {
        try self.frames.append(self.allocator, .{
            .input = self.input,
            .pos = self.pos,
            .filename = self.currentFilename,
        });
        self.input = frameData;
        self.pos = 0;
        self.currentFilename = filename;
    }

    pub fn popFrame(self: *Parser) !void {
        const top = self.frames.pop()
            orelse return ParseError.UnexpectedEOF;
        self.input = top.input;
        self.pos = top.pos;
        self.currentFilename = top.filename;
    }

    pub fn eof(self: *Parser) bool {
        while (true) {
            while (self.pos >= self.input.len) {
                self.popFrame() catch return true;
            }

            switch (self.input[self.pos]) {
                '%' => {
                    _ = self.parsePreprocessorDefinition() catch return false;
                    continue;
                },

                '@' => {
                    _ = self.expandPreprocessorInvocation() catch return false;
                    continue;
                },

                else => {},
            }

            break;
        }

        return self.pos >= self.input.len;
    }

    pub inline fn peekRawLine(self: *Parser) []const u8 {
        if (self.pos >= self.input.len) {
            return &.{};
        }

        var pos = self.pos;

        while (pos < self.input.len) {
            const c0 = self.input[pos];
            if (c0 == '\n') break;
            pos += 1;

            if (c0 != '\r') continue;
            if (pos + 1 >= self.input.len) break;
            const c1 = self.input[pos];
            if (c1 == '\n') break;
        }

        return self.input[self.pos..@min(pos + 1, self.input.len)];
    }

    pub inline fn peek(self: *Parser) ?u8 {
        if (self.eof()) return null;
        return self.input[self.pos];
    }

    pub inline fn char(self: *Parser, expected: u8) ParseError!void {
        if (self.eof()) return ParseError.UnexpectedEOF;
        if (self.input[self.pos] != expected) return ParseError.NoMatch;
        self.pos += 1;
    }

    pub fn takeWhile(self: *Parser, comptime pred: fn (u8) bool) []const u8 {
        if (self.pos >= self.input.len) {
            return &.{};
        }

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
        if (self.eof()) return 0;

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
        if (self.eof()) return ParseError.NoMatch;

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

        while (!self.eof()) {
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
            if (self.peek() == '0' and self.pos + 2 < self.input.len) {
                self.pos += 1;
                if (self.peek() == 'x') {
                    self.pos += 1;
                    break :blk try self.parseRawInteger(T, 16);
                } else if (self.peek() == 'b') {
                    self.pos += 1;
                    break :blk try self.parseRawInteger(T, 2);
                } else {
                    self.pos -= 1;
                }
            }

            break :blk try self.parseRawInteger(T, 10);
        };

        if (negative) {
            return -%x;
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

    pub fn parsePreprocessorDefinition(self: *Parser) !void {
        const start = self.pos;
        errdefer self.pos = start;

        if (self.pos >= self.input.len) return;
        if (self.input[self.pos] != '%') return;
        self.pos += 1;

        const directive = std.meta.stringToEnum(isa.PreprocessorDirective, try self.identifier1())
            orelse return ParseError.InvalidPreprocessorDirective;
        _ = try self.whitespace1();

        switch(directive) {
            .define => {
                const name = try self.identifier1();
                const payload = self.peekRawLine();
                self.pos += payload.len;

                var macro = try Macro.init(self.currentFilename);
                errdefer macro.deinit(self.allocator);
                macro.name = try self.allocator.dupe(u8, name);
                macro.body = try self.allocator.dupe(u8, payload);

                try self.macros.put(macro.name, macro);
            },

            .embed => {
                //TODO
                //Make new input buffer containing dump.  Take type.
                return ParseError.InvalidPreprocessorDirective;
            },

            .include => {
                const path = try self.parseStringLiteral();
                const contents = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(),
                    self.io, path, self.allocator, .unlimited);
                errdefer self.allocator.free(contents);
                try self.pushFrame(contents, path);
            },

            .macro => {
                const macroName = try self.identifier1();
                if (std.meta.stringToEnum(isa.PreprocessorBuiltin, macroName) != null) {
                    return ParseError.BuiltinPreprocessorOverride;
                }

                if (self.macros.contains(macroName)) return ParseError.MacroRedefined;

                _ = self.whitespace();
                try self.char('(');

                var macro = try Macro.init(self.currentFilename);
                errdefer macro.deinit(self.allocator);
                macro.name = try self.allocator.dupe(u8, macroName);

                while (!self.eof()) {
                    _ = self.whitespace();
                    if (self.peek() == ')') break;

                    const argName = try self.identifier1();
                    try macro.args.append(self.allocator, try self.allocator.dupe(u8, argName));

                    _ = self.whitespace();
                    switch (self.peek() orelse return ParseError.UnexpectedEOF) {
                        ',' => {
                            self.pos += 1;
                            continue;
                        },
                        ')' => break,
                        else => return ParseError.UnexpectedToken,
                    }
                }

                self.char(')') catch return ParseError.UnterminatedScope;
                _ = self.whitespace();

                try self.char('{');
                const bodyStart = self.pos;
                var braces: usize = 1;

                while (braces >= 1 and !self.eof()) {
                    const c = self.input[self.pos];
                    if (c == '{') {
                        braces += 1;
                    } else if (c == '}') {
                        braces -= 1;
                        if (braces == 0) break;
                    }

                    self.pos += 1;
                }

                if (self.eof()) return ParseError.UnexpectedEOF;
                macro.body = try self.allocator.dupe(u8, self.input[bodyStart..self.pos]);
                try self.char('}');
                try self.macros.put(macro.name, macro);
            },
        }
    }

    pub fn expandPreprocessorInvocation(self: *Parser) !bool {
        const start = self.pos;
        errdefer self.pos = start;

        if (self.pos >= self.input.len) {
            return false;
        }

        if (self.input[self.pos] != '@') {
            return false;
        }

        self.pos += 1;

        const parens = blk: {
            if (self.peek() == '(') {
                self.pos += 1;
                break :blk true;
            } else {
                break :blk false;
            }
        };

        const name = try self.identifier1();
        if (parens) self.char(')') catch return ParseError.UnterminatedScope;

        var argNames = std.ArrayList([]const u8).empty;
        defer argNames.deinit(self.allocator);
        if (self.peek() == '(') getArgs: {
            try self.char('(');
            if (self.peek() == ')') {
                try self.char(')');
                break :getArgs;
            }

            var i = self.pos;
            while (self.pos < self.input.len) {
                if (self.peek() != ')' and self.peek() != ',') {
                    self.pos += 1;
                    continue;
                }

                const arg = self.input[i..self.pos];
                try argNames.append(self.allocator, arg);
                i = self.pos + 1;

                if (self.peek() == ')') break;
                try self.char(',');
            }

            try self.char(')');
        }

        const macro = self.macros.get(name) orelse return ParseError.UnknownMacro;
        if (macro.args.items.len != argNames.items.len) {
            return ParseError.ArityMismatch;
        }

        const remaining = self.input[self.pos..];
        self.input = self.input[0..start];
        self.pos = start;
        try self.pushFrame(remaining, self.currentFilename);

        const body = try self.substituteArgs(macro, argNames.items);
        try self.pushFrame(body, macro.filename);

        return true;
    }

    fn substituteArgs(self: *Parser, macro: Macro, args: []const []const u8) ![]const u8 {
        var output = try std.ArrayList(u8).initCapacity(self.allocator, 3 * macro.body.len / 4);
        errdefer output.deinit(self.allocator);

        var i: usize = 0;
        while (i < macro.body.len) {
            const c = macro.body[i];

            i += 1;
            if (c != '@') {
                try output.append(self.allocator, c);
                continue;
            }

            var match: ?usize = null;
            for (macro.args.items, 0..) |arg, j| {
                if (std.mem.eql(u8, arg, macro.body[i..i + arg.len])) {
                    match = j;
                    break;
                }
            }

            if (match) |j| {
                try output.appendSlice(self.allocator, args[j]);
                i += macro.args.items[j].len;
            }
        }

        try self.substitutions.append(self.allocator, output);
        return output.items;
    }
};

test "binary" {
    const input = "0b0001001110101";
    var parser = try Parser.init(std.testing.allocator, undefined);
    parser.input = input;
    defer parser.deinit();
    const res: u32 = try Parser.parseInteger(&parser, u32);
    try std.testing.expectEqual(0b0001001110101, res);
}

test "hex" {
    const input = "0xCAFEbabe";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    parser.input = input;
    const res: u32 = try Parser.parseInteger(&parser, u32);
    try std.testing.expectEqual(0xCAFEbabe, res);
}

test "decimal" {
    const input = "-17623";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    parser.input = input;
    const res: i32 = try Parser.parseInteger(&parser, i32);
    try std.testing.expectEqual(-17623, res);
}

test "integer" {
    const input = "0xdeadbeef";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    parser.input = input;
    const res: u32 = try Parser.parseInteger(&parser, u32);
    try std.testing.expectEqual(0xdeadbeef, res);
}

test "register" {
    const input = "$t0";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    parser.input = input;
    const res = try Parser.parseRegisterName(&parser);
    try std.testing.expectEqual(isa.Register.t0, res);
}

test "string literal" {
    const input = "\"wawa\"";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    parser.input = input;
    const res = try Parser.parseStringLiteral(&parser);
    try std.testing.expectEqualStrings("wawa", res);
}

test "integer backtracking" {
    const input = "0 q"; 
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    parser.input = input;
    const res = try parser.parseInteger(u32);
    try std.testing.expectEqual(@as(u32, 0), res);
    try std.testing.expectEqual(@as(u8, ' '), parser.peek().?);
}

test "whitespace" {
    const input = "   \t  $t0";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    parser.input = input;
    _ = parser.whitespace();
    const reg = try parser.parseRegisterName();
    try std.testing.expectEqual(isa.Register.t0, reg);
}

test "preprocessor %define registration" {
    const input = "%define VALUE 0x42\n";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    
    try parser.pushFrame(input, "test.lc6");
    try parser.parsePreprocessorDefinition();
    
    try std.testing.expect(parser.macros.contains("VALUE"));
    const macro = parser.macros.get("VALUE").?;
    try std.testing.expectEqualStrings(" 0x42\n", macro.body);
    try std.testing.expectEqual(@as(usize, 0), macro.args.items.len);
}

test "preprocessor %macro with multiple arguments" {
    const input = "%macro multi_arg(a, b, c) { add @a, @b, @c }";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    
    try parser.pushFrame(input, "test.lc6");
    try parser.parsePreprocessorDefinition();
    
    try std.testing.expect(parser.macros.contains("multi_arg"));
    const macro = parser.macros.get("multi_arg").?;
    try std.testing.expectEqual(@as(usize, 3), macro.args.items.len);
    try std.testing.expectEqualStrings("a", macro.args.items[0]);
    try std.testing.expectEqualStrings("b", macro.args.items[1]);
    try std.testing.expectEqualStrings("c", macro.args.items[2]);
    try std.testing.expectEqualStrings(" add @a, @b, @c ", macro.body);
}

test "preprocessor %macro nested braces" {
    const input = "%macro nested() { { internal_block } text }";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    
    try parser.pushFrame(input, "test.lc6");
    try parser.parsePreprocessorDefinition();
    
    const macro = parser.macros.get("nested").?;
    try std.testing.expectEqualStrings(" { internal_block } text ", macro.body);
}

test "preprocessor keyword override" {
    const input = "%macro ifda(reg) { add $t0, $t0, @reg }";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    
    try parser.pushFrame(input, "test.lc6");
    
    const invalid_input = "%macro if(reg) { halt }";
    var p2 = try Parser.init(std.testing.allocator, undefined);
    defer p2.deinit();
    try p2.pushFrame(invalid_input, "test.lc6");
    
    try std.testing.expectError(ParseError.BuiltinPreprocessorOverride, p2.parsePreprocessorDefinition());
}

test "preprocessor %macro expansion substitution" {
    const macro_def = "%macro load_add(reg, src) { lw @reg, $s0, @src\n add @reg, @reg, @reg }";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    
    try parser.pushFrame(macro_def, "test.lc6");
    try parser.parsePreprocessorDefinition();
    
    const invocation = "@load_add($t1,10)";
    try parser.pushFrame(invocation, "test.lc6");
    
    const expanded = try parser.expandPreprocessorInvocation();
    try std.testing.expect(expanded);
    
    try std.testing.expectEqualStrings(" lw $t1, $s0, 10\n add $t1, $t1, $t1 ", parser.input);
}

test "preprocessor zero-arity %macro expansion" {
    const input = "%macro zero_reg() { $s0 }";
    var parser = try Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    
    try parser.pushFrame(input, "test.lc6");
    try parser.parsePreprocessorDefinition();
    
    try parser.pushFrame("@zero_reg()", "test.lc6");
    const expanded = try parser.expandPreprocessorInvocation();
    try std.testing.expect(expanded);
    try std.testing.expectEqualStrings(" $s0 ", parser.input);
}
