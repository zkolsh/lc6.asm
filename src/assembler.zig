const c = @import("elf_io");
const std =  @import("std");
const isa =  @import("isa.zig");

const Parser = @import("parser.zig");
const Tokenizer = @import("tokenizer.zig");
const Assembly = @This();

allocator: std.mem.Allocator,
strings: std.heap.ArenaAllocator,
sources: ?Tokenizer,

segments: std.StringHashMap(Segment),
currentSegment: *Segment,
currentSegmentName: []const u8,

symbols: std.StringHashMap(Symbol),
relocations: std.ArrayList(Relocation),

diagnostics: *std.Io.Writer,

pub const Symbol = struct {
    offset: usize,
    segment: []const u8,
};

pub const Relocation = struct {
    addr: usize,
    name: []const u8,
    offset: i32 = 0,
    section: []const u8,
    kind: isa.RelocationMode,
    bookmark: Tokenizer.Bookmark,
};

const Segment = std.ArrayList(u8);

pub const Error = error {
    InvalidAlignment,
    InvalidLabel,
    InvalidRelocation,
    LabelNotAllowedHere,
    SerializationFailed,
    SymbolRedefined,
    UnresolvedSymbol,
} || Parser.Error;

pub fn init(allocator: std.mem.Allocator, stderr: *std.Io.Writer) !Assembly {
    var segments = std.StringHashMap(Segment).init(allocator);
    try segments.put(".text", std.ArrayList(u8).empty);
    try segments.put(".data", std.ArrayList(u8).empty);

    var symbols = std.StringHashMap(Symbol).init(allocator);
    try symbols.put("heap_base", .{.offset = 0, .segment="?heap"});

    return .{
        .allocator = allocator,
        .strings = std.heap.ArenaAllocator.init(allocator),
        .sources = null,
        .segments = segments,
        .currentSegment = segments.getPtr(".text").?,
        .currentSegmentName = ".text",
        .symbols = symbols,
        .relocations = try std.ArrayList(Relocation).initCapacity(allocator, 32),
        .diagnostics = stderr,
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

pub fn encodeStatement(self: *Assembly, stmt: isa.Statement, bookmark: Tokenizer.Bookmark) Error!void {
    switch (stmt.value) {
        .section => |name| {
            if (stmt.label.len != 0) {
                return Error.LabelNotAllowedHere;
            }

            self.currentSegment = try self.getOrPutSegment(name);
            self.currentSegmentName = try self.strings.allocator().dupe(u8, name);
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

            const savedName = try self.strings.allocator().dupe(u8, label);
            try self.relocations.append(self.allocator, .{
                .addr = labelLoc,
                .name = savedName,
                .section = self.currentSegmentName,
                .kind = .word,
                .bookmark = bookmark,
            });

            try self.currentSegment.appendNTimes(self.allocator, 0x77, 4);
        },

        .lo16 => |label| {
            try self.alignSegment(self.currentSegment, 2);
            labelLoc = self.getOffset();

            const savedName = try self.strings.allocator().dupe(u8, label);
            try self.relocations.append(self.allocator, .{
                .addr = labelLoc,
                .name = savedName,
                .section = self.currentSegmentName,
                .kind = .ptrlo,
                .bookmark = bookmark,
            });

            try self.currentSegment.appendNTimes(self.allocator, 0x47, 2);
        },

        .hi16 => |label| {
            try self.alignSegment(self.currentSegment, 2);
            labelLoc = self.getOffset();

            const savedName = try self.strings.allocator().dupe(u8, label);
            try self.relocations.append(self.allocator, .{
                .addr = labelLoc,
                .name = savedName,
                .section = self.currentSegmentName,
                .kind = .ptrhi,
                .bookmark = bookmark,
            });

            try self.currentSegment.appendNTimes(self.allocator, 0x74, 2);
        },

        .rtype => |r| {
            try self.alignSegment(self.currentSegment, 4);
            labelLoc = self.getOffset();

            const imm = switch (r.aux) {
                .static => |x| x,
                .dynamic => |dyn| blk: {
                    const savedName = try self.strings.allocator().dupe(u8, dyn.label);
                    try self.relocations.append(self.allocator, .{
                        .addr = labelLoc,
                        .name = savedName,
                        .offset = dyn.offset,
                        .section = self.currentSegmentName,
                        .kind = .aux,
                        .bookmark = bookmark,
                    });

                    break :blk 0;
                },
                .pointer => return Error.InvalidRelocation,
            };

            const mangled: u32
                = (@as(u32, isa.RType.getRInfo(r.funct).funct))
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

            const info = isa.IType.getInfo(i.opcode);
            const imm = switch (i.imm) {
                .static => |x| x,
                .dynamic => |dyn| blk: {
                    const savedName = try self.strings.allocator().dupe(u8, dyn.label);
                    try self.relocations.append(self.allocator, .{
                        .addr = labelLoc,
                        .name = savedName,
                        .offset = dyn.offset,
                        .section = self.currentSegmentName,
                        .kind = info.reltype.?,
                        .bookmark = bookmark,
                    });

                    break :blk 0;
                },

                .pointer => |x| blk: {
                    const savedName = try self.strings.allocator().dupe(u8, x.label);
                    try self.relocations.append(self.allocator, .{
                        .addr = labelLoc,
                        .name = savedName,
                        .offset = 0,
                        .section = self.currentSegmentName,
                        .kind = if (x.high) .ptrhi else .ptrlo,
                        .bookmark = bookmark,
                    });

                    break :blk 0;
                },
            };

            const lr: u32 = switch (i.linkRegister) {
                .lr0 => 0,
                .lr1 => 1,
                .lr2 => 2,
                .lr3 => 3,
                else => 0,
            };

            const rt: u32 = switch (i.opcode) {
                .jr    => 0,
                .jalr  => 1 << 20,
                .jalrx => (1 << 21) | (lr << 19),
                else   => @as(u32, @intFromEnum(i.rt)) << 17,
            };

            const high: u32 = switch (i.opcode) {
                .lci, .anh, .orh, .xorh => 1 << 16,
                else => 0,
            };

            const mangled: u32
                = (@as(u32, info.opcode) << 27)
                | (@as(u32, @intFromEnum(i.rs)) << 22)
                | rt
                | high
                | @as(u32, @intCast(imm));

            const view = std.mem.nativeToLittle(u32, mangled);
            try self.currentSegment.appendSlice(self.allocator, std.mem.asBytes(&view));
        },

        .jtype => |j| {
            try self.alignSegment(self.currentSegment, 4);
            labelLoc = self.getOffset();

            const info = isa.JType.getInfo(j.opcode);
            const imm = switch (j.imm) {
                .static => |x| try validateImmediate(info.immtype.?, x),
                .dynamic => |dyn| blk: {
                    const savedName = try self.strings.allocator().dupe(u8, dyn.label);
                    try self.relocations.append(self.allocator, .{
                        .addr = labelLoc,
                        .name = savedName,
                        .offset = dyn.offset,
                        .section = self.currentSegmentName,
                        .kind = info.reltype.?,
                        .bookmark = bookmark,
                    });

                    break :blk 0;
                },

                .pointer => |x| blk: {
                    const savedName = try self.strings.allocator().dupe(u8, x.label);
                    try self.relocations.append(self.allocator, .{
                        .addr = labelLoc,
                        .name = savedName,
                        .offset = 0,
                        .section = self.currentSegmentName,
                        .kind = if (x.high) .ptrhi else .ptrlo,
                        .bookmark = bookmark,
                    });

                    break :blk 0;
                },
            };

            const so: u32 = switch (j.opcode) {
                .j    => 0b00,
                .jal  => 0b01,
                .jalx => 0b10,
            };

            const lr: u32 = switch (j.linkRegister) {
                .lr0 => 0,
                .lr1 => 1,
                .lr2 => 2,
                .lr3 => 3,
                else => 0,
            };

            const mangled: u32
                = (@as(u32, info.opcode) << 27)
                | (so << 25)
                | (lr << 24)
                | @as(u32, @intCast(imm));

            const view = std.mem.nativeToLittle(u32, mangled);
            try self.currentSegment.appendSlice(self.allocator, std.mem.asBytes(&view));
        },
    }

    if (stmt.label.len != 0) {
        try self.defineLabel(stmt.label, labelLoc);
    }
}

fn getOrPutSegment(self: *Assembly, name: []const u8) Error!*Segment {
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
        return Error.InvalidAlignment;
    }

    const remainder = segment.items.len % alignment;
    if (remainder != 0) {
        try segment.appendNTimes(self.allocator, 0, alignment - remainder);
    }
}

fn defineLabel(self: *Assembly, name: []const u8, offset: usize) Error!void {
    if (name.len == 0) {
        return Error.InvalidLabel;
    }

    const gpr = try self.symbols.getOrPut(name);
    if (gpr.found_existing) {
        return Error.SymbolRedefined;
    } else {
        gpr.key_ptr.* = try self.strings.allocator().dupe(u8, name);
        gpr.value_ptr.* = .{
            .offset = offset,
            .segment = self.currentSegmentName,
        };
    }
}

fn validateImmediate(target: isa.ImmediateKind, immediate: u25) Error!u25 {
    return switch (target) {
        .elimm => std.math.cast(u25, immediate) orelse return Error.NumericOverflow,
        .vlimm => std.math.cast(u24, immediate) orelse return Error.NumericOverflow,
        .llimm => std.math.cast(u20, immediate) orelse return Error.NumericOverflow,
        .limm  => std.math.cast(u19, immediate) orelse return Error.NumericOverflow,
        .imm   => std.math.cast(u17, immediate) orelse return Error.NumericOverflow,
        .simm  => std.math.cast(u16, immediate) orelse return Error.NumericOverflow,
        .aux   => std.math.cast(u2,  immediate) orelse return Error.NumericOverflow,
    };
}

pub fn assembleEntireFrame(self: *Assembly, io: std.Io, frame: []const u8, name: []const u8) !void {
    var parser = try Parser.init(io, self.allocator);
    defer parser.deinit();

    try parser.lexer.pushFrame(frame, name);
    const capacity = frame.len / 4;

    self.sources = parser.lexer;
    defer self.sources = null;

    if (self.segments.getPtr("data")) |data| {
        try data.ensureTotalCapacity(self.allocator, capacity);
    }

    if (self.segments.getPtr("text")) |text| {
        try text.ensureTotalCapacity(self.allocator, capacity);
    }

    while (parser.lexer.frameHead != null) {
        try parser.skipToStatementStart();
        const mark = try parser.lexer.bookmark();

        const statement = parser.parseStatement() catch |err| {
            if (err == Parser.Error.UnexpectedEOF) break;
            if (parser.lexer.frameHead == null) break;

            try parser.lexer.showErrorHere(self.diagnostics, err);
            try parser.skipToStatementEnd();
            continue;
        };

        const cursor = try parser.lexer.bookmark();
        self.encodeStatement(statement, mark) catch |err| {
            parser.lexer.restore(mark);
            try parser.lexer.showErrorHere(self.diagnostics, err);
            parser.lexer.restore(cursor);
            return err;
        };
    }

    try self.diagnostics.flush();
}

pub fn assembleEntireFile(self: *Assembly, io: std.Io, filepath: []const u8) !void {
    var parser = try Parser.init(io, self.allocator);
    defer parser.deinit();

    self.sources = parser.lexer;
    defer self.sources = null;

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

    var firstErr: ?Error = null;
    while (parser.lexer.frameHead != null) {
        try parser.skipToStatementStart();
        const mark = try parser.lexer.bookmark();

        const statement = parser.parseStatement() catch |err| {
            if (err == Parser.Error.UnexpectedEOF) break;
            if (parser.lexer.frameHead == null) break;

            if (firstErr == null) {
                firstErr = err;
            }

            try parser.lexer.showErrorHere(self.diagnostics, err);
            try parser.skipToStatementEnd();
            continue;
        };

        const cursor = try parser.lexer.bookmark();
        self.encodeStatement(statement, mark) catch |err| {
            parser.lexer.restore(mark);
            try parser.lexer.showErrorHere(self.diagnostics, err);
            parser.lexer.restore(cursor);

            if (firstErr == null) {
                firstErr = err;
            }
        };
    }

    try self.diagnostics.flush();

    if (firstErr) |e| {
        return e;
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

    const SegmentEntry = struct {
        name: []const u8,
        seg: *std.ArrayList(u8),
    };

    var ordered = std.ArrayList(SegmentEntry).empty;
    defer ordered.deinit(self.allocator);

    var textIndex: usize = 0;
    var segIndex: usize = 0;

    var segit = self.segments.iterator();
    while (segit.next()) |entry| : (segIndex += 1) {
        if (std.mem.eql(u8, entry.key_ptr.*, ".text")) {
            textIndex = segIndex;
        }

        try ordered.append(self.allocator, .{
            .name = entry.key_ptr.*,
            .seg = entry.value_ptr,
        });
    }

    if (textIndex != 0) {
        std.mem.swap(SegmentEntry, &ordered.items[0], &ordered.items[textIndex]);
    }

    var nextSectionIndex: u16 = 1;
    for (ordered.items) |segment| {
        const name = try self.strings.allocator().dupeSentinel(u8, segment.name, 0);
        const seg = segment.seg;

        if (std.mem.eql(u8, name, ".text")) {
            textIndex = segIndex;
        }

        try sectionIndices.put(segment.name, nextSectionIndex);
        try sectionIndices.put(name, nextSectionIndex);
        if (segment.name.len > 0 and segment.name[0] == '.') {
            try sectionIndices.put(segment.name[1..], nextSectionIndex);
        }
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
            .entsize = 0,
            .vaddr = 0,
        });
    }

    var syms = self.symbols.iterator();
    while (syms.next()) |entry| {
        const name = entry.key_ptr.*;
        const sym = entry.value_ptr.*;

        const stringOff: u32 = @intCast(strtab.items.len);

        try strtab.appendSlice(self.strings.allocator(), name);
        try strtab.append(self.strings.allocator(), 0);

        const index: u32 = @intCast(symtab.items.len);
        try symbolIndices.put(name, index);

        const isHeapBase = std.mem.eql(u8, name, "heap_base");
        const shndx: u16 = if (isHeapBase) c.SHN_UNDEF else sectionIndices.get(sym.segment).?;
        const bind: u8 = if (isHeapBase) c.STB_GLOBAL else c.STB_LOCAL;
        const stInfo: u8 = @intCast(c.ELF32_ST_INFO(bind, c.STT_NOTYPE));
        try symtab.append(self.allocator, .{
            .st_name = stringOff,
            .st_value = @intCast(sym.offset),
            .st_size = 0,
            .st_info = stInfo,
            .st_other = 0,
            .st_shndx = shndx,
        });
    }

    var relsBySection = std.StringHashMap(std.ArrayList(c.ElfRel)).init(self.allocator);
    defer {
        var it = relsBySection.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }

        relsBySection.deinit();
    }

    var relasBySection = std.StringHashMap(std.ArrayList(c.ElfRela)).init(self.allocator);
    defer {
        var it = relasBySection.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }

        relasBySection.deinit();
    }

    var relocationError: ?Error = null;
    for (self.relocations.items) |rel| {
        const relType = switch (rel.kind) {
            .ptrlo  => c.R_RTM32_PTRLO,
            .ptrhi  => c.R_RTM32_PTRHI,
            .word  => c.R_RTM32_WORD,
            .elimm => c.R_RTM32_ELIMM,
            .vlimm => c.R_RTM32_VLIMM,
            .llimm => c.R_RTM32_LLIMM,
            .limm  => c.R_RTM32_LIMM,
            .imm   => c.R_RTM32_IMM,
            .simm  => c.R_RTM32_SIMM,
            .aux   => c.R_RTM32_AUX,
        };

        if (symbolIndices.get(rel.name)) |symbolIndex| {
            if (rel.offset == 0) {
                const gpr = try relsBySection.getOrPut(rel.section);
                if (!gpr.found_existing) {
                    gpr.value_ptr.* = std.ArrayList(c.ElfRel).empty;
                }

                try gpr.value_ptr.append(self.allocator, .{
                    .r_offset = @intCast(rel.addr),
                    .r_info = c.ELF32_R_INFO(
                        symbolIndex,
                        relType
                    )
                });
            } else {
                const gpr = try relasBySection.getOrPut(rel.section);
                if (!gpr.found_existing) {
                    gpr.value_ptr.* = std.ArrayList(c.ElfRela).empty;
                }

                try gpr.value_ptr.append(self.allocator, .{
                    .r_offset = @intCast(rel.addr),
                    .r_info = c.ELF32_R_INFO(
                        symbolIndex,
                        relType
                    ),
                    .r_addend = rel.offset,
                });
            }
        } else if (self.sources) |*sources| {
            try self.diagnostics.writeAll("when patching symbol ");
            try self.diagnostics.writeAll(rel.name);
            try self.diagnostics.writeAll(":\n");
            sources.restore(rel.bookmark);

            if (sources.frameHead) |head| {
                head.pos = @max(0, head.pos - 1);
            }

            try sources.showErrorHere(self.diagnostics, Error.UnresolvedSymbol);
            relocationError = relocationError orelse Error.UnresolvedSymbol;

            try self.diagnostics.flush();
        } else {
            try self.diagnostics.writeAll("obtuse error patching symbol ");
            try self.diagnostics.writeAll(rel.name);
            try self.diagnostics.writeAll(": ");
            try self.diagnostics.writeAll(@errorName(Error.UnresolvedSymbol));
            relocationError = relocationError orelse Error.UnresolvedSymbol;

            try self.diagnostics.flush();
        }
    }

    if (relocationError) |err| {
        return err;
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
        .entsize = 0,
        .vaddr = 0,
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
        .entsize = @sizeOf(c.ElfSym),
        .vaddr = 0,
    });

    var relit = relsBySection.iterator();
    while (relit.next()) |entry| {
        const secname = entry.key_ptr.*;
        const rels = entry.value_ptr.*;

        const relname = try std.fmt.allocPrintSentinel(self.strings.allocator(), ".rel{s}", .{secname}, 0);
        try sections.append(self.allocator, .{
            .name = relname.ptr,
            .data = @ptrCast(rels.items.ptr),
            .size = @intCast(rels.items.len * @sizeOf(c.ElfRel)),
            .type = c.SHT_REL,
            .flags = c.SHF_NONE,
            .addralign = 4,
            .link = symtabIndex,
            .info = sectionIndices.get(secname).?,
            .entsize = @sizeOf(c.ElfRel),
            .vaddr = 0,
        });
    }

    var relait = relasBySection.iterator();
    while (relait.next()) |entry| {
        const secname = entry.key_ptr.*;
        const relas = entry.value_ptr.*;

        const relaname = try std.fmt.allocPrintSentinel(self.strings.allocator(), ".rela{s}", .{secname}, 0);
        try sections.append(self.allocator, .{
            .name = relaname.ptr,
            .data = @ptrCast(relas.items.ptr),
            .size = @intCast(relas.items.len * @sizeOf(c.ElfRela)),
            .type = c.SHT_RELA,
            .flags = c.SHF_NONE,
            .addralign = 4,
            .link = symtabIndex,
            .info = sectionIndices.get(secname).?,
            .entsize = @sizeOf(c.ElfRela),
            .vaddr = 0,
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
        return Error.SerializationFailed;
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

test "assembly initializes default segments" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();
    try diag.flush();

    try std.testing.expect(as.segments.contains(".text"));
    try std.testing.expect(as.segments.contains(".data"));

    try std.testing.expectEqualStrings(".text", as.currentSegmentName);
    try std.testing.expectEqual(@as(usize, 0), as.currentSegment.items.len);
}

test "arbitrary sections" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section "alpha"
        \\.byte 1
        \\.section "beta"
        \\.byte 2
        \\.section "alpha"
        \\.byte 3
    , "<test>");
    try diag.flush();

    try std.testing.expect(as.segments.contains("alpha"));
    try std.testing.expect(as.segments.contains("beta"));

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 3 }, as.segments.get("alpha").?.items);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2 }, as.segments.get("beta").?.items);
}

test "labels record correct segment and offset" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
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
    try diag.flush();

    const first = as.symbols.get("first").?;
    try std.testing.expectEqual(@as(usize, 0), first.offset);
    try std.testing.expectEqualStrings("alpha", first.segment);

    const second = as.symbols.get("second").?;
    try std.testing.expectEqual(@as(usize, 0), second.offset);
    try std.testing.expectEqualStrings("beta", second.segment);
}

test "relocation generation" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section text
        \\lw $a0, msg($zero)
        \\.section data
        \\msg:
        \\.word 42
    , "<test>");
    try diag.flush();

    try std.testing.expectEqual(@as(usize, 1), as.relocations.items.len);

    const r = as.relocations.items[0];
    try std.testing.expectEqual(isa.RelocationMode.imm, r.kind);
    try std.testing.expectEqualStrings("msg", r.name);
    try std.testing.expectEqual(@as(usize, 0), r.addr);
}

test "sample program" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section data
        \\msg: .nascii "To try (goodbye) (bye, bye, bye, bye, bye, bye, bye, bye)"
        \\
        \\.section text
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
    , "<test>");
    try diag.flush();

    try std.testing.expect(as.symbols.contains("msg"));
    try std.testing.expect(as.symbols.contains("start"));
    try std.testing.expect(as.symbols.contains("loop"));
    try std.testing.expect(as.symbols.contains("bye"));

    try std.testing.expect(as.segments.get("text").?.items.len > 0);
    try std.testing.expect(as.segments.get("data").?.items.len > 4);
}

test "heap_base symbol and relocation resolution" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\lw $a0, heap_base($zero)
        \\.section ".data"
        \\.word 0x11223344
        \\.word 0x55667788
    , "<test>");
    try diag.flush();

    const blob = try as.createElfBlob(c.ET_REL, 0);
    defer std.testing.allocator.free(blob);

    var view: c.ElfView = undefined;
    const parse_status = c.elf_view_parse(&view, blob.len, blob.ptr);
    try std.testing.expectEqual(c.ELF_SUCCESS, parse_status);

    var layout: c.ElfLayoutMap = undefined;
    var views = [_]c.ElfView{view};
    const layoutOk = c.elf_merge_calculate_layout(&layout, &views, 1);
    try std.testing.expectEqual(c.ELF_SUCCESS, layoutOk);

    const ram = try std.testing.allocator.alloc(u8, layout.total_memory_needed);
    defer std.testing.allocator.free(ram);

    const mergeOk = c.elf_merge(ram.ptr, ram.len, &layout, &views, 1);
    try std.testing.expectEqual(c.ELF_SUCCESS, mergeOk);

    var sectionLayout = try std.testing.allocator.alloc(c.ElfSectionAddress, layout.section_count);
    defer std.testing.allocator.free(sectionLayout);

    for (layout.sections[0..layout.section_count], 0..) |*section, i| {
        sectionLayout[i] = .{
            .section_name = &section.name,
            .base_vaddr = @as(u32, @intCast(section.base_vaddr)),
        };
    }

    const text = &layout.sections[0];
    const patchOk = c.elf_view_patch_relocations(&view, ram.ptr + text.base_vaddr, text.size, &text.name, sectionLayout.ptr, sectionLayout.len);
    try std.testing.expectEqual(c.ELF_SUCCESS, patchOk);

    var instruction: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&instruction), ram[0..4]);
    const imm17 = instruction & 0x1FFFF;
    try std.testing.expectEqual(@as(u32, 12), imm17);
}

test "error: label not allowed on section directive" {
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    var as = try Assembly.init(std.testing.allocator, &stderr.writer);
    defer as.deinit();

    const err = as.assembleEntireFrame(std.testing.io,
        \\bad_label: .section ".text"
    , "<test>");
    try stderr.writer.flush();
    try std.testing.expectError(Error.LabelNotAllowedHere, err);
}

test "error: symbol redefined in same or different section" {
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    var as = try Assembly.init(std.testing.allocator, &stderr.writer);
    defer as.deinit();

    const err = as.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\my_label: add $zero, $zero, $zero
        \\my_label: addi $t0, $t0, 1
    , "<test>");
    try stderr.writer.flush();
    try std.testing.expectError(Error.SymbolRedefined, err);
}

test "error: unresolved symbol during ELF blob creation" {
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    var as = try Assembly.init(std.testing.allocator, &stderr.writer);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\lw $a0, nonexistent_symbol($zero)
    , "<test>");

    try stderr.writer.flush();
    try std.testing.expectEqual(@as(usize, 1), as.relocations.items.len);
    const err = as.createElfBlob(c.ET_REL, 0);
    try std.testing.expectError(Error.UnresolvedSymbol, err);
    try stderr.writer.flush();
}

test "immediate data directives" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\b1: .byte 0x11 0x22 0x33
        \\s1: .short 0x4455 0x6677
        \\w1: .word 0x8899AABB
        \\str1: .asciiz "ABC"
        \\str2: .nascii "DEF"
        \\pad1: .pad 3 2 (8)
    , "<test>");
    try diag.flush();

    const data = as.segments.get(".data").?.items;

    try std.testing.expectEqual(@as(usize, 0), as.symbols.get("b1").?.offset);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33 }, data[0..3]);

    try std.testing.expectEqual(@as(usize, 4), as.symbols.get("s1").?.offset);
    try std.testing.expectEqual(@as(u8, 0), data[3]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x55, 0x44, 0x77, 0x66 }, data[4..8]);

    try std.testing.expectEqual(@as(usize, 8), as.symbols.get("w1").?.offset);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xBB, 0xAA, 0x99, 0x88 }, data[8..12]);

    try std.testing.expectEqual(@as(usize, 12), as.symbols.get("str1").?.offset);
    try std.testing.expectEqualSlices(u8, "ABC\x00", data[12..16]);

    try std.testing.expectEqual(@as(usize, 16), as.symbols.get("str2").?.offset);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 0, 0, 0, 'D', 'E', 'F' }, data[16..23]);

    try std.testing.expectEqual(@as(usize, 24), as.symbols.get("pad1").?.offset);
    try std.testing.expectEqual(@as(usize, 29), data.len);
    for (data[23..29]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "pointer data directives" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\.byte 0xFF
        \\p_ptr: .ptr target_sym
        \\.byte 0xEE
        \\p_lo:  .lo16 target_sym
        \\.byte 0xDD
        \\p_hi:  .hi16 target_sym
        \\target_sym: .word 0
    , "<test>");
    try diag.flush();

    const data = as.segments.get(".data").?.items;

    try std.testing.expectEqual(@as(usize, 4), as.symbols.get("p_ptr").?.offset);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x77, 0x77, 0x77, 0x77 }, data[4..8]);

    try std.testing.expectEqual(@as(usize, 10), as.symbols.get("p_lo").?.offset);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x47, 0x47 }, data[10..12]);

    try std.testing.expectEqual(@as(usize, 14), as.symbols.get("p_hi").?.offset);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x74, 0x74 }, data[14..16]);

    try std.testing.expectEqual(@as(usize, 3), as.relocations.items.len);
    try std.testing.expectEqual(isa.RelocationMode.word, as.relocations.items[0].kind);
    try std.testing.expectEqual(@as(usize, 4), as.relocations.items[0].addr);
    try std.testing.expectEqual(isa.RelocationMode.ptrlo, as.relocations.items[1].kind);
    try std.testing.expectEqual(@as(usize, 10), as.relocations.items[1].addr);
    try std.testing.expectEqual(isa.RelocationMode.ptrhi, as.relocations.items[2].kind);
    try std.testing.expectEqual(@as(usize, 14), as.relocations.items[2].addr);
}

test "RType encoding" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\add $t0, $t1, $t2
        \\sll $s0, $s1, 5
        \\cfs $a0, $psw
        \\rft
    , "<test>");
    try diag.flush();

    const text = as.segments.get(".text").?.items;
    try std.testing.expectEqual(@as(usize, 16), text.len);

    const add: u32 = 12 | (0 << 7) | (@as(u32, @intFromEnum(isa.Register.t0)) << 12) | (@as(u32, @intFromEnum(isa.Register.t2)) << 17) | (@as(u32, @intFromEnum(isa.Register.t1)) << 22);
    var addRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&addRes), text[0..4]);
    try std.testing.expectEqual(add, std.mem.littleToNative(u32, addRes));

    const sll: u32 = 0 | (5 << 7) | (@as(u32, @intFromEnum(isa.Register.s0)) << 12) | (@as(u32, @intFromEnum(isa.Register.s1)) << 17) | (0 << 22);
    var sllRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&sllRes), text[4..8]);
    try std.testing.expectEqual(sll, std.mem.littleToNative(u32, sllRes));

    const cfs: u32 = 32 | (0 << 7) | (0 << 12) | (0 << 17) | (@as(u32, @intFromEnum(isa.Register.a0)) << 22);
    var cfsRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&cfsRes), text[8..12]);
    try std.testing.expectEqual(cfs, std.mem.littleToNative(u32, cfsRes));

    const rft: u32 = 35;
    var rftRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&rftRes), text[12..16]);
    try std.testing.expectEqual(rft, std.mem.littleToNative(u32, rftRes));
}

test "IType encoding" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\addi $t0, $a0, 42
        \\lci  $t1, $zero, 0x1234
        \\ori  $t2, $t1, 0x5678
        \\orh  $t2, $t2, 0x9ABC
        \\jr   $ra, 0
        \\jalr $t0, 0
        \\jalrx $t0, $lr3, 0
    , "<test>");
    try diag.flush();

    const text = as.segments.get(".text").?.items;
    try std.testing.expectEqual(@as(usize, 28), text.len);

    const addi: u32 = (3 << 27) | (@as(u32, @intFromEnum(isa.Register.a0)) << 22) | (@as(u32, @intFromEnum(isa.Register.t0)) << 17) | 42;
    var addiRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&addiRes), text[0..4]);
    try std.testing.expectEqual(addi, std.mem.littleToNative(u32, addiRes));

    const lci: u32 = (4 << 27) | (0 << 22) | (@as(u32, @intFromEnum(isa.Register.t1)) << 17) | (1 << 16) | 0x1234;
    var lciRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&lciRes), text[4..8]);
    try std.testing.expectEqual(lci, std.mem.littleToNative(u32, lciRes));

    const ori: u32 = (6 << 27) | (@as(u32, @intFromEnum(isa.Register.t1)) << 22) | (@as(u32, @intFromEnum(isa.Register.t2)) << 17) | (0 << 16) | 0x5678;
    var oriRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&oriRes), text[8..12]);
    try std.testing.expectEqual(ori, std.mem.littleToNative(u32, oriRes));

    const orh: u32 = (6 << 27) | (@as(u32, @intFromEnum(isa.Register.t2)) << 22) | (@as(u32, @intFromEnum(isa.Register.t2)) << 17) | (1 << 16) | 0x9ABC;
    var orhRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&orhRes), text[12..16]);
    try std.testing.expectEqual(orh, std.mem.littleToNative(u32, orhRes));

    const jr: u32 = (2 << 27) | (@as(u32, @intFromEnum(isa.Register.ra)) << 22);
    var jrRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&jrRes), text[16..20]);
    try std.testing.expectEqual(jr, std.mem.littleToNative(u32, jrRes));

    const jalr: u32 = (2 << 27) | (@as(u32, @intFromEnum(isa.Register.t0)) << 22) | (1 << 20);
    var jalrRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&jalrRes), text[20..24]);
    try std.testing.expectEqual(jalr, std.mem.littleToNative(u32, jalrRes));

    const jalrx: u32 = (2 << 27) | (@as(u32, @intFromEnum(isa.Register.t0)) << 22) | (1 << 21) | (3 << 19);
    var jalrxRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&jalrxRes), text[24..28]);
    try std.testing.expectEqual(jalrx, std.mem.littleToNative(u32, jalrxRes));
}

test "JType encoding" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\j 0x100
        \\jal 0x200
        \\jalx $lr2, 0x300
    , "<test>");
    try diag.flush();

    const text = as.segments.get(".text").?.items;
    try std.testing.expectEqual(@as(usize, 12), text.len);

    const j: u32 = (1 << 27) | (0b00 << 25) | (0 << 24) | 0x100;
    var jRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&jRes), text[0..4]);
    try std.testing.expectEqual(j, std.mem.littleToNative(u32, jRes));

    const jal: u32 = (1 << 27) | (0b01 << 25) | (0 << 24) | 0x200;
    var jalRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&jalRes), text[4..8]);
    try std.testing.expectEqual(jal, std.mem.littleToNative(u32, jalRes));

    const jalx: u32 = (1 << 27) | (0b10 << 25) | (2 << 24) | 0x300;
    var jalxRes: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&jalxRes), text[8..12]);
    try std.testing.expectEqual(jalx, std.mem.littleToNative(u32, jalxRes));
}

test "pointer relocations on IType and JType" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\orh $t0, $zero, .hi16 target
        \\ori $t0, $t0, .lo16 target
        \\j .lo16 target
        \\target: add $zero, $zero, $zero
    , "<test>");
    try diag.flush();

    try std.testing.expectEqual(@as(usize, 3), as.relocations.items.len);
    try std.testing.expectEqual(isa.RelocationMode.ptrhi, as.relocations.items[0].kind);
    try std.testing.expectEqualStrings("target", as.relocations.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), as.relocations.items[0].addr);

    try std.testing.expectEqual(isa.RelocationMode.ptrlo, as.relocations.items[1].kind);
    try std.testing.expectEqualStrings("target", as.relocations.items[1].name);
    try std.testing.expectEqual(@as(usize, 4), as.relocations.items[1].addr);

    try std.testing.expectEqual(isa.RelocationMode.ptrlo, as.relocations.items[2].kind);
    try std.testing.expectEqualStrings("target", as.relocations.items[2].name);
    try std.testing.expectEqual(@as(usize, 8), as.relocations.items[2].addr);
}

test "relocations with nonzero addends create .rela sections in ELF" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\table: .word 10 20 30 40
        \\.section ".text"
        \\lw $a0, table+8($zero)
    , "<test>");
    try diag.flush();

    try std.testing.expectEqual(@as(usize, 1), as.relocations.items.len);
    try std.testing.expectEqual(@as(i32, 8), as.relocations.items[0].offset);

    const blob = try as.createElfBlob(c.ET_REL, 0);
    defer std.testing.allocator.free(blob);

    var view: c.ElfView = undefined;
    const status = c.elf_view_parse(&view, blob.len, blob.ptr);
    try std.testing.expectEqual(c.ELF_SUCCESS, status);

    const relaHeader = c.elf_view_get_section_header(&view, ".rela.text");
    try std.testing.expect(relaHeader != null);
    try std.testing.expectEqual(@as(u32, @intCast(@sizeOf(c.ElfRela))), relaHeader.*.sh_size);
}

test "ELF linking and relocation resolution of multiple reloc types" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\val: .word 0x12345678
        \\val_ptr: .ptr val
        \\val_lo: .lo16 val
        \\val_hi: .hi16 val
        \\.word 0
        \\.section ".text"
        \\entry: lw $a0, val($zero)
        \\beq $a0, $zero, target
        \\add $zero, $zero, $zero
        \\target: j done
        \\done: rft
    , "<test>");
    try diag.flush();

    const blob = try as.createElfBlob(c.ET_REL, 0);
    defer std.testing.allocator.free(blob);

    var view: c.ElfView = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&view, blob.len, blob.ptr));

    var layout: c.ElfLayoutMap = undefined;
    var views = [_]c.ElfView{view};
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge_calculate_layout(&layout, &views, 1));

    const ram = try std.testing.allocator.alloc(u8, layout.total_memory_needed);
    defer std.testing.allocator.free(ram);

    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge(ram.ptr, ram.len, &layout, &views, 1));

    var sectionLayout = try std.testing.allocator.alloc(c.ElfSectionAddress, layout.section_count);
    defer std.testing.allocator.free(sectionLayout);

    for (layout.sections[0..layout.section_count], 0..) |*section, i| {
        sectionLayout[i] = .{
            .section_name = &section.name,
            .base_vaddr = @as(u32, @intCast(section.base_vaddr)),
        };
    }

    for (layout.sections[0..layout.section_count]) |*section| {
        const name = std.mem.sliceTo(&section.name, 0);
        if (!std.mem.eql(u8, name, ".text") and !std.mem.eql(u8, name, ".data")) {
            continue;
        }

        const patchOk = c.elf_view_patch_relocations(&view, ram.ptr + section.base_vaddr, section.size, &section.name, sectionLayout.ptr, sectionLayout.len);
        try std.testing.expectEqual(c.ELF_SUCCESS, patchOk);
    }

    var dataVaddr: u32 = 0;
    var textVaddr: u32 = 0;
    for (layout.sections[0..layout.section_count]) |*section| {
        const name = std.mem.sliceTo(&section.name, 0);
        if (std.mem.eql(u8, name, ".data")) dataVaddr = @as(u32, @intCast(section.base_vaddr));
        if (std.mem.eql(u8, name, ".text")) textVaddr = @as(u32, @intCast(section.base_vaddr));
    }

    var ptrWord: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&ptrWord), ram[dataVaddr + 4 .. dataVaddr + 8]);
    try std.testing.expectEqual(dataVaddr, std.mem.littleToNative(u32, ptrWord));

    var loShort: u16 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&loShort), ram[dataVaddr + 8 .. dataVaddr + 10]);
    try std.testing.expectEqual(@as(u16, 0x4747 | @as(u16, @truncate(dataVaddr))), std.mem.littleToNative(u16, loShort));

    var hiShort: u16 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&hiShort), ram[dataVaddr + 10 .. dataVaddr + 12]);
    try std.testing.expectEqual(@as(u16, 0x7474 | @as(u16, @truncate(dataVaddr >> 16))), std.mem.littleToNative(u16, hiShort));

    var beqInstr: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&beqInstr), ram[textVaddr + 4 .. textVaddr + 8]);
    const beqImm = beqInstr & 0x1FFFF;
    try std.testing.expectEqual(@as(u32, 1), beqImm);
}

test "invalid alignment in pad directive" {
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    var as = try Assembly.init(std.testing.allocator, &stderr.writer);
    defer as.deinit();

    const err = as.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\.pad 4 4 (0)
    , "<test>");
    try stderr.writer.flush();
    try std.testing.expectError(Error.InvalidAlignment, err);
}

test "dynamic relocation in rtype aux" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\sll $t0, $t1, shift_sym
        \\shift_sym: add $zero, $zero, $zero
    , "<test>");
    try diag.flush();

    try std.testing.expectEqual(@as(usize, 1), as.relocations.items.len);
    try std.testing.expectEqual(isa.RelocationMode.aux, as.relocations.items[0].kind);
    try std.testing.expectEqualStrings("shift_sym", as.relocations.items[0].name);
}

test "multi-segment assembly ELF emission" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    var as = try Assembly.init(std.testing.allocator, &diag.interface);
    defer as.deinit();

    try as.assembleEntireFrame(std.testing.io,
        \\.section ".rodata"
        \\banner: .asciiz "overloaded record update"
        \\
        \\.section ".data"
        \\array: .word 10 20 30 40 50
        \\array_ptr: .ptr array
        \\array_len: .short 5
        \\flags: .byte 0x01 0x02
        \\
        \\.section ".text"
        \\start:
        \\  xor $zero, $zero, $zero
        \\  lw $a0, array($zero)
        \\  lw $a1, array+8($zero)
        \\  add $t0, $a0, $a1
        \\  sw $t0, array+16($zero)
        \\  
        \\loop_body:
        \\  addi $t1, $zero, 10
        \\  bne $t0, $t1, loop_body
        \\  
        \\finish:
        \\  jal subroutine
        \\  j finish
        \\
        \\subroutine:
        \\  jr $ra, 0
    , "<test>");
    try diag.flush();

    try std.testing.expect(as.symbols.contains("banner"));
    try std.testing.expect(as.symbols.contains("array"));
    try std.testing.expect(as.symbols.contains("array_ptr"));
    try std.testing.expect(as.symbols.contains("array_len"));
    try std.testing.expect(as.symbols.contains("flags"));
    try std.testing.expect(as.symbols.contains("start"));
    try std.testing.expect(as.symbols.contains("loop_body"));
    try std.testing.expect(as.symbols.contains("finish"));
    try std.testing.expect(as.symbols.contains("subroutine"));

    const blob = try as.createElfBlob(c.ET_REL, 0);
    defer std.testing.allocator.free(blob);

    var view: c.ElfView = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&view, blob.len, blob.ptr));

    const textHdr = c.elf_view_get_section_header(&view, ".text");
    const dataHdr = c.elf_view_get_section_header(&view, ".data");
    const rodataHdr = c.elf_view_get_section_header(&view, ".rodata");

    try std.testing.expect(textHdr != null);
    try std.testing.expect(dataHdr != null);
    try std.testing.expect(rodataHdr != null);

    try std.testing.expectEqual(@as(u32, @bitCast(c.SHF_ALLOC | c.SHF_EXECINSTR)), textHdr.*.sh_flags);
    try std.testing.expectEqual(@as(u32, @bitCast(c.SHF_ALLOC | c.SHF_WRITE)), dataHdr.*.sh_flags);
    try std.testing.expectEqual(@as(u32, @bitCast(c.SHF_ALLOC)), rodataHdr.*.sh_flags);
}
