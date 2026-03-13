const std = @import("std");

const sdk = @import("mcu_sdk");
const RESOLUTION = sdk.Vga.Resolution.med;

const Vga = sdk.utils.PciDevice(sdk.Vga, .vga);

const COLS = 16;
const ROWS = 16;
const BLOCK_W = RESOLUTION.width() / COLS; // 20
const BLOCK_H = RESOLUTION.height() / ROWS; // 12

pub fn main() void {
    const vga = Vga.find() orelse return;

    vga.mmio().setResolution(RESOLUTION);

    var palette = sdk.utils.DEFAULT_VGA_PALETTE;
    sdk.dma.write(
        vga.slot,
        sdk.Vga.PAL_ADDRESS,
        std.mem.sliceAsBytes(&palette),
    );

    var line: [RESOLUTION.width()]u8 = undefined;
    var prev_block_row: u32 = 0xFFFF;

    for (0..RESOLUTION.height()) |y| {
        const block_row: u32 = @intCast(y / BLOCK_H);

        if (block_row != prev_block_row) {
            prev_block_row = block_row;

            if (block_row < ROWS) {
                for (0..COLS) |col| {
                    const color: u8 = @intCast(block_row * COLS + col);
                    @memset(line[col * BLOCK_W ..][0..BLOCK_W], color);
                }
            } else {
                @memset(&line, 0);
            }
        }

        sdk.dma.write(
            vga.slot,
            @intCast(sdk.Vga.FB_ADDRESS + y * RESOLUTION.width()),
            &line,
        );
    }

    sdk.arch.Mie.setMeie();
    vga.mmio().interrupts().on_vblank = true;

    while (true) {
        if (vga.mmio().lastEvent()) |_| {
            vga.mmio().ack();
        }
        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
