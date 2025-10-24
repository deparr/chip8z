const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_gui = b.option(bool, "gui", "build gui instead of tui") orelse false;
    const check_only = b.option(bool, "check", "check only") orelse false;

    var exe: *std.Build.Step.Compile = undefined;
    if (build_gui) {
        exe = b.addExecutable(.{
            .name = "c8",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gui.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        if (target.result.os.tag == .windows and target.result.abi == .msvc) {
            // Work around a problematic definition in wchar.h in Windows SDK version 10.0.26100.0
            exe.root_module.addCMacro("_Avx2WmemEnabledWeakValue", "_Avx2WmemEnabled");
        }

        const sdl_dep = b.dependency("sdl", .{
            .target = target,
            .optimize = optimize,
        });
        const sdl_lib = sdl_dep.artifact("SDL3");
        exe.root_module.linkLibrary(sdl_lib);

    } else {
        exe = b.addExecutable(.{
            .name = "c8_tui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tui.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        const vaxis = b.dependency("vaxis", .{
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("vaxis", vaxis.module("vaxis"));
    }

    if (check_only) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }
}
