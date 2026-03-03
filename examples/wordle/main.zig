const std = @import("std");

const sdk = @import("mcu_sdk");

const SerialTerminal = sdk.utils.PciDevice(sdk.SerialTerminal, .serial_terminal);

const WORDS = [_][]const u8{
    "space", "cargo", "clown", "token", "radio",
    "ghost", "laser", "medal", "virus", "plant",
    "brain", "sword", "flame", "water", "earth",
    "steel", "glass", "paper", "light", "storm",
    "robot", "alien", "blood", "power", "magic",
    "toolb", "crate", "maint", "siren", "shell",
};

const MAX_ATTEMPTS = 6;
const WORD_LENGTH = 5;

const C = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";

    const white = "\x1b[37m";
    const bwhite = "\x1b[97m";
    const gray = "\x1b[90m";
    const black = "\x1b[30m";

    const green = "\x1b[32m";
    const bgreen = "\x1b[92m";
    const yellow = "\x1b[33m";
    const byellow = "\x1b[93m";
    const red = "\x1b[31m";
    const bred = "\x1b[91m";
    const cyan = "\x1b[36m";
    const bcyan = "\x1b[96m";

    const bg_green = "\x1b[42m";
    const bg_yellow = "\x1b[43m";
    const bg_gray = "\x1b[100m";
    const bg_black = "\x1b[40m";
};

const LetterResult = enum(u8) {
    empty,
    wrong,
    misplaced,
    correct,
};

const Game = struct {
    terminal: SerialTerminal,
    writer: sdk.utils.SerialTerminalWriter,
    out_buffer: [sdk.SerialTerminal.OUTPUT_BUFFER_SIZE]u8,

    target_word: []const u8,
    attempts: u8,
    guesses: [MAX_ATTEMPTS][WORD_LENGTH]u8,
    results: [MAX_ATTEMPTS][WORD_LENGTH]LetterResult,
    game_over: bool,
    won: bool,
    shift_id: u32,

    pub fn init(terminal: SerialTerminal) Game {
        const shift_id = sdk.rtc.shiftId();
        const word_index = shift_id % WORDS.len;

        var game = Game{
            .terminal = terminal,
            .writer = undefined,
            .out_buffer = undefined,
            .target_word = WORDS[word_index],
            .attempts = 0,
            .guesses = std.mem.zeroes([MAX_ATTEMPTS][WORD_LENGTH]u8),
            .results = std.mem.zeroes([MAX_ATTEMPTS][WORD_LENGTH]LetterResult),
            .game_over = false,
            .won = false,
            .shift_id = shift_id,
        };

        game.writer = .init(terminal.slot, terminal.mmio(), &game.out_buffer);

        return game;
    }

    pub fn run(this: *Game) void {
        sdk.arch.Mie.setMeie();
        this.terminal.mmio().interrupts().on_new_data = true;

        this.printBanner();
        this.printBoard();
        this.printPrompt();
        this.flush();

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

    fn printBanner(this: *Game) void {
        this.print("\n");
        this.print(C.bgreen ++ C.bold ++ "  ╦ ╦╔═╗╦═╗╔╦╗╦  ╔═╗" ++ C.reset ++ "\n");
        this.print(C.green ++ "  ║║║║ ║╠╦╝ ║║║  ║╣ " ++ C.reset ++ "\n");
        this.print(C.dim ++ C.green ++ "  ╚╩╝╚═╝╩╚══╩╝╩═╝╚═╝" ++ C.reset ++ "\n");
        this.print("\n");
        this.print(C.gray ++ "  Guess the 5-letter word!" ++ C.reset ++ "\n");
        this.print(C.dim ++ "  " ++ C.bg_green ++ C.black ++ " A " ++ C.reset);
        this.print(C.dim ++ " correct  ");
        this.print(C.bg_yellow ++ C.black ++ " B " ++ C.reset);
        this.print(C.dim ++ " wrong place  ");
        this.print(C.bg_gray ++ C.white ++ " C " ++ C.reset);
        this.print(C.dim ++ " not in word" ++ C.reset ++ "\n");
        this.printFmt(C.gray ++ "  Shift #{}" ++ C.reset ++ "\n\n", .{this.shift_id});
    }

    fn printBoard(this: *Game) void {
        this.print(C.gray ++ "  ┌───┬───┬───┬───┬───┐" ++ C.reset ++ "\n");

        for (0..MAX_ATTEMPTS) |row| {
            this.print(C.gray ++ "  │" ++ C.reset);

            for (0..WORD_LENGTH) |col| {
                const result = this.results[row][col];
                const letter = this.guesses[row][col];

                if (letter == 0) {
                    this.print("   ");
                } else {
                    switch (result) {
                        .correct => {
                            this.print(C.bg_green ++ C.black ++ C.bold ++ " ");
                            this.printChar(std.ascii.toUpper(letter));
                            this.print(" " ++ C.reset);
                        },
                        .misplaced => {
                            this.print(C.bg_yellow ++ C.black ++ C.bold ++ " ");
                            this.printChar(std.ascii.toUpper(letter));
                            this.print(" " ++ C.reset);
                        },
                        .wrong => {
                            this.print(C.bg_gray ++ C.white ++ " ");
                            this.printChar(std.ascii.toUpper(letter));
                            this.print(" " ++ C.reset);
                        },
                        .empty => {
                            this.print(" ");
                            this.printChar(std.ascii.toUpper(letter));
                            this.print(" ");
                        },
                    }
                }

                this.print(C.gray ++ "│" ++ C.reset);
            }

            this.print("\n");

            if (row < MAX_ATTEMPTS - 1) {
                this.print(C.gray ++ "  ├───┼───┼───┼───┼───┤" ++ C.reset ++ "\n");
            }
        }

        this.print(C.gray ++ "  └───┴───┴───┴───┴───┘" ++ C.reset ++ "\n\n");
    }

    fn handleInput(this: *Game) void {
        const bytes = this.terminal.mmio().len();
        var input_buffer: [sdk.SerialTerminal.INPUT_BUFFER_SIZE]u8 = undefined;
        sdk.dma.read(this.terminal.slot, 0, input_buffer[0..bytes]);

        var input = input_buffer[0..bytes];

        while (input.len > 0 and (input[input.len - 1] == '\n' or
            input[input.len - 1] == '\r' or
            input[input.len - 1] == ' '))
        {
            input = input[0 .. input.len - 1];
        }

        while (input.len > 0 and input[0] == ' ') {
            input = input[1..];
        }

        if (input.len == 0) {
            this.printPrompt();
            this.flush();

            return;
        }

        if (std.mem.eql(u8, input, "help")) {
            this.printHelp();
            this.printPrompt();
            this.flush();

            return;
        }

        if (std.mem.eql(u8, input, "reset")) {
            this.resetGame();
            this.printBoard();
            this.print(C.bcyan ++ "  [i] " ++ C.reset ++ "New game started!\n\n");
            this.printPrompt();
            this.flush();

            return;
        }

        if (this.game_over) {
            this.printGameOver();
            this.printPrompt();
            this.flush();

            return;
        }

        if (std.mem.eql(u8, input, "give up") or std.mem.eql(u8, input, "giveup")) {
            this.print(C.bred ++ "  [X] " ++ C.reset ++ "The word was: " ++ C.bold ++ C.bgreen);
            this.print(this.target_word);
            this.print(C.reset ++ "\n\n");
            this.game_over = true;
            this.printPrompt();
            this.flush();

            return;
        }

        if (input.len != WORD_LENGTH) {
            this.printFmt(C.bred ++ "  [!] " ++ C.reset ++ "Enter exactly {} letters\n\n", .{WORD_LENGTH});
            this.printPrompt();
            this.flush();

            return;
        }

        for (input) |c| {
            if (!std.ascii.isAlphabetic(c)) {
                this.print(C.bred ++ "  [!] " ++ C.reset ++ "Letters only!\n\n");
                this.printPrompt();
                this.flush();

                return;
            }
        }

        this.makeGuess(input);
        this.printBoard();

        if (this.won) {
            this.printWin();
        } else if (this.attempts >= MAX_ATTEMPTS) {
            this.game_over = true;
            this.printLose();
        }

        this.printPrompt();
        this.flush();
    }

    fn makeGuess(this: *Game, input: []const u8) void {
        const row = this.attempts;

        var target_used: [WORD_LENGTH]bool = .{ false, false, false, false, false };
        var guess_lower: [WORD_LENGTH]u8 = undefined;

        for (0..WORD_LENGTH) |i| {
            guess_lower[i] = std.ascii.toLower(input[i]);
            this.guesses[row][i] = guess_lower[i];
        }

        for (0..WORD_LENGTH) |i| {
            if (guess_lower[i] == this.target_word[i]) {
                this.results[row][i] = .correct;
                target_used[i] = true;
            }
        }

        for (0..WORD_LENGTH) |i| {
            if (this.results[row][i] == .correct) continue;

            var found = false;
            for (0..WORD_LENGTH) |j| {
                if (!target_used[j] and guess_lower[i] == this.target_word[j]) {
                    found = true;
                    target_used[j] = true;
                    break;
                }
            }

            this.results[row][i] = if (found) .misplaced else .wrong;
        }

        this.attempts += 1;

        var all_correct = true;
        for (0..WORD_LENGTH) |i| {
            if (this.results[row][i] != .correct) {
                all_correct = false;
                break;
            }
        }

        if (all_correct) {
            this.won = true;
            this.game_over = true;
        }
    }

    fn printWin(this: *Game) void {
        this.print(C.bgreen ++ C.bold ++ "  ╔═══════════════════╗\n");
        this.print("  ║   🎉 YOU WON! 🎉  ║\n");
        this.print("  ╚═══════════════════╝" ++ C.reset ++ "\n");

        const messages = [_][]const u8{
            "Genius!",
            "Magnificent!",
            "Impressive!",
            "Splendid!",
            "Great!",
            "Phew!",
        };

        this.print(C.green ++ "  ");
        this.print(messages[this.attempts - 1]);
        this.printFmt(" ({}/{})" ++ C.reset ++ "\n\n", .{ this.attempts, MAX_ATTEMPTS });
    }

    fn printLose(this: *Game) void {
        this.print(C.bred ++ C.bold ++ "  ╔═══════════════════╗\n");
        this.print("  ║    GAME  OVER     ║\n");
        this.print("  ╚═══════════════════╝" ++ C.reset ++ "\n");
        this.print(C.gray ++ "  The word was: " ++ C.bold ++ C.bgreen);
        this.print(this.target_word);
        this.print(C.reset ++ "\n\n");
    }

    fn printGameOver(this: *Game) void {
        if (this.won) {
            this.print(C.bgreen ++ "  [✓] " ++ C.reset ++ "You already won! Type 'reset' for new game\n\n");
        } else {
            this.print(C.bred ++ "  [X] " ++ C.reset ++ "Game over! Type 'reset' for new game\n\n");
        }
    }

    fn printHelp(this: *Game) void {
        this.print("\n");
        this.print(C.bcyan ++ "  ┌─ " ++ C.bold ++ "WORDLE HELP" ++ C.reset ++ C.bcyan ++ " ─┐" ++ C.reset ++ "\n\n");
        this.print(C.bwhite ++ "  Commands:" ++ C.reset ++ "\n");
        this.print(C.cyan ++ "  > " ++ C.white ++ "<word>   " ++ C.dim ++ "Make a guess\n" ++ C.reset);
        this.print(C.cyan ++ "  > " ++ C.white ++ "reset    " ++ C.dim ++ "Start new game\n" ++ C.reset);
        this.print(C.cyan ++ "  > " ++ C.white ++ "give up  " ++ C.dim ++ "Reveal the word\n" ++ C.reset);
        this.print(C.cyan ++ "  > " ++ C.white ++ "help     " ++ C.dim ++ "This screen\n" ++ C.reset);
        this.print("\n");
        this.print(C.bwhite ++ "  Colors:" ++ C.reset ++ "\n");
        this.print("  " ++ C.bg_green ++ C.black ++ C.bold ++ " A " ++ C.reset ++ " Letter is correct\n");
        this.print("  " ++ C.bg_yellow ++ C.black ++ C.bold ++ " B " ++ C.reset ++ " Letter in wrong spot\n");
        this.print("  " ++ C.bg_gray ++ C.white ++ " C " ++ C.reset ++ " Letter not in word\n");
        this.print("\n");
    }

    fn resetGame(this: *Game) void {
        this.attempts = 0;
        this.guesses = std.mem.zeroes([MAX_ATTEMPTS][WORD_LENGTH]u8);
        this.results = std.mem.zeroes([MAX_ATTEMPTS][WORD_LENGTH]LetterResult);
        this.game_over = false;
        this.won = false;
    }

    fn printPrompt(this: *Game) void {
        if (this.game_over) {
            this.print(C.gray ++ "wordle" ++ C.dim ++ ":done" ++ C.bwhite ++ "$ " ++ C.reset);
        } else {
            this.printFmt(C.green ++ "wordle" ++ C.bgreen ++ ":{}/{}" ++ C.bwhite ++ "$ " ++ C.reset, .{ this.attempts + 1, MAX_ATTEMPTS });
        }
    }

    inline fn print(this: *Game, text: []const u8) void {
        this.writer.interface.writeAll(text) catch {};
    }

    inline fn printFmt(this: *Game, comptime fmt: []const u8, args: anytype) void {
        this.writer.interface.print(fmt, args) catch {};
    }

    inline fn printChar(this: *Game, c: u8) void {
        this.writer.interface.writeByte(c) catch {};
    }

    inline fn flush(this: *Game) void {
        this.writer.flush() catch {};
    }
};

pub fn main() void {
    const terminal = SerialTerminal.find() orelse return;

    var game = Game.init(terminal);
    game.run();
}

comptime {
    _ = sdk.utils.EntryPoint(.{
        .stack_size = std.math.pow(u32, 2, 14),
    });
}
