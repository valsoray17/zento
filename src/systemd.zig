const std = @import("std");

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
    fn callLogin1Method(self: *Bus, method: [*:0]const u8) !void {
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
            method, // method name
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

    /// Suspend the system
    pub fn doSuspend(self: *Bus) !void {
        return self.callLogin1Method("Suspend");
    }

    /// Hibernate the system
    pub fn hibernate(self: *Bus) !void {
        return self.callLogin1Method("Hibernate");
    }

    /// Reboot the system
    pub fn reboot(self: *Bus) !void {
        return self.callLogin1Method("Reboot");
    }

    /// Power off the system
    pub fn powerOff(self: *Bus) !void {
        return self.callLogin1Method("PowerOff");
    }
};

