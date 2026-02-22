const std = @import("std");

const sdk = @import("mcu_sdk");

const SerialTerminal = struct {
    entry: sdk.Pci.Entry,
    slot: u8 = 0,

    pub inline fn mmio(this: SerialTerminal) *volatile sdk.SerialTerminal {
        return @ptrFromInt(this.entry.address);
    }
};

const Signaler = struct {
    entry: sdk.Pci.Entry,
    slot: u8 = 0,

    pub inline fn mmio(this: Signaler) *volatile sdk.Signaler {
        return @ptrFromInt(this.entry.address);
    }
};

inline fn findDevice(comptime T: type, comptime pci_type: sdk.Pci.DeviceType) ?T {
    for (&sdk.pci.status().entries, 0..) |entry, slot| {
        if (entry.ty == pci_type) {
            return .{ .entry = entry, .slot = @intCast(slot) };
        }
    }

    return null;
}

pub const MIN_FREQ: u16 = 1200;
pub const MAX_FREQ: u16 = 1600;
pub const MIN_CODE: u8 = 1;
pub const MAX_CODE: u8 = 100;

const C = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const italic = "\x1b[3m";
    const inv = "\x1b[7m";

    const orange = "\x1b[38;5;208m";
    const borange = "\x1b[38;5;214m";
    const dorange = "\x1b[38;5;166m";

    const white = "\x1b[37m";
    const bwhite = "\x1b[97m";
    const black = "\x1b[30m";
    const gray = "\x1b[90m";

    const green = "\x1b[32m";
    const bgreen = "\x1b[92m";
    const red = "\x1b[31m";
    const bred = "\x1b[91m";
    const cyan = "\x1b[36m";
    const bcyan = "\x1b[96m";
    const yellow = "\x1b[33m";
    const byellow = "\x1b[93m";

    // Background
    const bg_orange = "\x1b[48;5;208m";
};

const Shell = struct {
    terminal: SerialTerminal,
    signaler: Signaler,
    writer: sdk.utils.SerialTerminalWriter,
    out_buffer: [sdk.SerialTerminal.OUTPUT_BUFFER_SIZE]u8,
    cur_freq: u16,
    cur_code: u8,
    send_count: u32,

    pub fn init(terminal: SerialTerminal, signaler: Signaler) Shell {
        var shell = Shell{
            .terminal = terminal,
            .signaler = signaler,
            .writer = undefined,
            .out_buffer = undefined,
            .cur_freq = 0,
            .cur_code = 0,
            .send_count = 0,
        };

        shell.writer = .init(terminal.slot, terminal.mmio(), &shell.out_buffer);

        return shell;
    }

    pub fn run(this: *Shell) void {
        sdk.arch.Mie.setMeie();
        this.terminal.mmio().interrupts().on_new_data = true;
        this.signaler.mmio().interrupts().on_pulse = true;

        this.printBanner();

        while (true) {
            if (this.terminal.mmio().lastEvent()) |event| {
                this.terminal.mmio().ack();

                if (event.ty == .new_data) {
                    this.handleInput();
                }
            }

            if (this.signaler.mmio().lastEvent()) |event| {
                this.signaler.mmio().ack();

                if (event.ty == .pulse) {
                    this.print("\n");
                    this.printBox("SIGNAL RECEIVED", C.bgreen);
                    this.print(C.green ++ "  )) " ++ C.bgreen ++ "Incoming pulse detected" ++ C.reset ++ "\n\n");
                    this.printPrompt();
                    this.flush();
                }
            }

            sdk.arch.wfi();
        }
    }

    fn printBanner(this: *Shell) void {
        this.print("\n" ++ C.orange);
        this.print("        _____.----------.\n");
        this.print("       /     |  " ++ C.borange ++ ".(o)." ++ C.orange ++ "  |    " ++ C.bold ++ C.borange ++ "Flipper Sub-GHz" ++ C.reset ++ "\n");
        this.print(C.orange ++ "      |      |  " ++ C.bwhite ++ ":^^^:" ++ C.orange ++ "  |    " ++ C.dim ++ "Signal Transmitter" ++ C.reset ++ "\n");
        this.print(C.orange ++ "      |      |  " ++ C.borange ++ "`---'" ++ C.orange ++ "  |\n");
        this.print("      |      |         |\n");
        this.print("       \\_____| " ++ C.dim ++ "[]  []" ++ C.reset ++ C.orange ++ "  |\n");
        this.print("             |_________|\n");
        this.print(C.reset ++ "\n");

        this.printThinBox("Type 'help' for commands");
        this.print("\n");
        this.printPrompt();
        this.flush();
    }

    fn printBox(this: *Shell, title: []const u8, comptime color: []const u8) void {
        this.print(color ++ C.bold ++ "  ┌─ " ++ C.reset);
        this.print(color ++ C.bold);
        this.print(title);
        this.print(" " ++ C.reset);
        this.print(color ++ C.bold ++ "─┐" ++ C.reset ++ "\n");
    }

    fn printThinBox(this: *Shell, text: []const u8) void {
        this.print(C.gray ++ "  ┌");

        for (0..text.len + 2) |_| {
            this.print("─");
        }

        this.print("┐\n");
        this.print("  │ " ++ C.reset ++ C.dim);
        this.print(text);
        this.print(C.gray ++ " │\n");
        this.print("  └");

        for (0..text.len + 2) |_| {
            this.print("─");
        }

        this.print("┘" ++ C.reset ++ "\n");
    }

    fn handleInput(this: *Shell) void {
        const bytes = this.terminal.mmio().len();
        var input_buffer: [sdk.SerialTerminal.INPUT_BUFFER_SIZE]u8 = undefined;
        sdk.dma.read(this.terminal.slot, 0, input_buffer[0..bytes]);

        var input = input_buffer[0..bytes];

        while (input.len > 0 and (input[input.len - 1] == '\n' or input[input.len - 1] == '\r')) {
            input = input[0 .. input.len - 1];
        }

        this.executeCommand(input);
        this.printPrompt();
        this.flush();
    }

    fn executeCommand(this: *Shell, input: []const u8) void {
        var trimmed = input;

        while (trimmed.len > 0 and trimmed[0] == ' ') {
            trimmed = trimmed[1..];
        }

        if (trimmed.len == 0) {
            return;
        }

        var cmd = trimmed;
        var args: []const u8 = "";

        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |idx| {
            cmd = trimmed[0..idx];
            args = trimmed[idx + 1 ..];

            while (args.len > 0 and args[0] == ' ') {
                args = args[1..];
            }
        }

        if (std.mem.eql(u8, cmd, "help")) {
            this.cmdHelp();
        } else if (std.mem.eql(u8, cmd, "freq")) {
            this.cmdFreq(args);
        } else if (std.mem.eql(u8, cmd, "code")) {
            this.cmdCode(args);
        } else if (std.mem.eql(u8, cmd, "set")) {
            this.cmdSet(args);
        } else if (std.mem.eql(u8, cmd, "send")) {
            this.cmdSend();
        } else if (std.mem.eql(u8, cmd, "status")) {
            this.cmdStatus();
        } else {
            this.print(C.bred ++ "  [!] " ++ C.reset ++ C.red ++ "Unknown: " ++ C.reset);
            this.print(cmd);
            this.print("\n");
        }
    }

    fn cmdHelp(this: *Shell) void {
        this.print("\n");
        this.printBox("Sub-GHz Commands", C.orange);
        this.print("\n");
        this.print(C.borange ++ "  > " ++ C.bwhite ++ "freq " ++ C.gray ++ "<n>      " ++ C.dim ++ "Set frequency\n" ++ C.reset);
        this.print(C.borange ++ "  > " ++ C.bwhite ++ "code " ++ C.gray ++ "<n>      " ++ C.dim ++ "Set code\n" ++ C.reset);
        this.print(C.borange ++ "  > " ++ C.bwhite ++ "set " ++ C.gray ++ "<f> <c>   " ++ C.dim ++ "Set freq & code\n" ++ C.reset);
        this.print(C.borange ++ "  > " ++ C.bwhite ++ "send" ++ C.gray ++ "          " ++ C.dim ++ "Transmit signal\n" ++ C.reset);
        this.print(C.borange ++ "  > " ++ C.bwhite ++ "status" ++ C.gray ++ "        " ++ C.dim ++ "Current config\n" ++ C.reset);
        this.print(C.borange ++ "  > " ++ C.bwhite ++ "help" ++ C.gray ++ "          " ++ C.dim ++ "This screen\n" ++ C.reset);
        this.print("\n");
        this.printFmt(C.gray ++ "  freq: {}-{}  code: {}-{}" ++ C.reset ++ "\n\n", .{ MIN_FREQ, MAX_FREQ, MIN_CODE, MAX_CODE });
    }

    fn cmdFreq(this: *Shell, args: []const u8) void {
        if (args.len == 0) {
            this.printFmt(C.bred ++ "  [!] " ++ C.reset ++ "Specify frequency ({}-{})\n", .{ MIN_FREQ, MAX_FREQ });

            return;
        }

        const val = parseU16(args);

        if (val < MIN_FREQ or val > MAX_FREQ) {
            this.printFmt(C.bred ++ "  [!] " ++ C.reset ++ "Range: {}-{}\n", .{ MIN_FREQ, MAX_FREQ });

            return;
        }

        this.cur_freq = val;
        this.print(C.bgreen ++ "  [+] " ++ C.reset ++ "Freq " ++ C.orange ++ "= " ++ C.bold ++ C.borange);
        this.printNumber(val);
        this.print(C.reset ++ "\n");
    }

    fn cmdCode(this: *Shell, args: []const u8) void {
        if (args.len == 0) {
            this.printFmt(C.bred ++ "  [!] " ++ C.reset ++ "Specify code ({}-{})\n", .{ MIN_CODE, MAX_CODE });

            return;
        }

        const val = parseU16(args);

        if (val < MIN_CODE or val > MAX_CODE) {
            this.printFmt(C.bred ++ "  [!] " ++ C.reset ++ "Range: {}-{}\n", .{ MIN_CODE, MAX_CODE });

            return;
        }

        this.cur_code = @truncate(val);
        this.print(C.bgreen ++ "  [+] " ++ C.reset ++ "Code " ++ C.orange ++ "= " ++ C.bold ++ C.borange);
        this.printNumber(val);
        this.print(C.reset ++ "\n");
    }

    fn cmdSet(this: *Shell, args: []const u8) void {
        if (args.len == 0) {
            this.print(C.bred ++ "  [!] " ++ C.reset ++ "Usage: set <freq> <code>\n");

            return;
        }

        var freq_str = args;
        var code_str: []const u8 = "";

        if (std.mem.indexOfScalar(u8, args, ' ')) |idx| {
            freq_str = args[0..idx];
            code_str = args[idx + 1 ..];

            while (code_str.len > 0 and code_str[0] == ' ') {
                code_str = code_str[1..];
            }
        } else {
            this.print(C.bred ++ "  [!] " ++ C.reset ++ "Usage: set <freq> <code>\n");

            return;
        }

        const freq = parseU16(freq_str);
        const code = parseU16(code_str);

        if (freq < MIN_FREQ or freq > MAX_FREQ) {
            this.printFmt(C.bred ++ "  [!] " ++ C.reset ++ "Freq range: {}-{}\n", .{ MIN_FREQ, MAX_FREQ });

            return;
        }
        if (code < MIN_CODE or code > MAX_CODE) {
            this.printFmt(C.bred ++ "  [!] " ++ C.reset ++ "Code range: {}-{}\n", .{ MIN_CODE, MAX_CODE });

            return;
        }

        this.cur_freq = freq;
        this.cur_code = @truncate(code);

        this.print(C.bgreen ++ "  [+] " ++ C.reset ++ "Freq " ++ C.orange ++ "= " ++ C.bold ++ C.borange);
        this.printNumber(freq);
        this.print(C.reset ++ "  Code " ++ C.orange ++ "= " ++ C.bold ++ C.borange);
        this.printNumber(code);
        this.print(C.reset ++ "\n");
    }

    fn cmdSend(this: *Shell) void {
        if (this.cur_freq == 0) {
            this.print(C.bred ++ "  [!] " ++ C.reset ++ "No frequency configured\n");

            return;
        }

        if (!this.signaler.mmio().ready()) {
            this.print(C.byellow ++ "  [~] " ++ C.reset ++ C.dim ++ "Cooldown, wait..." ++ C.reset ++ "\n");

            return;
        }

        this.signaler.mmio().set(this.cur_freq, this.cur_code);
        this.signaler.mmio().send();
        this.send_count += 1;

        this.print("\n");
        this.printBox("TRANSMITTING", C.orange);
        this.print(C.orange ++ "  ((" ++ C.borange ++ "((" ++ C.bold ++ C.bwhite ++ " SENT " ++ C.reset ++ C.borange ++ "))" ++ C.orange ++ "))" ++ C.reset ++ "\n");
        this.print(C.gray ++ "  freq=" ++ C.borange);
        this.printNumber(this.cur_freq);
        this.print(C.gray ++ "  code=" ++ C.borange);
        this.printNumber(this.cur_code);
        this.print(C.reset ++ "\n\n");
    }

    fn cmdStatus(this: *Shell) void {
        this.print("\n");
        this.print(C.orange ++ "  ┌──────────────────────┐\n");
        this.print("  │" ++ C.bold ++ C.borange ++ "   Sub-GHz Config    " ++ C.reset ++ C.orange ++ "│\n");
        this.print("  ├──────────────────────┤\n");

        this.print("  │ " ++ C.gray ++ "Freq: " ++ C.reset);

        if (this.cur_freq == 0) {
            this.print(C.dim ++ "---          " ++ C.reset);
        } else {
            this.print(C.bold ++ C.borange);
            this.printNumber(this.cur_freq);
            this.printPadding(this.cur_freq);
        }

        this.print(C.orange ++ "│\n");

        this.print("  │ " ++ C.gray ++ "Code: " ++ C.reset ++ C.bold ++ C.borange);
        this.printNumber(this.cur_code);
        this.printPaddingU8(this.cur_code);
        this.print(C.orange ++ "│\n");

        this.print("  │ " ++ C.gray ++ "Sent: " ++ C.reset ++ C.bwhite);
        this.printNumber(this.send_count);
        this.printPadding(this.send_count);
        this.print(C.orange ++ "│\n");

        this.print("  │ " ++ C.gray ++ "Ready: ");

        if (this.signaler.mmio().ready()) {
            this.print(C.bgreen ++ "YES          " ++ C.reset);
        } else {
            this.print(C.bred ++ "NO           " ++ C.reset);
        }

        this.print(C.orange ++ "│\n");

        this.print("  └──────────────────────┘" ++ C.reset ++ "\n\n");
    }

    fn printPadding(this: *Shell, n: anytype) void {
        const val: u32 = @intCast(n);
        const digits: u32 = if (val == 0) 1 else blk: {
            var d: u32 = 0;
            var v = val;
            while (v > 0) : (v /= 10) d += 1;
            break :blk d;
        };

        var i: u32 = 0;
        while (i < 13 - digits) : (i += 1) {
            this.print(" ");
        }

        this.print(C.reset);
    }

    fn printPaddingU8(this: *Shell, n: u8) void {
        const val: u32 = @intCast(n);
        const digits: u32 = if (val == 0) 1 else blk: {
            var d: u32 = 0;
            var v = val;
            while (v > 0) : (v /= 10) d += 1;
            break :blk d;
        };

        var i: u32 = 0;
        while (i < 13 - digits) : (i += 1) {
            this.print(" ");
        }

        this.print(C.reset);
    }

    fn parseU16(s: []const u8) u16 {
        var val: u16 = 0;

        for (s) |c| {
            if (c >= '0' and c <= '9') {
                val = val *| 10 +| (c - '0');
            } else {
                break;
            }
        }

        return val;
    }

    inline fn printPrompt(this: *Shell) void {
        this.print(C.orange ++ "flipper" ++ C.borange ++ ":sub-ghz" ++ C.bwhite ++ "$ " ++ C.reset);
    }

    inline fn print(this: *Shell, text: []const u8) void {
        this.writer.interface.writeAll(text) catch {};
    }

    inline fn printFmt(this: *Shell, comptime fmt: []const u8, args: anytype) void {
        this.writer.interface.print(fmt, args) catch {};
    }

    inline fn printNumber(this: *Shell, n: anytype) void {
        this.writer.interface.print("{}", .{n}) catch {};
    }

    inline fn flush(this: *Shell) void {
        this.writer.flush() catch {};
    }
};

pub fn main() void {
    const terminal = findDevice(SerialTerminal, .serial_terminal) orelse return;
    const signaler = findDevice(Signaler, .signaler) orelse return;

    var shell = Shell.init(terminal, signaler);
    shell.run();
}

comptime {
    _ = sdk.utils.EntryPoint(.{
        .stack_size = std.math.pow(u32, 2, 14),
    });
}
