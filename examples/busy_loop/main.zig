const std = @import("std");

const sdk = @import("mcu_sdk");

pub fn main() void {
    while (true) {}
}

comptime {
    _ = sdk.utils.EntryPoint(.{});
}
