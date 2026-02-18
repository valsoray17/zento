const std = @import("std");
const wl = @import("wayland").client.wl;

/// Connect to the Wayland display, enumerate globals, and disconnect.
/// This is a smoke test to verify the zig-wayland setup works.
pub fn run() !void {
    const stdout = std.io.getStdOut().writer();

    // Connect to the default Wayland display ($WAYLAND_DISPLAY or "wayland-0").
    // Go equivalent: net.Dial("unix", socketPath)
    const display = wl.Display.connect(null) orelse {
        try stdout.print("Failed to connect to Wayland display\n", .{});
        return error.ConnectFailed;
    };
    defer display.disconnect();

    // The registry is how Wayland advertises available interfaces.
    // Like D-Bus introspection — the compositor tells us what it supports.
    const registry = try display.getRegistry();

    // Set up a listener for registry events.
    // When the compositor sends us a "global" event (advertising an interface),
    // our callback fires. This is event-driven, not request-response.
    registry.setListener(*const @TypeOf(stdout), registryListener, &stdout);

    // roundtrip() sends our requests and blocks until the compositor
    // responds. After this returns, all global events have fired.
    if (display.roundtrip() != .SUCCESS) {
        return error.RoundtripFailed;
    }
}

/// Callback for wl_registry.global events.
/// Called once per interface the compositor supports.
fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, stdout: *const @TypeOf(std.io.getStdOut().writer())) void {
    _ = registry;
    switch (event) {
        .global => |global| {
            const name_str = global.interface orelse "unknown";
            stdout.print("  {s} v{}\n", .{ name_str, global.version }) catch {};
        },
        .global_remove => {},
    }
}
