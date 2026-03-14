// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const ondatra = @import("ondatra");
pub const arch = ondatra.guest;

pub const utils = @import("utils.zig");

pub const Rgb = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};

pub const Memory = struct {
    pub const BOOT_INFO = 0x0000_1000;

    pub const SENSORS = 0x0000_2000;
    comptime {
        std.debug.assert(SENSORS >= BOOT_INFO + @sizeOf(BootInfo));
    }

    pub const POWER = 0x0000_3000;
    comptime {
        std.debug.assert(POWER >= SENSORS + @sizeOf(Sensors));
    }

    pub const RTC = 0x0000_4000;
    comptime {
        std.debug.assert(RTC >= POWER + @sizeOf(Power));
    }

    pub const PRNG = 0x0000_5000;
    comptime {
        std.debug.assert(PRNG >= RTC + @sizeOf(Rtc));
    }

    pub const CLINT = 0x0200_0000;

    pub const DMA = 0x1000_1000;

    pub const PCI = 0x1000_2000;
    comptime {
        std.debug.assert(PCI >= DMA + @sizeOf(Dma));
    }

    pub const PCI_DEVICES = 0x2000_0000;

    pub const RAM_START: u32 = 0x8000_0000;
};

pub const BootInfo = extern struct {
    cpu_frequency: u64,
    ram_size: u32,
    free_ram_start: u32,
};

pub const boot_info: *volatile BootInfo = @ptrFromInt(Memory.BOOT_INFO);

pub const Sensors = extern struct {
    pub const Flags = packed struct(u8) {
        overheat: bool = false,
        throttled: bool = false,
        _pad: u6 = 0,
    };

    /// C
    temperature: i16 = 0,
    flags: Flags = .{},
};

pub const sensors: *volatile Sensors = @ptrFromInt(Memory.SENSORS);

pub const Power = extern struct {
    /// mWh
    battery_charge: u32 = 0,
    has_external_source: bool = false,
};

pub const power: *volatile Power = @ptrFromInt(Memory.POWER);

pub const Rtc = extern struct {
    pub const Interrupts = extern struct {
        on_interval: bool = false,
        on_alarm: bool = false,
    };

    pub const Unit = enum(u8) {
        seconds = 0,
        minutes = 1,
        hours = 2,
        _,
    };

    pub const Config = extern struct {
        alarm: u64 = 0,
        interval: u32 = 0,
        unit: Unit = .seconds,
        interrupts: Interrupts = .{},
    };

    pub const Event = extern struct {
        pub const Type = enum(u8) {
            none = 0,
            interval = 1,
            alarm = 2,
            _,
        };

        ty: Type = .none,
    };

    pub const Status = extern struct {
        prev_interval_at: u64 = 0,
        timestamp: u64 = 0,
        shift_id: u32 = 0,
        last_event: Event = .{},
    };

    pub const Action = extern struct {
        ack: u8 = 0,
    };

    _config: Config = .{},
    _status: Status = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile Rtc) *volatile Config {
        return &this._config;
    }

    pub inline fn status(this: *volatile Rtc) *volatile Status {
        return &this._status;
    }

    pub inline fn action(this: *volatile Rtc) *volatile Action {
        return &this._action;
    }

    pub inline fn timestamp(this: *volatile Rtc) u64 {
        return this.status().timestamp;
    }

    pub inline fn shiftId(this: *volatile Rtc) u32 {
        return this.status().shift_id;
    }

    pub inline fn setAlarm(this: *volatile Rtc, value: u64) void {
        this.config().alarm = value;
    }

    pub inline fn every(this: *volatile Rtc, interval: u32, unit: Unit) void {
        this.config().unit = unit;
        this.config().interval = interval;
    }

    pub inline fn interrupts(this: *volatile Rtc) *volatile Interrupts {
        return &this.config().interrupts;
    }

    pub inline fn lastEvent(this: *volatile Rtc) ?Event {
        const event = this.status().last_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn ack(this: *volatile Rtc) void {
        this.action().ack = 1;
    }
};

pub const rtc: *volatile Rtc = @ptrFromInt(Memory.RTC);

pub const Prng = extern struct {
    pub const Status = extern struct {
        /// Returns a random byte
        value: u8 = 0,
    };

    _status: Status = .{},

    pub inline fn status(this: *volatile Prng) *volatile Status {
        return &this._status;
    }

    fn fill(ptr: *anyopaque, buf: []u8) void {
        _ = ptr;

        for (0..buf.len) |i| {
            buf[i] = prng.status().value;
        }
    }

    pub inline fn interface() std.Random {
        return .{
            .ptr = undefined,
            .fillFn = fill,
        };
    }
};

pub const prng: *volatile Prng = @ptrFromInt(Memory.PRNG);

pub const Clint = extern struct {
    pub const Interrupts = extern struct {
        on_sync_pulse: bool = false,
    };

    pub const Config = extern struct {
        mtime: u64 = 0,
        mtimecmp: u64 = 0,
        interrupts: Interrupts = .{},
    };

    pub const Event = extern struct {
        pub const Type = enum(u8) {
            none = 0,
            sync = 1,
            _,
        };

        ty: Type = .none,
    };

    pub const Status = extern struct {
        last_event: Event = .{},
    };

    pub const Action = extern struct {
        ack: u8 = 0,
    };

    _config: Config = .{},
    _status: Status = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile Clint) *volatile Config {
        return &this._config;
    }

    pub inline fn status(this: *volatile Clint) *volatile Status {
        return &this._status;
    }

    pub inline fn action(this: *volatile Clint) *volatile Action {
        return &this._action;
    }

    pub inline fn interrupts(this: *volatile Clint) *volatile Interrupts {
        return &this.config().interrupts;
    }

    pub inline fn lastEvent(this: *volatile Clint) ?Event {
        const event = this.status().last_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn readMtime(this: *volatile Clint) u64 {
        const bytes = std.mem.asBytes(&this.config().mtime);

        while (true) {
            const hi1 = std.mem.bytesToValue(u32, bytes[4..]);
            const lo = std.mem.bytesToValue(u32, bytes[0..]);
            const hi2 = std.mem.bytesToValue(u32, bytes[4..]);

            if (hi1 == hi2) {
                return @as(u64, hi1) << 32 | lo;
            }
        }
    }

    pub inline fn readMtimeNs(this: *volatile Clint) u64 {
        const ticks = this.readMtime();

        return utils.ticksToNs(ticks);
    }

    pub inline fn readMtimecmp(this: *volatile Clint) u64 {
        const bytes = std.mem.asBytes(&this.config().mtimecmp);

        while (true) {
            const hi1 = std.mem.bytesToValue(u32, bytes[4..]);
            const lo = std.mem.bytesToValue(u32, bytes[0..]);
            const hi2 = std.mem.bytesToValue(u32, bytes[4..]);

            if (hi1 == hi2) {
                return @as(u64, hi1) << 32 | lo;
            }
        }
    }

    pub inline fn readMtimecmpNs(this: *volatile Clint) u64 {
        const ticks = this.readMtimecmp();

        return utils.ticksToNs(ticks);
    }

    pub inline fn interruptAfter(this: *volatile Clint, ticks: u64) void {
        const mtime = this.readMtime();

        this.config().mtimecmp = mtime + ticks;
    }

    pub inline fn interruptAt(this: *volatile Clint, ticks: u64) void {
        this.config().mtimecmp = ticks;
    }

    pub inline fn interruptAfterNs(this: *volatile Clint, ns: u64) void {
        const ticks = utils.nsToTicks(ns);

        this.interruptAfter(ticks);
    }

    pub inline fn interruptAtNs(this: *volatile Clint, ns: u64) void {
        const ticks = utils.nsToTicks(ns);

        this.interruptAt(ticks);
    }

    pub inline fn ack(this: *volatile Clint) void {
        this.action().ack = 1;
    }
};

pub const clint: *volatile Clint = @ptrFromInt(Memory.CLINT);

pub const Dma = struct {
    pub const Mode = enum(u8) {
        read = 0,
        write = 1,
        fill = 2,
        _,
    };

    pub const Config = extern struct {
        src_address: u32 = 0,
        dst_address: u32 = 0,
        len: u32 = 0,
        pattern_len: u32 = 0,
        channel: u8 = 0,
        mode: Mode = .read,
    };

    pub const Action = extern struct {
        execute: u8 = 0,
    };

    _config: Config = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile Dma) *volatile Config {
        return &this._config;
    }

    pub inline fn action(this: *volatile Dma) *volatile Action {
        return &this._action;
    }

    pub inline fn read(this: *volatile Dma, channel: u8, address: u32, dst: []u8) void {
        this.config().* = .{
            .src_address = address,
            .dst_address = @intFromPtr(dst.ptr) - Memory.RAM_START,
            .len = dst.len,
            .channel = channel,
            .mode = .read,
        };
        this.action().execute = 1;
    }

    pub inline fn write(this: *volatile Dma, channel: u8, address: u32, src: []const u8) void {
        this.config().* = .{
            .src_address = @intFromPtr(src.ptr) - Memory.RAM_START,
            .dst_address = address,
            .len = src.len,
            .channel = channel,
            .mode = .write,
        };
        this.action().execute = 1;
    }

    pub inline fn fill(this: *volatile Dma, channel: u8, address: u32, pattern: []const u8, total_len: u32) void {
        this.config().* = .{
            .src_address = @intFromPtr(pattern.ptr) - Memory.RAM_START,
            .dst_address = address,
            .len = total_len,
            .pattern_len = pattern.len,
            .channel = channel,
            .mode = .fill,
        };
        this.action().execute = 1;
    }

    pub inline fn memset(this: *volatile Dma, channel: u8, address: u32, byte: u8, len: u32) void {
        const pattern: [1]u8 = .{byte};

        this.fill(channel, address, &pattern, len);
    }
};

pub const dma: *volatile Dma = @ptrFromInt(Memory.DMA);

pub const Pci = extern struct {
    pub const MAX_DEVICES: usize = 18;

    pub const DeviceType = enum(u8) {
        none = 0,
        tts = 1,
        serial_terminal = 2,
        signaler = 3,
        gps = 4,
        light = 5,
        env_sensor = 6,
        vga = 7,
        prize_box = 8,
        _,
    };

    pub const Entry = extern struct {
        address: u32 = 0,
        len: u32 = 0,
        ty: DeviceType = .none,
    };

    pub const Event = extern struct {
        pub const Ty = enum(u8) {
            none = 0,
            connected = 1,
            disconnected = 2,
            _,
        };

        ty: Ty = .none,
        slot: u8 = 0,
        device_type: DeviceType = .none,
    };

    pub const Interrupts = extern struct {
        on_disconnected: bool = false,
        on_connected: bool = false,
    };

    pub const Config = extern struct {
        interrupts: Interrupts = .{},
    };

    pub const Status = extern struct {
        entries: [MAX_DEVICES]Entry = std.mem.zeroes([MAX_DEVICES]Entry),
        devices_count: u8 = 0,
        last_event: Event = .{},
    };

    pub const Action = extern struct {
        ack: u8 = 0,
    };

    _config: Config = .{},
    _status: Status = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile Pci) *volatile Config {
        return &this._config;
    }

    pub inline fn status(this: *volatile Pci) *volatile Status {
        return &this._status;
    }

    pub inline fn action(this: *volatile Pci) *volatile Action {
        return &this._action;
    }

    pub inline fn interrupts(this: *volatile Pci) *volatile Interrupts {
        return &this.config().interrupts;
    }

    pub inline fn devicesCount(this: *volatile Pci) u8 {
        return this.status().devices_count;
    }

    pub inline fn entry(this: *volatile Pci, index: u8) ?*volatile Entry {
        if (index < this.devicesCount()) {
            return &this.status().entries[index];
        }

        return null;
    }

    pub inline fn lastEvent(this: *volatile Pci) ?Event {
        const event = this.status().last_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn ack(this: *volatile Pci) void {
        this.action().ack = 1;
    }
};

pub const pci: *volatile Pci = @ptrFromInt(Memory.PCI);

pub const Tts = extern struct {
    pub const BUFFER_SIZE: usize = 128;

    pub const Interrupts = extern struct {
        on_ready: bool = false,
    };

    pub const Language = enum(u8) {
        galcom = 0,
        eal = 1,
        sol_common = 2,
        unathi = 3,
        siik_mass = 4,
        skrellian = 5,
        local_rootspeak = 6,
        global_rootspeak = 7,
        lunar = 8,
        gutter = 9,
        indepented = 10,
        spacer = 11,
        robot = 12,
        drone = 13,
        _,
    };

    pub const Config = extern struct {
        language: Language = .galcom,
        interrupts: Interrupts = .{},
    };

    pub const Event = extern struct {
        pub const Type = enum(u8) {
            none = 0,
            ready = 1,
            _,
        };

        ty: Type = .none,
    };

    pub const Status = extern struct {
        ready: bool = false,
        last_event: Event = .{},
    };

    pub const Action = extern struct {
        execute: u8 = 0,
        ack: u8 = 0,
    };

    _config: Config = .{},
    _status: Status = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile Tts) *volatile Config {
        return &this._config;
    }

    pub inline fn interrupts(this: *volatile Tts) *volatile Interrupts {
        return &this.config().interrupts;
    }

    pub inline fn status(this: *volatile Tts) *volatile Status {
        return &this._status;
    }

    pub inline fn action(this: *volatile Tts) *volatile Action {
        return &this._action;
    }

    pub inline fn ready(this: *volatile Tts) bool {
        return this.status().ready;
    }

    pub inline fn lastEvent(this: *volatile Tts) ?Event {
        const event = this.status().last_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn say(this: *volatile Tts) void {
        this.action().execute = 1;
    }

    pub inline fn ack(this: *volatile Tts) void {
        this.action().ack = 1;
    }
};

pub const SerialTerminal = extern struct {
    pub const INPUT_BUFFER_SIZE: usize = 1024;
    pub const OUTPUT_BUFFER_SIZE: usize = 1024;

    pub const Event = extern struct {
        pub const Type = enum(u8) {
            none = 0,
            new_data = 1,
            _,
        };

        ty: Type = .none,
    };

    pub const Interrupts = extern struct {
        on_new_data: bool = false,
    };

    pub const Config = extern struct {
        interrupts: Interrupts = .{},
        raw_mode: u8 = 0,
    };

    pub const Status = extern struct {
        len: u16 = 0,
        last_event: Event = .{},
    };

    pub const Action = extern struct {
        flush: u8 = 0,
        ack: u8 = 0,
    };

    _config: Config = .{},
    _status: Status = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile SerialTerminal) *volatile Config {
        return &this._config;
    }

    pub inline fn status(this: *volatile SerialTerminal) *volatile Status {
        return &this._status;
    }

    pub inline fn action(this: *volatile SerialTerminal) *volatile Action {
        return &this._action;
    }

    pub inline fn interrupts(this: *volatile SerialTerminal) *volatile Interrupts {
        return &this.config().interrupts;
    }

    pub inline fn len(this: *volatile SerialTerminal) u16 {
        return this.status().len;
    }

    pub inline fn lastEvent(this: *volatile SerialTerminal) ?Event {
        const event = this.status().last_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn flush(this: *volatile SerialTerminal) void {
        this.action().flush = 1;
    }

    pub inline fn ack(this: *volatile SerialTerminal) void {
        this.action().ack = 1;
    }

    pub inline fn setRawMode(this: *volatile SerialTerminal, enabled: bool) void {
        this.config().raw_mode = if (enabled) 1 else 0;
    }

    pub inline fn isRawMode(this: *volatile SerialTerminal) bool {
        return this.config().raw_mode != 0;
    }
};

pub const Signaler = extern struct {
    pub const Event = extern struct {
        pub const Type = enum(u8) {
            none = 0,
            pulse = 1,
            ready = 2,
            _,
        };

        ty: Type = .none,
    };

    pub const Interrupts = extern struct {
        on_pulse: bool = false,
        on_ready: bool = false,
    };

    pub const Config = extern struct {
        frequency: u16 = 0,
        code: u8 = 0,
        interrupts: Interrupts = .{},
    };

    pub const Status = extern struct {
        last_event: Event = .{},
        ready: bool = false,
    };

    pub const Action = extern struct {
        set: u8 = 0,
        send: u8 = 0,
        ack: u8 = 0,
    };

    _config: Config = .{},
    _status: Status = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile Signaler) *volatile Config {
        return &this._config;
    }

    pub inline fn status(this: *volatile Signaler) *volatile Status {
        return &this._status;
    }

    pub inline fn action(this: *volatile Signaler) *volatile Action {
        return &this._action;
    }

    pub inline fn interrupts(this: *volatile Signaler) *volatile Interrupts {
        return &this._config.interrupts;
    }

    pub inline fn lastEvent(this: *volatile Signaler) ?Event {
        const event = this.status().last_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn ready(this: *volatile Signaler) bool {
        return this.status().ready;
    }

    pub inline fn set(this: *volatile Signaler, frequency: u16, code: u8) void {
        const cfg = this.config();

        cfg.frequency = frequency;
        cfg.code = code;

        this.action().set = 1;
    }

    pub inline fn send(this: *volatile Signaler) void {
        this.action().send = 1;
    }

    pub inline fn ack(this: *volatile Signaler) void {
        this.action().ack = 1;
    }
};

pub const Gps = extern struct {
    pub const Status = extern struct {
        x: i16 = 0,
        y: i16 = 0,
        z: i16 = 0,
    };

    _status: Status = .{},

    pub inline fn status(this: *volatile Gps) *volatile Status {
        return &this._status;
    }
};

pub const Light = extern struct {
    pub const Interrupts = extern struct {
        on_ready: bool = false,
    };

    pub const Config = extern struct {
        interrupts: Interrupts = .{},
        color: Rgb = .{},
        brightness: u8 = 0,
    };

    pub const Event = extern struct {
        pub const Type = enum(u8) {
            none = 0,
            ready = 1,
            _,
        };

        ty: Type = .none,
    };

    pub const Status = extern struct {
        ready: bool = false,
        last_event: Event = .{},
    };

    pub const Action = extern struct {
        set: u8 = 0,
        ack: u8 = 0,
    };

    _config: Config = .{},
    _status: Status = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile Light) *volatile Config {
        return &this._config;
    }

    pub inline fn interrupts(this: *volatile Light) *volatile Interrupts {
        return &this._config.interrupts;
    }

    pub inline fn status(this: *volatile Light) *volatile Status {
        return &this._status;
    }

    pub inline fn action(this: *volatile Light) *volatile Action {
        return &this._action;
    }

    pub inline fn lastEvent(this: *volatile Light) ?Event {
        const event = this.status().last_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn ready(this: *volatile Light) bool {
        return this.status().ready;
    }

    pub inline fn ack(this: *volatile Light) void {
        this.action().ack = 1;
    }

    pub inline fn set(this: *volatile Light, color: Rgb, brightness: u8) void {
        this.config().color = color;
        this.config().brightness = brightness;
        this.action().set = 1;
    }
};

pub const EnvSensor = extern struct {
    pub const Event = extern struct {
        pub const Type = enum(u8) {
            none = 0,
            ready = 1,
            _,
        };

        ty: Type = .none,
    };

    pub const Interrupts = extern struct {
        on_ready: bool = false,
    };

    pub const Rays = extern struct {
        alpha: bool = false,
        beta: bool = false,
        hawking: bool = false,
    };

    pub const Config = extern struct {
        interrupts: Interrupts = .{},
        rays: Rays = .{},
    };

    pub const Atmos = extern struct {
        total_moles: u32 = 0,
        /// Pa
        pressure: u32 = 0,
        /// K
        temperature: u16 = 0,
        /// Moles
        oxygen: u16 = 0,
        /// Moles
        nitrogen: u16 = 0,
        /// Moles
        carbon_dioxide: u16 = 0,
        /// Moles
        hydrogen: u16 = 0,
        /// Moles
        plasma: u16 = 0,
    };

    pub const Radiation = extern struct {
        /// Ci
        avg_activity: u32 = 0,
        /// eV
        avg_energy: u32 = 0,
        /// mGy
        dose: u16 = 0,
    };

    pub const Status = extern struct {
        atmos: Atmos = .{},
        radiation: Radiation = .{},
        ready: bool = false,
        last_event: Event = .{},
    };

    pub const Action = extern struct {
        update: u8 = 0,
        ack: u8 = 0,
    };

    _config: Config = .{},
    _status: Status = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile EnvSensor) *volatile Config {
        return &this._config;
    }

    pub inline fn status(this: *volatile EnvSensor) *volatile Status {
        return &this._status;
    }

    pub inline fn action(this: *volatile EnvSensor) *volatile Action {
        return &this._action;
    }

    pub inline fn lastEvent(this: *volatile EnvSensor) ?Event {
        const event = this.status().last_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn ready(this: *volatile EnvSensor) bool {
        return this.status().ready;
    }

    pub inline fn ack(this: *volatile EnvSensor) void {
        this.action().ack = 1;
    }
};

pub const Vga = extern struct {
    pub const KeyState = bool;

    pub const Pixel = u8;

    pub const KEYBOARD_LEN: usize = Scancode.KEYS;
    pub const KEYBOARD_SIZE: usize = KEYBOARD_LEN * @sizeOf(KeyState);

    pub const PAL_LEN: usize = 256;
    pub const PAL_SIZE: usize = PAL_LEN * @sizeOf(Rgb);

    pub const KEYBOARD_ADDRESS: usize = 0x0;
    comptime {
        std.debug.assert(KEYBOARD_ADDRESS == 0x0);
    }

    pub const PAL_ADDRESS: usize = std.mem.Alignment.of(Rgb).forward(KEYBOARD_ADDRESS + KEYBOARD_SIZE);
    comptime {
        std.debug.assert(PAL_ADDRESS == 0x6A);
    }

    pub const FB_ADDRESS: usize = std.mem.Alignment.of(u8).forward(PAL_ADDRESS + PAL_SIZE);
    comptime {
        std.debug.assert(FB_ADDRESS == 0x36A);
    }

    pub const Interrupts = extern struct {
        on_vblank: bool = false,
    };

    pub const KeyboardInterrupts = extern struct {
        on_key_press: bool = false,
        on_key_release: bool = false,
    };

    pub const MouseInterrupts = extern struct {
        on_move: bool = false,
        on_button_press: bool = false,
        on_button_release: bool = false,
        on_scroll: bool = false,
    };

    pub const BlitterConfig = extern struct {
        pub const Cmd = enum(u8) {
            none = 0,
            clear = 1,
            rect = 2,
            circle = 3,
            copy = 4,
            _,
        };

        pub const Args = extern union {
            pub const Mode = enum(u8) {
                crop,
                wrap,
            };

            pub const Origin = enum(u8) {
                top_left,
                top,
                top_right,
                right,
                bottom_right,
                bottom,
                bottom_left,
                left,
                center,
            };

            pub const Position = extern struct {
                x: u16 = 0,
                y: u16 = 0,
            };

            pub const Clear = extern struct {
                color: u8 = 0,
            };

            pub const Rect = extern struct {
                color: u8 = 0,
                pos: Position = .{},
                w: u16 = 0,
                h: u16 = 0,
                origin: Origin = .top_left,
                mode: Mode = .crop,
            };

            pub const Circle = extern struct {
                color: u8 = 0,
                pos: Position = .{},
                r: u16 = 0,
                origin: Origin = .top_left,
                mode: Mode = .crop,
            };

            pub const Copy = extern struct {
                /// Address of the source pixels.
                src: u32,
                w: u16 = 0,
                h: u16 = 0,
                src_pos: Position = .{},
                dst_pos: Position = .{},
                mode: Mode = .crop,
            };

            clear: Clear,
            rect: Rect,
            circle: Circle,
            copy: Copy,
        };

        cmd: Cmd = .none,
        args: Args = .{ .clear = .{ .color = 0 } },
    };

    pub const Resolution = enum(u8) {
        low = 0,
        med = 1,
        hi = 2,
        _,

        pub inline fn width(this: Resolution) u16 {
            return switch (this) {
                .low => return 160,
                .med => return 320,
                .hi => return 640,
                else => return 0,
            };
        }

        pub inline fn height(this: Resolution) u16 {
            return switch (this) {
                .low => return 120,
                .med => return 240,
                .hi => return 480,
                else => return 0,
            };
        }

        pub inline fn len(this: Resolution) usize {
            return @as(usize, this.width()) * @as(usize, this.height());
        }

        pub inline fn size(this: Resolution) usize {
            return this.len() * @sizeOf(Pixel);
        }

        pub inline fn fps(this: Resolution) u8 {
            return switch (this) {
                .low => return 30,
                .med => return 24,
                .hi => return 15,
                else => return 0,
            };
        }
    };

    pub const Config = extern struct {
        interrupts: Interrupts = .{},
        keyboard_interrupts: KeyboardInterrupts = .{},
        mouse_interrupts: MouseInterrupts = .{},
        blitter: BlitterConfig = .{},
        resolution: Resolution = .low,
    };

    pub const Event = extern struct {
        pub const Type = enum(u8) {
            none = 0,
            vblank = 1,
            _,
        };

        ty: Type = .none,
    };

    pub const Scancode = enum(u8) {
        pub const KEYS = @typeInfo(Scancode).@"enum".fields.len - 1;

        none = 0x00,

        a = 0x04,
        b = 0x05,
        c = 0x06,
        d = 0x07,
        e = 0x08,
        f = 0x09,
        g = 0x0A,
        h = 0x0B,
        i = 0x0C,
        j = 0x0D,
        k = 0x0E,
        l = 0x0F,
        m = 0x10,
        n = 0x11,
        o = 0x12,
        p = 0x13,
        q = 0x14,
        r = 0x15,
        s = 0x16,
        t = 0x17,
        u = 0x18,
        v = 0x19,
        w = 0x1A,
        x = 0x1B,
        y = 0x1C,
        z = 0x1D,

        @"1" = 0x1E,
        @"2" = 0x1F,
        @"3" = 0x20,
        @"4" = 0x21,
        @"5" = 0x22,
        @"6" = 0x23,
        @"7" = 0x24,
        @"8" = 0x25,
        @"9" = 0x26,
        @"0" = 0x27,

        enter = 0x28,
        escape = 0x29,
        backspace = 0x2A,
        tab = 0x2B,
        space = 0x2C,

        minus = 0x2D,
        equals = 0x2E,
        left_bracket = 0x2F,
        right_bracket = 0x30,
        backslash = 0x31,
        semicolon = 0x33,
        apostrophe = 0x34,
        grave = 0x35,
        comma = 0x36,
        period = 0x37,
        slash = 0x38,

        caps_lock = 0x39,
        scroll_lock = 0x47,
        num_lock = 0x53,

        f1 = 0x3A,
        f2 = 0x3B,
        f3 = 0x3C,
        f4 = 0x3D,
        f5 = 0x3E,
        f6 = 0x3F,
        f7 = 0x40,
        f8 = 0x41,
        f9 = 0x42,
        f10 = 0x43,
        f11 = 0x44,
        f12 = 0x45,

        print_screen = 0x46,
        pause = 0x48,
        insert = 0x49,
        home = 0x4A,
        page_up = 0x4B,
        delete = 0x4C,
        end = 0x4D,
        page_down = 0x4E,

        right = 0x4F,
        left = 0x50,
        down = 0x51,
        up = 0x52,

        kp_divide = 0x54,
        kp_multiply = 0x55,
        kp_minus = 0x56,
        kp_plus = 0x57,
        kp_enter = 0x58,
        kp_1 = 0x59,
        kp_2 = 0x5A,
        kp_3 = 0x5B,
        kp_4 = 0x5C,
        kp_5 = 0x5D,
        kp_6 = 0x5E,
        kp_7 = 0x5F,
        kp_8 = 0x60,
        kp_9 = 0x61,
        kp_0 = 0x62,
        kp_period = 0x63,

        left_ctrl = 0xE0,
        left_shift = 0xE1,
        left_alt = 0xE2,
        left_meta = 0xE3,
        right_ctrl = 0xE4,
        right_shift = 0xE5,
        right_alt = 0xE6,
        right_meta = 0xE7,

        mute = 0x7F,
        volume_up = 0x80,
        volume_down = 0x81,

        _,

        pub inline fn isModifier(this: Scancode) bool {
            return @intFromEnum(this) >= 0xE0 and @intFromEnum(this) <= 0xE7;
        }

        pub inline fn isNumpad(this: Scancode) bool {
            return @intFromEnum(this) >= 0x54 and @intFromEnum(this) <= 0x63;
        }

        const to_idx_table: [256]u8 = blk: {
            var table: [256]u8 = [_]u8{0xFF} ** 256;
            var idx: u8 = 0;

            const scancodes = [_]u8{
                0x04,
                0x05,
                0x06,
                0x07,
                0x08,
                0x09,
                0x0A,
                0x0B,
                0x0C,
                0x0D,
                0x0E,
                0x0F,
                0x10,
                0x11,
                0x12,
                0x13,
                0x14,
                0x15,
                0x16,
                0x17,
                0x18,
                0x19,
                0x1A,
                0x1B,
                0x1C,
                0x1D,
                0x1E,
                0x1F,
                0x20,
                0x21,
                0x22,
                0x23,
                0x24,
                0x25,
                0x26,
                0x27,
                0x28,
                0x29,
                0x2A,
                0x2B,
                0x2C,
                0x2D,
                0x2E,
                0x2F,
                0x30,
                0x31,
                0x33,
                0x34,
                0x35,
                0x36,
                0x37,
                0x38,
                0x39,
                0x3A,
                0x3B,
                0x3C,
                0x3D,
                0x3E,
                0x3F,
                0x40,
                0x41,
                0x42,
                0x43,
                0x44,
                0x45,
                0x46,
                0x47,
                0x48,
                0x49,
                0x4A,
                0x4B,
                0x4C,
                0x4D,
                0x4E,
                0x4F,
                0x50,
                0x51,
                0x52,
                0x53,
                0x54,
                0x55,
                0x56,
                0x57,
                0x58,
                0x59,
                0x5A,
                0x5B,
                0x5C,
                0x5D,
                0x5E,
                0x5F,
                0x60,
                0x61,
                0x62,
                0x63,
                0x7F,
                0x80,
                0x81,
                0xE0,
                0xE1,
                0xE2,
                0xE3,
                0xE4,
                0xE5,
                0xE6,
                0xE7,
            };

            for (scancodes) |sc| {
                table[sc] = idx;
                idx += 1;
            }

            std.debug.assert(idx == KEYS);

            break :blk table;
        };

        pub inline fn toIdx(this: Scancode) usize {
            std.debug.assert(this != .none);

            const raw = @intFromEnum(this);
            const idx = to_idx_table[raw];

            if (idx == 0xFF) {
                return KEYS;
            } else {
                return idx;
            }
        }

        pub inline fn fromIdx(idx: usize) ?Scancode {
            if (idx >= KEYS) {
                return null;
            }

            return from_idx_table[idx];
        }

        const from_idx_table: [KEYS]Scancode = blk: {
            var table: [KEYS]Scancode = undefined;

            for (0..256) |sc| {
                const idx = to_idx_table[sc];

                if (idx != 0xFF) {
                    table[idx] = @enumFromInt(sc);
                }
            }

            break :blk table;
        };
    };

    pub const Modifiers = packed struct(u8) {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        meta: bool = false,
        caps_lock: bool = false,
        num_lock: bool = false,
        _pad: u2 = 0,
    };

    pub const KeyboardEvent = extern struct {
        pub const MAX_EVENTS = 16;

        pub const Type = enum(u8) {
            none = 0,
            press = 1,
            release = 2,
            _,
        };

        ty: Type = .none,
        scancode: Scancode = .none,
        modifiers: Modifiers = .{},
    };

    pub const MouseButton = enum(u8) {
        none = 0,
        left = 1,
        right = 2,
        middle = 3,
        _,
    };

    pub const MouseEvent = extern struct {
        pub const MAX_EVENTS = 32;

        pub const Type = enum(u8) {
            none = 0,
            press = 1,
            release = 2,
            move = 3,
            scroll = 4,
            _,
        };

        ty: Type = .none,
        button: MouseButton = .none,
        dx: i16 = 0,
        dy: i16 = 0,
        scroll_dx: i16 = 0,
        scroll_dy: i16 = 0,
    };

    pub const MouseState = packed struct(u8) {
        left: bool = false,
        right: bool = false,
        middle: bool = false,
        _pad: u5 = 0,
    };

    pub const Status = extern struct {
        last_event: Event = .{},
        head_keyboard_event: KeyboardEvent = .{},
        head_mouse_event: MouseEvent = .{},
        mouse_state: MouseState = .{},
    };

    pub const Action = extern struct {
        ack: u8 = 0,
        keyboard_ack: u8 = 0,
        mouse_ack: u8 = 0,
        execute_blitter: u8 = 0,
    };

    _config: Config = .{},
    _status: Status = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile Vga) *volatile Config {
        return &this._config;
    }

    pub inline fn interrupts(this: *volatile Vga) *volatile Interrupts {
        return &this._config.interrupts;
    }

    pub inline fn keyboardInterrupts(this: *volatile Vga) *volatile KeyboardInterrupts {
        return &this._config.keyboard_interrupts;
    }

    pub inline fn mouseInterrupts(this: *volatile Vga) *volatile MouseInterrupts {
        return &this._config.mouse_interrupts;
    }

    pub inline fn blitter(this: *volatile Vga) *volatile BlitterConfig {
        return &this._config.blitter;
    }

    pub inline fn getResolution(this: *volatile Vga) Resolution {
        return this.config().resolution;
    }

    pub inline fn setResolution(this: *volatile Vga, new_res: Resolution) void {
        this.config().resolution = new_res;
    }

    pub inline fn status(this: *volatile Vga) *volatile Status {
        return &this._status;
    }

    pub inline fn lastEvent(this: *volatile Vga) ?Event {
        const event = this.status().last_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn headKeyboardEvent(this: *volatile Vga) ?KeyboardEvent {
        const event = this.status().head_keyboard_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn headMouseEvent(this: *volatile Vga) ?MouseEvent {
        const event = this.status().head_mouse_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn mouseState(this: *volatile Vga) *volatile MouseState {
        return &this.status().mouse_state;
    }

    pub inline fn action(this: *volatile Vga) *volatile Action {
        return &this._action;
    }

    pub inline fn ack(this: *volatile Vga) void {
        this.action().ack = 1;
    }

    pub inline fn keyboardAck(this: *volatile Vga) void {
        this.action().keyboard_ack = 1;
    }

    pub inline fn mouseAck(this: *volatile Vga) void {
        this.action().mouse_ack = 1;
    }

    pub inline fn executeBlitter(this: *volatile Vga) void {
        this.action().execute_blitter = 1;
    }

    pub inline fn clear(this: *volatile Vga, args: BlitterConfig.Args.Clear) void {
        this.blitter().* = .{
            .cmd = .clear,
            .args = .{ .clear = args },
        };
        this.executeBlitter();
    }

    pub inline fn rect(this: *volatile Vga, args: BlitterConfig.Args.Rect) void {
        this.blitter().* = .{
            .cmd = .rect,
            .args = .{ .rect = args },
        };
        this.executeBlitter();
    }

    pub inline fn circle(this: *volatile Vga, args: BlitterConfig.Args.Circle) void {
        this.blitter().* = .{
            .cmd = .circle,
            .args = .{ .circle = args },
        };
        this.executeBlitter();
    }

    pub inline fn copy(this: *volatile Vga, args: BlitterConfig.Args.Copy) void {
        this.blitter().* = .{
            .cmd = .copy,
            .args = .{ .copy = args },
        };
        this.executeBlitter();
    }
};

pub const PrizeBox = extern struct {
    pub const Interrupts = extern struct {
        on_ready: bool = false,
    };

    pub const Config = extern struct {
        interrupts: Interrupts = .{},
    };

    pub const Event = extern struct {
        pub const Type = enum(u8) {
            none = 0,
            ready = 1,
            _,
        };

        ty: Type = .none,
    };

    pub const Status = extern struct {
        ready: bool = false,
        empty: bool = true,
        last_event: Event = .{},
    };

    pub const Action = extern struct {
        ack: u8 = 0,
        vend: u8 = 0,
    };

    _config: Config = .{},
    _status: Status = .{},
    _action: Action = .{},

    pub inline fn config(this: *volatile PrizeBox) *volatile Config {
        return &this._config;
    }

    pub inline fn interrupts(this: *volatile PrizeBox) *volatile Interrupts {
        return &this.config().interrupts;
    }

    pub inline fn status(this: *volatile PrizeBox) *volatile Status {
        return &this._status;
    }

    pub inline fn ready(this: *volatile PrizeBox) bool {
        return this.status().ready;
    }

    pub inline fn empty(this: *volatile PrizeBox) bool {
        return this.status().empty;
    }

    pub inline fn lastEvent(this: *volatile PrizeBox) ?Event {
        const event = this.status().last_event;

        return if (event.ty == .none) null else event;
    }

    pub inline fn action(this: *volatile PrizeBox) *volatile Action {
        return &this._action;
    }

    pub inline fn ack(this: *volatile PrizeBox) void {
        this.action().ack = 1;
    }

    pub inline fn vend(this: *volatile PrizeBox) void {
        this.action().vend = 1;
    }
};
