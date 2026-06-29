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

const versionString: []const u8 = ".1";

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

    const main_blob = try assembler.createElfBlob(c.ET_REL, 0);
    defer init.arena.allocator().free(main_blob);

    if (!linkObject) {
        const out_file = try std.Io.Dir.cwd().createFile(init.io, outputName.?, .{});
        defer out_file.close(init.io);
        try out_file.writeStreamingAll(init.io, main_blob);
        std.process.exit(0);
    }

    var views = try allocator.alloc(c.ElfView, libraries.items.len + 1);
    var status = c.elf_view_parse(&views[0], main_blob.len, main_blob.ptr);
    if (status != c.ELF_SUCCESS) {
        try stdout.interface.print("error: failed to parse assembled object: {s}\n", .{c.elf_status_str(status)});
        std.process.exit(1);
    }

    for (libraries.items, 0..) |lib_path, i| {
        const lib_blob = try std.Io.Dir.cwd().readFileAlloc(init.io, lib_path, init.arena.allocator(), .unlimited);
        status = c.elf_view_parse(&views[i + 1], lib_blob.len, lib_blob.ptr);
        if (status != c.ELF_SUCCESS) {
            try stdout.interface.print("error: failed to parse library {s}: {s}\n", .{lib_path, c.elf_status_str(status)});
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

    const text_vaddr = (0 + (layout.text_align - 1)) & ~(layout.text_align - 1);
    const data_vaddr = (text_vaddr + layout.text_size + (layout.data_align - 1)) & ~(layout.data_align - 1);

    for (views) |view| {
        if (view.header.*.e_type != c.ET_REL) continue;

        status = c.elf_view_patch_relocations(&view, ram.ptr, ram.len, ".text", @as(u32, @intCast(text_vaddr)), @as(u32, @intCast(data_vaddr)));
        if (status != c.ELF_SUCCESS) {
            try stdout.interface.print("error: .text relocation failed: {s}\n", .{c.elf_status_str(status)});
            std.process.exit(1);
        }
        
        status = c.elf_view_patch_relocations(&view, ram.ptr, ram.len, ".data", @as(u32, @intCast(text_vaddr)), @as(u32, @intCast(data_vaddr)));
        if (status != c.ELF_SUCCESS) {
            try stdout.interface.print("error: .data relocation failed: {s}\n", .{c.elf_status_str(status)});
            std.process.exit(1);
        }
    }

    const entry_point = views[0].header.*.e_entry + @as(u32, @intCast(text_vaddr));
    const final_sections = [_]c.ElfRawSection{
        .{
            .name = ".text",
            .data = ram.ptr + text_vaddr,
            .size = @as(u32, @intCast(layout.text_size)),
            .type = c.SHT_PROGBITS,
            .flags = c.SHF_ALLOC | c.SHF_EXECINSTR,
            .addralign = @as(u32, @intCast(layout.text_align)),
            .link = 0, .info = 0, .entsize = 0,
        },
        .{
            .name = ".data",
            .data = ram.ptr + data_vaddr,
            .size = @as(u32, @intCast(layout.data_size)),
            .type = c.SHT_PROGBITS,
            .flags = c.SHF_ALLOC | c.SHF_WRITE,
            .addralign = @as(u32, @intCast(layout.data_align)),
            .link = 0, .info = 0, .entsize = 0,
        },
    };

    const final_size = c.elf_writer_calculate_size(&final_sections, final_sections.len);
    const final_blob = try allocator.alloc(u8, final_size);
    
    status = c.elf_writer_serialize(final_blob.ptr, final_blob.len, c.ET_EXEC, entry_point, &final_sections, final_sections.len);
    if (status != c.ELF_SUCCESS) {
        try stdout.interface.print("error: final serialization failed: {s}\n", .{c.elf_status_str(status)});
        std.process.exit(1);
    }

    const out_file = try std.Io.Dir.cwd().createFile(init.io, outputName.?, .{});
    defer out_file.close(init.io);
    try out_file.writeStreamingAll(init.io, final_blob);
}
