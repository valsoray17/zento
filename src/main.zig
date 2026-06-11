const std = @import("std");
const wayland = @import("wayland.zig");

// ============================================================================
// Main
// ============================================================================
//
// Env vars are non-global in 0.16 — read them here from `init` (the only place
// they're available) and pass them down. See wayland.Env.

pub fn main(init: std.process.Init) !void {
    const env = wayland.Env{
        .home = init.environ_map.get("HOME"),
        .data_dirs = init.environ_map.get("XDG_DATA_DIRS"),
        .cache_home = init.environ_map.get("XDG_CACHE_HOME"),
    };
    try wayland.run(init.io, env);
}
