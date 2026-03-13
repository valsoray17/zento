const std = @import("std");

pub const ResultKind = enum {
    instant, // Calculator: show value, no action needed
    action, // SystemD or app: exec on Enter
    preview, // Dictionary: show definition
};

pub const SuggestFn = *const fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]Candidate;
pub const ExecuteFn = *const fn (Candidate) anyerror!void;

pub const Candidate = struct {
    label: []const u8, // "suspend" or "= 8"
    sublabel: ?[]const u8, // "Suspend the system" or null
    kind: ResultKind,
    /// Handler-specific command data (e.g., D-Bus method name, app path)
    action: ?[]const u8 = null,
    execute_fn: ?ExecuteFn = null,
};

/// Handler interface — each plugin implements suggest and optionally execute
pub const Handler = struct {
    name: []const u8,
    suggest: SuggestFn,
    /// Execute selected candidate. Null for instant-result handlers (e.g., calculator).
    execute: ?ExecuteFn = null,
};
