const std = @import("std");
const handler = @import("handler.zig");
const calc = @import("calc.zig");
const convert = @import("convert.zig");
const dict = @import("dict.zig");
const systemd = @import("systemd.zig");

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    // Get a writer to stdout
    // Go equivalent: os.Stdout or fmt.Print
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    // Print welcome message
    // `try` is like Go's `if err != nil { return err }`
    // It propagates errors up automatically
    try stdout.print("🚀 Launcher v0.1\n", .{});
    try stdout.print("Type 'quit' to exit, anything else to echo\n\n", .{});

    const home_path = std.posix.getenv("HOME") orelse "/tmp";
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dict_dir = std.fmt.bufPrint(&path_buf, "{s}/.stardict/dic/stardict-dictd-web1913-2.4.2", .{home_path}) catch unreachable;

    var timer = try std.time.Timer.start();
    dict.init(std.heap.page_allocator, dict_dir, "dictd_www.dict.org_web1913") catch {};
    const load_time_ms = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms;

    const wc = dict.wordCount();
    if (wc > 0) {
        try stdout.print("Dictionary loaded: {} words in {d:.1}ms\n", .{ wc, load_time_ms });
    } else {
        try stdout.print("Warning: dictionary not loaded\n", .{});
    }

    // Buffer for reading input
    // In Go: make([]byte, 1024) - but Zig arrays are stack-allocated by default
    // [1024]u8 = array of 1024 bytes (u8 = uint8)
    var buf: [1024]u8 = undefined; // `undefined` = uninitialized (like C)

    // Arena allocator for handler candidates — resets each input cycle.
    // Sits on top of page_allocator: one mmap for the backing pages,
    // then just pointer bumping for each alloc. Reset is free (no syscall).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Main loop
    while (true) {
        _ = arena.reset(.retain_capacity);
        try stdout.print("> ", .{});

        // Read a line from stdin
        // Returns a slice (?[]u8) - the ? means it can be null
        // Go equivalent: reader.ReadString('\n')
        const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch |err| {
            try stdout.print("Error reading input: {}\n", .{err});
            continue;
        };

        // Check for EOF (Ctrl+D)
        // `orelse` is like Go's `if x == nil { break }`
        const input = line orelse break;

        // Trim whitespace - returns a slice (pointer + length, no allocation)
        // Go equivalent: strings.TrimSpace(input)
        const trimmed = std.mem.trim(u8, input, " \t\r\n");

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
        if (std.mem.startsWith(u8, trimmed, "dw ")) {
            const query = trimmed[3..];
            const candidates = try dict.suggest(arena.allocator(), query);
            if (candidates.len > 0 and candidates[0].sublabel != null) {
                try stdout.print("{s}\n", .{candidates[0].sublabel.?});
            } else if (candidates.len > 0) {
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

        // Try systemd command (exact match only in CLI)
        candidates = try systemd.suggest(arena.allocator(), trimmed);
        for (candidates) |cand| {
            if (cand.score == 1.0) {
                systemd.execute(cand) catch |err| {
                    try stdout.print("Command failed: {}\n", .{err});
                    continue;
                };
                try stdout.print("{s}ing...\n", .{cand.label});
                continue;
            }
        }

        // Not a calculation or conversion — echo for now
        try stdout.print("Unknown command: {s}\n", .{trimmed});
    }

    // TODO free up stuff and exit
}
