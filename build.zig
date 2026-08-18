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
        }),
    });

    exe.root_module.strip = strip;
    exe.link_gc_sections = true;

    const translate_elf = b.addTranslateC(.{
        .root_source_file = b.path("cbits/elf_io.h"),
        .target = target,
        .optimize = optimize,
    });

    const elf = translate_elf.createModule();
    elf.link_libc = true;
    elf.strip = strip;

    exe.root_module.addImport("elf_io", elf);
    exe.root_module.addCSourceFile(.{
        .file = b.path("cbits/elf_io.c"),
        .flags = &.{"-Wall", "-Wextra", "-std=c99"},
    });

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
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
