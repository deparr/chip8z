const std = @import("std");
const Chip8 = @import("./Chip8.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Model = struct {
    comp: *Chip8,

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {},
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches(key.escape, .{})) {
                    ctx.quit = true;
                    return;
                }
            },
            else => {}
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();
        return .{
            .widget = self.widget(),
            .size = max_size,
            .buffer = &.{},
            .children = &.{},
        };
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const comp = try Chip8.init(allocator);
    defer comp.deinit(allocator);

    var rom_buf: [4096]u8 = undefined;
    const rom_file = try std.fs.cwd().openFile("roms/pong2.c8", .{});
    const rom_len = try rom_file.readAll(&rom_buf);
    rom_file.close();
    comp.loadRom(rom_buf[0..rom_len]);

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    const model = try allocator.create(Model);
    defer allocator.destroy(model);
    model.* = .{
        .comp = comp,
    };

    try app.run(model.widget(), .{});

    // comp.status = .run;
    // std.debug.print("{}\n", .{comp});
    // while (comp.status == .run) {
    //     try comp.step();
    //
    //     if (comp.draw)
    //         debug_draw(comp.gfx);
    //
    //     std.Thread.sleep(1_000_000_000 / 60);
    // }
    // std.debug.print("{}\n", .{comp});
}

fn debug_draw(gfx: []u8) void {
    for (0..Chip8.gfx_height) |y| {
        for (0..Chip8.gfx_width) |x| {
            const pix = if (gfx[y * Chip8.gfx_width + x] > 0) "⬜" else "⬛";
            std.debug.print("{s}", .{pix});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("\n", .{});
}
