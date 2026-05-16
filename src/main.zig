const std = @import("std");
const A = @import("assembler.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var assembler: A.Assembly = try A.Assembly.init(allocator);
    defer assembler.deinit();

    try assembler.assembleEntireFile("rsrc/hola.lc6");
    try assembler.writeOut("assembly.c");
}
