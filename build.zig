const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "strip debug symbols from the binary");

    const exe = b.addExecutable(.{
        .name = "rtm32.asm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .single_threaded = true,
        }),
        .linkage = switch (target.result.os.tag) {
            .macos => .dynamic,
            else => .static,
        },
    });

    exe.link_gc_sections = true;

    const translate_elf = b.addTranslateC(.{
        .root_source_file = b.path("cbits/elf_io.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.requiresLibC(),
    });

    translate_elf.defineCMacro("ELFIO_AVOID_LIBC", "1");

    const elf = translate_elf.createModule();
    const cflags: []const []const u8 = &.{"-Wall", "-Wextra", "-std=c99", "-DELFIO_AVOID_LIBC"};
    elf.strip = strip;
    
    elf.addCSourceFile(.{
        .flags = cflags,
        .file = b.path("cbits/elf_io_platform.c"),
    });

    elf.addCSourceFile(.{
        .flags = cflags,
        .file = b.path("cbits/elf_io.c"),
    });

    exe.root_module.addImport("elf_io", elf);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.stdio = .zig_test;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
