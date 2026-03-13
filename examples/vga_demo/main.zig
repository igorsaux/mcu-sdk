const std = @import("std");

const sdk = @import("mcu_sdk");
const RESOLUTION = sdk.Vga.Resolution.med;

const Vga = sdk.utils.PciDevice(sdk.Vga, .vga);

var sin_table: [256]u8 = undefined;

fn initSinTable() void {
    for (0..256) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * (std.math.pi * 2.0 / 256.0);
        const s = @sin(angle);
        sin_table[i] = @intFromFloat((s + 1.0) * 127.5);
    }
}

inline fn fastSin(x: u32) u8 {
    return sin_table[@as(u8, @truncate(x))];
}

fn initPalette() [sdk.Vga.PAL_LEN]sdk.Rgb {
    var pal: [sdk.Vga.PAL_LEN]sdk.Rgb = undefined;

    for (0..256) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 256.0;

        const r: f32 = @sin(t * std.math.pi * 2.0) * 127.0 + 128.0;
        const g: f32 = @sin(t * std.math.pi * 2.0 + 2.094) * 127.0 + 128.0; // +2π/3
        const b: f32 = @sin(t * std.math.pi * 2.0 + 4.189) * 127.0 + 128.0; // +4π/3

        pal[i] = .{
            .r = @intFromFloat(@max(0, @min(255, r))),
            .g = @intFromFloat(@max(0, @min(255, g))),
            .b = @intFromFloat(@max(0, @min(255, b))),
        };
    }

    return pal;
}

const Ball = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    radius: u16,
    color_base: u8,
};

var balls: [5]Ball = undefined;

fn initBalls() void {
    const random = sdk.Prng.interface();

    for (&balls, 0..) |*ball, i| {
        ball.* = .{
            .x = @floatFromInt(random.intRangeAtMost(u16, 50, 270)),
            .y = @floatFromInt(random.intRangeAtMost(u16, 30, 170)),
            .vx = (@as(f32, @floatFromInt(random.intRangeAtMost(u8, 0, 200))) - 100.0) / 50.0,
            .vy = (@as(f32, @floatFromInt(random.intRangeAtMost(u8, 0, 200))) - 100.0) / 50.0,
            .radius = @intCast(15 + i * 5),
            .color_base = @intCast(i * 50),
        };
    }
}

fn updateBalls() void {
    for (&balls) |*ball| {
        ball.x += ball.vx;
        ball.y += ball.vy;

        const r: f32 = @floatFromInt(ball.radius);

        if (ball.x - r < 0) {
            ball.x = r;
            ball.vx = -ball.vx;
        }
        if (ball.x + r >= @as(f32, RESOLUTION.width())) {
            ball.x = @as(f32, RESOLUTION.width()) - r - 1;
            ball.vx = -ball.vx;
        }
        if (ball.y - r < 0) {
            ball.y = r;
            ball.vy = -ball.vy;
        }
        if (ball.y + r >= @as(f32, RESOLUTION.height())) {
            ball.y = @as(f32, RESOLUTION.height()) - r - 1;
            ball.vy = -ball.vy;
        }
    }
}

fn drawPlasmaBackground(vga: *const Vga, frame: u32) void {
    const stripe_height: u16 = 8;
    var y: u16 = 0;

    while (y < RESOLUTION.height()) : (y += stripe_height) {
        const wave1 = fastSin(y *% 3 +% frame);
        const wave2 = fastSin(y *% 5 +% frame *% 2);
        const color: u8 = @truncate((wave1 +% wave2) / 2);

        vga.mmio().rect(.{
            .color = color,
            .pos = .{ .x = 0, .y = y },
            .w = @intCast(RESOLUTION.width()),
            .h = stripe_height,
            .origin = .top_left,
            .mode = .crop,
        });
    }
}

fn drawBalls(vga: *const Vga, frame: u32) void {
    for (balls) |ball| {
        const color: u8 = ball.color_base +% @as(u8, @truncate(frame *% 2));

        vga.mmio().circle(.{
            .color = color,
            .pos = .{
                .x = @intFromFloat(ball.x),
                .y = @intFromFloat(ball.y),
            },
            .r = ball.radius,
            .origin = .center,
            .mode = .crop,
        });
    }
}

fn drawRotatingRects(vga: *const Vga, frame: u32) void {
    const cx: i32 = RESOLUTION.width() / 2;
    const cy: i32 = RESOLUTION.height() / 2;

    for (0..4) |i| {
        const angle_offset: u32 = @intCast(i * 64); // 90°
        const angle: u32 = frame *% 3 +% angle_offset;

        const sin_val: i32 = @as(i32, fastSin(angle)) - 128;
        const cos_val: i32 = @as(i32, fastSin(angle +% 64)) - 128;

        const dist: i32 = 60;
        const px: i32 = cx + @divTrunc(cos_val * dist, 128);
        const py: i32 = cy + @divTrunc(sin_val * dist, 128);

        const color: u8 = @truncate(200 + i * 10 + frame);

        vga.mmio().rect(.{
            .color = color,
            .pos = .{
                .x = @intCast(@max(0, @min(RESOLUTION.width() - 1, px))),
                .y = @intCast(@max(0, @min(RESOLUTION.height() - 1, py))),
            },
            .w = 20,
            .h = 20,
            .origin = .center,
            .mode = .crop,
        });
    }
}

fn drawCenterPulse(vga: *const Vga, frame: u32) void {
    const base_r: u32 = 30;
    const pulse: u32 = fastSin(frame *% 8);
    const radius: u16 = @intCast(base_r + pulse / 10);

    vga.mmio().circle(.{
        .color = @truncate(frame *% 4),
        .pos = .{ .x = @intCast(RESOLUTION.width() / 2), .y = @intCast(RESOLUTION.height() / 2) },
        .r = radius,
        .origin = .center,
        .mode = .crop,
    });
}

pub fn main() void {
    const vga = Vga.find() orelse return;

    vga.mmio().setResolution(RESOLUTION);

    initSinTable();
    initBalls();

    var palette = initPalette();
    sdk.dma.write(
        vga.slot,
        sdk.Vga.PAL_ADDRESS,
        std.mem.sliceAsBytes(&palette),
    );

    sdk.arch.Mie.setMeie();
    vga.mmio().interrupts().on_vblank = true;

    var frame: u32 = 0;

    while (true) {
        if (vga.mmio().lastEvent()) |event| {
            if (event.ty == .vblank) {
                updateBalls();

                drawPlasmaBackground(&vga, frame);
                drawBalls(&vga, frame);
                drawRotatingRects(&vga, frame);
                drawCenterPulse(&vga, frame);

                frame +%= 1;
            }

            vga.mmio().ack();
        }

        sdk.arch.wfi();
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
