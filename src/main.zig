const std = @import("std");

// ============================================================================
// Calculator
// ============================================================================

// Function signature breakdown:
//   fn name(param: Type) ReturnType
//   `?f64` means "optional f64" — can return null if parsing fails
//
// Go equivalent: func calculate(input string) (float64, bool)
fn calculate(input: []const u8) ?f64 {
    // Find operator position and type
    // Using an anonymous struct to return both values together
    // Go equivalent would be a custom struct, but Zig makes this lightweight
    var found: ?struct { pos: usize, op: u8 } = null;

    for (input, 0..) |char, i| {
        // Skip first char (could be negative number like "-5+3")
        if (i == 0) continue;

        // Check if it's an operator
        switch (char) {
            '+', '-', '*', '/', '%' => {
                // .{ } is struct literal syntax — fields inferred from type
                found = .{ .pos = i, .op = char };
                break;
            },
            else => {},
        }
    }

    // Unwrap the optional struct, or return null if no operator found
    const f = found orelse return null;
    const pos = f.pos;
    const op = f.op;

    // Split into left and right parts
    // input[0..pos] is slice syntax, like Go's input[:pos]
    const left_str = std.mem.trim(u8, input[0..pos], " ");
    const right_str = std.mem.trim(u8, input[pos + 1 ..], " ");

    // Parse strings to floats
    // std.fmt.parseFloat returns an error union, we use `catch` to handle failure
    const left = std.fmt.parseFloat(f64, left_str) catch return null;
    const right = std.fmt.parseFloat(f64, right_str) catch return null;

    // Perform calculation
    // Switch in Zig is an expression — it returns a value!
    // Much nicer than Go's switch statements
    return switch (op) {
        '+' => left + right,
        '-' => left - right,
        '*' => left * right,
        '/' => if (right != 0) left / right else null,
        '%' => @mod(left, right),
        else => null,
    };
}

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

    // Buffer for reading input
    // In Go: make([]byte, 1024) - but Zig arrays are stack-allocated by default
    // [1024]u8 = array of 1024 bytes (u8 = uint8)
    var buf: [1024]u8 = undefined; // `undefined` = uninitialized (like C)

    // Main loop
    while (true) {
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

        // Try calculator first
        // `if (optional) |value|` unwraps the optional if it's not null
        // Go equivalent: if result, ok := calculate(input); ok { ... }
        if (calculate(trimmed)) |result| {
            try stdout.print("= {d}\n", .{result});
            continue;
        }

        // Not a calculation — echo for now (will add more commands later)
        try stdout.print("Unknown command: {s}\n", .{trimmed});
    }
}
