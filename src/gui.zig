const usage =
    \\Usage:
    \\  c8 [options] rom_file
    \\
    \\Options:
    \\--fg=<string>               RGB color for foreground (#ffffff)
    \\--bg=<string>               RGB color for background (#000000)
    \\--tickrate=<number>         How many emulator steps to run per tick (32)
    \\
;

const Options = struct {
    rom_file: []const u8, // argv[1]
    fg_color: SDL.Color, // --fg
    bg_color: SDL.Color, // --bg
    tickrate: u32, // --tickrate

    fn deinit(self: *const Options, gpa: std.mem.Allocator) void {
        gpa.free(self.rom_file);
    }
};

fn parseArgs(gpa: std.mem.Allocator) !Options {
    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    var rom_file: ?[]const u8 = null;
    var fg_color: SDL.Color = SDL.Color.parse("ffffff") catch unreachable;
    var bg_color: SDL.Color = SDL.Color.parse("000000") catch unreachable;
    var tickrate: u16 = 32;

    while (args.next()) |arg| {
        if (eql(arg, "-h") or eql(arg, "--help")) {
            var w = std.fs.File.stderr().writer(&.{});
            w.interface.writeAll(usage) catch {};
            std.process.exit(0);
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            var split = std.mem.splitScalar(u8, arg[2..], '=');
            const option = split.first();
            const value = split.rest();

            if (eql(option, "fg")) {
                const color = SDL.Color.parse(value) catch {
                    std.debug.print("unable to parse {s} = '{s}' as SDL color defaulting to '{s}'\n", .{ "fg", value, "ffffff" });
                    continue;
                };
                fg_color = color;
            } else if (eql(option, "bg")) {
                const color = SDL.Color.parse(value) catch {
                    std.debug.print("unable to parse {s} = '{s}' as SDL color defaulting to '{s}'\n", .{ "bg", value, "000000" });
                    continue;
                };
                bg_color = color;
            } else if (eql(option, "tickrate")) {
                const given_tickrate = std.fmt.parseInt(u16, value, 10) catch |err| {
                    std.debug.print("{t}: unable to parse u16 from '{s}', defaulting to 32\n", .{ err, value });
                    continue;
                };

                tickrate = given_tickrate;
            }
        } else {
            rom_file = try gpa.dupe(u8, arg);
        }
    }

    return .{
        .rom_file = rom_file orelse return error.MissingRomFile,
        .fg_color = fg_color,
        .bg_color = bg_color,
        .tickrate = tickrate,
    };
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const opts = try parseArgs(gpa);
    defer opts.deinit(gpa);

    const rom = try std.fs.cwd().readFileAlloc(gpa, opts.rom_file, 1 << 16);
    defer gpa.free(rom);
    var comp: *Chip8 = try .initWithRom(gpa, rom);
    defer comp.deinit(gpa);

    try SDL.init(.{
        .video = true,
        .events = true,
        .audio = true,
    });
    defer SDL.quit();

    const win_width = 1024;
    const win_height = 512;

    var window = try SDL.createWindow(
        "chip8",
        .{ .centered = {} },
        .{ .centered = {} },
        win_width,
        win_height,
        .{ .vis = .shown },
    );
    defer window.destroy();

    var renderer = try SDL.createRenderer(window, null, .{ .accelerated = true });
    defer renderer.destroy();

    const tex_h = win_height / 32;
    const tex_w = win_width / 64;
    var render_rect = SDL.Rectangle{ .width = tex_w, .height = tex_h };

    var paused = false;
    comp.status = .run;
    var prev_time: i64 = 0;
    mainLoop: while (comp.status == .run) {
        while (SDL.pollEvent()) |ev| {
            switch (ev) {
                .quit => break :mainLoop,
                .key_down, .key_up => |key| {
                    switch (key.scancode) {
                        .escape => break :mainLoop,
                        .p => {
                            if (key.key_state == .released) {
                                paused = !paused;
                                std.log.info("TOGGLE PAUSE", .{});
                            }
                        },
                        .i => {
                            if (key.key_state == .released)
                                std.log.info("{f}", .{comp});
                        },
                        .u => {
                            if (key.key_state == .released and !key.is_repeat) {
                                comp.reset(rom);
                                std.log.info("reset", .{});
                            }
                        },
                        else => {
                            if (!key.is_repeat) {
                                handle_key(comp, key);
                            }
                        },
                    }
                },
                else => {},
            }
        }

        if (!paused) {
            for (0..opts.tickrate) |_| {
                const current_time = std.time.milliTimestamp();
                if (comp.draw) break;

                try comp.step();
                if (current_time - prev_time >= Chip8.clock_rate_ms) {
                    comp.decrementTimers();
                    prev_time = current_time;
                }
            }

            if (comp.draw) {
                for (0..comp.gfx.len) |i| {
                    render_rect.y = @intCast((i / 64) * tex_h);
                    render_rect.x = @intCast((i % 64) * tex_w);
                    try renderer.setColor(if (comp.gfx[i] == 1) opts.fg_color else opts.bg_color);
                    try renderer.fillRect(render_rect);
                }

                comp.draw = false;
                renderer.present();
            }
        }

        std.Thread.sleep(std.time.ns_per_s / 60);
    }
}

fn handle_key(comp: *Chip8, key: SDL.KeyboardEvent) void {
    const keyidx: u4 = switch (key.scancode) {
        .@"1" => 0x1,
        .@"2" => 0x2,
        .@"3" => 0x3,
        .@"4" => 0xc,

        .q => 0x4,
        .w => 0x5,
        .e => 0x6,
        .r => 0xd,

        .a => 0x7,
        .s => 0x8,
        .d => 0x9,
        .f => 0xe,

        .z => 0xa,
        .x => 0x0,
        .c => 0xb,
        .v => 0xf,
        else => return,
    };

    if (key.key_state == .pressed) {
        comp.keyDown(keyidx);
    } else {
        comp.keyUp(keyidx);
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const std = @import("std");
const SDL = @import("sdl2");
const builtin = @import("builtin");
const Chip8 = @import("Chip8.zig");
