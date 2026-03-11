// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");

const sdk = @import("root.zig");

pub inline fn EntryPoint(comptime config: struct {
    stack_size: u32 = if (builtin.mode == .Debug) std.math.pow(u32, 2, 14) else std.math.pow(u32, 2, 10),
    enable_fpu: bool = true,
}) type {
    return struct {
        const root = @import("root");

        var stack: [config.stack_size]u8 align(16) linksection(".bss") = undefined;

        export fn _start() callconv(.naked) noreturn {
            asm volatile (
                \\ .option push
                \\ .option norelax
                \\
                \\ la sp, %[stack_top]
                \\
                \\ j %[init]
                \\
                \\ .option pop
                :
                : [stack_top] "i" (&@as([*]align(16) u8, @ptrCast(&stack))[stack.len]),
                  [init] "i" (&init),
            );
        }

        fn init() callconv(.c) noreturn {
            if (comptime config.enable_fpu) {
                sdk.arch.Mstatus.enableFpu();
            }

            const ReturnType = @typeInfo(@TypeOf(root.main)).@"fn".return_type.?;

            switch (ReturnType) {
                void, noreturn => {
                    @call(.never_inline, root.main, .{});
                },
                else => {
                    if (@typeInfo(ReturnType) != .error_union) {
                        @compileError("expected return type of main to be 'void', '!void' or 'noreturn'");
                    }

                    _ = @call(.never_inline, root.main, .{}) catch |err| {
                        sdk.uart.print("The main function failed with an error: {s}\n", .{@errorName(err)});
                    };
                },
            }

            while (true) {
                sdk.arch.Mie.clearMeie();
                sdk.arch.Mie.clearMtie();
                sdk.arch.Mie.clearMsie();
                sdk.arch.Mip.clearMsip();

                sdk.arch.wfi();
            }
        }
    };
}

pub inline fn nsToTicks(ns: u64) u64 {
    return @truncate(@as(u128, ns) * sdk.boot_info.cpu_frequency / std.time.ns_per_s);
}

pub inline fn ticksToNs(ticks: u64) u64 {
    return @truncate(@as(u128, ticks) * std.time.ns_per_s / sdk.boot_info.cpu_frequency);
}

pub const DmaReader = struct {
    interface: std.Io.Reader,
    channel: u8,
    pos: u32,
    end: u32,

    pub inline fn init(channel: u8, size: u32, address: u32, buffer: []u8) DmaReader {
        return .{
            .interface = .{
                .buffer = buffer,
                .seek = 0,
                .end = 0,
                .vtable = &.{
                    .stream = stream,
                },
            },
            .channel = channel,
            .pos = address,
            .end = size,
        };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const this: *DmaReader = @fieldParentPtr("interface", reader);

        if (this.pos >= this.end) {
            return error.EndOfStream;
        }

        const available = writer.buffer.len - writer.end;
        const limited = if (limit.toInt()) |l|
            @min(available, l)
        else
            available;

        if (limited == 0) {
            return 0;
        }

        const to_read: u32 = @intCast(@min(limited, this.end - this.pos));
        const dest = writer.buffer[writer.end..][0..to_read];

        sdk.dma.read(this.channel, this.pos, dest);

        this.pos += to_read;
        writer.end += to_read;

        return to_read;
    }

    pub inline fn seekTo(this: *DmaReader, new_pos: u32) void {
        const logical_pos = this.getPos();

        if (new_pos >= logical_pos and new_pos < this.pos) {
            this.interface.seek += new_pos - logical_pos;

            return;
        }

        this.pos = new_pos;
        this.interface.seek = 0;
        this.interface.end = 0;
    }

    pub inline fn seekBy(this: *DmaReader, offset: i32) void {
        const current = this.getPos();
        const new_pos: u32 = if (offset >= 0)
            current +| @as(u32, @intCast(offset))
        else
            current -| @as(u32, @intCast(-offset));

        this.seekTo(new_pos);
    }

    pub inline fn seekFromEnd(this: *DmaReader, offset: u32) void {
        this.seekTo(this.end -| offset);
    }

    pub inline fn getPos(this: *const DmaReader) u32 {
        const buffered: u32 = @intCast(this.interface.end - this.interface.seek);

        return this.pos - buffered;
    }
};

pub const DmaWriter = struct {
    interface: std.Io.Writer,
    channel: u8,
    pos: u32,
    end: u32,

    pub inline fn init(channel: u8, size: u32, address: u32, buffer: []u8) DmaWriter {
        return .{
            .interface = .{
                .buffer = buffer,
                .end = 0,
                .vtable = &.{
                    .drain = drain,
                },
            },
            .channel = channel,
            .pos = address,
            .end = size,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const this: *DmaWriter = @fieldParentPtr("interface", w);

        if (w.end > 0) {
            try this.dmaWrite(w.buffer[0..w.end]);
            w.end = 0;
        }

        var written: usize = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len > 0) {
                try this.dmaWrite(bytes);
            }

            written += bytes.len;
        }

        const pattern = data[data.len - 1];

        for (0..splat) |_| {
            if (pattern.len > 0) {
                try this.dmaWrite(pattern);
            }

            written += pattern.len;
        }

        return written;
    }

    inline fn dmaWrite(this: *DmaWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (this.end - this.pos < bytes.len) {
            return error.WriteFailed;
        }

        sdk.dma.write(this.channel, this.pos, bytes);
        this.pos += bytes.len;
    }

    pub inline fn seekTo(this: *DmaWriter, new_pos: u32) std.Io.Writer.Error!void {
        try this.interface.flush();
        this.pos = new_pos;
    }

    pub inline fn seekBy(this: *DmaWriter, offset: i32) std.Io.Writer.Error!void {
        try this.interface.flush();

        if (offset >= 0) {
            this.pos +|= @as(u32, @intCast(offset));
        } else {
            this.pos -|= @as(u32, @intCast(-offset));
        }
    }

    pub inline fn seekFromEnd(this: *DmaWriter, offset: u32) std.Io.Writer.Error!void {
        try this.seekTo(this.end -| offset);
    }

    pub inline fn getPos(this: *const DmaWriter) u32 {
        return this.pos + @as(u32, @intCast(this.interface.end));
    }

    pub inline fn fillBytes(this: *DmaWriter, byte: u8, count: u32) !void {
        try this.interface.flush();

        if (this.end - this.pos < count) {
            return error.WriteFailed;
        }

        const pattern: [1]u8 = .{byte};
        sdk.dma.fill(this.channel, this.pos, &pattern, count);
        this.pos += count;
    }

    pub inline fn fillPattern(this: *DmaWriter, pattern: []const u8, total_len: u32) !void {
        try this.interface.flush();

        if (this.end - this.pos < total_len) {
            return error.WriteFailed;
        }

        sdk.dma.fill(this.channel, this.pos, pattern, total_len);
        this.pos += total_len;
    }
};

pub const SerialTerminalWriter = struct {
    interface: std.Io.Writer,
    channel: u8,
    serial_terminal: *volatile sdk.SerialTerminal,
    pos: u32,

    pub inline fn init(channel: u8, serial_terminal: *volatile sdk.SerialTerminal, buffer: []u8) SerialTerminalWriter {
        return .{
            .interface = .{
                .buffer = buffer,
                .end = 0,
                .vtable = &.{
                    .drain = drain,
                },
            },
            .channel = channel,
            .serial_terminal = serial_terminal,
            .pos = 0,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const this: *SerialTerminalWriter = @fieldParentPtr("interface", w);

        if (w.end > 0) {
            this.writeBytes(w.buffer[0..w.end]);
            w.end = 0;
        }

        var written: usize = 0;

        for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len > 0) {
                this.writeBytes(bytes);
            }

            written += bytes.len;
        }

        const pattern = data[data.len - 1];

        for (0..splat) |_| {
            if (pattern.len > 0) {
                this.writeBytes(pattern);
            }

            written += pattern.len;
        }

        return written;
    }

    fn writeBytes(this: *SerialTerminalWriter, bytes: []const u8) void {
        var offset: usize = 0;

        while (offset < bytes.len) {
            const space = sdk.SerialTerminal.OUTPUT_BUFFER_SIZE - this.pos;

            if (space == 0) {
                this.flushTerminal();
                continue;
            }

            const chunk_len: u32 = @truncate(@min(bytes.len - offset, space));

            sdk.dma.write(this.channel, this.pos, bytes[offset..][0..chunk_len]);

            var flush_needed = false;
            for (bytes[offset..][0..chunk_len]) |b| {
                if (b == '\n') {
                    flush_needed = true;
                    break;
                }
            }

            this.pos += chunk_len;
            offset += chunk_len;

            if (flush_needed) {
                this.flushTerminal();
            }
        }
    }

    inline fn flushTerminal(this: *SerialTerminalWriter) void {
        if (this.pos == 0) {
            return;
        }

        if (this.pos < sdk.SerialTerminal.OUTPUT_BUFFER_SIZE) {
            sdk.dma.write(this.channel, this.pos, &.{0});
        }

        this.serial_terminal.flush();
        this.pos = 0;
    }

    pub inline fn flush(this: *SerialTerminalWriter) std.Io.Writer.Error!void {
        try this.interface.flush();
        this.flushTerminal();
    }
};

pub fn PciDevice(comptime T: type, comptime ty: sdk.Pci.DeviceType) type {
    return struct {
        entry: sdk.Pci.Entry,
        slot: u8 = 0,

        pub inline fn mmio(this: *const @This()) *volatile T {
            return @ptrFromInt(this.entry.address);
        }

        pub inline fn find() ?@This() {
            for (&sdk.pci.status().entries, 0..) |entry, slot| {
                if (entry.ty == ty) {
                    return .{ .entry = entry, .slot = @intCast(slot) };
                }
            }

            return null;
        }
    };
}

pub const DateTime = struct {
    pub const EPOCH_YEAR: u32 = 1970;
    const DAYS_IN_MONTH = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    pub const Components = struct {
        year: u32,
        month: u8, // 1-12
        day: u8, // 1-31
        hour: u8, // 0-23
        minute: u8, // 0-59
        second: u8, // 0-59

        pub inline fn now() Components {
            return fromTimestamp(timestamp());
        }

        pub inline fn toTimestamp(this: Components) u64 {
            return DateTime.compose(this);
        }

        pub inline fn fromTimestamp(ts: u64) Components {
            return DateTime.decompose(ts);
        }

        pub inline fn addSeconds(this: Components, delta: i64) Components {
            const current = this.toTimestamp();

            if (delta >= 0) {
                return fromTimestamp(current +| @as(u64, @intCast(delta)));
            } else {
                const abs: u64 = @intCast(-delta);

                return fromTimestamp(current -| abs);
            }
        }

        pub inline fn addMinutes(this: Components, delta: i64) Components {
            return this.addSeconds(delta * std.time.s_per_min);
        }

        pub inline fn addHours(this: Components, delta: i64) Components {
            return this.addSeconds(delta * std.time.s_per_hour);
        }

        pub inline fn addDays(this: Components, delta: i64) Components {
            return this.addSeconds(delta * std.time.s_per_day);
        }

        pub inline fn addMonths(this: Components, delta: i32) Components {
            const current_abs_months: i64 = @as(i64, this.year) * 12 + (this.month - 1);
            const new_abs_months: i64 = current_abs_months + delta;

            const epoch_abs_months: i64 = @as(i64, DateTime.EPOCH_YEAR) * 12;

            if (new_abs_months < epoch_abs_months) {
                return .{
                    .year = DateTime.EPOCH_YEAR,
                    .month = 1,
                    .day = 1,
                    .hour = 0,
                    .minute = 0,
                    .second = 0,
                };
            }

            const new_year: u32 = @intCast(@divFloor(new_abs_months, 12));
            const new_month: u8 = @intCast(@mod(new_abs_months, 12) + 1);
            const max_day = DateTime.daysInMonth(new_year, new_month);

            return .{
                .year = new_year,
                .month = new_month,
                .day = @min(this.day, max_day),
                .hour = this.hour,
                .minute = this.minute,
                .second = this.second,
            };
        }

        pub inline fn addYears(this: Components, delta: i32) Components {
            const new_year: i64 = @as(i64, this.year) + delta;

            if (new_year < DateTime.EPOCH_YEAR) {
                return .{
                    .year = DateTime.EPOCH_YEAR,
                    .month = 1,
                    .day = 1,
                    .hour = 0,
                    .minute = 0,
                    .second = 0,
                };
            }

            const year: u32 = @intCast(new_year);
            const max_day = DateTime.daysInMonth(year, this.month);

            return .{
                .year = year,
                .month = this.month,
                .day = @min(this.day, max_day),
                .hour = this.hour,
                .minute = this.minute,
                .second = this.second,
            };
        }

        pub inline fn compare(this: Components, other: Components) std.math.Order {
            if (this.year != other.year) {
                return std.math.order(this.year, other.year);
            }

            if (this.month != other.month) {
                return std.math.order(this.month, other.month);
            }

            if (this.day != other.day) {
                return std.math.order(this.day, other.day);
            }

            if (this.hour != other.hour) {
                return std.math.order(this.hour, other.hour);
            }

            if (this.minute != other.minute) {
                if (this.minute != other.minute) return std.math.order(this.minute, other.minute);
                return std.math.order(this.minute, other.minute);
            }

            return std.math.order(this.second, other.second);
        }

        pub inline fn eq(this: Components, other: Components) bool {
            return this.compare(other) == .eq;
        }

        pub inline fn diffSeconds(this: Components, other: Components) i64 {
            const self_ts: i64 = @intCast(this.toTimestamp());
            const other_ts: i64 = @intCast(other.toTimestamp());

            return self_ts - other_ts;
        }

        pub inline fn diffDays(this: Components, other: Components) i64 {
            return @divFloor(this.diffSeconds(other), std.time.s_per_day);
        }
    };

    pub inline fn now() Components {
        return decompose(timestamp());
    }

    pub inline fn timestamp() u64 {
        return sdk.rtc.status().timestamp;
    }

    pub inline fn isLeapYear(year: u32) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }

    pub inline fn daysInYear(year: u32) u32 {
        return if (isLeapYear(year)) 366 else 365;
    }

    pub inline fn daysInMonth(year: u32, month: u8) u32 {
        if (month == 2 and isLeapYear(year)) {
            return 29;
        }

        return DAYS_IN_MONTH[month - 1];
    }

    pub inline fn dayOfWeek(ts: u64) u8 {
        const days = ts / std.time.s_per_day;

        return @intCast((days + 3) % 7);
    }

    pub inline fn dayOfWeekFromComponents(c: Components) u8 {
        return dayOfWeek(compose(c));
    }

    pub fn decompose(ts: u64) Components {
        var remaining = ts;

        var year: u32 = EPOCH_YEAR;
        while (true) {
            const seconds_in_year = @as(u64, daysInYear(year)) * std.time.s_per_day;
            if (remaining < seconds_in_year) break;
            remaining -= seconds_in_year;
            year += 1;
        }

        var day_of_year = remaining / std.time.s_per_day;
        remaining = remaining % std.time.s_per_day;

        var month: u8 = 1;
        while (month <= 12) {
            const days = daysInMonth(year, month);
            if (day_of_year < days) break;
            day_of_year -= days;
            month += 1;
        }

        const hour: u8 = @intCast(remaining / std.time.s_per_hour);
        remaining = remaining % std.time.s_per_hour;

        const minute: u8 = @intCast(remaining / std.time.s_per_min);
        const second: u8 = @intCast(remaining % std.time.s_per_min);

        return .{
            .year = year,
            .month = month,
            .day = @as(u8, @intCast(day_of_year)) + 1,
            .hour = hour,
            .minute = minute,
            .second = second,
        };
    }

    pub inline fn compose(c: Components) u64 {
        var total: u64 = 0;

        var y: u32 = EPOCH_YEAR;
        while (y < c.year) : (y += 1) {
            total += @as(u64, daysInYear(y)) * std.time.s_per_day;
        }

        var m: u8 = 1;
        while (m < c.month) : (m += 1) {
            total += @as(u64, daysInMonth(c.year, m)) * std.time.s_per_day;
        }

        total += @as(u64, c.day - 1) * std.time.s_per_day;
        total += @as(u64, c.hour) * std.time.s_per_hour;
        total += @as(u64, c.minute) * std.time.s_per_min;
        total += c.second;

        return total;
    }

    /// YYYY-MM-DDTHH:MM:SS
    pub inline fn format(ts: u64, writer: *std.Io.Writer) !void {
        const c = decompose(ts);

        try writer.print(
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
            .{ c.year, c.month, c.day, c.hour, c.minute, c.second },
        );
    }

    /// YYYY-MM-DD
    pub inline fn formatDate(ts: u64, writer: *std.Io.Writer) !void {
        const c = decompose(ts);
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ c.year, c.month, c.day });
    }

    /// HH:MM:SS
    pub inline fn formatTime(ts: u64, writer: *std.Io.Writer) !void {
        const c = decompose(ts);
        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ c.hour, c.minute, c.second });
    }

    pub inline fn formatNow(writer: *std.Io.Writer) !void {
        try format(timestamp(), writer);
    }
};

pub const DEFAULT_VGA_PALETTE: [sdk.Vga.PAL_LEN]sdk.Rgb = blk: {
    var pal: [sdk.Vga.PAL_LEN]sdk.Rgb = undefined;

    const std16 = [16]sdk.Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 128, .g = 0, .b = 0 },
        .{ .r = 0, .g = 128, .b = 0 },
        .{ .r = 128, .g = 128, .b = 0 },
        .{ .r = 0, .g = 0, .b = 128 },
        .{ .r = 128, .g = 0, .b = 128 },
        .{ .r = 0, .g = 128, .b = 128 },
        .{ .r = 192, .g = 192, .b = 192 },
        .{ .r = 128, .g = 128, .b = 128 },
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .r = 255, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
        .{ .r = 255, .g = 0, .b = 255 },
        .{ .r = 0, .g = 255, .b = 255 },
        .{ .r = 255, .g = 255, .b = 255 },
    };

    for (0..16) |i| {
        pal[i] = std16[i];
    }

    // 16–231: 6×6×6 color cube
    const levels = [_]u8{ 0, 51, 102, 153, 204, 255 };
    var idx: usize = 16;

    for (levels) |r| {
        for (levels) |g| {
            for (levels) |b| {
                pal[idx] = .{ .r = r, .g = g, .b = b };
                idx += 1;
            }
        }
    }

    for (0..24) |j| {
        const v: u8 = @intCast(8 + j * 10);
        pal[232 + j] = .{ .r = v, .g = v, .b = v };
    }

    break :blk pal;
};
