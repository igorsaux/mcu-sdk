const std = @import("std");

const sdk = @import("mcu_sdk");

const SerialTerminal = sdk.utils.PciDevice(sdk.SerialTerminal, .serial_terminal);
const EnvSensor = sdk.utils.PciDevice(sdk.EnvSensor, .env_sensor);

const C = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const italic = "\x1b[3m";
    const inv = "\x1b[7m";

    const cyan = "\x1b[36m";
    const bcyan = "\x1b[96m";
    const dcyan = "\x1b[38;5;30m";

    const white = "\x1b[37m";
    const bwhite = "\x1b[97m";
    const black = "\x1b[30m";
    const gray = "\x1b[90m";

    const green = "\x1b[32m";
    const bgreen = "\x1b[92m";
    const red = "\x1b[31m";
    const bred = "\x1b[91m";
    const yellow = "\x1b[33m";
    const byellow = "\x1b[93m";
    const blue = "\x1b[34m";
    const bblue = "\x1b[94m";
    const magenta = "\x1b[35m";
    const bmagenta = "\x1b[95m";
};

const Shell = struct {
    terminal: SerialTerminal,
    sensor: EnvSensor,
    writer: sdk.utils.SerialTerminalWriter,
    out_buffer: [sdk.SerialTerminal.OUTPUT_BUFFER_SIZE]u8,
    read_count: u32,

    pub fn init(terminal: SerialTerminal, sensor: EnvSensor) Shell {
        var shell = Shell{
            .terminal = terminal,
            .sensor = sensor,
            .writer = undefined,
            .out_buffer = undefined,
            .read_count = 0,
        };

        shell.writer = .init(terminal.slot, terminal.mmio(), &shell.out_buffer);

        return shell;
    }

    pub fn run(this: *Shell) void {
        sdk.arch.Mie.setMeie();
        this.terminal.mmio().interrupts().on_new_data = true;
        this.sensor.mmio().config().interrupts.on_ready = true;

        this.printBanner();

        while (true) {
            if (this.terminal.mmio().lastEvent()) |event| {
                this.terminal.mmio().ack();

                if (event.ty == .new_data) {
                    this.handleInput();
                }
            }

            if (this.sensor.mmio().lastEvent()) |event| {
                this.sensor.mmio().ack();

                if (event.ty == .ready) {
                    this.print("\n");
                    this.printBox("SENSOR READY", C.bgreen);
                    this.print(C.green ++ "  ✓ " ++ C.bgreen ++ "New readings available" ++ C.reset ++ "\n\n");
                    this.printPrompt();
                    this.flush();
                }
            }

            sdk.arch.wfi();
        }
    }

    fn printBanner(this: *Shell) void {
        this.print("\n" ++ C.cyan);
        this.print("      ╔════════════════╗\n");
        this.print("      ║ " ++ C.bcyan ++ "◉" ++ C.cyan ++ " ENV SENSOR " ++ C.bcyan ++ "◉" ++ C.cyan ++ " ║     " ++ C.bold ++ C.bcyan ++ "Environmental Monitor" ++ C.reset ++ "\n");
        this.print(C.cyan ++ "      ╠════════════════╣    " ++ C.dim ++ "Atmospheric & Radiation" ++ C.reset ++ "\n");
        this.print(C.cyan ++ "      ║ " ++ C.dim ++ "≋≋≋≋≋≋≋≋≋≋≋≋≋≋" ++ C.reset ++ C.cyan ++ " ║\n");
        this.print("      ║ " ++ C.byellow ++ "  ☢" ++ C.cyan ++ " " ++ C.dim ++ "RAD" ++ C.reset ++ C.cyan ++ " " ++ C.bgreen ++ "○" ++ C.cyan ++ " " ++ C.dim ++ "ATM" ++ C.reset ++ C.cyan ++ "  ║\n");
        this.print("      ╚════════════════╝\n");
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
        } else if (std.mem.eql(u8, cmd, "read")) {
            this.cmdRead();
        } else if (std.mem.eql(u8, cmd, "atmos")) {
            this.cmdAtmos();
        } else if (std.mem.eql(u8, cmd, "rad")) {
            this.cmdRad();
        } else if (std.mem.eql(u8, cmd, "rays")) {
            this.cmdRays(args);
        } else if (std.mem.eql(u8, cmd, "update")) {
            this.cmdUpdate();
        } else if (std.mem.eql(u8, cmd, "status")) {
            this.cmdStatus();
        } else {
            this.printFmt(C.bred ++ "  [!] " ++ C.reset ++ C.red ++ "Unknown: " ++ C.reset ++ "{s}\n", .{cmd});
        }
    }

    fn cmdHelp(this: *Shell) void {
        this.print("\n");
        this.printBox("EnvSensor Commands", C.cyan);
        this.print("\n");
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "read" ++ C.gray ++ "          " ++ C.dim ++ "Full sensor readout\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "atmos" ++ C.gray ++ "         " ++ C.dim ++ "Atmospheric data\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "rad" ++ C.gray ++ "           " ++ C.dim ++ "Radiation levels\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "rays " ++ C.gray ++ "<type>   " ++ C.dim ++ "Toggle ray detection\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "update" ++ C.gray ++ "        " ++ C.dim ++ "Request new reading\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "status" ++ C.gray ++ "        " ++ C.dim ++ "Sensor status\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "help" ++ C.gray ++ "          " ++ C.dim ++ "This screen\n" ++ C.reset);
        this.print("\n");
        this.print(C.gray ++ "  rays: alpha, beta, hawking" ++ C.reset ++ "\n\n");
    }

    fn cmdRead(this: *Shell) void {
        if (!this.sensor.mmio().ready()) {
            this.print(C.byellow ++ "  [~] " ++ C.reset ++ C.dim ++ "Sensor not ready..." ++ C.reset ++ "\n");
            return;
        }

        this.read_count += 1;
        this.cmdAtmos();
        this.flush();
        this.cmdRad();
    }

    fn cmdAtmos(this: *Shell) void {
        const atmos = this.sensor.mmio().status().atmos;

        const pressure_kpa = atmos.pressure / 1000;
        const pressure_frac = (atmos.pressure % 1000) / 100;

        const temp_k: u16 = atmos.temperature;
        const temp_c: i32 = @as(i32, temp_k) - 273;

        this.print("\n" ++ C.cyan);
        this.print("  ┌────────────────────────────────┐\n");
        this.print("  │" ++ C.bold ++ C.bcyan ++ "      Atmospheric Data          " ++ C.reset ++ C.cyan ++ "│\n");
        this.print("  ├────────────────────────────────┤\n");

        this.printFmt("  │ " ++ C.gray ++ "Pressure:" ++ C.reset ++ " " ++ C.bwhite ++ "{d: >5}.{d}" ++ C.dim ++ " kPa" ++ C.reset ++ "          " ++ C.cyan ++ "│\n", .{ pressure_kpa, pressure_frac });

        this.printFmt("  │ " ++ C.gray ++ "Temp:" ++ C.reset ++ "     " ++ C.byellow ++ "{d: >4}" ++ C.dim ++ " C (" ++ C.byellow ++ "{d: >4}" ++ C.dim ++ " K)" ++ C.reset ++ "      " ++ C.cyan ++ "│\n", .{ temp_c, temp_k });

        this.printFmt("  │ " ++ C.gray ++ "Moles:" ++ C.reset ++ "    " ++ C.bwhite ++ "{d: <18}   " ++ C.reset ++ C.cyan ++ "│\n", .{atmos.total_moles});

        this.print("  ├────────────────────────────────┤\n");

        this.printFmt("  │ " ++ C.bblue ++ "O2:" ++ C.reset ++ "  {d: <6} " ++ C.bwhite ++ "N2:" ++ C.reset ++ "  {d: <10}    " ++ C.cyan ++ "│\n", .{ atmos.oxygen, atmos.nitrogen });

        this.printFmt("  │ " ++ C.gray ++ "CO2:" ++ C.reset ++ " {d: <6} " ++ C.bcyan ++ "H2:" ++ C.reset ++ "  {d: <10}    " ++ C.cyan ++ "│\n", .{ atmos.carbon_dioxide, atmos.hydrogen });

        this.printFmt("  │ " ++ C.bmagenta ++ "Plasma:" ++ C.reset ++ "  " ++ C.gray ++ "{d: <18}    " ++ C.reset ++ C.cyan ++ "│\n", .{atmos.plasma});

        this.print("  └────────────────────────────────┘" ++ C.reset ++ "\n");
    }

    fn cmdRad(this: *Shell) void {
        const rad = this.sensor.mmio().status().radiation;

        this.print("\n" ++ C.yellow);
        this.print("  ┌────────────────────────────────┐\n");
        this.print("  │" ++ C.bold ++ C.byellow ++ "      ☢ Radiation Data ☢        " ++ C.reset ++ C.yellow ++ "│\n");
        this.print("  ├────────────────────────────────┤\n");

        this.printFmt("  │ " ++ C.gray ++ "Activity:" ++ C.reset ++ " " ++ C.bold ++ C.byellow ++ "{d: >10}" ++ C.dim ++ " Ci" ++ C.reset ++ "      " ++ C.yellow ++ "│\n", .{rad.avg_activity});

        this.printFmt("  │ " ++ C.gray ++ "Energy:" ++ C.reset ++ "   " ++ C.bold ++ C.byellow ++ "{d: >10}" ++ C.dim ++ " eV" ++ C.reset ++ "        " ++ C.yellow ++ "│\n", .{rad.avg_energy});

        const dose_color = if (rad.dose > 100) C.bred else if (rad.dose > 50) C.byellow else C.bgreen;
        _ = dose_color;
        this.print("  │ " ++ C.gray ++ "Dose:" ++ C.reset ++ "     " ++ C.bold);

        if (rad.dose > 100) {
            this.print(C.bred);
        } else if (rad.dose > 50) {
            this.print(C.byellow);
        } else {
            this.print(C.bgreen);
        }

        this.printFmt("{d: >10}" ++ C.dim ++ " mGy" ++ C.reset ++ "       " ++ C.yellow ++ "│\n", .{rad.dose});

        this.print("  └────────────────────────────────┘" ++ C.reset ++ "\n\n");
    }

    fn cmdRays(this: *Shell, args: []const u8) void {
        if (args.len == 0) {
            this.print(C.bred ++ "  [!] " ++ C.reset ++ "Usage: rays <alpha|beta|hawking>\n");
            this.printRaysStatus();
            return;
        }

        var ray_type = args;

        if (std.mem.indexOfScalar(u8, args, ' ')) |idx| {
            ray_type = args[0..idx];
        }

        const rays = this.sensor.mmio().config().rays;

        if (std.mem.eql(u8, ray_type, "alpha")) {
            this.sensor.mmio().config().rays.alpha = !rays.alpha;
            this.printFmt(C.bgreen ++ "  [+] " ++ C.reset ++ "Alpha rays: {s}\n", .{if (!rays.alpha) C.bgreen ++ "ON " ++ C.reset else C.bred ++ "OFF" ++ C.reset});
        } else if (std.mem.eql(u8, ray_type, "beta")) {
            this.sensor.mmio().config().rays.beta = !rays.beta;
            this.printFmt(C.bgreen ++ "  [+] " ++ C.reset ++ "Beta rays: {s}\n", .{if (!rays.beta) C.bgreen ++ "ON " ++ C.reset else C.bred ++ "OFF" ++ C.reset});
        } else if (std.mem.eql(u8, ray_type, "hawking")) {
            this.sensor.mmio().config().rays.hawking = !rays.hawking;
            this.printFmt(C.bgreen ++ "  [+] " ++ C.reset ++ "Hawking radiation: {s}\n", .{if (!rays.hawking) C.bgreen ++ "ON " ++ C.reset else C.bred ++ "OFF" ++ C.reset});
        } else {
            this.printFmt(C.bred ++ "  [!] " ++ C.reset ++ "Unknown ray type: {s}\n", .{ray_type});
        }
    }

    fn printRaysStatus(this: *Shell) void {
        const rays = this.sensor.mmio().config().rays;

        this.printFmt(C.gray ++ "  Current: " ++ C.reset ++ "a:{s} b:{s} H:{s}\n", .{
            if (rays.alpha) C.bgreen ++ "ON " ++ C.reset else C.bred ++ "OFF " ++ C.reset,
            if (rays.beta) C.bgreen ++ "ON " ++ C.reset else C.bred ++ "OFF " ++ C.reset,
            if (rays.hawking) C.bgreen ++ "ON" ++ C.reset else C.bred ++ "OFF" ++ C.reset,
        });
    }

    fn cmdUpdate(this: *Shell) void {
        if (!this.sensor.mmio().ready()) {
            this.print(C.byellow ++ "  [~] " ++ C.reset ++ C.dim ++ "Sensor busy..." ++ C.reset ++ "\n");
            return;
        }

        this.sensor.mmio().action().update = 1;
        this.print(C.bgreen ++ "  [+] " ++ C.reset ++ "Update requested\n");
    }

    fn cmdStatus(this: *Shell) void {
        this.print("\n" ++ C.cyan);
        this.print("  ┌──────────────────────────┐\n");
        this.print("  │" ++ C.bold ++ C.bcyan ++ "      Sensor Status       " ++ C.reset ++ C.cyan ++ "│\n");
        this.print("  ├──────────────────────────┤\n");

        this.print("  │ " ++ C.gray ++ "Ready:" ++ C.reset ++ "  ");

        if (this.sensor.mmio().ready()) {
            this.print(C.bgreen ++ "YES" ++ C.reset ++ "              ");
        } else {
            this.print(C.byellow ++ "NO" ++ C.reset ++ "               ");
        }

        this.print(C.cyan ++ "│\n");

        this.printFmt("  │ " ++ C.gray ++ "Reads:" ++ C.reset ++ "  " ++ C.bwhite ++ "{d: <16} " ++ C.reset ++ C.cyan ++ "│\n", .{this.read_count});

        this.print("  ├──────────────────────────┤\n");
        this.print("  │ " ++ C.gray ++ "Ray Detection:" ++ C.reset ++ "           " ++ C.cyan ++ "│\n");

        const rays = this.sensor.mmio().config().rays;

        this.print("  │   " ++ C.gray ++ "Alpha:" ++ C.reset ++ "   ");

        if (rays.alpha) {
            this.print(C.bgreen ++ "ON" ++ C.reset ++ "           ");
        } else {
            this.print(C.bred ++ "OFF" ++ C.reset ++ "           ");
        }

        this.print(C.cyan ++ "│\n");

        this.print("  │   " ++ C.gray ++ "Beta:" ++ C.reset ++ "    ");
        if (rays.beta) {
            this.print(C.bgreen ++ "ON" ++ C.reset ++ "           ");
        } else {
            this.print(C.bred ++ "OFF" ++ C.reset ++ "           ");
        }

        this.print(C.cyan ++ "│\n");

        this.print("  │   " ++ C.gray ++ "Hawking:" ++ C.reset ++ " ");

        if (rays.hawking) {
            this.print(C.bgreen ++ "ON" ++ C.reset ++ "           ");
        } else {
            this.print(C.bred ++ "OFF" ++ C.reset ++ "           ");
        }

        this.print(C.cyan ++ "│\n");

        this.print("  └──────────────────────────┘" ++ C.reset ++ "\n\n");
    }

    inline fn printPrompt(this: *Shell) void {
        this.print(C.cyan ++ "env" ++ C.bcyan ++ ":sensor" ++ C.bwhite ++ "$ " ++ C.reset);
    }

    inline fn print(this: *Shell, text: []const u8) void {
        this.writer.interface.writeAll(text) catch {};
    }

    inline fn printFmt(this: *Shell, comptime fmt: []const u8, args: anytype) void {
        this.writer.interface.print(fmt, args) catch {};
    }

    inline fn flush(this: *Shell) void {
        this.writer.flush() catch {};
    }
};

pub fn main() void {
    const terminal = SerialTerminal.find() orelse return;
    const sensor = EnvSensor.find() orelse return;

    var shell = Shell.init(terminal, sensor);
    shell.run();
}

comptime {
    _ = sdk.utils.EntryPoint(.{
        .stack_size = std.math.pow(u32, 2, 14),
    });
}
