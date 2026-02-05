const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options - defaults to native
    const target = b.standardTargetOptions(.{});

    // Standard optimization options
    const optimize = b.standardOptimizeOption(.{});

    // Define the executable
    const exe = b.addExecutable(.{
        .name = "launcher",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link system libraries
    exe.linkLibC();
    exe.linkSystemLibrary("libsystemd");

    // Install the executable
    b.installArtifact(exe);

    // Create a "run" step: `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Allow passing args: `zig build run -- arg1 arg2`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the launcher");
    run_step.dependOn(&run_cmd.step);
}
