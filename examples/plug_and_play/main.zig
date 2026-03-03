const std = @import("std");

const sdk = @import("mcu_sdk");

const Tts = sdk.utils.PciDevice(sdk.Tts, .tts);

inline fn getTts() Tts {
    sdk.pci.interrupts().* = .{
        .on_connected = true,
    };

    defer sdk.pci.interrupts().* = .{};

    while (true) {
        if (sdk.arch.Mip.getMeip()) {
            const event = sdk.pci.status().last_event;
            sdk.pci.ack();

            if (event.ty == .connected and event.device_type == .tts) {
                const entry = sdk.pci.entry(event.slot).?;

                return .{
                    .entry = entry.*,
                    .slot = event.slot,
                };
            }
        }

        if (Tts.find()) |tts| {
            return tts;
        }

        sdk.arch.wfi();
    }
}

pub fn main() void {
    sdk.arch.Mie.setMeie();

    while (true) {
        const tts = getTts();
        tts.mmio().interrupts().on_ready = true;

        sdk.dma.memset(tts.slot, 0, 0, sdk.Tts.BUFFER_SIZE);
        sdk.dma.write(tts.slot, 0, "Hello, world!");

        sdk.pci.interrupts().* = .{
            .on_disconnected = true,
        };

        print_loop: while (true) {
            if (sdk.arch.Mip.getMeip()) {
                if (sdk.pci.lastEvent()) |event| {
                    sdk.pci.ack();

                    if (event.ty == .disconnected and event.slot == tts.slot) {
                        break :print_loop;
                    }
                } else if (tts.mmio().lastEvent()) |event| {
                    tts.mmio().ack();

                    if (event.ty == .ready) {
                        tts.mmio().say();
                    }
                }
            }

            if (tts.mmio().ready()) {
                tts.mmio().say();
            }

            sdk.arch.wfi();
        }
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
