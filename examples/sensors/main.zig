const std = @import("std");

const sdk = @import("mcu_sdk");

const Tts = sdk.utils.PciDevice(sdk.Tts, .tts);

const CHECK_COOLDOWN = 15 * std.time.ns_per_s;

pub fn main() void {
    const tts = Tts.find() orelse return;

    sdk.arch.Mie.setMtie();

    while (true) {
        if (tts.mmio().ready()) {
            var msg: [sdk.Tts.BUFFER_SIZE]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&msg);

            const sensors = sdk.sensors.*;

            writer.print("Sensors: {}C {}mWh", .{ sensors.temperature, sensors.power_usage }) catch unreachable;

            if (sensors.flags.throttled) {
                writer.print(", throttled", .{}) catch unreachable;
            }

            if (sensors.flags.overheat) {
                writer.print(", warning: overheat!", .{}) catch unreachable;
            }

            writer.writeByte(0) catch unreachable;

            sdk.dma.write(tts.slot, 0, msg[0..writer.end]);
            tts.mmio().say();
        }

        sdk.clint.interruptAfterNs(CHECK_COOLDOWN);
        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
