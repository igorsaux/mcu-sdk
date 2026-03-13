const std = @import("std");

const sdk = @import("mcu_sdk");
const RESOLUTION = sdk.Vga.Resolution.low;

const Vga = sdk.utils.PciDevice(sdk.Vga, .vga);

const WIDTH: i16 = @intCast(RESOLUTION.width());
const HEIGHT: i16 = @intCast(RESOLUTION.height());

const PLAYER_SIZE: u16 = 16;
const CURSOR_ARM: u16 = 5;
const SPEED_NORMAL: i16 = 2;
const SPEED_FAST: i16 = 6;
const DOT_RADIUS: u16 = 3;
const MAX_DOTS: usize = 512;

// Palette indices
const C_BG: u8 = 0;
const C_PLAYER: u8 = 1;
const C_PLAYER_FAST: u8 = 2;
const C_CURSOR: u8 = 3;
const C_DOT: u8 = 4;
const C_IND_LEFT: u8 = 5;
const C_IND_RIGHT: u8 = 6;
const C_IND_MID: u8 = 7;

const Dot = struct { x: u16, y: u16 };

var player_x: i16 = @divTrunc(WIDTH, 2) - @as(i16, PLAYER_SIZE / 2);
var player_y: i16 = @divTrunc(HEIGHT, 2) - @as(i16, PLAYER_SIZE / 2);
var cursor_x: i16 = @divTrunc(WIDTH, 2);
var cursor_y: i16 = @divTrunc(HEIGHT, 2);

var dots: [MAX_DOTS]Dot = undefined;
var dot_count: usize = 0;
var shift_held: bool = false;

inline fn clamp(val: i16, lo: i16, hi: i16) i16 {
    return @max(lo, @min(hi, val));
}

fn handleInput(vga: *const Vga) void {
    // Drain keyboard events (state-based input used below)
    while (vga.mmio().headKeyboardEvent()) |_| {
        vga.mmio().keyboardAck();
    }

    // Process mouse events for deltas and clicks
    while (vga.mmio().headMouseEvent()) |event| {
        switch (event.ty) {
            .move => {
                cursor_x = clamp(cursor_x +| event.dx, 0, WIDTH - 1);
                cursor_y = clamp(cursor_y +| event.dy, 0, HEIGHT - 1);
            },
            .press => {
                if (event.button == .left and dot_count < MAX_DOTS) {
                    dots[dot_count] = .{
                        .x = @intCast(cursor_x),
                        .y = @intCast(cursor_y),
                    };
                    dot_count += 1;
                } else if (event.button == .right) {
                    dot_count = 0; // clear canvas
                }
            },
            else => {},
        }

        vga.mmio().mouseAck();
    }

    // Read keyboard state via DMA
    var keys: [sdk.Vga.KEYBOARD_LEN]sdk.Vga.KeyState = undefined;
    sdk.dma.read(
        vga.slot,
        sdk.Vga.KEYBOARD_ADDRESS,
        std.mem.sliceAsBytes(&keys),
    );

    shift_held = keys[sdk.Vga.Scancode.left_shift.toIdx()] or
        keys[sdk.Vga.Scancode.right_shift.toIdx()];

    const speed: i16 = if (shift_held) SPEED_FAST else SPEED_NORMAL;

    if (keys[sdk.Vga.Scancode.w.toIdx()] or keys[sdk.Vga.Scancode.up.toIdx()])
        player_y -= speed;
    if (keys[sdk.Vga.Scancode.s.toIdx()] or keys[sdk.Vga.Scancode.down.toIdx()])
        player_y += speed;
    if (keys[sdk.Vga.Scancode.a.toIdx()] or keys[sdk.Vga.Scancode.left.toIdx()])
        player_x -= speed;
    if (keys[sdk.Vga.Scancode.d.toIdx()] or keys[sdk.Vga.Scancode.right.toIdx()])
        player_x += speed;

    player_x = clamp(player_x, 0, WIDTH - @as(i16, PLAYER_SIZE));
    player_y = clamp(player_y, 0, HEIGHT - @as(i16, PLAYER_SIZE));
}

fn draw(vga: *const Vga) void {
    vga.mmio().clear(.{ .color = C_BG });

    // Dots (left-click paint)
    for (dots[0..dot_count]) |dot| {
        vga.mmio().circle(.{
            .color = C_DOT,
            .pos = .{ .x = dot.x, .y = dot.y },
            .r = DOT_RADIUS,
            .origin = .center,
            .mode = .crop,
        });
    }

    // Player square (green / yellow when Shift)
    vga.mmio().rect(.{
        .color = if (shift_held) C_PLAYER_FAST else C_PLAYER,
        .pos = .{
            .x = @intCast(player_x),
            .y = @intCast(player_y),
        },
        .w = PLAYER_SIZE,
        .h = PLAYER_SIZE,
        .origin = .top_left,
        .mode = .crop,
    });

    // Mouse button indicators (top-left corner)
    const ms = vga.mmio().mouseState().*;

    if (ms.left) {
        vga.mmio().circle(.{
            .color = C_IND_LEFT,
            .pos = .{ .x = 8, .y = 8 },
            .r = 4,
            .origin = .center,
            .mode = .crop,
        });
    }

    if (ms.middle) {
        vga.mmio().circle(.{
            .color = C_IND_MID,
            .pos = .{ .x = 20, .y = 8 },
            .r = 4,
            .origin = .center,
            .mode = .crop,
        });
    }

    if (ms.right) {
        vga.mmio().circle(.{
            .color = C_IND_RIGHT,
            .pos = .{ .x = 32, .y = 8 },
            .r = 4,
            .origin = .center,
            .mode = .crop,
        });
    }

    // Cursor crosshair
    vga.mmio().rect(.{
        .color = C_CURSOR,
        .pos = .{ .x = @intCast(cursor_x), .y = @intCast(cursor_y) },
        .w = CURSOR_ARM * 2 + 1,
        .h = 1,
        .origin = .center,
        .mode = .crop,
    });
    vga.mmio().rect(.{
        .color = C_CURSOR,
        .pos = .{ .x = @intCast(cursor_x), .y = @intCast(cursor_y) },
        .w = 1,
        .h = CURSOR_ARM * 2 + 1,
        .origin = .center,
        .mode = .crop,
    });
}

pub fn main() void {
    const vga = Vga.find() orelse return;

    vga.mmio().setResolution(RESOLUTION);

    // Palette
    var palette: [sdk.Vga.PAL_LEN]sdk.Rgb = undefined;
    @memset(palette[0..], .{});

    palette[C_BG] = .{ .r = 20, .g = 20, .b = 30 };
    palette[C_PLAYER] = .{ .r = 80, .g = 200, .b = 80 };
    palette[C_PLAYER_FAST] = .{ .r = 230, .g = 220, .b = 60 };
    palette[C_CURSOR] = .{ .r = 255, .g = 255, .b = 255 };
    palette[C_DOT] = .{ .r = 255, .g = 120, .b = 100 };
    palette[C_IND_LEFT] = .{ .r = 255, .g = 50, .b = 50 };
    palette[C_IND_RIGHT] = .{ .r = 50, .g = 100, .b = 255 };
    palette[C_IND_MID] = .{ .r = 50, .g = 220, .b = 50 };

    sdk.dma.write(
        vga.slot,
        sdk.Vga.PAL_ADDRESS,
        std.mem.sliceAsBytes(&palette),
    );

    // Only vblank interrupt — keyboard/mouse events drained each frame
    sdk.arch.Mie.setMeie();
    vga.mmio().interrupts().on_vblank = true;

    while (true) {
        handleInput(&vga);

        if (vga.mmio().lastEvent()) |event| {
            if (event.ty == .vblank) {
                draw(&vga);
            }

            vga.mmio().ack();
        }

        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{
        .stack_size = std.math.pow(u32, 2, 14),
    });
}
