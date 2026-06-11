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

const candidates = [_]h.Candidate{
    .{ .label = "Suspend", .sublabel = "Suspend the system", .aliases = &.{"Sleep"}, .key = "Suspend", .id = "Suspend" },
    .{ .label = "Hibernate", .sublabel = "Hibernate the system", .key = "Hibernate", .id = "Hibernate" },
    .{ .label = "Reboot", .sublabel = "Reboot the system", .aliases = &.{"Restart"}, .key = "Reboot", .id = "Reboot" },
    .{ .label = "Shutdown", .sublabel = "Power off the system", .aliases = &.{"Turn Off"}, .key = "PowerOff", .id = "PowerOff" },
};

pub const Systemd = struct {
    /// Return candidates matching input by prefix
    pub fn load(_: *Systemd, _: std.Io) anyerror![]const h.Candidate {
        return &candidates;
    }

    /// Execute a systemd command using the candidate's action (D-Bus method name)
    pub fn execute(_: *Systemd, _: std.Io, key: []const u8) anyerror!void {
        var bus = try Bus.connectSystem();
        defer bus.disconnect();

        try bus.callLogin1Method(key);
    }

    pub fn handler(self: *Systemd) h.Handler {
        return .{
            .ptr = self,
            .name = "systemd",
            .kind = .cmd,
            .on_enter = .{ .run = h.executeFn(Systemd) },
            .source = .{ .load = h.loadFn(Systemd) },
        };
    }
};
