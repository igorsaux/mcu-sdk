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
