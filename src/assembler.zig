const std =  @import("std");

const P = @import("parser.zig");
const isa =  @import("isa.zig");

pub const Relocation = struct {
    addr: usize,
    name: []const u8,
    kind: isa.RelocationMode,
    pos: usize,
    input: []const u8,
    filename: []const u8,
};

pub const AssemblyError = error {
    NoData,
    InvalidInstruction,
    UnresolvedSymbol,
};

pub const Assembly = struct {
    data_memory: [65536]u8 = [_]u8{0} ** 65536,
    program_memory: [65536]u32 = [_]u32{0} ** 65536,
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

    pub fn writeHeader(self: *Assembly, io: std.Io, filepath: []const u8) !void {
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
                const str = try p.parseStringLiteral();
                if (self.dc % 2 == 1) self.dc += 1;
                std.mem.writeInt(u16, self.data_memory[self.dc..][0..2], @truncate(str.len), .big);
                std.mem.copyForwards(u8, self.data_memory[self.dc + 2..], str);
                self.dc += str.len + 2;
            },

            .pad => {
                const len = try p.parseInteger(usize);
                self.dc += len;
            },

            .ptr => {
                const name = try p.identifier1();
                const symbol = self.symbols.get(name).?;
                if (self.dc % 2 == 1) self.dc += 1;
                self.data_memory[self.dc] = @truncate(symbol);
                self.dc += 2;
            },

            .word => {
                while (!p.eof()) {
                    const x = try p.parseInteger(i16);
                    if (self.dc % 2 == 1) self.dc += 1;
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

    fn rtypeRegular(self: *Assembly, p: *P.Parser, rtype: isa.RType) !void {
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
            = (@as(u32, rtype.getFunct().code))
            | (@as(u32, 1 << 6))
            | (@as(u32, @intFromEnum(rs)) <<  7)
            | (@as(u32, @intFromEnum(rt)) << 12)
            | (@as(u32, @intFromEnum(rd)) << 17);
        self.pc += 1;
    }

    fn rtypeAux(self: *Assembly, p: *P.Parser, rtype: isa.RType) !void {
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
        try p.char(',');
        _ = p.tabulation();
        const imm: u5 = p.parseInteger(u5) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.pc, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = isa.RelocationMode.rtype,
                    .pos = p.pos,
                    .input = p.input,
                    .filename = p.currentFilename,
                });
                break :blk 0;
            }
            return err;
        };

        self.program_memory[self.pc]
            = (@as(u32, rtype.getFunct().code))
            | (@as(u32, 1 << 6))
            | (@as(u32, @intFromEnum(rs))  <<  7)
            | (@as(u32, @intFromEnum(rt))  << 12)
            | (@as(u32, @intFromEnum(rd))  << 17)
            | (@as(u32, imm) << 22);
        self.pc += 1;
    }

    inline fn encodeR(self: *Assembly, p: *P.Parser, rtype: isa.RType) !void {
        switch (rtype) {
            .sll => return self.rtypeAux(p, rtype),
            .srl => return self.rtypeAux(p, rtype),
            .sra => return self.rtypeAux(p, rtype),
            .sllr => return self.rtypeRegular(p, rtype),
            .srlr => return self.rtypeRegular(p, rtype),
            .srar => return self.rtypeRegular(p, rtype),
            .cfs => @panic("UNIMPLEMENTED"),
            .cts => @panic("UNIMPLEMENTED"),
            .@"and" => return self.rtypeRegular(p, rtype),
            .@"or" => return self.rtypeRegular(p, rtype),
            .xor => return self.rtypeRegular(p, rtype),
            .nor => return self.rtypeRegular(p, rtype),
            .slt => return self.rtypeRegular(p, rtype),
            .sltu => return self.rtypeRegular(p, rtype),
            .jr => @panic("UNIMPLEMENTED"),
            .jalr => @panic("UNIMPLEMENTED"),
            .lhx => return self.rtypeRegular(p, rtype),
            .lhux => return self.rtypeRegular(p, rtype),
            .lbx => return self.rtypeRegular(p, rtype),
            .lbux => return self.rtypeRegular(p, rtype),
            .lwx => return self.rtypeRegular(p, rtype),
            .mul => return self.rtypeRegular(p, rtype),
            .mulh => return self.rtypeRegular(p, rtype),
            .mulhu => return self.rtypeRegular(p, rtype),
            .div => return self.rtypeRegular(p, rtype),
            .divu => return self.rtypeRegular(p, rtype),
            .rest => return self.rtypeRegular(p, rtype),
            .restu => return self.rtypeRegular(p, rtype),
            .add => return self.rtypeRegular(p, rtype),
            .sub => return self.rtypeRegular(p, rtype),
            .trap => @panic("UNIMPLEMENTED"),
            .rft => @panic("UNIMPLEMENTED"),
        }
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
        const imm: u16 = p.parseInteger(u16) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.pc, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = isa.RelocationMode.tail16,
                    .pos = p.pos,
                    .input = p.input,
                    .filename = p.currentFilename,
                });
                break :blk 0;
            }
            return err;
        };

        self.program_memory[self.pc]
            = (@as(u32, instr.getInfo().op) << 27)
            | (@as(u32, @intFromEnum(rd))   << 22)
            | (@as(u32, @intFromEnum(rs))   << 17)
            | (@as(u32, 1 << 16))
            |  @as(u32, imm);

        self.pc += 1;
    }

    fn encodeL(self: *Assembly, p: *P.Parser, instr: isa.InstructionName) !void {
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
        const imm: u16 = p.parseInteger(u16) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.pc, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = isa.RelocationMode.tail16,
                    .pos = p.pos,
                    .input = p.input,
                    .filename = p.currentFilename,
                });
                break :blk 0;
            }
            return err;
        };

        self.program_memory[self.pc]
            = (@as(u32, instr.getInfo().op) << 27)
            | (@as(u32, @intFromEnum(rd))   << 22)
            | (@as(u32, @intFromEnum(rs))   << 17)
            |  @as(u32, imm);

        self.pc += 1;
    }

    fn encodeJ(self: *Assembly, p: *P.Parser, instr: isa.InstructionName) !void {
        const pc = self.pc;
        errdefer self.pc = pc;

        const ppos = p.pos;
        errdefer p.pos = ppos;

        _ = p.tabulation();
        const imm: u27 = p.parseInteger(u27) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.pc, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = isa.RelocationMode.tail16,
                    .pos = p.pos,
                    .input = p.input,
                    .filename = p.currentFilename,
                });
                break :blk 0;
            }
            return err;
        };

        self.program_memory[self.pc]
            = (@as(u32, instr.getInfo().op) << 27)
            |  @as(u32, imm);
        self.pc += 1;
    }

    fn assembleText(self: *Assembly, p: *P.Parser) !void {
        const pc = self.pc;
        errdefer self.pc = pc;

        const ppos = p.pos;
        errdefer p.pos = ppos;

        const label: ?[]const u8 = p.parseLabel() catch null;
        if (label) |name| {
            const stored_name = try self.allocator.dupe(u8, name);
            try self.symbols.put(stored_name, self.pc);
            _ = p.tabulation();
            if (p.isNewline()) return;
        } else {
            p.pos = ppos;
        }

        const mnemonic = p.alphanumeric1() catch return;
        if (std.meta.stringToEnum(isa.RType, mnemonic)) |rtype| {
            try self.encodeR(p, rtype);
        } else if (std.meta.stringToEnum(isa.InstructionName, mnemonic)) |instr| switch (instr) {
            .rtype => return AssemblyError.InvalidInstruction,
            .j => try self.encodeJ(p, instr),
            .jal => try self.encodeJ(p, instr),
            .andi => try self.encodeI(p, instr),
            .andih => try self.encodeL(p, instr),
            .ori => try self.encodeI(p, instr),
            .orih => try self.encodeL(p, instr),
            .xori => try self.encodeI(p, instr),
            .xorih => try self.encodeL(p, instr),
            .lw => try self.encodeI(p, instr),
            .sw => try self.encodeI(p, instr),
            .sh => try self.encodeI(p, instr),
            .sb => try self.encodeI(p, instr),
            .lh => try self.encodeI(p, instr),
            .lhu => try self.encodeL(p, instr),
            .lb => try self.encodeI(p, instr),
            .lbu => try self.encodeL(p, instr),
            .beq => try self.encodeI(p, instr),
            .bne => try self.encodeI(p, instr),
            .blt => try self.encodeI(p, instr),
            .bgt => try self.encodeI(p, instr),
            .ble => try self.encodeI(p, instr),
            .bge => try self.encodeI(p, instr),
            .slti => try self.encodeI(p, instr),
            .sltiu => try self.encodeL(p, instr),
            .addi => try self.encodeI(p, instr),
        } else {
            return AssemblyError.InvalidInstruction;
        }
    }

    pub fn assembleLine(self: *Assembly, p: *P.Parser) !void {
        _ = p.whitespace();
        if (p.eof()) return;
        _ = p.whitespace();
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

        if (p.peek() == '%') {
            try p.parsePreprocessorDefinition();
            return self.assembleLine(p);
        }

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

        if (p.isNewline()) {
            try p.newline();
            return;
        }

        if (!p.eof() and !std.ascii.isWhitespace(p.peek().?)) {
            return P.ParseError.UnexpectedToken;
        }
    }

    fn patchKnownRelocations(self: *Assembly) void {
        var i: usize = 0;
        while (i < self.relocations.items.len) {
            const r = self.relocations.items[i];
            if (self.symbols.get(r.name)) |symbol| {
                var instruction = self.program_memory[r.addr];
                switch (r.kind) {
                    .rtype, .tail8a => {
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
        const data = try std.Io.Dir.cwd().readFileAlloc(io, filepath, self.allocator, .unlimited);
        errdefer self.allocator.free(data);
        
        var p: P.Parser = try P.Parser.init(self.allocator, io);
        defer p.deinit();

        try p.pushFrame(data, filepath);

        while (!p.eof()) {
            self.assembleLine(&p) catch |err| {
                self.showError(&p, filepath, err);
                return err;
            };
        }

        self.patchKnownRelocations();
        if (self.relocations.items.len > 0) {
            for (self.relocations.items) |r| {
                p.pos = r.pos;
                p.input = r.input;
                p.currentFilename = r.filename;
                self.showError(&p, filepath, AssemblyError.UnresolvedSymbol);
            }
            return AssemblyError.UnresolvedSymbol;
        }
    }

    fn showError(_: *Assembly, p: *P.Parser, filepath: []const u8, err: anyerror) void {
        var i = p.frames.items.len;
        while (i > 0) {
            i -= 1;
            const frame = p.frames.items[i];
            if (frame.input.len > 0) {
                const loc = P.Parser.getLocationInfo(frame.input, frame.pos, frame.filename);
                const fname = if (loc.filename.len > 0) loc.filename else filepath;
                std.debug.print("in buffer expanded from {s}:{d}:{d}:\n", .{fname, loc.line, loc.column});
            }
        }

        const loc = p.getLocation();
        const fname = if (loc.filename.len > 0) loc.filename else filepath;
        const snippet = p.input[loc.start..loc.end];
        
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ fname, loc.line, loc.column, @errorName(err) });
        std.debug.print("{s}\n", .{snippet});
        
        for (0..loc.column - 1) |_| std.debug.print(" ", .{});
        std.debug.print("^\n", .{});
    }
};

test "encodeR add" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();
    assembly.current_section = .text;
    var parser = try P.Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    try parser.pushFrame("add $t0, $s0, $a0", "<test>");
    try assembly.assembleLine(&parser);
    try std.testing.expectEqual(@as(u20, 0x004E0), assembly.program_memory[0]);
}

test "forward references" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();
    assembly.current_section = .text;
    var p1 = try P.Parser.init(std.testing.allocator, undefined);
    defer p1.deinit();
    try p1.pushFrame("j future_label", "<test>");
    try assembly.assembleLine(&p1);
    try std.testing.expectEqual(@as(usize, 1), assembly.pc);
    try std.testing.expectEqual(@as(usize, 1), assembly.relocations.items.len);
    try std.testing.expectEqualStrings("future_label", assembly.relocations.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), assembly.relocations.items[0].addr);
    var p2 = try P.Parser.init(std.testing.allocator, undefined);
    defer p2.deinit();
    try p2.pushFrame("future_label:", "<test>");
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
        var p = try P.Parser.init(std.testing.allocator, undefined);
        defer p.deinit();
        try p.pushFrame(line, "<test>");
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
        var p = try P.Parser.init(std.testing.allocator, undefined);
        defer p.deinit();
        try p.pushFrame(line, "<.data program>");
        assembly.assembleLine(&p) catch |err| {
            assembly.showError(&p, "<.data program>", err);
            return err;
        };
    }
}

test "%macro register clear pseudo-op" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();
    assembly.current_section = .text;

    var p1 = P.Parser.init(std.testing.allocator, undefined) catch unreachable;
    defer p1.deinit();

    try p1.pushFrame("%macro clear(r) { add @r, $s0, $s0 }\n.text\n  @clear($t0)\n", "test.lc6");
    while (!p1.eof()) {
        try assembly.assembleLine(&p1);
    }

    try std.testing.expectEqual(@as(usize, 1), assembly.pc);
}

test "%macro array element stride loader" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();
    assembly.current_section = .text;

    var p1 = P.Parser.init(std.testing.allocator, undefined) catch unreachable;
    defer p1.deinit();

    try p1.pushFrame("%macro fetch(dest, base) { lw @dest, @base, 0 }\n  @fetch($a0, $sp)\n", "test.lc6");
    while (!p1.eof()) {
        try assembly.assembleLine(&p1);
    }
}

test "%macro conditional yield block" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();
    assembly.current_section = .text;

    var p1 = P.Parser.init(std.testing.allocator, undefined) catch unreachable;
    defer p1.deinit();

    try p1.pushFrame("%macro assert_die() { beq $t0, $t1, 1\n halt }\n@assert_die()\n", "test.lc6");
    while (!p1.eof()) {
        try assembly.assembleLine(&p1);
    }

    try std.testing.expectEqual(@as(usize, 2), assembly.pc);
}

test "complex %macro flow" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();

    const continuous_source =
        \\.data
        \\  value: .word 255
        \\.text
        \\  %macro pipeline(reg) {
        \\    lw @reg, $s0, value
        \\    add @reg, @reg, @reg
        \\  }
        \\  main:
        \\    @pipeline($t2)
        \\    halt
    ;

    var p = P.Parser.init(std.testing.allocator, undefined) catch unreachable;
    defer p.deinit();
    try p.pushFrame(continuous_source, "test.lc6");

    while (!p.eof()) {
        try assembly.assembleLine(&p);
    }

    try std.testing.expectEqual(@as(usize, 2), assembly.pc);
    try std.testing.expectEqual(@as(usize, 1), assembly.relocations.items.len);
}
