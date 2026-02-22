const std = @import("std");

const sdk = @import("mcu_sdk");

const Tts = struct {
    entry: sdk.Pci.Entry,
    slot: u8 = 0,

    pub inline fn mmio(this: Tts) *volatile sdk.Tts {
        return @ptrFromInt(this.entry.address);
    }
};

inline fn getTts() ?Tts {
    for (&sdk.pci.status().entries, 0..) |entry, slot| {
        if (entry.ty != .tts) {
            continue;
        }

        return .{
            .entry = entry,
            .slot = @intCast(slot),
        };
    }

    return null;
}

const CHECK_COOLDOWN = 15 * std.time.ns_per_s;

pub fn main() void {
    const tts = getTts() orelse return;

    sdk.arch.Mie.setMtie();

    while (true) {
        if (tts.mmio().isReady()) {
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
