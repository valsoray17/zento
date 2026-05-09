const std = @import("std");

pub const Unit = enum {
    celsius,
    fahrenheit,

    pub fn fromStr(s: []const u8) ?@This() {
        if (std.ascii.eqlIgnoreCase(s, "c") or std.ascii.eqlIgnoreCase(s, "celsius")) return .celsius;
        if (std.ascii.eqlIgnoreCase(s, "f") or std.ascii.eqlIgnoreCase(s, "fahrenheit")) return .fahrenheit;
        return null;
    }

    pub fn toStr(self: @This()) []const u8 {
        return switch (self) {
            .celsius => "C°",
            .fahrenheit => "F°",
        };
    }
};

pub fn express(self: Unit, allocator: std.mem.Allocator, value: f64, to: Unit) std.mem.Allocator.Error![]const u8 {
    const result: f64 = switch (self) {
        .celsius => switch (to) {
            .celsius => value,
            .fahrenheit => value * 9.0 / 5.0 + 32.0,
        },
        .fahrenheit => switch (to) {
            .celsius => (value - 32.0) * 5.0 / 9.0,
            .fahrenheit => value,
        },
    };
    return try std.fmt.allocPrint(allocator, "= {d:.2} {s}", .{ result, to.toStr() });
}
