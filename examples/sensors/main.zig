const std = @import("std");

const sdk = @import("mcu_sdk");

const Tts = sdk.utils.PciDevice(sdk.Tts, .tts);

const CHECK_COOLDOWN = 15 * std.time.ns_per_s;

pub fn main() void {
    const tts = Tts.find() orelse return;

    sdk.arch.Mie.setMtie();

    while (true) {
        if (tts.mmio().ready()) {
            sdk.dma.memset(tts.slot, 0, 0, sdk.Tts.BUFFER_SIZE);

            var buffer: [sdk.Tts.BUFFER_SIZE]u8 = undefined;
            var writer: sdk.utils.DmaWriter = .init(tts.slot, sdk.Tts.BUFFER_SIZE, 0, &buffer);

            const sensors = sdk.sensors.*;

            writer.interface.print("Sensors: {}C", .{sensors.temperature}) catch unreachable;

            if (sensors.flags.throttled) {
                writer.interface.print(", throttled", .{}) catch unreachable;
            }

            if (sensors.flags.overheat) {
                writer.interface.print(", warning: overheat!", .{}) catch unreachable;
            }

            writer.interface.flush() catch unreachable;

            tts.mmio().say();
        }

        sdk.clint.interruptAfterNs(CHECK_COOLDOWN);
        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
