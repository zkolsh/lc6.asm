const c = @import("elf_io");
const std =  @import("std");
const parsing = @import("parser.zig");
const lexing = @import("tokenizer.zig");
const isa =  @import("isa.zig");

const Statement = parsing.Statement;
const Parser = parsing.Parser;
const Tokenizer = lexing.Tokenizer;

pub const Symbol = struct {
    offset: usize,
    segment: []const u8,
};

pub const Relocation = struct {
    addr: usize,
    name: []const u8,
    section: []const u8,
    kind: isa.RelocationMode,
    bookmark: Tokenizer.Bookmark,
};

pub const AssemblyError = error {
    InvalidInstruction,
    InvalidAlignment,
    InvalidLabel,
    LabelNotAllowedHere,
    SymbolRedefined,
    NoData,
    SerializationFailed,
    UnresolvedSymbol,
} || parsing.ParseError;

const Segment = std.ArrayList(u8);
pub const Assembly = struct {
    allocator: std.mem.Allocator,
    strings: std.heap.ArenaAllocator,

    segments: std.StringHashMap(Segment),
    currentSegment: *Segment,
    currentSegmentName: []const u8,

    symbols: std.StringHashMap(Symbol),
    relocations: std.ArrayList(Relocation),

    pub fn init(allocator: std.mem.Allocator) !Assembly {
        var segments = std.StringHashMap(Segment).init(allocator);
        try segments.put("text", std.ArrayList(u8).empty);
        try segments.put("data", std.ArrayList(u8).empty);

        return .{
            .allocator = allocator,
            .strings = std.heap.ArenaAllocator.init(allocator),
            .segments = segments,
            .currentSegment = segments.getPtr("text").?,
            .currentSegmentName = "text",
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .relocations = try std.ArrayList(Relocation).initCapacity(allocator, 32),
        };
    }

    pub fn deinit(self: *Assembly) void {
        self.relocations.deinit(self.allocator);

        var segment = self.segments.iterator();
        while (segment.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }

        self.segments.deinit();
        self.symbols.deinit();
        self.strings.deinit();
    }

    pub fn encodeStatement(self: *Assembly, stmt: Statement, bookmark: Tokenizer.Bookmark) AssemblyError!void {
        switch (stmt.value) {
            .section => |name| {
                if (stmt.label.len != 0) {
                    return AssemblyError.LabelNotAllowedHere;
                }

                self.currentSegment = try self.getOrPutSegment(name);
                self.currentSegmentName = name;
                return;
            },

            else => {},
        }

        var labelLoc = self.getOffset();
        switch (stmt.value) {
            .section => unreachable,

            .bytes => |bytes| {
                try self.currentSegment.appendSlice(self.allocator, bytes);
            },

            .shorts => |shorts| {
                try self.alignSegment(self.currentSegment, 2);
                labelLoc = self.getOffset();

                for (shorts) |x| {
                    const le = std.mem.nativeToLittle(u16, x);
                    try self.currentSegment.appendSlice(self.allocator, std.mem.asBytes(&le));
                }
            },

            .words => |words| {
                try self.alignSegment(self.currentSegment, 4);
                labelLoc = self.getOffset();

                for (words) |x| {
                    const le = std.mem.nativeToLittle(u32, x);
                    try self.currentSegment.appendSlice(self.allocator, std.mem.asBytes(&le));
                }
            },

            .asciiz => |str| {
                try self.currentSegment.appendSlice(self.allocator, str);
                try self.currentSegment.append(self.allocator, 0);
            },

            .nascii => |str| {
                try self.alignSegment(self.currentSegment, 4);
                labelLoc = self.getOffset();

                const len = std.mem.nativeToLittle(u32, @intCast(str.len));
                try self.currentSegment.appendSlice(self.allocator, std.mem.asBytes(&len));
                try self.currentSegment.appendSlice(self.allocator, str);
            },

            .padding => |padding| {
                try self.alignSegment(self.currentSegment, padding.alignment);
                labelLoc = self.getOffset();

                try self.currentSegment.appendNTimes(self.allocator, 0, padding.size);
            },

            .ptr => |label| {
                try self.alignSegment(self.currentSegment, 4);
                labelLoc = self.getOffset();

                try self.relocations.append(self.allocator, .{
                    .addr = labelLoc,
                    .name = label,
                    .section = self.currentSegmentName,
                    .kind = .word,
                    .bookmark = bookmark,
                });

                try self.currentSegment.appendNTimes(self.allocator, 0, 4);
            },

            .rtype => |r| {
                try self.alignSegment(self.currentSegment, 4);
                labelLoc = self.getOffset();

                const imm = switch (r.aux) {
                    .static => |x| x,
                    .dynamic => |label| blk: {
                        try self.relocations.append(self.allocator, .{
                            .addr = labelLoc,
                            .name = label,
                            .section = self.currentSegmentName,
                            .kind = .rtype,
                            .bookmark = bookmark,
                        });

                        break :blk 0;
                    },
                };

                const mangled: u32
                    = (@as(u32, r.funct.getFunct().code))
                    | (@as(u32, imm) <<  7)
                    | (@as(u32, @intFromEnum(r.rd)) << 12)
                    | (@as(u32, @intFromEnum(r.rt)) << 17)
                    | (@as(u32, @intFromEnum(r.rs)) << 22);

                const view = std.mem.nativeToLittle(u32, mangled);
                try self.currentSegment.appendSlice(self.allocator, std.mem.asBytes(&view));
            },

            .itype => |i| {
                try self.alignSegment(self.currentSegment, 4);
                labelLoc = self.getOffset();

                const info = i.opcode.getInfo();
                const imm = switch (i.imm) {
                    .static => |x| x,
                    .dynamic => |label| blk: {
                        try self.relocations.append(self.allocator, .{
                            .addr = labelLoc,
                            .name = label,
                            .section = self.currentSegmentName,
                            .kind = info.reltype,
                            .bookmark = bookmark,
                        });

                        break :blk 0;
                    },
                };

                const mangled: u32
                    = (@as(u32, info.op) << 27)
                    | (@as(u32, @intFromEnum(i.rs))   << 22)
                    | (@as(u32, @intFromEnum(i.rt))   << 17)
                    |  @as(u32, @intCast(imm));

                const view = std.mem.nativeToLittle(u32, mangled);
                try self.currentSegment.appendSlice(self.allocator, std.mem.asBytes(&view));
            },

            .ltype => |l| {
                try self.alignSegment(self.currentSegment, 4);
                labelLoc = self.getOffset();

                const info = l.opcode.getInfo();
                const imm = switch (l.imm) {
                    .static => |x| x,
                    .dynamic => |label| blk: {
                        try self.relocations.append(self.allocator, .{
                            .addr = labelLoc,
                            .name = label,
                            .section = self.currentSegmentName,
                            .kind = info.reltype,
                            .bookmark = bookmark,
                        });

                        break :blk 0;
                    },
                };

                const mangled: u32
                    = (@as(u32, info.op) << 27)
                    | (@as(u32, @intFromEnum(l.rs))   << 22)
                    | (@as(u32, @intFromEnum(l.rt))   << 17)
                    | (if (info.high) @as(u32, 1 << 16) else @as(u32, 0))
                    |  @as(u32, @intCast(imm));

                const view = std.mem.nativeToLittle(u32, mangled);
                try self.currentSegment.appendSlice(self.allocator, std.mem.asBytes(&view));
            },

            .jtype => |j| {
                try self.alignSegment(self.currentSegment, 4);
                labelLoc = self.getOffset();

                const info = j.opcode.getInfo();
                const imm = switch (j.imm) {
                    .static => |x| x,
                    .dynamic => |label| blk: {
                        try self.relocations.append(self.allocator, .{
                            .addr = labelLoc,
                            .name = label,
                            .section = self.currentSegmentName,
                            .kind = info.reltype,
                            .bookmark = bookmark,
                        });

                        break :blk 0;
                    },
                };

                const mangled: u32
                    = (@as(u32, info.op) << 27)
                    |  @as(u32, @intCast(imm));

                const view = std.mem.nativeToLittle(u32, mangled);
                try self.currentSegment.appendSlice(self.allocator, std.mem.asBytes(&view));
            },
        }

        if (stmt.label.len != 0) {
            try self.defineLabel(stmt.label, labelLoc);
        }
    }

    fn getOrPutSegment(self: *Assembly, name: []const u8) AssemblyError!*Segment {
        const gpr = try self.segments.getOrPut(name);
        if (gpr.found_existing) {
            return gpr.value_ptr;
        } else {
            gpr.key_ptr.* = try self.strings.allocator().dupe(u8, name);
            gpr.value_ptr.* = .empty;
            return gpr.value_ptr;
        }
    }

    fn getOffset(self: *Assembly) usize {
        return self.currentSegment.items.len;
    }

    fn alignSegment(self: *Assembly, segment: *Segment, alignment: usize) !void {
        if (alignment == 0) {
            return AssemblyError.InvalidAlignment;
        }

        const remainder = segment.items.len % alignment;
        if (remainder != 0) {
            try segment.appendNTimes(self.allocator, 0, alignment - remainder);
        }
    }

    fn defineLabel(self: *Assembly, name: []const u8, offset: usize) AssemblyError!void {
        if (name.len == 0) {
            return AssemblyError.InvalidLabel;
        }

        const gpr = try self.symbols.getOrPut(name);
        if (gpr.found_existing) {
            return AssemblyError.SymbolRedefined;
        } else {
            gpr.key_ptr.* = try self.strings.allocator().dupe(u8, name);
            gpr.value_ptr.* = .{
                .offset = offset,
                .segment = self.currentSegmentName,
            };
        }
    }

    pub fn assembleEntireFrame(self: *Assembly, io: std.Io, frame: []const u8, name: []const u8) !void {
        var parser = try Parser.init(io, self.allocator);
        defer parser.deinit();

        try parser.lexer.pushFrame(frame, name);
        const capacity = frame.len / 4;

        if (self.segments.getPtr("data")) |data| {
            try data.ensureTotalCapacity(self.allocator, capacity);
        }

        if (self.segments.getPtr("text")) |text| {
            try text.ensureTotalCapacity(self.allocator, capacity);
        }

        while (parser.lexer.frameHead != null) {
            const mark = parser.lexer.bookmark();
            
            const statement = parser.parseStatement() catch |err| {
                if (err == parsing.ParseError.UnexpectedEOF) break;
                if (parser.lexer.frameHead == null) break;

                parser.lexer.showErrorHere(err);
                try parser.skipToStatementEnd();
                continue;
            };

            try self.encodeStatement(statement, mark);
        }
    }

    pub fn assembleEntireFile(self: *Assembly, io: std.Io, filepath: []const u8) !void {
        var parser = try Parser.init(io, self.allocator);
        defer parser.deinit();

        try parser.lexer.openFile(filepath);
        if (parser.lexer.frameHead) |head| {
            const capacity = head.input.len / 4;

            if (self.segments.getPtr("data")) |data| {
                try data.ensureTotalCapacity(self.allocator, capacity);
            }

            if (self.segments.getPtr("text")) |text| {
                try text.ensureTotalCapacity(self.allocator, capacity);
            }
        }

        while (parser.lexer.frameHead != null) {
            const mark = parser.lexer.bookmark();

            const statement = parser.parseStatement() catch |err| {
                if (err == parsing.ParseError.UnexpectedEOF) break;
                if (parser.lexer.frameHead == null) break;

                parser.lexer.showErrorHere(err);
                try parser.skipToStatementEnd();
                continue;
            };

            try self.encodeStatement(statement, mark);
        }
    }

    pub fn patchStaticRelocations(self: *Assembly) void {
        var i: usize = 0;
        while (i < self.relocations.items.len) {
            const rel = self.relocations.items[i];

            if (rel.kind != .pc16) {
                i += 1;
                continue;
            }

            const symbol = self.symbols.get(rel.name) orelse {
                i += 1;
                continue;
            };

            if (!std.mem.eql(u8, rel.section, symbol.segment)) {
                i += 1;
                continue;
            }

            const segment = self.segments.getPtr(rel.section).?;

            const pc = rel.addr;
            const target = symbol.offset;

            const delta = @as(i32, @intCast(target)) - @as(i32, @intCast(pc + 4));
            const imm = @as(i16, @truncate(delta >> 2));

            var word: u32 = undefined;
            std.mem.copyForwards(u8, std.mem.asBytes(&word), segment.items[pc..][0..4]);

            word &= 0xFFFF0000;
            word |= @as(u16, @bitCast(imm));
            std.mem.copyForwards(u8, segment.items[pc..][0..4], std.mem.asBytes(&word));

            self.allocator.free(rel.name);
            _ = self.relocations.swapRemove(i);
        }
    }

    pub fn createElfBlob(self: *Assembly, elfType: c.ElfType, entryPoint: u32) ![]u8 {
        var strtab = try std.ArrayList(u8).initCapacity(self.strings.allocator(), 1);
        defer strtab.deinit(self.strings.allocator());
        try strtab.append(self.strings.allocator(), 0);

        var symtab = try std.ArrayList(c.ElfSym).initCapacity(self.allocator, 1);
        defer symtab.deinit(self.allocator);
        try symtab.append(self.allocator, std.mem.zeroes(c.ElfSym));

        var symbolIndices = std.StringHashMap(u32).init(self.allocator);
        defer symbolIndices.deinit();

        var sectionIndices = std.StringHashMap(u16).init(self.allocator);
        defer sectionIndices.deinit();

        var sections = try std.ArrayList(c.ElfRawSection).initCapacity(self.allocator, 8);
        defer sections.deinit(self.allocator);

        var segit = self.segments.iterator();
        var nextSectionIndex: u16 = 1;
        while (segit.next()) |entry| {
            const name = try self.strings.allocator().dupeZ(u8, entry.key_ptr.*);
            const seg = entry.value_ptr.*;

            try sectionIndices.put(entry.key_ptr.*, nextSectionIndex);
            nextSectionIndex += 1;

            const flags: c.ElfShFlags =
                if (std.mem.eql(u8, name, ".text"))
                    c.SHF_ALLOC | c.SHF_EXECINSTR
                else if (std.mem.eql(u8, name, ".data"))
                    c.SHF_ALLOC | c.SHF_WRITE
                else if (std.mem.eql(u8, name, ".rodata"))
                    c.SHF_ALLOC
                else
                    c.SHF_NONE;

            try sections.append(self.allocator, .{
                .name = name.ptr,
                .data = seg.items.ptr,
                .size = @intCast(seg.items.len),
                .type = c.SHT_PROGBITS,
                .flags = flags,
                .addralign = 4,
                .link = 0,
                .info = 0,
                .entsize = 0
            });
        }

        var syms = self.symbols.iterator();
        while (syms.next()) |entry| {
            const name = entry.key_ptr.*;
            const sym = entry.value_ptr.*;

            const stringOff: u32 = @intCast(strtab.items.len);

            try strtab.appendSlice(self.allocator, name);
            try strtab.append(self.allocator, 0);

            const index: u32 = @intCast(symtab.items.len);
            try symbolIndices.put(name, index);

            try symtab.append(self.allocator, .{
                .st_name = stringOff,
                .st_value = @intCast(sym.offset),
                .st_size = 0,
                .st_info = 0,
                .st_other = 0,
                .st_shndx = sectionIndices.get(sym.segment).?
            });
        }

        var relocsBySection = std.StringHashMap(std.ArrayList(c.ElfRel)).init(self.allocator);
        defer {
            var it = relocsBySection.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }

            relocsBySection.deinit();
        }

        for (self.relocations.items) |rel| {
            const gpr = try relocsBySection.getOrPut(rel.section);
            if (!gpr.found_existing) {
                gpr.value_ptr.* = std.ArrayList(c.ElfRel).empty;
            }

            const relType = switch (rel.kind) {
                .rtype => c.R_RTM32_RTYPE,
                .lo16 => c.R_RTM32_LO16,
                .hi16 => c.R_RTM32_HI16,
                .pc16 => c.R_RTM32_PC16,
                .tail27 => c.R_RTM32_TAIL27,
                .word => c.R_RTM32_WORD,
            };

            try gpr.value_ptr.append(self.allocator, .{
                .r_offset = @intCast(rel.addr),
                .r_info = c.ELF32_R_INFO(
                    symbolIndices.get(rel.name).?,
                    relType
                )
            });
        }

        const strtabIndex: u16 = nextSectionIndex;
        nextSectionIndex += 1;

        try sections.append(self.allocator, .{
            .name = ".strtab",
            .data = strtab.items.ptr,
            .size = @intCast(strtab.items.len),
            .type = c.SHT_STRTAB,
            .flags = c.SHF_NONE,
            .addralign = 1,
            .link = 0,
            .info = 0,
            .entsize = 0
        });

        const symtabIndex: u16 = nextSectionIndex;
        nextSectionIndex += 1;

        try sections.append(self.allocator, .{
            .name = ".symtab",
            .data = @ptrCast(symtab.items.ptr),
            .size = @intCast(symtab.items.len * @sizeOf(c.ElfSym)),
            .type = c.SHT_SYMTAB,
            .flags = c.SHF_NONE,
            .addralign = 4,
            .link = strtabIndex,
            .info = 0,
            .entsize = @sizeOf(c.ElfSym)
        });

        var relit = relocsBySection.iterator();
        while (relit.next()) |entry| {
            const secname = entry.key_ptr.*;
            const rels = entry.value_ptr.*;

            const relname = try std.fmt.allocPrint(self.strings.allocator(), ".rel{s}", .{secname});
            try sections.append(self.allocator, .{
                .name = relname.ptr,
                .data = @ptrCast(rels.items.ptr),
                .size = @intCast(rels.items.len * @sizeOf(c.ElfRel)),
                .type = c.SHT_REL,
                .flags = c.SHF_NONE,
                .addralign = 4,
                .link = symtabIndex,
                .info = sectionIndices.get(secname).?,
                .entsize = @sizeOf(c.ElfRel)
            });
        }

        const size = c.elf_writer_calculate_size(sections.items.ptr, sections.items.len);
        const blob = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(blob);

        const status = c.elf_writer_serialize(
            blob.ptr,
            blob.len,
            elfType,
            entryPoint,
            sections.items.ptr,
            sections.items.len,
        );

        if (status != c.ELF_SUCCESS) {
            return AssemblyError.SerializationFailed;
        } else {
            return blob;
        }
    }

    pub fn writeElf(self: *Assembly, io: std.Io, filepath: []const u8, elfType: c.ElfType, entryPoint: u32) !void {
        const blob = try self.createElfBlob(elfType, entryPoint);
        defer self.allocator.free(blob);

        const file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, blob);
    }
};

test "assembly initializes default segments" {
    var as = try Assembly.init(std.testing.allocator);
    defer as.deinit();

    try std.testing.expect(as.segments.contains("text"));
    try std.testing.expect(as.segments.contains("data"));

    try std.testing.expectEqualStrings("text", as.currentSegmentName);
    try std.testing.expectEqual(@as(usize, 0), as.currentSegment.items.len);
}

test "arbitrary sections" {
    var as = try Assembly.init(std.testing.allocator);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section "alpha"
        \\.byte 1
        \\.section "beta"
        \\.byte 2
        \\.section "alpha"
        \\.byte 3
    , "<test>");

    try std.testing.expect(as.segments.contains("alpha"));
    try std.testing.expect(as.segments.contains("beta"));

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 3 }, as.segments.get("alpha").?.items);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2 }, as.segments.get("beta").?.items);
}

test "labels record correct segment and offset" {
    var as = try Assembly.init(std.testing.allocator);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section alpha
        \\first:
        \\.byte 1
        \\.byte 2
        \\.section beta
        \\second:
        \\.word 0x12345678
    , "<test>");

    const first = as.symbols.get("first").?;
    try std.testing.expectEqual(@as(usize, 0), first.offset);
    try std.testing.expectEqualStrings("alpha", first.segment);

    const second = as.symbols.get("second").?;
    try std.testing.expectEqual(@as(usize, 0), second.offset);
    try std.testing.expectEqualStrings("beta", second.segment);
}

test "relocation generation" {
    var as = try Assembly.init(std.testing.allocator);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section text
        \\lw $a0, msg($zero)
        \\.section data
        \\msg:
        \\.word 42
    , "<test>");

    try std.testing.expectEqual(@as(usize, 1), as.relocations.items.len);

    const r = as.relocations.items[0];
    try std.testing.expectEqual(isa.RelocationMode.lo16, r.kind);
    try std.testing.expectEqualStrings("msg", r.name);
    try std.testing.expectEqual(@as(usize, 0), r.addr);
}

test "sample program" {
    var as = try Assembly.init(std.testing.allocator);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section data
        \\msg: .nascii "To try (goodbye) (bye, bye, bye, bye, bye, bye, bye, bye)"
        \\
        \\.section text
        \\start:
        \\xor $zero, $zero, $zero
        \\lw $a0, msg($zero)
        \\orih $t0, $zero, 0xFFFF
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
    , "<test>");

    try std.testing.expect(as.symbols.contains("msg"));
    try std.testing.expect(as.symbols.contains("start"));
    try std.testing.expect(as.symbols.contains("loop"));
    try std.testing.expect(as.symbols.contains("bye"));

    try std.testing.expect(as.segments.get("text").?.items.len > 0);
    try std.testing.expect(as.segments.get("data").?.items.len > 4);

    // as.patchStaticRelocations();
    // try std.testing.expectEqual(@as(usize, 0), as.relocations.items.len);
}
