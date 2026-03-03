const std = @import("std");

const sdk = @import("mcu_sdk");

const Tts = sdk.utils.PciDevice(sdk.Tts, .tts);

pub fn main() void {
    const tts = Tts.find() orelse return;

    sdk.arch.Mie.setMeie();
    sdk.clint.interrupts().sync_pulse = true;

    sdk.dma.memset(tts.slot, 0, 0, sdk.Tts.BUFFER_SIZE);
    sdk.dma.write(tts.slot, 0, "Sync pulse");

    while (true) {
        if (sdk.clint.lastEvent()) |event| {
            sdk.clint.ack();

            if (event.ty == .sync and tts.mmio().ready()) {
                tts.mmio().say();
            }
        }

        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
