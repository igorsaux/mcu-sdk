const std = @import("std");

const sdk = @import("mcu_sdk");

const Tts = sdk.utils.PciDevice(sdk.Tts, .tts);

pub fn main() void {
    const tts = Tts.find() orelse return;

    sdk.arch.Mie.setMeie();
    sdk.clint.interrupts().on_sync_pulse = true;

    var charge = sdk.power.battery_charge;

    while (true) {
        if (sdk.clint.lastEvent()) |event| {
            sdk.clint.ack();

            if (event.ty == .sync and tts.mmio().ready()) {
                const now_charge = sdk.power.battery_charge;
                const charge_delta = now_charge -| charge;

                sdk.dma.memset(tts.slot, 0, 0, sdk.Tts.BUFFER_SIZE);

                var buffer: [sdk.Tts.BUFFER_SIZE]u8 = undefined;
                var writer: sdk.utils.DmaWriter = .init(tts.slot, sdk.Tts.BUFFER_SIZE, 0, &buffer);
                writer.interface.print("Dlt: {}mWh, Rem: {}mWh", .{ charge_delta, now_charge }) catch unreachable;
                writer.interface.flush() catch unreachable;

                charge = now_charge;

                tts.mmio().say();
            }
        }

        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
