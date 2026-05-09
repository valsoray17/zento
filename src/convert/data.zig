const std = @import("std");

pub const Unit = enum {
    bytes,
    kb,
    mb,
    gb,
    tb,

    pub fn fromStr(s: []const u8) ?@This() {
        const table = [_]struct { str: []const u8, unit: Unit }{
            .{ .str = "b",         .unit = .bytes },
            .{ .str = "bytes",     .unit = .bytes },
            .{ .str = "kb",        .unit = .kb },
            .{ .str = "kilobytes", .unit = .kb },
            .{ .str = "mb",        .unit = .mb },
            .{ .str = "megabytes", .unit = .mb },
            .{ .str = "gb",        .unit = .gb },
            .{ .str = "gigabytes", .unit = .gb },
            .{ .str = "tb",        .unit = .tb },
            .{ .str = "terabytes", .unit = .tb },
        };
        for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(s, entry.str)) return entry.unit;
        }
        return null;
    }

    pub fn toStr(self: @This()) []const u8 {
        return switch (self) {
            .bytes => "B",
            .kb => "KB",
            .mb => "MB",
            .gb => "GB",
            .tb => "TB",
        };
    }

    pub fn toBytes(self: @This()) u64 {
        return switch (self) {
            .bytes => 1,
            .kb => 1024,
            .mb => 1024 * 1024,
            .gb => 1024 * 1024 * 1024,
            .tb => 1024 * 1024 * 1024 * 1024,
        };
    }
};

pub fn express(self: Unit, allocator: std.mem.Allocator, value: f64, to: Unit) std.mem.Allocator.Error![]const u8 {
    const base = value * @as(f64, @floatFromInt(self.toBytes()));
    const result = base / @as(f64, @floatFromInt(to.toBytes()));
    return try std.fmt.allocPrint(allocator, "= {d:.2} {s}", .{ result, to.toStr() });
}
