const std = @import("std");

const sdk = @import("mcu_sdk");

const Tts = sdk.utils.PciDevice(sdk.Tts, .tts);
const Gps = sdk.utils.PciDevice(sdk.Gps, .gps);

pub fn main() void {
    const tts = Tts.find() orelse return;
    const gps = Gps.find() orelse return;

    sdk.arch.Mie.setMeie();
    tts.mmio().interrupts().on_ready = true;

    while (true) {
        sdk.dma.memset(tts.slot, 0, 0, sdk.Tts.BUFFER_SIZE);

        var buffer: [128]u8 = undefined;
        var writer: sdk.utils.DmaWriter = .init(tts.slot, sdk.Tts.BUFFER_SIZE, 0, &buffer);

        const xyz = gps.mmio().status().*;
        writer.interface.print("x: {}, y: {}, z: {}", .{ xyz.x, xyz.y, xyz.z }) catch unreachable;
        writer.interface.flush() catch unreachable;

        if (tts.mmio().lastEvent()) |event| {
            tts.mmio().ack();

            if (event.ty == .ready) {
                tts.mmio().say();
            }
        } else if (tts.mmio().ready()) {
            tts.mmio().say();
        }

        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
