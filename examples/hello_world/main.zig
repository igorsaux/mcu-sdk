const std = @import("std");

const sdk = @import("mcu_sdk");

const Tts = sdk.utils.PciDevice(sdk.Tts, .tts);

pub fn main() void {
    const tts = Tts.find() orelse return;

    sdk.arch.Mie.setMeie();
    tts.mmio().interrupts().on_ready = true;

    sdk.dma.memset(tts.slot, 0, 0, sdk.Tts.BUFFER_SIZE);
    sdk.dma.write(tts.slot, 0, "Hello, world!");

    while (true) {
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
