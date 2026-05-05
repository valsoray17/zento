const std = @import("std");
const h = @import("handler.zig");

// Import sd-bus from libsystemd
// This is Zig's C interop — similar to cgo in Go, but at compile time
const c = @cImport({
    @cInclude("systemd/sd-bus.h");
});

/// Connection to the system D-Bus
/// Wraps the raw C pointer for safer Zig usage
pub const Bus = struct {
    bus: *c.sd_bus,

    /// Connect to the system bus
    pub fn connectSystem() !Bus {
        var bus: ?*c.sd_bus = null;

        // sd_bus_open_system returns negative errno on failure
        const ret = c.sd_bus_open_system(&bus);
        if (ret < 0) {
            return error.ConnectionFailed;
        }

        return Bus{ .bus = bus.? };
    }

    /// Disconnect and free resources
    pub fn disconnect(self: *Bus) void {
        _ = c.sd_bus_unref(self.bus);
    }

    /// Call a method on org.freedesktop.login1.Manager
    fn callLogin1Method(self: *Bus, method: []const u8) !void {
        var buf: [64]u8 = undefined;
        const method_z = std.fmt.bufPrintZ(&buf, "{s}", .{method}) catch return error.MethodNameTooLong;
        var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        var reply: ?*c.sd_bus_message = null;

        defer {
            c.sd_bus_error_free(&err);
            if (reply) |r| _ = c.sd_bus_message_unref(r);
        }

        const ret = c.sd_bus_call_method(
            self.bus,
            "org.freedesktop.login1", // service
            "/org/freedesktop/login1", // object path
            "org.freedesktop.login1.Manager", // interface
            method_z, // method name
            &err,
            &reply,
            "b", // signature: boolean
            @as(c_int, 1), // interactive = true
        );

        if (ret < 0) {
            // TODO: could extract err.message for better diagnostics
            return error.MethodCallFailed;
        }
    }

};

// ============================================================================
// Handler interface
// ============================================================================

const Entry = struct {
    keyword: []const u8,
    sublabel: []const u8,
    method: []const u8,
};

const entries = [_]Entry{
    .{ .keyword = "Suspend", .sublabel = "Suspend the system", .method = "Suspend" },
    .{ .keyword = "Hibernate", .sublabel = "Hibernate the system", .method = "Hibernate" },
    .{ .keyword = "Reboot", .sublabel = "Reboot the system", .method = "Reboot" },
    .{ .keyword = "Shutdown", .sublabel = "Power off the system", .method = "PowerOff" },
};

pub const handler = h.Handler{
    .name = "systemd",
    .kind = .cmd,
    .on_enter = .{ .run = execute },
    .source = .{ .load = load },
};

/// Return candidates matching input by prefix
pub fn load(allocator: std.mem.Allocator) std.mem.Allocator.Error![]h.Candidate {
    var candidates = try allocator.alloc(h.Candidate, entries.len);

    for (entries, 0..) |entry, i| {
        candidates[i] = .{
            .label = entry.keyword,
            .sublabel = entry.sublabel,
            .key = entry.method,
            .id = entry.keyword,
        };
    }

    return candidates;
}

/// Execute a systemd command using the candidate's action (D-Bus method name)
pub fn execute(key: []const u8) anyerror!void {
    var bus = try Bus.connectSystem();
    defer bus.disconnect();

    try bus.callLogin1Method(key);
}

