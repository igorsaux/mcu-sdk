const std = @import("std");

const sdk = @import("mcu_sdk");

const Tts = sdk.utils.PciDevice(sdk.Tts, .tts);

pub fn main() void {
    const tts = Tts.find() orelse return;

    sdk.arch.Mie.setMeie();
    sdk.rtc.every(13, .seconds);
    sdk.rtc.interrupts().on_interval = true;

    while (true) {
        if (sdk.rtc.lastEvent()) |event| {
            sdk.rtc.ack();

            if (event.ty == .interval and tts.mmio().ready()) {
                sdk.dma.memset(tts.slot, 0, 0, sdk.Tts.BUFFER_SIZE);

                var buffer: [sdk.Tts.BUFFER_SIZE]u8 = undefined;
                var writer: sdk.utils.DmaWriter = .init(tts.slot, sdk.Tts.BUFFER_SIZE, 0, &buffer);

                sdk.utils.DateTime.formatNow(&writer.interface) catch unreachable;
                writer.interface.flush() catch unreachable;

                tts.mmio().say();
            }
        }

        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
