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

const versionString: []const u8 = "1.1.0";

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
    var stdout = std.Io.File.stdout().writer(init.io, &.{});
    defer stdout.flush() catch {};
    
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
            try stdout.interface.print(helpText, .{exename.?});
            return;
        } else if (std.mem.eql(u8, arg, "-o")) {
            if (outputName != null) {
                try stdout.interface.print("error: only one output file is supported (found \"{s}\" and \"{s}\")\n", .{outputName.?, arg});
                std.process.exit(1);
            }

            outputName = args.next() orelse {
                try stdout.interface.writeAll("error: expected output file name.\n");
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "-l:")) {
            try libraries.append(allocator, arg[3..]);
        } else if (std.mem.eql(u8, arg, "-t")) {
            const formatStr = args.next() orelse {
                try stdout.interface.writeAll("error: expected format (elf or mdbg) after -t.\n");
                std.process.exit(1);
            };
            if (std.mem.eql(u8, formatStr, "elf")) {
                outputType = .elf;
            } else if (std.mem.eql(u8, formatStr, "mdbg")) {
                outputType = .mdbg;
            } else {
                try stdout.interface.print("error: unrecognized format \"{s}\". Expected elf or mdbg.\n", .{formatStr});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-E")) {
            justPreprocess = true;
        } else if (std.mem.eql(u8, arg, "-c")) {
            linkObject = false;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try stdout.interface.print("{s} version {s}\n", .{exename.?, versionString});
            return;
        } else if (arg[0] == '-') {
            try stdout.interface.print("error: unrecognized argument \"{s}\"\n", .{arg});
            std.process.exit(1);
        } else {
            if (inputName != null) {
                try stdout.interface.print("error: only one input file is supported (found \"{s}\" and \"{s}\")\n", .{inputName.?, arg});
                std.process.exit(1);
            }

            inputName = arg;
        }
    }

    if (inputName == null) {
        try stdout.interface.writeAll("error: no input file.\n");
        std.process.exit(1);
    }

    if (outputName == null) {
        try stdout.interface.writeAll("error: no output file.\n");
        std.process.exit(1);
    }

    if (justPreprocess) {
        var lexer = try T.Tokenizer.init(init.io, init.arena.allocator());
        defer lexer.deinit();

        const outFile = try std.Io.Dir.cwd().createFile(init.io, outputName.?, .{});
        defer outFile.close(init.io);

        const text = lexer.preprocessAll(init.arena.allocator()) catch |err| {
            lexer.showErrorHere(err);
            std.process.exit(1);
        };

        try outFile.writeStreamingAll(init.io, text);
        std.process.exit(0);
    }

    if (!linkObject and outputType == .mdbg) {
        try stdout.interface.writeAll("error: cannot stop before linking (-c) when emitting an mdbg snapshot.  Remove -c or use -t elf.\n");
        std.process.exit(1);
    }

    var assembler: A.Assembly = try A.Assembly.init(allocator);
    defer assembler.deinit();
    try assembler.assembleEntireFile(init.io, inputName.?);

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
        try stdout.interface.print("error: failed to parse assembled object: {s}\n", .{c.elf_status_str(status)});
        std.process.exit(1);
    }

    for (libraries.items, 0..) |libPath, i| {
        const libBlob = try std.Io.Dir.cwd().readFileAlloc(init.io, libPath, init.arena.allocator(), .unlimited);

        status = c.elf_view_parse(&views[i + 1], libBlob.len, libBlob.ptr);
        if (status != c.ELF_SUCCESS) {
            try stdout.interface.print("error: failed to parse library {s}: {s}\n", .{libPath, c.elf_status_str(status)});
            std.process.exit(1);
        }
    }

    var layout: c.ElfLayoutMap = undefined;
    status = c.elf_merge_calculate_layout(&layout, views.ptr, views.len);

    if (status != c.ELF_SUCCESS) {
        try stdout.interface.print("error: linker layout failed: {s}\n", .{c.elf_status_str(status)});
        std.process.exit(1);
    }

    const ram = try allocator.alloc(u8, layout.total_memory_needed);
    status = c.elf_merge(ram.ptr, ram.len, &layout, views.ptr, views.len);

    if (status != c.ELF_SUCCESS) {
        try stdout.interface.print("error: linker merge failed: {s}\n", .{c.elf_status_str(status)});
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
                try stdout.interface.print("error: relocation of section {s} failed: {s}\n", .{&section.name, c.elf_status_str(status)});
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
                try stdout.interface.print("error: final serialization failed: {s}\n", .{c.elf_status_str(status)});
                std.process.exit(1);
            }
            try outFile.writeStreamingAll(init.io, finalBlob);
        },
    }
}

test {
    std.testing.refAllDecls(A);
}
