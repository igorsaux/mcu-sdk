const std = @import("std");
const sdk = @import("mcu_sdk");

const SerialTerminal = struct {
    entry: sdk.Pci.Entry,
    slot: u8 = 0,

    pub inline fn mmio(this: SerialTerminal) *volatile sdk.SerialTerminal {
        return @ptrFromInt(this.entry.address);
    }
};

inline fn getSerialTerminal() ?SerialTerminal {
    for (&sdk.pci.status().entries, 0..) |entry, slot| {
        if (entry.ty != .serial_terminal) {
            continue;
        }

        return .{
            .entry = entry,
            .slot = @intCast(slot),
        };
    }

    return null;
}

// ANSI escape codes
const C = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const italic = "\x1b[3m";

    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const cyan = "\x1b[36m";
    const white = "\x1b[37m";

    const bred = "\x1b[91m";
    const bgreen = "\x1b[92m";
    const byellow = "\x1b[93m";
    const bcyan = "\x1b[96m";
    const bwhite = "\x1b[97m";
};

const Shell = struct {
    terminal: SerialTerminal,
    writer: sdk.utils.SerialTerminalWriter,
    out_buffer: [sdk.SerialTerminal.OUTPUT_BUFFER_SIZE]u8,
    cmd_count: u32,
    start_time_ns: u64,

    pub fn init(terminal: SerialTerminal) Shell {
        var shell = Shell{
            .terminal = terminal,
            .writer = undefined,
            .out_buffer = undefined,
            .cmd_count = 0,
            .start_time_ns = sdk.clint.readMtimeNs(),
        };

        shell.writer = .init(terminal.slot, terminal.mmio(), &shell.out_buffer);

        return shell;
    }

    pub fn run(this: *Shell) void {
        sdk.arch.Mie.setMeie();
        this.terminal.mmio().interrupts().on_new_data = true;

        this.printWelcome();

        while (true) {
            if (this.terminal.mmio().lastEvent()) |event| {
                this.terminal.mmio().ack();

                if (event.ty == .new_data) {
                    this.handleInput();
                }
            }

            sdk.arch.wfi();
        }
    }

    fn printWelcome(this: *Shell) void {
        this.print("\n" ++ C.bold ++ C.cyan);
        this.print("  _   _ _____   ____  _          _ _ \n");
        this.print(" | \\ | |_   _| / ___|| |__   ___| | |\n");
        this.print(" |  \\| | | |   \\___ \\| '_ \\ / _ \\ | |\n");
        this.print(" | |\\  | | |    ___) | | | |  __/ | |\n");
        this.print(" |_| \\_| |_|   |____/|_| |_|\\___|_|_|\n");
        this.print(C.reset ++ "\n");
        this.print(C.bwhite ++ "NanoTrasen Microcontroller Shell " ++ C.green ++ "v1.0" ++ C.reset ++ "\n");
        this.print(C.dim ++ "Type 'help' for available commands." ++ C.reset ++ "\n\n");
        this.printPrompt();
        this.flush();
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
        this.cmd_count += 1;
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

        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |space_idx| {
            cmd = trimmed[0..space_idx];
            args = trimmed[space_idx + 1 ..];

            while (args.len > 0 and args[0] == ' ') {
                args = args[1..];
            }
        }

        if (std.mem.eql(u8, cmd, "help")) {
            this.cmdHelp();
        } else if (std.mem.eql(u8, cmd, "echo")) {
            this.cmdEcho(args);
        } else if (std.mem.eql(u8, cmd, "cowsay")) {
            this.cmdCowsay(args);
        } else if (std.mem.eql(u8, cmd, "fortune")) {
            this.cmdFortune();
        } else if (std.mem.eql(u8, cmd, "8ball")) {
            this.cmd8Ball();
        } else if (std.mem.eql(u8, cmd, "dice")) {
            this.cmdDice(args);
        } else if (std.mem.eql(u8, cmd, "uptime")) {
            this.cmdUptime();
        } else if (std.mem.eql(u8, cmd, "stats")) {
            this.cmdStats();
        } else if (std.mem.eql(u8, cmd, "bee")) {
            this.cmdBee();
        } else if (std.mem.eql(u8, cmd, "honk")) {
            this.cmdHonk();
        } else if (std.mem.eql(u8, cmd, "spess")) {
            this.cmdSpess();
        } else {
            this.print(C.red ++ "Unknown command: " ++ C.reset);
            this.print(C.yellow);
            this.print(cmd);
            this.print(C.reset ++ "\nType " ++ C.cyan ++ "'help'" ++ C.reset ++ " for available commands.\n");
        }
    }

    fn cmdHelp(this: *Shell) void {
        this.print("\n" ++ C.bold ++ C.bwhite ++ "Available commands:" ++ C.reset ++ "\n\n");
        this.print(C.cyan ++ "  help" ++ C.reset ++ "          - Show this help\n");
        this.print(C.cyan ++ "  echo" ++ C.reset ++ " <text>   - Echo text back\n");
        this.print(C.cyan ++ "  cowsay" ++ C.reset ++ " <text> - Cow says something\n");
        this.print(C.cyan ++ "  fortune" ++ C.reset ++ "       - Random wisdom\n");
        this.print(C.cyan ++ "  8ball" ++ C.reset ++ "         - Ask the magic 8-ball\n");
        this.print(C.cyan ++ "  dice" ++ C.reset ++ " [N]      - Roll a dice (default: d6)\n");
        this.print(C.cyan ++ "  uptime" ++ C.reset ++ "        - Show uptime\n");
        this.print(C.cyan ++ "  stats" ++ C.reset ++ "         - Shell statistics\n");
        this.print(C.cyan ++ "  bee" ++ C.reset ++ "           - Bee movie?\n");
        this.print(C.cyan ++ "  honk" ++ C.reset ++ "          - HONK!\n");
        this.print(C.cyan ++ "  spess" ++ C.reset ++ "         - Space travel\n");
        this.print("\n");
    }

    fn cmdEcho(this: *Shell, args: []const u8) void {
        if (args.len == 0) {
            this.print("\n");
        } else {
            this.print(args);
            this.print("\n");
        }
    }

    fn cmdCowsay(this: *Shell, args: []const u8) void {
        const text = if (args.len == 0) "Moo!" else args;

        this.print(C.bwhite ++ " ");
        for (0..text.len + 2) |_| {
            this.print("_");
        }
        this.print("\n< " ++ C.byellow);
        this.print(text);
        this.print(C.bwhite ++ " >\n ");
        for (0..text.len + 2) |_| {
            this.print("-");
        }
        this.print(C.reset ++ "\n");

        this.print(C.yellow);
        this.print("        \\   ^__^\n");
        this.print("         \\  (oo)\\_______\n");
        this.print("            (__)\\       )\\/\\\n");
        this.print("                ||----w |\n");
        this.print("                ||     ||\n");
        this.print(C.reset);
    }

    fn cmdFortune(this: *Shell) void {
        const fortunes = [_][]const u8{
            C.magenta ++ "The singularity is closer than you think." ++ C.reset,
            C.bred ++ "Plasma is just spicy air." ++ C.reset,
            C.yellow ++ "The clown is not the impostor. Or is he?" ++ C.reset,
            C.red ++ "Have you checked the toxins lab lately?" ++ C.reset,
            C.bred ++ "Security is just a suggestion." ++ C.reset,
            C.cyan ++ "The AI has your best interests at heart. Probably." ++ C.reset,
            C.blue ++ "Space is cold. Wear a jacket." ++ C.reset,
            C.byellow ++ "Cargo ordered what? Oh no." ++ C.reset,
            C.bcyan ++ "The captain is always right. Until they're not." ++ C.reset,
            C.green ++ "Chemistry: turning plants into war crimes since 2550." ++ C.reset,
            C.bwhite ++ "The shuttle has been called. 10 minutes remain." ++ C.reset,
            C.magenta ++ "Atmospherics: we swear the plasma leak wasn't us." ++ C.reset,
            C.dim ++ "Maintenance: where dreams go to die." ++ C.reset,
            C.bred ++ "NT HR reminder: eating your coworkers is not allowed." ++ C.reset,
            C.bgreen ++ "The changeling could be anyone. Even you." ++ C.reset,
        };

        const idx = sdk.prng.status().value % fortunes.len;
        this.print("\n  " ++ C.dim ++ "\"" ++ C.reset);
        this.print(fortunes[idx]);
        this.print(C.dim ++ "\"" ++ C.reset ++ "\n\n");
    }

    fn cmd8Ball(this: *Shell) void {
        const answers = [_][]const u8{
            C.bgreen ++ "It is certain." ++ C.reset,
            C.bgreen ++ "Without a doubt." ++ C.reset,
            C.green ++ "Yes, definitely." ++ C.reset,
            C.yellow ++ "Reply hazy, try again." ++ C.reset,
            C.yellow ++ "Ask again later." ++ C.reset,
            C.byellow ++ "Cannot predict now." ++ C.reset,
            C.red ++ "Don't count on it." ++ C.reset,
            C.bred ++ "My reply is no." ++ C.reset,
            C.red ++ "Very doubtful." ++ C.reset,
            C.magenta ++ "The gods say: HONK!" ++ C.reset,
            C.bred ++ "Signs point to plasma fire." ++ C.reset,
            C.cyan ++ "The AI says: Maybe." ++ C.reset,
            C.red ++ "Outlook not so good." ++ C.reset,
            C.green ++ "It is decidedly so." ++ C.reset,
            C.dim ++ "Better not tell you now." ++ C.reset,
        };

        const idx = sdk.prng.status().value % answers.len;
        this.print("\n  " ++ C.bold ++ C.magenta ++ "8-ball: " ++ C.reset);
        this.print(answers[idx]);
        this.print("\n\n");
    }

    fn cmdDice(this: *Shell, args: []const u8) void {
        var sides: u32 = 6;

        if (args.len > 0) {
            sides = 0;
            for (args) |c| {
                if (c >= '0' and c <= '9') {
                    sides = sides * 10 + (c - '0');
                } else {
                    break;
                }
            }
            if (sides == 0) sides = 6;
            if (sides > 100) sides = 100;
        }

        const roll = (sdk.prng.status().value % @as(u8, @truncate(sides))) + 1;

        this.print("\n  " ++ C.bold ++ C.white ++ "Rolling d");
        this.printNumber(sides);
        this.print("... " ++ C.bcyan);
        this.printNumber(roll);
        this.print(C.reset ++ "!\n\n");
    }

    fn cmdUptime(this: *Shell) void {
        const now_ns = sdk.clint.readMtimeNs();
        const elapsed_ns = now_ns - this.start_time_ns;

        const seconds = elapsed_ns / std.time.ns_per_s;
        const minutes = seconds / 60;
        const hours = minutes / 60;

        this.print("\n  " ++ C.bold ++ C.green ++ "Uptime: " ++ C.reset ++ C.bwhite);
        this.printNumber(@truncate(hours));
        this.print(C.dim ++ "h " ++ C.reset ++ C.bwhite);
        this.printNumber(@truncate(minutes % 60));
        this.print(C.dim ++ "m " ++ C.reset ++ C.bwhite);
        this.printNumber(@truncate(seconds % 60));
        this.print(C.dim ++ "s" ++ C.reset ++ "\n\n");
    }

    fn cmdStats(this: *Shell) void {
        this.print("\n  " ++ C.bold ++ C.cyan ++ "=== Shell Statistics ===" ++ C.reset ++ "\n");
        this.print("  Commands executed: " ++ C.byellow);
        this.printNumber(this.cmd_count);
        this.print(C.reset ++ "\n");
        this.print("  Terminal slot: " ++ C.bcyan);
        this.printNumber(this.terminal.slot);
        this.print(C.reset ++ "\n\n");
    }

    fn cmdBee(this: *Shell) void {
        this.print("\n" ++ C.yellow);
        this.print("      \\ ` /\n");
        this.print("    _- `---` -_\n");
        this.print(C.byellow);
        this.print("   /  ## # ##  \\\n");
        this.print("  |  #### ####  |\n");
        this.print("  | ########### |\n");
        this.print("   \\  ## # ##  /\n");
        this.print(C.yellow);
        this.print("    -_  ###  _-   " ++ C.dim ++ "BZZZzzz..." ++ C.reset ++ "\n");
        this.print(C.yellow ++ "      `-----`\n" ++ C.reset);
        this.print("\n" ++ C.italic ++ C.bwhite);
        this.print("  According to all known laws of aviation,\n");
        this.print("  there is no way a bee should be able to fly.\n");
        this.print(C.reset ++ "\n");
    }

    fn cmdHonk(this: *Shell) void {
        this.print("\n" ++ C.bold ++ C.magenta);
        this.print("  ██╗  ██╗ ██████╗ ███╗   ██╗██╗  ██╗██╗\n");
        this.print(C.byellow);
        this.print("  ██║  ██║██╔═══██╗████╗  ██║██║ ██╔╝██║\n");
        this.print(C.magenta);
        this.print("  ███████║██║   ██║██╔██╗ ██║█████╔╝ ██║\n");
        this.print(C.byellow);
        this.print("  ██╔══██║██║   ██║██║╚██╗██║██╔═██╗ ╚═╝\n");
        this.print(C.magenta);
        this.print("  ██║  ██║╚██████╔╝██║ ╚████║██║  ██╗██╗\n");
        this.print(C.byellow);
        this.print("  ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝\n");
        this.print(C.reset ++ "\n");
        this.print("        " ++ C.bold ++ C.byellow ++ "THE HONKMOTHER BLESSES YOU" ++ C.reset ++ "\n\n");
    }

    fn cmdSpess(this: *Shell) void {
        this.print("\n" ++ C.bwhite);
        this.print("                  " ++ C.byellow ++ "." ++ C.bwhite ++ "  *  " ++ C.byellow ++ "." ++ C.bwhite ++ "   .    *\n");
        this.print("       *   " ++ C.byellow ++ "." ++ C.bwhite ++ "        .        .        .\n");
        this.print("    .    *    " ++ C.cyan ++ "___---___" ++ C.bwhite ++ "    .     *\n");
        this.print("         .  " ++ C.bcyan ++ "/\\         /\\" ++ C.bwhite ++ "     .\n");
        this.print("  .        " ++ C.bcyan ++ "/  \\  " ++ C.bold ++ C.blue ++ "NT" ++ C.reset ++ C.bcyan ++ "   /  \\" ++ C.bwhite ++ "        *\n");
        this.print("       *  " ++ C.bcyan ++ "|    \\_____/    |" ++ C.bwhite ++ "  .\n");
        this.print("    .     " ++ C.cyan ++ "|    [     ]    |" ++ C.bwhite ++ "      .\n");
        this.print("          " ++ C.cyan ++ "|______|_|______|" ++ C.bwhite ++ "   *\n");
        this.print("      *         " ++ C.bred ++ "| |" ++ C.bwhite ++ "           .\n");
        this.print("          .    " ++ C.red ++ "/   \\" ++ C.bwhite ++ "     .\n");
        this.print("   .   *      " ++ C.byellow ++ "/_____\\" ++ C.bwhite ++ "         *\n");
        this.print("                          .       .\n");
        this.print(C.reset ++ "\n" ++ C.italic ++ C.bcyan);
        this.print("    \"Space... the final frontier.\"\n");
        this.print(C.reset ++ "\n");
    }

    inline fn printPrompt(this: *Shell) void {
        this.print(C.bold ++ C.green ++ "NT" ++ C.reset ++ C.cyan ++ "> " ++ C.reset);
    }

    inline fn print(this: *Shell, text: []const u8) void {
        this.writer.interface.writeAll(text) catch {};
    }

    inline fn printNumber(this: *Shell, n: u32) void {
        this.writer.interface.print("{}", .{n}) catch {};
    }

    inline fn flush(this: *Shell) void {
        this.writer.flush() catch {};
    }
};

pub fn main() void {
    const terminal = getSerialTerminal() orelse return;
    var shell = Shell.init(terminal);

    shell.run();
}

comptime {
    _ = sdk.utils.EntryPoint(.{
        .stack_size = std.math.pow(u32, 2, 14),
    });
}
