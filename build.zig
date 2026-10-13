const std = @import("std");
const Translator = @import("translate_c").Translator;

const cflags: []const []const u8 = &.{"-Wall", "-Wextra", "-std=c99"};

fn getProgramVersion(gpa: std.mem.Allocator) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const build_zig_zon = @embedFile("build.zig.zon");

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const build_zig = try std.zon.parse.fromSlice(struct {version: []const u8}, .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .source = build_zig_zon,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });

    return build_zig.version;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "strip debug symbols from the binary");

    const options = b.addOptions();

    const exe = b.addExecutable(.{
        .name = "rtm32.asm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = false,
            .error_tracing = true,
            .sanitize_c = .full,
        }),
        .linkage = switch (target.result.os.tag) {
            .macos => .dynamic,
            else => .static,
        },
    });

    exe.link_gc_sections = true;

    const version = try getProgramVersion(b.allocator);
    options.addOption([]const u8, "version", version);
    exe.root_module.addImport("build_options", options.createModule());

    const translate_elf = b.dependency("translate_c", .{});
    const trans: Translator = .init(translate_elf, .{
        .c_source_file = b.path("cbits/elf_io.c"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .default_init = true,
    });

    trans.defineCMacro("ELFIO_AVOID_LIBC", "");
    exe.root_module.addImport("elf_io", trans.mod);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.stdio = .zig_test;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    b.installArtifact(exe_tests);

    const docs_step = b.step("docs", "Generate project documentation");
    const install_docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&install_docs.step);

    const lldb = b.addSystemCommand(&.{"lldb", "--"});
    lldb.addArtifactArg(exe_tests);

    const lldb_step = b.step("debug", "Run tests under lldb");
    lldb_step.dependOn(&lldb.step);
}
