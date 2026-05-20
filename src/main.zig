const std = @import("std");
const A = @import("assembler.zig");

const helpText: []const u8 =
    \\usage: {s} [options...] <input file> -o <output file>
    \\
    \\options:
    \\  -h, --help          show this message
    \\  -v, --version       show program version
    \\  -o <file>           place the output into <file>
    ;

const versionString: []const u8 = ".0";

pub fn main(init: std.process.Init) !void {
    var stdout = std.Io.File.stdout().writer(init.io, &.{});
    var args = init.minimal.args.iterate();
    const exename = args.next();

    var inputName: ?[]const u8 = null;
    var outputName: ?[]const u8 = null;

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

    var assembler: A.Assembly = try A.Assembly.init(init.arena.allocator());
    defer assembler.deinit();

    try assembler.assembleEntireFile(init.io, inputName.?);
    try assembler.writeHeader(init.io, outputName.?);
}
