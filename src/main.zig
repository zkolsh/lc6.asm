const std = @import("std");
const A = @import("assembler.zig");
const c = @import("elf_io");

const helpText: []const u8 =
    \\usage: {s} [options...] <input file> -o <output file>
    \\
    \\options:
    \\  -h, --help          show this message
    \\  -v, --version       show program version
    \\  -o <file>           place the output into <file>
    \\  -l:<file>           link against an additional ELF object/library
    \\  -c                  stop before linking
    \\
    ;

const versionString: []const u8 = "0.2";

pub fn main(init: std.process.Init) !void {
    var stdout = std.Io.File.stdout().writer(init.io, &.{});
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    const exename = args.next();

    var inputName: ?[]const u8 = null;
    var outputName: ?[]const u8 = null;

    const allocator = init.arena.allocator();
    var libraries = try std.ArrayList([]const u8).initCapacity(allocator, 1);

    var linkObject = true;
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

    var assembler: A.Assembly = try A.Assembly.init(allocator);
    defer assembler.deinit();
    try assembler.assembleEntireFile(init.io, inputName.?);
    // assembler.patchStaticRelocations();

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

    const outFile = try std.Io.Dir.cwd().createFile(init.io, outputName.?, .{});
    defer outFile.close(init.io);
    try outFile.writeStreamingAll(init.io, finalBlob);
}
