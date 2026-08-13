const std = @import("std");
const isa = @import("isa.zig");

pub const LexerError = error {
    ArityMismatch,
    BuiltinPreprocessorOverride,
    ExpectedIdentifier,
    InvalidCharacter,
    InvalidEscape,
    InvalidPreprocessorDirective,
    MacroNotAllowedHere,
    MacroRedefined,
    StrayElse,
    StrayEndif,
    StrayEndmacro,
    TooManyFrames,
    UnexpectedEOF,
    UnknownMacro,
    UnterminatedComment,
    UnterminatedPreprocessorDirective,
    UnterminatedString,
} || std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError || std.Io.Dir.StatFileError;

const Macro = struct {
    name: []const u8,
    args: std.ArrayList([]const u8),
    body: []const u8,
    filename: []const u8,

    pub fn init(filename: []const u8) Macro {
        return .{
            .name = &[_]u8{},
            .args = std.ArrayList([]const u8).empty,
            .body = &[_]u8{},
            .filename = filename,
        };
    }

    pub fn deinit(self: *Macro, allocator: std.mem.Allocator) void {
        self.args.deinit(allocator);
    }
};

const Frame = struct {
    pos: usize = 0,
    input: []const u8,
    filename: []const u8,
    next: ?*Frame,
};

pub const Tokenizer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stringArena: std.heap.ArenaAllocator,
    frameArena: std.heap.ArenaAllocator,
    macros: std.StringHashMap(Macro),

    frameHead: ?*Frame,

    allowMacroDefinition: bool = true,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Tokenizer {
        return .{
            .io = io,
            .allocator = allocator,
            .stringArena = std.heap.ArenaAllocator.init(allocator),
            .frameArena = std.heap.ArenaAllocator.init(allocator),
            .macros = std.StringHashMap(Macro).init(allocator),
            .frameHead = null,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        var it = self.macros.iterator();
        while (it.next()) |x| {
            x.value_ptr.deinit(self.allocator);
        }

        self.macros.deinit();
        self.frameArena.deinit();
        self.stringArena.deinit();
    }

    pub const Token = struct {
        pub const Kind = enum {
            char,
            colon,
            comma,
            dollar,
            dot,
            eof,
            identifier,
            lparen,
            minus,
            newline,
            number,
            plus,
            rparen,
            semicolon,
            string,
            tilde,
            whitespace,
        };

        kind: Kind,
        data: []const u8,
    };

    pub const Bookmark = struct {
        frame: ?*Frame,
        pos: [12]usize,
    };

    pub fn bookmark(self: *Tokenizer) LexerError!Bookmark {
        var b = Bookmark{
            .frame = self.frameHead,
            .pos = [_]usize{0} ** 12,
        };

        var it = self.frameHead;
        var i: usize = 0;
        while (it) |f| : (it = f.next) {
            if (i < b.pos.len) {
                b.pos[i] = f.pos;
            } else {
                return LexerError.TooManyFrames;
            }

            i += 1;
        }

        return b;
    }

    pub fn restore(self: *Tokenizer, mark: Bookmark) void {
        self.frameHead = mark.frame;

        var it = self.frameHead;
        var i: usize = 0;
        while (it) |f| : (it = f.next) {
            if (i < mark.pos.len) f.pos = mark.pos[i];
            i += 1;
        }
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

    pub fn getLocation(self: *const Tokenizer) ?Location {
        const head = self.frameHead orelse return null;
        return getLocationInfo(head.input, head.pos, head.filename);
    }

    pub fn pushFrame(self: *Tokenizer, frameData: []const u8, filename: []const u8) LexerError!void {
        const frame = try self.frameArena.allocator().create(Frame);
        errdefer self.frameArena.allocator().destroy(frame);

        frame.* = .{
            .pos = 0,
            .input = frameData,
            .filename = filename,
            .next = self.frameHead,
        };

        self.frameHead = frame;
    }

    pub fn openFile(self: *Tokenizer, filename: []const u8) LexerError!void {
        const cwd = std.Io.Dir.cwd();
        const path: []const u8 = if (self.frameHead) |head| blk: {
            const dirname = std.fs.path.dirname(head.filename) orelse ".";
            break :blk try std.fs.path.join(self.stringArena.allocator(), &[_][]const u8{dirname, filename});
        } else filename;

        const data = try cwd.readFileAlloc(self.io, path, self.stringArena.allocator(), .unlimited);
        errdefer self.stringArena.allocator().free(data);

        return try self.pushFrame(data, filename);
    }

    pub fn popFrame(self: *Tokenizer) void {
        self.frameHead = self.frameHead.?.next orelse null;
    }

    const State = enum {
        start,
        whitespace,
        character,
        character_end,
        slash,
        backslash,
        line_comment,
        block_comment,
        block_comment_star,
        number,
        decimal,
        binary,
        hex,
        octal,
        identifier,
        string,
        pp_directive,
        pp_expansion,
    };

    const ArgpState = enum {
        lparen,
        argname,
        argsep,
    };

    fn peek(self: *Tokenizer) u8 {
        const head: *Frame = self.frameHead orelse return 0;
        if (head.pos >= head.input.len) return 0;
        return head.input[head.pos];
    }

    fn getEscape(frame: *Frame) LexerError!u8 {
        if (frame.pos >= frame.input.len) return LexerError.UnexpectedEOF;

        frame.pos += 1;
        switch (frame.input[frame.pos - 1]) {
            '0' => return 0,
            '"' => return '"',
            '\'' => return '\'',
            '\\' => return '\\',
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'x' => {
                if (frame.pos + 2 >= frame.input.len) return LexerError.UnexpectedEOF;
                const hi = frame.input[frame.pos + 0];
                const lo = frame.input[frame.pos + 1];
                frame.pos += 2;

                const n1 = std.fmt.charToDigit(hi, 16) catch return LexerError.InvalidEscape;
                const n0 = std.fmt.charToDigit(lo, 16) catch return LexerError.InvalidEscape;
                return @intCast((n1 << 4) | n0);
            },
            else => return LexerError.InvalidEscape,
        }

        unreachable;
    }

    pub fn showErrorHere(self: *const Tokenizer, err: anyerror) void {
        const loc = self.getLocation() orelse {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            return;
        };

        var depth: usize = 0;
        var it = self.frameHead;
        while (it) |frame| {
            depth += 1;
            it = frame.next;
        }

        var frames: [64]*const Frame = undefined;
        var count: usize = 0;

        it = self.frameHead;
        while (it) |frame| : (it = frame.next) {
            frames[count] = frame;
            count += 1;
        }

        var i = count;
        while (i > 1) {
            i -= 1;
            const frame = frames[i];
            const frame_loc = Tokenizer.getLocationInfo(
                frame.input,
                frame.pos,
                frame.filename,
            );

            std.debug.print("in buffer expanded from {s}:{d}:{d}\n", .{frame_loc.filename, frame_loc.line, frame_loc.column});
        }

        const frame = self.frameHead.?;
        const snippet = frame.input[loc.start..loc.end];
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{loc.filename, loc.line, loc.column, @errorName(err)});
        std.debug.print("{s}\n", .{snippet});

        for (snippet[0..loc.column - 1]) |c| switch (c) {
            '\t' => std.debug.print("\t", .{}),
            else => std.debug.print(" ",  .{}),
        };

        std.debug.print("^\n", .{});
    }

    pub fn skipWhitespace(self: *Tokenizer) LexerError!void {
        while (self.frameHead != null) {
            const mark = try self.bookmark();
            const token = try self.next();
            if (token.kind == .whitespace) continue;
            self.restore(mark);
            return;
        }

        return LexerError.UnexpectedEOF;
    }

    pub fn nextWord(self: *Tokenizer) LexerError!Token {
        while (self.frameHead != null) {
            const token = try self.next();
            if (token.kind == .whitespace or token.kind == .newline) continue;
            return token;
        }

        return LexerError.UnexpectedEOF;
    }

    pub fn next(self: *Tokenizer) LexerError!Token {
        var head: *Frame = self.frameHead orelse return LexerError.UnexpectedEOF;
        var tokenStart = head.pos;

        var stringBuilder = std.ArrayList(u8).empty;
        var char: u8 = 0;
        return state: switch (State.start) {
            .start => switch (self.peek()) {
                0 => {
                    if (self.frameHead != null) {
                        self.frameHead = head.next;

                        if (head.next) |newHead| {
                            head = newHead;
                            tokenStart = head.pos;
                            continue :state .start;
                        }
                    }

                    return .{.kind = .eof, .data = &[_]u8{}};
                },

                ' ', '\r', '\t' => {
                    tokenStart = head.pos;
                    head.pos += 1;
                    continue :state .whitespace;
                },

                'a'...'z', 'A'...'Z' => {
                    head.pos += 1;
                    continue :state .identifier;
                },

                '0' => {
                    head.pos += 1;
                    continue :state .number;
                },

                '1'...'9' => {
                    continue :state .decimal;
                },

                '\n' => {
                    head.pos += 1;
                    return .{.kind = .newline, .data = head.input[tokenStart..head.pos]};
                },

                '.' => {
                    head.pos += 1;
                    return .{.kind = .dot, .data = head.input[tokenStart..head.pos]};
                },

                ',' => {
                    head.pos += 1;
                    return .{.kind = .comma, .data = head.input[tokenStart..head.pos]};
                },

                ':' => {
                    head.pos += 1;
                    return .{.kind = .colon, .data = head.input[tokenStart..head.pos]};
                },

                ';' => {
                    head.pos += 1;
                    return .{.kind = .semicolon, .data = head.input[tokenStart..head.pos]};
                },

                '$' => {
                    head.pos += 1;
                    return .{.kind = .dollar, .data = head.input[tokenStart..head.pos]};
                },

                '+' => {
                    head.pos += 1;
                    return .{.kind = .plus, .data = head.input[tokenStart..head.pos]};
                },

                '-' => {
                    head.pos += 1;
                    return .{.kind = .minus, .data = head.input[tokenStart..head.pos]};
                },

                '~' => {
                    head.pos += 1;
                    return .{.kind = .tilde, .data = head.input[tokenStart..head.pos]};
                },

                '(' => {
                    head.pos += 1;
                    return .{.kind = .lparen, .data = head.input[tokenStart..head.pos]};
                },

                ')' => {
                    head.pos += 1;
                    return .{.kind = .rparen, .data = head.input[tokenStart..head.pos]};
                },

                '"' => {
                    head.pos += 1;
                    tokenStart = head.pos;
                    continue :state .string;
                },

                '\'' => {
                    head.pos += 1;
                    tokenStart = head.pos;
                    continue :state .character;
                },

                '/' => {
                    head.pos += 1;
                    continue :state .slash;
                },

                '\\' => {
                    head.pos += 1;
                    continue :state .backslash;
                },

                '%' => {
                    head.pos += 1;
                    continue :state .pp_directive;
                },

                '@' => {
                    head.pos += 1;
                    continue :state .pp_expansion;
                },

                else => LexerError.InvalidCharacter,
            },

            .whitespace => switch (self.peek()) {
                ' ', '\t', '\r' => {
                    head.pos += 1;
                    continue :state .whitespace;
                },

                else => {
                    return .{.kind = .whitespace, .data = head.input[tokenStart..head.pos]};
                },
            },

            .identifier => switch (self.peek()) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '\'' => {
                    head.pos += 1;
                    continue :state .identifier;
                },

                else => {
                    return .{.kind = .identifier, .data = head.input[tokenStart..head.pos]};
                },
            },

            .number => switch (self.peek()) {
                'b', 'B' => {
                    head.pos += 1;
                    continue :state .binary;
                },

                'o', 'O' => {
                    head.pos += 1;
                    continue :state .octal;
                },

                'x', 'X' => {
                    head.pos += 1;
                    continue :state .hex;
                },

                else => continue :state .decimal,
            },

            .binary => switch (self.peek()) {
                '0', '1' => {
                    head.pos += 1;
                    continue :state .binary;
                },

                else => {
                    return .{.kind = .number, .data = head.input[tokenStart..head.pos]};
                },
            },

            .octal => switch (self.peek()) {
                '0'...'7' => {
                    head.pos += 1;
                    continue :state .octal;
                },

                else => {
                    return .{.kind = .number, .data = head.input[tokenStart..head.pos]};
                },
            },

            .decimal => switch (self.peek()) {
                '0'...'9' => {
                    head.pos += 1;
                    continue :state .decimal;
                },

                else => {
                    return .{.kind = .number, .data = head.input[tokenStart..head.pos]};
                },
            },

            .hex => switch (self.peek()) {
                '0'...'9', 'a'...'f', 'A'...'F' => {
                    head.pos += 1;
                    continue :state .hex;
                },
                else => {
                    return .{.kind = .number, .data = head.input[tokenStart..head.pos]};
                },
            },

            .slash => switch (self.peek()) {
                '*' => {
                    head.pos += 1;
                    continue :state .block_comment;
                },

                '/' => {
                    head.pos += 1;
                    continue :state .line_comment;
                },

                else => return LexerError.InvalidCharacter,
            },

            .backslash => switch (self.peek()) {
                '\n' => {
                    head.pos += 1;
                    tokenStart = head.pos;
                    continue :state .start;
                },

                else => return LexerError.InvalidCharacter,
            },

            .line_comment => switch (self.peek()) {
                0 => {
                    continue :state .start;
                },

                '\n' => {
                    tokenStart = head.pos;
                    continue :state .start;
                },

                else => {
                    head.pos += 1;
                    continue :state .line_comment;
                }
            },

            .block_comment => switch (self.peek()) {
                0 => return LexerError.UnterminatedComment,

                '*' => {
                    head.pos += 1;
                    continue :state .block_comment_star;
                },

                else => {
                    head.pos += 1;
                    continue :state .block_comment;
                },
            },

            .block_comment_star => switch (self.peek()) {
                0 => return LexerError.UnterminatedComment,

                '/' => {
                    head.pos += 1;
                    tokenStart = head.pos;
                    continue :state .start;
                },

                else => {
                    head.pos += 1;
                    continue :state .block_comment;
                },
            },

            .character => switch (self.peek()) {
                0 => return LexerError.UnterminatedString,

                '\\' => {
                    head.pos += 1;
                    char = try getEscape(head);
                    continue :state .character_end;
                },

                else => |c| {
                    head.pos += 1;
                    char = c;
                    continue :state .character_end;
                },
            },

            .character_end => switch (self.peek()) {
                0 => return LexerError.UnterminatedString,

                '\'' => {
                    head.pos += 1;
                    return .{.kind = .char, .data = &[_]u8{char}};
                },

                else => {
                    tokenStart = head.pos;
                    head.pos += 1;
                    continue :state .character_end;
                },
            },

            .string => switch (self.peek()) {
                0 => return LexerError.UnterminatedString,

                '"' => {
                    try stringBuilder.appendSlice(self.stringArena.allocator(), head.input[tokenStart..head.pos]);
                    head.pos += 1;
                    return .{.kind = .string, .data = stringBuilder.items};
                },

                '\\' => {
                    try stringBuilder.appendSlice(self.stringArena.allocator(), head.input[tokenStart..head.pos]);

                    head.pos += 1;
                    if (self.peek() == '\n') {
                        head.pos += 1;
                    } else {
                        try stringBuilder.append(self.stringArena.allocator(), try getEscape(head));
                    }

                    tokenStart = head.pos;
                    continue :state .string;
                },

                else => {
                    head.pos += 1;
                    continue :state .string;
                },
            },

            .pp_directive => {
                try self.ppDirective(head);

                head = self.frameHead.?;
                tokenStart = head.pos;
                continue :state .start;
            },

            .pp_expansion => {
                const frame = try self.ppExpansion(head);

                tokenStart = 0;
                head = frame;
                self.frameHead = frame;
                continue :state .start;
            },
        };
    }

    fn ppDirective(self: *Tokenizer, head: *Frame) LexerError!void {
        var stringBuilder = std.ArrayList(u8).empty;

        const directiveStart = head.pos - 1;
        var tokenStart = head.pos;

        while (head.pos < head.input.len and std.ascii.isAlphanumeric(head.input[head.pos]))
            : (head.pos += 1) {}

        const directive = std.meta.stringToEnum(isa.PreprocessorDirective, head.input[tokenStart..head.pos])
            orelse return LexerError.InvalidPreprocessorDirective;

        while (head.pos < head.input.len and (head.input[head.pos] == ' ' or head.input[head.pos] == '\t'))
            : (head.pos += 1) {}

        switch (directive) {
            .define => {
                if (self.allowMacroDefinition == false) return LexerError.MacroNotAllowedHere;

                tokenStart = head.pos;
                while (head.pos < head.input.len and std.ascii.isAlphanumeric(head.input[head.pos]))
                    : (head.pos += 1) {}

                const name = head.input[tokenStart..head.pos];
                if (std.meta.stringToEnum(isa.PreprocessorBuiltin, name)) |_| {
                    return LexerError.BuiltinPreprocessorOverride;
                }

                while (head.pos < head.input.len and (head.input[head.pos] == ' ' or head.input[head.pos] == '\t'))
                    : (head.pos += 1) {}
                
                tokenStart = head.pos;

                while (head.pos < head.input.len and (head.input[head.pos] != '\n'))
                    : (head.pos += 1) {}

                var macro = Macro.init(head.filename);
                macro.name = name;
                macro.body = head.input[tokenStart..head.pos];

                const gpr = try self.macros.getOrPut(macro.name);
                if (gpr.found_existing) {
                    return LexerError.MacroRedefined;
                    //gpr.value_ptr.deinit(self.allocator);
                }

                gpr.value_ptr.* = macro;

                const newInput = try self.stringArena.allocator().dupe(u8, head.input);
                for (newInput[directiveStart..head.pos]) |*c| {
                    if (c.* != '\n' and c.* != '\r') c.* = ' ';
                }

                head.input = newInput;
                head.pos = directiveStart;

                return;
            },

            .include => {
                const filename = try self.nextWord();
                if (filename.kind != .string) return LexerError.InvalidPreprocessorDirective;

                try self.openFile(filename.data);
                return;
            },

            .embed => {
                const filename = try self.next();
                if (filename.kind != .string) return LexerError.InvalidPreprocessorDirective;

                const cwd = std.Io.Dir.cwd();
                const dirname = std.fs.path.dirname(head.filename) orelse ".";
                const path = try std.fs.path.join(self.stringArena.allocator(), &[_][]const u8{dirname, filename.data});
                const stat = try cwd.statFile(self.io, path, .{});

                var hexes = try self.stringArena.allocator().alloc(u8, @intCast(stat.size * 5));
                errdefer self.stringArena.allocator().free(hexes);

                const data = try cwd.readFileAlloc(self.io, path, self.stringArena.allocator(), .unlimited);
                defer self.stringArena.allocator().free(data);

                var streamPosition: usize = 0;
                for (data) |byte| {
                    _ = try std.fmt.bufPrint(hexes[streamPosition..], "0x{x:0>2} ", .{byte});
                    streamPosition += 5;
                }

                try self.pushFrame(hexes, path);
                return;
            },

            .filename => {
                try stringBuilder.append(self.stringArena.allocator(), '"');
                try stringBuilder.appendSlice(self.stringArena.allocator(), head.filename);
                try stringBuilder.append(self.stringArena.allocator(), '"');

                try self.pushFrame(stringBuilder.items, head.filename);
                return;
            },

            .line => {
                const loc = self.getLocation().?;
                const line = try std.fmt.allocPrint(self.stringArena.allocator(), "\"{}\"", .{loc.line});

                try self.pushFrame(stringBuilder.items, line);
                return;
            },

            .macro => {
                if (self.allowMacroDefinition == false) return LexerError.MacroNotAllowedHere;
                self.allowMacroDefinition = false;
                defer self.allowMacroDefinition = true;

                const macroName = try self.nextWord();
                if (macroName.kind != .identifier) return LexerError.ExpectedIdentifier;

                while (head.pos < head.input.len and (head.input[head.pos] == ' ' or head.input[head.pos] == '\t'))
                    : (head.pos += 1) {}

                var macro = Macro.init(head.filename);
                errdefer macro.deinit(self.allocator);
                macro.name = macroName.data;
                macro.filename = head.filename;

                argparse: switch (ArgpState.lparen) {
                    .lparen => {
                        const lparen = try self.next();
                        if (lparen.kind != .lparen) return LexerError.InvalidPreprocessorDirective;

                        const mark = try self.bookmark();
                        const future = try self.nextWord();
                        if (future.kind == .rparen) {
                            break :argparse;
                        } else {
                            self.restore(mark);
                            continue :argparse .argname;
                        }
                    },

                    .argname => {
                        const argName = try self.nextWord();
                        if (argName.kind != .identifier) return LexerError.ExpectedIdentifier;

                        try macro.args.append(self.allocator, argName.data);
                        continue :argparse .argsep;
                    },

                    .argsep => {
                        const sep = try self.nextWord();
                        switch (sep.kind) {
                            .comma => continue :argparse .argname,
                            .rparen => break :argparse,
                            else => return LexerError.InvalidCharacter,
                        }
                    },
                }

                var lastError = try self.bookmark();

                while (head.pos < head.input.len and (head.input[head.pos] == '\n'))
                    : (head.pos += 1) {}

                tokenStart = head.pos;
                while (self.frameHead != null and self.frameHead.?.pos < self.frameHead.?.input.len) {
                    _ = self.next() catch |err| switch (err) {
                        LexerError.StrayEndmacro => break,

                        LexerError.UnexpectedEOF => return LexerError.UnterminatedPreprocessorDirective,

                        LexerError.InvalidCharacter => {
                            self.frameHead.?.pos += 1;
                            continue;
                        },

                        else => {
                            if (lastError.frame == self.frameHead and lastError.pos[0] == self.frameHead.?.pos) {
                                self.frameHead.?.pos += 1;
                            }

                            lastError = try self.bookmark();
                            continue;
                        },
                    };
                }

                const tokenEnd = head.pos - "%endmacro".len;
                macro.body = head.input[tokenStart..tokenEnd];

                const gpr = try self.macros.getOrPut(macro.name);
                if (gpr.found_existing) {
                    return LexerError.MacroRedefined;
                    //gpr.value_ptr.deinit(self.allocator);
                }

                gpr.value_ptr.* = macro;

                const newInput = try self.stringArena.allocator().dupe(u8, head.input);
                for (newInput[directiveStart..head.pos]) |*c| {
                    if (c.* != '\n' and c.* != '\r') c.* = ' ';
                }

                head.input = newInput;
                head.pos = directiveStart;
                return;
            },

            .ifdef, .ifndef => |yn| {
                const name = try self.nextWord();
                if (name.kind != .identifier) return LexerError.ExpectedIdentifier;

                const enabled = self.macros.contains(name.data) == (yn == .ifdef);
                var assigned: bool = false;
                var correctScope: bool = enabled;

                var lastError = try self.bookmark();

                tokenStart = head.pos;
                var tokenEnd = head.pos;
                while (head.pos < head.input.len) {
                    _ = self.next() catch |err| switch (err) {
                        LexerError.StrayEndif => {
                            if (!assigned) {
                                if (correctScope) {
                                    tokenEnd = head.pos - "%endif".len;
                                    assigned = true;
                                }
                            }

                            break;
                        },

                        LexerError.StrayElse => {
                            if (!assigned) {
                                if (correctScope) {
                                    tokenEnd = head.pos - "%else".len;
                                    correctScope = false;
                                    assigned = true;
                                } else {
                                    tokenStart = head.pos;
                                    correctScope = true;
                                }
                            }

                            continue;
                        },

                        LexerError.UnexpectedEOF => return LexerError.UnterminatedPreprocessorDirective,

                        LexerError.InvalidCharacter => {
                            self.frameHead.?.pos += 1;
                            continue;
                        },

                        else => {
                            if (lastError.frame == self.frameHead and lastError.pos[0] == self.frameHead.?.pos) {
                                self.frameHead.?.pos += 1;
                            }

                            lastError = try self.bookmark();
                            continue;
                        },
                    };
                }

                std.debug.assert(assigned);
                std.debug.assert(tokenStart < tokenEnd);

                try self.pushFrame(head.input[tokenStart..tokenEnd], head.filename);
                return;
            },

            .@"else" => return LexerError.StrayElse,
            .endif => return LexerError.StrayEndif,
            .endmacro => return LexerError.StrayEndmacro,
        }
    }

    inline fn ppExpansion(self: *Tokenizer, head: *Frame) LexerError!*Frame {
        const tokenStart = head.pos;
        const name = try self.nextWord();
        if (name.kind != .identifier) return LexerError.ExpectedIdentifier;

        if (std.meta.stringToEnum(isa.PreprocessorBuiltin, name.data)) |builtin| {
            return ppBuiltinExpansion(self, head, builtin);
        } else if (self.macros.get(name.data)) |macro| {
            return ppMacroExpansion(self, head, macro);
        } else {
            head.pos = tokenStart; // rewind for injection
            return LexerError.UnknownMacro;
        }
    }

    fn ppBuiltinExpansion(self: *Tokenizer, head: *Frame, builtin: isa.PreprocessorBuiltin) LexerError!*Frame {
        var stringBuilder = std.ArrayList(u8).empty;
        errdefer stringBuilder.deinit(self.stringArena.allocator());

        switch (builtin) {
            .alignOf => {
                const lparen = try self.next();
                if (lparen.kind != .lparen) return LexerError.InvalidPreprocessorDirective;

                const dot = try self.next();
                if (dot.kind != .dot) return LexerError.InvalidPreprocessorDirective;

                const directiveToken = try self.next();
                if (directiveToken.kind != .identifier) return LexerError.InvalidPreprocessorDirective;

                const directive = std.meta.stringToEnum(isa.DataDirective, directiveToken.data)
                    orelse return LexerError.InvalidPreprocessorDirective;

                const rparen = try self.next();
                if (rparen.kind != .rparen) return LexerError.InvalidPreprocessorDirective;

                const alignment: []const u8 = switch (directive) {
                    .asciiz  => "1",
                    .byte    => "1",
                    .nascii  => "4",
                    .pad     => "1",
                    .ptr     => "4",
                    .section => return LexerError.InvalidPreprocessorDirective,
                    .short   => "2",
                    .word    => "4",
                };

                const frame = try self.frameArena.allocator().create(Frame);
                frame.pos = 0;
                frame.input = alignment;
                frame.filename = head.filename;
                frame.next = head;

                return frame;
            },

            .sizeOf => {
                const lparen = try self.next();
                if (lparen.kind != .lparen) return LexerError.InvalidPreprocessorDirective;

                const dot = try self.next();
                if (dot.kind != .dot) return LexerError.InvalidPreprocessorDirective;

                const directiveToken = try self.next();
                if (directiveToken.kind != .identifier) return LexerError.InvalidPreprocessorDirective;

                const directive = std.meta.stringToEnum(isa.DataDirective, directiveToken.data)
                    orelse return LexerError.InvalidPreprocessorDirective;

                const rparen = try self.next();
                if (rparen.kind != .rparen) return LexerError.InvalidPreprocessorDirective;

                const size: []const u8 = switch (directive) {
                    .asciiz  => "0",
                    .byte    => "1",
                    .nascii  => "4",
                    .pad     => "0",
                    .ptr     => "4",
                    .section => return LexerError.InvalidPreprocessorDirective,
                    .short   => "2",
                    .word    => "4",
                };

                const frame = try self.frameArena.allocator().create(Frame);
                frame.pos = 0;
                frame.input = size;
                frame.filename = head.filename;
                frame.next = head;

                return frame;
            },

            .stringify => {
                const lparen = try self.next();
                if (lparen.kind != .lparen) return LexerError.InvalidPreprocessorDirective;

                var depth: usize = 0;
                var lastError = try self.bookmark();
                while (self.frameHead != null and self.frameHead.?.pos < self.frameHead.?.input.len) expand: {
                    // std.debug.print("input.ptr={*} len={} pos={}\n", .{self.frameHead.?.input.ptr, self.frameHead.?.input.len, self.frameHead.?.pos});
                    const token: Token = self.next() catch |err| switch (err) {
                        LexerError.UnexpectedEOF => break :expand,
                        else => {
                            if (lastError.frame == self.frameHead and lastError.pos[0] == self.frameHead.?.pos) {
                                self.frameHead.?.pos += 1;
                            }

                            lastError = try self.bookmark();
                            continue;
                        },
                    };

                    switch (token.kind) {
                        .string => {
                            try stringBuilder.append(self.stringArena.allocator(), '"');

                            // don't even risk it
                            for (token.data) |c| {
                                try stringBuilder.appendSlice(self.stringArena.allocator(), "'\\x");
                                try stringBuilder.append(self.stringArena.allocator(), (c >> 4) & 0xF);
                                try stringBuilder.append(self.stringArena.allocator(), (c >> 0) & 0xF);
                            }

                            try stringBuilder.append(self.stringArena.allocator(), '"');
                        },

                        .char => {
                            try stringBuilder.appendSlice(self.stringArena.allocator(), "'\\x");
                            try stringBuilder.append(self.stringArena.allocator(), (token.data[0] >> 4) & 0xF);
                            try stringBuilder.append(self.stringArena.allocator(), (token.data[0] >> 0) & 0xF);
                            try stringBuilder.append(self.stringArena.allocator(), '\'');
                        },

                        .lparen => {
                            depth += 1;
                            try stringBuilder.appendSlice(self.stringArena.allocator(), token.data);
                        },

                        .rparen => {
                            depth -= 1;
                            if (depth == 0) {
                                break :expand;
                            } else {
                                try stringBuilder.appendSlice(self.stringArena.allocator(), token.data);
                            }
                        },

                        else => try stringBuilder.appendSlice(self.stringArena.allocator(), token.data),
                    }
                }

                const frame = try self.frameArena.allocator().create(Frame);
                frame.pos = 0;
                frame.input = stringBuilder.items;
                frame.filename = head.filename;
                frame.next = head;

                return frame;
            },
        }

        unreachable;
    }

    fn ppMacroExpansion(self: *Tokenizer, head: *Frame, macro: Macro) LexerError!*Frame {
        var args = std.StringHashMap([]const u8).init(self.allocator);
        defer args.deinit();

        argparse: switch (ArgpState.lparen) {
            .lparen => {
                const lparen = try self.next();
                if (lparen.kind != .lparen) return LexerError.InvalidPreprocessorDirective;

                const mark = try self.bookmark();
                const future = try self.nextWord();
                if (future.kind == .rparen) {
                    break :argparse;
                } else {
                    self.restore(mark);
                    continue :argparse .argname;
                }
            },

            .argname => {
                const argName = try self.nextWord();
                if (argName.kind != .identifier) return LexerError.ExpectedIdentifier;

                const argc = args.count();
                if (argc >= macro.args.items.len) {
                    return LexerError.ArityMismatch;
                }

                const gpr = try args.getOrPut(macro.args.items[argc]);
                gpr.value_ptr.* = argName.data;

                continue :argparse .argsep;
            },

            .argsep => {
                const sep = try self.nextWord();
                switch (sep.kind) {
                    .comma => continue :argparse .argname,
                    .rparen => break :argparse,
                    else => return LexerError.InvalidCharacter,
                }
            },
        }

        if (args.count() != macro.args.items.len) {
            return LexerError.ArityMismatch;
        }

        const frame = try self.frameArena.allocator().create(Frame);
        self.frameHead = frame;
        frame.next = head;
        frame.filename = head.filename;
        frame.pos = 0;

        frame.input = macro.body;

        if (args.count() == 0) {
            return frame;
        }

        const KV = std.StringHashMap(Macro).KV;
        var stash = try std.ArrayList(KV).initCapacity(self.allocator, args.count());
        defer stash.deinit(self.allocator);

        for (macro.args.items) |key| {
            if (self.macros.fetchRemove(key)) |kv| {
                stash.appendAssumeCapacity(kv);
            }
        }

        defer for (stash.items) |kv| {
            self.macros.putAssumeCapacity(kv.key, kv.value);
        };

        var stringBuilder = try std.ArrayList(u8).initCapacity(self.stringArena.allocator(), 5 * macro.body.len / 4);
        var lastError = try self.bookmark();
        while (self.frameHead != null and self.frameHead.?.pos < self.frameHead.?.input.len) subst: {
            // std.debug.print("input.ptr={*} len={} pos={}\n", .{self.frameHead.?.input.ptr, self.frameHead.?.input.len, self.frameHead.?.pos});
            const token: Token = self.next() catch |err| blk: switch (err) {
                LexerError.UnknownMacro => {
                    const id = try self.nextWord();
                    if (id.kind != .identifier) return LexerError.ExpectedIdentifier;

                    if (args.get(id.data)) |value| {
                        break :blk .{.kind = .identifier, .data = value};
                    } else {
                        return err;
                    }
                },

                LexerError.UnexpectedEOF => break :subst,

                else => {
                    if (lastError.frame == self.frameHead and lastError.pos[0] == self.frameHead.?.pos) {
                        self.frameHead.?.pos += 1;
                    }

                    lastError = try self.bookmark();
                    continue;
                },
            };

            switch (token.kind) {
                .string => {
                    try stringBuilder.append(self.stringArena.allocator(), '"');
                    try stringBuilder.appendSlice(self.stringArena.allocator(), token.data);
                    try stringBuilder.append(self.stringArena.allocator(), '"');
                },

                .char => {
                    try stringBuilder.appendSlice(self.stringArena.allocator(), "'\\x");
                    try stringBuilder.append(self.stringArena.allocator(), (token.data[0] >> 4) & 0xF);
                    try stringBuilder.append(self.stringArena.allocator(), (token.data[0] >> 0) & 0xF);
                    try stringBuilder.append(self.stringArena.allocator(), '\'');
                },

                else => try stringBuilder.appendSlice(self.stringArena.allocator(), token.data),
            }
        }

        frame.input = stringBuilder.items;
        frame.pos = 0;
        return frame;
    }
};

fn testTokens(input: []const u8, expected: []const Tokenizer.Token.Kind) !void {
    const allocator = std.testing.allocator;
    
    var tokenizer = try Tokenizer.init(std.testing.io, allocator);
    defer tokenizer.deinit();

    try tokenizer.pushFrame(input, "<fn testTokens>");

    for (expected, 0..) |expectedKind, i| {
        const token = tokenizer.nextWord() catch |err| {
            tokenizer.showErrorHere(err);
            return err;
        };

        if (token.kind != expectedKind) {
            std.debug.print(
                \\>>> [testTokens:{}]: lexer error: expected {}, got {}.
                \\raw slice: "{s}"
                \\
            , .{i, expectedKind, token.kind, token.data});
            tokenizer.showErrorHere(error.TestExpectedEqual);
            return error.TestExpectedEqual;
        }
    }

    if (expected.len == 0 or expected[expected.len - 1] != .eof) {
        const finalToken = tokenizer.nextWord() catch |err| {
            tokenizer.showErrorHere(err);
            return err;
        };

        if (finalToken.kind != .eof) {
            std.debug.print(
                \\>>> [testTokens]: error: expected EOF, got more tokens.
                \\actual: {}, raw slice: "{s}"
                \\
            , .{finalToken.kind, finalToken.data});
            return error.TestExpectedEOF;
        }
    }
}

test "single character punctuation tokens" {
    try testTokens(".", &.{.dot});
    try testTokens(",", &.{.comma});
    try testTokens(":", &.{.colon});
    try testTokens("-", &.{.minus});
    try testTokens("+", &.{.plus});
    try testTokens("~", &.{.tilde});
    try testTokens("$", &.{.dollar});
}

test "identifiers and whitespace" {
    try testTokens("abc() var123 camelCase", &.{.identifier, .lparen, .rparen, .identifier, .identifier});
    try testTokens("  \t\n  my_var  ", &.{.identifier});
}

test "numeric literals" {
    try testTokens("123 0xABC 0b1010 0o755 0", &[5]Tokenizer.Token.Kind{
        .number,
        .number,
        .number,
        .number,
        .number,
    });
}

test "character literals" {
    try testTokens("'a' 'b' '\\n' '\\x41'", &.{.char, .char, .char, .char});
}

test "comments" {
    try testTokens(
        \\// this is a line comment
        \\+ // another line comment
        \\/* block comment */ -
        \\/**/ ~
    , &.{.plus, .minus, .tilde});
}

test "mixed stream sequence" {
    const source =
        \\foo + bar - 42:
        \\$baz . , ~ 'x'
    ;
    
    try testTokens(source, &[_]Tokenizer.Token.Kind{
        .identifier, // foo
        .plus,       // +
        .identifier, // bar
        .minus,      // -
        .number,     // 42
        .colon,      // :
        .dollar,     // $
        .identifier, // baz
        .dot,        // .
        .comma,      // ,
        .tilde,      // ~
        .char,       // 'x'
        .eof,
    });
}

test "macros" {
    try testTokens(
        \\%macro test(a1)
        \\identifier "string" 0x123
        \\0x876 identifier
        \\%endmacro
        \\"one"
        \\%ifdef wanker
        \\@test()
        \\%else
        \\@test(Aww)
        \\%endif
        \\ 123
        \\
    , &.{.string, .identifier, .string, .number, .number, .identifier, .number});
}

test "sizeOf" {
    try testTokens("@sizeOf(.word)", &.{.number});
    try testTokens("@sizeOf(.ptr)", &.{.number});
    try testTokens("@sizeOf(.short)", &.{.number});
    try testTokens("@sizeOf(.byte)", &.{.number});
}

test "alignOf" {
    try testTokens("@alignOf(.word)", &.{.number});
    try testTokens("@alignOf(.ptr)", &.{.number});
    try testTokens("@alignOf(.short)", &.{.number});
    try testTokens("@alignOf(.byte)", &.{.number});
}
