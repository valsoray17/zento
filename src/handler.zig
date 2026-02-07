const std = @import("std");

pub const ResultKind = enum {
    instant, // Calculator: show value, no action needed
    action, // SystemD or app: exec or Enter
    preview, // Dictionary: show definition
};

pub const Candidate = struct {
    label: []const u8, // "suspend" or "= 8"
    sublabel: ?[]const u8, // "power command" or null
    kind: ResultKind,
    score: f32, // 0.0 - 1.0, higher = better match
};

pub const SuggestFn = *const fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]Candidate;
