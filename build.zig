const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Wayland protocol scanner ---
    // Generates type-safe Zig bindings from protocol XML at build time.
    // Like protoc for Wayland: XML schema → Zig structs with methods.
    const scanner = Scanner.create(b, .{});

    // Core Wayland protocols (from wayland-protocols system package)
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");

    // wlr-layer-shell (vendored from freedesktop.org/wlroots/wlr-protocols)
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));

    // Generate bindings for interfaces we'll use.
    // Version = max version we implement (not latest in the XML).
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("zwlr_layer_shell_v1", 4);

    // Module from scanner output — source code imports via @import("wayland")
    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    // --- Executable ---
    const exe = b.addExecutable(.{
        .name = "launcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("wayland", wayland);

    // Link system libraries
    exe.linkLibC();
    exe.linkSystemLibrary("libsystemd");
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("pixman-1");
    exe.linkSystemLibrary("fcft");
    exe.linkSystemLibrary("xkbcommon");

    b.installArtifact(exe);

    // Run step: `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the launcher");
    run_step.dependOn(&run_cmd.step);
}
