const std = @import("std");
const h = @import("handler.zig");

pub const Calc = struct {
    /// Return 0 or 1 candidates if input is a valid math expression
    pub fn suggest(_: *Calc, _: std.Io, allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]h.Candidate {
        var candidates = try allocator.alloc(h.Candidate, 1);

        const result = calculate(input) orelse return candidates[0..0];

        // Label is dynamic ("= 5", "= 3.14") — allocated from the arena
        const label = try std.fmt.allocPrint(allocator, "= {d}", .{result});

        candidates[0] = .{
            .label = label,
            .sublabel = null,
        };
        return candidates[0..1];
    }
    pub fn handler(self: *Calc) h.Handler {
        return .{
            .ptr = self,
            .name = "calc",
            .kind = .calc,
            .on_enter = .close,
            .source = .{ .suggest = h.suggestFn(Calc) },
        };
    }
};

/// Try to evaluate a math expression (e.g., "2+3", "10 / 3", "-5+3")
/// Supports: +, -, *, /, %
fn calculate(input: []const u8) ?f64 {
    // Find operator position and type
    // Skip first char (could be negative number like "-5+3")
    var found: ?struct { pos: usize, op: u8 } = null;

    for (input, 0..) |char, i| {
        if (i == 0) continue;

        switch (char) {
            '+', '-', '*', '/', '%' => {
                found = .{ .pos = i, .op = char };
                break;
            },
            else => {},
        }
    }

    const f = found orelse return null;

    const left_str = std.mem.trim(u8, input[0..f.pos], " ");
    const right_str = std.mem.trim(u8, input[f.pos + 1 ..], " ");

    const left = std.fmt.parseFloat(f64, left_str) catch return null;
    const right = std.fmt.parseFloat(f64, right_str) catch return null;

    return switch (f.op) {
        '+' => left + right,
        '-' => left - right,
        '*' => left * right,
        '/' => if (right != 0) left / right else null,
        '%' => @mod(left, right),
        else => null,
    };
}
