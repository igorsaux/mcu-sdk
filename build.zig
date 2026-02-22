// Copyright (C) 2026 Igor Spichkin
// SPDX-License-Identifier: AGPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ondatra = b.dependency("ondatra", .{
        .target = target,
        .optimize = optimize,
    });

    const sdk = b.addModule("mcu_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ondatra", .module = ondatra.module("ondatra") },
        },
    });

    addGuestExecutable(b, sdk, "examples/hello_world", "hello_world");
    addGuestExecutable(b, sdk, "examples/busy_loop", "busy_loop");
    addGuestExecutable(b, sdk, "examples/sensors", "sensors");
    addGuestExecutable(b, sdk, "examples/serial_terminal", "serial_terminal");
    addGuestExecutable(b, sdk, "examples/signaler", "signaler");
}

const riscv32Query: std.Target.Query = .{
    .cpu_arch = .riscv32,
    .cpu_model = .{
        .explicit = std.Target.Cpu.Model.generic(.riscv32),
    },
    .cpu_features_add = std.Target.riscv.featureSet(&[_]std.Target.riscv.Feature{
        std.Target.riscv.Feature.@"32bit",
        std.Target.riscv.Feature.i,
        std.Target.riscv.Feature.m,
        std.Target.riscv.Feature.f,
        std.Target.riscv.Feature.zicsr,
        std.Target.riscv.Feature.zicntr,
        std.Target.riscv.Feature.zifencei,
        std.Target.riscv.Feature.zba,
        std.Target.riscv.Feature.zbb,
    }),
    .os_tag = .freestanding,
};

fn addGuestExecutable(
    b: *std.Build,
    sdk: *std.Build.Module,
    comptime base_folder: []const u8,
    comptime base_name: []const u8,
) void {
    const target = b.resolveTargetQuery(riscv32Query);

    const binary = b.addExecutable(.{
        .name = base_name ++ ".elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path(base_folder ++ "/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .strip = true,
            .imports = &.{
                .{ .name = "mcu_sdk", .module = sdk },
            },
        }),
    });
    binary.linker_script = b.path("examples/linker.ld");

    b.installArtifact(binary);
}
