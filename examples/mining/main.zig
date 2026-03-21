const std = @import("std");
const sdk = @import("mcu_sdk");

const Tts = sdk.utils.PciDevice(sdk.Tts, .tts);
const MiningBlock = sdk.utils.PciDevice(sdk.MiningBlock, .mining_block);

const HASH_DELAY_NS: u64 = 100_000_000; // 1ms

const FOUND_DELAY_NS: u64 = 100_000_000; // 100ms

const INITIAL_NONCE: u32 = 0;

const MinerState = struct {
    nonce: u32 = INITIAL_NONCE,
    blocks_found: u32 = 0,
    attempts: u32 = 0,
};

var state: MinerState = .{};
fn say(tts: Tts, message: []const u8) void {
    sdk.arch.Mie.setMeie();

    while (!tts.mmio().ready()) {
        sdk.arch.wfi();
    }

    while (tts.mmio().lastEvent()) |_| {
        tts.mmio().ack();
    }

    sdk.dma.memset(tts.slot, 0, 0, sdk.Tts.BUFFER_SIZE);
    sdk.dma.write(tts.slot, 0, message);

    tts.mmio().say();

    sdk.arch.Mie.clearMeie();
}

fn sleepNs(ns: u64) void {
    sdk.arch.Mie.setMtie();

    sdk.clint.interruptAfterNs(ns);
    sdk.arch.wfi();

    while (sdk.clint.lastEvent()) |_| {
        sdk.clint.ack();
    }

    sdk.arch.Mie.clearMtie();
}

fn getAlgorithmName(algo: sdk.MiningBlock.Status) []const u8 {
    if (algo.algorithm != .proof_of_work) {
        return "Unknown";
    }

    return switch (algo.args.proof_of_work.hash) {
        .fnv1a => "FNV-1a",
        .murmur_hash3 => "MurmurHash3",
        .blake2s => "BLAKE2s",
        .xx_hash => "xxHash",
        .sha256 => "SHA-256",
        _ => "Unknown",
    };
}

fn tryMine(mining_block: MiningBlock) bool {
    const found = mining_block.mmio().send(state.nonce);

    state.attempts += 1;
    state.nonce +%= 1;

    return found;
}

fn onBlockFound(tts: Tts) void {
    state.blocks_found += 1;

    var msg_buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&msg_buf);

    writer.print("Block found! Total: {}", .{state.blocks_found}) catch unreachable;

    say(tts, msg_buf[0..writer.end]);

    sleepNs(FOUND_DELAY_NS);
}

fn printStatus(tts: Tts, mining_block: MiningBlock) void {
    const status = mining_block.mmio().status().*;
    const algo_name = getAlgorithmName(status);

    var msg_buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&msg_buf);

    writer.print("Mining: {s}", .{algo_name}) catch unreachable;

    say(tts, msg_buf[0..writer.end]);
}

pub fn main() void {
    const tts = Tts.find() orelse return;
    const mining_block = MiningBlock.find() orelse return;

    tts.mmio().interrupts().on_ready = true;

    const status = mining_block.mmio().status().*;
    if (status.algorithm == .none) {
        say(tts, "Error: Mining not configured");
        return;
    }

    printStatus(tts, mining_block);
    sleepNs(1_500_000_000);

    say(tts, "Starting miner...");
    sleepNs(1_500_000_000);

    while (true) {
        if (tryMine(mining_block)) {
            onBlockFound(tts);
        }

        sleepNs(HASH_DELAY_NS);

        if (state.attempts % 1000 == 0) {
            var msg_buf: [64]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&msg_buf);

            writer.print("Attempts: {}", .{state.attempts}) catch unreachable;

            say(tts, msg_buf[0..writer.end]);
        }
    }
}

comptime {
    _ = sdk.utils.EntryPoint(.{
        .stack_size = std.math.pow(u32, 2, 14),
    });
}
