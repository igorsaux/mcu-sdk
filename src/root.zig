// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

const ondatra = @import("ondatra");
pub const arch = ondatra.guest;

pub const utils = @import("utils.zig");

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

    pub const CLINT = 0x0200_0000;

    pub const PRNG = 0x0C00_2000;
    comptime {
        std.debug.assert(PRNG >= CLINT + @sizeOf(Clint));
    }

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
    pub const Rgb = extern struct {
        r: u8 = 0,
        g: u8 = 0,
        b: u8 = 0,
    };

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
