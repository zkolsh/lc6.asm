const std =  @import("std");

const P = @import("parser.zig");
const isa =  @import("isa.zig");

pub const Relocation = struct {
    addr: usize,
    name: []const u8,
    kind: isa.RelocationMode,
    pos: usize,
};

pub const AssemblyError = error {
    NoData,
    InvalidInstruction,
    UnresolvedSymbol,
};

pub const Assembly = struct {
    data_memory: [65536]u8 = [_]u8{0} ** 65536,
    program_memory: [65536]u20 = [_]u20{0} ** 65536,
    dc: usize = 0,
    pc: usize = 0,
    current_section: isa.Section = .data,

    allocator: std.mem.Allocator,
    symbols: std.StringHashMap(usize),
    relocations: std.ArrayList(Relocation),

    pub fn init(allocator: std.mem.Allocator) !Assembly {
        return .{
            .allocator = allocator,
            .symbols = std.StringHashMap(usize).init(allocator),
            .relocations = try std.ArrayList(Relocation).initCapacity(allocator, 8),
        };
    }

    pub fn deinit(self: *Assembly) void {
        for (self.relocations.items) |r| {
            self.allocator.free(r.name);
        }

        self.relocations.deinit(self.allocator);

        var it = self.symbols.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
        }

        self.symbols.deinit();
    }

    pub fn writeOut(self: *Assembly, io: std.Io, filepath: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);

        try writer.interface.print("#include <stdint.h>\n", .{});
        try writer.interface.print("\n", .{});

        try writer.interface.print("uint32_t program_memory[{d}] = {{\n", .{self.program_memory.len});
        var i: usize = 0;
        while (i < self.pc) : (i += 8) {
            try writer.interface.print("\t", .{});
            var j: usize = 0;
            while (j < 8 and i + j < self.pc) : (j += 1) {
                try writer.interface.print("0x{X}, ", .{self.program_memory[i + j]});
            }
            try writer.interface.writeAll("\n");
        }
        try writer.interface.writeAll("};\n");
        try writer.interface.flush();

        i = 0;
        try writer.interface.print("\n", .{});
        try writer.interface.print("uint8_t data_memory[{d}] = {{\n", .{self.data_memory.len});
        while (i < self.dc) : (i += 8) {
            try writer.interface.writeAll("\t");
            var j: usize = 0;
            while (j < 8 and i + j < self.dc) : (j += 1) {
                try writer.interface.print("0x{X}, ", .{self.data_memory[i + j]});
            }
            try writer.interface.writeAll("\n");
        }
        try writer.interface.writeAll("};");
        try writer.interface.flush();
    }

    fn encodeR(self: *Assembly, p: *P.Parser, instr: isa.InstructionName) !void {
        const pc = self.pc;
        errdefer self.pc = pc;

        const ppos = p.pos;
        errdefer p.pos = ppos;

        _ = p.tabulation();
        const rd = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rs = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rt = try p.parseRegisterName();
        self.program_memory[self.pc]
            = (@as(u20, instr.getInfo().op) << 16)
            | (@as(u20, @intFromEnum(rd)) << 12)
            | (@as(u20, @intFromEnum(rs)) <<  8)
            | (@as(u20, @intFromEnum(rt)) <<  4);
        self.pc += 1;
    }

    fn encodeI(self: *Assembly, p: *P.Parser, instr: isa.InstructionName) !void {
        const pc = self.pc;
        errdefer self.pc = pc;

        const ppos = p.pos;
        errdefer p.pos = ppos;

        _ = p.tabulation();
        const rd = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rs = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const imm: u8 = p.parseInteger(u8) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.pc, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = instr.getInfo().reloc.?,
                    .pos = p.pos,
                });
                break :blk 0;
            }
            return err;
        };

        self.program_memory[self.pc]
            = (@as(u20, instr.getInfo().op) << 16)
            | (@as(u20, @intFromEnum(rd)) << 12)
            | (@as(u20, @intFromEnum(rs)) <<  8)
            | @as(u20, imm);
        self.pc += 1;
    }

    fn encodeS(self: *Assembly, p: *P.Parser, instr: isa.InstructionName) !void {
        const pc = self.pc;
        errdefer self.pc = pc;

        const ppos = p.pos;
        errdefer p.pos = ppos;

        _ = p.tabulation();
        const imm: u16 = p.parseInteger(u16) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.pc, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = instr.getInfo().reloc.?,
                    .pos = p.pos,
                });
                break :blk 0;
            }
            return err;
        };

        self.program_memory[self.pc]
            = (@as(u20, instr.getInfo().op) << 16)
            | @as(u20, imm);
        self.pc += 1;
    }

    fn assembleData(self: *Assembly, p: *P.Parser) !void {
        const pc = self.pc;
        errdefer self.pc = pc;

        const ppos = p.pos;
        errdefer p.pos = ppos;

        const label: ?[]const u8 = p.parseLabel() catch null;
        if (label) |name| {
            const stored_name = try self.allocator.dupe(u8, name);
            try self.symbols.put(stored_name, self.dc);
            _ = p.tabulation();
            if (p.eof()) return;
        } else {
            p.pos = ppos;
        }

        const directive = p.parseDataDirective() catch return;
        _ = p.tabulation();

        const start = p.pos;
        errdefer p.pos = start;

        const dc = self.dc;
        errdefer self.dc = dc;

        switch (directive) {
            .asciiz => {
                const str = try p.parseStringLiteral();
                std.mem.copyForwards(u8, self.data_memory[self.dc..], str);
                self.data_memory[self.dc + str.len] = 0;
                self.dc += str.len + 1;
            },

            .byte => {
                while (!p.isNewline()) {
                    const x = try p.parseInteger(i8);
                    self.data_memory[self.dc] = @bitCast(x);
                    self.dc += 1;
                    _ = p.tabulation();

                    if (p.isNewline()) {
                        const end = p.pos;
                        try p.newline();
                        _ = p.tabulation();
                        const next_token = p.pos;
                        _ = p.parseInteger(i8) catch {
                            p.pos = end;
                            break;
                        };

                        p.pos = next_token;
                    }
                }
            },

            .nascii => {
                if (self.dc % 2 == 1) self.dc += 1;
                const str = try p.parseStringLiteral();
                std.mem.writeInt(u16, self.data_memory[self.dc..][0..2], @truncate(str.len), .big);
                std.mem.copyForwards(u8, self.data_memory[self.dc + 2..], str);
                self.dc += str.len + 2;
            },

            .pad => {
                const len = try p.parseInteger(usize);
                self.dc += len;
            },

            .word => {
                if (self.dc % 2 == 1) self.dc += 1;
                while (!p.eof()) {
                    const x = try p.parseInteger(i16);
                    std.mem.writeInt(u16, self.data_memory[self.dc..][0..2], @bitCast(x), .big);
                    self.dc += 2;
                    _ = p.tabulation();

                    if (p.isNewline()) {
                        const end = p.pos;
                        try p.newline();
                        _ = p.tabulation();
                        const next_token = p.pos;
                        _ = p.parseInteger(i16) catch {
                            p.pos = end;
                            break;
                        };

                        p.pos = next_token;
                    }
                }
            },
        }
    }

    fn assembleText(self: *Assembly, p: *P.Parser) !void {
        const pc = self.pc;
        errdefer self.pc = pc;

        const ppos = p.pos;
        errdefer p.pos = ppos;

        const label: ?[]const u8 = p.parseLabel() catch |err| blk: {
            if (err == P.ParseError.NoMatch) break :blk null;
            if (err == P.ParseError.UnexpectedToken) break :blk null;
            return err;
        };

        if (label) |name| {
            const stored_name = try self.allocator.dupe(u8, name);
            try self.symbols.put(stored_name, self.pc);
            _ = p.tabulation();
            if (p.isNewline()) return;
        } else {
            p.pos = ppos;
        }

        const mnemonic = p.alphanumeric1() catch return;
        const instr = std.meta.stringToEnum(isa.InstructionName, mnemonic)
            orelse return AssemblyError.InvalidInstruction;

        switch (instr) {
            .add => try self.encodeR(p, instr),
            .lw => try self.encodeI(p, instr),
            .sw => try self.encodeI(p, instr),
            .beq => try self.encodeI(p, instr),
            .j => try self.encodeS(p, instr),
            .halt => {
                self.program_memory[self.pc] = 0xFFFFF;
                self.pc += 1;
            }
        }
    }

    pub fn assembleLine(self: *Assembly, p: *P.Parser) !void {
        _ = p.whitespace();
        if (p.eof()) return;
        if (p.isNewline()) {
            try p.newline();
            return self.assembleLine(p);
        }

        const pc = self.pc;
        errdefer self.pc = pc;

        const ppos = p.pos;
        errdefer p.pos = ppos;

        const section: ?[]const u8 = p.parseSectionLabel() catch |err| blk: {
            if (err == P.ParseError.NoMatch) break :blk null;
            if (err == P.ParseError.UnexpectedToken) break :blk null;
            return err;
        };

        if (section) |name| {
            if (std.mem.eql(u8, name, "data")) self.current_section = .data;
            if (std.mem.eql(u8, name, "text")) self.current_section = .text;

            _ = p.tabulation();
            return;
        } else {
            p.pos = ppos;

            switch (self.current_section) {
                .data => try self.assembleData(p),
                .text => try self.assembleText(p),
            }
        }

        try p.newline();
    }

    pub fn patchRelocations(self: *Assembly) void {
        var i: usize = 0;
        while (i < self.relocations.items.len) {
            const r = self.relocations.items[i];
            if (self.symbols.get(r.name)) |symbol| {
                var instruction = self.program_memory[r.addr];
                switch (r.kind) {
                    .tail8a => {
                        instruction &= 0xFFF00;
                        instruction |= @as(u8, @truncate(symbol));
                    },
                    .tail8r => {
                        const pc = r.addr + 1;
                        const delta = @as(i32, @intCast(symbol)) - @as(i32, @intCast(pc));
                        instruction &= 0xFFF00;
                        instruction |= @as(u8, @bitCast(@as(i8, @intCast(delta))));
                    },
                    .tail16 => {
                        instruction &= 0xF0000;
                        instruction |= @as(u16, @truncate(symbol));
                    },
                }
                self.program_memory[r.addr] = instruction;
                self.allocator.free(r.name);
                _ = self.relocations.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn assembleEntireFile(self: *Assembly, io: std.Io, filepath: []const u8) !void {
        var file = try std.Io.Dir.cwd().openFile(io, filepath, .{});
        defer file.close(io);
        
        //FIXME: 1MB max capacity
        var buffer: [1024 * 1024]u8 = undefined;
        const data = try std.Io.Dir.readFile(std.Io.Dir.cwd(), io, filepath, &buffer);
        var p: P.Parser = P.Parser{.input = data};

        while (!p.eof()) {
            self.assembleLine(&p) catch |err| {
                self.showError(&p, filepath, err);
                return err;
            };
        }

        self.patchRelocations();
        if (self.relocations.items.len > 0) {
            for (self.relocations.items) |r| {
                p.pos = r.pos;
                self.showError(&p, filepath, AssemblyError.UnresolvedSymbol);
            }
            return AssemblyError.UnresolvedSymbol;
        }
    }

    fn showError(_: *Assembly, p: *P.Parser, filepath: []const u8, err: anyerror) void {
        var line: usize = 1;
        var column: usize = 1;
        var line_start: usize = 0;

        for (p.input[0..p.pos], 0..) |c, i| {
            if (c == '\n') {
                line += 1;
                column = 1;
                line_start = i + 1;
            } else {
                column += 1;
            }
        }

        var line_end = p.pos;
        while (line_end < p.input.len and p.input[line_end] != '\n' and p.input[line_end] != '\r') : (line_end += 1) {
        }

        const snippet = p.input[line_start..line_end];

        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ filepath, line, column, @errorName(err) });
        std.debug.print("{s}\n", .{snippet});
        
        for (0..column - 1) |_| std.debug.print(" ", .{});
        std.debug.print("^\n", .{});
    }
};

test "encodeR add" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();
    assembly.current_section = .text;
    var parser = P.Parser{.input = "add $t0, $s0, $a0"};
    try assembly.assembleLine(&parser);
    try std.testing.expectEqual(@as(u20, 0x004E0), assembly.program_memory[0]);
}

test "forward references" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();
    assembly.current_section = .text;
    var p1 = P.Parser{.input = "j future_label"};
    try assembly.assembleLine(&p1);
    try std.testing.expectEqual(@as(usize, 1), assembly.pc);
    try std.testing.expectEqual(@as(usize, 1), assembly.relocations.items.len);
    try std.testing.expectEqualStrings("future_label", assembly.relocations.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), assembly.relocations.items[0].addr);
    var p2 = P.Parser{.input = "future_label:"};
    try assembly.assembleLine(&p2);
    try std.testing.expectEqual(@as(usize, 1), assembly.symbols.get("future_label").?);
}

test "small .text program" {
    const source = 
        \\.text
        \\start:
        \\  add $t0, $t1, $t2
        \\  beq $t0, $s0, start
        \\  j end
        \\end:
        \\  add $s1, $s1, $s1
    ;

    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();

    var it = std.mem.tokenizeSequence(u8, source, "\n");
    while (it.next()) |line| {
        var p = P.Parser{.input = line};
        try assembly.assembleLine(&p);
    }

    try std.testing.expectEqual(@as(usize, 0), assembly.symbols.get("start").?);
    try std.testing.expectEqual(@as(usize, 3), assembly.symbols.get("end").?);
}

test "small .data program" {
    const source = 
        \\.data
        \\  x0: .byte 0
        \\  x1: .byte 1
        \\  xs: .byte 0 1 2 3 4 5 6 7 8 9 10
        \\  x2: .byte 2
        \\  w0: .word 6553
        \\  .word 99 100 101
        \\  .pad 4
        \\  wawa: .asciiz "wawawawawawawawawawawawawawawawawawawawawawawawawa"
        \\  .pad 4
        \\  wawo: .nascii "WAAAAAAAAAAAA"
        \\  x3: .byte 13
    ;

    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();

    var it = std.mem.tokenizeSequence(u8, source, "\n");
    while (it.next()) |line| {
        var p = P.Parser{.input = line};
        assembly.assembleLine(&p) catch |err| {
            assembly.showError(&p, "<.data program>", err);
            return err;
        };
    }
}
