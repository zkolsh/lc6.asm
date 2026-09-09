const std = @import("std");
const A = @import("assembler.zig");
const T = @import("tokenizer.zig");
const c = @import("elf_io");

const helpText: []const u8 =
    \\usage: {s} [options...] <input file> -o <output file>
    \\
    \\options:
    \\  -h, --help          show this message
    \\  -v, --version       show program version
    \\  -o <file>           place the output into <file>
    \\  -l:<file>           link against an additional ELF object/library
    \\  -t <elf|mdbg>       emit using this format (default = mdbg)
    \\  -E                  stop after preprocessing
    \\  -c                  stop before linking (ELF-only)
    \\
    ;

const versionString: []const u8 = "1.2.0";

const OutputType = enum {
    elf,
    mdbg,
};

const DebugFileHeader = extern struct {
    magic: u32,
    version: u32,
    aligned_base_addr: u32,
    payload_size: u32,
    real_start_addr: u32,
    requested_size: u32,
    alignment_flags: u32,
    machine_name: [16]u8,
    segment_name: [16]u8,
};

pub fn main(init: std.process.Init) !void {
    const stderr = std.Io.File.stderr();
    var yell: [256]u8 = undefined;
    var diagnostics = stderr.writer(init.io, &yell).interface;

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    const exename = args.next();

    var inputName: ?[]const u8 = null;
    var outputName: ?[]const u8 = null;

    const allocator = init.arena.allocator();
    var libraries = try std.ArrayList([]const u8).initCapacity(allocator, 1);

    var outputType: OutputType = .mdbg;
    var linkObject = true;

    var justPreprocess = false;

    while (args.next()) |arg| {
        if (arg.len == 0) continue;

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try diagnostics.print(helpText, .{exename.?});
            return;
        } else if (std.mem.eql(u8, arg, "-o")) {
            if (outputName != null) {
                try diagnostics.print("error: only one output file is supported (found \"{s}\" and \"{s}\")\n", .{outputName.?, arg});
                std.process.exit(1);
            }

            outputName = args.next() orelse {
                try diagnostics.writeAll("error: expected output file name.\n");
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "-l:")) {
            try libraries.append(allocator, arg[3..]);
        } else if (std.mem.eql(u8, arg, "-t")) {
            const formatStr = args.next() orelse {
                try diagnostics.writeAll("error: expected format (elf or mdbg) after -t.\n");
                std.process.exit(1);
            };
            if (std.mem.eql(u8, formatStr, "elf")) {
                outputType = .elf;
            } else if (std.mem.eql(u8, formatStr, "mdbg")) {
                outputType = .mdbg;
            } else {
                try diagnostics.print("error: unrecognized format \"{s}\". Expected elf or mdbg.\n", .{formatStr});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-E")) {
            justPreprocess = true;
        } else if (std.mem.eql(u8, arg, "-c")) {
            linkObject = false;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try diagnostics.print("{s} version {s}\n", .{exename.?, versionString});
            return;
        } else if (arg[0] == '-') {
            try diagnostics.print("error: unrecognized argument \"{s}\"\n", .{arg});
            std.process.exit(1);
        } else {
            if (inputName != null) {
                try diagnostics.print("error: only one input file is supported (found \"{s}\" and \"{s}\")\n", .{inputName.?, arg});
                std.process.exit(1);
            }

            inputName = arg;
        }
    }

    if (inputName == null) {
        try diagnostics.writeAll("error: no input file.\n");
        std.process.exit(1);
    }

    if (outputName == null) {
        try diagnostics.writeAll("error: no output file.\n");
        std.process.exit(1);
    }

    if (justPreprocess) {
        var lexer = try T.Tokenizer.init(init.io, init.arena.allocator());
        defer lexer.deinit();

        const outFile = try std.Io.Dir.cwd().createFile(init.io, outputName.?, .{});
        defer outFile.close(init.io);


        const text = lexer.preprocessAll(init.arena.allocator()) catch |err| {
            try lexer.showErrorHere(&diagnostics, err);
            try diagnostics.flush();
            std.process.exit(1);
        };

        try outFile.writeStreamingAll(init.io, text);
        try diagnostics.flush();
        std.process.exit(0);
    }

    if (!linkObject and outputType == .mdbg) {
        try diagnostics.writeAll("error: cannot stop before linking (-c) when emitting an mdbg snapshot.  Remove -c or use -t elf.\n");
        std.process.exit(1);
    }

    var assembler: A.Assembly = try A.Assembly.init(allocator, &diagnostics);
    defer assembler.deinit();
    try assembler.assembleEntireFile(init.io, inputName.?);
    try diagnostics.flush();

    const mainBlob = try assembler.createElfBlob(c.ET_REL, 0);
    defer init.arena.allocator().free(mainBlob);

    if (!linkObject) {
        const outFile = try std.Io.Dir.cwd().createFile(init.io, outputName.?, .{});
        defer outFile.close(init.io);

        try outFile.writeStreamingAll(init.io, mainBlob);
        std.process.exit(0);
    }

    var views = try allocator.alloc(c.ElfView, libraries.items.len + 1);
    var status = c.elf_view_parse(&views[0], mainBlob.len, mainBlob.ptr);
    if (status != c.ELF_SUCCESS) {
        try diagnostics.print("error: failed to parse assembled object: {s}\n", .{c.elf_status_str(status)});
        std.process.exit(1);
    }

    for (libraries.items, 0..) |libPath, i| {
        const libBlob = try std.Io.Dir.cwd().readFileAlloc(init.io, libPath, init.arena.allocator(), .unlimited);

        status = c.elf_view_parse(&views[i + 1], libBlob.len, libBlob.ptr);
        if (status != c.ELF_SUCCESS) {
            try diagnostics.print("error: failed to parse library {s}: {s}\n", .{libPath, c.elf_status_str(status)});
            std.process.exit(1);
        }
    }

    var layout: c.ElfLayoutMap = undefined;
    status = c.elf_merge_calculate_layout(&layout, views.ptr, views.len);

    if (status != c.ELF_SUCCESS) {
        try diagnostics.print("error: linker layout failed: {s}\n", .{c.elf_status_str(status)});
        std.process.exit(1);
    }

    const ram = try allocator.alloc(u8, layout.total_memory_needed);
    status = c.elf_merge(ram.ptr, ram.len, &layout, views.ptr, views.len);

    if (status != c.ELF_SUCCESS) {
        try diagnostics.print("error: linker merge failed: {s}\n", .{c.elf_status_str(status)});
        std.process.exit(1);
    }

    var sectionLayout = try allocator.alloc(c.ElfSectionAddress, layout.section_count);
    defer allocator.free(sectionLayout);

    for (layout.sections[0..layout.section_count], 0..) |*section, i| {
        sectionLayout[i] = .{
            .section_name = &section.name,
            .base_vaddr = @as(u32, @intCast(section.base_vaddr)),
        };
    }

    for (views) |view| {
        if (view.header.*.e_type != c.ET_REL) {
            continue;
        }

        for (layout.sections[0..layout.section_count]) |*section| {
            const begin = section.base_vaddr;
            const end = begin + section.size;
            const name = std.mem.sliceTo(&section.name, 0);

            if (!std.mem.eql(u8, name, ".text") and !std.mem.eql(u8, name, ".data")) {
                continue;
            }

            status = c.elf_view_patch_relocations(&view, ram.ptr + begin, end - begin, &section.name, sectionLayout.ptr, sectionLayout.len);
            if (status != c.ELF_SUCCESS) {
                try diagnostics.print("error: relocation of section {s} failed: {s}\n", .{&section.name, c.elf_status_str(status)});
                std.process.exit(1);
            }
        }
    }

    const outFile = try std.Io.Dir.cwd().createFile(init.io, outputName.?, .{});
    defer outFile.close(init.io);

    switch (outputType) {
        .mdbg => {
            var minAddress: u32 = 0xFFFFFFFF;
            var maxAddress: u32 = 0;

            for (layout.sections[0..layout.section_count]) |*section| {
                if (section.size == 0) continue;
                const begin = @as(u32, @intCast(section.base_vaddr));
                const end = begin + @as(u32, @intCast(section.size));
                
                if (begin < minAddress) minAddress = begin;
                if (end > maxAddress) maxAddress = end;
            }

            if (minAddress == 0xFFFFFFFF) minAddress = 0;
            
            const alignedStart = minAddress & ~@as(u32, 3);
            const alignedEnd = (maxAddress + 3) & ~@as(u32, 3);
            const payloadSize = alignedEnd - alignedStart;
            const reqSize = maxAddress - minAddress;

            var header = std.mem.zeroes(DebugFileHeader);
            header.magic = 0x4742444D; // "MDBG"
            header.version = 2;
            header.aligned_base_addr = alignedStart;
            header.payload_size = payloadSize;
            header.real_start_addr = minAddress;
            header.requested_size = reqSize;
            header.alignment_flags = 0;

            @memcpy(header.machine_name[0..5], "RTM32");
            @memcpy(header.segment_name[0..4], "USER");

            try outFile.writeStreamingAll(init.io, std.mem.asBytes(&header));
            const sliceEnd = @min(alignedEnd, @as(u32, @intCast(ram.len)));
            if (alignedStart < sliceEnd) {
                try outFile.writeStreamingAll(init.io, ram[alignedStart..sliceEnd]);

                const len = sliceEnd - alignedStart;
                const padding = (-%len) & 3;
                const zeros = [_]u8{0, 0, 0, 0};
                try outFile.writeStreamingAll(init.io, zeros[0..padding]);
            }
        },

        .elf => {
            var finalSections = try std.ArrayList(c.ElfRawSection).initCapacity(allocator, layout.section_count);
            defer finalSections.deinit(allocator);

            var textBase: u32 = 0;
            for (layout.sections[0..layout.section_count]) |*section| {
                var flags: c.ElfShFlags = c.SHF_ALLOC;

                if (std.mem.eql(u8, std.mem.sliceTo(&section.name, 0), ".text")) {
                    flags |= c.SHF_EXECINSTR;
                    textBase = @as(u32, @intCast(section.base_vaddr));
                } else if (std.mem.eql(u8, std.mem.sliceTo(&section.name, 0), ".data")) {
                    flags |= c.SHF_WRITE;
                }

                try finalSections.append(allocator, .{
                    .name = std.mem.sliceTo(&section.name, 0).ptr,
                    .data = ram.ptr + section.base_vaddr,
                    .size = @as(u32, @intCast(section.size)),
                    .type = c.SHT_PROGBITS,
                    .flags = flags,
                    .addralign = @as(u32, @intCast(section.alignment)),
                    .link = 0,
                    .info = 0,
                    .entsize = 0
                });
            }

            const entryPoint = views[0].header.*.e_entry + textBase;
            const finalSize = c.elf_writer_calculate_size(finalSections.items.ptr, finalSections.items.len);
            const finalBlob = try allocator.alloc(u8, finalSize);
            status = c.elf_writer_serialize(
                finalBlob.ptr,
                finalBlob.len,
                c.ET_EXEC,
                entryPoint,
                finalSections.items.ptr,
                finalSections.items.len,
            );

            if (status != c.ELF_SUCCESS) {
                try diagnostics.print("error: total serialization failed: {s}\n", .{c.elf_status_str(status)});
                std.process.exit(1);
            }
            try outFile.writeStreamingAll(init.io, finalBlob);
        },
    }
}

test {
    std.testing.refAllDecls(A);
}

test "ELF two-object merge" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    const allocator = std.testing.allocator;

    var as1 = try A.Assembly.init(allocator, &diag.interface);
    defer as1.deinit();
    try as1.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\func1:
        \\  addi $t0, $zero, 1
        \\  jr $ra, 0
        \\.section ".data"
        \\data1:
        \\  .word 0x11111111 0x22222222
    , "<obj1>");

    const blob1 = try as1.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob1);

    var as2 = try A.Assembly.init(allocator, &diag.interface);
    defer as2.deinit();
    try as2.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\func2:
        \\  addi $t1, $zero, 2
        \\  jr $ra, 0
        \\.section ".data"
        \\data2:
        \\  .word 0x33333333 0x44444444
    , "<obj2>");

    const blob2 = try as2.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob2);

    var views: [2]c.ElfView = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[0], blob1.len, blob1.ptr));
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[1], blob2.len, blob2.ptr));

    var layout: c.ElfLayoutMap = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge_calculate_layout(&layout, &views, 2));

    const ram = try allocator.alloc(u8, layout.total_memory_needed);
    defer allocator.free(ram);

    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge(ram.ptr, ram.len, &layout, &views, 2));

    var textLayout: ?c.ElfLayoutSection = null;
    var dataLayout: ?c.ElfLayoutSection = null;
    for (layout.sections[0..layout.section_count]) |sec| {
        const name = std.mem.sliceTo(&sec.name, 0);
        if (std.mem.eql(u8, name, ".text")) textLayout = sec;
        if (std.mem.eql(u8, name, ".data")) dataLayout = sec;
    }

    try std.testing.expect(textLayout != null);
    try std.testing.expect(dataLayout != null);

    try std.testing.expectEqual(@as(usize, 16), textLayout.?.size);
    try std.testing.expectEqual(@as(usize, 16), dataLayout.?.size);

    const textBase = textLayout.?.base_vaddr;
    const dataBase = dataLayout.?.base_vaddr;

    var textWord0: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&textWord0), ram[textBase + 0 .. textBase + 4]);
    // addi $t0, $zero, 1 -> opcode 3, rs=0, rt=t0(14), high=0, imm=1
    const expected_addi1 = (3 << 27) | (@as(u32, 14) << 17) | 1;
    try std.testing.expectEqual(expected_addi1, std.mem.littleToNative(u32, textWord0));

    var textWord2: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&textWord2), ram[textBase + 8 .. textBase + 12]);
    // addi $t1, $zero, 2 -> opcode 3, rs=0, rt=t1(15), high=0, imm=2
    const expected_addi2 = (3 << 27) | (@as(u32, 15) << 17) | 2;
    try std.testing.expectEqual(expected_addi2, std.mem.littleToNative(u32, textWord2));

    var word0: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&word0), ram[dataBase + 0 .. dataBase + 4]);
    try std.testing.expectEqual(@as(u32, 0x11111111), std.mem.littleToNative(u32, word0));

    var word2: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&word2), ram[dataBase + 8 .. dataBase + 12]);
    try std.testing.expectEqual(@as(u32, 0x33333333), std.mem.littleToNative(u32, word2));

    var val: u32 = 0;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_peek_symbol_value(&views[0], "func1", &val));
    try std.testing.expectEqual(@as(u32, 0), val);

    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_peek_symbol_value(&views[0], "data1", &val));
    try std.testing.expectEqual(@as(u32, 0), val);

    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_peek_symbol_value(&views[1], "func2", &val));
    try std.testing.expectEqual(@as(u32, 0), val);

    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_peek_symbol_value(&views[1], "data2", &val));
    try std.testing.expectEqual(@as(u32, 0), val);

    try std.testing.expectEqual(c.ELF_SYMBOL_NOT_FOUND, c.elf_view_peek_symbol_value(&views[0], "bogus", &val));
}

test "ELF three-object merge" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    const allocator = std.testing.allocator;

    var as1 = try A.Assembly.init(allocator, &diag.interface);
    defer as1.deinit();
    try as1.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\main:
        \\  lw $a0, msg($zero)
        \\  beq $a0, $zero, done
        \\  add $zero, $zero, $zero
        \\done:
        \\  rft
        \\.section ".data"
        \\msg:
        \\  .word 0xCAFEBABE
    , "<main_obj>");

    const blob1 = try as1.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob1);

    var as2 = try A.Assembly.init(allocator, &diag.interface);
    defer as2.deinit();
    try as2.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\target_fn:
        \\  lw $a0, factor($zero)
        \\  jr $ra, 0
        \\.section ".data"
        \\factor:
        \\  .word 42
    , "<lib_obj>");

    const blob2 = try as2.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob2);

    var as3 = try A.Assembly.init(allocator, &diag.interface);
    defer as3.deinit();
    try as3.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\version_str:
        \\  .asciiz "v2.0"
    , "<const_obj>");

    const blob3 = try as3.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob3);

    var views: [3]c.ElfView = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[0], blob1.len, blob1.ptr));
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[1], blob2.len, blob2.ptr));
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[2], blob3.len, blob3.ptr));

    var layout: c.ElfLayoutMap = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge_calculate_layout(&layout, &views, 3));

    const ram = try allocator.alloc(u8, layout.total_memory_needed);
    defer allocator.free(ram);

    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge(ram.ptr, ram.len, &layout, &views, 3));

    var sectionLayout = try allocator.alloc(c.ElfSectionAddress, layout.section_count);
    defer allocator.free(sectionLayout);

    for (layout.sections[0..layout.section_count], 0..) |*section, i| {
        sectionLayout[i] = .{
            .section_name = &section.name,
            .base_vaddr = @as(u32, @intCast(section.base_vaddr)),
        };
    }

    for (views) |view| {
        for (layout.sections[0..layout.section_count]) |*section| {
            const size = @as(u32, @intCast(section.size));
            if (size == 0) continue;

            const name = std.mem.sliceTo(&section.name, 0);
            if (!std.mem.eql(u8, name, ".text") and !std.mem.eql(u8, name, ".data")) {
                continue;
            }

            const patchOk = c.elf_view_patch_relocations(&view, ram.ptr + section.base_vaddr, size, &section.name, sectionLayout.ptr, sectionLayout.len);
            try std.testing.expectEqual(c.ELF_SUCCESS, patchOk);
        }
    }

    var textVaddr: u32 = 0;
    var dataVaddr: u32 = 0;
    for (layout.sections[0..layout.section_count]) |*section| {
        const name = std.mem.sliceTo(&section.name, 0);
        if (std.mem.eql(u8, name, ".text")) textVaddr = @as(u32, @intCast(section.base_vaddr));
        if (std.mem.eql(u8, name, ".data")) dataVaddr = @as(u32, @intCast(section.base_vaddr));
    }

    var beqInstr: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&beqInstr), ram[textVaddr + 4 .. textVaddr + 8]);
    const beqImm = beqInstr & 0x1FFFF;
    try std.testing.expectEqual(@as(u32, 1), beqImm);

    var factorWord: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&factorWord), ram[dataVaddr + 4 .. dataVaddr + 8]);
    try std.testing.expectEqual(@as(u32, 42), std.mem.littleToNative(u32, factorWord));

    try std.testing.expectEqualSlices(u8, "v2.0\x00", ram[dataVaddr + 8 .. dataVaddr + 13]);
}

test "ELF four-object root with shared leaf" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    const allocator = std.testing.allocator;

    var asRoot = try A.Assembly.init(allocator, &diag.interface);
    defer asRoot.deinit();
    try asRoot.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\root_start:
        \\  xor $zero, $zero, $zero
        \\  lw $a0, root_ready($zero)
        \\  beq $a0, $zero, halt
        \\  add $zero, $zero, $zero
        \\halt:
        \\  rft
        \\.section ".data"
        \\root_ready:
        \\  .word 1
    , "<root>");

    const blobRoot = try asRoot.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blobRoot);

    var asConfig = try A.Assembly.init(allocator, &diag.interface);
    defer asConfig.deinit();
    try asConfig.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\baud_rate: .word 115200
        \\max_retries: .short 3
    , "<config>");

    const blobConfig = try asConfig.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blobConfig);

    var asFoo = try A.Assembly.init(allocator, &diag.interface);
    defer asFoo.deinit();
    try asFoo.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\foo_func:
        \\  lw $t0, foo_val($zero)
        \\  addi $t0, $t0, 10
        \\  jr $ra, 0
        \\.section ".data"
        \\foo_val:
        \\  .word 100
    , "<foo>");

    const blobFoo = try asFoo.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blobFoo);

    var asBar = try A.Assembly.init(allocator, &diag.interface);
    defer asBar.deinit();
    try asBar.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\bar_func:
        \\  lw $t1, bar_state($zero)
        \\  jr $ra, 0
        \\.section ".data"
        \\bar_state:
        \\  .word 0xAABBCCDD
    , "<bar>");

    const blobBar = try asBar.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blobBar);

    var views: [4]c.ElfView = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[0], blobRoot.len, blobRoot.ptr));
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[1], blobConfig.len, blobConfig.ptr));
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[2], blobFoo.len, blobFoo.ptr));
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[3], blobBar.len, blobBar.ptr));

    try std.testing.expectEqual(@as(u32, 0), views[0].header.*.e_entry);

    var layout: c.ElfLayoutMap = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge_calculate_layout(&layout, &views, 4));

    const ram = try allocator.alloc(u8, layout.total_memory_needed);
    defer allocator.free(ram);

    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge(ram.ptr, ram.len, &layout, &views, 4));

    var sectionLayout = try allocator.alloc(c.ElfSectionAddress, layout.section_count);
    defer allocator.free(sectionLayout);

    for (layout.sections[0..layout.section_count], 0..) |*section, i| {
        sectionLayout[i] = .{
            .section_name = &section.name,
            .base_vaddr = @as(u32, @intCast(section.base_vaddr)),
        };
    }

    for (views) |view| {
        for (layout.sections[0..layout.section_count]) |*section| {
            const size = @as(u32, @intCast(section.size));
            if (size == 0) continue;

            const name = std.mem.sliceTo(&section.name, 0);
            if (!std.mem.eql(u8, name, ".text") and !std.mem.eql(u8, name, ".data")) {
                continue;
            }

            const patchOk = c.elf_view_patch_relocations(&view, ram.ptr + section.base_vaddr, size, &section.name, sectionLayout.ptr, sectionLayout.len);
            try std.testing.expectEqual(c.ELF_SUCCESS, patchOk);
        }
    }

    var textBase: u32 = 0;
    var dataBase: u32 = 0;
    for (layout.sections[0..layout.section_count]) |sec| {
        const name = std.mem.sliceTo(&sec.name, 0);
        if (std.mem.eql(u8, name, ".text")) textBase = @as(u32, @intCast(sec.base_vaddr));
        if (std.mem.eql(u8, name, ".data")) dataBase = @as(u32, @intCast(sec.base_vaddr));
    }

    var rootBeq: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&rootBeq), ram[textBase + 8 .. textBase + 12]);
    try std.testing.expectEqual(@as(u32, 1), rootBeq & 0x1FFFF);

    var baudWord: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&baudWord), ram[dataBase + 4 .. dataBase + 8]);
    try std.testing.expectEqual(@as(u32, 115200), std.mem.littleToNative(u32, baudWord));

    var fooLw: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&fooLw), ram[textBase + 20 .. textBase + 24]);
    try std.testing.expect(fooLw != 0);

    var barStateOff: u32 = 0;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_peek_symbol_value(&views[3], "bar_state", &barStateOff));
    try std.testing.expectEqual(@as(u32, 0), barStateOff);

    var barWord: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&barWord), ram[dataBase + 16 .. dataBase + 20]);
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), std.mem.littleToNative(u32, barWord));
}

test "ELF linker error: invalid relocation target section not in layout" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator).writer;
    const allocator = std.testing.allocator;

    var as = try A.Assembly.init(allocator, &writer);
    defer as.deinit();
    try as.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\val: .word 0x12345678
        \\.section ".text"
        \\lw $a0, val($zero)
    , "<test>");

    const blob = try as.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob);

    var view: c.ElfView = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&view, blob.len, blob.ptr));

    var incompleteLayout = [_]c.ElfSectionAddress{
        .{.section_name = ".text", .base_vaddr = 0},
    };

    var textData: [16]u8 = undefined;
    const status = c.elf_view_patch_relocations(&view, &textData, textData.len, ".text", &incompleteLayout, incompleteLayout.len);
    try std.testing.expectEqual(c.ELF_INVALID_RELOCATION, status);
}

test "ELF merge section alignment and padding propagation" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    const allocator = std.testing.allocator;

    var as1 = try A.Assembly.init(allocator, &diag.interface);
    defer as1.deinit();
    try as1.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\b: .byte 1 2 3
    , "<obj1>");

    const blob1 = try as1.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob1);

    var as2 = try A.Assembly.init(allocator, &diag.interface);
    defer as2.deinit();
    try as2.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\w: .word 0x87654321
    , "<obj2>");

    const blob2 = try as2.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob2);

    var views: [2]c.ElfView = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[0], blob1.len, blob1.ptr));
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[1], blob2.len, blob2.ptr));

    var layout: c.ElfLayoutMap = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge_calculate_layout(&layout, &views, 2));

    const ram = try allocator.alloc(u8, layout.total_memory_needed);
    defer allocator.free(ram);

    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge(ram.ptr, ram.len, &layout, &views, 2));

    var dataBase: u32 = 0;
    for (layout.sections[0..layout.section_count]) |sec| {
        const name = std.mem.sliceTo(&sec.name, 0);
        if (std.mem.eql(u8, name, ".data")) {
            dataBase = @as(u32, @intCast(sec.base_vaddr));
        }
    }

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, ram[dataBase .. dataBase + 3]);

    var wordVal: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&wordVal), ram[dataBase + 4 .. dataBase + 8]);
    try std.testing.expectEqual(@as(u32, 0x87654321), std.mem.littleToNative(u32, wordVal));
}

test "ELF linker errors: invalid magic, wrong machine, truncated buffer, missing params" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator).writer;
    const allocator = std.testing.allocator;

    var as = try A.Assembly.init(allocator, &writer);
    defer as.deinit();
    try as.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\rft
    , "<test>");

    const blob = try as.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob);

    var view: c.ElfView = undefined;

    try std.testing.expectEqual(c.ELF_MISSING_PARAMS, c.elf_view_parse(null, blob.len, blob.ptr));
    try std.testing.expectEqual(c.ELF_MISSING_PARAMS, c.elf_merge_calculate_layout(null, &view, 1));
    try std.testing.expectEqual(c.ELF_MISSING_PARAMS, c.elf_merge(null, 100, undefined, &view, 1));

    var tinyBuf = [_]u8{ 0x7F, 'E', 'L', 'F' };
    try std.testing.expectEqual(c.ELF_BUFFER_TOO_SMALL, c.elf_view_parse(&view, tinyBuf.len, &tinyBuf));

    var badMagic = try allocator.dupe(u8, blob);
    defer allocator.free(badMagic);
    badMagic[0] = 0x00;
    try std.testing.expectEqual(c.ELF_INVALID_MAGIC, c.elf_view_parse(&view, badMagic.len, badMagic.ptr));

    var badArch = try allocator.dupe(u8, blob);
    defer allocator.free(badArch);
    badArch[18] = 0x03; // EM_386
    badArch[19] = 0x00;
    try std.testing.expectEqual(c.ELF_ARCH_MISMATCH, c.elf_view_parse(&view, badArch.len, badArch.ptr));

    var badClass = try allocator.dupe(u8, blob);
    defer allocator.free(badClass);
    badClass[4] = 2; // ELFCLASS64
    try std.testing.expectEqual(c.ELF_WORDSIZE_MISMATCH, c.elf_view_parse(&view, badClass.len, badClass.ptr));

    var badEndian = try allocator.dupe(u8, blob);
    defer allocator.free(badEndian);
    badEndian[5] = 2; // ELFDATA2MSB
    try std.testing.expectEqual(c.ELF_ENDIANNESS_MISMATCH, c.elf_view_parse(&view, badEndian.len, badEndian.ptr));
}

test "ELF linker errors: merge buffer too small and relocation buffer too small" {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator).writer;
    const allocator = std.testing.allocator;

    var as = try A.Assembly.init(allocator, &writer);
    defer as.deinit();
    try as.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\val: .word 0x12345678
        \\.section ".text"
        \\lw $a0, val($zero)
    , "<test>");

    const blob = try as.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob);

    var view: c.ElfView = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&view, blob.len, blob.ptr));

    var layout: c.ElfLayoutMap = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge_calculate_layout(&layout, &view, 1));

    var smallRam: [4]u8 = undefined;
    try std.testing.expectEqual(c.ELF_BUFFER_TOO_SMALL, c.elf_merge(&smallRam, smallRam.len, &layout, &view, 1));

    var sectionAddress = [_]c.ElfSectionAddress{
        .{ .section_name = ".text", .base_vaddr = 0 },
        .{ .section_name = ".data", .base_vaddr = 4 },
    };
    var smallSectionBuf: [2]u8 = undefined;
    try std.testing.expectEqual(c.ELF_BUFFER_TOO_SMALL, c.elf_view_patch_relocations(&view, &smallSectionBuf, smallSectionBuf.len, ".text", &sectionAddress, sectionAddress.len));
}

test "heap_base resolution over ELF merge" {
    var yell: [64]u8 = undefined;
    var diag = std.Io.File.stderr().writer(std.testing.io, &yell);
    const allocator = std.testing.allocator;

    var as1 = try A.Assembly.init(allocator, &diag.interface);
    defer as1.deinit();
    try as1.assembleEntireFrame(std.testing.io,
        \\.section ".text"
        \\lw $a0, heap_base($zero)
    , "<obj1>");

    const blob1 = try as1.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob1);

    var as2 = try A.Assembly.init(allocator, &diag.interface);
    defer as2.deinit();
    try as2.assembleEntireFrame(std.testing.io,
        \\.section ".data"
        \\.word 0x11111111 0x22222222 0x33333333 0x44444444
    , "<obj2>");

    const blob2 = try as2.createElfBlob(c.ET_REL, 0);
    defer allocator.free(blob2);

    var views: [2]c.ElfView = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[0], blob1.len, blob1.ptr));
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&views[1], blob2.len, blob2.ptr));

    var layout: c.ElfLayoutMap = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge_calculate_layout(&layout, &views, 2));

    const ram = try allocator.alloc(u8, layout.total_memory_needed);
    defer allocator.free(ram);

    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_merge(ram.ptr, ram.len, &layout, &views, 2));

    var sectionLayout = try allocator.alloc(c.ElfSectionAddress, layout.section_count);
    defer allocator.free(sectionLayout);

    for (layout.sections[0..layout.section_count], 0..) |*section, i| {
        sectionLayout[i] = .{
            .section_name = &section.name,
            .base_vaddr = @as(u32, @intCast(section.base_vaddr)),
        };
    }

    for (views) |view| {
        for (layout.sections[0..layout.section_count]) |*section| {
            const size = @as(u32, @intCast(section.size));
            if (size == 0) continue;
            const name = std.mem.sliceTo(&section.name, 0);
            if (!std.mem.eql(u8, name, ".text") and !std.mem.eql(u8, name, ".data")) continue;

            const patchOk = c.elf_view_patch_relocations(&view, ram.ptr + section.base_vaddr, size, &section.name, sectionLayout.ptr, sectionLayout.len);
            try std.testing.expectEqual(c.ELF_SUCCESS, patchOk);
        }
    }

    var secSize: u32 = 0;
    _ = c.elf_view_get_section(&views[0], ".text", &secSize, null);
    const expectedHeapBase = (secSize + 3) & ~@as(u32, 3);

    var instr: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&instr), ram[0..4]);
    const imm17 = instr & 0x1FFFF;
    try std.testing.expectEqual(expectedHeapBase, imm17);
}

test "ELF serializer round trip" {
    const allocator = std.testing.allocator;

    const data1 = [_]u8{1, 2, 3, 4, 5, 6, 7, 8};
    const rawSections = [_]c.ElfRawSection{
        .{
            .name = ".text",
            .data = &data1,
            .size = data1.len,
            .type = c.SHT_PROGBITS,
            .flags = c.SHF_ALLOC | c.SHF_EXECINSTR,
            .vaddr = 0,
            .addralign = 4,
            .link = 0,
            .info = 0,
            .entsize = 0,
        },
    };

    const neededSize = c.elf_writer_calculate_size(&rawSections, rawSections.len);
    try std.testing.expect(neededSize > 0);

    const outBuf = try allocator.alloc(u8, neededSize);
    defer allocator.free(outBuf);

    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_writer_serialize(outBuf.ptr, outBuf.len, c.ET_EXEC, 0x1000, &rawSections, rawSections.len));

    var view: c.ElfView = undefined;
    try std.testing.expectEqual(c.ELF_SUCCESS, c.elf_view_parse(&view, outBuf.len, outBuf.ptr));

    try std.testing.expectEqual(@as(u16, c.ET_EXEC), view.header.*.e_type);
    try std.testing.expectEqual(@as(u32, 0x1000), view.header.*.e_entry);

    var secSize: u32 = 0;
    var secFlags: u32 = 0;
    const secPtr = c.elf_view_get_section(&view, ".text", &secSize, &secFlags);
    try std.testing.expect(secPtr != null);
    try std.testing.expectEqual(@as(u32, 8), secSize);
    try std.testing.expectEqual(@as(u32, c.SHF_ALLOC | c.SHF_EXECINSTR), secFlags);
    try std.testing.expectEqualSlices(u8, &data1, secPtr[0..8]);
}
