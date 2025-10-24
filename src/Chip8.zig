const std = @import("std");

const Chip8 = @This();

pub const gfx_width = 64;
pub const gfx_height = 32;
const mem_size = std.math.maxInt(Addr);
const program_offset = 512;
const display_size = 256;
const stack_size = 96;
const stack_offset = mem_size - display_size - stack_size;

const c8_font: [80]u8 = .{
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
};

cpu: struct {
    regs: [16]u8 = undefined,
    i: Addr = 0,
    pc: Addr = program_offset,
    sp: Addr = stack_offset,

    const flag: Reg = 0xF;
    const Cpu = @This();
} = .{},

mem: []u8 = undefined,
gfx: []u8 = undefined,
keys: u16 = 0,
cycles: u32 = 0,
delay_timer: u8 = 0,
sound_timer: u8 = 0,
draw: bool = false,
skip: bool = false,
status: enum {
    init,
    halt,
    run,
    @"error",
} = .init,
rand: std.Random.DefaultPrng,

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Chip8 {
    var comp = try allocator.create(Chip8);
    comp.* = .{
        .mem = try allocator.alloc(u8, mem_size),
        .gfx = try allocator.alloc(u8, gfx_width * gfx_height),
        .rand = .init(0x234e234234),
    };

    @memset(comp.mem, 0);
    @memcpy(comp.mem.ptr, &c8_font);
    @memset(comp.gfx, 0);
    @memset(&comp.cpu.regs, 0);

    return comp;
}

pub fn initWithRom(allocator: std.mem.Allocator, rom: []const u8) std.mem.Allocator.Error!*Chip8 {
    var comp = try init(allocator);
    comp.loadRom(rom);
    return comp;
}

pub fn deinit(self: *const Chip8, allocator: std.mem.Allocator) void {
    allocator.free(self.mem);
    allocator.free(self.gfx);
    allocator.destroy(self);
}

pub fn loadRom(self: *const Chip8, rom: []const u8) void {
    std.debug.assert(rom.len <= stack_offset - program_offset);
    @memcpy(self.mem[program_offset..].ptr, rom);
}

fn getKey(self: *const Chip8, key: u8) bool {
    return (self.keys & (@as(u16, 1) << @truncate(key))) > 0;
}

pub fn keyUp(self: *Chip8, key: u4) void {
    self.keys |= @as(u16, 1) << key;
}

pub fn keyDown(self: *Chip8, key: u4) void {
    self.keys &= ~(@as(u16, 1) << key);
}

pub fn decrementTimers(self: *Chip8) void {
    self.delay_timer -|= 1;
    self.sound_timer -|= 1;
}

const Addr = u12;
const Reg2 = packed struct(u8) {
    y: u4,
    x: u4,
};
const Reg = u4;
const RegImm = packed struct(u12) {
    nn: u8,
    x: u4,
};
const SpriteAddr = packed struct(u12) {
    h: u4,
    y: u4,
    x: u4,
};

const OpCode = union(enum) {
    native_call: Addr,
    display_clear: void,
    @"return": void,
    jump: Addr,
    call: Addr,
    if_eq_imm: RegImm,
    if_neq_imm: RegImm,
    if_eq_reg: Reg2,
    mov_imm: RegImm,
    add_imm: RegImm, // no carry
    mov_reg: Reg2,
    or_reg: Reg2,
    and_reg: Reg2,
    xor_reg: Reg2,
    add_reg: Reg2,
    sub_reg: Reg2,
    shr_reg: Reg,
    sub_reg2: Reg2,
    shl_reg: Reg,
    if_neq_reg: Reg2,
    index: Addr,
    jump_add: Addr,
    rand: RegImm,
    draw: SpriteAddr,
    if_eq_key: Reg,
    if_neq_key: Reg,
    delay_get: Reg,
    key_wait: Reg,
    delay_set: Reg,
    sound_set: Reg,
    index_add: Reg,
    sprite_addr: Reg,
    bcd: Reg,
    reg_dump: Reg,
    reg_load: Reg,
    halt: void,
};

pub fn run(self: *Chip8) C8StepError!void {
    if (self.status != .init)
        return C8StepError.InvalidStatus;

    self.status = .run;
    while (self.status == .run) {
        try self.step();
    }
}

const C8StepError = error{
    InvalidAddress,
    InvalidOpcode,
    InvalidStatus,
    UnimplementedOpCode,
    StackOverflow,
    StackUnderflow,
};

pub fn step(self: *Chip8) C8StepError!void {
    errdefer self.status = .@"error";

    const pc = self.cpu.pc;
    const opcode_raw: u16 = @as(u16, self.mem[pc]) << 8 | @as(u16, self.mem[pc + 1]);
    const opcode = try decode(opcode_raw);
    var next_pc: Addr = pc + 2;
    switch (opcode) {
        .native_call => return C8StepError.UnimplementedOpCode,
        .display_clear => {
            @memset(self.gfx, 0);
            self.draw = true;
        },
        .@"return" => {
            std.debug.assert(self.cpu.sp > stack_offset);
            self.cpu.sp -= 2;

            next_pc = @intCast(self.mem[self.cpu.sp]);
            next_pc = (next_pc << 8) | self.mem[self.cpu.sp + 1];
        },
        .jump => |addr| next_pc = addr,
        .jump_add => |addr| next_pc = addr + self.cpu.regs[0],
        .call => |addr| {
            self.mem[self.cpu.sp] = @truncate(next_pc >> 8);
            self.mem[self.cpu.sp + 1] = @truncate(next_pc);
            self.cpu.sp += 2;
            next_pc = addr;
        },

        .if_eq_imm => |op| self.skip = op.nn == self.cpu.regs[op.x],
        .if_neq_imm => |op| self.skip = op.nn != self.cpu.regs[op.x],
        .if_eq_reg => |op| self.skip = self.cpu.regs[op.x] == self.cpu.regs[op.y],
        .if_neq_reg => |op| self.skip = self.cpu.regs[op.x] != self.cpu.regs[op.y],
        .mov_imm => |op| self.cpu.regs[op.x] = op.nn,
        .add_imm => |op| self.cpu.regs[op.x] +%= op.nn,

        .mov_reg => |op| self.cpu.regs[op.x] = self.cpu.regs[op.y],

        .or_reg => |op| self.cpu.regs[op.x] |= self.cpu.regs[op.y],
        .and_reg => |op| self.cpu.regs[op.x] &= self.cpu.regs[op.y],
        .xor_reg => |op| self.cpu.regs[op.x] ^= self.cpu.regs[op.y],

        .add_reg => |op| {
            const vx = self.cpu.regs[op.x];
            const vy = self.cpu.regs[op.y];
            const res, const overflow = @addWithOverflow(vx, vy);
            self.cpu.regs[op.x] = res;
            self.cpu.regs[0xF] = @intCast(overflow);
        },
        .sub_reg => |op| {
            const vx = self.cpu.regs[op.x];
            const vy = self.cpu.regs[op.y];
            const res, const underflow = @subWithOverflow(vx, vy);
            self.cpu.regs[op.x] = res;
            self.cpu.regs[0xF] = @intFromBool(underflow != 0);
        },
        .sub_reg2 => |op| {
            const vx = self.cpu.regs[op.x];
            const vy = self.cpu.regs[op.y];
            const res, const underflow = @subWithOverflow(vy, vx);
            self.cpu.regs[op.x] = res;
            self.cpu.regs[0xF] = @intFromBool(underflow != 0);
        },

        .shr_reg => |reg| {
            const vx = self.cpu.regs[reg];
            self.cpu.regs[0xF] = vx & 0x01;
            self.cpu.regs[reg] = vx >> 1;
        },
        .shl_reg => |reg| {
            const vx = self.cpu.regs[reg];
            self.cpu.regs[0xF] = (vx & 0x80) >> 7;
            self.cpu.regs[reg] = vx << 1;
        },

        .index => |addr| self.cpu.i = addr,
        .rand => |reg| {
            self.cpu.regs[reg.x] = @as(u8, @truncate(self.rand.next())) & reg.nn;
        },
        .draw => |op| {
            self.cpu.regs[0xF] = 0;
            const vx = self.cpu.regs[op.x];
            const vy = self.cpu.regs[op.y];
            for (0..op.h) |y| {
                const pixel = self.mem[self.cpu.i + y];
                for (0..8) |x| {
                    if (pixel & (@as(u8, 0x80) >> @truncate(x)) != 0) {
                        // todo dont think this is right
                        const idx = (vx + x + (y + vy) * 64) % self.gfx.len;
                        if (self.gfx[idx] == 1)
                            self.cpu.regs[0xF] = 1;
                        self.gfx[idx] ^= 1;
                    }
                }
            }
            self.draw = true;
        },
        .if_eq_key => |reg| self.skip = self.getKey(self.cpu.regs[reg]),
        .if_neq_key => |reg| self.skip = !self.getKey(self.cpu.regs[reg]),

        .delay_get => |reg| self.cpu.regs[reg] = self.delay_timer,
        .delay_set => |reg| self.delay_timer = self.cpu.regs[reg],
        .sound_set => |reg| self.sound_timer = self.cpu.regs[reg],
        .sprite_addr => |reg| self.cpu.i = @as(u12, self.cpu.regs[reg]) * 5,
        .index_add => |reg| self.cpu.i +|= self.cpu.regs[reg],

        .key_wait => |reg|{
            var i: u4 = 0;
            const got_key = blk: while (i <= 15) : (i += 1) {
                if ((self.keys & (@as(u16, 1) << i)) > 0) {
                    self.cpu.regs[reg] = i;
                    break :blk true;
                }
            } else false;

            if (!got_key)
                next_pc = pc;
        },
        .bcd => |reg| {
            const x = self.cpu.regs[reg];
            const hundred = x / 100;
            const ten = x / 10;
            const one = x % 10;

            self.mem[self.cpu.i] = hundred;
            self.mem[self.cpu.i + 1] = ten;
            self.mem[self.cpu.i + 2] = one;
        },
        .reg_dump => |to| {
            std.debug.assert(self.cpu.i + to + 1 < self.mem.len);
            var addr = self.cpu.i;
            for (0..to + 1) |reg| {
                self.mem[addr] = self.cpu.regs[reg];
                addr += 1;
            }
        },
        .reg_load => |to| {
            std.debug.assert(self.cpu.i + to + 1 < self.mem.len);
            var addr = self.cpu.i;
            for (0..to + 1) |reg| {
                self.cpu.regs[reg] = self.mem[addr];
                addr += 1;
            }
        },

        .halt => self.status = .halt,
    }

    self.cycles +|= 1;
    self.cpu.pc = next_pc;
}

fn decode(opcode: u16) C8StepError!OpCode {
    const icode: u4 = @intCast(opcode >> 12);
    const ifun: u4 = @truncate(opcode);
    const addr: Addr = @truncate(opcode);
    const vx: u4 = @intCast((opcode & 0x0f00) >> 8);
    const vxy: Reg2 = @bitCast(@as(u8, @truncate((opcode & 0x0ff0) >> 4)));
    const vxnn: RegImm = @bitCast(addr);
    const vi: u8 = @truncate(opcode);

    return switch (icode) {
        0x0 => switch (vi) {
            0xE0 => .display_clear,
            0xEE => .@"return",
            else => OpCode{ .native_call = addr },
        },
        0x1 => OpCode{ .jump = addr },
        0x2 => OpCode{ .call = addr },
        0x3 => OpCode{ .if_eq_imm = vxnn },
        0x4 => OpCode{ .if_neq_imm = vxnn },
        0x5 => OpCode{ .if_eq_reg = vxy },
        0x6 => OpCode{ .mov_imm = vxnn },
        0x7 => OpCode{ .add_imm = vxnn },
        0x8 => switch (ifun) {
            0x0 => OpCode{ .mov_reg = vxy },
            0x1 => OpCode{ .or_reg = vxy },
            0x2 => OpCode{ .and_reg = vxy },
            0x3 => OpCode{ .xor_reg = vxy },
            0x4 => OpCode{ .add_reg = vxy },
            0x5 => OpCode{ .sub_reg = vxy },
            0x6 => OpCode{ .shr_reg = vx },
            0x7 => OpCode{ .sub_reg2 = vxy },
            0xE => OpCode{ .shl_reg = vx },
            else => C8StepError.InvalidOpcode,
        },
        0x9 => OpCode{ .if_neq_reg = vxy },
        0xA => OpCode{ .index = addr },
        0xB => OpCode{ .jump_add = addr },
        0xC => OpCode{ .rand = vxnn },
        0xD => OpCode{ .draw = @bitCast(addr) },
        0xE => switch (vi) {
            0x9E => OpCode{ .if_eq_key = vx },
            0xA1 => OpCode{ .if_neq_key = vx },
            else => C8StepError.InvalidOpcode,
        },
        0xF => switch (vi) {
            0x07 => OpCode{ .delay_get = vx },
            0x0A => OpCode{ .key_wait = vx },
            0x15 => OpCode{ .delay_set = vx },
            0x18 => OpCode{ .sound_set = vx },
            0x1E => OpCode{ .index_add = vx },
            0x29 => OpCode{ .sprite_addr = vx },
            0x33 => OpCode{ .bcd = vx },
            0x55 => OpCode{ .reg_dump = vx },
            0x65 => OpCode{ .reg_load = vx },
            0xff => .halt,
            else => C8StepError.InvalidOpcode,
        },
    };
}

test "opcode_packed_structs" {
    const add = try decode(0x8424);
    switch (add) {
        .add_reg => |regs| {
            try std.testing.expectEqual(4, regs.x);
            try std.testing.expectEqual(2, regs.y);
        },
        else => try std.testing.expect(false),
    }

    const draw = try decode(0xD934);
    switch (draw) {
        .draw => |dinfo| {
            try std.testing.expectEqual(9, dinfo.x);
            try std.testing.expectEqual(3, dinfo.y);
            try std.testing.expectEqual(4, dinfo.h);
        },
        else => try std.testing.expect(false),
    }

    const add_imm = try decode(0x7422);
    switch (add_imm) {
        .add_imm => |ainfo| {
            try std.testing.expectEqual(4, ainfo.x);
            try std.testing.expectEqual(0x22, ainfo.nn);
        },
        else => try std.testing.expect(false),
    }
}

pub fn format(
    self: *Chip8,
    writer: *std.Io.Writer,
) !void {
    try writer.print(
        \\Chip8{{
        \\ status: .{t},
        \\ pc: 0x{x:04},
        \\ cycles: 0x{d:04},
        \\ regs: {any},
        \\}}
    , .{ self.status, self.cpu.pc, self.cycles, self.cpu.regs });
}
