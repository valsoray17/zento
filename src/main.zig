const std = @import("std");
const stardict = @import("stardict.zig");

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
// Unit Conversion
// ============================================================================

// Temperature units — simple enum with just two values
//
// In Go, you'd write:
//   type TempUnit int
//   const (
//       Celsius TempUnit = iota
//       Fahrenheit
//   )
//   func (u TempUnit) String() string { ... }
//
// Zig allows methods directly inside enums — cleaner!
const TempUnit = enum {
    celsius,
    fahrenheit,

    // Parse string suffix to temperature unit (case-insensitive)
    // `self` is implicit for methods — like Go receivers but cleaner syntax
    // Returns optional: null if no match
    fn fromStr(s: []const u8) ?TempUnit {
        if (s.len == 0) return null;
        // Switch on first character — case insensitive
        return switch (s[0]) {
            'C', 'c' => .celsius,
            'F', 'f' => .fahrenheit,
            else => null,
        };
    }

    // Get display string for the unit
    // Note: `self` comes first, like Go's (u TempUnit) receiver
    fn toStr(self: TempUnit) []const u8 {
        return switch (self) {
            .celsius => "C",
            .fahrenheit => "F",
        };
    }
};

// Data size units — bytes, KB, MB, GB, TB
//
// Using binary units (1 KB = 1024 bytes), which is standard for storage.
// If you need SI units (1 KB = 1000 bytes), that's a future enhancement.
const DataUnit = enum {
    bytes,
    kb,
    mb,
    gb,
    tb,

    // Parse string to data unit (case-insensitive)
    // Handles: "B", "KB", "MB", "GB", "TB" (and lowercase variants)
    fn fromStr(s: []const u8) ?DataUnit {
        if (s.len == 0) return null;

        // Normalize to lowercase for comparison
        // Note: We're checking fixed-length prefixes, so this is simple
        if (s.len >= 2) {
            const first = std.ascii.toLower(s[0]);
            const second = std.ascii.toLower(s[1]);

            if (first == 'k' and second == 'b') return .kb;
            if (first == 'm' and second == 'b') return .mb;
            if (first == 'g' and second == 'b') return .gb;
            if (first == 't' and second == 'b') return .tb;
        }

        // Single character: just "B" for bytes
        if (s.len >= 1 and (s[0] == 'B' or s[0] == 'b')) {
            // Make sure it's not "KB", "MB", etc.
            if (s.len == 1) return .bytes;
        }

        return null;
    }

    // Get display string for the unit
    fn toStr(self: DataUnit) []const u8 {
        return switch (self) {
            .bytes => "B",
            .kb => "KB",
            .mb => "MB",
            .gb => "GB",
            .tb => "TB",
        };
    }

    // Multiplier to convert this unit to bytes
    // Using u64 to handle TB-scale values without overflow
    fn toBytes(self: DataUnit) u64 {
        return switch (self) {
            .bytes => 1,
            .kb => 1024,
            .mb => 1024 * 1024,
            .gb => 1024 * 1024 * 1024,
            .tb => 1024 * 1024 * 1024 * 1024,
        };
    }
};

// Find conversion separator (" to " or " in ") in input
// Returns position and length of separator, or null if not found
fn findSeparator(input: []const u8) ?struct { pos: usize, len: usize } {
    // Try " to " first (4 chars)
    if (std.mem.indexOf(u8, input, " to ")) |pos| {
        return .{ .pos = pos, .len = 4 };
    }
    // Try " in " (4 chars)
    if (std.mem.indexOf(u8, input, " in ")) |pos| {
        return .{ .pos = pos, .len = 4 };
    }
    return null;
}

// Parse number prefix from input, return value and remaining string
//
// "32F to C"   → { value: 32, rest: "F to C" }
// "100 MB to KB" → { value: 100, rest: "MB to KB" }
// "hello"      → null (not a conversion)
//
// This is the shared first step for all unit conversions.
fn parseNumberPrefix(input: []const u8) ?struct { value: f64, rest: []const u8 } {
    const trimmed = std.mem.trim(u8, input, " ");
    if (trimmed.len == 0) return null;

    // Find where the number ends (digits, dot, minus)
    var num_end: usize = 0;
    for (trimmed, 0..) |c, i| {
        if ((c >= '0' and c <= '9') or c == '.' or c == '-') {
            num_end = i + 1;
        } else break;
    }

    if (num_end == 0) return null; // No number found

    const num_str = trimmed[0..num_end];
    const rest = std.mem.trim(u8, trimmed[num_end..], " ");

    const value = std.fmt.parseFloat(f64, num_str) catch return null;

    return .{ .value = value, .rest = rest };
}

// Convert temperature: "F to C" with value 32 → "0.00 C"
//
// Takes pre-parsed value and the rest of input (e.g., "F to C").
// Buffer is for writing result — Zig avoids hidden allocations.
fn convertTemperature(value: f64, rest: []const u8, buf: []u8) ?[]const u8 {
    // Find separator (" to " or " in ")
    const sep = findSeparator(rest) orelse return null;

    // Split: "F to C" → "F" and "C"
    const from_str = std.mem.trim(u8, rest[0..sep.pos], " ");
    const to_str = std.mem.trim(u8, rest[sep.pos + sep.len ..], " ");

    // Parse units — if either fails, this isn't a temperature conversion
    const from_unit = TempUnit.fromStr(from_str) orelse return null;
    const to_unit = TempUnit.fromStr(to_str) orelse return null;

    // Convert using direct formula (Option A — just F and C)
    const result: f64 = switch (from_unit) {
        .celsius => switch (to_unit) {
            .celsius => value,
            .fahrenheit => value * 9.0 / 5.0 + 32.0,
        },
        .fahrenheit => switch (to_unit) {
            .celsius => (value - 32.0) * 5.0 / 9.0,
            .fahrenheit => value,
        },
    };

    // Format result into buffer
    const formatted = std.fmt.bufPrint(buf, "{d:.2} {s}", .{ result, to_unit.toStr() }) catch return null;
    return formatted;
}

// Convert data size: "MB to KB" with value 100 → "102400.00 KB"
//
// Strategy: convert to bytes first, then to target unit.
// This avoids needing a conversion table between every pair of units.
fn convertDataUnit(value: f64, rest: []const u8, buf: []u8) ?[]const u8 {
    // Find separator (" to " or " in ")
    const sep = findSeparator(rest) orelse return null;

    // Split: "MB to KB" → "MB" and "KB"
    const from_str = std.mem.trim(u8, rest[0..sep.pos], " ");
    const to_str = std.mem.trim(u8, rest[sep.pos + sep.len ..], " ");

    // Parse units — if either fails, this isn't a data unit conversion
    const from_unit = DataUnit.fromStr(from_str) orelse return null;
    const to_unit = DataUnit.fromStr(to_str) orelse return null;

    // Convert: value → bytes → target unit
    const bytes = value * @as(f64, @floatFromInt(from_unit.toBytes()));
    const result = bytes / @as(f64, @floatFromInt(to_unit.toBytes()));

    // Format result into buffer
    const formatted = std.fmt.bufPrint(buf, "{d:.2} {s}", .{ result, to_unit.toStr() }) catch return null;
    return formatted;
}

// Main conversion dispatcher — tries all conversion types
fn convert(input: []const u8, buf: []u8) ?[]const u8 {
    // Step 1: Parse number prefix (shared for all conversions)
    const parsed = parseNumberPrefix(input) orelse return null;

    // Step 2: Try each converter until one succeeds
    if (convertTemperature(parsed.value, parsed.rest, buf)) |result| return result;
    if (convertDataUnit(parsed.value, parsed.rest, buf)) |result| return result;
    // Later: if (calculateBandwidth(parsed.value, parsed.rest, buf)) |result| return result;

    return null;
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

    const home_path = std.posix.getenv("HOME") orelse "/tmp";
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dict_dir = std.fmt.bufPrint(&path_buf, "{s}/.stardict/dic/stardict-dictd-web1913-2.4.2", .{home_path}) catch unreachable;

    var timer = try std.time.Timer.start();
    const dict: ?stardict.Dictionary = stardict.Dictionary.load(std.heap.page_allocator, dict_dir, "dictd_www.dict.org_web1913") catch null;
    const load_time_ms = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms;

    if (dict) |d| {
        try stdout.print("Dictionary loaded: {} words in {d:.1}ms\n", .{ d.entries.len, load_time_ms });
    } else {
        try stdout.print("Warning: dictionary not loaded\n", .{});
    }

    // Buffer for reading input
    // In Go: make([]byte, 1024) - but Zig arrays are stack-allocated by default
    // [1024]u8 = array of 1024 bytes (u8 = uint8)
    var buf: [1024]u8 = undefined; // `undefined` = uninitialized (like C)
                                   //
    var definition: [32 * 1024]u8 = undefined; // 32KB for large dictionary definitions

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

        // Try dictionary lookup: "dw word"
        if (std.mem.startsWith(u8, trimmed, "dw ")) {
            const word = trimmed[3..];
            const d = dict orelse {
                try stdout.print("Dictionary not loaded\n", .{});
                continue;
            };
            const def = d.lookup(word, &definition) catch |err| {
                try stdout.print("Lookup failed for '{s}': {}\n", .{ word, err });
                continue;
            };
            try stdout.print("{s}\n", .{def});
            continue;
        }

        // Try calculator first
        // `if (optional) |value|` unwraps the optional if it's not null
        // Go equivalent: if result, ok := calculate(input); ok { ... }
        if (calculate(trimmed)) |result| {
            try stdout.print("= {d}\n", .{result});
            continue;
        }

        // Try unit conversion
        var convert_buf: [256]u8 = undefined;
        if (convert(trimmed, &convert_buf)) |result| {
            try stdout.print("= {s}\n", .{result});
            continue;
        }

        // Not a calculation or conversion — echo for now
        try stdout.print("Unknown command: {s}\n", .{trimmed});
    }

    // TODO free up stuff and exit
}
