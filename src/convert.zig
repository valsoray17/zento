const std = @import("std");
const h = @import("handler.zig");

// ============================================================================
// Temperature
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
    fn fromStr(s: []const u8) ?TempUnit {
        if (s.len == 0) return null;
        return switch (s[0]) {
            'C', 'c' => .celsius,
            'F', 'f' => .fahrenheit,
            else => null,
        };
    }

    fn toStr(self: TempUnit) []const u8 {
        return switch (self) {
            .celsius => "C",
            .fahrenheit => "F",
        };
    }
};

// Convert temperature: "F to C" with value 32 → "0.00 C"
fn convertTemperature(allocator: std.mem.Allocator, value: f64, rest: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const sep = findSeparator(rest) orelse return null;

    const from_str = std.mem.trim(u8, rest[0..sep.pos], " ");
    const to_str = std.mem.trim(u8, rest[sep.pos + sep.len ..], " ");

    const from_unit = TempUnit.fromStr(from_str) orelse return null;
    const to_unit = TempUnit.fromStr(to_str) orelse return null;

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

    return try std.fmt.allocPrint(allocator, "= {d:.2} {s}", .{ result, to_unit.toStr() });
}

// ============================================================================
// Data Units
// ============================================================================

// Data size units — bytes, KB, MB, GB, TB
//
// Using binary units (1 KB = 1024 bytes), which is standard for storage.
const DataUnit = enum {
    bytes,
    kb,
    mb,
    gb,
    tb,

    fn fromStr(s: []const u8) ?DataUnit {
        if (s.len == 0) return null;

        if (s.len >= 2) {
            const first = std.ascii.toLower(s[0]);
            const second = std.ascii.toLower(s[1]);

            if (first == 'k' and second == 'b') return .kb;
            if (first == 'm' and second == 'b') return .mb;
            if (first == 'g' and second == 'b') return .gb;
            if (first == 't' and second == 'b') return .tb;
        }

        if (s.len >= 1 and (s[0] == 'B' or s[0] == 'b')) {
            if (s.len == 1) return .bytes;
        }

        return null;
    }

    fn toStr(self: DataUnit) []const u8 {
        return switch (self) {
            .bytes => "B",
            .kb => "KB",
            .mb => "MB",
            .gb => "GB",
            .tb => "TB",
        };
    }

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

// Convert data size: "MB to KB" with value 100 → "= 102400.00 KB"
fn convertDataUnit(allocator: std.mem.Allocator, value: f64, rest: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const sep = findSeparator(rest) orelse return null;

    const from_str = std.mem.trim(u8, rest[0..sep.pos], " ");
    const to_str = std.mem.trim(u8, rest[sep.pos + sep.len ..], " ");

    const from_unit = DataUnit.fromStr(from_str) orelse return null;
    const to_unit = DataUnit.fromStr(to_str) orelse return null;

    const bytes = value * @as(f64, @floatFromInt(from_unit.toBytes()));
    const result = bytes / @as(f64, @floatFromInt(to_unit.toBytes()));

    return try std.fmt.allocPrint(allocator, "= {d:.2} {s}", .{ result, to_unit.toStr() });
}

// ============================================================================
// Shared helpers
// ============================================================================

// Find conversion separator (" to " or " in ") in input
fn findSeparator(input: []const u8) ?struct { pos: usize, len: usize } {
    if (std.mem.indexOf(u8, input, " to ")) |pos| {
        return .{ .pos = pos, .len = 4 };
    }
    if (std.mem.indexOf(u8, input, " in ")) |pos| {
        return .{ .pos = pos, .len = 4 };
    }
    return null;
}

// Parse number prefix from input, return value and remaining string
//
// "32F to C"     → { value: 32, rest: "F to C" }
// "100 MB to KB" → { value: 100, rest: "MB to KB" }
// "hello"        → null
fn parseNumberPrefix(input: []const u8) ?struct { value: f64, rest: []const u8 } {
    const trimmed = std.mem.trim(u8, input, " ");
    if (trimmed.len == 0) return null;

    var num_end: usize = 0;
    for (trimmed, 0..) |c, i| {
        if ((c >= '0' and c <= '9') or c == '.' or c == '-') {
            num_end = i + 1;
        } else break;
    }

    if (num_end == 0) return null;

    const num_str = trimmed[0..num_end];
    const rest = std.mem.trim(u8, trimmed[num_end..], " ");

    const value = std.fmt.parseFloat(f64, num_str) catch return null;

    return .{ .value = value, .rest = rest };
}

// ============================================================================
// Handler interface
// ============================================================================

/// Return 0 or 1 candidates if input is a valid unit conversion
pub fn suggest(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]h.Candidate {
    var candidates = try allocator.alloc(h.Candidate, 1);

    const parsed = parseNumberPrefix(input) orelse return candidates[0..0];

    // Try each converter until one succeeds
    const label = try convertTemperature(allocator, parsed.value, parsed.rest) orelse
        try convertDataUnit(allocator, parsed.value, parsed.rest) orelse
        return candidates[0..0];

    candidates[0] = .{
        .label = label,
        .sublabel = null,
        .kind = .instant,
    };
    return candidates[0..1];
}
