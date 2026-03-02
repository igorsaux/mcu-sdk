const std = @import("std");

const sdk = @import("mcu_sdk");

const Light = sdk.utils.PciDevice(sdk.Light, .light);

var r: u8 = 0;
var g: u8 = 0;
var b: u8 = 0;

const Component = enum { r, g, b };
var color: Component = .r;
var color_going_up: bool = true;

var brightness: u8 = 1;
var brightness_going_up: bool = true;

pub fn main() void {
    const light = Light.find() orelse return;

    sdk.arch.Mie.setMeie();
    light.mmio().interrupts().on_ready = true;

    while (true) {
        if (light.mmio().lastEvent()) |event| {
            light.mmio().ack();

            if (event.ty == .ready) {
                stepColor();
                light.mmio().set(.{ .r = r, .g = g, .b = b }, brightness);
            }
        } else if (light.mmio().ready()) {
            stepColor();
            light.mmio().set(.{ .r = r, .g = g, .b = b }, brightness);
        }

        sdk.arch.wfi();
    }
}

fn stepColor() void {
    const clr: *u8 = switch (color) {
        .r => &r,
        .g => &g,
        .b => &b,
    };

    if (color_going_up) {
        if (clr.* == 255) {
            color_going_up = false;
        } else {
            clr.* +|= 51;
        }
    } else {
        if (clr.* == 0) {
            color_going_up = true;
            color = switch (color) {
                .r => .g,
                .g => .b,
                .b => .r,
            };
        } else {
            clr.* -|= 51;
        }
    }

    if (brightness_going_up) {
        brightness +|= 1;
    } else {
        brightness -|= 1;
    }

    brightness = std.math.clamp(brightness, 1, 3);
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
