const std = @import("std");
const handler = @import("handler.zig");
const calc = @import("calc.zig");
const convert = @import("convert.zig");
const dict = @import("dict.zig");
const systemd = @import("systemd.zig");
const wayland = @import("wayland.zig");

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    // Zig 0.15: buffered writer — buffer on stack, flush explicitly.
    // "Please use buffering! And don't forget to flush!" — release notes.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    // Default: launch GUI. Pass --cli for the text REPL.
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    var cli_mode = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--cli")) cli_mode = true;
    }
    if (!cli_mode) {
        try wayland.run();
        return;
    }

    // Print welcome message
    // `try` is like Go's `if err != nil { return err }`
    // It propagates errors up automatically
    try stdout.print("🚀 Launcher v0.1\n", .{});
    try stdout.print("Type 'quit' to exit\n\n", .{});

    // Zig 0.15: buffered reader — buffer on stack.
    // takeDelimiterExclusive returns a slice into this buffer (zero-copy).
    var stdin_buf: [4096]u8 = undefined;
    var stdin_r = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_r.interface;

    // Arena allocator for handler candidates — resets each input cycle.
    // Sits on top of page_allocator: one mmap for the backing pages,
    // then just pointer bumping for each alloc. Reset is free (no syscall).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Main loop
    while (true) {
        _ = arena.reset(.retain_capacity);
        try stdout.print("> ", .{});
        // Flush before blocking on stdin so the prompt appears immediately.
        try stdout.flush();

        // Read a line from stdin.
        // takeDelimiterExclusive: returns slice up to (not including) '\n',
        // stored in stdin's internal buffer. EOF → error.EndOfStream → break.
        // Go equivalent: reader.ReadString('\n')
        const input = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| {
                try stdout.print("Error reading input: {}\n", .{e});
                try stdout.flush();
                continue;
            },
        };

        // Trim whitespace - returns a slice (pointer + length, no allocation)
        // Go equivalent: strings.TrimSpace(input)
        const trimmed = std.mem.trim(u8, input, " \t\r");

        // Check for quit command
        // std.mem.eql compares slices (like bytes.Equal in Go)
        if (std.mem.eql(u8, trimmed, "quit")) {
            try stdout.print("Goodbye!\n", .{});
            break;
        }

        // Empty input — just show prompt again
        if (trimmed.len == 0) {
            continue;
        }

        // Dictionary mode: "dw word"
        // dict.suggest handles lazy loading internally.
        if (std.mem.startsWith(u8, trimmed, "dw ")) {
            const query = trimmed[3..];
            const candidates = try dict.suggest(arena.allocator(), query);
            if (candidates.len > 0) {
                try stdout.print("{s}\n", .{candidates[0].label});
            } else {
                try stdout.print("No results for '{s}'\n", .{query});
            }
            continue;
        }

        // Try calculator
        var candidates = try calc.suggest(arena.allocator(), trimmed);
        if (candidates.len > 0) {
            try stdout.print("{s}\n", .{candidates[0].label});
            continue;
        }

        // Try unit conversion
        candidates = try convert.suggest(arena.allocator(), trimmed);
        if (candidates.len > 0) {
            try stdout.print("{s}\n", .{candidates[0].label});
            continue;
        }

        // Try systemd command — load all, prefix-filter in CLI
        const sys_candidates = try systemd.load(arena.allocator());
        for (sys_candidates) |cand| {
            if (!std.mem.startsWith(u8, cand.label, trimmed)) continue;
            systemd.execute(cand.key orelse continue) catch |err| {
                try stdout.print("Command failed: {}\n", .{err});
                continue;
            };
            try stdout.print("{s}ing...\n", .{cand.label});
        }

        // Not a calculation or conversion — echo for now
        try stdout.print("Unknown command: {s}\n", .{trimmed});
    }
}
