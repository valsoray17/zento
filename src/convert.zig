const std = @import("std");
const h = @import("handler.zig");
const temperature = @import("convert/temperature.zig");
const data = @import("convert/data.zig");

// ============================================================================
// Shared helpers
// ============================================================================

// Parse the leading unit token (non-space characters) from input.
//
// "ms to s"  → { token: "ms", rest: "to s" }
// "MB to KB" → { token: "MB", rest: "to KB" }
// "F"        → { token: "F",  rest: "" }
fn parseUnitToken(input: []const u8) struct { token: []const u8, rest: []const u8 } {
    const trimmed = std.mem.trim(u8, input, " ");
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ') : (end += 1) {}
    return .{
        .token = trimmed[0..end],
        .rest = std.mem.trim(u8, trimmed[end..], " "),
    };
}

// Strip a leading "to " or "in " separator, return the rest.
//
// "to s"  → "s"
// "in KB" → "KB"
// "s"     → null
fn stripSeparator(s: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, s, "to ")) return std.mem.trim(u8, s[3..], " ");
    if (std.mem.startsWith(u8, s, "in ")) return std.mem.trim(u8, s[3..], " ");
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
pub const handler = h.Handler{
    .name = "convert",
    .kind = .calc,
    .on_enter = .close,
    .source = .{ .suggest = suggest },
};

pub fn suggest(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]h.Candidate {
    var candidates = try allocator.alloc(h.Candidate, 1);

    const parsed = parseNumberPrefix(input) orelse return candidates[0..0];
    const from = parseUnitToken(parsed.rest);
    if (from.token.len == 0) return candidates[0..0];

    const after_sep = stripSeparator(from.rest) orelse return candidates[0..0];
    const to = parseUnitToken(after_sep);
    if (to.token.len == 0) return candidates[0..0];

    if (temperature.Unit.fromStr(from.token)) |from_unit| {
        const to_unit = temperature.Unit.fromStr(to.token) orelse return candidates[0..0];
        candidates[0] = .{ .label = try temperature.express(from_unit, allocator, parsed.value, to_unit) };
        return candidates[0..1];
    }
    if (data.Unit.fromStr(from.token)) |from_unit| {
        const to_unit = data.Unit.fromStr(to.token) orelse return candidates[0..0];
        candidates[0] = .{ .label = try data.express(from_unit, allocator, parsed.value, to_unit) };
        return candidates[0..1];
    }
    return candidates[0..0];
}
