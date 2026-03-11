const std = @import("std");

const sdk = @import("mcu_sdk");
const RESOLUTION = sdk.Vga.Resolution.hi;

const Vga = sdk.utils.PciDevice(sdk.Vga, .vga);

const BLOCK_SIZE: u16 = 4;
const LETTER_WIDTH: u16 = 5;
const LETTER_HEIGHT: u16 = 7;
const LETTER_SPACING: u16 = 1;

const LETTER_D = [7]u8{
    0b11110,
    0b10001,
    0b10001,
    0b10001,
    0b10001,
    0b10001,
    0b11110,
};

const LETTER_V = [7]u8{
    0b10001,
    0b10001,
    0b10001,
    0b01010,
    0b01010,
    0b00100,
    0b00100,
};

const TEXT = [_]*const [7]u8{ &LETTER_D, &LETTER_V, &LETTER_D };
const TEXT_WIDTH: f32 = (LETTER_WIDTH * 3 + LETTER_SPACING * 2) * BLOCK_SIZE; // 68
const TEXT_HEIGHT: f32 = LETTER_HEIGHT * BLOCK_SIZE; // 28

const COLORS = [_]u8{
    9,
    10,
    11,
    12,
    13,
    14,
    15,
};

var pos_x: f32 = 50.0;
var pos_y: f32 = 50.0;
var vel_x: f32 = 1.8;
var vel_y: f32 = 1.3;
var color_index: usize = 0;

fn drawLetter(vga: *const Vga, letter: *const [7]u8, base_x: u16, base_y: u16, color: u8) void {
    for (0..LETTER_HEIGHT) |row| {
        const bits = letter[row];

        for (0..LETTER_WIDTH) |col| {
            const bit: u3 = @intCast(LETTER_WIDTH - 1 - col);

            if ((bits >> bit) & 1 == 1) {
                const px: u16 = base_x + @as(u16, @intCast(col)) * BLOCK_SIZE;
                const py: u16 = base_y + @as(u16, @intCast(row)) * BLOCK_SIZE;

                vga.mmio().rect(.{
                    .color = color,
                    .pos = .{ .x = px, .y = py },
                    .w = BLOCK_SIZE,
                    .h = BLOCK_SIZE,
                    .origin = .top_left,
                    .mode = .crop,
                });
            }
        }
    }
}

fn drawText(vga: *const Vga, x: u16, y: u16, color: u8) void {
    var offset_x: u16 = 0;

    for (TEXT) |letter| {
        drawLetter(vga, letter, x + offset_x, y, color);
        offset_x += (LETTER_WIDTH + LETTER_SPACING) * BLOCK_SIZE;
    }
}

fn update() void {
    pos_x += vel_x;
    pos_y += vel_y;

    var bounced = false;

    if (pos_x <= 0) {
        pos_x = 0;
        vel_x = -vel_x;
        bounced = true;
    } else if (pos_x + TEXT_WIDTH >= RESOLUTION.width()) {
        pos_x = RESOLUTION.width() - TEXT_WIDTH;
        vel_x = -vel_x;
        bounced = true;
    }

    if (pos_y <= 0) {
        pos_y = 0;
        vel_y = -vel_y;
        bounced = true;
    } else if (pos_y + TEXT_HEIGHT >= RESOLUTION.height()) {
        pos_y = RESOLUTION.height() - TEXT_HEIGHT;
        vel_y = -vel_y;
        bounced = true;
    }

    if (bounced) {
        color_index = (color_index + 1) % COLORS.len;
    }
}

pub fn main() void {
    const vga = Vga.find() orelse return;

    vga.mmio().setResolution(RESOLUTION);

    var palette = sdk.utils.DEFAULT_VGA_PALETTE;
    sdk.dma.write(
        vga.slot,
        sdk.Vga.PAL_ADDRESS,
        std.mem.sliceAsBytes(&palette),
    );

    const random = sdk.Prng.interface();
    pos_x = @floatFromInt(random.intRangeAtMost(u16, 10, 240));
    pos_y = @floatFromInt(random.intRangeAtMost(u16, 10, 160));

    if (random.boolean()) vel_x = -vel_x;
    if (random.boolean()) vel_y = -vel_y;

    sdk.arch.Mie.setMeie();
    vga.mmio().interrupts().on_vblank = true;

    while (true) {
        if (vga.mmio().lastEvent()) |event| {
            if (event.ty == .vblank) {
                vga.mmio().clear(.{ .color = 0 });

                update();

                const x: u16 = @intFromFloat(pos_x);
                const y: u16 = @intFromFloat(pos_y);
                drawText(&vga, x, y, COLORS[color_index]);
            }

            vga.mmio().ack();
        }

        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
