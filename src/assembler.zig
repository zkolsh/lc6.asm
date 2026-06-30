const std =  @import("std");

const c = @import("elf_io");

const P = @import("parser.zig");
const isa =  @import("isa.zig");

pub const Symbol = struct {
    offset: usize,
    section: isa.Section,
};

pub const Relocation = struct {
    addr: usize,
    name: []const u8,
    kind: isa.RelocationMode,
    bookmark: P.Parser.Bookmark,
};

pub const AssemblyError = error {
    InvalidInstruction,
    NoData,
    SerializationFailed,
    UnresolvedSymbol,
};

pub const Assembly = struct {
    data: std.ArrayList(u8) = std.ArrayList(u8).empty,
    text: std.ArrayList(u8) = std.ArrayList(u8).empty,
    currentSection: isa.Section = .data,

    allocator: std.mem.Allocator,
    symbols: std.StringHashMap(Symbol),
    relocations: std.ArrayList(Relocation),

    pub fn init(allocator: std.mem.Allocator) !Assembly {
        return .{
            .allocator = allocator,
            .symbols = std.StringHashMap(Symbol).init(allocator),
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

        try writer.interface.print("uint32_t program_memory[{d}] = {{\n", .{self.text.items.len});
        var i: usize = 0;
        while (i < self.text.items.len) : (i += 8) {
            try writer.interface.print("\t", .{});
            var j: usize = 0;
            while (j < 8 and i + j < self.text.items.len) : (j += 1) {
                try writer.interface.print("0x{X}, ", .{self.text.items[i + j]});
            }
            try writer.interface.writeAll("\n");
        }
        try writer.interface.writeAll("};\n");
        try writer.interface.flush();

        i = 0;
        try writer.interface.print("\n", .{});
        try writer.interface.print("uint8_t data_memory[{d}] = {{\n", .{self.data.items.len});
        while (i < self.data.items.len) : (i += 8) {
            try writer.interface.writeAll("\t");
            var j: usize = 0;
            while (j < 8 and i + j < self.data.items.len) : (j += 1) {
                try writer.interface.print("0x{X}, ", .{self.data.items[i + j]});
            }
            try writer.interface.writeAll("\n");
        }
        try writer.interface.writeAll("};");
        try writer.interface.flush();
    }

    pub fn createElfBlob(self: *Assembly, elfType: c.ElfType, entryPoint: u32) ![]u8 {
        var strtab = try std.ArrayList(u8).initCapacity(self.allocator, 1);
        defer strtab.deinit(self.allocator);
        try strtab.append(self.allocator, 0);

        var stringOffsets = std.StringHashMap(u32).init(self.allocator);
        defer stringOffsets.deinit();

        var symtab = try std.ArrayList(c.ElfSym).initCapacity(self.allocator, 1);
        defer symtab.deinit(self.allocator);
        try symtab.append(self.allocator, std.mem.zeroes(c.ElfSym));

        var symbols = self.symbols.iterator();
        while (symbols.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            const offset = @as(u32, @intCast(strtab.items.len));
            try strtab.appendSlice(self.allocator, name);
            try strtab.append(self.allocator, 0);
            try stringOffsets.put(name, offset);

            try symtab.append(self.allocator, .{
                .st_name = offset,
                .st_value = @as(u32, @intCast(value.offset)),
                .st_size = 0,
                .st_info = 0,
                .st_other = 0,
                .st_shndx = if (value.section == .text) 1 else 2,
            });
        }

        var relText = try std.ArrayList(c.ElfRel).initCapacity(self.allocator, self.relocations.items.len);
        defer relText.deinit(self.allocator);

        for (self.relocations.items) |rel| {
            var symbolIndex: u32 = 0;
            for (symtab.items, 0..) |sym, i| {
                if (i == 0) continue;

                const tabName = std.mem.sliceTo(strtab.items[sym.st_name..], 0);
                if (std.mem.eql(u8, tabName, rel.name)) {
                    symbolIndex = @as(u32, @intCast(i));
                    break;
                }
            }

            const relType = switch (rel.kind) {
                .rtype => c.R_RTM32_RTYPE,
                .lo16 => c.R_RTM32_LO16,
                .hi16 => c.R_RTM32_HI16,
                .pc16 => c.R_RTM32_PC16,
                .tail27 => c.R_RTM32_TAIL27,
                .word => c.R_RTM32_WORD,
            };

            try relText.append(self.allocator, .{
                .r_offset = @as(u32, @intCast(rel.addr)),
                .r_info = (@as(u32, symbolIndex) << 8) | @as(u32, @intCast(relType)),
            });
        }

        const sections = [_]c.ElfRawSection{
            .{
                .name = ".text",
                .data = self.text.items.ptr,
                .size = @as(u32, @intCast(self.text.items.len)),
                .type = c.SHT_PROGBITS,
                .flags = c.SHF_ALLOC | c.SHF_EXECINSTR,
                .addralign = 4,
                .link = 0,
                .info = 0,
                .entsize = 0,
            },
            .{
                .name = ".data",
                .data = self.data.items.ptr,
                .size = @as(u32, @intCast(self.data.items.len)),
                .type = c.SHT_PROGBITS,
                .flags = c.SHF_ALLOC | c.SHF_WRITE,
                .addralign = 4,
                .link = 0,
                .info = 0,
                .entsize = 0,
            },
            .{
                .name = ".strtab",
                .data = strtab.items.ptr,
                .size = @as(u32, @intCast(strtab.items.len)),
                .type = c.SHT_STRTAB,
                .flags = c.SHF_NONE,
                .addralign = 1,
                .link = 0,
                .info = 0,
                .entsize = 0,
            },
            .{
                .name = ".symtab",
                .data = @ptrCast(symtab.items.ptr),
                .size = @as(u32, @intCast(symtab.items.len * @sizeOf(c.ElfSym))),
                .type = c.SHT_SYMTAB,
                .flags = c.SHF_NONE,
                .addralign = 4,
                .link = 3,
                .info = 0,
                .entsize = @sizeOf(c.ElfSym),
            },
            .{
                .name = ".rel.text",
                .data = @ptrCast(relText.items.ptr),
                .size = @as(u32, @intCast(relText.items.len * @sizeOf(c.ElfRel))),
                .type = c.SHT_REL,
                .flags = c.SHF_NONE,
                .addralign = 4,
                .link = 4,
                .info = 1,
                .entsize = @sizeOf(c.ElfRel),
            },
        };

        const size = c.elf_writer_calculate_size(&sections, sections.len);
        const blob = try self.allocator.alloc(u8, size);

        const status =  c.elf_writer_serialize(blob.ptr, blob.len, elfType, entryPoint, &sections, sections.len);
        if (status != c.ELF_SUCCESS) {
            self.allocator.free(blob);
            return AssemblyError.SerializationFailed;
        }

        return blob;
    }

    pub fn writeElf(self: *Assembly, io: std.Io, filepath: []const u8, elfType: c.ElfType, entryPoint: u32) !void {
        const blob = try self.createElfBlob(elfType, entryPoint);
        defer self.allocator.free(blob);

        const file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, blob);
    }

    fn assembleData(self: *Assembly, p: *P.Parser) !void {
        var mark = p.bookmark();
        const label: ?[]const u8 = p.parseLabel() catch null;
        if (label) |name| {
            const storedName = try self.allocator.dupe(u8, name);
            try self.symbols.put(storedName, .{
                .offset = self.data.items.len,
                .section = self.currentSection
            });
            _ = p.tabulation();
            if (p.eof()) return;
        } else {
            p.restore(mark);
        }

        const directive = p.parseDataDirective() catch return;
        _ = p.tabulation();

        mark = p.bookmark();
        errdefer p.restore(mark);

        switch (directive) {
            .asciiz => {
                const str = try p.parseStringLiteral();
                try self.data.appendSlice(self.allocator, str);
                try self.data.append(self.allocator, 0);
            },

            .byte => {
                while (!p.eof()) {
                    try self.data.append(self.allocator, try p.parseByte());
                    _ = p.tabulation();

                    if (p.isNewline()) {
                        const here = p.bookmark();
                        try p.newline();
                        _ = p.tabulation();
                        
                        const nextMark = p.bookmark();
                        _ = p.parseByte() catch {
                            p.restore(here);
                            break;
                        };

                        p.restore(nextMark);
                    }
                }
            },

            .nascii => {
                if (self.data.items.len % 4 != 0) {
                    try self.data.appendNTimes(self.allocator, 0, 4 - (self.data.items.len % 4));
                }

                const str = try p.parseStringLiteral();
                const len = std.mem.nativeToLittle(u32, @as(u32, @intCast(str.len)));
                try self.data.appendSlice(self.allocator, std.mem.asBytes(&len));
                try self.data.appendSlice(self.allocator, str);
            },

            .pad => {
                const len = try p.parseInteger(usize);
                try self.data.appendNTimes(self.allocator, 0, len);
            },

            .ptr => {
                if (self.data.items.len % 4 != 0) {
                    try self.data.appendNTimes(self.allocator, 0, 4 - (self.data.items.len % 4));
                }

                try self.relocations.append(self.allocator, .{
                    .addr = self.data.items.len,
                    .name = try self.allocator.dupe(u8, try p.identifier1()),
                    .kind = .word,
                    .bookmark = p.bookmark(),
                });
            },

            .word => {
                if (self.data.items.len % 4 != 0) {
                    try self.data.appendNTimes(self.allocator, 0, 4 - (self.data.items.len % 4));
                }

                while (!p.eof()) {
                    const len = std.mem.nativeToLittle(i32, try p.parseInteger(i32));
                    try self.data.appendSlice(self.allocator, std.mem.asBytes(&len));
                    _ = p.tabulation();

                    if (p.isNewline()) {
                        const here = p.bookmark();
                        try p.newline();
                        _ = p.tabulation();
                        
                        const nextMark = p.bookmark();
                        _ = p.parseInteger(i32) catch {
                            p.restore(here);
                            break;
                        };

                        p.restore(nextMark);
                    }
                }
            },
        }
    }

    fn encodeR3(self: *Assembly, p: *P.Parser, rtype: isa.RType) !void {
        const mark = p.bookmark();
        errdefer p.restore(mark);

        _ = p.tabulation();
        const rd = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rs = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rt = try p.parseRegisterName();

        const mangled: u32
            = (@as(u32, rtype.getFunct().code))
            | (@as(u32, @intFromEnum(rs)) <<  7)
            | (@as(u32, @intFromEnum(rt)) << 12)
            | (@as(u32, @intFromEnum(rd)) << 17);

        const view = std.mem.nativeToLittle(u32, mangled);
        try self.text.appendSlice(self.allocator, std.mem.asBytes(&view));
    }

    fn encodeRShift(self: *Assembly, p: *P.Parser, rtype: isa.RType) !void {
        const mark = p.bookmark();
        errdefer p.restore(mark);

        _ = p.tabulation();
        const rd = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rt = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const imm: u6 = p.parseInteger(u6) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.text.items.len, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = isa.RelocationMode.rtype,
                    .bookmark = p.bookmark(),
                });
                break :blk 0;
            }
            return err;
        };

        const mangled: u32
            = (@as(u32, rtype.getFunct().code))
            | (@as(u32, @intFromEnum(rt))  << 12)
            | (@as(u32, @intFromEnum(rd))  << 17)
            | (@as(u32, imm) << 22);

        const view = std.mem.nativeToLittle(u32, mangled);
        try self.text.appendSlice(self.allocator, std.mem.asBytes(&view));
    }

    fn encodeRShiftV(self: *Assembly, p: *P.Parser, rtype: isa.RType) !void {
        const mark = p.bookmark();
        errdefer p.restore(mark);

        _ = p.tabulation();
        const rd = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rt = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rs = try p.parseRegisterName();

        const mangled: u32
            = (@as(u32, rtype.getFunct().code))
            | (@as(u32, @intFromEnum(rs)) <<  7)
            | (@as(u32, @intFromEnum(rt)) << 12)
            | (@as(u32, @intFromEnum(rd)) << 17);

        const view = std.mem.nativeToLittle(u32, mangled);
        try self.text.appendSlice(self.allocator, std.mem.asBytes(&view));
    }

    fn encodeRMemX(self: *Assembly, p: *P.Parser, rtype: isa.RType) !void {
        const mark = p.bookmark();
        errdefer p.restore(mark);

        _ = p.tabulation();
        const rt = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rs = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rd = try p.parseRegisterName();

        const mangled: u32
            = (@as(u32, rtype.getFunct().code))
            | (@as(u32, @intFromEnum(rs)) <<  7)
            | (@as(u32, @intFromEnum(rt)) << 12)
            | (@as(u32, @intFromEnum(rd)) << 17);

        const view = std.mem.nativeToLittle(u32, mangled);
        try self.text.appendSlice(self.allocator, std.mem.asBytes(&view));
    }

    fn encodeRJ(self: *Assembly, p: *P.Parser, rtype: isa.RType) !void {
        const mark = p.bookmark();
        errdefer p.restore(mark);

        _ = p.tabulation();
        const rs = try p.parseRegisterName();

        const mangled: u32
            = (@as(u32, rtype.getFunct().code))
            | (@as(u32, @intFromEnum(rs)) <<  7);

        const view = std.mem.nativeToLittle(u32, mangled);
        try self.text.appendSlice(self.allocator, std.mem.asBytes(&view));
    }

    inline fn encodeR(self: *Assembly, p: *P.Parser, rtype: isa.RType) !void {
        switch (rtype) {
            .sll => return self.encodeRShift(p, rtype),
            .srl => return self.encodeRShift(p, rtype),
            .sra => {
                const mark = p.bookmark();
                errdefer p.restore(mark);

                _ = p.tabulation();
                const rd = try p.parseRegisterName();
                try p.char(',');
                _ = p.tabulation();
                const rs = try p.parseRegisterName();
                try p.char(',');
                _ = p.tabulation();
                const imm: u6 = p.parseInteger(u6) catch |err| blk: {
                    if (err == P.ParseError.NoMatch) {
                        const label = try p.identifier1();
                        try self.relocations.append(self.allocator, .{
                            .addr = self.text.items.len, 
                            .name = try self.allocator.dupe(u8, label),
                            .kind = isa.RelocationMode.rtype,
                            .bookmark = p.bookmark(),
                        });
                        break :blk 0;
                    }
                    return err;
                };

                const mangled: u32
                    = (@as(u32, rtype.getFunct().code))
                    | (@as(u32, @intFromEnum(rs))  <<  7)
                    | (@as(u32, @intFromEnum(rd))  << 17)
                    | (@as(u32, imm) << 22);

                const view = std.mem.nativeToLittle(u32, mangled);
                try self.text.appendSlice(self.allocator, std.mem.asBytes(&view));
            },
            .sllr => return self.encodeRShiftV(p, rtype),
            .srlr => return self.encodeRShiftV(p, rtype),
            .srar => return self.encodeRShiftV(p, rtype),
            .cfs => @panic("UNIMPLEMENTED"),
            .cts => @panic("UNIMPLEMENTED"),
            .@"and" => return self.encodeR3(p, rtype),
            .@"or" => return self.encodeR3(p, rtype),
            .xor => return self.encodeR3(p, rtype),
            .nor => return self.encodeR3(p, rtype),
            .slt => return self.encodeR3(p, rtype),
            .sltu => return self.encodeR3(p, rtype),
            .jr => return self.encodeRJ(p, rtype),
            .jalr => return self.encodeRJ(p, rtype),
            .lhx => return self.encodeRMemX(p, rtype),
            .lhux => return self.encodeRMemX(p, rtype),
            .lbx => return self.encodeRMemX(p, rtype),
            .lbux => return self.encodeRMemX(p, rtype),
            .lwx => return self.encodeRMemX(p, rtype),
            .mul => return self.encodeR3(p, rtype),
            .mulh => return self.encodeR3(p, rtype),
            .mulhu => return self.encodeR3(p, rtype),
            .div => return self.encodeR3(p, rtype),
            .divu => return self.encodeR3(p, rtype),
            .rest => return self.encodeR3(p, rtype),
            .restu => return self.encodeR3(p, rtype),
            .add => return self.encodeR3(p, rtype),
            .sub => return self.encodeR3(p, rtype),
            .trap => @panic("UNIMPLEMENTED"),
            .rft => @panic("UNIMPLEMENTED"),
        }
    }

    fn encodeIALU(self: *Assembly, p: *P.Parser, instr: isa.InstructionName, comptime high: bool) !void {
        const mark = p.bookmark();
        errdefer p.restore(mark);

        _ = p.tabulation();
        const rt = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rs = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const imm: u16 = p.parseInteger(u16) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.text.items.len, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = if (high) isa.RelocationMode.hi16 else isa.RelocationMode.lo16,
                    .bookmark = p.bookmark(),
                });
                break :blk 0;
            }
            return err;
        };

        const mangled: u32
            = (@as(u32, instr.getInfo().op) << 27)
            | (@as(u32, @intFromEnum(rs))   << 22)
            | (@as(u32, @intFromEnum(rt))   << 17)
            | (if (high) @as(u32, 1 << 16) else @as(u32, 0))
            |  @as(u32, imm);

        const view = std.mem.nativeToLittle(u32, mangled);
        try self.text.appendSlice(self.allocator, std.mem.asBytes(&view));
    }

    fn encodeIMem(self: *Assembly, p: *P.Parser, instr: isa.InstructionName, comptime high: bool) !void {
        const mark = p.bookmark();
        errdefer p.restore(mark);

        _ = p.tabulation();
        const rt = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const imm: u16 = p.parseInteger(u16) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.text.items.len, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = isa.RelocationMode.lo16,
                    .bookmark = p.bookmark(),
                });
                break :blk 0;
            }
            return err;
        };

        _ = p.tabulation();
        try p.char('(');
        _ = p.tabulation();
        const rs = try p.parseRegisterName();
        _ = p.tabulation();
        try p.char(')');

        const mangled: u32
            = (@as(u32, instr.getInfo().op) << 27)
            | (@as(u32, @intFromEnum(rs))   << 22)
            | (@as(u32, @intFromEnum(rt))   << 17)
            | (if (high) @as(u32, 1 << 16) else @as(u32, 0))
            |  @as(u32, imm);

        const view = std.mem.nativeToLittle(u32, mangled);
        try self.text.appendSlice(self.allocator, std.mem.asBytes(&view));
    }

    fn encodeB(self: *Assembly, p: *P.Parser, instr: isa.InstructionName) !void {
        const mark = p.bookmark();
        errdefer p.restore(mark);

        _ = p.tabulation();
        const rs = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const rt = try p.parseRegisterName();
        try p.char(',');
        _ = p.tabulation();
        const imm: u16 = p.parseInteger(u16) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.text.items.len, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = isa.RelocationMode.pc16,
                    .bookmark = p.bookmark(),
                });
                break :blk 0;
            }
            return err;
        };

        const mangled: u32
            = (@as(u32, instr.getInfo().op) << 27)
            | (@as(u32, @intFromEnum(rs))   << 22)
            | (@as(u32, @intFromEnum(rt))   << 17)
            |  @as(u32, imm);

        const view = std.mem.nativeToLittle(u32, mangled);
        try self.text.appendSlice(self.allocator, std.mem.asBytes(&view));
    }

    fn encodeS(self: *Assembly, p: *P.Parser, instr: isa.InstructionName) !void {
        const mark = p.bookmark();
        errdefer p.restore(mark);

        _ = p.tabulation();
        const imm: u27 = p.parseInteger(u27) catch |err| blk: {
            if (err == P.ParseError.NoMatch) {
                const label = try p.identifier1();
                try self.relocations.append(self.allocator, .{
                    .addr = self.text.items.len, 
                    .name = try self.allocator.dupe(u8, label),
                    .kind = isa.RelocationMode.tail27,
                    .bookmark = p.bookmark(),
                });
                break :blk 0;
            }
            return err;
        };

        const mangled: u32
            = (@as(u32, instr.getInfo().op) << 27)
            |  @as(u32, imm);

        const view = std.mem.nativeToLittle(u32, mangled);
        try self.text.appendSlice(self.allocator, std.mem.asBytes(&view));
    }

    fn assembleText(self: *Assembly, p: *P.Parser) !void {
        const mark = p.bookmark();
        errdefer p.restore(mark);

        const label: ?[]const u8 = p.parseLabel() catch null;
        if (label) |name| {
            const storedName = try self.allocator.dupe(u8, name);
            try self.symbols.put(storedName, .{
                .offset = if (self.currentSection == .text) self.text.items.len else self.data.items.len,
                .section = self.currentSection
            });
            _ = p.tabulation();
            if (p.isNewline()) return;
        } else {
            p.restore(mark);
        }

        const mnemonic = p.alphanumeric1() catch return;
        if (std.meta.stringToEnum(isa.RType, mnemonic)) |rtype| {
            try self.encodeR(p, rtype);
        } else if (std.meta.stringToEnum(isa.InstructionName, mnemonic)) |instr| switch (instr) {
            .rtype => return AssemblyError.InvalidInstruction,
            .j => try self.encodeS(p, instr),
            .jal => try self.encodeS(p, instr),
            .andi => try self.encodeIALU(p, instr, false),
            .andih => try self.encodeIALU(p, instr, true),
            .ori => try self.encodeIALU(p, instr, false),
            .orih => try self.encodeIALU(p, instr, true),
            .xori => try self.encodeIALU(p, instr, false),
            .xorih => try self.encodeIALU(p, instr, true),
            .lw => try self.encodeIMem(p, instr, false),
            .sw => try self.encodeIMem(p, instr, false),
            .sh => try self.encodeIMem(p, instr, false),
            .sb => try self.encodeIMem(p, instr, false),
            .lh => try self.encodeIMem(p, instr, false),
            .lhu => try self.encodeIMem(p, instr, true),
            .lb => try self.encodeIMem(p, instr, false),
            .lbu => try self.encodeIMem(p, instr, true),
            .beq => try self.encodeB(p, instr),
            .bne => try self.encodeB(p, instr),
            .blt => try self.encodeB(p, instr),
            .bgt => try self.encodeB(p, instr),
            .ble => try self.encodeB(p, instr),
            .bge => try self.encodeB(p, instr),
            .slti => try self.encodeIALU(p, instr, false),
            .sltiu => try self.encodeIALU(p, instr, true),
            .addi => try self.encodeIALU(p, instr, false),
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

        const mark = p.bookmark();
        errdefer p.restore(mark);

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
            if (std.mem.eql(u8, name, "data")) self.currentSection = .data;
            if (std.mem.eql(u8, name, "text")) self.currentSection = .text;
            _ = p.tabulation();
            return;
        } else {
            p.restore(mark);
            switch (self.currentSection) {
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
        while (i < self.relocations.items.len) : (i += 1) {
            const r = self.relocations.items[i];
            if (r.kind != isa.RelocationMode.pc16) continue;

            if (self.symbols.get(r.name)) |symbol| {
                if (symbol.section != isa.Section.text) continue;

                const pc = r.addr;
                const target = symbol.offset;

                const delta = @as(i32, @intCast(target)) - @as(i32, @intCast(pc + 4));
                const imm = @as(i16, @truncate(delta >> 2));

                var view: u32 = undefined;
                std.mem.copyForwards(u8, std.mem.asBytes(&view), self.text.items[pc .. pc + 4]);
                
                view &= 0xFFFF0000;
                view |= @as(u16, @bitCast(imm));
                
                std.mem.copyForwards(u8, self.text.items[pc .. pc + 4], std.mem.asBytes(&view));
                self.allocator.free(r.name);
                _ = self.relocations.swapRemove(i);
            }
        }
    }

    pub fn assembleEntireFile(self: *Assembly, io: std.Io, filepath: []const u8) !void {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, filepath, self.allocator, .unlimited);
        errdefer self.allocator.free(data);
        
        var p: P.Parser = try P.Parser.init(self.allocator, io);
        defer p.deinit();

        try p.pushFrame(data, filepath);
        try self.data.ensureTotalCapacity(self.allocator, data.len / 8);
        try self.text.ensureTotalCapacity(self.allocator, data.len / 8);

        while (!p.eof()) {
            self.assembleLine(&p) catch |err| {
                self.showError(&p, filepath, err);
                return err;
            };
        }

        self.patchKnownRelocations();

        // if (self.relocations.items.len > 0) {
        //     for (self.relocations.items) |r| {
        //         p.restore(r.bookmark);
        //         self.showError(&p, filepath, AssemblyError.UnresolvedSymbol);
        //     }
        //     return AssemblyError.UnresolvedSymbol;
        // }
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
    assembly.currentSection = .text;
    var parser = try P.Parser.init(std.testing.allocator, undefined);
    defer parser.deinit();
    try parser.pushFrame("add $t0, $s0, $a0", "<test>");
    try assembly.assembleLine(&parser);
    // FIXME: obsolete
    // try std.testing.expectEqual(@as(u20, 0x004E0), assembly.program_memory[0]);
}

test "forward references" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();
    assembly.currentSection = .text;
    var p1 = try P.Parser.init(std.testing.allocator, undefined);
    defer p1.deinit();
    try p1.pushFrame("j future_label", "<test>");
    try assembly.assembleLine(&p1);
    try std.testing.expectEqual(@as(usize, 1), assembly.text.items.len);
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
    assembly.currentSection = .text;

    var p1 = P.Parser.init(std.testing.allocator, undefined) catch unreachable;
    defer p1.deinit();

    try p1.pushFrame("%macro clear(r) { add @r, $s0, $s0 }\n.text\n  @clear($t0)\n", "test.rtm");
    while (!p1.eof()) {
        try assembly.assembleLine(&p1);
    }

    try std.testing.expectEqual(@as(usize, 1), assembly.text.items.len);
}

test "%macro array element stride loader" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();
    assembly.currentSection = .text;

    var p1 = P.Parser.init(std.testing.allocator, undefined) catch unreachable;
    defer p1.deinit();

    try p1.pushFrame("%macro fetch(dest, base) { lw @dest, @base, 0 }\n  @fetch($a0, $sp)\n", "test.rtm");
    while (!p1.eof()) {
        try assembly.assembleLine(&p1);
    }
}

test "%macro conditional yield block" {
    var assembly = try Assembly.init(std.testing.allocator);
    defer assembly.deinit();
    assembly.currentSection = .text;

    var p1 = P.Parser.init(std.testing.allocator, undefined) catch unreachable;
    defer p1.deinit();

    try p1.pushFrame("%macro assert_die() { beq $t0, $t1, 1\n me: j me }\n@assert_die()\n", "test.rtm");
    while (!p1.eof()) {
        try assembly.assembleLine(&p1);
    }

    try std.testing.expectEqual(@as(usize, 2), assembly.text.items.len);
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
        \\  die:
        \\    j die
    ;

    var p = P.Parser.init(std.testing.allocator, undefined) catch unreachable;
    defer p.deinit();
    try p.pushFrame(continuous_source, "test.rtm");

    while (!p.eof()) {
        try assembly.assembleLine(&p);
    }

    //FIXME: revisit all tests tbh
    // try std.testing.expectEqual(@as(usize, 2), assembly.text.items.len);
    // try std.testing.expectEqual(@as(usize, 1), assembly.relocations.items.len);
}
