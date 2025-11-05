const sdl = @import("sdl");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_tui = b.option(bool, "tui", "build a tui instead") orelse false;

    var exe: *std.Build.Step.Compile = undefined;
    if (build_tui) {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/tui.zig"),
            .target = target,
            .optimize = optimize,
        });

        const vaxis = b.dependency("vaxis", .{
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("vaxis", vaxis.module("vaxis"));

        exe = b.addExecutable(.{
            .name = "c8-tui",
            .root_module = exe_mod,
        });
    } else {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/gui.zig"),
            .target = target,
            .optimize = optimize,
        });

        const sdk = sdl.init(b, .{});
        exe = b.addExecutable(.{
            .name = "c8",
            .root_module = exe_mod,
        });

        sdk.link(exe, .dynamic, sdl.Library.SDL2);
        exe_mod.addImport("sdl2", sdk.getWrapperModule());
    }

    b.installArtifact(exe);
}
