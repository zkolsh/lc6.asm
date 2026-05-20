const std = @import("std");
const A = @import("assembler.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var assembler: A.Assembly = try A.Assembly.init(allocator);
    defer assembler.deinit();

    try assembler.assembleEntireFile(init.io, "rsrc/loop.lc6");
    try assembler.writeOut(init.io, "assembly.c");
}
