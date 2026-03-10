const std = @import("std");

const sdk = @import("mcu_sdk");

const SerialTerminal = sdk.utils.PciDevice(sdk.SerialTerminal, .serial_terminal);

// ANSI escape codes
const C = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const italic = "\x1b[3m";
    const blink = "\x1b[5m";
    const reverse = "\x1b[7m";

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

    const bg_red = "\x1b[41m";
    const bg_green = "\x1b[42m";
    const bg_yellow = "\x1b[43m";
    const bg_blue = "\x1b[44m";
    const bg_magenta = "\x1b[45m";
    const bg_cyan = "\x1b[46m";
    const bg_white = "\x1b[47m";

    // Cursor control
    const hide_cursor = "\x1b[?25l";
    const show_cursor = "\x1b[?25h";
    const clear_screen = "\x1b[2J\x1b[H";
    const clear_line = "\x1b[2K";
    const save_cursor = "\x1b7";
    const restore_cursor = "\x1b8";
};

// Key codes for raw mode
const Key = struct {
    const ESC: u8 = 0x1b;
    const ENTER: u8 = 0x0d;
    const BACKSPACE: u8 = 0x7f;
    const BACKSPACE_ALT: u8 = 0x08;
    const TAB: u8 = 0x09;
    const SPACE: u8 = 0x20;

    // Arrow key sequences: ESC [ A/B/C/D
    fn isArrowUp(bytes: []const u8) bool {
        return bytes.len == 3 and bytes[0] == 0x1b and bytes[1] == '[' and bytes[2] == 'A';
    }
    fn isArrowDown(bytes: []const u8) bool {
        return bytes.len == 3 and bytes[0] == 0x1b and bytes[1] == '[' and bytes[2] == 'B';
    }
    fn isArrowRight(bytes: []const u8) bool {
        return bytes.len == 3 and bytes[0] == 0x1b and bytes[1] == '[' and bytes[2] == 'C';
    }
    fn isArrowLeft(bytes: []const u8) bool {
        return bytes.len == 3 and bytes[0] == 0x1b and bytes[1] == '[' and bytes[2] == 'D';
    }
};

const Shell = struct {
    terminal: SerialTerminal,
    writer: sdk.utils.SerialTerminalWriter,
    out_buffer: []u8,
    input_buffer: []u8,
    cmd_count: u32,
    start_time_ns: u64,
    pending_input: []u8,
    pending_len: usize = 0,
    pending_pos: usize = 0,

    pub fn init(terminal: SerialTerminal, out_buffer: []u8, input_buffer: []u8) Shell {
        var shell = Shell{
            .terminal = terminal,
            .writer = undefined,
            .out_buffer = out_buffer,
            .input_buffer = input_buffer,
            .cmd_count = 0,
            .start_time_ns = sdk.clint.readMtimeNs(),
            .pending_input = input_buffer,
        };

        shell.writer = .init(terminal.slot, terminal.mmio(), out_buffer);

        return shell;
    }

    pub fn run(this: *Shell) void {
        sdk.arch.Mie.setMeie();
        this.terminal.mmio().interrupts().on_new_data = true;

        this.printWelcome();

        while (true) {
            if (this.terminal.mmio().lastEvent()) |event| {
                const len = this.terminal.mmio().len();
                this.terminal.mmio().ack();

                if (event.ty == .new_data) {
                    this.handleInput(len);
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

    fn handleInput(this: *Shell, bytes: u16) void {
        sdk.dma.read(this.terminal.slot, 0, this.input_buffer[0..bytes]);

        var input = this.input_buffer[0..bytes];
        while (input.len > 0 and (input[input.len - 1] == '\n' or input[input.len - 1] == '\r')) {
            input = input[0 .. input.len - 1];
        }

        this.executeCommand(input);
        this.cmd_count += 1;
        this.printPrompt();
        this.flush();
    }

    /// Read raw input (for raw mode commands)
    fn readRawInput(this: *Shell) ?[]u8 {
        if (this.terminal.mmio().lastEvent()) |event| {
            const bytes = this.terminal.mmio().len();
            this.terminal.mmio().ack();

            if (event.ty == .new_data) {
                sdk.dma.read(this.terminal.slot, 0, this.input_buffer[0..bytes]);
                return this.input_buffer[0..bytes];
            }
        }
        return null;
    }

    /// Parse the length of one key/escape sequence from buffer
    fn parseKeyLength(buf: []const u8) usize {
        if (buf.len == 0) {
            return 0;
        }

        // ESC sequence
        if (buf[0] == 0x1b) {
            if (buf.len == 1) {
                // Just ESC
                return 1;
            }

            if (buf[1] == '[') {
                // CSI sequence: ESC [ ... final_byte (0x40-0x7E)
                var i: usize = 2;

                while (i < buf.len) : (i += 1) {
                    const c = buf[i];

                    if (c >= 0x40 and c <= 0x7E) {
                        return i + 1;
                    }
                }
                // Incomplete sequence - return what we have
                return buf.len;
            } else if (buf[1] == 'O') {
                // SS3 sequence: ESC O char (for F1-F4 on some terminals)
                return if (buf.len >= 3) 3 else buf.len;
            } else {
                // Alt+key: ESC char
                return 2;
            }
        }

        // Regular character (including UTF-8 would need more logic)
        return 1;
    }

    /// Read ONE key/sequence from raw input
    /// Returns slice to the key bytes, or null if no input available
    fn readRawKey(this: *Shell) ?[]const u8 {
        // First check if we have pending data from previous read
        if (this.pending_pos < this.pending_len) {
            const remaining = this.pending_input[this.pending_pos..this.pending_len];
            const key_len = parseKeyLength(remaining);

            if (key_len > 0) {
                const result = remaining[0..key_len];
                this.pending_pos += key_len;
                return result;
            }
        }

        // No pending data, check for new input
        if (this.terminal.mmio().lastEvent()) |event| {
            if (event.ty == .new_data) {
                const bytes = this.terminal.mmio().len();
                sdk.dma.read(this.terminal.slot, 0, this.input_buffer[0..bytes]);
                this.terminal.mmio().ack();

                this.pending_input = this.input_buffer;
                this.pending_len = bytes;
                this.pending_pos = 0;

                // Now parse the first key
                const key_len = parseKeyLength(this.input_buffer[0..bytes]);

                if (key_len > 0) {
                    this.pending_pos = key_len;
                    return this.input_buffer[0..key_len];
                }
            } else {
                this.terminal.mmio().ack();
            }
        }

        return null;
    }

    /// Clear pending input buffer (call when exiting raw mode)
    fn clearPendingInput(this: *Shell) void {
        this.pending_len = 0;
        this.pending_pos = 0;
    }

    /// Check if there's more pending input to process
    fn hasPendingInput(this: *Shell) bool {
        return this.pending_pos < this.pending_len;
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
        } else if (std.mem.eql(u8, cmd, "keys")) {
            this.cmdKeys();
        } else if (std.mem.eql(u8, cmd, "draw")) {
            this.cmdDraw();
        } else if (std.mem.eql(u8, cmd, "type")) {
            this.cmdType();
        } else {
            this.print(C.red ++ "Unknown command: " ++ C.reset);
            this.print(C.yellow);
            this.print(cmd);
            this.print(C.reset ++ "\nType " ++ C.cyan ++ "'help'" ++ C.reset ++ " for available commands.\n");
        }
    }

    fn cmdHelp(this: *Shell) void {
        this.print("\n" ++ C.bold ++ C.bwhite ++ "Available commands:" ++ C.reset ++ "\n\n");

        this.print(C.bold ++ C.yellow ++ " Standard:" ++ C.reset ++ "\n");
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

        this.print("\n" ++ C.bold ++ C.magenta ++ " Interactive (Raw Mode):" ++ C.reset ++ "\n");
        this.print(C.bcyan ++ "  keys" ++ C.reset ++ "          - Show key codes in real-time\n");
        this.print(C.bcyan ++ "  draw" ++ C.reset ++ "          - ASCII art drawing canvas\n");
        this.print(C.bcyan ++ "  type" ++ C.reset ++ "          - Typing speed test\n");

        this.print("\n");
    }

    /// Shows key codes in real-time — perfect demonstration of raw mode
    fn cmdKeys(this: *Shell) void {
        this.terminal.mmio().setRawMode(true);
        this.clearPendingInput();

        this.print("\x1b[?1049h");
        this.print("\x1b[2J\x1b[H");

        this.print(C.bold ++ C.cyan ++ "╔═══════════════════════════════════════════╗\n");
        this.print("║         KEY CODE VIEWER (Raw Mode)        ║\n");
        this.print("╚═══════════════════════════════════════════╝" ++ C.reset ++ "\n\n");
        this.print(C.dim ++ "Press any key to see its code.\n");
        this.print("Try: arrows, Ctrl+C, Tab, Enter, etc.\n");
        this.print("Press " ++ C.reset ++ C.bold ++ "ESC twice" ++ C.reset ++ C.dim ++ " to exit.\n\n" ++ C.reset);
        this.print(C.yellow ++ "─────────────────────────────────────────────" ++ C.reset ++ "\n");
        this.flush();

        var esc_count: u8 = 0;
        var key_num: u32 = 0;

        outer: while (true) {
            while (this.readRawKey()) |bytes| {
                // Check for double ESC
                if (bytes.len == 1 and bytes[0] == Key.ESC) {
                    esc_count += 1;

                    if (esc_count >= 2) {
                        break :outer;
                    }
                } else {
                    esc_count = 0;
                }

                key_num += 1;

                // Print key number
                this.print(C.dim ++ "#");
                this.printNumber(key_num);
                this.print(" " ++ C.reset);

                // Print hex bytes
                this.print(C.yellow ++ "[" ++ C.reset);
                for (bytes, 0..) |b, i| {
                    if (i > 0) {
                        this.print(" ");
                    }

                    this.printHex(b);
                }
                this.print(C.yellow ++ "]" ++ C.reset);

                // Print interpretation
                this.print(C.cyan ++ " → " ++ C.reset);
                this.interpretKey(bytes);
                this.print("\n");
                this.flush();
            }

            sdk.arch.wfi();
        }

        this.print("\x1b[?1049l");
        this.flush();

        this.terminal.mmio().setRawMode(false);
        this.clearPendingInput();

        this.print(C.green ++ "✓ Exited key viewer." ++ C.reset ++ "\n");
    }

    fn interpretKey(this: *Shell, bytes: []const u8) void {
        if (bytes.len == 0) return;

        if (bytes.len == 1) {
            const b = bytes[0];
            switch (b) {
                0x1b => this.print(C.magenta ++ "ESC" ++ C.reset ++ C.dim ++ " (press again to exit)" ++ C.reset),
                0x0d, 0x0a => this.print(C.bgreen ++ "Enter" ++ C.reset),
                0x7f, 0x08 => this.print(C.bred ++ "Backspace" ++ C.reset),
                0x09 => this.print(C.byellow ++ "Tab" ++ C.reset),
                0x20 => this.print(C.bwhite ++ "Space" ++ C.reset),
                0x00 => this.print(C.red ++ "Ctrl+@/NUL" ++ C.reset),
                0x01...0x07, 0x0b...0x0c, 0x0e...0x1a => {
                    this.print(C.bcyan ++ "Ctrl+" ++ C.reset ++ C.bold);
                    var buf: [1]u8 = .{'A' + b - 1};
                    this.print(&buf);
                    this.print(C.reset);
                },
                0x21...0x7e => {
                    this.print(C.bwhite ++ "'" ++ C.reset ++ C.bold ++ C.green);
                    var buf: [1]u8 = .{b};
                    this.print(&buf);
                    this.print(C.reset ++ C.bwhite ++ "'" ++ C.reset);
                },
                else => {
                    this.print(C.dim ++ "byte 0x" ++ C.reset);
                    this.printHex(b);
                },
            }
        } else if (bytes.len >= 3 and bytes[0] == 0x1b and bytes[1] == '[') {
            // CSI sequences
            if (bytes.len == 3) {
                switch (bytes[2]) {
                    'A' => this.print(C.bgreen ++ "↑ Arrow Up" ++ C.reset),
                    'B' => this.print(C.bgreen ++ "↓ Arrow Down" ++ C.reset),
                    'C' => this.print(C.bgreen ++ "→ Arrow Right" ++ C.reset),
                    'D' => this.print(C.bgreen ++ "← Arrow Left" ++ C.reset),
                    'H' => this.print(C.byellow ++ "Home" ++ C.reset),
                    'F' => this.print(C.byellow ++ "End" ++ C.reset),
                    else => this.print(C.dim ++ "CSI sequence" ++ C.reset),
                }
            } else if (bytes.len == 4 and bytes[3] == '~') {
                switch (bytes[2]) {
                    '1' => this.print(C.byellow ++ "Home" ++ C.reset),
                    '2' => this.print(C.byellow ++ "Insert" ++ C.reset),
                    '3' => this.print(C.bred ++ "Delete" ++ C.reset),
                    '4' => this.print(C.byellow ++ "End" ++ C.reset),
                    '5' => this.print(C.bcyan ++ "Page Up" ++ C.reset),
                    '6' => this.print(C.bcyan ++ "Page Down" ++ C.reset),
                    else => this.print(C.dim ++ "CSI sequence" ++ C.reset),
                }
            } else {
                this.print(C.dim ++ "CSI sequence (" ++ C.reset);
                this.printNumber(@truncate(bytes.len));
                this.print(C.dim ++ " bytes)" ++ C.reset);
            }
        } else if (bytes.len == 2 and bytes[0] == 0x1b) {
            // Alt+key
            this.print(C.magenta ++ "Alt+" ++ C.reset);

            if (bytes[1] >= 0x20 and bytes[1] < 0x7f) {
                var buf: [1]u8 = .{bytes[1]};
                this.print(C.bold);
                this.print(&buf);
                this.print(C.reset);
            } else {
                this.print(C.dim ++ "0x" ++ C.reset);
                this.printHex(bytes[1]);
            }
        } else {
            this.print(C.dim ++ "sequence (" ++ C.reset);
            this.printNumber(@truncate(bytes.len));
            this.print(C.dim ++ " bytes)" ++ C.reset);
        }
    }

    /// ASCII drawing canvas with cursor control
    fn cmdDraw(this: *Shell) void {
        const WIDTH: u8 = 40;
        const HEIGHT: u8 = 15;

        this.terminal.mmio().setRawMode(true);
        this.clearPendingInput(); // Clear any stale input

        this.print("\x1b[?1049h"); // Enter alternate screen
        this.print("\x1b[2J\x1b[H"); // Clear and home
        this.print(C.hide_cursor);

        var canvas: [HEIGHT][WIDTH]u8 = undefined;
        for (&canvas) |*row| {
            @memset(row, ' ');
        }

        var cursor_x: u8 = WIDTH / 2;
        var cursor_y: u8 = HEIGHT / 2;
        var brush: u8 = '*';
        var drawing = false;

        const brushes = [_]u8{ '*', '#', '@', 'O', '+', '.', '~', '=' };
        var brush_idx: u8 = 0;

        this.drawCanvas(&canvas, cursor_x, cursor_y, brush, drawing);
        this.flush();

        var should_exit = false;

        outer: while (!should_exit) {
            // Process ALL pending keys before waiting
            var redraw = false;

            while (this.readRawKey()) |bytes| {
                if (bytes.len == 1) {
                    switch (bytes[0]) {
                        Key.ESC => {
                            should_exit = true;
                            break :outer;
                        },
                        Key.SPACE => {
                            drawing = !drawing;
                            redraw = true;
                        },
                        'c', 'C' => {
                            for (&canvas) |*row| {
                                @memset(row, ' ');
                            }

                            redraw = true;
                        },
                        'b', 'B' => {
                            brush_idx = (brush_idx + 1) % @as(u8, @intCast(brushes.len));
                            brush = brushes[brush_idx];
                            redraw = true;
                        },
                        'f', 'F' => {
                            canvas[cursor_y][cursor_x] = brush;
                            redraw = true;
                        },
                        else => {},
                    }
                } else if (Key.isArrowUp(bytes)) {
                    if (cursor_y > 0) {
                        cursor_y -= 1;
                    }

                    if (drawing) {
                        canvas[cursor_y][cursor_x] = brush;
                    }

                    redraw = true;
                } else if (Key.isArrowDown(bytes)) {
                    if (cursor_y < HEIGHT - 1) {
                        cursor_y += 1;
                    }
                    if (drawing) {
                        canvas[cursor_y][cursor_x] = brush;
                    }

                    redraw = true;
                } else if (Key.isArrowLeft(bytes)) {
                    if (cursor_x > 0) {
                        cursor_x -= 1;
                    }
                    if (drawing) {
                        canvas[cursor_y][cursor_x] = brush;
                    }

                    redraw = true;
                } else if (Key.isArrowRight(bytes)) {
                    if (cursor_x < WIDTH - 1) {
                        cursor_x += 1;
                    }

                    if (drawing) {
                        canvas[cursor_y][cursor_x] = brush;
                    }

                    redraw = true;
                }

                // If no more pending input, break to redraw
                if (!this.hasPendingInput()) {
                    break;
                }
            }

            if (redraw) {
                this.print("\x1b[H"); // Move to top
                this.drawCanvas(&canvas, cursor_x, cursor_y, brush, drawing);
                this.flush();
            }

            // Only wait if we've processed everything
            if (!this.hasPendingInput()) {
                sdk.arch.wfi();
            }
        }

        this.print(C.show_cursor);
        this.print("\x1b[?1049l");
        this.flush();

        this.terminal.mmio().setRawMode(false);
        this.clearPendingInput();

        this.print(C.green ++ "✓ Exited drawing mode." ++ C.reset ++ "\n");
    }

    fn drawCanvas(this: *Shell, canvas: *const [15][40]u8, cx: u8, cy: u8, brush: u8, drawing: bool) void {
        this.print(C.bold ++ C.cyan ++ "╔══════════════════════════════════════════╗\n");
        this.print("║           ASCII DRAWING CANVAS           ║\n");
        this.print("╚══════════════════════════════════════════╝" ++ C.reset ++ "\n");

        this.print(C.yellow ++ "┌");

        for (0..40) |_| {
            this.print("─");
        }

        this.print("┐" ++ C.reset ++ "\n");

        for (canvas, 0..) |row, y| {
            this.print(C.yellow ++ "│" ++ C.reset);

            for (row, 0..) |cell, x| {
                if (x == cx and y == cy) {
                    if (drawing) {
                        this.print(C.bg_green ++ C.bold);
                    } else {
                        this.print(C.bg_blue ++ C.bold);
                    }

                    var buf: [1]u8 = .{brush};

                    this.print(&buf);
                    this.print(C.reset);
                } else if (cell != ' ') {
                    this.print(C.bwhite);

                    var buf: [1]u8 = .{cell};

                    this.print(&buf);
                    this.print(C.reset);
                } else {
                    this.print(" ");
                }
            }

            this.print(C.yellow ++ "│" ++ C.reset ++ "\n");
        }

        this.print(C.yellow ++ "└");

        for (0..40) |_| {
            this.print("─");
        }

        this.print("┘" ++ C.reset ++ "\n");

        this.print(C.dim ++ "Arrows:" ++ C.reset ++ " move  ");
        this.print(C.dim ++ "Space:" ++ C.reset);

        if (drawing) {
            this.print(C.bgreen ++ " DRAWING" ++ C.reset);
        } else {
            this.print(C.yellow ++ " pen up" ++ C.reset);
        }

        this.print("  " ++ C.dim ++ "B:" ++ C.reset ++ " brush[");
        var buf: [1]u8 = .{brush};
        this.print(C.bcyan);
        this.print(&buf);
        this.print(C.reset ++ "]  ");
        this.print(C.dim ++ "C:" ++ C.reset ++ " clear  ");
        this.print(C.dim ++ "ESC:" ++ C.reset ++ " exit\n");
    }

    /// Typing speed test
    fn cmdType(this: *Shell) void {
        const phrases = [_][]const u8{
            "the quick brown fox",
            "space station thirteen",
            "plasma fire in medbay",
            "clown honks loudly",
            "cargo ordered guns",
            "all crew to escape",
            "singularity loose",
            "nanotrasen approved",
        };

        const phrase = phrases[sdk.prng.status().value % phrases.len];

        this.terminal.mmio().setRawMode(true);
        this.clearPendingInput();

        this.print("\x1b[?1049h");
        this.print("\x1b[2J\x1b[H");

        this.print(C.bold ++ C.cyan ++ "╔═══════════════════════════════════════════╗\n");
        this.print("║            TYPING SPEED TEST              ║\n");
        this.print("╚═══════════════════════════════════════════╝" ++ C.reset ++ "\n\n");

        this.print(C.dim ++ "Type the following phrase:\n\n" ++ C.reset);
        this.print(C.bold ++ C.bwhite ++ "  \"");
        this.print(phrase);
        this.print("\"" ++ C.reset ++ "\n\n");
        this.print(C.dim ++ "Your input: " ++ C.reset ++ C.bold);
        this.flush();

        var typed: [64]u8 = undefined;
        var typed_len: usize = 0;
        var started = false;
        var start_time: u64 = 0;
        var cancelled = false;
        var completed = false;

        outer: while (!cancelled and !completed) {
            while (this.readRawKey()) |bytes| {
                // Process each byte in the key sequence
                for (bytes) |b| {
                    if (b == Key.ESC) {
                        cancelled = true;
                        break :outer;
                    }

                    if (!started) {
                        started = true;
                        start_time = sdk.clint.readMtimeNs();
                    }

                    if (b == Key.BACKSPACE or b == Key.BACKSPACE_ALT) {
                        if (typed_len > 0) {
                            typed_len -= 1;
                            this.print("\x08 \x08");
                        }
                    } else if (b == Key.ENTER) {
                        completed = true;
                        break :outer;
                    } else if (b >= 0x20 and b < 0x7f and typed_len < typed.len) {
                        typed[typed_len] = b;
                        typed_len += 1;

                        if (typed_len <= phrase.len and typed[typed_len - 1] == phrase[typed_len - 1]) {
                            this.print(C.bgreen);
                        } else {
                            this.print(C.bred);
                        }

                        var ch: [1]u8 = .{b};
                        this.print(&ch);
                        this.print(C.reset ++ C.bold);
                    }
                }
                this.flush();

                // Check for completion
                if (typed_len == phrase.len and std.mem.eql(u8, typed[0..typed_len], phrase)) {
                    completed = true;
                    break :outer;
                }
            }

            sdk.arch.wfi();
        }

        const end_time = sdk.clint.readMtimeNs();

        this.print("\x1b[?1049l");
        this.flush();

        this.terminal.mmio().setRawMode(false);
        this.clearPendingInput();

        if (cancelled) {
            this.print(C.yellow ++ "Test cancelled." ++ C.reset ++ "\n");

            return;
        }

        // ... rest of results display unchanged ...
        const elapsed_ms = (end_time - start_time) / std.time.ns_per_ms;
        const elapsed_s = elapsed_ms / 1000;

        const chars: u64 = phrase.len;
        const words = (chars + 4) / 5;
        var wpm: u64 = 0;

        if (elapsed_s > 0) {
            wpm = (words * 60) / elapsed_s;
        } else if (elapsed_ms > 0) {
            wpm = (words * 60 * 1000) / elapsed_ms;
        }

        var correct: usize = 0;

        for (0..@min(typed_len, phrase.len)) |i| {
            if (typed[i] == phrase[i]) correct += 1;
        }

        const accuracy = if (phrase.len > 0) (correct * 100) / phrase.len else 0;

        this.print("\n");
        this.print(C.bold ++ C.bgreen ++ "═══════════════════════════════════════════\n");
        this.print("                  RESULTS\n");
        this.print("═══════════════════════════════════════════" ++ C.reset ++ "\n\n");

        this.print("  " ++ C.cyan ++ "Time: " ++ C.reset ++ C.bwhite);
        this.printNumber(@truncate(elapsed_ms));
        this.print(C.dim ++ " ms" ++ C.reset ++ "\n");

        this.print("  " ++ C.cyan ++ "Speed: " ++ C.reset ++ C.bold);

        if (wpm >= 60) {
            this.print(C.bgreen);
        } else if (wpm >= 40) {
            this.print(C.byellow);
        } else {
            this.print(C.bred);
        }

        this.printNumber(@truncate(wpm));
        this.print(" WPM" ++ C.reset ++ "\n");

        this.print("  " ++ C.cyan ++ "Accuracy: " ++ C.reset ++ C.bold);

        if (accuracy == 100) {
            this.print(C.bgreen ++ "PERFECT! ");
        } else if (accuracy >= 90) {
            this.print(C.byellow);
        } else {
            this.print(C.bred);
        }

        this.printNumber(@truncate(accuracy));
        this.print("%" ++ C.reset ++ "\n\n");

        this.print("  ");

        if (wpm >= 80 and accuracy == 100) {
            this.print(C.bold ++ C.bgreen ++ "★★★ LEGENDARY TYPIST ★★★" ++ C.reset);
        } else if (wpm >= 60) {
            this.print(C.bold ++ C.bcyan ++ "★★ Expert Typist ★★" ++ C.reset);
        } else if (wpm >= 40) {
            this.print(C.bold ++ C.byellow ++ "★ Good Job! ★" ++ C.reset);
        } else {
            this.print(C.dim ++ "Keep practicing!" ++ C.reset);
        }

        this.print("\n\n");
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

    fn printHex(this: *Shell, byte: u8) void {
        const hex = "0123456789ABCDEF";
        var buf: [2]u8 = .{ hex[byte >> 4], hex[byte & 0x0F] };
        this.print(&buf);
    }

    inline fn flush(this: *Shell) void {
        this.writer.flush() catch {};
    }
};

pub fn main() void {
    const terminal = SerialTerminal.find() orelse return;
    var out_buffer: [sdk.SerialTerminal.OUTPUT_BUFFER_SIZE]u8 = undefined;
    var input_buffer: [sdk.SerialTerminal.INPUT_BUFFER_SIZE]u8 = undefined;

    var shell = Shell.init(terminal, &out_buffer, &input_buffer);

    shell.run();
}

comptime {
    _ = sdk.utils.EntryPoint(.{
        .stack_size = std.math.pow(u32, 2, 14),
    });
}
